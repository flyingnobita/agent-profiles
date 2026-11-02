#!/usr/bin/env bats
# Portability kernel: the helper is exercised through its public CLI with the
# GNU-only tools a stock macOS host does not ship masked out of PATH. A masked
# command reproduces the BSD/macOS behaviour: it rejects the GNU-only flag (or
# is absent altogether) instead of returning a useful answer.
# shellcheck disable=SC2030,SC2031

setup() {
  load '../helpers/common.bash'
  load '../helpers/assert.bash'
  load '../helpers/fixtures.bash'
  load '../helpers/isolation.bash'
  load '../helpers/platform.bash'
  setup_isolation
  AP_HOST_PATH="$PATH"
}

teardown() {
  # The lease holders below are long-lived by design. An assertion failure, an
  # interrupted test or a readiness timeout must still leave nothing behind.
  ap_test_teardown_owned
  teardown_isolation
}

# mask_command <dir> <name>: the command is not available at all, so a test can
# prove the helper no longer depends on it.
mask_command() {
  local dir="$1"
  local name="$2"
  mkdir -p "$dir"
  cat >"$dir/$name" <<SHIM
#!/usr/bin/env bash
printf 'portability: %s is masked in this test\n' "$name" >&2
exit 127
SHIM
  chmod +x "$dir/$name"
}

# shim_delegate <name>: the command the caller's PATH resolves right now, before
# a shim directory is prepended. A host may keep a tool outside /usr/bin (macOS
# ships cp in /bin), so a shim must never hardcode a path prefix.
shim_delegate() {
  local name="$1"
  local real
  real=$(command -v "$name" || true)
  if [[ -z "$real" ]]; then
    printf 'shim_delegate: %s is not on PATH\n' "$name" >&2
    return 1
  fi
  printf '%s\n' "$real"
}

# reject_gnu_options <dir> <name>: the command exists but rejects an option
# argument, which is how BSD/macOS userland answers a GNU-only flag.
reject_gnu_options() {
  local dir="$1"
  local name="$2"
  local real
  real=$(shim_delegate "$name") || return 1
  mkdir -p "$dir"
  cat >"$dir/$name" <<SHIM
#!/usr/bin/env bash
case "\${1:-}" in
  -*) printf '${name}: illegal option -- %s\\n' "\${1#-}" >&2; exit 1 ;;
esac
exec "$real" "\$@"
SHIM
  chmod +x "$dir/$name"
}

# reject_gnu_long_option <dir> <name> <option>: only that exact long option is
# rejected, so the rest of the BSD tool's behaviour is preserved.
reject_gnu_long_option() {
  local dir="$1"
  local name="$2"
  local option="$3"
  local real
  real=$(shim_delegate "$name") || return 1
  mkdir -p "$dir"
  cat >"$dir/$name" <<SHIM
#!/usr/bin/env bash
for arg in "\$@"; do
  if [[ "\$arg" == "$option" ]]; then
    printf '${name}: illegal option -- %s\\n' "\$arg" >&2
    exit 1
  fi
done
exec "$real" "\$@"
SHIM
  chmod +x "$dir/$name"
}

@test "portability: helper resolves its installed path without GNU readlink" {
  local repo="$TEST_TMPDIR/repo-readlink"
  create_fixture_repo "$repo"

  # An installed skill lives in its own directory; the two supported
  # installation modes either link to the entrypoint or run it in place.
  local skill="$TEST_TMPDIR/installed-skill"
  mkdir -p "$skill"
  cp -a "$AP_SKILL_DIR/." "$skill/"
  local linked="$TEST_TMPDIR/bin/agent-profiles"
  mkdir -p "$TEST_TMPDIR/bin"
  ln -s "$skill/scripts/agent-profiles" "$linked"

  local shim="$TEST_TMPDIR/bsd-bin"
  reject_gnu_options "$shim" readlink
  export PATH="$shim:$AP_HOST_PATH"

  cd "$repo"

  run bash "$linked" --version
  assert_success
  [[ "$output" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]

  # The skill must also be usable from its real path, not only through a link.
  run bash "$skill/scripts/agent-profiles" --version
  assert_success

  run bash "$linked" init --profile bounded
  assert_success
  assert_dir_exists "$repo/.agent-profiles/bounded/home"
  assert_file_exists "$repo/.agent-profiles/bounded/.agent-profile"

  run bash "$linked" list
  assert_success
  assert_output_contains "bounded"
}

@test "portability: profile init and sorted list work without mapfile or GNU stat" {
  local repo="$TEST_TMPDIR/repo-stat"
  create_fixture_repo "$repo"
  cd "$repo"

  # BSD/macOS stat has no -c format option, so every GNU format string must go.
  local shim="$TEST_TMPDIR/bsd-bin"
  reject_gnu_options "$shim" stat
  export PATH="$shim:$AP_HOST_PATH"

  run bash "$AP_HELPER" init --profile zulu
  assert_success
  run bash "$AP_HELPER" init --profile alpha
  assert_success
  run bash "$AP_HELPER" init --profile mike
  assert_success

  run bash "$AP_HELPER" list
  assert_success
  assert_output_equals "$(printf '%s\n' alpha mike zulu)"

  # Profile identity is still enforced. A second path that resolves to an
  # existing profile is an inode alias: it must be refused, never skipped
  # because an empty stat result looked like "no alias found".
  ln -s "$repo/.agent-profiles/zulu" "$repo/.agent-profiles/alias-zulu"

  run bash "$AP_HELPER" init --profile zulu
  assert_failure 73
  assert_output_contains "aliases existing profile"
}

@test "portability: canonical path checks resolve existing and missing symlink ancestors" {
  local shim="$TEST_TMPDIR/bsd-bin"
  reject_gnu_options "$shim" realpath
  export PATH="$shim:$AP_HOST_PATH"

  # Storage and the not-yet-created host mount targets are canonicalized before
  # the profile runs.
  local repo_run="$TEST_TMPDIR/repo-realpath-run"
  create_fixture_repo "$repo_run"
  cd "$repo_run"
  run bash "$AP_HELPER" init --profile default
  assert_success
  run bash "$AP_HELPER" run -- true
  assert_success

  # A backup root whose tail does not exist yet is resolved through its real
  # ancestors and created outside the checkout.
  local repo_migrate="$TEST_TMPDIR/repo-realpath-migrate"
  create_fixture_repo "$repo_migrate"
  cd "$repo_migrate"
  mkdir -p "$repo_migrate/.agent-sandbox/home"
  printf 'legacy\n' >"$repo_migrate/.agent-sandbox/home/legacy.txt"

  local backups="$TEST_TMPDIR/backups/nested/deep"
  run bash "$AP_HELPER" migrate --yes --backup-root "$backups"
  assert_success
  assert_output_contains "Migration completed successfully"

  local run_dir
  run_dir=$(find "$backups" -mindepth 1 -maxdepth 1 -type d | head -n 1)
  [[ -n "$run_dir" ]]
  assert_file_exists "$run_dir/legacy/agent-sandbox/home/legacy.txt"

  # An existing symlink ancestor that resolves inside the checkout must be
  # refused even though the backup path itself does not exist.
  local repo_link="$TEST_TMPDIR/repo-realpath-link"
  create_fixture_repo "$repo_link"
  cd "$repo_link"
  mkdir -p "$repo_link/.agent-sandbox/home"
  printf 'legacy\n' >"$repo_link/.agent-sandbox/home/legacy.txt"
  ln -s "$repo_link" "$TEST_TMPDIR/repo-link"

  run bash "$AP_HELPER" migrate --backup-root "$TEST_TMPDIR/repo-link/backups"
  assert_failure 73
  assert_output_contains "inside the git checkout"
}

@test "portability: shared and exclusive locks retain contention and descendant leases without flock or dynamic descriptors" {
  local repo="$TEST_TMPDIR/repo-locks"
  create_fixture_repo "$repo"
  cd "$repo"

  local shim="$TEST_TMPDIR/no-flock-bin"
  mask_command "$shim" flock
  export PATH="$shim:$AP_HOST_PATH"

  run bash "$AP_HELPER" init --profile default
  assert_success

  local lock_file="$repo/.agent-profiles/.locks/default.lock"
  assert_file_exists "$lock_file"
  local lock_inode_before
  lock_inode_before=$(python3 -c 'import os, sys; print(os.stat(sys.argv[1]).st_ino)' "$lock_file")

  local lease_dir="$TEST_TMPDIR/lease-fixtures"
  local holder_script
  holder_script=$(ap_test_lease_holder_script "$lease_dir")

  # Two shared leases are compatible: a run starts while the first holds the
  # lease. Readiness is the holder's own start plus a refused exclusive probe,
  # never a fixed sleep: `run` needs well over 0.6 s to reach the lease on a
  # loaded or slow host, and the hosted macOS runner proved it.
  local first_marker="$TEST_TMPDIR/first-started"
  local first_release="$TEST_TMPDIR/first-release"
  ap_test_start_lease_holder "$AP_HELPER" default "$holder_script" \
    "$first_marker" "$first_release" "$TEST_TMPDIR/first-holder.log"
  local first=$AP_TEST_LEASE_PID
  run bash "$AP_HELPER" run -- true
  assert_success
  ap_test_release_lease_holder "$first_release" "$first" "$lock_file"

  # An exclusive lifecycle lock is refused while a shared lease is held.
  local holder_marker="$TEST_TMPDIR/holder-started"
  local holder_release="$TEST_TMPDIR/holder-release"
  ap_test_start_lease_holder "$AP_HELPER" default "$holder_script" \
    "$holder_marker" "$holder_release" "$TEST_TMPDIR/holder.log"
  local holder=$AP_TEST_LEASE_PID
  run bash "$AP_HELPER" reset --profile default --yes
  assert_failure 75
  assert_output_contains "in use"
  ap_test_release_lease_holder "$holder_release" "$holder" "$lock_file"

  # A background descendant keeps the inherited lease after the direct parent
  # exits, and the persistent lock inode is never replaced. The descendant is
  # registered by the fixture helper, so teardown covers it from here on.
  local pid_file="$TEST_TMPDIR/lease-child.pid"
  local child_marker="$TEST_TMPDIR/child-started"
  local child_release="$TEST_TMPDIR/child-release"
  ap_test_start_lease_descendant "$AP_HELPER" default "$holder_script" \
    "$child_marker" "$child_release" "$pid_file" "$TEST_TMPDIR/descendant.log"
  local child
  child=$(cat "$pid_file")
  [[ -n "$child" ]]

  local lock_inode_after
  lock_inode_after=$(python3 -c 'import os, sys; print(os.stat(sys.argv[1]).st_ino)' "$lock_file")
  assert_equal "$lock_inode_after" "$lock_inode_before"

  run bash "$AP_HELPER" reset --profile default --yes
  assert_failure 75
  assert_output_contains "in use"

  ap_test_stop_owned_pid "$child"
  ap_test_wait_pid_gone "$child"
  ap_test_lease_wait_free "$lock_file"

  run bash "$AP_HELPER" reset --profile default --yes
  assert_success
}

# Guard (approved plan, slice 1 test 5): the Linux runner ships bash 5, so this
# passes here and on the base commit; it is red on stock macOS /bin/bash 3.2,
# where mapfile -d '' does not exist. It pins the NUL-delimited journal field
# parsing that replaces it.
@test "portability: NUL-delimited journal fields survive Bash 3.2 recovery parsing" {
  local repo="$TEST_TMPDIR/repo with spaces"
  repo="$repo"$'\n'"and a newline"
  create_fixture_repo "$repo"
  cd "$repo"

  run bash "$AP_HELPER" init --profile default
  assert_success
  printf 'keep me\n' >"$repo/.agent-profiles/default/home/marker.txt"

  local journal="$repo/.agent-profiles/.journal/reset-default.json"

  # Crash after the profile was moved into trash: the recorded state carries
  # paths that contain a space and a newline.
  run env AP_FAULT_AFTER=trashed bash "$AP_HELPER" reset --profile default --yes
  assert_failure
  assert_file_exists "$journal"

  local trash_path
  trash_path=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["trash_path"])' "$journal")
  [[ -n "$trash_path" ]]
  assert_file_exists "$trash_path/home/marker.txt"

  run bash "$AP_HELPER" recover --yes
  assert_success
  assert_output_contains "Recovered interrupted 'reset' operation for profile 'default'"

  [[ ! -e "$journal" ]]
  [[ ! -e "$trash_path" ]]
  assert_dir_exists "$repo/.agent-profiles/default/home"
  [[ ! -e "$repo/.agent-profiles/default/home/marker.txt" ]]

  run bash "$AP_HELPER" run --profile default -- true
  assert_success
}

@test "portability: setup manifests and release checksums verify without sha256sum" {
  local repo="$TEST_TMPDIR/repo-hash"
  create_fixture_repo "$repo"
  cd "$repo"

  # Only the released toolchain is available: no GNU coreutils hashing.
  local shim="$TEST_TMPDIR/no-sha-bin"
  mask_command "$shim" sha256sum
  export PATH="$shim:$AP_HOST_PATH"

  export MISE_CONFIG_DIR="$TEST_TMPDIR/mise/config"
  export MISE_DATA_DIR="$TEST_TMPDIR/mise/data"
  export MISE_STATE_DIR="$TEST_TMPDIR/mise/state"
  export MISE_CACHE_DIR="$TEST_TMPDIR/mise/cache"
  export MISE_TRUSTED_CONFIG_PATHS="$TEST_TMPDIR"
  export AP_OS_RELEASE="$TEST_TMPDIR/os-release"
  mkdir -p "$MISE_CONFIG_DIR" "$MISE_DATA_DIR" "$MISE_STATE_DIR" "$MISE_CACHE_DIR"
  printf 'ID=arch\nID_LIKE=arch\nPRETTY_NAME="Arch Linux"\n' >"$AP_OS_RELEASE"

  run bash "$AP_HELPER" setup --apply
  assert_success

  local release
  release=$(sed -n 's/^# release: //p' "$MISE_CONFIG_DIR/tasks/agent-profiles")
  assert_dir_exists "$release"
  assert_file_exists "$release/manifest.sha256"

  # Byte compatibility: the manifest still lists every shipped script and
  # VERSION in sorted order with the two-space "hash  path" text format.
  local expected="$TEST_TMPDIR/expected.sha256"
  python3 - "$AP_SKILL_DIR" "$expected" <<'PY'
import hashlib
import os
import sys

skill, destination = sys.argv[1], sys.argv[2]
files = []
for current, dirs, names in os.walk(os.path.join(skill, "scripts")):
    # Bytecode is local build state, not shipped source: the product's manifest
    # and the release tar builder both exclude it, so the expected manifest uses
    # the same file set and a stray .pyc in the checkout cannot change it.
    dirs[:] = [name for name in dirs if name != "__pycache__"]
    for name in names:
        if name.endswith(".pyc"):
            continue
        path = os.path.join(current, name)
        if os.path.islink(path) or not os.path.isfile(path):
            continue
        files.append(os.path.relpath(path, skill))
files.sort(key=lambda value: value.encode())


def digest(path):
    hasher = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(65536), b""):
            hasher.update(chunk)
    return hasher.hexdigest()


lines = ["%s  %s" % (digest(os.path.join(skill, rel)), rel) for rel in files]
lines.append("%s  VERSION" % digest(os.path.join(skill, "VERSION")))
with open(destination, "w") as handle:
    handle.write("\n".join(lines) + "\n")
PY
  run cmp "$expected" "$release/manifest.sha256"
  assert_success

  run grep -Eq '^# managed-by: flyingnobita-agent-profiles [0-9]+\.[0-9]+\.[0-9]+ sha256:[0-9a-f]{64}$' "$MISE_CONFIG_DIR/tasks/agent-profiles"
  assert_success

  # doctor verifies that released manifest without the GNU checker.
  run bash "$AP_HELPER" doctor --json
  assert_success
  python3 -c '
import json, sys
data = json.loads(sys.argv[1])
tasks = [c for c in data["checks"] if c.get("id") == "tasks"]
assert tasks, "doctor did not report a tasks check"
assert tasks[0]["status"] == "available", tasks[0]
' "$output"

  # A tampered release is still detected and reported as broken.
  printf 'tampered\n' >>"$release/scripts/lib/common.sh"
  run bash "$AP_HELPER" doctor --json
  assert_success
  python3 -c '
import json, sys
data = json.loads(sys.argv[1])
tasks = [c for c in data["checks"] if c.get("id") == "tasks"]
assert tasks, "doctor did not report a tasks check"
assert tasks[0]["status"] == "error", tasks[0]
assert "manifest verification failed" in tasks[0]["detail"], tasks[0]
' "$output"
}

@test "portability: setup manifest ignores bytecode present in the skill tree" {
  local repo="$TEST_TMPDIR/repo-bytecode"
  create_fixture_repo "$repo"
  cd "$repo"

  export MISE_CONFIG_DIR="$TEST_TMPDIR/mise/config"
  export MISE_DATA_DIR="$TEST_TMPDIR/mise/data"
  export MISE_STATE_DIR="$TEST_TMPDIR/mise/state"
  export MISE_CACHE_DIR="$TEST_TMPDIR/mise/cache"
  export MISE_TRUSTED_CONFIG_PATHS="$TEST_TMPDIR"
  export AP_OS_RELEASE="$TEST_TMPDIR/os-release"
  mkdir -p "$MISE_CONFIG_DIR" "$MISE_DATA_DIR" "$MISE_STATE_DIR" "$MISE_CACHE_DIR"
  printf 'ID=arch\nID_LIKE=arch\nPRETTY_NAME="Arch Linux"\n' >"$AP_OS_RELEASE"

  # The manifest path is the product's own: deploy from a disposable copy of the
  # skill, once as shipped and once with synthetic bytecode in the tree, and
  # compare what setup wrote. The copy starts clean so a stale .pyc in this
  # checkout cannot make the two halves agree for the wrong reason.
  local skill_copy="$TEST_TMPDIR/skill-bytecode"
  cp -a "$AP_SKILL_DIR" "$skill_copy"
  find "$skill_copy" -name "__pycache__" -type d -prune -exec rm -rf {} +
  local helper="$skill_copy/scripts/agent-profiles"

  run bash "$helper" setup --apply
  assert_success

  local task="$MISE_CONFIG_DIR/tasks/agent-profiles"
  local release_clean manifest_clean
  release_clean=$(sed -n 's/^# release: //p' "$task")
  assert_file_exists "$release_clean/manifest.sha256"
  manifest_clean="$TEST_TMPDIR/manifest-clean.sha256"
  cp "$release_clean/manifest.sha256" "$manifest_clean"

  mkdir -p "$skill_copy/scripts/lib/__pycache__"
  printf 'stray bytecode\n' >"$skill_copy/scripts/lib/__pycache__/x.cpython-315.pyc"

  run bash "$helper" setup --apply
  assert_success

  # A bytecode file is not shipped source, so the digest, the release directory
  # and the manifest bytes are unchanged: no new release is deployed.
  local release_bytecode
  release_bytecode=$(sed -n 's/^# release: //p' "$task")
  assert_equal "$release_bytecode" "$release_clean"
  run cmp "$manifest_clean" "$release_bytecode/manifest.sha256"
  assert_success
  run grep -E '(\.pyc|__pycache__)' "$release_bytecode/manifest.sha256"
  assert_failure 1

  # The two-space format, the sorted order and the VERSION line are unchanged.
  run grep -Eq '^[0-9a-f]{64}  scripts/agent-profiles$' "$release_bytecode/manifest.sha256"
  assert_success
  run grep -Eq '^[0-9a-f]{64}  scripts/lib/common[.]sh$' "$release_bytecode/manifest.sha256"
  assert_success
  run grep -Eq '^[0-9a-f]{64}  VERSION$' "$release_bytecode/manifest.sha256"
  assert_success
  run python3 - "$release_bytecode/manifest.sha256" <<'PY'
import sys

with open(sys.argv[1]) as handle:
    paths = [line.rstrip("\n").partition("  ")[2] for line in handle if line.strip()]
assert paths, "empty manifest"
# Every script in sorted order, then VERSION.
assert paths[-1] == "VERSION", paths[-1]
scripts = paths[:-1]
assert scripts and all(path.startswith("scripts/") for path in scripts), scripts
assert scripts == sorted(scripts, key=lambda value: value.encode()), (
    "manifest script order is not byte-sorted"
)
PY
  assert_success
}

@test "portability: doctor timeout handles a hanging probe without GNU timeout" {
  local repo="$TEST_TMPDIR/repo-timeout"
  create_fixture_repo "$repo"
  cd "$repo"

  # A hanging version probe that writes a credential-shaped value before it
  # blocks: the classification must be a timeout, and nothing raw may leak.
  local agents="$TEST_TMPDIR/agents-bin"
  mkdir -p "$agents"
  cat >"$agents/claude" <<'STUB'
#!/usr/bin/env bash
printf 'ANTHROPIC_API_KEY=sk-ant-secret-value\n'
sleep 30
STUB
  chmod +x "$agents/claude"

  local shim="$TEST_TMPDIR/no-timeout-bin"
  mask_command "$shim" timeout
  export PATH="$shim:$agents:$AP_HOST_PATH"

  run bash "$AP_HELPER" doctor --json --agent claude
  assert_success
  assert_output_not_contains "sk-ant-secret-value"

  python3 -c '
import json, sys
data = json.loads(sys.argv[1])
agent = data["agents"]["claude"]
assert agent["status"] == "unverified", agent
assert agent["version_probe"] == "timeout", agent
assert agent["version"] is None, agent
' "$output"
}

@test "portability: migration copy preserves symlinks without GNU cp options" {
  local shim="$TEST_TMPDIR/bsd-bin"
  reject_gnu_long_option "$shim" cp --no-dereference
  export PATH="$shim:$AP_HOST_PATH"

  local repo="$TEST_TMPDIR/repo-copy"
  create_fixture_repo "$repo"
  cd "$repo"

  mkdir -p "$repo/.agent-sandbox/home"
  printf 'legacy\n' >"$repo/.agent-sandbox/home/legacy.txt"
  ln -s home/legacy.txt "$repo/.agent-sandbox/link.txt"

  local backups="$TEST_TMPDIR/copy-backups"
  run env AP_FORCE_COPY=1 bash "$AP_HELPER" migrate --yes --backup-root "$backups"
  assert_success
  assert_output_contains "Cross-device copy verified"

  local run_dir
  run_dir=$(find "$backups" -mindepth 1 -maxdepth 1 -type d | head -n 1)
  [[ -n "$run_dir" ]]
  [[ -L "$run_dir/legacy/agent-sandbox/link.txt" ]]
  assert_equal "$(readlink "$run_dir/legacy/agent-sandbox/link.txt")" "home/legacy.txt"
  assert_file_exists "$run_dir/legacy/agent-sandbox/home/legacy.txt"

  # Originals are removed only after the symlink-preserving copy verified.
  [[ ! -d "$repo/.agent-sandbox" ]]
  assert_dir_exists "$repo/.agent-profiles/default/home"

  # A verified-content mismatch still aborts and leaves the original tree,
  # including its symlink, untouched.
  local repo_mismatch="$TEST_TMPDIR/repo-copy-mismatch"
  create_fixture_repo "$repo_mismatch"
  cd "$repo_mismatch"
  mkdir -p "$repo_mismatch/.agent-sandbox/home"
  printf 'legacy\n' >"$repo_mismatch/.agent-sandbox/home/legacy.txt"
  ln -s home/legacy.txt "$repo_mismatch/.agent-sandbox/link.txt"

  run env AP_FORCE_COPY=1 AP_CORRUPT_STAGED=1 bash "$AP_HELPER" migrate --yes \
    --backup-root "$TEST_TMPDIR/copy-backups-mismatch"
  assert_failure 77
  assert_output_contains "checksum mismatch"
  [[ -L "$repo_mismatch/.agent-sandbox/link.txt" ]]
  assert_equal "$(readlink "$repo_mismatch/.agent-sandbox/link.txt")" "home/legacy.txt"
  assert_file_exists "$repo_mismatch/.agent-sandbox/home/legacy.txt"
}

@test "portability: the BSD shim delegates to the command the host resolves" {
  # A host may keep a tool somewhere other than /usr/bin: macOS ships cp in
  # /bin, so a shim that execs /usr/bin/cp fails with "No such file or
  # directory" instead of copying. The shim must delegate to whatever the
  # caller's PATH resolves before the shim is prepended. A wrapper around cp
  # stands in for a host whose cp lives outside /usr/bin.
  local real_cp
  real_cp=$(command -v cp)
  local hostbin="$TEST_TMPDIR/host-bin"
  local delegated="$TEST_TMPDIR/host-cp-calls"
  mkdir -p "$hostbin"
  cat >"$hostbin/cp" <<CP
#!/usr/bin/env bash
printf 'host cp\n' >>"$delegated"
exec "$real_cp" "\$@"
CP
  chmod +x "$hostbin/cp"
  export PATH="$hostbin:$AP_HOST_PATH"

  local shim="$TEST_TMPDIR/bsd-bin"
  reject_gnu_long_option "$shim" cp --no-dereference
  export PATH="$shim:$PATH"

  local source="$TEST_TMPDIR/source.txt" target="$TEST_TMPDIR/target.txt"
  printf 'shim\n' >"$source"

  # The BSD rejection still wins, and nothing is delegated for it.
  run "$shim/cp" --no-dereference "$source" "$target"
  assert_failure
  assert_output_contains "illegal option"
  [[ ! -e "$target" ]]
  [[ ! -e "$delegated" ]]

  # A portable invocation runs the host's own cp, wherever it lives.
  run "$shim/cp" "$source" "$target"
  assert_success
  assert_file_exists "$target"
  [[ -s "$delegated" ]]
}
