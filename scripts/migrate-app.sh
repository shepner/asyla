#!/bin/sh
#
# Simple script to migrate a Docker app from one host to another
# Uses rsync to copy data from source iSCSI drive to destination iSCSI drive
#
# Usage:
#   ./migrate-app.sh <app-name> <source-host> <dest-host> [--dry-run] [--cleanup-source]
#
# Example:
#   ./migrate-app.sh sonarr d01 d03
#   ./migrate-app.sh sonarr d01 d03 --dry-run
#   ./migrate-app.sh sonarr d01 d03 --cleanup-source
#
# Prerequisites:
#   - SSH access to both hosts (as docker user)
#   - SSH keys configured for docker user on all hosts (see setup scripts)
#   - sudo/doas access on both hosts
#   - rsync installed on both hosts
#   - Source host: sudo/doas access to rsync command (add to sudoers/doas.conf)
#   - Destination host: doas/sudo access to create directories
#

APP_NAME="${1}"
SOURCE_HOST="${2}"
DEST_HOST="${3}"

if [ -z "${APP_NAME}" ] || [ -z "${SOURCE_HOST}" ] || [ -z "${DEST_HOST}" ]; then
    echo "Usage: $0 <app-name> <source-host> <dest-host> [--dry-run] [--cleanup-source]"
    echo ""
    echo "Example: $0 sonarr d01 d03"
    echo ""
    echo "Options:"
    echo "  --dry-run         Show what would be done without actually doing it"
    echo "  --cleanup-source  Stop and remove container from source after migration"
    exit 1
fi

# Parse flags
DRY_RUN=false
CLEANUP_SOURCE=false
USE_COMPOSE=false
for arg in "$@"; do
    case "$arg" in
        --dry-run)
            DRY_RUN=true
            ;;
        --cleanup-source)
            CLEANUP_SOURCE=true
            ;;
    esac
done

USER="docker"
SOURCE_PATH="/mnt/docker/${APP_NAME}"
DEST_PATH="/mnt/docker/${APP_NAME}"

echo "=========================================="
echo "Migrating ${APP_NAME} from ${SOURCE_HOST} to ${DEST_HOST}"
if [ "${DRY_RUN}" = "true" ]; then
    echo "DRY RUN MODE - No changes will be made"
fi
echo "=========================================="
echo ""

# Step 1: Check if container exists on source
echo "Step 1: Checking source host (${SOURCE_HOST})..."
if ssh "${USER}@${SOURCE_HOST}" "doas docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q '^${APP_NAME}$' || docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q '^${APP_NAME}$'" 2>/dev/null; then
    echo "  ✓ Container ${APP_NAME} found on ${SOURCE_HOST}"
    USE_COMPOSE=false
else
    echo "  Container ${APP_NAME} not found via docker ps, checking docker-compose..."
    if ssh "${USER}@${SOURCE_HOST}" "test -f ~/scripts/d03/docker-compose.yml && docker compose ps --format json 2>/dev/null | grep -q '\"${APP_NAME}\"' || test -f ~/scripts/d03/apps/${APP_NAME}/compose.yml" 2>/dev/null; then
        echo "  ✓ Found docker-compose configuration"
        USE_COMPOSE=true
    else
        echo "  ✗ Container not found. Exiting."
        exit 1
    fi
fi

# Step 2: Stop container on source
echo ""
echo "Step 2: Stopping container on source..."
if [ "${DRY_RUN}" = "true" ]; then
    echo "  [DRY RUN] Would stop container ${APP_NAME} on ${SOURCE_HOST}"
else
    if [ "${USE_COMPOSE}" = "true" ]; then
        echo "  Stopping via docker-compose..."
        ssh "${USER}@${SOURCE_HOST}" "cd ~/scripts/d03 && docker compose stop ${APP_NAME} 2>/dev/null || cd ~/scripts/d03/apps/${APP_NAME} && docker compose stop 2>/dev/null || true"
    else
        echo "  Stopping container..."
        ssh "${USER}@${SOURCE_HOST}" "doas docker stop ${APP_NAME} 2>/dev/null || docker stop ${APP_NAME} 2>/dev/null || true"
    fi
    sleep 2
    echo "  ✓ Container stopped"
fi

# Step 3: Verify source path exists
echo ""
echo "Step 3: Verifying source data path..."
if ssh "${USER}@${SOURCE_HOST}" "test -d ${SOURCE_PATH}" 2>/dev/null; then
    echo "  ✓ Source path exists: ${SOURCE_PATH}"
    # Get size for progress indication
    SIZE=$(ssh "${USER}@${SOURCE_HOST}" "du -sh ${SOURCE_PATH} 2>/dev/null | cut -f1" || echo "unknown")
    echo "  Size: ${SIZE}"
else
    echo "  ✗ Source path does not exist: ${SOURCE_PATH}"
    echo "  Please verify the app name and path."
    exit 1
fi

# Step 4: Create destination directory
echo ""
echo "Step 4: Preparing destination host (${DEST_HOST})..."
if [ "${DRY_RUN}" = "true" ]; then
    echo "  [DRY RUN] Would create ${DEST_PATH} on ${DEST_HOST}"
else
    ssh "${USER}@${DEST_HOST}" "doas mkdir -p ${DEST_PATH} && doas chown -R docker:asyla ${DEST_PATH} || sudo mkdir -p ${DEST_PATH} && sudo chown -R docker:asyla ${DEST_PATH}" 2>/dev/null || true
    echo "  ✓ Destination directory prepared"
fi

# Step 5: Sync data using rsync
echo ""
echo "Step 5: Syncing data from ${SOURCE_HOST} to ${DEST_HOST}..."
echo "  This may take a while depending on data size..."
if [ "${DRY_RUN}" = "true" ]; then
    echo "  [DRY RUN] Would run rsync to copy:"
    echo "    From: ${USER}@${SOURCE_HOST}:${SOURCE_PATH}/"
    echo "    To:   ${USER}@${DEST_HOST}:${DEST_PATH}/"
    # Show what would be copied
    ssh "${USER}@${SOURCE_HOST}" "sudo rsync --dry-run --itemize-changes -a ${SOURCE_PATH}/ /tmp/migrate-test/ 2>&1 | head -30" || \
    ssh "${USER}@${SOURCE_HOST}" "doas rsync --dry-run --itemize-changes -a ${SOURCE_PATH}/ /tmp/migrate-test/ 2>&1 | head -30" || \
    echo "  (Could not preview - will proceed with actual sync)"
else
    # Use rsync on source host to push to destination host
    # This requires rsync on source host and SSH access from source to destination
    if ssh "${USER}@${SOURCE_HOST}" "sudo rsync --version >/dev/null 2>&1" 2>/dev/null; then
        # Run rsync on source host, using sudo to access the files
        ssh "${USER}@${SOURCE_HOST}" "sudo rsync --progress -a -e ssh ${SOURCE_PATH}/ ${USER}@${DEST_HOST}:${DEST_PATH}/" || {
            echo "  ✗ rsync failed with sudo, trying doas..."
            ssh "${USER}@${SOURCE_HOST}" "doas rsync --progress -a -e ssh ${SOURCE_PATH}/ ${USER}@${DEST_HOST}:${DEST_PATH}/" || {
                echo "  ✗ rsync failed. Trying direct rsync..."
                ssh "${USER}@${SOURCE_HOST}" "rsync --progress -a -e ssh ${SOURCE_PATH}/ ${USER}@${DEST_HOST}:${DEST_PATH}/" || {
                    echo "  ✗ rsync failed. Please check permissions and connectivity."
                    echo "  Note: Source host must be able to SSH to destination host as docker user."
                    exit 1
                }
            }
        }
    elif ssh "${USER}@${SOURCE_HOST}" "doas rsync --version >/dev/null 2>&1" 2>/dev/null; then
        ssh "${USER}@${SOURCE_HOST}" "doas rsync --progress -a -e ssh ${SOURCE_PATH}/ ${USER}@${DEST_HOST}:${DEST_PATH}/" || {
            echo "  ✗ rsync failed. Trying direct rsync..."
            ssh "${USER}@${SOURCE_HOST}" "rsync --progress -a -e ssh ${SOURCE_PATH}/ ${USER}@${DEST_HOST}:${DEST_PATH}/" || {
                echo "  ✗ rsync failed. Please check permissions and connectivity."
                echo "  Note: Source host must be able to SSH to destination host as docker user."
                exit 1
            }
        }
    else
        # Fallback: direct rsync if user has access
        ssh "${USER}@${SOURCE_HOST}" "rsync --progress -a -e ssh ${SOURCE_PATH}/ ${USER}@${DEST_HOST}:${DEST_PATH}/" || {
            echo "  ✗ rsync failed. Please check permissions and connectivity."
            echo "  Note: Source host must be able to SSH to destination host as docker user."
            exit 1
        }
    fi
    echo "  ✓ Data sync complete"
fi

# Step 6: Set permissions on destination
echo ""
echo "Step 6: Setting permissions on destination..."
if [ "${DRY_RUN}" = "true" ]; then
    echo "  [DRY RUN] Would set ownership to docker:asyla"
else
    ssh "${USER}@${DEST_HOST}" "doas chown -R docker:asyla ${DEST_PATH} || sudo chown -R docker:asyla ${DEST_PATH}" 2>/dev/null || true
    echo "  ✓ Permissions set"
fi

# Step 7: Start container on destination (if requested)
echo ""
echo "Step 7: Starting container on destination..."
if [ "${DRY_RUN}" = "true" ]; then
    echo "  [DRY RUN] Would start container ${APP_NAME} on ${DEST_HOST}"
    echo "  [DRY RUN] You would need to manually start it:"
    echo "    ssh ${USER}@${DEST_HOST} 'cd ~/scripts/d03 && docker compose up -d ${APP_NAME}'"
    echo "    OR"
    echo "    ssh ${USER}@${DEST_HOST} '~/scripts/docker/${APP_NAME}.sh'"
else
    echo "  Note: You need to start the container manually on ${DEST_HOST}"
    echo "  For docker-compose:"
    echo "    ssh ${USER}@${DEST_HOST} 'cd ~/scripts/d03 && docker compose up -d ${APP_NAME}'"
    echo "  For shell scripts:"
    echo "    ssh ${USER}@${DEST_HOST} '~/scripts/docker/${APP_NAME}.sh'"
fi

# Step 8: Cleanup source (if requested)
if [ "${CLEANUP_SOURCE}" = "true" ]; then
    echo ""
    echo "Step 8: Cleaning up source host..."
    if [ "${DRY_RUN}" = "true" ]; then
        echo "  [DRY RUN] Would remove container ${APP_NAME} from ${SOURCE_HOST}"
    else
        if [ "${USE_COMPOSE}" = "true" ]; then
            ssh "${USER}@${SOURCE_HOST}" "cd ~/scripts/d03 && docker compose rm -f ${APP_NAME} 2>/dev/null || cd ~/scripts/d03/apps/${APP_NAME} && docker compose down 2>/dev/null || true"
        else
            ssh "${USER}@${SOURCE_HOST}" "doas docker rm -f ${APP_NAME} 2>/dev/null || docker rm -f ${APP_NAME} 2>/dev/null || true"
        fi
        echo "  ✓ Container removed from source"
        echo "  Note: Data still exists at ${SOURCE_PATH} on ${SOURCE_HOST}"
        echo "  You can manually delete it after verifying the migration."
    fi
fi

echo ""
echo "=========================================="
echo "Migration complete!"
if [ "${DRY_RUN}" = "false" ]; then
    echo ""
    echo "Next steps:"
    echo "1. Start the container on ${DEST_HOST}"
    echo "2. Verify the application works correctly"
    echo "3. Update any DNS/proxy configurations if needed"
    if [ "${CLEANUP_SOURCE}" != "true" ]; then
        echo "4. After verification, you can stop/remove the container on ${SOURCE_HOST}"
    fi
fi
echo "=========================================="
