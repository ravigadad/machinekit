#!/usr/bin/env bats
# Tests for lib/machinekit/secrets/put.sh — the `put` use-case.

load "${BATS_TEST_DIRNAME}/../../../test_helper"

setup() {
  # shellcheck source=../../../../lib/machinekit/secrets/put.sh
  source "$MACHINEKIT_DIR/lib/machinekit/secrets/put.sh"
  mktest::stub_function logging::info
  mktest::stub_function logging::success
  mktest::stub_function preflight::resolve_inputs
}

# --- secrets::put (use-case orchestrator) ---

@test "put resolves the dest, confirms overwrite, then encrypts a plaintext source" {
  STUB_OUTPUT="fake-target" mktest::stub_function secrets::put::_target
  STUB_OUTPUT="fake-dest" mktest::stub_function secrets::dest_path "fake-target"
  mktest::stub_function secrets::put::_confirm_overwrite "fake-dest"
  mktest::stub_function secrets::put::_from_plaintext "" "fake-dest"
  mktest::stub_function secrets::put::_from_encrypted
  secrets::put "" ""
  mktest::assert_stub_called_in_order secrets::dest_path "fake-target"
  mktest::assert_stub_called_in_order secrets::put::_confirm_overwrite "fake-dest"
  mktest::assert_stub_called_in_order secrets::put::_from_plaintext "" "fake-dest"
  mktest::assert_stub_not_called secrets::put::_from_encrypted
  # With a target resolved up front, the blueprint is never fetched.
  mktest::assert_stub_not_called preflight::resolve_inputs
}

@test "put files an already-encrypted source as-is via _from_encrypted" {
  STUB_OUTPUT="fake-target" mktest::stub_function secrets::put::_target
  STUB_OUTPUT="fake-dest" mktest::stub_function secrets::dest_path "fake-target"
  mktest::stub_function secrets::put::_confirm_overwrite "fake-dest"
  mktest::stub_function age::is_encrypted_file "/fake/secret.age"   # recognized as encrypted
  mktest::stub_function secrets::put::_from_encrypted "/fake/secret.age" "fake-dest"
  mktest::stub_function secrets::put::_from_plaintext
  secrets::put "" "/fake/secret.age"
  mktest::assert_stub_called secrets::put::_from_encrypted "/fake/secret.age" "fake-dest"
  mktest::assert_stub_not_called secrets::put::_from_plaintext
}

@test "put encrypts a plaintext file source via _from_plaintext" {
  STUB_OUTPUT="fake-target" mktest::stub_function secrets::put::_target
  STUB_OUTPUT="fake-dest" mktest::stub_function secrets::dest_path "fake-target"
  mktest::stub_function secrets::put::_confirm_overwrite "fake-dest"
  STUB_RETURN=1 mktest::stub_function age::is_encrypted_file "/fake/plain.txt"   # not an age file
  mktest::stub_function secrets::put::_from_plaintext "/fake/plain.txt" "fake-dest"
  mktest::stub_function secrets::put::_from_encrypted
  secrets::put "" "/fake/plain.txt"
  mktest::assert_stub_called secrets::put::_from_plaintext "/fake/plain.txt" "fake-dest"
  mktest::assert_stub_not_called secrets::put::_from_encrypted
}

@test "put resolves inputs in the main shell then picks when no target is given" {
  STUB_OUTPUT="" mktest::stub_function secrets::put::_target
  mktest::stub_function input::is_interactive
  STUB_OUTPUT="secrets/picked.age" mktest::stub_function secrets::put::_pick
  STUB_OUTPUT="fake-dest" mktest::stub_function secrets::dest_path "secrets/picked.age"
  mktest::stub_function secrets::put::_confirm_overwrite "fake-dest"
  mktest::stub_function secrets::put::_from_plaintext "" "fake-dest"
  secrets::put "" ""
  # resolve_inputs (which arms cleanup traps) runs before the pick, not inside its $().
  mktest::assert_stub_called_in_order preflight::resolve_inputs
  mktest::assert_stub_called_in_order secrets::put::_pick
  mktest::assert_stub_called secrets::put::_from_plaintext "" "fake-dest"
}

@test "put fails when no target is given and not interactive" {
  STUB_OUTPUT="" mktest::stub_function secrets::put::_target
  STUB_RETURN=1 mktest::stub_function input::is_interactive
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run ! secrets::put "" ""
  MATCH="no target" mktest::assert_stub_called lifecycle::fail
}

# --- secrets::put::_from_plaintext ---

@test "_from_plaintext resolves the recipient, reads the value, and encrypts to the dest" {
  STUB_OUTPUT="fake-recipient" mktest::stub_function secrets::put::_recipient
  STUB_OUTPUT="plaintext" mktest::stub_function secrets::put::_read_value ""
  mktest::stub_function secrets::place "fake-recipient" "fake-dest"
  secrets::put::_from_plaintext "" "fake-dest"
  mktest::assert_stub_called_in_order secrets::put::_recipient
  mktest::assert_stub_called_in_order secrets::place "fake-recipient" "fake-dest"
  mktest::assert_stub_called secrets::put::_read_value ""
}

@test "_from_plaintext never places a secret when the value read fails" {
  STUB_OUTPUT="fake-recipient" mktest::stub_function secrets::put::_recipient
  STUB_EXIT=1 mktest::stub_function secrets::put::_read_value ""
  mktest::stub_function secrets::place "fake-recipient" "fake-dest"
  run ! secrets::put::_from_plaintext "" "fake-dest"
  # A failed read must abort before any encryption — otherwise place writes an
  # empty secret (the value would flow to place concurrently in a naive pipe).
  mktest::assert_stub_not_called secrets::place "fake-recipient" "fake-dest"
}

@test "_from_plaintext refuses to write an empty value rather than clobber" {
  STUB_OUTPUT="fake-recipient" mktest::stub_function secrets::put::_recipient
  STUB_OUTPUT="" mktest::stub_function secrets::put::_read_value ""
  mktest::stub_function secrets::place "fake-recipient" "fake-dest"
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run ! secrets::put::_from_plaintext "" "fake-dest"
  MATCH="empty secret" mktest::assert_stub_called lifecycle::fail
  mktest::assert_stub_not_called secrets::place "fake-recipient" "fake-dest"
}

# --- secrets::put::_from_encrypted ---

@test "_from_encrypted verifies the local key can decrypt, then copies the file as-is" {
  STUB_RETURN=1 mktest::stub_function context::get "secrets.recipient"   # no --recipient override
  mktest::stub_function age::can_decrypt "/fake/secret.age"
  mktest::stub_function secrets::place_file "/fake/secret.age" "fake-dest"
  secrets::put::_from_encrypted "/fake/secret.age" "fake-dest"
  mktest::assert_stub_called_in_order age::can_decrypt "/fake/secret.age"
  mktest::assert_stub_called_in_order secrets::place_file "/fake/secret.age" "fake-dest"
}

@test "_from_encrypted fails clearly on inability to decrypt, and does not copy" {
  STUB_RETURN=1 mktest::stub_function context::get "secrets.recipient"
  STUB_RETURN=1 mktest::stub_function age::can_decrypt "/fake/secret.age"
  mktest::stub_function secrets::place_file "/fake/secret.age" "fake-dest"
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run ! secrets::put::_from_encrypted "/fake/secret.age" "fake-dest"
  MATCH="can't decrypt" mktest::assert_stub_called lifecycle::fail
  mktest::assert_stub_not_called secrets::place_file "/fake/secret.age" "fake-dest"
}

@test "_from_encrypted rejects a --recipient override rather than copy silently" {
  STUB_OUTPUT="age1override" mktest::stub_function context::get "secrets.recipient"
  mktest::stub_function age::can_decrypt
  mktest::stub_function secrets::place_file
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run ! secrets::put::_from_encrypted "/fake/secret.age" "fake-dest"
  MATCH="retarget" mktest::assert_stub_called lifecycle::fail
  mktest::assert_stub_not_called age::can_decrypt
  mktest::assert_stub_not_called secrets::place_file
}

# --- secrets::put::_recipient ---

@test "_recipient uses the explicit override when set" {
  STUB_OUTPUT="age1override" mktest::stub_function context::get "secrets.recipient"
  mktest::stub_function age::recipient
  run secrets::put::_recipient
  [ "$output" = "age1override" ]
  mktest::assert_stub_not_called age::recipient
}

@test "_recipient derives from the installed key when no override is set" {
  STUB_RETURN=1 mktest::stub_function context::get "secrets.recipient"
  STUB_OUTPUT="age1derived" mktest::stub_function age::recipient
  run secrets::put::_recipient
  [ "$output" = "age1derived" ]
}

# --- secrets::put::_target ---

@test "_target prefers the positional argument" {
  run secrets::put::_target "secrets/from/positional.age"
  [ "$output" = "secrets/from/positional.age" ]
}

@test "_target falls back to the env-resolved path when the argument is empty" {
  STUB_OUTPUT="secrets/from/env.age" mktest::stub_function context::get "secrets.path"
  run secrets::put::_target ""
  [ "$output" = "secrets/from/env.age" ]
}

@test "_target is empty when neither the argument nor the env is set" {
  STUB_RETURN=1 mktest::stub_function context::get "secrets.path"
  run secrets::put::_target ""
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- secrets::put::_pick ---

@test "_pick returns the inventory row the user selects" {
  STUB_OUTPUT=$'secrets/a.age\ttrue\tfalse\tmissing\nsecrets/b.age\ttrue\ttrue\tprovided' \
    mktest::stub_function secrets::inventory
  printf '2\n' > "$BATS_TEST_TMPDIR/tty"
  MACHINEKIT_TTY="$BATS_TEST_TMPDIR/tty" run --separate-stderr secrets::put::_pick
  [ "$status" -eq 0 ]
  [ "$output" = "secrets/b.age" ]
}

@test "_pick fails on an out-of-range selection" {
  STUB_OUTPUT=$'secrets/a.age\ttrue\tfalse\tmissing' mktest::stub_function secrets::inventory
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  printf '9\n' > "$BATS_TEST_TMPDIR/tty"
  MACHINEKIT_TTY="$BATS_TEST_TMPDIR/tty" run ! secrets::put::_pick
  MATCH="invalid selection" mktest::assert_stub_called lifecycle::fail
}

# --- secrets::put::_confirm_overwrite ---

@test "_confirm_overwrite is a no-op when the dest does not exist" {
  mktest::stub_function context::get "secrets.overwrite"
  secrets::put::_confirm_overwrite "$BATS_TEST_TMPDIR/absent.age"
  mktest::assert_stub_not_called context::get "secrets.overwrite"
}

@test "_confirm_overwrite passes when overwrite is confirmed" {
  local dest="$BATS_TEST_TMPDIR/exists.age"; : > "$dest"
  STUB_OUTPUT="true" mktest::stub_function context::get "secrets.overwrite" "--coerce" "boolean" "--default" "false" "--prompt" "Overwrite the existing secret at $dest? (y/n)"
  secrets::put::_confirm_overwrite "$dest"
}

@test "_confirm_overwrite fails when overwrite is declined" {
  local dest="$BATS_TEST_TMPDIR/exists.age"; : > "$dest"
  STUB_OUTPUT="false" mktest::stub_function context::get "secrets.overwrite" "--coerce" "boolean" "--default" "false" "--prompt" "Overwrite the existing secret at $dest? (y/n)"
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run ! secrets::put::_confirm_overwrite "$dest"
  MATCH="not overwritten" mktest::assert_stub_called lifecycle::fail
}

# --- secrets::put::_read_value ---

@test "_read_value prefers --from-file even when stdin looks piped" {
  STUB_RETURN=1 mktest::stub_function input::stdin_is_tty   # stdin looks piped (non-tty)
  printf 'file-secret' > "$BATS_TEST_TMPDIR/val"
  run secrets::put::_read_value "$BATS_TEST_TMPDIR/val" <<< "stdin-secret"
  # The explicit flag wins: in a script, non-tty stdin must not shadow --from-file.
  [ "$output" = "file-secret" ]
}

@test "_read_value forwards piped stdin when no file is given" {
  STUB_RETURN=1 mktest::stub_function input::stdin_is_tty   # non-tty stdin: a value was piped in
  run secrets::put::_read_value "" <<< "piped-secret"
  [ "$output" = "piped-secret" ]
}

@test "_read_value prompts interactively when stdin is a tty and no file is given" {
  mktest::stub_function input::stdin_is_tty   # stdin is a tty
  mktest::stub_function input::is_interactive
  STUB_OUTPUT="prompted-secret" mktest::stub_function secrets::put::_prompt_value
  run secrets::put::_read_value ""
  [ "$output" = "prompted-secret" ]
}

@test "_read_value fails non-interactively with neither stdin nor a file" {
  mktest::stub_function input::stdin_is_tty   # stdin is a tty, so nothing was piped
  STUB_RETURN=1 mktest::stub_function input::is_interactive
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run ! secrets::put::_read_value ""
  MATCH="no value" mktest::assert_stub_called lifecycle::fail
}

# --- secrets::put::_prompt_value ---

@test "_prompt_value reads the value from the tty without echoing it" {
  printf 'tty-secret\n' > "$BATS_TEST_TMPDIR/tty"
  MACHINEKIT_TTY="$BATS_TEST_TMPDIR/tty" run --separate-stderr secrets::put::_prompt_value
  [ "$status" -eq 0 ]
  [ "$output" = "tty-secret" ]
}
