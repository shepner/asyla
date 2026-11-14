# identity-platform (d05)

theOrg's Keycloak (realm `theorg`, https://id.asyla.org), its keycloak-db and the openldap it
federates, moved from the Mac Mini. asyla deploys it from theOrg identity-platform `DEPLOY.md`,
"Production on d05", and `deploy/d05/compose.example.yml` at `701e893` (main, the #82 merge),
carried to `47f65add` (`47f65add39763bc3ccd086e69e4b3c571d85098a`, *Publish images* run 22377
green): keycloak and openldap in profile `restored`, and `deploy/d05/openldap-leaf.sh`. theOrg's
four images are tagged with that sha; the two upstream digests did not change.

This folder is **M1** (agreed with theOrg): `up` creates the two networks, pulls the six images,
places theOrg's root CA, reports on the openldap leaf, and starts **keycloak-db alone**. openldap
and keycloak first start at the M5 cutover (DEPLOY.md steps 5-6), after a restore into empty
targets; `start-openldap`, `start-keycloak` and `restore` refuse until that is written. The ops
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
    `deploy/d05/openldap-leaf.sh` at `47f65add` (git blob `2a59d8431843474857cbafba37c0edf72e9f2729`,
    SHA-256 `eb741790e24672917241d1bfa96846b18e4adaa7e029894e39545c883ddba95c`). Never edit it
    here; a new version is a new copy and a new provenance line. It needs util-linux `flock` on the
    host (d05: util-linux 2.41.5, read 2026-11-14) and pulls `smallstep/step-cli:0.30.2` (pinned by
    digest in the script) from Docker Hub on its first run.
  - `leaf-issue`: networks, the checked root CA, `openldap-tls`, then `openldap-leaf.sh issue`
    (a 24h leaf from step-ca's JWK provisioner `ldap`). Before openldap's first start: osixia
    self-signs when the files are missing. Needs `LDAP_PROVISIONER_PASSWORD`
    (`secret/v2/certificate-management/step-ca/provisioners/ldap`, field `password`), which the
    script takes out of its environment at start and hands only to `openldap-leaf.sh issue` (which
    passes it to docker by name and to step on stdin). Refused without it, over a valid leaf
    (openldap-leaf.sh, exit 3) and on a replica. It is not in `host.toml`'s `start_env` (a start
    runs `up`, which must never get it): the operator runs the leaf switches from the workstation
    with `scripts/app_switch.sh`, which runs one switch over one ssh as build_host.py's
    `env_command` does, each value on ssh stdin (never in an argv), and allows only the switches and
    values in this app's `switch_env` in `d05/host.toml`. The leaf lives 24 hours, so the schedule
    is installed right after the first issue, in the same sitting:

    ```
    cd ~/local/asyla && python3 core/tools/credentials.py exec LDAP_PROVISIONER_PASSWORD -- projects/asyla-hosts/scripts/app_switch.sh d05 identity-platform leaf-issue LDAP_PROVISIONER_PASSWORD
    cd ~/local/asyla && projects/asyla-hosts/scripts/app_switch.sh d05 identity-platform leaf-schedule-install
    ```

    `leaf-schedule-status`, `leaf-renew` and `leaf-schedule-remove` run the same way, with no VAR.
  - `leaf-renew`: `openldap-leaf.sh renew`, no secret (refused when one is set): renews at half
    life over mTLS with the current leaf and reloads slapd when openldap runs. Not on a replica.
  - The schedule (theOrg DEPLOY.md item 13: every 3 hours): `identity-platform-leaf-renew.timer`
    (`OnCalendar=*-*-* 00/3:17:00`, `Persistent=true`, up to 5 min random delay) and its oneshot
    service (a template: `User=` and `ExecStart=` filled in at install), both here. Not installed by
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
    `datetime.fromisoformat` on Python 3.12, reads), `action`, `result` (ok or fail), `exit`,
    `not_after` (the leaf's), `issued_ok` (the last successful issue; `leaf-schedule-install` needs
    it) and `problems`: none when ok; on a failure one problem `leaf`, `warn` (a work item) while the
    leaf has 6 hours or more left, `urgent` when it has less, has expired or cannot be read. No
    secret is in it. host-maintenance alerts on it through its `[[status]]` entry
    `identity-platform-leaf` (`config/maintenance.toml`, `max_age_minutes = 200`), which is there
    commented out until the first `leaf-issue` and `leaf-schedule-install`, because a missing file
    alerts as urgent; uncommenting it is a host-maintenance change approved with those steps.
- No secret is in any file, here or on the host. The workstation resolves them from OpenBao at
  deploy (`d05/host.toml`: `start_env` `IDP_KEYCLOAK_DB_PASSWORD`; `IDP_LDAP_ADMIN_PASSWORD` and
  `IDP_DEPLOY_DEX_CLIENT_SECRET` are M5's, not sent in M1), and `identity-platform.sh` maps them
  onto the compose names (its header). Images are pulled with the theorg-registry token the
  workstation hands over at use (`pull_token_env`, as `IDENTITY_PLATFORM_REGISTRY_PULL_TOKEN`)
  through `docker-credential-identity-platform-env`, under a throwaway `DOCKER_CONFIG`.
- Data: `/mnt/docker/IdentityPlatform/{ca,keycloak-db}` in M1. No backup yet: the system of record
  stays on the Mini until M5.
- Replica (test01 as `[replica] of = "d05"`): `images` pulls what is missing and lists keycloak-db's
  image for build_host.py's egress probe; `up` on a host not named d05 makes the networks, places
  the CA and starts keycloak-db alone with a throwaway password made at run time (a replica gets no
  `start_env`; d05's value is never used there). openldap and keycloak never start on a replica.
