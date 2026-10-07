# Cursor agent in this project

This is the **asyla** project. Cursor is expected to **document and improve its own workflows** here.

## How the agent should work

- Keep Cursor-for-Cursor artifacts under `.cursor/` (rules, skills, notes, helpers).
- After non-trivial or repeatable workflows, add a rule/skill/helper so future sessions improve.

## Current artifacts

- Rule: `.cursor/rules/self-document-workflows.mdc`
- Rule: `.cursor/rules/task-complete-commit-push.mdc` — when a task is complete, run commit-and-push in the same turn; do not leave it for the user to ask.

## Open work

- [x] **Roll tc-datalogger `a0d2e1a` out to d03** (handed over 2026-10-07 by the personal-hub session
  that made the change; tc-datalogger is a personal project, the d03 deployment is this repo's).
  `a0d2e1a` removes the k3s leftovers from the dashboard (`k8s_client.py`, the `kubernetes`
  dependency); a data pull now goes only through Docker exec, which is what d03 already uses
  (the compose mounts the Docker socket read-only). Not urgent: d03's current tag `e6ad625` still has
  the k3s code, but it is inactive outside a cluster. **Blocked on** tc-datalogger's open item on
  image names: `stack-build.yml` pushes `gitea.asyla.org/asyla/tc-datalogger/tc-<service>`, while
  `d03/apps/tc-datalogger/compose.yml` pulls `${TC_REGISTRY}/tc-datalogger-<service>`. Once images
  exist under the names the compose pulls: set `TC_IMAGE_TAG` to the full `a0d2e1a` SHA (or later)
  in the d03 host `.env` and `.env.example`, run `tc-datalogger.sh up`, then `tc-datalogger.sh
  verify`, and trigger one data pull from the dashboard.
  **Done 2026-10-07** (by the personal-hub session, at the operator's request): rolled out `ddb2506`
  (`ddb2506879a44446bffa800229c07f16478eff97`), which is `a0d2e1a` plus the image-name fix (`3a8e652`)
  and the dashboard's Docker SDK fix (docker 7.1.0; on `e6ad625` the dashboard logged "Docker SDK
  failed ... http+docker" and fell back to raw HTTP). Set `TC_IMAGE_TAG` in the d03 host `.env` and
  `.env.example`; `tc-datalogger.sh up` recreated all 6 containers on the new tag; `verify` passed
  (local `:8081/login` and public URL); the dashboard logs "Successfully connected to Docker via SDK".
  The dashboard data pull is the operator's to trigger (needs their login). Roll back by setting
  `TC_IMAGE_TAG` back to `e6ad625d741d46d2638f4692afbfe89b959001bc` and running `up`.
