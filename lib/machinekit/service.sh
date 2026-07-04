#!/usr/bin/env bash
# service — installs a long-lived scheduled service under the OS-native scheduler:
# a macOS system LaunchDaemon or a Linux user systemd timer. It owns the launchd
# vs systemd split so consumers (git_backup, and later periodic jobs) describe only
# *what* to run and *when*, never the per-OS unit mechanics.
#
# Two triggers, one shared install core: install_interval fires every N seconds
# monotonically (drifting with reboots — right for "every few minutes");
# install_calendar fires at wall-clock times (a full cron spec, catch-up enabled
# so a missed run fires after downtime — right for "Sunday at 03:00"). These are
# distinct scheduling models, not one primitive with a mode flag: `interval 300`
# fires 5 min after each run wherever the clock lands; `*/5 * * * *` fires at :00,
# :05, :10. The cron dialect is unrestricted — lists, ranges, and steps all work,
# enumerated to a launchd dict-array and to systemd comma-lists by one expander.
#
# Every service runs headless as the applying user and survives logout/reboot:
# macOS via a system LaunchDaemon with UserName (a user LaunchAgent wouldn't run
# without a GUI session); Linux via a user timer plus loginctl linger. That is a
# fixed per-OS decision, not a caller-visible scope.
#
# RUNTIME-UNVERIFIED: the launchd/systemd load commands encode the unit-loading
# path from docs, not a live run. The unit generators, schedule/env renderers, and
# cron translation are tested; loading is the VM seam.

# --- public: schedule a service ---

# Fire EXEC every SECONDS. EXEC is a single executable (shebang + executable bit);
# trailing KEY=VAL pairs become the service's environment.
service::install_interval() {
  local label="$1" exec="$2" seconds="$3"
  shift 3
  service::_install "$label" "$exec" interval "$seconds" "$@"
}

# Fire EXEC at the cron-style WHEN (`minute hour day month weekday`, single values
# or `*` only). Trailing KEY=VAL pairs become the service's environment.
service::install_calendar() {
  local label="$1" exec="$2" when="$3"
  shift 3
  service::_validate_cron "$when"
  service::_install "$label" "$exec" calendar "$when" "$@"
}

# --- install core + OS dispatch ---

service::_install() {
  local label="$1" exec="$2" kind="$3" value="$4"
  shift 4
  local family
  family=$(context::get os.family)
  case "$family" in
    darwin) service::_install_darwin "$label" "$exec" "$kind" "$value" "$@" ;;
    linux)  service::_install_linux "$label" "$exec" "$kind" "$value" "$@" ;;
    *) lifecycle::fail "service: unsupported os.family '$family' for a scheduled service" ;;
  esac
}

# Headless server → a system LaunchDaemon (loads at boot with no GUI session),
# which is why this needs sudo. The daemon is dropped to the applying user via
# UserName so the job operates on their files without tripping ownership guards.
service::_install_darwin() {
  local label="$1" exec="$2" kind="$3" value="$4"
  shift 4
  local launchd_label plist stanza env_dict user
  launchd_label=$(service::_launchd_label "$label")
  plist="/Library/LaunchDaemons/$launchd_label.plist"
  stanza=$(service::_launchd_schedule_stanza "$kind" "$value")
  env_dict=$(service::_launchd_env_dict "$@")
  user=$(service::_run_as_user)
  service::_plist_content "$launchd_label" "$exec" "$user" "$stanza" "$env_dict" \
    | sudo tee "$plist" >/dev/null
  sudo launchctl bootout system "$plist" 2>/dev/null || true
  sudo launchctl bootstrap system "$plist"
}

# Headless server → a user systemd timer plus linger (the service survives logout
# and reboot), the Linux equivalent of the LaunchDaemon.
service::_install_linux() {
  local label="$1" exec="$2" kind="$3" value="$4"
  shift 4
  local unit_name unit_dir description env_lines schedule_lines
  unit_name=$(service::_systemd_unit_name "$label")
  unit_dir="$HOME/.config/systemd/user"
  description="machinekit $label"
  mkdir -p "$unit_dir"
  env_lines=$(service::_systemd_env_lines "$@")
  schedule_lines=$(service::_systemd_schedule_lines "$kind" "$value")
  service::_systemd_service_content "$description" "$exec" "$env_lines" \
    > "$unit_dir/$unit_name.service"
  service::_systemd_timer_content "$description" "$schedule_lines" \
    > "$unit_dir/$unit_name.timer"
  sudo loginctl enable-linger "$(id -un)"
  systemctl --user daemon-reload
  systemctl --user enable --now "$unit_name.timer"
}

# --- unit content generators (pure) ---

service::_plist_content() {
  local launchd_label="$1" exec="$2" user="$3" schedule_stanza="$4" env_dict="$5"
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$launchd_label</string>
  <key>UserName</key><string>$user</string>
  <key>ProgramArguments</key>
  <array><string>$exec</string></array>
  <key>EnvironmentVariables</key>
  <dict>
$env_dict
  </dict>
$schedule_stanza
</dict>
</plist>
EOF
}

service::_systemd_service_content() {
  local description="$1" exec="$2" env_lines="$3"
  cat <<EOF
[Unit]
Description=$description

[Service]
Type=oneshot
$env_lines
ExecStart=$exec
EOF
}

service::_systemd_timer_content() {
  local description="$1" schedule_lines="$2"
  cat <<EOF
[Unit]
Description=$description timer

[Timer]
$schedule_lines

[Install]
WantedBy=timers.target
EOF
}

# --- schedule stanza renderers ---

# The launchd <dict>/<key> block selecting when the daemon fires.
service::_launchd_schedule_stanza() {
  local kind="$1" value="$2"
  case "$kind" in
    interval) printf '  <key>StartInterval</key><integer>%s</integer>\n' "$value" ;;
    calendar)
      printf '  <key>StartCalendarInterval</key>\n'
      service::_cron_to_launchd_calendar "$value"
      ;;
    *) lifecycle::fail "service: unknown schedule kind '$kind'" ;;
  esac
}

# The systemd [Timer] lines. Interval fires SECONDS after activation and every
# SECONDS thereafter (no run-at-boot). Calendar is persistent so a run missed
# during downtime fires on the next boot.
service::_systemd_schedule_lines() {
  local kind="$1" value="$2"
  case "$kind" in
    interval) printf 'OnActiveSec=%s\nOnUnitActiveSec=%s\n' "$value" "$value" ;;
    calendar) printf 'OnCalendar=%s\nPersistent=true\n' "$(service::_cron_to_systemd_oncalendar "$value")" ;;
    *) lifecycle::fail "service: unknown schedule kind '$kind'" ;;
  esac
}

# --- env renderers ---

service::_launchd_env_dict() {
  local pair
  for pair in "$@"; do
    printf '    <key>%s</key><string>%s</string>\n' "${pair%%=*}" "${pair#*=}"
  done
}

service::_systemd_env_lines() {
  local pair
  for pair in "$@"; do
    printf 'Environment=%s\n' "$pair"
  done
}

# --- cron translation ---
#
# One expander turns a cron field into its explicit value set; both renderers
# consume it. launchd StartCalendarInterval takes only single-valued dicts, so a
# multi-valued field enumerates to an array of dicts (the cartesian product across
# fields); systemd OnCalendar takes the same values as a comma-list. So the full
# cron dialect — lists, ranges, steps — renders faithfully to both.

# Expand one cron field to its sorted, unique value set (one integer per line), or
# the literal `*` for a wildcard. Handles comma lists of single values, ranges
# (a-b), and steps (*/n, a-b/n, a/n). Fails on malformed or out-of-range input.
service::_cron_field_values() {
  local field="$1" min="$2" max="$3"
  [ "$field" = "*" ] && { printf '*\n'; return 0; }
  local -a tokens values=()
  IFS=',' read -r -a tokens <<<"$field"
  local token base step has_step start end value
  for token in "${tokens[@]}"; do
    has_step=0
    step=1
    if [[ "$token" == */* ]]; then
      has_step=1
      step=${token##*/}
      base=${token%%/*}
    else
      base=$token
    fi
    if [ "$base" = "*" ]; then
      start=$min
      end=$max
    elif [[ "$base" == *-* ]]; then
      start=${base%%-*}
      end=${base##*-}
    else
      start=$base
      [ "$has_step" -eq 1 ] && end=$max || end=$base
    fi
    [[ "$start" =~ ^[0-9]+$ && "$end" =~ ^[0-9]+$ && "$step" =~ ^[0-9]+$ ]] || service::_cron_invalid "$field"
    start=$((10#$start)); end=$((10#$end)); step=$((10#$step))
    { [ "$step" -ge 1 ] && [ "$start" -ge "$min" ] && [ "$end" -le "$max" ] && [ "$start" -le "$end" ]; } \
      || service::_cron_invalid "$field"
    for (( value=start; value<=end; value+=step )); do
      values+=("$value")
    done
  done
  printf '%s\n' "${values[@]}" | sort -n -u
}

service::_cron_invalid() {
  lifecycle::fail "service: calendar field '$1' is not valid cron (single value, *, list a,b, range a-b, or step */n) or is out of range."
}

# launchd StartCalendarInterval: one <dict> per firing time. Non-wildcard fields
# enumerate to their values; the cartesian product across them is the set of dicts
# (a single dict when only one combination, an <array> when several).
service::_cron_to_launchd_calendar() {
  local when="$1" minute hour dom month dow
  read -r minute hour dom month dow <<<"$when"
  local -a combos=("")
  local spec key field range_min range_max
  for spec in "Minute:$minute:0:59" "Hour:$hour:0:23" "Day:$dom:1:31" "Month:$month:1:12" "Weekday:$dow:0:7"; do
    IFS=':' read -r key field range_min range_max <<<"$spec"
    [ "$field" = "*" ] && continue
    local -a values expanded=()
    mapfile -t values < <(service::_cron_field_values "$field" "$range_min" "$range_max")
    local combo value
    for combo in "${combos[@]}"; do
      for value in "${values[@]}"; do
        expanded+=("$combo    <key>$key</key><integer>$value</integer>"$'\n')
      done
    done
    combos=("${expanded[@]}")
  done
  if [ "${#combos[@]}" -eq 1 ]; then
    printf '  <dict>\n%s  </dict>\n' "${combos[0]}"
  else
    printf '  <array>\n'
    local combo
    for combo in "${combos[@]}"; do
      printf '  <dict>\n%s  </dict>\n' "$combo"
    done
    printf '  </array>\n'
  fi
}

# systemd OnCalendar: `[DOW] *-Month-Day Hour:Minute:00`, each component a
# comma-list (or `*`), weekdays mapped to names.
service::_cron_to_systemd_oncalendar() {
  local when="$1" minute hour dom month dow
  read -r minute hour dom month dow <<<"$when"
  local prefix=""
  [ "$dow" != "*" ] && prefix="$(service::_dow_names "$dow") "
  printf '%s*-%s-%s %s:%s:00\n' \
    "$prefix" \
    "$(service::_oncal_component "$month" 1 12)" \
    "$(service::_oncal_component "$dom" 1 31)" \
    "$(service::_oncal_component "$hour" 0 23)" \
    "$(service::_oncal_component "$minute" 0 59)"
}

# One OnCalendar component: `*` for a wildcard, else the field's values zero-padded
# and comma-joined.
service::_oncal_component() {
  local field="$1" min="$2" max="$3"
  [ "$field" = "*" ] && { printf '*'; return 0; }
  local -a values
  mapfile -t values < <(service::_cron_field_values "$field" "$min" "$max")
  local out="" value
  for value in "${values[@]}"; do
    out+="${out:+,}$(printf '%02d' "$value")"
  done
  printf '%s' "$out"
}

# The weekday field's values as systemd day names (Sun..Sat), de-duplicated;
# cron's 0 and 7 both mean Sunday.
service::_dow_names() {
  local field="$1"
  local -a names=(Sun Mon Tue Wed Thu Fri Sat) values
  mapfile -t values < <(service::_cron_field_values "$field" 0 7)
  local out="" value name
  for value in "${values[@]}"; do
    name=${names[$((value % 7))]}
    [[ ",$out," == *",$name,"* ]] && continue
    out+="${out:+,}$name"
  done
  printf '%s' "$out"
}

# Validate a full cron spec by expanding every field (which fails on malformed or
# out-of-range input); the five fields are minute hour day month weekday.
service::_validate_cron() {
  local when="$1"
  local -a fields
  read -r -a fields <<<"$when"
  [ "${#fields[@]}" -eq 5 ] || lifecycle::fail \
    "service: calendar spec '$when' must have 5 cron fields (minute hour day month weekday)."
  service::_cron_field_values "${fields[0]}" 0 59 >/dev/null
  service::_cron_field_values "${fields[1]}" 0 23 >/dev/null
  service::_cron_field_values "${fields[2]}" 1 31 >/dev/null
  service::_cron_field_values "${fields[3]}" 1 12 >/dev/null
  service::_cron_field_values "${fields[4]}" 0 7 >/dev/null
}

# --- identity / user ---

# Every machinekit service is namespaced: reverse-DNS for the launchd label,
# dashed for the systemd unit. Callers pass the bare label (e.g. git-backup).
service::_launchd_label() {
  printf 'com.machinekit.%s\n' "$1"
}

service::_systemd_unit_name() {
  printf 'machinekit-%s\n' "$1"
}

# The user the macOS LaunchDaemon runs as: loaded into the system domain (starts
# at boot with no GUI login) but executing as the file owner. SUDO_USER recovers
# the real user if apply was itself run under sudo.
service::_run_as_user() {
  printf '%s\n' "${SUDO_USER:-$(id -un)}"
}
