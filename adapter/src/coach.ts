// One Coach per side (docs/ringside-plan.md "Coach turn"): a turn every cadence while the round is
// live, at once on round_start, its own knockdown and a 25% health swing; one turn in flight at
// most. Each turn is a fresh chat: the system prompt, one user message, the tools. The reply's
// tool calls go to the game as plan/queue/say frames; the game's `applied` answers feed the next
// prompt. At the cost cap the side keeps its last plan.
import type { GameLink } from "./link.ts";
import type { BattleLog } from "./log.ts";
import { toolCallsForLog } from "./log.ts";
import type { Effort } from "./models.ts";
import { TOOLS, buildSystemPrompt, buildTurnMessage, mergePlan, validatePlan, validateQueue, validateSay } from "./prompt.ts";
import type { Applied, GameEvent, Hello, ModelClient, Plan, Side, State } from "./types.ts";
import { other } from "./types.ts";

export type CoachStatus = "waiting" | "thinking" | "coaching" | "out of budget" | "stopped" | "failed";

export interface CoachStats {
  side: Side;
  model: string;
  status: CoachStatus;
  turns: number;
  tokens: number;
  usd: number;
  avgSeconds: number | null;
  plansApplied: number;
  refused: number;
  errors: number;
  lastError: string | null;
  lastCaption: string | null;
  plan: Plan | null;
}

export interface CoachOptions {
  cadenceMs?: number;
  capUsd?: number;
  effort?: Effort;
  now?: () => number;
  setTimer?: (fn: () => void, ms: number) => unknown;
  clearTimer?: (t: unknown) => void;
  onTurn?: (side: Side, info: { reason: string; calls: string[]; caption: string | null; seconds: number; usd: number | null; error?: string }) => void;
}

const HEALTH_SWING = 0.25;

export class Coach {
  status: CoachStatus = "waiting";
  turns = 0;
  tokens = 0;
  usd = 0;
  plansApplied = 0;
  refused = 0;
  errors = 0;
  lastError: string | null = null;
  lastCaption: string | null = null;
  plan: Plan | null = null;
  private seconds = 0;
  private events: GameEvent[] = [];
  private results: string[] = [];
  private pending = new Map<string, string>(); // plan_id -> what was sent, awaiting `applied`
  private inFlight = false;
  private wanted: string | null = null; // a turn asked for while one was in flight
  private timer: unknown = null;
  private lastHealth: [number, number] | null = null;
  private system: string;
  private stopped = false;
  readonly cadenceMs: number;
  readonly capUsd: number;
  private readonly now: () => number;
  private readonly setTimer: (fn: () => void, ms: number) => unknown;
  private readonly clearTimer: (t: unknown) => void;
  private readonly onTurn: CoachOptions["onTurn"];
  private roundLive = false;

  readonly side: Side;
  readonly spec: string;
  readonly client: ModelClient;
  readonly link: GameLink;
  readonly hello: Hello;
  readonly log: BattleLog | null;

  constructor(side: Side, spec: string, client: ModelClient, link: GameLink, hello: Hello, log: BattleLog | null, opts: CoachOptions = {}) {
    this.side = side;
    this.spec = spec;
    this.client = client;
    this.link = link;
    this.hello = hello;
    this.log = log;
    this.cadenceMs = opts.cadenceMs ?? 2000;
    this.capUsd = opts.capUsd ?? 1;
    this.now = opts.now ?? Date.now;
    this.setTimer = opts.setTimer ?? ((fn, ms) => setTimeout(fn, ms));
    this.clearTimer = opts.clearTimer ?? ((t) => clearTimeout(t as NodeJS.Timeout));
    this.onTurn = opts.onTurn;
    this.system = buildSystemPrompt(side, hello, opts.effort ?? "low");
    log?.system(side, spec, this.system);
    link.on("event", this.onEvent);
    link.on("state", this.onState);
    link.on("applied", this.onApplied);
    // A coach made after the round started (hello and round_start can arrive in one read).
    if (link.roundLive) {
      this.roundLive = true;
      this.turn("round_start");
    }
  }

  stats(): CoachStats {
    return {
      side: this.side,
      model: this.spec,
      status: this.status,
      turns: this.turns,
      tokens: this.tokens,
      usd: this.usd,
      avgSeconds: this.turns ? this.seconds / this.turns : null,
      plansApplied: this.plansApplied,
      refused: this.refused,
      errors: this.errors,
      lastError: this.lastError,
      lastCaption: this.lastCaption,
      plan: this.plan,
    };
  }

  stop(): void {
    this.stopped = true;
    if (this.status !== "out of budget" && this.status !== "failed") this.status = "stopped";
    this.clearCadence();
    this.link.off("event", this.onEvent);
    this.link.off("state", this.onState);
    this.link.off("applied", this.onApplied);
  }

  private onEvent = (e: GameEvent): void => {
    this.events.push(e);
    if (this.events.length > 30) this.events.splice(0, this.events.length - 30);
    if (e.event === "round_start") {
      this.roundLive = true;
      this.lastHealth = null;
      this.turn("round_start");
    } else if (e.event === "knockdown" && e.side === this.side) {
      this.turn("knockdown");
    } else if (e.event === "round_end" || e.event === "match_end") {
      this.roundLive = false;
      this.clearCadence();
    }
  };

  private onState = (s: State): void => {
    const h: [number, number] = [s.p1.health / Math.max(1, s.p1.max_health), s.p2.health / Math.max(1, s.p2.max_health)];
    if (this.lastHealth && this.roundLive && (this.lastHealth[0] - h[0] >= HEALTH_SWING || this.lastHealth[1] - h[1] >= HEALTH_SWING)) {
      this.turn("health_swing"); // lastHealth is reset by the turn
    }
    if (!this.lastHealth) this.lastHealth = h;
  };

  private onApplied = (a: Applied): void => {
    if (a.side !== this.side) return;
    const sent = this.pending.get(a.plan_id);
    if (sent === undefined) return;
    this.pending.delete(a.plan_id);
    if (a.ok) this.plansApplied++;
    else this.refused++;
    this.results.push(a.ok ? `${sent}: applied${a.error ? ` (${a.error})` : ""}` : `${sent}: refused (${a.error ?? "no reason"})`);
  };

  private clearCadence(): void {
    if (this.timer !== null) this.clearTimer(this.timer);
    this.timer = null;
  }

  private schedule(): void {
    this.clearCadence();
    if (this.stopped || !this.roundLive || this.status === "out of budget" || this.status === "failed") return;
    this.timer = this.setTimer(() => {
      this.timer = null;
      this.turn("cadence");
    }, this.cadenceMs);
  }

  // Starts a turn now, or remembers to start one when the current one ends.
  turn(reason: string): void {
    if (this.stopped || this.status === "out of budget" || this.status === "failed") return;
    if (this.inFlight) {
      this.wanted = reason;
      return;
    }
    void this.run(reason);
  }

  private async run(reason: string): Promise<void> {
    this.inFlight = true;
    this.clearCadence();
    this.status = "thinking";
    const started = this.now();
    const state = this.link.latest;
    const events = this.events.splice(0);
    const results = this.results.splice(0);
    const prompt = buildTurnMessage(this.side, state, events, this.plan, results);
    if (state) this.lastHealth = [state.p1.health / Math.max(1, state.p1.max_health), state.p2.health / Math.max(1, state.p2.max_health)];
    let error: string | undefined;
    let reply: Awaited<ReturnType<ModelClient["chat"]>> | null = null;
    this.link.send({ type: "thinking", side: this.side, on: true });
    try {
      reply = await this.client.chat(this.spec, { messages: [{ role: "system", content: this.system }, { role: "user", content: prompt }], tools: TOOLS });
    } catch (e) {
      error = e instanceof Error ? e.message : String(e);
      this.errors++;
      this.lastError = error;
    }
    this.link.send({ type: "thinking", side: this.side, on: false });
    const seconds = reply?.seconds ?? (this.now() - started) / 1000;
    this.turns++;
    this.seconds += seconds;
    const sent: string[] = [];
    let caption: string | null = null;
    if (reply) {
      this.tokens += reply.tokens;
      if (reply.usd != null) this.usd += reply.usd;
      const calls = reply.message.tool_calls ?? [];
      if (calls.length === 0) this.results.push(reply.finish === "length" ? "no tools: your reply ran out of room; think less and answer with the tools" : `no tools given${reply.message.content ? ` (you wrote: ${String(reply.message.content).slice(0, 100)})` : ""}; use the tools`);
      for (const [i, c] of calls.entries()) {
        const id = `${this.side}-${this.turns}-${i}`;
        const args = parseArgs(c.function?.arguments);
        switch (c.function?.name) {
          case "set_plan": {
            const { plan, problems } = validatePlan(args);
            if (problems.length) this.results.push(`set_plan: ${problems.join(", ")}`);
            if (Object.keys(plan).length) {
              this.plan = mergePlan(this.plan, plan);
              this.pending.set(id, `set_plan ${JSON.stringify(plan)}`);
              if (!this.link.send({ type: "plan", side: this.side, plan_id: id, plan })) this.results.push("set_plan: the game is not connected");
              sent.push(`set_plan ${JSON.stringify(plan)}`);
            }
            break;
          }
          case "queue": {
            const { moves, problems } = validateQueue(args);
            if (problems.length) this.results.push(`queue: ${problems.join(", ")}`);
            if (moves.length) {
              this.pending.set(id, `queue ${moves.join(" ")}`);
              if (!this.link.send({ type: "queue", side: this.side, plan_id: id, moves })) this.results.push("queue: the game is not connected");
              sent.push(`queue ${moves.join(" ")}`);
            }
            break;
          }
          case "say": {
            const text = validateSay(args);
            if (text) {
              caption = text;
              this.lastCaption = text;
              this.link.send({ type: "say", side: this.side, text });
              sent.push(`say "${text}"`);
            }
            break;
          }
          default:
            this.results.push(`unknown tool ${c.function?.name ?? "?"}`);
        }
      }
      this.status = "coaching";
      if (this.usd >= this.capUsd) {
        this.status = "out of budget";
        this.results.push("budget spent: the plan in force stays");
      }
    } else if (this.errors >= 5 && this.turns === this.errors) {
      this.status = "failed"; // never a single good answer
    } else this.status = "coaching";
    this.log?.turn(this.side, {
      turn: this.turns,
      at: new Date(started).toISOString(),
      reason,
      seconds,
      tokens: reply?.tokens ?? 0,
      usd: reply?.usd ?? null,
      prompt,
      reply: { content: reply?.message.content ?? null, tool_calls: toolCallsForLog(reply?.message.tool_calls) },
      results: [...this.results],
      finish: reply?.finish,
      error,
    });
    this.onTurn?.(this.side, { reason, calls: sent, caption, seconds, usd: reply?.usd ?? null, error });
    this.inFlight = false;
    const wanted = this.wanted;
    this.wanted = null;
    if (wanted && this.roundLive) void this.run(wanted);
    else this.schedule();
  }
}

const parseArgs = (s: string | undefined): unknown => {
  try {
    return JSON.parse(s || "{}");
  } catch {
    return {};
  }
};

export const opponentOf = other;
