#!/usr/bin/env bash
# Global mise task detection and machine setup support (ticket 03)
# shellcheck disable=SC2034

AP_SETUP_TASKS=(agent-profiles-init agent-profiles)
AP_SETUP_AGENTS=(claude codex agy opencode)
AP_SETUP_DEPS=(bash git python3 mise bwrap)

ap_setup_skill_dir() {
  printf "%s\n" "$(dirname "$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")")"
}

ap_setup_read_field() {
  local file="$1"
  local key="$2"
  if [[ ! -r "$file" ]]; then
    return 0
  fi
  sed -n "s/^${key}=//p" "$file" 2>/dev/null | head -n 1 | tr -d '"'
}

ap_setup_detect() {
  local os_name
  os_name="$(uname -s 2>/dev/null || echo unknown)"
  AP_SETUP_OS_RELEASE="${AP_OS_RELEASE:-/etc/os-release}"
  AP_SETUP_OS_ID="$(ap_setup_read_field "$AP_SETUP_OS_RELEASE" ID)"
  AP_SETUP_OS_ID_LIKE="$(ap_setup_read_field "$AP_SETUP_OS_RELEASE" ID_LIKE)"
  AP_SETUP_OS_PRETTY="$(ap_setup_read_field "$AP_SETUP_OS_RELEASE" PRETTY_NAME)"

  [[ -n "$AP_SETUP_OS_ID" ]] || AP_SETUP_OS_ID="unknown"
  [[ -n "$AP_SETUP_OS_PRETTY" ]] || AP_SETUP_OS_PRETTY="unknown"

  AP_SETUP_FAMILY="unsupported"
  if [[ "$os_name" == "Linux" ]]; then
    case " $AP_SETUP_OS_ID $AP_SETUP_OS_ID_LIKE " in
      *" arch "* | *" archlinux "*) AP_SETUP_FAMILY="arch" ;;
      *" debian "* | *" ubuntu "*) AP_SETUP_FAMILY="debian" ;;
    esac
  fi

  AP_SETUP_PKG_MANAGER=""
  case "$AP_SETUP_FAMILY" in
    arch) command -v pacman >/dev/null 2>&1 && AP_SETUP_PKG_MANAGER="pacman" ;;
    debian) command -v apt-get >/dev/null 2>&1 && AP_SETUP_PKG_MANAGER="apt-get" ;;
  esac

  if [[ -z "$AP_SETUP_PKG_MANAGER" ]]; then
    local candidate
    for candidate in pacman apt-get dnf zypper apk; do
      if command -v "$candidate" >/dev/null 2>&1; then
        AP_SETUP_PKG_MANAGER="$candidate"
        break
      fi
    done
  fi
}

ap_setup_resolve() {
  local name="$1"
  local found
  found="$(command -v "$name" 2>/dev/null || true)"
  [[ -n "$found" ]] || return 1
  readlink -f "$found" 2>/dev/null || printf "%s\n" "$found"
}

ap_setup_package_for() {
  local dep="$1"
  case "$AP_SETUP_FAMILY:$dep" in
    arch:bwrap) printf "bubblewrap\n" ;;
    debian:bwrap) printf "bubblewrap\n" ;;
    arch:python3) printf "python\n" ;;
    debian:python3) printf "python3\n" ;;
    *:bash | *:git) printf "%s\n" "$dep" ;;
    *) return 1 ;;
  esac
}

ap_setup_package_command() {
  local dep="$1"
  local package
  if ! package="$(ap_setup_package_for "$dep")"; then
    return 1
  fi
  if [[ -z "$AP_SETUP_PKG_MANAGER" ]]; then
    return 1
  fi
  case "$AP_SETUP_PKG_MANAGER" in
    pacman) printf "pacman -S %s\n" "$package" ;;
    apt-get) printf "apt-get install %s\n" "$package" ;;
    *) return 1 ;;
  esac
}

ap_setup_mise_registry_has() {
  local tool="$1"
  command -v mise >/dev/null 2>&1 || return 1
  mise registry 2>/dev/null | awk '{print $1}' | grep -Fxq "$tool"
}

ap_mise_config_dir() {
  if [[ -n "${MISE_CONFIG_DIR:-}" ]]; then
    printf "%s\n" "$MISE_CONFIG_DIR"
    return 0
  fi
  if command -v mise >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
    local resolved
    resolved="$(
      mise doctor --json 2>/dev/null | python3 -c '
import json, sys
try:
    value = json.load(sys.stdin).get("dirs", {}).get("config")
    if value and value.startswith("/"):
        print(value)
except Exception:
    pass
' 2>/dev/null || true
    )"
    if [[ -n "$resolved" ]]; then
      printf "%s\n" "$resolved"
      return 0
    fi
  fi
  printf "%s\n" "${XDG_CONFIG_HOME:-$HOME/.config}/mise"
}

ap_setup_task_path() {
  local config_dir="$1"
  local task="$2"
  printf "%s\n" "$config_dir/tasks/$task"
}

ap_setup_print_detection() {
  local id_like="none"
  [[ -n "$AP_SETUP_OS_ID_LIKE" ]] && id_like="$AP_SETUP_OS_ID_LIKE"
  printf "OS: %s (ID=%s, ID_LIKE=%s, %s family)\n" \
    "$AP_SETUP_OS_PRETTY" "$AP_SETUP_OS_ID" "$id_like" "$AP_SETUP_FAMILY"

  if [[ -n "$AP_SETUP_PKG_MANAGER" ]]; then
    printf "Package manager: %s (%s family)\n" "$AP_SETUP_PKG_MANAGER" "$AP_SETUP_FAMILY"
  else
    printf "Package manager: none detected\n"
  fi
  if [[ "$AP_SETUP_FAMILY" == "unsupported" ]]; then
    printf "  [UNSUPPORTED] unsupported automatic path: distribution family '%s' is not supported\n" \
      "$AP_SETUP_OS_ID"
  fi
  printf "\n"

  printf "Dependencies:\n"
  local dep path install_command
  for dep in "${AP_SETUP_DEPS[@]}"; do
    if path="$(ap_setup_resolve "$dep")"; then
      printf "  [OK] %s: %s\n" "$dep" "$path"
    elif [[ "$dep" == "mise" ]]; then
      printf "  [MANUAL] mise: unsupported automatic path (install mise manually; no curl installation)\n"
    elif install_command="$(ap_setup_package_command "$dep")"; then
      printf "  [MISSING] %s: not found (install: %s)\n" "$dep" "$install_command"
    else
      printf "  [MISSING] %s: not found (unsupported automatic path)\n" "$dep"
    fi
  done
  printf "\n"

  printf "Agents:\n"
  local agent
  for agent in "${AP_SETUP_AGENTS[@]}"; do
    if path="$(ap_setup_resolve "$agent")"; then
      printf "  [FOUND] %s: %s\n" "$agent" "$path"
    elif ap_setup_mise_registry_has "$agent"; then
      printf "  [MISSING] %s: not found (optional; install with --agent %s via the mise registry)\n" \
        "$agent" "$agent"
    else
      printf "  [MISSING] %s: not found (unsupported automatic path)\n" "$agent"
    fi
  done
  printf "\n"

  local config_dir task
  config_dir="$(ap_mise_config_dir)"
  printf "Global tasks:\n"
  printf "  config dir: %s\n" "$config_dir"
  for task in "${AP_SETUP_TASKS[@]}"; do
    if [[ -f "$(ap_setup_task_path "$config_dir" "$task")" ]]; then
      printf "  %s: present\n" "$task"
    else
      printf "  %s: absent\n" "$task"
    fi
  done
}

ap_setup_version() {
  local version_file
  version_file="$(ap_setup_skill_dir)/VERSION"
  if [[ ! -f "$version_file" ]]; then
    return 1
  fi
  tr -d '[:space:]' <"$version_file"
}

ap_setup_manifest_content() {
  local skill_dir="$1"
  (
    cd "$skill_dir" || exit 1
    {
      find scripts -type f -print | LC_ALL=C sort | while IFS= read -r file; do
        sha256sum "$file"
      done
      sha256sum VERSION
    }
  )
}

ap_setup_current_digest() {
  local content
  content="$(ap_setup_manifest_content "$(ap_setup_skill_dir)")" || return 1
  [[ -n "$content" ]] || return 1
  printf "%s\n" "$content" | sha256sum | cut -d' ' -f1
}

ap_setup_release_root() {
  printf "%s\n" "${XDG_DATA_HOME:-$HOME/.local/share}/flyingnobita-agent-profiles/releases"
}

# Copies the installed skill's scripts and VERSION into a versioned release
# directory and writes a sha256 manifest. Reuses an already valid release so a
# repeated apply is idempotent. Sets AP_SETUP_RELEASE_DIR, AP_SETUP_VERSION and
# AP_SETUP_MANIFEST_DIGEST, then prints the release directory.
ap_setup_deploy_release() {
  local skill_dir version content digest sha8 root final tmp
  skill_dir="$(ap_setup_skill_dir)"
  if ! version="$(ap_setup_version)"; then
    return 1
  fi
  if ! content="$(ap_setup_manifest_content "$skill_dir")" || [[ -z "$content" ]]; then
    return 1
  fi
  digest="$(printf "%s\n" "$content" | sha256sum | cut -d' ' -f1)"
  sha8="${digest:0:8}"
  root="$(ap_setup_release_root)"
  final="$root/$version-$sha8"

  if [[ -d "$final" ]] && (cd "$final" && sha256sum -c manifest.sha256 --quiet >/dev/null 2>&1); then
    AP_SETUP_RELEASE_DIR="$final"
    AP_SETUP_VERSION="$version"
    AP_SETUP_MANIFEST_DIGEST="$digest"
    printf "%s\n" "$final"
    return 0
  fi

  (umask 022 && mkdir -p "$root")
  tmp="$(mktemp -d "$root/.tmp-XXXXXX")" || return 1
  mkdir -p "$tmp/scripts"
  cp -a "$skill_dir/scripts/." "$tmp/scripts/"
  cp -a "$skill_dir/VERSION" "$tmp/VERSION"
  printf "%s\n" "$content" >"$tmp/manifest.sha256"

  if ! (cd "$tmp" && sha256sum -c manifest.sha256 --quiet >/dev/null 2>&1); then
    rm -rf "$tmp"
    return 1
  fi

  rm -rf "$final"
  mv "$tmp" "$final"

  AP_SETUP_RELEASE_DIR="$final"
  AP_SETUP_VERSION="$version"
  AP_SETUP_MANIFEST_DIGEST="$digest"
  printf "%s\n" "$final"
}

ap_setup_task_command() {
  case "$1" in
    agent-profiles-init) printf "init\n" ;;
    agent-profiles) printf "run\n" ;;
    *) return 1 ;;
  esac
}

# shellcheck disable=SC2016
ap_setup_task_content() {
  local task="$1"
  local release="$2"
  local version="$3"
  local digest="$4"
  local subcommand helper
  subcommand="$(ap_setup_task_command "$task")" || return 1
  helper="$release/scripts/agent-profiles"

  printf '#!/usr/bin/env bash\n'
  printf '#MISE dir="{{cwd}}"\n'
  printf '# managed-by: flyingnobita-agent-profiles %s sha256:%s\n' "$version" "$digest"
  printf '# release: %s\n' "$release"
  printf 'helper=%q\n' "$helper"
  printf 'if [[ ! -f "$helper" ]]; then\n'
  printf '  echo "agent-profiles: error: helper missing at $helper; rerun agent-profiles setup --apply from the installed skill" >&2\n'
  printf '  exit 78\n'
  printf 'fi\n'
  printf 'exec bash "$helper" %s "$@"\n' "$subcommand"
}

ap_setup_write_task() {
  local config_dir="$1"
  local task="$2"
  local release="$3"
  local version="$4"
  local digest="$5"
  local target tmp
  target="$(ap_setup_task_path "$config_dir" "$task")"
  tmp="$target.tmp.$$"
  if ! ap_setup_task_content "$task" "$release" "$version" "$digest" >"$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  chmod 755 "$tmp"
  mv "$tmp" "$target"
}

ap_setup_is_managed_task() {
  local file="$1"
  [[ -f "$file" ]] || return 1
  grep -Eq '^# managed-by: flyingnobita-agent-profiles [0-9]+\.[0-9]+\.[0-9]+ sha256:[0-9a-f]{64}$' "$file"
}

ap_setup_inline_conflict() {
  local config_dir="$1"
  local task="$2"
  local file
  for file in "$config_dir/config.toml" "$config_dir"/conf.d/*.toml; do
    [[ -f "$file" ]] || continue
    if grep -Eq "^\[tasks\.(\"?${task}\"?|'${task}')\][[:space:]]*$" "$file"; then
      return 0
    fi
  done
  return 1
}

# Returns 0 when mise reports a global task with this name from a source other
# than our task file, which indicates a conflict elsewhere in the global config.
ap_setup_listing_conflict() {
  local config_dir="$1"
  local task="$2"
  command -v mise >/dev/null 2>&1 || return 1
  local json
  json="$(mise tasks ls --global --json 2>/dev/null)" || return 1
  [[ -n "$json" ]] || return 1
  printf "%s" "$json" | python3 -c '
import json, sys
task = sys.argv[1]
target = sys.argv[2]
try:
    tasks = json.load(sys.stdin)
except Exception:
    sys.exit(1)
for entry in tasks:
    if entry.get("name") != task:
        continue
    source = entry.get("source") or entry.get("file") or ""
    if source and source != target:
        sys.exit(0)
sys.exit(1)
' "$task" "$(ap_setup_task_path "$config_dir" "$task")"
}

ap_setup_backup_task() {
  local file="$1"
  local backup_root timestamp backup_dir
  backup_root="${XDG_STATE_HOME:-$HOME/.local/state}/flyingnobita-agent-profiles/backups"
  timestamp="$(date -u +%Y%m%dT%H%M%SZ)-$$"
  backup_dir="$backup_root/$timestamp/tasks"
  (umask 077 && mkdir -p "$backup_dir") || return 1
  cp -a "$file" "$backup_dir/"
  printf "%s\n" "$backup_dir/$(basename "$file")"
}

ap_setup_managed_config_reason() {
  local config_dir="$1"
  local tasks_dir="$config_dir/tasks"
  local task target

  if [[ -L "$tasks_dir" ]]; then
    printf "tasks directory '%s' is a symlink\n" "$tasks_dir"
    return 0
  fi
  for task in "${AP_SETUP_TASKS[@]}"; do
    target="$(ap_setup_task_path "$config_dir" "$task")"
    if [[ -L "$target" ]]; then
      printf "task file '%s' is a symlink\n" "$target"
      return 0
    fi
    if [[ -e "$target" && ! -w "$target" ]]; then
      printf "task file '%s' is read-only\n" "$target"
      return 0
    fi
  done
  if [[ -d "$tasks_dir" && ! -w "$tasks_dir" ]]; then
    printf "tasks directory '%s' is read-only\n" "$tasks_dir"
    return 0
  fi
  if command -v chezmoi >/dev/null 2>&1 && chezmoi source-path "$tasks_dir" >/dev/null 2>&1; then
    printf "chezmoi manages the tasks directory\n"
    return 0
  fi
  return 1
}

ap_setup_prepare_managed() {
  local config_dir="$1"
  local reason="$2"
  local prepare_dir="$3"
  local version digest release task

  printf "managed configuration detected: %s\n" "$reason"
  if [[ -z "$prepare_dir" ]]; then
    printf "The target was left untouched. Rerun with --prepare-dir DIR to prepare source changes for your configuration manager.\n"
    return 0
  fi

  version="$(ap_setup_version)" || return 1
  digest="$(ap_setup_current_digest)" || return 1
  release="$(ap_setup_release_root)/$version-${digest:0:8}"

  (umask 022 && mkdir -p "$prepare_dir/tasks") || return 1
  for task in "${AP_SETUP_TASKS[@]}"; do
    if ! ap_setup_task_content "$task" "$release" "$version" "$digest" \
      >"$prepare_dir/tasks/$task"; then
      return 1
    fi
    chmod 755 "$prepare_dir/tasks/$task"
  done

  cat >"$prepare_dir/INSTRUCTIONS.md" <<EOF
# Prepared agent-profiles mise tasks

Managed configuration was detected: $reason

The target task files were not modified. Copy the prepared task files into your managed source:

- $prepare_dir/tasks/agent-profiles-init -> $config_dir/tasks/agent-profiles-init
- $prepare_dir/tasks/agent-profiles -> $config_dir/tasks/agent-profiles

Then rerun:

    bash $(ap_setup_skill_dir)/scripts/agent-profiles setup --apply

This deploys the helper release at $release and installs the two global tasks.
EOF

  printf "prepared: %s\n" "$prepare_dir"
}

# Apply the machine setup: deploy the release and install both global task
# files, preserving foreign tasks and backing up managed files before changes.
ap_setup_apply_tasks() {
  local prepare_dir="${1:-}"
  local config_dir reason
  config_dir="$(ap_mise_config_dir)"

  if ! command -v mise >/dev/null 2>&1 && [[ -z "${MISE_CONFIG_DIR:-}" ]]; then
    ap_die "$EX_UNAVAILABLE" "mise is required for global task integration; install mise manually (no curl installation)"
  fi

  if reason="$(ap_setup_managed_config_reason "$config_dir")"; then
    ap_setup_prepare_managed "$config_dir" "$reason" "$prepare_dir" \
      || ap_die "$EX_BROKEN" "failed to prepare managed configuration files"
    return 0
  fi

  if ! ap_setup_deploy_release >/dev/null; then
    ap_die "$EX_BROKEN" "failed to deploy the versioned helper release"
  fi

  (umask 022 && mkdir -p "$config_dir/tasks")
  local task target content conflicts=0 backup
  for task in "${AP_SETUP_TASKS[@]}"; do
    target="$(ap_setup_task_path "$config_dir" "$task")"

    if ap_setup_inline_conflict "$config_dir" "$task"; then
      printf "conflict: inline mise task '%s' in the global config was left untouched\n" "$task"
      conflicts=$((conflicts + 1))
      continue
    fi

    if [[ -e "$target" ]] && ! ap_setup_is_managed_task "$target"; then
      printf "conflict: foreign task file '%s' was left untouched\n" "$target"
      conflicts=$((conflicts + 1))
      continue
    fi

    if [[ ! -e "$target" ]] && ap_setup_listing_conflict "$config_dir" "$task"; then
      printf "conflict: global mise task '%s' from another source was left untouched\n" "$task"
      conflicts=$((conflicts + 1))
      continue
    fi

    content="$(ap_setup_task_content "$task" "$AP_SETUP_RELEASE_DIR" \
      "$AP_SETUP_VERSION" "$AP_SETUP_MANIFEST_DIGEST")" || {
      ap_die "$EX_BROKEN" "failed to render global mise task: $target"
    }

    if [[ -f "$target" ]] && printf "%s\n" "$content" | cmp -s - "$target"; then
      continue
    fi

    if [[ -f "$target" ]]; then
      if ! backup="$(ap_setup_backup_task "$target")"; then
        ap_die "$EX_BROKEN" "failed to back up the previous task file: $target"
      fi
      printf "backup: %s\n" "$backup"
    fi

    if ! ap_setup_write_task "$config_dir" "$task" "$AP_SETUP_RELEASE_DIR" \
      "$AP_SETUP_VERSION" "$AP_SETUP_MANIFEST_DIGEST"; then
      ap_die "$EX_BROKEN" "failed to write global mise task: $target"
    fi
  done

  printf "\nApplied:\n"
  printf "  release: %s\n" "$AP_SETUP_RELEASE_DIR"
  for task in "${AP_SETUP_TASKS[@]}"; do
    printf "  task: %s\n" "$(ap_setup_task_path "$config_dir" "$task")"
  done
  if [[ $conflicts -gt 0 ]]; then
    printf "  conflicts: %s (existing tasks preserved)\n" "$conflicts"
  fi
}
