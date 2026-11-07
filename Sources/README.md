# Sources

## Overview
Swift source root for the `iphone-use` package, containing the `iPhoneUse` executable target (`Sources/iPhoneUse`) that implements the macOS desktop application, localhost HTTP control API, stdio MCP server, CLI runner, USB video capture/lockdown channels, Bluetooth LE HID peripheral, and Gemini autonomous task executor.

## Subdirectories & Boundaries
- `iPhoneUse`: [./iPhoneUse/README.md](./iPhoneUse/README.md) - Main `iPhoneUse` executable target entrypoint (`main.swift`) and its 12 subsystem modules (`API`, `App`, `Bluetooth`, `CLI`, `Capture`, `Devices`, `Input`, `Localization`, `MCP`, `Task`, `UI`, `USB`).
