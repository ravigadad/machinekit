#!/usr/bin/env bash
# git_aliases module — ships the git alias/function library.
# Template-only: the aliases land at ~/.git_aliases.zsh (editable directly,
# without opening machinekit's config dir), sourced by an env.zsh.d snippet.

git_aliases::requires() { printf 'zsh\n'; }

git_aliases::postflight_info() {
  printf 'Git aliases and helper functions installed at ~/.git_aliases.zsh.\n'
}

git_aliases::postflight_instructions() {
  printf "See what is available: run 'alias' in a new shell, or read ~/.git_aliases.zsh.\n"
  printf "The aliases are adapted from oh-my-zsh's git plugin, whose README documents them: https://github.com/ohmyzsh/ohmyzsh/tree/master/plugins/git\n"
}
