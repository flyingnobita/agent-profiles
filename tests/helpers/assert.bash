#!/usr/bin/env bash
# shellcheck disable=SC2154

assert_success() {
  if [[ "$status" -ne 0 ]]; then
    echo "Expected status 0, got $status" >&2
    echo "Output:" >&2
    echo "$output" >&2
    return 1
  fi
}

assert_failure() {
  local expected="${1:-}"
  if [[ "$status" -eq 0 ]]; then
    echo "Expected non-zero status, got 0" >&2
    echo "Output:" >&2
    echo "$output" >&2
    return 1
  fi
  if [[ -n "$expected" && "$status" -ne "$expected" ]]; then
    echo "Expected status $expected, got $status" >&2
    echo "Output:" >&2
    echo "$output" >&2
    return 1
  fi
}

assert_output_contains() {
  local expected="$1"
  if [[ "$output" != *"$expected"* ]]; then
    echo "Expected output to contain: $expected" >&2
    echo "Actual output:" >&2
    echo "$output" >&2
    return 1
  fi
}

assert_output_not_contains() {
  local unexpected="$1"
  if [[ "$output" == *"$unexpected"* ]]; then
    echo "Expected output NOT to contain: $unexpected" >&2
    echo "Actual output:" >&2
    echo "$output" >&2
    return 1
  fi
}

assert_output_equals() {
  local expected="$1"
  if [[ "$output" != "$expected" ]]; then
    echo "Expected output: $expected" >&2
    echo "Actual output:   $output" >&2
    return 1
  fi
}

assert_file_exists() {
  local path="$1"
  if [[ ! -f "$path" ]]; then
    echo "Expected file to exist: $path" >&2
    return 1
  fi
}

assert_dir_exists() {
  local path="$1"
  if [[ ! -d "$path" ]]; then
    echo "Expected directory to exist: $path" >&2
    return 1
  fi
}

assert_equal() {
  local actual="$1"
  local expected="$2"
  if [[ "$actual" != "$expected" ]]; then
    echo "Expected: $expected" >&2
    echo "Actual:   $actual" >&2
    return 1
  fi
}
