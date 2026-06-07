#!/usr/bin/env bash
# container_manager — capability module for container runtimes.
# Default satisfier: orbstack (macOS), docker_ce (Linux).

container_manager::is_capability() { return 0; }

container_manager::default_satisfier() {
  local family
  family=$(context::get "os.family")
  case "$family" in
    darwin) printf 'orbstack\n' ;;
    linux)  printf 'docker_ce\n' ;;
    *)      lifecycle::fail "container_manager: no default satisfier for os.family '${family}'" ;;
  esac
}

container_manager::requires() { container_manager::default_satisfier; }

container_manager::install() { :; }
