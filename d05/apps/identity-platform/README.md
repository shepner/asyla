# identity-platform (d05)

theOrg's Keycloak (realm `theorg`, https://id.asyla.org), its keycloak-db and the openldap it
federates, moved from the Mac Mini. asyla deploys it from theOrg identity-platform `DEPLOY.md`,
"Production on d05", and `deploy/d05/compose.example.yml` at `701e893` (main, the #82 merge),
carried to `47f65add` (`47f65add39763bc3ccd086e69e4b3c571d85098a`, *Publish images* run 22377
green): keycloak and openldap in profile `restored`, and `deploy/d05/openldap-leaf.sh`; then to
`fcbed3fe` (`fcbed3febc7e65bc7afbab980d6b3868a0b3fe53`, the #85 merge, *Publish images* run 22553
green): `openldap-leaf.sh issue` takes the provisioner password on stdin only; then to merged main
`5dd8de6` (`5dd8de606a38b74c883eb7137770c37017ca8303`, the #88 merge, after #86 `a5415377` and #87
`8ff2201a`; its tree is PR #88's `bd0c6bff`): every one-shot takes its value on stdin; then to
merged main `bb456ee` (`bb456ee07d47cf9beb906d5492c92d09a7239bfc`, the #89 merge, *test* run 26060
and *Publish images* run 26059 green): keycloak-configure's read-only `check-reset-off` (DEPLOY.md
cutover step 6). From `5dd8de6` to `bb456ee` nothing under `deploy/d05/` changed but
`CUTOVER-BUNDLE.md`'s line references, and neither `scripts/keycloak_backup.sh`,
`scripts/openldap_backup.sh`, `scripts/cutover_bundle.sh` nor a `Dockerfile.*`; then to merged
main `d706369c` (`d706369c435a092948f4e86fad36f1a8a74cac51`, the #98 merge, 2026-11-22): the
explicit mail switch `KEYCLOAK_MAIL` (`on` or `off`, unset is off) and keycloak-configure's
read-only `check-mail-off` (`scripts/keycloak_realm.py`). From `bb456ee` to `d706369c` the only
change to a d05 interface is in `deploy/d05/compose.example.yml`, which adds `- KEYCLOAK_MAIL` by
name to keycloak-configure; `compose.yml` here leaves it out on purpose (unset is off, so mail and
"Forgot password?" stay off; operator decision R3). `check-reset-off` and its stdin form,
`scripts/cutover_bundle.sh`, `scripts/keycloak_backup.sh`, `scripts/openldap_backup.sh`, the
`Dockerfile.*`, `publish-images.yml` and the rest of `deploy/` did not change; `cutover_mini.py`
changed on the Mini's side only, and the bundle and manifest formats are unchanged. theOrg's four
images and the cutover-bundle image are tagged with that sha by `publish-images.yml` on a push to
main (`docker-compose.yml:438-442` at `d706369c`; the registry was not read for this pin; at
`bb456ee` each was read present on 2026-11-21); the two upstream digests did not change.

This folder is **M1** (agreed with theOrg): `up` creates the two networks, pulls the six images,
places theOrg's root CA, reports on the openldap leaf, and starts **keycloak-db alone**. openldap
and keycloak first start at the M5 cutover (DEPLOY.md steps 5-6), after a restore into empty
targets; `configure` runs keycloak-configure after them (behind the cutover marker gate below),
then `check-reset-off` checks the realm's password reset is off and `check-mail-off` that mail is
off (before configure too, without the realm),
and `restore` refuses and points at `restore-openldap` and `restore-keycloak`. The cutover
bundle's switches, the two restores, `start-openldap` / `start-keycloak`, `configure`,
`check-reset-off`, `check-mail-off`, `count-check` and `cutover-done` are M5's switches ("Cutover bundle (M5 G2)"), and
`rollback-stop` / `rollback-reset` stand d05's copy down and clear it after a rollback to the Mini
("Rollback inside the Mini's window (M5)"). Once `cutover-done` exists (on d05,
never a replica), `up` starts keycloak-db, openldap and keycloak together and needs
`IDP_LDAP_ADMIN_PASSWORD` too, and `verify` checks all three. The ops
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
    `deploy/d05/openldap-leaf.sh` at `d706369c`, unchanged since `fcbed3fe` (git blob `1fae6b5c1c598e76e586899fca9250781825aea4`,
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
  deploy (`d05/host.toml`: `start_env` `IDP_KEYCLOAK_DB_PASSWORD` and `IDP_LDAP_ADMIN_PASSWORD`;
  `up` unsets the LDAP value before `cutover-done` and refuses (exit 1, nothing started) without
  either after it; `IDP_DEPLOY_DEX_CLIENT_SECRET` goes only to `configure`, `check-reset-off` and `check-mail-off`, on stdin), and `identity-platform.sh` maps them
  onto the compose names (its header). Only the long-running services (keycloak, keycloak-db,
  openldap) name a secret in `compose.yml`; every one-shot (configure, the backup and restore runs)
  takes its value on stdin, as theOrg's merged main since `5dd8de6` (PR #88); the image tag is
  pinned to `d706369c` (`compose.yml` header). Images are pulled with the theorg-registry token the
  workstation hands over at use (`pull_token_env`, as `IDENTITY_PLATFORM_REGISTRY_PULL_TOKEN`)
  through `docker-credential-identity-platform-env`, under a throwaway `DOCKER_CONFIG`.
- Data: `/mnt/docker/IdentityPlatform/{ca,keycloak-db}` in M1. The system of record stays on the
  Mini until the M5 cutover; `backup` refuses before `cutover-done` (see "Backup (M5 unit D)").
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
  merged main `d706369c` (`d706369c435a092948f4e86fad36f1a8a74cac51`, the #98 merge; #87 merged as
  `8ff2201a`, #89 as `bb456ee`), the same commit as `IDENTITY_PLATFORM_TAG`. The image is
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
  cd ~/local/asyla && projects/asyla-hosts/scripts/app_switch.sh d05 identity-platform restore-openldap
  cd ~/local/asyla && python3 core/tools/credentials.py exec IDP_KEYCLOAK_DB_PASSWORD -- projects/asyla-hosts/scripts/app_switch.sh d05 identity-platform restore-keycloak IDP_KEYCLOAK_DB_PASSWORD
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
  - `restore-openldap` (cutover step 5): `docker compose --profile ops run --rm -T openldap-backup
    restore` with `OPENLDAP_BACKUP_CONFIG_MOUNT=rw` in compose's environment for that run (compose.yml
    mounts openldap-config read-only otherwise, and the restore refuses a read-only target); no
    secret (theOrg's `openldap_backup.sh` reads none). Writes `restored-openldap`.
  - `restore-keycloak` (cutover step 5): reads keycloak-db's password (`IDP_KEYCLOAK_DB_PASSWORD`,
    the name `up` reads) as one line on stdin and writes it to `docker compose --profile ops run
    --rm -T -e KEYCLOAK_BACKUP_PASSWORD_STDIN=1 keycloak-backup restore` on stdin alone (never
    `PGPASSWORD`, an argv, a file or a log). keycloak-db must be running and healthy. Refused (exit
    3) with `IDP_KEYCLOAK_DB_PASSWORD` in its environment, a terminal or an empty read on stdin.
    Writes `restored-keycloak`.
  - `start-openldap` (cutover step 5): reads `IDP_LDAP_ADMIN_PASSWORD`'s value as one line on stdin
    and runs `docker compose --profile restored up -d --no-deps --wait --wait-timeout 300 openldap`
    (DEPLOY.md's form; the timeout is asyla's, `IDENTITY_PLATFORM_START_WAIT_S`) with the value only
    in that process's environment, as `LDAP_ADMIN_PASSWORD` and `LDAP_CONFIG_PASSWORD`. Then it
    checks an admin bind with it (the admin password is then the copy's) in theOrg's stdin form
    (`rotate_ldap_admin_lab.py` at bb456ee): `docker exec -i ID ldapwhoami -x -H
    ldaps://localhost:636 -D cn=admin,dc=theorg,dc=local -y /dev/stdin`, the value on its stdin
    with no newline. A failed bind (49: the copy's password is not OpenBao's) leaves openldap
    running, writes no marker and exits 1. Writes `started-openldap` (`date`, `admin-bind ok`).
  - `start-keycloak` (cutover step 6): the same `up` for keycloak, with `IDP_KEYCLOAK_DB_PASSWORD`'s
    value as `KC_DB_PASSWORD`; keycloak-db must be running and healthy. Writes `started-keycloak`.
  - Both starts take no ARG and refuse (exit 3, no docker call, nothing changed) with the value's
    name in the environment, on a replica, without their markers (below), once their own
    `started-*` marker or `cutover-done` exists, or with a terminal or an empty read on stdin; a
    service not healthy in time is exit 1 with no marker.
  - `configure` (cutover step 6): reads `IDP_LDAP_ADMIN_PASSWORD`'s then
    `IDP_DEPLOY_DEX_CLIENT_SECRET`'s value, one line each on stdin (`scripts/app_switch.sh` writes
    them in host.toml's `switch_env` order), and writes both, in theOrg's form (DEPLOY.md "Secrets on
    stdin only" at bb456ee: `LDAP_ADMIN_PASSWORD=` and `VAULT_DEX_CLIENT_SECRET=` lines), to the
    stdin of `docker compose --profile ops run --rm -T keycloak-configure apply`, then of the same
    with `reconcile` (never an argv, an environment, a file or a log; compose.yml passes neither by
    name, so the compose process needs neither). keycloak must be running and healthy. An apply
    that fails skips reconcile; either failing passes its exit through (3: it refused its stdin or
    a setting) with no marker. Past the refusals, before apply, it removes `counted`, `reset-off`
    and `configured`, so a re-run leaves none stale (`check-reset-off` and `count-check` are run
    again after it). On both 0
    it writes `configured` (`date`, `apply ok`, `reconcile ok`). It is re-runnable, after `configured` and `cutover-done` too (DEPLOY.md
    "Updating": the configuration steps are idempotent). Refused (exit 3, no docker run, nothing
    changed) with either name in the environment, on a replica, a terminal or an empty read of
    either line; exit 2 for an ARG. The operator's run, the two VARs in that order:

    ```
    cd ~/local/asyla && python3 core/tools/credentials.py exec IDP_LDAP_ADMIN_PASSWORD IDP_DEPLOY_DEX_CLIENT_SECRET -- projects/asyla-hosts/scripts/app_switch.sh d05 identity-platform configure IDP_LDAP_ADMIN_PASSWORD IDP_DEPLOY_DEX_CLIENT_SECRET
    ```
  - `check-reset-off` (cutover step 6, right after `configure`; DEPLOY.md at `bb456ee`): reads
    `IDP_DEPLOY_DEX_CLIENT_SECRET`'s value as one line on stdin and writes it, in theOrg's form
    (exactly one `VAULT_DEX_CLIENT_SECRET=` line), to the stdin of `docker compose --profile ops
    run --rm -T keycloak-configure check-reset-off` alone (never an argv, an environment, a file or
    a log). theOrg's check is read-only: it GETs realm `theorg` over the admin API and exits 1
    unless `resetPasswordAllowed` is false (an absent realm or field fails too); a failure stops the
    cutover before step 7. Needs configure's markers and a valid `configured`, and keycloak running
    and healthy. Past the refusals, before the run, it removes `reset-off`. On 0 it writes
    `reset-off` (`date`, `resetPasswordAllowed false`), which `count-check` (M5 path) and
    `cutover-done` (both paths) need; otherwise its exit passes through (1: not false; 3: it
    refused its stdin) with no marker. Re-runnable, after `cutover-done` too. Refused (exit 3, no
    docker run, nothing changed) as `configure` is: the name in the environment, a replica, the
    lock busy, a missing or invalid marker, keycloak not healthy, a terminal or an empty read; exit
    2 for an ARG. The operator's run:

    ```
    cd ~/local/asyla && python3 core/tools/credentials.py exec IDP_DEPLOY_DEX_CLIENT_SECRET -- projects/asyla-hosts/scripts/app_switch.sh d05 identity-platform check-reset-off IDP_DEPLOY_DEX_CLIENT_SECRET
    ```
  - Mail off: `check-mail-off` (theOrg #98 at `d706369c`; DEPLOY.md "Production on d05" and cutover step 6, and
    `scripts/keycloak_realm.py check-mail-off`). `compose.yml` lists no `KEYCLOAK_MAIL`, so
    keycloak-configure sees it unset, which is off: `apply` keeps the realm's SMTP server cleared
    and `resetPasswordAllowed` false (operator decision R3). `check-mail-off` proves it, read-only.
    It reads `IDP_DEPLOY_DEX_CLIENT_SECRET`'s value as one line on stdin and writes it, in theOrg's
    form (exactly one `VAULT_DEX_CLIENT_SECRET=` line, theOrg's only stdin name for it), to the
    stdin of `docker compose --profile ops run --rm -T keycloak-configure check-mail-off [--without-realm]`
    alone. It runs on d05 only (refused on a replica), alone, under the cutover lock. The mode
    follows `cutover-state/configured`, and the switch prints which ran:
    - without-realm mode (no `configured`): `check-mail-off --without-realm` reads only
      `KEYCLOAK_MAIL` and the mail relay's client record from OpenBao, no Keycloak, and exits 1 if
      the coming `apply` would turn mail on. In the M5 cutover it runs **before step 6** (DEPLOY.md
      at `d706369c`: no Keycloak yet, so before `start-keycloak` and `configure`).
    - realm mode (`configured` present): `check-mail-off` reads the live realm `theorg` as
      theorg-iga too (no LDAP password), and needs configure's markers, a valid `configured`
      (`cutover_gate`, as `check-reset-off`) and keycloak running and healthy. In the M5 cutover it
      runs again **after `configure` and `check-reset-off`**; on the mirror path, after `configure`
      ("Rebuild from the nas01 mirror").
    - After a failed `configure` there is no `configured`, so it runs without-realm mode though a
      realm exists: run `configure` again first, then `check-mail-off`.

    Exit codes pass through: 0 mail off; 1 on, not proven off, or a setting refused (a bad
    `KEYCLOAK_MAIL` too); 3 its stdin refused. Refused (exit 3, no docker run, nothing changed)
    with the name in the environment, on a replica, the lock busy, `rolled-back`, in realm mode a
    missing or invalid marker or keycloak not healthy, a terminal or an empty read; exit 2 for an
    ARG. It writes no marker, removes none and is **not a `cutover-done` gate**: a failure is the
    operator's stop, not the gate's. It always reads the relay record (the deploy role may read
    `secret/v2/communications/mail-relay/clients/keycloak`). The operator's run, in both modes:

    ```
    cd ~/local/asyla && python3 core/tools/credentials.py exec IDP_DEPLOY_DEX_CLIENT_SECRET -- projects/asyla-hosts/scripts/app_switch.sh d05 identity-platform check-mail-off IDP_DEPLOY_DEX_CLIENT_SECRET
    ```
  - `count-check` (cutover step 7, Counts; DEPLOY.md at `bb456ee`): no value, no ARG. First the
    Mini's `backup/summary.txt` is read once (as root through keycloak-db's image, read-only) and
    its sha256 must equal `unpacked`'s `keycloak-summary-sha256` (theOrg `bb456ee`
    `scripts/cutover_bundle.sh`: the sha256 of `keycloak/summary.txt`), so the counts compared are
    the Mini's copy's; not equal: exit 1, no backup run, no marker. Then
    keycloak-backup backup on d05 into the emptied `count-check/` (`docker compose --profile ops
    run --rm -T -v .../count-check:/backup -e KEYCLOAK_BACKUP_PASSWORD_STDIN=1 keycloak-backup
    backup`: the `-v` replaces the service's `backup/` mount for that run, so the Mini's copy is
    untouched; keycloak-db's password taken from the running container, as `backup`, on its stdin
    alone), then its `summary.txt` compared with the Mini's `backup/summary.txt`: the `realm`,
    `users`, `clients`, `credentials` and `changesets` lines, sorted. `changesets` is count(*) of
    Keycloak's Liquibase changelog (theOrg bb456ee `scripts/keycloak_backup.sh:175-182`), which
    restore already requires equal (`:553`): a difference means d05 ran a different Keycloak
    against the copy, and step 7 stops (exit 1, no marker). Both are read, and `count-check/` emptied, as root through keycloak-db's image
    (`--pull never --network none`, read-only for the reads). After the backup, whatever the
    comparison, the same `find` removes everything in `count-check/` but `summary.txt`, so no
    Keycloak dump stays on disk; anything else left is exit 1, no marker. Equal: writes `counted` (`date`,
    `manifests-sha256`, `counts equal`), exit 0. Not equal: exit 1, both differing line sets
    printed (counts, not secrets), no marker. The backup failing: its exit, no marker. Refused
    (exit 3, nothing changed) on a replica, when `count-check/`, a target or `cutover-state/` is a
    symlink, with the lock busy, once `cutover-done` exists, and unless `unpacked`, both
    `restored-*`, both `started-*`, `configured` and `reset-off` are valid. Re-runnable until `cutover-done`.

    ```
    cd ~/local/asyla/projects/asyla-hosts && scripts/app_switch.sh d05 identity-platform count-check
    ```
  - `cutover-done` (after the cutover's step 8 verification): no value, no ARG. Refused (exit 3,
    nothing written) on a replica, with the lock busy, unless every marker is there and valid
    (`unpacked`, both `restored-*` naming `unpacked`'s `manifests-sha256`, both `started-*`,
    `configured` with `apply ok` and `reconcile ok`, `reset-off` with `resetPasswordAllowed
    false`, and `counted` with `counts equal` naming
    `unpacked`'s `manifests-sha256`), and unless openldap and keycloak are running
    and healthy. Writes `cutover-done` (`date`, `manifests-sha256`); once it exists it says so and
    exits 0. From then on a build's `up` starts all three services and needs both start_env values.

    ```
    cd ~/local/asyla/projects/asyla-hosts && scripts/app_switch.sh d05 identity-platform cutover-done
    ```
  - Both restores need a valid `unpacked` marker (its `manifests-sha256` 64 hex) and take no ARG;
    each is refused (exit 3, no docker run, nothing changed) on a replica and once its own
    `restored-*` marker or `cutover-done` exists. On 0 each writes its marker (`date`, the unpacked
    `manifests-sha256`); otherwise the restore's own exit passes through with no marker (3: it
    refused a target that is not empty; 2: a mount or usage problem; 1: it failed).
  - `reset-cutover`, `unpack-bundle` and both restores refuse (exit 3, nothing touched) when `backup/`,
    `openldap-backup/` or `cutover-state/` is a symlink (both starts, `configure`, `check-reset-off` and `check-mail-off`: `cutover-state/`). The fifteen switches (these twelve, `check-mail-off`, `rollback-stop` and `rollback-reset`) run one at a time: each
    holds util-linux `flock -n` on `cutover-state/.lock` for its whole run, and refuses (exit 3,
    "another cutover switch is running") when it is busy.
- The marker gate: one marker per step in `/mnt/docker/IdentityPlatform/cutover-state/`, each
  written atomically and then synced (`sync -f`): `fetched`, `unpack-started`, `unpacked`,
  `restored-openldap` / `restored-keycloak` from the restores, and `cutover-done` from the
  `cutover-done` switch (`cutover-done` stops the starts, `reset-cutover`, `cutover-clean` and the restores;
  a `restored-*` marker stops `reset-cutover`), `started-openldap` / `started-keycloak` from the
  starts, `configured` from `configure`, `reset-off` from `check-reset-off`, `counted` from `count-check`. `start-openldap` needs `unpacked` and `restored-openldap`,
  `start-keycloak` needs `unpacked`, `restored-keycloak` and `started-openldap`, `configure` needs
  both `restored-*` and both `started-*`, `check-reset-off` those and `configured` (only with its
  `apply ok` and `reconcile ok` lines), `count-check` all of those, `unpacked` and `reset-off`
  (only with its `resetPasswordAllowed false` line), `cutover-done` those and `counted` (only
  with its `counts equal` line); `unpacked` counts only with a non-empty version equal to
  `fetched`'s, `started-openldap` only with its `admin-bind ok` line, a `restored-*` or `started-*`
  marker only when not empty. Each names the missing or invalid marker and exits 3. `restore` refuses (exit 1, never build_host.py's skip status 3) and
  points at `restore-openldap` and `restore-keycloak`. `rolled-back`, from `rollback-stop` (below),
  stops the starts, the restores, `configure`, `check-reset-off`, `check-mail-off`, `count-check`, `cutover-done` and
  `backup` (exit 3) and `up` past `cutover-done` (exit 1), until
  `rollback-reset` removes it.
- Exit codes of the fifteen cutover switches (`check-mail-off` passes its run's exit through,
  above: 1 there is mail on or not proven off): 0 done; 2 a usage error (a wrong ARG, an ARG to
  `reset-cutover`, `cutover-clean`, a restore, a start, `configure`, `check-reset-off`, `check-mail-off`, `count-check`, `cutover-done`, `rollback-stop` or `rollback-reset`); 3 refused, nothing changed (a replica, the value's name set
  in the environment, a terminal or an empty read on stdin, a marker or state check, combined with
  another switch); 1 a failure (a pull or download, a check after unpack, a target left not empty).
  unpack-bundle keeps unpack's own exit: 2 and 3 changed nothing; 1, 4 or any other failure may have
  left files: run `reset-cutover` before a retry. The restores keep the restore's own exit, as
  above. None runs on a replica.

## Rollback inside the Mini's window (M5)

When the cutover is rolled back to the Mini (theOrg `DEPLOY.md`'s 3-day rollback window), two
switches stand d05's copy down and then clear it, each its own approval, run alone from the
workstation. Both are the M5 path only (refused past any mirror-path marker), take no value and no
ARG, hold the cutover lock and never run on a replica; both are allowed after `cutover-done`. They
touch no DNS and no tunnel.

- `rollback-stop`, once traffic is back on the Mini (or before step 9): it stops keycloak, then
  openldap (keycloak reads openldap), and checks that neither runs. Containers, volumes, data dirs
  and markers are kept for inspection; keycloak-db runs on. It writes `rolled-back`, which refuses
  the gated switches, `cutover-done` and `backup` (exit 3) and `up` past `cutover-done` (exit 1).
  It needs a `restored-*` or `started-*` marker (exit 3 otherwise: nothing to stand down). Run again,
  it stops what runs, keeps the first `rolled-back` and exits 0. A stop failing, or one still
  running: exit 1, no marker.

  ```
  cd ~/local/asyla && projects/asyla-hosts/scripts/app_switch.sh d05 identity-platform rollback-stop
  ```

- `rollback-reset`, when d05's copy is to go: it needs `rolled-back` and nothing running
  (openldap, keycloak, the ops one-shots). It removes the keycloak and openldap containers, stops
  keycloak-db, empties as root (lost+found kept; `find -xdev`, `rm --one-file-system
  --preserve-root=all`) `backup/`, `openldap-backup/`, `openldap-data/`, `openldap-config/`,
  keycloak-db's data dir, `count-check/` and `openldap-count-check/`, then removes every cutover
  marker but `fetched`, `rolled-back` last. `openldap-tls/`, `ca/`, the bundle (`cutover/`) and the
  NAS mirror are never touched. It refuses (exit 3, nothing changed) with `APP_ROOT` on the NAS
  share, a symlink, a non-dir or a mount point among its dirs (or `APP_ROOT` a mount point); exit 1,
  nothing changed, without `mountpoint` or keycloak-db's image. A failure after that is exit 1 with
  `rolled-back` kept: run it again. Then the build's `apps` phase alone starts keycloak-db on an
  empty database, and the cutover starts over from `unpack-bundle` (the same bundle, as `fetched`
  is kept; or `cutover-clean` and `fetch-bundle` for a new one):

  ```
  cd ~/local/asyla && projects/asyla-hosts/scripts/app_switch.sh d05 identity-platform rollback-reset
  cd ~/local/asyla && python3 core/tools/credentials.py exec THEORG_REGISTRY_PULL_TOKEN IDP_KEYCLOAK_DB_PASSWORD IDP_LDAP_ADMIN_PASSWORD -- python3 projects/asyla-hosts/scripts/build_host.py d05 build --apply --only apps --app identity-platform
  cd ~/local/asyla && python3 core/tools/credentials.py exec IDP_CUTOVER_BUNDLE_IDENTITY -- projects/asyla-hosts/scripts/app_switch.sh d05 identity-platform unpack-bundle IDP_CUTOVER_BUNDLE_IDENTITY MANIFESTS_SHA256 KC_SUM OL_SUM
  ```

- Tests: `scripts/tests/test_identity_platform_rollback_sh.sh` (the switches) and
  `scripts/tests/test_identity_platform_mirror_runbook.py` (this section's commands against
  `switch_env` and `switch_args`).

## Backup (M5 unit D)

`identity-platform.sh backup` is host-maintenance's nightly backup task (asyla #654; the operator's
"Yes, mirror nightly", 2026-11-16). host-maintenance runs it with stdin `/dev/null` and
`MAINT_FOREGROUND=1`, blocks until it exits and reads only the exit status: 0 counts as a fresh
backup. So it exits 0 only when every step passed, in this order (theOrg `DEPLOY.md` at `bb456ee`):

1. `openldap-backup backup`, then `openldap-backup verify` (no secret).
2. `keycloak-backup backup` with keycloak-db's password as one line on its stdin alone
   (`-T -e KEYCLOAK_BACKUP_PASSWORD_STDIN=1`), then `keycloak-backup verify` with no stdin (theOrg:
   verify needs no password). The password is the running keycloak-db's own `POSTGRES_PASSWORD`,
   read with a `docker inspect` template that emits that one entry (as `communications.sh` does for
   its database); it is never printed, an argv, an environment or a file.
3. Each copy (`openldap-backup/`, `backup/`) mirrored to
   `/mnt/nas/data1/docker/IdentityPlatform/mirror/{openldap,keycloak}` once
   `/mnt/nas/data1/docker` is a mount point.

A failed step exits 1 naming it; the later steps are skipped.

- Refused (exit 3, nothing run or written, so never counted as a fresh backup): on a replica, before
  `cutover-state/cutover-done` exists (the data is the Mini's until then), when `backup/`,
  `openldap-backup/`, `mirror-stage/` or `cutover-state/` is a symlink, when combined with another
  switch, and when the cutover lock is busy.
- The lock: `backup` takes the cutover switches' exclusive `flock -n` on `cutover-state/.lock`. No
  `configure`, restore or second `backup` runs meanwhile, and a second `backup` is refused here
  (3) rather than by theOrg's own `/backup/.lock` (1).
- The stage: the copies' files are root-owned and owner-only, so `mirror-stage.sh` runs as root in
  the copy's own image (`docker run --rm --network none --pull never --user 0:0`; steps 1 and 2 just
  used it) with the copy and `mirror-stage/NAME` mounted. Under `flock -s` on the copy's `.lock`
  (theOrg's mirroring rule: it waits for a running backup) it empties the stage, copies the files
  `manifest.sha256` names and the manifest, checks them with `sha256sum -c`, copies `STATUS` last
  and chowns the stage to this user. That the images carry `flock`, `sha256sum` and `find` is an
  inference (they are Debian-based, and theOrg's own backup scripts use `flock`), not checked on d05.
- The mirror, as this user: the stage's `STATUS` must be `OK`; the mirror's `STATUS` is removed
  first, then the named files and `manifest.sha256` are copied, then `STATUS` last, so a mirror cut
  off part-way has no `STATUS`. `.work`, `.prev`, `.lock` and unnamed files never reach the stage or
  the mirror. Files an older manifest named and the current one does not stay in the mirror.
- Tests: `scripts/tests/test_identity_platform_backup_sh.sh` (stubs; the real `mirror-stage.sh`).

## Rebuild from the nas01 mirror (#1101)

After d05 is rebuilt, both copies come back from the nightly mirror above, not from the Mini's
bundle (`identity-platform.sh`'s header, "After a rebuild"). The operator commands, in order, each
run alone from the workstation:

```
cd ~/local/asyla && python3 core/tools/credentials.py exec GITLAB_TOKEN GITEA_TOKEN ASYLA_HOSTS_DEPLOY_USER ASYLA_HOSTS_DEPLOY_TOKEN THEORG_REGISTRY_PULL_TOKEN IDP_KEYCLOAK_DB_PASSWORD IDP_LDAP_ADMIN_PASSWORD -- python3 projects/asyla-hosts/scripts/build_host.py d05 build --apply --confirm d05
cd ~/local/asyla && projects/asyla-hosts/scripts/app_switch.sh d05 identity-platform restore-mirror
cd ~/local/asyla && projects/asyla-hosts/scripts/app_switch.sh d05 identity-platform mirror-check
cd ~/local/asyla && python3 core/tools/credentials.py exec LDAP_PROVISIONER_PASSWORD -- projects/asyla-hosts/scripts/app_switch.sh d05 identity-platform leaf-issue LDAP_PROVISIONER_PASSWORD
cd ~/local/asyla && projects/asyla-hosts/scripts/app_switch.sh d05 identity-platform leaf-schedule-install
cd ~/local/asyla && python3 core/tools/credentials.py exec IDP_LDAP_ADMIN_PASSWORD -- projects/asyla-hosts/scripts/app_switch.sh d05 identity-platform start-openldap IDP_LDAP_ADMIN_PASSWORD
cd ~/local/asyla && python3 core/tools/credentials.py exec IDP_KEYCLOAK_DB_PASSWORD -- projects/asyla-hosts/scripts/app_switch.sh d05 identity-platform start-keycloak IDP_KEYCLOAK_DB_PASSWORD
cd ~/local/asyla && python3 core/tools/credentials.py exec IDP_LDAP_ADMIN_PASSWORD IDP_DEPLOY_DEX_CLIENT_SECRET -- projects/asyla-hosts/scripts/app_switch.sh d05 identity-platform configure IDP_LDAP_ADMIN_PASSWORD IDP_DEPLOY_DEX_CLIENT_SECRET
cd ~/local/asyla && python3 core/tools/credentials.py exec IDP_DEPLOY_DEX_CLIENT_SECRET -- projects/asyla-hosts/scripts/app_switch.sh d05 identity-platform check-reset-off IDP_DEPLOY_DEX_CLIENT_SECRET
cd ~/local/asyla && python3 core/tools/credentials.py exec IDP_DEPLOY_DEX_CLIENT_SECRET -- projects/asyla-hosts/scripts/app_switch.sh d05 identity-platform check-mail-off IDP_DEPLOY_DEX_CLIENT_SECRET
cd ~/local/asyla && projects/asyla-hosts/scripts/app_switch.sh d05 identity-platform cutover-done
```

- `check-mail-off` runs after `configure` (and `check-reset-off`), so `configured` exists and it
  runs in realm mode: it proves mail and "Forgot password?" are off in the restored realm. It
  writes no marker and is not a `cutover-done` gate; a failure (exit 1) stops the runbook here for
  the operator's decision ("Mail off: check-mail-off" above).

- The build: d05 is not disposable, so the operator approves the exact command. The line above is
  for a d05 whose VM is gone: its `vm` phase skips a VM that still exists unless `--recreate`
  (`phase_vm` in `build_host.py`), and the rest of the build then runs on the old VM. For a d05 VM
  that still exists, the build replaces it with `--recreate`; `--confirm d05` is what `build_host.py`
  checks before it destroys d05's VM:

  ```
  cd ~/local/asyla && python3 core/tools/credentials.py exec GITLAB_TOKEN GITEA_TOKEN ASYLA_HOSTS_DEPLOY_USER ASYLA_HOSTS_DEPLOY_TOKEN THEORG_REGISTRY_PULL_TOKEN IDP_KEYCLOAK_DB_PASSWORD IDP_LDAP_ADMIN_PASSWORD -- python3 projects/asyla-hosts/scripts/build_host.py d05 build --apply --recreate --confirm d05
  ```

  Before `cutover-done` the build's `up` starts keycloak-db alone, which `restore-mirror` needs
  running and healthy.
- `restore-mirror` refuses (exit 3, nothing changed) a mirror older than 48 hours, among other
  checks. To restore an older mirror anyway, run `restore-mirror-accept-age` in its place (the same
  switch with the age check off, with a warning):

  ```
  cd ~/local/asyla && projects/asyla-hosts/scripts/app_switch.sh d05 identity-platform restore-mirror-accept-age
  ```

  A copy already restored (a valid `mirror-restored-*` marker) is skipped on a re-run.
- When `restore-mirror` fails part-way (exit 1, or 3 over a target it left not empty), its error
  names `reset-mirror`: it empties, as root, the dirs of each copy whose restore did not finish
  (keycloak: keycloak-db stopped, its data dir too) and removes its marker and stage; a valid
  `mirror-restored-*` is never touched and the NAS mirror is never read or written. It refuses
  (exit 3, nothing changed) past `mirror-checked`, a start or any M5 marker, with an openldap,
  keycloak or backup one-shot container, a symlink or a mount point among its dirs, `APP_ROOT` on
  the NAS share, or data no `restore-mirror` wrote. When it reset keycloak (its last line says so),
  the build's `apps` phase alone starts keycloak-db again on an empty database (`--confirm` is the
  `vm` phase's only; this phase takes the pull token and `start_env`). Then `restore-mirror` again:

  ```
  cd ~/local/asyla && projects/asyla-hosts/scripts/app_switch.sh d05 identity-platform reset-mirror
  cd ~/local/asyla && python3 core/tools/credentials.py exec THEORG_REGISTRY_PULL_TOKEN IDP_KEYCLOAK_DB_PASSWORD IDP_LDAP_ADMIN_PASSWORD -- python3 projects/asyla-hosts/scripts/build_host.py d05 build --apply --only apps --app identity-platform
  cd ~/local/asyla && projects/asyla-hosts/scripts/app_switch.sh d05 identity-platform restore-mirror
  ```

- `mirror-check` compares fresh summaries with the restored ones; exit 1 prints the lines that
  differ. Do not start anything until it exits 0.
- `leaf-issue` goes after `mirror-check`, right before `start-openldap`: the restored slapd does not
  start with an empty TLS volume (theOrg `DEPLOY.md` at `bb456ee`), the restore itself starts no
  slapd, and issuing last keeps the 24-hour leaf fresh for the start and issues nothing when
  `restore-mirror` refuses. If `leaf-issue` refuses over a valid leaf (exit 3), go on.
- On this path the starts, `configure`, `check-reset-off` and `cutover-done` take `mirror-restored-openldap`,
  `mirror-restored-keycloak` and `mirror-checked` in place of `unpacked`, both `restored-*` and
  `counted`; `cutover-done` needs `reset-off` here too. `restore-openldap`, `restore-keycloak` and `count-check` are refused on it.
- Cadence: once before the Mini's rollback window closes, then quarterly as a ticket (not a
  schedule), and after a change to these switches or a theOrg repin. The proof runs on a test01
  replica of d05, never on d05 (the header of the script names the operator's steps):

  ```
  cd ~/local/asyla/projects/asyla-hosts && scripts/tests/test_identity_platform_mirror_restore_test01.sh
  ```

- Tests: `scripts/tests/test_identity_platform_mirror_runbook.py` (this section's switches and
  values against `switch_env`, in order).
