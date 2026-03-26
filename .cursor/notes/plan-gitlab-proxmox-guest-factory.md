# Plan: GitLab-driven Proxmox guest factory + runner bootstrap

## Purpose

- New infrastructure automation lives under **GitLab** ([gitlab.com/asyla](https://gitlab.com/asyla)), starting with a project that **creates Proxmox guests from parameters** and **installs a GitLab Runner** on the new instance as the first software layer.
- **Later**: same pipeline or follow-on jobs add Docker and app-specific setup (aligned with the existing **d03-as-template** pattern in this repo’s docs).
- **Non-goal**: Replace or disrupt the **GitHub-based `asyla`** workflow until explicitly migrated; GitHub remains source of truth for host docs/scripts until then.

## Constraints and preferences

- **No Ansible** — prefer other tooling for provisioning and post-boot steps.
- **SQLite / single-instance apps**: prior discussion (local disk + continuous backup, VM disk on NFS below the guest, etc.) applies to future app data; this plan only covers **VM creation + runner**.

## Prerequisites

- **Self-hosted GitLab Runner** (or other runner) that can reach **Proxmox** and **new guest IPs** on the LAN. GitLab.com SaaS runners cannot drive private Proxmox without a tunnel.
- **Proxmox**: API token (or equivalent), a **template VM** (minimal Debian cloud image + cloud-init), storage for snippets if using `cicustom`, bridges/VLANs matching production.
- **GitLab CI/CD variables** (group or project, masked + protected where applicable): Proxmox API URL/token, SSH key for post-boot, runner registration token (or current GitLab runner auth flow).

## Target pipeline flow

1. **Trigger**: Manual pipeline with **CI variables** (and optionally GitLab **workflow inputs** when available): e.g. `GUEST_NAME`, `VMID`, `IP_CIDR`, `GATEWAY`, `DNS`, `BRIDGE`, `VLAN`, `CPU`, `RAM_MB`, `DISK_GB`, `PROXMOX_NODE`, `TEMPLATE_VMID` (or cloud-image storage path).
2. **Provision**: Job talks to **Proxmox API** — clone template (or create from cloud image), set resources and network, attach **parameterized cloud-init** (snippet upload or API-driven `cicustom`). **Do not** commit secrets into cloud-init in git; generate per-run user-data/network-config in CI if they contain sensitive values.
3. **First boot**: Cloud-init sets hostname, network, SSH keys, base packages (minimal v1 — **runner-first**, not the full d03 `runcmd` chain unless desired later).
4. **Runner install**: After **SSH** (or **qemu-guest-agent**) is reachable, a **second job** installs `gitlab-runner` and registers non-interactively using CI variables. Keeps registration tokens out of long-lived Proxmox snippets.
5. **Output**: Artifact or job log summary: `vmid`, hostname, IP, SSH target, runner name/tag.

**Reference pattern in this repo**: [d03/README.md](../../d03/README.md) (Debian cloud image, Proxmox, cloud-init); [d03/setup/cloud-init-userdata.yml](../../d03/setup/cloud-init-userdata.yml) (structure only — new guests should not hard-code d03 hostname/IP).

## Implementation options (no Ansible)

### Terraform vs Python (decision aid)

| Criterion | Terraform (e.g. `bpg/proxmox` provider) | Python (`proxmoxer` or `httpx` + API) |
|-----------|----------------------------------------|--------------------------------------|
| **Mental model** | Declared desired state; `plan` before `apply` | Imperative steps: clone, set, start |
| **State** | State file tracks resources (drift, destroy) | No built-in state unless you add it |
| **Review** | Good for “what will change?” in MRs | Easier to eyeball a short script |
| **Learning** | HCL, providers, lifecycle, backends | Python only if already comfortable |
| **Homelab scale** | Fits well once you have several VM types or shared modules | Fits well for **one** factory flow and fast iteration |
| **CI** | `terraform init/plan/apply` + remote state optional | `python provision.py` + optional JSON artifact |

**Suggestion if undecided**

- **Start with Python** when the goal is a **single, well-defined pipeline** (clone + params + start + wait + SSH) and you want to **ship quickly** without learning HCL and state backends first.
- **Introduce Terraform** when you want **declarative inventory**, **plan/apply gates**, **multiple related resources** (DNS, firewall, buckets), or **team-style review** of infra diffs — migrate or wrap the same Proxmox operations in a provider.

Either choice can live in a **new GitLab repo** under `asyla` (e.g. `proxmox-guest-factory`); keep secrets only in GitLab CI/CD variables.

### Ruled out

- **Ansible** — excluded by project preference.

## Phases

1. **MVP**: GitLab repo + CI skeleton; Proxmox clone + parameterized cloud-init; SSH wait; install + register GitLab Runner; documented variables and template VM requirements.
2. **Harden**: Idempotency or clear errors on duplicate `VMID`; qemu-guest-agent optional; structured job output (JSON artifact).
3. **Extend**: Optional Docker + alignment with d03-style setup scripts (still optional to pull from GitHub until mirrored to GitLab).

## Related context

- Existing d03 automation pulls setup scripts from **GitHub** in cloud-init; the factory project can omit that in v1 or point to GitLab mirrors later.
- Personal/homelab: Litestream-style backup for SQLite on guests remains a **separate** concern from this factory; document in guest runbooks when apps land.

## Next actions (checklist)

- [ ] Create empty GitLab project under `asyla`; enable CI/CD variables.
- [ ] Ensure a LAN-reachable GitLab Runner runs jobs for that project.
- [ ] Build or designate Proxmox **template VM** (minimal Debian cloud + cloud-init).
- [ ] Implement **provision** + **bootstrap-runner** jobs (Python or Terraform per decision above).
- [ ] Document required pipeline variables and a **first-run example** in the new repo’s README.
- [ ] (Optional) Add a one-line pointer from root [README.md](../../README.md) or [AGENTS.md](../../AGENTS.md) to this plan or the GitLab repo when it exists.
