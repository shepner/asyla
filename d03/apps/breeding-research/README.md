# breeding-research on d03

FastAPI dog breeding research app. Data: **`/mnt/docker/breeding-research/`** (`gcp-credentials.json`, etc.).
Source: the breeding-research repo, private on Gitea (`https://gitea.asyla.org/personal/breeding-research.git`;
the GitLab copy `asyla/breeding-research` was archived on 2026-10-11 and gets no new commits). Its CI
(`.gitea/workflows/build.yml`) pushes `gitea.asyla.org/personal/breeding-research:<sha>` and `:latest`
from main and rebuilds them weekly; d03 runs `:latest`, pulled with d03's own login to that registry,
so a rebuilt host needs no source clone.

## Run

```bash
cp .env.example .env   # then fill in BQ_* and BASIC_AUTH_*
~/scripts/d03/apps/breeding-research/breeding-research.sh up verify
```

A deploy runs `up` with the Postgres password from OpenBao (below, Postgres):

```bash
cd ~/local/asyla && python3 core/tools/credentials.py exec BREEDING_RESEARCH_PG_PASSWORD -- \
  python3 projects/asyla-hosts/scripts/build_host.py d03 build --only apps --app breeding-research --apply
```

`up` and `restart` pull the image only when it is not on the host, so the app never moves to a new
image by itself (host-maintenance's rollback re-tags the old image, then runs `up`); `update` pulls
`latest`, and `refresh` pulls it, then runs `up`. host-maintenance's weekly apps run updates it.
Pin another image by hand with `BREEDING_RESEARCH_IMAGE_OVERRIDE=<ref>` in the call's environment.

A local build instead (`BREEDING_RESEARCH_PULL_OVERRIDE=0`): the source in `.src/breeding-research`
or `BREEDING_RESEARCH_SRC` (a clone of the private repo needs a read credential on d03); the image is
`breeding-research:local`, `up` builds it when it is missing, and `refresh` pulls the source
(`git pull --ff-only`), rebuilds, then runs `up`.

## Postgres

`breeding-research-postgres` (`postgres:16.16-bookworm`, pinned by digest in `compose.yml`) is the
central breed database (personal breeding-research plan central-breed-db, phase 1): role and
database `breeding_research`, data in `/mnt/docker/breeding-research/pg-data`, no host port. The app
reaches it on `breeding_research_net` through `DATABASE_URL`
(`postgresql://breeding_research:<password>@breeding-research-postgres:5432/breeding_research`),
which `breeding-research.sh` builds; compose gets both values by name only.

### Password

`BREEDING_RESEARCH_PG_PASSWORD`, stored in OpenBao (asyla hub `data/components.toml`
`[credentials.stored]`) and sent by a deploy over SSH stdin (`d03/host.toml` `start_env`), never a
file; it is not in `.env`. A run without it (host-maintenance's weekly `refresh` and its rollback's
`up`) takes the running container's own `POSTGRES_PASSWORD` (as d06 communications.sh does), so
`up`, `restart`, `rebuild` and `refresh` refuse only when neither exists. It must use only
`A-Za-z0-9._~-` (no URL encoding), e.g. 48 hex characters. Postgres reads `POSTGRES_PASSWORD` only
when it initialises an empty `pg-data`, so a value that differs from the running container's is
refused. To rotate: `ALTER ROLE breeding_research PASSWORD '...'` in the container first, then store
the new value and deploy.

### Backup, restore, restore test

- `backup` first runs `pg_dump -Fc` in the container (local socket, which the image trusts: no
  password) into `pgdump/breeding_research.dump.partial` (owner-only), reads it back with
  `pg_restore --list`, then moves it into place; then the usual mirror to
  `/mnt/nas/data1/docker/breeding-research/mirror`, without the live `pg-data/`. One dump is kept;
  the NAS's ZFS snapshots of the mirror hold the history. A failed dump leaves the last good one, in
  `pgdump/` and in the mirror, and `backup` exits 1.
- `dbrestore [FILE]` loads a dump (default `pgdump/breeding_research.dump`) into the running
  container in one transaction (`--single-transaction --exit-on-error`: a failure changes nothing).
  Refused while the database has a user table, unless `RESTORE_FORCE=1` (`--clean --if-exists`). The
  app is stopped meanwhile and started again if it was running.
- `dbcheck [FILE]` is the restore test: the dump goes into a throwaway container of the same image
  (`--network none`, removed afterwards, the live database untouched), and its table list and each
  table's row count are compared with what the dump holds; exit 1 on any difference.
- A rebuilt host: `restore` brings `pgdump/` back from the mirror; the deploy's `up` then finds
  `pg-data` empty with a dump present, starts postgres alone and runs `dbrestore` before the app
  starts, so the app never starts on an empty database. Deleting `pg-data` by hand does the same on
  the next `up`.

### Schema and data load (BigQuery export)

The schema and the loader are the app image's own (breeding-research repo `db/migrations/`,
`scripts/db_migrate.py`, `scripts/pg_load.py`; central breed DB milestone 3). These run them in the
running `breeding-research` container (`/app`, uid 65534), which already has `DATABASE_URL`, so no
password passes through them:

- `dbmigrate` applies the pending migrations (`python scripts/db_migrate.py`); `dbstatus` lists
  them and changes nothing (`--status`).
- `dbload` reads a tar of one export directory (`manifest.json` and `<table>.jsonl`, from the
  repo's `scripts/bq_export.py`) on stdin and runs `python scripts/pg_load.py --tar -`, which loads
  each table in its own transaction, prints each table's export-vs-Postgres row count and checksums,
  and exits nonzero on any mismatch. Running the same export again adds no rows. Refused when stdin
  is a terminal.
- All three are refused, with nothing run, when the app is not running or its image has no such
  script ("update the app image first"): images built before milestone 3 do not ship them.

From the workstation, `dbload_from_workstation.sh EXPORT_DIR` (in this directory) sends the
export: it packs `manifest.json` and the top-level `*.jsonl` (macOS-safe: `COPYFILE_DISABLE=1 tar
--no-xattrs`, no `._` members) and pipes it, in memory, into one `ssh -o BatchMode=yes docker@d03`
running `breeding-research.sh dbmigrate dbload`. `D03_SSH` and `D03_SCRIPT` override the target.
Offline test: `bash scripts/tests/test_breeding_research_db_sh.sh`.

Operator steps, each approved on its own:

1. Push breeding-research: its CI builds `:<sha>` and `:latest` with the scripts in the image.
2. Merge and push this repo's branch.
3. Sync the scripts to d03: `python3 tools/host_maintenance_run.py --task scripts --hosts d03`
   (asyla hub).
4. Move the app to the new image: `python3 tools/host_maintenance_run.py --task apps --hosts d03
   --apps breeding-research` (runs `refresh`); `dbstatus` on d03 then lists the migrations.
5. Export from BigQuery (breeding-research `scripts/bq_export.py`), then
   `d03/apps/breeding-research/dbload_from_workstation.sh <export dir>`; every table must report a
   match. Take a `backup` afterwards so the loaded data is in `pgdump/` and the mirror.

The app's own mount (`/mnt/docker/breeding-research` as `/data/app`, uid 65534) covers `pg-data/`
(Postgres's, 0700) and `pgdump/` (the docker user's, 0700); it can read neither.

Moved off the retired k3s cluster on 2026-05-29. The one-time data migration script is in the
breeding-research repo's history (`scripts/migrate-data-k3s-to-d03.sh`, removed in `48099ba`).

## Edge

d03 serves it directly: the internal-access d03 Caddy proxies `breeding-research.asyla.org` to
`breeding-research:8080` on the LAN, and external-access publishes it through the d03 tunnel
(`hosts/d03/apps.yml`).
