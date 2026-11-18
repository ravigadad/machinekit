#!/usr/bin/env bash
# job — helpers for the scripts that service.sh schedules. Each scheduled script
# sources this file from beside itself (service::install_script copies it there),
# so a script still depends on nothing outside its own directory. It is not part
# of lib/machinekit.sh: apply never sources it.
#
# A run reports trouble through the notify command its module configured, and
# falls back to the system log. A step that can be expected to fail runs through
# job::run_step, whose alert names the step and ends with the tool's own error.
# Anything else that ends the run with a failure — a command nobody wrapped, an
# unset variable, a signal — is caught by the handler that
# job::alert_on_unexpected_exit installs, which sends a general alert instead.
# A script that has already reported its failure leaves through job::fail or
# job::exit_failed, so the handler stays quiet and nothing is reported twice.
[ -n "${_MK_JOB_LOADED:-}" ] && return 0
_MK_JOB_LOADED=1

# How many of a failed tool's last output lines go into an alert. A tool prints
# its error last; the full output goes to the job's log.
_JOB_NOTIFY_OUTPUT_LINES=3

_JOB_TAG=""
_JOB_NOTIFY_COMMAND=""
_JOB_CONTEXT=""
_JOB_EXIT_REPORTED=0
_JOB_SIGNAL=""
_JOB_DELETE_ON_EXIT=""
_JOB_FAILED_ITEMS=0

# TAG names the run in the system log; NOTIFY_COMMAND, when set, is run with one
# message argument instead.
job::configure() {
  _JOB_TAG="$1"
  _JOB_NOTIFY_COMMAND="$2"
}

job::notify() {
  local message="$1"
  if [ -n "$_JOB_NOTIFY_COMMAND" ]; then
    "$_JOB_NOTIFY_COMMAND" "$message" || true
  else
    logger -t "$_JOB_TAG" "$message" 2>/dev/null || printf '%s\n' "$message" >&2
  fi
}

job::fail() {
  job::notify "$1"
  job::exit_failed
}

# Leave with a failure every alert for has already been sent, such as a count of
# items that each notified on their own.
job::exit_failed() {
  _JOB_EXIT_REPORTED=1
  exit 1
}

# Run a command, passing its output through to the job's log. When it fails,
# notify MESSAGE followed by the last lines of that output, so the alert says why,
# and return nonzero.
job::run_step() {
  local message="$1" output
  shift
  if output=$("$@" 2>&1); then
    [ -z "$output" ] || printf '%s\n' "$output"
    return 0
  fi
  [ -z "$output" ] || printf '%s\n' "$output"
  job::notify "$message${output:+ ${ job::output_tail "$output"; }}"
  return 1
}

# The last lines of OUTPUT joined onto one line, for an alert.
job::output_tail() {
  printf '%s\n' "$1" | tail -n "$_JOB_NOTIFY_OUTPUT_LINES" \
    | awk 'NR > 1 { printf " | " } { printf "%s", $0 } END { print "" }'
}

# Alert when this shell exits with a failure nothing reported, naming CONTEXT
# ("postgres_dump: dump of 'app'"). A `( … )` subshell does not inherit an exit
# trap, so a script that runs each item in a subshell calls this again inside it.
# The signals get their own traps because an exit trap that runs after a signal
# reads a status of 0.
job::alert_on_unexpected_exit() {
  _JOB_CONTEXT="$1"
  _JOB_EXIT_REPORTED=0
  _JOB_SIGNAL=""
  trap 'job::_on_exit' EXIT
  trap 'job::_on_signal HUP 129' HUP
  trap 'job::_on_signal INT 130' INT
  trap 'job::_on_signal TERM 143' TERM
}

# Run one item of a run — a database, a folder — in its own subshell, so a
# failure ends that item and the run moves on to the next. Call it as a plain
# statement, never behind `||`, `&&`, `if` or `!`: bash ignores `set -e` in
# everything a tested command runs, so the item would carry on past a failed
# command. That is also why the outcome is counted here rather than returned.
job::run_item() {
  local item_status
  set +e
  ( set -e; "$@" )
  item_status=$?
  set -e
  [ "$item_status" -eq 0 ] || _JOB_FAILED_ITEMS=$((_JOB_FAILED_ITEMS + 1))
}

# Leave with a failure when any item failed. Each failed item already alerted.
job::exit_failed_if_items_failed() {
  [ "$_JOB_FAILED_ITEMS" -eq 0 ] || job::exit_failed
}

# Remove PATH when the shell exits, unless keep_files_on_exit is called first. For
# a file that must never be left half-written.
job::delete_on_exit() {
  _JOB_DELETE_ON_EXIT="$1"
}

job::keep_files_on_exit() {
  _JOB_DELETE_ON_EXIT=""
}

job::_on_signal() {
  _JOB_SIGNAL="$1"
  exit "$2"
}

# A file that can't be removed must not stop the alert; rm's own error still
# reaches the job's log.
job::_on_exit() {
  local status=$?
  [ -z "$_JOB_DELETE_ON_EXIT" ] || rm -f -- "$_JOB_DELETE_ON_EXIT" || true
  [ "$status" -ne 0 ] || return 0
  [ "$_JOB_EXIT_REPORTED" -eq 0 ] || return 0
  if [ -n "$_JOB_SIGNAL" ]; then
    job::notify "$_JOB_CONTEXT was stopped by SIG$_JOB_SIGNAL before it finished; see the job's log."
  else
    job::notify "$_JOB_CONTEXT failed unexpectedly (exit $status); see the job's log for the error."
  fi
}
