#!/usr/bin/env bats
# Tests for lib/machinekit/resolver.sh

load "${BATS_TEST_DIRNAME}/../../test_helper"

setup() {
  # shellcheck source=../../../lib/machinekit/resolver.sh
  source "$MACHINEKIT_DIR/lib/machinekit/resolver.sh"
  unset _MK_RESOLVER_LOADED

  # Prevent real module files from loading in resolver tests; capability
  # functions are defined inline per-test.
  mktest::stub_function modules::source_all
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

# --- after edges (soft ordering) ---

@test "resolve orders a module after an active after-target" {
  alpha::after() { printf 'beta\n'; }
  result=$(resolver::resolve alpha beta)
  alpha_line=$(printf '%s\n' "$result" | grep -n '^alpha$' | cut -d: -f1)
  beta_line=$(printf '%s\n'  "$result" | grep -n '^beta$'  | cut -d: -f1)
  [ "$beta_line" -lt "$alpha_line" ]
}

@test "resolve ignores an after edge to an inactive module and never activates it" {
  alpha::after() { printf 'beta\n'; }
  result=$(resolver::resolve alpha)
  [ "$result" = "alpha" ]
}

@test "resolve orders a module after a transitively-active after-target" {
  alpha::after()   { printf 'gamma\n'; }
  beta::requires() { printf 'gamma\n'; }
  result=$(resolver::resolve alpha beta)
  gamma_line=$(printf '%s\n' "$result" | grep -n '^gamma$' | cut -d: -f1)
  alpha_line=$(printf '%s\n' "$result" | grep -n '^alpha$' | cut -d: -f1)
  [ "$gamma_line" -lt "$alpha_line" ]
}

@test "resolve detects a cycle formed by an after edge" {
  alpha::requires() { printf 'beta\n'; }
  beta::after()     { printf 'alpha\n'; }
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run resolver::resolve alpha
  [ "$status" -ne 0 ]
  MATCH="circular" mktest::assert_stub_called lifecycle::fail
}

# --- capability expansion ---

@test "resolve pulls in the default satisfier when a capability is listed" {
  cap::is_capability()      { return 0; }
  cap::default_satisfier()  { printf 'sat\n'; }
  cap::requires()           { cap::default_satisfier; }
  cap::install()            { :; }
  result=$(resolver::resolve cap)
  printf '%s\n' "$result" | grep -q '^sat$'
  printf '%s\n' "$result" | grep -q '^cap$'
}

@test "resolve lists default satisfier before the capability module" {
  cap::is_capability()     { return 0; }
  cap::default_satisfier() { printf 'sat\n'; }
  cap::requires()          { cap::default_satisfier; }
  cap::install()           { :; }
  result=$(resolver::resolve cap)
  sat_line=$(printf '%s\n' "$result" | grep -n '^sat$' | cut -d: -f1)
  cap_line=$(printf '%s\n' "$result" | grep -n '^cap$' | cut -d: -f1)
  [ "$sat_line" -lt "$cap_line" ]
}

@test "resolve uses explicit satisfier over default when both are listed" {
  cap::is_capability()     { return 0; }
  cap::default_satisfier() { printf 'default_sat\n'; }
  cap::requires()          { cap::default_satisfier; }
  cap::install()           { :; }
  explicit_sat::provides() { printf 'cap\n'; }
  explicit_sat::install()  { :; }
  result=$(resolver::resolve cap explicit_sat)
  printf '%s\n' "$result" | grep -q '^explicit_sat$'
  count=$(printf '%s\n' "$result" | grep -c '^default_sat$' || true)
  [ "$count" -eq 0 ]
}

@test "resolve does not duplicate satisfier when listed explicitly alongside capability" {
  cap::is_capability()     { return 0; }
  cap::default_satisfier() { printf 'sat\n'; }
  cap::requires()          { cap::default_satisfier; }
  cap::install()           { :; }
  sat::provides()          { printf 'cap\n'; }
  sat::install()           { :; }
  result=$(resolver::resolve cap sat)
  count=$(printf '%s\n' "$result" | grep -c '^sat$')
  [ "$count" -eq 1 ]
}

# --- conflict detection ---

@test "resolve fails when two satisfiers claim the same capability" {
  sat_a::provides() { printf 'cap\n'; }
  sat_b::provides() { printf 'cap\n'; }
  sat_a::install()  { :; }
  sat_b::install()  { :; }
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run resolver::resolve sat_a sat_b
  [ "$status" -ne 0 ]
  MATCH="cap" mktest::assert_stub_called lifecycle::fail
}

@test "resolve allows multiple satisfiers for the same capability when configured" {
  sat_a::provides() { printf 'cap\n'; }
  sat_b::provides() { printf 'cap\n'; }
  sat_a::install()  { :; }
  sat_b::install()  { :; }
  STUB_OUTPUT="true" mktest::stub_function config::get \
    "capability.cap.allow_multiple_satisfiers"
  result=$(resolver::resolve sat_a sat_b)
  printf '%s\n' "$result" | grep -q '^sat_a$'
  printf '%s\n' "$result" | grep -q '^sat_b$'
}
