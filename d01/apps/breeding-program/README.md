# breeding-program (d01)

Dog breeding / whelping app (source: `gitea.asyla.org/asyla/breeding-program`, private). FastAPI container,
data in BigQuery (GCP project `breeding-program`), sign-in by **Cloudflare Access** (JWT verified in-app).

- Public: `https://breeding-program.asyla.org` through `cloudflared-d01` on `breeding_program_net`.
- **LAN** (owner decision 2026-09-28): Pi-hole points the same hostname at d01, and `caddy-internal-d01`
  (`asyla/projects/internal-access`, `hosts/d01/Caddyfile`) adds `X-Asyla-Lan-Auth: <secrets/lan-trust-secret>`.
  The app signs those requests in as `LAN_TRUST_EMAIL` without Cloudflare. Everyone on the LAN is that person.
  The same secret goes in `/mnt/docker/internal-proxy/.env` as `BREEDING_PROGRAM_LAN_SECRET`.
- Its own Access application (`breeding-program`, one-time PIN, email allow list, 1-month session). `access: false`
  in `../cloudflared/apps.yml` keeps it out of the shared "d01 media" app.

## Files

| Where | What |
|---|---|
| `compose.yml` | Read-only container, all caps dropped, runs as the docker user, no published ports |
| `breeding-program.sh` | `init`, `check`, `build`, `up`, `down`, `restart`, `verify`, `backup`, `logs` |
| `app.env.example` | Copied to `/mnt/docker/breeding-program/app.env` (mode 600) by `init` |
| `push-source.sh` | **Workstation**: ships the repo's committed HEAD to `/mnt/docker/breeding-program/src` |
| `cloudflare-access.py` | **On d01**: Access app + policy (prints `CF_ACCESS_AUD`); `--publish` adds ingress + DNS |
| `/mnt/docker/internal-proxy/.env` | `BREEDING_PROGRAM_LAN_SECRET` for caddy-internal-d01 (copy of `lan-trust-secret`; lives only on d01, `deploy.sh` never touches it) |
| `/mnt/docker/breeding-program/secrets/` | `gcp-sa.json`, `session-secret`, `lan-trust-secret` (mode 600, owner docker) |

## First deploy

```bash
# workstation
~/local/personal/projects/asyla/d01/apps/breeding-program/push-source.sh
# d01
~/scripts/d01/apps/breeding-program/breeding-program.sh init build
# service-account key (breeding-program-app@breeding-program.iam.gserviceaccount.com) -> secrets/gcp-sa.json, chmod 600
python3 ~/scripts/d01/apps/breeding-program/cloudflare-access.py --email you@example.com   # prints CF_ACCESS_AUD
#   put CF_ACCESS_AUD=… in /mnt/docker/breeding-program/app.env
~/scripts/d01/apps/breeding-program/breeding-program.sh up verify
python3 ~/scripts/d01/apps/breeding-program/cloudflare-access.py --email you@example.com --publish  # go live
~/scripts/d01/apps/breeding-program/breeding-program.sh verify
```

Changing who can sign in: re-run `cloudflare-access.py` with the **full** list of `--email`s (it replaces the
list). The app's own kennel invites still decide what each signed-in person can see.

## Updating

```bash
push-source.sh                                   # workstation, after committing
~/scripts/d01/apps/breeding-program/breeding-program.sh build restart verify   # d01
```

Before deploying a schema change, apply it to BigQuery first (`scripts/bq/apply_schema.py` in the app repo).

## Notes

- `cloudflared-d01` runs from `../cloudflared` in token mode (remote config). `up` connects it to
  `breeding_program_net` live; the cloudflared compose lists the network so it survives a recreate.
- `../cloudflared/setup-tunnel-api.py` **replaces** the whole ingress list from `../cloudflared/apps.yml`;
  this app is listed there so a re-run keeps it.
- `verify` checks two paths after `/healthz`: **public**, pinned (`curl --resolve`) to the Cloudflare IP from public
  DNS (`dig @1.1.1.1`, or Cloudflare DNS-over-HTTPS when `dig` is missing), which must 302 to
  `asyla.cloudflareaccess.com`; and **LAN**, the normal lookup (split DNS → d01 → `caddy-internal-d01`), which must
  answer 200. Either mismatch prints a `[WARN]`.
- Backups (`backup`): rsync snapshots of the app dir (env + secrets) to `${DOCKER_D1}/breeding-program`.
  The data itself is in BigQuery.
