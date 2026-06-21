#!/usr/bin/env bats
# Tests for lib/machinekit/managed_block.sh — maintaining a delimited,
# machinekit-owned block within a file, reconciled each run, while leaving
# content outside the block untouched. Pure file I/O; no collaborators to stub.
#
# The helper's contract is the exact file it produces, so each test diffs the
# whole file against an inline (unquoted) heredoc.

load "${BATS_TEST_DIRNAME}/../../test_helper"

setup() {
  # shellcheck source=../../../lib/machinekit/managed_block.sh
  source "$MACHINEKIT_DIR/lib/machinekit/managed_block.sh"
  FILE="$BATS_TEST_TMPDIR/ignore"
}

@test "begin and end markers are distinct" {
  [ "$_MK_MANAGED_BLOCK_BEGIN_MARKER" != "$_MK_MANAGED_BLOCK_END_MARKER" ]
}

# --- creating the file ---

@test "creates the file with a block when it is absent" {
  printf '%s\n' "a" "b" | managed_block::ensure "$FILE" "#"
  diff "$FILE" - <<EOF
# $_MK_MANAGED_BLOCK_BEGIN_MARKER
a
b
# $_MK_MANAGED_BLOCK_END_MARKER
EOF
}

@test "uses the given comment prefix in the markers" {
  printf '%s\n' "(?d).DS_Store" | managed_block::ensure "$FILE" "//"
  diff "$FILE" - <<EOF
// $_MK_MANAGED_BLOCK_BEGIN_MARKER
(?d).DS_Store
// $_MK_MANAGED_BLOCK_END_MARKER
EOF
}

@test "writes empty delimiters when the body is empty" {
  printf '' | managed_block::ensure "$FILE" "#"
  diff "$FILE" - <<EOF
# $_MK_MANAGED_BLOCK_BEGIN_MARKER
# $_MK_MANAGED_BLOCK_END_MARKER
EOF
}

# --- preserving surrounding content ---

@test "append a block to an existing file, preserving its content" {
  printf '%s\n' "# my own ignores" "secret.key" > "$FILE"
  printf '%s\n' "a" | managed_block::ensure "$FILE" "#"
  diff "$FILE" - <<EOF
# my own ignores
secret.key
# $_MK_MANAGED_BLOCK_BEGIN_MARKER
a
# $_MK_MANAGED_BLOCK_END_MARKER
EOF
}

@test "replaces the block in place, keeping its position above following content" {
  managed_block::ensure "$FILE" "#" <<< "old1"
  printf '%s\n' "keep-after" >> "$FILE"
  managed_block::ensure "$FILE" "#" <<< "new1"
  diff "$FILE" - <<EOF
# $_MK_MANAGED_BLOCK_BEGIN_MARKER
new1
# $_MK_MANAGED_BLOCK_END_MARKER
keep-after
EOF
}

# --- non-destructive on a malformed file ---

@test "drops a stray begin marker rather than eating the content after it" {
  printf '%s\n' "# $_MK_MANAGED_BLOCK_BEGIN_MARKER" "orphan" "important-after" > "$FILE"
  printf '%s\n' "a" | managed_block::ensure "$FILE" "#"
  diff "$FILE" - <<EOF
orphan
important-after
# $_MK_MANAGED_BLOCK_BEGIN_MARKER
a
# $_MK_MANAGED_BLOCK_END_MARKER
EOF
}

# --- idempotency (a property of repeated runs, not a single output) ---

@test "is idempotent across repeated runs with the same content" {
  printf '%s\n' "a" "b" | managed_block::ensure "$FILE" "#"
  cp "$FILE" "$BATS_TEST_TMPDIR/first"
  printf '%s\n' "a" "b" | managed_block::ensure "$FILE" "#"
  diff "$BATS_TEST_TMPDIR/first" "$FILE"
}
