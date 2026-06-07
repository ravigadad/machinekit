#!/usr/bin/env bash
# tool_version_manager — capability module for runtime version managers.
# Default satisfier: mise. Alternative satisfier: asdf (not yet implemented).

tool_version_manager::is_capability() { return 0; }

tool_version_manager::default_satisfier() { printf 'mise\n'; }

tool_version_manager::requires() { tool_version_manager::default_satisfier; }

tool_version_manager::install() { :; }
