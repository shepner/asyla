# Runbook: Migrating an Application from d01 to d03 Tunnel Model

This runbook describes how to migrate an application from d01 (SWAG-based) to d03 (Cloudflare Tunnel model). This same pattern applies to migrating from any host to the tunnel model.

## Overview

**Goal**: Move an application from d01 (exposed via SWAG) to d03 (exposed via Cloudflare Tunnel), maintaining the same public hostname and functionality.

**Benefits**:
- No port forwarding required
- Independent of d01 (no single point of failure)
- Cloudflare Access authentication
- Per-app network isolation

## Prerequisites

- Application is already running on d01 (or ready to deploy on d03)
- Application has a Docker Compose file (or can be containerized)
- You have access to Cloudflare Zero Trust dashboard
- You know the current public hostname (e.g. `app.asyla.org`)

## Migration Steps

### Phase 1: Set Up Application on d03

#### 1. Deploy Application on d03

1. **Copy or create app compose file**:
   - If app exists on d01, copy compose file to `d03/apps/{app-name}/compose.yml`
   - Ensure compose file follows d03 conventions (per-app network, etc.)

2. **Update compose for per-app network**:
   ```yaml
   version: '3.8'
   
   networks:
     {app}_net:
       name: {app}_net
       driver: bridge
   
   services:
     your-service:
       # ... config ...
       networks:
         - {app}_net
   ```

3. **Deploy app on d03**:
   ```bash
   cd ~/scripts/d03/apps/{app-name}
   # Follow app-specific setup (credentials, config, etc.)
   docker compose up -d
   ```

4. **Verify app is running**:
   ```bash
   docker ps | grep {app-name}
   docker network ls | grep {app}_net
   ```

#### 2. Add to Cloudflare Tunnel

Follow the [Adding a New Application runbook](runbook-add-app.md):

```bash
cd ~/scripts/d03/scripts
./add-tunnel-app.sh {app-name} {hostname} {service} {port} true
```

**Use the same hostname** as currently used on d01 (e.g. if d01 has `app.asyla.org`, use `app` as hostname).

#### 3. Configure Cloudflare

1. **Add Public Hostname** in Cloudflare Tunnel (same hostname as d01)
2. **Create Access Application** (if not already exists for this hostname)
3. **DNS**: Point hostname to tunnel (CNAME to `<tunnel-id>.cfargotunnel.com`)

**Important**: At this point, DNS still points to d01, so traffic still goes to d01.

### Phase 2: Test Tunnel Access

#### 1. Test via Tunnel Directly

You can test the tunnel before switching DNS:

1. **Get tunnel hostname**: From Cloudflare Tunnel → d03 → Details, note the tunnel hostname (e.g. `abc123.cfargotunnel.com`)
2. **Add hosts entry** (temporary, for testing):
   ```bash
   # On your workstation
   echo "abc123.cfargotunnel.com {hostname}.asyla.org" | sudo tee -a /etc/hosts
   ```
3. **Test**: Visit `https://{hostname}.asyla.org` - should reach d03 via tunnel
4. **Remove hosts entry** after testing:
   ```bash
   sudo sed -i '/abc123.cfargotunnel.com/d' /etc/hosts
   ```

#### 2. Verify Functionality

- Access login works (if Access enabled)
- Application loads correctly
- All features work as expected
- Compare with d01 version to ensure parity

### Phase 3: Switch DNS and Verify

#### 1. Update DNS Record

In Cloudflare DNS:

1. Find existing A record or CNAME for `{hostname}.asyla.org`
2. **Change to CNAME** (if A record):
   - **Type**: CNAME
   - **Name**: `{hostname}`
   - **Target**: `<tunnel-id>.cfargotunnel.com`
3. **Or update CNAME target** (if already CNAME):
   - Change target from d01's IP or hostname to `<tunnel-id>.cfargotunnel.com`

**DNS propagation**: Usually takes 1-5 minutes, can take up to 24 hours globally.

#### 2. Verify DNS Switch

```bash
# Check DNS resolution
dig {hostname}.asyla.org +short
# Should return tunnel hostname (e.g. abc123.cfargotunnel.com)

# Or use nslookup
nslookup {hostname}.asyla.org
```

#### 3. Test Production Access

1. Visit `https://{hostname}.asyla.org` from internet
2. Should see Cloudflare Access login (if enabled)
3. After auth, should reach application on d03
4. Verify all functionality works

### Phase 4: Cleanup d01

**Wait 24-48 hours** to ensure all users have switched to new DNS, then:

#### 1. Remove from SWAG (if applicable)

On d01:

1. Remove proxy config from SWAG:
   ```bash
   # Remove or rename proxy config file
   rm /docker/swag/config/nginx/proxy-confs/{app}.subdomain.conf
   # Or move to disabled:
   mv /docker/swag/config/nginx/proxy-confs/{app}.subdomain.conf \
      /docker/swag/config/nginx/proxy-confs/{app}.subdomain.conf.disabled
   ```

2. Restart SWAG:
   ```bash
   docker restart swag
   ```

#### 2. Remove Certificate (optional)

If SWAG cert included this subdomain:

1. Update SWAG `SUBDOMAINS` or `EXTRA_DOMAINS` env (remove subdomain)
2. Restart SWAG (cert will be updated on next renewal)

#### 3. Stop Application on d01 (if moved)

If application was moved (not duplicated):

```bash
# On d01
cd ~/scripts/docker/{app-name}
docker compose down
# Or remove if using shell scripts
```

#### 4. Remove Port Forwarding (if applicable)

If this was the only app using port forwarding on d01, you can remove port forwarding rules from your router (80/443 → d01). **Only do this after all apps are migrated**.

## Rollback Plan

If issues occur after DNS switch:

1. **Revert DNS**: Change CNAME back to d01 (or A record to d01 IP)
2. **Restore SWAG config**: Re-enable proxy config on d01
3. **Restart SWAG**: `docker restart swag` on d01
4. **Investigate**: Check d03 tunnel logs, app logs, network connectivity

## Post-Migration Checklist

- [ ] Application accessible via tunnel
- [ ] Cloudflare Access working (if enabled)
- [ ] All features functional
- [ ] DNS fully propagated (check from multiple locations)
- [ ] SWAG config removed from d01
- [ ] Application stopped/removed from d01 (if moved)
- [ ] Documentation updated

## Multiple Applications

To migrate multiple applications:

1. **Migrate one at a time** (easier troubleshooting)
2. **Test each thoroughly** before moving to next
3. **Use same pattern** for all apps
4. **Batch cleanup** on d01 after all are migrated

## Reference

- [Adding a New Application](runbook-add-app.md)
- [Cloudflare Tunnel Documentation](cloudflare-tunnel.md)
- [Cloudflare Tunnel Setup](cloudflare-tunnel.md#initial-setup)
