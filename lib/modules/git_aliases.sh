#!/usr/bin/env bash
# git_aliases module — ships the git alias/function library.
# Template-only: the aliases land at ~/.git_aliases.zsh (editable directly,
# without opening machinekit's config dir), sourced by an env.zsh.d snippet.

git_aliases::requires() { printf 'zsh\n'; }
