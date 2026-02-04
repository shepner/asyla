#!/bin/bash
# Purpose: Bash profile additions for docker user (d02): history search and completion.
# Usage: Source from ~/.bashrc; update_scripts.sh appends the source line if missing.
# - Up/Down: search history by current line prefix (e.g. type "docker" then Up to cycle matching commands).
# - Tab: normal readline completion; loads bash-completion if installed.

# Only run in interactive shells
[[ $- != *i* ]] && return

# History search by prefix (doskey-like): Up/Down use current line as search prefix
# Keycodes: \e[A / \e[B (xterm) and \e[OA / \e[OB (some vt)
if [[ -n "$BASH_VERSION" ]]; then
    bind '"\e[A": history-search-backward'  2>/dev/null || true
    bind '"\e[B": history-search-forward'   2>/dev/null || true
    bind '"\e[OA": history-search-backward' 2>/dev/null || true
    bind '"\e[OB": history-search-forward'  2>/dev/null || true
fi

# Optional: load bash-completion if installed (improves tab completion for commands)
if [[ -f /usr/share/bash-completion/bash_completion ]]; then
    . /usr/share/bash-completion/bash_completion 2>/dev/null || true
fi
