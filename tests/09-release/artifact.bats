#!/usr/bin/env bats
# Release artifact contract (S7): the versioned tarball is compared with every
# shipped source file, and the tooling builds it reproducibly on a stock macOS
# userland where GNU tar options, sha256sum and stat -c do not exist.
#
# The disposable repository copies below keep the checkout itself clean: the
# build output always goes to a test-owned output directory, never to dist/.
# shellcheck disable=SC2030,SC2031

setup() {
  load '../helpers/common.bash'
  load '../helpers/assert.bash'
  load '../helpers/isolation.bash'
  load '../helpers/platform.bash'
  setup_isolation
  CHECK_RELEASE="$AP_SUBJECT/tests/tools/check-release"
  RELEASE_TOOL="$AP_SUBJECT/tools/release-artifacts"
  NOTES="$AP_SUBJECT/RELEASE_NOTES.md"
  VERSION="$(tr -d '[:space:]' <"$AP_SKILL_DIR/VERSION")"
  TARBALL_NAME="flyingnobita-agent-profiles-$VERSION.tar.gz"
}

teardown() {
  teardown_isolation
}

# copy_repo <dest>: a disposable copy of the checkout without .git or dist, so a
# test can rebuild after a source change and still run the real release tools.
copy_repo() {
  local dest="$1"
  mkdir -p "$dest"
  cp -a "$AP_SUBJECT/." "$dest/"
  rm -rf "$dest/.git" "$dest/dist"
}

# mask_command <dir> <name>: the command is absent, as it is on stock macOS for
# sha256sum.
mask_command() {
  local dir="$1"
  local name="$2"
  mkdir -p "$dir"
  cat >"$dir/$name" <<SHIM
#!/usr/bin/env bash
printf 'artifact: %s is masked in this test\n' "$name" >&2
exit 127
SHIM
  chmod +x "$dir/$name"
}

# reject_gnu_options <dir> <name>: the command exists but rejects option
# arguments, which is how BSD tar and BSD stat answer a GNU-only flag.
reject_gnu_options() {
  local dir="$1"
  local name="$2"
  mkdir -p "$dir"
  cat >"$dir/$name" <<SHIM
#!/usr/bin/env bash
case "\${1:-}" in
  -*) printf '${name}: illegal option -- %s\n' "\${1#-}" >&2; exit 1 ;;
esac
exec $(command -v "$name") "\$@"
SHIM
  chmod +x "$dir/$name"
}

# repack_artifact <tarball> <drop|add|link> <member> [<link-target>]: rewrites
# the tarball as if the build had produced tampered content and refreshes its
# checksum, so what the contract rejects is the member itself rather than the
# checksum. The "link" mode replaces a member with a symlink to <link-target>.
repack_artifact() {
  python3 - "$1" "$2" "$3" "${4:-}" <<'PY'
import gzip
import hashlib
import io
import os
import sys
import tarfile

tarball, mode, member = sys.argv[1], sys.argv[2], sys.argv[3]
link_target = sys.argv[4]
with tarfile.open(tarball, "r:gz") as archive:
    members = []
    for info in archive.getmembers():
        handle = archive.extractfile(info) if info.isfile() else None
        members.append((info, handle.read() if handle is not None else None))

buffer = io.BytesIO()
with tarfile.open(fileobj=buffer, mode="w", format=tarfile.USTAR_FORMAT) as archive:
    for info, data in members:
        if mode in ("drop", "link") and info.name.rstrip("/") == member.rstrip("/"):
            continue
        archive.addfile(info, io.BytesIO(data) if data is not None else None)
    if mode == "add":
        info = tarfile.TarInfo(member)
        payload = b"content that is not in the shipped source\n"
        info.size = len(payload)
        info.mode = 0o644
        archive.addfile(info, io.BytesIO(payload))
    if mode == "link":
        info = tarfile.TarInfo(member)
        info.type = tarfile.SYMTYPE
        info.linkname = link_target
        info.mode = 0o777
        archive.addfile(info)

data = buffer.getvalue()
with open(tarball, "wb") as raw:
    with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as handle:
        handle.write(data)

digest = hashlib.sha256()
with open(tarball, "rb") as handle:
    for chunk in iter(lambda: handle.read(65536), b""):
        digest.update(chunk)
with open(tarball + ".sha256", "w") as manifest:
    manifest.write("%s  %s\n" % (digest.hexdigest(), os.path.basename(tarball)))
PY
}

# extract_artifact <tarball> <dest>: extract without GNU tar, refusing absolute
# and parent-traversal members before anything is written.
extract_artifact() {
  python3 - "$1" "$2" <<'PY'
import sys
import tarfile

tarball, dest = sys.argv[1], sys.argv[2]
with tarfile.open(tarball, "r:gz") as archive:
    for info in archive.getmembers():
        if info.name.startswith("/") or ".." in info.name.split("/"):
            raise SystemExit("unsafe member: %s" % info.name)
    try:
        archive.extractall(dest, filter="data")
    except TypeError:
        archive.extractall(dest)
PY
}

@test "release: versioned release notes describe the local v0.3.0 scope" {
  assert_file_exists "$NOTES"
  run grep -E "^# .*flyingnobita-agent-profiles v$VERSION$" "$NOTES"
  assert_success

  # Only the current scope is asserted. The archived v0.1.0 section truthfully
  # records that macOS was not qualified in that release.
  local scope
  scope=$(awk -v title="flyingnobita-agent-profiles v$VERSION" '
    /^#+ .*v[0-9]+\.[0-9]+\.[0-9]+/ { inside = index($0, title) > 0 }
    inside { print }
  ' "$NOTES")
  [[ -n "$scope" ]]

  for term in "MIT" "Linux" "macOS arm64" "nothing is mounted" "weaker" \
    "no bubblewrap prerequisite" "credential-dependent" "not published"; do
    printf '%s\n' "$scope" | grep -qiF -- "$term"
  done

  # The notes word the boundary as "neither platform is a security sandbox"; the
  # README wording is accepted too, so either way the scope must deny that a
  # profile is a security sandbox.
  printf '%s\n' "$scope" | grep -qiF -- "not a security sandbox" \
    || printf '%s\n' "$scope" | grep -qiF -- "neither platform is a security sandbox"

  # A reversion to the deferred-platform claim in the current scope is refused.
  run grep -Fi -- "macOS is not qualified" <<<"$scope"
  assert_failure 1
}

@test "release: mise defines the release-artifacts task that verifies before building" {
  run grep -F -- "[tasks.release-artifacts]" "$AP_SUBJECT/mise.toml"
  assert_success
  run grep -F -- "check-release" "$AP_SUBJECT/mise.toml"
  assert_success
  run grep -F -- "tools/release-artifacts" "$AP_SUBJECT/mise.toml"
  assert_success
}

@test "release: release-artifacts builds a tarball, checksum and notes outside Git" {
  assert_file_exists "$RELEASE_TOOL"
  local out="$TEST_TMPDIR/dist"
  run bash "$RELEASE_TOOL" "$AP_SUBJECT" --output-dir "$out"
  assert_success

  assert_file_exists "$out/flyingnobita-agent-profiles-$VERSION.tar.gz"
  assert_file_exists "$out/flyingnobita-agent-profiles-$VERSION.tar.gz.sha256"
  assert_file_exists "$out/RELEASE_NOTES.md"

  run ap_test_manifest_verify "$out" "$out/flyingnobita-agent-profiles-$VERSION.tar.gz.sha256"
  assert_success

  # Build output must not become tracked content.
  run grep -qxF -- "dist/" "$AP_SUBJECT/.gitignore"
  assert_success
}

@test "release: the built artifact verifies, extracts and runs from a disposable copy" {
  assert_file_exists "$RELEASE_TOOL"
  local out="$TEST_TMPDIR/dist"
  run bash "$RELEASE_TOOL" "$AP_SUBJECT" --output-dir "$out"
  assert_success

  run bash "$CHECK_RELEASE" "$AP_SUBJECT" --artifacts "$out"
  assert_success
  assert_output_contains "artifact checksum verifies"
  assert_output_contains "extracted artifact runs --version and doctor --json"
}

@test "release: check-release validates artifact members before extraction on every python3" {
  # The interpreter's tarfile extraction filter decides nothing here: 3.9 has no
  # filter, 3.10.12/3.11.4/3.12 add --data--, and 3.14 makes it the default. A
  # member that must be refused has to fail with this tool's own message on
  # every one of them, never as a filter exception from inside extractall.
  local repo="$TEST_TMPDIR/repo-member-validation"
  local clean="$TEST_TMPDIR/dist-member-clean"
  copy_repo "$repo"

  run bash "$RELEASE_TOOL" "$repo" --output-dir "$clean"
  assert_success

  # A clean artifact extracts and runs.
  run bash "$CHECK_RELEASE" "$repo" --artifacts "$clean"
  assert_success
  assert_output_contains "extracted artifact runs --version and doctor --json"

  # Extraction never delegates to TarFile.extractall, so the filter behaviour
  # cannot change the outcome. A shim that makes extractall raise proves the
  # validated extraction path above is what actually runs.
  local guard="$TEST_TMPDIR/no-extractall"
  mkdir -p "$guard"
  cat >"$guard/sitecustomize.py" <<'PY'
import tarfile


def _forbidden(*args, **kwargs):
    raise AssertionError("check-release delegated extraction to tarfile")


tarfile.TarFile.extractall = _forbidden
tarfile.TarFile.extract = _forbidden
PY
  run env PYTHONPATH="$guard" bash "$CHECK_RELEASE" "$repo" --artifacts "$clean"
  assert_success
  assert_output_contains "extracted artifact runs --version and doctor --json"

  # A shipped absolute symlink: the source and the artifact describe the same
  # link, so the fingerprint matches and only the member validation can refuse
  # it. Before the fix this raised AbsoluteLinkError/
  # LinkOutsideDestinationError from inside extractall and was reported as
  # "artifact could not be extracted".
  local shipped="$repo/skills/flyingnobita-agent-profiles/scripts/lib/agents/claude.sh"
  local member="flyingnobita-agent-profiles/scripts/lib/agents/claude.sh"
  local outside="$TEST_TMPDIR/dist-member-outside"
  rm -f "$shipped"
  ln -s /tmp/questions.md "$shipped"
  mkdir -p "$outside"
  cp -p "$clean/$TARBALL_NAME" "$outside/$TARBALL_NAME"
  cp -p "$clean/$TARBALL_NAME.sha256" "$outside/$TARBALL_NAME.sha256"
  cp -p "$clean/RELEASE_NOTES.md" "$outside/RELEASE_NOTES.md"
  repack_artifact "$outside/$TARBALL_NAME" link "$member" /tmp/questions.md

  run bash "$CHECK_RELEASE" "$repo" --artifacts "$outside"
  assert_failure
  assert_output_contains "artifact fingerprint matches every shipped source file"
  assert_output_contains "artifact symlink target is absolute: $member -> /tmp/questions.md"
  assert_output_not_contains "Traceback"

  # A relative link that still leaves the destination is refused the same way.
  local escape="$TEST_TMPDIR/dist-member-escape"
  rm -f "$shipped"
  ln -s ../../../../../outside.md "$shipped"
  mkdir -p "$escape"
  cp -p "$clean/$TARBALL_NAME" "$escape/$TARBALL_NAME"
  cp -p "$clean/$TARBALL_NAME.sha256" "$escape/$TARBALL_NAME.sha256"
  cp -p "$clean/RELEASE_NOTES.md" "$escape/RELEASE_NOTES.md"
  repack_artifact "$escape/$TARBALL_NAME" link "$member" ../../../../../outside.md

  run bash "$CHECK_RELEASE" "$repo" --artifacts "$escape"
  assert_failure
  assert_output_contains "artifact fingerprint matches every shipped source file"
  assert_output_contains "artifact symlink escapes the artifact: $member -> ../../../../../outside.md"
  assert_output_not_contains "Traceback"
}

@test "release: artifact fingerprint matches every shipped source file and rejects stale content" {
  local repo="$TEST_TMPDIR/repo-fingerprint"
  local out="$TEST_TMPDIR/dist-fingerprint"
  copy_repo "$repo"

  run bash "$RELEASE_TOOL" "$repo" --output-dir "$out"
  assert_success

  # A fresh artifact is accepted before anything is changed.
  run bash "$CHECK_RELEASE" "$repo" --artifacts "$out"
  assert_success

  local tarball="$out/$TARBALL_NAME"
  cp -p "$tarball" "$TEST_TMPDIR/pristine.tar.gz"
  cp -p "$tarball.sha256" "$TEST_TMPDIR/pristine.tar.gz.sha256"

  # Stale content: the artifact was built, then one shipped source file changed.
  local shipped="$repo/skills/flyingnobita-agent-profiles/references/agents/codex.md"
  assert_file_exists "$shipped"
  cp -p "$shipped" "$TEST_TMPDIR/codex.md"
  printf '\nStale marker added after the build.\n' >>"$shipped"
  run bash "$CHECK_RELEASE" "$repo" --artifacts "$out"
  assert_failure
  assert_output_contains "artifact member content differs from source"

  cp -p "$TEST_TMPDIR/codex.md" "$shipped"
  run bash "$CHECK_RELEASE" "$repo" --artifacts "$out"
  assert_success

  # Missing and extra members are still rejected when the checksum is refreshed,
  # so the entry comparison - not the checksum - covers the source tree.
  repack_artifact "$tarball" drop "flyingnobita-agent-profiles/references/agents/codex.md"
  run bash "$CHECK_RELEASE" "$repo" --artifacts "$out"
  assert_failure
  assert_output_contains "artifact is missing shipped source"

  cp -p "$TEST_TMPDIR/pristine.tar.gz" "$tarball"
  repack_artifact "$tarball" add "flyingnobita-agent-profiles/references/agents/extra.md"
  run bash "$CHECK_RELEASE" "$repo" --artifacts "$out"
  assert_failure
  assert_output_contains "artifact contains an unexpected member"

  cp -p "$TEST_TMPDIR/pristine.tar.gz" "$tarball"
  cp -p "$TEST_TMPDIR/pristine.tar.gz.sha256" "$tarball.sha256"
  run bash "$CHECK_RELEASE" "$repo" --artifacts "$out"
  assert_success
  assert_output_contains "artifact fingerprint matches every shipped source file"

  # Mode and entry type are part of the comparison, not only content.
  local mode
  mode=$(ap_test_stat_mode "$shipped")
  chmod 600 "$shipped"
  run bash "$CHECK_RELEASE" "$repo" --artifacts "$out"
  assert_failure
  assert_output_contains "artifact member mode differs from source"
  chmod "$mode" "$shipped"

  mv "$shipped" "$TEST_TMPDIR/codex.saved"
  ln -s "claude-code.md" "$shipped"
  run bash "$CHECK_RELEASE" "$repo" --artifacts "$out"
  assert_failure
  assert_output_contains "artifact member type differs from source"
  rm -f "$shipped"
  mv "$TEST_TMPDIR/codex.saved" "$shipped"

  # A shipped symlink is compared by target, not by the file it points at.
  local link_out="$TEST_TMPDIR/dist-link"
  local link_dir="$repo/skills/flyingnobita-agent-profiles/references/linked"
  mkdir -p "$link_dir"
  ln -s "../questions.md" "$link_dir/questions.md"
  run bash "$RELEASE_TOOL" "$repo" --output-dir "$link_out"
  assert_success
  ln -sfn "../troubleshooting.md" "$link_dir/questions.md"
  run bash "$CHECK_RELEASE" "$repo" --artifacts "$link_out"
  assert_failure
  assert_output_contains "artifact member link target differs from source"
  rm -rf "$link_dir"

  # BSD grep has no -P, so a PCRE scan exits non-zero and an unchecked `if`
  # silently passes. The portable scan must still see the em dash.
  local bsd_bin="$TEST_TMPDIR/bsd-grep-bin"
  mkdir -p "$bsd_bin"
  cat >"$bsd_bin/grep" <<SHIM
#!/usr/bin/env bash
for arg in "\$@"; do
  case "\$arg" in
    -P | -*P*) printf 'grep: illegal option -- P\n' >&2; exit 2 ;;
  esac
done
exec $(command -v grep) "\$@"
SHIM
  chmod +x "$bsd_bin/grep"

  local em_dash
  em_dash=$(printf '\342\200\224')
  cp -p "$repo/README.md" "$TEST_TMPDIR/README.md"
  printf 'Stale prose %s added after the build.\n' "$em_dash" >>"$repo/README.md"
  run env PATH="$bsd_bin:$PATH" bash "$CHECK_RELEASE" "$repo"
  assert_failure
  assert_output_contains "em dash in README.md"

  cp -p "$TEST_TMPDIR/README.md" "$repo/README.md"
  run env PATH="$bsd_bin:$PATH" bash "$CHECK_RELEASE" "$repo"
  assert_success
}

@test "release: artifact tooling builds reproducibly without GNU tar checksum or stat options" {
  local repo="$TEST_TMPDIR/repo-repeat"
  local bin="$TEST_TMPDIR/no-gnu-bin"
  local first="$TEST_TMPDIR/dist-one"
  local second="$TEST_TMPDIR/dist-two"
  copy_repo "$repo"

  # Stock macOS: no sha256sum, BSD tar rejects GNU long options, BSD stat has no
  # -c format string. The build must not need any of them.
  mask_command "$bin" sha256sum
  mask_command "$bin" tar
  reject_gnu_options "$bin" stat

  run env PATH="$bin:$PATH" SOURCE_DATE_EPOCH=1700000000 \
    bash "$RELEASE_TOOL" "$repo" --output-dir "$first"
  assert_success
  run env PATH="$bin:$PATH" SOURCE_DATE_EPOCH=1700000000 \
    bash "$RELEASE_TOOL" "$repo" --output-dir "$second"
  assert_success
  # The build verifies the artifact it wrote against the shipped source.
  assert_output_contains "artifact fingerprint matches every shipped source file"

  # Same source, same SOURCE_DATE_EPOCH, same bytes.
  assert_file_exists "$first/$TARBALL_NAME"
  assert_file_exists "$second/$TARBALL_NAME"
  assert_equal "$(ap_test_sha256 "$first/$TARBALL_NAME")" \
    "$(ap_test_sha256 "$second/$TARBALL_NAME")"
  run cmp -s "$first/$TARBALL_NAME" "$second/$TARBALL_NAME"
  assert_success

  # The checksum the build wrote verifies with the shipped verifier.
  run ap_test_manifest_verify "$first" "$first/$TARBALL_NAME.sha256"
  assert_success

  # The extracted artifact runs on Darwin-shaped input with no GNU userland.
  local extract="$TEST_TMPDIR/extract"
  mkdir -p "$extract"
  extract_artifact "$first/$TARBALL_NAME" "$extract"
  local helper="$extract/flyingnobita-agent-profiles/scripts/agent-profiles"
  assert_file_exists "$helper"

  run bash "$helper" --version
  assert_success
  assert_equal "$output" "$VERSION"

  local darwin_bin="$TEST_TMPDIR/darwin-bin"
  local real_uname
  real_uname=$(command -v uname)
  mkdir -p "$darwin_bin"
  cat >"$darwin_bin/uname" <<STUB
#!/usr/bin/env bash
case "\${1:-}" in
  -s) printf 'Darwin\n' ;;
  -m) printf 'arm64\n' ;;
  *) exec "$real_uname" "\$@" ;;
esac
STUB
  chmod +x "$darwin_bin/uname"

  run env PATH="$darwin_bin:$bin:$PATH" \
    HOME="$HOME" \
    XDG_CONFIG_HOME="$XDG_CONFIG_HOME" \
    XDG_DATA_HOME="$XDG_DATA_HOME" \
    XDG_STATE_HOME="$XDG_STATE_HOME" \
    XDG_CACHE_HOME="$XDG_CACHE_HOME" \
    DISABLE_TELEMETRY=1 \
    bash "$helper" doctor --json
  assert_success
  echo "$output" | python3 -c '
import json, sys
data = json.load(sys.stdin)
os_name = data["os"]["name"]
if os_name != "Darwin":
    raise SystemExit("doctor reported %r instead of Darwin" % os_name)
checks = {check["id"]: check for check in data["checks"]}
if checks["bwrap"]["status"] != "not_applicable":
    raise SystemExit("bwrap is %r on Darwin" % checks["bwrap"]["status"])
'
}

@test "release: check-release rejects a tampered artifact" {
  local out="$TEST_TMPDIR/dist-tampered"
  mkdir -p "$out"
  run bash "$RELEASE_TOOL" "$AP_SUBJECT" --output-dir "$out"
  assert_success

  printf 'x' >>"$out/flyingnobita-agent-profiles-$VERSION.tar.gz"
  run bash "$CHECK_RELEASE" "$AP_SUBJECT" --artifacts "$out"
  assert_failure
  assert_output_contains "artifact checksum verification failed"
}
