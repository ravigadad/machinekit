#!/usr/bin/env bash
# container_manager — capability module for container runtimes.
# Default satisfier: orbstack (macOS), docker_ce (Linux).

# One canonical machinekit-owned docker network, shared by every consumer (a
# resource module opening itself to containers, a service module attaching its
# compose). Not per-consumer.
_CONTAINER_MANAGER_NETWORK="machinekit"

container_manager::is_capability() { return 0; }

# Ensure the canonical network exists and print its subnet. We don't pin a CIDR
# (it could collide inside docker's 172.16/12 pool or with the host LAN/VPN); we
# let docker auto-assign and read it back, so callers learn exactly what to open.
container_manager::container_subnet() {
  container_manager::_docker network inspect "$_CONTAINER_MANAGER_NETWORK" >/dev/null 2>&1 \
    || container_manager::_docker network create "$_CONTAINER_MANAGER_NETWORK" >/dev/null
  container_manager::_docker network inspect "$_CONTAINER_MANAGER_NETWORK" \
    --format '{{ (index .IPAM.Config 0).Subnet }}'
}

# The DNS name a container uses to reach the host. macOS/OrbStack resolves it
# natively; on Linux a compose maps it via `extra_hosts: host-gateway`. Same name
# both ways, so a consumer building a host-facing URL needn't branch on OS.
container_manager::host_alias() {
  printf 'host.docker.internal\n'
}

# On Linux the docker daemon runs as root and the user isn't in the docker group
# (the get.docker.com script doesn't add them), so docker needs sudo; on
# macOS/OrbStack the socket is user-owned.
container_manager::_docker() {
  case "$(context::get os.family)" in
    linux) sudo docker "$@" ;;
    *)     docker "$@" ;;
  esac
}

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
