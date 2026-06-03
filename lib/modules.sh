#!/usr/bin/env bash
# Modules aggregator. Sources every module file in lib/modules/.
#
# A module may ship bundled assets (templates, scripts) in a sibling
# directory `lib/modules/<name>/` next to its `<name>.sh`; the home
# module's staging-dir builder picks those up.

_MK_MODULES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/modules"

modules::dir() {
  printf '%s\n' "$_MK_MODULES_DIR"
}

# shellcheck source=modules/age.sh
source "$_MK_MODULES_DIR/age.sh"
# shellcheck source=modules/brewfile.sh
source "$_MK_MODULES_DIR/brewfile.sh"
# shellcheck source=modules/home.sh
source "$_MK_MODULES_DIR/home.sh"
# shellcheck source=modules/git.sh
source "$_MK_MODULES_DIR/git.sh"
# shellcheck source=modules/mise.sh
source "$_MK_MODULES_DIR/mise.sh"
# shellcheck source=modules/zsh.sh
source "$_MK_MODULES_DIR/zsh.sh"
