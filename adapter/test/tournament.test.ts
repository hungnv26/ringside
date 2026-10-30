import assert from "node:assert/strict";
import { existsSync, mkdtempSync, readdirSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { REPO_ROOT } from "../src/models.ts";
import { createSetupServer, roster, Runner, stages, validateTournament } from "../src/setup.ts";
import { schedule, standings, TournamentRunner, tournamentId, type Tournament, type TournamentRequest } from "../src/tournament.ts";

const fighters = roster(REPO_ROOT);
const stageIds = stages(REPO_ROOT).map((s) => s.id);
const entrants = [
  { fighter: "jin", spec: "fake:coach" },
  { fighter: "kenji", spec: "anthropic:claude-haiku-5-5" },
  { fighter: "jin", spec: "openai:gpt-5.4-mini" },
];
const request = (over: Record<string, unknown> = {}) => validateTournament({ name: "Test cup", entrants, stage: "rotate", cap: 0.5, ...over }, fighters, stageIds);

test("validateTournament: entrants, legs, stage and a default name", () => {
  const r = request();
  assert.equal(r.entrants.length, 3);
  assert.equal(r.legs, 1);
  assert.equal(r.stage, "rotate");
  assert.equal(r.cap, 0.5);
  assert.equal(r.cadence, 2000);
  assert.equal(request({ name: "  " }).name, "3 entrants, round robin");
  assert.equal(request({ name: "", legs: "2" }).name, "3 entrants, home and away");
  assert.throws(() => request({ entrants: entrants.slice(0, 1) }), /2 to 8 entrants/);
  assert.throws(() => request({ entrants: [...entrants, entrants[0]] }), /listed twice/);
  assert.throws(() => request({ entrants: [entrants[0], { fighter: "ryu", spec: "fake:coach" }] }), /entrant 2: unknown fighter/);
  assert.throws(() => request({ legs: 3 }), /legs must be 1 or 2/);
  assert.throws(() => request({ stage: "moon" }), /unknown stage/);
  assert.throws(() => request({ cap: 99 }), /cap must be/);
});

test("schedule: every pair once, the return leg swaps corners, stages rotate, seeds count up", () => {
  const one = schedule(request({ seed: 100 }), ["ring", "dojo"]);
  assert.deepEqual(one.map((f) => [f.p1, f.p2]), [[0, 1], [0, 2], [1, 2]]);
  assert.deepEqual(one.map((f) => f.stage), ["ring", "dojo", "ring"]);
  assert.deepEqual(one.map((f) => f.seed), [100, 101, 102]);
  assert.ok(one.every((f) => f.status === "pending" && f.matchId === null));
  const two = schedule(request({ legs: 2, stage: "beach" }), stageIds);
  assert.equal(two.length, 6);
  assert.deepEqual(two.slice(3).map((f) => [f.p1, f.p2]), [[1, 0], [2, 0], [2, 1]]);
  assert.ok(two.every((f) => f.stage === "beach" && f.seed === null));
  assert.match(tournamentId(request(), new Date("2026-10-30T12:00:00Z")), /^2026-10-30T12-00-00-test-cup$/);
  assert.match(tournamentId(request({ name: "***" }), new Date("2026-10-30T12:00:00Z")), /-tournament$/);
});

test("standings: points, round difference and cost order the table", () => {
  const r = request({ legs: 2 });
  const t: Tournament = { id: "t", name: r.name, at: "2026-10-30T00:00:00Z", finishedAt: null, stopped: false, request: r, names: { jin: "Jin", kenji: "Kenji" }, fixtures: schedule(r, stageIds) };
  const done = (n: number, winner: "p1" | "p2" | null, wins: number[], usd: number[]) => Object.assign(t.fixtures[n - 1], { status: "done", winner, wins, usd, matchId: `m${n}` });
  done(1, "p1", [2, 0], [0, 0.01]); // 0 beats 1
  done(2, "p2", [1, 2], [0, 0.05]); // 2 beats 0
  done(3, null, [1, 1], [0.01, 0.05]); // 1 draws 2
  done(4, "p1", [2, 1], [0.01, 0]); // 1 beats 0
  t.fixtures[4].status = "failed";
  t.fixtures[5].status = "skipped";
  const rows = standings(t);
  assert.deepEqual(rows.map((x) => x.entrant), [2, 1, 0]);
  assert.deepEqual(rows.map((x) => x.points), [1.5, 1.5, 1]);
  assert.equal(rows[0].fighter, "Jin");
  assert.equal(rows[0].model, "openai:gpt-5.4-mini");
  assert.deepEqual([rows[0].roundsFor, rows[0].roundsAgainst, rows[0].played], [3, 2, 2]);
  assert.deepEqual([rows[1].wins, rows[1].losses, rows[1].draws], [1, 1, 1]);
  assert.equal(rows[0].usd, 0.1);
  assert.equal(rows[2].played, 3);
});

// A stub adapter: the corner whose fighter id sorts first wins 2-0; it writes battle.json and exits.
const STUB = [process.execPath, "-e", `
const fs = require("node:fs"); const a = process.argv; const dir = a[a.indexOf("--log") + 1];
const side = (k) => { const v = a[a.indexOf(k) + 1]; return { fighter: v.split("=")[0], model: v.split("=")[1] }; };
const p1 = side("--p1"), p2 = side("--p2");
if (p1.model.includes("crash")) process.exit(3);
const winner = p1.fighter <= p2.fighter ? "p1" : "p2";
fs.mkdirSync(dir, { recursive: true });
fs.writeFileSync(dir + "/battle.json", JSON.stringify({ at: new Date().toISOString(), stage: a[a.indexOf("--stage") + 1], seed: a.includes("--seed") ? Number(a[a.indexOf("--seed") + 1]) : null, sides: { p1, p2 }, result: { winner, wins: winner === "p1" ? [2, 0] : [0, 2], reason: "rounds" }, coaches: { p1: { turns: 1, usd: 0.01 }, p2: { turns: 1, usd: 0.02 } } }));
`, "--"];

const wait = async (until: () => boolean) => {
  for (let i = 0; i < 200 && !until(); i++) await new Promise((r) => setTimeout(r, 25));
};

test("TournamentRunner plays every fixture in turn, saves the file and keeps the standings", async () => {
  const root = mkdtempSync(join(tmpdir(), "ringside-cup-"));
  const runner = new Runner(STUB, root);
  const cup = new TournamentRunner(runner, 10);
  const r = validateTournament({ name: "Fast cup", entrants: [{ fighter: "kenji", spec: "fake:coach" }, { fighter: "jin", spec: "fake:a" }, { fighter: "mira", spec: "fake:b" }], stage: "ring", legs: 2, seed: 5 }, fighters, stageIds);
  const t = cup.start(r, fighters, stageIds);
  assert.equal(t.fixtures.length, 6);
  assert.ok(cup.active);
  assert.equal(cup.status()?.current, 1);
  assert.throws(() => cup.start(r, fighters, stageIds), /already running/);
  await wait(() => !cup.active);
  assert.ok(t.finishedAt, "finished");
  assert.deepEqual(t.fixtures.map((f) => f.status), Array(6).fill("done"));
  assert.deepEqual(t.fixtures.map((f) => f.seed), [5, 6, 7, 8, 9, 10]);
  assert.equal(readdirSync(root).filter((d) => d !== "tournaments").length, 6, "six match folders");
  // jin < kenji < mei, so jin wins every match, kenji beats mei twice
  const rows = standings(t);
  assert.deepEqual(rows.map((x) => [x.fighter, x.points]), [["Jin", 4], ["Kenji", 2], ["Mira", 0]]);
  assert.deepEqual(rows.map((x) => x.played), [4, 4, 4]);
  assert.equal(rows[0].usd, 0.06);
  const saved = JSON.parse(readFileSync(join(root, "tournaments", `${t.id}.json`), "utf8"));
  assert.equal(saved.fixtures[5].matchId, t.fixtures[5].matchId);
  assert.equal(cup.list()[0].id, t.id);
  assert.equal(cup.get()?.standings[0].fighter, "Jin");
  assert.equal(cup.get(t.id)?.id, t.id);
  assert.equal(cup.get("nope"), null);
  assert.equal(cup.status()?.done, 6);
  assert.equal(cup.stop(), false);
});

test("TournamentRunner: a crashed match is failed and the rest still play; stop skips what is left", async () => {
  const root = mkdtempSync(join(tmpdir(), "ringside-cup2-"));
  const runner = new Runner(STUB, root);
  const cup = new TournamentRunner(runner, 10);
  const r = validateTournament({ entrants: [{ fighter: "jin", spec: "fake:crash" }, { fighter: "kenji", spec: "fake:a" }, { fighter: "mira", spec: "fake:b" }], stage: "dojo" }, fighters, stageIds);
  const t = cup.start(r, fighters, stageIds);
  await wait(() => !cup.active);
  assert.deepEqual(t.fixtures.map((f) => f.status), ["failed", "failed", "done"]);
  assert.match(t.fixtures[0].reason ?? "", /exited \(3\) without a result, twice/);
  assert.deepEqual(t.fixtures.map((f) => f.attempts), [2, 2, 1], "a match without a result is played once more");
  assert.equal(standings(t)[0].fighter, "Kenji");

  // A slow stub: sleeps until killed, so stop() has a running match to end.
  const slow = new Runner([process.execPath, "-e", "setTimeout(() => {}, 60000)", "--"], root);
  const cup2 = new TournamentRunner(slow, 10);
  const t2 = cup2.start(validateTournament({ entrants: [{ fighter: "jin", spec: "fake:a" }, { fighter: "kenji", spec: "fake:b" }, { fighter: "mira", spec: "fake:c" }], stage: "dojo" }, fighters, stageIds), fighters, stageIds);
  await wait(() => slow.running);
  assert.equal(cup2.stop(), true);
  assert.ok(t2.stopped);
  await wait(() => !cup2.active);
  assert.deepEqual(t2.fixtures.map((f) => f.status), ["failed", "skipped", "skipped"]);
  assert.equal(t2.fixtures[0].reason, "stopped");
  assert.ok(existsSync(join(root, "tournaments", `${t2.id}.json`)));
  assert.equal(cup2.list().length, 2);
});

test("the API starts, reports, lists and stops tournaments, and refuses a match meanwhile", async () => {
  const root = mkdtempSync(join(tmpdir(), "ringside-cup-api-"));
  const runner = new Runner([process.execPath, "-e", "setTimeout(() => {}, 60000)", "--"], root);
  const cup = new TournamentRunner(runner, 10);
  const server = createSetupServer(runner, REPO_ROOT, (async () => { throw new Error("no network"); }) as unknown as typeof fetch, cup);
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", () => r()));
  const port = (server.address() as { port: number }).port;
  const call = async (path: string, body?: unknown) => {
    const res = await fetch(`http://127.0.0.1:${port}${path}`, body ? { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) } : undefined);
    return { status: res.status, body: await res.json() };
  };
  try {
    const bad = await call("/api/tournament", { entrants: [entrants[0]] });
    assert.equal(bad.status, 400);
    const ok = await call("/api/tournament", { name: "API cup", entrants, stage: "rotate" });
    assert.equal(ok.status, 200);
    assert.equal(ok.body.fixtures, 3);
    await wait(() => runner.running);
    const status = await call("/api/status");
    assert.equal(status.body.tournament.name, "API cup");
    assert.equal(status.body.tournament.current, 1);
    assert.ok(status.body.running);
    const refused = await call("/api/match", { p1: entrants[0], p2: entrants[1], stage: "ring" });
    assert.equal(refused.status, 400);
    assert.match(refused.body.error, /tournament is running/);
    const t = await call("/api/tournament");
    assert.equal(t.body.id, ok.body.id);
    assert.equal(t.body.standings.length, 3);
    assert.equal((await call("/api/tournament?id=nope")).status, 404);
    assert.deepEqual((await call("/api/tournament/stop", {})).body, { stopped: true });
    await wait(() => !cup.active);
    const list = await call("/api/tournaments");
    assert.equal(list.body.tournaments.length, 1);
    assert.equal(list.body.tournaments[0].stopped, true);
  } finally {
    server.close();
  }
});
