# ci01 apps

ci01 is theOrg's heavy CI host (asyla #1237): a Gitea runner in docker mode (`[runner]` in
`ci01/host.toml`) and one app beside it, the Docker Hub pull-through cache its daemon uses. Nothing on
ci01 serves people, and it holds no other system's keys.

The app uses the same management pattern as the other hosts' apps: a script accepting **up**,
**down**, **restart**, **backup**, **update**, **refresh**, and **logs**. `~/update_all.sh` discovers
every directory under `~/scripts/ci01/apps/` and runs `backup` then `update` on each.

**backup** keeps nothing: ci01 has no NAS mount (no `nfs.sh` step), and its only app's data is a cache
that refills from pulls (`restore = false` in `ci01/host.toml`).

## Owned by this repo

Deployed by `update_scripts.sh`, which mirrors `ci01/` into `~/scripts/ci01/`: files this repo no
longer has are deleted on the host unless a repo `.gitignore` matches them (`*.env` secrets,
`__pycache__/`). No other repo deploys onto ci01, so `apps/.gitignore` lists no folder.

| App | Script | Notes |
|-----|--------|-------|
| **registry-mirror** | `~/scripts/ci01/apps/registry-mirror/registry-mirror.sh` | Docker Hub pull-through cache (`registry:2` in proxy mode, anonymous) on `127.0.0.1:5000`, for ci01's own daemon only (`registry-mirrors`, theOrg #1195); no key; see its README |
| **gitea-runner** | `~/scripts/ci01/apps/gitea-runner/gitea-runner.sh` | A link to `docker/gitea-runner/gitea-runner.sh`; the build's runner phase installs and registers it (labels `theorg`, `ci`, `ci01`, docker mode) |
