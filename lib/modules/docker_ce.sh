#!/usr/bin/env bash
# docker_ce — container runtime for Linux; satisfies container_manager.

docker_ce::provides() { printf 'container_manager\n'; }

docker_ce::install() {
  logging::step "docker_ce install"
  # Idempotency guard: the get.docker.com script isn't safe to re-run — it warns,
  # sleeps 20s, then resets the deb/rpm repo config. Skip when docker's present.
  if input::command_exists docker; then
    logging::debug "docker_ce: already installed"
    return 0
  fi
  if input::is_dry_run; then
    logging::dry_run "would install: docker-ce (via get.docker.com convenience script)"
    return 0
  fi
  docker_ce::_run_install_script
  logging::success "docker_ce install complete."
}

docker_ce::_run_install_script() {
  curl -fsSL https://get.docker.com | sudo sh
}
