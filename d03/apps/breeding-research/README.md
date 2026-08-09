# breeding-research on d03

FastAPI dog breeding research app. Data: **`/mnt/docker/breeding-research/`** (`gcp-credentials.json`, etc.).

## Run

```bash
cp .env.example .env   # or run migrate script to pull k8s secret
~/scripts/d03/apps/breeding-research/breeding-research.sh up verify
```

Migrated from k3s (see `asyla/projects/breeding-research/scripts/migrate-data-k3s-to-d03.sh`).

**Image on d03:** GitLab registry pull needs `docker login registry.gitlab.com` on d03. Otherwise build on the host (`breeding-research.sh build` with `BREEDING_RESEARCH_SRC`) or load from a workstation: `docker buildx build --platform linux/amd64 -t breeding-research:d03-migrate --load .` then `docker save | ssh d03 docker load`.

## Edge

k3s `internal-proxy` forwards `breeding-research.asyla.org` → **10.0.0.62:8080** until d03 Caddy serves it directly.
