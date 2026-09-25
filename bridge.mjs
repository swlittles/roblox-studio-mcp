// Roblox Studio bridge.
//
// A local HTTP server that the companion Studio plugin long-polls for commands. Every DataModel the plugin
// runs in (edit, play-test server, each play-test client) registers as its own session, so commands can
// target a specific side of a live multiplayer test. Tool handlers live here and are shared by the MCP
// stdio server (server.mjs) and the command line client (cli.mjs) through POST /api/call.

import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import { execFile, execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import zlib from "node:zlib";

export const PORT = Number(process.env.STUDIO_BRIDGE_PORT || 44777);
const HERE = path.dirname(fileURLToPath(import.meta.url));
const POLL_HOLD_MS = 20000;
const SESSION_TTL_MS = 45000;
const LOG_LIMIT = 4000;

const sessions = new Map(); // id -> session
const pendingResults = new Map(); // commandId -> {resolve, timer}
const logs = []; // {seq, time, session, context, player, type, message}
let logSeq = 0;
let commandSeq = 0;

function now() { return Date.now(); }

function sessionSummary(s) {
  return {
    id: s.id, context: s.context, player: s.player || undefined, place: s.place,
    placeId: s.placeId, connectedAgoSec: Math.round((now() - s.firstSeen) / 1000),
    lastSeenAgoSec: Math.round((now() - s.lastSeen) / 1000), testActive: s.testActive,
  };
}

function liveSessions() {
  for (const [id, s] of sessions) {
    if (!s.waiter && now() - s.lastSeen > SESSION_TTL_MS) sessions.delete(id);
  }
  return [...sessions.values()].sort((a, b) => a.firstSeen - b.firstSeen);
}

// Target syntax: "edit" | "server" | "client" | "client:<PlayerName>" | "client:<n>" (1-based) | "<session id>"
export function resolveTarget(target = "edit") {
  const live = liveSessions();
  if (!live.length) throw new Error("No Studio sessions connected. Open a place in Roblox Studio with the StudioBridge plugin installed.");
  const exact = live.find((s) => s.id === target);
  if (exact) return exact;
  const [kind, which] = String(target).split(":");
  // Prefer sessions that are actively polling; a killed Studio leaves a session behind until the TTL expires.
  const matches = live.filter((s) => s.context === kind).sort((a, b) => (a.waiter ? 0 : 1) - (b.waiter ? 0 : 1) || a.firstSeen - b.firstSeen);
  if (!matches.length) {
    throw new Error(`No '${kind}' session. Connected: ${live.map((s) => `${s.context}${s.player ? ":" + s.player : ""}`).join(", ")}`);
  }
  if (!which) return matches[0];
  if (/^\d+$/.test(which)) {
    const s = matches[Number(which) - 1];
    if (!s) throw new Error(`Only ${matches.length} ${kind} session(s) connected.`);
    return s;
  }
  const byName = matches.find((s) => (s.player || "").toLowerCase() === which.toLowerCase());
  if (!byName) throw new Error(`No ${kind} session for player '${which}'. Players: ${matches.map((s) => s.player).join(", ")}`);
  return byName;
}

function dispatch(session, type, args = {}, timeoutMs = 30000) {
  const id = `c${++commandSeq}`;
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      pendingResults.delete(id);
      reject(new Error(`Timed out after ${timeoutMs} ms waiting for ${session.context} session to finish '${type}'.`));
    }, timeoutMs);
    pendingResults.set(id, { resolve, reject, timer });
    session.queue.push({ id, type, args });
    flush(session);
  });
}

function flush(session) {
  if (!session.waiter || !session.queue.length) return;
  const { res, timer } = session.waiter;
  session.waiter = null;
  clearTimeout(timer);
  const commands = session.queue.splice(0);
  send(res, 200, { commands });
}

function send(res, status, body) {
  const data = JSON.stringify(body ?? {});
  res.writeHead(status, { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(data) });
  res.end(data);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on("data", (c) => chunks.push(c));
    req.on("end", () => {
      const text = Buffer.concat(chunks).toString("utf8");
      if (!text) return resolve({});
      try { resolve(JSON.parse(text)); } catch (e) { reject(e); }
    });
    req.on("error", reject);
  });
}

function recordLogs(session, entries) {
  for (const e of entries || []) {
    logs.push({
      seq: ++logSeq, time: e.t ?? now() / 1000, session: session.id, context: session.context,
      player: session.player, type: e.type, message: String(e.message ?? ""),
    });
  }
  if (logs.length > LOG_LIMIT) logs.splice(0, logs.length - LOG_LIMIT);
}

function touch(body) {
  let s = sessions.get(body.id);
  if (!s) {
    s = { id: body.id, firstSeen: now(), queue: [], waiter: null };
    sessions.set(body.id, s);
  }
  Object.assign(s, {
    lastSeen: now(), context: body.context, player: body.player, place: body.place,
    placeId: body.placeId, testActive: body.testActive,
  });
  return s;
}

async function handlePlugin(req, res, route) {
  const body = await readBody(req);
  if (route === "source") return send(res, 200, { source: fs.readFileSync(path.join(HERE, "plugin", "Core.luau"), "utf8") });
  if (!body.id) return send(res, 400, { error: "missing id" });
  const session = touch(body);
  recordLogs(session, body.logs);
  for (const r of body.results || []) {
    const pending = pendingResults.get(r.commandId);
    if (!pending) continue;
    pendingResults.delete(r.commandId);
    clearTimeout(pending.timer);
    pending.resolve(r);
  }
  if (route === "bye") {
    sessions.delete(session.id);
    return send(res, 200, {});
  }
  if (route === "push") return send(res, 200, {});
  // route === "poll": hold the request open until a command arrives.
  if (session.waiter) { clearTimeout(session.waiter.timer); send(session.waiter.res, 200, { commands: [] }); }
  const timer = setTimeout(() => {
    if (session.waiter?.res === res) { session.waiter = null; session.lastSeen = now(); send(res, 200, { commands: [] }); }
  }, POLL_HOLD_MS);
  session.waiter = { res, timer };
  req.on("close", () => { if (session.waiter?.res === res) { clearTimeout(timer); session.waiter = null; } });
  flush(session);
}

// ---------------------------------------------------------------------------------------------------------
// Rojo-compatible project reader used by sync_project. Supports $className, $path, $properties, nested
// instances and the usual file conventions (*.server.luau, *.client.luau, init.*, folders, .txt, .json).

const SCRIPT_RULES = [
  [/\.server\.(luau|lua)$/, "Script"],
  [/\.client\.(luau|lua)$/, "LocalScript"],
  [/\.(luau|lua)$/, "ModuleScript"],
];

function scriptClass(file) {
  for (const [re, cls] of SCRIPT_RULES) if (re.test(file)) return [cls, file.replace(re, "")];
  return null;
}

function readFsNode(full, name) {
  const stat = fs.statSync(full);
  if (stat.isDirectory()) {
    const entries = fs.readdirSync(full).filter((f) => !f.startsWith("."));
    const initFile = entries.find((f) => /^init(\.server|\.client)?\.(luau|lua)$/.test(f));
    const node = { name, className: "Folder", children: [] };
    if (initFile) {
      node.className = scriptClass(initFile)[0];
      node.source = fs.readFileSync(path.join(full, initFile), "utf8");
    }
    for (const f of entries.sort()) {
      if (f === initFile) continue;
      const child = readFsFile(path.join(full, f), f);
      if (child) node.children.push(child);
    }
    return node;
  }
  return readFsFile(full, name, true);
}

function readFsFile(full, file, keepName = false) {
  const stat = fs.statSync(full);
  if (stat.isDirectory()) return readFsNode(full, file);
  const rule = scriptClass(file);
  if (rule) return { name: keepName && !/\.(luau|lua)$/.test(file) ? file : rule[1], className: rule[0], source: fs.readFileSync(full, "utf8"), children: [] };
  if (file.endsWith(".txt")) return { name: file.slice(0, -4), className: "StringValue", properties: { Value: fs.readFileSync(full, "utf8") }, children: [] };
  return null;
}

function readProjectNode(dir, name, spec) {
  let node = { name, className: spec.$className, children: [] };
  if (spec.$path) {
    const fsNode = readFsNode(path.resolve(dir, spec.$path), name);
    node = { ...fsNode, name, className: spec.$className || fsNode.className };
  }
  if (spec.$properties) node.properties = { ...(node.properties || {}), ...spec.$properties };
  for (const [key, value] of Object.entries(spec)) {
    if (key.startsWith("$")) continue;
    node.children.push(readProjectNode(dir, key, value));
  }
  if (!node.className) node.className = "Folder";
  return node;
}

export function readProject(projectFile) {
  const file = path.resolve(projectFile);
  const spec = JSON.parse(fs.readFileSync(file, "utf8"));
  const root = readProjectNode(path.dirname(file), spec.name || "Project", spec.tree);
  return root;
}

function countScripts(node) {
  return (node.source !== undefined ? 1 : 0) + (node.children || []).reduce((n, c) => n + countScripts(c), 0);
}

// ---------------------------------------------------------------------------------------------------------
// Real window capture (macOS). Uses bin/studio-snap, which briefly brings Studio forward when it sits on
// another Space (for example behind a full-screen editor). Needs Screen Recording permission for the app
// hosting the agent.

function snapHelper() {
  const bin = path.join(HERE, "bin", "studio-snap");
  if (!fs.existsSync(bin)) {
    fs.mkdirSync(path.dirname(bin), { recursive: true });
    execFileSync("swiftc", ["-O", "-o", bin, path.join(HERE, "native", "studio-snap.swift")]);
  }
  return bin;
}

function captureWindow(title = "", width = 1600) {
  const out = path.join(os.tmpdir(), `studio-window-${now()}.png`);
  return new Promise((resolve, reject) => {
    execFile(snapHelper(), [title, out], (err, stdout) => {
      if (err) return reject(new Error(`window capture failed: ${stdout || err.message}`));
      execFile("sips", ["-Z", String(width), out], () => {
        const data = fs.readFileSync(out).toString("base64");
        fs.rmSync(out, { force: true });
        resolve(data);
      });
    });
  });
}

// ---------------------------------------------------------------------------------------------------------
// Bytecode for sessions without loadstring (play-test server/client run through the bundled Fiu VM).
// Fiu understands bytecode versions 3-6, so this uses a pinned Luau 0.700 compiler.

function compileBytecode(code) {
  const compiler = path.join(HERE, "bin", "luau-compile-bc6");
  if (!fs.existsSync(compiler)) return undefined;
  const file = path.join(os.tmpdir(), `bridge-${process.pid}-${++commandSeq}.luau`);
  fs.writeFileSync(file, code);
  try {
    return execFileSync(compiler, ["--binary", "-O1", "-g1", file], { stdio: ["ignore", "pipe", "pipe"] }).toString("base64");
  } catch (e) {
    throw new Error(`Compile error: ${(e.stderr || e.stdout || e.message).toString().replaceAll(file, "code")}`);
  } finally {
    fs.rmSync(file, { force: true });
  }
}

// Minimal PNG encoder for raw RGB buffers from the raycast renderer / EditableImage readback.
const CRC_TABLE = Array.from({ length: 256 }, (_, n) => {
  let c = n;
  for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
  return c >>> 0;
});
function crc32(buf) {
  let c = 0xffffffff;
  for (const b of buf) c = CRC_TABLE[(c ^ b) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}
function pngChunk(type, data) {
  const len = Buffer.alloc(4); len.writeUInt32BE(data.length);
  const td = Buffer.concat([Buffer.from(type, "ascii"), data]);
  const crc = Buffer.alloc(4); crc.writeUInt32BE(crc32(td));
  return Buffer.concat([len, td, crc]);
}
export function encodePng(rgb, width, height) {
  const raw = Buffer.alloc((width * 3 + 1) * height);
  for (let y = 0; y < height; y++) rgb.copy(raw, y * (width * 3 + 1) + 1, y * width * 3, (y + 1) * width * 3);
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(width, 0); ihdr.writeUInt32BE(height, 4);
  ihdr[8] = 8; ihdr[9] = 2; ihdr[10] = 0; ihdr[11] = 0; ihdr[12] = 0;
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    pngChunk("IHDR", ihdr), pngChunk("IDAT", zlib.deflateSync(raw)), pngChunk("IEND", Buffer.alloc(0)),
  ]);
}

// ---------------------------------------------------------------------------------------------------------
// Tool implementations. Each returns {text?, image?} where image is base64 PNG.

function unwrap(result) {
  if (!result.ok) {
    const out = result.output?.length ? `\n--- output ---\n${result.output.join("\n")}` : "";
    throw new Error(`${result.error}${out}`);
  }
  return result;
}

function waitFor(predicate, timeoutMs, stepMs = 250) {
  return new Promise((resolve) => {
    const start = now();
    const tick = () => {
      const value = predicate();
      if (value || now() - start > timeoutMs) return resolve(value);
      setTimeout(tick, stepMs);
    };
    tick();
  });
}

export const tools = {
  studio_status: {
    description: "List connected Roblox Studio sessions (edit DataModel, play-test server and each play-test client).",
    schema: {},
    async run() {
      const live = liveSessions().map(sessionSummary);
      return { text: live.length ? JSON.stringify(live, null, 2) : "No Studio sessions connected." };
    },
  },

  run_luau: {
    description:
      "Execute Luau in a Studio DataModel and return print/warn output plus returned values. Code may yield (task.wait). " +
      "`plugin` is available in scope. Target: edit (default), server, client, client:<PlayerName|n>, or a session id.",
    schema: { code: "string", target: "string?", timeoutSec: "number?" },
    async run({ code, target = "edit", timeoutSec = 30 }) {
      const session = resolveTarget(target);
      const bytecode = session.context === "edit" ? undefined : compileBytecode(code);
      const r = unwrap(await dispatch(session, "run", { code, bytecode }, timeoutSec * 1000 + 2000));
      const parts = [];
      if (r.output?.length) parts.push(r.output.join("\n"));
      if (r.returns?.length) parts.push(`=> ${r.returns.join(", ")}`);
      return { text: parts.join("\n") || "(no output)" };
    },
  },

  get_logs: {
    description: "Read Studio Output (LogService) captured from connected sessions. Use `since` with the last seq to page.",
    schema: { target: "string?", since: "number?", limit: "number?", level: "string?", contains: "string?" },
    async run({ target, since = 0, limit = 200, level, contains }) {
      let entries = logs.filter((e) => e.seq > since);
      if (target) {
        const [kind, who] = target.split(":");
        entries = entries.filter((e) => e.context === kind && (!who || (e.player || "").toLowerCase() === who.toLowerCase()));
      }
      if (level) entries = entries.filter((e) => e.type.toLowerCase().includes(level.toLowerCase()));
      if (contains) entries = entries.filter((e) => e.message.includes(contains));
      entries = entries.slice(-limit);
      const lines = entries.map((e) => `[${e.seq}] ${e.context}${e.player ? ":" + e.player : ""} ${e.type.replace("Message", "")}: ${e.message}`);
      return { text: lines.join("\n") || `(no logs after seq ${since}; latest seq ${logSeq})` };
    },
  },

  screenshot: {
    description:
      "See what Studio shows. Default mode 'window' captures the real Studio window (macOS; briefly brings Studio " +
      "forward if it is on another Space). Use `title` to pick a window (e.g. a multiplayer client's player name). " +
      "mode 'render' asks a session (target: edit|server|client[:name]) for a software raycast render with GUI " +
      "overlay and a GUI text listing; it works without screen access and can move the camera first: " +
      "camera={position:[x,y,z], lookAt:[x,y,z], fov?, release?}. In window mode `camera` is applied to the target " +
      "session before capturing.",
    schema: { mode: "string?", target: "string?", title: "string?", camera: "object?", includeUi: "boolean?", width: "number?", method: "string?", exposure: "number?" },
    async run({ mode = "window", target, title, camera, includeUi = true, width, method, exposure }) {
      const live = liveSessions();
      if (!target) target = live.some((s) => s.context === "client") ? "client" : "edit";
      if (mode === "window") {
        if (camera) {
          const session = resolveTarget(target);
          await dispatch(session, "camera", { camera }, 10000).catch(() => {});
        }
        const edit = live.find((s) => s.context === "edit");
        const png = await captureWindow(title ?? edit?.place ?? "", width ?? 1600);
        return { image: png, text: `window capture${title ? ` (${title})` : ""}` };
      }
      const session = resolveTarget(target);
      const r = unwrap(await dispatch(session, "screenshot", { camera, includeUi, width, method: method ?? "raycast", exposure }, 90000));
      const png = r.png ?? encodePng(Buffer.from(r.rgb, "base64"), r.width, r.height).toString("base64");
      const texts = r.texts?.length ? `\nGUI text:\n${r.texts.join("\n")}` : "";
      return { image: png, text: `${session.context}${session.player ? ":" + session.player : ""} ${r.method} ${r.width}x${r.height}${texts}` };
    },
  },

  sync_project: {
    description:
      "Push scripts from a Rojo project file into the open place (edit mode only). Creates/updates scripts and folders, " +
      "removes previously synced instances that no longer exist on disk.",
    schema: { project: "string" },
    async run({ project }) {
      const tree = readProject(project);
      const session = resolveTarget("edit");
      const r = unwrap(await dispatch(session, "sync", { tree }, 60000));
      return { text: `Synced ${countScripts(tree)} scripts. ${r.returns?.join(" ") || ""}`.trim() };
    },
  },

  start_test: {
    description:
      "Start a Studio test from the edit DataModel. mode: play (solo, default), run (server only), multiplayer " +
      "(players 1-8 simulated clients). Waits until the server and client sessions connect.",
    schema: { mode: "string?", players: "number?", waitSec: "number?" },
    async run({ mode = "play", players = 1, waitSec = 90 }) {
      const edit = resolveTarget("edit");
      if (liveSessions().some((s) => s.context === "server")) throw new Error("A test is already running. Call stop_test first.");
      unwrap(await dispatch(edit, "test", { mode, players }, 15000));
      const wantClients = mode === "run" ? 0 : mode === "multiplayer" ? players : 1;
      const ok = await waitFor(() => {
        const live = liveSessions();
        return live.some((s) => s.context === "server") && live.filter((s) => s.context === "client" && s.player).length >= wantClients;
      }, waitSec * 1000);
      const live = liveSessions().map((s) => `${s.context}${s.player ? ":" + s.player : ""}`);
      return { text: `${ok ? "Test running" : "Test started but not all sessions connected yet"}. Sessions: ${live.join(", ")}` };
    },
  },

  stop_test: {
    description: "End the running Studio test session.",
    schema: {},
    async run() {
      const server = resolveTarget("server");
      await dispatch(server, "endtest", {}, 8000).catch(() => {});
      await waitFor(() => !liveSessions().some((s) => s.context === "server" || s.context === "client"), 20000);
      for (const [id, s] of sessions) if (s.context !== "edit") sessions.delete(id);
      return { text: "Test stopped." };
    },
  },

  add_players: {
    description: "Add simulated clients to a running multiplayer test.",
    schema: { players: "number" },
    async run({ players }) {
      const before = liveSessions().filter((s) => s.context === "client").length;
      unwrap(await dispatch(resolveTarget("server"), "addplayers", { players }, 15000));
      await waitFor(() => liveSessions().filter((s) => s.context === "client" && s.player).length >= before + players, 60000);
      return { text: `Clients: ${liveSessions().filter((s) => s.context === "client").map((s) => s.player).join(", ")}` };
    },
  },

  list_gui: {
    description: "List the PlayerGui hierarchy of a play-test client with positions, visibility and text.",
    schema: { target: "string?" },
    async run({ target = "client" }) {
      const r = unwrap(await dispatch(resolveTarget(target), "gui", {}, 20000));
      return { text: r.returns.join("\n") };
    },
  },

  reload_plugin: {
    description: "Hot-reload the StudioBridge core (plugin/Core.luau) in every connected session.",
    schema: {},
    async run() {
      const live = liveSessions();
      await Promise.all(live.map((s) => dispatch(s, "reload", {}, 8000).catch(() => {})));
      await new Promise((r) => setTimeout(r, 1500));
      return { text: `Reloaded ${live.length} session(s).` };
    },
  },

  get_tree: {
    description: "Describe the instance hierarchy under a path such as 'Workspace.Camp' (dot separated from game).",
    schema: { path: "string?", depth: "number?", target: "string?" },
    async run({ path: p = "Workspace", depth = 2, target = "edit" }) {
      const r = unwrap(await dispatch(resolveTarget(target), "tree", { path: p, depth }, 20000));
      return { text: r.returns.join("\n") };
    },
  },
};

export async function callTool(name, args = {}) {
  const tool = tools[name];
  if (!tool) throw new Error(`Unknown tool ${name}. Available: ${Object.keys(tools).join(", ")}`);
  return tool.run(args);
}

// ---------------------------------------------------------------------------------------------------------

export function startBridge() {
  return new Promise((resolve, reject) => {
    const server = http.createServer(async (req, res) => {
      try {
        const url = new URL(req.url, `http://127.0.0.1:${PORT}`);
        const [, area, route] = url.pathname.split("/");
        if (area === "plugin" && req.method === "POST") return await handlePlugin(req, res, route);
        if (area === "api" && route === "ping") return send(res, 200, { bridge: "roblox-studio-bridge", pid: process.pid });
        if (area === "api" && route === "call" && req.method === "POST") {
          const { tool, args } = await readBody(req);
          try { return send(res, 200, { ok: true, result: await callTool(tool, args) }); }
          catch (e) { return send(res, 200, { ok: false, error: e.message }); }
        }
        send(res, 404, { error: "not found" });
      } catch (e) {
        send(res, 500, { error: e.message });
      }
    });
    server.requestTimeout = 0;
    server.headersTimeout = 0;
    server.once("error", reject);
    server.listen(PORT, "127.0.0.1", () => resolve(server));
  });
}

export async function bridgeRunning() {
  try {
    const r = await fetch(`http://127.0.0.1:${PORT}/api/ping`, { signal: AbortSignal.timeout(1500) });
    return (await r.json()).bridge === "roblox-studio-bridge";
  } catch { return false; }
}

export async function remoteCall(tool, args) {
  const r = await fetch(`http://127.0.0.1:${PORT}/api/call`, {
    method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ tool, args }),
  });
  const body = await r.json();
  if (!body.ok) throw new Error(body.error);
  return body.result;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  startBridge().then(() => console.error(`roblox-studio-bridge listening on 127.0.0.1:${PORT}`)).catch((e) => {
    console.error(e.message); process.exit(1);
  });
}
