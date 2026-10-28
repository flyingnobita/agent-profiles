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
  awk -F= -v key="$key" '$1 == key { value = substr($0, length(key) + 2); gsub(/"/, "", value); print value; exit }' "$file" 2>/dev/null
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
  mise registry 2>/dev/null | awk -v tool="$tool" '$1 == tool { found = 1 } END { exit !found }'
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

# Read-only plan for setup --preview: names the release and task writes,
# conflicts, missing prerequisites and requested agent installs. It writes
# nothing and calls no installer.
ap_setup_print_plan() {
  local tasks_only="$1"
  local prepare_dir="$2"
  shift 2
  local version digest release config_dir reason task target dep agent path
  local -a requested_agents=("$@")

  version="$(ap_setup_version 2>/dev/null || true)"
  digest="$(ap_setup_current_digest 2>/dev/null || true)"
  config_dir="$(ap_mise_config_dir)"

  printf "\nPlanned changes (preview only; nothing is written):\n"
  if [[ -n "$version" && -n "$digest" ]]; then
    release="$(ap_setup_release_root)/$version-${digest:0:8}"
  else
    release="unknown (VERSION or scripts manifest could not be read)"
  fi
  local tasks_managed=0
  if reason="$(ap_setup_managed_config_reason "$config_dir")"; then
    tasks_managed=1
    printf "  release: skipped because managed configuration was detected: %s\n" "$reason"
  else
    printf "  release: %s (created or verified on --apply)\n" "$release"
  fi

  for task in "${AP_SETUP_TASKS[@]}"; do
    target="$(ap_setup_task_path "$config_dir" "$task")"
    if [[ $tasks_managed -eq 1 ]]; then
      if [[ -n "$prepare_dir" ]]; then
        printf "  task: %s/tasks/%s (prepared source change; target left untouched)\n" "$prepare_dir" "$task"
      else
        printf "  task: %s (skipped: managed configuration; rerun with --prepare-dir DIR)\n" "$target"
      fi
    elif ap_setup_inline_conflict "$config_dir" "$task"; then
      printf "  task: %s (conflict: inline global mise task left untouched)\n" "$target"
    elif [[ -e "$target" ]] && ! ap_setup_is_managed_task "$target"; then
      printf "  task: %s (conflict: foreign task file left untouched)\n" "$target"
    elif [[ ! -e "$target" ]] && ap_setup_listing_conflict "$config_dir" "$task"; then
      printf "  task: %s (conflict: global task from another source left untouched)\n" "$target"
    elif [[ -f "$target" ]] && ap_setup_is_managed_task "$target"; then
      printf "  task: %s (managed task refreshed on --apply)\n" "$target"
    else
      printf "  task: %s (written on --apply)\n" "$target"
    fi
  done

  if [[ -n "$prepare_dir" && ! -f "$prepare_dir/INSTRUCTIONS.md" ]]; then
    if [[ $tasks_managed -eq 1 ]] || ap_setup_config_file_managed_reason "$config_dir" >/dev/null; then
      printf "  prepared: %s/INSTRUCTIONS.md (source-change instructions written on --apply)\n" "$prepare_dir"
    fi
  fi

  if [[ "$tasks_only" -eq 1 ]]; then
    printf "  prerequisites: skipped (--tasks-only requested; no package manager or agent installation)\n"
  fi
  for dep in bash git python3 bwrap; do
    if [[ "$tasks_only" -eq 1 ]]; then
      break
    fi
    if ap_setup_resolve "$dep" >/dev/null 2>&1; then
      continue
    fi
    if [[ "$dep" == "mise" ]]; then
      printf "  prerequisite: mise (manual installation required; no curl)\n"
    elif ap_setup_package_command "$dep" >/dev/null 2>&1; then
      printf "  prerequisite: %s (install: %s)\n" "$dep" "$(ap_setup_package_command "$dep")"
    else
      printf "  prerequisite: %s (unsupported automatic path)\n" "$dep"
    fi
  done
  if ! ap_setup_resolve mise >/dev/null 2>&1; then
    printf "  prerequisite: mise (manual installation required; no curl)\n"
  fi

  for agent in "${requested_agents[@]:-}"; do
    [[ -n "$agent" ]] || continue
    if [[ "$tasks_only" -eq 1 ]]; then
      printf "  agent: %s (skipped: --tasks-only requested; no installation)\n" "$agent"
      continue
    fi
    if reason="$(ap_setup_config_file_managed_reason "$config_dir")"; then
      if [[ -n "$prepare_dir" ]]; then
        printf "  agent: %s (prepared source change in %s/mise/config.toml.fragment; target left untouched)\n" \
          "$agent" "$prepare_dir"
      else
        printf "  agent: %s (skipped: managed configuration; rerun with --prepare-dir DIR)\n" "$agent"
      fi
      continue
    fi
    if path="$(ap_setup_resolve "$agent")"; then
      printf "  agent: %s (already available at %s)\n" "$agent" "$path"
    elif ! ap_setup_mise_registry_has "$agent"; then
      printf "  agent: %s (unsupported automatic path: not in the mise registry)\n" "$agent"
    else
      printf "  agent: %s (install through the mise registry on --apply; global mise config backed up first)\n" \
        "$agent"
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

AP_SETUP_BACKUP_SEQ=0

ap_setup_backup_file() {
  local file="$1"
  local category="$2"
  local backup_root timestamp backup_dir
  backup_root="${XDG_STATE_HOME:-$HOME/.local/state}/flyingnobita-agent-profiles/backups"
  AP_SETUP_BACKUP_SEQ=$((AP_SETUP_BACKUP_SEQ + 1))
  timestamp="$(date -u +%Y%m%dT%H%M%SZ)-$$-$AP_SETUP_BACKUP_SEQ"
  backup_dir="$backup_root/$timestamp/$category"
  (umask 077 && mkdir -p "$backup_dir") || return 1
  cp -a "$file" "$backup_dir/"
  printf "%s\n" "$backup_dir/$(basename "$file")"
}

ap_setup_backup_task() {
  ap_setup_backup_file "$1" "tasks"
}

# Read-only detection of a global mise configuration file that belongs to a
# dotfiles repository or another manager. It must never be rewritten in place.
ap_setup_config_file_managed_reason() {
  local config_dir="$1"
  local config_file="$config_dir/config.toml"
  local dir_reason

  if dir_reason="$(ap_setup_config_dir_managed_reason "$config_dir")"; then
    printf "%s\n" "$dir_reason"
    return 0
  fi
  if [[ -d "$config_dir" && ! -w "$config_dir" ]]; then
    printf "global mise config directory '%s' is read-only\n" "$config_dir"
    return 0
  fi
  if [[ -L "$config_file" ]]; then
    printf "global mise config '%s' is a symlink\n" "$config_file"
    return 0
  fi
  if [[ -e "$config_file" && ! -w "$config_file" ]]; then
    printf "global mise config '%s' is read-only\n" "$config_file"
    return 0
  fi
  if [[ -e "$config_file" ]] && command -v chezmoi >/dev/null 2>&1 \
    && chezmoi source-path "$config_file" >/dev/null 2>&1; then
    printf "chezmoi manages the global mise config\n"
    return 0
  fi
  return 1
}

# Detects a global mise configuration directory that is itself a symlink or
# resolves through a symlinked parent, which indicates dotfiles management.
ap_setup_config_dir_managed_reason() {
  local config_dir="$1"
  local resolved_dir

  if [[ -L "$config_dir" ]]; then
    printf "global mise config directory '%s' is a symlink\n" "$config_dir"
    return 0
  fi
  resolved_dir=$(readlink -f "$config_dir" 2>/dev/null || true)
  if [[ -n "$resolved_dir" && "$resolved_dir" != "$config_dir" ]]; then
    printf "global mise config directory '%s' resolves through a symlinked parent\n" "$config_dir"
    return 0
  fi
  return 1
}

ap_setup_managed_config_reason() {
  local config_dir="$1"
  local tasks_dir="$config_dir/tasks"
  local task target
  local dir_reason

  if dir_reason="$(ap_setup_config_dir_managed_reason "$config_dir")"; then
    printf "%s\n" "$dir_reason"
    return 0
  fi
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

ap_setup_install_package() {
  local dep="$1"
  local package
  local -a cmd=()

  package="$(ap_setup_package_for "$dep")" || return 1
  case "$AP_SETUP_PKG_MANAGER" in
    pacman) cmd=(pacman -S --noconfirm "$package") ;;
    apt-get) cmd=(apt-get install -y "$package") ;;
    *) return 1 ;;
  esac

  if [[ "$(id -u)" -ne 0 ]]; then
    command -v sudo >/dev/null 2>&1 || return 1
    cmd=(sudo "${cmd[@]}")
  fi

  printf "install: %s\n" "${cmd[*]}"
  "${cmd[@]}"
}

ap_setup_install_prerequisites() {
  local dep
  if [[ "$tasks_only" -eq 1 ]]; then
    printf "  prerequisites: skipped (--tasks-only requested; no package manager or agent installation)\n"
  fi
  for dep in bash git python3 bwrap; do
    if [[ "$tasks_only" -eq 1 ]]; then
      break
    fi
    if ap_setup_resolve "$dep" >/dev/null 2>&1; then
      continue
    fi
    if ! ap_setup_install_package "$dep"; then
      printf "unsupported automatic path: dependency '%s' cannot be installed automatically\n" "$dep"
    fi
  done
  if ! ap_setup_resolve mise >/dev/null 2>&1; then
    printf "manual: mise must be installed manually (no curl installation)\n"
  fi
}

# Writes a prepared, additive source change for a managed global mise config.
# The target is never modified; the fragment keeps unrelated tools untouched.
ap_setup_prepare_agent_install() {
  local prepare_dir="$1"
  local config_file="$2"
  local reason="$3"
  local agent="$4"
  local fragment="$prepare_dir/mise/config.toml.fragment"

  (umask 022 && mkdir -p "$prepare_dir/mise") || return 1
  if [[ ! -f "$fragment" ]]; then
    {
      printf '# Add these entries under [tools] in your managed global mise configuration.\n'
      printf '# Other tools in that file are preserved; setup never edits it directly.\n'
    } >"$fragment"
  fi
  if ! grep -qF "$agent = \"latest\"" "$fragment"; then
    printf '%s = "latest"\n' "$agent" >>"$fragment"
  fi

  local instructions="$prepare_dir/INSTRUCTIONS.md"
  if [[ ! -f "$instructions" ]]; then
    {
      printf '# Prepared agent-profiles changes\n\n'
      printf 'Managed configuration was detected: %s\n\n' "$reason"
    } >"$instructions"
  fi
  if ! grep -qF "prepared/mise/config.toml.fragment" "$instructions"; then
    {
      printf '## Managed global mise configuration\n\n'
      printf 'Add the entries from %s/mise/config.toml.fragment under [tools] in\n' "$prepare_dir"
      printf '%s, keeping every unrelated tool, then commit it through your configuration manager.\n\n' "$config_file"
    } >>"$instructions"
  fi
  printf "prepared: %s\n" "$fragment"
}

# Installs requested agents only when they are missing, backing up the global
# mise configuration before any persistent write. A managed configuration is
# left untouched and the change is prepared for the user instead.
ap_setup_install_agents() {
  local prepare_dir="${1:-}"
  shift
  local agent path config_dir config_file reason backup
  local config_backed_up=0
  config_dir="$(ap_mise_config_dir)"
  config_file="$config_dir/config.toml"

  for agent in "$@"; do
    [[ -n "$agent" ]] || continue
    if path="$(ap_setup_resolve "$agent")"; then
      printf "agent: %s already available at %s\n" "$agent" "$path"
      continue
    fi
    if ! ap_setup_mise_registry_has "$agent"; then
      printf "unsupported automatic path: agent '%s' is not in the mise registry\n" "$agent"
      continue
    fi
    if reason="$(ap_setup_config_file_managed_reason "$config_dir")"; then
      printf "managed configuration detected: %s\n" "$reason"
      printf "agent: %s was not installed; add '%s@latest' to your managed mise configuration and rerun setup\n" \
        "$agent" "$agent"
      if [[ -n "$prepare_dir" ]]; then
        ap_setup_prepare_agent_install "$prepare_dir" "$config_file" "$reason" "$agent"
      fi
      continue
    fi
    if [[ -f "$config_file" && $config_backed_up -eq 0 ]]; then
      if ! backup="$(ap_setup_backup_file "$config_file" mise)"; then
        ap_die "$EX_BROKEN" "failed to back up the global mise config: $config_file"
      fi
      config_backed_up=1
      printf "backup: %s\n" "$backup"
    fi
    printf "install: mise use --global %s@latest (global mise config backed up first)\n" "$agent"
    if ! mise use --global "$agent@latest"; then
      ap_die "$EX_BROKEN" "failed to install agent '$agent' through the mise registry"
    fi
  done
}

# Apply the machine setup: deploy the release and install both global task
# files, preserving foreign tasks and backing up managed files before changes.
ap_setup_apply_tasks() {
  local prepare_dir="${1:-}"
  local tasks_only="${2:-0}"
  local -a requested_agents=("${@:3}")
  local config_dir reason managed=0
  config_dir="$(ap_mise_config_dir)"

  if ! command -v mise >/dev/null 2>&1 && [[ -z "${MISE_CONFIG_DIR:-}" ]]; then
    ap_die "$EX_UNAVAILABLE" "mise is required for global task integration; install mise manually (no curl installation)"
  fi

  if reason="$(ap_setup_managed_config_reason "$config_dir")"; then
    managed=1
    ap_setup_prepare_managed "$config_dir" "$reason" "$prepare_dir" \
      || ap_die "$EX_BROKEN" "failed to prepare managed configuration files"
  fi

  if [[ $managed -eq 0 ]] && ! ap_setup_deploy_release >/dev/null; then
    ap_die "$EX_BROKEN" "failed to deploy the versioned helper release"
  fi

  local task target content conflicts=0 backup
  if [[ $managed -eq 0 ]]; then
    (umask 022 && mkdir -p "$config_dir/tasks")
  fi
  for task in "${AP_SETUP_TASKS[@]}"; do
    [[ $managed -eq 0 ]] || break
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

    if [[ -f "$target" && "$(cat "$target")" == "$content" ]]; then
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

  if [[ "$tasks_only" -eq 0 ]]; then
    ap_setup_install_prerequisites
    ap_setup_install_agents "$prepare_dir" "${requested_agents[@]}"
  fi

  printf "\nApplied:\n"
  if [[ $managed -eq 0 ]]; then
    printf "  release: %s\n" "$AP_SETUP_RELEASE_DIR"
  fi
  for task in "${AP_SETUP_TASKS[@]}"; do
    printf "  task: %s\n" "$(ap_setup_task_path "$config_dir" "$task")"
  done
  if [[ $conflicts -gt 0 ]]; then
    printf "  conflicts: %s (existing tasks preserved)\n" "$conflicts"
  fi
}
