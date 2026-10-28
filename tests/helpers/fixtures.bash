#!/usr/bin/env bash

create_fixture_repo() {
  local target_dir="$1"
  mkdir -p "$target_dir"
  git -C "$target_dir" init -q -b main
  git -C "$target_dir" config user.name "Test User"
  git -C "$target_dir" config user.email "test@example.com"
  git -C "$target_dir" config commit.gpgsign false
  touch "$target_dir/.gitkeep"
  git -C "$target_dir" add .gitkeep
  git -C "$target_dir" commit -q -m "initial commit"
}
