// What a coach reads and the tools it answers with. Pure functions: the tests pin the text.
import { OPTION_NAMES, other, type ChatBody, type FighterInfo, type GameEvent, type Hello, type Plan, type RecentAttack, type Side, type SideState, type State } from "./types.ts";
import type { Effort } from "./models.ts";

export const MAX_CAPTION = 60;

export const TOOLS: NonNullable<ChatBody["tools"]> = [
  {
    type: "function",
    function: {
      name: "set_plan",
      description:
        "Change your fighter's game plan. Every field is optional; a field you leave out keeps its value. The fighter executes at 60 frames a second by itself: you set tendencies, not buttons.",
      parameters: {
        type: "object",
        properties: {
          aggression: { type: "number", minimum: 0, maximum: 1, description: "How often it attacks rather than waits (0 passive, 1 relentless)." },
          range: { description: "Where it wants to stand: close (throw and string range, under 1.2 m), mid (poke range, about 1.6 m), far (over 2.2 m, fireballs and waiting), or metres as a number.", anyOf: [{ type: "string", enum: ["close", "mid", "far"] }, { type: "number", minimum: 0.5, maximum: 4 }] },
          block: { type: "number", minimum: 0, maximum: 1, description: "Chance to block an attack it sees coming." },
          punish: { type: "number", minimum: 0, maximum: 1, description: "Chance to punish a whiffed or blocked attack." },
          anti_air: { type: "number", minimum: 0, maximum: 1, description: "Chance to answer a jump-in with an uppercut or rising move." },
          reaction: { type: "string", enum: ["fast", "normal", "slow"], description: "Reaction time: fast 6 frames, normal 10, slow 16 (the game's Hard CPU reacts in 8)." },
          pressure: { type: "number", minimum: 0, maximum: 1, description: "How often it keeps attacking an opponent who is blocking." },
          options: {
            type: "object",
            description: `Weights (0 never, 1 normal, up to 3) on what it picks when it acts: ${OPTION_NAMES.join(", ")}. poke = a long normal from mid range; string = jab combo; rush = travelling special; grab = command grab; ground_special = the 214 special; stance = power-up stance; reversal = counter stance.`,
            properties: Object.fromEntries(OPTION_NAMES.map((n) => [n, { type: "number", minimum: 0, maximum: 3 }])),
          },
        },
      },
    },
  },
  {
    type: "function",
    function: {
      name: "queue",
      description: "Make the fighter do these inputs next, in order, as soon as it can act: a move input from your list (LP, 2HK, 6HK, 236K, 236236K...), throw, dash, backdash, jump, sidestep, 'block N' (hold back N frames) or 'wait N'. Use for a combo, a super when the meter is full, or a specific punish. Not more than 4.",
      parameters: { type: "object", properties: { moves: { type: "array", items: { type: "string" }, maxItems: 4 } }, required: ["moves"] },
    },
  },
  {
    type: "function",
    function: {
      name: "say",
      description: `A caption shown at your corner, at most ${MAX_CAPTION} characters: what you are telling your fighter.`,
      parameters: { type: "object", properties: { text: { type: "string", maxLength: MAX_CAPTION } }, required: ["text"] },
    },
  },
];

const pct = (v: number, max: number): string => `${Math.round((100 * v) / Math.max(1, max))}%`;
const m = (v: number): string => `${(Math.round(v * 10) / 10).toFixed(1)} m`;

export function movesText(f: FighterInfo): string {
  return f.moves.map((mv) => `- ${mv.input}: ${mv.name}, ${mv.level}, ${mv.startup}f startup, ${mv.damage} damage${mv.notes ? `, ${mv.notes}` : ""}`).join("\n");
}

export function buildSystemPrompt(side: Side, hello: Hello, _effort: Effort = "low"): string {
  const me = hello[side];
  const them = hello[other(side)];
  return `You are the ringside coach of ${me.name} in a one-on-one 3D fighting game (best of ${hello.rounds_to_win * 2 - 1} rounds of ${hello.round_seconds} seconds, ${me.max_health} health). Your fighter fights by itself at 60 frames a second; you cannot press buttons. Every couple of seconds you see the fight and adjust the game plan with the tools: set_plan (tendencies: aggression, range, block, punish, anti_air, reaction, pressure, option weights), queue (specific moves to do next) and say (a short caption). Give your tools in one reply and nothing else; do not explain.

Your fighter, ${me.name}${me.archetype ? ` (${me.archetype})` : ""}:
${movesText(me)}
Shared basics: LP jab (4f, cancels), HP straight, LK mid kick, HK roundhouse (long), 2LP, 2LK low kick, 2HP uppercut (launcher, anti-air), 2HK sweep (low, knockdown), jump attacks are overheads, throw (LP+LK, unblockable, 120 damage, techable). Lows must be blocked crouching, overheads standing. A whiffed heavy move leaves you open for about 20 frames: that is when punishes land.

Opponent: ${them.name}${them.archetype ? ` (${them.archetype})` : ""}, ${them.max_health} health. Their specials: ${them.moves
    .filter((mv) => /^\d{3}/.test(mv.input))
    .map((mv) => `${mv.input} ${mv.name}`)
    .join(", ") || "none"}.

Ranges: close under 1.2 m (throws, strings), mid about 1.6 m (pokes), far over 2.2 m. Read what the opponent keeps doing (their recent attacks and outcomes) and answer it: block more against a basher, punish more against a whiffer, go low against a standing blocker, anti-air a jumper, close in on a zoner, keep away from a grappler. Spend the super (236236 + button) when the meter is full and you are in range. Change one or two things per turn; the fighter needs time to show the plan.`;
}

export function recentText(recent: RecentAttack[] | undefined): string {
  if (!recent || recent.length === 0) return "nothing yet";
  return recent.map((r) => `${r.input}${r.name ? ` ${r.name}` : ""} (${r.outcome})`).join(", ");
}

function sideText(label: string, s: SideState): string {
  return `${label}: health ${pct(s.health, s.max_health)}, meter ${pct(s.meter, s.max_meter)}${s.meter >= s.max_meter ? " (SUPER READY)" : ""}, ${s.state}${s.move ? ` (${s.move})` : ""}${s.cornered ? ", cornered" : ""}. Recent attacks: ${recentText(s.recent)}.`;
}

export function eventText(e: GameEvent, side: Side): string {
  const who = (s: unknown) => (s === side ? "you" : s === other(side) ? "they" : String(s));
  const whom = (s: unknown) => (s === side ? "you" : s === other(side) ? "them" : String(s));
  switch (e.event) {
    case "round_start":
      return `Round ${e.round} starts.`;
    case "hit":
      return `${who(e.attacker)} landed ${e.input} ${e.name ?? ""} (${e.result}${Number(e.combo) > 1 ? `, combo ${e.combo}` : ""}, ${e.damage} damage) on ${whom(e.defender)}.`;
    case "throw":
      return `${who(e.attacker)} threw ${whom(e.defender)}.`;
    case "knockdown":
      return `${who(e.side)} got knocked down.`;
    case "super":
      return `${who(e.side)} used the super ${e.name ?? ""}.`;
    case "round_end":
      return `Round over: ${e.winner == null ? "draw" : who(e.winner) === "you" ? "you won it" : "they won it"} (${e.reason}).`;
    case "match_end":
      return `Match over: ${e.winner == null ? "draw" : who(e.winner) === "you" ? "you won" : "they won"}.`;
    default:
      return `${e.event}.`;
  }
}

export function planText(plan: Plan | null): string {
  if (!plan || Object.keys(plan).length === 0) return "the fighter's own default style";
  const parts: string[] = [];
  for (const [k, v] of Object.entries(plan)) {
    if (k === "options" && v && typeof v === "object") {
      const o = Object.entries(v as Record<string, number>).map(([n, w]) => `${n} ${w}`);
      if (o.length) parts.push(`options ${o.join(", ")}`);
    } else if (v !== undefined) parts.push(`${k} ${v}`);
  }
  return parts.join("; ") || "the fighter's own default style";
}

export function buildTurnMessage(side: Side, state: State | null, events: GameEvent[], currentPlan: Plan | null, lastResults: string[]): string {
  const lines: string[] = [];
  if (state) {
    const me = state[side];
    const them = state[other(side)];
    lines.push(`Round ${state.round}, ${state.timer} s left, rounds won you ${state.wins[side === "p1" ? 0 : 1]} - ${state.wins[side === "p1" ? 1 : 0]} them. Distance ${m(state.distance)}.`);
    lines.push(sideText("You", me));
    lines.push(sideText("Opponent", them));
  } else lines.push("The round has not started yet.");
  lines.push(events.length ? `Since your last turn: ${events.map((e) => eventText(e, side)).join(" ")}` : "Since your last turn: nothing notable.");
  lines.push(`Your current plan: ${planText(currentPlan)}.`);
  if (lastResults.length) lines.push(`Your last tools: ${lastResults.join("; ")}.`);
  lines.push("Adjust the plan with the tools.");
  return lines.join("\n");
}

// ---- plan validation (what goes to the game) ----

const clamp01 = (v: unknown): number | undefined => (typeof v === "number" && Number.isFinite(v) ? Math.min(1, Math.max(0, v)) : undefined);

// The plan the model gave, cleaned: numbers clamped, unknown fields and options dropped.
// Returns the plan and the complaints (for the next prompt).
export function validatePlan(raw: unknown): { plan: Plan; problems: string[] } {
  const problems: string[] = [];
  const plan: Plan = {};
  if (!raw || typeof raw !== "object") return { plan, problems: ["set_plan needs an object"] };
  const r = raw as Record<string, unknown>;
  for (const k of ["aggression", "block", "punish", "anti_air", "pressure"] as const) {
    if (r[k] !== undefined) {
      const v = clamp01(r[k]);
      if (v === undefined) problems.push(`${k} must be a number 0..1`);
      else plan[k] = v;
    }
  }
  if (r.range !== undefined) {
    if (r.range === "close" || r.range === "mid" || r.range === "far") plan.range = r.range;
    else if (typeof r.range === "number" && Number.isFinite(r.range)) plan.range = Math.min(4, Math.max(0.5, r.range));
    else problems.push("range must be close, mid, far or metres");
  }
  if (r.reaction !== undefined) {
    if (r.reaction === "fast" || r.reaction === "normal" || r.reaction === "slow") plan.reaction = r.reaction;
    else problems.push("reaction must be fast, normal or slow");
  }
  if (r.options !== undefined) {
    if (r.options && typeof r.options === "object") {
      const options: Record<string, number> = {};
      for (const [n, w] of Object.entries(r.options as Record<string, unknown>)) {
        if (!(OPTION_NAMES as readonly string[]).includes(n)) problems.push(`unknown option ${n}`);
        else if (typeof w !== "number" || !Number.isFinite(w)) problems.push(`option ${n} must be a number`);
        else options[n] = Math.min(3, Math.max(0, w));
      }
      if (Object.keys(options).length) plan.options = options;
    } else problems.push("options must be an object of weights");
  }
  for (const k of Object.keys(r)) if (!["aggression", "range", "block", "punish", "anti_air", "reaction", "pressure", "options"].includes(k)) problems.push(`unknown field ${k}`);
  return { plan, problems };
}

export function validateQueue(raw: unknown): { moves: string[]; problems: string[] } {
  const r = (raw && typeof raw === "object" ? (raw as Record<string, unknown>).moves : raw) as unknown;
  if (!Array.isArray(r)) return { moves: [], problems: ["queue needs moves: [..]"] };
  const moves = r.filter((x): x is string => typeof x === "string" && x.trim() !== "").map((x) => x.trim()).slice(0, 4);
  const problems = r.length > 4 ? ["only the first 4 moves are queued"] : [];
  return { moves, problems };
}

export function validateSay(raw: unknown): string {
  const t = raw && typeof raw === "object" ? String((raw as Record<string, unknown>).text ?? "") : String(raw ?? "");
  return t.replace(/\s+/g, " ").trim().slice(0, MAX_CAPTION);
}

// Merges a plan into the plan in force (what the game does too).
export function mergePlan(current: Plan | null, next: Plan): Plan {
  const out: Plan = { ...(current ?? {}), ...next };
  if (current?.options || next.options) out.options = { ...(current?.options ?? {}), ...(next.options ?? {}) };
  return out;
}
