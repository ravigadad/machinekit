#!/usr/bin/env bash
# Stub and assertion helpers for machinekit's bats test suite.
# Loaded by tests/test_helper.bash; requires jq (a machinekit prerequisite).
#
# Usage:
#   mktest::stub_function FUNC [EXPECTED_ARG...]
#   STUB_RETURN=1 STUB_OUTPUT="val" STUB_ERROR="msg" mktest::stub_function FUNC [ARG...]
#   mktest::assert_stub_called FUNC [EXPECTED_ARG...]
#   TIMES=2 mktest::assert_stub_called FUNC [EXPECTED_ARG...]
#   mktest::assert_stub_not_called FUNC [EXPECTED_ARG...]
#   TIMES=2 mktest::assert_stub_not_called FUNC [EXPECTED_ARG...]
#
# Stub configuration (env vars, all optional):
#   STUB_RETURN=N   return code when stub returns (default 0)
#   STUB_OUTPUT=str written to stdout when rule matches
#   STUB_ERROR=str  written to stderr when rule matches
#   STUB_EXIT=N     call exit N instead of return; use for exit-collaborators
#
# Assertion modifiers (env vars, all optional):
#   TIMES=N         assert called exactly N times
#   MATCH=regex     assert any recorded arg matches the regex (ERE); takes precedence over positional args
#
# Multiple calls to mktest::stub_function for the same FUNC append rules in
# order; the first matching rule wins. Calling without positional args creates
# a wildcard rule that matches any arguments.

# Internal: handles a call to a stubbed function at test runtime.
mktest::_dispatch_stub() {
  local func="$1"
  local stub_base="$2"
  shift 2

  local rules_file="${stub_base}.rules.json"
  local calls_file="${stub_base}.calls"

  # Record this invocation as a JSON array.
  local call_json
  call_json=$(jq -cn '$ARGS.positional' --args -- "$@")
  printf '%s\n' "$call_json" >> "$calls_file"

  if [ ! -f "$rules_file" ]; then
    printf 'stub: %s: no rules defined\n' "$func" >&2
    return 1
  fi

  # First matching rule wins: exact arg array match, or wildcard (expected: null).
  local match
  match=$(jq -c --argjson call "$call_json" \
    'first(.[] | select(.expected == null or .expected == $call)) // empty' \
    "$rules_file")

  if [ -z "$match" ]; then
    printf 'stub: %s: no rule matches args: %s\n' "$func" "$call_json" >&2
    return 1
  fi

  local out err retval exitcode
  out=$(printf '%s' "$match"      | jq -r '.out           // ""')
  err=$(printf '%s' "$match"      | jq -r '.err           // ""')
  retval=$(printf '%s' "$match"   | jq -r '.retval')
  exitcode=$(printf '%s' "$match" | jq -r '.exitcode // empty')

  [ -n "$out" ] && printf '%s\n' "$out"
  [ -n "$err" ] && printf '%s\n' "$err" >&2
  [ -n "$exitcode" ] && exit "$exitcode"
  return "$retval"
}

# mktest::stub_function FUNC [EXPECTED_ARG...]
mktest::stub_function() {
  local func="$1"
  local retval="${STUB_RETURN:-0}"
  local out="${STUB_OUTPUT:-}"
  local err="${STUB_ERROR:-}"
  local exitcode_json="null"
  [ -n "${STUB_EXIT:-}" ] && exitcode_json="${STUB_EXIT}"
  shift

  local stub_base="$BATS_TEST_TMPDIR/stub.${func//::/__}"
  local rules_file="${stub_base}.rules.json"
  local calls_file="${stub_base}.calls"

  local expected_json
  if [ $# -gt 0 ]; then
    expected_json=$(jq -cn '$ARGS.positional' --args -- "$@")
  else
    expected_json='null'
  fi

  local new_rule
  new_rule=$(jq -n \
    --argjson expected  "$expected_json" \
    --argjson retval    "$retval" \
    --arg     out       "$out" \
    --arg     err       "$err" \
    --argjson exitcode  "$exitcode_json" \
    '{expected: $expected, retval: $retval, out: $out, err: $err, exitcode: $exitcode}')

  if [ -f "$rules_file" ]; then
    local updated
    updated=$(jq --argjson rule "$new_rule" '. + [$rule]' "$rules_file")
    printf '%s\n' "$updated" > "$rules_file"
  else
    printf '[%s]\n' "$new_rule" > "$rules_file"
    printf '' > "$calls_file"
  fi

  eval "${func}() { mktest::_dispatch_stub '${func}' '${stub_base}' \"\$@\"; }"
}

# Internal: prints the call count for a stub to stdout.
# Returns 1 (with error to stderr) if the function was never stubbed.
mktest::_stub_call_count() {
  local func="$1"; shift
  local calls_file="$BATS_TEST_TMPDIR/stub.${func//::/__}.calls"
  if [ ! -f "$calls_file" ]; then
    printf 'stub: %s was never stubbed\n' "$func" >&2
    return 1
  fi
  if [ -n "${MATCH:-}" ]; then
    jq -s --arg regex "$MATCH" '[.[] | select(any(.[]; test($regex)))] | length' "$calls_file"
  elif [ $# -gt 0 ]; then
    local expected_json
    expected_json=$(jq -cn '$ARGS.positional' --args -- "$@")
    jq -s --argjson exp "$expected_json" '[.[] | select(. == $exp)] | length' "$calls_file"
  else
    wc -l < "$calls_file" | tr -d ' '
  fi
}

# mktest::assert_stub_called FUNC [EXPECTED_ARG...]
mktest::assert_stub_called() {
  local func="$1"; shift
  local times="${TIMES:-}"
  local count
  count=$(mktest::_stub_call_count "$func" "$@") || return 1
  if [ -n "$times" ]; then
    [ "$count" -eq "$times" ] || {
      printf 'assert_stub_called: %s: expected %s call(s), got %s\n' "$func" "$times" "$count" >&2
      return 1
    }
  else
    [ "$count" -gt 0 ] || {
      if [ -n "${MATCH:-}" ]; then
        printf 'assert_stub_called: %s was never called with args matching /%s/\n' "$func" "$MATCH" >&2
      else
        printf 'assert_stub_called: %s was never called\n' "$func" >&2
      fi
      return 1
    }
  fi
}

# mktest::assert_stub_not_called FUNC [EXPECTED_ARG...]
mktest::assert_stub_not_called() {
  local func="$1"; shift
  local times="${TIMES:-}"
  local count
  count=$(mktest::_stub_call_count "$func" "$@") || return 1
  if [ -n "$times" ]; then
    [ "$count" -ne "$times" ] || {
      printf 'assert_stub_not_called: %s: was called exactly %s time(s)\n' "$func" "$times" >&2
      return 1
    }
  else
    [ "$count" -eq 0 ] || {
      printf 'assert_stub_not_called: %s was called %s time(s)\n' "$func" "$count" >&2
      return 1
    }
  fi
}
