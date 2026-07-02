#!/usr/bin/env bash
# tool_version_manager — capability module for runtime version managers.
# Default satisfier: mise. Alternative satisfier: asdf (not yet implemented).

tool_version_manager::is_capability() { return 0; }

# tool_version_manager::exec TOOL_SPEC CMD [ARG...] — run CMD with TOOL_SPEC (e.g.
# node@latest) available, installing it on demand via the active version manager
# (mise exec auto-installs a named spec). When no manager is on the box, run CMD
# as-is, so a caller whose CMD self-provisions its runtime (a vendor installer that
# checks for node and installs its own) still works — callers route through here
# unconditionally rather than branching on whether a manager is present.
tool_version_manager::exec() {
  local tool_spec="$1"; shift
  # Drive mise directly, as container_manager drives docker; a second satisfier
  # (asdf) would branch here the way _docker branches on os.family.
  if input::command_exists mise; then
    mise exec "$tool_spec" -- "$@"
  else
    "$@"
  fi
}

tool_version_manager::default_satisfier() { printf 'mise\n'; }

tool_version_manager::requires() { tool_version_manager::default_satisfier; }

tool_version_manager::install() { :; }
