# breeding-research on d03

FastAPI dog breeding research app. Data: **`/mnt/docker/breeding-research/`** (`gcp-credentials.json`, etc.).

## Run

```bash
cp .env.example .env   # or run migrate script to pull k8s secret
~/scripts/d03/apps/breeding-research/breeding-research.sh up verify
```

Migrated from k3s (see `asyla/projects/breeding-research/scripts/migrate-data-k3s-to-d03.sh`).

## Edge

k3s `internal-proxy` forwards `breeding-research.asyla.org` → **10.0.0.62:8080** until d03 Caddy serves it directly.
