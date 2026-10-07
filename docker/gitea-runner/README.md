# gitea-runner (d01, d02, d03)

A Gitea Actions runner (`docker.io/gitea/runner:4.1.0`) on each Docker host. It is registered
**instance-wide** with the labels `asyla`, `<host>` and `docker`, and runs every job in a
`node:24-bookworm` container (hub ADR-010 and ADR-011: site label `asyla`, host, capability; a
workflow never asks for `asyla` alone).

The files live here once. Each host's `apps/gitea-runner/gitea-runner.sh` is a symlink to
`gitea-runner.sh`, so `update_all.sh` and host-maintenance find it like any other app.

| What | Where |
| --- | --- |
| Script | `~/scripts/<host>/apps/gitea-runner/gitea-runner.sh` → `~/scripts/docker/gitea-runner/gitea-runner.sh` |
| Data | `/mnt/docker/GiteaRunner/data`: `.runner` (the runner's credential, 0600) and `config.yaml` (copied from here by `up`) |
| Container | `gitea-runner`, `restart: unless-stopped` |

## Safety

- Jobs run in containers, never on the host (no `:host` labels).
- Jobs do not get the host's Docker socket (`container.docker_host: "-"`), cannot be privileged,
  and cannot bind-mount host paths (`valid_volumes: []`). Only the runner container has the socket.
- The registration token is read from stdin by `register` and passed to `gitea-runner` as an
  environment variable. It is never printed, stored, or in the compose file.

## Install or re-install

Run from the asyla hub, not by hand: `tools/install_gitea_runners.py` (runbook
`runbooks/gitea-runners.md` in the asyla hub). It syncs this repo onto the host, registers with an
instance token generated on d03, and starts the runner. By hand, on the host:

```bash
~/update_scripts.sh
~/scripts/$(hostname -s)/apps/gitea-runner/gitea-runner.sh register up   # prompts for the token, hidden
~/scripts/$(hostname -s)/apps/gitea-runner/gitea-runner.sh status
```

## Changing labels or the job image

Edit `JOB_IMAGE` or the label lines in `gitea-runner.sh`, deploy, then `gitea-runner.sh restart`. The
image's entrypoint passes the labels to the daemon, so they update without re-registering.

## Removing a runner

`gitea-runner.sh down`, delete `/mnt/docker/GiteaRunner/data/.runner`, then delete the runner in
Gitea (Site Administration → Actions → Runners). Without the last step a stale offline entry stays.
