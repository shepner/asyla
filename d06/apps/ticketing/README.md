# ticketing (d06)

theOrg's work board, Vikunja and vikunja-mcp, moved from the Mac Mini. asyla deploys it here from
theOrg ticketing `DEPLOY.md` (main `041215a`, the #19 merge; its tree equals #19's head `89d6369`);
theOrg's own `deploy.yml` does not target d06.

- `compose.yml`: what any host runs, a replica included; nothing in it reaches the vault. DEPLOY.md's
  example with the network named `ticketing_net` (internal-access `hosts/d06` joins it), vikunja
  published on `127.0.0.1:3456` only and vikunja-mcp not published.
- `compose.vault.yml`: added by `ticketing.sh` on d06 only: `vikunja-jwt`, `configure`, Vikunja's
  JWT file on an in-memory volume, and the vault settings of vikunja-mcp. Never on a replica (its
  containers reach nothing off the host, and configure would overwrite production's token).
- No secret is in any file, here or on the host. On d06, `up`, `restart` and `configure` need the
  `svc-ticketing-deploy-a` and `svc-ticketing-mcp-a` Dex client values in the process environment
  (`TICKETING_DEPLOY_DEX_CLIENT_SECRET`, `TICKETING_MCP_DEX_CLIENT_SECRET`): the workstation
  resolves them from OpenBao at deploy (build_host.py `start_env`) and refuses to start without
  them. A replica runs vikunja alone, with no JWT setting.
- Images: pulled with the `theorg-registry` read:package token, which the workstation hands over
  at use (build_host.py `pull_token_env`, as `TICKETING_REGISTRY_PULL_TOKEN`); see `ticketing.sh`.
- Data: `/mnt/docker/Ticketing/{db,mcp-data,backup,vector}`. `db` is the system of record.
- Backup (nightly, only on the host `vikunja.asyla.org` resolves to): theOrg's backup image writes
  one checked copy to `backup/`, `verify` re-checks it, and it is mirrored to
  `/mnt/nas/data1/docker/Ticketing/mirror`; history is the NAS's snapshots. `restore` puts the
  mirror back into `backup/` and runs theOrg's restore into an empty `db/`. When `backup/SEED`
  exists (a copy seeded there by the asyla hub's `seed_ticketing.py`), `restore` takes `backup/`
  as it stands instead, only if its `STATUS` starts with `OK`, never reads the NAS mirror, and
  removes `SEED` after theOrg's restore passes; the next backup then writes the mirror.
- Names (internal-access `hosts/d06`, LAN only, over `ticketing_net`): `vikunja.asyla.org` and
  `vikunja-mcp.asyla.org` (bearer-guarded).
- Upgrade: change `TICKETING_TAG` in `ticketing.sh` to a theOrg `main` sha whose images are
  published, commit, then `ticketing.sh backup update up verify`.
