#!/usr/bin/env bats
# Tests for lib/modules/offsite_backup/restic_run.sh — the standalone,
# manifest-driven restic runner. restic is the one external tool it drives and
# the service unit pins it by absolute path; the tests pin a fake through the
# same env var, so what is exercised is exactly the production seam.

load "${BATS_TEST_DIRNAME}/../../../test_helper"

setup() {
  SCRIPT="$MACHINEKIT_DIR/lib/modules/offsite_backup/restic_run.sh"
  SOURCE_DIR="$BATS_TEST_TMPDIR/source"
  MANIFEST="$BATS_TEST_TMPDIR/manifest.tsv"
  NOTIFY_LOG="$BATS_TEST_TMPDIR/notify.log"
  NOTIFY="$BATS_TEST_TMPDIR/notify.sh"
  RESTIC="$BATS_TEST_TMPDIR/restic"
  RESTIC_ARGV="$BATS_TEST_TMPDIR/restic.argv"
  RESTIC_ENV="$BATS_TEST_TMPDIR/restic.env"
  PASSWORD_FILE="$BATS_TEST_TMPDIR/repository_password"
  CREDENTIALS_FILE="$BATS_TEST_TMPDIR/credentials"
  cat > "$NOTIFY" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$1" >> "$NOTIFY_LOG"
EOF
  chmod +x "$NOTIFY"
  printf 'fake-repository-password' > "$PASSWORD_FILE"
  mkdir -p "$SOURCE_DIR"
  printf 'content\n' > "$SOURCE_DIR/dump.file"
  fake_restic 0
}

# A restic that records each invocation's argv and the repository/credential
# environment it was handed, then exits with EXIT_STATUS.
fake_restic() {
  local exit_status="$1"
  cat > "$RESTIC" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$RESTIC_ARGV"
{ printf 'RESTIC_REPOSITORY=%s\n' "\${RESTIC_REPOSITORY:-}"
  printf 'RESTIC_PASSWORD_FILE=%s\n' "\${RESTIC_PASSWORD_FILE:-}"
  printf 'FAKE_BACKEND_KEY=%s\n' "\${FAKE_BACKEND_KEY:-}"
  printf 'FAKE_BACKEND_SECRET=%s\n' "\${FAKE_BACKEND_SECRET:-}"
} > "$RESTIC_ENV"
exit $exit_status
EOF
  chmod +x "$RESTIC"
}

# A restic that fails only for invocations matching PATTERN, so a test can fail
# one subcommand (backup, forget, check) while the rest succeed.
fake_restic_failing_on() {
  local pattern="$1"
  cat > "$RESTIC" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$RESTIC_ARGV"
case "\$*" in *$pattern*) exit 1 ;; esac
exit 0
EOF
  chmod +x "$RESTIC"
}

run_mode() {
  local mode="$1"; shift
  run env \
    MK_OFFSITE_BACKUP_MODE="$mode" \
    MK_OFFSITE_BACKUP_MANIFEST="$MANIFEST" \
    MK_OFFSITE_BACKUP_NOTIFY="$NOTIFY" \
    MK_OFFSITE_BACKUP_RESTIC="$RESTIC" \
    MK_OFFSITE_BACKUP_REPOSITORY="fake:repository" \
    MK_OFFSITE_BACKUP_PASSWORD_FILE="$PASSWORD_FILE" \
    "$@" \
    bash "$SCRIPT"
}

# The common case: one path with a keep policy, no staleness deadline.
run_backup() {
  printf '%s\t%s\n' "$SOURCE_DIR" "" > "$MANIFEST"
  run_mode backup MK_OFFSITE_BACKUP_KEEP_DAILY=7 "$@"
}

# --- backup: the golden path ---

@test "backs up each configured path and prunes to the keep policy" {
  run_backup
  [ "$status" -eq 0 ]
  grep -q "^backup .*$SOURCE_DIR" "$RESTIC_ARGV"
  grep -q "^forget .*--prune" "$RESTIC_ARGV"
  grep -q -- "--keep-daily 7" "$RESTIC_ARGV"
  [ ! -f "$NOTIFY_LOG" ]
}

@test "hands restic the repository and password file from the pinned paths" {
  run_backup
  [ "$status" -eq 0 ]
  grep -q "^RESTIC_REPOSITORY=fake:repository$" "$RESTIC_ENV"
  grep -q "^RESTIC_PASSWORD_FILE=$PASSWORD_FILE$" "$RESTIC_ENV"
}

@test "exports the backend credentials file as environment variables" {
  # Backends read wholly different variable names, so the file is carried
  # opaquely: whatever KEY=value lines it holds become environment variables.
  printf 'FAKE_BACKEND_KEY=some-key\nFAKE_BACKEND_SECRET=some-secret\n' > "$CREDENTIALS_FILE"
  run_backup MK_OFFSITE_BACKUP_CREDENTIALS_FILE="$CREDENTIALS_FILE"
  [ "$status" -eq 0 ]
  grep -q "^FAKE_BACKEND_KEY=some-key$" "$RESTIC_ENV"
  grep -q "^FAKE_BACKEND_SECRET=some-secret$" "$RESTIC_ENV"
}

@test "ignores a credentials line that is not a KEY=value pair rather than dying on it" {
  # The file is a secret the operator authored; a stray line must not take the
  # whole backup down before anything can notify about it.
  printf 'not a variable\nFAKE_BACKEND_KEY=some-key\n' > "$CREDENTIALS_FILE"
  run_backup MK_OFFSITE_BACKUP_CREDENTIALS_FILE="$CREDENTIALS_FILE"
  [ "$status" -eq 0 ]
  grep -q "^FAKE_BACKEND_KEY=some-key$" "$RESTIC_ENV"
}

@test "keeps a credential value containing an equals sign intact" {
  printf 'FAKE_BACKEND_SECRET=abc==def\n' > "$CREDENTIALS_FILE"
  run_backup MK_OFFSITE_BACKUP_CREDENTIALS_FILE="$CREDENTIALS_FILE"
  [ "$status" -eq 0 ]
  grep -q "^FAKE_BACKEND_SECRET=abc==def$" "$RESTIC_ENV"
}

@test "tags its own snapshots and forgets only those" {
  # A repository may hold snapshots this machine did not write; an untagged
  # forget --prune would delete them.
  run_backup
  [ "$status" -eq 0 ]
  grep -q "^backup .*--tag machinekit" "$RESTIC_ARGV"
  grep -q "^forget .*--tag machinekit" "$RESTIC_ARGV"
}

@test "backs up every path in the manifest" {
  local other="$BATS_TEST_TMPDIR/other"
  mkdir -p "$other"
  printf '%s\t\n%s\t\n' "$SOURCE_DIR" "$other" > "$MANIFEST"
  run_mode backup MK_OFFSITE_BACKUP_KEEP_DAILY=7
  [ "$status" -eq 0 ]
  grep -q "^backup .*$SOURCE_DIR" "$RESTIC_ARGV"
  grep -q "^backup .*$other" "$RESTIC_ARGV"
}

# --- backup: retention safety ---

@test "skips forget entirely when no keep policy is configured" {
  # forget --prune with no --keep-* deletes every snapshot in the repository.
  printf '%s\t%s\n' "$SOURCE_DIR" "" > "$MANIFEST"
  run_mode backup
  [ "$status" -eq 0 ]
  run ! grep -q "^forget" "$RESTIC_ARGV"
}

@test "passes every configured keep window through to forget" {
  printf '%s\t%s\n' "$SOURCE_DIR" "" > "$MANIFEST"
  run_mode backup \
    MK_OFFSITE_BACKUP_KEEP_DAILY=7 \
    MK_OFFSITE_BACKUP_KEEP_WEEKLY=4 \
    MK_OFFSITE_BACKUP_KEEP_MONTHLY=12
  [ "$status" -eq 0 ]
  grep -q -- "--keep-daily 7" "$RESTIC_ARGV"
  grep -q -- "--keep-weekly 4" "$RESTIC_ARGV"
  grep -q -- "--keep-monthly 12" "$RESTIC_ARGV"
}

# --- backup: failure handling ---

@test "a failed path notifies and exits non-zero" {
  fake_restic_failing_on "backup"
  run_backup
  [ "$status" -ne 0 ]
  grep -q "backup failed" "$NOTIFY_LOG"
}

@test "isolates a failing path: the others still back up and the run exits non-zero" {
  local other="$BATS_TEST_TMPDIR/other"
  mkdir -p "$other"
  fake_restic_failing_on "$SOURCE_DIR"
  printf '%s\t\n%s\t\n' "$SOURCE_DIR" "$other" > "$MANIFEST"
  run_mode backup MK_OFFSITE_BACKUP_KEEP_DAILY=7
  [ "$status" -ne 0 ]
  grep -q "backup failed" "$NOTIFY_LOG"
  grep -q "^backup .*$other" "$RESTIC_ARGV"
}

@test "a failed prune notifies and exits non-zero" {
  fake_restic_failing_on "forget"
  run_backup
  [ "$status" -ne 0 ]
  grep -q "prune failed" "$NOTIFY_LOG"
}

# --- backup: the staleness alarm ---

@test "notifies and exits non-zero when nothing under a path is newer than its deadline" {
  # A dump that quietly stops running while the upload keeps succeeding is
  # otherwise invisible — the whole point of the deadline.
  touch -t 202001010000 "$SOURCE_DIR/dump.file"
  printf '%s\t%s\n' "$SOURCE_DIR" "36" > "$MANIFEST"
  run_mode backup MK_OFFSITE_BACKUP_KEEP_DAILY=7
  [ "$status" -ne 0 ]
  grep -q "36h" "$NOTIFY_LOG"
}

@test "stays quiet when something under the path is newer than its deadline" {
  printf '%s\t%s\n' "$SOURCE_DIR" "36" > "$MANIFEST"
  run_mode backup MK_OFFSITE_BACKUP_KEEP_DAILY=7
  [ "$status" -eq 0 ]
  [ ! -f "$NOTIFY_LOG" ]
}

@test "does not check staleness for a path with no deadline" {
  touch -t 202001010000 "$SOURCE_DIR/dump.file"
  run_backup
  [ "$status" -eq 0 ]
  [ ! -f "$NOTIFY_LOG" ]
}

@test "still backs a stale path up rather than skipping it" {
  touch -t 202001010000 "$SOURCE_DIR/dump.file"
  printf '%s\t%s\n' "$SOURCE_DIR" "36" > "$MANIFEST"
  run_mode backup MK_OFFSITE_BACKUP_KEEP_DAILY=7
  grep -q "^backup .*$SOURCE_DIR" "$RESTIC_ARGV"
}

# --- check ---

@test "check verifies the repository without re-downloading its data" {
  run_mode check
  [ "$status" -eq 0 ]
  grep -q "^check$" "$RESTIC_ARGV"
  [ ! -f "$NOTIFY_LOG" ]
}

@test "check re-reads the data when that is explicitly asked for" {
  run_mode check MK_OFFSITE_BACKUP_READ_DATA=true
  [ "$status" -eq 0 ]
  grep -q -- "^check --read-data$" "$RESTIC_ARGV"
}

@test "a failed check notifies and exits non-zero" {
  fake_restic 1
  run_mode check
  [ "$status" -ne 0 ]
  grep -q "repository check failed" "$NOTIFY_LOG"
}

@test "check backs nothing up" {
  run_mode check
  run ! grep -q "^backup" "$RESTIC_ARGV"
}

# --- probe ---

@test "probe succeeds and stays silent when the repository opens" {
  run_mode probe
  [ "$status" -eq 0 ]
  grep -q "^cat config$" "$RESTIC_ARGV"
  # The caller is asking a question, not reporting trouble — an absent repository
  # is the expected answer on a first apply, not something to notify about.
  [ ! -f "$NOTIFY_LOG" ]
}

@test "probe fails and stays silent when the repository does not open" {
  fake_restic 1
  run_mode probe
  [ "$status" -ne 0 ]
  [ ! -f "$NOTIFY_LOG" ]
}

# --- init ---

@test "init creates the repository" {
  run_mode init
  [ "$status" -eq 0 ]
  grep -q "^init$" "$RESTIC_ARGV"
}

@test "a failed init notifies and exits non-zero" {
  fake_restic 1
  run_mode init
  [ "$status" -ne 0 ]
  grep -q "could not be created" "$NOTIFY_LOG"
}

@test "init backs nothing up" {
  run_mode init
  run ! grep -q "^backup" "$RESTIC_ARGV"
}

# --- mode dispatch ---

@test "an unknown mode notifies and exits non-zero rather than guessing" {
  run_mode bogus
  [ "$status" -ne 0 ]
  grep -q "unknown mode" "$NOTIFY_LOG"
}
