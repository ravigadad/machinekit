#!/usr/bin/env bash
# framework — keeps machinekit's own clone (MACHINEKIT_DIR) on its update target:
# the highest release tag, or the tip of origin/main when update.track = "main".
# `machinekit update` moves the clone; apply only checks and warns, unless
# auto_update is on, in which case it updates and reruns itself.
[ -n "${_MK_FRAMEWORK_LOADED:-}" ] && return 0
_MK_FRAMEWORK_LOADED=1

# Release tags are bare X.Y.Z, the same string as VERSION.
_FRAMEWORK_RELEASE_TAG_PATTERN='^[0-9]+\.[0-9]+\.[0-9]+$'

# framework::update RESET — move the clone to its target. Without RESET (0), local
# changes or commits stop the update; with RESET (1), tracked changes are discarded.
framework::update() {
  local reset="$1" track target changes
  framework::fetch || lifecycle::fail "machinekit: could not fetch updates from origin."
  track=${ framework::track; }
  target=${ framework::target "$track"; }
  if [ "$reset" != "1" ]; then
    changes=${ framework::local_changes; }
    [ -z "$changes" ] || lifecycle::fail \
      "machinekit: $MACHINEKIT_DIR has local changes, so it was not updated:"$'\n'"$changes"$'\n'"Run 'machinekit update --reset' to discard them and update."
  fi
  framework::move_to "$target" "$reset"
  logging::success "machinekit is now on $target."
}

# Warn when the clone is not on its target. With auto_update on (and not a dry
# run), update and rerun the apply instead. A failed fetch only warns, so an
# offline apply still runs.
framework::check_for_update() {
  [ -z "${_MK_FRAMEWORK_UPDATED:-}" ] || return 0
  local track target auto_update behind
  if ! framework::fetch; then
    logging::warn "machinekit: could not check for an update (fetching from origin failed)."
    return 0
  fi
  track=${ framework::track; }
  target=${ framework::target "$track"; }
  framework::is_on "$target" && return 0
  auto_update=${ context::get "auto_update" --default false --coerce boolean; }
  if [ "$auto_update" = "true" ] && ! input::is_dry_run; then
    framework::_update_and_rerun_apply
    return 0
  fi
  behind=${ framework::commits_until "$target"; }
  if [ "$behind" -gt 0 ]; then
    logging::warn "machinekit is $behind commits behind $target. Run 'machinekit update' (or apply with --auto-update)."
  else
    logging::warn "machinekit is not on $target. Run 'machinekit update' (or apply with --auto-update)."
  fi
}

framework::track() {
  local track
  track=${ context::get "update.track" --default release; }
  case "$track" in
    release|main) printf '%s\n' "$track" ;;
    *) lifecycle::fail "machinekit: update.track is '$track'; it must be release or main." ;;
  esac
}

framework::target() {
  case "$1" in
    main)    printf 'origin/main\n' ;;
    release) framework::_git tag --list --sort=-version:refname | grep -m 1 -E "$_FRAMEWORK_RELEASE_TAG_PATTERN" ;;
  esac
}

# --force so a release tag that moved on origin moves here too.
framework::fetch() {
  framework::_git fetch --quiet --force --tags origin
}

# What an update would lose: changes to tracked files, and commits origin has under
# no branch or tag. Untracked files are left out, since moving the clone keeps them.
framework::local_changes() {
  framework::_git status --porcelain --untracked-files=no
  framework::_git log --oneline HEAD --not --remotes --tags
}

framework::move_to() {
  local target="$1" force="$2" force_args=()
  [ "$force" = "1" ] && force_args=(--force)
  framework::_git checkout --quiet --detach "${force_args[@]}" "$target"
}

framework::is_on() {
  [ "$(framework::_git rev-parse HEAD)" = "$(framework::_git rev-parse "$1^{commit}")" ]
}

framework::commits_until() {
  framework::_git rev-list --count "HEAD..$1"
}

# The update replaces this apply's code while it runs. The rest of this function
# is already parsed, and it ends in exec, so nothing is read from the replaced
# files. The update takes the lock itself, so this apply gives it up first.
framework::_update_and_rerun_apply() {
  logging::step "Updating machinekit before applying (auto_update is on)"
  lifecycle::release_lock
  framework::_run_update_command || lifecycle::fail "machinekit: the update failed, so nothing was applied."
  lifecycle::exec env _MK_FRAMEWORK_UPDATED=1 "$MACHINEKIT_DIR/bin/machinekit" apply
}

framework::_run_update_command() {
  "$MACHINEKIT_DIR/bin/machinekit" update
}

framework::_git() {
  git -C "$MACHINEKIT_DIR" "$@"
}
