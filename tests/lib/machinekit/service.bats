#!/usr/bin/env bats
# Tests for lib/machinekit/service.sh — the OS-split scheduled-service installer.
# The launchd/systemd load is the runtime-unverified seam and is stubbed here;
# the unit-content generators, schedule/env renderers, and cron translation are
# pure and tested for real.

load "${BATS_TEST_DIRNAME}/../../test_helper"

setup() {
  # shellcheck source=../../../lib/machinekit/service.sh
  source "$MACHINEKIT_DIR/lib/machinekit/service.sh"
}

# --- install_interval ---

@test "install_interval installs the job on the interval kind for this OS" {
  mktest::stub_function service::_on_os install "svc" "/fake/exec" "interval" "300" "FOO=bar"
  service::install_interval "svc" "/fake/exec" "300" "FOO=bar"
  mktest::assert_stub_called service::_on_os install "svc" "/fake/exec" "interval" "300" "FOO=bar"
}

# --- install_calendar ---

@test "install_calendar validates the cron spec, then installs the calendar kind for this OS" {
  mktest::stub_function service::validate_cron "0 3 * * 0"
  mktest::stub_function service::_on_os install "svc" "/fake/exec" "calendar" "0 3 * * 0" "FOO=bar"
  service::install_calendar "svc" "/fake/exec" "0 3 * * 0" "FOO=bar"
  mktest::assert_stub_called_in_order service::validate_cron
  mktest::assert_stub_called_in_order service::_on_os install "svc" "/fake/exec" "calendar" "0 3 * * 0" "FOO=bar"
}

@test "install_calendar does not install when the cron spec is invalid" {
  # _validate_cron fails by exiting (lifecycle::fail), so install is skipped only
  # because the process is gone — not by a checked return. Model it as an exit.
  STUB_EXIT=1 mktest::stub_function service::validate_cron
  mktest::stub_function service::_on_os
  run service::install_calendar "svc" "/fake/exec" "bogus" "FOO=bar"
  [ "$status" -ne 0 ]
  mktest::assert_stub_not_called service::_on_os
}

# --- uninstall ---

@test "uninstall removes the service for this OS" {
  mktest::stub_function service::_on_os uninstall "svc"
  service::uninstall "svc"
  mktest::assert_stub_called service::_on_os uninstall "svc"
}

# --- installed_labels ---

@test "installed_labels lists the installed services for this OS" {
  STUB_OUTPUT=$'svc-one\nsvc-two' mktest::stub_function service::_on_os installed_labels
  run service::installed_labels
  [ "$output" = $'svc-one\nsvc-two' ]
}

# --- _on_os (OS dispatch) ---

@test "_on_os runs the darwin form of the operation on macOS" {
  STUB_OUTPUT="darwin" mktest::stub_function context::get "os.family"
  mktest::stub_function service::_install_darwin "svc" "/fake/exec" "interval" "300" "FOO=bar"
  mktest::stub_function service::_install_linux
  service::_on_os install "svc" "/fake/exec" "interval" "300" "FOO=bar"
  mktest::assert_stub_called service::_install_darwin "svc" "/fake/exec" "interval" "300" "FOO=bar"
  mktest::assert_stub_not_called service::_install_linux
}

@test "_on_os runs the linux form of the operation on Linux" {
  STUB_OUTPUT="linux" mktest::stub_function context::get "os.family"
  mktest::stub_function service::_uninstall_darwin
  mktest::stub_function service::_uninstall_linux "svc"
  service::_on_os uninstall "svc"
  mktest::assert_stub_called service::_uninstall_linux "svc"
  mktest::assert_stub_not_called service::_uninstall_darwin
}

@test "_on_os fails on an unsupported os.family" {
  STUB_OUTPUT="plan9" mktest::stub_function context::get "os.family"
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run service::_on_os install "svc" "/fake/exec" "interval" "300"
  [ "$status" -ne 0 ]
  MATCH="os.family" mktest::assert_stub_called lifecycle::fail
}

@test "_on_os stops when reading the os family fails" {
  STUB_EXIT=97 mktest::stub_function context::get "os.family"
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  mktest::stub_function service::_install_darwin
  mktest::stub_function service::_install_linux
  run service::_on_os install "svc" "/fake/exec" "interval" "300"
  [ "$status" -eq 97 ]
}

# --- _install_darwin ---

@test "_install_darwin writes the system LaunchDaemon, threading the resolved parts, and reloads it" {
  STUB_OUTPUT="/fake/daemons" mktest::stub_function service::_launchd_daemons_dir
  STUB_OUTPUT="com.machinekit.svc" mktest::stub_function service::_launchd_label "svc"
  STUB_OUTPUT="STANZA" mktest::stub_function service::_launchd_schedule_stanza "somekind" "someval"
  STUB_OUTPUT="ENVDICT" mktest::stub_function service::_launchd_env_dict "FOO=bar"
  STUB_OUTPUT="alice" mktest::stub_function service::_run_as_user
  # Exact-arg stub: only matches if every resolved part lands in its slot.
  mktest::stub_function service::_plist_content "com.machinekit.svc" "/fake/exec" "alice" "STANZA" "ENVDICT"
  mktest::stub_function sudo
  service::_install_darwin "svc" "/fake/exec" "somekind" "someval" "FOO=bar"
  local plist="/fake/daemons/com.machinekit.svc.plist"
  mktest::assert_stub_called service::_plist_content "com.machinekit.svc" "/fake/exec" "alice" "STANZA" "ENVDICT"
  mktest::assert_stub_called sudo "tee" "$plist"
  mktest::assert_stub_called sudo "launchctl" "bootout" "system" "$plist"
  mktest::assert_stub_called sudo "launchctl" "bootstrap" "system" "$plist"
}

@test "_install_darwin stops when rendering the schedule fails" {
  STUB_OUTPUT="/fake/daemons" mktest::stub_function service::_launchd_daemons_dir
  STUB_OUTPUT="com.machinekit.svc" mktest::stub_function service::_launchd_label "svc"
  STUB_EXIT=97 mktest::stub_function service::_launchd_schedule_stanza "somekind" "someval"
  mktest::stub_function service::_launchd_env_dict
  mktest::stub_function service::_run_as_user
  mktest::stub_function service::_plist_content
  mktest::stub_function sudo
  run service::_install_darwin "svc" "/fake/exec" "somekind" "someval"
  [ "$status" -eq 97 ]
}

# --- _install_linux ---

@test "_install_linux writes the user units, threading the resolved parts, and enables the timer with linger" {
  local unit_dir="$BATS_TEST_TMPDIR/units"
  STUB_OUTPUT="$unit_dir" mktest::stub_function service::_systemd_user_unit_dir
  STUB_OUTPUT="machinekit-svc" mktest::stub_function service::_systemd_unit_name "svc"
  STUB_OUTPUT="ENVLINES" mktest::stub_function service::_systemd_env_lines "FOO=bar"
  STUB_OUTPUT="SCHEDLINES" mktest::stub_function service::_systemd_schedule_lines "somekind" "someval"
  STUB_OUTPUT="SERVICE" mktest::stub_function service::_systemd_service_content "machinekit svc" "/fake/exec" "ENVLINES"
  STUB_OUTPUT="TIMER" mktest::stub_function service::_systemd_timer_content "machinekit svc" "SCHEDLINES"
  mktest::stub_function sudo
  mktest::stub_function systemctl
  service::_install_linux "svc" "/fake/exec" "somekind" "someval" "FOO=bar"
  [ "$(cat "$unit_dir/machinekit-svc.service")" = "SERVICE" ]
  [ "$(cat "$unit_dir/machinekit-svc.timer")" = "TIMER" ]
  MATCH="enable-linger" mktest::assert_stub_called sudo
  mktest::assert_stub_called systemctl "--user" "daemon-reload"
  mktest::assert_stub_called systemctl "--user" "enable" "--now" "machinekit-svc.timer"
}

@test "_install_linux stops when rendering the schedule fails" {
  STUB_OUTPUT="$BATS_TEST_TMPDIR/units" mktest::stub_function service::_systemd_user_unit_dir
  STUB_OUTPUT="machinekit-svc" mktest::stub_function service::_systemd_unit_name "svc"
  mktest::stub_function service::_systemd_env_lines
  STUB_EXIT=97 mktest::stub_function service::_systemd_schedule_lines "somekind" "someval"
  mktest::stub_function service::_systemd_service_content
  mktest::stub_function service::_systemd_timer_content
  mktest::stub_function sudo
  mktest::stub_function systemctl
  run service::_install_linux "svc" "/fake/exec" "somekind" "someval"
  [ "$status" -eq 97 ]
}

# --- _uninstall_darwin ---

@test "_uninstall_darwin unloads the LaunchDaemon and deletes its plist" {
  STUB_OUTPUT="/fake/daemons" mktest::stub_function service::_launchd_daemons_dir
  STUB_OUTPUT="com.machinekit.svc" mktest::stub_function service::_launchd_label "svc"
  mktest::stub_function sudo
  service::_uninstall_darwin "svc"
  local plist="/fake/daemons/com.machinekit.svc.plist"
  mktest::assert_stub_called_in_order sudo "launchctl" "bootout" "system" "$plist"
  mktest::assert_stub_called_in_order sudo "rm" "-f" "--" "$plist"
}

@test "_uninstall_darwin still deletes the plist when the daemon was not loaded" {
  STUB_OUTPUT="/fake/daemons" mktest::stub_function service::_launchd_daemons_dir
  STUB_OUTPUT="com.machinekit.svc" mktest::stub_function service::_launchd_label "svc"
  local plist="/fake/daemons/com.machinekit.svc.plist"
  STUB_RETURN=5 mktest::stub_function sudo "launchctl" "bootout" "system" "$plist"
  mktest::stub_function sudo "rm" "-f" "--" "$plist"
  service::_uninstall_darwin "svc"
  mktest::assert_stub_called sudo "rm" "-f" "--" "$plist"
}

# --- _uninstall_linux ---

@test "_uninstall_linux stops the timer and service, deletes both units, and reloads" {
  local unit_dir="$BATS_TEST_TMPDIR/units"
  mkdir -p "$unit_dir"
  : > "$unit_dir/machinekit-svc.service"
  : > "$unit_dir/machinekit-svc.timer"
  : > "$unit_dir/machinekit-other.timer"
  STUB_OUTPUT="$unit_dir" mktest::stub_function service::_systemd_user_unit_dir
  STUB_OUTPUT="machinekit-svc" mktest::stub_function service::_systemd_unit_name "svc"
  mktest::stub_function systemctl
  service::_uninstall_linux "svc"
  mktest::assert_stub_called_in_order systemctl "--user" "disable" "--now" "machinekit-svc.timer"
  mktest::assert_stub_called_in_order systemctl "--user" "stop" "machinekit-svc.service"
  mktest::assert_stub_called_in_order systemctl "--user" "daemon-reload"
  [ ! -e "$unit_dir/machinekit-svc.service" ]
  [ ! -e "$unit_dir/machinekit-svc.timer" ]
  [ -e "$unit_dir/machinekit-other.timer" ]
}

@test "_uninstall_linux still deletes the units when the timer was not enabled" {
  local unit_dir="$BATS_TEST_TMPDIR/units"
  mkdir -p "$unit_dir"
  : > "$unit_dir/machinekit-svc.timer"
  STUB_OUTPUT="$unit_dir" mktest::stub_function service::_systemd_user_unit_dir
  STUB_OUTPUT="machinekit-svc" mktest::stub_function service::_systemd_unit_name "svc"
  STUB_RETURN=5 mktest::stub_function systemctl "--user" "disable" "--now" "machinekit-svc.timer"
  STUB_RETURN=5 mktest::stub_function systemctl "--user" "stop" "machinekit-svc.service"
  mktest::stub_function systemctl "--user" "daemon-reload"
  service::_uninstall_linux "svc"
  [ ! -e "$unit_dir/machinekit-svc.timer" ]
}

# --- _installed_labels_darwin ---

@test "_installed_labels_darwin lists the label of each machinekit LaunchDaemon" {
  local daemons_dir="$BATS_TEST_TMPDIR/daemons"
  mkdir -p "$daemons_dir"
  : > "$daemons_dir/com.machinekit.svc-one.plist"
  : > "$daemons_dir/com.machinekit.svc-two.plist"
  : > "$daemons_dir/com.example.other.plist"
  STUB_OUTPUT="$daemons_dir" mktest::stub_function service::_launchd_daemons_dir
  STUB_OUTPUT="com.machinekit." mktest::stub_function service::_launchd_label ""
  run service::_installed_labels_darwin
  [ "$status" -eq 0 ]
  [ "$output" = $'svc-one\nsvc-two' ]
}

@test "_installed_labels_darwin lists nothing when no machinekit LaunchDaemon exists" {
  STUB_OUTPUT="$BATS_TEST_TMPDIR/empty" mktest::stub_function service::_launchd_daemons_dir
  STUB_OUTPUT="com.machinekit." mktest::stub_function service::_launchd_label ""
  run service::_installed_labels_darwin
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- _installed_labels_linux ---

@test "_installed_labels_linux lists the label of each machinekit timer" {
  local unit_dir="$BATS_TEST_TMPDIR/units"
  mkdir -p "$unit_dir"
  : > "$unit_dir/machinekit-svc-one.timer"
  : > "$unit_dir/machinekit-svc-one.service"
  : > "$unit_dir/machinekit-svc-two.timer"
  : > "$unit_dir/other.timer"
  STUB_OUTPUT="$unit_dir" mktest::stub_function service::_systemd_user_unit_dir
  STUB_OUTPUT="machinekit-" mktest::stub_function service::_systemd_unit_name ""
  run service::_installed_labels_linux
  [ "$status" -eq 0 ]
  [ "$output" = $'svc-one\nsvc-two' ]
}

@test "_installed_labels_linux lists nothing when no machinekit timer exists" {
  STUB_OUTPUT="$BATS_TEST_TMPDIR/empty" mktest::stub_function service::_systemd_user_unit_dir
  STUB_OUTPUT="machinekit-" mktest::stub_function service::_systemd_unit_name ""
  run service::_installed_labels_linux
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- unit content generators (pure) ---

@test "_plist_content embeds the label, exec, run-as user, schedule stanza, and env dict" {
  run service::_plist_content "com.machinekit.svc" "/fake/exec" "alice" "SCHEDULE_STANZA" "ENV_DICT"
  [[ "$output" == *"<key>Label</key><string>com.machinekit.svc</string>"* ]]
  [[ "$output" == *"<array><string>/fake/exec</string></array>"* ]]
  [[ "$output" == *"<key>UserName</key><string>alice</string>"* ]]
  [[ "$output" == *"SCHEDULE_STANZA"* ]]
  [[ "$output" == *"ENV_DICT"* ]]
}

@test "_systemd_service_content is a oneshot embedding the description, env lines, and ExecStart" {
  run service::_systemd_service_content "machinekit svc" "/fake/exec" "ENV_LINES"
  [[ "$output" == *"Description=machinekit svc"* ]]
  [[ "$output" == *"Type=oneshot"* ]]
  [[ "$output" == *"ENV_LINES"* ]]
  [[ "$output" == *"ExecStart=/fake/exec"* ]]
}

@test "_systemd_timer_content embeds the description and schedule lines and installs to timers.target" {
  run service::_systemd_timer_content "machinekit svc" "SCHEDULE_LINES"
  [[ "$output" == *"machinekit svc"* ]]
  [[ "$output" == *"SCHEDULE_LINES"* ]]
  [[ "$output" == *"WantedBy=timers.target"* ]]
}

# --- schedule stanza renderers ---

@test "_launchd_schedule_stanza renders an interval as StartInterval" {
  run service::_launchd_schedule_stanza "interval" "300"
  [[ "$output" == *"<key>StartInterval</key><integer>300</integer>"* ]]
}

@test "_launchd_schedule_stanza renders a calendar spec as StartCalendarInterval over the cron dict" {
  STUB_OUTPUT="CRON_DICT" mktest::stub_function service::_cron_to_launchd_calendar "0 3 * * 0"
  run service::_launchd_schedule_stanza "calendar" "0 3 * * 0"
  [[ "$output" == *"<key>StartCalendarInterval</key>"* ]]
  [[ "$output" == *"CRON_DICT"* ]]
}

@test "_systemd_schedule_lines renders an interval as OnActiveSec plus OnUnitActiveSec" {
  run service::_systemd_schedule_lines "interval" "300"
  [[ "$output" == *"OnActiveSec=300"* ]]
  [[ "$output" == *"OnUnitActiveSec=300"* ]]
}

@test "_systemd_schedule_lines renders a calendar spec as a persistent OnCalendar" {
  STUB_OUTPUT="Sun *-*-* 03:00:00" mktest::stub_function service::_cron_to_systemd_oncalendar "0 3 * * 0"
  run service::_systemd_schedule_lines "calendar" "0 3 * * 0"
  [[ "$output" == *"OnCalendar=Sun *-*-* 03:00:00"* ]]
  [[ "$output" == *"Persistent=true"* ]]
}

@test "_systemd_schedule_lines stops when translating the calendar spec fails" {
  STUB_EXIT=97 mktest::stub_function service::_cron_to_systemd_oncalendar "fake spec"
  run service::_systemd_schedule_lines "calendar" "fake spec"
  [ "$status" -eq 97 ]
}

# --- env renderers ---

@test "_launchd_env_dict renders each pair as a key/string entry" {
  run service::_launchd_env_dict "FOO=bar" "BAZ=qux"
  [[ "$output" == *"<key>FOO</key><string>bar</string>"* ]]
  [[ "$output" == *"<key>BAZ</key><string>qux</string>"* ]]
}

@test "_launchd_env_dict is empty when no pairs are given" {
  run service::_launchd_env_dict
  [ -z "$output" ]
}

@test "_systemd_env_lines renders each pair as an Environment line" {
  run service::_systemd_env_lines "FOO=bar" "BAZ=qux"
  [[ "$output" == *"Environment=FOO=bar"* ]]
  [[ "$output" == *"Environment=BAZ=qux"* ]]
}

@test "_systemd_env_lines is empty when no pairs are given" {
  run service::_systemd_env_lines
  [ -z "$output" ]
}

# --- cron field expansion ---

@test "_cron_field_values returns the wildcard sentinel for '*'" {
  run service::_cron_field_values "*" 0 59
  [ "$output" = "*" ]
}

@test "_cron_field_values returns a single value" {
  run service::_cron_field_values "15" 0 59
  [ "$output" = "15" ]
}

@test "_cron_field_values expands a comma list, sorted and de-duplicated" {
  run service::_cron_field_values "45,15,15" 0 59
  [ "$output" = "15
45" ]
}

@test "_cron_field_values expands a range" {
  run service::_cron_field_values "1-5" 0 23
  [ "$output" = "1
2
3
4
5" ]
}

@test "_cron_field_values expands a step over the wildcard" {
  run service::_cron_field_values "*/15" 0 59
  [ "$output" = "0
15
30
45" ]
}

@test "_cron_field_values expands a step over a range" {
  run service::_cron_field_values "0-30/10" 0 59
  [ "$output" = "0
10
20
30" ]
}

@test "_cron_field_values delegates an out-of-range value to _cron_invalid" {
  STUB_EXIT=1 mktest::stub_function service::_cron_invalid "70"
  run service::_cron_field_values "70" 0 59
  [ "$status" -ne 0 ]
  mktest::assert_stub_called service::_cron_invalid "70"
}

@test "_cron_field_values delegates non-numeric garbage to _cron_invalid" {
  STUB_EXIT=1 mktest::stub_function service::_cron_invalid "abc"
  run service::_cron_field_values "abc" 0 59
  [ "$status" -ne 0 ]
  mktest::assert_stub_called service::_cron_invalid "abc"
}

# --- _cron_invalid ---

@test "_cron_invalid fails via lifecycle::fail, naming the offending field" {
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run service::_cron_invalid "bogus"
  [ "$status" -ne 0 ]
  MATCH="bogus" mktest::assert_stub_called lifecycle::fail
}

# --- _cron_to_launchd_calendar (its own logic: wildcard-skip, cartesian, dict/array) ---

@test "_cron_to_launchd_calendar renders a single expanded value as one dict" {
  STUB_OUTPUT="7" mktest::stub_function service::_cron_field_values "5" 0 59
  run service::_cron_to_launchd_calendar "5 * * * *"
  [[ "$output" == *"<key>Minute</key><integer>7</integer>"* ]]
  [[ "$output" != *"<array>"* ]]
}

@test "_cron_to_launchd_calendar enumerates multiple expanded values into an array of dicts" {
  STUB_OUTPUT=$'7\n8' mktest::stub_function service::_cron_field_values "5" 0 59
  run service::_cron_to_launchd_calendar "5 * * * *"
  [[ "$output" == *"<array>"* ]]
  [[ "$output" == *"<key>Minute</key><integer>7</integer>"* ]]
  [[ "$output" == *"<key>Minute</key><integer>8</integer>"* ]]
}

@test "_cron_to_launchd_calendar cartesian-products the non-wildcard fields" {
  STUB_OUTPUT=$'7\n8' mktest::stub_function service::_cron_field_values "5" 0 59
  STUB_OUTPUT=$'1\n2' mktest::stub_function service::_cron_field_values "9" 0 23
  run service::_cron_to_launchd_calendar "5 9 * * *"
  [[ "$output" == *"<array>"* ]]
  [ "$(grep -c '<dict>' <<<"$output")" -eq 4 ]          # 2 minutes × 2 hours
  # Each (minute, hour) pairing is its own dict — a product, not a zip.
  local flat; flat="$(tr -d ' \n' <<<"$output")"
  for m in 7 8; do for h in 1 2; do
    [[ "$flat" == *"<dict><key>Minute</key><integer>$m</integer><key>Hour</key><integer>$h</integer></dict>"* ]] \
      || { echo "missing pairing Minute=$m Hour=$h"; return 1; }
  done; done
}

@test "_cron_to_launchd_calendar skips wildcard fields, emitting a single empty dict" {
  mktest::stub_function service::_cron_field_values
  run service::_cron_to_launchd_calendar "* * * * *"
  [[ "$output" == *"<dict>"* ]]
  [[ "$output" != *"<array>"* ]]
  [[ "$output" != *"<integer>"* ]]
  mktest::assert_stub_not_called service::_cron_field_values
}

@test "_cron_to_launchd_calendar stops when expanding a field fails" {
  STUB_EXIT=97 mktest::stub_function service::_cron_field_values "5" 0 59
  run service::_cron_to_launchd_calendar "5 * * * *"
  [ "$status" -eq 97 ]
}

# --- _cron_to_systemd_oncalendar (its own logic: compose the OnCalendar shape) ---

@test "_cron_to_systemd_oncalendar composes weekday, date, and time from its helpers" {
  STUB_OUTPUT="DOW" mktest::stub_function service::_dow_names "5"
  STUB_OUTPUT="MON" mktest::stub_function service::_oncal_component "4" 1 12
  STUB_OUTPUT="DAY" mktest::stub_function service::_oncal_component "3" 1 31
  STUB_OUTPUT="HR"  mktest::stub_function service::_oncal_component "2" 0 23
  STUB_OUTPUT="MIN" mktest::stub_function service::_oncal_component "1" 0 59
  run service::_cron_to_systemd_oncalendar "1 2 3 4 5"
  [ "$output" = "DOW *-MON-DAY HR:MIN:00" ]
}

@test "_cron_to_systemd_oncalendar omits the weekday prefix when the weekday is a wildcard" {
  mktest::stub_function service::_dow_names
  STUB_OUTPUT="MON" mktest::stub_function service::_oncal_component "4" 1 12
  STUB_OUTPUT="DAY" mktest::stub_function service::_oncal_component "3" 1 31
  STUB_OUTPUT="HR"  mktest::stub_function service::_oncal_component "2" 0 23
  STUB_OUTPUT="MIN" mktest::stub_function service::_oncal_component "1" 0 59
  run service::_cron_to_systemd_oncalendar "1 2 3 4 *"
  [ "$output" = "*-MON-DAY HR:MIN:00" ]
  mktest::assert_stub_not_called service::_dow_names
}

@test "_cron_to_systemd_oncalendar stops when naming the weekdays fails" {
  STUB_EXIT=97 mktest::stub_function service::_dow_names "5"
  mktest::stub_function service::_oncal_component
  run service::_cron_to_systemd_oncalendar "1 2 3 4 5"
  [ "$status" -eq 97 ]
}

@test "_cron_to_systemd_oncalendar stops when rendering a component fails" {
  STUB_EXIT=97 mktest::stub_function service::_oncal_component "4" 1 12
  mktest::stub_function service::_oncal_component
  run service::_cron_to_systemd_oncalendar "1 2 3 4 *"
  [ "$status" -eq 97 ]
}

# --- _oncal_component ---

@test "_oncal_component passes a wildcard through without expanding" {
  mktest::stub_function service::_cron_field_values
  run service::_oncal_component "*" 0 59
  [ "$output" = "*" ]
  mktest::assert_stub_not_called service::_cron_field_values
}

@test "_oncal_component zero-pads and comma-joins the expanded values" {
  STUB_OUTPUT=$'5\n30' mktest::stub_function service::_cron_field_values "some.field" 0 59
  run service::_oncal_component "some.field" 0 59
  [ "$output" = "05,30" ]
}

@test "_oncal_component stops when expanding the field fails" {
  STUB_EXIT=97 mktest::stub_function service::_cron_field_values "some.field" 0 59
  run service::_oncal_component "some.field" 0 59
  [ "$status" -eq 97 ]
}

# --- _dow_names ---

@test "_dow_names maps the expanded weekday numbers to systemd day names" {
  STUB_OUTPUT=$'1\n3\n5' mktest::stub_function service::_cron_field_values "some.dow" 0 7
  run service::_dow_names "some.dow"
  [ "$output" = "Mon,Wed,Fri" ]
}

@test "_dow_names collapses 0 and 7 (both Sunday) to a single name" {
  STUB_OUTPUT=$'0\n7' mktest::stub_function service::_cron_field_values "some.dow" 0 7
  run service::_dow_names "some.dow"
  [ "$output" = "Sun" ]
}

@test "_dow_names stops when expanding the field fails" {
  STUB_EXIT=97 mktest::stub_function service::_cron_field_values "some.dow" 0 7
  run service::_dow_names "some.dow"
  [ "$status" -eq 97 ]
}

# --- _validate_cron ---

@test "_validate_cron expands every field (in its range) to validate it" {
  mktest::stub_function service::_cron_field_values "0" 0 59
  mktest::stub_function service::_cron_field_values "3" 0 23
  mktest::stub_function service::_cron_field_values "*" 1 31
  mktest::stub_function service::_cron_field_values "*" 1 12
  mktest::stub_function service::_cron_field_values "0" 0 7
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  service::validate_cron "0 3 * * 0"
  mktest::assert_stub_called service::_cron_field_values "0" 0 59
  mktest::assert_stub_called service::_cron_field_values "3" 0 23
  mktest::assert_stub_called service::_cron_field_values "*" 1 31
  mktest::assert_stub_called service::_cron_field_values "*" 1 12
  mktest::assert_stub_called service::_cron_field_values "0" 0 7
  mktest::assert_stub_not_called lifecycle::fail
}

@test "_validate_cron fails when the field count is wrong" {
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run service::validate_cron "0 3 * *"
  MATCH="5 cron fields" mktest::assert_stub_called lifecycle::fail
}

@test "_validate_cron fails on an out-of-range field" {
  STUB_EXIT=1 mktest::stub_function lifecycle::fail
  run service::validate_cron "0 25 * * *"
  MATCH="cron" mktest::assert_stub_called lifecycle::fail
}

# --- identity / path helpers ---

@test "_launchd_label namespaces the label under com.machinekit" {
  run service::_launchd_label "the-service-name"
  [ "$output" = "com.machinekit.the-service-name" ]
}

@test "_systemd_unit_name namespaces the label under machinekit-" {
  run service::_systemd_unit_name "the-service-name"
  [ "$output" = "machinekit-the-service-name" ]
}

@test "_launchd_daemons_dir is the system LaunchDaemons dir" {
  run service::_launchd_daemons_dir
  [ "$output" = "/Library/LaunchDaemons" ]
}

@test "_systemd_user_unit_dir is the user unit dir under HOME" {
  HOME="/fake/home" run service::_systemd_user_unit_dir
  [ "$output" = "/fake/home/.config/systemd/user" ]
}

@test "_run_as_user prefers SUDO_USER (the real user behind a sudo'd apply)" {
  SUDO_USER="alice" run service::_run_as_user
  [ "$output" = "alice" ]
}

@test "_run_as_user falls back to the current user when SUDO_USER is unset" {
  unset SUDO_USER
  run service::_run_as_user
  [ "$output" = "$(id -un)" ]
}
