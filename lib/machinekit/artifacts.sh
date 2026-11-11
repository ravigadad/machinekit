#!/usr/bin/env bash
# artifacts — removes what machinekit installed that the config no longer asks
# for: an entry turned off or deleted, or its whole module dropped.
#
# Each module that installs services or files declares them, without changing
# anything (so preflight and a dry run can ask), through
# <module>::installed_artifacts: one `kind<TAB>name` line each. `service`
# and `file` are the framework's kinds; any other kind is the module's own, and
# the module removes it with <module>::remove_artifact KIND NAME. Every apply
# records the declared set, so the next one can tell what has since dropped out.
# With no record to compare against, an installed item is found by its machinekit
# name instead.
#
# Removal is consent-gated, and only ever touches services, machinekit's own files
# and what a module's remove_artifact owns, never data.
[ -n "${_MK_ARTIFACTS_LOADED:-}" ] && return 0
_MK_ARTIFACTS_LOADED=1

_ARTIFACTS_REMOVAL_PROMPT="Remove the installed items listed above that are no longer configured? (y/n)"

# Work out, before anything changes, what is installed but no longer configured,
# and list it. remove_stale acts on the result after the installs.
artifacts::plan() {
  local declared recorded leftovers stale
  declared=${ artifacts::_declared; }
  recorded=${ artifacts::_recorded; }
  leftovers=${ artifacts::_leftovers; }
  stale=${ artifacts::_stale "$declared" "$recorded" "$leftovers"; }
  context::set "artifacts.declared" "$declared" --json
  context::set "artifacts.stale" "$stale" --json
  artifacts::_report_stale "$stale"
}

# Remove what plan found stale, once consented, then record what this apply
# declared. An item that was declined or failed to go stays in the record, so the
# next apply offers it again.
artifacts::remove_stale() {
  local stale declared kept
  stale=${ context::get_json "artifacts.stale"; }
  declared=${ context::get_json "artifacts.declared"; }
  if input::is_dry_run; then
    [ "$stale" = "[]" ] || logging::dry_run "would offer to remove the items listed in preflight as no longer configured"
    return 0
  fi
  if [ "$stale" = "[]" ]; then
    artifacts::_write_record "$declared"
    return 0
  fi
  if artifacts::_removal_consented; then
    kept=${ artifacts::_remove_each "$stale"; }
  else
    logging::warn "kept the installed items that are no longer configured. Re-apply with --remove-unconfigured (or MACHINEKIT_REMOVE_UNCONFIGURED=1) to remove them."
    kept=$stale
  fi
  artifacts::_write_record "${ artifacts::_union "$declared" "$kept"; }"
}

# Where a module keeps the files it installs.
artifacts::module_data_dir() {
  printf '%s/%s\n' "${ artifacts::_data_dir; }" "$1"
}

artifacts::module_config_dir() {
  printf '%s/%s\n' "${ artifacts::_config_dir; }" "$1"
}

# State rather than data: losing it only means the next apply has nothing to
# compare against, and so removes nothing it can't find by name.
artifacts::record_path() {
  printf '%s\n' "${XDG_STATE_HOME:-$HOME/.local/state}/machinekit/installed.json"
}

# --- what the config installs, what was recorded, and what was left behind ---

# bash turns -e off inside a capture, so a command failing partway through a
# declaration would leave it short, and plan would offer the rest of that module's
# live installs for removal. The set -e stops the run instead.
artifacts::_declared() {
  local defining_modules mod declarations line lines=""
  defining_modules=${ modules::active_defining installed_artifacts; }
  while IFS= read -r mod; do
    [ -n "$mod" ] || continue
    declarations=${ set -e; "${mod}::installed_artifacts"; }
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      lines+="$mod"$'\t'"$line"$'\n'
    done <<< "$declarations"
  done <<< "$defining_modules"
  artifacts::_items_json "${lines%$'\n'}"
}

# Lines of `module<TAB>kind<TAB>name` as a JSON list of items.
artifacts::_items_json() {
  jq -Rnc '[inputs | select(length > 0) | split("\t") | {module: .[0], kind: .[1], name: .[2]}]' <<< "$1"
}

artifacts::_recorded() {
  local record
  record=${ artifacts::record_path; }
  if [ ! -f "$record" ]; then
    printf '[]\n'
    return 0
  fi
  jq -ce 'if type == "array" and all(.[]; type == "object") then . else error end' "$record" 2>/dev/null \
    || lifecycle::fail "artifacts: $record is not a list of installed items. Delete it to start a new record; until then, an apply finds what machinekit installed only by its machinekit name."
}

artifacts::_leftovers() {
  local services files
  services=${ artifacts::_leftover_services; }
  files=${ artifacts::_leftover_files; }
  artifacts::_union "$services" "$files"
}

# A service's unit names no module, so a leftover one carries none.
artifacts::_leftover_services() {
  local labels label lines=""
  labels=${ service::installed_labels; }
  while IFS= read -r label; do
    [ -n "$label" ] || continue
    lines+=$'\t'"service"$'\t'"$label"$'\n'
  done <<< "$labels"
  artifacts::_items_json "${lines%$'\n'}"
}

# Only files whose names match what a module installs, in that module's own dirs.
# Anything else there, such as data a user pointed a module at, is never offered.
# Each <module>::installed_file_patterns line is `data|config<TAB>glob`, the glob
# relative to that dir.
artifacts::_leftover_files() {
  local defining_modules mod patterns where pattern module_dir path lines=""
  defining_modules=${ modules::defining installed_file_patterns; }
  while IFS= read -r mod; do
    [ -n "$mod" ] || continue
    patterns=${ "${mod}::installed_file_patterns"; }
    while IFS=$'\t' read -r where pattern; do
      [ -n "$pattern" ] || continue
      case "$where" in
        data) module_dir=${ artifacts::module_data_dir "$mod"; } ;;
        config) module_dir=${ artifacts::module_config_dir "$mod"; } ;;
        *) lifecycle::fail "artifacts: ${mod}::installed_file_patterns names '$where', not data or config." ;;
      esac
      # The pattern is left unquoted so it globs.
      # shellcheck disable=SC2086
      for path in "$module_dir"/$pattern; do
        [ -f "$path" ] || continue
        lines+="$mod"$'\t'"file"$'\t'"$path"$'\n'
      done
    done <<< "$patterns"
  done <<< "$defining_modules"
  artifacts::_items_json "${lines%$'\n'}"
}

# What was recorded or left behind but is no longer declared. A service or file
# is the same item whichever module names it; a module's own kind is the same
# item only within that module. The recorded copy of an item wins over a leftover
# one, since it knows its module.
artifacts::_stale() {
  jq -nc --argjson declared "$1" --argjson recorded "$2" --argjson leftovers "$3" '
    def identity: if .kind == "service" or .kind == "file" then [.kind, .name] else [.module, .kind, .name] end;
    ($declared | map(identity)) as $wanted
    | $recorded + $leftovers
    | unique_by(identity)
    | map(select(identity as $id | any($wanted[]; . == $id) | not))'
}

artifacts::_report_stale() {
  local stale="$1" item
  [ "$stale" = "[]" ] && return 0
  logging::info "Installed but no longer configured (removal asks first):"
  while IFS= read -r item; do
    [ -n "$item" ] || continue
    logging::info "  ${ artifacts::_describe "$item"; }"
  done <<< "$(jq -c '.[]' <<< "$stale")"
}

artifacts::_describe() {
  jq -r 'if .kind == "service" or .kind == "file" then "\(.kind) \(.name)" else "\(.module) \(.kind) \(.name)" end' <<< "$1"
}

# --- removal ---

# Remove each item, printing the ones that could not be removed as a JSON list.
# A removal's own output goes to stderr so it can't end up in that list.
artifacts::_remove_each() {
  local stale="$1" item kept=""
  while IFS= read -r item; do
    [ -n "$item" ] || continue
    if artifacts::_remove "$item" >&2; then
      logging::success "removed ${ artifacts::_describe "$item"; }"
    else
      logging::warn "could not remove ${ artifacts::_describe "$item"; }; it is kept and offered again on the next apply."
      kept+="$item"$'\n'
    fi
  done <<< "$(jq -c '.[]' <<< "$stale")"
  jq -sc . <<< "$kept"
}

artifacts::_remove() {
  local item="$1" module kind name
  module=$(jq -r '.module' <<< "$item")
  kind=$(jq -r '.kind' <<< "$item")
  name=$(jq -r '.name' <<< "$item")
  case "$kind" in
    service) service::uninstall "$name" ;;
    file) artifacts::_remove_file "$name" ;;
    *)
      if ! declare -F "${module}::remove_artifact" > /dev/null 2>&1; then
        logging::warn "artifacts: module '$module' has no way to remove a $kind."
        return 1
      fi
      "${module}::remove_artifact" "$kind" "$name"
      ;;
  esac
}

# Only a file under machinekit's own data or config dir, so a damaged record can't
# delete anything else.
artifacts::_remove_file() {
  local path="$1"
  if ! artifacts::_within_own_dirs "$path"; then
    logging::warn "artifacts: refusing to remove $path, which is outside machinekit's own dirs."
    return 1
  fi
  rm -f -- "$path"
}

artifacts::_within_own_dirs() {
  local path="$1" data_dir config_dir
  data_dir=${ artifacts::_data_dir; }
  config_dir=${ artifacts::_config_dir; }
  [[ "$path" != */../* ]] && [[ "$path" == "$data_dir"/* || "$path" == "$config_dir"/* ]]
}

# One consent covers the listed set: it was printed in preflight, so an
# interactive yes is not answered blind.
artifacts::_removal_consented() {
  local consent
  consent=${ context::get "remove_unconfigured" --default false --coerce boolean \
    --prompt "$_ARTIFACTS_REMOVAL_PROMPT"; }
  [ "$consent" = "true" ]
}

artifacts::_write_record() {
  local record temporary_record
  record=${ artifacts::record_path; }
  mkdir -p "$(dirname "$record")"
  temporary_record=$(mktemp "$record.XXXXXX")
  printf '%s\n' "$1" > "$temporary_record"
  mv "$temporary_record" "$record"
}

artifacts::_union() {
  jq -nc --argjson first "$1" --argjson second "$2" '$first + ($second - $first)'
}

artifacts::_data_dir() {
  printf '%s\n' "${XDG_DATA_HOME:-$HOME/.local/share}/machinekit"
}

artifacts::_config_dir() {
  printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/machinekit"
}
