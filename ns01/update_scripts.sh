#!/bin/bash
# Update Docker scripts from repository
# Uses sparse git checkout to get only needed files, then mirrors them into
# ~/scripts/<host>/ and ~/scripts/docker/.
#
# Source: private GitLab asyla/asyla-hosts, read with the deploy token in /etc/asyla/asyla-hosts.env
# (root, 0600; ASYLA_HOSTS_DEPLOY_USER / ASYLA_HOSTS_DEPLOY_TOKEN). git gets it from a credential
# helper that reads that file, so the token is never in argv, a URL or a git config.
#
# Mirror rule: a path under ~/scripts/<host>/ or ~/scripts/docker/ is deleted
# unless the repo tracks it or one of the repo's .gitignore files matches it.
# .gitignore is the preserve list: secrets (*.env), runtime files (__pycache__/)
# and anything a later ns01/apps/.gitignore names (none today: no other repo deploys here).
#
# The same script as d01-d03's. It replaces the GitHub updater (public shepner/asyla, with an
# overlay from GitLab asyla/pihole that never ran: its token file was never put on the host).
#
# Usage: update_scripts.sh [--dry-run]
#   --dry-run  list what would be deleted and what is preserved; change nothing

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

DRY_RUN=false
for arg in "$@"; do
    case "$arg" in
        --dry-run|-n) DRY_RUN=true ;;
        -h|--help) sed -n '2,14p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) log_error "Unknown argument: $arg"; exit 1 ;;
    esac
done

if [ "$EUID" -ne 0 ]; then
    exec sudo "$0" "$@"
fi

REPO_URL="${ASYLA_HOSTS_REPO_URL:-https://gitlab.com/asyla/asyla-hosts.git}"
DEPLOY_ENV="/etc/asyla/asyla-hosts.env"
HOSTNAME=$(hostname -s)
TARGET_USER="docker"
TARGET_HOME="/home/$TARGET_USER"
TARGET_SCRIPTS="$TARGET_HOME/scripts"
TMPDIR_ROOT=$(mktemp -d)
WORKDIR="$TMPDIR_ROOT/repo"
trap 'cd /; rm -rf "$TMPDIR_ROOT"' EXIT

log_info "Updating scripts from repository..."

if [ ! -r "$DEPLOY_ENV" ]; then
    log_error "$DEPLOY_ENV is missing: it holds the read-only deploy token (installed by the host build)"
    exit 1
fi

log_info "Cloning repository (sparse checkout) from $REPO_URL..."
# Every git call below (the clone and the checkouts' lazy blob fetches) resets inherited
# credential helpers, then answers from DEPLOY_ENV.
export GIT_TERMINAL_PROMPT=0 GIT_CONFIG_COUNT=2
export GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0=
export GIT_CONFIG_KEY_1=credential.helper
export GIT_CONFIG_VALUE_1="!f() { test \"\$1\" = get || return 0; . $DEPLOY_ENV; echo username=\$ASYLA_HOSTS_DEPLOY_USER; echo password=\$ASYLA_HOSTS_DEPLOY_TOKEN; }; f"
git clone -q --depth 1 --no-checkout --filter=blob:none "$REPO_URL" "$WORKDIR"

cd "$WORKDIR"

# checkout_tree <tree>: check out <tree> from master, or warn if master has no such directory.
# A checkout that fails or comes out incomplete stops the run before anything is pruned: on
# 2026-10-07 a checkout of docker/ broke partway (blobs are fetched lazily), the old
# `|| log_warn` carried on, prune_tree deleted 45 host files, and cp put back only the 14
# written before the break.
checkout_tree() {
    local tree="$1" want have
    if [ -z "$(git ls-tree -d --name-only master -- "$tree")" ]; then
        log_warn "No $tree directory found in repository"
        return 0
    fi
    if ! git checkout master -- "$tree"; then
        log_error "Checkout of $tree failed; stopping before anything is pruned or installed"
        exit 1
    fi
    want=$(git ls-tree -r --name-only master -- "$tree" | wc -l)
    have=$(git ls-files -- "$tree" | while IFS= read -r f; do [ -e "$f" ] || [ -L "$f" ] && echo "$f"; done | wc -l)
    if [ "$want" -ne "$have" ]; then
        log_error "Checkout of $tree is incomplete ($have of $want files); stopping before anything is pruned or installed"
        exit 1
    fi
}

log_info "Checking out host-specific scripts ($HOSTNAME)..."
checkout_tree "$HOSTNAME"

log_info "Checking out docker scripts..."
checkout_tree docker

# Not optional: the root .gitignore holds the *.env / secret patterns that keep
# host-local secrets from being pruned below.
git checkout master -- .gitignore

# Delete everything under $TARGET_SCRIPTS/<tree> that the repo neither tracks nor ignores.
# Only runs for trees present in the clone, so a missing checkout never empties a host dir.
prune_tree() {
    local tree="$1"
    local host_list="$TMPDIR_ROOT/$tree.host" repo_list="$TMPDIR_ROOT/$tree.repo"
    local untracked="$TMPDIR_ROOT/$tree.untracked" ignored="$TMPDIR_ROOT/$tree.ignored"
    local doomed="$TMPDIR_ROOT/$tree.delete" rc=0 path dir

    [ -d "$WORKDIR/$tree" ] && [ -d "$TARGET_SCRIPTS/$tree" ] || return 0

    (cd "$TARGET_SCRIPTS" && find "$tree" \( -type f -o -type l \) -print0) | sort -z > "$host_list"
    git -C "$WORKDIR" ls-files -z -- "$tree" | sort -z > "$repo_list"
    comm -z -23 "$host_list" "$repo_list" > "$untracked"

    # check-ignore exits 1 when nothing matches; anything above that is a real failure.
    git -C "$WORKDIR" check-ignore --no-index -z --stdin < "$untracked" > "$ignored" || rc=$?
    if [ "$rc" -gt 1 ]; then
        log_error "git check-ignore failed for $tree; not pruning"
        return 1
    fi
    sort -z -o "$ignored" "$ignored"
    comm -z -23 "$untracked" "$ignored" > "$doomed"

    while IFS= read -r -d '' path; do
        if $DRY_RUN; then
            echo "  would delete: $TARGET_SCRIPTS/$path"
        else
            rm -f "$TARGET_SCRIPTS/$path"
            echo "  deleted (not in repo): $TARGET_SCRIPTS/$path"
            # Remove directories this left empty (rmdir refuses non-empty ones).
            dir=$(dirname "$path")
            while [ "$dir" != "$tree" ] && [ "$dir" != "." ] && rmdir "$TARGET_SCRIPTS/$dir" 2>/dev/null; do
                dir=$(dirname "$dir")
            done
        fi
    done < "$doomed"

    local n_preserved n_doomed
    n_preserved=$(tr -cd '\0' < "$ignored" | wc -c)
    n_doomed=$(tr -cd '\0' < "$doomed" | wc -c)
    log_info "$TARGET_SCRIPTS/$tree: $n_doomed path(s) not in repo$($DRY_RUN && echo ' (dry run)')"
    if $DRY_RUN; then
        while IFS= read -r -d '' path; do
            echo "  preserve (gitignored): $TARGET_SCRIPTS/$path"
        done < "$ignored"
    elif [ "$n_preserved" -gt 0 ]; then
        log_info "Preserved $n_preserved gitignored path(s) under $TARGET_SCRIPTS/$tree (--dry-run lists them)"
    fi
}

log_info "Pruning files no longer in the repository..."
mkdir -p "$TARGET_SCRIPTS"
prune_tree "$HOSTNAME"
prune_tree docker

if $DRY_RUN; then
    log_info "Dry run: nothing changed."
    exit 0
fi

log_info "Installing scripts to $TARGET_SCRIPTS and $TARGET_HOME..."
if [ -d "$WORKDIR/$HOSTNAME" ]; then
    cp -r "$WORKDIR/$HOSTNAME" "$TARGET_SCRIPTS/"
    # IMPORTANT: use install(1), not cp, because update_scripts.sh is itself
    # one of the files being replaced. cp truncates the destination inode
    # in place, which corrupts the running bash's open file descriptor and
    # produces "syntax error near unexpected token" mid-run. install(1)
    # writes to a tempfile and rename(2)s atomically, leaving our running
    # inode alone (bash keeps reading the original via its open fd).
    for f in update.sh update_scripts.sh update_all.sh; do
        if [ -f "$TARGET_SCRIPTS/$HOSTNAME/$f" ]; then
            install -m 744 -p "$TARGET_SCRIPTS/$HOSTNAME/$f" "$TARGET_HOME/$f"
        fi
    done
fi

# Install the shared docker/ tree (common.env, common.sh, backup_all.sh, etc.).
if [ -d "$WORKDIR/docker" ]; then
    cp -r "$WORKDIR/docker" "$TARGET_SCRIPTS/"
fi

if getent passwd "$TARGET_USER" >/dev/null 2>&1; then
    chown -R "$TARGET_USER:" "$TARGET_SCRIPTS" "$TARGET_HOME"/update.sh "$TARGET_HOME"/update_scripts.sh "$TARGET_HOME"/update_all.sh 2>/dev/null || true
fi
find "$TARGET_SCRIPTS" -name "*.sh" -exec chmod 744 {} \;
chmod 744 "$TARGET_HOME"/update.sh "$TARGET_HOME"/update_scripts.sh "$TARGET_HOME"/update_all.sh 2>/dev/null || true

if [ -f "$TARGET_SCRIPTS/$HOSTNAME/setup/setup_manual.sh" ]; then
    ln -sf "$TARGET_SCRIPTS/$HOSTNAME/setup/setup_manual.sh" "$TARGET_HOME/setup_manual.sh"
    chown -h "$TARGET_USER:" "$TARGET_HOME/setup_manual.sh" 2>/dev/null || true
fi

if [ -f "$TARGET_SCRIPTS/$HOSTNAME/setup/docker_bashrc_additions.sh" ]; then
    BASHRC="$TARGET_HOME/.bashrc"
    touch "$BASHRC"
    if ! grep -q 'docker_bashrc_additions.sh' "$BASHRC" 2>/dev/null; then
        echo "" >> "$BASHRC"
        echo "# History search (Up/Down by prefix) and completion - asyla ns01" >> "$BASHRC"
        echo '[ -f "$HOME/scripts/ns01/setup/docker_bashrc_additions.sh" ] && . "$HOME/scripts/ns01/setup/docker_bashrc_additions.sh"' >> "$BASHRC"
        log_info "Added history-search and completion to $BASHRC"
    fi
    chown "$TARGET_USER:" "$BASHRC" 2>/dev/null || true
fi

log_info "Scripts updated successfully! Setup scripts are in $TARGET_SCRIPTS/$HOSTNAME/setup/"
