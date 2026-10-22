import Foundation
import Darwin
import WorkbenchProtocol
import WorkbenchRuntime

enum UserFacingFailure {
  static func message(_ error: any Error) -> String {
    if let error = error as? UIError { return error.localizedDescription }
    if let startup = error as? StartupFailure { return startup.localizedDescription }
    if let transport = error as? TransportFailure {
      switch transport {
      case .oversizedReply: return "표시할 변경 내용이 너무 큽니다. 파일을 나누어 검토하거나 Git에서 확인해 주세요."
      case .unsupportedSchema: return "앱과 작업 엔진의 버전이 맞지 않습니다. 업데이트한 앱을 다시 열어 주세요."
      case .system(_, let code) where code == ETIMEDOUT: return "작업 엔진의 응답이 지연되었습니다. 현재 변경 상태를 새로고침한 뒤 다시 시도해 주세요."
      case .oversizedRequest: return "입력 내용이 요청 크기 제한을 넘었습니다. 내용을 줄여 다시 시도해 주세요."
      case .invalidReply: return "작업 엔진의 응답을 읽지 못했습니다. 현재 변경 상태를 새로고침해 주세요."
      default: return "작업 엔진에 연결하지 못했습니다. ‘다시 연결’을 눌러 작업을 이어가세요."
      }
    }
    if let service = error as? ServiceFailure {
      switch service.code {
      case "unsupported_external_filter": return "Git 외부 필터가 등록되어 있습니다. 현재 버전은 실제 사용 여부와 관계없이 전역 설정을 포함한 외부 필터 환경을 지원하지 않습니다."
      case "unsafe_task_worktree", "wrong_task_branch": return "작업 폴더의 위치나 브랜치가 바뀌었습니다. 원래 폴더와 브랜치를 복구한 뒤 새로고침해 주세요."
      case "unsafe_source_repository": return "원래 저장소의 Git 위치 설정이 바뀌었습니다. 저장소 설정을 확인하고 다시 열어 주세요."
      case "git_unavailable": return "Git을 실행하지 못했습니다. macOS의 Command Line Tools 또는 Xcode 설치 상태를 확인해 주세요."
      case "unknown_method": return "앱과 작업 엔진의 기능 버전이 맞지 않습니다. 앱을 완전히 종료한 뒤 업데이트한 앱을 다시 열어 주세요."
      case "unsafe_repository_lock": return "저장소의 작업 잠금 파일이 일반 파일이 아니거나 안전하지 않습니다. Git 폴더의 workbench.operation.lock을 확인해 주세요."
      case "invalid_label": return "작업 이름은 줄바꿈 없이 200바이트 이내로 입력해 주세요."
      case "unsupported_hunk_change": return "이 변경은 앱에서 부분 스테이징할 수 없습니다. Git에서 파일 종류와 전체 변경을 확인해 주세요."
      case "journal_configuration_mismatch": return "저장한 작업 기록과 저장소 구성이 맞지 않습니다. 기존 기록을 다른 설정으로 열 수 없습니다."
      case "stale_source_snapshot": return "계획을 만든 뒤 원래 프로젝트 폴더가 바뀌었습니다. 현재 변경은 유지됩니다. 현재 상태를 기준으로 새 작업을 만들어 주세요."
      case "unsupported_submodule_or_directory": return "이 저장소에는 아직 지원하지 않는 하위 저장소나 특수 파일이 있습니다. Git에서 해당 항목을 확인해 주세요."
      case "unsupported_nested_repository": return "프로젝트 안에 별도의 Git 저장소가 있습니다. 중첩 저장소나 에이전트 작업 폴더를 .gitignore에 추가하거나 프로젝트 밖으로 옮긴 뒤 다시 확인해 주세요."
      case "unsafe_relative_path", "symlink_parent": return "파일 경로를 안전하게 읽을 수 없습니다. 프로젝트 안의 중첩 저장소나 심볼릭 링크를 Git에서 확인해 주세요."
      case "result_too_large": return "표시할 변경 내용이 너무 큽니다. 파일을 나누어 검토하거나 Git에서 확인해 주세요."
      case "git_timeout": return "Git 조회가 오래 걸려 중단했습니다. 저장소와 디스크 상태를 확인한 뒤 다시 시도해 주세요."
      case "git_write_outcome_unknown": return "Git 쓰기의 완료 여부를 확인하지 못했습니다. 같은 동작을 반복하기 전에 새로고침과 Git 기록을 확인해 주세요. 잠금 파일은 실행 중인 Git 작업이 없는지 확인한 뒤 처리하세요."
      case "git_failed" where service.message.contains("index.lock"): return "Git 잠금 파일이 있어 쓰기를 완료하지 못했습니다. 다른 Git 작업이 실행 중인지 먼저 확인해 주세요."
      case "git_failed" where service.message.contains("Author identity unknown") || service.message.contains("unable to auto-detect email"): return "커밋 작성자 이름과 이메일이 설정되지 않았습니다. Git의 user.name과 user.email을 설정한 뒤 다시 커밋해 주세요."
      case "invalid_slug": return "브랜치 이름에는 영문·숫자·하이픈을 사용해 주세요. 64자 이내이며 하이픈으로 시작할 수 없습니다."
      case "unsupported_encoding", "unsupported_filename_encoding": return "이 항목의 문자 인코딩을 읽을 수 없습니다. Git에서 원본 인코딩을 확인해 주세요."
      case "branch_collision": return "같은 이름의 브랜치가 이미 있습니다. 다른 작업 이름으로 새 계획을 만들어 주세요."
      case "worktree_collision": return "작업 폴더가 이미 있습니다. 기존 폴더를 확인하고 다른 브랜치 이름으로 새 계획을 만들어 주세요."
      case "stale_plan": return "실행 계획의 유효 시간이 지났습니다. 현재 상태로 계획을 다시 확인해 주세요."
      case "untrusted_recipe": return "준비 스크립트가 아직 신뢰 등록되지 않았습니다. 스크립트와 실행 프로그램을 확인하고 등록한 뒤 다시 계획해 주세요."
      case "service_stopping": return "작업 엔진을 종료하고 있습니다. 잠시 후 저장소를 다시 열어 주세요."
      case "unexpected_changes": return "준비 스크립트가 허용한 범위 밖의 파일을 바꿨습니다. 변경을 확인한 뒤 복구 여부를 결정해 주세요."
      case "recipe_failed", "recipe_timeout": return "준비 스크립트를 완료하지 못했습니다. 작업 폴더의 변경과 준비 기록을 확인한 뒤 다시 시도해 주세요."
      case "stale_snapshot", "stale_read_snapshot": return "파일이 외부에서 변경되었습니다. 새로고침한 뒤 다시 시도해 주세요."
      case "stale_diff": return "변경 표시 기준이 바뀌었습니다. Diff를 다시 읽고 스테이징할 변경을 확인해 주세요."
      case "repo_locked", "repository_busy", "service_busy": return "다른 작업이 저장소를 사용 중입니다. 잠시 후 다시 시도해 주세요."
      case "preparation_queue_full": return "준비 작업이 가득 찼습니다. 진행 중인 작업이 끝나거나 취소가 완료된 뒤 다시 시도해 주세요."
      case "task_not_ready": return "이 저장소의 준비가 끝나지 않았습니다. 준비 결과를 확인하고 완료한 뒤 편집해 주세요."
      case "context_conflict": return "다른 화면에서 저장한 내용이 있습니다. 입력은 유지했습니다. 새로고침 후 저장본을 확인해 주세요."
      case "invalid_task_context": return "입력 범위를 확인해 주세요. 목적 2,000자, 완료 조건 30개·각 300자, 참고 10개, 남은 일 5,000자까지 저장할 수 있습니다."
      case "invalid_verification_report": return "결과와 근거를 입력해 주세요. 긴 로그나 명령 설명은 핵심 내용으로 줄여 다시 저장해 주세요."
      default: break
      }
    }
    return "작업을 완료하지 못했습니다. 변경 사항을 확인한 뒤 다시 시도해 주세요."
  }
}
