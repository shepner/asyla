# breeding-research on d03

FastAPI dog breeding research app. Data: **`/mnt/docker/breeding-research/`** (`gcp-credentials.json`, etc.).
Source: the breeding-research repo, private on Gitea (`https://gitea.asyla.org/personal/breeding-research.git`;
the GitLab copy `asyla/breeding-research` was archived on 2026-10-11 and gets no new commits). It has
no CI and publishes no registry image, so d03 builds the image from source (see `.env.example`).
d03 has no clone today (2026-10-14): the running `breeding-research:d03-migrate` image was built
during the d03 migration. A clone of the private repo needs a read credential on d03; until one is
decided, put the source in place from the Mac and set `BREEDING_RESEARCH_SRC`.

## Run

```bash
cp .env.example .env   # then fill in BQ_* and BASIC_AUTH_*
git clone https://gitea.asyla.org/personal/breeding-research.git .src/breeding-research   # or set BREEDING_RESEARCH_SRC
~/scripts/d03/apps/breeding-research/breeding-research.sh up verify
```

`refresh` pulls the source (`git pull --ff-only`), rebuilds, then runs `up`.

Moved off the retired k3s cluster on 2026-05-29. The one-time data migration script is in the
breeding-research repo's history (`scripts/migrate-data-k3s-to-d03.sh`, removed in `48099ba`).

## Edge

d03 serves it directly: the internal-access d03 Caddy proxies `breeding-research.asyla.org` to
`breeding-research:8080` on the LAN, and external-access publishes it through the d03 tunnel
(`hosts/d03/apps.yml`).
