#!/usr/bin/env node
// Command line client for the Studio bridge. Starts a background bridge if none is running.
//
//   node cli.mjs status
//   node cli.mjs run [target] < script.luau        (or: node cli.mjs run edit -e "print(1)")
//   node cli.mjs shot [target|-] [out.png] ['{"mode":"render","camera":{"position":[0,50,0],"lookAt":[0,0,0]}}']
//   node cli.mjs <tool> '<json args>'

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { bridgeRunning, remoteCall } from "./bridge.mjs";

const HERE = path.dirname(fileURLToPath(import.meta.url));

async function ensureBridge() {
  if (await bridgeRunning()) return;
  const log = fs.openSync(path.join(os.tmpdir(), "studio-bridge.log"), "a");
  spawn(process.execPath, [path.join(HERE, "bridge.mjs")], { detached: true, stdio: ["ignore", log, log] }).unref();
  for (let i = 0; i < 40; i++) {
    await new Promise((r) => setTimeout(r, 150));
    if (await bridgeRunning()) return;
  }
  throw new Error("Bridge failed to start; see $TMPDIR/studio-bridge.log");
}

function readStdin() {
  return fs.readFileSync(0, "utf8");
}

const [cmd = "status", ...rest] = process.argv.slice(2);
await ensureBridge();
try {
  let result;
  if (cmd === "status") result = await remoteCall("studio_status", {});
  else if (cmd === "run") {
    const target = rest[0] && rest[0] !== "-e" ? rest.shift() : "edit";
    const code = rest[0] === "-e" ? rest[1] : readStdin();
    const timeoutSec = Number(process.env.TIMEOUT || 30);
    result = await remoteCall("run_luau", { code, target, timeoutSec });
  } else if (cmd === "shot") {
    const [target, out = path.join(os.tmpdir(), `studio-shot-${Date.now()}.png`), extra = "{}"] = rest;
    result = await remoteCall("screenshot", { ...(target && target !== "-" ? { target } : {}), ...JSON.parse(extra) });
    fs.writeFileSync(out, Buffer.from(result.image, "base64"));
    result = { text: `${result.text}\nSaved ${out}` };
  } else result = await remoteCall(cmd, rest[0] ? JSON.parse(rest[0]) : {});
  if (result.text) console.log(result.text);
} catch (e) {
  console.error(`error: ${e.message}`);
  process.exit(1);
}
