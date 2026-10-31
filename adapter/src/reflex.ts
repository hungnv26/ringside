// A corner's reflexes (docs/jev-plan.md): Jev ticks on every state frame (4 a second) while the
// round is live and, from one call's answers, nudges the plan knobs, makes a read when it is
// confident, and wakes the brain (the Coach) when a gate fires. It never queues moves, never
// writes rules; with no brain it captions its own changes. One call in flight at most; a frame
// that arrives while one is running is skipped.
//
// Authority: the brain's plan is the baseline. A knob moves only a full level (0.25) at a time,
// stays within a quarter of the brain's setting, and never within 2 s of the brain setting it.
// Range, reaction and the favoured option change on a majority of the last three ticks.
import type { Coach } from "./coach.ts";
import { choiceOf, favourWeights, GATES, jevQuestions, jevState, KNOBS, knobOf, NO_FAVOUR, NO_READ, noulOf, type Gate, type JevAnswer, type JevQuestion, type ReflexClient } from "./jev.ts";
import type { GameLink } from "./link.ts";
import type { BattleLog } from "./log.ts";
import { mergePlan, MAX_CAPTION } from "./prompt.ts";
import type { GameEvent, Hello, Plan, Side, State } from "./types.ts";

/** Who made the read now pending at a side, so `read` events are credited to the right mind. */
export interface ReadLedger {
  owner: "coach" | "reflex" | null;
}

export type ReflexStatus = "waiting" | "ticking" | "out of budget" | "failed" | "stopped";

export interface ReflexStats {
  side: Side;
  model: string;
  status: ReflexStatus;
  ticks: number;
  skipped: number;
  errors: number;
  lastError: string | null;
  tokens: number;
  usd: number;
  avgMs: number | null;
  reads: { made: number; right: number };
  gates: Record<Gate, number>;
  nudges: number;
  lastRead: string | null;
  lastCaption: string | null;
  /** The knobs and choices from the last tick, for the live board. */
  last: Record<string, string | number> | null;
}

export interface ReflexOptions {
  coach?: Coach | null;
  /** Ticks a second: 4 (every state frame) or 2. */
  hz?: number;
  /** The read's probability must reach this to be sent (default 0.6). */
  readThreshold?: number;
  /** A gate's probability must reach this to fire (default 0.7). */
  gateThreshold?: number;
  gateCooldownMs?: number;
  capUsd?: number;
  /** Nudge the plan (coach mode); off in self-coding mode, where the rules engine plays the plan. */
  nudgePlan?: boolean;
  /** Fire the brain's turn on a gate (coach mode with a brain); otherwise gates are only recorded. */
  wakeBrain?: boolean;
  /** Caption the changes (a corner with no brain). */
  captions?: boolean;
  ledger?: ReadLedger;
  now?: () => number;
  onTick?: (side: Side, info: { tick: number; sent: string[]; gates: Gate[]; seconds: number; usd: number | null; error?: string }) => void;
}

/** Reflex ticks a second the CLI and the setup page offer. */
export const REFLEX_RATES = [2, 4] as const;
/** Two ticks a second by default: Jev answers in about 280 ms, so 4 Hz skips a third of its ticks and costs twice as much for little gain (docs/jev-plan.md, 2026-10-31). */
export const DEFAULT_REFLEX_RATE = 2;
export const DEFAULT_READ_THRESHOLD = 0.6;
export const DEFAULT_GATE_THRESHOLD = 0.7;

const STEP = 0.25;
const BAND = 0.25;
const BRAIN_HOLD_MS = 2000;
const CAPTION_GAP_MS = 2000;
const HISTORY = 3;
const KNOB_WORDS: Record<string, string> = { aggression: "push", block: "block", punish: "punish", anti_air: "anti-air", pressure: "pressure" };
const RANGE_WORDS: Record<string, string> = { close: "close in", mid: "stay mid", far: "keep away" };

export class Reflexes {
  status: ReflexStatus = "waiting";
  ticks = 0;
  skipped = 0;
  errors = 0;
  lastError: string | null = null;
  tokens = 0;
  usd = 0;
  nudges = 0;
  reads = { made: 0, right: 0 };
  gates: Record<Gate, number> = { plan_failing: 0, window_open: 0, pattern_changed: 0 };
  lastRead: string | null = null;
  lastCaption: string | null = null;
  last: ReflexStats["last"] = null;
  /** The plan as the game has it from this side: the brain's plan with the nudges on top. */
  applied: Plan = {};
  readonly questions: Record<string, JevQuestion>;
  readonly side: Side;
  readonly spec: string;
  readonly client: ReflexClient;
  readonly link: GameLink;
  readonly hello: Hello;
  readonly log: BattleLog | null;
  readonly coach: Coach | null;
  readonly minIntervalMs: number;
  readonly readThreshold: number;
  readonly gateThreshold: number;
  readonly gateCooldownMs: number;
  readonly capUsd: number;
  readonly nudgePlan: boolean;
  readonly wakeBrain: boolean;
  readonly captions: boolean;
  readonly ledger: ReadLedger;
  private readonly now: () => number;
  private readonly onTick: ReflexOptions["onTick"];
  private inFlight = false;
  private stopped = false;
  private roundLive = false;
  private pendingRead = false;
  private lastTickAt = -Infinity;
  private lastCaptionAt = -Infinity;
  private ms = 0;
  private lastGateAt: Record<Gate, number> = { plan_failing: -Infinity, window_open: -Infinity, pattern_changed: -Infinity };
  private history: Record<"range" | "reaction" | "favour", string[]> = { range: [], reaction: [], favour: [] };
  private favourite: string | null = null;
  private events: GameEvent[] = [];
  // What the reflexes did since the brain's last turn (recordForBrain).
  private since = { ticks: 0, reads: 0, right: 0, gates: { plan_failing: 0, window_open: 0, pattern_changed: 0 } as Record<Gate, number>, nudges: [] as string[] };

  constructor(side: Side, spec: string, client: ReflexClient, link: GameLink, hello: Hello, log: BattleLog | null, opts: ReflexOptions = {}) {
    this.side = side;
    this.spec = spec;
    this.client = client;
    this.link = link;
    this.hello = hello;
    this.log = log;
    this.coach = opts.coach ?? null;
    this.minIntervalMs = Math.round(1000 / Math.max(1, Math.min(4, opts.hz ?? DEFAULT_REFLEX_RATE))) - 20; // a little under: frames are 250 ms apart
    this.readThreshold = opts.readThreshold ?? DEFAULT_READ_THRESHOLD;
    this.gateThreshold = opts.gateThreshold ?? DEFAULT_GATE_THRESHOLD;
    this.gateCooldownMs = opts.gateCooldownMs ?? 4000;
    this.capUsd = opts.capUsd ?? 1;
    this.nudgePlan = opts.nudgePlan ?? true;
    this.wakeBrain = opts.wakeBrain ?? !!this.coach;
    this.captions = opts.captions ?? !this.coach;
    this.ledger = opts.ledger ?? { owner: null };
    this.now = opts.now ?? Date.now;
    this.onTick = opts.onTick;
    this.questions = jevQuestions(side, hello);
    if (!this.coach) log?.system(side, spec, `Reflexes only (${spec}): no brain. The questions Jev answers on every tick:\n\n\`\`\`json\n${JSON.stringify(this.questions, null, 2)}\n\`\`\``);
    link.on("event", this.onEvent);
    link.on("state", this.onState);
    if (link.roundLive) this.roundLive = true;
  }

  stats(): ReflexStats {
    return {
      side: this.side,
      model: this.spec,
      status: this.status,
      ticks: this.ticks,
      skipped: this.skipped,
      errors: this.errors,
      lastError: this.lastError,
      tokens: this.tokens,
      usd: this.usd,
      avgMs: this.ticks ? this.ms / this.ticks : null,
      reads: { ...this.reads },
      gates: { ...this.gates },
      nudges: this.nudges,
      lastRead: this.lastRead,
      lastCaption: this.lastCaption,
      last: this.last,
    };
  }

  stop(): void {
    this.stopped = true;
    if (this.status !== "out of budget" && this.status !== "failed") this.status = "stopped";
    this.link.off("event", this.onEvent);
    this.link.off("state", this.onState);
  }

  /** One line for the brain's next prompt: what the reflexes did since its last turn; resets the record. */
  recordForBrain(): string | null {
    const s = this.since;
    if (!s.ticks) return null;
    const gates = GATES.filter((g) => s.gates[g]).map((g) => `${g.replace("_", " ")} ${s.gates[g]}×`);
    const text = `Your reflexes since your last turn: ${s.ticks} ticks; reads ${s.right}/${s.reads}; ${gates.length ? `gates ${gates.join(", ")}` : "no gate fired"}; ${s.nudges.length ? `nudged ${s.nudges.slice(-4).join(", ")}` : "no plan nudge"}. Your set_plan is their baseline; use orders to steer them.`;
    this.since = { ticks: 0, reads: 0, right: 0, gates: { plan_failing: 0, window_open: 0, pattern_changed: 0 }, nudges: [] };
    return text;
  }

  private onEvent = (e: GameEvent): void => {
    if (e.event === "round_start") {
      this.roundLive = true;
      this.pendingRead = false; // the game drops reads between rounds
      this.history = { range: [], reaction: [], favour: [] };
    } else if (e.event === "round_end" || e.event === "match_end") {
      this.roundLive = false;
      this.pendingRead = false;
    } else if (e.event === "read" && e.side === this.side) {
      if (e.actual === "replaced") {
        if (this.ledger.owner !== "reflex") this.pendingRead = false; // ours was replaced by the brain's
      } else if (this.ledger.owner === "reflex") {
        if (e.right) (this.reads.right++, this.since.right++);
        this.pendingRead = false;
        this.ledger.owner = null;
      }
      return;
    }
    this.events.push(e);
    if (this.events.length > 20) this.events.splice(0, this.events.length - 20);
  };

  private onState = (s: State): void => {
    if (!this.roundLive || this.stopped || this.status === "out of budget" || this.status === "failed") return;
    if (this.inFlight || this.now() - this.lastTickAt < this.minIntervalMs) {
      this.skipped++;
      return;
    }
    void this.tick(s);
  };

  private majority(key: "range" | "reaction" | "favour", value: string): string | null {
    const h = this.history[key];
    h.push(value);
    if (h.length > HISTORY) h.splice(0, h.length - HISTORY);
    if (h.length < HISTORY) return null;
    const counts = new Map<string, number>();
    for (const v of h) counts.set(v, (counts.get(v) ?? 0) + 1);
    for (const [v, n] of counts) if (n >= 2) return v;
    return null;
  }

  private async tick(s: State): Promise<void> {
    this.inFlight = true;
    const started = this.now();
    this.lastTickAt = started;
    const tick = ++this.ticks;
    this.since.ticks++;
    const baseline = this.coach?.plan ?? null;
    const state = jevState(this.side, this.hello, s, this.events.splice(0), baseline, this.coach?.orders ?? null);
    let answers: Record<string, JevAnswer> = {};
    let error: string | undefined;
    let r: Awaited<ReturnType<ReflexClient["decide"]>> | null = null;
    try {
      r = await this.client.decide(this.spec, state, this.questions);
      answers = r.answers;
    } catch (e) {
      error = e instanceof Error ? e.message : String(e);
      this.errors++;
      this.lastError = error;
    }
    const seconds = r?.seconds ?? (this.now() - started) / 1000;
    this.ms += seconds * 1000;
    const sent: string[] = [];
    const fired: Gate[] = [];
    const last: Record<string, string | number> = {};
    if (r) {
      this.tokens += r.usage.input_tokens + r.usage.output_tokens;
      if (r.usd != null) this.usd += r.usd;
      const brainHeld = !!this.coach && this.now() - this.coach.planSetAt < BRAIN_HOLD_MS;
      const plan: Plan = {};
      const words: string[] = [];
      const mayNudge = this.nudgePlan && !brainHeld; // the hold gates the sending, not the record or the majorities
      {
        for (const k of KNOBS) {
          const level = knobOf(answers[k]);
          if (level == null) continue;
          last[k] = level;
          if (!mayNudge) continue;
          const base = baseline?.[k];
          const target = typeof base === "number" ? Math.min(base + BAND, Math.max(base - BAND, level)) : level;
          const current = this.applied[k] ?? base;
          if (current === undefined || Math.abs(target - current) >= STEP - 1e-9) {
            plan[k] = Math.round(target * 100) / 100;
            words.push(`${KNOB_WORDS[k]} ${current === undefined ? plan[k] : target > current ? "↑" : "↓"}`);
          }
        }
        for (const key of ["range", "reaction", "favour"] as const) {
          const c = choiceOf(answers[key]);
          if (!c) continue;
          last[key] = c.choice;
          const agreed = this.majority(key, c.choice);
          if (!agreed || !mayNudge) continue;
          if (key === "favour") {
            if (agreed !== (this.favourite ?? NO_FAVOUR)) {
              const options = favourWeights(this.favourite, agreed);
              if (Object.keys(options).length) plan.options = options;
              this.favourite = agreed;
              words.push(agreed === NO_FAVOUR ? "own mix" : `go ${agreed}`);
            }
          } else if (agreed !== (this.applied[key] ?? baseline?.[key])) {
            (plan as Record<string, unknown>)[key] = agreed;
            words.push(key === "range" ? (RANGE_WORDS[agreed] ?? agreed) : `react ${agreed}`);
          }
        }
      }
      if (Object.keys(plan).length) {
        this.applied = mergePlan(this.applied, plan);
        const id = `${this.side}-r${tick}`;
        if (this.link.send({ type: "plan", side: this.side, plan_id: id, plan, source: "reflex" })) {
          this.nudges++;
          sent.push(`plan ${JSON.stringify(plan)}`);
          this.since.nudges.push(words.join(", "));
        }
      }
      const read = choiceOf(answers.read);
      if (read) last.read = `${read.choice} ${read.p.toFixed(2)}`;
      if (read && read.choice !== NO_READ && read.p >= this.readThreshold && !this.pendingRead) {
        if (this.link.send({ type: "predict", side: this.side, plan_id: `${this.side}-r${tick}-read`, what: read.choice, source: "reflex" })) {
          this.pendingRead = true;
          this.ledger.owner = "reflex";
          this.reads.made++;
          this.since.reads++;
          this.lastRead = read.choice;
          sent.push(`predict ${read.choice} (${read.p.toFixed(2)})`);
          words.push(`expecting ${read.choice}`);
        }
      }
      for (const g of GATES) {
        const p = noulOf(answers[g]);
        if (p == null) continue;
        last[g] = Math.round(p * 100) / 100;
        if (p >= this.gateThreshold && this.now() - this.lastGateAt[g] >= this.gateCooldownMs) {
          this.lastGateAt[g] = this.now();
          this.gates[g]++;
          this.since.gates[g]++;
          fired.push(g);
        }
      }
      if (fired.length && this.wakeBrain && this.coach) this.coach.turn(`reflex:${fired.join("+")}`); // one turn, whatever fired together
      if (this.captions && words.length && this.now() - this.lastCaptionAt >= CAPTION_GAP_MS) {
        let text = "";
        for (const w of words) {
          const next = text ? `${text}, ${w}` : w;
          if (next.length > MAX_CAPTION) break;
          text = next;
        }
        if (text) {
          this.lastCaptionAt = this.now();
          this.lastCaption = text;
          this.link.send({ type: "say", side: this.side, text });
          sent.push(`say "${text}"`);
        }
      }
      this.last = last;
      this.status = "ticking";
      if (this.usd >= this.capUsd) this.status = "out of budget";
    } else if (this.errors >= 5 && this.ticks === this.errors) this.status = "failed";
    else this.status = "ticking";
    this.log?.reflex(this.side, { tick, at: new Date(started).toISOString(), seconds, tokens: r ? r.usage.input_tokens : 0, usd: r?.usd ?? null, last, sent, gates: fired, error });
    this.onTick?.(this.side, { tick, sent, gates: fired, seconds, usd: r?.usd ?? null, error });
    this.inFlight = false;
  }
}

/** The brain's half and the reflexes' half of a corner's spec (docs/jev-plan.md "Spec grammar"). */
export function parseSpec(spec: string): { brain: string | null; reflex: string | null } {
  const plus = spec.indexOf("+");
  if (plus > 0) {
    const brain = spec.slice(0, plus);
    const suffix = spec.slice(plus + 1);
    if (suffix !== "jev" && suffix !== "fake") throw new Error(`"${spec}": the reflexes suffix must be +jev (or +fake)`);
    // A fake brain keeps the match free and keyless: its reflexes are faked too.
    return { brain, reflex: suffix === "fake" || brain.startsWith("fake:") ? "jev:fake" : "jev:jev" };
  }
  if (spec.startsWith("jev:")) return { brain: null, reflex: spec.slice(4) === "fake" ? "jev:fake" : spec };
  return { brain: spec, reflex: null };
}
