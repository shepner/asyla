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

`up` and `restart` pull the image only when it is not on the host, so the app never moves to a new
image by itself (host-maintenance's rollback re-tags the old image, then runs `up`); `update` pulls
`latest`, and `refresh` pulls it, then runs `up`. host-maintenance's weekly apps run updates it.
Pin another image by hand with `BREEDING_RESEARCH_IMAGE_OVERRIDE=<ref>` in the call's environment.

A local build instead (`BREEDING_RESEARCH_PULL_OVERRIDE=0`): the source in `.src/breeding-research`
or `BREEDING_RESEARCH_SRC` (a clone of the private repo needs a read credential on d03); the image is
`breeding-research:local`, `up` builds it when it is missing, and `refresh` pulls the source
(`git pull --ff-only`), rebuilds, then runs `up`.

Moved off the retired k3s cluster on 2026-05-29. The one-time data migration script is in the
breeding-research repo's history (`scripts/migrate-data-k3s-to-d03.sh`, removed in `48099ba`).

## Edge

d03 serves it directly: the internal-access d03 Caddy proxies `breeding-research.asyla.org` to
`breeding-research:8080` on the LAN, and external-access publishes it through the d03 tunnel
(`hosts/d03/apps.yml`).
