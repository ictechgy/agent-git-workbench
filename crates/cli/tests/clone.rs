use std::{fs, process::Command};

#[test]
fn clone_rejects_unsafe_transport_and_credentials_without_writing_a_destination() {
    let temp = tempfile::TempDir::new().unwrap();
    for url in [
        "file:///tmp/not-a-remote.git",
        "ext::sh -c arbitrary-command",
        "https://river-user:river-secret@git.example.test/team/project.git",
    ] {
        let destination = temp.path().join("new project 한글");
        let output = Command::new(env!("CARGO_BIN_EXE_workbench"))
            .arg("clone")
            .arg(url)
            .arg(&destination)
            .output()
            .unwrap();
        assert!(!output.status.success());
        assert!(output.stdout.is_empty());
        let error = String::from_utf8(output.stderr).unwrap();
        assert!(serde_json::from_str::<serde_json::Value>(&error).is_ok());
        assert!(!error.contains("river-user"));
        assert!(!error.contains("river-secret"));
        assert!(!destination.exists());
    }
}

#[test]
fn clone_never_overwrites_an_existing_destination() {
    let temp = tempfile::TempDir::new().unwrap();
    let destination = temp.path().join("existing");
    fs::create_dir(&destination).unwrap();
    let owned = destination.join("user.txt");
    fs::write(&owned, "preserve this file").unwrap();
    let output = Command::new(env!("CARGO_BIN_EXE_workbench"))
        .args(["clone", "https://git.example.test/team/project.git"])
        .arg(&destination)
        .output()
        .unwrap();
    assert!(!output.status.success());
    assert_eq!(fs::read_to_string(owned).unwrap(), "preserve this file");
}
