import assert from "node:assert/strict";
import { test } from "node:test";
import { mkdtempSync, readFileSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { BattleLog, battleId } from "../src/log.ts";
import { clientFor, gameClock, makeVideo, parseCli, reflexClientFor } from "../src/main.ts";
import { FakeJevClient, JevClient } from "../src/jev.ts";
import { FakeModelClient } from "../src/fake.ts";
import { ProviderClient } from "../src/models.ts";
import { hello } from "./helpers.ts";
import { spawnSync } from "node:child_process";

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
  assert.equal(a.window, "1080p");
  assert.equal(parseCli(["--window", "fullscreen"]).window, "fullscreen");
  assert.throws(() => parseCli(["--window", "4k"]), /--window must be/);
  assert.equal(a.graphics, "high");
  assert.equal(parseCli(["--graphics", "showcase"]).graphics, "showcase");
  assert.throws(() => parseCli(["--graphics", "ultra"]), /--graphics must be/);
  const d = parseCli([]);
  assert.deepEqual(d.sides, { p1: { fighter: "jin", spec: "fake:coach" }, p2: { fighter: "kenji", spec: "fake:coach" } });
  assert.throws(() => parseCli(["--p1", "jin"]), /fighter=provider:model/);
  assert.throws(() => parseCli(["--effort", "max"]), /effort/);
});

test("the CLI knows the reflexes: the +jev suffix, jev:jev alone, the rate and thresholds, a slower brain by default", () => {
  const a = parseCli(["--p1", "jin=anthropic:claude-opus-5-5+jev", "--p2", "kenji=jev:jev"]);
  assert.equal(a.sides.p1.spec, "anthropic:claude-opus-5-5+jev");
  assert.equal(a.sides.p2.spec, "jev:jev");
  assert.equal(a.cadence, 6000, "a brain with reflexes turns every 6 s unless told otherwise");
  assert.equal(a.reflexRate, 2, "two ticks a second by default");
  assert.equal(a.readThreshold, 0.6);
  assert.equal(a.gateThreshold, 0.7);
  assert.equal(parseCli(["--p1", "jin=fake:coach+jev", "--cadence", "3000"]).cadence, 3000);
  assert.equal(parseCli(["--p1", "jin=jev:fake"]).cadence, 2000, "reflexes alone: the cadence is nobody's");
  const b = parseCli(["--reflex-rate", "4", "--read-threshold", "0.75", "--gate-threshold", "0.5"]);
  assert.equal(b.reflexRate, 4);
  assert.equal(b.readThreshold, 0.75);
  assert.equal(b.gateThreshold, 0.5);
  assert.throws(() => parseCli(["--reflex-rate", "3"]), /--reflex-rate/);
  assert.throws(() => parseCli(["--read-threshold", "0.1"]), /--read-threshold/);
  assert.throws(() => parseCli(["--p1", "jin=fake:coach+turbo"]), /\+jev/);
});

test("reflexClientFor shares one Jev client and one fake", () => {
  const cache = new Map();
  const a = reflexClientFor("jev:fake", cache);
  const b = reflexClientFor("jev:jev", cache);
  const c = reflexClientFor("jev:typesafe-jev-1.13.0", cache);
  assert.ok(a instanceof FakeJevClient);
  assert.ok(b instanceof JevClient);
  assert.equal(b, c);
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

test("makeVideo keeps the sound Godot's movie writer puts inside the .avi", async (t) => {
  if (spawnSync("ffmpeg", ["-version"]).status !== 0) return t.skip("no ffmpeg");
  const dir = mkdtempSync(join(tmpdir(), "ringside-video-"));
  const avi = join(dir, "match.avi");
  const mp4 = join(dir, "match.mp4");
  // Like the movie writer: MJPEG video and 16-bit PCM audio in one AVI, no .wav beside it.
  const made = spawnSync("ffmpeg", ["-loglevel", "error", "-f", "lavfi", "-i", "color=c=gray:s=64x36:d=0.5:r=30", "-f", "lavfi", "-i", "sine=f=440:d=0.5", "-c:v", "mjpeg", "-c:a", "pcm_s16le", avi]);
  assert.equal(made.status, 0, String(made.stderr));
  await makeVideo(avi, mp4, () => {});
  const probe = spawnSync("ffprobe", ["-v", "error", "-show_entries", "stream=codec_type", "-of", "csv=p=0", mp4]);
  assert.deepEqual(String(probe.stdout).trim().split("\n").sort(), ["audio", "video"]);
  assert.equal(existsSync(avi), false);
});

test("the CLI takes motion blur and film-quality recording", () => {
  assert.equal(parseCli([]).motionBlur, "cinematic");
  assert.equal(parseCli([]).film, false);
  const a = parseCli(["--motion-blur", "subtle", "--film", "--record", "x.mp4"]);
  assert.equal(a.motionBlur, "subtle");
  assert.equal(a.film, true);
  assert.throws(() => parseCli(["--motion-blur", "max"]), /--motion-blur/);
});

test("gameClock waits game ticks, not wall time, and restarts on a new round", async () => {
  const link = { latest: { tick: 100 } as { tick: number } | null };
  const clock = gameClock(link, 2);
  let fired = 0;
  clock.setTimer(() => fired++, 1000); // 60 ticks
  await new Promise((r) => setTimeout(r, 20));
  assert.equal(fired, 0); // no game time has passed
  link.latest = { tick: 130 };
  await new Promise((r) => setTimeout(r, 20));
  assert.equal(fired, 0);
  link.latest = { tick: 5 }; // a new round: the count restarts from here
  await new Promise((r) => setTimeout(r, 20));
  link.latest = { tick: 64 };
  await new Promise((r) => setTimeout(r, 20));
  assert.equal(fired, 0);
  link.latest = { tick: 65 };
  await new Promise((r) => setTimeout(r, 20));
  assert.equal(fired, 1);
  const h = clock.setTimer(() => fired++, 10);
  clock.clearTimer(h);
  link.latest = { tick: 500 };
  await new Promise((r) => setTimeout(r, 20));
  assert.equal(fired, 1);
});

test("makeVideo blends a film-quality movie: 240 rendered frames a second into 60", async (t) => {
  if (spawnSync("ffmpeg", ["-version"]).status !== 0) return t.skip("no ffmpeg");
  const dir = mkdtempSync(join(tmpdir(), "ringside-film-"));
  const movie = join(dir, "match.avi");
  const mp4 = join(dir, "match.mp4");
  // One second at 240 fps: the blend keeps one frame in four.
  const made = spawnSync("ffmpeg", ["-loglevel", "error", "-f", "lavfi", "-i", "testsrc=s=64x36:d=1:r=240", "-f", "lavfi", "-i", "sine=f=440:d=1", "-c:v", "mjpeg", "-c:a", "pcm_s16le", movie]);
  assert.equal(made.status, 0, String(made.stderr));
  await makeVideo(movie, mp4, () => {}, true);
  const probe = spawnSync("ffprobe", ["-v", "error", "-count_frames", "-select_streams", "v", "-show_entries", "stream=r_frame_rate,nb_read_frames", "-of", "csv=p=0", mp4]);
  const [rate, frames] = String(probe.stdout).trim().split(",");
  assert.equal(rate, "60/1");
  assert.ok(Math.abs(Number(frames) - 60) <= 1, `frames ${frames}`);
});
