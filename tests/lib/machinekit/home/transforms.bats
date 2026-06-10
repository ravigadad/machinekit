#!/usr/bin/env bats
# Tests for lib/machinekit/home/transforms.sh

load "${BATS_TEST_DIRNAME}/../../../test_helper"

setup() {
  # shellcheck source=../../../../lib/machinekit/home/transforms.sh
  source "$MACHINEKIT_DIR/lib/machinekit/home/transforms.sh"
  unset _MK_HOME_TRANSFORMS_LOADED

  _MK_HOME_TRANSFORM_EXTS=()
  _MK_HOME_TRANSFORM_TIERS=()
  _MK_HOME_TRANSFORM_FNS=()
  _MK_HOME_TRANSFORM_PIPELINE=()
  _MK_HOME_TRANSFORM_TEMPS=()
  _MK_HOME_TRANSFORM_DEST=""
  _MK_HOME_TRANSFORM_CONTENT=""
  unset _MK_HOME_TRANSFORM_CLEANUP_REGISTERED

  # Logging collaborators — allow-only; mechanism, not contract.
  mktest::stub_function logging::step
  mktest::stub_function logging::debug
}

# --- load guard ---

@test "sourcing twice does not redefine functions" {
  home::transforms::register() { echo "original"; }
  _MK_HOME_TRANSFORMS_LOADED=1
  source "$MACHINEKIT_DIR/lib/machinekit/home/transforms.sh"
  [ "$(home::transforms::register)" = "original" ]
}

# --- home::transforms::register ---

@test "register makes an extension resolvable via lookup" {
  home::transforms::register gz decode zip::decompress
  [ "$(home::transforms::lookup gz)" = "decode zip::decompress" ]
}

@test "register hard-fails on an invalid tier, naming the extension" {
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run ! home::transforms::register gz sideways zip::decompress
  MATCH="gz" mktest::assert_stub_called lifecycle::fail
}

@test "register hard-fails when an extension is claimed by a different handler, naming both" {
  home::transforms::register gz decode zip::decompress
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run ! home::transforms::register gz decode other::inflate
  MATCH="zip::decompress and other::inflate" mktest::assert_stub_called lifecycle::fail
}

@test "register hard-fails when an extension is re-registered with a different tier" {
  home::transforms::register tmpl content gomplate::render
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run ! home::transforms::register tmpl decode gomplate::render
  mktest::assert_stub_called lifecycle::fail
}

@test "register is an idempotent no-op, logged, when the identical tuple is re-registered" {
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  home::transforms::register gz decode zip::decompress
  home::transforms::register gz decode zip::decompress
  [ "$(home::transforms::lookup gz)" = "decode zip::decompress" ]
  [ "${#_MK_HOME_TRANSFORM_EXTS[@]}" -eq 1 ]
  mktest::assert_stub_not_called lifecycle::fail
  MATCH="gz" mktest::assert_stub_called logging::debug
}

# --- home::transforms::register_from_modules ---

@test "register_from_modules registers each active module's declared transforms" {
  mktest::stub_function home::transforms::register
  mktest::stub_function modules::source_all
  STUB_OUTPUT=$'mod_a\nmod_b\nmod_c' mktest::stub_function context::get_array "modules.active"
  mod_a::file_transforms() {
    printf '%s\n' "gz   decode zip::decompress"
    printf '%s\n' "tmpl content gomplate::render"
  }
  mod_b::file_transforms() { printf '%s\n' "age decode age::decrypt"; }
  # mod_c declares no file_transforms hook — must be skipped.

  home::transforms::register_from_modules

  mktest::assert_stub_called home::transforms::register gz decode zip::decompress
  mktest::assert_stub_called home::transforms::register tmpl content gomplate::render
  mktest::assert_stub_called home::transforms::register age decode age::decrypt
  TIMES=3 mktest::assert_stub_called home::transforms::register
}

@test "register_from_modules hard-fails on a malformed file_transforms line" {
  mktest::stub_function home::transforms::register
  mktest::stub_function modules::source_all
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  STUB_OUTPUT="mod_a" mktest::stub_function context::get_array "modules.active"
  mod_a::file_transforms() { printf '%s\n' "gz decode zip::decompress extra"; }
  run ! home::transforms::register_from_modules
  MATCH="malformed" mktest::assert_stub_called lifecycle::fail
}

# --- home::transforms::lookup ---

@test "lookup prints tier and handler for a registered extension" {
  home::transforms::register tmpl content gomplate::render
  [ "$(home::transforms::lookup tmpl)" = "content gomplate::render" ]
}

@test "lookup returns nonzero for an unregistered extension" {
  run ! home::transforms::lookup nope
  [ "$status" -eq 1 ]
}

# --- home::transforms::apply ---

@test "apply parses the destination, then executes the pipeline against the source" {
  mktest::stub_function home::transforms::_parse
  mktest::stub_function home::transforms::_execute
  home::transforms::apply "/staging/foo.md.tmpl.age" "foo.md.tmpl.age"
  mktest::assert_stub_called_in_order home::transforms::_parse "foo.md.tmpl.age"
  mktest::assert_stub_called_in_order home::transforms::_execute "/staging/foo.md.tmpl.age"
}

# --- home::transforms::_index_of ---

@test "_index_of prints the position of a registered extension" {
  _MK_HOME_TRANSFORM_EXTS=(gz tmpl age)
  [ "$(home::transforms::_index_of tmpl)" = "1" ]
}

@test "_index_of returns nonzero when the extension is absent" {
  _MK_HOME_TRANSFORM_EXTS=(gz)
  run ! home::transforms::_index_of age
  [ "$status" -eq 1 ]
}

# --- home::transforms::_parse ---

@test "_parse strips a single registered suffix and records its handler" {
  STUB_OUTPUT="content gomplate::render" mktest::stub_function home::transforms::lookup tmpl
  STUB_RETURN=1 mktest::stub_function home::transforms::lookup conf
  home::transforms::_parse "app.conf.tmpl"
  [ "$_MK_HOME_TRANSFORM_DEST" = "app.conf" ]
  [ "${#_MK_HOME_TRANSFORM_PIPELINE[@]}" -eq 1 ]
  [ "${_MK_HOME_TRANSFORM_PIPELINE[0]}" = "gomplate::render" ]
}

@test "_parse peels nested suffixes right-to-left into execution order" {
  STUB_OUTPUT="decode age::decrypt" mktest::stub_function home::transforms::lookup age
  STUB_OUTPUT="content gomplate::render" mktest::stub_function home::transforms::lookup tmpl
  STUB_RETURN=1 mktest::stub_function home::transforms::lookup md
  home::transforms::_parse "foo.md.tmpl.age"
  [ "$_MK_HOME_TRANSFORM_DEST" = "foo.md" ]
  [ "${#_MK_HOME_TRANSFORM_PIPELINE[@]}" -eq 2 ]
  [ "${_MK_HOME_TRANSFORM_PIPELINE[0]}" = "age::decrypt" ]
  [ "${_MK_HOME_TRANSFORM_PIPELINE[1]}" = "gomplate::render" ]
}

@test "_parse keeps an unregistered terminal extension and yields an empty pipeline" {
  STUB_RETURN=1 mktest::stub_function home::transforms::lookup md
  home::transforms::_parse "README.md"
  [ "$_MK_HOME_TRANSFORM_DEST" = "README.md" ]
  [ "${#_MK_HOME_TRANSFORM_PIPELINE[@]}" -eq 0 ]
}

@test "_parse peels only the basename, leaving directory components intact" {
  STUB_OUTPUT="content gomplate::render" mktest::stub_function home::transforms::lookup tmpl
  STUB_RETURN=1 mktest::stub_function home::transforms::lookup conf
  home::transforms::_parse ".config/app.conf.tmpl"
  [ "$_MK_HOME_TRANSFORM_DEST" = ".config/app.conf" ]
  [ "${_MK_HOME_TRANSFORM_PIPELINE[0]}" = "gomplate::render" ]
}

@test "_parse hard-fails when a decode marker follows a content marker" {
  STUB_OUTPUT="content gomplate::render" mktest::stub_function home::transforms::lookup tmpl
  STUB_OUTPUT="decode age::decrypt" mktest::stub_function home::transforms::lookup age
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run ! home::transforms::_parse "foo.md.age.tmpl"
  MATCH="decode" mktest::assert_stub_called lifecycle::fail
}

@test "_parse peels stacked decode markers without tripping the cross-tier law" {
  STUB_OUTPUT="decode age::decrypt" mktest::stub_function home::transforms::lookup age
  STUB_OUTPUT="decode zip::decompress" mktest::stub_function home::transforms::lookup gz
  STUB_RETURN=1 mktest::stub_function home::transforms::lookup foo
  home::transforms::_parse "foo.gz.age"
  [ "$_MK_HOME_TRANSFORM_DEST" = "foo" ]
  [ "${#_MK_HOME_TRANSFORM_PIPELINE[@]}" -eq 2 ]
  [ "${_MK_HOME_TRANSFORM_PIPELINE[0]}" = "age::decrypt" ]
  [ "${_MK_HOME_TRANSFORM_PIPELINE[1]}" = "zip::decompress" ]
}

@test "_parse keeps a leading-dot dotfile whose whole name matches a marker" {
  # The leading dot is a dotfile marker, not an extension separator — '.tmpl'
  # must stay '.tmpl', never collapse to ''. tmpl is registered here so the guard,
  # not a lookup miss, is what stops the peel.
  STUB_OUTPUT="content gomplate::render" mktest::stub_function home::transforms::lookup tmpl
  home::transforms::_parse ".tmpl"
  [ "$_MK_HOME_TRANSFORM_DEST" = ".tmpl" ]
  [ "${#_MK_HOME_TRANSFORM_PIPELINE[@]}" -eq 0 ]
}

@test "_parse peels a real extension off a dotfile while preserving the leading-dot stem" {
  STUB_OUTPUT="content gomplate::render" mktest::stub_function home::transforms::lookup tmpl
  home::transforms::_parse ".foo.tmpl"
  [ "$_MK_HOME_TRANSFORM_DEST" = ".foo" ]
  [ "${#_MK_HOME_TRANSFORM_PIPELINE[@]}" -eq 1 ]
  [ "${_MK_HOME_TRANSFORM_PIPELINE[0]}" = "gomplate::render" ]
}

# --- home::transforms::_execute ---

@test "_execute runs a single handler and exposes its output as the content path" {
  mktest::stub_function lifecycle::register_cleanup
  fake_a::stage() { printf 'A:'; cat "$1"; }
  _MK_HOME_TRANSFORM_PIPELINE=(fake_a::stage)
  local src="$BATS_TEST_TMPDIR/src"
  printf 'seed\n' > "$src"
  home::transforms::_execute "$src"
  [ "$_MK_HOME_TRANSFORM_CONTENT" != "$src" ]
  [ "$(cat "$_MK_HOME_TRANSFORM_CONTENT")" = "A:seed" ]
}

@test "_execute chains handlers in pipeline order, threading each output into the next" {
  mktest::stub_function lifecycle::register_cleanup
  fake_a::stage() { printf 'A:'; cat "$1"; }
  fake_b::stage() { printf 'B:'; cat "$1"; }
  _MK_HOME_TRANSFORM_PIPELINE=(fake_a::stage fake_b::stage)
  local src="$BATS_TEST_TMPDIR/src"
  printf 'seed\n' > "$src"
  home::transforms::_execute "$src"
  [ "$(cat "$_MK_HOME_TRANSFORM_CONTENT")" = "B:A:seed" ]
}

@test "_execute removes the intermediate temp, keeping only the final content" {
  mktest::stub_function lifecycle::register_cleanup
  local marker="$BATS_TEST_TMPDIR/intermediate"
  fake_a::stage() { printf 'A:'; cat "$1"; }
  # The second stage's input is the first stage's output temp — the intermediate.
  fake_b::stage() { printf '%s' "$1" > "$marker"; printf 'B:'; cat "$1"; }
  _MK_HOME_TRANSFORM_PIPELINE=(fake_a::stage fake_b::stage)
  local src="$BATS_TEST_TMPDIR/src"
  printf 'seed\n' > "$src"
  home::transforms::_execute "$src"
  local intermediate
  intermediate=$(cat "$marker")
  [ ! -f "$intermediate" ]
  [ "$intermediate" != "$_MK_HOME_TRANSFORM_CONTENT" ]
  [ -f "$_MK_HOME_TRANSFORM_CONTENT" ]
}

@test "_execute identity-copies the source to a removable temp when the pipeline is empty" {
  mktest::stub_function lifecycle::register_cleanup
  _MK_HOME_TRANSFORM_PIPELINE=()
  local src="$BATS_TEST_TMPDIR/src"
  printf 'hello\n' > "$src"
  home::transforms::_execute "$src"
  [ "$_MK_HOME_TRANSFORM_CONTENT" != "$src" ]
  [ "$(cat "$_MK_HOME_TRANSFORM_CONTENT")" = "hello" ]
}

@test "_execute registers a cleanup hook for the temps it creates" {
  mktest::stub_function lifecycle::register_cleanup
  fake_a::stage() { printf 'A:'; cat "$1"; }
  _MK_HOME_TRANSFORM_PIPELINE=(fake_a::stage)
  local src="$BATS_TEST_TMPDIR/src"
  printf 'seed\n' > "$src"
  home::transforms::_execute "$src"
  mktest::assert_stub_called lifecycle::register_cleanup home::transforms::_cleanup_temps
}

@test "_execute aborts and skips later stages when a handler fails" {
  mktest::stub_function lifecycle::register_cleanup
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  local second_ran="$BATS_TEST_TMPDIR/second_ran"
  failing::stage() { return 1; }
  second::stage() { printf 'ran' > "$second_ran"; cat "$1"; }
  _MK_HOME_TRANSFORM_PIPELINE=(failing::stage second::stage)
  local src="$BATS_TEST_TMPDIR/src"
  printf 'seed\n' > "$src"
  run ! home::transforms::_execute "$src"
  MATCH="failing::stage" mktest::assert_stub_called lifecycle::fail
  [ ! -f "$second_ran" ]
}

# --- home::transforms::_cleanup_temps ---

@test "_cleanup_temps removes every tracked temp and clears the list" {
  local f1="$BATS_TEST_TMPDIR/t1" f2="$BATS_TEST_TMPDIR/t2"
  printf 'x\n' > "$f1"
  printf 'y\n' > "$f2"
  _MK_HOME_TRANSFORM_TEMPS=("$f1" "$f2")
  home::transforms::_cleanup_temps
  [ ! -f "$f1" ]
  [ ! -f "$f2" ]
  [ "${#_MK_HOME_TRANSFORM_TEMPS[@]}" -eq 0 ]
}
