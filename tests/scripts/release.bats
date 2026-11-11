#!/usr/bin/env bats
# Tests for scripts/release — run as a subprocess in a clone of a local fixture
# origin, so the push lands in a repo the test controls.

load "${BATS_TEST_DIRNAME}/../test_helper"

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  export GIT_CONFIG_NOSYSTEM=1
  export GIT_AUTHOR_NAME="fake-author" GIT_AUTHOR_EMAIL="fake@example.invalid"
  export GIT_COMMITTER_NAME="fake-author" GIT_COMMITTER_EMAIL="fake@example.invalid"
  origin_dir="$BATS_TEST_TMPDIR/origin.git"
  clone_dir="$BATS_TEST_TMPDIR/clone"
  git init -q --bare -b main "$origin_dir"
  git clone -q "$origin_dir" "$clone_dir" 2>/dev/null
  mkdir -p "$clone_dir/scripts"
  cp "$MACHINEKIT_DIR/scripts/release" "$clone_dir/scripts/release"
  printf '0.1.0\n' > "$clone_dir/VERSION"
  git -C "$clone_dir" add -A
  git -C "$clone_dir" commit -q -m "first"
  git -C "$clone_dir" push -q origin main
}

_mk_test_release() {
  run bash -c 'cd "$1" && scripts/release "$2"' _ "$clone_dir" "$1"
}

@test "release sets VERSION, commits, tags and pushes main and the tag" {
  _mk_test_release 0.2.0
  [ "$status" -eq 0 ]
  [ "$(git -C "$origin_dir" show main:VERSION)" = "0.2.0" ]
  [ "$(git -C "$origin_dir" rev-parse '0.2.0^{commit}')" = "$(git -C "$origin_dir" rev-parse main)" ]
}

@test "release tags the current commit without a new one when VERSION already matches" {
  local before
  before="$(git -C "$clone_dir" rev-parse HEAD)"
  _mk_test_release 0.1.0
  [ "$status" -eq 0 ]
  [ "$(git -C "$origin_dir" rev-parse '0.1.0^{commit}')" = "$before" ]
  [ "$(git -C "$origin_dir" rev-parse main)" = "$before" ]
}

@test "release refuses a version that is not X.Y.Z" {
  _mk_test_release v0.2.0
  [ "$status" -ne 0 ]
  [[ "$output" == *"X.Y.Z"* ]]
}

@test "release refuses a version that is not higher than the latest release" {
  git -C "$clone_dir" tag 0.3.0
  git -C "$clone_dir" push -q origin 0.3.0
  _mk_test_release 0.2.0
  [ "$status" -ne 0 ]
  [[ "$output" == *"0.3.0"* ]]
}

@test "release refuses when not on main" {
  git -C "$clone_dir" checkout -q -b feature
  _mk_test_release 0.2.0
  [ "$status" -ne 0 ]
  [[ "$output" == *"main"* ]]
}

@test "release refuses when the working tree has changes" {
  printf 'edited\n' >> "$clone_dir/VERSION"
  _mk_test_release 0.2.0
  [ "$status" -ne 0 ]
  [[ "$output" == *"changes"* ]]
}

@test "release refuses when main differs from origin" {
  printf 'x\n' > "$clone_dir/new.txt"
  git -C "$clone_dir" add new.txt
  git -C "$clone_dir" commit -q -m "unpushed"
  _mk_test_release 0.2.0
  [ "$status" -ne 0 ]
  [[ "$output" == *"origin/main"* ]]
  run git -C "$origin_dir" tag --list
  [ -z "$output" ]
}
