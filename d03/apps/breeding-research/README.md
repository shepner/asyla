# breeding-research on d03

FastAPI dog breeding research app. Data: **`/mnt/docker/breeding-research/`** (`gcp-credentials.json`, etc.).
Source: the breeding-research repo (`https://gitlab.com/asyla/breeding-research.git`). It has no CI and
publishes no registry image, so d03 builds the image from source (see `.env.example`).

## Run

```bash
cp .env.example .env   # then fill in BQ_* and BASIC_AUTH_*
git clone https://gitlab.com/asyla/breeding-research.git .src/breeding-research   # or set BREEDING_RESEARCH_SRC
~/scripts/d03/apps/breeding-research/breeding-research.sh up verify
```

`refresh` pulls the source (`git pull --ff-only`), rebuilds, then runs `up`.

Moved off the retired k3s cluster on 2026-05-29. The one-time data migration script is in the
breeding-research repo's history (`scripts/migrate-data-k3s-to-d03.sh`, removed in `48099ba`).

## Edge

d03 serves it directly: the internal-access d03 Caddy proxies `breeding-research.asyla.org` to
`breeding-research:8080` on the LAN, and external-access publishes it through the d03 tunnel
(`hosts/d03/apps.yml`).
