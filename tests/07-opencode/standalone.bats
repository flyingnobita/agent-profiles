#!/usr/bin/env bats

setup() {
  load '../helpers/common.bash'
  load '../helpers/assert.bash'
  load '../helpers/fixtures.bash'
  load '../helpers/isolation.bash'
  setup_isolation

  STUB_BIN="$TEST_TMPDIR/stub-bin"
  mkdir -p "$STUB_BIN"
  cat >"$STUB_BIN/opencode" <<'STUB'
#!/usr/bin/env bash
printf 'ARGS=%s\n' "$*"
STUB
  chmod +x "$STUB_BIN/opencode"

  local repo="$TEST_TMPDIR/repo-opencode-standalone"
  create_fixture_repo "$repo"
  cd "$repo"
  run bash "$AP_HELPER" init --profile dev
  assert_success
}

teardown() {
  teardown_isolation
}

# The helper writes notices to stderr, so compare only the stub's argument line.
run_opencode() {
  run env PATH="$STUB_BIN:$PATH" bash "$AP_HELPER" run --profile dev -- "$@"
  assert_success
  ARGS_LINE=$(grep '^ARGS=' <<<"$output")
}

@test "opencode standalone: the TUI runs with a private server instead of the shared background service" {
  run_opencode opencode
  assert_equal "ARGS=--standalone" "$ARGS_LINE"
}

@test "opencode standalone: TUI flags and a directory are forwarded after the inserted flag" {
  run_opencode opencode --continue some/dir
  assert_equal "ARGS=--standalone --continue some/dir" "$ARGS_LINE"
}

@test "opencode standalone: values of TUI flags are not mistaken for subcommands" {
  run_opencode opencode --log-level debug --prompt serve
  assert_equal "ARGS=--standalone --log-level debug --prompt serve" "$ARGS_LINE"
}

@test "opencode standalone: commands that accept a private server get one" {
  run_opencode opencode run "fix the serve command"
  assert_equal "ARGS=--standalone run fix the serve command" "$ARGS_LINE"

  local cmd
  for cmd in "mini" "api GET /api/info" "auth list" "models" "session list" "stats" "reload" \
    "mcp list" "debug config" "plugin check"; do
    # shellcheck disable=SC2086
    run_opencode opencode $cmd
    assert_equal "ARGS=--standalone $cmd" "$ARGS_LINE"
  done
}

@test "opencode standalone: commands that reject the flag are unchanged" {
  local cmd
  for cmd in "acp" "service stop" "serve" "upgrade" "update" "uninstall" "pair" \
    "mcp add" "debug paths" "debug heap-dump" "plugin add" "plugin remove"; do
    # shellcheck disable=SC2086
    run_opencode opencode $cmd
    assert_equal "ARGS=$cmd" "$ARGS_LINE"
  done
}

@test "opencode standalone: an explicit --standalone or --server is respected" {
  run_opencode opencode --standalone
  assert_equal "ARGS=--standalone" "$ARGS_LINE"

  run_opencode opencode --server http://127.0.0.1:4096
  assert_equal "ARGS=--server http://127.0.0.1:4096" "$ARGS_LINE"

  run_opencode opencode run --server=http://127.0.0.1:4096 hello
  assert_equal "ARGS=run --server=http://127.0.0.1:4096 hello" "$ARGS_LINE"
}

@test "opencode standalone: an opencode binary given by path is also rewritten" {
  run_opencode "$STUB_BIN/opencode"
  assert_equal "ARGS=--standalone" "$ARGS_LINE"
}

@test "opencode standalone: other commands are forwarded verbatim" {
  run_opencode sh -c 'printf "ARGS=%s\n" "$*"' sh opencode run
  assert_equal "ARGS=opencode run" "$ARGS_LINE"
}
