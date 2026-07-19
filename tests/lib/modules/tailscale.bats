#!/usr/bin/env bats
# Tests for lib/modules/tailscale.sh

load "${BATS_TEST_DIRNAME}/../../test_helper"

setup() {
  # shellcheck source=../../../lib/modules/tailscale.sh
  source "$MACHINEKIT_DIR/lib/modules/tailscale.sh"

  # Allow-only logging collaborators — logging is mechanism, not contract.
  mktest::stub_function logging::step
  mktest::stub_function logging::debug
  mktest::stub_function logging::info
  mktest::stub_function logging::warn
  mktest::stub_function logging::success
  mktest::stub_function logging::dry_run
}

# --- tailscale::requires ---

@test "requires pipes its declared secret through the backend-requirements helper and emits the result" {
  STUB_OUTPUT=$'tailscale/fake\ttrue\tfalse' mktest::stub_function tailscale::declared_secrets
  secrets::declared_backend_requirements() { cat > "$BATS_TEST_TMPDIR/br.stdin"; printf 'age\n'; }
  run tailscale::requires
  [ "$status" -eq 0 ]
  [ "$output" = "age" ]
  # The module hands its declared-secret row to the shared classifier verbatim.
  [ "$(cat "$BATS_TEST_TMPDIR/br.stdin")" = $'tailscale/fake\ttrue\tfalse' ]
}

@test "requires nothing when no secret is declared (untagged device)" {
  mktest::stub_function tailscale::declared_secrets
  secrets::declared_backend_requirements() { cat > /dev/null; }
  run tailscale::requires
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- tailscale::preflight ---

@test "preflight is a no-op for an untagged (user) device" {
  STUB_OUTPUT="" mktest::stub_function tailscale::_tag
  mktest::stub_function secrets::present
  mktest::stub_function lifecycle::fail
  tailscale::preflight
  mktest::assert_stub_not_called secrets::present
  mktest::assert_stub_not_called lifecycle::fail
}

@test "preflight passes when a tagged device has its secret" {
  STUB_OUTPUT="server" mktest::stub_function tailscale::_tag
  STUB_OUTPUT="tailscale/default" mktest::stub_function tailscale::_secret_name
  mktest::stub_function secrets::present "tailscale/default"
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  tailscale::preflight
  mktest::assert_stub_not_called lifecycle::fail
}

@test "preflight fails when a tagged device is missing its secret" {
  STUB_OUTPUT="server" mktest::stub_function tailscale::_tag
  STUB_OUTPUT="tailscale/default" mktest::stub_function tailscale::_secret_name
  STUB_RETURN=1 mktest::stub_function secrets::present "tailscale/default"
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run ! tailscale::preflight
  MATCH="tailscale/default" mktest::assert_stub_called lifecycle::fail
}

# --- tailscale::declared_secrets ---

@test "declared_secrets declares the tailnet secret required and not generatable on a tagged device" {
  STUB_OUTPUT="server" mktest::stub_function tailscale::_tag
  STUB_OUTPUT="tailscale/fake" mktest::stub_function tailscale::_secret_name
  run tailscale::declared_secrets
  [ "$status" -eq 0 ]
  [ "$output" = $'tailscale/fake\ttrue\tfalse' ]
}

@test "declared_secrets emits nothing for an untagged (user) device" {
  STUB_OUTPUT="" mktest::stub_function tailscale::_tag
  mktest::stub_function tailscale::_secret_name
  run tailscale::declared_secrets
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  mktest::assert_stub_not_called tailscale::_secret_name
}

# --- tailscale::install ---

@test "install delegates to _install_cask when the device wants the macOS GUI app" {
  mktest::stub_function tailscale::_use_cask
  mktest::stub_function tailscale::_install_cask
  mktest::stub_function tailscale::_install_linux
  mktest::stub_function brew::install_formula "tailscale"
  mktest::stub_function tailscale::_start_daemon
  tailscale::install
  mktest::assert_stub_called tailscale::_install_cask
  mktest::assert_stub_not_called tailscale::_install_linux
  mktest::assert_stub_not_called brew::install_formula "tailscale"
  mktest::assert_stub_not_called tailscale::_start_daemon
}

@test "install on Linux delegates to the official-installer path" {
  STUB_RETURN=1 mktest::stub_function tailscale::_use_cask
  STUB_OUTPUT="linux" mktest::stub_function tailscale::_os_family
  mktest::stub_function tailscale::_install_linux
  mktest::stub_function brew::install_formula "tailscale"
  mktest::stub_function tailscale::_start_daemon
  tailscale::install
  mktest::assert_stub_called tailscale::_install_linux
  mktest::assert_stub_not_called brew::install_formula "tailscale"
  mktest::assert_stub_not_called tailscale::_start_daemon
}

@test "install on a tagged Mac installs the formula, then starts the daemon" {
  STUB_RETURN=1 mktest::stub_function tailscale::_use_cask
  STUB_OUTPUT="darwin" mktest::stub_function tailscale::_os_family
  mktest::stub_function tailscale::_install_linux
  mktest::stub_function brew::install_formula "tailscale"
  STUB_RETURN=1 mktest::stub_function input::is_dry_run
  mktest::stub_function tailscale::_start_daemon
  tailscale::install
  # Order is the contract: the daemon can't start a formula that isn't installed.
  mktest::assert_stub_called_in_order brew::install_formula "tailscale"
  mktest::assert_stub_called_in_order tailscale::_start_daemon
  mktest::assert_stub_not_called tailscale::_install_linux
}

@test "install on a tagged Mac in dry-run installs the formula but reports instead of starting" {
  STUB_RETURN=1 mktest::stub_function tailscale::_use_cask
  STUB_OUTPUT="darwin" mktest::stub_function tailscale::_os_family
  mktest::stub_function brew::install_formula "tailscale"
  mktest::stub_function input::is_dry_run
  mktest::stub_function tailscale::_start_daemon
  tailscale::install
  mktest::assert_stub_called brew::install_formula "tailscale"
  mktest::assert_stub_not_called tailscale::_start_daemon
  mktest::assert_stub_called logging::dry_run
}

# --- tailscale::_install_cask ---

@test "_install_cask installs the tailscale-app cask" {
  mktest::stub_function brew::install_cask "tailscale-app"
  tailscale::_install_cask
  mktest::assert_stub_called brew::install_cask "tailscale-app"
}

@test "_install_cask warns and continues when the cask install fails" {
  STUB_RETURN=1 mktest::stub_function brew::install_cask "tailscale-app"
  tailscale::_install_cask
  mktest::assert_stub_called logging::warn
}

# --- tailscale::_install_linux ---

@test "_install_linux runs the official installer when tailscale is absent" {
  STUB_RETURN=1 mktest::stub_function input::command_exists "tailscale"
  STUB_RETURN=1 mktest::stub_function input::is_dry_run
  mktest::stub_function tailscale::_run_official_installer
  tailscale::_install_linux
  mktest::assert_stub_called tailscale::_run_official_installer
}

@test "_install_linux is a no-op when tailscale is already installed" {
  mktest::stub_function input::command_exists "tailscale"
  mktest::stub_function tailscale::_run_official_installer
  tailscale::_install_linux
  mktest::assert_stub_not_called tailscale::_run_official_installer
}

@test "_install_linux in dry-run reports without installing" {
  STUB_RETURN=1 mktest::stub_function input::command_exists "tailscale"
  mktest::stub_function input::is_dry_run
  mktest::stub_function tailscale::_run_official_installer
  tailscale::_install_linux
  mktest::assert_stub_not_called tailscale::_run_official_installer
  mktest::assert_stub_called logging::dry_run
}

# --- tailscale::_run_official_installer ---

@test "_run_official_installer fetches the tailscale installer over curl" {
  # Capture the real curl invocation with a fake; the empty stdout means nothing
  # reaches the piped shell.
  local capture; capture=$(mktemp)
  curl() { printf '%s' "$*" > "$capture"; }
  tailscale::_run_official_installer
  [ "$(cat "$capture")" = "-fsSL https://tailscale.com/install.sh" ]
}

# --- tailscale::_start_daemon ---

@test "_start_daemon starts the tailscale system daemon via sudo brew services" {
  STUB_OUTPUT="/opt/homebrew/bin/brew" mktest::stub_function brew::_bin
  mktest::stub_function sudo
  tailscale::_start_daemon
  mktest::assert_stub_called sudo "/opt/homebrew/bin/brew" "services" "start" "tailscale"
}

# --- tailscale::_use_cask ---

@test "_use_cask is true only for an untagged macOS device" {
  STUB_OUTPUT="" mktest::stub_function tailscale::_tag
  STUB_OUTPUT="darwin" mktest::stub_function tailscale::_os_family
  tailscale::_use_cask
}

@test "_use_cask is false for an untagged Linux device" {
  STUB_OUTPUT="" mktest::stub_function tailscale::_tag
  STUB_OUTPUT="linux" mktest::stub_function tailscale::_os_family
  run ! tailscale::_use_cask
}

@test "_use_cask is false for a tagged macOS device" {
  STUB_OUTPUT="server" mktest::stub_function tailscale::_tag
  STUB_OUTPUT="darwin" mktest::stub_function tailscale::_os_family
  run ! tailscale::_use_cask
}

@test "_use_cask is false for a tagged Linux device" {
  STUB_OUTPUT="server" mktest::stub_function tailscale::_tag
  STUB_OUTPUT="linux" mktest::stub_function tailscale::_os_family
  run ! tailscale::_use_cask
}

# --- tailscale::post_apply ---

@test "post_apply does nothing on an untagged device (sign-in is a postflight instruction now)" {
  STUB_OUTPUT="" mktest::stub_function tailscale::_tag
  mktest::stub_function tailscale::_join
  tailscale::post_apply
  mktest::assert_stub_not_called tailscale::_join
}

@test "post_apply joins with the configured tag on a tagged device" {
  STUB_OUTPUT="server" mktest::stub_function tailscale::_tag
  mktest::stub_function tailscale::_join "server"
  tailscale::post_apply
  mktest::assert_stub_called tailscale::_join "server"
}

# --- tailscale::_membership_summary (single source for the live + postflight line) ---

@test "_membership_summary names the tag and the pinned hostname" {
  STUB_OUTPUT="server" mktest::stub_function tailscale::_hostname
  run tailscale::_membership_summary "server"
  [[ "$output" == *"tag:server"* ]]
  [[ "$output" == *"hostname: server"* ]]
}

@test "_membership_summary omits the hostname clause when none is pinned" {
  STUB_OUTPUT="" mktest::stub_function tailscale::_hostname
  run tailscale::_membership_summary "server"
  [[ "$output" == *"tag:server"* ]]
  [[ "$output" != *"hostname"* ]]
}

# --- tailscale::_signin_instruction ---

@test "_signin_instruction points macOS users at the GUI app" {
  STUB_OUTPUT="darwin" mktest::stub_function tailscale::_os_family
  run tailscale::_signin_instruction
  [[ "$output" == *"app"* ]]
}

@test "_signin_instruction points Linux users at the CLI" {
  STUB_OUTPUT="linux" mktest::stub_function tailscale::_os_family
  run tailscale::_signin_instruction
  [[ "$output" == *"tailscale up"* ]]
}

# --- tailscale::postflight_info ---

@test "postflight_info reports tailnet membership on a connected tagged device" {
  STUB_OUTPUT="server" mktest::stub_function tailscale::_tag
  mktest::stub_function tailscale::_is_connected
  STUB_OUTPUT="joined the tailnet as tag:server." \
    mktest::stub_function tailscale::_membership_summary "server"
  run tailscale::postflight_info
  [[ "$output" == *"joined the tailnet as tag:server"* ]]
}

@test "postflight_info emits nothing on an untagged device" {
  STUB_OUTPUT="" mktest::stub_function tailscale::_tag
  run tailscale::postflight_info
  [ -z "$output" ]
}

@test "postflight_info emits nothing when a tagged device is not connected" {
  STUB_OUTPUT="server" mktest::stub_function tailscale::_tag
  STUB_RETURN=1 mktest::stub_function tailscale::_is_connected
  run tailscale::postflight_info
  [ -z "$output" ]
}

# --- tailscale::postflight_instructions ---

@test "postflight_instructions surfaces the manual sign-in step on an untagged device" {
  STUB_OUTPUT="" mktest::stub_function tailscale::_tag
  STUB_OUTPUT="SIGN IN HERE" mktest::stub_function tailscale::_signin_instruction
  run tailscale::postflight_instructions
  [[ "$output" == *"SIGN IN HERE"* ]]
}

@test "postflight_instructions emits nothing on a connected tagged device" {
  STUB_OUTPUT="server" mktest::stub_function tailscale::_tag
  mktest::stub_function tailscale::_is_connected
  run tailscale::postflight_instructions
  [ -z "$output" ]
}

@test "postflight_instructions tells a disconnected tagged device how to join" {
  STUB_OUTPUT="server" mktest::stub_function tailscale::_tag
  STUB_RETURN=1 mktest::stub_function tailscale::_is_connected
  run tailscale::postflight_instructions
  [[ "$output" == *"MACHINEKIT_TAILSCALE_JOIN=1"* ]]
  [[ "$output" == *"tag:server"* ]]
}

# --- tailscale::_join ---

@test "_join short-circuits when already connected to the tailnet" {
  mktest::stub_function tailscale::_is_connected
  mktest::stub_function tailscale::_up
  tailscale::_join "server"
  mktest::assert_stub_not_called tailscale::_up
}

@test "_join reports the intended action in dry-run without joining" {
  STUB_RETURN=1 mktest::stub_function tailscale::_is_connected
  mktest::stub_function input::is_dry_run
  mktest::stub_function tailscale::_up
  tailscale::_join "server"
  mktest::assert_stub_called logging::dry_run
  mktest::assert_stub_not_called tailscale::_up
}

@test "_join resolves the secret and brings tailscale up when consented" {
  STUB_RETURN=1 mktest::stub_function tailscale::_is_connected
  STUB_RETURN=1 mktest::stub_function input::is_dry_run
  STUB_OUTPUT="true" mktest::stub_function context::get "tailscale.join" --default false --coerce boolean \
    --prompt "Join the tailnet now as tagged device tag:server? (y/n)"
  STUB_OUTPUT="tailscale/default" mktest::stub_function tailscale::_secret_name
  STUB_OUTPUT="fake-oauth-secret" mktest::stub_function secrets::resolve "tailscale/default"
  mktest::stub_function tailscale::_up "fake-oauth-secret" "server"
  mktest::stub_function tailscale::_membership_summary "server"
  tailscale::_join "server"
  mktest::assert_stub_called tailscale::_up "fake-oauth-secret" "server"
}

@test "_join skips joining when consent is withheld" {
  STUB_RETURN=1 mktest::stub_function tailscale::_is_connected
  STUB_RETURN=1 mktest::stub_function input::is_dry_run
  STUB_OUTPUT="false" mktest::stub_function context::get "tailscale.join" --default false --coerce boolean \
    --prompt "Join the tailnet now as tagged device tag:server? (y/n)"
  mktest::stub_function tailscale::_up
  tailscale::_join "server"
  mktest::assert_stub_not_called tailscale::_up
  mktest::assert_stub_called logging::warn
}

# --- tailscale::_up ---

@test "_up brings tailscale up off-argv via file:/dev/stdin with the advertised tag" {
  STUB_OUTPUT="/opt/homebrew/bin/tailscale" mktest::stub_function tailscale::_bin
  STUB_OUTPUT="" mktest::stub_function tailscale::_hostname
  mktest::stub_function sudo
  tailscale::_up "fake-oauth-secret" "server"
  # The secret is NOT among these args — it rides stdin (asserted below).
  mktest::assert_stub_called sudo "/opt/homebrew/bin/tailscale" "up" \
    "--auth-key" "file:/dev/stdin" "--advertise-tags" "tag:server"
}

@test "_up pins the hostname when one is configured" {
  STUB_OUTPUT="/opt/homebrew/bin/tailscale" mktest::stub_function tailscale::_bin
  STUB_OUTPUT="memory-server" mktest::stub_function tailscale::_hostname
  mktest::stub_function sudo
  tailscale::_up "fake-oauth-secret" "server"
  mktest::assert_stub_called sudo "/opt/homebrew/bin/tailscale" "up" \
    "--auth-key" "file:/dev/stdin" "--advertise-tags" "tag:server" "--hostname=memory-server"
}

@test "_up passes the secret on stdin, never as an argument" {
  STUB_OUTPUT="/opt/homebrew/bin/tailscale" mktest::stub_function tailscale::_bin
  STUB_OUTPUT="" mktest::stub_function tailscale::_hostname
  # The stub framework records args, not stdin; capture stdin to a file instead.
  local capture; capture=$(mktemp)
  sudo() { cat > "$capture"; }
  tailscale::_up "fake-oauth-secret" "server"
  [ "$(cat "$capture")" = "fake-oauth-secret?ephemeral=false" ]
}

# --- tailscale::_bin ---

@test "_bin resolves the tailscale binary so sudo can find it" {
  mktest::stub_function tailscale
  run tailscale::_bin
  [ "$output" = "tailscale" ]
}

# --- tailscale::_is_connected ---

@test "_is_connected reflects the tailscale status exit code" {
  STUB_RETURN=1 mktest::stub_function tailscale "status"
  run ! tailscale::_is_connected
}

# --- tailscale::_tag ---

@test "_tag reads module.tailscale.tag from config" {
  STUB_OUTPUT="poomba" mktest::stub_function config::get "module.tailscale.tag" --default ""
  run tailscale::_tag
  [ "$output" = "poomba" ]
}

# --- tailscale::_hostname ---

@test "_hostname reads module.tailscale.hostname from config, defaulting to empty" {
  STUB_OUTPUT="memory-server" mktest::stub_function config::get "module.tailscale.hostname" --default ""
  run tailscale::_hostname
  [ "$output" = "memory-server" ]
}

# --- tailscale::_os_family ---

@test "_os_family reads os.family from context" {
  STUB_OUTPUT="spinach" mktest::stub_function context::get "os.family"
  run tailscale::_os_family
  [ "$output" = "spinach" ]
}

# --- tailscale::_tailnet ---

@test "_tailnet reads module.tailscale.tailnet from config, defaulting to 'default'" {
  STUB_OUTPUT="work" mktest::stub_function config::get "module.tailscale.tailnet" --default "default"
  run tailscale::_tailnet
  [ "$output" = "work" ]
}

# --- tailscale::_secret_name ---

@test "_secret_name builds the bare logical secret name by service and tailnet" {
  STUB_OUTPUT="work" mktest::stub_function tailscale::_tailnet
  run tailscale::_secret_name
  [ "$output" = "tailscale/work" ]
}
