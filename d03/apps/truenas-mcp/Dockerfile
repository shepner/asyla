# TrueNAS MCP Server for d03 — see https://github.com/vespo92/TrueNasCoreMCP
# Requires TRUENAS_URL and TRUENAS_API_KEY at runtime (env or .env).

FROM python:3.12-slim

RUN pip install --no-cache-dir truenas-mcp-server

ENTRYPOINT ["truenas-mcp-server"]
