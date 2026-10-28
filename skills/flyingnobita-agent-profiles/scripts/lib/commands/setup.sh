#!/usr/bin/env bash
# Command: setup - detect the Linux machine environment and configure global
# mise tasks without touching unrelated configuration.
# shellcheck source=skills/flyingnobita-agent-profiles/scripts/lib/mise-tasks.sh

source "$LIB_DIR/mise-tasks.sh"

ap_cmd_setup() {
  local mode=""
  local prepare_dir=""
  local tasks_only=0
  local -a requested_agents=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --preview)
        if [[ "$mode" == "apply" ]]; then
          ap_die "$EX_USAGE" "--preview and --apply are mutually exclusive"
        fi
        mode="preview"
        shift
        ;;
      --apply)
        if [[ "$mode" == "preview" ]]; then
          ap_die "$EX_USAGE" "--preview and --apply are mutually exclusive"
        fi
        mode="apply"
        shift
        ;;
      --tasks-only)
        # shellcheck disable=SC2034
        tasks_only=1
        shift
        ;;
      --agent)
        if [[ $# -lt 2 ]]; then
          ap_die "$EX_USAGE" "--agent requires an agent argument"
        fi
        requested_agents+=("$2")
        shift 2
        ;;
      --agent=*)
        requested_agents+=("${1#*=}")
        shift
        ;;
      --prepare-dir)
        if [[ $# -lt 2 ]]; then
          ap_die "$EX_USAGE" "--prepare-dir requires a directory argument"
        fi
        prepare_dir="$2"
        shift 2
        ;;
      --prepare-dir=*)
        prepare_dir="${1#*=}"
        shift
        ;;
      -*)
        ap_die "$EX_USAGE" "unknown setup option: $1"
        ;;
      *)
        ap_die "$EX_USAGE" "unexpected setup argument: $1"
        ;;
    esac
  done

  local agent
  for agent in "${requested_agents[@]:-}"; do
    [[ -n "$agent" ]] || continue
    case "$agent" in
      claude | codex | agy | opencode) ;;
      *) ap_die "$EX_USAGE" "unsupported agent: $agent. Supported agents: claude, codex, agy, opencode" ;;
    esac
  done

  if [[ -n "$prepare_dir" && "$prepare_dir" != /* ]]; then
    prepare_dir="$PWD/$prepare_dir"
  fi

  if [[ -z "$mode" ]]; then
    mode="preview"
  fi

  ap_setup_detect
  ap_setup_print_detection

  if [[ "$mode" == "preview" ]]; then
    ap_setup_print_plan "${requested_agents[@]:-}"
    printf "\nNo changes made (preview). Use --apply to configure global mise tasks.\n"
    return 0
  fi

  ap_setup_apply_tasks "$prepare_dir" "$tasks_only" "${requested_agents[@]}"
}
