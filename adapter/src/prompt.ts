// What a coach reads and the tools it answers with. Pure functions: the tests pin the text.
import { OPTION_NAMES, other, type ChatBody, type FighterInfo, type GameEvent, type Hello, type Plan, type RecentAttack, type Rule, type Side, type SideState, type State } from "./types.ts";
import type { Effort } from "./models.ts";

export const MAX_CAPTION = 60;
export const MAX_TALK = 140;
export const MAX_READ = 24;
/** What a read may name besides one of the opponent's move inputs (the game checks the same list). */
export const READ_WORDS = ["jump", "throw", "super", "fireball", "low", "overhead", "sweep", "reversal", "uppercut"] as const;

export const PREDICT_TOOL: NonNullable<ChatBody["tools"]>[number] = {
  type: "function",
  function: {
    name: "predict",
    description: `A read: what the opponent does within the next 6 seconds. One of their move inputs (623P, 2HK...) or ${READ_WORDS.join(", ")}. One read at a time; a new one replaces the old, which then counts as a miss. A correct read shows CALLED IT on screen and counts for you; call it only when you see a pattern.`,
    parameters: { type: "object", properties: { what: { type: "string", maxLength: MAX_READ } }, required: ["what"] },
  },
};

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
  PREDICT_TOOL,
];

const pct = (v: number, max: number): string => `${Math.round((100 * v) / Math.max(1, max))}%`;
const m = (v: number): string => `${(Math.round(v * 10) / 10).toFixed(1)} m`;

export function movesText(f: FighterInfo): string {
  return f.moves.map((mv) => `- ${mv.input}: ${mv.name}, ${mv.level}, ${mv.startup}f startup, ${mv.damage} damage${mv.notes ? `, ${mv.notes}` : ""}`).join("\n");
}

export function buildSystemPrompt(side: Side, hello: Hello, _effort: Effort = "low"): string {
  const me = hello[side];
  const them = hello[other(side)];
  return `You are the ringside coach of ${me.name} in a one-on-one 3D fighting game (best of ${hello.rounds_to_win * 2 - 1} rounds of ${hello.round_seconds} seconds, ${me.max_health} health). Your fighter fights by itself at 60 frames a second; you cannot press buttons. Every couple of seconds you see the fight and adjust the game plan with the tools: set_plan (tendencies: aggression, range, block, punish, anti_air, reaction, pressure, option weights), queue (specific moves to do next), say (a short caption) and predict (a read on what the opponent does next). Start every reply with one line of corner talk, under ${MAX_TALK} characters: what you see and what you are changing. It is shown on screen under your fighter's name, so write it for the crowd. Then the tools, and nothing else.

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
      // A blocked attack did no real damage: say so instead of quoting the move's damage.
      return `${who(e.attacker)} landed ${[e.input, e.name].filter(Boolean).join(" ")} (${e.result}${Number(e.combo) > 1 ? `, combo ${e.combo}` : ""}${e.result === "blocked" ? ", no damage" : `, ${e.damage} damage`}) on ${whom(e.defender)}.`;
    case "throw":
      return `${who(e.attacker)} threw ${whom(e.defender)}.`;
    case "knockdown":
      return `${who(e.side)} got knocked down.`;
    case "super":
      return `${who(e.side)} used the super ${e.name ?? ""}.`;
    case "read":
      return e.side === side ? (e.right ? `Your read "${e.what}" came true (${e.actual}): CALLED IT.` : `Your read "${e.what}" missed${e.actual ? ` (${e.actual})` : ""}.`) : "";
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
  const told = events.map((e) => eventText(e, side)).filter(Boolean);
  lines.push(told.length ? `Since your last turn: ${told.join(" ")}` : "Since your last turn: nothing notable.");
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

/** The read's word: a move input or one of READ_WORDS; "" when there is nothing usable. */
export function validatePredict(raw: unknown): string {
  const t = raw && typeof raw === "object" ? String((raw as Record<string, unknown>).what ?? "") : String(raw ?? "");
  return t.replace(/[^\w.]/g, "").slice(0, MAX_READ);
}

/** The first line of the reply text, for the HUD: the coach's corner talk. */
export function talkOf(content: unknown): string {
  const first = (String(content ?? "").split("\n").map((l) => l.replace(/^[\s#*>\-•"“”]+|["“”]+$/g, "").trim()).find((l) => l.length > 0) ?? "").replace(/\s+/g, " ");
  if (first.length <= MAX_TALK) return first;
  const cut = first.lastIndexOf(" ", MAX_TALK - 1); // whole words, then an ellipsis
  return first.slice(0, cut > MAX_TALK / 2 ? cut : MAX_TALK - 1).trimEnd() + "…";
}

// Merges a plan into the plan in force (what the game does too).
export function mergePlan(current: Plan | null, next: Plan): Plan {
  const out: Plan = { ...(current ?? {}), ...next };
  if (current?.options || next.options) out.options = { ...(current?.options ?? {}), ...(next.options ?? {}) };
  return out;
}

// ---- phase 4: the self-coding fighter and the beat fighter ----

export const OPPONENT_STATES = ["idle", "attacking", "recovering", "blocking", "knocked_down", "jumping", "stunned"];

export const POLICY_TOOL: NonNullable<ChatBody["tools"]>[number] = {
  type: "function",
  function: {
    name: "set_policy",
    description:
      "Write your fighter's behaviour for the next round: the plan (tendencies) and up to 12 rules. Every 10 frames, when the fighter is free and has nothing queued, the rules whose conditions all hold are collected and one is picked by weight; its moves are then performed in order. A rule rests 45 frames after firing. With no matching rule the fighter plays its own style under the plan. Replaces the previous rules entirely.",
    parameters: {
      type: "object",
      properties: {
        plan: TOOLS[0].function.parameters,
        rules: {
          type: "array",
          maxItems: 12,
          items: {
            type: "object",
            required: ["when", "do"],
            properties: {
              name: { type: "string", description: "A short name, shown in the logs." },
              when: {
                type: "object",
                description: "All conditions must hold. Leave a field out to not test it.",
                properties: {
                  range: { type: "string", enum: ["close", "mid", "far"], description: "close under 1.2 m, mid under 2.2 m, far beyond." },
                  opponent: { type: "string", enum: OPPONENT_STATES, description: "attacking = their move is about to hit; recovering = they whiffed or finished a move and are open; blocking = in blockstun; stunned = being hit." },
                  opponent_cornered: { type: "boolean" },
                  cornered: { type: "boolean", description: "Your own back is at the edge." },
                  meter_full: { type: "boolean", description: "Your super is ready." },
                  health_below: { type: "number", minimum: 0, maximum: 1, description: "Your health share is below this." },
                  opponent_health_below: { type: "number", minimum: 0, maximum: 1 },
                },
              },
              do: { type: "array", items: { type: "string" }, minItems: 1, maxItems: 4, description: "Move inputs from your list, or throw, dash, backdash, jump, jump_in, sidestep, 'block N', 'crouch_block N', 'wait N', 'approach N', 'retreat N' (N frames)." },
              weight: { type: "number", minimum: 0, maximum: 5, description: "Relative chance among the rules that match (default 1)." },
            },
          },
        },
      },
    },
  },
};

export const SCRIPT_TOOLS: NonNullable<ChatBody["tools"]> = [POLICY_TOOL, TOOLS[2]];
export const BEAT_TOOLS: NonNullable<ChatBody["tools"]> = [TOOLS[1], TOOLS[2]];

export function buildScriptSystemPrompt(side: Side, hello: Hello): string {
  const me = hello[side];
  const them = hello[other(side)];
  return `You program ${me.name}, a fighter in a one-on-one 3D fighting game (best of ${hello.rounds_to_win * 2 - 1} rounds of ${hello.round_seconds} seconds, ${me.max_health} health). You cannot act during a round: before the match and after every round you write the fighter's behaviour with set_policy (a plan of tendencies plus rules: when the fight looks like this, do these moves), and the fighter runs it alone at 60 frames a second. After each round you see what happened: every attack by both sides with how often it hit, was blocked or whiffed, throws, knockdowns, health left. Rewrite the rules to beat what the opponent actually did. Give set_policy once per turn, optionally say once; nothing else.

Your fighter, ${me.name}${me.archetype ? ` (${me.archetype})` : ""}:
${movesText(me)}
Shared basics: LP jab (4f, cancels), HP straight, LK mid kick, HK roundhouse (long), 2LP, 2LK low kick, 2HP uppercut (launcher, anti-air), 2HK sweep (low, knockdown), jump attacks are overheads, throw (unblockable, techable). Lows must be blocked crouching, overheads standing. A whiffed heavy leaves the attacker open about 20 frames.

Opponent: ${them.name}${them.archetype ? ` (${them.archetype})` : ""}, ${them.max_health} health. Their moves:
${movesText(them)}

Good rules are specific: a punish when the opponent is recovering at close range, an anti-air when they are jumping, a low when they block standing a lot, the super when meter_full and in range, a retreat when your health is low and you are not cornered. Three to eight rules usually beat twelve.`;
}

export function summaryText(side: Side, summary: any): string {
  if (!summary || typeof summary !== "object") return "no summary";
  const one = (label: string, s: any) => {
    if (!s) return `${label}: nothing`;
    const attacks = Object.entries((s.attacks ?? {}) as Record<string, Record<string, number>>)
      .map(([input, c]) => `${input} ${c.hit ?? 0} hit, ${c.counter ?? 0} counter, ${c.blocked ?? 0} blocked, ${c.whiffed ?? 0} whiffed`)
      .join("; ");
    return `${label}: health left ${pct(s.health_left ?? 0, s.max_health ?? 1)}, ${s.throws ?? 0} throws, knocked down ${s.knockdowns ?? 0} times. Attacks: ${attacks || "none"}.${s.rule_fired_last ? ` Last rule that fired: ${s.rule_fired_last}.` : ""}`;
  };
  return `${one("You", summary[side])}\n${one("Opponent", summary[other(side)])}`;
}

export function buildScriptTurnMessage(side: Side, hello: Hello, events: GameEvent[], lastResults: string[]): string {
  const lines: string[] = [];
  const ends = events.filter((e) => e.event === "round_end");
  if (ends.length === 0) lines.push(`The match is about to start. Write ${hello[side].name}'s behaviour for round 1.`);
  for (const e of ends) {
    lines.push(`Round ${e.round ?? "?"} over: ${e.winner == null ? "draw" : e.winner === side ? "you won it" : "they won it"} (${e.reason}).`);
    lines.push(summaryText(side, (e as any).summary));
  }
  if (lastResults.length) lines.push(`Your last tools: ${lastResults.join("; ")}.`);
  lines.push("Write the behaviour for the next round with set_policy.");
  return lines.join("\n");
}

export function buildBeatSystemPrompt(side: Side, hello: Hello, beatTicks: number): string {
  const me = hello[side];
  const them = hello[other(side)];
  return `You fight as ${me.name} in a one-on-one 3D fighting game played in beats: every ${(beatTicks / 60).toFixed(1)} seconds the game pauses and both players choose their next moves; then it plays on with both choices. Choose with queue (one to four inputs, performed in order as soon as your fighter can act; nothing happens by itself, so choose blocks too) and optionally say a caption. Answer with the tools only.

Your fighter, ${me.name}${me.archetype ? ` (${me.archetype})` : ""}:
${movesText(me)}
Shared basics: LP jab (4f, cancels), HP straight, LK mid kick, HK roundhouse (long), 2LP, 2LK low kick, 2HP uppercut (launcher, anti-air), 2HK sweep (low, knockdown), j.HK flying kick (overhead), throw (unblockable, techable, under 1 m). Movement: 'approach N' / 'retreat N' walk for N frames, dash, backdash, jump, 'block N' (stand, blocks highs and mids), 'crouch_block N' (blocks lows and mids), 'wait N'. Lows must be blocked crouching, overheads standing.

Opponent: ${them.name}${them.archetype ? ` (${them.archetype})` : ""}, ${them.max_health} health. Their specials: ${them.moves
    .filter((mv) => /^\d{3}/.test(mv.input))
    .map((mv) => `${mv.input} ${mv.name}`)
    .join(", ") || "none"}.

Distance matters: at over 2.2 m only specials and walking reach; at 1.2 to 2.2 m long kicks and lunges; under 1.2 m everything, throws under 1 m. Read what they did last beat and answer it.`;
}

export function buildBeatMessage(side: Side, beat: State & { n?: number }, events: GameEvent[], lastResults: string[]): string {
  const lines: string[] = [];
  const me = beat[side];
  const them = beat[other(side)];
  lines.push(`Beat ${beat.n ?? "?"}, round ${beat.round}, ${beat.timer} s left, rounds won you ${beat.wins[side === "p1" ? 0 : 1]} - ${beat.wins[side === "p1" ? 1 : 0]} them. Distance ${m(beat.distance)}.`);
  lines.push(sideText("You", me) + (me.queued && me.queued.length ? ` Still queued: ${me.queued.join(", ")}.` : ""));
  lines.push(sideText("Opponent", them));
  lines.push(events.length ? `Since the last beat: ${events.map((e) => eventText(e, side)).join(" ")}` : "Since the last beat: nothing landed.");
  if (lastResults.length) lines.push(`Your last tools: ${lastResults.join("; ")}.`);
  lines.push("Choose your moves for this beat with queue.");
  return lines.join("\n");
}

/** The rules the model gave, cleaned for the game (which validates them again). */
export function validateRules(raw: unknown): { rules: Rule[]; problems: string[] } {
  const problems: string[] = [];
  if (!Array.isArray(raw)) return { rules: [], problems: ["rules must be an array"] };
  const rules: Rule[] = [];
  for (const [i, r] of raw.entries()) {
    if (rules.length >= 12) {
      problems.push("at most 12 rules; the rest were dropped");
      break;
    }
    if (!r || typeof r !== "object") {
      problems.push(`rule ${i + 1} is not an object`);
      continue;
    }
    const o = r as Record<string, unknown>;
    const when = o.when && typeof o.when === "object" ? (o.when as Record<string, unknown>) : {};
    const moves = Array.isArray(o.do) ? o.do.map((x) => String(x).trim()).filter(Boolean).slice(0, 4) : [];
    if (!moves.length) {
      problems.push(`rule ${i + 1} (${String(o.name ?? "")}) has no moves`);
      continue;
    }
    const w: Rule["when"] = {};
    for (const [k, v] of Object.entries(when)) {
      if (k === "range" && ["close", "mid", "far"].includes(String(v))) w.range = v as Rule["when"]["range"];
      else if (k === "opponent" && OPPONENT_STATES.includes(String(v))) w.opponent = String(v);
      else if (["opponent_cornered", "cornered", "meter_full"].includes(k) && typeof v === "boolean") (w as Record<string, unknown>)[k] = v;
      else if (["health_below", "opponent_health_below"].includes(k) && typeof v === "number") (w as Record<string, unknown>)[k] = Math.min(1, Math.max(0, v));
      else problems.push(`rule ${i + 1}: condition ${k}=${JSON.stringify(v)} dropped`);
    }
    rules.push({ name: o.name ? String(o.name).slice(0, 40) : `rule ${i + 1}`, when: w, do: moves, weight: typeof o.weight === "number" ? Math.min(5, Math.max(0, o.weight)) : 1 });
  }
  return { rules, problems };
}
