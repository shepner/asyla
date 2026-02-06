#!/bin/bash
# Purpose: Bash profile additions for docker user (ns01): history search and completion.
# Usage: Source from ~/.bashrc; update_scripts.sh appends the source line if missing.

# Only run in interactive shells
[[ $- != *i* ]] && return

if [[ -n "$BASH_VERSION" ]]; then
    bind '"\e[A": history-search-backward'  2>/dev/null || true
    bind '"\e[B": history-search-forward'   2>/dev/null || true
    bind '"\e[OA": history-search-backward' 2>/dev/null || true
    bind '"\e[OB": history-search-forward'  2>/dev/null || true
fi

if [[ -f /usr/share/bash-completion/bash_completion ]]; then
    . /usr/share/bash-completion/bash_completion 2>/dev/null || true
fi
