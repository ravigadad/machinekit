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

@test "requires age when a folder references an ssh_key" {
  STUB_OUTPUT="agents" mktest::stub_function git_backup::_referenced_key_names
  run git_backup::requires
  [ "$status" -eq 0 ]
  [ "$output" = "age" ]
}

@test "requires nothing when no ssh_key is referenced" {
  STUB_OUTPUT="" mktest::stub_function git_backup::_referenced_key_names
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
  local secret="$BATS_TEST_TMPDIR/agents.age"; touch "$secret"
  STUB_OUTPUT="agents" mktest::stub_function git_backup::_referenced_key_names
  STUB_OUTPUT="$secret" mktest::stub_function git_backup::_secret_path "agents"
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  git_backup::_validate_keys
  mktest::assert_stub_not_called lifecycle::fail
}

@test "_validate_keys fails when a referenced key secret is missing" {
  STUB_OUTPUT="agents" mktest::stub_function git_backup::_referenced_key_names
  STUB_OUTPUT="$BATS_TEST_TMPDIR/absent.age" mktest::stub_function git_backup::_secret_path "agents"
  STUB_OUTPUT="secrets/git_backup/ssh_keys/agents.age" mktest::stub_function git_backup::_secret_rel "agents"
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

@test "_install_key decrypts the named key to a 600 file under a 700 dir" {
  local key="$BATS_TEST_TMPDIR/keys/agents"
  STUB_OUTPUT="$key" mktest::stub_function git_backup::_key_path "agents"
  STUB_OUTPUT="/bp/secrets/git_backup/ssh_keys/agents.age" mktest::stub_function git_backup::_secret_path "agents"
  STUB_OUTPUT="KEYDATA" mktest::stub_function age::decrypt
  git_backup::_install_key "agents"
  [ "$(cat "$key")" = "KEYDATA" ]
  [ "$(mktest::file_mode "$key")" = "600" ]
  [ "$(mktest::file_mode "$BATS_TEST_TMPDIR/keys")" = "700" ]
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

# --- _install_service dispatch ---

@test "_install_service dispatches to the darwin installer on macOS" {
  STUB_OUTPUT="darwin" mktest::stub_function context::get "os.family"
  mktest::stub_function git_backup::_install_service_darwin
  mktest::stub_function git_backup::_install_service_linux
  git_backup::_install_service
  mktest::assert_stub_called git_backup::_install_service_darwin
  mktest::assert_stub_not_called git_backup::_install_service_linux
}

@test "_install_service dispatches to the linux installer on Linux" {
  STUB_OUTPUT="linux" mktest::stub_function context::get "os.family"
  mktest::stub_function git_backup::_install_service_darwin
  mktest::stub_function git_backup::_install_service_linux
  git_backup::_install_service
  mktest::assert_stub_called git_backup::_install_service_linux
  mktest::assert_stub_not_called git_backup::_install_service_darwin
}

# --- unit content generators ---

@test "_plist_content embeds the script, manifest, notify, git, interval, and run-as user" {
  run git_backup::_plist_content "/s/push.sh" "/m/manifest.tsv" "/n/notify" "/b/git" "600" "alice"
  [[ "$output" == *"com.machinekit.git-backup"* ]]
  [[ "$output" == *"/s/push.sh"* ]]
  [[ "$output" == *"<key>MK_GIT_BACKUP_MANIFEST</key><string>/m/manifest.tsv</string>"* ]]
  [[ "$output" == *"<key>MK_GIT_BACKUP_GIT</key><string>/b/git</string>"* ]]
  [[ "$output" == *"<integer>600</integer>"* ]]
  # The daemon runs as root by default; UserName drops it to the repo's owner so
  # git doesn't reject the user-owned working tree as dubious ownership.
  [[ "$output" == *"<key>UserName</key><string>alice</string>"* ]]
}

@test "_systemd_service_content embeds the env (incl. git) and ExecStart" {
  run git_backup::_systemd_service_content "/s/push.sh" "/m/manifest.tsv" "/n/notify" "/b/git"
  [[ "$output" == *"Environment=MK_GIT_BACKUP_MANIFEST=/m/manifest.tsv"* ]]
  [[ "$output" == *"Environment=MK_GIT_BACKUP_GIT=/b/git"* ]]
  [[ "$output" == *"ExecStart=/bin/bash /s/push.sh"* ]]
}

@test "_systemd_timer_content sets the interval" {
  run git_backup::_systemd_timer_content "600"
  [[ "$output" == *"OnUnitActiveSec=600"* ]]
}

# --- _install_service_darwin / _install_service_linux (external commands stubbed) ---

@test "_install_service_darwin writes the system LaunchDaemon and reloads it" {
  STUB_OUTPUT="/s/push.sh" mktest::stub_function git_backup::_push_script_path
  STUB_OUTPUT="/m/manifest.tsv" mktest::stub_function git_backup::_manifest_path
  STUB_OUTPUT="/n/notify" mktest::stub_function git_backup::_notify
  STUB_OUTPUT="/b/git" mktest::stub_function git_backup::_git_path
  STUB_OUTPUT="300" mktest::stub_function git_backup::_interval
  STUB_OUTPUT="alice" mktest::stub_function git_backup::_service_user
  # Exact-arg stub: only matches if the resolved git and run-as user are threaded
  # into the right slots.
  mktest::stub_function git_backup::_plist_content "/s/push.sh" "/m/manifest.tsv" "/n/notify" "/b/git" "300" "alice"
  mktest::stub_function sudo
  git_backup::_install_service_darwin
  local plist="/Library/LaunchDaemons/com.machinekit.git-backup.plist"
  mktest::assert_stub_called sudo "tee" "$plist"
  mktest::assert_stub_called sudo "launchctl" "bootout" "system" "$plist"
  mktest::assert_stub_called sudo "launchctl" "bootstrap" "system" "$plist"
}

@test "_install_service_linux writes the user units and enables the timer with linger" {
  HOME="$BATS_TEST_TMPDIR"
  STUB_OUTPUT="/s/push.sh" mktest::stub_function git_backup::_push_script_path
  STUB_OUTPUT="/m/manifest.tsv" mktest::stub_function git_backup::_manifest_path
  STUB_OUTPUT="/n/notify" mktest::stub_function git_backup::_notify
  STUB_OUTPUT="/b/git" mktest::stub_function git_backup::_git_path
  STUB_OUTPUT="300" mktest::stub_function git_backup::_interval
  # Exact-arg stubs: SERVICE/TIMER only land if the inputs (incl. git) are threaded right.
  STUB_OUTPUT="SERVICE" mktest::stub_function git_backup::_systemd_service_content "/s/push.sh" "/m/manifest.tsv" "/n/notify" "/b/git"
  STUB_OUTPUT="TIMER" mktest::stub_function git_backup::_systemd_timer_content "300"
  mktest::stub_function sudo
  mktest::stub_function systemctl
  git_backup::_install_service_linux
  [ "$(cat "$HOME/.config/systemd/user/machinekit-git-backup.service")" = "SERVICE" ]
  [ "$(cat "$HOME/.config/systemd/user/machinekit-git-backup.timer")" = "TIMER" ]
  MATCH="enable-linger" mktest::assert_stub_called sudo
  mktest::assert_stub_called systemctl "--user" "daemon-reload"
  mktest::assert_stub_called systemctl "--user" "enable" "--now" "machinekit-git-backup.timer"
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

@test "_service_user prefers SUDO_USER (the real user behind a sudo'd apply)" {
  SUDO_USER="alice" run git_backup::_service_user
  [ "$output" = "alice" ]
}

@test "_service_user falls back to the current user when SUDO_USER is unset" {
  unset SUDO_USER
  run git_backup::_service_user
  [ "$output" = "$(id -un)" ]
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

@test "_secret_rel builds the pool-relative path for a key name" {
  run git_backup::_secret_rel "agents"
  [ "$output" = "secrets/git_backup/ssh_keys/agents.age" ]
}

@test "_secret_path roots the relative path under the blueprint dir" {
  STUB_OUTPUT="/bp" mktest::stub_function blueprints::dir
  run git_backup::_secret_path "agents"
  [ "$output" = "/bp/secrets/git_backup/ssh_keys/agents.age" ]
}

@test "_key_path locates the decrypted key under the machinekit config dir" {
  run git_backup::_key_path "agents"
  [ "$output" = "$HOME/.config/machinekit/git_backup/ssh_keys/agents" ]
}

@test "_manifest_path locates the manifest under the machinekit data dir" {
  run git_backup::_manifest_path
  [ "$output" = "$HOME/.local/share/machinekit/git_backup/manifest.tsv" ]
}

@test "_push_script_path locates the installed push script under the data dir" {
  run git_backup::_push_script_path
  [ "$output" = "$HOME/.local/share/machinekit/git_backup/push.sh" ]
}
