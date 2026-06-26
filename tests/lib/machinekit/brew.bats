#!/usr/bin/env bats
# Tests for lib/machinekit/brew.sh

load "${BATS_TEST_DIRNAME}/../../test_helper"

setup() {
  # shellcheck source=../../../lib/machinekit/brew.sh
  source "$MACHINEKIT_DIR/lib/machinekit/brew.sh"
  _MK_BREW_FORMULA_CACHED=0
  _MK_BREW_FORMULA_CACHE=""
  _MK_BREW_CASK_CACHED=0
  _MK_BREW_CASK_CACHE=""
  unset _MK_BREW_LOADED

  # Logging collaborators — allow-only; they are mechanism, not contract.
  mktest::stub_function logging::step
  mktest::stub_function logging::info
  mktest::stub_function logging::success
  mktest::stub_function logging::debug
}

# --- load guard ---

@test "sourcing twice does not redefine functions" {
  # Functions defined by the first source are already present; second source is a no-op.
  brew::bootstrap() { echo "original"; }
  _MK_BREW_LOADED=1
  source "$MACHINEKIT_DIR/lib/machinekit/brew.sh"
  [ "$(brew::bootstrap)" = "original" ]
}

# --- brew::bootstrap ---

@test "bootstrap does not install when brew is already on PATH" {
  mktest::stub_function brew_core::setup_path
  mktest::stub_function input::command_exists "brew"
  mktest::stub_function brew::_install_homebrew
  brew::bootstrap
  mktest::assert_stub_not_called brew::_install_homebrew
}

@test "bootstrap installs when brew is not on PATH" {
  mktest::stub_function brew_core::setup_path
  STUB_RETURN=1 mktest::stub_function input::command_exists "brew"
  mktest::stub_function brew::_install_homebrew
  brew::bootstrap
  mktest::assert_stub_called brew::_install_homebrew
}

# --- brew::install_formula / install_cask (delegation) ---

@test "install_formula delegates to _install_pkg as a formula" {
  mktest::stub_function brew::_install_pkg
  brew::install_formula "git" --override-dry-run
  mktest::assert_stub_called brew::_install_pkg "formula" "git" "--override-dry-run"
}

@test "install_cask delegates to _install_pkg as a cask" {
  mktest::stub_function brew::_install_pkg
  brew::install_cask "tailscale" --override-dry-run
  mktest::assert_stub_called brew::_install_pkg "cask" "tailscale" "--override-dry-run"
}

# --- brew::_install_pkg ---

@test "_install_pkg fails with a clear error when homebrew is not installed" {
  mktest::stub_function input::is_dry_run
  STUB_RETURN=1 mktest::stub_function input::command_exists "brew"
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run ! brew::_install_pkg formula "git"
  MATCH="not installed" mktest::assert_stub_called lifecycle::fail
}

@test "_install_pkg skips when the package is already installed" {
  mktest::stub_function input::is_dry_run
  mktest::stub_function input::command_exists "brew"
  mktest::stub_function brew::_is_installed "formula" "git"
  mktest::stub_function brew::_run_install "git"
  brew::_install_pkg formula "git"
  mktest::assert_stub_not_called brew::_run_install "git"
}

@test "_install_pkg in dry-run reports a would-install message" {
  mktest::stub_function input::is_dry_run
  mktest::stub_function input::command_exists "brew"
  STUB_RETURN=1 mktest::stub_function brew::_is_installed "formula" "someformula"
  mktest::stub_function logging::dry_run
  brew::_install_pkg formula "someformula"
  MATCH="someformula" mktest::assert_stub_called logging::dry_run
}

@test "_install_pkg installs an absent formula via _run_install" {
  STUB_RETURN=1 mktest::stub_function input::is_dry_run
  mktest::stub_function input::command_exists "brew"
  STUB_RETURN=1 mktest::stub_function brew::_is_installed "formula" "git"
  mktest::stub_function brew::_run_install "git"
  brew::_install_pkg formula "git"
  mktest::assert_stub_called brew::_run_install "git"
}

@test "_install_pkg installs an absent cask with --cask via _run_install" {
  STUB_RETURN=1 mktest::stub_function input::is_dry_run
  mktest::stub_function input::command_exists "brew"
  STUB_RETURN=1 mktest::stub_function brew::_is_installed "cask" "tailscale"
  mktest::stub_function brew::_run_install "--cask" "tailscale"
  brew::_install_pkg cask "tailscale"
  mktest::assert_stub_called brew::_run_install "--cask" "tailscale"
}

@test "_install_pkg with --override-dry-run installs even in dry-run mode" {
  mktest::stub_function input::is_dry_run
  mktest::stub_function input::command_exists "brew"
  STUB_RETURN=1 mktest::stub_function brew::_is_installed "formula" "git"
  mktest::stub_function brew::_run_install "git"
  brew::_install_pkg formula "git" --override-dry-run
  mktest::assert_stub_called brew::_run_install "git"
  mktest::assert_stub_not_called input::is_dry_run
}

@test "_install_pkg fails on an unknown option" {
  mktest::stub_function input::is_dry_run
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run ! brew::_install_pkg formula "git" "--bad-flag"
  MATCH="unknown option" mktest::assert_stub_called lifecycle::fail
}

@test "_install_pkg invalidates the formula cache after a real install" {
  STUB_RETURN=1 mktest::stub_function input::is_dry_run
  mktest::stub_function input::command_exists "brew"
  STUB_RETURN=1 mktest::stub_function brew::_is_installed "formula" "git"
  mktest::stub_function brew::_run_install "git"
  _MK_BREW_FORMULA_CACHED=1
  brew::_install_pkg formula "git"
  [ "$_MK_BREW_FORMULA_CACHED" = "0" ]
}

@test "_install_pkg invalidates the cask cache after a real install" {
  STUB_RETURN=1 mktest::stub_function input::is_dry_run
  mktest::stub_function input::command_exists "brew"
  STUB_RETURN=1 mktest::stub_function brew::_is_installed "cask" "some-app"
  mktest::stub_function brew::_run_install "--cask" "some-app"
  _MK_BREW_CASK_CACHED=1
  brew::_install_pkg cask "some-app"
  [ "$_MK_BREW_CASK_CACHED" = "0" ]
}

@test "_install_pkg leaves the cache intact when the package is already installed" {
  mktest::stub_function input::is_dry_run
  mktest::stub_function input::command_exists "brew"
  mktest::stub_function brew::_is_installed "formula" "git"
  _MK_BREW_FORMULA_CACHED=1
  brew::_install_pkg formula "git"
  [ "$_MK_BREW_FORMULA_CACHED" = "1" ]
}

@test "_install_pkg leaves the cache intact in dry-run" {
  mktest::stub_function input::is_dry_run
  mktest::stub_function input::command_exists "brew"
  STUB_RETURN=1 mktest::stub_function brew::_is_installed "formula" "someformula"
  mktest::stub_function logging::dry_run
  _MK_BREW_FORMULA_CACHED=1
  brew::_install_pkg formula "someformula"
  [ "$_MK_BREW_FORMULA_CACHED" = "1" ]
}

# --- brew::_run_install ---

@test "_run_install in interactive mode installs without HOMEBREW_NO_ASK" {
  mktest::stub_function input::is_interactive
  unset HOMEBREW_NO_ASK
  # The stub framework records args, not env; capture both via a fake brew.
  local capture; capture=$(mktemp)
  brew() { printf '%s|%s' "${HOMEBREW_NO_ASK:-unset}" "$*" > "$capture"; }
  brew::_run_install git
  [ "$(cat "$capture")" = "unset|install git" ]
}

@test "_run_install in non-interactive mode installs with HOMEBREW_NO_ASK=1" {
  STUB_RETURN=1 mktest::stub_function input::is_interactive
  local capture; capture=$(mktemp)
  brew() { printf '%s|%s' "${HOMEBREW_NO_ASK:-unset}" "$*" > "$capture"; }
  brew::_run_install --cask some-app
  [ "$(cat "$capture")" = "1|install --cask some-app" ]
}

# --- brew::start_service / brew::restart_service ---

@test "start_service on darwin defaults to a system service via sudo brew services" {
  STUB_OUTPUT="darwin" mktest::stub_function context::get "os.family"
  STUB_OUTPUT="/opt/homebrew/bin/brew" mktest::stub_function brew::_bin
  mktest::stub_function sudo
  brew::start_service postgresql@18
  mktest::assert_stub_called sudo "/opt/homebrew/bin/brew" "services" "start" "postgresql@18"
}

@test "start_service on darwin with the user scope runs brew services without sudo" {
  STUB_OUTPUT="darwin" mktest::stub_function context::get "os.family"
  STUB_OUTPUT="fake_brew" mktest::stub_function brew::_bin
  mktest::stub_function sudo
  mktest::stub_function fake_brew "services" "start" "syncthing"
  brew::start_service syncthing user
  mktest::assert_stub_called fake_brew "services" "start" "syncthing"
  mktest::assert_stub_not_called sudo "fake_brew" "services" "start" "syncthing"
}

@test "start_service on linux runs brew as the user (not sudo) and enables lingering" {
  STUB_OUTPUT="linux" mktest::stub_function context::get "os.family"
  STUB_OUTPUT="admin" mktest::stub_function id "-un"
  STUB_OUTPUT="fake_brew" mktest::stub_function brew::_bin
  mktest::stub_function sudo
  mktest::stub_function fake_brew "services" "start" "postgresql@18"
  brew::start_service postgresql@18
  mktest::assert_stub_called fake_brew "services" "start" "postgresql@18"
  mktest::assert_stub_called sudo "loginctl" "enable-linger" "admin"
  mktest::assert_stub_not_called sudo "fake_brew" "services" "start" "postgresql@18"
}

@test "restart_service on darwin restarts via sudo brew services" {
  STUB_OUTPUT="darwin" mktest::stub_function context::get "os.family"
  STUB_OUTPUT="/opt/homebrew/bin/brew" mktest::stub_function brew::_bin
  mktest::stub_function sudo
  brew::restart_service postgresql@18
  mktest::assert_stub_called sudo "/opt/homebrew/bin/brew" "services" "restart" "postgresql@18"
}

@test "restart_service on linux runs brew restart as the user" {
  STUB_OUTPUT="linux" mktest::stub_function context::get "os.family"
  STUB_OUTPUT="admin" mktest::stub_function id "-un"
  STUB_OUTPUT="fake_brew" mktest::stub_function brew::_bin
  mktest::stub_function sudo
  mktest::stub_function fake_brew "services" "restart" "postgresql@18"
  brew::restart_service postgresql@18
  mktest::assert_stub_called fake_brew "services" "restart" "postgresql@18"
}

@test "_service fails on an unsupported os family" {
  STUB_OUTPUT="windows" mktest::stub_function context::get "os.family"
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run brew::start_service postgresql@18
  [ "$status" -ne 0 ]
  mktest::assert_stub_called lifecycle::fail
}

# --- brew::_is_installed ---

@test "_is_installed returns true for a name in the list" {
  STUB_OUTPUT="$(printf 'git\njq\nage')" mktest::stub_function brew::_installed "formula"
  brew::_is_installed formula "jq"
}

@test "_is_installed returns false for a name not in the list" {
  STUB_OUTPUT="$(printf 'git\njq')" mktest::stub_function brew::_installed "formula"
  run ! brew::_is_installed formula "age"
}

@test "_is_installed does not partial-match names" {
  STUB_OUTPUT="$(printf 'git\njq-extras')" mktest::stub_function brew::_installed "formula"
  run ! brew::_is_installed formula "jq"
}

@test "_is_installed checks the cask list for a cask" {
  STUB_OUTPUT="$(printf 'tailscale\nfirefox')" mktest::stub_function brew::_installed "cask"
  brew::_is_installed cask "tailscale"
}

# --- brew::_bin ---

@test "_bin resolves the brew binary so sudo can find it" {
  mktest::stub_function brew
  run brew::_bin
  [ "$output" = "brew" ]
}

# --- brew::_install_homebrew ---

@test "_install_homebrew runs the official installer non-interactively when not interactive" {
  STUB_RETURN=1 mktest::stub_function input::is_interactive
  mktest::stub_function brew_core::run_official_installer 1
  mktest::stub_function brew_core::setup_path
  mktest::stub_function input::command_exists "brew"
  brew::_install_homebrew
  mktest::assert_stub_called brew_core::run_official_installer 1
}

@test "_install_homebrew runs the official installer interactively when interactive" {
  mktest::stub_function input::is_interactive
  mktest::stub_function brew_core::run_official_installer ""
  mktest::stub_function brew_core::setup_path
  mktest::stub_function input::command_exists "brew"
  brew::_install_homebrew
  mktest::assert_stub_called brew_core::run_official_installer ""
}

@test "_install_homebrew fails when brew is not found after installing" {
  mktest::stub_function input::is_interactive
  mktest::stub_function brew_core::run_official_installer ""
  mktest::stub_function brew_core::setup_path
  STUB_RETURN=1 mktest::stub_function input::command_exists "brew"
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run ! brew::_install_homebrew
  MATCH="not found" mktest::assert_stub_called lifecycle::fail
}

# --- brew::_installed ---

@test "_installed formula returns the list from brew list --formula" {
  mktest::stub_function input::command_exists "brew"
  STUB_OUTPUT="$(printf 'git\njq\nage')" mktest::stub_function brew "list" "--formula"
  result=$(brew::_installed formula)
  [ "$result" = "$(printf 'git\njq\nage')" ]
}

@test "_installed cask returns the list from brew list --cask" {
  mktest::stub_function input::command_exists "brew"
  STUB_OUTPUT="$(printf 'tailscale\nfirefox')" mktest::stub_function brew "list" "--cask"
  result=$(brew::_installed cask)
  [ "$result" = "$(printf 'tailscale\nfirefox')" ]
}

@test "_installed returns empty without caching when brew is not installed" {
  STUB_RETURN=1 mktest::stub_function input::command_exists "brew"
  mktest::stub_function brew "list" "--formula"
  result=$(brew::_installed formula)
  [ -z "$result" ]
  mktest::assert_stub_not_called brew "list" "--formula"
}

@test "_installed caches per kind across repeated calls" {
  mktest::stub_function input::command_exists "brew"
  STUB_OUTPUT="git" mktest::stub_function brew "list" "--formula"
  brew::_installed formula >/dev/null
  brew::_installed formula >/dev/null
  TIMES=1 mktest::assert_stub_called brew "list" "--formula"
}

@test "_installed fails on an unknown kind" {
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run ! brew::_installed bogus
  MATCH="unknown kind" mktest::assert_stub_called lifecycle::fail
}
