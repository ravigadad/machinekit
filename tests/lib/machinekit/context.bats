#!/usr/bin/env bats
# Tests for lib/machinekit/context.sh
# Each @test runs in its own subshell; MACHINEKIT_CONTEXT_FILE is unset in
# setup so the lazy initializer starts fresh each test.

load "${BATS_TEST_DIRNAME}/../../test_helper"

setup() {
  # shellcheck source=../../../lib/machinekit/context.sh
  source "$MACHINEKIT_DIR/lib/machinekit/context.sh"
  unset MACHINEKIT_TEST_KEY
  # Pre-initialize the store directly so tests that call real context methods
  # don't hit the subshell guard, without going through _internal_storage_file
  # (which would pollute stub call records for tests that assert on it).
  MACHINEKIT_CONTEXT_FILE=$(mktemp)
  printf '{}' > "$MACHINEKIT_CONTEXT_FILE"
  export MACHINEKIT_CONTEXT_FILE
}

# --- context::init_storage ---

@test "init_storage delegates to _internal_storage_file" {
  mktest::stub_function context::_internal_storage_file
  context::init_storage
  mktest::assert_stub_called context::_internal_storage_file
}

# --- context::set (store) ---
# Inspect the store file directly with jq rather than reading back through
# context::get/json/get_array — these are context::set unit tests; coupling
# them to a second unit is the integrated anti-pattern.

@test "set writes a scalar value" {
  context::set "fake.name" "Alice"
  [ "$(jq -r '.fake.name' "$MACHINEKIT_CONTEXT_FILE")" = "Alice" ]
}

@test "set overwrites an existing value" {
  context::set "fake.name" "Alice"
  context::set "fake.name" "Bob"
  [ "$(jq -r '.fake.name' "$MACHINEKIT_CONTEXT_FILE")" = "Bob" ]
}

@test "set creates nested JSON from a dotted key" {
  context::set "a.b.c" "deep"
  [ "$(jq -r '.a.b.c' "$MACHINEKIT_CONTEXT_FILE")" = "deep" ]
}

@test "set writes two top-level keys without clobbering" {
  context::set "fake.name" "Alice"
  context::set "fake.email" "alice@example.com"
  [ "$(jq -r '.fake.name' "$MACHINEKIT_CONTEXT_FILE")" = "Alice" ]
  [ "$(jq -r '.fake.email' "$MACHINEKIT_CONTEXT_FILE")" = "alice@example.com" ]
}

@test "set preserves spaces in a value" {
  context::set "fake.name" "Alice Aaronson"
  [ "$(jq -r '.fake.name' "$MACHINEKIT_CONTEXT_FILE")" = "Alice Aaronson" ]
}

@test "set does not corrupt the store when nesting under an existing scalar" {
  context::set "a" "scalar"
  run context::set "a.b.c" "deep"
  [ "$status" -ne 0 ]
  [ "$(jq -r '.a' "$MACHINEKIT_CONTEXT_FILE")" = "scalar" ]
}

# --- context::set (with --json) ---

@test "set --json stores a pre-built JSON array" {
  context::set "modules.active" '["git","mise","age"]' --json
  [ "$(jq -r '.modules.active[0]' "$MACHINEKIT_CONTEXT_FILE")" = "git" ]
}

@test "set --json stores a nested object" {
  context::set "meta" '{"version":"1","os":"darwin"}' --json
  [ "$(jq -r '.meta.os' "$MACHINEKIT_CONTEXT_FILE")" = "darwin" ]
}

@test "set --json does not corrupt the store when jq fails" {
  context::set "a" "scalar"
  run context::set "a.b" '"x"' --json
  [ "$status" -ne 0 ]
  [ "$(jq -r '.a' "$MACHINEKIT_CONTEXT_FILE")" = "scalar" ]
}

# --- context::get (orchestration: cascade + short-circuit) ---

@test "get returns the store value and does not consult env" {
  STUB_OUTPUT="from-store" mktest::stub_function context::_from_store "test.key"
  mktest::stub_function context::_from_env "test.key"
  result=$(context::get "test.key")
  [ "$result" = "from-store" ]
  mktest::assert_stub_not_called context::_from_env "test.key"
}

@test "get falls through to env on a store miss" {
  STUB_RETURN=1 mktest::stub_function context::_from_store "test.key"
  STUB_OUTPUT="from-env" mktest::stub_function context::_from_env "test.key"
  result=$(context::get "test.key")
  [ "$result" = "from-env" ]
}

@test "get returns the env value and does not consult user-config" {
  STUB_RETURN=1 mktest::stub_function context::_from_store "test.key"
  STUB_OUTPUT="from-env" mktest::stub_function context::_from_env "test.key"
  mktest::stub_function context::_from_user_config "test.key"
  result=$(context::get "test.key")
  [ "$result" = "from-env" ]
  mktest::assert_stub_not_called context::_from_user_config "test.key"
}

@test "get falls through to user-config on a store and env miss" {
  STUB_RETURN=1 mktest::stub_function context::_from_store "test.key"
  STUB_RETURN=1 mktest::stub_function context::_from_env "test.key"
  STUB_OUTPUT="from-user-config" mktest::stub_function context::_from_user_config "test.key"
  result=$(context::get "test.key")
  [ "$result" = "from-user-config" ]
}

@test "get does not prompt without --required or --prompt" {
  STUB_RETURN=1 mktest::stub_function context::_from_store
  STUB_RETURN=1 mktest::stub_function context::_from_env
  STUB_RETURN=1 mktest::stub_function context::_from_user_config
  mktest::stub_function context::_prompt
  run ! context::get "test.key"
  mktest::assert_stub_not_called context::_prompt
}

@test "get --required and --default are mutually exclusive" {
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run ! context::get "test.key" --required --default "x"
  MATCH="mutually exclusive" mktest::assert_stub_called lifecycle::fail
}

@test "get --required prompts on a full miss" {
  STUB_RETURN=1 mktest::stub_function context::_from_store
  STUB_RETURN=1 mktest::stub_function context::_from_env
  STUB_RETURN=1 mktest::stub_function context::_from_user_config
  STUB_OUTPUT="from-prompt" mktest::stub_function context::_prompt "test.key"
  result=$(context::get "test.key" --required)
  [ "$result" = "from-prompt" ]
}

@test "get --prompt alone triggers prompting and returns the value" {
  STUB_RETURN=1 mktest::stub_function context::_from_store
  STUB_RETURN=1 mktest::stub_function context::_from_env
  STUB_RETURN=1 mktest::stub_function context::_from_user_config
  STUB_OUTPUT="user-answer" mktest::stub_function context::_prompt "test.key" "--label" "Ask me"
  result=$(context::get "test.key" --prompt "Ask me")
  [ "$result" = "user-answer" ]
}

@test "get --prompt with a blank string still prompts" {
  STUB_RETURN=1 mktest::stub_function context::_from_store
  STUB_RETURN=1 mktest::stub_function context::_from_env
  STUB_RETURN=1 mktest::stub_function context::_from_user_config
  STUB_OUTPUT="user-answer" mktest::stub_function context::_prompt "test.key"
  result=$(context::get "test.key" --prompt "")
  [ "$result" = "user-answer" ]
}
@test "get --prompt alone returns 1 when user enters nothing" {
  STUB_RETURN=1 mktest::stub_function context::_from_store
  STUB_RETURN=1 mktest::stub_function context::_from_env
  STUB_RETURN=1 mktest::stub_function context::_from_user_config
  STUB_RETURN=1 mktest::stub_function context::_prompt "test.key" "--label" "Ask me"
  run ! context::get "test.key" --prompt "Ask me"
}

@test "get --required fails when prompt also misses" {
  STUB_RETURN=1 mktest::stub_function context::_from_store
  STUB_RETURN=1 mktest::stub_function context::_from_env
  STUB_RETURN=1 mktest::stub_function context::_from_user_config
  STUB_RETURN=1 mktest::stub_function context::_prompt "test.key"
  mktest::stub_function context::_fail_required "test.key"
  run ! context::get "test.key" --required
  mktest::assert_stub_called context::_fail_required "test.key"
}

@test "get --prompt passes the custom text to _prompt" {
  STUB_RETURN=1 mktest::stub_function context::_from_store
  STUB_RETURN=1 mktest::stub_function context::_from_env
  STUB_RETURN=1 mktest::stub_function context::_from_user_config
  STUB_OUTPUT="from-prompt" mktest::stub_function context::_prompt "test.key" "--label" "Custom text"
  result=$(context::get "test.key" --required --prompt "Custom text")
  [ "$result" = "from-prompt" ]
}

@test "get --prompt --secret passes --secret through to _prompt" {
  STUB_RETURN=1 mktest::stub_function context::_from_store
  STUB_RETURN=1 mktest::stub_function context::_from_env
  STUB_RETURN=1 mktest::stub_function context::_from_user_config
  STUB_OUTPUT="secret-val" mktest::stub_function context::_prompt "test.key" "--label" "Secret" "--secret"
  result=$(context::get "test.key" --prompt "Secret" --secret)
  [ "$result" = "secret-val" ]
}

@test "get --secret threads --secret to both the env and user-config readers" {
  STUB_RETURN=1 mktest::stub_function context::_from_store "test.key"
  STUB_RETURN=1 mktest::stub_function context::_from_env "test.key" "--secret"
  STUB_OUTPUT="secret-val" mktest::stub_function context::_from_user_config "test.key" "--secret"
  result=$(context::get "test.key" --secret)
  [ "$result" = "secret-val" ]
  mktest::assert_stub_called context::_from_env "test.key" "--secret"
  mktest::assert_stub_called context::_from_user_config "test.key" "--secret"
}

@test "get --default + --prompt prompts and returns default on empty response" {
  STUB_RETURN=1 mktest::stub_function context::_from_store "test.key"
  STUB_RETURN=1 mktest::stub_function context::_from_env "test.key"
  STUB_RETURN=1 mktest::stub_function context::_from_user_config "test.key"
  STUB_OUTPUT="fallback" mktest::stub_function context::_prompt "test.key" "--label" "Ask me" "--default" "fallback"
  result=$(context::get "test.key" --default "fallback" --prompt "Ask me")
  [ "$result" = "fallback" ]
}

@test "get --default returns the default on a full miss" {
  STUB_RETURN=1 mktest::stub_function context::_from_store "test.key"
  STUB_RETURN=1 mktest::stub_function context::_from_env "test.key"
  STUB_RETURN=1 mktest::stub_function context::_from_user_config "test.key"
  result=$(context::get "test.key" --default "fallback")
  [ "$result" = "fallback" ]
}

@test "get --default --store-default also stores the default" {
  STUB_RETURN=1 mktest::stub_function context::_from_store "test.key"
  STUB_RETURN=1 mktest::stub_function context::_from_env "test.key"
  STUB_RETURN=1 mktest::stub_function context::_from_user_config "test.key"
  mktest::stub_function context::set "test.key" "fallback"
  result=$(context::get "test.key" --default "fallback" --store-default)
  mktest::assert_stub_called context::set "test.key" "fallback"
  [ "$result" = "fallback" ]
}

@test "get --default does not override a cascade hit" {
  STUB_OUTPUT="from-store" mktest::stub_function context::_from_store "test.key"
  mktest::stub_function context::_from_env "test.key"
  result=$(context::get "test.key" --default "fallback")
  [ "$result" = "from-store" ]
}

@test "get --coerce delegates to the coerce function with the resolved value" {
  STUB_OUTPUT="raw_value" mktest::stub_function context::_from_store "test.key"
  STUB_OUTPUT="boolean_sentinel" mktest::stub_function context::_coerce_boolean "raw_value"
  result=$(context::get "test.key" --coerce boolean)
  [ "$result" = "boolean_sentinel" ]
}

@test "get --coerce with an unknown type fails" {
  STUB_OUTPUT="some-value" mktest::stub_function context::_from_store "test.key"
  run ! context::get "test.key" --coerce unknown
}

@test "get rejects an unknown option" {
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run ! context::get "test.key" --bogus
  MATCH="--bogus" mktest::assert_stub_called lifecycle::fail
}

# --- context::set_array / context::get_array ---

@test "set_array delegates to set --json with a JSON array" {
  mktest::stub_function context::set "modules.active" '["git","mise","age"]' "--json"
  context::set_array "modules.active" "git" "mise" "age"
  mktest::assert_stub_called context::set "modules.active" '["git","mise","age"]' "--json"
}

@test "set_array with no items delegates to set --json with an empty array" {
  mktest::stub_function context::set "modules.active" '[]' "--json"
  context::set_array "modules.active"
  mktest::assert_stub_called context::set "modules.active" '[]' "--json"
}

@test "get_array returns elements from a stored array" {
  context::set "modules.active" '["git","mise","age"]' "--json"
  result=$(context::get_array "modules.active")
  [ "$(printf '%s\n' "$result" | wc -l | tr -d ' ')" -eq 3 ]
  [ "$(printf '%s\n' "$result" | sed -n '1p')" = "git" ]
  [ "$(printf '%s\n' "$result" | sed -n '2p')" = "mise" ]
  [ "$(printf '%s\n' "$result" | sed -n '3p')" = "age" ]
}

@test "get_array returns 1 for an unset key" {
  run ! context::get_array "nonexistent.array"
}

@test "get_array returns 1 and emits nothing when the key holds a scalar" {
  context::set "not.array" "scalar"
  run context::get_array "not.array"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

# --- context::json ---

@test "json returns a valid JSON object" {
  context::set "test.key" "value"
  context::json | jq . >/dev/null
}

@test "fresh context starts as an empty object" {
  result=$(context::json)
  [ "$result" = "{}" ]
}

# --- context::seed_from_flags ---

@test "seed_from_flags seeds set MACHINEKIT_* env vars into the context store" {
  export MACHINEKIT_BLUEPRINTS_SOURCE="https://example.com/bp.git"
  export MACHINEKIT_MODE_DRY_RUN=1
  unset MACHINEKIT_MACHINE_TYPE
  context::seed_from_flags
  [ "$(context::get "blueprints.source")" = "https://example.com/bp.git" ]
  [ "$(context::get "mode.dry_run")" = "1" ]
  run ! context::_from_store "machine_type"
}

@test "seed_from_flags is a no-op when no MACHINEKIT_* env vars are set" {
  unset MACHINEKIT_BLUEPRINTS_SOURCE MACHINEKIT_BLUEPRINTS_SOURCE_PROTOCOL \
        MACHINEKIT_MACHINE_TYPE \
        MACHINEKIT_EXISTING_SSH_KEY_FILE MACHINEKIT_SSH_KEY_GENERATE MACHINEKIT_SSH_KEY_OVERWRITE \
        MACHINEKIT_EXISTING_AGE_KEY_FILE MACHINEKIT_AGE_KEY_GENERATE MACHINEKIT_AGE_KEY_OVERWRITE \
        MACHINEKIT_MODE_DRY_RUN MACHINEKIT_MODE_INTERACTIVE
  context::seed_from_flags
  [ "$(context::json)" = "{}" ]
}

# --- context::load_user_config ---

@test "load_user_config parses the defaults file at the resolved path into the cache" {
  printf 'machine_type = "personal"\n' > "$BATS_TEST_TMPDIR/defaults.toml"
  STUB_OUTPUT="$BATS_TEST_TMPDIR/defaults.toml" mktest::stub_function context::_user_config_path
  context::load_user_config
  [ "$(printf '%s' "$_MK_CONTEXT_USER_CONFIG_JSON" | jq -r '.machine_type')" = "personal" ]
}

@test "load_user_config leaves the cache empty when the defaults file is absent" {
  STUB_OUTPUT="$BATS_TEST_TMPDIR/nonexistent.toml" mktest::stub_function context::_user_config_path
  context::load_user_config
  [ -z "$_MK_CONTEXT_USER_CONFIG_JSON" ]
}

# --- context::cleanup ---

@test "cleanup removes the context file and clears the variable" {
  local file="$MACHINEKIT_CONTEXT_FILE"
  [ -f "$file" ]
  context::cleanup
  [ ! -f "$file" ]
  [ -z "${MACHINEKIT_CONTEXT_FILE:-}" ]
}

@test "cleanup is a no-op when the context file is already unset" {
  unset MACHINEKIT_CONTEXT_FILE
  context::cleanup
}

# --- context::_internal_storage_file ---

@test "_internal_storage_file creates the store, sets and exports MACHINEKIT_CONTEXT_FILE, and registers cleanup on first call" {
  unset MACHINEKIT_CONTEXT_FILE
  export _MK_TEST_OVERRIDE_SUBSHELL_DEPTH=0
  STUB_OUTPUT="$BATS_TEST_TMPDIR/store.json" mktest::stub_function mktemp
  mktest::stub_function lifecycle::register_cleanup "context::cleanup"
  context::_internal_storage_file >/dev/null
  [ "$MACHINEKIT_CONTEXT_FILE" = "$BATS_TEST_TMPDIR/store.json" ]
  [ "$(cat "$MACHINEKIT_CONTEXT_FILE")" = "{}" ]
  mktest::assert_stub_called lifecycle::register_cleanup "context::cleanup"
}

@test "_internal_storage_file returns the store path" {
  unset MACHINEKIT_CONTEXT_FILE
  export _MK_TEST_OVERRIDE_SUBSHELL_DEPTH=0
  STUB_OUTPUT="$BATS_TEST_TMPDIR/store.json" mktest::stub_function mktemp
  mktest::stub_function lifecycle::register_cleanup
  result=$(context::_internal_storage_file)
  [ "$result" = "$BATS_TEST_TMPDIR/store.json" ]
}

@test "_internal_storage_file fails when called from a subshell before the store is initialized" {
  unset MACHINEKIT_CONTEXT_FILE
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run ! context::_internal_storage_file
  MATCH="subshell" mktest::assert_stub_called lifecycle::fail
}

@test "_internal_storage_file returns existing path and does not re-initialize when already set" {
  MACHINEKIT_CONTEXT_FILE="$BATS_TEST_TMPDIR/inherited.json"
  printf '{"pre":"existing"}' > "$MACHINEKIT_CONTEXT_FILE"
  mktest::stub_function lifecycle::register_cleanup
  mktest::stub_function mktemp
  result=$(context::_internal_storage_file)
  [ "$result" = "$BATS_TEST_TMPDIR/inherited.json" ]
  [ "$(cat "$MACHINEKIT_CONTEXT_FILE")" = '{"pre":"existing"}' ]
  mktest::assert_stub_not_called lifecycle::register_cleanup
  mktest::assert_stub_not_called mktemp
}

# --- context::_coerce_boolean ---

@test "_coerce_boolean returns true for truthy values" {
  for val in 1 true yes y TRUE YES Y; do
    [ "$(context::_coerce_boolean "$val")" = "true" ]
  done
}

@test "_coerce_boolean returns false for falsy values" {
  for val in 0 false no n FALSE NO N; do
    [ "$(context::_coerce_boolean "$val")" = "false" ]
  done
}

@test "_coerce_boolean fails on an unrecognized value" {
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run ! context::_coerce_boolean "maybe"
  MATCH="maybe" mktest::assert_stub_called lifecycle::fail
}

# --- context::_var_key ---

@test "_var_key uppercases, converts dots to underscores, and preserves underscores" {
  [ "$(context::_var_key "fake.name")" = "FAKE_NAME" ]
}

@test "_var_key handles a single-component key" {
  [ "$(context::_var_key "verbose")" = "VERBOSE" ]
}

# --- context::env_var_name ---

@test "env_var_name maps a dotted key to its MACHINEKIT_ environment variable" {
  [ "$(context::env_var_name "infisical.client_secret")" = "MACHINEKIT_INFISICAL_CLIENT_SECRET" ]
}

# --- context::_from_store ---

@test "_from_store prints a stored value" {
  printf '{"test":{"key":"stored"}}' > "$MACHINEKIT_CONTEXT_FILE"
  result=$(context::_from_store "test.key")
  [ "$result" = "stored" ]
}

@test "_from_store returns 1 for an unset key" {
  run ! context::_from_store "test.key"
}

# --- context::_from_env ---

@test "_from_env resolves the MACHINEKIT_ variable and writes it back to the store" {
  export MACHINEKIT_TEST_KEY="from-env"
  STUB_OUTPUT="MACHINEKIT_TEST_KEY" mktest::stub_function context::env_var_name "test.key"
  mktest::stub_function context::set "test.key" "from-env"
  result=$(context::_from_env "test.key")
  [ "$result" = "from-env" ]
  mktest::assert_stub_called context::set "test.key" "from-env"
}

@test "_from_env with --secret returns the value but never writes it to the store" {
  export MACHINEKIT_TEST_KEY="hunter2"
  STUB_OUTPUT="MACHINEKIT_TEST_KEY" mktest::stub_function context::env_var_name "test.key"
  mktest::stub_function context::set
  result=$(context::_from_env "test.key" --secret)
  [ "$result" = "hunter2" ]
  mktest::assert_stub_not_called context::set
}

@test "_from_env returns 1 when the MACHINEKIT_ variable is unset" {
  STUB_OUTPUT="MACHINEKIT_TEST_KEY" mktest::stub_function context::env_var_name "test.key"
  run ! context::_from_env "test.key"
}

# --- context::_from_user_config ---

@test "_from_user_config resolves a key from the loaded defaults and writes it back to the store" {
  _MK_CONTEXT_USER_CONFIG_JSON='{"machine_type":"personal"}'
  mktest::stub_function context::set "machine_type" "personal"
  result=$(context::_from_user_config "machine_type")
  [ "$result" = "personal" ]
  mktest::assert_stub_called context::set "machine_type" "personal"
}

@test "_from_user_config with --secret returns the value but never writes it to the store" {
  _MK_CONTEXT_USER_CONFIG_JSON='{"infisical":{"client_secret":"hunter2"}}'
  mktest::stub_function context::set
  result=$(context::_from_user_config "infisical.client_secret" --secret)
  [ "$result" = "hunter2" ]
  mktest::assert_stub_not_called context::set
}

@test "_from_user_config resolves a nested dotted key" {
  _MK_CONTEXT_USER_CONFIG_JSON='{"ssh":{"key_generate":true}}'
  mktest::stub_function context::set "ssh.key_generate" "true"
  result=$(context::_from_user_config "ssh.key_generate")
  [ "$result" = "true" ]
}

@test "_from_user_config returns 1 when the key is absent from the defaults" {
  _MK_CONTEXT_USER_CONFIG_JSON='{"machine_type":"personal"}'
  run ! context::_from_user_config "age.key_generate"
}

@test "_from_user_config returns 1 when no defaults are loaded" {
  _MK_CONTEXT_USER_CONFIG_JSON=""
  run ! context::_from_user_config "machine_type"
}

# --- context::_user_config_path ---

@test "_user_config_path is defaults.toml under the default config dir" {
  HOME=/fake/home
  unset XDG_CONFIG_HOME
  run context::_user_config_path
  [ "$output" = "/fake/home/.config/machinekit/defaults.toml" ]
}

@test "_user_config_path honors XDG_CONFIG_HOME" {
  HOME=/fake/home
  XDG_CONFIG_HOME=/fake/home/.xdg
  run context::_user_config_path
  [ "$output" = "/fake/home/.xdg/machinekit/defaults.toml" ]
}

# --- context::_prompt_label ---

@test "_prompt_label converts a dotted key to a capitalized phrase" {
  [ "$(context::_prompt_label "fake.name")" = "Fake name" ]
}

@test "_prompt_label capitalizes a single-component key" {
  [ "$(context::_prompt_label "shell")" = "Shell" ]
}

# --- context::_prompt ---

@test "_prompt reads the response, echoes it, shows the label, and stores it" {
  mktest::stub_function input::is_interactive
  STUB_OUTPUT="Fake name" mktest::stub_function context::_prompt_label "fake.name"
  mktest::stub_function context::_prompt_hint
  mktest::stub_function context::set "fake.name" "Alice"
  printf 'Alice\n' > "$BATS_TEST_TMPDIR/tty"
  export MACHINEKIT_TTY="$BATS_TEST_TMPDIR/tty"
  run --separate-stderr context::_prompt "fake.name"
  [ "$status" -eq 0 ]
  [ "$output" = "Alice" ]
  [[ "$stderr" == *"Fake name"* ]]
  mktest::assert_stub_called context::set "fake.name" "Alice"
}

@test "_prompt with --secret returns the value but never writes it to the store" {
  mktest::stub_function input::is_interactive
  mktest::stub_function context::_prompt_label "secret.key"
  mktest::stub_function context::_prompt_hint
  mktest::stub_function context::set
  printf 'hunter2\n' > "$BATS_TEST_TMPDIR/tty"
  export MACHINEKIT_TTY="$BATS_TEST_TMPDIR/tty"
  run --separate-stderr context::_prompt "secret.key" --label "Password" --secret
  [ "$status" -eq 0 ]
  [ "$output" = "hunter2" ]
  mktest::assert_stub_not_called context::set
}

@test "_prompt uses a custom label when provided and does not call _prompt_label" {
  mktest::stub_function input::is_interactive
  mktest::stub_function context::_prompt_label
  mktest::stub_function context::_prompt_hint
  mktest::stub_function context::set "fake.name" "Alice"
  printf 'Alice\n' > "$BATS_TEST_TMPDIR/tty"
  export MACHINEKIT_TTY="$BATS_TEST_TMPDIR/tty"
  run --separate-stderr context::_prompt "fake.name" --label "Custom prompt"
  [ "$output" = "Alice" ]
  [[ "$stderr" == *"Custom prompt"* ]]
  mktest::assert_stub_not_called context::_prompt_label
}

@test "_prompt returns 1 on an empty response" {
  mktest::stub_function input::is_interactive
  STUB_OUTPUT="Fake name" mktest::stub_function context::_prompt_label "fake.name"
  mktest::stub_function context::_prompt_hint
  printf '' > "$BATS_TEST_TMPDIR/tty"
  export MACHINEKIT_TTY="$BATS_TEST_TMPDIR/tty"
  run ! context::_prompt "fake.name"
}

@test "_prompt returns the default and stores it when user enters nothing and default is provided" {
  mktest::stub_function input::is_interactive
  mktest::stub_function context::_prompt_label "fake.name"
  mktest::stub_function context::_prompt_hint
  mktest::stub_function context::set "fake.name" "fallback"
  printf '' > "$BATS_TEST_TMPDIR/tty"
  export MACHINEKIT_TTY="$BATS_TEST_TMPDIR/tty"
  result=$(context::_prompt "fake.name" --label "Enter name" --default "fallback")
  [ "$result" = "fallback" ]
  mktest::assert_stub_called context::set "fake.name" "fallback"
}

@test "_prompt includes the hint from _prompt_hint in the label" {
  mktest::stub_function input::is_interactive
  mktest::stub_function context::set
  STUB_OUTPUT=" [HINT]" mktest::stub_function context::_prompt_hint
  printf 'answer\n' > "$BATS_TEST_TMPDIR/tty"
  export MACHINEKIT_TTY="$BATS_TEST_TMPDIR/tty"
  run --separate-stderr context::_prompt "test.key" --label "Question" --default "val" --type "boolean"
  [[ "$stderr" == *"[HINT]"* ]]
}

@test "_prompt returns 1 when non-interactive" {
  STUB_RETURN=1 mktest::stub_function input::is_interactive
  run ! context::_prompt "test.key"
}

# --- context::_prompt_hint ---

@test "_prompt_hint returns [Y/n] for boolean type with true default" {
  [ "$(context::_prompt_hint "boolean" "1" "true")" = " [Y/n]" ]
}

@test "_prompt_hint returns [y/N] for boolean type with false default" {
  [ "$(context::_prompt_hint "boolean" "1" "false")" = " [y/N]" ]
}

@test "_prompt_hint returns [y/n] for boolean type without a default" {
  [ "$(context::_prompt_hint "boolean" "0" "")" = " [y/n]" ]
}

@test "_prompt_hint returns [value] for non-boolean type with a default" {
  [ "$(context::_prompt_hint "" "1" "green")" = " [green]" ]
}

@test "_prompt_hint returns empty for non-boolean type without a default" {
  [ -z "$(context::_prompt_hint "" "0" "")" ]
}

# --- context::_fail_required ---

@test "_fail_required exits non-zero and reports the key, env var, and --help hint" {
  mktest::stub_function logging::error
  run context::_fail_required "whatever.juice_box"
  [ "$status" -ne 0 ]
  MATCH="whatever\.juice_box" mktest::assert_stub_called logging::error
  MATCH="MACHINEKIT_WHATEVER_JUICE_BOX" mktest::assert_stub_called logging::error
  MATCH="\-\-help" mktest::assert_stub_called logging::error
}
