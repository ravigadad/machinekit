#!/usr/bin/env bash
# git module — collects git user identity and ships the gitconfig template.
#
# Preflight publishes git.user_name and git.user_email into context;
# dot_gitconfig.tmpl picks them up at chezmoi-apply time.

git::preflight() {
  # Resolve eagerly so a missing value fails here with a clear message
  # rather than at chezmoi-apply time with a template error.
  local name email
  name=$(context::get "git.user_name"   --required) || return 1
  email=$(context::get "git.user_email" --required) || return 1
  logging::info "Git user.name:  $name"
  logging::info "Git user.email: $email"
}

git::install() {
  # Dotfiles are handled by the chezmoi module; nothing to install here.
  :
}
