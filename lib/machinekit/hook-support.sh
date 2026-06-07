#!/usr/bin/env bash
# Hook support library. Source this at the top of blueprint hook scripts to
# access machinekit's logging, input detection, lifecycle helpers, and context
# store. Available via the MACHINEKIT_SUPPORT env var at hook runtime.
#
#   source "$MACHINEKIT_SUPPORT"
#
# Context values set or modified by a hook are visible to subsequent hooks and
# (if any code reads context after hooks run) to the apply pipeline. Context
# is read-write by design.

_mk_support_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=logging.sh
source "$_mk_support_dir/logging.sh"
# shellcheck source=input.sh
source "$_mk_support_dir/input.sh"
# shellcheck source=lifecycle.sh
source "$_mk_support_dir/lifecycle.sh"
# shellcheck source=context.sh
source "$_mk_support_dir/context.sh"
# shellcheck source=config.sh
source "$_mk_support_dir/config.sh"
unset _mk_support_dir
