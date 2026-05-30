#!/usr/bin/env bash
# chezmoi module — composes a merged source dir (staging), writes the
# chezmoi config from context, and runs chezmoi against the staging dir.
#
# The staging dir is built by layering each active module's templates,
# then the blueprint's common/dotfiles/ on top — users override module
# defaults by placing a same-path file in their blueprint. The dir is
# wiped and rebuilt every run; chezmoi tracks by destination path + content
# hash, so identical rebuilds produce no diff.
[ -n "${_MK_CHEZMOI_LOADED:-}" ] && return 0
_MK_CHEZMOI_LOADED=1

_MK_CHEZMOI_STAGING_DIR=""

# Held at module scope so the EXIT-trap cleanup registered by chezmoi::install
# can reach it across the subshell boundary.
_MK_CHEZMOI_TMP_CONFIG_DIR=""

chezmoi::cleanup_tmp_config() {
  [ -n "$_MK_CHEZMOI_TMP_CONFIG_DIR" ] || return 0
  rm -rf -- "$_MK_CHEZMOI_TMP_CONFIG_DIR"
  _MK_CHEZMOI_TMP_CONFIG_DIR=""
}

chezmoi::staging_dir() {
  [ -n "$_MK_CHEZMOI_STAGING_DIR" ] || lifecycle::fail "chezmoi::staging_dir called before chezmoi::build_staging"
  printf '%s\n' "$_MK_CHEZMOI_STAGING_DIR"
}

chezmoi::build_staging() {
  chezmoi::_prepare_staging_dir
  logging::step "Building chezmoi source dir"

  local module
  while IFS= read -r module; do
    [ -z "$module" ] && continue
    chezmoi::_layer_dir "$(modules::dir)/$module/templates" "$module templates"
  done < <(context::get_array "modules.active" || true)

  chezmoi::_layer_dir "$(blueprints::dir)/common/dotfiles" "blueprint common/dotfiles"

  logging::success "Source dir built at $_MK_CHEZMOI_STAGING_DIR"
}

chezmoi::_prepare_staging_dir() {
  if input::is_dry_run; then
    _MK_CHEZMOI_STAGING_DIR=$(mktemp -d)
    lifecycle::register_cleanup chezmoi::cleanup_staging
  else
    # Real-mode staging is intentionally persistent across runs — chezmoi tracks
    # by destination path + content hash, so leaving it in place is harmless and
    # avoids re-building on partial re-runs.
    _MK_CHEZMOI_STAGING_DIR="$HOME/.local/share/machinekit/chezmoi-staging"
    rm -rf -- "$_MK_CHEZMOI_STAGING_DIR"
    mkdir -p "$_MK_CHEZMOI_STAGING_DIR"
  fi
}

# Copy a source dir's contents into the staging dir, layering on top of whatever
# is already there (later layers override earlier ones by same path). No-op when
# the source doesn't exist.
chezmoi::_layer_dir() {
  local src="$1" label="$2"
  [ -d "$src" ] || return 0
  cp -R -- "$src"/. "$_MK_CHEZMOI_STAGING_DIR/"
  logging::debug "staging: layered $label"
}

chezmoi::cleanup_staging() {
  [ -n "$_MK_CHEZMOI_STAGING_DIR" ] || return 0
  rm -rf -- "$_MK_CHEZMOI_STAGING_DIR"
  _MK_CHEZMOI_STAGING_DIR=""
}

chezmoi::write_config() {
  local config_path="${1:-$HOME/.config/chezmoi/chezmoi.toml}"
  mkdir -p "$(dirname "$config_path")"

  local age_key_path
  age_key_path=$(context::get "age.key_path") || lifecycle::fail "age.key_path is required but not set"

  local config_content
  config_content=$(
    printf '# managed by machinekit apply — do not edit by hand.\n'
    jq -n \
      --arg source_dir "$(chezmoi::staging_dir)" \
      --arg encryption "age" \
      --arg identity "$age_key_path" \
      --argjson data "$(context::json)" \
      '{encryption: $encryption, sourceDir: $source_dir, age: {identity: $identity}, data: $data}' \
    | dasel -i json -o toml --root
  ) || lifecycle::fail "Failed to generate chezmoi config"
  printf '%s\n' "$config_content" > "$config_path"
}

chezmoi::_diff() {
  local source_dir
  source_dir="$(chezmoi::staging_dir)"
  logging::step "chezmoi dry-run: diff against $HOME"
  if ! input::command_exists chezmoi; then
    logging::dry_run "chezmoi not installed; would run chezmoi apply against $source_dir"
    return 0
  fi
  _MK_CHEZMOI_TMP_CONFIG_DIR=$(mktemp -d)
  lifecycle::register_cleanup chezmoi::cleanup_tmp_config
  local tmp_config="$_MK_CHEZMOI_TMP_CONFIG_DIR/chezmoi.toml"
  chezmoi::write_config "$tmp_config"
  logging::info "chezmoi diff — what would change in $HOME"
  if input::is_interactive; then
    chezmoi::_show_interactive_diff "$source_dir" "$tmp_config"
  else
    chezmoi::_show_plain_diff "$source_dir" "$tmp_config"
  fi
  chezmoi::cleanup_tmp_config
}

chezmoi::_show_interactive_diff() {
  local source_dir="$1" tmp_config="$2"
  logging::info "  Unified diff format. In the pager: arrows/j/k scroll · / searches · q exits and continues."
  read -r -s -n 1 -p $'\n[machinekit] Press any key to open diff...' <"${MACHINEKIT_TTY:-/dev/tty}"
  printf '\n' >&2
  chezmoi --color=on diff -S "$source_dir" -c "$tmp_config" | less -R
}

chezmoi::_show_plain_diff() {
  local source_dir="$1" tmp_config="$2"
  chezmoi --no-pager diff -S "$source_dir" -c "$tmp_config"
}

chezmoi::install() {
  chezmoi::build_staging
  if input::is_dry_run; then
    chezmoi::_diff
    return 0
  fi
  local source_dir
  source_dir="$(chezmoi::staging_dir)"
  chezmoi::write_config
  logging::success "chezmoi config written."
  logging::step "chezmoi apply"
  # In non-interactive mode, `--force` resolves conflicts by overwriting the
  # destination with the source — the right semantic for headless provisioning
  # ("blueprints are the source of truth"). In interactive mode we let chezmoi
  # prompt as usual so the user can decide per-file.
  if input::is_interactive; then
    chezmoi apply -S "$source_dir"
  else
    chezmoi apply -S "$source_dir" --force
  fi
  logging::success "chezmoi apply complete."
}
