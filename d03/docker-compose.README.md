# Docker Compose Configuration for d03

This directory contains the docker-compose configuration for d03, which uses docker-compose (v2) for container management instead of shell scripts.

## Overview

**d03 is a greenfield opportunity** and serves as the **base template** for future docker hosts. This docker-compose setup addresses key pain points:

- **Better backup coordination**: Automated, efficient backup process
- **Network segmentation**: Security isolation for internet-facing services
- **Coordinated start/stop**: Proper dependency management
- **Resource efficiency**: CPU and memory limits
- **Security hardening**: Least privilege, isolation, monitoring

## Architecture

### Network Segmentation

Three networks for security isolation:

1. **internet** - For services exposed to internet (swag, etc.)
   - Isolated from internal services
   - Limits blast radius of compromise

2. **internal** - For internal-only services
   - Not exposed to internet
   - Can communicate with backend services

3. **backend** - For database/backend services
   - Most isolated
   - Only accessible from internal services

### Storage

- **iSCSI** (`/mnt/docker`): Container data storage
  - Avoids NFS file locking issues with SQLite
  - Fast, local-like performance
  - Data is host-specific

- **NFS** (`/mnt/nas/data1/docker`, `/mnt/nas/data2/docker`): Backup storage
  - Backups from iSCSI → NFS
  - Resilient storage for recovery

### Environment Variables

Common environment variables are defined in `~/scripts/docker/common.env`:

```bash
DOCKER_UID=1003
DOCKER_GID=1000
DOCKER_DL=/mnt/docker  # iSCSI
DOCKER_D1=/mnt/nas/data1/docker  # NFS
DOCKER_D2=/mnt/nas/data2/docker  # NFS
LOCAL_TZ="America/Chicago"
```

Reference these in docker-compose.yml using `${VARIABLE_NAME}` syntax.

## Usage

### Basic Commands

```bash
# Start all containers
docker compose up -d

# Stop all containers
docker compose down

# View logs
docker compose logs -f

# Restart a specific service
docker compose restart <service-name>

# Update and restart containers
docker compose pull
docker compose up -d
```

### Using Profiles

```bash
# Start only media containers
docker compose --profile media up -d

# Start only core services
docker compose --profile core up -d
```

### Managing Individual Services

```bash
# Start a specific service
docker compose up -d <service-name>

# Stop a specific service
docker compose stop <service-name>

# View logs for a service
docker compose logs -f <service-name>
```

## First Application: TC_datalogger

TC_datalogger (Torn City API → BigQuery) is the first application on d03. All build/run/maintain pieces live in this repo under `d03/apps/TC_datalogger/`; the app source is pulled from the [TC_datalogger repo](https://github.com/shepner/TC_datalogger) on the VM.

- **Working files**: `/mnt/docker/TC_datalogger/` (iSCSI) — subdirs match the app name; `repo/` is the git clone; each service has `config/` and `logs/`.
- **Backups**: tgz files in `/mnt/nas/data1/docker/` (e.g. `TC_datalogger-YYYYMMDD-HHMMSS.tgz`).
- **On d03**: One-time `provision.sh` (clone repo + create dirs), add credentials in each service’s `config/`, then:
  ```bash
  ~/scripts/d03/apps/TC_datalogger/tc_datalogger.sh up
  ```
- **Backup / update / refresh / rebuild**:
  - `tc_datalogger.sh backup` — tgz to NFS
  - `tc_datalogger.sh update` — git pull, rebuild, up
  - `tc_datalogger.sh refresh` — rebuild and up
  - `tc_datalogger.sh rebuild` — full rebuild and up

See `~/scripts/d03/apps/TC_datalogger/README.md` for full steps. The root `docker-compose.yml` in `~/scripts/d03/` is for future shared/infrastructure containers.

## Adding New Containers (d03 docker-compose.yml)

1. **Copy the template service** from `docker-compose.yml`
2. **Choose appropriate network**:
   - `internet` - If exposed to internet
   - `internal` - If internal-only
   - `backend` - If database/backend service
3. **Set storage path**: Use `${DOCKER_DL}/<service-name>` for container data
4. **Add dependencies**: Use `depends_on` with `condition: service_healthy`
5. **Set resource limits**: CPU and memory constraints
6. **Add healthcheck**: If service supports it
7. **Apply security hardening**: Non-root user, read-only where possible

## Backup Strategy

**Current approach** (to be improved):
- Manual backups using `tar -czf` (slow, cumbersome)

**Planned improvement**:
- Automated backup service in compose
- rsync-based backups (faster, incremental)
- Parallel backups (multiple containers simultaneously)
- Backup coordination with compose profiles

## Security Best Practices

1. **Network Isolation**: Internet-facing services isolated from internal
2. **Least Privilege**: Non-root users, minimal capabilities
3. **Resource Limits**: CPU/memory constraints to limit impact
4. **Healthchecks**: Monitor service health
5. **Read-only Filesystems**: Where possible
6. **No Privileged Mode**: Unless absolutely necessary

## Troubleshooting

### Container won't start
- Check logs: `docker compose logs <service-name>`
- Verify dependencies: `docker compose ps`
- Check network connectivity: `docker network ls`

### Backup issues
- Verify NFS mounts: `mount | grep nfs`
- Check iSCSI connection: `iscsiadm -m session`
- Verify storage paths: `ls -la /mnt/docker`

### Network issues
- Verify network isolation: `docker network inspect d03_internet`
- Check service dependencies: `docker compose config`

## Related Documentation

- [Docker Compose Documentation](https://docs.docker.com/compose/)
- [Docker Security Best Practices](https://docs.docker.com/engine/security/)
- [d03 README](../README.md)

