# identity-platform (d05)

theOrg's Keycloak (realm `theorg`, https://id.asyla.org), its keycloak-db and the openldap it
federates, moved from the Mac Mini. asyla deploys it from theOrg identity-platform `DEPLOY.md`,
"Production on d05", and `deploy/d05/compose.example.yml` at `701e893` (main, the #82 merge).

This folder is **M1** (agreed with theOrg): `up` creates the two networks, pulls the six images,
places theOrg's root CA, reports on the openldap leaf, and starts **keycloak-db alone**. openldap
and keycloak first start at the M5 cutover (DEPLOY.md steps 5-6), after a restore into empty
targets; `start-openldap`, `start-keycloak` and `restore` refuse until that is written. The ops
one-shots (backups, keycloak-configure) are never started by `up`.

- `compose.yml`: the example with both networks external, every secret passed by name only,
  `KC_BOOTSTRAP_ADMIN_*` left out, keycloak and openldap in the profile `cutover`, and
  keycloak-configure's settings filled in (its header lists each change).
- Networks (created by `identity-platform.sh up`, idempotent; an existing one with other settings
  is refused, never changed): `identity-platform-net` 10.213.5.64/26, and `identity-platform-edge`
  10.213.5.0/29, `--internal`, gateway .1, ip-range .4/30 (Caddy at .2 from internal-access
  hosts/d05, Keycloak at .3).
- `theorg-v2-root.crt`: theOrg's root ("theOrg-v2 Root CA", expires 2036-08-29), copied from
  internal-access `hosts/d03/upstream-ca/theorg-v2-root.pem`. `up` checks its SHA-256
  (`CD:39:...:87:D3`, also keycloak-configure's `KEYCLOAK_CA_FINGERPRINT`) before placing it at
  `/mnt/docker/IdentityPlatform/ca/root_ca.crt`, and refuses on a mismatch.
- openldap leaf: `/mnt/docker/IdentityPlatform/openldap-tls/{ldap.crt,ldap.key,ca.crt}`, reported
  only. Its renewer is theOrg's (pending); the TODO in `identity-platform.sh` marks where it hooks in.
- No secret is in any file, here or on the host. The workstation resolves them from OpenBao at
  deploy (`d05/host.toml`: `start_env` `IDP_KEYCLOAK_DB_PASSWORD`; `start_env_optional`
  `IDP_LDAP_ADMIN_PASSWORD`, `IDP_DEPLOY_DEX_CLIENT_SECRET`), and `identity-platform.sh` maps them
  onto the compose names (its header). Images are pulled with the theorg-registry token the
  workstation hands over at use (`pull_token_env`, as `IDENTITY_PLATFORM_REGISTRY_PULL_TOKEN`)
  through `docker-credential-identity-platform-env`, under a throwaway `DOCKER_CONFIG`.
- Data: `/mnt/docker/IdentityPlatform/{ca,keycloak-db}` in M1. No backup yet: the system of record
  stays on the Mini until M5.
