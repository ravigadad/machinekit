#!/usr/bin/env bash
# Brewfile module — applies the user's Brewfile from the blueprint.

brewfile::install() {
  logging::step "common/Brewfile"
  local brewfile
  brewfile="$(blueprints::dir)/common/Brewfile"
  if [ ! -f "$brewfile" ]; then
    logging::info "No common/Brewfile found in blueprints; skipping."
    return 0
  fi
  if input::is_dry_run; then
    logging::info "Diffing $brewfile"
    brewfile::_diff "$brewfile"
  else
    logging::info "Applying $brewfile"
    brew bundle --file "$brewfile"
    logging::success "common/Brewfile applied."
  fi
}

# Dry-run companion: reports which entries are already installed vs. would be
# installed. Fetches the installed formula/cask lists once rather than per-line
# to avoid repeated brew invocations.
brewfile::_diff() {
  local brewfile="$1"
  local installed_formulae installed_casks line

  if ! input::command_exists brew; then
    logging::dry_run "Homebrew not installed; cannot diff Brewfile."
    return 0
  fi

  installed_formulae=$(brew::_installed_formulae)
  installed_casks=$(brew list --cask 2>/dev/null || true)

  while IFS= read -r line; do
    line="${line%%#*}"
    [[ "$line" =~ [^[:space:]] ]] || continue

    if [[ "$line" =~ ^[[:space:]]*brew[[:space:]]+[\"\']([^\"\']+)[\"\'] ]]; then
      brewfile::_report_entry "brew" "${BASH_REMATCH[1]}" "$installed_formulae"
    elif [[ "$line" =~ ^[[:space:]]*cask[[:space:]]+[\"\']([^\"\']+)[\"\'] ]]; then
      brewfile::_report_entry "cask" "${BASH_REMATCH[1]}" "$installed_casks"
    fi
  done < "$brewfile"
}

brewfile::_report_entry() {
  local type="$1" name="$2" installed_list="$3"
  if printf '%s\n' "$installed_list" | grep -qxF "$name"; then
    logging::info "  $type \"$name\" — already installed"
  else
    logging::dry_run "  $type \"$name\" — would install"
  fi
}
