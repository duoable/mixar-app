# Mixar — Agent Guide

Mixar is an AI-powered 3D content creation desktop tool built as a custom fork of Blender 5.2.
It incorporates real-time AI agents (Mixie), layered texture painting, AI 3D generation, and native editor spaces.
For complete architectural details, see [CLAUDE.md](file:///Users/studio/Git/mixar-app/CLAUDE.md).

## Quick Build & Run (macOS)

```bash
make init          # initializes git submodules and downloads Blender precompiled libraries
make build         # overlays src/ onto upstream/, configures CMake, compiles and installs python packages
make run [Prod]    # launches the built Mixar app (build/Prod/bin/Mixar.app)
```

Alternatively:
- Double-click `./Update and Run Mixar.command` in Finder or run it in terminal.

## Built App Locations

- Executable: `build/Prod/bin/Mixar.app/Contents/MacOS/Mixar`
- Resources / embedded Python: `build/Prod/bin/Mixar.app/Contents/Resources/5.2/python/bin/python3.13`
- User configuration and addons on macOS:
  `~/Library/Application Support/Mixar/5.2/`
  Addons: `~/Library/Application Support/Mixar/5.2/scripts/addons/`

## B.E.L.T. Plugin Integration

The B.E.L.T. plugin repository (`/Users/studio/Git/belt`) is installed as a symlink:
`~/Library/Application Support/Mixar/5.2/scripts/addons/belt` -> `/Users/studio/Git/belt`

Inside Mixar (or standard Blender), any script or AI agent can use B.E.L.T.:
```python
import belt
belt.api.help()                    # List all available tools
belt.api.describe("smart_remesh")  # Inspect tool settings and schema
belt.api.run("smart_remesh", settings={...})  # Execute a tool
```

To run B.E.L.T. smoke tests against Mixar:
```bash
/Users/studio/Git/belt/scripts/dev.sh test mixar
```

## AI Agent Integration & MCP Bridge

Mixar provides a standard Model Context Protocol (MCP) server that external AI assistants (Claude Code, OpenAI Codex, Antigravity, Cursor, VS Code) can use to inspect scenes, execute Blender scripts, operate UI, and create materials.

Launcher script: `src/scripts/mixar/mcp.py`

### Connecting AI Assistants

1. **Claude Code**:
   ```bash
   claude mcp add --scope user mixar -- /usr/bin/python3 /Users/studio/Git/mixar-app/src/scripts/mixar/mcp.py
   ```

2. **OpenAI Codex** (`~/.codex/config.toml`):
   ```toml
   [mcp_servers.mixar]
   command = "/usr/bin/python3"
   args = ["/Users/studio/Git/mixar-app/src/scripts/mixar/mcp.py"]
   tool_timeout_sec = 610
   ```

3. **Antigravity / Gemini CLI** (`~/.gemini/config/mcp_config.json`):
   ```json
   {
     "mcpServers": {
       "mixar": {
         "command": "/usr/bin/python3",
         "args": ["/Users/studio/Git/mixar-app/src/scripts/mixar/mcp.py"]
       }
     }
   }
   ```

4. **Cursor** (`~/.cursor/mcp.json`):
   ```json
   {
     "mcpServers": {
       "mixar": {
         "command": "/usr/bin/python3",
         "args": ["/Users/studio/Git/mixar-app/src/scripts/mixar/mcp.py"]
       }
     }
   }
   ```
