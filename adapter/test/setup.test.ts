import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { createSetupServer, elo, matchArgs, parseCharacter, results, roster, Runner, stages, summarize, validateMatch, type BattleSummary } from "../src/setup.ts";
import { REPO_ROOT } from "../src/models.ts";

const tres = `[gd_resource type="Resource" script_class="CharacterData" format=3]

[resource]
id = &"jin"
display_name = "Jin"
archetype = "Kicker"
select_order = 4
`;

test("parseCharacter reads id, name, archetype and order", () => {
  assert.deepEqual(parseCharacter(tres), { id: "jin", name: "Jin", archetype: "Kicker", order: 4 });
  assert.equal(parseCharacter("nothing here"), null);
});

test("roster and stages come from the game's files", () => {
  const r = roster(REPO_ROOT);
  assert.ok(r.length >= 7, `roster has ${r.length}`);
  assert.ok(r.some((f) => f.id === "jin" && f.name === "Jin"));
  assert.equal(r[0].order, Math.min(...r.map((f) => f.order)));
  const s = stages(REPO_ROOT);
  assert.ok(s.some((x) => x.id === "rooftop" && x.name === "Rooftop"));
  assert.ok(s.some((x) => x.id === "market" && x.name === "Night Market"));
});

const battle = (at: string, p1: string, p2: string, winner: string | null, usd1 = 0.01, usd2 = 0.02): BattleSummary => ({
  id: at, at, stage: "ring", seed: 1, sides: { p1: { fighter: "jin", model: p1 }, p2: { fighter: "kenji", model: p2 } }, winner, wins: winner === "p1" ? [2, 0] : winner === "p2" ? [0, 2] : [1, 1], reason: winner ? "rounds" : "draw", video: false, mode: "coach",
  coaches: { p1: { turns: 10, tokens: 100, usd: usd1, avgSeconds: 2, errors: 0 }, p2: { turns: 10, tokens: 100, usd: usd2, avgSeconds: 2, errors: 0 } },
});

test("elo: a win moves 16 points at equal rating, draws count half, sorted by rating", () => {
  const rows = elo([battle("2026-01-01T00:00:00Z", "a:x", "b:y", "p1"), battle("2026-01-02T00:00:00Z", "a:x", "b:y", null, 0.1, 0.2)]);
  assert.equal(rows[0].model, "a:x");
  assert.equal(rows[0].wins, 1);
  assert.equal(rows[0].draws, 1);
  assert.equal(rows[1].losses, 1);
  // first match: 1016 vs 984; the draw then pulls them back a little
  assert.ok(rows[0].rating > 1000 && rows[0].rating < 1016, String(rows[0].rating));
  assert.equal(rows[0].rating + rows[1].rating, 2000);
  assert.equal(rows[0].usd, 0.11);
});

test("elo processes battles in time order whatever the input order", () => {
  const a = [battle("2026-01-02T00:00:00Z", "a:x", "b:y", "p2"), battle("2026-01-01T00:00:00Z", "a:x", "b:y", "p1")];
  const b = [...a].reverse();
  assert.deepEqual(elo(a), elo(b));
});

test("results reads battle.json files newest first and skips folders without one", () => {
  const root = mkdtempSync(join(tmpdir(), "ringside-logs-"));
  for (const [id, at] of [["older", "2026-01-01T00:00:00Z"], ["newer", "2026-01-03T00:00:00Z"]]) {
    mkdirSync(join(root, id));
    writeFileSync(join(root, id, "battle.json"), JSON.stringify({ at, stage: "dojo", seed: 3, sides: { p1: { fighter: "jin", model: "fake:coach" }, p2: { fighter: "kenji", model: "fake:coach" } }, result: { winner: "p2", wins: [1, 2], reason: "rounds" }, coaches: { p1: { turns: 5, usd: 0 }, p2: { turns: 6, usd: 0 } } }));
  }
  mkdirSync(join(root, "unfinished"));
  const r = results(root);
  assert.deepEqual(r.map((b) => b.id), ["newer", "older"]);
  assert.equal(r[0].winner, "p2");
  assert.equal(r[0].coaches.p2.turns, 6);
  assert.equal(summarize({}, "x"), null);
});

const fighters = roster(REPO_ROOT);
const stageIds = stages(REPO_ROOT).map((s) => s.id);

test("validateMatch accepts a good request and fills defaults", () => {
  const m = validateMatch({ p1: { fighter: "jin", spec: "fake:coach" }, p2: { fighter: "kenji", spec: "anthropic:claude-haiku-5-5" }, stage: "beach", seed: "", cap: "0.5" }, fighters, stageIds);
  assert.equal(m.seed, null);
  assert.equal(m.cap, 0.5);
  assert.equal(m.cadence, 2000);
  assert.equal(m.effort, "low");
  const args = matchArgs(m, "/logs/x", "/logs/x/captures");
  assert.deepEqual(args.slice(0, 4), ["--p1", "jin=fake:coach", "--p2", "kenji=anthropic:claude-haiku-5-5"]);
  assert.ok(args.includes("--quit") && args.includes("--log") && !args.includes("--seed") && !args.includes("--capture"));
  const withSeed = matchArgs({ ...m, seed: 7, capture: true }, "/logs/x", "/logs/x/captures");
  assert.ok(withSeed.includes("--seed") && withSeed[withSeed.indexOf("--seed") + 1] === "7" && withSeed.includes("--capture"));
  const recorded = matchArgs({ ...m, record: true }, "/logs/x", "/logs/x/captures");
  assert.equal(recorded[recorded.indexOf("--record") + 1], "/logs/x/match.mp4");
});

test("validateMatch refuses bad fighters, specs, stages and numbers", () => {
  const good = { p1: { fighter: "jin", spec: "fake:coach" }, p2: { fighter: "kenji", spec: "fake:coach" }, stage: "ring" };
  assert.throws(() => validateMatch({ ...good, p1: { fighter: "ryu", spec: "fake:coach" } }, fighters, stageIds), /unknown fighter/);
  assert.throws(() => validateMatch({ ...good, p2: { fighter: "kenji", spec: "gpt-5" } }, fighters, stageIds), /provider:model/);
  assert.throws(() => validateMatch({ ...good, stage: "moon" }, fighters, stageIds), /unknown stage/);
  assert.throws(() => validateMatch({ ...good, cap: -1 }, fighters, stageIds), /cap must be/);
  assert.throws(() => validateMatch({ ...good, effort: "max" }, fighters, stageIds), /effort/);
});

// A stub adapter: writes live.json into the --log folder, prints a line, exits 0.
const STUB = [process.execPath, "-e", `
const fs = require("node:fs"); const i = process.argv.indexOf("--log"); const dir = process.argv[i + 1];
fs.mkdirSync(dir, { recursive: true });
fs.writeFileSync(dir + "/live.json", JSON.stringify({ phase: "over", hello: { p1: { id: "jin", name: "Jin" }, p2: { id: "kenji", name: "Kenji" }, stage: "Ring", rounds_to_win: 2 }, result: { winner: "p1", wins: [2, 0], reason: "rounds" }, coaches: {}, events: [] }));
fs.writeFileSync(dir + "/battle.json", JSON.stringify({ at: new Date().toISOString(), stage: "Ring", sides: { p1: { fighter: "jin", model: "fake:coach" }, p2: { fighter: "kenji", model: "fake:coach" } }, result: { winner: "p1", wins: [2, 0], reason: "rounds" }, coaches: { p1: { turns: 1, usd: 0 }, p2: { turns: 1, usd: 0 } } }));
console.log("stub ran " + process.argv.slice(1).join(" "));
`, "--"];

test("Runner starts one match at a time, keeps its console and reads live.json", async () => {
  const root = mkdtempSync(join(tmpdir(), "ringside-run-"));
  const runner = new Runner(STUB, root);
  const request = validateMatch({ p1: { fighter: "jin", spec: "fake:coach" }, p2: { fighter: "kenji", spec: "fake:coach" }, stage: "ring" }, fighters, stageIds);
  const { id } = runner.start(request);
  assert.match(id, /-jin-vs-kenji$/);
  assert.ok(runner.running);
  assert.throws(() => runner.start(request), /already running/);
  for (let i = 0; i < 100 && runner.running; i++) await new Promise((r) => setTimeout(r, 50));
  const s = runner.status() as any;
  assert.equal(s.running, false);
  assert.equal(s.match.exit, 0);
  assert.ok(s.console.some((l: string) => l.startsWith("stub ran") && l.includes("--p1 jin=fake:coach")));
  assert.equal(s.live.result.winner, "p1");
  assert.equal(results(root).length, 1);
  assert.equal(runner.stop(), false);
});

test("the API serves setup, results, logs and refuses bad requests", async () => {
  const root = mkdtempSync(join(tmpdir(), "ringside-api-"));
  const runner = new Runner(STUB, root);
  const server = createSetupServer(runner, REPO_ROOT, (async () => { throw new Error("no network in tests"); }) as unknown as typeof fetch);
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", () => r()));
  const port = (server.address() as { port: number }).port;
  const get = async (path: string, init?: RequestInit) => {
    const res = await fetch(`http://127.0.0.1:${port}${path}`, init);
    return { status: res.status, body: await res.json().catch(() => null), text: null as string | null };
  };
  try {
    const setup = await get("/api/setup");
    assert.equal(setup.status, 200);
    assert.ok(setup.body.roster.length >= 7 && setup.body.stages.length >= 8);
    assert.deepEqual(setup.body.providers, ["fake", "anthropic", "openai", "openrouter", "ollama"]);
    assert.ok("anthropic" in setup.body.keys);
    assert.deepEqual((await get("/api/models?provider=fake")).body, { models: ["coach"] });
    const bad = await get("/api/match", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ p1: { fighter: "x", spec: "fake:coach" } }) });
    assert.equal(bad.status, 400);
    assert.match(bad.body.error, /unknown fighter/);
    const ok = await get("/api/match", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ p1: { fighter: "jin", spec: "fake:coach" }, p2: { fighter: "kenji", spec: "fake:coach" }, stage: "ring" }) });
    assert.equal(ok.status, 200);
    for (let i = 0; i < 100 && runner.running; i++) await new Promise((r) => setTimeout(r, 50));
    const res = await get("/api/results");
    assert.equal(res.body.battles.length, 1);
    assert.equal(res.body.elo[0].model, "fake:coach");
    const log = await fetch(`http://127.0.0.1:${port}/api/log?id=${ok.body.id}&file=battle.json`);
    assert.equal(log.status, 200);
    assert.equal((await get(`/api/log?id=../etc&file=passwd`)).status, 400);
    assert.equal((await get(`/api/log?id=${ok.body.id}&file=p1.md`)).status, 404);
    const html = await fetch(`http://127.0.0.1:${port}/`);
    assert.match(await html.text(), /Ringside Setup/);
  } finally {
    server.close();
  }
});
