// Tournaments (docs/ringside-plan.md phase 4): a round robin between entrants, each a fighter and
// the model that coaches it, played one match after another through the setup page's Runner.
// Every pair meets once, or twice with the corners swapped for the return leg. The schedule, each
// fixture's result and the standings live in battle-logs/tournaments/<id>.json, so a tournament
// survives a restart of the setup server (unfinished fixtures are then skipped, not resumed).
import type { EventEmitter } from "node:events";
import { existsSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import type { Effort } from "./models.ts";
import type { Fighter, MatchRequest } from "./setup.ts";
import type { Mode } from "./types.ts";

export const MAX_ENTRANTS = 8;
export const ROTATE = "rotate"; // the stage option that cycles through every stage

export interface Entrant {
  fighter: string;
  spec: string;
}

export interface TournamentRequest {
  name: string;
  entrants: Entrant[];
  legs: 1 | 2;
  stage: string; // a stage id or ROTATE
  seed: number | null; // fixture n plays with seed + n - 1
  cap: number;
  cadence: number;
  effort: Effort;
  mode: Mode;
  window: string;
  graphics: string;
  motionBlur?: string;
  film?: boolean;
  capture: boolean;
  record: boolean;
  reflexRate?: number;
  readThreshold?: number;
  gateThreshold?: number;
}

export type FixtureStatus = "pending" | "running" | "done" | "failed" | "skipped";

export interface Fixture {
  n: number;
  p1: number; // entrant index in corner 1
  p2: number;
  stage: string;
  seed: number | null;
  status: FixtureStatus;
  matchId: string | null;
  winner: "p1" | "p2" | null;
  wins: number[] | null;
  reason: string | null;
  usd: number[]; // per corner
  attempts: number; // a match that ends without a result is played once more
}

const MAX_ATTEMPTS = 2;

export interface Tournament {
  id: string;
  name: string;
  at: string;
  finishedAt: string | null;
  stopped: boolean;
  request: TournamentRequest;
  names: Record<string, string>; // fighter id -> display name
  fixtures: Fixture[];
}

export interface StandingRow {
  entrant: number;
  fighter: string;
  model: string;
  played: number;
  wins: number;
  losses: number;
  draws: number;
  points: number;
  roundsFor: number;
  roundsAgainst: number;
  usd: number;
}

/** The fixtures of a round robin: every pair i<j in order, then the return leg with corners swapped. */
export function schedule(request: TournamentRequest, stageIds: string[]): Fixture[] {
  const out: Fixture[] = [];
  const n = request.entrants.length;
  for (let leg = 0; leg < request.legs; leg++) {
    for (let i = 0; i < n; i++) {
      for (let j = i + 1; j < n; j++) {
        const k = out.length;
        const stage = request.stage === ROTATE ? stageIds[k % Math.max(1, stageIds.length)] ?? request.stage : request.stage;
        out.push({ n: k + 1, p1: leg === 0 ? i : j, p2: leg === 0 ? j : i, stage, seed: request.seed == null ? null : request.seed + k, status: "pending", matchId: null, winner: null, wins: null, reason: null, usd: [0, 0], attempts: 0 });
      }
    }
  }
  return out;
}

/** Points: a win 1, a draw ½. Ties break on round difference, rounds won, then cost (lower first). */
export function standings(t: Tournament): StandingRow[] {
  const rows: StandingRow[] = t.request.entrants.map((e, i) => ({ entrant: i, fighter: t.names[e.fighter] ?? e.fighter, model: e.spec, played: 0, wins: 0, losses: 0, draws: 0, points: 0, roundsFor: 0, roundsAgainst: 0, usd: 0 }));
  for (const f of t.fixtures) {
    if (f.status !== "done") continue;
    const a = rows[f.p1];
    const b = rows[f.p2];
    const [wa, wb] = f.wins ?? [0, 0];
    a.played++;
    b.played++;
    a.roundsFor += wa;
    a.roundsAgainst += wb;
    b.roundsFor += wb;
    b.roundsAgainst += wa;
    a.usd += f.usd[0] ?? 0;
    b.usd += f.usd[1] ?? 0;
    if (f.winner === "p1") (a.wins++, b.losses++, (a.points += 1));
    else if (f.winner === "p2") (b.wins++, a.losses++, (b.points += 1));
    else (a.draws++, b.draws++, (a.points += 0.5), (b.points += 0.5));
  }
  return rows
    .map((r) => ({ ...r, usd: Math.round(r.usd * 1000) / 1000 }))
    .sort((x, y) => y.points - x.points || y.roundsFor - y.roundsAgainst - (x.roundsFor - x.roundsAgainst) || y.roundsFor - x.roundsFor || x.usd - y.usd || x.entrant - y.entrant);
}

export function tournamentId(request: TournamentRequest, now = new Date()): string {
  const slug = request.name.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "").slice(0, 40) || "tournament";
  return `${now.toISOString().replace(/[:.]/g, "-").slice(0, 19)}-${slug}`;
}

/** What the tournament needs from the match runner (setup.ts's Runner; the tests use the same). */
export interface MatchRunner extends EventEmitter {
  readonly running: boolean;
  readonly logRoot: string;
  current: { id: string; dir: string; exit: number | null } | null;
  start(request: MatchRequest): { id: string };
  stop(): boolean;
}

export interface TournamentStatus {
  id: string;
  name: string;
  active: boolean;
  stopped: boolean;
  total: number;
  done: number;
  current: number | null; // fixture number now playing
}

export class TournamentRunner {
  current: Tournament | null = null;
  readonly runner: MatchRunner;
  readonly gapMs: number;

  constructor(runner: MatchRunner, gapMs = 2000) {
    this.runner = runner;
    this.gapMs = gapMs;
    runner.on("exit", (m: { id: string; dir: string; exit: number | null }) => this.onExit(m));
  }

  get dir(): string {
    return join(this.runner.logRoot, "tournaments");
  }

  get active(): boolean {
    return this.current !== null && this.current.finishedAt === null;
  }

  start(request: TournamentRequest, fighters: Fighter[], stageIds: string[]): Tournament {
    if (this.active) throw new Error("a tournament is already running");
    if (this.runner.running) throw new Error("a match is already running");
    const names: Record<string, string> = {};
    for (const f of fighters) names[f.id] = f.name;
    let id = tournamentId(request);
    for (let n = 2; existsSync(join(this.dir, `${id}.json`)); n++) id = `${tournamentId(request)}-${n}`;
    const t: Tournament = { id, name: request.name, at: new Date().toISOString(), finishedAt: null, stopped: false, request, names, fixtures: schedule(request, stageIds) };
    this.current = t;
    this.advance();
    return t;
  }

  /** Skips what has not been played and stops the match in progress; the tournament ends when it exits. */
  stop(): boolean {
    const t = this.current;
    if (!t || !this.active) return false;
    t.stopped = true;
    for (const f of t.fixtures) if (f.status === "pending") f.status = "skipped";
    if (t.fixtures.some((f) => f.status === "running") && this.runner.running) {
      this.runner.stop();
      this.save(t);
    } else this.finish(t);
    return true;
  }

  private advance(): void {
    const t = this.current;
    if (!t || t.finishedAt) return;
    if (this.runner.running) return; // the running match's exit brings us back here
    const f = t.fixtures.find((x) => x.status === "pending");
    if (!f) return this.finish(t);
    const r = t.request;
    const request: MatchRequest = { p1: r.entrants[f.p1], p2: r.entrants[f.p2], stage: f.stage, seed: f.seed, cap: r.cap, cadence: r.cadence, effort: r.effort, capture: r.capture, record: r.record, mode: r.mode, window: r.window, graphics: r.graphics, motionBlur: r.motionBlur, film: r.film, reflexRate: r.reflexRate, readThreshold: r.readThreshold, gateThreshold: r.gateThreshold };
    try {
      f.matchId = this.runner.start(request).id;
      f.status = "running";
      f.attempts++;
      this.save(t);
    } catch (e) {
      f.status = "failed";
      f.reason = e instanceof Error ? e.message : String(e);
      this.save(t);
      setTimeout(() => this.advance(), this.gapMs).unref();
    }
  }

  private onExit(m: { id: string; dir: string; exit: number | null }): void {
    const t = this.current;
    if (!t || t.finishedAt) return;
    const f = t.fixtures.find((x) => x.status === "running" && x.matchId === m.id);
    if (f) {
      let battle: any = null;
      try {
        battle = JSON.parse(readFileSync(join(m.dir, "battle.json"), "utf8"));
      } catch {}
      if (battle?.result) {
        f.status = "done";
        f.winner = battle.result.winner === "p1" || battle.result.winner === "p2" ? battle.result.winner : null;
        f.wins = Array.isArray(battle.result.wins) ? battle.result.wins.map(Number) : null;
        f.reason = battle.result.reason ?? null;
        // A corner's cost: its brain's and its reflexes' (docs/jev-plan.md).
        f.usd = [Number(battle.coaches?.p1?.usd ?? 0) + Number(battle.reflexes?.p1?.usd ?? 0), Number(battle.coaches?.p2?.usd ?? 0) + Number(battle.reflexes?.p2?.usd ?? 0)];
      } else if (t.stopped) {
        f.status = "failed";
        f.reason = "stopped";
      } else if (f.attempts < MAX_ATTEMPTS) {
        f.status = "pending"; // played again next
        f.reason = `played again: attempt ${f.attempts} exited (${m.exit ?? "?"}) without a result`;
      } else {
        f.status = "failed";
        f.reason = `adapter exited (${m.exit ?? "?"}) without a result, twice`;
      }
    }
    if (t.stopped || !t.fixtures.some((x) => x.status === "pending")) return this.finish(t);
    this.save(t);
    setTimeout(() => this.advance(), this.gapMs).unref();
  }

  private finish(t: Tournament): void {
    for (const f of t.fixtures) {
      if (f.status === "pending") f.status = "skipped";
      if (f.status === "running") (f.status = "failed"), (f.reason = "stopped");
    }
    t.finishedAt = new Date().toISOString();
    this.save(t);
  }

  private save(t: Tournament): void {
    mkdirSync(this.dir, { recursive: true });
    writeFileSync(join(this.dir, `${t.id}.json`), JSON.stringify(t, null, 2));
  }

  status(): TournamentStatus | null {
    const t = this.current;
    if (!t) return null;
    return { id: t.id, name: t.name, active: this.active, stopped: t.stopped, total: t.fixtures.length, done: t.fixtures.filter((f) => f.status !== "pending" && f.status !== "running").length, current: t.fixtures.find((f) => f.status === "running")?.n ?? null };
  }

  /** A saved tournament with its standings; the current one when no id is given. */
  get(id?: string | null): (Tournament & { standings: StandingRow[] }) | null {
    let t: Tournament | null = null;
    if (!id || (this.current && this.current.id === id)) t = this.current ?? (id ? null : this.list()[0] ?? null);
    else if (/^[\w-]+$/.test(id)) {
      try {
        t = JSON.parse(readFileSync(join(this.dir, `${id}.json`), "utf8"));
      } catch {}
    }
    return t ? { ...t, standings: standings(t) } : null;
  }

  /** Every saved tournament, newest first. */
  list(): Tournament[] {
    if (!existsSync(this.dir)) return [];
    const out: Tournament[] = [];
    for (const file of readdirSync(this.dir)) {
      if (!file.endsWith(".json")) continue;
      try {
        const t = JSON.parse(readFileSync(join(this.dir, file), "utf8"));
        if (t && Array.isArray(t.fixtures) && t.request) out.push(this.current && this.current.id === t.id ? this.current : t);
      } catch {}
    }
    return out.sort((a, b) => (a.at < b.at ? 1 : a.at > b.at ? -1 : 0));
  }
}
