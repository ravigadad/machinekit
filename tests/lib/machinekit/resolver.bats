#!/usr/bin/env bats
# Tests for lib/machinekit/resolver.sh

load "${BATS_TEST_DIRNAME}/../../test_helper"

setup() {
  # shellcheck source=../../../lib/machinekit/resolver.sh
  source "$MACHINEKIT_DIR/lib/machinekit/resolver.sh"
  unset _MK_RESOLVER_LOADED
}

# --- load guard ---

@test "sourcing twice does not redefine functions" {
  resolver::resolve() { echo "original"; }
  _MK_RESOLVER_LOADED=1
  source "$MACHINEKIT_DIR/lib/machinekit/resolver.sh"
  [ "$(resolver::resolve)" = "original" ]
}

# --- resolver::resolve ---

@test "resolve with no arguments outputs nothing" {
  result=$(resolver::resolve)
  [ -z "$result" ]
}

@test "resolve outputs a module with no dependencies" {
  result=$(resolver::resolve alpha)
  [ "$result" = "alpha" ]
}

@test "resolve outputs dependency before dependent" {
  alpha::requires() { printf 'beta\n'; }
  result=$(resolver::resolve alpha)
  [ "$result" = $'beta\nalpha' ]
}

@test "resolve handles transitive dependencies in order" {
  alpha::requires() { printf 'beta\n'; }
  beta::requires()  { printf 'gamma\n'; }
  result=$(resolver::resolve alpha)
  gamma_line=$(printf '%s\n' "$result" | grep -n '^gamma$' | cut -d: -f1)
  beta_line=$(printf '%s\n'  "$result" | grep -n '^beta$'  | cut -d: -f1)
  alpha_line=$(printf '%s\n' "$result" | grep -n '^alpha$' | cut -d: -f1)
  [ "$gamma_line" -lt "$beta_line" ]
  [ "$beta_line"  -lt "$alpha_line" ]
}

@test "resolve deduplicates a shared dependency" {
  alpha::requires() { printf 'beta\ngamma\n'; }
  beta::requires()  { printf 'delta\n'; }
  gamma::requires() { printf 'delta\n'; }
  result=$(resolver::resolve alpha)
  count=$(printf '%s\n' "$result" | grep -c '^delta$')
  [ "$count" -eq 1 ]
}

@test "resolve includes all requested modules in output" {
  result=$(resolver::resolve alpha beta)
  printf '%s\n' "$result" | grep -q '^alpha$'
  printf '%s\n' "$result" | grep -q '^beta$'
}

@test "resolve treats a module with no ::requires function as having no dependencies" {
  result=$(resolver::resolve standalone)
  [ "$result" = "standalone" ]
}

@test "resolve detects and fails on circular dependencies" {
  alpha::requires() { printf 'beta\n'; }
  beta::requires()  { printf 'alpha\n'; }
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run resolver::resolve alpha
  [ "$status" -ne 0 ]
  MATCH="circular" mktest::assert_stub_called lifecycle::fail
}
