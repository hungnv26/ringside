// A deterministic stand-in for a model (spec "fake:coach"): every call answers with tool calls, so
// the whole loop (prompt, plan frames, applied results, logs) runs with no key and no cost.
import type { ChatBody, ChatResult, ModelClient } from "./types.ts";

const RANGES = ["close", "mid", "far"] as const;
const CAPTIONS = ["Pressure on.", "Keep your distance.", "Watch the low kick.", "Finish it."];

export class FakeModelClient implements ModelClient {
  calls = 0;
  readonly delayMs: number;
  constructor(delayMs = 0) {
    this.delayMs = delayMs;
  }

  async chat(_spec: string, body: ChatBody): Promise<ChatResult> {
    const n = this.calls++;
    if (this.delayMs) await new Promise((r) => setTimeout(r, this.delayMs));
    const system = String(body.messages.find((m) => m.role === "system")?.content ?? "");
    const own = system.slice(system.indexOf("Your fighter"), system.indexOf("Opponent:")); // its own move list, not the opponent's
    const has236K = /\b236K\b/.test(own);
    const plan = { aggression: n % 2 === 0 ? 0.3 : 0.9, range: RANGES[n % 3] };
    const calls = [{ id: `fake-${n}-plan`, type: "function", function: { name: "set_plan", arguments: JSON.stringify(plan) } }];
    if (n % 3 === 2) calls.push({ id: `fake-${n}-queue`, type: "function", function: { name: "queue", arguments: JSON.stringify({ moves: has236K ? ["2HK", "236K"] : ["2HK"] }) } });
    calls.push({ id: `fake-${n}-say`, type: "function", function: { name: "say", arguments: JSON.stringify({ text: CAPTIONS[n % CAPTIONS.length] }) } });
    const promptTokens = Math.ceil(body.messages.reduce((s, m) => s + String(m.content ?? "").length, 0) / 4);
    return {
      message: { content: null, tool_calls: calls },
      usage: { prompt_tokens: promptTokens, completion_tokens: 40, total_tokens: promptTokens + 40, x_input: promptTokens, x_cache_read: 0, x_cache_write: 0 },
      tokens: promptTokens + 40,
      usd: 0,
      finish: "tool_calls",
      seconds: this.delayMs / 1000,
    };
  }
}
