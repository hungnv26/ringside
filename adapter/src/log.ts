// Battle logs: battle-logs/<id>/battle.json (setup, result, totals), <side>.md (readable: the
// system prompt once, then every turn), <side>.jsonl (one line per turn, for tools),
// <side>.reflex.jsonl (one line per reflex tick when the side has reflexes).
import { appendFileSync, mkdirSync, writeFileSync } from "node:fs";
import { basename, dirname, join } from "node:path";
import { REPO_ROOT } from "./models.ts";
import type { Hello, Side, ToolCall } from "./types.ts";

export interface TurnLog {
  turn: number;
  at: string;
  reason: string; // cadence | round_start | knockdown | health_swing
  seconds: number;
  tokens: number;
  usd: number | null;
  prompt: string;
  reply: { content: string | null; tool_calls: { name: string; arguments: string }[] };
  results: string[];
  finish?: string;
  error?: string;
}

export interface ReflexTickLog {
  tick: number;
  at: string;
  seconds: number;
  tokens: number;
  usd: number | null;
  /** The knobs (0..1), choices and gate probabilities of this tick. */
  last: Record<string, string | number>;
  sent: string[];
  gates: string[];
  error?: string;
}

export function battleId(hello: Hello, now = new Date()): string {
  return `${now.toISOString().replace(/[:.]/g, "-").slice(0, 19)}-${hello.p1.id}-vs-${hello.p2.id}`;
}

export class BattleLog {
  readonly dir: string;
  private systemWritten = new Set<Side>();

  readonly id: string;

  constructor(id: string, root = join(REPO_ROOT, "battle-logs")) {
    this.id = id;
    this.dir = join(root, id);
    mkdirSync(this.dir, { recursive: true });
  }

  /** A log in exactly this folder (the setup page picks it); the id is the folder's name. */
  static at(dir: string): BattleLog {
    return new BattleLog(basename(dir), dirname(dir));
  }

  /** The live status the setup page polls (live.json), rewritten whole each time. */
  live(data: Record<string, unknown>): void {
    writeFileSync(join(this.dir, "live.json"), JSON.stringify(data) + "\n");
  }

  system(side: Side, model: string, text: string): void {
    if (this.systemWritten.has(side)) return;
    this.systemWritten.add(side);
    writeFileSync(join(this.dir, `${side}.md`), `# ${side} · ${model}\n\n## System prompt\n\n${text}\n\n`);
    writeFileSync(join(this.dir, `${side}.jsonl`), "");
  }

  turn(side: Side, t: TurnLog): void {
    const calls = t.reply.tool_calls.map((c) => `- \`${c.name}\` ${c.arguments}`).join("\n");
    const md = [
      `## Turn ${t.turn} · ${t.at} · ${t.reason} · ${t.seconds.toFixed(1)} s · ${t.tokens} tokens${t.usd != null ? ` · $${t.usd.toFixed(4)}` : ""}`,
      "",
      "### Prompt",
      "",
      t.prompt,
      "",
      "### Reply",
      "",
      t.reply.content ? t.reply.content : "(no text)",
      calls ? `\n${calls}` : "\n(no tool calls)",
      "",
      t.results.length ? `### Results\n\n${t.results.map((r) => `- ${r}`).join("\n")}\n` : "",
      t.error ? `### Error\n\n${t.error}\n` : "",
    ].join("\n");
    appendFileSync(join(this.dir, `${side}.md`), md + "\n");
    appendFileSync(join(this.dir, `${side}.jsonl`), JSON.stringify(t) + "\n");
  }

  /** One reflex tick (reflex.ts): what Jev answered and what was sent. */
  reflex(side: Side, t: ReflexTickLog): void {
    appendFileSync(join(this.dir, `${side}.reflex.jsonl`), JSON.stringify(t) + "\n");
  }

  battle(data: Record<string, unknown>): void {
    writeFileSync(join(this.dir, "battle.json"), JSON.stringify(data, null, 2) + "\n");
  }
}

export const toolCallsForLog = (calls: ToolCall[] | undefined): { name: string; arguments: string }[] => (calls ?? []).map((c) => ({ name: c.function?.name ?? "", arguments: c.function?.arguments ?? "{}" }));
