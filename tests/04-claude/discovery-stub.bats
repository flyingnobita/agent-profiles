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

write_claude_stub() {
  local stub_bin="$1"
  mkdir -p "$stub_bin"
  cat >"$stub_bin/claude" <<'EOF'
#!/usr/bin/env bash
cfg="${CLAUDE_CONFIG_DIR:-$HOME}"
printf 'CONFIG_DIR=%s\n' "$cfg"
printf 'PROFILE_JSON=%s\n' "$(cat "$cfg/.claude.json" 2>/dev/null || true)"
printf 'PROFILE_SETTINGS=%s\n' "$(cat "$cfg/settings.json" 2>/dev/null || true)"
printf 'HOME_SETTINGS=%s\n' "$(cat "$HOME/.claude/settings.json" 2>/dev/null || true)"
printf 'SKILLS=%s\n' "$(find "$cfg/skills" -mindepth 1 -maxdepth 1 -printf '%f ' 2>/dev/null || true)"
printf 'SECURE=%s\n' "${CLAUDE_SECURESTORAGE_CONFIG_DIR:-UNSET}"
EOF
  chmod +x "$stub_bin/claude"
}

seed_synthetic_host() {
  mkdir -p "$HOME/.claude/skills/host-marker-skill"
  printf '{"hostMarker":true,"mcpServers":{"host-marker-mcp":{"command":"/bin/true"}}}\n' \
    >"$HOME/.claude.json"
  printf 'host-settings-marker\n' >"$HOME/.claude/settings.json"
  printf '{"marker":"host-credential-marker"}\n' >"$HOME/.claude/.credentials.json"
  printf -- '---\nname: host-marker-skill\n---\nhost marker\n' \
    >"$HOME/.claude/skills/host-marker-skill/SKILL.md"
}

@test "claude stub: selected profile config and skills replace synthetic host config" {
  local repo="$TEST_TMPDIR/repo-claude-stub"
  create_fixture_repo "$repo"
  cd "$repo"

  seed_synthetic_host
  run bash "$AP_HELPER" init --profile alpha
  assert_success

  local prof_claude="$repo/.agent-profiles/alpha/.claude"
  printf '{"profileMarker":true}\n' >"$prof_claude/.claude.json"
  printf 'alpha-settings-marker\n' >"$prof_claude/settings.json"
  mkdir -p "$prof_claude/skills/alpha-marker-skill"
  printf -- '---\nname: alpha-marker-skill\n---\nalpha marker\n' \
    >"$prof_claude/skills/alpha-marker-skill/SKILL.md"

  local stub_bin="$TEST_TMPDIR/claude-stub-bin"
  write_claude_stub "$stub_bin"

  run env PATH="$stub_bin:$PATH" bash "$AP_HELPER" run --profile alpha -- claude
  assert_success

  assert_output_contains "CONFIG_DIR=$prof_claude"
  assert_output_contains 'PROFILE_JSON={"profileMarker":true}'
  assert_output_contains "PROFILE_SETTINGS=alpha-settings-marker"
  # The profile mount hides the synthetic host settings directory.
  assert_output_contains "HOME_SETTINGS=alpha-settings-marker"
  assert_output_contains "SKILLS=alpha-marker-skill"
  assert_output_contains "SECURE=UNSET"

  assert_output_not_contains "hostMarker"
  assert_output_not_contains "host-marker-mcp"
  assert_output_not_contains "host-settings-marker"
  assert_output_not_contains "host-marker-skill"
  assert_output_not_contains "host-credential-marker"
}

@test "claude stub: host credential file is not read, copied or made writable" {
  local repo="$TEST_TMPDIR/repo-claude-cred"
  create_fixture_repo "$repo"
  cd "$repo"

  seed_synthetic_host
  local host_cred="$HOME/.claude/.credentials.json"
  local before after
  before=$(sha256sum "$host_cred" | awk '{print $1}')

  run bash "$AP_HELPER" init --profile alpha
  assert_success

  local stub_bin="$TEST_TMPDIR/claude-cred-stub-bin"
  write_claude_stub "$stub_bin"
  run env PATH="$stub_bin:$PATH" bash "$AP_HELPER" run --profile alpha -- claude
  assert_success

  after=$(sha256sum "$host_cred" | awk '{print $1}')
  assert_equal "$after" "$before"
  [[ ! -e "$repo/.agent-profiles/alpha/.claude/.credentials.json" ]]
  assert_output_not_contains "host-credential-marker"
}

@test "claude doctor: --profile diagnostics leave the profile unchanged" {
  local repo="$TEST_TMPDIR/repo-claude-readonly"
  create_fixture_repo "$repo"
  cd "$repo"

  run bash "$AP_HELPER" init --profile alpha
  assert_success

  local prof_dir="$repo/.agent-profiles/alpha"
  local before after
  before=$(cd "$prof_dir" && find . -type f -exec sha256sum {} + | sort)

  run bash "$AP_HELPER" doctor --json --agent claude --profile alpha
  assert_success

  after=$(cd "$prof_dir" && find . -type f -exec sha256sum {} + | sort)
  assert_equal "$after" "$before"
}
