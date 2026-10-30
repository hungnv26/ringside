// Model calls in the providers' own APIs, ported from Outpost War's key gateway
// (outpost-zero/tools/war_models.mjs). The coaches speak the OpenAI chat format; each call is
// translated: Claude to the Messages API with prompt caching (system+tools cached, so a turn's
// fixed part is read at a tenth of the price), OpenAI reasoning models to the Responses API
// (tools while reasoning), everything else (OpenAI chat models, OpenRouter, Ollama) to chat
// completions. Effort is the thinking effort for both big providers ("low" by default: a
// coach's turn is worth less than two seconds).
import { chmodSync, mkdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { ChatBody, ChatResult, ModelClient, ToolCall, Usage } from "./types.ts";

export type Effort = "low" | "medium" | "high";
export const MAX_TOKENS = 4000;
const OPENAI_REASONING = /^(o\d|gpt-5|gpt-6)/;
const TIMEOUT_MS = 120_000;

export const REPO_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..", "..");
const read = (path: string): string => {
  try {
    return readFileSync(path, "utf8").trim();
  } catch {
    return "";
  }
};

// Keys: infra/keys/<provider>.key under this repo, else $RINGSIDE_KEYS_DIR, else Outpost Zero's
// (the user's other game keeps the same files), else <PROVIDER>_API_KEY in the environment.
export function keyDirs(): string[] {
  const dirs = [join(REPO_ROOT, "infra", "keys")];
  if (process.env.RINGSIDE_KEYS_DIR) dirs.push(process.env.RINGSIDE_KEYS_DIR);
  dirs.push(resolve(REPO_ROOT, "..", "outpost-zero", "infra", "keys"));
  return dirs;
}
export function providerKey(provider: string): { key: string; source: string } {
  for (const dir of keyDirs()) {
    const key = read(join(dir, `${provider}.key`));
    if (key) return { key, source: join(dir, `${provider}.key`) };
  }
  const env = process.env[`${provider.toUpperCase()}_API_KEY`];
  return env ? { key: env, source: `${provider.toUpperCase()}_API_KEY` } : { key: "", source: "" };
}

// Prices per model (design/model_prices.json), read when the file changes.
let prices = { mtime: 0, data: {} as Record<string, { in: number; cacheRead?: number; cacheWrite?: number; out: number }> };
export function modelPrices(): typeof prices.data {
  const file = join(REPO_ROOT, "design", "model_prices.json");
  try {
    const mtime = statSync(file).mtimeMs;
    if (mtime !== prices.mtime) prices = { mtime, data: JSON.parse(readFileSync(file, "utf8")) };
  } catch {}
  return prices.data;
}

// What one call cost in USD, null when the model has no price.
export function callCost(table: ReturnType<typeof modelPrices>, spec: string, usage: Usage | null): number | null {
  const p = table[spec];
  if (!p || !usage) return null;
  const input = usage.x_input ?? usage.prompt_tokens ?? 0;
  const cached = usage.x_cache_read ?? 0;
  const written = usage.x_cache_write ?? 0;
  const out = usage.completion_tokens ?? 0;
  return (input * p.in + cached * (p.cacheRead ?? p.in) + written * (p.cacheWrite ?? p.in) + out * p.out) / 1e6;
}

const parseArgs = (s: string | undefined): Record<string, unknown> => {
  try {
    const v = JSON.parse(s || "{}");
    return v && typeof v === "object" ? v : {};
  } catch {
    return {};
  }
};
const text = (c: unknown): string => (typeof c === "string" ? c : Array.isArray(c) ? c.map((p) => (typeof p === "string" ? p : (p as { text?: string })?.text ?? "")).join("") : c == null ? "" : String(c));

// ---- Claude ----

export function toAnthropic(body: ChatBody, model: string, effort: Effort): Record<string, unknown> {
  const system: string[] = [];
  const messages: { role: string; content: Record<string, unknown>[] }[] = [];
  const push = (role: string, blocks: Record<string, unknown>[]) => {
    const last = messages[messages.length - 1];
    if (last && last.role === role) last.content.push(...blocks);
    else messages.push({ role, content: [...blocks] });
  };
  for (const m of body.messages ?? []) {
    if (m.role === "system") {
      const t = text(m.content).trim();
      if (t) system.push(t);
    } else if (m.role === "user") {
      push("user", [{ type: "text", text: text(m.content) || "(empty)" }]);
    } else if (m.role === "tool") {
      push("user", [{ type: "tool_result", tool_use_id: String(m.tool_call_id ?? ""), content: text(m.content) || "(no output)" }]);
    } else if (m.role === "assistant") {
      const blocks: Record<string, unknown>[] = [];
      const t = text(m.content).trim();
      if (t) blocks.push({ type: "text", text: t });
      for (const c of m.tool_calls ?? []) blocks.push({ type: "tool_use", id: String(c.id), name: String(c.function?.name ?? ""), input: parseArgs(c.function?.arguments) });
      push("assistant", blocks.length ? blocks : [{ type: "text", text: "(no reply)" }]);
    }
  }
  if (messages[0]?.role !== "user") messages.unshift({ role: "user", content: [{ type: "text", text: "(start)" }] });
  const tools = (body.tools ?? []).map((t) => ({ name: t.function.name, description: t.function.description ?? "", input_schema: t.function.parameters ?? { type: "object", properties: {} } }));
  const out: Record<string, unknown> = {
    model,
    max_tokens: MAX_TOKENS,
    system: system.length ? [{ type: "text", text: system.join("\n\n"), cache_control: { type: "ephemeral" } }] : undefined,
    messages,
    output_config: { effort },
  };
  if (tools.length) {
    out.tools = tools;
    out.tool_choice = { type: "auto" };
  }
  return out;
}

export function fromAnthropic(r: Record<string, any>): { message: ChatResult["message"]; usage: Usage; finish: string } {
  const content: Record<string, any>[] = Array.isArray(r.content) ? r.content : [];
  const reply = content.filter((b) => b.type === "text").map((b) => b.text).join("");
  const calls: ToolCall[] = content.filter((b) => b.type === "tool_use").map((b) => ({ id: b.id, type: "function", function: { name: b.name, arguments: JSON.stringify(b.input ?? {}) } }));
  const u = r.usage ?? {};
  const cached = u.cache_read_input_tokens ?? 0;
  const written = u.cache_creation_input_tokens ?? 0;
  const input = u.input_tokens ?? 0;
  const finish = ({ tool_use: "tool_calls", end_turn: "stop", stop_sequence: "stop", max_tokens: "length", refusal: "refusal" } as Record<string, string>)[r.stop_reason] ?? "stop";
  return {
    message: { content: reply || (r.stop_reason === "refusal" ? "(declined)" : null), ...(calls.length ? { tool_calls: calls } : {}) },
    usage: { prompt_tokens: input + cached + written, completion_tokens: u.output_tokens ?? 0, total_tokens: input + cached + written + (u.output_tokens ?? 0), x_input: input, x_cache_read: cached, x_cache_write: written },
    finish,
  };
}

// Without thinking blocks: a retry when Claude refuses replayed thinking.
export function withoutThinking(req: Record<string, any>): Record<string, any> {
  return { ...req, messages: req.messages.map((m: any) => (m.role === "assistant" ? { ...m, content: m.content.filter((b: any) => b.type !== "thinking" && b.type !== "redacted_thinking") } : m)).filter((m: any) => m.content.length) };
}

// ---- OpenAI (Responses API) ----

export function toResponses(body: ChatBody, model: string, effort: Effort, cacheKey?: string): Record<string, unknown> {
  const instructions: string[] = [];
  const input: Record<string, unknown>[] = [];
  for (const m of body.messages ?? []) {
    if (m.role === "system") {
      const t = text(m.content).trim();
      if (t) instructions.push(t);
    } else if (m.role === "user") {
      input.push({ role: "user", content: text(m.content) || "(empty)" });
    } else if (m.role === "tool") {
      input.push({ type: "function_call_output", call_id: String(m.tool_call_id ?? ""), output: text(m.content) || "(no output)" });
    } else if (m.role === "assistant") {
      const t = text(m.content).trim();
      if (t) input.push({ role: "assistant", content: t });
      for (const c of m.tool_calls ?? []) input.push({ type: "function_call", call_id: String(c.id), name: String(c.function?.name ?? ""), arguments: String(c.function?.arguments ?? "{}") });
    }
  }
  const tools = (body.tools ?? []).map((t) => ({ type: "function", name: t.function.name, description: t.function.description ?? "", parameters: t.function.parameters ?? { type: "object", properties: {} }, strict: false }));
  return {
    model,
    instructions: instructions.join("\n\n") || undefined,
    input,
    ...(tools.length ? { tools, tool_choice: "auto" } : {}),
    reasoning: { effort },
    store: false,
    max_output_tokens: MAX_TOKENS,
    ...(cacheKey ? { prompt_cache_key: cacheKey } : {}),
  };
}

export function fromResponses(r: Record<string, any>): { message: ChatResult["message"]; usage: Usage; finish: string } {
  const output: Record<string, any>[] = Array.isArray(r.output) ? r.output : [];
  const reply = output
    .filter((o) => o.type === "message")
    .flatMap((o) => o.content ?? [])
    .filter((c: any) => c.type === "output_text")
    .map((c: any) => c.text)
    .join("");
  const calls: ToolCall[] = output.filter((o) => o.type === "function_call").map((o) => ({ id: o.call_id, type: "function", function: { name: o.name, arguments: o.arguments ?? "{}" } }));
  const u = r.usage ?? {};
  const cached = u.input_tokens_details?.cached_tokens ?? 0;
  const finish = calls.length ? "tool_calls" : r.status === "incomplete" && r.incomplete_details?.reason === "max_output_tokens" ? "length" : "stop";
  return {
    message: { content: reply || null, ...(calls.length ? { tool_calls: calls } : {}) },
    usage: { prompt_tokens: u.input_tokens ?? 0, completion_tokens: u.output_tokens ?? 0, total_tokens: (u.input_tokens ?? 0) + (u.output_tokens ?? 0), x_input: (u.input_tokens ?? 0) - cached, x_cache_read: cached, x_cache_write: 0 },
    finish,
  };
}

// ---- chat completions (OpenAI chat models, OpenRouter, Ollama) ----

export function fromChatCompletion(r: Record<string, any>): { message: ChatResult["message"]; usage: Usage; finish: string } {
  const choice = r.choices?.[0] ?? {};
  const m = choice.message ?? {};
  const u = r.usage ?? {};
  const cached = u.prompt_tokens_details?.cached_tokens ?? 0;
  return {
    message: { content: m.content ?? null, ...(Array.isArray(m.tool_calls) && m.tool_calls.length ? { tool_calls: m.tool_calls } : {}) },
    usage: { prompt_tokens: u.prompt_tokens ?? 0, completion_tokens: u.completion_tokens ?? 0, total_tokens: u.total_tokens ?? 0, x_input: (u.prompt_tokens ?? 0) - cached, x_cache_read: cached, x_cache_write: 0 },
    finish: choice.finish_reason === "tool_calls" || (m.tool_calls?.length ?? 0) > 0 ? "tool_calls" : choice.finish_reason ?? "stop",
  };
}

export function splitSpec(spec: string): { provider: string; model: string } {
  const i = spec.indexOf(":");
  return i < 0 ? { provider: "", model: spec } : { provider: spec.slice(0, i), model: spec.slice(i + 1) };
}

export const PROVIDERS = ["anthropic", "openai", "openrouter", "ollama"];
/** The reflexes' provider (jev.ts): a key like the others, one model, no chat. */
export const REFLEX_PROVIDER = "jev";
export const KEYED_PROVIDERS = [...PROVIDERS, REFLEX_PROVIDER];

export class ProviderClient implements ModelClient {
  readonly effort: Effort;
  readonly fetchFn: typeof fetch;
  constructor(effort: Effort = "low", fetchFn: typeof fetch = fetch) {
    this.effort = effort;
    this.fetchFn = fetchFn;
  }

  async chat(spec: string, body: ChatBody, cacheKey?: string): Promise<ChatResult> {
    const { provider, model } = splitSpec(spec);
    if (!PROVIDERS.includes(provider) || !model) throw new Error(`model must be provider:model with provider one of ${PROVIDERS.join(", ")}; got "${spec}"`);
    const started = Date.now();
    const post = async (url: string, headers: Record<string, string>, req: unknown) => {
      const res = await this.fetchFn(url, { method: "POST", headers: { "content-type": "application/json", ...headers }, body: JSON.stringify(req), signal: AbortSignal.timeout(TIMEOUT_MS) });
      const raw = await res.text();
      return { ok: res.ok, status: res.status, raw };
    };
    let out: { message: ChatResult["message"]; usage: Usage; finish: string };
    if (provider === "anthropic") {
      const { key } = providerKey("anthropic");
      if (!key) throw new Error("no Anthropic key (infra/keys/anthropic.key)");
      const headers = { "x-api-key": key, "anthropic-version": "2023-06-01" };
      let req = toAnthropic(body, model, this.effort);
      let r = await post("https://api.anthropic.com/v1/messages", headers, req);
      if (r.status === 400 && /thinking/i.test(r.raw)) r = await post("https://api.anthropic.com/v1/messages", headers, withoutThinking(req));
      if (!r.ok) throw new Error(`anthropic ${r.status}: ${r.raw.slice(0, 300)}`);
      out = fromAnthropic(JSON.parse(r.raw));
    } else if (provider === "openai" && OPENAI_REASONING.test(model)) {
      const { key } = providerKey("openai");
      if (!key) throw new Error("no OpenAI key (infra/keys/openai.key)");
      const r = await post("https://api.openai.com/v1/responses", { authorization: `Bearer ${key}` }, toResponses(body, model, this.effort, cacheKey));
      if (!r.ok) throw new Error(`openai ${r.status}: ${r.raw.slice(0, 300)}`);
      out = fromResponses(JSON.parse(r.raw));
    } else {
      let url: string;
      const headers: Record<string, string> = {};
      const extra: Record<string, unknown> = {};
      if (provider === "openai") {
        const { key } = providerKey("openai");
        if (!key) throw new Error("no OpenAI key (infra/keys/openai.key)");
        url = "https://api.openai.com/v1/chat/completions";
        headers.authorization = `Bearer ${key}`;
      } else if (provider === "openrouter") {
        const { key } = providerKey("openrouter");
        if (!key) throw new Error("no OpenRouter key (infra/keys/openrouter.key)");
        url = "https://openrouter.ai/api/v1/chat/completions";
        headers.authorization = `Bearer ${key}`;
        headers["x-title"] = "Ringside";
      } else {
        url = (process.env.OLLAMA_URL ?? "http://127.0.0.1:11434") + "/v1/chat/completions";
        extra.reasoning_effort = "none"; // local models answer without thinking: a thinking turn took 25-50 s on this Mac
      }
      const r = await post(url, headers, { ...body, model, max_tokens: MAX_TOKENS, ...extra });
      if (!r.ok) throw new Error(`${provider} ${r.status}: ${r.raw.slice(0, 300)}`);
      out = fromChatCompletion(JSON.parse(r.raw));
    }
    const tokens = (out.usage.prompt_tokens ?? 0) + (out.usage.completion_tokens ?? 0);
    return { ...out, tokens, usd: callCost(modelPrices(), spec, out.usage), seconds: (Date.now() - started) / 1000 };
  }
}

// ---- for the setup page ----

/** Where each provider's key comes from (never the key itself). */
export function keyStatus(): Record<string, { saved: boolean; source: string; hint: string }> {
  return Object.fromEntries(
    KEYED_PROVIDERS.map((p) => {
      const { key, source } = providerKey(p);
      return [p, { saved: !!key, source: source.startsWith(REPO_ROOT) ? source.slice(REPO_ROOT.length + 1) : source, hint: key ? `…${key.slice(-4)}` : "" }];
    }),
  );
}

/** Saves a provider key to infra/keys/<provider>.key (mode 600). */
export function saveKey(provider: string, key: string): string {
  if (!KEYED_PROVIDERS.includes(provider) || provider === "ollama") throw new Error(`no key is kept for ${provider}`);
  const trimmed = key.trim();
  if (!/^[\x21-\x7e]{8,400}$/.test(trimmed)) throw new Error("that does not look like an API key");
  const dir = join(REPO_ROOT, "infra", "keys");
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  const file = join(dir, `${provider}.key`);
  writeFileSync(file, trimmed + "\n", { mode: 0o600 });
  chmodSync(file, 0o600);
  return file.slice(REPO_ROOT.length + 1);
}

/** The models a provider offers with the saved key (ids, sorted); tool-capable only on OpenRouter. */
export async function listModels(provider: string, fetchFn: typeof fetch = fetch): Promise<string[]> {
  const get = async (url: string, headers: Record<string, string> = {}) => {
    const res = await fetchFn(url, { headers, signal: AbortSignal.timeout(20_000) });
    if (!res.ok) throw new Error(`${provider}: ${res.status} ${(await res.text()).slice(0, 200)}`);
    return (await res.json()) as any;
  };
  const { key } = providerKey(provider);
  let ids: string[] = [];
  if (provider === "anthropic") {
    if (!key) throw new Error("no Anthropic key");
    const r = await get("https://api.anthropic.com/v1/models?limit=100", { "x-api-key": key, "anthropic-version": "2023-06-01" });
    ids = (r.data ?? []).map((m: any) => String(m.id));
  } else if (provider === "openai") {
    if (!key) throw new Error("no OpenAI key");
    const r = await get("https://api.openai.com/v1/models", { authorization: `Bearer ${key}` });
    ids = (r.data ?? []).map((m: any) => String(m.id)).filter((id: string) => /^(gpt-|o\d)/.test(id) && !/(audio|realtime|transcribe|tts|image|search|embedding|moderation|instruct|codex)/.test(id));
  } else if (provider === "openrouter") {
    const r = await get("https://openrouter.ai/api/v1/models", key ? { authorization: `Bearer ${key}` } : {});
    ids = (r.data ?? []).filter((m: any) => (m.supported_parameters ?? []).includes("tools")).map((m: any) => String(m.id));
  } else if (provider === "ollama") {
    const r = await get((process.env.OLLAMA_URL ?? "http://127.0.0.1:11434") + "/api/tags");
    ids = (r.models ?? []).map((m: any) => String(m.name));
  } else if (provider === REFLEX_PROVIDER) {
    ids = ["jev", "fake"]; // the current Jev (jev.ts JEV_MODEL), or the fake for a free match
  } else throw new Error(`unknown provider ${provider}`);
  return [...new Set(ids)].sort();
}
