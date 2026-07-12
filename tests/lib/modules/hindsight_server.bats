#!/usr/bin/env bats
# Tests for lib/modules/hindsight_server.sh

load "${BATS_TEST_DIRNAME}/../../test_helper"

setup() {
  # shellcheck source=../../../lib/modules/hindsight_server.sh
  source "$MACHINEKIT_DIR/lib/modules/hindsight_server.sh"

  # Allow-only logging collaborators — logging is mechanism, not contract.
  mktest::stub_function logging::step
  mktest::stub_function logging::info
  mktest::stub_function logging::warn
  mktest::stub_function logging::success
  mktest::stub_function logging::dry_run
  mktest::stub_function logging::debug
}

# --- hindsight_server::requires ---

@test "requires container_manager, postgres, and the backends for its declared secrets" {
  STUB_OUTPUT=$'hindsight/llm_api_key\ttrue\tfalse\nhindsight/tenant_api_key\ttrue\ttrue' \
    mktest::stub_function hindsight_server::declared_secrets
  secrets::declared_backend_requirements() { cat > "$BATS_TEST_TMPDIR/br.stdin"; printf 'age\n'; }
  run hindsight_server::requires
  [ "$status" -eq 0 ]
  [ "$output" = $'container_manager\npostgres\nage' ]
  # The declared-secret rows are piped to the shared backend classifier.
  [ "$(cat "$BATS_TEST_TMPDIR/br.stdin")" = $'hindsight/llm_api_key\ttrue\tfalse\nhindsight/tenant_api_key\ttrue\ttrue' ]
}

# --- hindsight_server::preflight ---

@test "preflight passes when the provider is set and the llm key is available" {
  STUB_OUTPUT="anthropic" mktest::stub_function hindsight_server::_llm_provider
  mktest::stub_function hindsight_server::_llm_key_available
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  hindsight_server::preflight
  mktest::assert_stub_not_called lifecycle::fail
}

@test "preflight fails when no llm_provider is configured" {
  STUB_OUTPUT="" mktest::stub_function hindsight_server::_llm_provider
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run ! hindsight_server::preflight
  MATCH="llm_provider" mktest::assert_stub_called lifecycle::fail
}

@test "preflight fails when the llm key is unavailable" {
  STUB_OUTPUT="anthropic" mktest::stub_function hindsight_server::_llm_provider
  STUB_RETURN=1 mktest::stub_function hindsight_server::_llm_key_available
  STUB_OUTPUT="hindsight/llm_api_key" mktest::stub_function hindsight::secrets::name "llm_api_key"
  STUB_OUTPUT=".config/hindsight/hindsight.env" mktest::stub_function hindsight_server::_env_rel
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run ! hindsight_server::preflight
  MATCH="llm_api_key" mktest::assert_stub_called lifecycle::fail
}

# --- hindsight_server::_llm_key_available ---

@test "_llm_key_available is true when the llm key is provided in the pool" {
  mktest::stub_function hindsight::secrets::provided "llm_api_key"
  hindsight_server::_llm_key_available
}

@test "_llm_key_available is true when an env file already exists" {
  STUB_RETURN=1 mktest::stub_function hindsight::secrets::provided "llm_api_key"
  local env; env=$(mktemp)
  STUB_OUTPUT="$env" mktest::stub_function hindsight_server::_env_path
  hindsight_server::_llm_key_available
}

@test "_llm_key_available is false when neither the pool key nor an env file is present" {
  STUB_RETURN=1 mktest::stub_function hindsight::secrets::provided "llm_api_key"
  STUB_OUTPUT="/nonexistent/hindsight.env" mktest::stub_function hindsight_server::_env_path
  run ! hindsight_server::_llm_key_available
}

# --- hindsight_server::declared_secrets ---

@test "declared_secrets declares the LLM key non-generatable and the generatable trio" {
  STUB_OUTPUT="hindsight/llm_api_key"    mktest::stub_function hindsight::secrets::name llm_api_key
  STUB_OUTPUT="hindsight/tenant_api_key" mktest::stub_function hindsight::secrets::name tenant_api_key
  STUB_OUTPUT="hindsight/db_password"    mktest::stub_function hindsight::secrets::name db_password
  STUB_OUTPUT="hindsight/cp_access_key"  mktest::stub_function hindsight::secrets::name cp_access_key
  run hindsight_server::declared_secrets
  [ "$status" -eq 0 ]
  [ "$output" = $'hindsight/llm_api_key\ttrue\tfalse\nhindsight/tenant_api_key\ttrue\ttrue\nhindsight/db_password\ttrue\ttrue\nhindsight/cp_access_key\ttrue\ttrue' ]
}

# --- hindsight_server::install ---

@test "install installs pgvector before provisioning, then ensures the env file and places the compose" {
  mktest::stub_function brew::install_formula "pgvector"
  mktest::stub_function hindsight_server::_provision_database
  mktest::stub_function hindsight_server::_ensure_env_file
  mktest::stub_function hindsight_server::_place_compose
  hindsight_server::install
  # Order is the contract: the vector extension (in _provision_database) needs
  # the pgvector formula already installed.
  mktest::assert_stub_called_in_order brew::install_formula "pgvector"
  mktest::assert_stub_called_in_order hindsight_server::_provision_database
  mktest::assert_stub_called hindsight_server::_ensure_env_file
  mktest::assert_stub_called hindsight_server::_place_compose
}

# --- hindsight_server::post_apply ---

@test "post_apply provisions the role and starts the server, then health-checks" {
  STUB_RETURN=1 mktest::stub_function input::is_dry_run
  mktest::stub_function hindsight_server::_provision_role
  mktest::stub_function hindsight_server::_compose_up
  mktest::stub_function hindsight_server::_health_check
  hindsight_server::post_apply
  # Order is the contract: the role and container must be up before the probe.
  mktest::assert_stub_called_in_order hindsight_server::_provision_role
  mktest::assert_stub_called_in_order hindsight_server::_compose_up
  mktest::assert_stub_called_in_order hindsight_server::_health_check
}

@test "post_apply in dry-run reports and touches nothing" {
  mktest::stub_function input::is_dry_run
  mktest::stub_function hindsight_server::_provision_role
  mktest::stub_function hindsight_server::_compose_up
  mktest::stub_function hindsight_server::_health_check
  hindsight_server::post_apply
  mktest::assert_stub_not_called hindsight_server::_provision_role
  mktest::assert_stub_not_called hindsight_server::_compose_up
  mktest::assert_stub_not_called hindsight_server::_health_check
  mktest::assert_stub_called logging::dry_run
}

# --- hindsight_server::_provision_database ---

@test "_provision_database creates the database, then the vector extension in it" {
  STUB_OUTPUT="hsdb" mktest::stub_function hindsight_server::_db_name
  mktest::stub_function postgres::ensure_database "hsdb"
  mktest::stub_function postgres::ensure_extension "hsdb" "vector"
  hindsight_server::_provision_database
  # Order is the contract: the extension needs the database to exist first.
  mktest::assert_stub_called_in_order postgres::ensure_database "hsdb"
  mktest::assert_stub_called_in_order postgres::ensure_extension "hsdb" "vector"
}

# --- hindsight_server::_provision_role ---

@test "_provision_role creates the role, then makes it own the database" {
  STUB_OUTPUT="hsuser" mktest::stub_function hindsight_server::_db_user
  STUB_OUTPUT="hspass" mktest::stub_function hindsight_server::_db_password
  STUB_OUTPUT="hsdb" mktest::stub_function hindsight_server::_db_name
  mktest::stub_function postgres::ensure_role "hsuser" "hspass"
  mktest::stub_function postgres::ensure_database "hsdb" "hsuser"
  hindsight_server::_provision_role
  # Order is the contract: the role must exist before it can own the db (which
  # _provision_database already created under the superuser during install).
  mktest::assert_stub_called_in_order postgres::ensure_role "hsuser" "hspass"
  mktest::assert_stub_called_in_order postgres::ensure_database "hsdb" "hsuser"
}

# --- hindsight_server::_ensure_env_file ---

@test "_ensure_env_file reuses an existing env file untouched" {
  local env; env=$(mktemp)
  STUB_OUTPUT="$env" mktest::stub_function hindsight_server::_env_path
  mktest::stub_function hindsight_server::_assemble_env_file
  hindsight_server::_ensure_env_file
  mktest::assert_stub_not_called hindsight_server::_assemble_env_file
  mktest::assert_stub_called logging::info
}

@test "_ensure_env_file in dry-run reports without assembling" {
  STUB_OUTPUT="/nonexistent/hindsight.env" mktest::stub_function hindsight_server::_env_path
  mktest::stub_function input::is_dry_run
  mktest::stub_function hindsight_server::_assemble_env_file
  hindsight_server::_ensure_env_file
  mktest::assert_stub_not_called hindsight_server::_assemble_env_file
  mktest::assert_stub_called logging::dry_run
}

@test "_ensure_env_file assembles when absent and not in dry-run" {
  STUB_OUTPUT="/nonexistent/hindsight.env" mktest::stub_function hindsight_server::_env_path
  STUB_RETURN=1 mktest::stub_function input::is_dry_run
  mktest::stub_function hindsight_server::_assemble_env_file "/nonexistent/hindsight.env"
  hindsight_server::_ensure_env_file
  mktest::assert_stub_called hindsight_server::_assemble_env_file "/nonexistent/hindsight.env"
}

# --- hindsight_server::_assemble_env_file ---

@test "_assemble_env_file resolves the secrets and writes them, announcing generated ones" {
  STUB_OUTPUT="llm-key" mktest::stub_function hindsight_server::_resolve_llm_key
  STUB_OUTPUT="tenant-key" mktest::stub_function hindsight::secrets::resolve "tenant_api_key"
  STUB_OUTPUT="db-pass" mktest::stub_function hindsight::secrets::resolve "db_password"
  STUB_OUTPUT="ui-pass" mktest::stub_function hindsight_server::_resolve_cp_access_key "/path/env"
  mktest::stub_function hindsight_server::_write_env_file "/path/env" "llm-key" "tenant-key" "db-pass" "ui-pass"
  # Neither generated secret was provided, so both are announced.
  STUB_RETURN=1 mktest::stub_function hindsight::secrets::provided "tenant_api_key"
  STUB_RETURN=1 mktest::stub_function hindsight::secrets::provided "db_password"
  mktest::stub_function hindsight::secrets::announce_generated_tenant "/path/env" "HINDSIGHT_API_TENANT_API_KEY"
  mktest::stub_function hindsight_server::_announce_db_password
  hindsight_server::_assemble_env_file "/path/env"
  mktest::assert_stub_called hindsight_server::_write_env_file "/path/env" "llm-key" "tenant-key" "db-pass" "ui-pass"
  mktest::assert_stub_called hindsight::secrets::announce_generated_tenant "/path/env" "HINDSIGHT_API_TENANT_API_KEY"
  mktest::assert_stub_called hindsight_server::_announce_db_password
}

@test "_assemble_env_file does not announce secrets that were provided" {
  STUB_OUTPUT="llm-key" mktest::stub_function hindsight_server::_resolve_llm_key
  STUB_OUTPUT="tenant-key" mktest::stub_function hindsight::secrets::resolve "tenant_api_key"
  STUB_OUTPUT="db-pass" mktest::stub_function hindsight::secrets::resolve "db_password"
  STUB_OUTPUT="ui-pass" mktest::stub_function hindsight_server::_resolve_cp_access_key
  mktest::stub_function hindsight_server::_write_env_file
  # Both provided → neither announced.
  mktest::stub_function hindsight::secrets::provided "tenant_api_key"
  mktest::stub_function hindsight::secrets::provided "db_password"
  mktest::stub_function hindsight::secrets::announce_generated_tenant
  mktest::stub_function hindsight_server::_announce_db_password
  hindsight_server::_assemble_env_file "/path/env"
  mktest::assert_stub_not_called hindsight::secrets::announce_generated_tenant
  mktest::assert_stub_not_called hindsight_server::_announce_db_password
}

# --- hindsight_server::_resolve_llm_key ---

@test "_resolve_llm_key returns the provided llm key" {
  mktest::stub_function hindsight::secrets::provided "llm_api_key"
  STUB_OUTPUT="llm-key" mktest::stub_function hindsight::secrets::resolve "llm_api_key"
  run hindsight_server::_resolve_llm_key
  [ "$output" = "llm-key" ]
}

@test "_resolve_llm_key fails when the llm key is not provided" {
  STUB_RETURN=1 mktest::stub_function hindsight::secrets::provided "llm_api_key"
  STUB_OUTPUT="hindsight/llm_api_key" mktest::stub_function hindsight::secrets::name "llm_api_key"
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  mktest::stub_function hindsight::secrets::resolve
  run ! hindsight_server::_resolve_llm_key
  MATCH="llm_api_key" mktest::assert_stub_called lifecycle::fail
}

# --- hindsight_server::_resolve_cp_access_key ---

@test "_resolve_cp_access_key returns the provided secret without prompting" {
  mktest::stub_function hindsight::secrets::provided "cp_access_key"
  STUB_OUTPUT="pool-pw" mktest::stub_function hindsight::secrets::resolve "cp_access_key"
  mktest::stub_function context::get
  run hindsight_server::_resolve_cp_access_key "/path/env"
  [ "$output" = "pool-pw" ]
  mktest::assert_stub_not_called context::get
}

@test "_resolve_cp_access_key returns an interactively entered password, no generate or announce" {
  STUB_RETURN=1 mktest::stub_function hindsight::secrets::provided "cp_access_key"
  STUB_OUTPUT="typed-pw" mktest::stub_function context::get
  mktest::stub_function hindsight::secrets::resolve "cp_access_key"
  mktest::stub_function hindsight_server::_announce_cp_access
  run hindsight_server::_resolve_cp_access_key "/path/env"
  [ "$output" = "typed-pw" ]
  mktest::assert_stub_not_called hindsight::secrets::resolve
  mktest::assert_stub_not_called hindsight_server::_announce_cp_access
}

@test "_resolve_cp_access_key generates and announces when neither provided nor entered" {
  STUB_RETURN=1 mktest::stub_function hindsight::secrets::provided "cp_access_key"
  STUB_RETURN=1 mktest::stub_function context::get
  STUB_OUTPUT="gen-pw" mktest::stub_function hindsight::secrets::resolve "cp_access_key"
  mktest::stub_function hindsight_server::_announce_cp_access "/path/env"
  run hindsight_server::_resolve_cp_access_key "/path/env"
  [ "$output" = "gen-pw" ]
  mktest::assert_stub_called hindsight_server::_announce_cp_access "/path/env"
}

# --- hindsight_server::_write_env_file ---

@test "_write_env_file writes the keys to a 600 file, creating the dir" {
  local dest; dest="$(mktemp -d)/sub/hindsight.env"
  hindsight_server::_write_env_file "$dest" "llm-key" "tenant-key" "db-pass" "ui-pass"
  [ "$(mktest::file_mode "$dest")" = "600" ]
  run cat "$dest"
  [[ "$output" == *"HINDSIGHT_API_LLM_API_KEY=llm-key"* ]]
  [[ "$output" == *"HINDSIGHT_API_TENANT_API_KEY=tenant-key"* ]]
  # The control plane authenticates to the API with the tenant key under its own name.
  [[ "$output" == *"HINDSIGHT_CP_DATAPLANE_API_KEY=tenant-key"* ]]
  # And gates its own UI with the separate access password.
  [[ "$output" == *"HINDSIGHT_CP_ACCESS_KEY=ui-pass"* ]]
  [[ "$output" == *"MACHINEKIT_HINDSIGHT_DB_PASSWORD=db-pass"* ]]
}

# --- hindsight_server::_place_compose ---

@test "_place_compose in dry-run reports without writing" {
  mktest::stub_function input::is_dry_run
  mktest::stub_function hindsight_server::_render_compose
  hindsight_server::_place_compose
  mktest::assert_stub_not_called hindsight_server::_render_compose
  mktest::assert_stub_called logging::dry_run
}

@test "_place_compose writes the rendered compose to the compose path, creating the dir" {
  STUB_RETURN=1 mktest::stub_function input::is_dry_run
  local dest; dest="$(mktemp -d)/sub/docker-compose.yaml"
  STUB_OUTPUT="$dest" mktest::stub_function hindsight_server::_compose_path
  STUB_OUTPUT="rendered-compose" mktest::stub_function hindsight_server::_render_compose
  hindsight_server::_place_compose
  [ "$(cat "$dest")" = "rendered-compose" ]
}

# --- hindsight_server::_render_compose ---

@test "_render_compose reflects the image, port, env file, env vars, and network" {
  STUB_OUTPUT="ghcr.io/example/hindsight:vX" mktest::stub_function hindsight_server::_image
  STUB_OUTPUT="1234" mktest::stub_function hindsight_server::_api_port
  STUB_OUTPUT="5678" mktest::stub_function hindsight_server::_ui_port
  STUB_OUTPUT="/path/hindsight.env" mktest::stub_function hindsight_server::_env_path
  STUB_OUTPUT="anthropic" mktest::stub_function hindsight_server::_llm_provider
  STUB_OUTPUT="" mktest::stub_function hindsight_server::_llm_model
  STUB_OUTPUT="" mktest::stub_function hindsight_server::_llm_base_url
  STUB_OUTPUT="postgresql://hs:\${MACHINEKIT_HINDSIGHT_DB_PASSWORD}@host.docker.internal:5432/hs" \
    mktest::stub_function hindsight_server::_database_url
  run hindsight_server::_render_compose
  [ "$status" -eq 0 ]
  [[ "$output" == *"ghcr.io/example/hindsight:vX"* ]]
  [[ "$output" == *"1234:8888"* ]]
  [[ "$output" == *"5678:9999"* ]]
  # The override moves only the host side; the container port stays pinned at 8888.
  [[ "$output" == *'HINDSIGHT_API_PORT: "8888"'* ]]
  [[ "$output" != *'HINDSIGHT_API_PORT: "1234"'* ]]
  [[ "$output" == *"/path/hindsight.env"* ]]
  [[ "$output" == *'HINDSIGHT_API_LLM_PROVIDER: "anthropic"'* ]]
  # shellcheck disable=SC2016  # the placeholder is meant to stay literal
  [[ "$output" == *'HINDSIGHT_API_DATABASE_URL: "postgresql://hs:${MACHINEKIT_HINDSIGHT_DB_PASSWORD}@host.docker.internal:5432/hs"'* ]]
  [[ "$output" == *'HINDSIGHT_API_RUN_MIGRATIONS_ON_STARTUP: "true"'* ]]
  [[ "$output" == *"networks:"* ]]
  [[ "$output" == *"machinekit:"* ]]
  [[ "$output" == *"external: true"* ]]
  # Model and base URL omitted when unset, so Hindsight applies its own defaults.
  [[ "$output" != *"HINDSIGHT_API_LLM_MODEL"* ]]
  [[ "$output" != *"HINDSIGHT_API_LLM_BASE_URL"* ]]
}

@test "_render_compose includes the llm model when one is configured" {
  STUB_OUTPUT="ghcr.io/example/hindsight:vX" mktest::stub_function hindsight_server::_image
  STUB_OUTPUT="1234" mktest::stub_function hindsight_server::_api_port
  STUB_OUTPUT="5678" mktest::stub_function hindsight_server::_ui_port
  STUB_OUTPUT="/path/hindsight.env" mktest::stub_function hindsight_server::_env_path
  STUB_OUTPUT="anthropic" mktest::stub_function hindsight_server::_llm_provider
  STUB_OUTPUT="claude-opus-4-8" mktest::stub_function hindsight_server::_llm_model
  STUB_OUTPUT="" mktest::stub_function hindsight_server::_llm_base_url
  STUB_OUTPUT="postgresql://hs@host.docker.internal:5432/hs" mktest::stub_function hindsight_server::_database_url
  run hindsight_server::_render_compose
  [ "$status" -eq 0 ]
  [[ "$output" == *'HINDSIGHT_API_LLM_MODEL: "claude-opus-4-8"'* ]]
}

@test "_render_compose includes the llm base url when one is configured" {
  STUB_OUTPUT="ghcr.io/example/hindsight:vX" mktest::stub_function hindsight_server::_image
  STUB_OUTPUT="1234" mktest::stub_function hindsight_server::_api_port
  STUB_OUTPUT="5678" mktest::stub_function hindsight_server::_ui_port
  STUB_OUTPUT="/path/hindsight.env" mktest::stub_function hindsight_server::_env_path
  STUB_OUTPUT="anthropic" mktest::stub_function hindsight_server::_llm_provider
  STUB_OUTPUT="" mktest::stub_function hindsight_server::_llm_model
  STUB_OUTPUT="https://azure.example/openai" mktest::stub_function hindsight_server::_llm_base_url
  STUB_OUTPUT="postgresql://hs@host.docker.internal:5432/hs" mktest::stub_function hindsight_server::_database_url
  run hindsight_server::_render_compose
  [ "$status" -eq 0 ]
  [[ "$output" == *'HINDSIGHT_API_LLM_BASE_URL: "https://azure.example/openai"'* ]]
}

# --- hindsight_server::_database_url ---

@test "_database_url splices the password placeholder into the container url" {
  STUB_OUTPUT="hsdb" mktest::stub_function hindsight_server::_db_name
  STUB_OUTPUT="hsuser" mktest::stub_function hindsight_server::_db_user
  STUB_OUTPUT="postgresql://hsuser@host.docker.internal:5432/hsdb" \
    mktest::stub_function postgres::connection_string "hsdb" "hsuser" "container"
  run hindsight_server::_database_url
  # shellcheck disable=SC2016  # the placeholder is meant to stay literal
  [ "$output" = 'postgresql://hsuser:${MACHINEKIT_HINDSIGHT_DB_PASSWORD}@host.docker.internal:5432/hsdb' ]
}

# --- hindsight_server::_compose_up ---

@test "_compose_up runs compose through container_manager::_docker against the placed files" {
  STUB_OUTPUT="/path/docker-compose.yaml" mktest::stub_function hindsight_server::_compose_path
  STUB_OUTPUT="/path/hindsight.env" mktest::stub_function hindsight_server::_env_path
  mktest::stub_function container_manager::_docker
  hindsight_server::_compose_up
  mktest::assert_stub_called container_manager::_docker \
    "compose" "-f" "/path/docker-compose.yaml" "--env-file" "/path/hindsight.env" "up" "-d"
}

# --- hindsight_server::_health_check ---

@test "_health_check probes the api port and stays quiet on success" {
  STUB_OUTPUT="8888" mktest::stub_function hindsight_server::_api_port
  mktest::stub_function curl
  hindsight_server::_health_check
  mktest::assert_stub_not_called logging::warn
}

@test "_health_check warns when the probe does not pass within the budget" {
  STUB_OUTPUT="8888" mktest::stub_function hindsight_server::_api_port
  STUB_RETURN=1 mktest::stub_function curl
  mktest::stub_function sleep   # don't actually wait out the poll budget
  hindsight_server::_health_check
  mktest::assert_stub_called logging::warn
}

# --- hindsight_server::_db_password ---

@test "_db_password reads the machinekit db password key from the env file" {
  local env; env=$(mktemp)
  printf 'HINDSIGHT_API_PORT=8888\nMACHINEKIT_HINDSIGHT_DB_PASSWORD=s3cr3t\n' > "$env"
  STUB_OUTPUT="$env" mktest::stub_function hindsight_server::_env_path
  run hindsight_server::_db_password
  [ "$output" = "s3cr3t" ]
}

@test "_db_password fails when the key is absent from the env file" {
  local env; env=$(mktemp)
  printf 'HINDSIGHT_API_PORT=8888\n' > "$env"
  STUB_OUTPUT="$env" mktest::stub_function hindsight_server::_env_path
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run ! hindsight_server::_db_password
  mktest::assert_stub_called lifecycle::fail
}

# --- hindsight_server::_env_rel ---

@test "_env_rel is the decoded home-relative destination of the env file" {
  run hindsight_server::_env_rel
  [ "$output" = ".config/hindsight/hindsight.env" ]
}

# --- hindsight_server::_env_path ---

@test "_env_path anchors the decoded env destination under HOME" {
  STUB_OUTPUT=".config/hindsight/hindsight.env" mktest::stub_function hindsight_server::_env_rel
  run hindsight_server::_env_path
  [ "$output" = "$HOME/.config/hindsight/hindsight.env" ]
}

# --- hindsight_server::_compose_path ---

@test "_compose_path points at the compose file under the home config dir" {
  run hindsight_server::_compose_path
  [ "$output" = "$HOME/.config/hindsight/docker-compose.yaml" ]
}

# --- hindsight_server::_llm_provider ---

@test "_llm_provider reads module.hindsight_server.llm_provider with no default" {
  STUB_OUTPUT="openai" mktest::stub_function config::get \
    "module.hindsight_server.llm_provider" --default ""
  run hindsight_server::_llm_provider
  [ "$output" = "openai" ]
}

# --- hindsight_server::_db_name ---

@test "_db_name reads module.hindsight_server.db_name, defaulting to hindsight" {
  STUB_OUTPUT="mem" mktest::stub_function config::get \
    "module.hindsight_server.db_name" --default "$_HINDSIGHT_SERVER_DEFAULT_DB"
  run hindsight_server::_db_name
  [ "$output" = "mem" ]
}

# --- hindsight_server::_db_user ---

@test "_db_user reads module.hindsight_server.db_user, defaulting to hindsight" {
  STUB_OUTPUT="memuser" mktest::stub_function config::get \
    "module.hindsight_server.db_user" --default "$_HINDSIGHT_SERVER_DEFAULT_USER"
  run hindsight_server::_db_user
  [ "$output" = "memuser" ]
}

# --- hindsight_server::_image ---

# --- hindsight_server::_ui_port ---

@test "_ui_port reads module.hindsight_server.ui_port, defaulting to the constant" {
  STUB_OUTPUT="4321" mktest::stub_function config::get \
    "module.hindsight_server.ui_port" --default "$_HINDSIGHT_SERVER_DEFAULT_UI_PORT"
  run hindsight_server::_ui_port
  [ "$output" = "4321" ]
}

@test "_image reads module.hindsight_server.image, defaulting to the bundled image" {
  STUB_OUTPUT="ghcr.io/x/y:z" mktest::stub_function config::get \
    "module.hindsight_server.image" --default "$_HINDSIGHT_SERVER_DEFAULT_IMAGE"
  run hindsight_server::_image
  [ "$output" = "ghcr.io/x/y:z" ]
}

# --- hindsight_server::_api_port ---

@test "_api_port reads module.hindsight_server.api_port, defaulting to 8888" {
  STUB_OUTPUT="9000" mktest::stub_function config::get \
    "module.hindsight_server.api_port" --default "$_HINDSIGHT_SERVER_DEFAULT_API_PORT"
  run hindsight_server::_api_port
  [ "$output" = "9000" ]
}
