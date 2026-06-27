#!/usr/bin/env bash
# path — put the public `machinekit` command on the user's PATH the way the
# coding-agent CLIs do: a stable symlink in ~/.local/bin plus an idempotent PATH
# line in the shell's rc file. The symlink is a local idempotent install; the rc
# edit is consent-gated (the caller's --no-modify-path opts out), with a printed
# fallback when opted out or when the shell isn't one we wire automatically.
[ -n "${_MK_PATH_LOADED:-}" ] && return 0
_MK_PATH_LOADED=1

# Put `machinekit` on PATH. Always links it into ~/.local/bin; unless the user
# opted out (modify_path = 0) and the shell is one we know, also adds ~/.local/bin
# to that shell's PATH. Otherwise prints how to finish by hand.
path::ensure_on_path() {
  local modify_path="$1"
  path::_link "$MACHINEKIT_DIR"

  if [ "$modify_path" = "0" ]; then
    path::_print_manual_instructions
    return 0
  fi

  local shell_name rc_file export_line
  shell_name="$(path::_detect_shell)"
  rc_file="$(path::_rc_file "$shell_name")"
  if [ -z "$rc_file" ]; then
    path::_print_manual_instructions
    return 0
  fi

  export_line="$(path::_export_line "$shell_name")"
  path::_write_path_block "$rc_file" "$export_line"
  logging::success "Added ~/.local/bin to PATH in $rc_file"
  logging::info "Restart your shell (or source $rc_file) to run 'machinekit'."
}

# Symlink the public entry into ~/.local/bin, re-pointing (-f) to heal a framework
# that has since moved.
path::_link() {
  local framework_dir="$1"
  local local_bin_dir
  local_bin_dir="$(path::_local_bin_dir)"
  mkdir -p "$local_bin_dir"
  ln -sf "$framework_dir/bin/machinekit" "$local_bin_dir/machinekit"
}

# Absolute ~/.local/bin, resolved at call time (tests point HOME at a tmpdir).
path::_local_bin_dir() {
  printf '%s\n' "$HOME/.local/bin"
}

# The shell the user runs, by name (zsh, bash, fish, …); empty if $SHELL is unset.
path::_detect_shell() {
  local shell_path="${SHELL:-}"
  [ -n "$shell_path" ] && basename "$shell_path"
}

# The rc file a PATH line belongs in for the given shell; empty for a shell we
# don't wire automatically (the caller falls back to printed instructions). For
# bash the login-vs-interactive rc differs by OS, so prefer one the user already
# has, defaulting to ~/.bashrc.
path::_rc_file() {
  local shell_name="$1"
  case "$shell_name" in
    zsh)  printf '%s\n' "$HOME/.zshrc" ;;
    fish) printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/fish/config.fish" ;;
    bash)
      local candidate
      for candidate in "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.profile"; do
        [ -f "$candidate" ] && { printf '%s\n' "$candidate"; return 0; }
      done
      printf '%s\n' "$HOME/.bashrc"
      ;;
  esac
}

# The shell-appropriate line that prepends ~/.local/bin to PATH.
path::_export_line() {
  local shell_name="$1"
  # The rc line carries literal $HOME/$PATH for the shell to expand, not us.
  # shellcheck disable=SC2016
  case "$shell_name" in
    fish) printf '%s\n' 'set -gx PATH $HOME/.local/bin $PATH' ;;
    *)    printf '%s\n' 'export PATH="$HOME/.local/bin:$PATH"' ;;
  esac
}

# Reconcile the PATH line into the rc file as an idempotent, machinekit-owned
# block (re-run safe; the user's surrounding content is untouched).
path::_write_path_block() {
  local rc_file="$1" export_line="$2"
  printf '%s\n' "$export_line" | managed_block::ensure "$rc_file" "#"
}

# Tell the user how to finish by hand — used when they opted out of the rc edit or
# run a shell we don't wire automatically.
path::_print_manual_instructions() {
  local local_bin_dir
  local_bin_dir="$(path::_local_bin_dir)"
  logging::info "machinekit is linked at $local_bin_dir/machinekit."
  logging::info "Add $local_bin_dir to your PATH to run it as 'machinekit'."
}
