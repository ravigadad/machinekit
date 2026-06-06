#!/usr/bin/env bats
# Tests for lib/machinekit/blueprints.sh

load "${BATS_TEST_DIRNAME}/../../test_helper"

setup() {
  unset _MK_BLUEPRINTS_LOADED
  # shellcheck source=../../../lib/machinekit/blueprints.sh
  source "$MACHINEKIT_DIR/lib/machinekit/blueprints.sh"
  _MK_BLUEPRINTS_DIR=""
  mktest::stub_function logging::step
  mktest::stub_function logging::info
}

# --- blueprints::fetch (orchestrator) ---

@test "fetch prepares the destination and git-clones when protocol is git" {
  STUB_OUTPUT="https://github.com/user/bp" mktest::stub_function context::get "blueprints.source" "--required"
  STUB_OUTPUT="git" mktest::stub_function blueprints::_resolve_protocol "https://github.com/user/bp"
  mktest::stub_function blueprints::_prepare_dest
  mktest::stub_function blueprints::_fetch_git "https://github.com/user/bp"
  mktest::stub_function input::is_dry_run
  blueprints::fetch
  mktest::assert_stub_called blueprints::_prepare_dest
  mktest::assert_stub_called blueprints::_fetch_git "https://github.com/user/bp"
}

@test "fetch prepares the destination and copies when protocol is cp" {
  STUB_OUTPUT="/local/bp" mktest::stub_function context::get "blueprints.source" "--required"
  STUB_OUTPUT="cp" mktest::stub_function blueprints::_resolve_protocol "/local/bp"
  mktest::stub_function blueprints::_prepare_dest
  mktest::stub_function blueprints::_fetch_cp "/local/bp"
  mktest::stub_function input::is_dry_run
  blueprints::fetch
  mktest::assert_stub_called blueprints::_prepare_dest
  mktest::assert_stub_called blueprints::_fetch_cp "/local/bp"
}

@test "fetch in non-dry-run moves the temp dir to the permanent location and updates _MK_BLUEPRINTS_DIR" {
  local tmp_dir="$BATS_TEST_TMPDIR/tmp-fetch"
  mkdir "$tmp_dir"
  _MK_BLUEPRINTS_DIR="$tmp_dir"
  local final="$BATS_TEST_TMPDIR/final-bp"
  export MACHINEKIT_BLUEPRINTS_DIR="$final"
  STUB_OUTPUT="https://github.com/user/bp" mktest::stub_function context::get "blueprints.source" "--required"
  STUB_OUTPUT="git" mktest::stub_function blueprints::_resolve_protocol "https://github.com/user/bp"
  mktest::stub_function blueprints::_prepare_dest
  mktest::stub_function blueprints::_fetch_git "https://github.com/user/bp"
  STUB_RETURN=1 mktest::stub_function input::is_dry_run
  blueprints::fetch
  [ ! -d "$tmp_dir" ]
  [ -d "$final" ]
  [ "$_MK_BLUEPRINTS_DIR" = "$final" ]
}

@test "fetch in non-dry-run creates parent dirs when they do not exist" {
  local tmp_dir="$BATS_TEST_TMPDIR/tmp-fetch"
  mkdir "$tmp_dir"
  _MK_BLUEPRINTS_DIR="$tmp_dir"
  local final="$BATS_TEST_TMPDIR/nonexistent/parent/blueprints"
  export MACHINEKIT_BLUEPRINTS_DIR="$final"
  STUB_OUTPUT="https://github.com/user/bp" mktest::stub_function context::get "blueprints.source" "--required"
  STUB_OUTPUT="git" mktest::stub_function blueprints::_resolve_protocol "https://github.com/user/bp"
  mktest::stub_function blueprints::_prepare_dest
  mktest::stub_function blueprints::_fetch_git "https://github.com/user/bp"
  STUB_RETURN=1 mktest::stub_function input::is_dry_run
  blueprints::fetch
  [ -d "$final" ]
  [ "$_MK_BLUEPRINTS_DIR" = "$final" ]
}

# --- blueprints::dir ---

@test "dir fails before fetch has been called" {
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run ! blueprints::dir
  MATCH="before.*fetch" mktest::assert_stub_called lifecycle::fail
}

@test "dir returns the set value after _MK_BLUEPRINTS_DIR is assigned" {
  _MK_BLUEPRINTS_DIR="$BATS_TEST_TMPDIR/bp"
  result=$(blueprints::dir)
  [ "$result" = "$BATS_TEST_TMPDIR/bp" ]
}

# --- blueprints::_resolve_protocol ---

@test "_resolve_protocol returns git and stores it in context for a URL source" {
  STUB_RETURN=1 mktest::stub_function context::get "blueprints.source_protocol"
  mktest::stub_function context::set "blueprints.source_protocol" "git"
  result=$(blueprints::_resolve_protocol "https://github.com/user/bp")
  [ "$result" = "git" ]
  mktest::assert_stub_called context::set "blueprints.source_protocol" "git"
}

@test "_resolve_protocol returns git and stores it in context for a local path containing a .git dir" {
  local repo="$BATS_TEST_TMPDIR/myrepo"
  mkdir -p "$repo/.git"
  STUB_RETURN=1 mktest::stub_function context::get "blueprints.source_protocol"
  mktest::stub_function context::set "blueprints.source_protocol" "git"
  result=$(blueprints::_resolve_protocol "$repo")
  [ "$result" = "git" ]
  mktest::assert_stub_called context::set "blueprints.source_protocol" "git"
}

@test "_resolve_protocol returns cp and stores it in context for a plain local path without .git" {
  local dir="$BATS_TEST_TMPDIR/mydir"
  mkdir "$dir"
  STUB_RETURN=1 mktest::stub_function context::get "blueprints.source_protocol"
  mktest::stub_function context::set "blueprints.source_protocol" "cp"
  result=$(blueprints::_resolve_protocol "$dir")
  [ "$result" = "cp" ]
  mktest::assert_stub_called context::set "blueprints.source_protocol" "cp"
}

@test "_resolve_protocol uses an explicitly set protocol from context" {
  local repo="$BATS_TEST_TMPDIR/myrepo"
  mkdir -p "$repo/.git"
  STUB_OUTPUT="cp" mktest::stub_function context::get "blueprints.source_protocol"
  result=$(blueprints::_resolve_protocol "$repo")
  [ "$result" = "cp" ]
}

@test "_resolve_protocol fails when protocol cp is paired with a URL" {
  STUB_OUTPUT="cp" mktest::stub_function context::get "blueprints.source_protocol"
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run ! blueprints::_resolve_protocol "https://github.com/user/bp"
  MATCH="cp.*not compatible" mktest::assert_stub_called lifecycle::fail
}

@test "_resolve_protocol fails for an unknown protocol" {
  STUB_OUTPUT="ftp" mktest::stub_function context::get "blueprints.source_protocol"
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run ! blueprints::_resolve_protocol "https://github.com/user/bp"
  MATCH="ftp" mktest::assert_stub_called lifecycle::fail
}

# --- blueprints::_prepare_dest ---

@test "_prepare_dest sets _MK_BLUEPRINTS_DIR to a temp path, removes it, and registers cleanup" {
  local fake_dir="$BATS_TEST_TMPDIR/fake-tmp-dir"
  mkdir "$fake_dir"
  STUB_OUTPUT="$fake_dir" mktest::stub_function mktemp "-d"
  mktest::stub_function lifecycle::register_cleanup "blueprints::cleanup_dest"
  blueprints::_prepare_dest
  [ "$_MK_BLUEPRINTS_DIR" = "$fake_dir" ]
  [ ! -e "$_MK_BLUEPRINTS_DIR" ]
  mktest::assert_stub_called lifecycle::register_cleanup "blueprints::cleanup_dest"
}

# --- blueprints::_classify_clone_error ---

@test "_classify_clone_error identifies SSH permission denied as auth" {
  result=$(blueprints::_classify_clone_error "git@github.com: Permission denied (publickey).")
  [ "$result" = "auth" ]
}

@test "_classify_clone_error identifies HTTPS terminal-prompts-disabled as auth" {
  result=$(blueprints::_classify_clone_error "fatal: could not read Username for 'https://github.com': terminal prompts disabled")
  [ "$result" = "auth" ]
}

@test "_classify_clone_error identifies could-not-read-Username as auth" {
  result=$(blueprints::_classify_clone_error "fatal: could not read Username for 'https://host'")
  [ "$result" = "auth" ]
}

@test "_classify_clone_error identifies DNS failure as network" {
  result=$(blueprints::_classify_clone_error "fatal: unable to access '...': Could not resolve host: github.com")
  [ "$result" = "network" ]
}

@test "_classify_clone_error identifies Network is unreachable as network" {
  result=$(blueprints::_classify_clone_error "ssh: connect to host github.com port 22: Network is unreachable")
  [ "$result" = "network" ]
}

@test "_classify_clone_error identifies Connection refused as network" {
  result=$(blueprints::_classify_clone_error "ssh: connect to host github.com port 22: Connection refused")
  [ "$result" = "network" ]
}

@test "_classify_clone_error identifies Repository not found as not_found" {
  result=$(blueprints::_classify_clone_error "ERROR: Repository not found.")
  [ "$result" = "not_found" ]
}

@test "_classify_clone_error returns unknown for unrecognized output" {
  result=$(blueprints::_classify_clone_error "fatal: some completely unexpected error")
  [ "$result" = "unknown" ]
}

# --- blueprints::_handle_clone_failure ---

@test "_handle_clone_failure auth + SSH URL + interactive calls ssh::setup_key" {
  mktest::stub_function input::is_interactive
  mktest::stub_function ssh::setup_key
  mktest::stub_function logging::warn
  blueprints::_handle_clone_failure "Permission denied (publickey)" "git@github.com:user/repo" 0
  mktest::assert_stub_called ssh::setup_key
}

@test "_handle_clone_failure auth + SSH URL + already-run ssh → lifecycle::fail" {
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run ! blueprints::_handle_clone_failure "Permission denied (publickey)" "git@github.com:user/repo" 1
  MATCH="still failed" mktest::assert_stub_called lifecycle::fail
}

@test "_handle_clone_failure auth + SSH URL + non-interactive → lifecycle::fail with key hint" {
  STUB_RETURN=1 mktest::stub_function input::is_interactive
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run ! blueprints::_handle_clone_failure "Permission denied (publickey)" "git@github.com:user/repo" 0
  MATCH="existing-ssh-key" mktest::assert_stub_called lifecycle::fail
}

@test "_handle_clone_failure auth + HTTPS URL → lifecycle::fail with credentials hint" {
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run ! blueprints::_handle_clone_failure "terminal prompts disabled" "https://github.com/user/repo" 0
  MATCH="authentication" mktest::assert_stub_called lifecycle::fail
}

@test "_handle_clone_failure network error → lifecycle::fail with network hint" {
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run ! blueprints::_handle_clone_failure "Could not resolve host: github.com" "git@github.com:user/repo" 0
  MATCH="network" mktest::assert_stub_called lifecycle::fail
}

@test "_handle_clone_failure not_found + SSH URL → lifecycle::fail with repo-not-found message" {
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run ! blueprints::_handle_clone_failure "ERROR: Repository not found." "git@github.com:user/repo" 0
  MATCH="not found" mktest::assert_stub_called lifecycle::fail
}

@test "_handle_clone_failure not_found + HTTPS URL → lifecycle::fail with private-repo ambiguity note" {
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run ! blueprints::_handle_clone_failure "ERROR: Repository not found." "https://github.com/user/repo" 0
  MATCH="private" mktest::assert_stub_called lifecycle::fail
}

@test "_handle_clone_failure unknown error → lifecycle::fail" {
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run ! blueprints::_handle_clone_failure "some weird git error" "git@github.com:user/repo" 0
  mktest::assert_stub_called lifecycle::fail
}

# --- blueprints::_fetch_git ---

@test "_fetch_git clones a URL source directly and does not resolve the path" {
  _MK_BLUEPRINTS_DIR="$BATS_TEST_TMPDIR/dest"
  mktest::stub_function blueprints::_resolve_source_path
  STUB_RETURN=1 mktest::stub_function context::get "existing_ssh_key_file"
  STUB_OUTPUT="false" mktest::stub_function context::get "ssh.key_generate" "--coerce" "boolean" "--default" "false"
  mktest::stub_function git "clone" "--" "https://github.com/user/bp" "$BATS_TEST_TMPDIR/dest"
  blueprints::_fetch_git "https://github.com/user/bp"
  mktest::assert_stub_called git "clone" "--" "https://github.com/user/bp" "$BATS_TEST_TMPDIR/dest"
  mktest::assert_stub_not_called blueprints::_resolve_source_path
}

@test "_fetch_git resolves a local path before cloning" {
  _MK_BLUEPRINTS_DIR="$BATS_TEST_TMPDIR/dest"
  STUB_OUTPUT="/abs/myrepo" mktest::stub_function blueprints::_resolve_source_path "./myrepo"
  STUB_RETURN=1 mktest::stub_function context::get "existing_ssh_key_file"
  STUB_OUTPUT="false" mktest::stub_function context::get "ssh.key_generate" "--coerce" "boolean" "--default" "false"
  mktest::stub_function git "clone" "--" "/abs/myrepo" "$BATS_TEST_TMPDIR/dest"
  blueprints::_fetch_git "./myrepo"
  mktest::assert_stub_called git "clone" "--" "/abs/myrepo" "$BATS_TEST_TMPDIR/dest"
}

@test "_fetch_git does not set up SSH when no flags are given" {
  _MK_BLUEPRINTS_DIR="$BATS_TEST_TMPDIR/dest"
  mktest::stub_function blueprints::_resolve_source_path
  STUB_RETURN=1 mktest::stub_function context::get "existing_ssh_key_file"
  STUB_OUTPUT="false" mktest::stub_function context::get "ssh.key_generate" "--coerce" "boolean" "--default" "false"
  mktest::stub_function ssh::setup_key
  mktest::stub_function git "clone" "--" "https://github.com/user/bp" "$BATS_TEST_TMPDIR/dest"
  blueprints::_fetch_git "https://github.com/user/bp"
  mktest::assert_stub_not_called ssh::setup_key
}

@test "_fetch_git installs SSH key proactively when existing_ssh_key_file is set" {
  _MK_BLUEPRINTS_DIR="$BATS_TEST_TMPDIR/dest"
  mktest::stub_function blueprints::_resolve_source_path
  STUB_OUTPUT="/tmp/key" mktest::stub_function context::get "existing_ssh_key_file"
  mktest::stub_function ssh::setup_key
  mktest::stub_function git "clone" "--" "git@github.com:user/bp" "$BATS_TEST_TMPDIR/dest"
  blueprints::_fetch_git "git@github.com:user/bp"
  mktest::assert_stub_called ssh::setup_key
}

@test "_fetch_git installs SSH key proactively when generate flag is set" {
  _MK_BLUEPRINTS_DIR="$BATS_TEST_TMPDIR/dest"
  mktest::stub_function blueprints::_resolve_source_path
  STUB_RETURN=1 mktest::stub_function context::get "existing_ssh_key_file"
  STUB_OUTPUT="true" mktest::stub_function context::get "ssh.key_generate" "--coerce" "boolean" "--default" "false"
  mktest::stub_function ssh::setup_key
  mktest::stub_function git "clone" "--" "git@github.com:user/bp" "$BATS_TEST_TMPDIR/dest"
  blueprints::_fetch_git "git@github.com:user/bp"
  mktest::assert_stub_called ssh::setup_key
}

@test "_fetch_git calls _handle_clone_failure and retries on git failure" {
  _MK_BLUEPRINTS_DIR="$BATS_TEST_TMPDIR/dest"
  mktest::stub_function blueprints::_resolve_source_path
  STUB_RETURN=1 mktest::stub_function context::get "existing_ssh_key_file"
  STUB_OUTPUT="false" mktest::stub_function context::get "ssh.key_generate" "--coerce" "boolean" "--default" "false"
  STUB_RETURN=1 mktest::stub_function git "clone" "--" "git@github.com:user/bp" "$BATS_TEST_TMPDIR/dest"
  mktest::stub_function blueprints::_handle_clone_failure
  run ! blueprints::_fetch_git "git@github.com:user/bp"
  TIMES=2 mktest::assert_stub_called git "clone" "--" "git@github.com:user/bp" "$BATS_TEST_TMPDIR/dest"
  mktest::assert_stub_called blueprints::_handle_clone_failure
}

@test "_fetch_git does not retry when _handle_clone_failure exits" {
  _MK_BLUEPRINTS_DIR="$BATS_TEST_TMPDIR/dest"
  mktest::stub_function blueprints::_resolve_source_path
  STUB_RETURN=1 mktest::stub_function context::get "existing_ssh_key_file"
  STUB_OUTPUT="false" mktest::stub_function context::get "ssh.key_generate" "--coerce" "boolean" "--default" "false"
  STUB_RETURN=1 mktest::stub_function git "clone" "--" "git@github.com:user/bp" "$BATS_TEST_TMPDIR/dest"
  STUB_EXIT=1 mktest::stub_function blueprints::_handle_clone_failure
  run ! blueprints::_fetch_git "git@github.com:user/bp"
  TIMES=1 mktest::assert_stub_called git "clone" "--" "git@github.com:user/bp" "$BATS_TEST_TMPDIR/dest"
}

# --- blueprints::_fetch_cp ---

@test "_fetch_cp copies source contents into _MK_BLUEPRINTS_DIR" {
  local src="$BATS_TEST_TMPDIR/src"
  mkdir -p "$src"
  printf 'hello\n' > "$src/file.txt"
  STUB_OUTPUT="$src" mktest::stub_function blueprints::_resolve_source_path "$src"
  _MK_BLUEPRINTS_DIR="$BATS_TEST_TMPDIR/dest"
  blueprints::_fetch_cp "$src"
  [ -f "$_MK_BLUEPRINTS_DIR/file.txt" ]
}

# --- blueprints::_is_url ---

@test "_is_url returns true for an https URL" {
  blueprints::_is_url "https://github.com/user/repo"
}

@test "_is_url returns true for an http URL" {
  blueprints::_is_url "http://example.com/repo"
}

@test "_is_url returns true for a git@ SSH URL" {
  blueprints::_is_url "git@github.com:user/repo.git"
}

@test "_is_url returns true for an ssh:// URL" {
  blueprints::_is_url "ssh://git@github.com/user/repo.git"
}

@test "_is_url returns false for a plain local path" {
  run ! blueprints::_is_url "/home/user/repos/blueprints"
}

@test "_is_url returns false for a relative path" {
  run ! blueprints::_is_url "../blueprints"
}

# --- blueprints::_resolve_source_path ---

@test "_resolve_source_path returns the absolute path for an existing non-empty directory" {
  local dir="$BATS_TEST_TMPDIR/mybp"
  mkdir "$dir"
  printf 'x' > "$dir/file.txt"
  result=$(blueprints::_resolve_source_path "$dir")
  [ "$result" = "$dir" ]
}

@test "_resolve_source_path fails for a nonexistent path" {
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run ! blueprints::_resolve_source_path "$BATS_TEST_TMPDIR/does-not-exist"
  MATCH="does not exist" mktest::assert_stub_called lifecycle::fail
}

@test "_resolve_source_path fails when the path is a file not a directory" {
  local f="$BATS_TEST_TMPDIR/file.txt"
  printf 'x' > "$f"
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run ! blueprints::_resolve_source_path "$f"
  MATCH="not a directory" mktest::assert_stub_called lifecycle::fail
}

@test "_resolve_source_path fails when the source directory is empty" {
  local dir="$BATS_TEST_TMPDIR/empty-bp"
  mkdir "$dir"
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run ! blueprints::_resolve_source_path "$dir"
  MATCH="empty" mktest::assert_stub_called lifecycle::fail
}

# --- blueprints::cleanup_dest ---

@test "cleanup_dest does nothing when _MK_BLUEPRINTS_DIR is empty" {
  _MK_BLUEPRINTS_DIR=""
  blueprints::cleanup_dest
}

@test "cleanup_dest removes the directory and clears _MK_BLUEPRINTS_DIR" {
  local dir="$BATS_TEST_TMPDIR/to-clean"
  mkdir "$dir"
  _MK_BLUEPRINTS_DIR="$dir"
  blueprints::cleanup_dest
  [ ! -e "$dir" ]
  [ -z "$_MK_BLUEPRINTS_DIR" ]
}
