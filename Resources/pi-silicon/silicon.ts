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
 * 3. Hands every tool call to the app before it runs, so the Jev guardrail can screen
 *    it. Pi's RPC protocol has no tool-permission request of its own — an RPC client
 *    is told a tool ran, not asked whether it may — but the extension API does: the
 *    `tool_call` event fires before execution and can block, and `ctx.ui.confirm`
 *    becomes an `extension_ui_request` the app answers on stdin. That pair is the
 *    permission hook, and this is the only place it can be installed from.
 * 4. Asks the app, once per turn, which one of this session's tools and skills fits what
 *    the user just typed, and appends the answer as a single line *after* the system
 *    prompt Pi built. The roster itself is never touched, so any prefix caching over it
 *    still holds. `before_agent_start` is the seam: it fires after the user submits and
 *    before the agent loop, and what it returns replaces the system prompt for that turn.
 *
 * The two app-facing dialogs carry distinct titles, and the app matches on both the title
 * and the method. The guardrail's is a blocking `confirm` with no timeout — a gate that
 * times out into "allowed" is not a gate. The suggestion's is an `input` with one, because
 * the right fallback for a hint that does not arrive is no hint.
 *
 * The app writes this file into the Pi workspace and supplies the environment:
 *   SILICON_GATEWAY_PORT — the gateway's loopback port
 *   SILICON_GATEWAY_KEY  — the per-launch gateway bearer
 *   SILICON_MCP_PATH     — path to the bundled silicon-mcp executable (optional)
 */

import { spawn, type ChildProcessByStdio } from "node:child_process";
import type { Readable, Writable } from "node:stream";
import { Type } from "typebox";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

/**
 * The title every guardrail request carries. The app matches on it exactly; it is a
 * protocol token, not a label. Changing it here means changing it in
 * `AppModel+Pi.swift`, where `PiGuardrailRequest.marker` is the other half.
 */
const GUARDRAIL_MARKER = "silicon.guardrail.v1";

/**
 * The title the tool-relevance request carries. Matched exactly by the app; the other half
 * is `PiSkillSuggestionRequest.marker` in `AppModel+SkillSelection.swift`.
 */
const RELEVANCE_MARKER = "silicon.skillselect.v1";

/** How long the app has to answer before the turn goes ahead without a suggestion. */
const RELEVANCE_TIMEOUT_MS = 20_000;

/** One roster entry as the app reads it. */
type RosterEntry = { name: string; kind: "tool" | "skill"; description: string };

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
  // ---- The app's guardrail, in front of every tool ----------------------------
  //
  // Registered first, before anything that can return early, because a session where this
  // handler is missing is a session where every tool call runs unscreened.
  //
  // Fires after `tool_execution_start` and before the tool runs, and what it returns
  // decides whether the tool runs at all. The app is asked through a confirm dialog
  // because that is the one channel an RPC client can answer: `ctx.ui.confirm` emits
  // `extension_ui_request` and blocks until an `extension_ui_response` with the same
  // id comes back on stdin.
  //
  // The title is a marker rather than a sentence — the app matches on it, and no
  // human ever reads it, because in RPC mode there is no terminal to read it in. The
  // message is the whole request, as JSON, so the app screens the real arguments
  // rather than a summary of them. The app answers `true` without asking anyone when
  // the guardrail is switched off, which is what keeps this transparent for someone
  // who never turned it on.
  //
  // If the app does not answer, the call waits. That is deliberate: a gate that times
  // out into "allowed" is not a gate. Pi's own abort path still ends the turn.
  pi.on("tool_call", async (event, ctx) => {
    const question = JSON.stringify({
      v: 1,
      tool: event.toolName,
      toolCallId: event.toolCallId,
      arguments: event.input ?? {},
    });
    const allowed = await ctx.ui.confirm(GUARDRAIL_MARKER, question);
    if (allowed) return;
    return {
      block: true,
      reason:
        "Silicon Optimizer's guardrail did not allow this call. The verdict and its " +
        "reasons are on the card in the app's Chat tab.",
    };
  });

  // ---- The app's tool suggestion, once per turn --------------------------------
  //
  // Registered here, beside the gate and before anything that can return early, for the
  // same reason: a session that skipped this registration is a session with no suggestion,
  // and the handler has to exist before the first turn either way.
  //
  // `mcpTools` is filled in further down, once the tool server has answered. An empty
  // roster on the first turn of a degraded session is not a problem — the app is sent what
  // there is, and an empty roster suggests nothing.
  const mcpTools: RosterEntry[] = [];

  pi.on("before_agent_start", async (event, ctx) => {
    try {
      const turn = (event.prompt ?? "").trim();
      if (turn.length === 0 || !ctx.hasUI) return;

      // Pi's own tools and skills, out of the same structured options it built the system
      // prompt from — so this reads what Pi actually loaded rather than re-discovering it.
      const options = event.systemPromptOptions ?? { cwd: "" };
      const snippets: Record<string, string> = options.toolSnippets ?? {};
      const roster: RosterEntry[] = [];
      const seen = new Set<string>();
      const add = (entry: RosterEntry) => {
        if (entry.name.length === 0 || seen.has(entry.name)) return;
        seen.add(entry.name);
        roster.push(entry);
      };
      for (const entry of mcpTools) add(entry);
      for (const name of options.selectedTools ?? []) {
        add({ name, kind: "tool", description: snippets[name] ?? name });
      }
      for (const skill of options.skills ?? []) {
        // A skill the model may not invoke is not a candidate: suggesting it would point
        // the agent at something only the user can run.
        if (skill.disableModelInvocation) continue;
        add({
          name: skill.name,
          kind: "skill",
          description: skill.description ?? skill.name,
        });
      }
      if (roster.length === 0) return;

      const question = JSON.stringify({
        v: 1,
        turn,
        lastToolResult: lastToolResultText(ctx),
        roster,
      });
      const answer = await ctx.ui.input(RELEVANCE_MARKER, question, {
        timeout: RELEVANCE_TIMEOUT_MS,
      });
      if (typeof answer !== "string" || answer.trim().length === 0) return;

      // Appended, never substituted: the roster above it is byte-identical on every turn,
      // which is what keeps a provider's prefix cache warm across the session.
      return { systemPrompt: `${event.systemPrompt}\n\n${answer}` };
    } catch {
      // A turn must never fail because a hint did not arrive.
      return;
    }
  });

  const port = process.env.SILICON_GATEWAY_PORT;
  const gatewayToken = process.env.SILICON_GATEWAY_KEY;
  if (!port || !gatewayToken) {
    // No gateway to register, but the gate above is already installed: a session that
    // starts with the app's environment half-set must not be a session with no guardrail.
    return;
  }
  const baseUrl = `http://127.0.0.1:${port}/v1`;

  // ---- The gateway as a provider ---------------------------------------------
  let models: Array<Record<string, unknown>> = [];
  try {
    const response = await fetch(`${baseUrl}/models`, {
      headers: { authorization: `Bearer ${gatewayToken}` },
    });
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
    // The roster the suggestion reads. The app derives its own one-line summary from this
    // description, so the whole text goes over rather than a truncation of it.
    mcpTools.push({
      name: tool.name,
      kind: "tool",
      description: tool.description ?? tool.name,
    });
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
 * A one-line digest of the newest tool result in the session, or undefined when there is
 * none. It is the only thing besides the turn itself the app is told about the
 * conversation: `is_follow_up_to_previous_tool_result` has to read *something*, and a
 * transcript is neither needed for that nor something to send for it.
 *
 * Cut here rather than in the app so a large result never crosses the pipe in the first
 * place. The app trims and redacts what arrives anyway.
 */
function lastToolResultText(ctx: { sessionManager?: any }): string | undefined {
  try {
    const entries = ctx.sessionManager?.buildContextEntries?.() ?? [];
    for (let index = entries.length - 1; index >= 0; index--) {
      const message = entries[index]?.message;
      if (!message || message.role !== "toolResult") continue;
      const blocks = Array.isArray(message.content) ? message.content : [];
      const text = blocks
        .filter((block: any) => block?.type === "text" && typeof block.text === "string")
        .map((block: any) => block.text)
        .join(" ")
        .replace(/\s+/g, " ")
        .trim();
      return text.length > 0 ? text.slice(0, 600) : undefined;
    }
  } catch {
    // A session shape this build does not recognise is not a reason to skip the hint.
  }
  return undefined;
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
