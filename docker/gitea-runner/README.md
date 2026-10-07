# gitea-runner (d01, d02, d03)

A native Gitea Actions runner (`gitea-runner` 4.1.0, systemd) on each Docker host. Jobs run **on
the host** as `docker` (passwordless sudo, docker group), so asyla workflows can manage the hosts.
It is registered **instance-wide** with the labels `asyla`, `<host>` and `docker`, all host mode
(hub ADR-010, ADR-011; a workflow never asks for `asyla` alone).

The files live here once. Each host's `apps/gitea-runner/gitea-runner.sh` is a symlink to
`gitea-runner.sh`, so `update_all.sh` and host-maintenance find it like any other app.

| What | Where |
| --- | --- |
| Script | `~/scripts/<host>/apps/gitea-runner/gitea-runner.sh` → `~/scripts/docker/gitea-runner/gitea-runner.sh` |
| Binary | `/usr/local/bin/gitea-runner` (pinned version, sha256 checked on install) |
| Service | `gitea-runner.service` (`User=docker`), unit from this folder |
| Data | `/var/lib/gitea-runner`: `.runner` (the runner's credential, 0600) and `config.yaml` (rendered by `install` with this host's labels) |
| Job workspaces | `~docker/.cache/act` (runner default) |

## What a job gets

`git`, `python3` (3.13 on Debian 13), `node` (Debian `nodejs`, installed by `install`; JavaScript
actions such as `actions/checkout` need it), `docker`, and `sudo`. One job at a time per host
(`capacity: 1`).

A job runs inside the service, so stopping the service ends it after `shutdown_timeout` (10 min).
Work that must outlive the runner (a reboot, restarting this runner) has to leave the service's
cgroup, e.g. `sudo systemd-run --unit=<name> <command>`, and report back another way.

## Safety

- Any account on the Gitea instance can write a workflow that runs here as `docker`, which is root
  in effect. Keep Gitea registration closed and the accounts trusted.
- The registration token is read from stdin by `register` and passed to `gitea-runner` as an
  environment variable. It is never printed, stored, or written to a file.

## Install or re-install

Run from the asyla hub, not by hand: `tools/install_gitea_runners.py` (runbook
`runbooks/gitea-runners.md` in the asyla hub). By hand, on the host:

```bash
~/update_scripts.sh
~/scripts/$(hostname -s)/apps/gitea-runner/gitea-runner.sh install register up   # prompts for the token, hidden
~/scripts/$(hostname -s)/apps/gitea-runner/gitea-runner.sh status
```

## Changing labels or the version

Edit `RUNNER_LABELS` or `RUNNER_VERSION` + `RUNNER_SHA256` in `gitea-runner.sh`, deploy, then
`gitea-runner.sh refresh`. The daemon reads labels from `config.yaml`, so no re-registration.

## Removing a runner

`gitea-runner.sh down`, delete `/var/lib/gitea-runner/.runner`, then delete the runner in Gitea
(Site Administration → Actions → Runners). Without the last step a stale offline entry stays.
