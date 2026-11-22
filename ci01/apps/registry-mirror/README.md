# registry-mirror (ci01)

A Docker Hub pull-through cache for ci01's own Docker daemon (asyla #1237). theOrg's CI jobs on ci01
pull the same Docker Hub images again and again, and Docker Hub answers anonymous pulls past its limit
with HTTP 429 (theOrg #1195). With the cache, a Docker Hub image is fetched once and served from ci01
after that.

- **What runs:** one `registry:2.8.3` container (pinned by its index digest in `compose.yml`) in proxy
  mode: `REGISTRY_PROXY_REMOTEURL=https://registry-1.docker.io`. A pull the cache lacks is fetched
  from Docker Hub, kept, and served from here after. **Anonymous:** no Docker Hub username or password
  on disk or in config (theOrg SEC-5/7), so #1195's authenticated-pull option is dropped.
- **Who uses it:** ci01's daemon only. It is published on `127.0.0.1:5000` and nowhere else, and
  `daemon.json` names it in `registry-mirrors` (`[docker]` in `ci01/host.toml`, rendered by
  `build/setup/docker.sh`). Docker treats registries on 127.0.0.0/8 as insecure by default, so plain
  http needs no `insecure-registries` entry
  ([dockerd, Insecure registries](https://docs.docker.com/reference/cli/dockerd/#insecure-registries)).
  The daemon uses a mirror for Docker Hub images only; other registries are pulled directly.
- **Data:** `/mnt/docker/registry-mirror` on the data disk. A cache: nothing to back up or restore
  (`restore = false` in the host spec); lost, it refills from pulls. `backup` and `restore` say so and
  do nothing.
- **Start or restart:** no key, so from the workstation:

  ```bash
  cd ~/local/asyla && python3 projects/asyla-hosts/scripts/build_host.py ci01 build --only apps --app registry-mirror --apply
  ```

  or `registry-mirror.sh up` on ci01.
- **Check:** `registry-mirror.sh verify`: the container is running (healthy or starting),
  `http://127.0.0.1:5000/v2/` answers 200, and `docker info` lists `http://127.0.0.1:5000/` as a
  registry mirror. `registry-mirror.sh status` lists what the cache holds and its size.

## Seeing it work

On ci01, pull one Docker Hub image twice (for example `docker pull alpine:3.20`, `docker rmi
alpine:3.20`, `docker pull alpine:3.20`). Then either:

- `docker logs registry-mirror` shows the requests for that image's manifest and blobs: the daemon
  asked the cache, not Docker Hub; or
- `curl http://127.0.0.1:5000/v2/_catalog` lists it (`library/alpine`).

## Caveat: buildx builders

The mirror is a setting of the daemon. A buildx builder with the `docker-container` driver runs its
own BuildKit, which does not read the daemon's `registry-mirrors`, so its `FROM` pulls go to Docker
Hub directly. Pointing those builders at the cache (a BuildKit config naming the mirror) is theOrg's,
under theOrg #1238. The default `docker` driver builds in the daemon, so it should use the mirror
(inference, not yet seen on ci01).
