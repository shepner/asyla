# Plan: GitLab-driven Proxmox guest factory + runner bootstrap

## Purpose

- New infrastructure automation lives under **GitLab** ([gitlab.com/asyla](https://gitlab.com/asyla)), starting with a project that **creates Proxmox guests from parameters** and **installs a GitLab Runner** on the new instance as the first software layer.
- **Later**: same pipeline or follow-on jobs add Docker and app-specific setup (aligned with the existing **d03-as-template** pattern in this repo’s docs).
- **Non-goal**: Replace or disrupt the **GitHub-based `asyla`** workflow until explicitly migrated; GitHub remains source of truth for host docs/scripts until then.

## Scope and operating posture

- Guests from this factory are for **lower-criticality** homelab workloads — acceptable downtime, not “household outage” tier. Design for **simplicity and low ongoing cost** (your time, compute, mental load), not maximum resilience.
- **Primary evolution path**: small, readable artifacts (Python + YAML + CI) that **Cursor or similar** can extend or repair without you learning a new stack first.
- **Terraform / HCL**: **deferred by default** — only worth revisiting if this grows into a large, long-lived inventory you want `plan`/`apply` review on; it adds learning curve and state/backend babysitting you explicitly want to avoid for this lane.

## Constraints and preferences

- **No Ansible** — prefer other tooling for provisioning and post-boot steps.
- **Prefer Python (or thin shell + `curl`)** over new declarative infra tools for the factory itself — fewer moving parts, no remote state service, easier for agent-assisted maintenance.
- **SQLite / single-instance apps**: prior discussion (local disk + continuous backup, VM disk on NFS below the guest, etc.) applies to future app data; this plan only covers **VM creation + runner**.

## Prerequisites

- **Self-hosted GitLab Runner** (or other runner) that can reach **Proxmox** and **new guest IPs** on the LAN. GitLab.com SaaS runners cannot drive private Proxmox without a tunnel.
- **Proxmox**: API token (or equivalent), a **template VM** (minimal Debian cloud image + cloud-init), storage for snippets if using `cicustom`, bridges/VLANs matching production.
- **GitLab CI/CD variables** (group or project, masked + protected where applicable): Proxmox API URL/token, SSH key for post-boot, runner registration token (or current GitLab runner auth flow).

## Target pipeline flow

1. **Trigger + inputs**
   - **Preferred**: Keep each guest’s **non-secret** parameters in a **versioned config file** in the factory repo (e.g. `guests/<name>.yaml` or `specs/<name>.yaml`). Same fields you would have passed as CI variables: `name` / hostname, `vmid`, `ip_cidr`, `gateway`, `dns`, `bridge`, `vlan`, `cpu`, `ram_mb`, `disk_gb`, `proxmox_node`, `template_vmid` (or cloud-image storage id), cloud-init template references, SSH **public** keys for bootstrap, etc.
   - **Pipeline**: Run **manually** (or on MR when that file changes) with **one** thin CI variable such as `GUEST_SPEC=guests/myservice.yaml` — Python loads the YAML/JSON and drives provisioning. Optional: GitLab **workflow inputs** to pick the spec path without typing a long variable list.
   - **Secrets** (Proxmox API token, runner registration token, SSH **private** key for post-boot): stay in **GitLab CI/CD variables** only — not in the spec file. The spec may name *which* variable to use or assume standard names (`PROXMOX_TOKEN`, etc.).
   - **Escape hatch**: Ad-hoc runs can still override with CI variables if the script merges **file base + env overrides** (optional MVP+).
2. **Provision**: Job talks to **Proxmox API** — clone template (or create from cloud image), set resources and network, attach **parameterized cloud-init** (snippet upload or API-driven `cicustom`). **Do not** commit secrets into cloud-init in git; generate per-run user-data/network-config in CI if they contain sensitive values.
3. **First boot**: Cloud-init sets hostname, network, SSH keys, base packages (minimal v1 — **runner-first**, not the full d03 `runcmd` chain unless desired later).
4. **Runner install**: After **SSH** (or **qemu-guest-agent**) is reachable, a **second job** installs `gitlab-runner` and registers non-interactively using CI variables. Keeps registration tokens out of long-lived Proxmox snippets.
5. **Output**: Artifact or job log summary: `vmid`, hostname, IP, SSH target, runner name/tag.

**Reference pattern in this repo**: [d03/README.md](../../d03/README.md) (Debian cloud image, Proxmox, cloud-init); [d03/setup/cloud-init-userdata.yml](../../d03/setup/cloud-init-userdata.yml) (structure only — new guests should not hard-code d03 hostname/IP).

## Implementation options (no Ansible)

### Decision (this project)

- **Use Python** (`proxmoxer` or plain `httpx`/`urllib` against the Proxmox REST API) for clone/configure/start/wait; keep **one or two modules** and obvious entrypoints so agents can follow the flow.
- **Do not adopt Terraform** for this factory unless requirements change (many resource types, strict plan/apply review, shared team). That keeps the stack **light** and avoids state files, provider upgrades, and HCL as a prerequisite.

### Terraform vs Python (reference only)

| Criterion | Terraform (e.g. `bpg/proxmox` provider) | Python (`proxmoxer` or `httpx` + API) |
|-----------|----------------------------------------|--------------------------------------|
| **Mental model** | Declared desired state; `plan` before `apply` | Imperative steps: clone, set, start |
| **State** | State file tracks resources (drift, destroy) | No built-in state unless you add it |
| **Review** | Good for “what will change?” in MRs | Easier to eyeball a short script |
| **Learning** | HCL, providers, lifecycle, backends | Reuses one common language; minimal new concepts |
| **Homelab scale** | Fits well once you have several VM types or shared modules | Fits well for **one** factory flow and fast iteration |
| **CI** | `terraform init/plan/apply` + remote state optional | `python provision.py` + optional JSON artifact |

The new GitLab repo (e.g. `proxmox-guest-factory`) holds this code; **secrets only** in GitLab CI/CD variables.

### Ruled out

- **Ansible** — excluded by project preference.

## Phases

1. **MVP**: GitLab repo + CI skeleton; **guest spec file** (YAML) + loader in Python; Proxmox clone + parameterized cloud-init; SSH wait; install + register GitLab Runner; documented spec schema, CI variables for secrets, and template VM requirements.
2. **Harden**: Idempotency or clear errors on duplicate `VMID`; qemu-guest-agent optional; structured job output (JSON artifact).
3. **Extend**: Optional Docker + alignment with d03-style setup scripts (still optional to pull from GitHub until mirrored to GitLab).

## Related context

- Existing d03 automation pulls setup scripts from **GitHub** in cloud-init; the factory project can omit that in v1 or point to GitLab mirrors later.
- Personal/homelab: Litestream-style backup for SQLite on guests remains a **separate** concern from this factory; document in guest runbooks when apps land.

## Next actions (checklist)

- [x] Create GitLab project [proxmox-guest-factory](https://gitlab.com/asyla/proxmox-guest-factory); enable CI/CD variables.
- [x] LAN-reachable GitLab Runner (user-operated).
- [ ] Build or designate Proxmox **template VM** (minimal Debian cloud + cloud-init).
- [x] Implement **provision** (`scripts/provision.py`) + **bootstrap-runner** (`scripts/bootstrap_runner.py` + CI job).
- [x] Document guest spec, variables, `env.example`, README.
- [ ] (Optional) Pointer from root [README.md](../../README.md) or [AGENTS.md](../../AGENTS.md) to this plan or the GitLab repo.
