This directory contains Cursor-for-Cursor artifacts for this project.

- **audit_update_all.sh** – Run locally to audit `update_all.sh` runs on remote hosts. SSHs to each host (default: d01 d02 d03 ns01 ns02), fetches `~/logs/update_all/latest` → `summary.txt`, and reports pass/fail. Usage: `./audit_update_all.sh [host...]`
