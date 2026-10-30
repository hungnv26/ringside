// Shared fixtures: a hello, a state and a fake link the coaches can drive without a socket.
import { EventEmitter } from "node:events";
import type { GameLink, LinkEvents } from "../src/link.ts";
import type { AdapterFrame, Hello, Side, State } from "../src/types.ts";

export const hello: Hello = {
  type: "hello",
  version: "0.1",
  stage: "rooftop",
  rounds_to_win: 2,
  round_seconds: 99,
  seed: 7,
  p1: {
    id: "jin",
    name: "Jin",
    archetype: "Kicker",
    max_health: 980,
    moves: [
      { input: "6HK", name: "Axe Kick", startup: 16, active: 3, recovery: 22, damage: 95, level: "overhead" },
      { input: "236K", name: "Spinning Back Kick", startup: 14, active: 4, recovery: 24, damage: 110, level: "mid", notes: "travels, slightly unsafe" },
      { input: "623K", name: "Tornado Kick", startup: 6, active: 8, recovery: 30, damage: 120, level: "mid", notes: "invincible frames 1-6, launches" },
      { input: "236236K", name: "Hurricane Kicks", startup: 8, active: 40, recovery: 30, damage: 300, level: "mid", notes: "super" },
    ],
  },
  p2: {
    id: "kenji",
    name: "Kenji",
    archetype: "Zoner",
    max_health: 1000,
    moves: [
      { input: "236P", name: "Fireball", startup: 12, active: 60, recovery: 20, damage: 70, level: "mid", notes: "projectile" },
      { input: "623P", name: "Rising Uppercut", startup: 4, active: 8, recovery: 30, damage: 120, level: "mid", notes: "invincible, launches" },
    ],
  },
};

export function state(over: Partial<State> = {}): State {
  return {
    type: "state",
    tick: 600,
    round: 1,
    timer: 89,
    wins: [0, 0],
    distance: 1.73,
    p1: { health: 735, max_health: 980, meter: 1000, max_meter: 1000, state: "idle", move: null, cornered: false, recent: [{ input: "HK", name: "Roundhouse", outcome: "whiffed" }, { input: "2LK", outcome: "hit" }] },
    p2: { health: 1000, max_health: 1000, meter: 200, max_meter: 1000, state: "attack", move: "236P", cornered: true, recent: [{ input: "236P", name: "Fireball", outcome: "blocked" }] },
    ...over,
  };
}

export class FakeLink extends EventEmitter<LinkEvents> implements GameLink {
  hello: Hello | null = hello;
  latest: State | null = null;
  roundLive = false;
  sent: AdapterFrame[] = [];
  connected = true;
  send(frame: AdapterFrame): boolean {
    if (!this.connected) return false;
    this.sent.push(frame);
    return true;
  }
  // The game's side of the protocol, as the tests play it.
  feedState(s: State): void {
    this.latest = s;
    this.emit("state", s);
  }
  feedEvent(event: string, extra: Record<string, unknown> = {}): void {
    if (event === "round_start") this.roundLive = true;
    if (event === "round_end" || event === "match_end") this.roundLive = false;
    this.emit("event", { type: "event", tick: this.latest?.tick ?? 0, event, ...extra });
  }
  feedApplied(side: Side, plan_id: string, ok: boolean, error = ""): void {
    this.emit("applied", { type: "applied", side, plan_id, ok, error });
  }
}

// A clock the tests advance by hand; timers fire in order when `advance` passes them.
export class FakeClock {
  t = 0;
  private timers: { at: number; fn: () => void; id: number }[] = [];
  private next = 1;
  now = (): number => this.t;
  setTimer = (fn: () => void, ms: number): unknown => {
    const id = this.next++;
    this.timers.push({ at: this.t + ms, fn, id });
    return id;
  };
  clearTimer = (id: unknown): void => {
    this.timers = this.timers.filter((x) => x.id !== id);
  };
  async advance(ms: number): Promise<void> {
    const until = this.t + ms;
    for (;;) {
      this.timers.sort((a, b) => a.at - b.at);
      const due = this.timers[0];
      if (!due || due.at > until) break;
      this.timers.shift();
      this.t = due.at;
      due.fn();
      await settle();
    }
    this.t = until;
    await settle();
  }
}

export const settle = async (): Promise<void> => {
  for (let i = 0; i < 10; i++) await new Promise((r) => setImmediate(r));
};
