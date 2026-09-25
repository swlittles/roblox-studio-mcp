#!/usr/bin/env node
// MCP stdio server for Roblox Studio. Hosts the plugin bridge on 127.0.0.1:44777, or forwards to a bridge
// that is already running (for example one started by cli.mjs) so several clients can share one Studio.

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import { tools, callTool, startBridge, bridgeRunning, remoteCall } from "./bridge.mjs";

let call = callTool;
try {
  await startBridge();
} catch (e) {
  if (e.code === "EADDRINUSE" && (await bridgeRunning())) call = remoteCall;
  else throw e;
}

const zodFor = { string: z.string(), number: z.number(), boolean: z.boolean(), object: z.record(z.any()) };
function toZod(schema) {
  const shape = {};
  for (const [key, type] of Object.entries(schema)) {
    const optional = type.endsWith("?");
    const base = zodFor[type.replace("?", "")];
    shape[key] = optional ? base.optional() : base;
  }
  return shape;
}

const server = new McpServer({ name: "roblox-studio-bridge", version: "0.1.0" });
for (const [name, tool] of Object.entries(tools)) {
  server.tool(name, tool.description, toZod(tool.schema), async (args) => {
    try {
      const result = await call(name, args);
      const content = [];
      if (result.image) content.push({ type: "image", data: result.image, mimeType: "image/png" });
      if (result.text) content.push({ type: "text", text: result.text });
      return { content };
    } catch (e) {
      return { isError: true, content: [{ type: "text", text: e.message }] };
    }
  });
}

await server.connect(new StdioServerTransport());
