#!/usr/bin/env bash
# machinekit's own prerequisites — the tools machinekit needs to function.
# The namespace is about *what* machinekit requires, not *how* it gets it,
# so the install mechanism can change without touching the public function.
#
# Prerequisites always install regardless of dry-run mode. Without them the
# pipeline can't run at all, so a dry-run on a fresh machine would show nothing
# useful. Homebrew + these tools are the floor, not the feature.

_MK_PREREQUISITES=(jq toml2json gomplate git age)

prerequisites::install() {
  logging::step "prerequisites (${_MK_PREREQUISITES[*]})"
  local tool
  for tool in "${_MK_PREREQUISITES[@]}"; do
    prerequisites::_install_tool "$tool"
  done
  logging::success "Prerequisites installed."
}

prerequisites::_install_tool() {
  brew::install_formula "$1" --override-dry-run
}
