#!/usr/bin/env bats

setup() {
  load '../helpers/common.bash'
  load '../helpers/assert.bash'
  load '../helpers/isolation.bash'
  setup_isolation
}

teardown() {
  teardown_isolation
}

@test "discovery: skill package directory exists in subject" {
  assert_dir_exists "$AP_SKILL_DIR"
}

@test "discovery: npx skills add --list discovers agent-profiles" {
  run skills add "$AP_SUBJECT" --list
  assert_success
  # The listing names the skill after its directory. "agent-profiles" is a
  # suffix of the old prefixed name and this checkout's path also contains it,
  # so the entry is asserted as the whole trailing token, not as a substring.
  run grep -Ex -- '.*[^[:alnum:]-]agent-profiles' <<<"$output"
  assert_success
}
