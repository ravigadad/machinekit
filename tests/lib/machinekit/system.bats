#!/usr/bin/env bats
# Tests for lib/machinekit/system.sh

load "${BATS_TEST_DIRNAME}/../../test_helper"

setup() {
  # shellcheck source=../../../lib/machinekit/system.sh
  source "$MACHINEKIT_DIR/lib/machinekit/system.sh"
  unset _MK_SYSTEM_LOADED
}

# --- load guard ---

@test "sourcing twice does not redefine functions" {
  system::detect() { echo "original"; }
  _MK_SYSTEM_LOADED=1
  source "$MACHINEKIT_DIR/lib/machinekit/system.sh"
  [ "$(system::detect)" = "original" ]
}

# --- system::detect ---

@test "detect stores darwin family and arm64 arch on Darwin arm64" {
  STUB_OUTPUT="Darwin" mktest::stub_function system::_os_name
  STUB_OUTPUT="arm64"  mktest::stub_function system::_arch_name
  mktest::stub_function context::set "os.family" "darwin"
  mktest::stub_function context::set "os.arch"   "arm64"
  system::detect
  mktest::assert_stub_called context::set "os.family" "darwin"
  mktest::assert_stub_called context::set "os.arch"   "arm64"
}

@test "detect stores darwin family and x86_64 arch on Darwin Intel" {
  STUB_OUTPUT="Darwin"  mktest::stub_function system::_os_name
  STUB_OUTPUT="x86_64"  mktest::stub_function system::_arch_name
  mktest::stub_function context::set "os.family" "darwin"
  mktest::stub_function context::set "os.arch"   "x86_64"
  system::detect
  mktest::assert_stub_called context::set "os.family" "darwin"
  mktest::assert_stub_called context::set "os.arch"   "x86_64"
}

@test "detect stores linux family and arm64 arch on Linux arm64" {
  STUB_OUTPUT="Linux" mktest::stub_function system::_os_name
  STUB_OUTPUT="arm64" mktest::stub_function system::_arch_name
  mktest::stub_function context::set "os.family" "linux"
  mktest::stub_function context::set "os.arch"   "arm64"
  system::detect
  mktest::assert_stub_called context::set "os.family" "linux"
  mktest::assert_stub_called context::set "os.arch"   "arm64"
}

@test "detect normalizes aarch64 to arm64 on Linux" {
  STUB_OUTPUT="Linux"   mktest::stub_function system::_os_name
  STUB_OUTPUT="aarch64" mktest::stub_function system::_arch_name
  mktest::stub_function context::set "os.family" "linux"
  mktest::stub_function context::set "os.arch"   "arm64"
  system::detect
  mktest::assert_stub_called context::set "os.arch" "arm64"
}

@test "detect stores linux family and x86_64 arch on Linux Intel" {
  STUB_OUTPUT="Linux"  mktest::stub_function system::_os_name
  STUB_OUTPUT="x86_64" mktest::stub_function system::_arch_name
  mktest::stub_function context::set "os.family" "linux"
  mktest::stub_function context::set "os.arch"   "x86_64"
  system::detect
  mktest::assert_stub_called context::set "os.family" "linux"
  mktest::assert_stub_called context::set "os.arch"   "x86_64"
}

@test "detect fails on unsupported OS" {
  STUB_OUTPUT="FreeBSD" mktest::stub_function system::_os_name
  STUB_OUTPUT="x86_64"  mktest::stub_function system::_arch_name
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run system::detect
  [ "$status" -eq 1 ]
  MATCH="Unsupported OS" mktest::assert_stub_called lifecycle::fail
}

@test "detect fails on unsupported architecture" {
  STUB_OUTPUT="Linux"  mktest::stub_function system::_os_name
  STUB_OUTPUT="mips64" mktest::stub_function system::_arch_name
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run system::detect
  [ "$status" -eq 1 ]
  MATCH="Unsupported architecture" mktest::assert_stub_called lifecycle::fail
}

# --- system::_os_name / system::_arch_name ---

@test "_os_name returns uname -s output" {
  [ "$(system::_os_name)" = "$(uname -s)" ]
}

@test "_arch_name returns uname -m output" {
  [ "$(system::_arch_name)" = "$(uname -m)" ]
}
