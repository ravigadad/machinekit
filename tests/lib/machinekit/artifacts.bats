#!/usr/bin/env bats
# Tests for lib/machinekit/artifacts.sh

load "${BATS_TEST_DIRNAME}/../../test_helper"

setup() {
  # shellcheck source=../../../lib/machinekit/artifacts.sh
  source "$MACHINEKIT_DIR/lib/machinekit/artifacts.sh"

  mktest::stub_function logging::info
  mktest::stub_function logging::success
  mktest::stub_function logging::dry_run
}

# --- plan ---

@test "plan computes the stale items from the declared, recorded and leftover sets, and keeps both lists for the run" {
  STUB_OUTPUT="DECLARED" mktest::stub_function artifacts::_declared
  STUB_OUTPUT="RECORDED" mktest::stub_function artifacts::_recorded
  STUB_OUTPUT="LEFTOVERS" mktest::stub_function artifacts::_leftovers
  STUB_OUTPUT="STALE" mktest::stub_function artifacts::_stale "DECLARED" "RECORDED" "LEFTOVERS"
  mktest::stub_function context::set "artifacts.declared" "DECLARED" --json
  mktest::stub_function context::set "artifacts.stale" "STALE" --json
  mktest::stub_function artifacts::_report_stale "STALE"
  artifacts::plan
  mktest::assert_stub_called context::set "artifacts.declared" "DECLARED" --json
  mktest::assert_stub_called context::set "artifacts.stale" "STALE" --json
  mktest::assert_stub_called artifacts::_report_stale "STALE"
}

@test "plan stops when collecting the declared items fails" {
  STUB_EXIT=97 mktest::stub_function artifacts::_declared
  mktest::stub_function artifacts::_recorded
  mktest::stub_function artifacts::_leftovers
  mktest::stub_function artifacts::_stale
  mktest::stub_function context::set
  mktest::stub_function artifacts::_report_stale
  run artifacts::plan
  [ "$status" -eq 97 ]
}

@test "plan stops when reading the record fails" {
  mktest::stub_function artifacts::_declared
  STUB_EXIT=97 mktest::stub_function artifacts::_recorded
  mktest::stub_function artifacts::_leftovers
  mktest::stub_function artifacts::_stale
  mktest::stub_function context::set
  mktest::stub_function artifacts::_report_stale
  run artifacts::plan
  [ "$status" -eq 97 ]
}

@test "plan stops when finding the leftovers fails" {
  mktest::stub_function artifacts::_declared
  mktest::stub_function artifacts::_recorded
  STUB_EXIT=97 mktest::stub_function artifacts::_leftovers
  mktest::stub_function artifacts::_stale
  mktest::stub_function context::set
  mktest::stub_function artifacts::_report_stale
  run artifacts::plan
  [ "$status" -eq 97 ]
}

# --- remove_stale ---

@test "remove_stale removes the stale items once consented, and records the declared items plus any it could not remove" {
  STUB_OUTPUT='["stale"]' mktest::stub_function context::get_json "artifacts.stale"
  STUB_OUTPUT='["declared"]' mktest::stub_function context::get_json "artifacts.declared"
  STUB_RETURN=1 mktest::stub_function input::is_dry_run
  mktest::stub_function artifacts::_removal_consented
  STUB_OUTPUT='["kept"]' mktest::stub_function artifacts::_remove_each '["stale"]'
  STUB_OUTPUT='["declared","kept"]' mktest::stub_function artifacts::_union '["declared"]' '["kept"]'
  mktest::stub_function artifacts::_write_record '["declared","kept"]'
  artifacts::remove_stale
  mktest::assert_stub_called artifacts::_remove_each '["stale"]'
  mktest::assert_stub_called artifacts::_write_record '["declared","kept"]'
}

@test "remove_stale keeps every stale item when removal is not consented, and says how to consent" {
  STUB_OUTPUT='["stale"]' mktest::stub_function context::get_json "artifacts.stale"
  STUB_OUTPUT='["declared"]' mktest::stub_function context::get_json "artifacts.declared"
  STUB_RETURN=1 mktest::stub_function input::is_dry_run
  STUB_RETURN=1 mktest::stub_function artifacts::_removal_consented
  mktest::stub_function artifacts::_remove_each
  mktest::stub_function logging::warn
  STUB_OUTPUT='["declared","stale"]' mktest::stub_function artifacts::_union '["declared"]' '["stale"]'
  mktest::stub_function artifacts::_write_record '["declared","stale"]'
  artifacts::remove_stale
  mktest::assert_stub_not_called artifacts::_remove_each
  MATCH="MACHINEKIT_REMOVE_UNCONFIGURED=1" mktest::assert_stub_called logging::warn
  mktest::assert_stub_called artifacts::_write_record '["declared","stale"]'
}

@test "remove_stale records the declared items without asking when nothing is stale" {
  STUB_OUTPUT='[]' mktest::stub_function context::get_json "artifacts.stale"
  STUB_OUTPUT='["declared"]' mktest::stub_function context::get_json "artifacts.declared"
  STUB_RETURN=1 mktest::stub_function input::is_dry_run
  mktest::stub_function artifacts::_removal_consented
  mktest::stub_function artifacts::_write_record '["declared"]'
  artifacts::remove_stale
  mktest::assert_stub_not_called artifacts::_removal_consented
  mktest::assert_stub_called artifacts::_write_record '["declared"]'
}

@test "remove_stale neither removes nor records anything on a dry run" {
  STUB_OUTPUT='["stale"]' mktest::stub_function context::get_json "artifacts.stale"
  STUB_OUTPUT='["declared"]' mktest::stub_function context::get_json "artifacts.declared"
  mktest::stub_function input::is_dry_run
  mktest::stub_function artifacts::_removal_consented
  mktest::stub_function artifacts::_remove_each
  mktest::stub_function artifacts::_write_record
  artifacts::remove_stale
  mktest::assert_stub_not_called artifacts::_removal_consented
  mktest::assert_stub_not_called artifacts::_remove_each
  mktest::assert_stub_not_called artifacts::_write_record
  MATCH="would offer to remove" mktest::assert_stub_called logging::dry_run
}

@test "remove_stale says nothing on a dry run when nothing is stale" {
  STUB_OUTPUT='[]' mktest::stub_function context::get_json "artifacts.stale"
  STUB_OUTPUT='["declared"]' mktest::stub_function context::get_json "artifacts.declared"
  mktest::stub_function input::is_dry_run
  mktest::stub_function artifacts::_write_record
  artifacts::remove_stale
  mktest::assert_stub_not_called logging::dry_run
  mktest::assert_stub_not_called artifacts::_write_record
}

@test "remove_stale stops when a removal stops the run" {
  STUB_OUTPUT='["stale"]' mktest::stub_function context::get_json "artifacts.stale"
  STUB_OUTPUT='["declared"]' mktest::stub_function context::get_json "artifacts.declared"
  STUB_RETURN=1 mktest::stub_function input::is_dry_run
  mktest::stub_function artifacts::_removal_consented
  STUB_EXIT=97 mktest::stub_function artifacts::_remove_each '["stale"]'
  mktest::stub_function artifacts::_union
  mktest::stub_function artifacts::_write_record
  run artifacts::remove_stale
  [ "$status" -eq 97 ]
  mktest::assert_stub_not_called artifacts::_write_record
}

# --- record_path ---

@test "record_path is installed.json in machinekit's XDG state dir" {
  XDG_STATE_HOME="/fake/state" run artifacts::record_path
  [ "$output" = "/fake/state/machinekit/installed.json" ]
}

@test "record_path falls back to ~/.local/state when XDG_STATE_HOME is unset" {
  unset XDG_STATE_HOME
  HOME="/fake/home" run artifacts::record_path
  [ "$output" = "/fake/home/.local/state/machinekit/installed.json" ]
}

# --- _declared ---

@test "_declared gathers each active module's declared items, tagged with the module" {
  STUB_OUTPUT=$'git_backup\nsyncthing' mktest::stub_function modules::active_defining installed_artifacts
  STUB_OUTPUT=$'service\tgit-backup\n\nfile\t/fake/a b' mktest::stub_function git_backup::installed_artifacts
  STUB_OUTPUT=$'folder\tagents' mktest::stub_function syncthing::installed_artifacts
  STUB_OUTPUT="ITEMS" mktest::stub_function artifacts::_items_json \
    $'git_backup\tservice\tgit-backup\ngit_backup\tfile\t/fake/a b\nsyncthing\tfolder\tagents'
  run artifacts::_declared
  [ "$status" -eq 0 ]
  [ "$output" = "ITEMS" ]
}

@test "_declared stops when a module's declaration stops the run" {
  STUB_OUTPUT="git_backup" mktest::stub_function modules::active_defining installed_artifacts
  STUB_EXIT=97 mktest::stub_function git_backup::installed_artifacts
  mktest::stub_function artifacts::_items_json
  run artifacts::_declared
  [ "$status" -eq 97 ]
}

@test "_declared stops when a command fails partway through a module's declaration" {
  STUB_OUTPUT="fake_module" mktest::stub_function modules::active_defining installed_artifacts
  fake_module::installed_artifacts() { false; printf 'service\tfake-label\n'; }
  mktest::stub_function artifacts::_items_json
  run artifacts::_declared
  [ "$status" -ne 0 ]
  mktest::assert_stub_not_called artifacts::_items_json
}

@test "_declared stops when listing the active modules fails" {
  STUB_EXIT=97 mktest::stub_function modules::active_defining installed_artifacts
  mktest::stub_function artifacts::_items_json
  run artifacts::_declared
  [ "$status" -eq 97 ]
}

# --- _items_json ---

@test "_items_json turns module-kind-name lines into items, skipping blank lines" {
  run artifacts::_items_json $'the_module\tfile\t/fake/a b\n\n\tservice\tthe-label'
  [ "$status" -eq 0 ]
  [ "$(jq -c . <<<"$output")" = '[{"module":"the_module","kind":"file","name":"/fake/a b"},{"module":"","kind":"service","name":"the-label"}]' ]
}

@test "_items_json is an empty list for no lines" {
  run artifacts::_items_json ""
  [ "$(jq -c . <<<"$output")" = '[]' ]
}

# --- _recorded ---

@test "_recorded reads the record file" {
  local record="$BATS_TEST_TMPDIR/installed.json"
  printf '%s\n' '[{"module":"m","kind":"file","name":"/fake"}]' > "$record"
  STUB_OUTPUT="$record" mktest::stub_function artifacts::record_path
  run artifacts::_recorded
  [ "$status" -eq 0 ]
  [ "$(jq -c . <<<"$output")" = '[{"module":"m","kind":"file","name":"/fake"}]' ]
}

@test "_recorded is an empty list when there is no record yet" {
  STUB_OUTPUT="$BATS_TEST_TMPDIR/missing.json" mktest::stub_function artifacts::record_path
  run artifacts::_recorded
  [ "$status" -eq 0 ]
  [ "$output" = '[]' ]
}

@test "_recorded fails, naming the file, when the record is not a list of items" {
  local record="$BATS_TEST_TMPDIR/installed.json"
  printf '%s\n' '{"not": "a list"}' > "$record"
  STUB_OUTPUT="$record" mktest::stub_function artifacts::record_path
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run artifacts::_recorded
  [ "$status" -eq 1 ]
  MATCH="$record" mktest::assert_stub_called lifecycle::fail
}

@test "_recorded fails, naming the file, when the record lists something other than items" {
  local record="$BATS_TEST_TMPDIR/installed.json"
  printf '%s\n' '["not an item"]' > "$record"
  STUB_OUTPUT="$record" mktest::stub_function artifacts::record_path
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run artifacts::_recorded
  [ "$status" -eq 1 ]
  MATCH="$record" mktest::assert_stub_called lifecycle::fail
}

@test "_recorded fails when the record is not JSON" {
  local record="$BATS_TEST_TMPDIR/installed.json"
  printf '%s\n' 'not json' > "$record"
  STUB_OUTPUT="$record" mktest::stub_function artifacts::record_path
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run artifacts::_recorded
  [ "$status" -eq 1 ]
  MATCH="$record" mktest::assert_stub_called lifecycle::fail
}

# --- _leftovers ---

@test "_leftovers joins the leftover services and files into one list" {
  STUB_OUTPUT='[{"service":1}]' mktest::stub_function artifacts::_leftover_services
  STUB_OUTPUT='[{"file":1}]' mktest::stub_function artifacts::_leftover_files
  STUB_OUTPUT="JOINED" mktest::stub_function artifacts::_union '[{"service":1}]' '[{"file":1}]'
  run artifacts::_leftovers
  [ "$status" -eq 0 ]
  [ "$output" = "JOINED" ]
}

@test "_leftovers stops when listing the services fails" {
  STUB_EXIT=97 mktest::stub_function artifacts::_leftover_services
  mktest::stub_function artifacts::_leftover_files
  mktest::stub_function artifacts::_union
  run artifacts::_leftovers
  [ "$status" -eq 97 ]
}

# --- _leftover_services ---

@test "_leftover_services lists each installed machinekit service as an item with no module" {
  STUB_OUTPUT=$'svc-one\nsvc-two' mktest::stub_function service::installed_labels
  STUB_OUTPUT='ITEMS' mktest::stub_function artifacts::_items_json $'\tservice\tsvc-one\n\tservice\tsvc-two'
  run artifacts::_leftover_services
  [ "$status" -eq 0 ]
  [ "$output" = "ITEMS" ]
}

@test "_leftover_services stops when listing the services fails" {
  STUB_EXIT=97 mktest::stub_function service::installed_labels
  mktest::stub_function artifacts::_items_json
  run artifacts::_leftover_services
  [ "$status" -eq 97 ]
}

# --- _leftover_files ---

@test "_leftover_files lists the files in each module's dirs that match the names it installs" {
  local data_dir="$BATS_TEST_TMPDIR/data/the_module" config_dir="$BATS_TEST_TMPDIR/config/the_module"
  mkdir -p "$data_dir/dumps" "$config_dir/ssh_keys/nested"
  : > "$data_dir/script.sh"
  : > "$data_dir/dumps/user-data.dump"
  : > "$data_dir/notes.txt"
  : > "$config_dir/ssh_keys/one"
  : > "$config_dir/ssh_keys/two"
  : > "$config_dir/ssh_keys/nested/deeper"
  STUB_OUTPUT="the_module" mktest::stub_function modules::defining installed_file_patterns
  STUB_OUTPUT=$'data\tscript.sh\nconfig\tssh_keys/*' mktest::stub_function the_module::installed_file_patterns
  STUB_OUTPUT="$data_dir" mktest::stub_function artifacts::module_data_dir the_module
  STUB_OUTPUT="$config_dir" mktest::stub_function artifacts::module_config_dir the_module
  STUB_OUTPUT="ITEMS" mktest::stub_function artifacts::_items_json \
    "the_module"$'\tfile\t'"$data_dir/script.sh"$'\n'"the_module"$'\tfile\t'"$config_dir/ssh_keys/one"$'\n'"the_module"$'\tfile\t'"$config_dir/ssh_keys/two"
  run artifacts::_leftover_files
  [ "$status" -eq 0 ]
  [ "$output" = "ITEMS" ]
}

@test "_leftover_files finds nothing when no file matches" {
  STUB_OUTPUT="the_module" mktest::stub_function modules::defining installed_file_patterns
  STUB_OUTPUT=$'data\tscript.sh' mktest::stub_function the_module::installed_file_patterns
  STUB_OUTPUT="$BATS_TEST_TMPDIR/missing_data" mktest::stub_function artifacts::module_data_dir the_module
  STUB_OUTPUT="[]" mktest::stub_function artifacts::_items_json ""
  run artifacts::_leftover_files
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "_leftover_files fails on a pattern line that names neither the data nor the config dir" {
  STUB_OUTPUT="the_module" mktest::stub_function modules::defining installed_file_patterns
  STUB_OUTPUT=$'state\tscript.sh' mktest::stub_function the_module::installed_file_patterns
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  mktest::stub_function artifacts::_items_json
  run artifacts::_leftover_files
  [ "$status" -eq 1 ]
  MATCH="the_module" mktest::assert_stub_called lifecycle::fail
}

@test "_leftover_files stops when a module's patterns stop the run" {
  STUB_OUTPUT="the_module" mktest::stub_function modules::defining installed_file_patterns
  STUB_EXIT=97 mktest::stub_function the_module::installed_file_patterns
  mktest::stub_function artifacts::_items_json
  run artifacts::_leftover_files
  [ "$status" -eq 97 ]
}

# --- _stale ---

@test "_stale is what was recorded or left over but is no longer declared" {
  local declared='[{"module":"m","kind":"service","name":"kept"},{"module":"syncthing","kind":"folder","name":"kept"}]'
  local recorded='[{"module":"m","kind":"service","name":"kept"},{"module":"m","kind":"service","name":"dropped"},{"module":"syncthing","kind":"folder","name":"gone"}]'
  local leftovers='[{"module":"","kind":"service","name":"dropped"},{"module":"","kind":"service","name":"kept"},{"module":"m","kind":"file","name":"/fake/old"}]'
  run artifacts::_stale "$declared" "$recorded" "$leftovers"
  [ "$status" -eq 0 ]
  [ "$(jq -c 'sort_by(.name)' <<<"$output")" = '[{"module":"m","kind":"file","name":"/fake/old"},{"module":"m","kind":"service","name":"dropped"},{"module":"syncthing","kind":"folder","name":"gone"}]' ]
}

@test "_stale tells a module's own kind apart by its module" {
  local declared='[{"module":"one","kind":"folder","name":"same"}]'
  local recorded='[{"module":"two","kind":"folder","name":"same"}]'
  run artifacts::_stale "$declared" "$recorded" '[]'
  [ "$(jq -c . <<<"$output")" = '[{"module":"two","kind":"folder","name":"same"}]' ]
}

@test "_stale is empty when everything recorded is still declared" {
  local declared='[{"module":"m","kind":"file","name":"/fake/a"}]'
  run artifacts::_stale "$declared" "$declared" '[]'
  [ "$(jq -c . <<<"$output")" = '[]' ]
}

# --- _report_stale ---

@test "_report_stale lists each stale item" {
  STUB_OUTPUT="service git-backup" mktest::stub_function artifacts::_describe '{"module":"m","kind":"service","name":"git-backup"}'
  artifacts::_report_stale '[{"module":"m","kind":"service","name":"git-backup"}]'
  MATCH="service git-backup" mktest::assert_stub_called logging::info
}

@test "_report_stale says nothing when nothing is stale" {
  artifacts::_report_stale '[]'
  mktest::assert_stub_not_called logging::info
}

# --- _describe ---

@test "_describe names a framework kind by kind and name" {
  run artifacts::_describe '{"module":"m","kind":"file","name":"/fake/path"}'
  [ "$output" = "file /fake/path" ]
}

@test "_describe names a module's own kind with its module" {
  run artifacts::_describe '{"module":"syncthing","kind":"folder","name":"agents"}'
  [ "$output" = "syncthing folder agents" ]
}

# --- _remove_each ---

@test "_remove_each removes every item and lists the ones it could not remove" {
  mktest::stub_function logging::warn
  mktest::stub_function artifacts::_remove '{"name":"a"}'
  STUB_RETURN=1 mktest::stub_function artifacts::_remove '{"name":"b"}'
  mktest::stub_function artifacts::_describe
  run artifacts::_remove_each '[{"name":"a"},{"name":"b"}]'
  [ "$status" -eq 0 ]
  [ "$(jq -c . <<<"$output")" = '[{"name":"b"}]' ]
  mktest::assert_stub_called artifacts::_remove '{"name":"a"}'
  mktest::assert_stub_called logging::warn
}

@test "_remove_each keeps a removal's own output out of the kept list" {
  STUB_OUTPUT="chatter" mktest::stub_function artifacts::_remove '{"name":"a"}'
  mktest::stub_function artifacts::_describe
  run --separate-stderr artifacts::_remove_each '[{"name":"a"}]'
  [ "$(jq -c . <<<"$output")" = '[]' ]
}

@test "_remove_each stops when a removal stops the run" {
  STUB_EXIT=97 mktest::stub_function artifacts::_remove
  mktest::stub_function artifacts::_describe
  run artifacts::_remove_each '[{"name":"a"}]'
  [ "$status" -eq 97 ]
}

# --- _remove ---

@test "_remove uninstalls a service" {
  mktest::stub_function service::uninstall "the-label"
  artifacts::_remove '{"module":"m","kind":"service","name":"the-label"}'
  mktest::assert_stub_called service::uninstall "the-label"
}

@test "_remove deletes a file" {
  mktest::stub_function artifacts::_remove_file "/fake/path"
  artifacts::_remove '{"module":"m","kind":"file","name":"/fake/path"}'
  mktest::assert_stub_called artifacts::_remove_file "/fake/path"
}

@test "_remove hands a module's own kind to that module" {
  mktest::stub_function the_module::remove_artifact "folder" "the-id"
  artifacts::_remove '{"module":"the_module","kind":"folder","name":"the-id"}'
  mktest::assert_stub_called the_module::remove_artifact "folder" "the-id"
}

@test "_remove fails for a module's own kind when the module cannot remove it" {
  mktest::stub_function logging::warn
  run artifacts::_remove '{"module":"no_such_module","kind":"folder","name":"the-id"}'
  [ "$status" -eq 1 ]
  MATCH="no_such_module" mktest::assert_stub_called logging::warn
}

@test "_remove passes on a failed removal" {
  STUB_RETURN=1 mktest::stub_function service::uninstall "the-label"
  run artifacts::_remove '{"module":"m","kind":"service","name":"the-label"}'
  [ "$status" -eq 1 ]
}

# --- _remove_file ---

@test "_remove_file deletes a file inside machinekit's own dirs" {
  local file="$BATS_TEST_TMPDIR/the_file"
  : > "$file"
  mktest::stub_function artifacts::_within_own_dirs "$file"
  artifacts::_remove_file "$file"
  [ ! -e "$file" ]
}

@test "_remove_file succeeds when the file is already gone" {
  mktest::stub_function artifacts::_within_own_dirs "$BATS_TEST_TMPDIR/missing"
  run artifacts::_remove_file "$BATS_TEST_TMPDIR/missing"
  [ "$status" -eq 0 ]
}

@test "_remove_file refuses a path outside machinekit's own dirs and leaves it" {
  local file="$BATS_TEST_TMPDIR/outside"
  : > "$file"
  STUB_RETURN=1 mktest::stub_function artifacts::_within_own_dirs "$file"
  mktest::stub_function logging::warn
  run artifacts::_remove_file "$file"
  [ "$status" -eq 1 ]
  [ -e "$file" ]
  MATCH="$file" mktest::assert_stub_called logging::warn
}

# --- _within_own_dirs ---

@test "_within_own_dirs is true for a path under machinekit's data or config dir" {
  STUB_OUTPUT="/fake/data/machinekit" mktest::stub_function artifacts::_data_dir
  STUB_OUTPUT="/fake/config/machinekit" mktest::stub_function artifacts::_config_dir
  artifacts::_within_own_dirs "/fake/data/machinekit/m/a"
  artifacts::_within_own_dirs "/fake/config/machinekit/m/b"
}

@test "_within_own_dirs is false for a path elsewhere" {
  STUB_OUTPUT="/fake/data/machinekit" mktest::stub_function artifacts::_data_dir
  STUB_OUTPUT="/fake/config/machinekit" mktest::stub_function artifacts::_config_dir
  run ! artifacts::_within_own_dirs "/fake/data/machinekit-other/a"
  run ! artifacts::_within_own_dirs "/fake/data/machinekit"
}

@test "_within_own_dirs is false for a path that climbs out of machinekit's dirs" {
  STUB_OUTPUT="/fake/data/machinekit" mktest::stub_function artifacts::_data_dir
  STUB_OUTPUT="/fake/config/machinekit" mktest::stub_function artifacts::_config_dir
  run ! artifacts::_within_own_dirs "/fake/data/machinekit/../outside"
}

# --- _removal_consented ---

@test "_removal_consented is true when consent resolves true" {
  STUB_OUTPUT="true" mktest::stub_function context::get "remove_unconfigured" \
    --default false --coerce boolean --prompt "$_ARTIFACTS_REMOVAL_PROMPT"
  artifacts::_removal_consented
}

@test "_removal_consented is false when consent resolves false" {
  STUB_OUTPUT="false" mktest::stub_function context::get "remove_unconfigured" \
    --default false --coerce boolean --prompt "$_ARTIFACTS_REMOVAL_PROMPT"
  run ! artifacts::_removal_consented
}

@test "_removal_consented stops when reading consent fails" {
  STUB_EXIT=97 mktest::stub_function context::get
  run artifacts::_removal_consented
  [ "$status" -eq 97 ]
}

# --- _write_record ---

@test "_write_record writes the items to the record file, creating its dir" {
  local record="$BATS_TEST_TMPDIR/state/machinekit/installed.json"
  STUB_OUTPUT="$record" mktest::stub_function artifacts::record_path
  artifacts::_write_record '[{"module":"m","kind":"file","name":"/fake"}]'
  [ "$(jq -c . "$record")" = '[{"module":"m","kind":"file","name":"/fake"}]' ]
  [ -z "$(find "$(dirname "$record")" -name 'installed.json.*')" ]
}

# --- _union ---

@test "_union joins two lists without repeating an item" {
  run artifacts::_union '[{"name":"a"},{"name":"b"}]' '[{"name":"b"},{"name":"c"}]'
  [ "$(jq -c . <<<"$output")" = '[{"name":"a"},{"name":"b"},{"name":"c"}]' ]
}

# --- module_data_dir / module_config_dir ---

@test "module_data_dir is the module's subdir of machinekit's data dir" {
  STUB_OUTPUT="/fake/data/machinekit" mktest::stub_function artifacts::_data_dir
  run artifacts::module_data_dir the_module
  [ "$output" = "/fake/data/machinekit/the_module" ]
}

@test "module_config_dir is the module's subdir of machinekit's config dir" {
  STUB_OUTPUT="/fake/config/machinekit" mktest::stub_function artifacts::_config_dir
  run artifacts::module_config_dir the_module
  [ "$output" = "/fake/config/machinekit/the_module" ]
}

# --- _data_dir / _config_dir ---

@test "_data_dir is machinekit's XDG data dir" {
  XDG_DATA_HOME="/fake/data" run artifacts::_data_dir
  [ "$output" = "/fake/data/machinekit" ]
}

@test "_config_dir is machinekit's XDG config dir" {
  XDG_CONFIG_HOME="/fake/config" run artifacts::_config_dir
  [ "$output" = "/fake/config/machinekit" ]
}
