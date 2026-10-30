// A deterministic stand-in for a model (spec "fake:coach"): every call answers with tool calls, so
// the whole loop (prompt, plan frames, applied results, logs) runs with no key and no cost.
import type { ChatBody, ChatResult, ModelClient } from "./types.ts";

const RANGES = ["close", "mid", "far"] as const;
const CAPTIONS = ["Pressure on.", "Keep your distance.", "Watch the low kick.", "Finish it."];
const TALK = ["They keep whiffing the heavy; I am tightening the block and waiting for it.", "Range is wrong for us: closing in and queuing the sweep.", "Meter is nearly full, so I am saving the super for a punish.", "Their jabs win up close; backing off to mid and poking."];

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
    const toolNames = (body.tools ?? []).map((t) => t.function.name);
    const promptTokensOf = () => Math.ceil(body.messages.reduce((s, m) => s + String(m.content ?? "").length, 0) / 4);
    const done = (calls: unknown[]): ChatResult => {
      const promptTokens = promptTokensOf();
      return { message: { content: null, tool_calls: calls as ChatResult["message"]["tool_calls"] }, usage: { prompt_tokens: promptTokens, completion_tokens: 40, total_tokens: promptTokens + 40, x_input: promptTokens, x_cache_read: 0, x_cache_write: 0 }, tokens: promptTokens + 40, usd: 0, finish: "tool_calls", seconds: this.delayMs / 1000 };
    };
    if (toolNames.includes("set_policy")) {
      // The self-coding fighter: a punish, a sweep up close, the super when ready, a poke at mid range.
      const rules = [
        { name: "punish", when: { range: "close", opponent: "recovering" }, do: ["2HP"], weight: 3 },
        { name: "sweep", when: { range: "close", opponent: "idle" }, do: ["2HK"] },
        { name: "super", when: { meter_full: true, range: "mid" }, do: [has236K ? "236236K" : "236236P"], weight: 4 },
        { name: "poke", when: { range: "mid" }, do: ["HK"] },
        { name: "close in", when: { range: "far" }, do: ["approach 20"] },
      ];
      return done([
        { id: `fake-${n}-policy`, type: "function", function: { name: "set_policy", arguments: JSON.stringify({ plan: { aggression: n % 2 === 0 ? 0.5 : 0.8 }, rules: rules.slice(0, 3 + (n % 3)) }) } },
        { id: `fake-${n}-say`, type: "function", function: { name: "say", arguments: JSON.stringify({ text: `Round plan ${n + 1}: ${3 + (n % 3)} rules.` }) } },
      ]);
    }
    if (toolNames.length && !toolNames.includes("set_plan")) {
      // Beat mode: cycle through approach, a poke, a block, a sweep.
      const picks = [["approach 20"], ["HK"], ["crouch_block 20"], ["2HK"], ["LP", "HP"], ["throw"]];
      return done([
        { id: `fake-${n}-queue`, type: "function", function: { name: "queue", arguments: JSON.stringify({ moves: picks[n % picks.length] }) } },
        ...(n % 4 === 0 ? [{ id: `fake-${n}-say`, type: "function", function: { name: "say", arguments: JSON.stringify({ text: CAPTIONS[n % CAPTIONS.length] }) } }] : []),
      ]);
    }
    const plan = { aggression: n % 2 === 0 ? 0.3 : 0.9, range: RANGES[n % 3] };
    const calls = [{ id: `fake-${n}-plan`, type: "function", function: { name: "set_plan", arguments: JSON.stringify(plan) } }];
    if (n % 3 === 2) calls.push({ id: `fake-${n}-queue`, type: "function", function: { name: "queue", arguments: JSON.stringify({ moves: has236K ? ["2HK", "236K"] : ["2HK"] }) } });
    calls.push({ id: `fake-${n}-say`, type: "function", function: { name: "say", arguments: JSON.stringify({ text: CAPTIONS[n % CAPTIONS.length] }) } });
    // Every fourth turn a read: the opponent's sweep (every fighter has one), or a jump.
    if (n % 4 === 1 && toolNames.includes("predict")) calls.push({ id: `fake-${n}-predict`, type: "function", function: { name: "predict", arguments: JSON.stringify({ what: n % 8 === 1 ? "2HK" : "jump" }) } });
    const promptTokens = Math.ceil(body.messages.reduce((s, m) => s + String(m.content ?? "").length, 0) / 4);
    return {
      message: { content: TALK[n % TALK.length], tool_calls: calls },
      usage: { prompt_tokens: promptTokens, completion_tokens: 40, total_tokens: promptTokens + 40, x_input: promptTokens, x_cache_read: 0, x_cache_write: 0 },
      tokens: promptTokens + 40,
      usd: 0,
      finish: "tool_calls",
      seconds: this.delayMs / 1000,
    };
  }
}
