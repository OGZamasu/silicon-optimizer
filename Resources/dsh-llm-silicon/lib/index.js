/**
 * dsh-llm-silicon — the DeepSeek Harness side of Silicon Optimizer's model gateway.
 *
 * Registers one provider route, `silicon`, whose model list is asked of the gateway live:
 * every model installed on this Mac and every model a swarm node offers, whether or not it
 * is loaded right now. Picking one and sending a message is what loads it — the gateway
 * holds the request open (SSE comments) while the model comes up, then streams normally.
 *
 * Silicon Optimizer installs this file into its private DSH_HOME and loads it through a
 * `--patch` overlay it regenerates at each harness start; nothing here is meant to be
 * edited by hand. The plugin deliberately has no dependencies beyond the dsh-llm peer that
 * is already part of every dsh install, so it can never fight the harness over versions.
 */
import { CallId, EMPTY_RESPONSE_CODE, LlmAdapter, LlmError } from "@deepseek-ai/dsh-llm";

export const name = "llm-silicon";
export const inject = ["llm"];

const PROVIDER = "silicon";
/** Advertised when the gateway does not know a model's context. Deliberately low: the
 * harness compacting early is recoverable, the 262K it would otherwise assume is not. */
const FALLBACK_CONTEXT = 16384;

// #region wire serialization (harness messages → chat completions)

function flattenText(blocks) {
  return blocks.filter((block) => block.type === "text").map((block) => block.text).join("");
}

function serializeAssistant(message) {
  const text = flattenText(message.content);
  const reasoning = message.content
    .filter((block) => block.type === "reasoning")
    .map((block) => block.text)
    .join("");
  const toolCalls = message.content
    .filter((block) => block.type === "tool-call")
    .map((block) => ({
      id: block.id,
      type: "function",
      function: { name: block.name, arguments: block.arguments },
    }));
  return {
    role: "assistant",
    content: text,
    // Reasoning is replayed only on tool-call turns, the thinking-passback contract the
    // local templates (and DeepSeek's) share.
    ...(toolCalls.length > 0 && reasoning.length > 0 ? { reasoning_content: reasoning } : {}),
    ...(toolCalls.length > 0 ? { tool_calls: toolCalls } : {}),
  };
}

function serializeMessages(messages) {
  const wire = [];
  for (const message of messages) {
    if (message.content.some((block) => block.type === "image")) {
      throw new LlmError(
        "The Silicon gateway route is text-only; images cannot be sent.",
        "UNSUPPORTED_CONTENT"
      );
    }
    if (message.role === "system") {
      wire.push({ role: "system", content: flattenText(message.content) });
      continue;
    }
    if (message.role === "assistant") {
      wire.push(serializeAssistant(message));
      continue;
    }
    const toolResults = message.content.filter((block) => block.type === "tool-result");
    const text = flattenText(message.content);
    if (text.length > 0 || toolResults.length === 0) {
      wire.push({ role: "user", content: text });
    }
    for (const result of toolResults) {
      wire.push({
        role: "tool",
        tool_call_id: result.toolCallId,
        content: flattenText(result.content) || "(no output)",
      });
    }
  }
  return wire;
}

function serializeRequest(options) {
  if (options.reasoningEffort !== undefined) {
    throw new LlmError(
      `The Silicon gateway does not expose reasoning efforts (got "${options.reasoningEffort}")`,
      "UNSUPPORTED_REASONING_EFFORT"
    );
  }
  const messages = [];
  if (options.system !== undefined) messages.push({ role: "system", content: options.system });
  messages.push(...serializeMessages(options.messages));
  const tools = options.tools?.map((tool) => ({
    type: "function",
    function: { name: tool.name, description: tool.description, parameters: tool.parameters },
  }));
  return {
    model: options.model,
    messages,
    stream: true,
    stream_options: { include_usage: true },
    ...(tools !== undefined && tools.length > 0 ? { tools } : {}),
    ...(options.temperature !== undefined ? { temperature: options.temperature } : {}),
    ...(options.maxTokens !== undefined ? { max_tokens: options.maxTokens } : {}),
    ...(options.stop !== undefined ? { stop: options.stop } : {}),
  };
}

// #endregion

// #region SSE parsing (dependency-free)

/**
 * Parse an SSE byte stream into `data:` payloads, yielding `[DONE]` last. Comments are
 * transport keep-alives (the gateway sends them while a model loads) and are skipped.
 * A stream that ends without `[DONE]` was truncated and cannot be trusted.
 */
async function* parseSse(stream) {
  const decoder = new TextDecoder();
  let buffer = "";
  for await (const chunk of stream) {
    buffer += decoder.decode(chunk, { stream: true });
    let boundary;
    while ((boundary = buffer.indexOf("\n")) >= 0) {
      let line = buffer.slice(0, boundary);
      buffer = buffer.slice(boundary + 1);
      if (line.endsWith("\r")) line = line.slice(0, -1);
      if (!line.startsWith("data:")) continue; // comments, event names, blanks
      let payload = line.slice(5);
      if (payload.startsWith(" ")) payload = payload.slice(1);
      yield payload;
      if (payload === "[DONE]") return;
    }
  }
  throw new LlmError("SSE stream ended without [DONE]", "STREAM_CLOSED");
}

// #endregion

// #region chunk translation (chat completions → harness StreamChunks)

function mapFinishReason(reason) {
  switch (reason) {
    case "stop": return { kind: "stop" };
    case "tool_calls": return { kind: "tool-calls" };
    case "length": return { kind: "max-tokens" };
    default:
      return {
        kind: "error",
        failure: { message: `model stopped: ${reason}`, code: reason.toUpperCase() },
      };
  }
}

function closeBlock(block) {
  switch (block.kind) {
    case "text": return { type: "text", text: block.text };
    case "reasoning": return { type: "reasoning", text: block.text };
    case "tool-call":
      return {
        type: "tool-call",
        id: CallId(block.callId ?? ""),
        name: block.name ?? "",
        arguments: block.text,
      };
  }
}

async function* translate(payloads) {
  let nextIndex = 0;
  let textBlock;
  let reasoningBlock;
  const toolBlocks = new Map();
  const order = [];
  let pendingFinish;
  let pendingUsage;

  function open(kind) {
    const block = { index: nextIndex++, kind, text: "" };
    order.push(block);
    return block;
  }

  for await (const payload of payloads) {
    if (payload === "[DONE]") {
      for (const block of order) {
        yield { type: "block-end", index: block.index, block: closeBlock(block) };
      }
      if (pendingUsage) yield { type: "usage", usage: pendingUsage };
      const reason = pendingFinish ?? { kind: "stop" };
      yield {
        type: "finish",
        reason:
          reason.kind === "stop" && order.length === 0
            ? {
                kind: "error",
                failure: {
                  message: "the model returned a completed response with no content",
                  code: EMPTY_RESPONSE_CODE,
                },
              }
            : reason,
      };
      return;
    }

    let chunk;
    try {
      chunk = JSON.parse(payload);
    } catch {
      throw new LlmError(`malformed SSE payload: ${payload.slice(0, 120)}`, "MALFORMED_RESPONSE");
    }
    // The gateway reports a failed load or a dead backend in-stream, the only channel
    // left once SSE has begun.
    if (chunk.error?.message) {
      throw new LlmError(chunk.error.message, "PROVIDER_ERROR");
    }

    for (const choice of chunk.choices ?? []) {
      const delta = choice.delta;
      const reasoning = delta?.reasoning_content;
      if (typeof reasoning === "string" && reasoning.length > 0) {
        if (!reasoningBlock) {
          reasoningBlock = open("reasoning");
          yield { type: "block-start", index: reasoningBlock.index, blockType: "reasoning" };
        }
        reasoningBlock.text += reasoning;
        yield { type: "reasoning-delta", index: reasoningBlock.index, text: reasoning };
      }
      const content = delta?.content;
      if (typeof content === "string" && content.length > 0) {
        if (!textBlock) {
          textBlock = open("text");
          yield { type: "block-start", index: textBlock.index, blockType: "text" };
        }
        textBlock.text += content;
        yield { type: "text-delta", index: textBlock.index, text: content };
      }
      for (const call of delta?.tool_calls ?? []) {
        let block = toolBlocks.get(call.index ?? 0);
        if (!block) {
          block = open("tool-call");
          toolBlocks.set(call.index ?? 0, block);
          yield { type: "block-start", index: block.index, blockType: "tool-call" };
        }
        if (call.id !== undefined) block.callId = call.id;
        if (call.function?.name !== undefined) block.name = call.function.name;
        const fragment = call.function?.arguments ?? "";
        block.text += fragment;
        yield {
          type: "tool-call-delta",
          index: block.index,
          id: CallId(block.callId ?? ""),
          ...(block.name !== undefined ? { name: block.name } : {}),
          argumentsDelta: fragment,
        };
      }
      if (typeof choice.finish_reason === "string") {
        pendingFinish = mapFinishReason(choice.finish_reason);
      }
    }
    if (chunk.usage) {
      pendingUsage = {
        inputTokens: chunk.usage.prompt_tokens ?? 0,
        outputTokens: chunk.usage.completion_tokens ?? 0,
      };
    }
  }
  throw new LlmError("SSE payload stream ended without [DONE]", "STREAM_CLOSED");
}

// #endregion

// #region adapter

function httpErrorCode(status) {
  if (status === 404) return "MODEL_NOT_FOUND";
  if (status === 429) return "RATE_LIMIT";
  if (status >= 400 && status < 500) return "BAD_REQUEST";
  return "PROVIDER_ERROR";
}

class SiliconAdapter extends LlmAdapter {
  /** @param {() => string} baseURL - resolved per call so a config change lands next request. */
  constructor(baseURL) {
    super();
    this.baseURL = baseURL;
    this.catalog = { at: 0, models: [] };
  }

  providerInfo(provider) {
    return { id: provider, name: "Silicon Optimizer" };
  }

  /** The gateway's live list: local installs plus every swarm node's offerings. */
  async fetchCatalog() {
    // A short-lived cache: the picker and per-request resolution both ask, often in the
    // same second.
    if (Date.now() - this.catalog.at < 5000) return this.catalog.models;
    const response = await fetch(`${this.baseURL()}/models`, {
      signal: AbortSignal.timeout(5000),
    });
    if (!response.ok) {
      throw new LlmError(
        `The Silicon Optimizer gateway answered ${response.status} — is the app running?`,
        "PROVIDER_ERROR"
      );
    }
    const body = await response.json();
    const models = (body.data ?? []).map((entry) => ({
      id: String(entry.id),
      name: String(entry.silicon?.name ?? entry.id),
      description: entry.silicon?.serving
        ? `serving now on ${entry.silicon?.where ?? "this Mac"}`
        : `on ${entry.silicon?.where ?? "this Mac"} — loads when first used`,
      contextWindow: typeof entry.silicon?.contextWindow === "number"
        ? entry.silicon.contextWindow
        : undefined,
    }));
    this.catalog = { at: Date.now(), models };
    return models;
  }

  async listModels(provider) {
    const models = await this.fetchCatalog();
    return models.map((model) => ({
      provider,
      id: model.id,
      name: model.name,
      description: model.description,
    }));
  }

  async resolveModel(provider, model) {
    let known;
    try {
      known = (await this.fetchCatalog()).find((entry) => entry.id === model);
    } catch {
      // The registry treats metadata as advisory; an unreachable gateway here would only
      // block resolution, and the stream call will say so much more clearly.
    }
    return {
      provider,
      id: model,
      name: known?.name ?? model,
      context: { contextWindow: known?.contextWindow ?? FALLBACK_CONTEXT },
    };
  }

  async *stream(options) {
    const request = serializeRequest(options);
    let response;
    try {
      response = await fetch(`${this.baseURL()}/chat/completions`, {
        method: "POST",
        headers: { "content-type": "application/json", accept: "text/event-stream" },
        body: JSON.stringify(request),
        signal: options.signal,
      });
    } catch (error) {
      if (error?.name === "AbortError") throw error;
      throw new LlmError(
        "Could not reach the Silicon Optimizer gateway — is the app running?",
        "PROVIDER_ERROR"
      );
    }
    if (!response.ok) {
      let message = `Silicon gateway error (HTTP ${response.status})`;
      try {
        const detail = (await response.json())?.error;
        if (detail?.message) message = detail.message;
      } catch {}
      throw new LlmError(message, httpErrorCode(response.status), { status: response.status });
    }
    if (!response.body) {
      throw new LlmError("The gateway returned no response body", "EMPTY_RESPONSE");
    }
    yield* translate(parseSse(response.body));
  }
}

// #endregion

export function apply(ctx, config) {
  const baseURL = () => {
    const raw = typeof config?.baseURL === "string" ? config.baseURL : "";
    // Tolerate a trailing slash; routes are appended bare.
    return (raw || "http://127.0.0.1:0/v1").replace(/\/+$/, "");
  };
  const adapter = new SiliconAdapter(baseURL);
  ctx.llm.registerAdapter([PROVIDER], adapter);
}
