#!/usr/bin/env bats
# Tests for install.sh — run as a subprocess under /bin/bash, the way the curl
# one-liner runs it, against a local fixture repo standing in for GitHub. The
# fixture's bin/machinekit, bash bootstrap and ensure-on-path only record how they
# were called.

load "${BATS_TEST_DIRNAME}/test_helper"

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  export GIT_CONFIG_NOSYSTEM=1
  export GIT_AUTHOR_NAME="fake-author" GIT_AUTHOR_EMAIL="fake@example.invalid"
  export GIT_COMMITTER_NAME="fake-author" GIT_COMMITTER_EMAIL="fake@example.invalid"
  calls_dir="$BATS_TEST_TMPDIR/calls"
  mkdir -p "$calls_dir"
  export calls_dir
  origin_dir="$BATS_TEST_TMPDIR/origin"
  export MACHINEKIT_REPO="$origin_dir"
  export MACHINEKIT_FRAMEWORK_DIR="$BATS_TEST_TMPDIR/framework"
  unset _MK_FRAMEWORK_UPDATED
}

# A fixture framework repo. With "with-update", it has libexec/machinekit-update,
# as every clone from this feature on does.
_mk_test_make_origin() {
  local with_update="${1:-}"
  mkdir -p "$origin_dir/bin" "$origin_dir/libexec" "$origin_dir/lib/bootstrap"
  cat > "$origin_dir/bin/machinekit" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" > "$calls_dir/machinekit"
EOF
  cat > "$origin_dir/lib/bootstrap/bash.sh" <<'EOF'
bootstrap::bash::ensure_modern_bash() { printf '%s\n' "$calls_dir/../fake-bash"; }
EOF
  cat > "$BATS_TEST_TMPDIR/fake-bash" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" > "$calls_dir/fake-bash"
EOF
  chmod +x "$origin_dir/bin/machinekit" "$BATS_TEST_TMPDIR/fake-bash"
  [ "$with_update" = "with-update" ] && : > "$origin_dir/libexec/machinekit-update"
  git init -q -b main "$origin_dir"
  git -C "$origin_dir" add -A
  git -C "$origin_dir" commit -q -m "fake framework"
}

@test "a fresh install clones the framework and hands off to its update command" {
  _mk_test_make_origin with-update
  run /bin/bash "$MACHINEKIT_DIR/install.sh" --no-modify-path
  [ "$status" -eq 0 ]
  [ -d "$MACHINEKIT_FRAMEWORK_DIR/.git" ]
  [ "$(cat "$calls_dir/machinekit")" = $'update\n--no-modify-path' ]
}

@test "a clone that already has the update command hands off without pulling" {
  _mk_test_make_origin with-update
  git clone -q "$origin_dir" "$MACHINEKIT_FRAMEWORK_DIR"
  printf 'new\n' > "$origin_dir/new.txt"
  git -C "$origin_dir" add new.txt
  git -C "$origin_dir" commit -q -m "newer"
  run /bin/bash "$MACHINEKIT_DIR/install.sh"
  [ "$status" -eq 0 ]
  [ ! -e "$MACHINEKIT_FRAMEWORK_DIR/new.txt" ]
  [ "$(cat "$calls_dir/machinekit")" = "update" ]
}

@test "a clone from before the update command is pulled once, then hands off to it" {
  _mk_test_make_origin
  git clone -q "$origin_dir" "$MACHINEKIT_FRAMEWORK_DIR"
  : > "$origin_dir/libexec/machinekit-update"
  git -C "$origin_dir" add -A
  git -C "$origin_dir" commit -q -m "add the update command"
  run /bin/bash "$MACHINEKIT_DIR/install.sh"
  [ "$status" -eq 0 ]
  [ -e "$MACHINEKIT_FRAMEWORK_DIR/libexec/machinekit-update" ]
  [ "$(cat "$calls_dir/machinekit")" = "update" ]
}

@test "the run an update starts does the install steps under the resolved bash" {
  _mk_test_make_origin with-update
  git clone -q "$origin_dir" "$MACHINEKIT_FRAMEWORK_DIR"
  _MK_FRAMEWORK_UPDATED=1 run /bin/bash "$MACHINEKIT_DIR/install.sh" --no-modify-path
  [ "$status" -eq 0 ]
  [ "$(cat "$calls_dir/fake-bash")" = "$MACHINEKIT_FRAMEWORK_DIR/libexec/machinekit-ensure-on-path"$'\n'"--no-modify-path" ]
  [ ! -e "$calls_dir/machinekit" ]
}
