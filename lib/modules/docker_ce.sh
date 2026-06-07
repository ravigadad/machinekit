#!/usr/bin/env bash
# docker_ce — container runtime for Linux; satisfies container_manager.

docker_ce::provides() { printf 'container_manager\n'; }

docker_ce::install() {
  logging::step "docker_ce install"
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
