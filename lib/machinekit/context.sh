#!/usr/bin/env bash
# Structured context store for machinekit-resolved inputs. JSON object in a
# temp file, manipulated via jq. Passed to gomplate at apply time so blueprint
# dotfiles can reference values as nested template fields.
#
# Keys use snake_case dotted notation: "git.user_name" lands at
# .git.user_name in the JSON tree.
#
# Requires jq on PATH (installed as a prerequisite before preflight runs).
set -euo pipefail

[ -n "${_MK_CONTEXT_LOADED:-}" ] && return 0
_MK_CONTEXT_LOADED=1
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/logging.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lifecycle.sh"

# context::init_storage
# Call once from the main shell before any $(...) that touches the store.
# Satisfies the first-call precondition in context::_internal_storage_file.
context::init_storage() {
  context::_internal_storage_file >/dev/null
}

# context::set KEY VALUE
# Write a scalar value into the context store at a dotted key path.
context::set() {
  context::init_storage
  local key="$1" val="$2" argopt="arg" store; shift 2
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) argopt="argjson" ;;
      *) lifecycle::fail "context::set: unknown option: $1" ;;
    esac
    shift
  done
  store=$(context::_internal_storage_file)
  local tmp_store
  tmp_store=$(mktemp "${store}.XXXXXX")
  # Write to a sibling tempfile first so a failure or interrupt never leaves
  # the store truncated. mv is atomic at the filesystem level.
  jq --arg path "$key" --$argopt val "$val" \
    '($path | split(".")) as $p | setpath($p; $val)' "$store" > "$tmp_store" \
    || { rm -f "$tmp_store"; return 1; }
  mv "$tmp_store" "$store"
}

# context::get KEY [--required] [--default VALUE] [--coerce TYPE] [--prompt TEXT]
# Resolve KEY through the cascade: store, then MACHINEKIT_ env var. With
# --required, an unresolved key prompts interactively and then fails; without
# it, an unresolved key returns 1 silently.
context::get() {
  local key="$1"; shift
  local required=0
  local default=""
  local has_default=0
  local store_default=0
  local coerce=""
  local prompt_text=""
  local should_prompt=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --required)       required=1 ;;
      --default)        has_default=1; default="$2"; shift ;;
      --coerce)         coerce="$2"; shift ;;
      --prompt)         should_prompt=1; prompt_text="$2"; shift ;;
      --store-default)  store_default=1 ;;
      *) lifecycle::fail "context::get: unknown option: $1" ;;
    esac
    shift
  done

  [ "$required" = 1 ] && [ "$has_default" = 1 ] && \
    lifecycle::fail "context::get: --required and --default are mutually exclusive"

  [ -n "$prompt_text" ] && should_prompt=1
  [ "$required" = 1 ] && should_prompt=1

  local _prompt_call=("$key")
  [ -n "$prompt_text" ] && _prompt_call+=(--label "$prompt_text")
  [ "$has_default" = 1 ] && _prompt_call+=(--default "$default")
  [ -n "$coerce" ] && _prompt_call+=(--type "$coerce")

  local val
  if   val=$(context::_from_store "$key"); then :
  elif val=$(context::_from_env   "$key"); then :
  elif [ "$should_prompt" = 1 ] && val=$(context::_prompt "${_prompt_call[@]}"); then :
  elif [ "$has_default" = 1 ]; then
    [ "$store_default" = 1 ] && context::set "$key" "$default"
    val="$default"
  else
    [ "$required" = 1 ] && context::_fail_required "$key"
    return 1
  fi

  if [ -n "$coerce" ]; then
    "context::_coerce_${coerce}" "$val"
  else
    printf '%s\n' "$val"
  fi
}

# context::set_array KEY [ELEMENT...]
# Replaces any prior value at the dotted key with a JSON string array.
context::set_array() {
  local key="$1"; shift
  local json_array
  if [ $# -eq 0 ]; then
    json_array='[]'
  else
    json_array=$(printf '%s\n' "$@" | jq -R . | jq -sc .)
  fi
  context::set "$key" "$json_array" --json
}

# context::get_array KEY
# Returns 1 if the key is unset; emits each element on its own line.
context::get_array() {
  local val
  val=$(context::_from_store "$1") || return 1
  printf '%s' "$val" | jq -e 'type == "array"' >/dev/null 2>&1 || return 1
  printf '%s' "$val" | jq -r '.[]'
}

# context::json
# Emit the full context as a JSON object.
context::json() {
  context::init_storage
  cat "$(context::_internal_storage_file)"
}

# context::seed_from_flags
# Promote MACHINEKIT_* env vars written during flag parsing into the context
# store. Call once from main() after prerequisites::install guarantees jq is
# on PATH and after context::init_storage has been called.
#
# Explicit table because the var-to-key mapping isn't mechanically reversible:
# MACHINEKIT_MODE_INTERACTIVE=0 means mode.interactive=false, not "0". The
# table stays here (not in the entry script) because context.sh already owns
# the MACHINEKIT_* ↔ context-key relationship via _from_env.
context::seed_from_flags() {
  local pairs pair env_var key val
  pairs=(
    "MACHINEKIT_BLUEPRINTS_SOURCE:blueprints.source"
    "MACHINEKIT_BLUEPRINTS_SOURCE_PROTOCOL:blueprints.source_protocol"
    "MACHINEKIT_MACHINE_TYPE:machine_type"
    "MACHINEKIT_EXISTING_AGE_KEY_FILE:existing_age_key_file"
    "MACHINEKIT_AGE_KEY_GENERATE:age.key_generate"
    "MACHINEKIT_AGE_KEY_OVERWRITE:age.key_overwrite"
    "MACHINEKIT_MODE_DRY_RUN:mode.dry_run"
    "MACHINEKIT_MODE_INTERACTIVE:mode.interactive"
  )
  for pair in "${pairs[@]}"; do
    env_var="${pair%%:*}"
    key="${pair##*:}"
    val="${!env_var:-}"
    if [ -n "$val" ]; then context::set "$key" "$val"; fi
  done
}

context::cleanup() {
  [ -n "${MACHINEKIT_CONTEXT_FILE:-}" ] && rm -f "$MACHINEKIT_CONTEXT_FILE"
  unset MACHINEKIT_CONTEXT_FILE
}

# context::_internal_storage_file
# Lazy initializer; returns the store path on every call.
# Exported so child processes share the store instead of forking an empty one.
# First call must be in the main shell — subshell exports are invisible to the
# parent, which would then create a second store and leak the temp file.
# Use context::init_storage to guarantee this.
context::_internal_storage_file() {
  if [ -z "${MACHINEKIT_CONTEXT_FILE:-}" ]; then
    # _MK_TEST_OVERRIDE_SUBSHELL_DEPTH allows tests to simulate main-shell
    # context when bats itself runs in a subshell ($BASH_SUBSHELL > 0).
    if [ "${_MK_TEST_OVERRIDE_SUBSHELL_DEPTH:-$BASH_SUBSHELL}" -gt 0 ]; then
      lifecycle::fail "context: store must be initialized from the main shell, not a subshell"
    fi
    MACHINEKIT_CONTEXT_FILE=$(mktemp)
    printf '{}' > "$MACHINEKIT_CONTEXT_FILE"
    export MACHINEKIT_CONTEXT_FILE
    lifecycle::register_cleanup context::cleanup
  fi
  printf '%s\n' "$MACHINEKIT_CONTEXT_FILE"
}

# context::_coerce_boolean VALUE
# Normalizes a truthy/falsy string to the literal `true` or `false`.
# Hard-fails on unrecognized input — that is misconfiguration, not a miss.
context::_coerce_boolean() {
  case "$1" in
    1|true|yes|y|TRUE|YES|Y)   printf 'true\n'  ;;
    0|false|no|n|FALSE|NO|N)   printf 'false\n' ;;
    *) lifecycle::fail "context: unrecognized boolean value: '$1'" ;;
  esac
}

# context::_var_key KEY
# Derive the environment-variable suffix from a dotted key:
# "git.user_name" -> "GIT_USER_NAME".
context::_var_key() {
  printf '%s' "$1" | tr '.' '_' | tr '[:lower:]' '[:upper:]'
}

# context::_from_store KEY
# Print the stored value for KEY, or return 1 if unset.
context::_from_store() {
  context::init_storage
  local store val
  store=$(context::_internal_storage_file)
  val=$(jq -r --arg path "$1" \
    '($path | split(".")) as $p | getpath($p)' "$store")
  [ "$val" = "null" ] && return 1
  printf '%s\n' "$val"
}

# context::_from_env KEY
# Resolve from the MACHINEKIT_<KEY> env var. Writes the value back to the store
# so subsequent reads are served from the cache rather than repeating the lookup.
# Returns 1 if the var is unset.
context::_from_env() {
  local env_var
  env_var="MACHINEKIT_$(context::_var_key "$1")"
  local env_val="${!env_var:-}"
  [ -z "$env_val" ] && return 1
  context::set "$1" "$env_val"
  printf '%s\n' "$env_val"
}

# context::_prompt_label KEY
# Human-readable prompt label for a key: "git.user_name" -> "Git user name".
context::_prompt_label() {
  printf '%s' "$1" | tr '._' ' ' | awk '{print toupper(substr($0,1,1)) substr($0,2)}'
}

# context::_prompt KEY [LABEL]
# Prompt interactively for KEY, writing the response back to the store.
# Returns 1 when non-interactive or the response is empty. The prompt label
# goes to stderr and the response is read from MACHINEKIT_TTY (default
# /dev/tty), so prompting still reaches the terminal when stdin is a pipe.
context::_prompt() {
  input::is_interactive >/dev/null || return 1
  local key="$1"; shift
  local label="" has_label=0 has_default=0 default="" type=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --label)   has_label=1; label="$2"; shift ;;
      --default) has_default=1; default="$2"; shift ;;
      --type)    type="$2"; shift ;;
      *) lifecycle::fail "context::_prompt: unknown option: $1" ;;
    esac
    shift
  done
  [ "$has_label" = 0 ] && label="$(context::_prompt_label "$key")"
  printf '%s%s: ' "$label" "$(context::_prompt_hint "$type" "$has_default" "$default")" >&2
  local response
  read -r response <"${MACHINEKIT_TTY:-/dev/tty}"
  if [ -z "$response" ]; then
    [ "$has_default" = 1 ] || return 1
    context::set "$key" "$default"
    printf '%s\n' "$default"
    return 0
  fi
  context::set "$key" "$response"
  printf '%s\n' "$response"
}

context::_prompt_hint() {
  local type="$1" has_default="$2" default="$3"
  case "$type" in
    boolean)
      if [ "$has_default" = 1 ]; then
        [ "$default" = "true" ] && printf ' [Y/n]' || printf ' [y/N]'
      else
        printf ' [y/n]'
      fi
      ;;
    *)
      [ "$has_default" = 1 ] && printf ' [%s]' "$default"
      ;;
  esac
}

# context::_fail_required KEY
# Report an unresolved required key with flag/env hints, then exit.
context::_fail_required() {
  local flag_name env_var
  flag_name=$(printf '%s' "$1" | tr '._' '-')
  env_var="MACHINEKIT_$(context::_var_key "$1")"
  logging::error "Required value not provided: $1"
  logging::error "  --${flag_name} <value>"
  logging::error "  ${env_var}=<value>"
  exit 1
}
