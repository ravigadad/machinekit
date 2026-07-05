#!/usr/bin/env bats
# Tests for lib/machinekit/home.sh

load "${BATS_TEST_DIRNAME}/../../test_helper"

# Portable file-mode query: BSD stat uses -f '%A', GNU stat uses -c '%a'.
_file_mode() { command stat -c '%a' "$1" 2>/dev/null || command stat -f '%A' "$1"; }

setup() {
  # shellcheck source=../../../lib/machinekit/home.sh
  source "$MACHINEKIT_DIR/lib/machinekit/home.sh"
  unset _MK_HOME_LOADED
  unset MACHINEKIT_CONFLICT_BEHAVIOR
  # Isolate decode from any ambient XDG override; the xdg_config tests set it.
  unset XDG_CONFIG_HOME
  _MK_HOME_STAGING_DIR=""
  _MK_HOME_DEST_PATH=""
  _MK_HOME_IS_PRIVATE=0

  # Logging collaborators — allow-only; they are mechanism, not contract.
  mktest::stub_function logging::step
  mktest::stub_function logging::debug
  mktest::stub_function logging::info
  mktest::stub_function logging::success
  mktest::stub_function logging::dry_run
  mktest::stub_function logging::warn
}

# --- load guard ---

@test "sourcing twice does not redefine functions" {
  home::sync() { echo "original"; }
  _MK_HOME_LOADED=1
  source "$MACHINEKIT_DIR/lib/machinekit/home.sh"
  [ "$(home::sync)" = "original" ]
}

# --- home::sync ---

@test "sync in dry-run shows the diff and does not apply" {
  mktest::stub_function input::is_dry_run
  mktest::stub_function home::dry_run::show_diff
  mktest::stub_function home::_apply
  home::sync
  mktest::assert_stub_called home::dry_run::show_diff
  mktest::assert_stub_not_called home::_apply
}

@test "sync in real mode applies the staging tree" {
  STUB_RETURN=1 mktest::stub_function input::is_dry_run
  mktest::stub_function home::dry_run::show_diff
  mktest::stub_function home::_apply
  home::sync
  mktest::assert_stub_called home::_apply
  mktest::assert_stub_not_called home::dry_run::show_diff
}

# --- home::will_exist ---

@test "will_exist is true when the absolute destination already exists, without building the plan" {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/.config"
  : > "$HOME/.config/already_there"
  mktest::stub_function home::_build_plan
  # Literal existence short-circuits before the plan is ever built.
  home::will_exist "$HOME/.config/already_there"
  mktest::assert_stub_not_called home::_build_plan
}

@test "will_exist is true when a non-suppressed plan record lands at the queried destination" {
  local query="$BATS_TEST_TMPDIR/nope"
  STUB_OUTPUT="[{\"dest\":\"$query\",\"suppressed\":false}]" mktest::stub_function home::_build_plan
  home::will_exist "$query"
}

@test "will_exist is false when no plan record lands at the queried destination" {
  local query="$BATS_TEST_TMPDIR/nope"
  STUB_OUTPUT="[{\"dest\":\"$BATS_TEST_TMPDIR/other\",\"suppressed\":false}]" mktest::stub_function home::_build_plan
  run home::will_exist "$query"
  [ "$status" -ne 0 ]
}

@test "will_exist is false when the plan record at the queried destination is suppressed" {
  local query="$BATS_TEST_TMPDIR/nope"
  STUB_OUTPUT="[{\"dest\":\"$query\",\"suppressed\":true}]" mktest::stub_function home::_build_plan
  run home::will_exist "$query"
  [ "$status" -ne 0 ]
}

# --- home::_build_plan ---

# Fake, deterministic decode/resolve/dest_key so the test controls each file's
# destination, key, and privacy — obviously not the real addressing rules.
_stub_plan_resolution() {
  home::_decode_path()        { _MK_HOME_DEST_PATH="D:$1"; _MK_HOME_IS_PRIVATE=0; [ "$1" = "a" ] && _MK_HOME_IS_PRIVATE=1; }
  # resolve yields the stripped dest AND the transform pipeline; a gets a
  # one-stage pipeline, everything else gets none — so the plan captures both.
  home::transforms::resolve() { _MK_HOME_TRANSFORM_DEST="R:$1"; case "$1" in *a) _MK_HOME_TRANSFORM_PIPELINE=("P:$1") ;; *) _MK_HOME_TRANSFORM_PIPELINE=() ;; esac; }
  # Faithful to the one invariant that matters: the real .mkignore manifest
  # decodes to the key ".mkignore" (which _build_plan omits from the plan).
  home::_dest_key()           { case "$1" in *.mkignore) printf '%s\n' ".mkignore" ;; *) printf '%s\n' "K:$1" ;; esac; }
}

@test "_build_plan emits one record per staged file, in sorted order, with private and suppressed flags" {
  local staging="$BATS_TEST_TMPDIR/staging"
  mkdir -p "$staging"
  : > "$staging/a"
  : > "$staging/b"
  STUB_OUTPUT="$staging" mktest::stub_function home::staging::dir
  _stub_plan_resolution
  # b's key is listed in the blueprint's .mkignore → suppressed; a is not.
  printf 'K:R:D:b\n' > "$staging/.mkignore"

  local plan
  plan="$(home::_build_plan)"

  [ "$(jq -r 'length' <<<"$plan")" = "2" ]
  [ "$(jq -r '.[0].src' <<<"$plan")" = "$staging/a" ]
  [ "$(jq -r '.[0].src_rel' <<<"$plan")" = "a" ]
  [ "$(jq -r '.[0].dest' <<<"$plan")" = "R:D:a" ]
  [ "$(jq -r '.[0].key' <<<"$plan")" = "K:R:D:a" ]
  [ "$(jq -r '.[0].private' <<<"$plan")" = "true" ]
  [ "$(jq -r '.[0].suppressed' <<<"$plan")" = "false" ]
  [ "$(jq -r '.[0].pipeline[0]' <<<"$plan")" = "P:D:a" ]
  [ "$(jq -r '.[1].src_rel' <<<"$plan")" = "b" ]
  [ "$(jq -r '.[1].private' <<<"$plan")" = "false" ]
  [ "$(jq -r '.[1].suppressed' <<<"$plan")" = "true" ]
  [ "$(jq -r '.[1].pipeline | length' <<<"$plan")" = "0" ]
}

@test "_build_plan omits the .mkignore manifest itself" {
  local staging="$BATS_TEST_TMPDIR/staging"
  mkdir -p "$staging"
  : > "$staging/only"
  STUB_OUTPUT="$staging" mktest::stub_function home::staging::dir
  home::_decode_path()        { _MK_HOME_DEST_PATH="d"; _MK_HOME_IS_PRIVATE=0; }
  home::transforms::resolve() { _MK_HOME_TRANSFORM_DEST="d"; }
  home::_dest_key()           { printf '%s\n' ".mkignore"; }

  local plan
  plan="$(home::_build_plan)"

  [ "$(jq -r 'length' <<<"$plan")" = "0" ]
}

@test "_build_plan marks nothing suppressed when there is no .mkignore" {
  local staging="$BATS_TEST_TMPDIR/staging"
  mkdir -p "$staging"
  : > "$staging/a"
  STUB_OUTPUT="$staging" mktest::stub_function home::staging::dir
  _stub_plan_resolution

  local plan
  plan="$(home::_build_plan)"

  [ "$(jq -r '.[0].suppressed' <<<"$plan")" = "false" ]
}

@test "_build_plan is an empty array when staging has no files" {
  local staging="$BATS_TEST_TMPDIR/staging"
  mkdir -p "$staging"
  STUB_OUTPUT="$staging" mktest::stub_function home::staging::dir
  _stub_plan_resolution

  local plan
  plan="$(home::_build_plan)"

  [ "$(jq -r 'length' <<<"$plan")" = "0" ]
}

# --- home::_each_planned_file ---

@test "_each_planned_file streams every record — including suppressed — to the callback with fields then pipeline" {
  STUB_OUTPUT='[{"src":"/s/a","src_rel":"a","dest":"/h/a","key":"ka","private":true,"suppressed":false,"pipeline":["fn_a"]},{"src":"/s/b","src_rel":"b","dest":"/h/b","key":"kb","private":false,"suppressed":true,"pipeline":[]}]' \
    mktest::stub_function home::_build_plan
  mktest::stub_function fake_sink
  home::_each_planned_file fake_sink
  # Both records reach the sink (the iterator does not decide suppression); the
  # fields arrive in record order with the pipeline as trailing args.
  mktest::assert_stub_called_in_order fake_sink "/s/a" "a" "/h/a" "ka" "1" "false" "fn_a"
  mktest::assert_stub_called_in_order fake_sink "/s/b" "b" "/h/b" "kb" "0" "true"
}

@test "_each_planned_file forwards prefix args ahead of the record fields" {
  STUB_OUTPUT='[{"src":"/s/a","src_rel":"a","dest":"/h/a","key":"ka","private":false,"suppressed":false,"pipeline":[]}]' \
    mktest::stub_function home::_build_plan
  mktest::stub_function fake_sink
  home::_each_planned_file fake_sink "the-prefix"
  mktest::assert_stub_called fake_sink "the-prefix" "/s/a" "a" "/h/a" "ka" "0" "false"
}

# --- home::_apply ---

@test "_apply delegates each planned file to _apply_file" {
  mktest::stub_function home::_each_planned_file
  home::_apply
  mktest::assert_stub_called home::_each_planned_file home::_apply_file
}

# --- home::_apply_file ---

@test "_apply_file makes the dest dir, applies parent perms, executes the pipeline, and reconciles" {
  mktest::stub_function home::_apply_parent_perms
  STUB_OUTPUT="$BATS_TEST_TMPDIR/rendered" mktest::stub_function home::transforms::execute
  mktest::stub_function home::_reconcile_file
  local dest="$BATS_TEST_TMPDIR/home/.gitconfig"
  home::_apply_file "/staging/dot_gitconfig.tmpl" "dot_gitconfig.tmpl" "$dest" ".gitconfig" "0" "false" "gomplate::render"
  [ -d "$BATS_TEST_TMPDIR/home" ]
  mktest::assert_stub_called home::_apply_parent_perms "dot_gitconfig.tmpl" "$dest"
  # The pipeline handlers travel to execute as trailing args; its stdout is the
  # rendered content path that reconcile then receives.
  mktest::assert_stub_called home::transforms::execute "/staging/dot_gitconfig.tmpl" "gomplate::render"
  mktest::assert_stub_called home::_reconcile_file "$BATS_TEST_TMPDIR/rendered" "$dest" ".gitconfig" "0"
}

@test "_apply_file skips a suppressed file: logs it and neither executes nor reconciles" {
  mktest::stub_function home::_apply_parent_perms
  mktest::stub_function home::transforms::execute
  mktest::stub_function home::_reconcile_file
  # Writable dest so dropping the suppressed guard fails on the execute/reconcile
  # contract, not on an incidental mkdir into a read-only path.
  home::_apply_file "/s/x" "x" "$BATS_TEST_TMPDIR/home/.x" ".x" "0" "true" "gomplate::render"
  mktest::assert_stub_not_called home::transforms::execute
  mktest::assert_stub_not_called home::_reconcile_file
  MATCH="\.x" mktest::assert_stub_called logging::debug
}

@test "_apply_file forwards is_private to reconcile" {
  mktest::stub_function home::_apply_parent_perms
  STUB_OUTPUT="$BATS_TEST_TMPDIR/rendered" mktest::stub_function home::transforms::execute
  mktest::stub_function home::_reconcile_file
  local dest="$BATS_TEST_TMPDIR/home/.ssh/config"
  home::_apply_file "/staging/private_dot_ssh/private_config" "private_dot_ssh/private_config" "$dest" ".ssh/config" "1" "false"
  mktest::assert_stub_called home::_reconcile_file "$BATS_TEST_TMPDIR/rendered" "$dest" ".ssh/config" "1"
}

# --- home::_decode_path ---

@test "_decode_path roots a plain filename at HOME" {
  export HOME=/fake/home
  home::_decode_path "env.zsh"
  [ "$_MK_HOME_DEST_PATH" = "/fake/home/env.zsh" ]
  [ "$_MK_HOME_IS_PRIVATE" = "0" ]
}

@test "_decode_path converts dot_ prefix to a leading dot" {
  export HOME=/fake/home
  home::_decode_path "dot_zshrc"
  [ "$_MK_HOME_DEST_PATH" = "/fake/home/.zshrc" ]
  [ "$_MK_HOME_IS_PRIVATE" = "0" ]
}

@test "_decode_path strips private_ prefix and sets is_private" {
  export HOME=/fake/home
  home::_decode_path "private_config"
  [ "$_MK_HOME_DEST_PATH" = "/fake/home/config" ]
  [ "$_MK_HOME_IS_PRIVATE" = "1" ]
}

@test "_decode_path handles combined private_dot_ prefix" {
  export HOME=/fake/home
  home::_decode_path "private_dot_ssh"
  [ "$_MK_HOME_DEST_PATH" = "/fake/home/.ssh" ]
  [ "$_MK_HOME_IS_PRIVATE" = "1" ]
}

@test "_decode_path decodes a nested path with all conventions" {
  export HOME=/fake/home
  home::_decode_path "private_dot_ssh/private_config"
  [ "$_MK_HOME_DEST_PATH" = "/fake/home/.ssh/config" ]
  [ "$_MK_HOME_IS_PRIVATE" = "1" ]
}

@test "_decode_path decodes a deep path preserving intermediate directories" {
  export HOME=/fake/home
  home::_decode_path "dot_config/machinekit/env.zsh.d/mise.zsh"
  [ "$_MK_HOME_DEST_PATH" = "/fake/home/.config/machinekit/env.zsh.d/mise.zsh" ]
  [ "$_MK_HOME_IS_PRIVATE" = "0" ]
}

@test "_decode_path roots xdg_config at the default config dir when XDG is unset" {
  export HOME=/fake/home
  unset XDG_CONFIG_HOME
  home::_decode_path "xdg_config/machinekit/env.zsh"
  [ "$_MK_HOME_DEST_PATH" = "/fake/home/.config/machinekit/env.zsh" ]
}

@test "_decode_path roots xdg_config at XDG_CONFIG_HOME when set under HOME" {
  export HOME=/fake/home
  export XDG_CONFIG_HOME=/fake/home/.dotfiles/config
  home::_decode_path "xdg_config/machinekit/env.zsh"
  [ "$_MK_HOME_DEST_PATH" = "/fake/home/.dotfiles/config/machinekit/env.zsh" ]
}

@test "_decode_path roots xdg_config at XDG_CONFIG_HOME even outside HOME" {
  export HOME=/fake/home
  export XDG_CONFIG_HOME=/srv/config
  home::_decode_path "xdg_config/machinekit/env.zsh"
  [ "$_MK_HOME_DEST_PATH" = "/srv/config/machinekit/env.zsh" ]
}

@test "_decode_path still decodes private_/dot_ prefixes after an xdg_config root" {
  export HOME=/fake/home
  export XDG_CONFIG_HOME=/srv/config
  home::_decode_path "xdg_config/private_dot_secret"
  [ "$_MK_HOME_DEST_PATH" = "/srv/config/.secret" ]
  [ "$_MK_HOME_IS_PRIVATE" = "1" ]
}

# --- home::_dest_key ---

@test "_dest_key is the HOME-relative path when the destination is under HOME" {
  export HOME=/fake/home
  run home::_dest_key "/fake/home/.config/machinekit/env.zsh"
  [ "$output" = ".config/machinekit/env.zsh" ]
}

@test "_dest_key is the absolute path when the destination is outside HOME" {
  export HOME=/fake/home
  run home::_dest_key "/srv/config/machinekit/env.zsh"
  [ "$output" = "/srv/config/machinekit/env.zsh" ]
}

# --- home::_apply_parent_perms ---

@test "_apply_parent_perms sets mode 700 on dest parent when staging parent has private_ prefix" {
  local dest_dir="$BATS_TEST_TMPDIR/home/.ssh"
  mkdir -p "$dest_dir"
  home::_apply_parent_perms "private_dot_ssh/config" "$BATS_TEST_TMPDIR/home/.ssh/config"
  [ "$(_file_mode "$dest_dir")" = "700" ]
}

@test "_apply_parent_perms does not chmod when staging parent has no private_ prefix" {
  local dest_dir="$BATS_TEST_TMPDIR/home/.config"
  mkdir -p "$dest_dir"
  chmod 755 "$dest_dir"
  home::_apply_parent_perms "dot_config/settings" "$BATS_TEST_TMPDIR/home/.config/settings"
  [ "$(_file_mode "$dest_dir")" = "755" ]
}

@test "_apply_parent_perms is a no-op for a top-level file with no parent component" {
  mktest::stub_function chmod
  home::_apply_parent_perms "dot_zshrc" "$BATS_TEST_TMPDIR/home/.zshrc"
  mktest::assert_stub_not_called chmod
}

# --- home::_reconcile_file ---

@test "_reconcile_file writes a new file directly, without conflict resolution" {
  local resolved="$BATS_TEST_TMPDIR/resolved"
  local dest="$BATS_TEST_TMPDIR/home/.zshrc"
  printf 'content\n' > "$resolved"
  mktest::stub_function home::_write_file
  mktest::stub_function home::_conflict_action
  home::_reconcile_file "$resolved" "$dest" ".zshrc" "0"
  mktest::assert_stub_called home::_write_file "$resolved" "$dest" "0"
  mktest::assert_stub_not_called home::_conflict_action
}

@test "_reconcile_file skips the write and removes the resolved temp when content is unchanged" {
  local resolved="$BATS_TEST_TMPDIR/resolved"
  local dest="$BATS_TEST_TMPDIR/home/.zshrc"
  mkdir -p "$BATS_TEST_TMPDIR/home"
  printf 'content\n' > "$resolved"
  printf 'content\n' > "$dest"
  mktest::stub_function home::_write_file
  mktest::stub_function home::_conflict_action
  home::_reconcile_file "$resolved" "$dest" ".zshrc" "0"
  mktest::assert_stub_not_called home::_write_file
  mktest::assert_stub_not_called home::_conflict_action
  [ ! -f "$resolved" ]
}

@test "_reconcile_file writes when content differs and _conflict_action returns true" {
  local resolved="$BATS_TEST_TMPDIR/resolved"
  local dest="$BATS_TEST_TMPDIR/home/.zshrc"
  mkdir -p "$BATS_TEST_TMPDIR/home"
  printf 'new content\n' > "$resolved"
  printf 'old content\n' > "$dest"
  STUB_RETURN=0 mktest::stub_function home::_conflict_action ".zshrc" "$resolved" "$dest"
  mktest::stub_function home::_write_file
  home::_reconcile_file "$resolved" "$dest" ".zshrc" "0"
  mktest::assert_stub_called home::_write_file "$resolved" "$dest" "0"
}

@test "_reconcile_file does not write when _conflict_action returns skip" {
  local resolved="$BATS_TEST_TMPDIR/resolved"
  local dest="$BATS_TEST_TMPDIR/home/.zshrc"
  mkdir -p "$BATS_TEST_TMPDIR/home"
  printf 'new content\n' > "$resolved"
  printf 'old content\n' > "$dest"
  STUB_RETURN=1 mktest::stub_function home::_conflict_action ".zshrc" "$resolved" "$dest"
  mktest::stub_function home::_write_file
  home::_reconcile_file "$resolved" "$dest" ".zshrc" "0"
  mktest::assert_stub_not_called home::_write_file
}

# --- home::_write_file ---

@test "_write_file copies resolved to dest_path" {
  local src="$BATS_TEST_TMPDIR/src.txt"
  local dest="$BATS_TEST_TMPDIR/dest.txt"
  printf 'content\n' > "$src"
  home::_write_file "$src" "$dest" "0"
  [ "$(cat "$dest")" = "content" ]
}

@test "_write_file removes the resolved temp file after copying" {
  local src="$BATS_TEST_TMPDIR/src.txt"
  local dest="$BATS_TEST_TMPDIR/dest.txt"
  printf 'content\n' > "$src"
  home::_write_file "$src" "$dest" "0"
  [ ! -f "$src" ]
}

@test "_write_file sets mode 600 on dest when is_private is 1" {
  local src="$BATS_TEST_TMPDIR/src.txt"
  local dest="$BATS_TEST_TMPDIR/dest.txt"
  printf 'content\n' > "$src"
  home::_write_file "$src" "$dest" "1"
  [ "$(_file_mode "$dest")" = "600" ]
}

# --- home::_conflict_action ---

@test "_conflict_action returns 0 when conflict_behavior is overwrite" {
  STUB_OUTPUT="overwrite" mktest::stub_function input::conflict_behavior
  mktest::stub_function input::is_interactive
  mktest::stub_function home::_prompt_conflict
  home::_conflict_action ".zshrc" "$BATS_TEST_TMPDIR/resolved" "$BATS_TEST_TMPDIR/dest"
}

@test "_conflict_action returns 1 when conflict_behavior is skip" {
  STUB_OUTPUT="skip" mktest::stub_function input::conflict_behavior
  mktest::stub_function input::is_interactive
  mktest::stub_function home::_prompt_conflict
  run ! home::_conflict_action ".zshrc" "$BATS_TEST_TMPDIR/resolved" "$BATS_TEST_TMPDIR/dest"
  [ "$status" -eq 1 ]
}

@test "_conflict_action calls lifecycle::fail when conflict_behavior is abort" {
  STUB_OUTPUT="abort" mktest::stub_function input::conflict_behavior
  mktest::stub_function input::is_interactive
  mktest::stub_function home::_prompt_conflict
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run ! home::_conflict_action ".zshrc" "$BATS_TEST_TMPDIR/resolved" "$BATS_TEST_TMPDIR/dest"
  MATCH="conflict" mktest::assert_stub_called lifecycle::fail
}

@test "_conflict_action calls lifecycle::fail for unknown conflict_behavior value" {
  STUB_OUTPUT="bogus" mktest::stub_function input::conflict_behavior
  mktest::stub_function input::is_interactive
  mktest::stub_function home::_prompt_conflict
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run ! home::_conflict_action ".zshrc" "$BATS_TEST_TMPDIR/resolved" "$BATS_TEST_TMPDIR/dest"
  MATCH="unknown" mktest::assert_stub_called lifecycle::fail
}

@test "_conflict_action defaults to overwrite when behavior is empty and not interactive" {
  mktest::stub_function input::conflict_behavior
  STUB_RETURN=1 mktest::stub_function input::is_interactive
  mktest::stub_function home::_prompt_conflict
  home::_conflict_action ".zshrc" "$BATS_TEST_TMPDIR/resolved" "$BATS_TEST_TMPDIR/dest"
  mktest::assert_stub_not_called home::_prompt_conflict
}

@test "_conflict_action delegates to _prompt_conflict when behavior is empty and interactive" {
  mktest::stub_function input::conflict_behavior
  mktest::stub_function input::is_interactive
  STUB_OUTPUT="overwrite" mktest::stub_function home::_prompt_conflict
  home::_conflict_action ".zshrc" "$BATS_TEST_TMPDIR/resolved" "$BATS_TEST_TMPDIR/dest"
  mktest::assert_stub_called home::_prompt_conflict ".zshrc"
}

@test "_conflict_action calls lifecycle::fail when _prompt_conflict returns abort" {
  mktest::stub_function input::conflict_behavior
  mktest::stub_function input::is_interactive
  STUB_OUTPUT="abort" mktest::stub_function home::_prompt_conflict
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run ! home::_conflict_action ".zshrc" "$BATS_TEST_TMPDIR/resolved" "$BATS_TEST_TMPDIR/dest"
  MATCH="abort" mktest::assert_stub_called lifecycle::fail
}

@test "_conflict_action propagates skip from _prompt_conflict" {
  mktest::stub_function input::conflict_behavior
  mktest::stub_function input::is_interactive
  STUB_OUTPUT="skip" mktest::stub_function home::_prompt_conflict
  run ! home::_conflict_action ".zshrc" "$BATS_TEST_TMPDIR/resolved" "$BATS_TEST_TMPDIR/dest"
  [ "$status" -eq 1 ]
}

@test "_conflict_action calls _show_conflict_diff and re-prompts when _prompt_conflict returns diff" {
  mktest::stub_function input::conflict_behavior
  mktest::stub_function input::is_interactive
  mktest::stub_function home::_show_conflict_diff
  local call_count_file="$BATS_TEST_TMPDIR/call_count"
  printf '0' > "$call_count_file"
  home::_prompt_conflict() {
    local n
    n=$(cat "$call_count_file")
    n=$((n + 1))
    printf '%d' "$n" > "$call_count_file"
    if [ "$n" -eq 1 ]; then printf 'diff\n'; else printf 'overwrite\n'; fi
  }
  home::_conflict_action ".zshrc" "$BATS_TEST_TMPDIR/resolved" "$BATS_TEST_TMPDIR/dest"
  mktest::assert_stub_called home::_show_conflict_diff \
    "$BATS_TEST_TMPDIR/resolved" "$BATS_TEST_TMPDIR/dest"
}

@test "_conflict_action exports overwrite and returns 0 when _prompt_conflict echoes overwrite-all" {
  mktest::stub_function input::conflict_behavior
  mktest::stub_function input::is_interactive
  STUB_OUTPUT="overwrite-all" mktest::stub_function home::_prompt_conflict
  home::_conflict_action ".zshrc" "$BATS_TEST_TMPDIR/resolved" "$BATS_TEST_TMPDIR/dest"
  [ "$MACHINEKIT_CONFLICT_BEHAVIOR" = "overwrite" ]
}

@test "_conflict_action exports skip and returns 1 when _prompt_conflict echoes skip-all" {
  mktest::stub_function input::conflict_behavior
  mktest::stub_function input::is_interactive
  STUB_OUTPUT="skip-all" mktest::stub_function home::_prompt_conflict
  local result=0
  home::_conflict_action ".zshrc" "$BATS_TEST_TMPDIR/resolved" "$BATS_TEST_TMPDIR/dest" \
    || result=$?
  [ "$result" -eq 1 ]
  [ "$MACHINEKIT_CONFLICT_BEHAVIOR" = "skip" ]
}

# --- home::_prompt_conflict ---

@test "_prompt_conflict echoes overwrite for o choice" {
  STUB_OUTPUT="o" mktest::stub_function home::_read_conflict_choice
  result=$(home::_prompt_conflict ".zshrc")
  [ "$result" = "overwrite" ]
}

@test "_prompt_conflict echoes skip for s choice" {
  STUB_OUTPUT="s" mktest::stub_function home::_read_conflict_choice
  result=$(home::_prompt_conflict ".zshrc")
  [ "$result" = "skip" ]
}

@test "_prompt_conflict echoes abort for a choice" {
  STUB_OUTPUT="a" mktest::stub_function home::_read_conflict_choice
  result=$(home::_prompt_conflict ".zshrc")
  [ "$result" = "abort" ]
}

@test "_prompt_conflict echoes diff for d choice" {
  STUB_OUTPUT="d" mktest::stub_function home::_read_conflict_choice
  result=$(home::_prompt_conflict ".zshrc")
  [ "$result" = "diff" ]
}

@test "_prompt_conflict echoes overwrite-all for O choice" {
  STUB_OUTPUT="O" mktest::stub_function home::_read_conflict_choice
  result=$(home::_prompt_conflict ".zshrc")
  [ "$result" = "overwrite-all" ]
}

@test "_prompt_conflict echoes skip-all for S choice" {
  STUB_OUTPUT="S" mktest::stub_function home::_read_conflict_choice
  result=$(home::_prompt_conflict ".zshrc")
  [ "$result" = "skip-all" ]
}

@test "_prompt_conflict re-prompts and warns on an invalid choice" {
  local call_count_file="$BATS_TEST_TMPDIR/call_count"
  printf '0' > "$call_count_file"
  home::_read_conflict_choice() {
    local n; n=$(cat "$call_count_file")
    n=$((n + 1))
    printf '%d' "$n" > "$call_count_file"
    if [ "$n" -eq 1 ]; then printf 'x'; else printf 'o'; fi
  }
  result=$(home::_prompt_conflict ".zshrc")
  [ "$result" = "overwrite" ]
  MATCH="invalid" mktest::assert_stub_called logging::warn
}

# --- home::_read_conflict_choice ---

@test "_read_conflict_choice reads one character from MACHINEKIT_TTY" {
  printf 'o' > "$BATS_TEST_TMPDIR/tty"
  MACHINEKIT_TTY="$BATS_TEST_TMPDIR/tty"
  result=$(home::_read_conflict_choice)
  [ "$result" = "o" ]
}

# --- home::_show_conflict_diff ---

@test "_show_conflict_diff calls git diff and pipes output to less when files differ" {
  STUB_OUTPUT="diff content" mktest::stub_function git diff --no-index --color=always "the-dest" "the-source"
  mktest::stub_function less
  home::_show_conflict_diff "the-source" "the-dest"
  mktest::assert_stub_called less
}

@test "_show_conflict_diff does not open less when diff is empty" {
  STUB_OUTPUT="" mktest::stub_function git diff --no-index --color=always "the-dest" "the-source"
  mktest::stub_function less
  home::_show_conflict_diff "the-source" "the-dest"
  mktest::assert_stub_not_called less
}
