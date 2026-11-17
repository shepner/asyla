# identity-platform (d05)

theOrg's Keycloak (realm `theorg`, https://id.asyla.org), its keycloak-db and the openldap it
federates, moved from the Mac Mini. asyla deploys it from theOrg identity-platform `DEPLOY.md`,
"Production on d05", and `deploy/d05/compose.example.yml` at `701e893` (main, the #82 merge),
carried to `47f65add` (`47f65add39763bc3ccd086e69e4b3c571d85098a`, *Publish images* run 22377
green): keycloak and openldap in profile `restored`, and `deploy/d05/openldap-leaf.sh`; then to
`fcbed3fe` (`fcbed3febc7e65bc7afbab980d6b3868a0b3fe53`, the #85 merge, *Publish images* run 22553
green): `openldap-leaf.sh issue` takes the provisioner password on stdin only. theOrg's four images
are tagged with that sha; the two upstream digests did not change.

This folder is **M1** (agreed with theOrg): `up` creates the two networks, pulls the six images,
places theOrg's root CA, reports on the openldap leaf, and starts **keycloak-db alone**. openldap
and keycloak first start at the M5 cutover (DEPLOY.md steps 5-6), after a restore into empty
targets; `start-openldap`, `start-keycloak`, `configure` and `restore` refuse until that is written
(the first three behind the cutover marker gate below). The cutover bundle's switches are its
first part ("Cutover bundle (M5 G2)"). The ops
one-shots (backups, keycloak-configure) are never started by `up`.

- `compose.yml`: the example with both networks external, every secret passed by name only,
  `KC_BOOTSTRAP_ADMIN_*` left out, keycloak and openldap in profile `restored` (as the example),
  and keycloak-configure's settings filled in (its header lists each change). After the M5 cutover
  every compose command needs `COMPOSE_PROFILES=restored` (DEPLOY.md); M1 never sets it.
- Networks (created by `identity-platform.sh up`, idempotent; an existing one with other settings
  is refused, never changed, its IPAM compared whole): `identity-platform-net` 10.213.5.64/26,
  gateway .65, and `identity-platform-edge`
  10.213.5.0/29, `--internal`, gateway .1, ip-range .4/30 (Caddy at .2 from internal-access
  hosts/d05, Keycloak at .3).
- `theorg-v2-root.crt`: theOrg's root ("theOrg-v2 Root CA", expires 2036-08-29), copied from
  internal-access `hosts/d03/upstream-ca/theorg-v2-root.pem`. `up` checks its SHA-256
  (`CD:39:...:87:D3`, also keycloak-configure's `KEYCLOAK_CA_FINGERPRINT`) before placing it at
  `/mnt/docker/IdentityPlatform/ca/root_ca.crt`, and refuses on a mismatch.
- openldap leaf: `/mnt/docker/IdentityPlatform/openldap-tls/{ldap.crt,ldap.key,ca.crt}`. `up` and
  `verify` only report it (missing is a warning, never fatal) and never issue.
  - `openldap-leaf.sh`: a byte-identical copy of theOrg identity-platform
    `deploy/d05/openldap-leaf.sh` at `fcbed3fe` (git blob `1fae6b5c1c598e76e586899fca9250781825aea4`,
    SHA-256 `2ea98d896a8c6085ea30f539883c33a543204fe994e231ef8663f2ff740681b1`). Never edit it
    here; a new version is a new copy and a new provenance line. It needs util-linux `flock` on the
    host (d05: util-linux 2.41.5, read 2026-11-14) and pulls `smallstep/step-cli:0.30.2` (pinned by
    digest in the script) from Docker Hub on its first run.
  - `leaf-issue`: networks, the checked root CA, `openldap-tls`, then `openldap-leaf.sh issue`
    (a 24h leaf from step-ca's JWK provisioner `ldap`). Before openldap's first start: osixia
    self-signs when the files are missing. It reads step-ca's `ldap` provisioner password
    (`secret/v2/certificate-management/step-ca/provisioners/ldap`, field `password`) as one line on
    its own stdin, into an unexported variable, and writes it with bash's builtin `printf` into a
    pipe to `openldap-leaf.sh issue`, which hands it to `docker run -i` on the container's stdin
    (no `-e`); the variable is unset after that run. The value is never in an environment, an argv,
    a file or a log. Refused (exit 3, no docker call, no status write) when
    `LDAP_PROVISIONER_PASSWORD` is set in its environment at all (even empty), when stdin is a
    terminal, when the line read is empty, and when another switch is given with it; refused over a
    valid leaf (openldap-leaf.sh, exit 3) and on a replica. It is in no `host.toml` `start_env` (a
    start runs `up`, which must never get it): the operator runs the leaf switches from the
    workstation with `scripts/app_switch.sh`, which runs one switch over one ssh with ssh's stdin
    passed straight to the app script and nothing exported on the host. With a VAR it reads that
    one value from its own environment (the credentials capability puts it there), unsets it before
    any child runs (so neither ssh nor the remote shell inherits it) and writes it with builtin
    `printf` to ssh's stdin; it allows only the switches and the one VAR in this app's `switch_env`
    in `d05/host.toml`. The leaf lives 24 hours, so the schedule is installed right after the first
    issue, in the same sitting:

    ```
    cd ~/local/asyla && python3 core/tools/credentials.py exec LDAP_PROVISIONER_PASSWORD -- projects/asyla-hosts/scripts/app_switch.sh d05 identity-platform leaf-issue LDAP_PROVISIONER_PASSWORD
    cd ~/local/asyla && projects/asyla-hosts/scripts/app_switch.sh d05 identity-platform leaf-schedule-install
    ```

    `leaf-schedule-status`, `leaf-renew` and `leaf-schedule-remove` run the same way, with no VAR.
  - `leaf-renew`: `openldap-leaf.sh renew`, no secret (refused when `LDAP_PROVISIONER_PASSWORD` is set): renews at half
    life over mTLS with the current leaf and reloads slapd when openldap runs. Not on a replica.
  - The schedule (theOrg DEPLOY.md item 13: every 3 hours): `identity-platform-leaf-renew.timer`
    (`OnCalendar=*-*-* 00/3:17:00`, `Persistent=true`, up to 5 min random delay) and its oneshot
    service (a template: `User=` and `ExecStart=` filled in at install; `RequiresMountsFor=/mnt/docker`,
    where the leaf and the status file live), both here. Not installed by
    `up`, a build or the updater: `identity-platform.sh leaf-schedule-install` installs and enables
    them (sudo), once the operator has approved the exact schedule and after `leaf-issue`;
    `leaf-schedule-status` (read-only) and `leaf-schedule-remove`. The service runs this folder's
    `identity-platform.sh`, which the 02:30 updater keeps at master. The updater does not touch the
    installed units: after a change to either template here (`identity-platform-leaf-renew.service`
    or `.timer`) reaches d05, re-run `leaf-schedule-install` (the command above). It is idempotent:
    it installs only a unit that differs, daemon-reloads only then, and enables the timer.
  - Status: every `leaf-issue` and `leaf-renew` past their refusals writes
    `/mnt/docker/IdentityPlatform/leaf-status.json` atomically (a temp file, then `mv`; a failed
    write fails the switch): `time` (UTC, `...Z`, which host-maintenance's `parse_iso`,
    `datetime.fromisoformat` on Python 3.12, reads), `action`, `result` (ok, fail or refused),
    `exit`, `not_after` (the leaf's), `issued_ok` (the last successful issue; `leaf-schedule-install`
    needs it) and `problems`: none when ok; on a failure one problem `leaf`, `warn` (a work item)
    while the leaf has 6 hours or more left, `urgent` when it has less, has expired or cannot be read.
    A `leaf-issue` that `openldap-leaf.sh` refuses (exit 3: a valid leaf already there, or its lock
    held) is `refused` and keeps the previous file's problems unchanged: no new work item. No
    secret is in it. host-maintenance alerts on it through its `[[status]]` entry
    `identity-platform-leaf` (`config/maintenance.toml`, `max_age_minutes = 200`), which is there
    commented out until the first `leaf-issue` and `leaf-schedule-install`, because a missing file
    alerts as urgent; uncommenting it is a host-maintenance change approved with those steps.
- No secret is in any file, here or on the host. The workstation resolves them from OpenBao at
  deploy (`d05/host.toml`: `start_env` `IDP_KEYCLOAK_DB_PASSWORD`; `IDP_LDAP_ADMIN_PASSWORD` and
  `IDP_DEPLOY_DEX_CLIENT_SECRET` are M5's, not sent in M1), and `identity-platform.sh` maps them
  onto the compose names (its header). Only the long-running services (keycloak, keycloak-db,
  openldap) name a secret in `compose.yml`; every one-shot (configure, the backup and restore runs)
  takes its value on stdin, as theOrg's `bd0c6bff` (PR #88, not merged). The image tag and digests
  stay at `fcbed3fe` until that reaches theOrg's main (pending repin; `compose.yml` header). Images are pulled with the theorg-registry token the
  workstation hands over at use (`pull_token_env`, as `IDENTITY_PLATFORM_REGISTRY_PULL_TOKEN`)
  through `docker-credential-identity-platform-env`, under a throwaway `DOCKER_CONFIG`.
- Data: `/mnt/docker/IdentityPlatform/{ca,keycloak-db}` in M1. No backup yet: the system of record
  stays on the Mini until M5.
- Replica (test01 as `[replica] of = "d05"`): `images` pulls what is missing and lists keycloak-db's
  image for build_host.py's egress probe; `up` on a host not named d05 makes the networks, places
  the CA and starts keycloak-db alone with a throwaway password made at run time (a replica gets no
  `start_env`; d05's value is never used there). openldap and keycloak never start on a replica.

## Cutover bundle (M5 G2)

The Mini's data comes to d05 as theOrg's cutover bundle (theOrg identity-platform
`deploy/d05/CUTOVER-BUNDLE.md`, asyla #654): the Mini's `pack` writes an age-encrypted
`bundle.tar.age` to the theorg generic package `identity-platform-cutover`, and d05 downloads it and
runs the cutover image's `unpack` into the two dirs the restores read (`backup/` and
`openldap-backup/` under `/mnt/docker/IdentityPlatform`).

- Pin: `CUTOVER_BUNDLE_COMMIT` in `identity-platform.sh` (one line) is theOrg identity-platform
  `7ac1bfb` (`7ac1bfb4ba3402f16d029765cdc92c51a5fab769`), PR #87: approved, CI green, **not merged**.
  Repin it to the merged main commit when #87 merges. The image is
  `gitea.asyla.org/theorg/identity-platform-cutover-bundle:<that commit>`.
- The relay: the operator copies pack's output on the Mini into the commands below: its `version`
  line (`m5-<12 hex>`, fetch-bundle's ARG) and its three sha256 lines, `manifests-sha256`,
  `keycloak-summary-sha256` and `openldap-summary-sha256` (unpack-bundle's three ARGs, in that
  order). unpack-bundle refuses a fetched version that is not `m5-` and the manifests sum's first
  12 hex, and after unpack checks its four lines against the fetched version and the three ARGs.
- The operator commands, each run alone from the workstation (`scripts/app_switch.sh` allows them
  through `switch_env` and `switch_args` in `d05/host.toml`; a value goes on ssh stdin, never an
  argv or an environment on d05):

  ```
  cd ~/local/asyla && python3 core/tools/credentials.py exec THEORG_REGISTRY_PULL_TOKEN -- projects/asyla-hosts/scripts/app_switch.sh d05 identity-platform fetch-bundle THEORG_REGISTRY_PULL_TOKEN VERSION
  cd ~/local/asyla && python3 core/tools/credentials.py exec IDP_CUTOVER_BUNDLE_IDENTITY -- projects/asyla-hosts/scripts/app_switch.sh d05 identity-platform unpack-bundle IDP_CUTOVER_BUNDLE_IDENTITY MANIFESTS_SHA256 KC_SUM OL_SUM
  cd ~/local/asyla && projects/asyla-hosts/scripts/app_switch.sh d05 identity-platform reset-cutover
  cd ~/local/asyla && projects/asyla-hosts/scripts/app_switch.sh d05 identity-platform cutover-clean
  ```

  - `fetch-bundle VERSION`: pulls the cutover image if missing (the theorg-registry token through
    the credential helper, as `pull`) and downloads `bundle.tar.age` to `cutover/` (the token on
    curl's config stdin alone); prints its size and sha256; writes the `fetched` marker. Refused
    over an existing bundle (`cutover-clean` first) or an `unpacked` marker (`reset-cutover`
    first).
  - `unpack-bundle MANIFESTS_SHA256 KC_SUM OL_SUM`: reads the age identity on stdin and writes it
    to the image's `unpack` on stdin alone; the contract's docker run plus `--pull never`:
    `docker run --rm -i --pull never --network none`. Right before it, past every refusal and the
    identity read, it writes the `unpack-started` marker (the fetched version and
    `MANIFESTS_SHA256`). The `IDP_CUTOVER_BUNDLE_IDENTITY` credentials slot waits on
    secrets-vault#65: until it exists this command cannot run. Refused with no `fetched` marker or
    bundle, a bundle whose sha256 is not the fetched one, an `unpacked` marker, an `unpack-started`
    marker without `unpacked` ("a previous unpack did not finish: run reset-cutover"), or a target
    holding more than `lost+found` (`reset-cutover` first).
  - `reset-cutover`: after a failed unpack (or to unpack again), removes the `unpacked` marker,
    empties both targets but for `lost+found` with the pinned image's `find` (`--pull never`,
    `--network none`: unpack's files are root-owned), and once both are verified empty removes the
    `unpack-started` marker; keeps the bundle and the `fetched` marker. It deletes only what an
    unpack wrote: with neither `unpack-started` nor `unpacked` it refuses (exit 3, nothing
    changed), unless both targets are already empty (a no-op). Refused once `cutover-done` or a
    `restored-*` marker exists, when `docker compose --profile restored --profile ops ps -a -q
    openldap keycloak keycloak-backup openldap-backup` lists a container, or when that call fails:
    past a restore the targets are never emptied here. With the image missing it succeeds when both
    targets are already empty; otherwise it removes `unpacked` (keeping `unpack-started`) and fails:
    run `cutover-clean` and `fetch-bundle` (which pulls the image), then `reset-cutover` again.
  - `cutover-clean`: removes `cutover/bundle.tar.age`, fetch-bundle's temp downloads
    (`cutover/.bundle.*`), and keeps the `fetched` marker, which the gate checks `unpacked`
    against (a new `fetch-bundle` rewrites it); idempotent, gated only on `cutover-done`
    (refused once it exists; a bundle can be fetched again).
  - Both `reset-cutover` and `unpack-bundle` refuse (exit 3, nothing touched) when `backup/`,
    `openldap-backup/` or `cutover-state/` is a symlink. The four switches run one at a time: each
    holds util-linux `flock -n` on `cutover-state/.lock` for its whole run, and refuses (exit 3,
    "another cutover switch is running") when it is busy.
- The marker gate: one marker per step in `/mnt/docker/IdentityPlatform/cutover-state/`, each
  written atomically and then synced (`sync -f`): `fetched`, `unpack-started`, `unpacked`,
  `restored-openldap` / `restored-keycloak` from the restores, and `cutover-done` from the later
  go-live or restore switch (those three not written yet; `cutover-done` stops `reset-cutover` and
  `cutover-clean`). `start-openldap` needs `unpacked` and `restored-openldap`, `start-keycloak`
  needs `unpacked` and `restored-keycloak`, `configure` needs both `restored-*`; `unpacked` counts
  only with a non-empty version equal to `fetched`'s, a `restored-*` marker only when not empty.
  Each names the missing or invalid marker and exits 3, and with its markers present still refuses
  (not yet written, exit 3). `restore` refuses (exit 1, never build_host.py's skip status 3) until theOrg's
  B2a (`keycloak_backup.sh` taking `PGPASSWORD` on stdin) and identity-platform #86.
- Exit codes of the four cutover switches: 0 done; 2 a usage error (a wrong ARG, an ARG to
  `reset-cutover` or `cutover-clean`); 3 refused, nothing changed (a replica, the value's name set
  in the environment, a terminal or an empty read on stdin, a marker or state check, combined with
  another switch); 1 a failure (a pull or download, a check after unpack, a target left not empty).
  unpack-bundle keeps unpack's own exit: 2 and 3 changed nothing; 1, 4 or any other failure may have
  left files: run `reset-cutover` before a retry. None runs on a replica.
