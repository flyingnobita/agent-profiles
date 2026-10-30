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

# hash_tree <dir>: stable content hash of every file under <dir>, so a test can
# prove a synthetic host tree is byte-identical before and after a profile run.
hash_tree() {
  python3 - "$1" <<'PY'
import hashlib
import os
import sys

root = sys.argv[1]
for dirpath, dirnames, filenames in os.walk(root):
    dirnames.sort()
    for name in sorted(filenames):
        path = os.path.join(dirpath, name)
        with open(path, "rb") as handle:
            digest = hashlib.sha256(handle.read()).hexdigest()
        print(digest, os.path.relpath(path, root))
PY
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
  # survive into the Darwin child. Stale profile identity markers are behaviour
  # 14's case, because a wrong live identity is refused instead of reset.
  run env PATH="$NO_BWRAP_BIN" AP_TEST_PLATFORM_OS=Darwin \
    HOME="$stale/home" \
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

@test "darwin run: HOME-relative Claude Codex Gemini and agents writes land in selected profile" {
  local repo="$TEST_TMPDIR/repo-darwin-writes"
  create_fixture_repo "$repo"
  cd "$repo"
  run bash "$AP_HELPER" init
  assert_success

  local prof_dir="$repo/.agent-profiles/default"
  local d
  for d in .claude .codex .gemini .agents; do
    mkdir -p "$HOME/$d"
    printf "host-canary-%s\n" "$d" >"$HOME/$d/canary.txt"
  done
  local host_before
  host_before=$(hash_tree "$HOME")

  run env PATH="$NO_BWRAP_BIN" AP_TEST_PLATFORM_OS=Darwin bash "$AP_HELPER" run -- sh -c '
    printf "claude\n" >"$HOME/.claude/marker.txt"
    printf "codex\n" >"$HOME/.codex/marker.txt"
    printf "gemini\n" >"$HOME/.gemini/marker.txt"
    printf "agents\n" >"$HOME/.agents/marker.txt"
  '
  assert_success

  local name
  for d in .claude .codex .gemini .agents; do
    name="${d#.}"
    assert_file_exists "$prof_dir/$d/marker.txt"
    assert_equal "$(cat "$prof_dir/$d/marker.txt")" "$name"
    [[ ! -e "$HOME/$d/marker.txt" ]]
  done

  # The synthetic host tree is byte-identical: no HOME-relative write reached it.
  assert_equal "$(hash_tree "$HOME")" "$host_before"

  # home/ is still only the initialization marker, not the Darwin HOME.
  assert_dir_exists "$prof_dir/home"
  [[ ! -e "$prof_dir/home/.claude" ]]
}
@test "darwin run: two profiles keep home-relative writes and PATH entries separate" {
  local repo="$TEST_TMPDIR/repo-darwin-two-profiles"
  create_fixture_repo "$repo"
  cd "$repo"
  run bash "$AP_HELPER" init --profile prof-a
  assert_success
  run bash "$AP_HELPER" init --profile prof-b
  assert_success

  local prof_a="$repo/.agent-profiles/prof-a"
  local prof_b="$repo/.agent-profiles/prof-b"

  local d
  for d in .claude .codex .gemini .agents; do
    mkdir -p "$HOME/$d"
    printf "host-canary-%s\n" "$d" >"$HOME/$d/canary.txt"
  done
  local host_before
  host_before=$(hash_tree "$HOME")

  run env PATH="$NO_BWRAP_BIN" AP_TEST_PLATFORM_OS=Darwin bash "$AP_HELPER" run --profile prof-a -- python3 -c '
import os
import sys

prof = sys.argv[1]
with open(os.path.join(prof, ".claude", "a.txt"), "w") as handle:
    handle.write("A\n")
assert os.environ["HOME"] == prof
print("PROFILE_A_OK")
' "$prof_a"
  assert_success
  assert_output_contains "PROFILE_A_OK"

  # Profile B starts with a PATH that still names profile A's bin directories.
  run env PATH="$prof_a/npm-global/bin:$prof_a/bin:$NO_BWRAP_BIN" AP_TEST_PLATFORM_OS=Darwin \
    bash "$AP_HELPER" run --profile prof-b -- python3 -c '
import os
import sys

prof = sys.argv[1]
other = sys.argv[2]
assert os.environ["HOME"] == prof, os.environ["HOME"]
assert os.environ["AGENT_PROFILES_NAME"] == "prof-b"
path = os.environ["PATH"].split(":")
assert not any(os.path.join(other, sub) in path for sub in ("bin", "npm-global/bin")), path
with open(os.path.join(prof, ".agents", "b.txt"), "w") as handle:
    handle.write("B\n")
print("PROFILE_B_OK")
' "$prof_b" "$prof_a"
  assert_success
  assert_output_contains "PROFILE_B_OK"

  # Writes never cross profiles.
  assert_equal "$(cat "$prof_a/.claude/a.txt")" "A"
  assert_equal "$(cat "$prof_b/.agents/b.txt")" "B"
  [[ ! -e "$prof_a/.agents/b.txt" ]]
  [[ ! -e "$prof_b/.claude/a.txt" ]]

  # The synthetic host tree is still byte-identical.
  assert_equal "$(hash_tree "$HOME")" "$host_before"
}
@test "darwin run: same-profile nesting dedupes PATH and different profile or checkout exits 75" {
  local repo="$TEST_TMPDIR/repo-darwin-nested"
  local repo_b="$TEST_TMPDIR/repo-darwin-nested-b"
  create_fixture_repo "$repo"
  create_fixture_repo "$repo_b"
  cd "$repo"
  run bash "$AP_HELPER" init --profile nest
  assert_success
  run bash "$AP_HELPER" init --profile other
  assert_success
  cd "$repo_b"
  run bash "$AP_HELPER" init --profile nest
  assert_success
  cd "$repo"

  local prof_dir="$repo/.agent-profiles/nest"

  # Darwin has no mount table to inspect, so nesting identity comes from the
  # validated active profile/root/checkout environment the outer run exported.
  run env PATH="$NO_BWRAP_BIN" AP_TEST_PLATFORM_OS=Darwin \
    bash "$AP_HELPER" run --profile nest -- \
    bash "$AP_HELPER" run --profile nest -- python3 -c '
import os
import sys

prof = sys.argv[1]
assert os.environ["HOME"] == prof
assert os.environ["AGENT_PROFILES_NAME"] == "nest"
path = os.environ["PATH"].split(":")
for sub in ("bin", "npm-global/bin", "cargo-global/bin", "python-user/bin"):
    entry = os.path.join(prof, sub)
    assert path.count(entry) == 1, f"{entry} appears {path.count(entry)} times: {path}"
print("NESTED_SAME_OK")
' "$prof_dir"
  assert_success
  assert_output_contains "NESTED_SAME_OK"

  run env PATH="$NO_BWRAP_BIN" AP_TEST_PLATFORM_OS=Darwin \
    bash "$AP_HELPER" run --profile nest -- \
    bash "$AP_HELPER" run --profile other -- echo should_not_run
  assert_failure
  assert_equal "$status" 75
  assert_output_contains "nested execution"
  assert_output_not_contains "should_not_run"

  run env PATH="$NO_BWRAP_BIN" AP_TEST_PLATFORM_OS=Darwin \
    bash "$AP_HELPER" run --profile nest -- \
    sh -c 'cd "$1" && bash "$2" run --profile nest -- echo should_not_run' _ "$repo_b" "$AP_HELPER"
  assert_failure
  assert_equal "$status" 75
  assert_output_contains "nested execution"
  assert_output_not_contains "should_not_run"
}
@test "darwin run: spurious inherited profile markers without an active session are reset" {
  local repo="$TEST_TMPDIR/repo-darwin-spurious"
  create_fixture_repo "$repo"
  cd "$repo"
  run bash "$AP_HELPER" init --profile target
  assert_success

  local prof_dir="$repo/.agent-profiles/target"
  local storage_dir="$repo/.agent-profiles"
  local spurious="$TEST_TMPDIR/spurious"

  # Without the explicit active-session marker the inherited identity is stale
  # bookkeeping from an earlier environment, not a live nested session, so the
  # run proceeds with a freshly exported identity.
  run env PATH="$NO_BWRAP_BIN" AP_TEST_PLATFORM_OS=Darwin \
    AGENT_PROFILES_NAME="spurious" \
    AGENT_PROFILES_DIR="$spurious/profile" \
    AGENT_PROFILES_ROOT="$spurious/storage" \
    AGENT_SANDBOX_DIR="$spurious/sandbox" \
    AGENT_SANDBOX_PROFILE="spurious" \
    bash "$AP_HELPER" run --profile target -- python3 -c '
import os
import sys

prof = sys.argv[1]
storage = sys.argv[2]
spurious = sys.argv[3]
assert os.environ["AGENT_PROFILES_NAME"] == "target"
assert os.environ["AGENT_PROFILES_DIR"] == prof
assert os.environ["AGENT_PROFILES_ROOT"] == storage
assert os.environ["AGENT_PROFILES_SESSION"] == "target"
assert os.environ["AGENT_SANDBOX_PROFILE"] == "target"
for name in ("AGENT_PROFILES_DIR", "AGENT_PROFILES_ROOT", "AGENT_SANDBOX_DIR"):
    assert not os.environ[name].startswith(spurious), (name, os.environ[name])
print("STALE_MARKERS_RESET_OK")
' "$prof_dir" "$storage_dir" "$spurious"
  assert_success
  assert_output_contains "STALE_MARKERS_RESET_OK"

  # A marker that names a different identity is a live mismatch, not staleness.
  run env PATH="$NO_BWRAP_BIN" AP_TEST_PLATFORM_OS=Darwin \
    AGENT_PROFILES_SESSION="spurious" \
    AGENT_PROFILES_NAME="spurious" \
    AGENT_PROFILES_DIR="$spurious/profile" \
    AGENT_PROFILES_ROOT="$spurious/storage" \
    bash "$AP_HELPER" run --profile target -- echo should_not_run
  assert_failure
  assert_equal "$status" 75
  assert_output_contains "nested execution"
  assert_output_not_contains "should_not_run"

  # The marker is workflow bookkeeping, never unforgeable evidence: a caller
  # that fabricates every matching value is treated as a live nested session.
  # A nested session takes the same-profile path and records no new run line.
  run env PATH="$NO_BWRAP_BIN" AP_TEST_PLATFORM_OS=Darwin bash "$AP_HELPER" run --profile target -- true
  assert_success
  local runs_file="$repo/.agent-profiles/.locks/target.runs"
  local records_before
  records_before=$(grep -c '' "$runs_file")

  run env PATH="$NO_BWRAP_BIN" AP_TEST_PLATFORM_OS=Darwin \
    AGENT_PROFILES_SESSION="target" \
    AGENT_PROFILES_NAME="target" \
    AGENT_PROFILES_DIR="$prof_dir" \
    AGENT_PROFILES_ROOT="$storage_dir" \
    bash "$AP_HELPER" run --profile target -- sh -c 'printf "forged_nested\n"'
  assert_success
  assert_output_contains "forged_nested"
  assert_equal "$(grep -c '' "$runs_file")" "$records_before"
}
