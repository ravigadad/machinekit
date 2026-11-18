#!/usr/bin/env bats
# Tests for lib/machinekit/service/job.sh — the helpers every scheduled script
# sources: alerting, running a step whose error goes into the alert, and the
# handler that alerts when a run exits in a way no step reported.

load "${BATS_TEST_DIRNAME}/../../../test_helper"

setup() {
  JOB_LIBRARY="$MACHINEKIT_DIR/lib/machinekit/service/job.sh"
  # shellcheck source=../../../../lib/machinekit/service/job.sh
  source "$JOB_LIBRARY"
  NOTIFY_LOG="$BATS_TEST_TMPDIR/notify.log"
  NOTIFY="$BATS_TEST_TMPDIR/notify.sh"
  cat > "$NOTIFY" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$1" >> "$NOTIFY_LOG"
EOF
  chmod +x "$NOTIFY"
}

# A script that sources the library, configures it with the fake notify command,
# and then runs BODY. Running a real bash process is the only way to observe what
# its exit and signal traps do.
write_job() {
  local body="$1"
  cat > "$BATS_TEST_TMPDIR/job_script.sh" <<EOF
set -euo pipefail
source "$JOB_LIBRARY"
job::configure fake-tag "$NOTIFY"
$body
EOF
}

run_job() {
  run "$BASH" "$BATS_TEST_TMPDIR/job_script.sh"
}

# --- job::notify ---

@test "notify runs the configured notify command with the message" {
  job::configure fake-tag "$NOTIFY"
  job::notify "fake message"
  [ "$(cat "$NOTIFY_LOG")" = "fake message" ]
}

@test "notify keeps going when the notify command fails" {
  job::configure fake-tag "$BATS_TEST_TMPDIR/missing-notify"
  run job::notify "fake message"
  [ "$status" -eq 0 ]
}

@test "notify logs to the system log under the tag when no notify command is configured" {
  job::configure fake-tag ""
  mktest::stub_function logger
  job::notify "fake message"
  mktest::assert_stub_called logger -t fake-tag "fake message"
}

@test "notify prints the message to stderr when the system log is unavailable" {
  job::configure fake-tag ""
  STUB_RETURN=1 mktest::stub_function logger
  run --separate-stderr job::notify "fake message"
  [ "$stderr" = "fake message" ]
}

# --- job::fail ---

@test "fail notifies the message and exits nonzero" {
  write_job 'job::fail "fake failure"'
  run_job
  [ "$status" -eq 1 ]
  [ "$(cat "$NOTIFY_LOG")" = "fake failure" ]
}

# --- job::run_step ---

@test "run_step passes a successful command's output through without notifying" {
  job::configure fake-tag "$NOTIFY"
  run job::run_step "fake message" printf 'fake output\n'
  [ "$status" -eq 0 ]
  [ "$output" = "fake output" ]
  [ ! -e "$NOTIFY_LOG" ]
}

@test "run_step notifies the message followed by the end of a failed command's output" {
  job::configure fake-tag "$NOTIFY"
  STUB_OUTPUT="fake tail" mktest::stub_function job::output_tail "fake error"
  failing_command() { printf 'fake error\n' >&2; return 3; }
  run job::run_step "fake message" failing_command
  [ "$status" -eq 1 ]
  [ "$output" = "fake error" ]
  [ "$(cat "$NOTIFY_LOG")" = "fake message fake tail" ]
}

@test "run_step notifies the message alone when a failed command printed nothing" {
  job::configure fake-tag "$NOTIFY"
  silent_failure() { return 3; }
  run job::run_step "fake message" silent_failure
  [ "$status" -eq 1 ]
  [ "$(cat "$NOTIFY_LOG")" = "fake message" ]
}

# --- job::output_tail ---

@test "output_tail joins the last lines of the output onto one line" {
  run job::output_tail $'line 1\nline 2\nline 3\nline 4'
  [ "$output" = "line 2 | line 3 | line 4" ]
}

@test "output_tail keeps output shorter than the limit whole" {
  run job::output_tail "only line"
  [ "$output" = "only line" ]
}

# --- job::alert_on_unexpected_exit ---

@test "an unreported failure alerts with the run's context and exit status" {
  write_job 'job::alert_on_unexpected_exit "fake context"
false'
  run_job
  [ "$status" -eq 1 ]
  [[ "$(cat "$NOTIFY_LOG")" == "fake context failed unexpectedly (exit 1)"* ]]
}

@test "an unreported failure keeps the exit status it had" {
  write_job 'job::alert_on_unexpected_exit "fake context"
exit 7'
  run_job
  [ "$status" -eq 7 ]
}

@test "an unset required variable alerts as an unreported failure" {
  # shellcheck disable=SC2016  # the job script expands the variable, not the test
  write_job 'job::alert_on_unexpected_exit "fake context"
: "${FAKE_REQUIRED_VARIABLE:?FAKE_REQUIRED_VARIABLE required}"'
  run_job
  [ "$status" -ne 0 ]
  [[ "$(cat "$NOTIFY_LOG")" == "fake context failed unexpectedly"* ]]
}

@test "a successful run does not alert" {
  write_job 'job::alert_on_unexpected_exit "fake context"
true'
  run_job
  [ "$status" -eq 0 ]
  [ ! -e "$NOTIFY_LOG" ]
}

@test "a failure already reported through fail does not alert a second time" {
  write_job 'job::alert_on_unexpected_exit "fake context"
job::fail "fake failure"'
  run_job
  [ "$status" -eq 1 ]
  [ "$(cat "$NOTIFY_LOG")" = "fake failure" ]
}

@test "a failure already reported through exit_failed does not alert" {
  write_job 'job::alert_on_unexpected_exit "fake context"
job::exit_failed'
  run_job
  [ "$status" -eq 1 ]
  [ ! -e "$NOTIFY_LOG" ]
}

@test "a run stopped by SIGTERM alerts that it was stopped, with the signal's exit status" {
  write_job 'job::alert_on_unexpected_exit "fake context"
kill -TERM $$
sleep 5'
  run_job
  [ "$status" -eq 143 ]
  [[ "$(cat "$NOTIFY_LOG")" == "fake context was stopped by SIGTERM"* ]]
}

@test "a subshell's handler alerts for the subshell alone, and the parent can report its count without a second alert" {
  write_job 'job::alert_on_unexpected_exit "fake run"
( job::alert_on_unexpected_exit "fake item"; false ) || job::exit_failed'
  run_job
  [ "$status" -eq 1 ]
  [[ "$(cat "$NOTIFY_LOG")" == "fake item failed unexpectedly"* ]]
  [ "$(wc -l < "$NOTIFY_LOG" | tr -d ' ')" = "1" ]
}

# --- job::run_item / job::exit_failed_if_items_failed ---

@test "run_item stops an item at its first failing command" {
  write_job 'item() { false; echo "kept going"; }
job::run_item item'
  run_job
  [[ "$output" != *"kept going"* ]]
}

@test "run_item keeps the run going after a failed item, and the run then exits with the failure" {
  write_job 'job::alert_on_unexpected_exit "fake run"
failing_item() { job::fail "fake item failure"; }
passing_item() { echo "second item ran"; }
job::run_item failing_item
job::run_item passing_item
job::exit_failed_if_items_failed'
  run_job
  [ "$status" -eq 1 ]
  [[ "$output" == *"second item ran"* ]]
  [ "$(cat "$NOTIFY_LOG")" = "fake item failure" ]
}

@test "exit_failed_if_items_failed carries on when every item succeeded" {
  write_job 'passing_item() { :; }
job::run_item passing_item
job::exit_failed_if_items_failed
echo "carried on"'
  run_job
  [ "$status" -eq 0 ]
  [ "$output" = "carried on" ]
}

@test "run_item leaves the run stopping on errors after it" {
  write_job 'failing_item() { false; }
job::run_item failing_item
false
echo "kept going"'
  run_job
  [ "$status" -ne 0 ]
  [[ "$output" != *"kept going"* ]]
}

# --- job::delete_on_exit / job::keep_files_on_exit ---

@test "delete_on_exit removes the file whichever way the run exits" {
  local in_flight="$BATS_TEST_TMPDIR/in-flight"
  write_job "job::alert_on_unexpected_exit 'fake context'
: > '$in_flight'
job::delete_on_exit '$in_flight'
job::fail 'fake failure'"
  run_job
  [ ! -e "$in_flight" ]
}

@test "a file that can't be removed at exit does not stop the alert" {
  local locked="$BATS_TEST_TMPDIR/locked"
  mkdir -p "$locked"
  : > "$locked/in-flight"
  chmod 555 "$locked"
  write_job "job::alert_on_unexpected_exit 'fake context'
job::delete_on_exit '$locked/in-flight'
false"
  run_job
  chmod 755 "$locked"
  [[ "$(cat "$NOTIFY_LOG")" == "fake context failed unexpectedly"* ]]
}

@test "keep_files_on_exit stops a file from being removed at exit" {
  local finished="$BATS_TEST_TMPDIR/finished"
  write_job "job::alert_on_unexpected_exit 'fake context'
: > '$finished'
job::delete_on_exit '$finished'
job::keep_files_on_exit"
  run_job
  [ "$status" -eq 0 ]
  [ -e "$finished" ]
}

# --- job::exit_failed ---

@test "exit_failed exits nonzero without notifying" {
  write_job 'job::exit_failed'
  run_job
  [ "$status" -eq 1 ]
  [ ! -e "$NOTIFY_LOG" ]
}
