#!/usr/bin/env bash
# OS and architecture detection, stored into context at os.*.
[ -n "${_MK_SYSTEM_LOADED:-}" ] && return 0
_MK_SYSTEM_LOADED=1

system::detect() {
  local raw_os raw_arch family arch

  raw_os="$(system::_os_name)"
  raw_arch="$(system::_arch_name)"

  case "$raw_os" in
    Darwin) family="darwin" ;;
    Linux)  family="linux"  ;;
    *)      lifecycle::fail "Unsupported OS: $raw_os" ;;
  esac

  case "$raw_arch" in
    arm64|aarch64) arch="arm64"  ;;
    x86_64)        arch="x86_64" ;;
    *)             lifecycle::fail "Unsupported architecture: $raw_arch" ;;
  esac

  context::set "os.family" "$family"
  context::set "os.arch"   "$arch"
}

system::_os_name()   { uname -s; }
system::_arch_name() { uname -m; }
