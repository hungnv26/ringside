import assert from "node:assert/strict";
import { test } from "node:test";
import { mkdtempSync, readFileSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { BattleLog, battleId } from "../src/log.ts";
import { clientFor, parseCli } from "../src/main.ts";
import { FakeModelClient } from "../src/fake.ts";
import { ProviderClient } from "../src/models.ts";
import { hello } from "./helpers.ts";

test("the CLI parses sides, stage and numbers, with fake defaults", () => {
  const a = parseCli(["--p1", "jin=anthropic:claude-haiku-5-5", "--p2=kenji=fake:coach", "--stage", "dojo", "--seed", "42", "--cap", "0.5", "--no-launch", "--quit"]);
  assert.deepEqual(a.sides, { p1: { fighter: "jin", spec: "anthropic:claude-haiku-5-5" }, p2: { fighter: "kenji", spec: "fake:coach" } });
  assert.equal(a.stage, "dojo");
  assert.equal(a.seed, 42);
  assert.equal(a.cap, 0.5);
  assert.equal(a.cadence, 2000);
  assert.equal(a.effort, "low");
  assert.equal(a.port, 8797);
  assert.equal(a.launch, false);
  assert.equal(a.quit, true);
  const d = parseCli([]);
  assert.deepEqual(d.sides, { p1: { fighter: "jin", spec: "fake:coach" }, p2: { fighter: "kenji", spec: "fake:coach" } });
  assert.throws(() => parseCli(["--p1", "jin"]), /fighter=provider:model/);
  assert.throws(() => parseCli(["--effort", "max"]), /effort/);
});

test("clientFor shares one provider client and one fake", () => {
  const cache = new Map();
  const a = clientFor("fake:coach", "low", cache);
  const b = clientFor("anthropic:claude-haiku-5-5", "low", cache);
  const c = clientFor("openai:gpt-5.4-mini", "low", cache);
  assert.ok(a instanceof FakeModelClient);
  assert.ok(b instanceof ProviderClient);
  assert.equal(b, c);
});

test("battle logs are written per side and for the battle", () => {
  const root = mkdtempSync(join(tmpdir(), "ringside-log-"));
  const id = battleId(hello, new Date("2026-10-30T01:02:03.456Z"));
  assert.equal(id, "2026-10-30T01-02-03-jin-vs-kenji");
  const log = new BattleLog(id, root);
  log.system("p1", "fake:coach", "SYSTEM");
  log.system("p1", "fake:coach", "again"); // once only
  log.turn("p1", { turn: 1, at: "t", reason: "round_start", seconds: 0.5, tokens: 100, usd: 0.001, prompt: "P", reply: { content: null, tool_calls: [{ name: "say", arguments: '{"text":"hi"}' }] }, results: ["say applied"] });
  log.battle({ id, result: { winner: "p1" } });
  const md = readFileSync(join(root, id, "p1.md"), "utf8");
  assert.match(md, /^# p1 · fake:coach\n\n## System prompt\n\nSYSTEM/);
  assert.doesNotMatch(md, /again/);
  assert.match(md, /## Turn 1 · t · round_start · 0\.5 s · 100 tokens · \$0\.0010/);
  assert.match(md, /- `say` \{"text":"hi"\}/);
  const lines = readFileSync(join(root, id, "p1.jsonl"), "utf8").trim().split("\n");
  assert.equal(lines.length, 1);
  assert.equal(JSON.parse(lines[0]).turn, 1);
  assert.ok(existsSync(join(root, id, "battle.json")));
  assert.equal(JSON.parse(readFileSync(join(root, id, "battle.json"), "utf8")).result.winner, "p1");
});
