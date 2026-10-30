// Ringside adapter: starts the game link, launches the game in coach mode, and runs one Coach per
// side until the match ends. See adapter/README.md for the flags.
//   node src/main.ts --p1 jin=anthropic:claude-haiku-5-5 --p2 kenji=fake:coach --stage rooftop
import { spawn, type ChildProcess } from "node:child_process";
import { existsSync, unlinkSync } from "node:fs";
import { basename } from "node:path";
import { Coach } from "./coach.ts";
import { FakeModelClient } from "./fake.ts";
import { Link } from "./link.ts";
import { BattleLog, battleId } from "./log.ts";
import type { Mode } from "./types.ts";
import { ProviderClient, REPO_ROOT, splitSpec, type Effort } from "./models.ts";
import { SIDES, type Hello, type ModelClient, type Side } from "./types.ts";

interface Args {
  sides: Record<Side, { fighter: string; spec: string }>;
  stage: string;
  seed: number;
  cap: number;
  cadence: number;
  effort: Effort;
  port: number;
  launch: boolean;
  godot: string;
  quit: boolean;
  capture: string;
  log: string;
  record: string;
  mode: Mode;
  beatTicks: number;
}

export function parseCli(argv: string[]): Args {
  const get = (name: string, fallback?: string): string | undefined => {
    const i = argv.indexOf(`--${name}`);
    if (i >= 0 && i + 1 < argv.length) return argv[i + 1];
    const eq = argv.find((a) => a.startsWith(`--${name}=`));
    return eq ? eq.slice(name.length + 3) : fallback;
  };
  const side = (name: Side, fighter: string): { fighter: string; spec: string } => {
    const v = get(name, `${fighter}=fake:coach`)!;
    const i = v.indexOf("=");
    if (i < 0) throw new Error(`--${name} must be fighter=provider:model, got "${v}"`);
    return { fighter: v.slice(0, i), spec: v.slice(i + 1) };
  };
  const effort = get("effort", "low") as Effort;
  const mode = get("mode", "coach") as Mode;
  if (!["coach", "script", "beat"].includes(mode)) throw new Error("--mode must be coach, script or beat");
  const beatTicks = Math.min(600, Math.max(15, Number(get("beat-ticks", "60")) || 60));
  if (!["low", "medium", "high"].includes(effort)) throw new Error(`--effort must be low, medium or high`);
  return {
    sides: { p1: side("p1", "jin"), p2: side("p2", "kenji") },
    stage: get("stage", "rooftop")!,
    seed: Number(get("seed", String(Math.floor(Math.random() * 1e9)))),
    cap: Number(get("cap", "1")),
    cadence: Number(get("cadence", "2000")),
    effort,
    port: Number(get("port", "8797")),
    launch: !argv.includes("--no-launch"),
    godot: get("godot", process.env.GODOT ?? "godot")!,
    quit: argv.includes("--quit"),
    capture: get("capture", "") ?? "",
    log: get("log", "") ?? "",
    record: get("record", "") ?? "",
    mode,
    beatTicks,
  };
}

/** .avi (+ .wav) from Godot's movie writer -> .mp4 (H.264 + AAC) with ffmpeg; the sources are removed on success. */
export async function makeVideo(avi: string, mp4: string, log: (line: string) => void): Promise<void> {
  if (!existsSync(avi)) throw new Error(`no movie was written at ${avi}`);
  const wav = avi.replace(/\.avi$/, ".wav");
  const inputs = existsSync(wav) ? ["-i", avi, "-i", wav] : ["-i", avi];
  const ffArgs = ["-loglevel", "error", "-y", ...inputs, "-c:v", "libx264", "-preset", "veryfast", "-crf", "23", "-pix_fmt", "yuv420p", ...(existsSync(wav) ? ["-c:a", "aac", "-b:a", "160k", "-shortest"] : ["-an"]), "-movflags", "+faststart", mp4];
  log(`video: encoding ${basename(mp4)} with ffmpeg`);
  const started = Date.now();
  await new Promise<void>((resolve, reject) => {
    const ff = spawn("ffmpeg", ffArgs, { stdio: ["ignore", "ignore", "pipe"] });
    let err = "";
    ff.stderr?.on("data", (d) => (err += String(d)));
    ff.on("error", (e) => reject(new Error(`ffmpeg not available (${e.message})`)));
    ff.on("exit", (code) => (code === 0 ? resolve() : reject(new Error(`ffmpeg exited ${code}: ${err.slice(0, 300)}`))));
  });
  for (const f of [avi, wav]) if (existsSync(f)) unlinkSync(f);
  log(`video: ${mp4} (${((Date.now() - started) / 1000).toFixed(0)} s)`);
}

export function clientFor(spec: string, effort: Effort, cache: Map<string, ModelClient>): ModelClient {
  const { provider } = splitSpec(spec);
  const key = provider === "fake" ? "fake" : "providers";
  let c = cache.get(key);
  if (!c) {
    c = provider === "fake" ? new FakeModelClient(300) : new ProviderClient(effort);
    cache.set(key, c);
  }
  return c;
}

const stamp = (): string => new Date().toISOString().slice(11, 19);
const say = (msg: string): void => console.log(`${stamp()} ${msg}`);

async function main(): Promise<void> {
  const args = parseCli(process.argv.slice(2));
  const link = new Link(args.port);
  await link.listen();
  say(`link on ws://127.0.0.1:${args.port}; ${args.sides.p1.fighter} (${args.sides.p1.spec}) vs ${args.sides.p2.fighter} (${args.sides.p2.spec}) on ${args.stage}, seed ${args.seed}, cap $${args.cap} per side, effort ${args.effort}, mode ${args.mode}${args.mode === "beat" ? ` (a beat every ${args.beatTicks} ticks)` : ""}`);

  let game: ChildProcess | null = null;
  let ending = false;
  let afterGame: (() => Promise<void>) | null = null;
  let liveWriter: (() => void) | null = null;
  let onVideo: (() => void) | null = null; // the video conversion, once the game has closed
  const end = async (reason: string, code: number): Promise<never> => {
    ending = true;
    link.send({ type: "end", reason });
    await new Promise((r) => setTimeout(r, 300));
    await link.close();
    if (game && game.exitCode === null) {
      // The game quits on `end`; give it a moment (the movie writer flushes its file), then insist.
      const kill = setTimeout(() => game?.kill(), 8000);
      await new Promise<void>((r) => (game!.exitCode !== null ? r() : game!.once("exit", () => r())));
      clearTimeout(kill);
    }
    if (afterGame) await afterGame().catch((e) => say(`video: ${e instanceof Error ? e.message : e}`));
    process.exit(code);
  };
  process.on("SIGINT", () => void end("interrupted", 130));
  process.on("SIGTERM", () => void end("terminated", 143));

  if (args.log) BattleLog.at(args.log).live({ at: new Date().toISOString(), phase: "waiting", sides: args.sides, stage: args.stage, seed: args.seed });
  if (args.launch) {
    const godotArgs = ["--path", REPO_ROOT, "--", `--coach=ws://127.0.0.1:${args.port}`, `--p1=${args.sides.p1.fighter}`, `--p2=${args.sides.p2.fighter}`, `--stage=${args.stage}`, `--seed=${args.seed}`];
    if (args.quit) godotArgs.push("--quit-after-match");
    if (args.capture) godotArgs.push(`--capture-dir=${args.capture}`);
    if (args.record) {
      // Godot's movie writer: every frame rendered at a fixed 60 fps (MJPEG .avi + .wav), then
      // ffmpeg makes the .mp4 once the game has closed. Rendering slower than real time slows
      // the game, not the coaches, so a recorded match sees a few more turns per round.
      const avi = args.record.replace(/\.mp4$/, "") + ".avi";
      godotArgs.unshift("--write-movie", avi, "--fixed-fps", "60");
      afterGame = async () => {
        await makeVideo(avi, args.record, say);
        onVideo?.();
      };
    }
    say(`launching ${args.godot} ${godotArgs.join(" ")}`);
    game = spawn(args.godot, godotArgs, { stdio: ["ignore", "pipe", "pipe"] });
    const relay = (data: Buffer) => {
      for (const line of String(data).split("\n")) if (line.trim() && !/material|shader/i.test(line)) console.log(`${stamp()} [game] ${line}`);
    };
    game.stdout?.on("data", relay);
    game.stderr?.on("data", relay);
    game.on("exit", (code) => {
      if (ending) return;
      say(`the game exited with code ${code ?? "?"} before the match ended`);
      void end("game exited", code ?? 1);
    });
    game.on("error", (e) => {
      say(`could not start the game: ${e.message}`);
      void end("no game", 1);
    });
  } else say("waiting for the game to connect (--no-launch)");

  // Everything after hello is set up inside its handler: the game may send hello and
  // round_start in one read, and a coach made later would miss the round.
  link.once("hello", (hello: Hello) => {
    say(`game connected: ${hello.p1.name} vs ${hello.p2.name} on ${hello.stage}, first to ${hello.rounds_to_win}`);
    link.send({ type: "models", p1: args.sides.p1.spec, p2: args.sides.p2.spec }); // the HUD's name plates
    link.send({ type: "mode", mode: args.mode, beat_ticks: args.beatTicks });
    // Beat mode: the game waits at each beat until both coaches have answered.
    const beatDone = new Map<number, Set<Side>>();
    const onBeatDone = (side: Side, n: number) => {
      const done = beatDone.get(n) ?? new Set<Side>();
      done.add(side);
      beatDone.set(n, done);
      if (done.size === 2) {
        beatDone.delete(n);
        link.send({ type: "resume", n });
      }
    };
    const log = args.log ? BattleLog.at(args.log) : new BattleLog(battleId(hello));
    const clients = new Map<string, ModelClient>();
    const recent: unknown[] = []; // the last events, for live.json
    let videoReady = false;
    liveWriter = () => live();
    onVideo = () => {
      videoReady = true;
      live();
    };
    let result: Record<string, unknown> | null = null;
    const live = () =>
      log.live({
        at: new Date().toISOString(),
        phase: result ? "over" : link.roundLive ? "live" : "between",
        hello: { p1: { id: hello.p1.id, name: hello.p1.name }, p2: { id: hello.p2.id, name: hello.p2.name }, stage: hello.stage, rounds_to_win: hello.rounds_to_win },
        sides: Object.fromEntries(SIDES.map((s) => [s, { fighter: hello[s].id, model: args.sides[s].spec }])),
        mode: args.mode,
        state: link.latest,
        coaches: Object.fromEntries(coaches.map((c) => [c.side, c.stats()])),
        events: recent.slice(-12),
        result,
        video: args.record ? { file: basename(args.record), ready: videoReady } : null,
      });
    const coaches = SIDES.map(
      (side) =>
        new Coach(side, args.sides[side].spec, clientFor(args.sides[side].spec, args.effort, clients), link, hello, log, {
          cadenceMs: args.cadence,
          capUsd: args.cap,
          effort: args.effort,
          mode: args.mode,
          beatTicks: args.beatTicks,
          onBeatDone,
          onTurn: (s, t) => {
            const who = `${s} ${hello[s].name}`;
            if (t.error) say(`${who}: error ${t.error}`);
            else say(`${who} (${t.reason}, ${t.seconds.toFixed(1)} s${t.usd != null ? `, $${t.usd.toFixed(4)}` : ""}): ${t.calls.join("; ") || "no tools"}`);
            if (t.caption) say(`${who} says: "${t.caption}"`);
          },
        }),
    );
    const liveTimer = setInterval(live, 1000);
    const status = setInterval(() => {
      for (const c of coaches) {
        const s = c.stats();
        say(`${s.side} ${hello[s.side].name}: ${s.status}, ${s.turns} turns, ${s.tokens} tokens, $${s.usd.toFixed(3)}, ${s.avgSeconds != null ? s.avgSeconds.toFixed(1) : "-"} s/turn, ${s.plansApplied} applied, ${s.refused} refused, ${s.errors} errors`);
      }
    }, 5000);
    link.on("event", (e) => {
      recent.push({ ...e, at: new Date().toISOString() });
      if (recent.length > 40) recent.shift();
      if (e.event === "match_end") result = { winner: (e.winner as Side | null) ?? null, wins: e.wins ?? null, reason: e.reason ?? null };
      live();
      if (e.event === "round_end") say(`round ${link.latest?.round ?? "?"} over: ${e.winner == null ? "draw" : `${e.winner} ${hello[e.winner as Side].name} wins`} (${e.reason})`);
      if (e.event === "match_end") {
        clearInterval(status);
        clearInterval(liveTimer);
        const winner = e.winner as Side | null;
        say(`MATCH OVER: ${winner ? `${winner} ${hello[winner].name} (${args.sides[winner].spec}) wins` : "draw"} ${JSON.stringify(e.wins ?? "")} (${e.reason ?? ""})`);
        for (const c of coaches) c.stop();
        log.battle({
          id: log.id,
          at: new Date().toISOString(),
          stage: hello.stage,
          seed: args.seed,
          sides: Object.fromEntries(SIDES.map((s) => [s, { fighter: hello[s].id, model: args.sides[s].spec }])),
          result: { winner, wins: e.wins ?? null, reason: e.reason ?? null },
          coaches: Object.fromEntries(coaches.map((c) => [c.side, c.stats()])),
          settings: { cap: args.cap, cadence: args.cadence, effort: args.effort, mode: args.mode, beatTicks: args.beatTicks },
        });
        live();
        say(`log: ${log.dir}`);
        void end("match over", 0);
      }
    });
  });
  link.on("disconnected", () => {
    if (!ending) {
      say("the game disconnected");
      void end("game disconnected", 1);
    }
  });
}

if (process.argv[1] && import.meta.url === new URL(`file://${process.argv[1]}`).href) {
  main().catch((e) => {
    console.error(e instanceof Error ? e.message : e);
    process.exit(1);
  });
}
