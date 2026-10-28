#!/usr/bin/env bash

# Resolve AP_SUBJECT to repo root if not already set
export AP_SUBJECT="${AP_SUBJECT:-$(cd "$BATS_TEST_DIRNAME/../.." && pwd)}"
export AP_SKILL_DIR="$AP_SUBJECT/skills/flyingnobita-agent-profiles"
export AP_HELPER="$AP_SKILL_DIR/scripts/agent-profiles"
