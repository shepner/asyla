# communications (d06)

theOrg's web chat stack, moving from the Mac Mini: NATS (JetStream, WebSocket) with its Prometheus
exporter, chat-api with its PostgreSQL message store, the Vikunja webhook bridge (webhook-to-mq)
and the stack's vector. asyla deploys it here from theOrg communications `docker-compose.yml` and
`DEPLOY.md` at `beff7c55` (`beff7c55c9880facd23a1c289f667de5c1692795`, the #40 merge, 2026-11-09),
the commit the asyla hub backlog item "d06: deploy theOrg communications at beff7c55" names.
theOrg's own deploy does not target d06.

- `compose.yml`: theOrg's file with asyla's changes listed at its top: images only (no `build:`),
  no mail-relay and no cloudflared, `container_name` dropped except vector's (theOrg's
  `vector-http.toml` excludes `communications-vector-1` by name), the network named
  `communications_net` (internal-access `hosts/d06` joins it), data in bind mounts instead of
  named volumes, and only `127.0.0.1` ports.
- `communications.sh`: `up`, `down`, `restart`, `backup`, `restore`, `verify`, `update`, `pull`,
  `images`, `logs`; switches combine (`backup update up verify`). `up` starts in DEPLOY.md's order:
  nats, nats-exporter, comms-postgres, chat-api, webhook-to-mq-vikunja, vector. vector starts only
  when observability's network (`observability_observability-net`) exists; otherwise `up` warns
  and the stack's logs and chronicle episodes are lost until it is started again.
- `docker-credential-communications-env`: a read-only Docker credential helper (a copy of
  ticketing's) for the pulls.
- `theorg/`: theOrg's anonymous-refusal check, vendored unchanged (below).

## Names and ports

- Compose project `communications`, so containers are `communications-<service>-1`. Network
  `communications_net`; vector is also on `observability_observability-net`, where Loki is
  `loki:3100` (plain HTTP). Chronicle episodes go to `10.0.0.150:6000` (memory-system, off the host).
- Published on `127.0.0.1` only: chat-api `9098`, nats monitoring `8222` (no auth: `verify` and the
  exporter), the exporter `7777`. Not published: nats `4222`, NATS over WebSocket `8080`,
  webhook-to-mq `9092`. d06 already used 3456, 9090, 9091, 9093, 9099, 9107, 9111, 9598, 80 and
  443 (`ss`, 2026-11-10); none of these collide.
- Names (internal-access `hosts/d06`, later, each with the operator's approval):
  `theorg.asyla.org` -> `chat-api:9098`; `nats.asyla.org` -> `nats:8080` only after `verify`'s
  anonymous check passes on d06.

## Images and the tag pin

`gitea.asyla.org/theorg/communications-{nats,chat-api,webhook-to-mq,vector,backup}`, all at one tag:
`COMMS_TAG` in `communications.sh`, the full `beff7c55` sha (theOrg's publish-images pushed those
images). Unlike ticketing this does not follow `latest`: the hand-off names a commit. Pin another
by hand with `COMMS_TAG_OVERRIDE=<a theOrg sha whose images are published>` in the call's
environment, then `communications.sh backup update up verify`. Third-party images are pinned:
`natsio/prometheus-nats-exporter:0.20.2` by version, and `postgres:16-bookworm` by the digest of
its multi-arch index (16.15, read with `docker buildx imagetools inspect` on 2026-11-10; to move
it, read the index digest the same way and change `compose.yml`).

Pulls never log in and never write a credential: they run under a throwaway `DOCKER_CONFIG` whose
`config.json` names only the helper beside the script, which hands Docker the `theorg-registry`
read:package token from the process environment. The workstation sends it at use (build_host.py
`pull_token_env` `THEORG_REGISTRY_PULL_TOKEN`, here as `COMMUNICATIONS_REGISTRY_PULL_TOKEN`). `up`
pulls only missing images, so it never moves to a new image by itself; a deploy (`d06/host.toml`
start: `pull up`) or `update` does.

## Secrets

No secret is in any file asyla writes, here or on the host (asyla SEC-5, SEC-7; d06 keeps no
secret on disk, the operator's rule of 2026-10-18). The workstation resolves five values from
OpenBao at deploy and sends them over SSH stdin into the process environment only (build_host.py
`start_env`); `up` and `restart` refuse before anything is stopped unless each is present, and
never print one.

The caveat: the values reach the containers as environment, and dockerd keeps each container's
environment at rest in `/var/lib/docker/containers/<id>/config.v2.json` (root, 0600), as it does
for ticketing's Dex values. That file is Docker's, not one asyla writes.

| Environment name | OpenBao record (KV v2) |
| --- | --- |
| `COMMS_POSTGRES_PASSWORD` | `v2/communications/postgres` `password` |
| `COMMS_NATS_WEBHOOK_MQ_USERNAME` | `v2/communications/nats-webhook-mq` `username` |
| `COMMS_NATS_WEBHOOK_MQ_PASSWORD` | `v2/communications/nats-webhook-mq` `password` |
| `COMMS_CHAT_API_TOKEN` | `v2/communications/chat-api-token` `value` |
| `COMMS_VIKUNJA_WEBHOOK_SECRET` | `v2/communications/vikunja-webhook-secret` `value` |

The names go in the asyla hub's `data/components.toml` `[credentials.stored]` (the hub repo, not
this one). `backup` and `restore` need only `COMMS_POSTGRES_PASSWORD`, and take it from the
running comms-postgres container when the environment has none: build_host.py's restore phase and
host-maintenance's nightly `backup` send no start values. `docker inspect`'s template matches that
one key (`POSTGRES_PASSWORD`) and emits nothing else; the value stays in the script's process and
reaches theOrg's backup image by name only. The docker group can read it there already (the
caveat above), so nothing new is exposed. With no running comms-postgres they refuse.

## NATS users

theOrg's broker reads its users from `/etc/nats/runtime/users.conf`. On the Mini theOrg's
bootstrap writes the passwords into that file; here it would be a secret file on d06, which asyla
SEC-7 does not allow. So `communications.sh` writes `users.conf` (into
`/mnt/docker/Communications/nats-runtime`, atomically) with user names and references only:

```
{ user: "webhook-mq", password: $NATS_PW_0 }
```

one line per user (theOrg's `nats-entrypoint.sh` `has_users` needs `user` and `password` on the
same line, and replaces a file with no such line by its refuse-all placeholder), and a compose override, generated per run in a temp directory and removed at exit, that names
`NATS_PW_<i>` in nats's environment (names only). Each value is the password pre-quoted as a NATS
string: `"` + the value with `\` doubled and `"` escaped + `"` (theOrg's `_esc`). Unquoted, nats
parses an environment value as config, so a value such as `-abc` stops nats from starting. The
users are `webhook-mq` (chat-api's and webhook-to-mq's principal) first, then each
`COMMS_MQ_USER_<X>_USERNAME`/`_PASSWORD` pair in the environment, sorted; a half pair, an empty
value, a repeated name or a control character is refused, and so is a run with no user (nats would
run open after a reload). Also refused, before `up` or `restart` stops or recreates anything: a `#`
or `/` in a user name (theOrg's `nats-entrypoint.sh` cuts each line at `#` and `//` before it
looks for users), and a webhook-mq user name or password with a character outside `A-Z a-z 0-9 _ -`
(chat-api percent-encodes both into its NATS URL and nats-py does not decode them, theOrg
`1d961052`; the vault's value is `token_urlsafe`). When `users.conf` changes while nats runs, nats is recreated: a reload
re-reads the file but not the environment that holds the passwords.

The design was proven in a Docker lab before it was written (session notes, 2026-11-10): "20/20
PASS, nats 2.10.29, built from beff7c55 Dockerfile.nats ... entrypoint has_users accepts references
(no placeholder); anonymous refused on 4222 and ws 8080; right password accepted, wrong refused,
on both; edge values (leading digits, `10k`, quotes/backslash/#/ //, leading `-`) accepted; reload
advances config_load_time and keeps auth; env unset -> nats refuses to start (fail closed)."

## Data, backup and restore

- Data: `/mnt/docker/Communications/{nats-data,nats-runtime,pg-data,webhook-buffer,vector,backup}`.
  `pg-data` (the message store) is the system of record; NATS streams are transport.
- `backup` runs only on the host `theorg.asyla.org` resolves to (ticketing.sh's rule): before the
  cutover that name reaches the Mini, and a d06 copy would overwrite the live chat's mirror. It
  runs theOrg's backup image (`backup`, then `verify`, which includes a scratch restore) into
  `backup/`, then mirrors it to `/mnt/nas/data1/docker/Communications/mirror`; history is the NAS's
  snapshots. `.lock` and the `.work/` of a running backup are left out.
- Why there is a stage: the backup image runs as uid 999 and keeps `backup/` at `999:999` mode
  `0700` with `0600` files (DEPLOY.md), so d06's `docker` user cannot read it. `backup` copies it
  with `sudo -n rsync` to `/mnt/docker/Communications/mirror-stage`, chowns that copy to the
  calling user (modes kept, owner-only), checks its `STATUS` starts with `OK`, and mirrors the
  stage. `restore` inverts it: mirror -> stage -> `backup/` (chowned back to `999:999`, `0700`).
- `restore` refuses when `pg-data` holds data (build_host.py reads that refusal as "data
  present" on a re-run); a `pg-data` this user cannot list belongs to an initialised
  comms-postgres, so it counts as holding data. It starts comms-postgres (on a rebuilt host, on the
  empty `pg-data`), stops chat-api, runs theOrg's restore, which verifies the copy first, and
  starts chat-api again if it was running; then run `verify`.
- `RESTORE_FORCE=1 communications.sh restore` replaces the live database of a running stack (C4:
  the Mini's final copy, put into the mirror). theOrg's restore refuses while another session is
  connected and keeps the database it replaced in `backup/.pre-restore-<UTC time>/` (DEPLOY.md,
  Undo a restore). Those safety copies stay on d06: no copy here carries them to the mirror or
  deletes them, so prune each by hand once its restore is accepted
  (`sudo rm -rf /mnt/docker/Communications/backup/.pre-restore-<time>`).
- A `backup` killed between its `sudo -n rsync` and its `chown` leaves `mirror-stage` owned by
  999. The next `backup` takes it back itself, and `restore` takes it back before it copies the
  mirror in, so nothing needs doing by hand.
- `d06/host.toml` sets `restore = false` for now: there is no data on d06 before the cutover, and
  no nightly backup schedule yet.

## Verify

DEPLOY.md, After a restore, checks 1-4, each fatal: chat-api `/health` 200 on `127.0.0.1:9098`
(waits up to `COMMS_WAIT_S`, 180 s); `python /app/chat_smoke.py` inside chat-api; nats `/healthz`
ok on `127.0.0.1:8222`; an anonymous client refused on 4222 and 8080; webhook-to-mq-vikunja
`/health` 200 from inside its container. `theorg.asyla.org` is not checked: until the cutover it
reaches the Mini.

The anonymous check is theOrg's `scripts/check_nats_refuses_anonymous.sh` and
`scripts/nats_auth_probe.py`, vendored byte-identical from `beff7c55` into `theorg/` (git blobs
`e3ac2097` and `0d783ae0`; compare with `git hash-object` against
`git rev-parse beff7c55:scripts/<file>` in theOrg communications). It runs with
`NATS_CONTAINER=communications-nats-1` and the chat-api image at `COMMS_TAG` as the probe image,
from inside `communications_net`. Update them only by copying a later theOrg commit's files whole.

## Lab

`COMMS_REGISTRY_OVERRIDE` names locally built images under another prefix and
`COMMS_OBSERVABILITY_NET` another network; the deploy sets neither. There is no hostname bypass:
a lab maps `theorg.asyla.org` to its own address (`--add-host`).

## Not yet true

- asyla cannot read the four `v2/communications/*` records: hub asyla's policy in theOrg
  secrets-vault (`policies/hub-asyla-d06.hcl`, at c214d21) grants none of them. theOrg's item
  `backlog/open/2026-11-09-secrets-vault-secrets-vault-hub-asyla-reads-communications-four-records-an.md`
  (theOrg `f263c2bf`) asks for it. Until it lands nothing here is deployed.
- No mail relay: theOrg's mail-relay service is not part of this hand-off.
- No mq-users: the Staff workers' NATS users (`COMMS_MQ_USER_<X>_USERNAME`/`_PASSWORD`, to be
  `start_env_optional`) wait for theOrg to name the principals (one exact vault path each).
- The C4 cutover: the names (`theorg.asyla.org` and `nats.asyla.org` CNAMEs, the off-LAN tunnel
  on d06), Vikunja's webhook target moved to d06's webhook-to-mq (9092 is not reachable from
  Vikunja today), Staff's `NATS_URL=wss://nats.asyla.org`, the Mini's final message-store copy put
  into the mirror, `restore = true`, and a nightly backup schedule.
