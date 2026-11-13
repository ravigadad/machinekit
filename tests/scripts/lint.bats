#!/usr/bin/env bats
# Tests for scripts/lint's while-read loop check — run as a subprocess in a
# fixture tree. shellcheck is replaced on PATH by a stub that passes, so only
# the loop check decides the result.

load "${BATS_TEST_DIRNAME}/../test_helper"

setup() {
  fixture_dir="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$fixture_dir/scripts" "$BATS_TEST_TMPDIR/bin"
  cp "$MACHINEKIT_DIR/scripts/lint" "$fixture_dir/scripts/lint"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$BATS_TEST_TMPDIR/bin/shellcheck"
  chmod +x "$BATS_TEST_TMPDIR/bin/shellcheck"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

_mk_test_write() {
  mkdir -p "$(dirname "$fixture_dir/$1")"
  printf '%s\n' "$2" > "$fixture_dir/$1"
}

# Spelled through a variable because scripts/lint checks this file too, and
# would flag the loop if it were written out.
_mk_test_stdin_loop() {
  local read_builtin=read
  printf 'while IFS= %s -r item; do :; done\n' "$read_builtin"
}

_mk_test_lint() {
  run "$fixture_dir/scripts/lint"
}

@test "lint passes loops that read from their own descriptor" {
  # shellcheck disable=SC2016 # the fixture's shell source, written literally
  _mk_test_write lib/fake.sh '#!/usr/bin/env bash
while IFS= read -u 3 -r item; do :; done 3<<< "$items"
while IFS=$'"'"'\t'"'"' read -u 4 -r key value; do :; done 4<<< "$pairs"'
  _mk_test_lint
  [ "$status" -eq 0 ]
}

@test "lint rejects a loop that reads stdin, naming its file and line" {
  _mk_test_write lib/fake.sh "#!/usr/bin/env bash
$(_mk_test_stdin_loop)"
  _mk_test_lint
  [ "$status" -eq 1 ]
  [[ "$output" == *"lib/fake.sh:2:"* ]]
}

@test "lint ignores a commented-out loop that reads stdin" {
  _mk_test_write lib/fake.sh "#!/usr/bin/env bash
# $(_mk_test_stdin_loop)"
  _mk_test_lint
  [ "$status" -eq 0 ]
}

@test "lint checks loops in every file it runs shellcheck on" {
  local path
  local -a paths=(bin/fake libexec/fake install.sh lib/modules/fake/nested.sh
    scripts/fake tests/helpers/fake.sh tests/vm/cases/fake tests/vm/run
    tests/test_helper.bash tests/lib/fake.bats)
  for path in "${paths[@]}"; do _mk_test_write "$path" "$(_mk_test_stdin_loop)"; done
  _mk_test_lint
  [ "$status" -eq 1 ]
  for path in "${paths[@]}"; do [[ "$output" == *"$path:1:"* ]]; done
}
