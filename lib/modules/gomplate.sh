#!/usr/bin/env bash
# gomplate module — renders .tmpl home files through gomplate.
#
# A base module (always active), so the .tmpl content transform is always
# registered. render is the pipeline handler: an IN→stdout filter that feeds
# the input through gomplate with a JSON context built from the machinekit
# context store. The context file is built once per run and reused across every
# rendered file, so gomplate's cross-file state is shared — which is why it is
# kept in a module global and set as a statement, never captured from a subshell.

# Lazily-built, run-scoped context file, shared across all rendered files.
_MK_GOMPLATE_CTX_FILE=""

gomplate::file_transforms() {
  printf '%s\n' "tmpl content gomplate::render"
}

gomplate::install() {
  # --override-dry-run: a dry run still renders templates to show diffs, so the
  # binary must be present even when nothing else would be installed.
  brew::install_formula gomplate --override-dry-run
}

# render IN → stdout — the pipeline handler for .tmpl files.
gomplate::render() {
  local src="$1"
  gomplate::_ensure_context
  gomplate --context ".=file://${_MK_GOMPLATE_CTX_FILE}?type=application/json" -f "$src"
}

# Build the shared context file once. Set as a statement (not via $(...)) so the
# memoized path survives across files in the same run.
gomplate::_ensure_context() {
  [ -n "$_MK_GOMPLATE_CTX_FILE" ] && return 0
  _MK_GOMPLATE_CTX_FILE=$(mktemp)
  context::json > "$_MK_GOMPLATE_CTX_FILE"
  lifecycle::register_cleanup gomplate::_cleanup_context
}

gomplate::_cleanup_context() {
  [ -n "$_MK_GOMPLATE_CTX_FILE" ] || return 0
  rm -f -- "$_MK_GOMPLATE_CTX_FILE"
  _MK_GOMPLATE_CTX_FILE=""
}
