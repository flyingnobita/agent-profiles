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
