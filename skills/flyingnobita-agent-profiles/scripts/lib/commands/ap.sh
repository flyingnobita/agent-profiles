#!/usr/bin/env bash
# Command: ap
# Short, profile-first grammar behind the global `mise ap` task. Every form
# delegates to the long commands in a fresh helper process.
# shellcheck source=skills/flyingnobita-agent-profiles/scripts/lib/runtime.sh

source "$LIB_DIR/runtime.sh"

ap_ap_usage() {
  cat <<'EOF'
Usage:
  mise ap NAME [COMMAND [ARGS...]]   Run COMMAND (default: your shell) in profile NAME
  mise ap --create NAME [COMMAND...] Same, creating NAME without asking
  mise ap new NAME                   Create profile NAME in this checkout
  mise ap ls                         List profiles in this checkout
  mise ap rm NAME [--yes]            Remove profile NAME (preview until --yes)
  mise ap reset NAME [--yes]         Recreate profile NAME empty (preview until --yes)
  mise ap doctor [OPTIONS]           Diagnose the machine and agent integrations
  mise ap migrate | recover [--yes]  Convert legacy storage, finish an interrupted operation
  mise ap --version                  Print the helper version

A missing profile is offered for creation in a terminal; elsewhere pass --create.
EOF
}

ap_ap_helper() {
  bash "$SCRIPT_DIR/agent-profiles" "$@"
}

# Creates the profile when it is missing: --create or a yes in a terminal.
# A typo must not silently become a new profile, so anything else refuses.
ap_ap_ensure_profile() {
  local name="$1"
  local create="$2"
  local repo_root reply
  repo_root=$(ap_find_repo_root)

  [[ -d "$repo_root/.agent-profiles/$name/home" ]] && return 0

  if [[ "$create" -eq 0 ]]; then
    if [[ ! -t 0 || ! -t 2 ]]; then
      ap_die "$EX_NOINPUT" "profile '$name' does not exist in this checkout; rerun with --create to create it"
    fi
    read -r -p "Create profile '$name' in $repo_root? [y/N] " reply || reply=""
    if [[ ! "$reply" =~ ^[Yy]([Ee][Ss])?$ ]]; then
      ap_die "$EX_NOINPUT" "profile '$name' was not created"
    fi
  fi

  ap_ap_helper init --profile "$name" || exit $?
}

ap_cmd_ap() {
  local create=0

  case "${1:-}" in
    "" | help | -h | --help)
      if [[ $# -eq 0 ]]; then
        ap_ap_usage >&2
        exit "$EX_USAGE"
      fi
      ap_ap_usage
      exit "$EX_OK"
      ;;
    ls | list)
      exec bash "$SCRIPT_DIR/agent-profiles" list "${@:2}"
      ;;
    new)
      [[ $# -eq 2 ]] || ap_die "$EX_USAGE" "usage: mise ap new NAME"
      exec bash "$SCRIPT_DIR/agent-profiles" init --profile "$2"
      ;;
    rm | reset)
      [[ $# -ge 2 ]] || ap_die "$EX_USAGE" "usage: mise ap $1 NAME [--yes]"
      local cmd="$1"
      [[ "$cmd" == "rm" ]] && cmd="remove"
      exec bash "$SCRIPT_DIR/agent-profiles" "$cmd" --profile "$2" "${@:3}"
      ;;
    doctor | migrate | recover | -v | --version)
      exec bash "$SCRIPT_DIR/agent-profiles" "$@"
      ;;
    --profile | --profile=*)
      # The previous `agent-profiles` task took run's own options.
      exec bash "$SCRIPT_DIR/agent-profiles" run "$@"
      ;;
    --create)
      create=1
      shift
      ;;
  esac

  [[ $# -gt 0 ]] || ap_die "$EX_USAGE" "usage: mise ap --create NAME [COMMAND...]"
  local name="$1"
  shift
  ap_validate_profile_name "$name"
  ap_ap_ensure_profile "$name" "$create"

  if [[ $# -eq 0 ]]; then
    set -- "${SHELL:-bash}"
  fi
  exec bash "$SCRIPT_DIR/agent-profiles" run --profile "$name" -- "$@"
}
