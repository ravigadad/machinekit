#!/usr/bin/env bats
# Tests for lib/machinekit/fetch.sh — the source-agnostic fetch core (resolve a
# protocol from a source, fetch a source into a destination via git clone or cp).

load "${BATS_TEST_DIRNAME}/../../test_helper"

setup() {
  # shellcheck source=../../../lib/machinekit/fetch.sh
  source "$MACHINEKIT_DIR/lib/machinekit/fetch.sh"
  mktest::stub_function logging::info
  mktest::stub_function logging::step
}

# --- fetch::resolve_protocol ---

@test "resolve_protocol returns git for a URL source" {
  mktest::stub_function fetch::_is_url "https://github.com/user/repo"
  result=$(fetch::resolve_protocol "https://github.com/user/repo")
  [ "$result" = "git" ]
}

@test "resolve_protocol returns git for a non-URL path containing a .git dir" {
  local repo="$BATS_TEST_TMPDIR/myrepo"
  mkdir -p "$repo/.git"
  STUB_RETURN=1 mktest::stub_function fetch::_is_url "$repo"
  result=$(fetch::resolve_protocol "$repo")
  [ "$result" = "git" ]
}

@test "resolve_protocol returns cp for a non-URL path without .git" {
  local dir="$BATS_TEST_TMPDIR/mydir"
  mkdir "$dir"
  STUB_RETURN=1 mktest::stub_function fetch::_is_url "$dir"
  result=$(fetch::resolve_protocol "$dir")
  [ "$result" = "cp" ]
}

@test "resolve_protocol honors an explicit override over what it would sniff" {
  mktest::stub_function fetch::_is_url "/some/repo"
  result=$(fetch::resolve_protocol "/some/repo" "cp")
  [ "$result" = "cp" ]
}

@test "resolve_protocol fails when override cp is paired with a URL" {
  mktest::stub_function fetch::_is_url "https://github.com/user/repo"
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run ! fetch::resolve_protocol "https://github.com/user/repo" "cp"
  MATCH="cp.*not compatible" mktest::assert_stub_called lifecycle::fail
}

@test "resolve_protocol fails for an unknown override protocol" {
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run ! fetch::resolve_protocol "https://github.com/user/repo" "ftp"
  MATCH="ftp" mktest::assert_stub_called lifecycle::fail
}

# --- fetch::into ---

@test "into dispatches to git clone when protocol is git" {
  mktest::stub_function fetch::_git "https://github.com/user/repo" "/dest"
  mktest::stub_function fetch::_cp
  fetch::into "https://github.com/user/repo" "/dest" "git"
  mktest::assert_stub_called fetch::_git "https://github.com/user/repo" "/dest"
  mktest::assert_stub_not_called fetch::_cp
}

@test "into dispatches to cp when protocol is cp" {
  mktest::stub_function fetch::_cp "/src" "/dest"
  mktest::stub_function fetch::_git
  fetch::into "/src" "/dest" "cp"
  mktest::assert_stub_called fetch::_cp "/src" "/dest"
  mktest::assert_stub_not_called fetch::_git
}

@test "into fails for an unknown protocol" {
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run ! fetch::into "/src" "/dest" "ftp"
  MATCH="ftp" mktest::assert_stub_called lifecycle::fail
}

# --- fetch::_git (orchestration: resolve path, provision SSH, clone with recovery) ---

@test "_git clones a URL source directly and does not resolve the path" {
  mktest::stub_function fetch::_is_url "https://github.com/user/bp"
  mktest::stub_function fetch::_resolve_source_path
  STUB_RETURN=1 mktest::stub_function fetch::_provision_ssh_for_clone
  mktest::stub_function fetch::_clone_with_recovery "https://github.com/user/bp" "$BATS_TEST_TMPDIR/dest" "0"
  fetch::_git "https://github.com/user/bp" "$BATS_TEST_TMPDIR/dest"
  mktest::assert_stub_called fetch::_clone_with_recovery "https://github.com/user/bp" "$BATS_TEST_TMPDIR/dest" "0"
  mktest::assert_stub_not_called fetch::_resolve_source_path
}

@test "_git resolves a non-URL source path before cloning" {
  STUB_RETURN=1 mktest::stub_function fetch::_is_url "./myrepo"
  STUB_OUTPUT="/abs/myrepo" mktest::stub_function fetch::_resolve_source_path "./myrepo"
  STUB_RETURN=1 mktest::stub_function fetch::_provision_ssh_for_clone
  mktest::stub_function fetch::_clone_with_recovery "/abs/myrepo" "$BATS_TEST_TMPDIR/dest" "0"
  fetch::_git "./myrepo" "$BATS_TEST_TMPDIR/dest"
  mktest::assert_stub_called fetch::_clone_with_recovery "/abs/myrepo" "$BATS_TEST_TMPDIR/dest" "0"
}

@test "_git tells recovery a key was provisioned when _provision_ssh_for_clone succeeds" {
  mktest::stub_function fetch::_is_url "https://github.com/user/bp"
  mktest::stub_function fetch::_resolve_source_path
  mktest::stub_function fetch::_provision_ssh_for_clone
  mktest::stub_function fetch::_clone_with_recovery "https://github.com/user/bp" "$BATS_TEST_TMPDIR/dest" "1"
  fetch::_git "https://github.com/user/bp" "$BATS_TEST_TMPDIR/dest"
  mktest::assert_stub_called fetch::_clone_with_recovery "https://github.com/user/bp" "$BATS_TEST_TMPDIR/dest" "1"
}

# --- fetch::_provision_ssh_for_clone ---

@test "_provision_ssh_for_clone does nothing and reports false when no flags are given" {
  STUB_RETURN=1 mktest::stub_function context::get "existing_ssh_key_file"
  STUB_OUTPUT="false" mktest::stub_function context::get "ssh.key_generate" "--coerce" "boolean" "--default" "false"
  mktest::stub_function ssh::setup_key
  run ! fetch::_provision_ssh_for_clone
  mktest::assert_stub_not_called ssh::setup_key
}

@test "_provision_ssh_for_clone installs the key and reports true when existing_ssh_key_file is set" {
  STUB_OUTPUT="/tmp/key" mktest::stub_function context::get "existing_ssh_key_file"
  mktest::stub_function ssh::setup_key
  run fetch::_provision_ssh_for_clone
  [ "$status" -eq 0 ]
  mktest::assert_stub_called ssh::setup_key
}

@test "_provision_ssh_for_clone installs the key and reports true when the generate flag is set" {
  STUB_RETURN=1 mktest::stub_function context::get "existing_ssh_key_file"
  STUB_OUTPUT="true" mktest::stub_function context::get "ssh.key_generate" "--coerce" "boolean" "--default" "false"
  mktest::stub_function ssh::setup_key
  run fetch::_provision_ssh_for_clone
  [ "$status" -eq 0 ]
  mktest::assert_stub_called ssh::setup_key
}

# --- fetch::_clone_with_recovery ---

@test "_clone_with_recovery clones once and succeeds without recovery" {
  mktest::stub_function git "clone" "--" "git@github.com:user/bp" "$BATS_TEST_TMPDIR/dest"
  mktest::stub_function fetch::_handle_clone_failure
  fetch::_clone_with_recovery "git@github.com:user/bp" "$BATS_TEST_TMPDIR/dest" "0"
  TIMES=1 mktest::assert_stub_called git "clone" "--" "git@github.com:user/bp" "$BATS_TEST_TMPDIR/dest"
  mktest::assert_stub_not_called fetch::_handle_clone_failure
}

@test "_clone_with_recovery calls _handle_clone_failure and retries on git failure" {
  STUB_RETURN=1 mktest::stub_function git "clone" "--" "git@github.com:user/bp" "$BATS_TEST_TMPDIR/dest"
  mktest::stub_function fetch::_handle_clone_failure
  run ! fetch::_clone_with_recovery "git@github.com:user/bp" "$BATS_TEST_TMPDIR/dest" "0"
  TIMES=2 mktest::assert_stub_called git "clone" "--" "git@github.com:user/bp" "$BATS_TEST_TMPDIR/dest"
  mktest::assert_stub_called fetch::_handle_clone_failure
}

@test "_clone_with_recovery does not retry when _handle_clone_failure exits" {
  STUB_RETURN=1 mktest::stub_function git "clone" "--" "git@github.com:user/bp" "$BATS_TEST_TMPDIR/dest"
  STUB_EXIT=1 mktest::stub_function fetch::_handle_clone_failure
  run ! fetch::_clone_with_recovery "git@github.com:user/bp" "$BATS_TEST_TMPDIR/dest" "0"
  TIMES=1 mktest::assert_stub_called git "clone" "--" "git@github.com:user/bp" "$BATS_TEST_TMPDIR/dest"
}

# --- fetch::_classify_clone_error ---

@test "_classify_clone_error identifies SSH permission denied as auth" {
  result=$(fetch::_classify_clone_error "git@github.com: Permission denied (publickey).")
  [ "$result" = "auth" ]
}

@test "_classify_clone_error identifies HTTPS terminal-prompts-disabled as auth" {
  result=$(fetch::_classify_clone_error "fatal: could not read Username for 'https://github.com': terminal prompts disabled")
  [ "$result" = "auth" ]
}

@test "_classify_clone_error identifies could-not-read-Username as auth" {
  result=$(fetch::_classify_clone_error "fatal: could not read Username for 'https://host'")
  [ "$result" = "auth" ]
}

@test "_classify_clone_error identifies DNS failure as network" {
  result=$(fetch::_classify_clone_error "fatal: unable to access '...': Could not resolve host: github.com")
  [ "$result" = "network" ]
}

@test "_classify_clone_error identifies Network is unreachable as network" {
  result=$(fetch::_classify_clone_error "ssh: connect to host github.com port 22: Network is unreachable")
  [ "$result" = "network" ]
}

@test "_classify_clone_error identifies Connection refused as network" {
  result=$(fetch::_classify_clone_error "ssh: connect to host github.com port 22: Connection refused")
  [ "$result" = "network" ]
}

@test "_classify_clone_error identifies Repository not found as not_found" {
  result=$(fetch::_classify_clone_error "ERROR: Repository not found.")
  [ "$result" = "not_found" ]
}

@test "_classify_clone_error returns unknown for unrecognized output" {
  result=$(fetch::_classify_clone_error "fatal: some completely unexpected error")
  [ "$result" = "unknown" ]
}

# --- fetch::_handle_clone_failure ---

@test "_handle_clone_failure dispatches auth errors to _handle_clone_auth_failure with the url type and key state" {
  STUB_OUTPUT="auth" mktest::stub_function fetch::_classify_clone_error
  mktest::stub_function fetch::_handle_clone_auth_failure "git@github.com:user/repo" "1" "0"
  fetch::_handle_clone_failure "the-git-stderr" "git@github.com:user/repo" 0
  mktest::assert_stub_called fetch::_handle_clone_auth_failure "git@github.com:user/repo" "1" "0"
}

@test "_handle_clone_failure network error exits with a network hint" {
  STUB_OUTPUT="network" mktest::stub_function fetch::_classify_clone_error
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run ! fetch::_handle_clone_failure "the-git-stderr" "git@github.com:user/repo" 0
  MATCH="network" mktest::assert_stub_called lifecycle::fail
}

@test "_handle_clone_failure not_found + SSH URL exits with a repo-not-found message" {
  STUB_OUTPUT="not_found" mktest::stub_function fetch::_classify_clone_error
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run ! fetch::_handle_clone_failure "the-git-stderr" "git@github.com:user/repo" 0
  MATCH="not found" mktest::assert_stub_called lifecycle::fail
}

@test "_handle_clone_failure not_found + HTTPS URL exits with a private-repo ambiguity note" {
  STUB_OUTPUT="not_found" mktest::stub_function fetch::_classify_clone_error
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run ! fetch::_handle_clone_failure "the-git-stderr" "https://github.com/user/repo" 0
  MATCH="private" mktest::assert_stub_called lifecycle::fail
}

@test "_handle_clone_failure unknown error exits via lifecycle::fail" {
  STUB_OUTPUT="unknown" mktest::stub_function fetch::_classify_clone_error
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run ! fetch::_handle_clone_failure "the-git-stderr" "git@github.com:user/repo" 0
  mktest::assert_stub_called lifecycle::fail
}

# --- fetch::_handle_clone_auth_failure ---

@test "_handle_clone_auth_failure SSH URL in an interactive run sets up the key and recovers" {
  mktest::stub_function input::is_interactive
  mktest::stub_function ssh::setup_key
  mktest::stub_function logging::warn
  fetch::_handle_clone_auth_failure "git@github.com:user/repo" 1 0
  mktest::assert_stub_called ssh::setup_key
}

@test "_handle_clone_auth_failure SSH URL with a key already provisioned is terminal" {
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run ! fetch::_handle_clone_auth_failure "git@github.com:user/repo" 1 1
  MATCH="still failed" mktest::assert_stub_called lifecycle::fail
}

@test "_handle_clone_auth_failure SSH URL non-interactive is terminal with a key hint" {
  STUB_RETURN=1 mktest::stub_function input::is_interactive
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run ! fetch::_handle_clone_auth_failure "git@github.com:user/repo" 1 0
  MATCH="existing-ssh-key" mktest::assert_stub_called lifecycle::fail
}

@test "_handle_clone_auth_failure non-SSH URL is terminal with a credentials hint" {
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run ! fetch::_handle_clone_auth_failure "https://github.com/user/repo" 0 0
  MATCH="authentication" mktest::assert_stub_called lifecycle::fail
}

# --- fetch::_cp ---

@test "_cp copies source contents into the destination" {
  local src="$BATS_TEST_TMPDIR/src"
  mkdir -p "$src"
  printf 'hello\n' > "$src/file.txt"
  STUB_OUTPUT="$src" mktest::stub_function fetch::_resolve_source_path "the-raw-source"
  fetch::_cp "the-raw-source" "$BATS_TEST_TMPDIR/dest"
  [ -f "$BATS_TEST_TMPDIR/dest/file.txt" ]
}

# --- fetch::_is_url ---

@test "_is_url returns true for an https URL" {
  fetch::_is_url "https://github.com/user/repo"
}

@test "_is_url returns true for an http URL" {
  fetch::_is_url "http://example.com/repo"
}

@test "_is_url returns true for a git@ SSH URL" {
  fetch::_is_url "git@github.com:user/repo.git"
}

@test "_is_url returns true for an ssh:// URL" {
  fetch::_is_url "ssh://git@github.com/user/repo.git"
}

@test "_is_url returns true for a file:// URL" {
  fetch::_is_url "file:///srv/repos/bp"
}

@test "_is_url returns false for an unrecognized protocol" {
  run ! fetch::_is_url "sparf://whatever.pickle"
}

@test "_is_url returns false for a plain local path" {
  run ! fetch::_is_url "/home/user/repos/blueprints"
}

@test "_is_url returns false for a relative path" {
  run ! fetch::_is_url "../blueprints"
}

# --- fetch::_resolve_source_path ---

@test "_resolve_source_path returns the absolute path for an existing non-empty directory" {
  local dir="$BATS_TEST_TMPDIR/mybp"
  mkdir "$dir"
  printf 'x' > "$dir/file.txt"
  result=$(fetch::_resolve_source_path "$dir")
  [ "$result" = "$dir" ]
}

@test "_resolve_source_path fails for a nonexistent path" {
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run ! fetch::_resolve_source_path "$BATS_TEST_TMPDIR/does-not-exist"
  MATCH="does not exist" mktest::assert_stub_called lifecycle::fail
}

@test "_resolve_source_path fails when the path is a file not a directory" {
  local f="$BATS_TEST_TMPDIR/file.txt"
  printf 'x' > "$f"
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run ! fetch::_resolve_source_path "$f"
  MATCH="not a directory" mktest::assert_stub_called lifecycle::fail
}

@test "_resolve_source_path fails when the source directory is empty" {
  local dir="$BATS_TEST_TMPDIR/empty-bp"
  mkdir "$dir"
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run ! fetch::_resolve_source_path "$dir"
  MATCH="empty" mktest::assert_stub_called lifecycle::fail
}
