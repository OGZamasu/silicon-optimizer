/**
 * Silicon Optimizer's Pi extension: one file, two jobs.
 *
 * 1. Registers the app's model gateway as a Pi provider ("silicon"), with the model
 *    list fetched live — every local install and every swarm node's model, permanent
 *    ids, loaded on demand by the gateway itself.
 * 2. Bridges the app's MCP tool server into Pi's own tool system. Pi does not speak
 *    MCP, so this file carries a minimal MCP client (JSONL over stdio) and mirrors
 *    every tool the server offers — names, schemas, and all — so the whole silicon
 *    toolbox (chat, images, video, 3D, benchmarks, swarm status…) is callable here
 *    exactly as it is in the other engines.
 *
 * The app writes this file into the Pi workspace and supplies the environment:
 *   SILICON_GATEWAY_PORT — the gateway's loopback port
 *   SILICON_MCP_PATH     — path to the bundled silicon-mcp executable (optional)
 */

import { spawn, type ChildProcessByStdio } from "node:child_process";
import type { Readable, Writable } from "node:stream";
import { Type } from "typebox";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

type GatewayModel = {
  id: string;
  silicon?: {
    name?: string;
    where?: string;
    serving?: boolean;
    contextWindow?: number;
  };
};

export default async function (pi: ExtensionAPI) {
  const port = process.env.SILICON_GATEWAY_PORT;
  if (!port) {
    return;
  }
  const baseUrl = `http://127.0.0.1:${port}/v1`;

  // ---- The gateway as a provider ---------------------------------------------
  let models: Array<Record<string, unknown>> = [];
  try {
    const response = await fetch(`${baseUrl}/models`);
    const payload = (await response.json()) as { data?: GatewayModel[] };
    models = (payload.data ?? []).map((model) => ({
      id: model.id,
      name: model.silicon?.name ?? model.id,
      reasoning: false,
      input: ["text"],
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      // A not-yet-loaded model advertises the context the gateway will load it
      // with; absent means a node model whose size is known only once serving.
      contextWindow: model.silicon?.contextWindow ?? 16384,
      maxTokens: 8192,
    }));
  } catch {
    // The gateway being briefly down must not kill Pi's startup; the provider
    // registers empty and the app restarts Pi once the gateway answers.
  }

  pi.registerProvider("silicon", {
    name: "Silicon Optimizer",
    baseUrl,
    apiKey: "$SILICON_GATEWAY_KEY",
    api: "openai-completions",
    models,
  });

  // ---- The app's MCP tools, mirrored -----------------------------------------
  const mcpPath = process.env.SILICON_MCP_PATH;
  if (!mcpPath) {
    return;
  }

  const client = new MCPClient(mcpPath);
  let tools: Array<{ name: string; description?: string; inputSchema?: unknown }>;
  try {
    await client.initialize();
    tools = await client.listTools();
  } catch {
    return; // No tools is a degraded session, not a broken one.
  }

  for (const tool of tools) {
    pi.registerTool({
      name: tool.name,
      label: tool.name,
      description: tool.description ?? tool.name,
      parameters: Type.Unsafe(
        (tool.inputSchema as object) ?? { type: "object", properties: {} }
      ),
      async execute(_toolCallId: string, params: unknown) {
        const result = await client.callTool(tool.name, params ?? {});
        const content = (result?.content ?? []) as Array<{
          type?: string;
          text?: string;
        }>;
        const text = content
          .filter((item) => item.type === "text" && typeof item.text === "string")
          .map((item) => item.text)
          .join("\n");
        return {
          content: [{ type: "text", text: text.length > 0 ? text : "(no output)" }],
          isError: result?.isError === true,
        };
      },
    });
  }
}

/**
 * The smallest MCP client that works: JSON-RPC 2.0 over stdio, one JSON object
 * per line. Long generation jobs (video on the render node) can run for many
 * minutes, so calls carry a 30-minute deadline — same figure the other engines use.
 */
class MCPClient {
  private child: ChildProcessByStdio<Writable, Readable, null>;
  private buffer = "";
  private nextId = 1;
  private pending = new Map<
    number,
    { resolve: (value: any) => void; reject: (error: Error) => void }
  >();

  constructor(executable: string) {
    this.child = spawn(executable, [], {
      stdio: ["pipe", "pipe", "ignore"],
    }) as ChildProcessByStdio<Writable, Readable, null>;
    this.child.stdout.setEncoding("utf8");
    this.child.stdout.on("data", (chunk: string) => this.consume(chunk));
    this.child.on("exit", () => {
      const dead = new Error("The silicon tool server exited.");
      for (const waiter of this.pending.values()) waiter.reject(dead);
      this.pending.clear();
    });
  }

  private consume(chunk: string) {
    this.buffer += chunk;
    let newline = this.buffer.indexOf("\n");
    while (newline >= 0) {
      const line = this.buffer.slice(0, newline).replace(/\r$/, "");
      this.buffer = this.buffer.slice(newline + 1);
      newline = this.buffer.indexOf("\n");
      if (line.trim().length === 0) continue;
      try {
        const message = JSON.parse(line);
        if (typeof message.id === "number" && this.pending.has(message.id)) {
          const waiter = this.pending.get(message.id)!;
          this.pending.delete(message.id);
          if (message.error) {
            waiter.reject(new Error(message.error.message ?? "tool error"));
          } else {
            waiter.resolve(message.result);
          }
        }
      } catch {
        // Non-JSON noise on stdout is ignored.
      }
    }
  }

  private request(method: string, params: unknown, timeoutMs: number): Promise<any> {
    const id = this.nextId++;
    const line = JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n";
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`${method} timed out`));
      }, timeoutMs);
      this.pending.set(id, {
        resolve: (value) => {
          clearTimeout(timer);
          resolve(value);
        },
        reject: (error) => {
          clearTimeout(timer);
          reject(error);
        },
      });
      this.child.stdin.write(line);
    });
  }

  private notify(method: string) {
    this.child.stdin.write(JSON.stringify({ jsonrpc: "2.0", method }) + "\n");
  }

  async initialize(): Promise<void> {
    await this.request(
      "initialize",
      {
        protocolVersion: "2025-06-18",
        capabilities: {},
        clientInfo: { name: "pi-silicon", version: "1.0" },
      },
      15_000
    );
    this.notify("notifications/initialized");
  }

  async listTools(): Promise<
    Array<{ name: string; description?: string; inputSchema?: unknown }>
  > {
    const result = await this.request("tools/list", {}, 15_000);
    return result?.tools ?? [];
  }

  async callTool(name: string, args: unknown): Promise<any> {
    return this.request(
      "tools/call",
      { name, arguments: args },
      1_800_000
    );
  }
}