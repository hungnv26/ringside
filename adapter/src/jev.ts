// Jev (TypeSafe AI's decision model) as a corner's reflexes (docs/jev-plan.md). Jev is not a chat
// model: one call takes a block of state and a batch of typed questions (noul = yes/no, choice,
// score) and answers all of them with calibrated probabilities in well under a second. It writes
// no text and no code, so it never queues combos, never writes captions or rules: that stays
// with the brain (coach.ts). Served through DigitalOcean's inference API by default (a model access
// key, account on Tier 3 or above) or TypeSafe's own API ($JEV_URL=https://api.typesafe.ai/v1/systemone,
// a console.typesafe.ai key): same body, same answers, only the model id differs ($JEV_MODEL).
import { callCost, modelPrices, providerKey, splitSpec } from "./models.ts";
import { buildTurnMessage, planText, READ_WORDS } from "./prompt.ts";
import type { Usage } from "./types.ts";
import { OPTION_NAMES, other, type GameEvent, type Hello, type Plan, type Side, type State } from "./types.ts";

export const DO_JEV_URL = "https://inference.do-ai.run/v1/systemone";
export const JEV_URL = process.env.JEV_URL ?? DO_JEV_URL;
/** The model id to send when a spec says just "jev": DigitalOcean names the version, TypeSafe takes "jev-latest". */
export function defaultJevModel(url: string, override?: string): string {
  if (override) return override;
  let host = "";
  try {
    host = new URL(url).host;
  } catch {
    host = "";
  }
  return /(^|\.)api\.typesafe\.ai(:\d+)?$/.test(host) ? "jev-latest" : "typesafe-jev-1.13.0";
}
export const JEV_MODEL = defaultJevModel(JEV_URL, process.env.JEV_MODEL);
/** Where the calls go, for the setup page ("inference.do-ai.run" or "api.typesafe.ai"). */
export const JEV_HOST = (() => {
  try {
    return new URL(JEV_URL).host;
  } catch {
    return JEV_URL;
  }
})();
const TIMEOUT_MS = 2500;
/** Events since the brain's last turn that the state block carries (the newest); every tick resends them. */
export const MAX_STATE_EVENTS = 8;

export type JevQuestion = { type: "noul"; instructions: string } | { type: "choice"; instructions: string; criteria: Record<string, string> } | { type: "score"; instructions: string; criteria: string[] };

/** One answer as the API returns it (fields by type; probabilities per option or per level index). */
export interface JevAnswer {
  type: string;
  choice?: string;
  probabilities?: Record<string, number> | number[];
  confidence?: number;
  score?: number;
  legend?: Record<string, string>;
  noul?: number;
}

export interface JevResult {
  answers: Record<string, JevAnswer>;
  usage: { input_tokens: number; output_tokens: number };
  usd: number | null;
  seconds: number;
}

/** What the reflexes need from a decision model (Jev, or the fake for tests). */
export interface ReflexClient {
  decide(spec: string, state: string, questions: Record<string, JevQuestion>): Promise<JevResult>;
}

/** The model id a reflex spec names: "jev:jev" is the current Jev, "jev:<id>" a specific one. */
export function jevModelId(spec: string): string {
  const { model } = splitSpec(spec);
  return !model || model === "jev" ? JEV_MODEL : model;
}

export class JevClient implements ReflexClient {
  readonly fetchFn: typeof fetch;
  readonly url: string;
  readonly keyFn: () => { key: string };
  /** `keyFn` finds the key (the jev.key file or $JEV_API_KEY); tests inject one so the machine's key stays out. */
  constructor(fetchFn: typeof fetch = fetch, url = JEV_URL, keyFn: () => { key: string } = () => providerKey("jev")) {
    this.fetchFn = fetchFn;
    this.url = url;
    this.keyFn = keyFn;
  }

  async decide(spec: string, state: string, questions: Record<string, JevQuestion>): Promise<JevResult> {
    const { key } = this.keyFn();
    if (!key) throw new Error("no Jev key (infra/keys/jev.key: a DigitalOcean model access key, or a TypeSafe key with $JEV_URL)");
    const started = Date.now();
    const res = await this.fetchFn(this.url, {
      method: "POST",
      headers: { "content-type": "application/json", authorization: `Bearer ${key}` },
      body: JSON.stringify({ model: jevModelId(spec), state, questions }),
      signal: AbortSignal.timeout(TIMEOUT_MS),
    });
    const raw = await res.text();
    if (!res.ok) throw new Error(`jev ${res.status}: ${raw.slice(0, 300)}`);
    const r = JSON.parse(raw) as { answers?: Record<string, JevAnswer>; usage?: { input_tokens?: number; output_tokens?: number } };
    const usage = { input_tokens: Number(r.usage?.input_tokens ?? 0), output_tokens: Number(r.usage?.output_tokens ?? 0) };
    return { answers: r.answers ?? {}, usage, usd: jevCost(usage), seconds: (Date.now() - started) / 1000 };
  }
}

/** What one call cost: Jev bills input only (design/model_prices.json "jev:jev"). */
export function jevCost(usage: { input_tokens: number; output_tokens: number }): number | null {
  const u: Usage = { prompt_tokens: usage.input_tokens, completion_tokens: usage.output_tokens, x_input: usage.input_tokens };
  return callCost(modelPrices(), "jev:jev", u);
}

// ---- the questions ----

/** The five plan knobs Jev scores, each on LEVELS (index 0..4 -> 0, 0.25, 0.5, 0.75, 1). */
export const KNOBS = ["aggression", "block", "punish", "anti_air", "pressure"] as const;
export const LEVELS = ["very low", "low", "medium", "high", "very high"];
export const NO_READ = "nothing";
export const NO_FAVOUR = "none";
/** The gates: yes/no questions whose probability wakes the brain. */
export const GATES = ["plan_failing", "window_open", "pattern_changed"] as const;
export type Gate = (typeof GATES)[number];

const OPTION_WORDS: Record<string, string> = {
  poke: "a long normal from mid range",
  string: "a jab combo up close",
  rush: "a travelling special to close in",
  dash: "dash in",
  jump: "jump in with an overhead",
  throw: "throw an opponent who blocks",
  grab: "the command grab",
  fireball: "a projectile from far",
  ground_special: "the 214 special",
  sidestep: "sidestep an attack",
  wait: "wait and react",
  retreat: "back off",
  approach: "walk in",
  stance: "the power-up stance",
  reversal: "the counter stance",
};
const READ_MEANINGS: Record<string, string> = {
  jump: "they jump in",
  throw: "they throw",
  super: "they use their super",
  fireball: "they throw a projectile",
  low: "a low attack (2LK, a sweep)",
  overhead: "an overhead (a jump attack, an axe kick)",
  sweep: "the sweep 2HK",
  reversal: "an invincible reversal (a 623 move)",
  uppercut: "an uppercut (2HP or a 623 move)",
};

/** The fixed question set for one side, built once per match from the fighters' move lists. */
export function jevQuestions(side: Side, hello: Hello): Record<string, JevQuestion> {
  const me = hello[side];
  const them = hello[other(side)];
  const q: Record<string, JevQuestion> = {};
  const knob = (what: string): JevQuestion => ({ type: "score", instructions: what, criteria: LEVELS });
  q.aggression = knob(`How often ${me.name} should attack rather than wait right now.`);
  q.block = knob(`How much ${me.name} should block attacks it sees coming right now: high against an opponent who keeps landing hits, low against one who whiffs and leaves openings.`);
  q.punish = knob(`How much ${me.name} should punish whiffed or blocked attacks right now: high when the opponent keeps whiffing heavy moves.`);
  q.anti_air = knob(`How ready ${me.name} should be to answer jump-ins with an uppercut or rising move: high when the opponent keeps jumping.`);
  q.pressure = knob(`How much ${me.name} should keep attacking an opponent who is blocking: high when their blocking has them cornered, low when they reverse out of it.`);
  q.range = {
    type: "choice",
    instructions: `Where ${me.name} should stand right now.`,
    criteria: { close: "under 1.2 m, throw and string range: against a zoner, a cornered opponent, or when the super is ready", mid: "about 1.6 m, poke range: the default when nothing else is clear", far: "over 2.2 m: against a grappler or a rusher, or to keep away and wait" },
  };
  q.reaction = {
    type: "choice",
    instructions: `How fast ${me.name} should react right now.`,
    criteria: { fast: "the opponent attacks a lot and blocks must come in time", normal: "the default", slow: "the opponent feints and fast reactions are losing exchanges" },
  };
  q.favour = {
    type: "choice",
    instructions: `Which option ${me.name} should favour when it acts right now, or none.`,
    criteria: { ...OPTION_WORDS, [NO_FAVOUR]: "no option stands out; keep the fighter's own mix" },
  };
  const reads: Record<string, string> = {};
  for (const mv of them.moves.filter((m) => /^\d{3}/.test(m.input))) reads[mv.input] = `${mv.name}, ${mv.level}${mv.notes ? `, ${mv.notes}` : ""}`;
  for (const w of READ_WORDS) reads[w] = READ_MEANINGS[w] ?? w;
  reads[NO_READ] = "no clear pattern yet";
  q.read = { type: "choice", instructions: `What ${them.name} does within the next 6 seconds, from what they keep doing.`, criteria: reads };
  q.plan_failing = { type: "noul", instructions: `The plan in force is failing: ${me.name} has been losing the exchanges since it was applied and the coach should rethink it.` };
  q.window_open = { type: "noul", instructions: `A specific punish or super window is open right now (the opponent is recovering from a whiff, knocked down or stunned, or ${me.name}'s super is ready in range) that the coach should queue moves for.` };
  q.pattern_changed = { type: "noul", instructions: `${them.name} has changed what they keep doing since the coach's last turn.` };
  return q;
}

/** The state block for one tick: who is fighting, the turn message's words, the brain's plan and orders. */
export function jevState(side: Side, hello: Hello, state: State | null, events: GameEvent[], baseline: Plan | null, orders: string | null): string {
  const me = hello[side];
  const them = hello[other(side)];
  const specials = them.moves
    .filter((mv) => /^\d{3}/.test(mv.input))
    .map((mv) => `${mv.input} ${mv.name}${mv.notes ? ` (${mv.notes})` : ""}`)
    .join(", ");
  const lines = [
    `Fighter: ${me.name}${me.archetype ? ` (${me.archetype})` : ""}. Opponent: ${them.name}${them.archetype ? ` (${them.archetype})` : ""}; their specials: ${specials || "none"}.`,
    buildTurnMessage(side, state, events.slice(-MAX_STATE_EVENTS), baseline, []).replace(/\nAdjust the plan with the tools\.$/, ""),
    `Coach's baseline plan: ${planText(baseline)}.`,
    `Coach's standing orders: ${orders?.trim() || "none yet"}.`,
    "Judge every answer from this state, what the opponent keeps doing, and the coach's baseline and orders.",
  ];
  return lines.join("\n");
}

// ---- reading the answers ----

const probOf = (p: JevAnswer["probabilities"], key: string | number): number => {
  if (!p) return 0;
  const v = Array.isArray(p) ? p[Number(key)] : (p[String(key)] ?? p[Number(key)]);
  return typeof v === "number" && Number.isFinite(v) ? v : 0;
};

/** A score answer as a knob value 0..1 in steps of 0.25 (the level nearest the weighted mean). */
export function knobOf(a: JevAnswer | undefined): number | null {
  if (!a) return null;
  let s = typeof a.score === "number" && Number.isFinite(a.score) ? a.score : NaN;
  if (Number.isNaN(s) && a.probabilities) {
    // No score given: the weighted mean of the level indices from the probabilities.
    let sum = 0;
    let weight = 0;
    for (let i = 0; i < LEVELS.length; i++) {
      const p = probOf(a.probabilities, i);
      sum += i * p;
      weight += p;
    }
    if (weight > 0) s = sum / weight;
  }
  if (Number.isNaN(s)) return null;
  const level = Math.round(Math.min(LEVELS.length - 1, Math.max(0, s)));
  return level / (LEVELS.length - 1);
}

/** A choice answer: the option and its probability (the given choice, else the most probable). */
export function choiceOf(a: JevAnswer | undefined): { choice: string; p: number } | null {
  if (!a) return null;
  if (typeof a.choice === "string" && a.choice) return { choice: a.choice, p: probOf(a.probabilities, a.choice) || (typeof a.confidence === "number" ? a.confidence : 0) };
  if (a.probabilities && !Array.isArray(a.probabilities)) {
    let best: { choice: string; p: number } | null = null;
    for (const [k, v] of Object.entries(a.probabilities)) if (typeof v === "number" && (!best || v > best.p)) best = { choice: k, p: v };
    return best;
  }
  return null;
}

/** A noul answer: the probability that the statement holds. */
export function noulOf(a: JevAnswer | undefined): number | null {
  if (!a) return null;
  const v = typeof a.noul === "number" ? a.noul : typeof a.confidence === "number" ? a.confidence : NaN;
  return Number.isFinite(v) ? Math.min(1, Math.max(0, v)) : null;
}

// ---- the fake, for tests and keyless runs ----

/** Attacks in a "Recent attacks: 236P Fireball (blocked), 2LK (hit)" list: input and outcome. */
export function parseRecent(text: string): { input: string; outcome: string }[] {
  const out: { input: string; outcome: string }[] = [];
  for (const m of text.matchAll(/([\w.]+)(?: [^,(:]*?)? \((hit|counter|blocked|whiffed|pending)\)/g)) out.push({ input: m[1], outcome: m[2] });
  return out;
}

/**
 * A deterministic stand-in for Jev (spec "jev:fake", or the reflexes of a fake coach): answers
 * from the words of the state, so the whole reflex loop runs with no key and no cost. Block and
 * reaction rise against an opponent landing hits, punish against a whiffer, anti-air against a
 * jumper; the read is the opponent's most repeated recent attack (two or more times, 0.72), else
 * nothing; the plan is failing when health is 20 points behind, a window is open when the super
 * is ready in range or the opponent is down; the pattern changed after three or more of their
 * hits since the last turn.
 */
export class FakeJevClient implements ReflexClient {
  calls = 0;
  readonly delayMs: number;
  readonly override: ((state: string, questions: Record<string, JevQuestion>) => Partial<Record<string, JevAnswer>>) | null;
  constructor(delayMs = 0, override: FakeJevClient["override"] = null) {
    this.delayMs = delayMs;
    this.override = override;
  }

  async decide(_spec: string, state: string, questions: Record<string, JevQuestion>): Promise<JevResult> {
    this.calls++;
    if (this.delayMs) await new Promise((r) => setTimeout(r, this.delayMs));
    const opp = /^Opponent: (.*)$/m.exec(state)?.[1] ?? "";
    const me = /^You: (.*)$/m.exec(state)?.[1] ?? "";
    const header = state.split("\n")[0] ?? "";
    const archetype = /Opponent: [^(]*\(([^)]*)\)/.exec(header)?.[1]?.toLowerCase() ?? "";
    const distance = Number(/Distance ([\d.]+) m/.exec(state)?.[1] ?? "1.6");
    const theirs = parseRecent(opp.slice(opp.indexOf("Recent attacks:") + "Recent attacks:".length));
    const hits = theirs.filter((a) => a.outcome === "hit" || a.outcome === "counter").length;
    const whiffs = theirs.filter((a) => a.outcome === "whiffed").length;
    const jumps = theirs.filter((a) => a.input.startsWith("j.")).length;
    const myHealth = Number(/health (\d+)%/.exec(me)?.[1] ?? "100");
    const theirHealth = Number(/health (\d+)%/.exec(opp)?.[1] ?? "100");
    const landed = (state.match(/they landed/g) ?? []).length;
    const score = (level: number): JevAnswer => ({ type: "score", score: level, probabilities: LEVELS.map((_, i) => (i === level ? 0.7 : 0.075)), legend: Object.fromEntries(LEVELS.map((l, i) => [i, l])), confidence: 0.7 });
    const choice = (name: string, pick: string, p: number): JevAnswer => {
      const q = questions[name];
      const options = q && q.type === "choice" ? Object.keys(q.criteria) : [pick];
      const rest = options.length > 1 ? (1 - p) / (options.length - 1) : 0;
      return { type: "choice", choice: pick, probabilities: Object.fromEntries(options.map((o) => [o, o === pick ? p : rest])), confidence: p };
    };
    const noul = (p: number): JevAnswer => ({ type: "noul", noul: p });
    const counts = new Map<string, number>();
    for (const a of theirs) if (a.outcome !== "pending") counts.set(a.input, (counts.get(a.input) ?? 0) + 1);
    let read: [string, number] = [NO_READ, 0.6];
    for (const [input, n] of counts) if (n >= 2 && n > (counts.get(read[0]) ?? 0) && questions.read?.type === "choice" && input in questions.read.criteria) read = [input, 0.72];
    const answers: Record<string, JevAnswer> = {
      aggression: score(myHealth >= theirHealth ? 2 : 3),
      block: score(hits >= 2 ? 3 : 1),
      punish: score(whiffs >= 2 ? 3 : 2),
      anti_air: score(jumps >= 1 ? 3 : 1),
      pressure: score(2),
      range: choice("range", archetype.includes("zoner") ? "close" : archetype.includes("grappler") ? "far" : "mid", 0.65),
      reaction: choice("reaction", hits >= 2 ? "fast" : "normal", 0.6),
      favour: choice("favour", distance < 1.2 ? "throw" : NO_FAVOUR, 0.55),
      read: choice("read", read[0], read[1]),
      plan_failing: noul(myHealth + 20 < theirHealth ? 0.8 : 0.2),
      window_open: noul((me.includes("SUPER READY") && distance < 2.2) || /knockdown|stunned/.test(opp.split(". Recent")[0] ?? "") ? 0.85 : 0.15),
      pattern_changed: noul(landed >= 3 ? 0.75 : 0.2),
    };
    const over = this.override?.(state, questions) ?? {};
    for (const [k, v] of Object.entries(over)) if (v) answers[k] = v;
    const input_tokens = Math.ceil((state.length + JSON.stringify(questions).length) / 4);
    return { answers: Object.fromEntries(Object.keys(questions).map((k) => [k, answers[k] ?? noul(0)])), usage: { input_tokens, output_tokens: 0 }, usd: 0, seconds: this.delayMs / 1000 };
  }
}

/** The option weights a favoured option sets (the previous favourite goes back to normal). */
export function favourWeights(previous: string | null, next: string): Record<string, number> {
  const options: Record<string, number> = {};
  if (previous && previous !== NO_FAVOUR && (OPTION_NAMES as readonly string[]).includes(previous)) options[previous] = 1;
  if (next !== NO_FAVOUR && (OPTION_NAMES as readonly string[]).includes(next)) options[next] = 2;
  return options;
}
