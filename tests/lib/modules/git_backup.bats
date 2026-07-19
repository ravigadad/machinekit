#!/usr/bin/env bats
# Tests for lib/modules/git_backup.sh — the install-time wiring of the periodic
# git backup. The push logic itself is tested in git_backup/push.bats; the
# launchd/systemd load is the runtime-unverified seam and is stubbed here.

load "${BATS_TEST_DIRNAME}/../../test_helper"

setup() {
  # shellcheck source=../../../lib/modules/git_backup.sh
  source "$MACHINEKIT_DIR/lib/modules/git_backup.sh"
  mktest::stub_function logging::step
  mktest::stub_function logging::info
  mktest::stub_function logging::debug
  mktest::stub_function logging::warn
  mktest::stub_function logging::success
  mktest::stub_function logging::dry_run
}

# --- requires ---

@test "requires pipes its declared key secrets through the backend-requirements helper and emits the result" {
  STUB_OUTPUT=$'git_backup/ssh_keys/deploy\ttrue\tfalse\ngit_backup/ssh_keys/mirror\ttrue\tfalse' \
    mktest::stub_function git_backup::declared_secrets
  secrets::declared_backend_requirements() { cat > "$BATS_TEST_TMPDIR/br.stdin"; printf 'age\nsecrets_manager\n'; }
  run git_backup::requires
  [ "$status" -eq 0 ]
  [ "$output" = $'age\nsecrets_manager' ]
  # The module hands its declared-secret rows to the shared classifier verbatim.
  [ "$(cat "$BATS_TEST_TMPDIR/br.stdin")" = $'git_backup/ssh_keys/deploy\ttrue\tfalse\ngit_backup/ssh_keys/mirror\ttrue\tfalse' ]
}

@test "requires nothing when no ssh_key is referenced (no secrets declared)" {
  mktest::stub_function git_backup::declared_secrets
  secrets::declared_backend_requirements() { cat > /dev/null; }
  run git_backup::requires
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- preflight ---

@test "preflight is a no-op when no folders are configured" {
  STUB_OUTPUT="" mktest::stub_function git_backup::_folders
  mktest::stub_function git_backup::_validate_folders
  mktest::stub_function git_backup::_validate_ignores
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  git_backup::preflight
  mktest::assert_stub_not_called git_backup::_validate_folders
  mktest::assert_stub_not_called git_backup::_validate_ignores
  mktest::assert_stub_not_called lifecycle::fail
}

@test "preflight validates folders, ignores, and keys, then warns single-writer" {
  STUB_OUTPUT='[{"path":"/a","remote":"r1"}]' mktest::stub_function git_backup::_folders
  mktest::stub_function git_backup::_validate_folders '[{"path":"/a","remote":"r1"}]'
  mktest::stub_function git_backup::_validate_ignores '[{"path":"/a","remote":"r1"}]'
  mktest::stub_function git_backup::_validate_keys
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  git_backup::preflight
  mktest::assert_stub_called git_backup::_validate_folders '[{"path":"/a","remote":"r1"}]'
  mktest::assert_stub_called git_backup::_validate_ignores '[{"path":"/a","remote":"r1"}]'
  mktest::assert_stub_called git_backup::_validate_keys
  mktest::assert_stub_called logging::warn
  mktest::assert_stub_not_called lifecycle::fail
}

# --- declared_secrets ---

@test "declared_secrets declares each referenced ssh key required and not generatable" {
  STUB_OUTPUT=$'deploy\nmirror' mktest::stub_function git_backup::_referenced_key_names
  STUB_OUTPUT="git_backup/ssh_keys/deploy" mktest::stub_function git_backup::_secret_name deploy
  STUB_OUTPUT="git_backup/ssh_keys/mirror" mktest::stub_function git_backup::_secret_name mirror
  run git_backup::declared_secrets
  [ "$status" -eq 0 ]
  [ "$output" = $'git_backup/ssh_keys/deploy\ttrue\tfalse\ngit_backup/ssh_keys/mirror\ttrue\tfalse' ]
}

@test "declared_secrets emits nothing when no folder references an ssh key" {
  STUB_OUTPUT="" mktest::stub_function git_backup::_referenced_key_names
  mktest::stub_function git_backup::_secret_name
  run git_backup::declared_secrets
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  mktest::assert_stub_not_called git_backup::_secret_name
}

# --- install ---

@test "install is a no-op when no folders are configured" {
  STUB_OUTPUT="" mktest::stub_function git_backup::_folders
  mktest::stub_function git_backup::_install_keys
  git_backup::install
  mktest::assert_stub_not_called git_backup::_install_keys
  mktest::assert_stub_called logging::debug
}

@test "install reports and does nothing in dry-run" {
  STUB_OUTPUT='[{"path":"/a","remote":"r1"}]' mktest::stub_function git_backup::_folders
  mktest::stub_function input::is_dry_run
  STUB_OUTPUT="300" mktest::stub_function git_backup::_interval
  mktest::stub_function git_backup::_install_keys
  git_backup::install
  mktest::assert_stub_not_called git_backup::_install_keys
  mktest::assert_stub_called logging::dry_run
}

@test "install lays down the keys, manifest, script, and service" {
  STUB_OUTPUT='[{"path":"/a","remote":"r1"}]' mktest::stub_function git_backup::_folders
  STUB_RETURN=1 mktest::stub_function input::is_dry_run
  mktest::stub_function git_backup::_install_keys
  mktest::stub_function git_backup::_write_manifest
  mktest::stub_function git_backup::_apply_gitignores
  mktest::stub_function git_backup::_install_push_script
  mktest::stub_function git_backup::_install_service
  git_backup::install
  mktest::assert_stub_called git_backup::_install_keys
  mktest::assert_stub_called git_backup::_write_manifest
  mktest::assert_stub_called git_backup::_apply_gitignores
  mktest::assert_stub_called git_backup::_install_push_script
  mktest::assert_stub_called git_backup::_install_service
}

# --- postflight_info ---

@test "postflight_info reports each folder's destination and delegates cadence to _human_interval" {
  STUB_OUTPUT='[{"path":"~/.agents","remote":"git@github.com:me/dotagents.git"}]' \
    mktest::stub_function git_backup::_folders
  STUB_OUTPUT="1800" mktest::stub_function git_backup::_interval
  STUB_OUTPUT="CADENCE" mktest::stub_function git_backup::_human_interval 1800
  run git_backup::postflight_info
  [[ "$output" == *"~/.agents"* ]]
  [[ "$output" == *"git@github.com:me/dotagents.git"* ]]
  # The rendered cadence comes from the collaborator, not this unit — _human_interval
  # owns the seconds→string mapping (tested directly below).
  [[ "$output" == *"CADENCE"* ]]
  mktest::assert_stub_called git_backup::_human_interval 1800
}

@test "postflight_info emits one line per backed-up folder" {
  STUB_OUTPUT='[{"path":"/a","remote":"r1"},{"path":"/b","remote":"r2"}]' \
    mktest::stub_function git_backup::_folders
  STUB_OUTPUT="3600" mktest::stub_function git_backup::_interval
  STUB_OUTPUT="CADENCE" mktest::stub_function git_backup::_human_interval 3600
  run git_backup::postflight_info
  [ "${#lines[@]}" -eq 2 ]
  [[ "$output" == *"/a"* ]]
  [[ "$output" == *"/b"* ]]
}

@test "postflight_info emits nothing when no folders are configured" {
  STUB_OUTPUT="" mktest::stub_function git_backup::_folders
  run git_backup::postflight_info
  [ -z "$output" ]
}

# --- _human_interval ---

@test "_human_interval renders whole hours, minutes, or falls back to seconds" {
  run git_backup::_human_interval 3600
  [ "$output" = "1h" ]
  run git_backup::_human_interval 1800
  [ "$output" = "30m" ]
  run git_backup::_human_interval 90
  [ "$output" = "90s" ]
}

# --- _validate_folders ---

@test "_validate_folders passes a well-formed folder set" {
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  git_backup::_validate_folders '[{"path":"/a","remote":"r1"},{"path":"/b","remote":"r2"}]'
  mktest::assert_stub_not_called lifecycle::fail
}

@test "_validate_folders fails when an entry is missing its remote" {
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run ! git_backup::_validate_folders '[{"path":"/a"}]'
  MATCH="path and a remote" mktest::assert_stub_called lifecycle::fail
}

@test "_validate_folders fails when an entry has an empty path" {
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run ! git_backup::_validate_folders '[{"path":"","remote":"r1"}]'
  MATCH="path and a remote" mktest::assert_stub_called lifecycle::fail
}

# --- _validate_ignores ---

@test "_validate_ignores passes the common defaults-on, no-patterns folder" {
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  git_backup::_validate_ignores '[{"path":"/a","remote":"r1"}]'
  mktest::assert_stub_not_called lifecycle::fail
  mktest::assert_stub_not_called logging::warn
}

@test "_validate_ignores passes an opt-out folder with no patterns" {
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  git_backup::_validate_ignores '[{"path":"/a","remote":"r1","manage_gitignore":false}]'
  mktest::assert_stub_not_called lifecycle::fail
}

@test "_validate_ignores fails an opt-out folder that still lists ignore_patterns" {
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run ! git_backup::_validate_ignores '[{"path":"/a","remote":"r1","manage_gitignore":false,"ignore_patterns":["x"]}]'
  MATCH="manage_gitignore = false" mktest::assert_stub_called lifecycle::fail
}

@test "_validate_ignores warns on the all-empty no-op folder" {
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  git_backup::_validate_ignores '[{"path":"/a","remote":"r1","add_default_ignores":false}]'
  mktest::assert_stub_not_called lifecycle::fail
  mktest::assert_stub_called logging::warn
}

# --- _validate_keys ---

@test "_validate_keys passes when the referenced key secret exists" {
  STUB_OUTPUT="agents" mktest::stub_function git_backup::_referenced_key_names
  STUB_OUTPUT="git_backup/ssh_keys/agents" mktest::stub_function git_backup::_secret_name "agents"
  mktest::stub_function secrets::present "git_backup/ssh_keys/agents"
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  git_backup::_validate_keys
  mktest::assert_stub_not_called lifecycle::fail
}

@test "_validate_keys fails when a referenced key secret is missing" {
  STUB_OUTPUT="agents" mktest::stub_function git_backup::_referenced_key_names
  STUB_OUTPUT="git_backup/ssh_keys/agents" mktest::stub_function git_backup::_secret_name "agents"
  STUB_RETURN=1 mktest::stub_function secrets::present "git_backup/ssh_keys/agents"
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run ! git_backup::_validate_keys
  MATCH="ssh_key 'agents'" mktest::assert_stub_called lifecycle::fail
}

# --- _install_keys ---

@test "_install_keys installs every referenced key" {
  printf 'k1\nk2\n' > "$BATS_TEST_TMPDIR/names"
  STUB_OUTPUT="$(cat "$BATS_TEST_TMPDIR/names")" mktest::stub_function git_backup::_referenced_key_names
  mktest::stub_function git_backup::_install_key
  git_backup::_install_keys
  mktest::assert_stub_called git_backup::_install_key "k1"
  mktest::assert_stub_called git_backup::_install_key "k2"
}

# --- _install_key ---

@test "_install_key creates a 700 dir and installs the resolved key via secrets::install_secret_file" {
  local key="$BATS_TEST_TMPDIR/keys/agents"
  STUB_OUTPUT="$key" mktest::stub_function git_backup::_key_path "agents"
  STUB_OUTPUT="git_backup/ssh_keys/agents" mktest::stub_function git_backup::_secret_name "agents"
  mktest::stub_function secrets::install_secret_file "$key" secrets::resolve "git_backup/ssh_keys/agents"
  git_backup::_install_key "agents"
  [ "$(mktest::file_mode "$BATS_TEST_TMPDIR/keys")" = "700" ]
  mktest::assert_stub_called secrets::install_secret_file "$key" secrets::resolve "git_backup/ssh_keys/agents"
}

@test "_install_key fails when no value resolves for the key secret" {
  local key="$BATS_TEST_TMPDIR/keys/agents"
  STUB_OUTPUT="$key" mktest::stub_function git_backup::_key_path "agents"
  STUB_OUTPUT="git_backup/ssh_keys/agents" mktest::stub_function git_backup::_secret_name "agents"
  STUB_RETURN=1 mktest::stub_function secrets::install_secret_file
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run ! git_backup::_install_key "agents"
  MATCH="no value resolved" mktest::assert_stub_called lifecycle::fail
}

# --- _write_manifest ---

@test "_write_manifest writes a row per folder via _manifest_row" {
  local manifest="$BATS_TEST_TMPDIR/out/manifest.tsv"
  STUB_OUTPUT="$manifest" mktest::stub_function git_backup::_manifest_path
  STUB_OUTPUT='[{"path":"/a","remote":"r1"},{"path":"/b","remote":"r2"}]' mktest::stub_function git_backup::_folders
  STUB_OUTPUT="defaultkey" mktest::stub_function git_backup::_default_ssh_key
  STUB_OUTPUT="manifest-row" mktest::stub_function git_backup::_manifest_row
  git_backup::_write_manifest
  mktest::assert_stub_called git_backup::_manifest_row '{"path":"/a","remote":"r1"}' "defaultkey"
  mktest::assert_stub_called git_backup::_manifest_row '{"path":"/b","remote":"r2"}' "defaultkey"
  [ "$(grep -c 'manifest-row' "$manifest")" -eq 2 ]
}

# --- _manifest_row ---

@test "_manifest_row emits path, remote, and the folder's resolved key path" {
  STUB_OUTPUT="/keys/k1" mktest::stub_function git_backup::_key_path "k1"
  run git_backup::_manifest_row '{"path":"/a","remote":"r1","ssh_key":"k1"}' "def"
  [ "$output" = "$(printf '/a\tr1\t/keys/k1')" ]
}

@test "_manifest_row falls back to the module default ssh_key when the folder omits one" {
  STUB_OUTPUT="/keys/def" mktest::stub_function git_backup::_key_path "def"
  run git_backup::_manifest_row '{"path":"/a","remote":"r1"}' "def"
  [ "$output" = "$(printf '/a\tr1\t/keys/def')" ]
}

@test "_manifest_row emits an empty key path when neither folder nor default names a key" {
  mktest::stub_function git_backup::_key_path
  run git_backup::_manifest_row '{"path":"/a","remote":"r1"}' ""
  [ "$output" = "$(printf '/a\tr1\t')" ]
  mktest::assert_stub_not_called git_backup::_key_path
}

@test "_manifest_row expands a leading ~ in the path" {
  mktest::stub_function git_backup::_key_path
  run git_backup::_manifest_row '{"path":"~/x","remote":"r1"}' ""
  [ "$output" = "$(printf '%s\tr1\t' "$HOME/x")" ]
}

# --- _apply_gitignores / _apply_gitignore / _gitignore_patterns / _default_ignores ---

@test "_apply_gitignores applies each folder's gitignore" {
  STUB_OUTPUT='[{"path":"/a","remote":"r1"},{"path":"/b","remote":"r2"}]' mktest::stub_function git_backup::_folders
  mktest::stub_function git_backup::_apply_gitignore
  git_backup::_apply_gitignores
  mktest::assert_stub_called git_backup::_apply_gitignore '{"path":"/a","remote":"r1"}' "/a"
  mktest::assert_stub_called git_backup::_apply_gitignore '{"path":"/b","remote":"r2"}' "/b"
}

@test "_apply_gitignores is a no-op when no folders are configured" {
  STUB_OUTPUT="" mktest::stub_function git_backup::_folders
  mktest::stub_function git_backup::_apply_gitignore
  git_backup::_apply_gitignores
  mktest::assert_stub_not_called git_backup::_apply_gitignore
}

@test "_apply_gitignore pipes the folder's patterns into managed_block::ensure for its .gitignore" {
  local dir="$BATS_TEST_TMPDIR/repo"; mkdir "$dir"
  STUB_OUTPUT=$'a\nb' mktest::stub_function git_backup::_gitignore_patterns '{"path":"x"}'
  # Hand-rolled stub: mktest records args but not stdin, and the pipe is the contract.
  managed_block::ensure() {
    printf '%s\n' "$@" > "$BATS_TEST_TMPDIR/ensure.args"
    cat > "$BATS_TEST_TMPDIR/ensure.stdin"
  }
  git_backup::_apply_gitignore '{"path":"x"}' "$dir"
  [ "$(cat "$BATS_TEST_TMPDIR/ensure.args")" = "$(printf '%s\n#' "$dir/.gitignore")" ]
  [ "$(cat "$BATS_TEST_TMPDIR/ensure.stdin")" = "$(printf 'a\nb')" ]
}

@test "_apply_gitignore skips a folder that does not exist yet" {
  mktest::stub_function managed_block::ensure
  git_backup::_apply_gitignore '{"path":"x"}' "$BATS_TEST_TMPDIR/absent"
  mktest::assert_stub_not_called managed_block::ensure
}

@test "_apply_gitignore leaves the file alone when manage_gitignore is false" {
  local path="$BATS_TEST_TMPDIR/repo"; mkdir "$path"
  mktest::stub_function managed_block::ensure
  git_backup::_apply_gitignore '{"path":"x","manage_gitignore":false}' "$path"
  mktest::assert_stub_not_called managed_block::ensure
}

@test "_gitignore_patterns emits user patterns before defaults" {
  run git_backup::_gitignore_patterns '{"ignore_patterns":["build/","node_modules/"]}'
  [ "${lines[0]}" = "build/" ]
  [ "${lines[1]}" = "node_modules/" ]
  [ "${lines[2]}" = ".DS_Store" ]
  [ "${lines[3]}" = "._*" ]
  [ "${lines[4]}" = ".stversions/" ]
}

@test "_gitignore_patterns omits defaults when add_default_ignores is false" {
  run git_backup::_gitignore_patterns '{"ignore_patterns":["build/"],"add_default_ignores":false}'
  [ "$output" = "build/" ]
}

@test "_gitignore_patterns de-duplicates, keeping the user's occurrence" {
  run git_backup::_gitignore_patterns '{"ignore_patterns":[".stversions/"]}'
  [ "${lines[0]}" = ".stversions/" ]
  [ "${#lines[@]}" -eq 3 ]
}

@test "_default_ignores includes the Syncthing version buffer" {
  run git_backup::_default_ignores
  [[ "$output" == *".DS_Store"* ]]
  [[ "$output" == *".stversions/"* ]]
}

# --- _install_push_script ---

@test "_install_push_script installs the real script as executable" {
  local dest="$BATS_TEST_TMPDIR/install/push.sh"
  STUB_OUTPUT="$dest" mktest::stub_function git_backup::_push_script_path
  git_backup::_install_push_script
  [ -x "$dest" ]
  grep -q "push-only-with-abort" "$dest"
}

# --- _install_service ---

@test "_install_service schedules the push script on the interval with the pinned env" {
  STUB_OUTPUT="/s/push.sh" mktest::stub_function git_backup::_push_script_path
  STUB_OUTPUT="/m/manifest.tsv" mktest::stub_function git_backup::_manifest_path
  STUB_OUTPUT="/n/notify" mktest::stub_function git_backup::_notify
  STUB_OUTPUT="/b/git" mktest::stub_function git_backup::_git_path
  STUB_OUTPUT="300" mktest::stub_function git_backup::_interval
  # Exact-arg stub: only matches if every resolved part lands in its positional slot.
  mktest::stub_function service::install_interval \
    "git-backup" "/s/push.sh" "300" \
    "MK_GIT_BACKUP_MANIFEST=/m/manifest.tsv" \
    "MK_GIT_BACKUP_NOTIFY=/n/notify" \
    "MK_GIT_BACKUP_GIT=/b/git"
  git_backup::_install_service
  mktest::assert_stub_called service::install_interval \
    "git-backup" "/s/push.sh" "300" \
    "MK_GIT_BACKUP_MANIFEST=/m/manifest.tsv" \
    "MK_GIT_BACKUP_NOTIFY=/n/notify" \
    "MK_GIT_BACKUP_GIT=/b/git"
}

# --- config accessors + paths ---

@test "_folders returns the configured folders" {
  STUB_OUTPUT='[{"path":"/a","remote":"r1"}]' mktest::stub_function config::get "module.git_backup.folders"
  run git_backup::_folders
  [ "$output" = '[{"path":"/a","remote":"r1"}]' ]
}

@test "_folders is empty and succeeds when the key is unset" {
  STUB_RETURN=1 mktest::stub_function config::get
  run git_backup::_folders
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "_interval defaults to 300" {
  STUB_OUTPUT="600" mktest::stub_function config::get "module.git_backup.interval" "--default" "300"
  run git_backup::_interval
  [ "$output" = "600" ]
}

@test "_notify defaults to empty" {
  STUB_OUTPUT="" mktest::stub_function config::get "module.git_backup.notify" "--default" ""
  run git_backup::_notify
  [ -z "$output" ]
}

@test "_git_path resolves the git on PATH" {
  local fakebin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$fakebin"
  printf '#!/usr/bin/env bash\n' > "$fakebin/git"
  chmod +x "$fakebin/git"
  PATH="$fakebin:$PATH" run git_backup::_git_path
  [ "$output" = "$fakebin/git" ]
}

@test "_default_ssh_key reads the module-level key" {
  STUB_OUTPUT="shared" mktest::stub_function config::get "module.git_backup.ssh_key" "--default" ""
  run git_backup::_default_ssh_key
  [ "$output" = "shared" ]
}

@test "_referenced_key_names lists distinct names, sorted, empties dropped, default applied" {
  STUB_OUTPUT='[{"ssh_key":"b"},{"ssh_key":"a"},{},{"ssh_key":"a"}]' mktest::stub_function git_backup::_folders
  STUB_OUTPUT="def" mktest::stub_function git_backup::_default_ssh_key
  run git_backup::_referenced_key_names
  [ "$output" = "$(printf 'a\nb\ndef')" ]
}

@test "_referenced_key_names drops empties when no default is set" {
  STUB_OUTPUT='[{},{"ssh_key":""}]' mktest::stub_function git_backup::_folders
  STUB_OUTPUT="" mktest::stub_function git_backup::_default_ssh_key
  run git_backup::_referenced_key_names
  [ -z "$output" ]
}

@test "_referenced_key_names is empty when no folders are configured" {
  STUB_OUTPUT="" mktest::stub_function git_backup::_folders
  run git_backup::_referenced_key_names
  [ -z "$output" ]
}

@test "_secret_name builds the bare logical secret name for a key name" {
  run git_backup::_secret_name "agents"
  [ "$output" = "git_backup/ssh_keys/agents" ]
}

@test "_key_path locates the decrypted key under the default config dir" {
  HOME=/fake/home
  unset XDG_CONFIG_HOME
  run git_backup::_key_path "agents"
  [ "$output" = "/fake/home/.config/machinekit/git_backup/ssh_keys/agents" ]
}

@test "_key_path honors XDG_CONFIG_HOME for the machinekit config dir" {
  HOME=/fake/home
  XDG_CONFIG_HOME=/fake/home/.xdg
  run git_backup::_key_path "agents"
  [ "$output" = "/fake/home/.xdg/machinekit/git_backup/ssh_keys/agents" ]
}

@test "_manifest_path locates the manifest under the default data dir" {
  HOME=/fake/home
  unset XDG_DATA_HOME
  run git_backup::_manifest_path
  [ "$output" = "/fake/home/.local/share/machinekit/git_backup/manifest.tsv" ]
}

@test "_manifest_path honors XDG_DATA_HOME" {
  HOME=/fake/home
  XDG_DATA_HOME=/fake/home/.xdg-data
  run git_backup::_manifest_path
  [ "$output" = "/fake/home/.xdg-data/machinekit/git_backup/manifest.tsv" ]
}

@test "_push_script_path locates the installed push script under the default data dir" {
  HOME=/fake/home
  unset XDG_DATA_HOME
  run git_backup::_push_script_path
  [ "$output" = "/fake/home/.local/share/machinekit/git_backup/push.sh" ]
}

@test "_push_script_path honors XDG_DATA_HOME" {
  HOME=/fake/home
  XDG_DATA_HOME=/fake/home/.xdg-data
  run git_backup::_push_script_path
  [ "$output" = "/fake/home/.xdg-data/machinekit/git_backup/push.sh" ]
}
