#!/usr/bin/env bats
# Darwin execution adapter: profile HOME, agent/XDG/tool environment, no
# bubblewrap and no host mountpoints, nesting identity and command lifetime.
#
# A Linux host cannot run Darwin, so these tests select the platform probe
# through the internal AP_TEST_PLATFORM_OS seam (see platform.sh). The seam is
# honoured only inside the test suite, is not a user-facing option and is not a
# documented supported variable. A green run of this file on Linux therefore
# proves branch selection and the environment contract only; it is never
# evidence of stock macOS bash 3.2, BSD userland, the Darwin kernel or real
# agent behavior. That evidence belongs to the macOS job and the MBP-M4 run.
# shellcheck disable=SC2030,SC2031

setup_file() {
  # Every Darwin invocation in this file runs with a PATH that contains every
  # host command except bwrap, so a green test proves Darwin execution never
  # needs, probes or falls back to bubblewrap.
  NO_BWRAP_BIN="$BATS_FILE_TMPDIR/no-bwrap-bin"
  mkdir -p "$NO_BWRAP_BIN"

  local dir tool name
  local old_ifs="$IFS"
  IFS=':'
  for dir in $PATH; do
    IFS="$old_ifs"
    [[ -d "$dir" ]] || continue
    for tool in "$dir"/*; do
      [[ -x "$tool" && ! -d "$tool" ]] || continue
      name="$(basename "$tool")"
      [[ "$name" == "bwrap" ]] && continue
      [[ -e "$NO_BWRAP_BIN/$name" ]] && continue
      ln -s "$tool" "$NO_BWRAP_BIN/$name" 2>/dev/null || true
    done
  done
  IFS="$old_ifs"

  export NO_BWRAP_BIN
}

setup() {
  load '../helpers/common.bash'
  load '../helpers/assert.bash'
  load '../helpers/fixtures.bash'
  load '../helpers/isolation.bash'
  setup_isolation
}

teardown() {
  teardown_isolation
}

@test "darwin run: executes without bwrap and never creates host mountpoints" {
  local repo="$TEST_TMPDIR/repo-darwin-no-bwrap"
  create_fixture_repo "$repo"
  cd "$repo"
  run bash "$AP_HELPER" init
  assert_success

  # Synthetic host configuration directories the Linux adapter would mount over.
  local d
  for d in .claude .codex .gemini .agents; do
    [[ ! -e "$HOME/$d" ]] || {
      echo "host directory already exists: $HOME/$d" >&2
      false
    }
  done

  run env PATH="$NO_BWRAP_BIN" AP_TEST_PLATFORM_OS=Darwin \
    bash "$AP_HELPER" run -- sh -c 'printf "darwin_child_ran\n"'
  assert_success
  assert_output_contains "darwin_child_ran"
  assert_output_not_contains "created empty host mountpoint"

  # bwrap is genuinely unavailable in the PATH used above, so the successful
  # run cannot have gone through bubblewrap.
  run env PATH="$NO_BWRAP_BIN" bash -c 'command -v bwrap'
  assert_failure

  for d in .claude .codex .gemini .agents; do
    [[ ! -e "$HOME/$d" ]] || {
      echo "host mountpoint created: $HOME/$d" >&2
      false
    }
  done

  # The seam is test-only: with the Bats marker removed the real platform
  # decides, so this Linux host keeps its bubblewrap refusal instead of
  # following the override.
  if [[ "$(uname -s)" == "Linux" ]]; then
    run env PATH="$NO_BWRAP_BIN" AP_TEST_PLATFORM_OS=Darwin BATS_TEST_FILENAME= \
      bash "$AP_HELPER" run -- echo ok
    assert_failure
    assert_equal "$status" 69
    assert_output_contains "bubblewrap"
  fi
}

@test "darwin run: exports profile HOME and all config and package roots without inherited values" {
  local repo="$TEST_TMPDIR/repo-darwin-env"
  create_fixture_repo "$repo"
  cd "$repo"
  run bash "$AP_HELPER" init --profile darwin-env
  assert_success

  local prof_dir="$repo/.agent-profiles/darwin-env"
  local storage_dir="$repo/.agent-profiles"
  local stale="$TEST_TMPDIR/stale"

  # Every managed variable arrives with a stale inherited value that must not
  # survive into the Darwin child.
  run env PATH="$NO_BWRAP_BIN" AP_TEST_PLATFORM_OS=Darwin \
    HOME="$stale/home" \
    AGENT_PROFILES_NAME="stale" \
    AGENT_PROFILES_DIR="$stale/profile" \
    AGENT_PROFILES_ROOT="$stale/storage" \
    AGENT_PROFILES_SESSION="stale" \
    AGENT_PROFILES_BASE_PATH="$stale/base" \
    AGENT_SANDBOX_DIR="$stale/sandbox" \
    AGENT_SANDBOX_PROFILE="stale" \
    XDG_CONFIG_HOME="$stale/config" \
    XDG_DATA_HOME="$stale/data" \
    XDG_STATE_HOME="$stale/state" \
    XDG_CACHE_HOME="$stale/cache" \
    NPM_CONFIG_PREFIX="$stale/npm" \
    NPM_CONFIG_CACHE="$stale/npm-cache" \
    UV_TOOL_DIR="$stale/uv" \
    UV_TOOL_BIN_DIR="$stale/uv-bin" \
    UV_CACHE_DIR="$stale/uv-cache" \
    CARGO_INSTALL_ROOT="$stale/cargo" \
    GOBIN="$stale/gobin" \
    PYTHONUSERBASE="$stale/python" \
    CLAUDE_CONFIG_DIR="$stale/claude" \
    CLAUDE_SECURESTORAGE_CONFIG_DIR="$stale/securestorage" \
    CODEX_HOME="$stale/codex" \
    OPENCODE_CONFIG_DIR="$stale/opencode" \
    MISE_DATA_DIR="$TEST_TMPDIR/mise/data" \
    MISE_CONFIG_DIR="$TEST_TMPDIR/mise/config" \
    MISE_STATE_DIR="$TEST_TMPDIR/mise/state" \
    MISE_CACHE_DIR="$TEST_TMPDIR/mise/cache" \
    bash "$AP_HELPER" run --profile darwin-env -- python3 -c '
import os
import sys

prof = sys.argv[1]
storage = sys.argv[2]

def want(name, expected):
    actual = os.environ.get(name)
    assert actual == expected, f"{name}: expected {expected!r}, got {actual!r}"

# HOME is the profile root itself, never the profile home/ initialization marker.
want("HOME", prof)
assert os.environ["HOME"] != os.path.join(prof, "home")

want("AGENT_PROFILES_NAME", "darwin-env")
want("AGENT_PROFILES_DIR", prof)
want("AGENT_PROFILES_ROOT", storage)
want("AGENT_PROFILES_SESSION", "darwin-env")
want("AGENT_SANDBOX_PROFILE", "darwin-env")
want("AGENT_SANDBOX_DIR", prof)

want("XDG_CONFIG_HOME", os.path.join(prof, ".config"))
want("XDG_DATA_HOME", os.path.join(prof, ".local/share"))
want("XDG_STATE_HOME", os.path.join(prof, ".local/state"))
want("XDG_CACHE_HOME", os.path.join(prof, ".cache"))

want("NPM_CONFIG_PREFIX", os.path.join(prof, "npm-global"))
want("NPM_CONFIG_CACHE", os.path.join(prof, ".cache/npm"))
want("UV_TOOL_DIR", os.path.join(prof, "uv-tools"))
want("UV_TOOL_BIN_DIR", os.path.join(prof, "bin"))
want("UV_CACHE_DIR", os.path.join(prof, ".cache/uv"))
want("CARGO_INSTALL_ROOT", os.path.join(prof, "cargo-global"))
want("GOBIN", os.path.join(prof, "bin"))
want("PYTHONUSERBASE", os.path.join(prof, "python-user"))

want("CLAUDE_CONFIG_DIR", os.path.join(prof, ".claude"))
want("CODEX_HOME", os.path.join(prof, ".codex"))
want("OPENCODE_CONFIG_DIR", os.path.join(prof, ".opencode"))
assert "CLAUDE_SECURESTORAGE_CONFIG_DIR" not in os.environ

leading = [
    os.path.join(prof, "npm-global/bin"),
    os.path.join(prof, "bin"),
    os.path.join(prof, "cargo-global/bin"),
    os.path.join(prof, "python-user/bin"),
]
path = os.environ["PATH"].split(":")
assert path[:4] == leading, path[:4]
assert path.count(os.path.join(prof, "bin")) == 1, path

base = os.environ["AGENT_PROFILES_BASE_PATH"]
assert "/.agent-profiles/" not in base, base
assert path[4:] == base.split(":"), (path[4:], base)

# No stale inherited value survives in any managed variable.
for name in (
    "HOME", "AGENT_PROFILES_NAME", "AGENT_PROFILES_DIR", "AGENT_PROFILES_ROOT",
    "AGENT_PROFILES_SESSION", "AGENT_PROFILES_BASE_PATH", "AGENT_SANDBOX_DIR",
    "AGENT_SANDBOX_PROFILE", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME",
    "XDG_CACHE_HOME", "NPM_CONFIG_PREFIX", "NPM_CONFIG_CACHE", "UV_TOOL_DIR",
    "UV_TOOL_BIN_DIR", "UV_CACHE_DIR", "CARGO_INSTALL_ROOT", "GOBIN",
    "PYTHONUSERBASE", "CLAUDE_CONFIG_DIR", "CODEX_HOME", "OPENCODE_CONFIG_DIR",
):
    value = os.environ.get(name, "")
    assert "stale" not in value, f"{name} kept a stale value: {value!r}"

print("DARWIN_ENV_OK")
' "$prof_dir" "$storage_dir"
  assert_success
  assert_output_contains "DARWIN_ENV_OK"
}
