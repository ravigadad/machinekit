#!/usr/bin/env bats
# Tests for lib/modules/agents_config_harnesses.sh

load "${BATS_TEST_DIRNAME}/../../test_helper"

setup() {
  # shellcheck source=../../../lib/modules/agents_config_harnesses.sh
  source "$MACHINEKIT_DIR/lib/modules/agents_config_harnesses.sh"
  mktest::stub_function logging::step
  mktest::stub_function logging::dry_run
}

# --- requires ---

@test "requires invokes each configured harness's requires" {
  STUB_OUTPUT=$'foo\nbar' mktest::stub_function agents_config_harnesses::_harnesses
  mktest::stub_function agents_config_harnesses::foo::requires
  mktest::stub_function agents_config_harnesses::bar::requires
  agents_config_harnesses::requires
  mktest::assert_stub_called agents_config_harnesses::foo::requires
  mktest::assert_stub_called agents_config_harnesses::bar::requires
}

@test "requires returns success even when a configured harness declares no requires" {
  # Neither 'foo' nor 'bar' has a submodule, so no ::requires function — the
  # loop's last command (the failing declare -F) must not become the return
  # value. Strip the `return 0` pin and this goes red.
  STUB_OUTPUT=$'foo\nbar' mktest::stub_function agents_config_harnesses::_harnesses
  run agents_config_harnesses::requires
  [ "$status" -eq 0 ]
}

@test "requires is a clean no-op when no harnesses are configured" {
  mktest::stub_function agents_config_harnesses::_harnesses
  run agents_config_harnesses::requires
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- after ---

@test "after declares a soft ordering behind agents_config_setup" {
  run agents_config_harnesses::after
  [ "$output" = "agents_config_setup" ]
}

# --- preflight ---

@test "preflight passes for known harnesses" {
  STUB_OUTPUT=$'foo\nbar' mktest::stub_function agents_config_harnesses::_harnesses
  mktest::stub_function agents_config_harnesses::_is_available "foo"
  mktest::stub_function agents_config_harnesses::_is_available "bar"
  run agents_config_harnesses::preflight
  [ "$status" -eq 0 ]
}

@test "preflight fails on an unknown harness, even after a valid one" {
  STUB_OUTPUT=$'foo\nbogus' mktest::stub_function agents_config_harnesses::_harnesses
  mktest::stub_function agents_config_harnesses::_is_available "foo"
  STUB_RETURN=1 mktest::stub_function agents_config_harnesses::_is_available "bogus"
  mktest::stub_function agents_config_harnesses::_available
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run agents_config_harnesses::preflight
  [ "$status" -ne 0 ]
  mktest::assert_stub_called lifecycle::fail
}

@test "preflight dispatches each harness's own preflight when it defines one" {
  STUB_OUTPUT=$'foo\nbar' mktest::stub_function agents_config_harnesses::_harnesses
  mktest::stub_function agents_config_harnesses::_is_available "foo"
  mktest::stub_function agents_config_harnesses::_is_available "bar"
  mktest::stub_function agents_config_harnesses::foo::preflight
  mktest::stub_function agents_config_harnesses::bar::preflight
  agents_config_harnesses::preflight
  mktest::assert_stub_called agents_config_harnesses::foo::preflight
  mktest::assert_stub_called agents_config_harnesses::bar::preflight
}

@test "preflight returns success when a known harness has no preflight" {
  # Neither fake harness defines a preflight → the loop's last command (the
  # failing declare -F) must not become the return value (the `return 0` pin).
  STUB_OUTPUT=$'foo\nbar' mktest::stub_function agents_config_harnesses::_harnesses
  mktest::stub_function agents_config_harnesses::_is_available "foo"
  mktest::stub_function agents_config_harnesses::_is_available "bar"
  run agents_config_harnesses::preflight
  [ "$status" -eq 0 ]
}

# --- install ---

@test "install in dry-run reports and projects nothing" {
  STUB_OUTPUT="/agents" mktest::stub_function agents_config_setup::dir
  STUB_OUTPUT=$'foo\nbar' mktest::stub_function agents_config_harnesses::_harnesses
  STUB_RETURN=1 mktest::stub_function agents_config_harnesses::foo::projection_present "/agents"
  STUB_RETURN=1 mktest::stub_function agents_config_harnesses::bar::projection_present "/agents"
  mktest::stub_function input::is_dry_run
  mktest::stub_function agents_config_harnesses::foo::project
  mktest::stub_function agents_config_harnesses::bar::project
  agents_config_harnesses::install
  mktest::assert_stub_not_called agents_config_harnesses::foo::project
  mktest::assert_stub_not_called agents_config_harnesses::bar::project
  mktest::assert_stub_called logging::dry_run
}

@test "install projects each harness that isn't already projected" {
  STUB_OUTPUT="/agents" mktest::stub_function agents_config_setup::dir
  STUB_OUTPUT=$'foo\nbar' mktest::stub_function agents_config_harnesses::_harnesses
  STUB_RETURN=1 mktest::stub_function agents_config_harnesses::foo::projection_present "/agents"
  STUB_RETURN=1 mktest::stub_function agents_config_harnesses::bar::projection_present "/agents"
  STUB_RETURN=1 mktest::stub_function input::is_dry_run
  mktest::stub_function agents_config_harnesses::foo::project "/agents"
  mktest::stub_function agents_config_harnesses::bar::project "/agents"
  agents_config_harnesses::install
  mktest::assert_stub_called agents_config_harnesses::foo::project "/agents"
  mktest::assert_stub_called agents_config_harnesses::bar::project "/agents"
}

@test "install skips harnesses already projected" {
  STUB_OUTPUT="/agents" mktest::stub_function agents_config_setup::dir
  STUB_OUTPUT=$'foo\nbar' mktest::stub_function agents_config_harnesses::_harnesses
  mktest::stub_function agents_config_harnesses::foo::projection_present "/agents"
  mktest::stub_function agents_config_harnesses::bar::projection_present "/agents"
  STUB_RETURN=1 mktest::stub_function input::is_dry_run
  mktest::stub_function agents_config_harnesses::foo::project
  mktest::stub_function agents_config_harnesses::bar::project
  agents_config_harnesses::install
  mktest::assert_stub_not_called agents_config_harnesses::foo::project
  mktest::assert_stub_not_called agents_config_harnesses::bar::project
}

@test "install is a clean no-op when no harnesses are configured" {
  STUB_OUTPUT="/agents" mktest::stub_function agents_config_setup::dir
  mktest::stub_function agents_config_harnesses::_harnesses
  STUB_RETURN=1 mktest::stub_function input::is_dry_run
  run agents_config_harnesses::install
  [ "$status" -eq 0 ]
}

# --- _available / _is_available (these legitimately inspect the real sourced submodule) ---

@test "_is_available is true for a sourced harness submodule" {
  agents_config_harnesses::_is_available claude_code
}

@test "_is_available is false for an unknown harness" {
  run ! agents_config_harnesses::_is_available bogus
}

@test "_available lists harnesses whose submodule defines project" {
  run agents_config_harnesses::_available
  [[ "$output" == *claude_code* ]]
}

# --- _harnesses ---

@test "_harnesses reads the configured harnesses list" {
  STUB_OUTPUT=$'foo\nbar' mktest::stub_function config::get_array "module.agents_config_harnesses.harnesses"
  run agents_config_harnesses::_harnesses
  [ "${lines[0]}" = "foo" ]
  [ "${lines[1]}" = "bar" ]
}

@test "_harnesses is empty (success) when the key is unset" {
  STUB_RETURN=1 mktest::stub_function config::get_array "module.agents_config_harnesses.harnesses"
  run agents_config_harnesses::_harnesses
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- _agents_md_source ---
# Shared by the file-symlink harness submodules (codex, opencode): the AGENTS.md
# they each point their global instructions file at.

@test "_agents_md_source is the AGENTS.md within the agents config dir" {
  run agents_config_harnesses::_agents_md_source /agents
  [ "$output" = "/agents/AGENTS.md" ]
}

# --- _ensure_agents_md_link ---
# A thin specialization of _ensure_link whose source is the dir's AGENTS.md.

@test "_ensure_agents_md_link delegates to _ensure_link with the derived AGENTS.md source" {
  STUB_OUTPUT="/agents/AGENTS.md" mktest::stub_function agents_config_harnesses::_agents_md_source "/agents"
  mktest::stub_function agents_config_harnesses::_ensure_link "/home/.codex/AGENTS.md" "/agents/AGENTS.md"
  agents_config_harnesses::_ensure_agents_md_link "/home/.codex/AGENTS.md" "/agents"
  mktest::assert_stub_called agents_config_harnesses::_ensure_link "/home/.codex/AGENTS.md" "/agents/AGENTS.md"
}

# --- _agents_md_link_present ---

@test "_agents_md_link_present delegates to _link_present with the derived AGENTS.md source" {
  STUB_OUTPUT="/agents/AGENTS.md" mktest::stub_function agents_config_harnesses::_agents_md_source "/agents"
  mktest::stub_function agents_config_harnesses::_link_present "/home/.codex/AGENTS.md" "/agents/AGENTS.md"
  agents_config_harnesses::_agents_md_link_present "/home/.codex/AGENTS.md" "/agents"
  mktest::assert_stub_called agents_config_harnesses::_link_present "/home/.codex/AGENTS.md" "/agents/AGENTS.md"
}

# --- _ensure_link ---
# Generic symlink projection used by the identity harnesses; SOURCE is explicit.

@test "_ensure_link creates the symlink when the path is absent" {
  local home_dir; home_dir="$(mktemp -d)"
  local link_path="$home_dir/.openclaw/workspace/SOUL.md" source="$home_dir/agents/SOUL.md"
  STUB_RETURN=1 mktest::stub_function agents_config_harnesses::_link_present "$link_path" "$source"
  agents_config_harnesses::_ensure_link "$link_path" "$source"
  [ -L "$link_path" ]
  [ "$(readlink "$link_path")" = "$source" ]
}

@test "_ensure_link is a no-op when the correct symlink already exists" {
  mktest::stub_function ln
  mktest::stub_function lifecycle::fail
  mktest::stub_function agents_config_harnesses::_link_present "/fake/link" "/fake/source"
  agents_config_harnesses::_ensure_link "/fake/link" "/fake/source"
  mktest::assert_stub_not_called ln
  mktest::assert_stub_not_called lifecycle::fail
}

@test "_ensure_link fails loudly when a real file occupies the path" {
  local home_dir; home_dir="$(mktemp -d)"
  local link_path="$home_dir/workspace/SOUL.md"
  mkdir -p "$home_dir/workspace"; printf 'mine\n' > "$link_path"
  STUB_RETURN=1 mktest::stub_function agents_config_harnesses::_link_present "$link_path" "/agents/SOUL.md"
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run agents_config_harnesses::_ensure_link "$link_path" "/agents/SOUL.md"
  [ "$status" -ne 0 ]
  mktest::assert_stub_called lifecycle::fail
}

@test "_ensure_link fails loudly when the path is a symlink to a different target" {
  local home_dir; home_dir="$(mktemp -d)"
  local link_path="$home_dir/workspace/SOUL.md"
  mkdir -p "$home_dir/workspace" "$home_dir/other"; ln -s "$home_dir/other/SOUL.md" "$link_path"
  STUB_RETURN=1 mktest::stub_function agents_config_harnesses::_link_present "$link_path" "/agents/SOUL.md"
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run agents_config_harnesses::_ensure_link "$link_path" "/agents/SOUL.md"
  [ "$status" -ne 0 ]
  mktest::assert_stub_called lifecycle::fail
}

# --- _link_present ---

@test "_link_present is true for the correct symlink" {
  local home_dir; home_dir="$(mktemp -d)"
  local link_path="$home_dir/workspace/SOUL.md" source="$home_dir/agents/SOUL.md"
  mkdir -p "$home_dir/agents" "$home_dir/workspace"; ln -s "$source" "$link_path"
  agents_config_harnesses::_link_present "$link_path" "$source"
}

@test "_link_present is false when the link is absent" {
  local home_dir; home_dir="$(mktemp -d)"
  run ! agents_config_harnesses::_link_present "$home_dir/workspace/SOUL.md" "$home_dir/agents/SOUL.md"
}

@test "_link_present is false when the symlink points elsewhere" {
  local home_dir; home_dir="$(mktemp -d)"
  local link_path="$home_dir/workspace/SOUL.md"
  mkdir -p "$home_dir/workspace" "$home_dir/other"; ln -s "$home_dir/other/SOUL.md" "$link_path"
  run ! agents_config_harnesses::_link_present "$link_path" "$home_dir/agents/SOUL.md"
}
