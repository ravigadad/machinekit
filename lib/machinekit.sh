#!/usr/bin/env bash
# Core machinekit library aggregator. Source this from bin/ entry points;
# execution code lives in lib/machinekit/* and lib/modules/*.

_mk_core_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/machinekit"

# shellcheck source=machinekit/logging.sh
source "$_mk_core_dir/logging.sh"
# shellcheck source=machinekit/lifecycle.sh
source "$_mk_core_dir/lifecycle.sh"
# shellcheck source=machinekit/input.sh
source "$_mk_core_dir/input.sh"
# shellcheck source=machinekit/sudo.sh
source "$_mk_core_dir/sudo.sh"
# shellcheck source=machinekit/context.sh
source "$_mk_core_dir/context.sh"
# shellcheck source=machinekit/brew.sh
source "$_mk_core_dir/brew.sh"
# shellcheck source=machinekit/blueprints.sh
source "$_mk_core_dir/blueprints.sh"
# shellcheck source=machinekit/prerequisites.sh
source "$_mk_core_dir/prerequisites.sh"
# shellcheck source=machinekit/preflight.sh
source "$_mk_core_dir/preflight.sh"
# shellcheck source=machinekit/hooks.sh
source "$_mk_core_dir/hooks.sh"
# shellcheck source=machinekit/postflight.sh
source "$_mk_core_dir/postflight.sh"

unset _mk_core_dir
