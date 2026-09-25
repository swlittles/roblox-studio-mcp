# roblox-studio-bridge MCP

An MCP server that lets an agent drive Roblox Studio: run Luau in any DataModel, sync a Rojo project into the
open place, start solo or multiplayer play tests, read Output, inspect GUIs and **see the game**.

## How it works

```
agent ──MCP stdio──▶ server.mjs ──▶ bridge.mjs (HTTP 127.0.0.1:44777) ◀──long-poll── StudioBridge plugin
                                                                          ├─ edit DataModel
                                                                          ├─ play-test server
                                                                          └─ play-test clients (relayed via the server)
```

- **Plugin** (`plugin/StudioBridge.server.luau`): a small bootstrap. In edit mode it downloads
  `plugin/Core.luau` from the bridge, so `reload_plugin` applies core changes without restarting Studio.
  Play-test DataModels use the copy bundled into the plugin.
- **Play-test clients** cannot use HttpService, so the server session relays their traffic through a
  RemoteEvent, with large results sent in chunks.
- **Code execution:** `loadstring` in edit mode. Play-test server and clients have no `loadstring`, so the
  bridge compiles the code with a pinned Luau 0.700 compiler (`bin/luau-compile-bc6`) and the bundled
  [Fiu](https://github.com/rce-incorporated/Fiu) VM runs the bytecode.
- **Screenshots:** by default `screenshot` captures the real Studio window with `bin/studio-snap` (macOS,
  needs Screen Recording permission for the app hosting the agent). If Studio is on another Space behind a
  full-screen app, it is brought forward for about a second and the previous app is restored.
- **Software render fallback (`mode: "render"`):** Studio's `StudioCaptureService` is feature-flagged off in current builds, and
  `CaptureService` captures can't be read back. The plugin falls back to a software **raycast renderer**
  (sun/moon plus point and spot lights with shadows, fog and sky), then overlays the visible GUI with the same
  z-order and clipping rules Roblox uses. It also renders ViewportFrame contents and returns every visible
  text string with its position. It works in edit mode, on the server and on each client, with no screen
  access.

## Tools

| Tool | Purpose |
|---|---|
| `studio_status` | Connected sessions (edit, server, `client:<Player>`) |
| `run_luau` | Run Luau (may yield) in `edit`/`server`/`client[:name\|n]`; returns prints + return values |
| `get_logs` | Output from all sessions, filter by target/level/text, page with `since` |
| `screenshot` | Real Studio window capture (default), or `mode:"render"` software render of a session; optional `camera {position, lookAt, fov, release}`, `title`, `width` |
| `list_gui` | A client's PlayerGui tree with positions, visibility and text |
| `sync_project` | Push a Rojo project's scripts into the open place (edit mode) |
| `start_test` / `stop_test` | `play`, `run`, or `multiplayer` with 1–8 simulated clients |
| `add_players` | Add clients to a running multiplayer test |
| `get_tree` | Instance hierarchy under a path |
| `reload_plugin` | Hot-reload `plugin/Core.luau` in edit sessions |

`cli.mjs` exposes the same tools from a shell (`node cli.mjs status`,
`node cli.mjs run server < file.luau`, `node cli.mjs shot client out.png '{"width":800}'`). If no bridge is
running, it starts one in the background.

## Install

`scripts/setup.sh` installs dependencies, the pinned compiler, the capture helper and the plugin.
Register the server in any MCP client:

```json
{ "mcpServers": { "roblox-studio": { "command": "node", "args": ["/abs/path/studio-mcp/server.mjs"] } } }
```

## License

MIT, see `LICENSE`. Third-party code: see `THIRD_PARTY_NOTICES.md` (Fiu, MIT).
