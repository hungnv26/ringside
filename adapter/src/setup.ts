// The setup page's server (docs/ringside-plan.md phase 2): http://127.0.0.1:8798 serves
// setup/index.html and a small JSON API. It reads the roster and stages from the game's files,
// reports which provider keys are saved and lists each provider's models, starts one match at a
// time by spawning the adapter (src/main.ts, which launches the game), relays its live.json and
// console, and keeps results and an Elo table from battle-logs/*/battle.json. Local only.
import { spawn, type ChildProcess } from "node:child_process";
import { EventEmitter } from "node:events";
import { createReadStream, existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { basename, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { keyStatus, listModels, modelPrices, PROVIDERS, REPO_ROOT, saveKey, splitSpec, type Effort } from "./models.ts";
import { MAX_ENTRANTS, ROTATE, TournamentRunner, type Entrant, type TournamentRequest } from "./tournament.ts";
import type { Mode } from "./types.ts";

export const DEFAULT_PORT = 8798;
const HERE = dirname(fileURLToPath(import.meta.url));
const PAGE = join(HERE, "..", "setup", "index.html");
export const LOG_ROOT = join(REPO_ROOT, "battle-logs");
const STAGE_NAMES: Record<string, string> = { ring: "Boxing Ring", dojo: "Dojo", rooftop: "Rooftop", temple: "Temple", beach: "Beach", market: "Night Market", train: "Express", courtyard: "Kowloon Courtyard" };
const EFFORTS: Effort[] = ["low", "medium", "high"];
const WINDOWS = ["720p", "900p", "1080p", "1440p", "fullscreen"];
const ELO_K = 32;
const ELO_START = 1000;

export interface Fighter {
  id: string;
  name: string;
  archetype: string;
  order: number;
}

// ---- the game's data ----

/** id, display name and archetype from a character .tres (the fields are plain lines). */
export function parseCharacter(text: string): Fighter | null {
  const field = (name: string) => text.match(new RegExp(`^${name} = &?"([^"]*)"`, "m"))?.[1] ?? "";
  const id = field("id");
  if (!id) return null;
  return { id, name: field("display_name") || id, archetype: field("archetype"), order: Number(text.match(/^select_order = (\d+)/m)?.[1] ?? 99) };
}

export function roster(root = REPO_ROOT): Fighter[] {
  const dir = join(root, "data", "characters");
  if (!existsSync(dir)) return [];
  return readdirSync(dir)
    .filter((f) => f.endsWith(".tres"))
    .map((f) => parseCharacter(readFileSync(join(dir, f), "utf8")))
    .filter((c): c is Fighter => c !== null)
    .sort((a, b) => a.order - b.order || a.name.localeCompare(b.name));
}

export function stages(root = REPO_ROOT): { id: string; name: string }[] {
  const dir = join(root, "scenes", "stages");
  if (!existsSync(dir)) return [];
  return readdirSync(dir)
    .filter((f) => f.endsWith(".tscn"))
    .map((f) => basename(f, ".tscn"))
    .sort()
    .map((id) => ({ id, name: STAGE_NAMES[id] ?? id }));
}

// ---- results and Elo ----

export interface BattleSummary {
  id: string;
  at: string;
  stage: string;
  seed: number | null;
  sides: Record<string, { fighter: string; model: string }>;
  mode: string;
  winner: string | null;
  wins: number[] | null;
  reason: string | null;
  coaches: Record<string, { turns: number; tokens: number; usd: number; avgSeconds: number | null; errors: number }>;
  video: boolean;
}

export function summarize(battle: any, id: string): BattleSummary | null {
  if (!battle || typeof battle !== "object" || !battle.sides) return null;
  const coaches: BattleSummary["coaches"] = {};
  for (const [side, c] of Object.entries((battle.coaches ?? {}) as Record<string, any>)) coaches[side] = { turns: Number(c.turns ?? 0), tokens: Number(c.tokens ?? 0), usd: Number(c.usd ?? 0), avgSeconds: c.avgSeconds ?? null, errors: Number(c.errors ?? 0) };
  return { id, at: String(battle.at ?? ""), stage: String(battle.stage ?? ""), seed: battle.seed ?? null, sides: battle.sides, mode: String(battle.settings?.mode ?? "coach"), winner: battle.result?.winner ?? null, wins: battle.result?.wins ?? null, reason: battle.result?.reason ?? null, coaches, video: false };
}

/** Every finished battle under battle-logs, newest first. */
export function results(root = LOG_ROOT): BattleSummary[] {
  if (!existsSync(root)) return [];
  const out: BattleSummary[] = [];
  for (const id of readdirSync(root)) {
    const file = join(root, id, "battle.json");
    if (!existsSync(file)) continue;
    try {
      const s = summarize(JSON.parse(readFileSync(file, "utf8")), id);
      if (s) out.push({ ...s, video: existsSync(join(root, id, "match.mp4")) });
    } catch {}
  }
  return out.sort((a, b) => (a.at < b.at ? 1 : a.at > b.at ? -1 : 0));
}

export interface EloRow {
  model: string;
  rating: number;
  matches: number;
  wins: number;
  losses: number;
  draws: number;
  usd: number;
}

/** Elo per model (not per fighter), K=32 from 1000, battles in time order; draws count half. */
export function elo(battles: BattleSummary[]): EloRow[] {
  const table = new Map<string, EloRow>();
  const row = (model: string) => {
    let r = table.get(model);
    if (!r) table.set(model, (r = { model, rating: ELO_START, matches: 0, wins: 0, losses: 0, draws: 0, usd: 0 }));
    return r;
  };
  for (const b of [...battles].sort((x, y) => (x.at < y.at ? -1 : x.at > y.at ? 1 : 0))) {
    const a = row(b.sides.p1?.model ?? "?");
    const c = row(b.sides.p2?.model ?? "?");
    const sa = b.winner === "p1" ? 1 : b.winner === "p2" ? 0 : 0.5;
    const ea = 1 / (1 + 10 ** ((c.rating - a.rating) / 400));
    const ra = a.rating + ELO_K * (sa - ea);
    const rc = c.rating + ELO_K * (1 - sa - (1 - ea));
    a.rating = ra;
    c.rating = rc;
    for (const [r, s] of [[a, sa], [c, 1 - sa]] as [EloRow, number][]) {
      r.matches++;
      if (s === 1) r.wins++;
      else if (s === 0) r.losses++;
      else r.draws++;
    }
    a.usd += b.coaches.p1?.usd ?? 0;
    c.usd += b.coaches.p2?.usd ?? 0;
  }
  return [...table.values()].sort((x, y) => y.rating - x.rating).map((r) => ({ ...r, rating: Math.round(r.rating), usd: Math.round(r.usd * 1000) / 1000 }));
}

// ---- the running match ----

export interface MatchRequest {
  p1: { fighter: string; spec: string };
  p2: { fighter: string; spec: string };
  stage: string;
  seed?: number | null;
  cap?: number;
  cadence?: number;
  effort?: Effort;
  capture?: boolean;
  record?: boolean;
  mode?: Mode;
  window?: string;
}

/** One corner of a request: a known fighter and a provider:model spec. */
function validateEntrant(raw: any, name: string, fighters: Fighter[]): Entrant {
  const s = raw ?? {};
  const fighter = String(s.fighter ?? "");
  const spec = String(s.spec ?? "").trim();
  if (!fighters.some((f) => f.id === fighter)) throw new Error(`${name}: unknown fighter "${fighter}"`);
  const { provider, model } = splitSpec(spec);
  if (!(PROVIDERS.includes(provider) || provider === "fake") || !model || /\s/.test(spec)) throw new Error(`${name}: the model must be provider:model (anthropic, openai, openrouter, ollama or fake)`);
  return { fighter, spec };
}

/** The settings every match shares: budget, pace, effort, mode, recording. */
function validateSettings(raw: any) {
  const num = (key: string, fallback: number, min: number, max: number) => {
    if (raw?.[key] === undefined || raw[key] === null || raw[key] === "") return fallback;
    const v = Number(raw[key]);
    if (!Number.isFinite(v) || v < min || v > max) throw new Error(`${key} must be a number between ${min} and ${max}`);
    return v;
  };
  const effort = String(raw?.effort ?? "low") as Effort;
  if (!EFFORTS.includes(effort)) throw new Error("effort must be low, medium or high");
  const mode = String(raw?.mode ?? "coach") as Mode;
  if (!["coach", "script"].includes(mode)) throw new Error("mode must be coach or script");
  const window = String(raw?.window ?? "1080p");
  if (!WINDOWS.includes(window)) throw new Error(`window must be one of ${WINDOWS.join(", ")}`);
  const seed = raw?.seed === undefined || raw?.seed === null || raw?.seed === "" ? null : Math.floor(num("seed", 0, 0, 2 ** 31 - 1));
  return { seed, cap: num("cap", 1, 0, 50), cadence: Math.floor(num("cadence", 2000, 500, 30000)), effort, capture: !!raw?.capture, record: !!raw?.record, mode, window };
}

export function validateMatch(raw: any, fighters: Fighter[], stageIds: string[]): MatchRequest {
  const p1 = validateEntrant(raw?.p1, "p1", fighters);
  const p2 = validateEntrant(raw?.p2, "p2", fighters);
  const stage = String(raw?.stage ?? "");
  if (!stageIds.includes(stage)) throw new Error(`unknown stage "${stage}"`);
  return { p1, p2, stage, ...validateSettings(raw) };
}

/** A tournament: 2 to 8 distinct entrants, one or two legs, a stage or "rotate", the match settings. */
export function validateTournament(raw: any, fighters: Fighter[], stageIds: string[]): TournamentRequest {
  const list = Array.isArray(raw?.entrants) ? raw.entrants : [];
  if (list.length < 2 || list.length > MAX_ENTRANTS) throw new Error(`a tournament needs 2 to ${MAX_ENTRANTS} entrants`);
  const entrants = list.map((e: unknown, i: number) => validateEntrant(e, `entrant ${i + 1}`, fighters));
  const seen = new Set<string>();
  for (const e of entrants) {
    const key = `${e.fighter}=${e.spec}`;
    if (seen.has(key)) throw new Error(`entrant ${key} is listed twice`);
    seen.add(key);
  }
  const legs = Number(raw?.legs ?? 1);
  if (legs !== 1 && legs !== 2) throw new Error("legs must be 1 or 2");
  const stage = String(raw?.stage ?? ROTATE);
  if (stage !== ROTATE && !stageIds.includes(stage)) throw new Error(`unknown stage "${stage}"`);
  const name = String(raw?.name ?? "").trim().slice(0, 60) || `${entrants.length} entrants, ${legs === 2 ? "home and away" : "round robin"}`;
  return { name, entrants, legs, stage, ...validateSettings(raw) };
}

export function matchArgs(m: MatchRequest, logDir: string, captureDir: string): string[] {
  const args = ["--p1", `${m.p1.fighter}=${m.p1.spec}`, "--p2", `${m.p2.fighter}=${m.p2.spec}`, "--stage", m.stage, "--cap", String(m.cap ?? 1), "--cadence", String(m.cadence ?? 2000), "--effort", m.effort ?? "low", "--log", logDir, "--quit"];
  if (m.seed != null) args.push("--seed", String(m.seed));
  if (m.capture) args.push("--capture", captureDir);
  if (m.record) args.push("--record", join(logDir, "match.mp4"));
  if (m.mode && m.mode !== "coach") args.push("--mode", m.mode);
  if (m.window) args.push("--window", m.window);
  return args;
}

export function matchId(m: MatchRequest, now = new Date()): string {
  return `${now.toISOString().replace(/[:.]/g, "-").slice(0, 19)}-${m.p1.fighter}-vs-${m.p2.fighter}`;
}

/** Runs one match at a time; emits "exit" with the match record when the adapter exits. */
export class Runner extends EventEmitter<{ exit: [{ id: string; dir: string; exit: number | null }] }> {
  child: ChildProcess | null = null;
  current: { id: string; dir: string; request: MatchRequest; startedAt: string; exit: number | null; console: string[] } | null = null;
  readonly command: string[]; // how the adapter is run (tests swap in a stub)
  readonly logRoot: string;

  constructor(command = [process.execPath, join(HERE, "main.ts")], logRoot = LOG_ROOT) {
    super();
    this.command = command;
    this.logRoot = logRoot;
  }

  get running(): boolean {
    return this.child !== null && this.child.exitCode === null && this.current?.exit == null;
  }

  start(request: MatchRequest): { id: string } {
    if (this.running) throw new Error("a match is already running");
    const id = matchId(request);
    const dir = join(this.logRoot, id);
    const args = matchArgs(request, dir, join(dir, "captures"));
    const [cmd, ...pre] = this.command;
    const child = spawn(cmd, [...pre, ...args], { cwd: dirname(HERE), stdio: ["ignore", "pipe", "pipe"], env: process.env });
    const current = { id, dir, request, startedAt: new Date().toISOString(), exit: null as number | null, console: [] as string[] };
    const take = (data: Buffer) => {
      for (const line of String(data).split("\n")) {
        if (!line.trim() || /material|shader/i.test(line)) continue;
        current.console.push(line.slice(0, 400));
        if (current.console.length > 300) current.console.shift();
      }
    };
    child.stdout?.on("data", take);
    child.stderr?.on("data", take);
    const ended = (code: number) => {
      if (current.exit !== null) return;
      current.exit = code;
      this.emit("exit", current);
    };
    child.on("error", (e) => {
      current.console.push(`could not start the adapter: ${e.message}`);
      ended(1);
    });
    child.on("exit", (code) => ended(code ?? 1));
    this.child = child;
    this.current = current;
    return { id };
  }

  stop(): boolean {
    if (!this.running || !this.child) return false;
    this.child.kill("SIGINT"); // the adapter ends the game and exits
    const child = this.child;
    setTimeout(() => {
      if (child.exitCode === null) child.kill("SIGKILL");
    }, 8000).unref();
    return true;
  }

  status(): Record<string, unknown> {
    const c = this.current;
    let live: unknown = null;
    if (c) {
      try {
        live = JSON.parse(readFileSync(join(c.dir, "live.json"), "utf8"));
      } catch {}
    }
    return { running: this.running, match: c ? { id: c.id, startedAt: c.startedAt, request: c.request, exit: c.exit } : null, live, console: c ? c.console.slice(-60) : [] };
  }
}

// ---- HTTP ----

/** A file with HTTP range support (video seeking). */
function sendFile(req: IncomingMessage, res: ServerResponse, path: string, type: string): void {
  const size = statSync(path).size;
  const range = /^bytes=(\d*)-(\d*)$/.exec(req.headers.range ?? "");
  if (range) {
    const start = range[1] ? Number(range[1]) : 0;
    const end = range[2] ? Math.min(Number(range[2]), size - 1) : size - 1;
    if (start > end || start >= size) {
      res.writeHead(416, { "content-range": `bytes */${size}` });
      res.end();
      return;
    }
    res.writeHead(206, { "content-type": type, "content-range": `bytes ${start}-${end}/${size}`, "content-length": end - start + 1, "accept-ranges": "bytes" });
    createReadStream(path, { start, end }).pipe(res);
    return;
  }
  res.writeHead(200, { "content-type": type, "content-length": size, "accept-ranges": "bytes" });
  createReadStream(path).pipe(res);
}

const json = (res: ServerResponse, status: number, body: unknown) => {
  res.writeHead(status, { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" });
  res.end(JSON.stringify(body));
};
const body = async (req: IncomingMessage): Promise<any> => {
  let raw = "";
  for await (const chunk of req) {
    raw += chunk;
    if (raw.length > 100_000) throw new Error("request too large");
  }
  return raw ? JSON.parse(raw) : {};
};

export function createSetupServer(runner = new Runner(), root = REPO_ROOT, fetchFn: typeof fetch = fetch, tournaments = new TournamentRunner(runner)) {
  const models = new Map<string, { at: number; ids: string[] }>(); // per provider, 15 min
  return createServer(async (req, res) => {
    const url = new URL(req.url ?? "/", "http://127.0.0.1");
    try {
      if (url.pathname === "/" || url.pathname === "/index.html") {
        res.writeHead(200, { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" });
        return res.end(readFileSync(PAGE));
      }
      if (url.pathname === "/api/setup") {
        const prices = modelPrices();
        return json(res, 200, {
          roster: roster(root),
          stages: stages(root),
          providers: ["fake", ...PROVIDERS],
          keys: keyStatus(),
          priced: Object.keys(prices),
          efforts: EFFORTS,
          windows: WINDOWS,
          modes: [
            { id: "coach", name: "Coach", blurb: "the model adjusts its fighter's plan every couple of seconds" },
            { id: "script", name: "Self-coding", blurb: "the model writes rules before the match and rewrites them after every round; no calls during a round" },
          ],
          defaults: { p1: { fighter: "jin", spec: "anthropic:claude-haiku-5-5" }, p2: { fighter: "kenji", spec: "openai:gpt-5.4-mini" }, stage: "rooftop", cap: 1, cadence: 2000, effort: "low", window: "1080p" },
          tournament: { maxEntrants: MAX_ENTRANTS, rotate: ROTATE },
          running: runner.running,
        });
      }
      if (url.pathname === "/api/tournament" && req.method === "POST") {
        const request = validateTournament(await body(req), roster(root), stages(root).map((s) => s.id));
        const t = tournaments.start(request, roster(root), stages(root).map((s) => s.id));
        return json(res, 200, { id: t.id, fixtures: t.fixtures.length });
      }
      if (url.pathname === "/api/tournament/stop" && req.method === "POST") return json(res, 200, { stopped: tournaments.stop() });
      if (url.pathname === "/api/tournament") {
        const t = tournaments.get(url.searchParams.get("id"));
        return t ? json(res, 200, t) : json(res, 404, { error: "no such tournament" });
      }
      if (url.pathname === "/api/tournaments") {
        return json(res, 200, { tournaments: tournaments.list().map((t) => ({ id: t.id, name: t.name, at: t.at, finishedAt: t.finishedAt, stopped: t.stopped, entrants: t.request.entrants.length, total: t.fixtures.length, done: t.fixtures.filter((f) => f.status === "done").length })) });
      }
      if (url.pathname === "/api/models") {
        const provider = url.searchParams.get("provider") ?? "";
        if (provider === "fake") return json(res, 200, { models: ["coach"] });
        const cached = models.get(provider);
        if (cached && Date.now() - cached.at < 15 * 60_000 && !url.searchParams.has("refresh")) return json(res, 200, { models: cached.ids, cached: true });
        const ids = await listModels(provider, fetchFn);
        models.set(provider, { at: Date.now(), ids });
        return json(res, 200, { models: ids });
      }
      if (url.pathname === "/api/key" && req.method === "POST") {
        const b = await body(req);
        const file = saveKey(String(b.provider ?? ""), String(b.key ?? ""));
        models.delete(String(b.provider));
        return json(res, 200, { ok: true, file, keys: keyStatus() });
      }
      if (url.pathname === "/api/match" && req.method === "POST") {
        const request = validateMatch(await body(req), roster(root), stages(root).map((s) => s.id));
        if (tournaments.active) throw new Error("a tournament is running; stop it first");
        return json(res, 200, runner.start(request));
      }
      if (url.pathname === "/api/stop" && req.method === "POST") return json(res, 200, { stopped: runner.stop() });
      if (url.pathname === "/api/status") return json(res, 200, { ...runner.status(), tournament: tournaments.status() });
      if (url.pathname === "/api/results") {
        const all = results(runner.logRoot);
        return json(res, 200, { battles: all.slice(0, 100), elo: elo(all) });
      }
      if (url.pathname === "/api/log") {
        const id = url.searchParams.get("id") ?? "";
        const file = url.searchParams.get("file") ?? "";
        if (!/^[\w-]+$/.test(id) || !/^(p1|p2)\.(md|jsonl)$|^battle\.json$|^live\.json$/.test(file)) return json(res, 400, { error: "bad log path" });
        const path = join(runner.logRoot, id, file);
        if (!existsSync(path)) return json(res, 404, { error: "no such log" });
        res.writeHead(200, { "content-type": file.endsWith(".json") ? "application/json; charset=utf-8" : "text/plain; charset=utf-8", "content-length": statSync(path).size });
        return res.end(readFileSync(path));
      }
      if (url.pathname.startsWith("/api/capture/")) {
        const [id, name] = url.pathname.slice("/api/capture/".length).split("/");
        if (!/^[\w-]+$/.test(id ?? "") || !/^ringside_\d+\.png$/.test(name ?? "")) return json(res, 400, { error: "bad capture path" });
        const path = join(runner.logRoot, id, "captures", name);
        if (!existsSync(path)) return json(res, 404, { error: "no such capture" });
        res.writeHead(200, { "content-type": "image/png" });
        return res.end(readFileSync(path));
      }
      if (url.pathname.startsWith("/api/video/")) {
        const id = url.pathname.slice("/api/video/".length).replace(/\.mp4$/, "");
        if (!/^[\w-]+$/.test(id)) return json(res, 400, { error: "bad video path" });
        const path = join(runner.logRoot, id, "match.mp4");
        if (!existsSync(path)) return json(res, 404, { error: "no video" });
        return sendFile(req, res, path, "video/mp4");
      }
      if (url.pathname === "/api/captures") {
        const id = url.searchParams.get("id") ?? "";
        const dir = join(runner.logRoot, id, "captures");
        if (!/^[\w-]+$/.test(id) || !existsSync(dir)) return json(res, 200, { captures: [] });
        return json(res, 200, { captures: readdirSync(dir).filter((f) => /^ringside_\d+\.png$/.test(f)).sort() });
      }
      json(res, 404, { error: "not found" });
    } catch (e) {
      json(res, 400, { error: e instanceof Error ? e.message : String(e) });
    }
  });
}

if (process.argv[1] && import.meta.url === new URL(`file://${process.argv[1]}`).href) {
  const i = process.argv.indexOf("--port");
  const port = i > 0 && process.argv[i + 1] ? Number(process.argv[i + 1]) : Number(process.env.PORT) || DEFAULT_PORT;
  const server = createSetupServer();
  server.listen(port, "127.0.0.1", () => console.log(`Ringside setup: http://127.0.0.1:${port}`));
}
