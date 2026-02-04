# Runbook: Adding a New Application to d03 Tunnel

This runbook provides step-by-step instructions for adding a new application to the Cloudflare Tunnel on d03. This is the standard process for all new applications.

## Prerequisites

- Application is already running on d03 (or ready to deploy)
- Application has a Docker Compose file
- You know the service name and port that should be exposed

## Steps

### 1. Prepare Application Compose File

Ensure your app's compose file has:

1. **Per-app network definition**:
   ```yaml
   version: '3.8'
   
   networks:
     {app}_net:
       name: {app}_net
       driver: bridge
   ```

2. **All services attached to the network**:
   ```yaml
   services:
     your-service:
       # ... other config ...
       networks:
         - {app}_net
   ```

**Example**: For an app named `my_app`, use network `my_app_net` (lowercase, underscores).

### 2. Add Application to Config

Use the automated script:

```bash
cd ~/scripts/d03/scripts
./add-tunnel-app.sh <app-name> <hostname> <service> <port> [access]

# Example:
./add-tunnel-app.sh my_app my-app my-service 8080 true
```

**Parameters**:
- `app-name`: Application name (lowercase, underscores) - used for network name `{app}_net`
- `hostname`: Subdomain (e.g. `my-app` → `my-app.asyla.org`)
- `service`: Docker service/container name that will be exposed
- `port`: Port the service listens on
- `access`: `true` (default) to enable Cloudflare Access, `false` to disable

The script will:
- Add entry to `apps.yml`
- Update cloudflared compose to include app network
- Output Cloudflare dashboard steps

### 3. Verify App Network in Compose

Check that cloudflared compose was updated:

```bash
cat ~/scripts/d03/cloudflared/docker-compose.yml
```

Should include your app's network in:
- `services.cloudflared.networks` list
- `networks` section (as external)

### 4. Configure Cloudflare

Follow the steps output by the script, or manually:

#### A. Add Public Hostname

1. Go to: **Cloudflare Zero Trust** → **Networks** → **Tunnels** → **d03**
2. Click **Configure** → **Public Hostnames** → **Add a public hostname**
3. Configure:
   - **Subdomain**: `{hostname}` (from step 2)
   - **Domain**: `asyla.org`
   - **Service**: `HTTP`
   - **URL**: `http://{service}:{port}` (e.g. `http://my-service:8080`)
4. **Enable "Create DNS record"** (or create manually)
5. Save

#### B. Create Access Application (if access=true)

1. Go to: **Zero Trust** → **Access** → **Applications**
2. Click **Add an application** → **Self-hosted**
3. Configure:
   - **Application name**: `{App Name}` (human-readable)
   - **Application domain**: `{hostname}.asyla.org`
   - **Session duration**: Choose (e.g. 24 hours)
4. Add **Access policies**:
   - Click **Add a policy**
   - **Policy name**: `Allow authenticated users`
   - **Action**: Allow
   - **Include**: Choose who can access:
     - **Email**: List of email addresses
     - **One-time PIN**: Users get PIN via email
     - **Identity provider**: Google, GitHub, etc.
   - Save policy
5. Save application

#### C. Verify DNS

1. Go to: **Cloudflare Dashboard** → **DNS** → **Records**
2. Verify CNAME exists:
   - **Type**: CNAME
   - **Name**: `{hostname}`
   - **Target**: `<tunnel-id>.cfargotunnel.com`
3. If missing, create it manually

### 5. Deploy Application

If not already running:

```bash
cd ~/scripts/d03/apps/{app-name}
# Follow app-specific deployment steps
docker compose up -d
```

Verify app is running:
```bash
docker ps | grep {app-name}
docker network ls | grep {app}_net
```

### 6. Restart cloudflared

After adding network to cloudflared compose:

```bash
cd ~/scripts/d03/cloudflared
docker compose up -d
```

Verify cloudflared is on the app network:
```bash
docker network inspect {app}_net | grep cloudflared
```

### 7. Verify End-to-End

1. **Check cloudflared logs**:
   ```bash
   docker logs cloudflared-d03
   ```
   Should show connection to Cloudflare and no errors.

2. **Test from internet**:
   - Visit: `https://{hostname}.asyla.org`
   - Should see Cloudflare Access login (if enabled)
   - After auth, should reach your application

3. **Check app logs**:
   ```bash
   docker logs {service-name}
   ```
   Should show incoming requests.

## Troubleshooting

### App not reachable

1. **Verify network**: `docker network inspect {app}_net` - cloudflared should be listed
2. **Verify service name**: Check Public Hostname URL matches actual service name
3. **Check app logs**: `docker logs {service-name}` - is it listening on the port?
4. **Check cloudflared logs**: `docker logs cloudflared-d03` - any connection errors?

### Access login not appearing

1. Verify Access application exists and domain matches Public Hostname
2. Check Access policies are configured
3. Try incognito/private browsing window

### DNS not resolving

1. Verify CNAME exists in Cloudflare DNS
2. Check CNAME target matches tunnel ID
3. Wait a few minutes for DNS propagation

## Next Steps

- Application is now accessible via `https://{hostname}.asyla.org`
- To add more apps, repeat this process
- To disable Access for an app, set `access: false` in `apps.yml` and remove Access application in Cloudflare

## Reference

- Full documentation: [cloudflare-tunnel.md](cloudflare-tunnel.md)
- Config file: `~/scripts/d03/cloudflared/apps.yml`
- Add script: `~/scripts/d03/scripts/add-tunnel-app.sh`
