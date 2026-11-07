# iphone-use

## Overview
Codex skill package for driving a physical iPhone via the local `iphone-use` HTTP/MCP server, combining skill instructions with Python service-recovery, MCP transport, and batch device-execution scripts.

## Subdirectories & Boundaries
- [SKILL.md](./SKILL.md) - Operational instructions and workflows for driving a connected iPhone via `phone_exec.py`, `ensure_service.py`, and MCP tools.
- [scripts](./scripts/README.md) - Python CLI utilities for service lifecycle recovery (`ensure_service.py`), stdio MCP tool invocation (`mcp_call.py`), and scripted iPhone UI automation (`phone_exec.py`).
