#!/usr/bin/env bash
# syncthing — installs Syncthing and wires this machine into a peer-to-peer sync
# mesh. Deliberately generic: it syncs whatever folders and shares with whatever
# peers the blueprint declares ([module.syncthing]); it knows nothing about what
# lives in those folders. The agents-config use case is just one consumer.
#
# Device identity is a TLS-cert fingerprint generated on first run (not a secret).
# Topology is hub-and-spoke: mark one always-on machine `hub = true`. Clients list
# only the hub's (stable, well-known) device ID with `introducer = true` and learn
# every other client through it. The hub pre-lists nobody — it accepts the joiners
# that connect to it, discovering their IDs at connect time, so adding a machine
# never means transcribing device IDs into the hub's config. See docs/modules.md.
#
# Joining the mesh reaches the network, so it is consent-gated: interactive
# confirmation, or MACHINEKIT_SYNCTHING_JOIN=1 unattended. Without consent the
# daemon still installs, generates its identity, applies its discovery posture, and
# creates its folders locally — it just doesn't wire peers or share (idle alone).
# For a client, joining = adding the hub; for the hub, joining = accepting whoever
# has connected and is awaiting approval.
#
# Discovery posture is configurable via `discovery`, defaulting to `tailnet`: the
# daemon is hardened off every public/broadcast path (global + local announce,
# relays, NAT traversal), reaching peers only by their static addresses (typically
# tailnet MagicDNS). Set `discovery = "default"` to keep Syncthing's own discovery
# for LAN or relay topologies — the posture is a default, not a law.
#
# CLI seam: the thin `syncthing`/`syncthing cli` wrappers at the bottom encode the
# command surface, verified against syncthing 2.1.1 via VM QA (the 2.x CLI differs
# from 1.x — device-id is a subcommand, discovery options are kebab-named, a
# device's addresses are a list). The orchestration, config parsing, consent, and
# dry-run logic above them are unit-tested.

_SYNCTHING_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

syncthing::preflight() {
  local folders peers
  folders=$(syncthing::_folders)
  peers=$(syncthing::_peers)
  [ -n "$folders" ] && syncthing::_validate_folders "$folders"
  [ -n "$folders" ] && syncthing::_validate_ignores "$folders"
  [ -n "$peers" ] && syncthing::_validate_peers "$peers"
  # Validate the discovery posture now (called directly, so an unknown value's
  # lifecycle::fail isn't swallowed the way it would be in _apply_discovery's loop).
  syncthing::_discovery_options >/dev/null
  return 0
}

# Install the daemon, give it an identity, start it, then converge its config:
# apply the discovery posture, create folders, and (consent permitting) join.
syncthing::install() {
  logging::step "syncthing install"
  brew::install_formula syncthing

  if input::is_dry_run; then
    logging::dry_run "would generate identity, start the daemon, set the discovery posture, apply folders/peers, and install the conflict notifier"
    return 0
  fi

  syncthing::_ensure_identity
  syncthing::_start
  syncthing::_wait_ready
  syncthing::_apply_discovery

  local share_with=""
  if syncthing::_join_consented; then
    context::set "syncthing.joined" true
    share_with=$(syncthing::_join)
  else
    context::set "syncthing.joined" false
    logging::warn "syncthing: mesh join not consented; folders stay local. Set MACHINEKIT_SYNCTHING_JOIN=1 to join."
  fi
  syncthing::_ensure_folders "$share_with"
  syncthing::_install_conflict_notifier
}

# Each folder entry must carry an id (stable + identical across machines, so the
# same logical folder lines up) and a path. Fail loudly on a malformed entry
# rather than producing a half-configured mesh.
syncthing::_validate_folders() {
  local folders="$1" bad
  bad=$(printf '%s' "$folders" | jq -r '
    any(.[]; (has("id")|not) or (has("path")|not) or (.id == "") or (.path == ""))')
  [ "$bad" = "true" ] && lifecycle::fail \
    "syncthing: every [[module.syncthing.folders]] entry needs both an id and a path."
  return 0
}

# Each peer must carry the device_id machinekit shares with. address/name are
# optional (address defaults to dynamic discovery, which on a hardened tailnet
# daemon means the operator should set a tcp:// address).
syncthing::_validate_peers() {
  local peers="$1" bad
  bad=$(printf '%s' "$peers" | jq -r '
    any(.[]; (has("device_id")|not) or (.device_id == ""))')
  [ "$bad" = "true" ] && lifecycle::fail \
    "syncthing: every [[module.syncthing.peers]] entry needs a device_id."
  return 0
}

# Each folder's ignore config must be coherent: refusing to manage .stignore while
# still listing ignore_patterns is a contradiction; managing it with neither
# defaults nor patterns is a pointless empty block (warn, don't fail).
syncthing::_validate_ignores() {
  local folders="$1" folder id manage add_defaults pattern_count
  while IFS= read -r folder; do
    [ -n "$folder" ] || continue
    id=$(printf '%s' "$folder" | jq -r '.id // "?"')
    manage=$(printf '%s' "$folder" | jq -r 'if .manage_stignore == null then true else .manage_stignore end')
    add_defaults=$(printf '%s' "$folder" | jq -r 'if .add_default_ignores == null then true else .add_default_ignores end')
    pattern_count=$(printf '%s' "$folder" | jq -r '(.ignore_patterns // []) | length')
    if [ "$manage" != "true" ] && [ "$pattern_count" -gt 0 ]; then
      lifecycle::fail "syncthing: folder '$id' sets manage_stignore = false but lists ignore_patterns — drop one (machinekit can't both manage .stignore and leave it alone)."
    fi
    if [ "$manage" = "true" ] && [ "$add_defaults" != "true" ] && [ "$pattern_count" -eq 0 ]; then
      logging::warn "syncthing: folder '$id' manages .stignore with no defaults and no ignore_patterns — only an empty managed block will be written."
    fi
  done < <(printf '%s' "$folders" | jq -c '.[]')
  return 0
}

# Generate identity + default config only if this machine has none yet; never
# clobber an existing identity (it's this device's stable address in the mesh).
syncthing::_ensure_identity() {
  if syncthing::_identity_exists; then
    logging::debug "syncthing: identity already present"
    return 0
  fi
  syncthing::_generate
}

# postflight: the fact worth surfacing at the end rather than mid-install — the
# hub's device ID (the one piece every client must pin), or a client's mesh
# membership. A client's own ID is not surfaced: the hub discovers it on connect,
# so there is nothing to copy.
syncthing::postflight_info() {
  if syncthing::_is_hub; then
    printf 'Syncthing hub device ID: %s\n' "$(syncthing::_own_device_id)"
    return 0
  fi
  [ "$(syncthing::_joined)" = "true" ] || return 0
  printf 'Joined the Syncthing mesh via the hub.\n'
}

# postflight: the mesh step still on the operator — wire the hub's ID into each
# client, join an unjoined client, or approve a joined client on the hub.
syncthing::postflight_instructions() {
  if syncthing::_is_hub; then
    printf "Add this device ID to each client's [[module.syncthing.peers]] (introducer = true).\n"
    return 0
  fi
  if [ "$(syncthing::_joined)" = "true" ]; then
    printf 'Approve this device on the hub (it appears there as a pending device), or re-apply the hub.\n'
  else
    printf 'Re-apply with MACHINEKIT_SYNCTHING_JOIN=1 to join the mesh.\n'
  fi
}

# Create or update each configured folder, shared with the given device IDs
# (space-separated; empty = local-only). Idempotent: the underlying upsert keys
# on the folder id, so re-runs converge rather than duplicate.
syncthing::_ensure_folders() {
  local share_with="$1" folder folders
  folders=$(syncthing::_folders)
  [ -n "$folders" ] || return 0
  while IFS= read -r folder; do
    [ -n "$folder" ] || continue
    syncthing::_ensure_folder "$folder" "$share_with"
  done < <(printf '%s' "$folders" | jq -c '.[]')
}

# Create and register one folder: make its dir, reconcile its .stignore, and upsert
# it in the daemon shared with the given device IDs (space-separated; empty =
# local-only).
syncthing::_ensure_folder() {
  local folder="$1" share_with="$2" id path
  id=$(printf '%s' "$folder" | jq -r '.id')
  path=$(printf '%s' "$folder" | jq -r '.path')
  path=${path/#\~/$HOME}
  mkdir -p "$path"
  syncthing::_apply_stignore "$folder" "$path"
  syncthing::_cli_ensure_folder "$id" "$path" "$share_with"
  logging::success "syncthing: folder '$id' → $path"
}

# Reconcile the folder's .stignore from its ignore config. manage_stignore = false
# leaves the file entirely to the user; otherwise machinekit maintains its block
# (user patterns first, then the built-in defaults).
syncthing::_apply_stignore() {
  local folder="$1" path="$2"
  [ "$(printf '%s' "$folder" | jq -r 'if .manage_stignore == null then true else .manage_stignore end')" = "true" ] || return 0
  syncthing::_stignore_patterns "$folder" | managed_block::ensure "$path/.stignore" "//"
}

# Emit the folder's ordered, de-duplicated ignore lines: user ignore_patterns
# first (so a user negation wins .stignore's first-match precedence), then the
# defaults unless add_default_ignores is false.
syncthing::_stignore_patterns() {
  local folder="$1"
  {
    printf '%s' "$folder" | jq -r '.ignore_patterns[]? // empty'
    if [ "$(printf '%s' "$folder" | jq -r 'if .add_default_ignores == null then true else .add_default_ignores end')" = "true" ]; then
      syncthing::_default_ignores
    fi
  } | awk 'NF && !seen[$0]++'
}

# Junk that should never replicate. (?d) marks them deletable so they can't block a
# directory's removal. Not .stversions/ — Syncthing already excludes its own
# reserved dirs from sync.
syncthing::_default_ignores() {
  printf '%s\n' '(?d).DS_Store' '(?d)._*'
}

# Wire this machine into the mesh and echo the device IDs to share folders with
# (one per line). A client adds its declared peers (the hub); a hub additionally
# absorbs the clients awaiting approval. `return 0` pins success so the hub `&&`
# doesn't make a non-hub's _join trip the set -e caller.
syncthing::_join() {
  syncthing::_ensure_peers
  syncthing::_is_hub && syncthing::_accept_pending
  return 0
}

# Accept every device awaiting approval — a client that connected knowing our ID —
# adding each and echoing its ID to share folders with. This is how the hub learns
# client IDs: at connect time, not transcribed into its config.
syncthing::_accept_pending() {
  local device_id pending
  pending=$(syncthing::_cli_pending_devices)
  [ -n "$pending" ] || return 0
  while IFS= read -r device_id; do
    [ -n "$device_id" ] || continue
    syncthing::_cli_add_device "$device_id" "dynamic" "$device_id" "false" >&2
    printf '%s\n' "$device_id"
  done <<< "$pending"
}

# Add each configured peer device, returning their device IDs (one per line) so
# the folder pass can share with them. A client lists the hub here; a hub usually
# lists nobody (it accepts joiners instead). Reached only once join is consented.
syncthing::_ensure_peers() {
  local peer peers
  peers=$(syncthing::_peers)
  [ -n "$peers" ] || return 0
  while IFS= read -r peer; do
    [ -n "$peer" ] || continue
    syncthing::_ensure_peer "$peer"
  done < <(printf '%s' "$peers" | jq -c '.[]')
}

# Add one configured peer device, echoing its device ID (one line) so the folder
# pass can share with it. address/name/introducer default when the entry omits
# them. The CLI's own output goes to stderr so stdout carries only the device ID.
syncthing::_ensure_peer() {
  local peer="$1" device_id address name introducer
  device_id=$(printf '%s' "$peer" | jq -r '.device_id')
  address=$(printf '%s' "$peer" | jq -r '.address // "dynamic"')
  name=$(printf '%s' "$peer" | jq -r '.name // .device_id')
  introducer=$(printf '%s' "$peer" | jq -r '.introducer // false')
  syncthing::_cli_add_device "$device_id" "$address" "$name" "$introducer" >&2
  printf '%s\n' "$device_id"
}

# Apply the configured discovery posture. Capture the options first so a bad
# preset's lifecycle::fail propagates — a process substitution would run the loop
# in a subshell and swallow the exit.
syncthing::_apply_discovery() {
  local options option value
  options=$(syncthing::_discovery_options)
  while read -r option value; do
    [ -n "$option" ] || continue
    syncthing::_cli_set_option "$option" "$value"
  done <<< "$options"
}

syncthing::_join_consented() {
  local consent
  consent=$(context::get "syncthing.join" --default false --coerce boolean \
    --prompt "Join the Syncthing mesh now (add peers and share folders)? (y/n)")
  [ "$consent" = "true" ]
}

# Lay down the standing conflict-notifier service: a manifest of the configured
# folder paths, the standalone scan script, and the scheduled service that runs
# it. No folders = nothing that could ever conflict, so nothing to install.
syncthing::_install_conflict_notifier() {
  local folders
  folders=$(syncthing::_folders)
  [ -n "$folders" ] || return 0
  syncthing::_write_conflict_manifest "$folders"
  syncthing::_install_conflict_scan_script
  syncthing::_install_conflict_service
}

# Write each folder's expanded path, one per line — the plain list the scan
# script reads (folders carry no ssh_key/remote, so unlike git_backup's
# manifest there's no per-row branching worth its own helper).
syncthing::_write_conflict_manifest() {
  local folders="$1" manifest folder path
  manifest=$(syncthing::_conflict_manifest_path)
  mkdir -p "$(dirname "$manifest")"
  : > "$manifest"
  while IFS= read -r folder; do
    [ -n "$folder" ] || continue
    path=$(printf '%s' "$folder" | jq -r '.path')
    path=${path/#\~/$HOME}
    printf '%s\n' "$path" >> "$manifest"
  done < <(printf '%s' "$folders" | jq -c '.[]')
}

syncthing::_install_conflict_scan_script() {
  local dest
  dest=$(syncthing::_conflict_scan_script_path)
  mkdir -p "$(dirname "$dest")"
  cp "$_SYNCTHING_DIR/syncthing/conflict_scan.sh" "$dest"
  chmod 755 "$dest"
}

# Schedule the service that runs the scan script for every folder, pinning the
# manifest and notify command into its environment. The scan script is a
# self-contained executable, so service::install_interval runs it directly
# (its shebang picks the interpreter); the launchd/systemd split is service.sh's
# job.
syncthing::_install_conflict_service() {
  service::install_interval \
    syncthing-conflicts \
    "$(syncthing::_conflict_scan_script_path)" \
    "$(syncthing::_conflict_interval)" \
    "MK_SYNCTHING_CONFLICT_MANIFEST=$(syncthing::_conflict_manifest_path)" \
    "MK_SYNCTHING_CONFLICT_NOTIFY=$(syncthing::_conflict_notify)"
}

# --- config accessors ---

# Array-of-tables; `|| true` so an unset key is an empty result (no folders is a
# valid single-machine config), not a set -e failure.
syncthing::_folders() {
  config::get "module.syncthing.folders" || true
}

syncthing::_peers() {
  config::get "module.syncthing.peers" || true
}

# A hub absorbs joiners (accepts pending devices) instead of pre-listing them.
syncthing::_is_hub() {
  [ "$(config::get "module.syncthing.hub" --default false --coerce boolean)" = "true" ]
}

# Whether this machine joined the mesh on this apply. install records the consent
# outcome so postflight can report it without re-evaluating (and possibly
# re-prompting) consent.
syncthing::_joined() {
  context::get "syncthing.joined" --default false
}

# Discovery posture: `tailnet` (default) hardens off every public/broadcast path;
# `default` leaves Syncthing's own discovery in place.
syncthing::_discovery_preset() {
  config::get "module.syncthing.discovery" --default tailnet
}

# Emit "<option> <value>" lines to set for the configured posture. tailnet drops
# global + local announce, relays, and NAT so peers are reached only by static
# addresses; default emits nothing, leaving Syncthing's settings untouched.
syncthing::_discovery_options() {
  local preset
  preset=$(syncthing::_discovery_preset)
  case "$preset" in
    tailnet)
      printf '%s\n' \
        "global-ann-enabled false" \
        "local-ann-enabled false" \
        "relays-enabled false" \
        "natenabled false"
      ;;
    default) : ;;
    *) lifecycle::fail "syncthing: unknown discovery posture '$preset' (expected 'tailnet' or 'default')." ;;
  esac
}

# Optional notify command for the conflict scan; empty lets it fall back to
# logger/journald. Mirrors git_backup's own notify config.
syncthing::_conflict_notify() {
  config::get "module.syncthing.notify" --default ""
}

syncthing::_conflict_interval() {
  config::get "module.syncthing.interval" --default 300
}

# --- conflict notifier paths ---

syncthing::_conflict_manifest_path() {
  printf '%s\n' "${XDG_DATA_HOME:-$HOME/.local/share}/machinekit/syncthing/conflict_manifest.txt"
}

syncthing::_conflict_scan_script_path() {
  printf '%s\n' "${XDG_DATA_HOME:-$HOME/.local/share}/machinekit/syncthing/conflict_scan.sh"
}

# --- external command seam (syncthing 2.x surface; isolated for easy correction) ---

# True when this machine already has a generated identity/config.
syncthing::_identity_exists() {
  syncthing device-id >/dev/null 2>&1
}

syncthing::_generate() {
  syncthing generate
}

syncthing::_own_device_id() {
  syncthing device-id
}

# Device IDs awaiting approval (one per line): clients that connected knowing our
# ID but that we haven't added yet. The REST endpoint keys them by device ID.
syncthing::_cli_pending_devices() {
  syncthing cli show pending devices | jq -r 'keys[]?'
}

# Syncthing refuses to run as root, so it must be a user-level service (not the
# default root LaunchDaemon) — matching upstream's `brew services start syncthing`.
syncthing::_start() {
  brew::start_service syncthing user
}

# Block until the daemon answers the local CLI, so config calls don't race start.
# Announce the wait first — otherwise it reads as a hang while the daemon boots.
syncthing::_wait_ready() {
  local attempts=30 delay=1 waited=0
  logging::info "syncthing: waiting for the daemon to become ready (up to $(( attempts * delay ))s)..."
  while [ "$waited" -lt "$attempts" ]; do
    syncthing cli show system >/dev/null 2>&1 && return 0
    waited=$((waited + 1))
    sleep "$delay"
  done
  lifecycle::fail "syncthing: daemon did not become ready in time."
}

syncthing::_cli_set_option() {
  local key="$1" value="$2"
  syncthing cli config options "$key" set "$value"
}

# Upsert by folder id; shared with each device id in $3 (space-separated).
syncthing::_cli_ensure_folder() {
  local id="$1" path="$2" share_with="$3" device
  syncthing cli config folders add --id "$id" --path "$path" 2>/dev/null \
    || syncthing cli config folders "$id" path set "$path"
  for device in $share_with; do
    syncthing cli config folders "$id" devices add --device-id "$device"
  done
}

syncthing::_cli_add_device() {
  local device_id="$1" address="$2" name="$3" introducer="$4"
  syncthing cli config devices add --device-id "$device_id" --name "$name" 2>/dev/null || true
  syncthing::_cli_set_address "$device_id" "$address"
  syncthing cli config devices "$device_id" introducer set "$introducer"
}

# A device's addresses are a list (default ["dynamic"]) with no "set" verb, only
# list/add. "dynamic" is already the default, so leave it; for a static address,
# add it once — guarded by reading the current list (via dump-json) so re-applies
# don't pile up duplicates.
syncthing::_cli_set_address() {
  local device_id="$1" address="$2"
  [ -n "$address" ] && [ "$address" != "dynamic" ] || return 0
  if syncthing cli config devices "$device_id" dump-json \
      | jq -r '.addresses[]?' 2>/dev/null | grep -qxF "$address"; then
    return 0
  fi
  syncthing cli config devices "$device_id" addresses add "$address"
}
