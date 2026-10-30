// Phase 0 of docs/jev-plan.md: does Jev's read mean anything on this game's state? Every coach
// turn in battle-logs/<id>/<side>.jsonl kept the prompt the model read (the state in words) and
// the time; the turns that follow say what the opponent then did ("they landed 2HK Sweep ...",
// "they threw you"). So each turn is a question for Jev with an answer in the log: ask the read
// question on the state, count the answers that came true within the read window (6 s), and
// report precision and coverage per threshold, latency and tokens, and how often each gate
// would have fired. With no key (or --client fake) the fake answers, which proves the pipeline
// and nothing about Jev.
//   node src/probe.ts [--client jev|fake] [--logs N] [--turns N] [--root battle-logs-dir] [--out FILE]
import { existsSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { choiceOf, FakeJevClient, GATES, JevClient, jevQuestions, NO_READ, noulOf, type JevQuestion, type ReflexClient } from "./jev.ts";
import { providerKey, REPO_ROOT } from "./models.ts";
import type { Hello, MoveInfo } from "./types.ts";

export const READ_WINDOW_MS = 6000;
export const THRESHOLDS = [0.5, 0.6, 0.7, 0.8];

export interface LoggedTurn {
  at: number;
  prompt: string;
}

/** What the opponent did, from the "Since your last turn" sentences of a later turn's prompt. */
export function opponentActions(prompt: string): { input: string; name: string }[] {
  const out: { input: string; name: string }[] = [];
  const since = /Since your last turn: (.*)/.exec(prompt)?.[1] ?? "";
  for (const m of since.matchAll(/they landed ([\w.]+)\s*([^(]*)\(/g)) out.push({ input: m[1], name: m[2].trim() });
  if (/they threw you/.test(since)) out.push({ input: "throw", name: "throw" });
  for (const m of since.matchAll(/they used the super ([^.]*)\./g)) out.push({ input: "super", name: m[1].trim() });
  return out;
}

/**
 * Does an action fulfil a read? The game's rule (coach_link.gd read_matches) knows each move's
 * level and flags; the log does not, so the words are matched on the input notation: lows are
 * crouching kicks and the sweep, overheads are jump attacks, uppercuts 2HP and 623 moves,
 * reversals 623 moves, fireballs 236P or a move named like one, supers 236236. Approximate.
 */
export function readCameTrue(read: string, actions: { input: string; name: string }[]): boolean {
  const w = read.toLowerCase();
  return actions.some(({ input, name }) => {
    const i = input.toLowerCase();
    switch (w) {
      case "throw":
        return i === "throw";
      case "super":
        return i === "super" || i.startsWith("236236");
      case "jump":
      case "overhead":
        return i.startsWith("j.");
      case "low":
        return /^2(lk|lp|hk)$/.test(i);
      case "sweep":
        return i === "2hk";
      case "uppercut":
        return i === "2hp" || i.startsWith("623");
      case "reversal":
        return i.startsWith("623");
      case "fireball":
        return i === "236p" || /fire|ball|wave|shot|projectile/i.test(name);
      default:
        return i === w;
    }
  });
}

/** The fighters as the side's system prompt (in <side>.md) describes them: enough for the questions. */
export function helloFromSystemPrompt(md: string): { side: "p1" | "p2"; hello: Hello } | null {
  const side = /^# (p1|p2) · /.exec(md)?.[1] as "p1" | "p2" | undefined;
  const mine = /You are the ringside coach of ([^ ]+) in/.exec(md)?.[1];
  const theirs = /^Opponent: ([^,(]+)(?: \(([^)]*)\))?, (\d+) health\. Their specials: (.*)\.$/m.exec(md);
  if (!side || !mine || !theirs) return null;
  const myMoves: MoveInfo[] = [];
  const block = md.slice(md.indexOf("Your fighter,"), md.indexOf("Shared basics:"));
  for (const m of block.matchAll(/^- ([\w.]+): ([^,]+), (\w+), (\d+)f startup, (\d+) damage(?:, (.*))?$/gm)) myMoves.push({ input: m[1], name: m[2], level: m[3], startup: Number(m[4]), active: 0, recovery: 0, damage: Number(m[5]), notes: m[6] });
  const theirMoves: MoveInfo[] = [];
  if (theirs[4] !== "none") for (const s of theirs[4].split(", ")) {
    const sp = s.indexOf(" ");
    theirMoves.push({ input: s.slice(0, sp), name: s.slice(sp + 1), level: "mid", startup: 0, active: 0, recovery: 0, damage: 0 });
  }
  const me = { id: mine.toLowerCase(), name: mine, archetype: /Your fighter, [^(]*\(([^)]*)\)/.exec(md)?.[1], max_health: Number(/, (\d+) health\)/.exec(md)?.[1] ?? 1000), moves: myMoves };
  const them = { id: theirs[1].toLowerCase(), name: theirs[1], archetype: theirs[2], max_health: Number(theirs[3]), moves: theirMoves };
  const hello: Hello = { type: "hello", p1: side === "p1" ? me : them, p2: side === "p1" ? them : me, stage: "", rounds_to_win: 2, round_seconds: 99 };
  return { side, hello };
}

export function loadTurns(file: string): LoggedTurn[] {
  if (!existsSync(file)) return [];
  const out: LoggedTurn[] = [];
  for (const line of readFileSync(file, "utf8").split("\n")) {
    if (!line.trim()) continue;
    try {
      const t = JSON.parse(line);
      if (typeof t.prompt === "string" && t.at && !/^The round has not started yet/.test(t.prompt)) out.push({ at: Date.parse(t.at), prompt: t.prompt });
    } catch {}
  }
  return out;
}

export interface ProbeRecord {
  log: string;
  side: string;
  turn: number;
  read: string;
  p: number;
  cameTrue: boolean | null; // null: no later turn within the window to judge by
  gates: Record<string, number>;
  seconds: number;
  tokens: number;
}

export interface ProbeReport {
  client: string;
  logs: number;
  turns: number;
  judged: number;
  latency: { p50: number; p95: number; mean: number };
  tokensPerCall: number;
  usd: number;
  thresholds: { threshold: number; fired: number; right: number; precision: number | null; coverage: number }[];
  gates: Record<string, { fired: number; rate: number }>;
  readsByWord: Record<string, { fired: number; right: number }>;
  llmReads: { model: string; made: number; right: number }[];
}

const quantile = (xs: number[], q: number): number => {
  if (!xs.length) return 0;
  const s = [...xs].sort((a, b) => a - b);
  return s[Math.min(s.length - 1, Math.floor(q * s.length))];
};

export async function probe(client: ReflexClient, clientName: string, root = join(REPO_ROOT, "battle-logs"), maxLogs = 12, maxTurns = 400, gateThreshold = 0.7): Promise<{ report: ProbeReport; records: ProbeRecord[] }> {
  const records: ProbeRecord[] = [];
  const llmReads: ProbeReport["llmReads"] = [];
  const ids = existsSync(root) ? readdirSync(root).filter((id) => existsSync(join(root, id, "battle.json"))).sort().reverse().slice(0, maxLogs) : [];
  let usd = 0;
  for (const id of ids) {
    let battle: any = null;
    try {
      battle = JSON.parse(readFileSync(join(root, id, "battle.json"), "utf8"));
    } catch {}
    for (const side of ["p1", "p2"] as const) {
      const reads = battle?.coaches?.[side]?.reads;
      if (reads && reads.made) llmReads.push({ model: String(battle.sides?.[side]?.model ?? "?"), made: Number(reads.made), right: Number(reads.right) });
      const md = existsSync(join(root, id, `${side}.md`)) ? readFileSync(join(root, id, `${side}.md`), "utf8") : "";
      const parsed = helloFromSystemPrompt(md);
      if (!parsed) continue;
      const questions = jevQuestions(side, parsed.hello);
      const turns = loadTurns(join(root, id, `${side}.jsonl`));
      for (let i = 0; i < turns.length && records.length < maxTurns; i++) {
        const t = turns[i];
        const header = `Fighter: ${parsed.hello[side].name}. Opponent: ${parsed.hello[side === "p1" ? "p2" : "p1"].name}${parsed.hello[side === "p1" ? "p2" : "p1"].archetype ? ` (${parsed.hello[side === "p1" ? "p2" : "p1"].archetype})` : ""}.`;
        const state = `${header}\n${t.prompt}\nCoach's baseline plan: none.\nCoach's standing orders: none yet.`;
        let r;
        try {
          r = await client.decide("jev:jev", state, questions);
        } catch (e) {
          console.error(`${id} ${side} turn ${i + 1}: ${e instanceof Error ? e.message : e}`);
          continue;
        }
        usd += r.usd ?? 0;
        const read = choiceOf(r.answers.read) ?? { choice: NO_READ, p: 0 };
        const later = turns.slice(i + 1).filter((u) => u.at > t.at && u.at <= t.at + READ_WINDOW_MS);
        const actions = later.flatMap((u) => opponentActions(u.prompt));
        const judged = later.length > 0;
        const gates: Record<string, number> = {};
        for (const g of GATES) gates[g] = noulOf(r.answers[g]) ?? 0;
        records.push({ log: id, side, turn: i + 1, read: read.choice, p: read.p, cameTrue: judged ? readCameTrue(read.choice, actions) : null, gates, seconds: r.seconds, tokens: r.usage.input_tokens });
      }
    }
  }
  const judged = records.filter((r) => r.cameTrue !== null && r.read !== NO_READ);
  const thresholds = THRESHOLDS.map((threshold) => {
    const fired = judged.filter((r) => r.p >= threshold);
    const right = fired.filter((r) => r.cameTrue).length;
    return { threshold, fired: fired.length, right, precision: fired.length ? right / fired.length : null, coverage: records.length ? fired.length / records.length : 0 };
  });
  const gates: ProbeReport["gates"] = {};
  for (const g of GATES) {
    const fired = records.filter((r) => r.gates[g] >= gateThreshold).length;
    gates[g] = { fired, rate: records.length ? fired / records.length : 0 };
  }
  const readsByWord: ProbeReport["readsByWord"] = {};
  for (const r of judged) {
    const row = (readsByWord[r.read] ??= { fired: 0, right: 0 });
    row.fired++;
    if (r.cameTrue) row.right++;
  }
  const secs = records.map((r) => r.seconds);
  const report: ProbeReport = {
    client: clientName,
    logs: ids.length,
    turns: records.length,
    judged: judged.length,
    latency: { p50: quantile(secs, 0.5), p95: quantile(secs, 0.95), mean: secs.length ? secs.reduce((a, b) => a + b, 0) / secs.length : 0 },
    tokensPerCall: records.length ? Math.round(records.reduce((a, r) => a + r.tokens, 0) / records.length) : 0,
    usd,
    thresholds,
    gates,
    readsByWord,
    llmReads,
  };
  return { report, records };
}

export function reportText(r: ProbeReport): string {
  const lines = [
    `Jev probe (${r.client}): ${r.turns} turns from ${r.logs} logs, ${r.judged} reads judged (a later turn within ${READ_WINDOW_MS / 1000} s)`,
    `latency p50 ${(r.latency.p50 * 1000).toFixed(0)} ms, p95 ${(r.latency.p95 * 1000).toFixed(0)} ms; ${r.tokensPerCall} input tokens per call; $${r.usd.toFixed(4)} in all`,
    "",
    "| threshold | reads fired | came true | precision | coverage of turns |",
    "|---|---|---|---|---|",
    ...r.thresholds.map((t) => `| ${t.threshold} | ${t.fired} | ${t.right} | ${t.precision == null ? "—" : `${(100 * t.precision).toFixed(0)}%`} | ${(100 * t.coverage).toFixed(0)}% |`),
    "",
    `gates at 0.7: ${Object.entries(r.gates)
      .map(([g, v]) => `${g} ${v.fired} (${(100 * v.rate).toFixed(0)}% of turns)`)
      .join(", ")}`,
    `reads by word: ${Object.entries(r.readsByWord)
      .sort((a, b) => b[1].fired - a[1].fired)
      .map(([w, v]) => `${w} ${v.right}/${v.fired}`)
      .join(", ") || "none"}`,
    `LLM coaches' reads in the same logs: ${r.llmReads.map((l) => `${l.model} ${l.right}/${l.made}`).join(", ") || "none recorded"}`,
  ];
  return lines.join("\n");
}

if (process.argv[1] && import.meta.url === new URL(`file://${process.argv[1]}`).href) {
  const argv = process.argv.slice(2);
  const get = (name: string, fallback: string) => {
    const i = argv.indexOf(`--${name}`);
    return i >= 0 && argv[i + 1] ? argv[i + 1] : fallback;
  };
  const wanted = get("client", providerKey("jev").key ? "jev" : "fake");
  const client: ReflexClient = wanted === "jev" ? new JevClient() : new FakeJevClient();
  if (wanted === "fake") console.log("no Jev key (infra/keys/jev.key): the fake answers, which proves the pipeline and nothing about Jev");
  probe(client, wanted, get("root", join(REPO_ROOT, "battle-logs")), Number(get("logs", "12")), Number(get("turns", "400")))
    .then(({ report, records }) => {
      console.log(reportText(report));
      const out = get("out", join(REPO_ROOT, "battle-logs", `jev-probe-${wanted}.json`));
      writeFileSync(out, JSON.stringify({ report, records }, null, 2));
      console.log(`written to ${out}`);
    })
    .catch((e) => {
      console.error(e instanceof Error ? e.message : e);
      process.exit(1);
    });
}
