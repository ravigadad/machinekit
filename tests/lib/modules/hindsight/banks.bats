#!/usr/bin/env bats
# Tests for lib/modules/hindsight/banks.sh

load "${BATS_TEST_DIRNAME}/../../../test_helper"

setup() {
  # shellcheck source=../../../../lib/modules/hindsight/banks.sh
  source "$MACHINEKIT_DIR/lib/modules/hindsight/banks.sh"
}

# --- server_reachable ---

@test "server_reachable is true when the health probe succeeds" {
  curl() { printf '%s\n' "$@" > "$BATS_TEST_TMPDIR/curl.args"; }
  hindsight::banks::server_reachable "http://memory-server:8888/"
  run cat "$BATS_TEST_TMPDIR/curl.args"
  # Trailing slash is stripped; /health is probed.
  [[ "$output" == *"http://memory-server:8888/health"* ]]
}

@test "server_reachable is false when the health probe fails" {
  curl() { return 1; }
  run hindsight::banks::server_reachable "http://memory-server:8888"
  [ "$status" -ne 0 ]
}

# --- configure ---

@test "configure PATCHes the bank's /config endpoint with the fields wrapped in an updates envelope" {
  mktest::stub_function hindsight::banks::_http_patch
  hindsight::banks::configure "http://memory-server:8888" "tok-123" "default" "music" '{"retain_mission":"m"}'
  mktest::assert_stub_called hindsight::banks::_http_patch \
    "http://memory-server:8888/v1/default/banks/music/config" "tok-123" '{"updates":{"retain_mission":"m"}}'
}

@test "configure strips a trailing slash from the base url" {
  mktest::stub_function hindsight::banks::_http_patch
  hindsight::banks::configure "http://memory-server:8888/" "tok-123" "default" "music" '{"retain_mission":"m"}'
  mktest::assert_stub_called hindsight::banks::_http_patch \
    "http://memory-server:8888/v1/default/banks/music/config" "tok-123" '{"updates":{"retain_mission":"m"}}'
}

@test "configure fails loudly when the patch fails" {
  STUB_RETURN=1 mktest::stub_function hindsight::banks::_http_patch
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run hindsight::banks::configure "http://memory-server:8888" "tok-123" "default" "music" '{"retain_mission":"m"}'
  [ "$status" -ne 0 ]
  MATCH="failed to configure bank 'music'" mktest::assert_stub_called lifecycle::fail
}

# --- _http_patch (the live-API seam) ---

@test "_http_patch PATCHes the endpoint, keeping the bearer off argv and on stdin" {
  # Capture both argv and stdin so we can assert the token is NOT in argv.
  curl() { printf '%s\n' "$@" > "$BATS_TEST_TMPDIR/curl.args"; cat > "$BATS_TEST_TMPDIR/curl.stdin"; }
  hindsight::banks::_http_patch \
    "http://memory-server:8888/v1/default/banks/music/config" "tok-123" '{"retain_mission":"m"}'
  run cat "$BATS_TEST_TMPDIR/curl.args"
  [[ "$output" == *"PATCH"* ]]
  [[ "$output" == *"Content-Type: application/json"* ]]
  [[ "$output" == *'{"retain_mission":"m"}'* ]]
  [[ "$output" == *"http://memory-server:8888/v1/default/banks/music/config"* ]]
  # The bearer token must not appear in the process argv.
  [[ "$output" != *"tok-123"* ]]
  # It is fed via stdin instead.
  run cat "$BATS_TEST_TMPDIR/curl.stdin"
  [ "$output" = "Authorization: Bearer tok-123" ]
}
