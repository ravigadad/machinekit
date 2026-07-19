#!/usr/bin/env bats
# Tests for lib/machinekit/postflight.sh

load "${BATS_TEST_DIRNAME}/../../test_helper"

setup() {
  # shellcheck source=../../../lib/machinekit/postflight.sh
  source "$MACHINEKIT_DIR/lib/machinekit/postflight.sh"

  # Logging and output collaborators — allow-only; they are mechanism. The
  # module header and fact lines ARE user-facing contract, so those are asserted
  # by the identifying token (module name / fact text), not the exact wording.
  mktest::stub_function logging::success
  mktest::stub_function logging::info
  mktest::stub_function logging::dry_run
  mktest::stub_function logging::step
}

# --- double-source guard ---

@test "sourcing a second time is a no-op" {
  # Re-sourcing with the guard already set must not redefine functions or error.
  _MK_POSTFLIGHT_LOADED=1
  source "$MACHINEKIT_DIR/lib/machinekit/postflight.sh"
}

# --- postflight::_module_group ---

@test "_module_group prints the heading once, then each emitting module's header and facts, in module order" {
  STUB_OUTPUT=$'fake_a\nfake_b' mktest::stub_function context::get_array modules.active
  fake_a::pf_info() { printf 'alpha configured a thing\n'; }
  fake_b::pf_info() { printf 'beta configured a thing\n'; }

  postflight::_module_group pf_info "Group Title" ""

  TIMES=1 mktest::assert_stub_called logging::step "Group Title"
  MATCH="fake_a" mktest::assert_stub_called logging::info
  MATCH="alpha configured a thing" mktest::assert_stub_called logging::info
  MATCH="fake_b" mktest::assert_stub_called logging::info
  MATCH="beta configured a thing" mktest::assert_stub_called logging::info
  # Info module headers come out in modules.active order.
  mktest::assert_stub_called_in_order logging::info "fake_a"
  mktest::assert_stub_called_in_order logging::info "fake_b"
}

@test "_module_group indents fact lines under the module header" {
  STUB_OUTPUT=$'fake_a' mktest::stub_function context::get_array modules.active
  fake_a::pf_info() { printf 'a configured fact\n'; }

  postflight::_module_group pf_info "Group Title" ""

  mktest::assert_stub_called logging::info "  a configured fact"
}

@test "_module_group prints every line of a multi-line hook" {
  STUB_OUTPUT=$'fake_a' mktest::stub_function context::get_array modules.active
  fake_a::pf_info() { printf 'line one\nline two\n'; }

  postflight::_module_group pf_info "Group Title" ""

  mktest::assert_stub_called logging::info "  line one"
  mktest::assert_stub_called logging::info "  line two"
}

@test "_module_group wraps the module header in the group's color, reset after" {
  STUB_OUTPUT=$'fake_a' mktest::stub_function context::get_array modules.active
  fake_a::pf_info() { printf 'a fact\n'; }

  postflight::_module_group pf_info "Group Title" "<color>"

  # The color prefix wraps only the header, not the facts.
  mktest::assert_stub_called logging::info "<color>fake_a${MK_COLOR_RESET}"
}

@test "_module_group skips a module that does not define the hook" {
  STUB_OUTPUT=$'fake_a\nfake_b' mktest::stub_function context::get_array modules.active
  # fake_a defines no pf_info hook.
  fake_b::pf_info() { printf 'beta configured a thing\n'; }

  postflight::_module_group pf_info "Group Title" ""

  MATCH="fake_a" mktest::assert_stub_not_called logging::info
  MATCH="fake_b" mktest::assert_stub_called logging::info
}

@test "_module_group skips a module whose hook emits nothing" {
  STUB_OUTPUT=$'fake_a\nfake_b' mktest::stub_function context::get_array modules.active
  fake_a::pf_info() { return 0; }
  fake_b::pf_info() { printf 'beta configured a thing\n'; }

  postflight::_module_group pf_info "Group Title" ""

  MATCH="fake_a" mktest::assert_stub_not_called logging::info
  MATCH="fake_b" mktest::assert_stub_called logging::info
}

@test "_module_group prints no heading when no module emits" {
  STUB_OUTPUT=$'fake_a' mktest::stub_function context::get_array modules.active
  fake_a::pf_info() { return 0; }

  postflight::_module_group pf_info "Group Title" ""

  mktest::assert_stub_not_called logging::step
  mktest::assert_stub_not_called logging::info
}

# --- postflight::run ---

@test "run in dry-run mode logs the dry-run message and baseline, skips the walks + exec hint" {
  mktest::stub_function input::is_dry_run
  mktest::stub_function postflight::_print_baseline
  mktest::stub_function postflight::_print_exec_hint
  mktest::stub_function postflight::_module_group

  postflight::run

  MATCH="dry.run" mktest::assert_stub_called logging::dry_run
  mktest::assert_stub_called postflight::_print_baseline
  mktest::assert_stub_not_called postflight::_module_group
  mktest::assert_stub_not_called postflight::_print_exec_hint
}

@test "run in real mode prints the baseline, walks info then instructions, then logs success and the exec hint" {
  STUB_RETURN=1 mktest::stub_function input::is_dry_run
  mktest::stub_function postflight::_print_baseline
  mktest::stub_function postflight::_print_exec_hint
  mktest::stub_function postflight::_module_group

  postflight::run

  MATCH="apply complete" mktest::assert_stub_called logging::success
  # The whole cascade is the contract: baseline → info walk → instructions walk → exec hint.
  mktest::assert_stub_called_in_order postflight::_print_baseline
  mktest::assert_stub_called_in_order postflight::_module_group \
    postflight_info "$_MK_POSTFLIGHT_INFO_HEADING" "$_MK_POSTFLIGHT_INFO_MODULE_COLOR"
  mktest::assert_stub_called_in_order postflight::_module_group \
    postflight_instructions "$_MK_POSTFLIGHT_INSTRUCTIONS_HEADING" "$_MK_POSTFLIGHT_INSTRUCTIONS_MODULE_COLOR"
  mktest::assert_stub_called_in_order postflight::_print_exec_hint
}

# --- postflight::_print_baseline ---

@test "_print_baseline reports machine type, active-module count, and files synced" {
  STUB_RETURN=1 mktest::stub_function input::is_dry_run
  STUB_OUTPUT=server mktest::stub_function context::get machine_type --default "(none)"
  STUB_OUTPUT=7 mktest::stub_function context::get home.files_synced --default 0
  STUB_OUTPUT=$'git\nzsh\ntailscale' mktest::stub_function context::get_array modules.active

  postflight::_print_baseline

  MATCH="server" mktest::assert_stub_called logging::info
  MATCH="3" mktest::assert_stub_called logging::info
  MATCH="home files synced:  7" mktest::assert_stub_called logging::info
}

# The absent-value fallbacks now ride context::get's --default (asserted by the
# exact-arg stubs above), so they are context.sh's contract, not re-tested here.

@test "_print_baseline labels the count 'to sync' in dry-run, never 'synced'" {
  mktest::stub_function input::is_dry_run
  STUB_OUTPUT=server mktest::stub_function context::get machine_type --default "(none)"
  STUB_OUTPUT=7 mktest::stub_function context::get home.files_synced --default 0
  STUB_OUTPUT=$'git' mktest::stub_function context::get_array modules.active

  postflight::_print_baseline

  MATCH="home files to sync: 7" mktest::assert_stub_called logging::info
  MATCH="synced" mktest::assert_stub_not_called logging::info
}

# --- postflight::_print_exec_hint ---

@test "_print_exec_hint logs the exec command" {
  postflight::_print_exec_hint
  MATCH="exec" mktest::assert_stub_called logging::info
}
