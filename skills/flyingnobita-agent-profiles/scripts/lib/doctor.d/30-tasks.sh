#!/usr/bin/env bash
# Doctor section: global mise task deployment and release health (ticket 03)
# shellcheck disable=SC2034

# shellcheck source=skills/flyingnobita-agent-profiles/scripts/lib/mise-tasks.sh
source "$LIB_DIR/mise-tasks.sh"

ap_doctor_task_marker() {
  local file="$1"
  local key="$2"
  case "$key" in
    digest)
      sed -n 's/^# managed-by: flyingnobita-agent-profiles [^ ]* sha256:\([0-9a-f]*\)$/\1/p' "$file"
      ;;
    release)
      sed -n 's/^# release: //p' "$file"
      ;;
  esac
}

ap_doctor_check_tasks() {
  local config_dir tasks_dir expected
  local status="available"
  local -a details=()
  local hint=""

  config_dir="$(ap_mise_config_dir 2>/dev/null || true)"
  tasks_dir="$config_dir/tasks"
  expected="$(ap_setup_current_digest 2>/dev/null || true)"

  local task target release digest
  local -a managed_tasks=()
  local -a absent_tasks=()
  local stale=0 broken=0 foreign=0
  for task in "${AP_SETUP_TASKS[@]}"; do
    target="$(ap_setup_task_path "$config_dir" "$task")"
    if [[ ! -e "$target" ]]; then
      absent_tasks+=("$task")
      continue
    fi
    if ! ap_setup_is_managed_task "$target"; then
      foreign=1
      details+=("foreign task '$target' is preserved and not managed")
      continue
    fi

    digest="$(ap_doctor_task_marker "$target" digest)"
    release="$(ap_doctor_task_marker "$target" release)"
    if [[ -z "$release" || ! -d "$release" ]]; then
      broken=1
      details+=("broken: release directory '$release' is missing")
      continue
    fi
    if ! (cd "$release" && sha256sum -c manifest.sha256 --quiet >/dev/null 2>&1); then
      broken=1
      details+=("broken: release manifest verification failed at '$release'")
      continue
    fi
    if [[ -n "$expected" && "$digest" != "$expected" ]]; then
      stale=1
      details+=("stale: deployed release '$release' does not match the installed skill (rerun setup)")
      continue
    fi
    managed_tasks+=("$task")
  done

  if [[ $broken -eq 1 ]]; then
    status="error"
    hint="Rerun 'agent-profiles setup --apply' to redeploy the versioned helper release."
  elif [[ $stale -eq 1 ]]; then
    status="warning"
    hint="Rerun 'agent-profiles setup --apply' to deploy the current skill version."
  elif [[ $foreign -eq 1 ]]; then
    status="warning"
    hint="Remove or rename the conflicting task before rerunning 'agent-profiles setup --apply'."
  elif [[ ${#absent_tasks[@]} -eq ${#AP_SETUP_TASKS[@]} ]]; then
    status="missing"
    hint="Run 'agent-profiles setup --apply' to install the global mise tasks."
  elif [[ ${#absent_tasks[@]} -gt 0 ]]; then
    status="warning"
    hint="Run 'agent-profiles setup --apply' to install the missing global task."
  fi

  if [[ ${#managed_tasks[@]} -gt 0 ]]; then
    details+=("managed tasks: ${managed_tasks[*]}")
  fi
  if [[ ${#absent_tasks[@]} -gt 0 ]]; then
    details+=("absent tasks: ${absent_tasks[*]}")
  fi
  details+=("task directory: $tasks_dir")

  local reason
  if reason="$(ap_setup_managed_config_reason "$config_dir" 2>/dev/null)"; then
    if [[ "$status" == "available" || "$status" == "missing" ]]; then
      status="warning"
    fi
    details+=("managed configuration: $reason; prepared files are required")
    hint="Rerun with --prepare-dir DIR and deploy the prepared source changes through your configuration manager."
  fi

  local repo_root
  repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  if [[ -n "$repo_root" ]]; then
    local project_file
    for project_file in "$repo_root/mise.toml" "$repo_root/.mise.toml" "$repo_root/mise.local.toml"; do
      [[ -f "$project_file" ]] || continue
      if grep -Eq '^\[tasks\.("?)(agent-profiles|agent-profiles-init)("?)\]' "$project_file"; then
        if [[ "$status" == "available" ]]; then
          status="warning"
        fi
        details+=("project-level task in '$project_file' shadows the global task in this checkout")
      fi
    done
  fi

  if [[ ${#details[@]} -eq 0 ]]; then
    details+=("no global task configuration found")
  fi

  local detail
  detail="$(printf '%s; ' "${details[@]}")"
  detail="${detail%; }"

  CHECKS_JSON=$(python3 -c '
import json, sys
checks = json.loads(sys.argv[1])
checks.append({
    "id": "tasks",
    "status": sys.argv[2],
    "detail": sys.argv[3],
    "hint": sys.argv[4]
})
print(json.dumps(checks))
' "$CHECKS_JSON" "$status" "$detail" "$hint")
}

ap_register_doctor_section "ap_doctor_check_tasks"
