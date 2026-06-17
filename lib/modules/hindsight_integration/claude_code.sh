#!/usr/bin/env bash
# hindsight_integration::claude_code — the Claude Code agent integration. Sourced
# by hindsight_integration.sh, which owns the shared config (server location,
# tenant key, bank prefix) and calls into the contract every integration submodule
# provides:
#   requires        — agent tool module this integration needs installed
#   install         — set up the agent's plugin/integration (idempotent)
#   write_config    — point the agent at the server: write its config file and
#                     register tools-bank MCP servers
#                     (URL, TOKEN, BANK_ID_PREFIX, RECALL_BANKS, TOOLS_BANKS)
#   config_present  — whether that config already exists (for create-once)
#
# The plugin reads ~/.hindsight/claude-code.json and activates on startup; tool_use
# banks additionally get their own MCP server (claude mcp add).

# This integration needs the Claude Code CLI; the resolver installs claude_code
# before the integration's own install runs (so no preflight CLI check — that
# would fail on a fresh machine, where all preflights run before any install).
hindsight_integration::claude_code::requires() {
  printf 'claude_code\n'
}

# Install the hindsight-memory plugin. The marketplace add and plugin install
# mutate Claude Code's state (and hit the network), so the step is gated on
# dry-run; the install itself is guarded for idempotency.
#
# VERIFY IN VM. The marketplace/plugin command shapes and the idempotency of
# re-adding a marketplace are from the upstream docs, not a live run.
hindsight_integration::claude_code::install() {
  if input::is_dry_run; then
    logging::dry_run "would add the hindsight marketplace and install the hindsight-memory plugin"
    return 0
  fi
  hindsight_integration::claude_code::_add_marketplace
  if hindsight_integration::claude_code::_plugin_installed; then
    logging::debug "hindsight_integration::claude_code: hindsight-memory plugin already installed"
    return 0
  fi
  claude plugin install hindsight-memory
}

hindsight_integration::claude_code::_add_marketplace() {
  claude plugin marketplace add vectorize-io/hindsight
}

hindsight_integration::claude_code::_plugin_installed() {
  claude plugin list 2>/dev/null | grep -q hindsight-memory
}

hindsight_integration::claude_code::config_present() {
  [ -f "$(hindsight_integration::claude_code::_config_path)" ]
}

# Point Claude Code at the server: write the plugin config (mode 600) — server
# URL + tenant token, dynamic per-project banks (ids `<prefix>-<repo>`), and
# read-only auto-recall from each recall bank — then register an MCP server per
# tools bank. recall_banks/tools_banks arrive newline-delimited. jq builds the
# JSON so values are escaped correctly.
hindsight_integration::claude_code::write_config() {
  local url="$1" token="$2" prefix="$3" recall_banks="$4" tools_banks="$5"
  local config_path dir recall_json
  config_path="$(hindsight_integration::claude_code::_config_path)"
  dir="$(dirname "$config_path")"
  mkdir -p "$dir"
  chmod 700 "$dir"
  recall_json="$(printf '%s' "$recall_banks" | jq -Rsc 'split("\n") | map(select(length > 0))')"
  jq -n --arg url "$url" --arg token "$token" --arg prefix "$prefix" \
    --argjson recall "$recall_json" '{
    hindsightApiUrl: $url,
    hindsightApiToken: $token,
    dynamicBankId: true,
    dynamicBankGranularity: ["project"],
    bankIdPrefix: $prefix,
    recallAdditionalBanks: $recall
  }' > "$config_path"
  chmod 600 "$config_path"
  hindsight_integration::claude_code::_register_mcp_servers "$url" "$token" "$tools_banks"
}

# Register a single-bank MCP server per tools bank (idempotent). Each gives the
# agent explicit read/write/reflect tools pinned to that bank at /mcp/<bank>/.
hindsight_integration::claude_code::_register_mcp_servers() {
  local url="$1" token="$2" tools_banks="$3" bank base
  base="${url%/}"
  while IFS= read -r bank; do
    [ -n "$bank" ] || continue
    hindsight_integration::claude_code::_mcp_server_present "$bank" && continue
    claude mcp add -s user -t http "hindsight-$bank" "$base/mcp/$bank/" \
      --header "Authorization: Bearer $token"
  done <<< "$tools_banks"
}

hindsight_integration::claude_code::_mcp_server_present() {
  claude mcp list 2>/dev/null | grep -q "hindsight-$1"
}

hindsight_integration::claude_code::_config_path() {
  printf '%s/.hindsight/claude-code.json\n' "$HOME"
}
