# Cloudflare Tunnel Setup for d03

This document describes the Cloudflare Tunnel setup for d03, which provides internet access to applications without port forwarding. This is the **reference implementation** for all future applications on d03 and for migrating apps from other hosts (d01, etc.).

## Overview

- **No port forwarding required**: All traffic is outbound from d03 to Cloudflare
- **Per-application Docker networks**: Each app runs on its own isolated network (`{app}_net`)
- **Cloudflare Access by default**: All apps are protected with Cloudflare Access authentication
- **Automated setup**: Config-driven with scripts for adding new apps

## Architecture

```
Internet → Cloudflare → Tunnel → cloudflared (Docker) → App Network → App Container
```

- **cloudflared** runs as a Docker container on d03
- **cloudflared** is attached to each app's Docker network (e.g. `tc_datalogger_net`)
- Each app is accessed via `http://<service-name>:<port>` on its network
- No host ports needed - cloudflared resolves service names via Docker DNS

## Initial Setup

### 1. Create Cloudflare Tunnel

1. Go to **Cloudflare Zero Trust** dashboard (or **Networks** → **Tunnels**)
2. Click **Create a tunnel**
3. Name it `d03` (or your preferred name)
4. Choose **Cloudflared** as the connector type
5. Copy the **tunnel token** (or save the installation command)

### 2. Configure Tunnel Token on d03

On d03, create `.env` file in `~/scripts/d03/cloudflared/`:

```bash
cd ~/scripts/d03/cloudflared
cp .env.example .env
# Edit .env and add your TUNNEL_TOKEN
```

**Important**: Do NOT commit `.env` to git - it contains secrets.

### 3. Start cloudflared

```bash
cd ~/scripts/d03/cloudflared
docker compose up -d
```

Verify it's running:
```bash
docker logs cloudflared-d03
```

### 4. Configure First App (TC_datalogger)

The first app (TC_datalogger) is already configured in `apps.yml`. Set up Cloudflare:

#### Public Hostname

1. Go to: **Zero Trust** → **Networks** → **Tunnels** → **d03**
2. Click **Configure** → **Public Hostnames** → **Add a public hostname**
3. Configure:
   - **Subdomain**: `tc-datalogger`
   - **Domain**: `asyla.org`
   - **Service**: `HTTP`
   - **URL**: `http://tc-dashboard:8080`
4. Save

#### DNS

Cloudflare should auto-create the CNAME. If not, create manually:
- **Type**: CNAME
- **Name**: `tc-datalogger`
- **Target**: `<tunnel-id>.cfargotunnel.com` (from tunnel details)

#### Access Application

1. Go to: **Zero Trust** → **Access** → **Applications**
2. Click **Add an application** → **Self-hosted**
3. Configure:
   - **Application name**: `TC Datalogger`
   - **Application domain**: `tc-datalogger.asyla.org`
   - **Session duration**: Choose (e.g. 24 hours)
4. Add **Access policies**:
   - **Policy name**: `Allow authenticated users`
   - **Action**: Allow
   - **Include**: Choose who can access (e.g. email list, one-time PIN, identity provider)
5. Save

### 5. Verify

From the internet, visit: `https://tc-datalogger.asyla.org`

You should:
1. See Cloudflare Access login page
2. After authentication, reach the TC_datalogger dashboard

## Adding a New Application

### Automated Method (Recommended)

Use the `add-tunnel-app.sh` script:

```bash
cd ~/scripts/d03/scripts
./add-tunnel-app.sh <app-name> <hostname> <service> <port> [access]

# Example:
./add-tunnel-app.sh my_app my-app my-service 8080 true
```

The script will:
1. Add entry to `apps.yml`
2. Update cloudflared compose to include app network
3. Output Cloudflare dashboard steps

Then:
1. Ensure your app's compose file defines `{app}_net` network and attaches all services to it
2. Follow the Cloudflare steps output by the script
3. Restart cloudflared: `cd ~/scripts/d03/cloudflared && docker compose up -d`

### Manual Method

1. **App Compose File**: Ensure your app has:
   ```yaml
   networks:
     {app}_net:
       name: {app}_net
       driver: bridge
   
   services:
     your-service:
       # ... other config ...
       networks:
         - {app}_net
   ```

2. **Add to apps.yml**: Add entry to `~/scripts/d03/cloudflared/apps.yml`:
   ```yaml
   - app: {app_name}
     hostname: {hostname}
     service: {service_name}
     port: {port}
     access: true
   ```

3. **Update cloudflared compose**: Add network to `~/scripts/d03/cloudflared/docker-compose.yml`:
   - Add `- {app}_net` to `services.cloudflared.networks`
   - Add network definition:
     ```yaml
     {app}_net:
       external: true
       name: {app}_net
     ```

4. **Cloudflare Dashboard**: Follow steps from "Configure First App" above

5. **Restart cloudflared**: `cd ~/scripts/d03/cloudflared && docker compose up -d`

## Per-Application Networks

**Convention**: Each application has its own Docker network named `{app}_net` (lowercase, underscores).

**Benefits**:
- Network isolation between apps
- No cross-app traffic unless explicitly connected
- cloudflared is the only container on multiple networks

**Example**: TC_datalogger uses `tc_datalogger_net`. All TC_datalogger services (pipelines, dashboard) attach to this network only.

## Configuration Files

### apps.yml

Single source of truth for all exposed apps. Located at: `~/scripts/d03/cloudflared/apps.yml`

Schema:
```yaml
domain: asyla.org

apps:
  - app: app_name          # Used for network name: {app}_net
    hostname: subdomain    # Full hostname: {hostname}.{domain}
    service: service_name   # Docker service/container name
    port: 8080             # Port service listens on
    access: true           # Enable Cloudflare Access (default: true)
```

### cloudflared/docker-compose.yml

Defines the cloudflared service and which app networks it connects to.

## Internal access (split DNS)

If Pi-hole or another internal DNS resolves `tc-datalogger.asyla.org` to d03’s IP, use the **internal reverse proxy** so the same URL works on the LAN without going through Cloudflare:

```bash
cd ~/scripts/d03/internal-proxy
docker compose up -d
```

See [../internal-proxy/README.md](../internal-proxy/README.md). TLS is self-signed (accept once in the browser).

## Troubleshooting

### cloudflared can't reach app

1. Verify app network exists: `docker network ls | grep {app}_net`
2. Verify cloudflared is on the network: `docker network inspect {app}_net`
3. Verify service name and port are correct in Cloudflare Public Hostname
4. Check app logs: `docker logs {container-name}`

### Access login page doesn't appear

1. Verify Access application exists in Zero Trust dashboard
2. Verify Access application domain matches Public Hostname
3. Check Access policies are configured correctly

### DNS not resolving

1. Verify CNAME exists in Cloudflare DNS
2. Check CNAME target matches tunnel ID
3. Wait for DNS propagation (can take a few minutes)

## Migrating Apps from Other Hosts

When migrating an app from d01 (or other hosts) to this model:

1. **On d03**: Follow "Adding a New Application" steps above
2. **Update DNS**: Point existing hostname to new tunnel (CNAME to tunnel)
3. **Test**: Verify app is accessible via tunnel
4. **On d01**: Remove app from SWAG proxy configs (if applicable)
5. **Cleanup**: Remove old port forwarding or SWAG configs

Same pattern applies for all hosts - each host gets its own tunnel, per-app networks, and config-driven setup.

## Reference

- [Cloudflare Tunnel Documentation](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/)
- [Cloudflare Access Documentation](https://developers.cloudflare.com/cloudflare-one/policies/access/)
- [cloudflared Docker Image](https://hub.docker.com/r/cloudflare/cloudflared)
