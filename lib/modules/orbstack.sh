#!/usr/bin/env bash
# orbstack — container runtime for macOS; satisfies container_manager.

orbstack::provides() { printf 'container_manager\n'; }

orbstack::install() {
  logging::step "orbstack install"
  brew::install_formula orbstack
}
