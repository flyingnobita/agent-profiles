#!/usr/bin/env bats

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

@test "bwrap: writes inside redirected directories land in profile storage and not host HOME" {
  local repo="$TEST_TMPDIR/repo-bwrap-redirect"
  create_fixture_repo "$repo"
  cd "$repo"
  run bash "$AP_HELPER" init
  assert_success

  # Ensure synthetic host mountpoint dirs exist in isolated HOME
  mkdir -p "$HOME/.claude"

  run bash "$AP_HELPER" run -- sh -c 'printf "profile_marker\n" > "$HOME/.claude/test_marker.txt"'
  assert_success

  # Marker landed in profile storage
  assert_file_exists "$repo/.agent-profiles/default/.claude/test_marker.txt"
  local content
  content=$(cat "$repo/.agent-profiles/default/.claude/test_marker.txt")
  assert_equal "$content" "profile_marker"

  # Host HOME remains untouched
  [[ ! -f "$HOME/.claude/test_marker.txt" ]]
}

@test "bwrap: creates empty host mountpoint with stderr notice when target is missing" {
  local repo="$TEST_TMPDIR/repo-bwrap-missing-target"
  create_fixture_repo "$repo"
  cd "$repo"
  run bash "$AP_HELPER" init
  assert_success

  # Ensure $HOME/.codex does NOT exist
  rm -rf "$HOME/.codex"

  run bash "$AP_HELPER" run -- echo ok
  assert_success
  assert_output_contains "notice: created empty host mountpoint"
  assert_output_contains ".codex"
  assert_dir_exists "$HOME/.codex"
}

@test "bwrap: binds over physical target when host directory is a symlink" {
  local repo="$TEST_TMPDIR/repo-bwrap-symlink-target"
  create_fixture_repo "$repo"
  cd "$repo"
  run bash "$AP_HELPER" init
  assert_success

  # Create physical dir and symlink $HOME/.codex -> physical dir
  local real_host_codex="$TEST_TMPDIR/custom_codex_target"
  mkdir -p "$real_host_codex"
  rm -rf "$HOME/.codex"
  ln -s "$real_host_codex" "$HOME/.codex"

  run bash "$AP_HELPER" run -- sh -c 'printf "symlink_marker\n" > "$HOME/.codex/marker.txt"'
  assert_success

  # Marker landed in profile storage
  assert_file_exists "$repo/.agent-profiles/default/.codex/marker.txt"

  # Host physical target has no marker
  [[ ! -f "$real_host_codex/marker.txt" ]]
}

@test "bwrap: rejects dangling symlink host mount target with exit 73" {
  local repo="$TEST_TMPDIR/repo-bwrap-dangling"
  create_fixture_repo "$repo"
  cd "$repo"
  run bash "$AP_HELPER" init
  assert_success

  rm -rf "$HOME/.codex"
  ln -s "$TEST_TMPDIR/nonexistent_dir" "$HOME/.codex"

  run bash "$AP_HELPER" run -- echo ok
  assert_failure
  assert_equal "$status" 73
  assert_output_contains "dangling symlink"
}

@test "bwrap: rejects non-directory host mount target with exit 73" {
  local repo="$TEST_TMPDIR/repo-bwrap-nondir"
  create_fixture_repo "$repo"
  cd "$repo"
  run bash "$AP_HELPER" init
  assert_success

  rm -rf "$HOME/.gemini"
  touch "$HOME/.gemini"

  run bash "$AP_HELPER" run -- echo ok
  assert_failure
  assert_equal "$status" 73
  assert_output_contains "not a directory"
}

@test "bwrap: fails with exit 69 if bwrap is missing from PATH" {
  local repo="$TEST_TMPDIR/repo-bwrap-nobwrap"
  create_fixture_repo "$repo"
  cd "$repo"
  run bash "$AP_HELPER" init
  assert_success

  # Strip bwrap from PATH using a restricted PATH
  local restricted_bin="$TEST_TMPDIR/restricted_bin"
  mkdir -p "$restricted_bin"
  local old_ifs="$IFS"
  IFS=':'
  for bin_dir in $PATH; do
    IFS="$old_ifs"
    for tool in "$bin_dir"/*; do
      [[ -x "$tool" && ! -d "$tool" ]] || continue
      local name
      name="$(basename "$tool")"
      [[ "$name" == "bwrap" ]] && continue
      [[ ! -e "$restricted_bin/$name" ]] && ln -s "$tool" "$restricted_bin/$name" 2>/dev/null || true
    done
  done
  IFS="$old_ifs"

  run env PATH="$restricted_bin" bash "$AP_HELPER" run -- true
  assert_failure
  assert_equal "$status" 69
  assert_output_contains "bwrap"
}

@test "bwrap: fails with exit 69 if bwrap capability check fails" {
  local repo="$TEST_TMPDIR/repo-bwrap-capfail"
  create_fixture_repo "$repo"
  cd "$repo"
  run bash "$AP_HELPER" init
  assert_success

  # Fake bwrap that fails capability probe
  local fake_bin="$TEST_TMPDIR/fake_bin"
  mkdir -p "$fake_bin"
  cat <<'EOF' > "$fake_bin/bwrap"
#!/usr/bin/env bash
echo "bwrap: Setting up mount namespace failed: Operation not permitted" >&2
exit 1
EOF
  chmod +x "$fake_bin/bwrap"

  run env PATH="$fake_bin:$PATH" bash "$AP_HELPER" run -- true
  assert_failure
  assert_equal "$status" 69
  assert_output_contains "unprivileged user namespaces"
}
