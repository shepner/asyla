#!/bin/bash
# Comprehensive maintenance for this host: update scripts, OS, then backup and upgrade
# each Docker app found under ~/scripts/<host>/apps/ (host = hostname -s, e.g. d03).
# Step 3 runs each app in a separate screen session (parallel, disconnect-safe); the
# main script polls until all complete. Run logs and per-app exit codes are written for auditing; use
# .cursor/helpers/audit_update_all.sh locally to check all hosts.

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

# Re-run as root if needed (for update_scripts.sh and update.sh)
if [ "$EUID" -ne 0 ]; then
    exec sudo "$0" "$@"
fi

if [ -n "${SUDO_USER:-}" ]; then
    HOME_DIR=$(getent passwd "$SUDO_USER" | cut -d: -f6)
else
    HOME_DIR="$HOME"
fi
HOME_DIR="${HOME_DIR:-/home/docker}"

# Host from hostname so apps path is correct even when script is run via symlink (e.g. ~/update_all.sh)
HOST="$(hostname -s)"
APPS_DIR="$HOME_DIR/scripts/$HOST/apps"

# Where to store run results (persistent for auditing)
LOG_BASE="${HOME_DIR}/logs/update_all"
RUN_ID="run_$(date +%Y%m%d_%H%M%S)"
RESULT_DIR="$LOG_BASE/$RUN_ID"

# Polling: interval (seconds) and max wait (seconds) for all apps to finish
POLL_INTERVAL=10
POLL_MAX=7200

log_info "Starting comprehensive system maintenance (host: $HOST)..."

# Step 1: Update scripts from repository
log_info "Step 1: Updating scripts from repository..."
"$HOME_DIR/update_scripts.sh"

# Step 2: Update OS
log_info "Step 2: Updating operating system..."
"$HOME_DIR/update.sh"

# Step 3: Backup and upgrade each Docker app in parallel (one screen per app)
if [ ! -d "$APPS_DIR" ]; then
    log_warn "No apps directory at $APPS_DIR, skipping app backup/upgrade."
else
    if ! command -v screen &>/dev/null; then
        log_warn "screen not found; running app backup/upgrade serially (no disconnect protection)."
    fi

    mkdir -p "$RESULT_DIR"
    chmod 1777 "$RESULT_DIR"
    RUN_LOG="$RESULT_DIR/run.log"
    {
        echo "host=$HOST"
        echo "run_id=$RUN_ID"
        echo "started=$(date -Iseconds)"
    } >> "$RUN_LOG"

    # Build list of (app, main_script) — same discovery as before (order and rules)
    APPS=()
    for app_dir in "$APPS_DIR"/*/; do
        [ -d "$app_dir" ] || continue
        app=$(basename "$app_dir")
        main_script=""
        for f in "$app_dir"*.sh; do
            [ -f "$f" ] || continue
            b=$(basename "$f")
            [[ "$b" == gen-* ]] && continue
            [[ "$b" == generate-* ]] && continue
            [[ "$b" == copy_* ]] && continue
            [[ "$b" == provision* ]] && continue
            main_script="$f"
            break
        done
        [ -n "$main_script" ] || continue
        APPS+=( "$app" "$main_script" )
    done

    if [ ${#APPS[@]} -eq 0 ]; then
        log_info "Step 3: No apps found under $APPS_DIR, skipping."
    else
        log_info "Step 3: Backing up and upgrading Docker apps in parallel (one screen per app)..."
        log_info "  Result dir: $RESULT_DIR (attach with: screen -r update_${HOST}_<app>)"

        i=0
        while [ $i -lt ${#APPS[@]} ]; do
            app="${APPS[$i]}"
            main_script="${APPS[$((i+1))]}"
            i=$((i+2))
            app_dir=$(dirname "$main_script")
            session_name="update_${HOST}_${app}"
            # Wrapper script so we don't fight quoting in screen; runs as SUDO_USER
            wrapper="$RESULT_DIR/._run_$app.sh"
            cat << WRAPPER_EOF > "$wrapper"
#!/bin/bash
cd $(printf '%s' "$app_dir" | sed "s/'/'\\\\''/g")
'$main_script' backup 2>/dev/null; b=\$?
'$main_script' update 2>/dev/null; u=\$?
[ \$u -ne 0 ] && { '$main_script' refresh 2>/dev/null; u=\$?; }
echo \$((b|u)) > $RESULT_DIR/$app.exit
WRAPPER_EOF
            chmod 755 "$wrapper"
            chown "${SUDO_USER:-root}" "$wrapper" 2>/dev/null || true
            if command -v screen &>/dev/null; then
                if [ -n "${SUDO_USER:-}" ]; then
                    su - "$SUDO_USER" -c "screen -S '$session_name' -dm '$wrapper'"
                else
                    screen -S "$session_name" -dm "$wrapper"
                fi
                log_info "  Started screen $session_name for $app"
            else
                ( su - "$SUDO_USER" -c "'$wrapper'" 2>/dev/null; true )
                log_info "  Completed $app (serial)"
            fi
        done

        total=$((${#APPS[@]} / 2))
        # Poll until all .exit files exist or timeout
        if command -v screen &>/dev/null; then
            elapsed=0
            while [ $elapsed -lt $POLL_MAX ]; do
                done_count=0
                for ((i=0; i<${#APPS[@]}; i+=2)); do
                    app="${APPS[$i]}"
                    [ -f "$RESULT_DIR/$app.exit" ] && done_count=$((done_count+1))
                done
                if [ "$done_count" -eq "$total" ]; then
                    log_info "  All $total app(s) finished."
                    break
                fi
                sleep "$POLL_INTERVAL"
                elapsed=$((elapsed + POLL_INTERVAL))
            done
            if [ $elapsed -ge $POLL_MAX ]; then
                log_warn "  Timeout (${POLL_MAX}s) waiting for apps; some screens may still be running."
            fi
        fi

        # Write summary and report
        summary="$RESULT_DIR/summary.txt"
        echo "host=$HOST" >> "$summary"
        echo "run_id=$RUN_ID" >> "$summary"
        echo "finished=$(date -Iseconds)" >> "$summary"
        echo "" >> "$summary"
        failed=0
        for ((i=0; i<${#APPS[@]}; i+=2)); do
            app="${APPS[$i]}"
            exit_file="$RESULT_DIR/$app.exit"
            if [ -f "$exit_file" ]; then
                code=$(cat "$exit_file")
                if [ "$code" = "0" ]; then
                    echo "  $app: OK" >> "$summary"
                    log_info "  $app: OK"
                else
                    echo "  $app: FAIL (exit $code)" >> "$summary"
                    log_warn "  $app: FAIL (exit $code)"
                    failed=$((failed+1))
                fi
            else
                echo "  $app: MISSING (no exit file)" >> "$summary"
                log_warn "  $app: MISSING (no exit file)"
                failed=$((failed+1))
            fi
        done
        echo "" >> "$summary"
        echo "total=$total failed=$failed" >> "$summary"

        # Symlink "latest" for audit script
        ln -sfn "$RUN_ID" "$LOG_BASE/latest" 2>/dev/null || true

        echo "finished=$(date -Iseconds)" >> "$RUN_LOG"
        echo "result_dir=$RESULT_DIR" >> "$RUN_LOG"
        if [ "$failed" -gt 0 ]; then
            log_warn "Step 3: $failed app(s) failed or missing. Run .cursor/helpers/audit_update_all.sh locally to audit."
        fi
    fi
fi

log_info "Comprehensive maintenance completed. Results: $RESULT_DIR"
