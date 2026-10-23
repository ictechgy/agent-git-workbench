use crate::{Request, Response, Service};
use anyhow::{Context, Result, ensure};
use fs2::FileExt;
use std::{
    fs,
    io::{BufRead, BufReader, BufWriter, Read, Write},
    os::fd::AsRawFd,
    os::unix::{
        fs::{FileTypeExt, MetadataExt, PermissionsExt},
        net::{UnixListener, UnixStream},
    },
    path::Path,
    sync::Arc,
    thread,
    time::{Duration, Instant},
};

const MAX_REQUEST: u64 = 1024 * 1024;
const MAX_HANDLERS: usize = 32;
const FRAME_TIMEOUT: Duration = Duration::from_secs(10);
pub fn serve(service: Arc<Service>, socket: &Path) -> Result<()> {
    let parent = socket.parent().context("socket_parent_required")?;
    fs::create_dir_all(parent)?;
    let meta = fs::symlink_metadata(parent)?;
    ensure!(
        meta.is_dir() && !meta.file_type().is_symlink() && meta.uid() == unsafe { libc_uid() },
        "unsafe_socket_directory"
    );
    fs::set_permissions(parent, fs::Permissions::from_mode(0o700))?;
    let lock = fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .open(socket.with_extension("socket.lock"))?;
    lock.try_lock_exclusive().context("socket_in_use")?;
    if let Ok(meta) = fs::symlink_metadata(socket) {
        ensure!(
            meta.file_type().is_socket()
                && meta.uid() == unsafe { libc_uid() }
                && UnixStream::connect(socket).is_err(),
            "socket_in_use"
        );
        fs::remove_file(socket)?;
    }
    let listener = UnixListener::bind(socket)?;
    listener.set_nonblocking(true)?;
    fs::set_permissions(socket, fs::Permissions::from_mode(0o600))?;
    let mut handlers = Vec::new();
    while !service.is_stopping() {
        // Reap under sustained accepts too, and bound Git reads and idle peers.
        handlers.retain(|handler: &thread::JoinHandle<()>| !handler.is_finished());
        match listener.accept() {
            Ok((mut stream, _)) => {
                stream.set_nonblocking(false)?;
                if handlers.len() >= MAX_HANDLERS {
                    stream.set_write_timeout(Some(Duration::from_millis(100)))?;
                    let _ = stream.write_all(b"{\"schema_version\":1,\"error\":{\"code\":\"service_busy\",\"message\":\"Too many concurrent requests; retry shortly.\"}}\n");
                    continue;
                }
                let service = service.clone();
                handlers.push(thread::spawn(move || {
                    let _ = handle(service, stream);
                }));
            }
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                let mut descriptor = libc::pollfd {
                    fd: listener.as_raw_fd(),
                    events: libc::POLLIN,
                    revents: 0,
                };
                // A shutdown RPC sets stopping; poll bounds the final wakeup
                // without waking every 10 ms while the workspace is idle.
                unsafe {
                    libc::poll(&mut descriptor, 1, 250);
                }
            }
            Err(error) => return Err(error.into()),
        }
    }
    // The shutdown response is fully written before the process exits. Existing
    // read requests can finish; no new mutation is accepted after stopping=true.
    for handler in handlers {
        let _ = handler.join();
    }
    fs::remove_file(socket)?;
    drop(lock);
    Ok(())
}
unsafe fn libc_uid() -> u32 {
    unsafe extern "C" {
        fn geteuid() -> u32;
    }
    unsafe { geteuid() }
}
fn handle(service: Arc<Service>, mut stream: UnixStream) -> Result<()> {
    let mut line = String::new();
    let reader = DeadlineReader {
        stream: &stream,
        deadline: Instant::now() + FRAME_TIMEOUT,
    };
    BufReader::new(reader.take(MAX_REQUEST + 1)).read_line(&mut line)?;
    ensure!(
        line.len() as u64 <= MAX_REQUEST && line.ends_with('\n'),
        "invalid_request_frame"
    );
    let request: Request = serde_json::from_str(&line)?;
    let response = service.dispatch(request);
    let writer = DeadlineWriter {
        stream: &mut stream,
        deadline: Instant::now() + FRAME_TIMEOUT,
    };
    let mut writer = BufWriter::new(writer);
    serde_json::to_writer(&mut writer, &response)?;
    writer.write_all(b"\n")?;
    writer.flush()?;
    Ok(())
}

fn remaining(deadline: Instant) -> std::io::Result<Duration> {
    deadline
        .checked_duration_since(Instant::now())
        .filter(|d| !d.is_zero())
        .ok_or_else(|| std::io::Error::new(std::io::ErrorKind::TimedOut, "IPC frame deadline"))
}
struct DeadlineReader<'a> {
    stream: &'a UnixStream,
    deadline: Instant,
}
impl Read for DeadlineReader<'_> {
    fn read(&mut self, buffer: &mut [u8]) -> std::io::Result<usize> {
        self.stream
            .set_read_timeout(Some(remaining(self.deadline)?))?;
        self.stream.read(buffer)
    }
}
struct DeadlineWriter<'a> {
    stream: &'a mut UnixStream,
    deadline: Instant,
}
impl Write for DeadlineWriter<'_> {
    fn write(&mut self, buffer: &[u8]) -> std::io::Result<usize> {
        self.stream
            .set_write_timeout(Some(remaining(self.deadline)?))?;
        self.stream.write(buffer)
    }
    fn flush(&mut self) -> std::io::Result<()> {
        self.stream.flush()
    }
}
pub fn call(socket: &Path, request: &Request) -> Result<Response> {
    let mut stream = UnixStream::connect(socket).context("service_unavailable")?;
    let timeout = if matches!(
        request.method.as_str(),
        "configure_remote" | "fetch_remote" | "pull_remote" | "push_remote"
    ) {
        360
    } else if matches!(request.method.as_str(), "stage_hunk" | "commit") {
        180
    } else {
        30
    };
    stream.set_read_timeout(Some(Duration::from_secs(timeout)))?;
    serde_json::to_writer(&mut stream, request)?;
    stream.write_all(b"\n")?;
    let mut line = String::new();
    BufReader::new(stream.take(16 * 1024 * 1024)).read_line(&mut line)?;
    ensure!(line.ends_with('\n'), "invalid_response_frame");
    Ok(serde_json::from_str(&line)?)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn a_dribbling_peer_cannot_reset_the_frame_deadline() {
        let (server, mut client) = UnixStream::pair().unwrap();
        let sender = thread::spawn(move || {
            for _ in 0..20 {
                if client.write_all(b"x").is_err() {
                    break;
                }
                thread::sleep(Duration::from_millis(20));
            }
        });
        let start = Instant::now();
        let mut reader = DeadlineReader {
            stream: &server,
            deadline: start + Duration::from_millis(100),
        };
        assert!(reader.read_to_end(&mut Vec::new()).is_err());
        assert!(start.elapsed() < Duration::from_millis(350));
        drop(server);
        sender.join().unwrap();
    }
    #[test]
    fn non_reading_peer_cannot_block_a_response_forever() {
        let (mut server, _client) = UnixStream::pair().unwrap();
        let start = Instant::now();
        let mut writer = DeadlineWriter {
            stream: &mut server,
            deadline: start + Duration::from_millis(100),
        };
        assert!(writer.write_all(&vec![0; 4 * 1024 * 1024]).is_err());
        assert!(start.elapsed() < Duration::from_secs(1));
    }
    #[test]
    fn idle_connections_are_bounded_and_service_recovers_after_disconnect() {
        let temp = tempfile::TempDir::new().unwrap();
        let home = temp.path().join("fixture");
        let workspace = crate::fixtures::create(&home).unwrap();
        let service = Service::open(workspace, &home.join("journal.sqlite")).unwrap();
        let socket = temp.path().join("ipc/service.sock");
        let running = service.clone();
        let path = socket.clone();
        let server = thread::spawn(move || serve(running, &path).unwrap());
        let start = Instant::now();
        while !socket.exists() {
            assert!(start.elapsed() < Duration::from_secs(3));
            thread::sleep(Duration::from_millis(5));
        }
        let clients: Vec<_> = (0..MAX_HANDLERS)
            .map(|_| UnixStream::connect(&socket).unwrap())
            .collect();
        let busy = call(
            &socket,
            &Request {
                method: "list_workspaces".into(),
                params: serde_json::json!({}),
            },
        )
        .unwrap();
        drop(clients);
        // Shutdown through the owning service so even a failing assertion has
        // no orphan listener or sleeping test thread.
        assert!(service.shutdown_if_idle().unwrap());
        server.join().unwrap();
        assert_eq!(busy.error.unwrap().code, "service_busy");
    }
}
