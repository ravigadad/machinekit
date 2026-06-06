#!/usr/bin/env bash
# git module — collects git user identity and ships the gitconfig template.
#
# Preflight ensures that config.module.git.user_name and *.user_email are set (if
# not declared in config already, the user is prompted), so dot_gitconfig.tmpl can
# pick them up at apply time.

git::preflight() {
  # Resolve eagerly so a missing value fails here with a clear message
  # rather than at apply time with a template error.
  local name email
  name=$(config::get "module.git.user_name"   --required --prompt "Git user.name")  || return 1
  email=$(config::get "module.git.user_email" --required --prompt "Git user.email") || return 1
  logging::info "Git user.name:  $name"
  logging::info "Git user.email: $email"
}

git::install() {
  # Dotfiles are handled by the home module; nothing to install here.
  :
}
