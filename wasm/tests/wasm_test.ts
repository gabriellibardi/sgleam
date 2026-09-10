import { assertEquals, assertMatch } from "jsr:@std/assert";
import { makeWasi } from "./wasi.ts";

// --- WASM exports interface ---

interface WasmExports {
  memory: WebAssembly.Memory;
  repl_new(
    code_ptr: number,
    code_len: number,
    config_ptr: number,
    config_len: number,
  ): number;
  repl_run(repl: number, ptr: number, len: number): number;
  repl_destroy(repl: number): void;
  repl_complete?(
    repl: number,
    ptr: number,
    len: number,
    cursor_pos: number,
  ): number;
  repl_ready?(
    repl: number,
    ptr: number,
    len: number,
    cursor: number,
  ): number;
  string_allocate(size: number): number;
  string_deallocate(ptr: number, size: number): void;
  format(ptr: number, len: number): number;
  cstr_deallocate(ptr: number): void;
  version(): number;
}

// --- Memory helpers ---

const encoder = new TextEncoder();
const decoder = new TextDecoder();

function encodeString(exports: WasmExports, str: string): [number, number] {
  const encoded = encoder.encode(str);
  const ptr = exports.string_allocate(encoded.length);
  new Uint8Array(exports.memory.buffer, ptr, encoded.length).set(encoded);
  return [ptr, encoded.length];
}

function readCstr(exports: WasmExports, ptr: number): string {
  const buffer = new Uint8Array(exports.memory.buffer);
  let end = ptr;
  while (buffer[end] !== 0) end++;
  return decoder.decode(buffer.slice(ptr, end));
}

// --- Mock env ---

const KEYPRESS = 0;
const KEYDOWN = 1;
const KEYUP = 2;
const PADDOWN = 3;
const PADUP = 4;
const PLAYER_JOIN = 5;
const PLAYER_LEAVE = 6;
const TICK = 7;
const CLOSE = 8;
const EVENT_NONE = 9;

interface EnvEvent {
  type: number;
  player?: number;
  value?: string;
  alt?: boolean;
  ctrl?: boolean;
  shift?: boolean;
  meta?: boolean;
  repeat?: boolean;
}

interface MworldStart {
  minPlayers: number;
  maxPlayers: number;
  tickRate: number;
}

interface PlayerSvg {
  player: number;
  svg: string;
}

interface EnvOptions {
  interruptAfter?: number;
  events?: EnvEvent[];
}

// Fake clock, advanced by sleep so the world loop's scheduling fires ticks
// deterministically without burning real wall-clock time. The engine reads
// the time through WASI, so this is handed to both sides: `sleep` here moves
// it, `makeWasi` reads it.
interface FakeClock {
  ms: bigint;
}

function makeEnv(
  getBuffer: () => ArrayBufferLike,
  svgs: string[],
  mworldStarts: MworldStart[],
  playerSvgs: PlayerSvg[],
  mworldStops: boolean[],
  clock: FakeClock,
  options: EnvOptions = {},
): WebAssembly.ModuleImports {
  let interruptCount = 0;
  const interruptAfter = options.interruptAfter ?? Infinity;
  const events = [...(options.events ?? [])];

  return {
    check_interrupt: (): number => {
      interruptCount++;
      return interruptCount >= interruptAfter ? 1 : 0;
    },
    sleep: (ms: bigint): void => {
      clock.ms += ms;
    },
    draw_svg: (ptr: number, len: number): void => {
      const b = new Uint8Array(getBuffer() as ArrayBuffer);
      svgs.push(decoder.decode(b.slice(ptr, ptr + len)));
    },
    get_event: (
      playerPtr: number,
      valuePtr: number,
      valueLen: number,
      mods: number,
    ): number => {
      const event = events.shift();
      if (!event) {
        return EVENT_NONE;
      }
      const buffer = getBuffer() as ArrayBuffer;
      const b = new Uint8Array(buffer);
      new DataView(buffer).setBigUint64(
        playerPtr,
        BigInt(event.player ?? 0),
        true,
      );
      const value = encoder.encode(event.value ?? "");
      const writeStart = Math.max(0, valuePtr);
      const writeEnd = Math.min(
        b.length,
        valuePtr + Math.max(0, valueLen),
      );
      if (writeStart < writeEnd) {
        b.fill(0, writeStart, writeEnd);
        b.set(value.subarray(0, writeEnd - writeStart), writeStart);
      }
      if (mods >= 0 && mods + 4 < b.length) {
        b[mods + 0] = event.alt ? 1 : 0;
        b[mods + 1] = event.ctrl ? 1 : 0;
        b[mods + 2] = event.shift ? 1 : 0;
        b[mods + 3] = event.meta ? 1 : 0;
        b[mods + 4] = event.repeat ? 1 : 0;
      }
      return event.type;
    },
    start_mworld: (
      minPlayers: bigint,
      maxPlayers: bigint,
      tickRate: bigint,
    ): void => {
      mworldStarts.push({
        minPlayers: Number(minPlayers),
        maxPlayers: Number(maxPlayers),
        tickRate: Number(tickRate),
      });
    },
    draw_player_svg: (player: bigint, ptr: number, len: number): void => {
      const b = new Uint8Array(getBuffer() as ArrayBuffer);
      playerSvgs.push({
        player: Number(player),
        svg: decoder.decode(b.slice(ptr, ptr + len)),
      });
    },
    stop_mworld: (): void => {
      mworldStops.push(true);
    },
    text_metrics: (
      _text: number,
      _textLen: number,
      _font: number,
      _fontLen: number,
      out: number,
    ): void => {
      const view = new DataView(getBuffer() as ArrayBuffer);
      for (const [i, v] of [10, 16, -5, 12].entries()) {
        view.setFloat64(out + i * 8, v, true);
      }
    },
    load_bitmap_fetch: (): number => 0,
    load_bitmap_width: (): number => 0,
    load_bitmap_height: (): number => 0,
    load_bitmap_data: (): number => 0,
  };
}

// --- WASM loader ---

interface WasmContext {
  exports: WasmExports;
  stdout: string[];
  stderr: string[];
  svgs: string[];
  mworldStarts: MworldStart[];
  playerSvgs: PlayerSvg[];
  mworldStops: boolean[];
}

interface LoadOptions {
  bigint?: boolean;
  interruptAfter?: number;
  events?: EnvEvent[];
}

async function loadWasm(options: LoadOptions = {}): Promise<WasmContext> {
  const stdout: string[] = [];
  const stderr: string[] = [];
  const svgs: string[] = [];
  const mworldStarts: MworldStart[] = [];
  const playerSvgs: PlayerSvg[] = [];
  const mworldStops: boolean[] = [];

  const wasmPath = new URL(
    "../../target/wasm32-wasip1/release-small/sgleam.wasm",
    import.meta.url,
  ).pathname;
  const wasmBytes = await Deno.readFile(wasmPath);
  const module = await WebAssembly.compile(wasmBytes);

  let exports: WasmExports;

  const clock: FakeClock = { ms: 0n };

  const wasi = makeWasi({
    getBuffer: () => exports.memory.buffer,
    write: (fd, text) => {
      if (fd === 2) stderr.push(text);
      else stdout.push(text);
    },
    env: ["RUST_BACKTRACE=1"],
    now: () => clock.ms,
  });

  const env = makeEnv(
    () => exports.memory.buffer,
    svgs,
    mworldStarts,
    playerSvgs,
    mworldStops,
    clock,
    {
      interruptAfter: options.interruptAfter,
      events: options.events,
    },
  );

  const instance = await WebAssembly.instantiate(module, {
    env,
    wasi_snapshot_preview1: wasi,
  });

  exports = instance.exports as unknown as WasmExports;

  return {
    exports,
    stdout,
    stderr,
    svgs,
    mworldStarts,
    playerSvgs,
    mworldStops,
  };
}

// --- Helper ---

interface ReplContext extends WasmContext {
  repl: number;
}

async function newRepl(
  source = "",
  options: LoadOptions = {},
): Promise<ReplContext> {
  const ctx = await loadWasm(options);
  const [codePtr, codeLen] = encodeString(ctx.exports, source);
  const config = options.bigint !== false ? "bigint=true" : "";
  const [cfgPtr, cfgLen] = encodeString(ctx.exports, config);
  const repl = ctx.exports.repl_new(codePtr, codeLen, cfgPtr, cfgLen);
  ctx.exports.string_deallocate(codePtr, codeLen);
  ctx.exports.string_deallocate(cfgPtr, cfgLen);
  return { ...ctx, repl };
}

function run(
  ctx: ReplContext,
  input: string,
): { result: number; stdout: string; stderr: string; svgs: string[] } {
  ctx.stdout.length = 0;
  ctx.stderr.length = 0;
  ctx.svgs.length = 0;
  const [ptr, len] = encodeString(ctx.exports, input);
  const result = ctx.exports.repl_run(ctx.repl, ptr, len);
  ctx.exports.string_deallocate(ptr, len);
  return {
    result,
    stdout: ctx.stdout.join(""),
    stderr: ctx.stderr.join(""),
    svgs: [...ctx.svgs],
  };
}

function destroy(ctx: ReplContext): void {
  ctx.exports.repl_destroy(ctx.repl);
}

// --- Constants ---

const REPL_OK = 0;
const REPL_ERROR = 1;
const REPL_QUIT = 2;

// --- World program used in multiple tests ---

const MOVE_SQUARE = `import gleam/int
import sgleam/fill
import sgleam/image
import sgleam/stroke
import sgleam/style
import sgleam/world
import sgleam/xplace
import sgleam/yplace

pub fn main() {
  world.create(Pos(lines / 2, columns / 2), draw)
  |> world.on_key_down(move)
  |> world.stop_when(fn(p) { p.line == 0 && p.column == 0 })
  |> world.run()
}

const lines = 9
const columns = 11
const size = 30

pub type Pos {
  Pos(line: Int, column: Int)
}

pub fn draw(p: Pos) -> image.Image {
  image.empty_scene(size * columns, size * lines)
  |> image.place_image_align(
    size * p.column,
    size * p.line,
    xplace.Left,
    yplace.Top,
    image.square(size, [fill.red, stroke.black] |> style.join),
  )
}

pub fn move(p: Pos, key: world.Key) -> Pos {
  let p = case key {
    world.ArrowLeft -> Pos(..p, column: p.column - 1)
    world.ArrowRight -> Pos(..p, column: p.column + 1)
    world.ArrowDown -> Pos(..p, line: p.line + 1)
    world.ArrowUp -> Pos(..p, line: p.line - 1)
    _ -> p
  }
  Pos(int.clamp(p.line, 0, lines - 1), int.clamp(p.column, 0, columns - 1))
}
`;

// A world with a handler for every kind of key event but keydown. What it
// prints says which handler ran, and for which key.
const KEY_HANDLERS = `import gleam/io
import gleam/string
import sgleam/image
import sgleam/stroke
import sgleam/world

pub fn main() {
  world.create(0, draw)
  |> world.on_key_press(handler("press"))
  |> world.on_key_up(handler("up"))
  |> world.stop_when(fn(handled) { handled == 2 })
  |> world.run()
}

pub fn draw(_handled: Int) -> image.Image {
  image.circle(20, stroke.red)
}

fn handler(name: String) -> fn(Int, world.Key) -> Int {
  fn(handled, key) {
    io.println(name <> " " <> string.inspect(key))
    handled + 1
  }
}
`;

// Every name `world` knows, in the order it lists them.
const KEY_NAMES = [
  "ArrowLeft",
  "ArrowRight",
  "ArrowUp",
  "ArrowDown",
  "PageUp",
  "PageDown",
  "Home",
  "End",
  "Backspace",
  "Tab",
  "Enter",
  "Escape",
  "Delete",
  "Insert",
  "F1",
  "F2",
  "F3",
  "F4",
  "F5",
  "F6",
  "F7",
  "F8",
  "F9",
  "F10",
  "F11",
  "F12",
  "CapsLock",
  "NumLock",
  "ScrollLock",
  "PrintScreen",
  "Pause",
  "Shift",
  "Control",
  "Alt",
  "Meta",
];

// A world that prints the key of every keydown it is given, and stops once it
// has seen `count` of them.
function keyNamesProgram(count: number): string {
  return `import gleam/io
import gleam/string
import sgleam/image
import sgleam/stroke
import sgleam/world

pub fn main() {
  world.create(0, draw)
  |> world.on_key_down(fn(seen, key) {
    io.println(string.inspect(key))
    seen + 1
  })
  |> world.stop_when(fn(seen) { seen == ${count} })
  |> world.run()
}

pub fn draw(_seen: Int) -> image.Image {
  image.circle(20, stroke.red)
}
`;
}

const PAD_HANDLERS = `import gleam/io
import gleam/string
import sgleam/image
import sgleam/stroke
import sgleam/world

pub fn main() {
  world.create(0, draw)
  |> world.on_pad_down(handler("down"))
  |> world.on_pad_up(handler("up"))
  |> world.stop_when(fn(handled) { handled == 2 })
  |> world.run()
}

pub fn draw(_handled: Int) -> image.Image {
  image.circle(20, stroke.red)
}

fn handler(name: String) -> fn(Int, world.PadInput) -> Int {
  fn(handled, input) {
    io.println(name <> " " <> string.inspect(input))
    handled + 1
  }
}
`;

const PAD_MAPPINGS = `import gleam/io
import gleam/string
import sgleam/image
import sgleam/stroke
import sgleam/world

pub fn main() {
  world.create(0, draw)
  |> world.on_pad_down(fn(handled, input) {
    io.println(string.inspect(input))
    handled + 1
  })
  |> world.stop_when(fn(handled) { handled == 12 })
  |> world.run()
}

pub fn draw(_handled: Int) -> image.Image {
  image.circle(20, stroke.red)
}
`;

const MWORLD_SQUARES = `import gleam/io
import sgleam/fill
import sgleam/image
import sgleam/mworld

pub type State {
  State(left_x: Int, right_x: Int, ticks: Int)
}

pub fn main() {
  mworld.create(State(100, 200, 0), min: 2, max: 2, to_image: draw)
  |> mworld.tick_rate(1000)
  |> mworld.on_tick(fn(state) {
    io.println("tick")
    State(..state, ticks: state.ticks + 1)
  })
  |> mworld.on_pad_down(move_with_pad)
  |> mworld.stop_when(fn(state) { state.left_x == 90 })
  |> mworld.run()
}

pub fn draw(state: State, player: mworld.Player) -> image.Image {
  let x = case mworld.player_index(player) {
    1 -> state.left_x + state.ticks
    _ -> state.right_x + state.ticks
  }
  image.empty_scene(300, 100)
  |> image.place_image(x, 50, image.square(20, fill.red))
}

pub fn move_with_pad(
  state: State,
  player: mworld.Player,
  input: mworld.PadInput,
) -> State {
  case mworld.player_index(player), input {
    1, input if input == mworld.left -> State(..state, left_x: 90)
    2, input if input == mworld.left -> State(..state, right_x: 190)
    _, _ -> state
  }
}
`;

const MWORLD_LIFECYCLE = `import gleam/int
import gleam/io
import sgleam/image
import sgleam/mworld
import sgleam/stroke

pub fn main() {
  mworld.create(0, min: 1, max: 2, to_image: draw)
  |> mworld.on_player_join(fn(count, player) {
    io.println("join " <> int.to_string(mworld.player_index(player)))
    count + 1
  })
  |> mworld.on_player_leave(fn(count, player) {
    io.println("leave " <> int.to_string(mworld.player_index(player)))
    count - 1
  })
  |> mworld.run()
}

pub fn draw(count: Int, _player: mworld.Player) -> image.Image {
  image.circle(20 + count, stroke.red)
}
`;

const ANIMATE = `import gleam/int
import gleam/io
import sgleam/image
import sgleam/stroke
import sgleam/world

pub fn main() {
  world.animate(fn(frame) {
    io.println("frame " <> int.to_string(frame))
    image.circle(10 + frame, stroke.red)
  })
}
`;

// --- Tests ---

Deno.test("version returns non-empty string", async () => {
  const ctx = await loadWasm();
  const ptr = ctx.exports.version();
  const ver = readCstr(ctx.exports, ptr);
  ctx.exports.cstr_deallocate(ptr);
  assertEquals(ver.length > 0, true, "version should be non-empty");
});

Deno.test("repl smoke test", async () => {
  const ctx = await newRepl();
  const r = run(ctx, "1 + 2");
  assertEquals(r.result, REPL_OK, `stderr:\n${r.stderr}\nstdout:\n${r.stdout}`);
  assertEquals(r.stdout, "3\n");
  destroy(ctx);
});

Deno.test("an import of a pasted input is in scope for its definitions", async () => {
  const ctx = await newRepl();
  const r = run(
    ctx,
    "import gleam/int\n\npub fn f(n) {\n  int.to_string(n)\n}\n\nf(5)\n",
  );
  assertEquals(r.result, REPL_OK, `stderr:\n${r.stderr}\nstdout:\n${r.stdout}`);
  assertEquals(r.stdout, '"5"\n');
  destroy(ctx);
});

Deno.test(":quit returns quit status", async () => {
  const ctx = await newRepl();
  const r = run(ctx, ":quit");
  assertEquals(r.result, REPL_QUIT);
  destroy(ctx);
});

Deno.test("multiple runs", async () => {
  const ctx = await newRepl();
  const r1 = run(ctx, "1 + 2");
  assertEquals(r1.stdout, "3\n");
  const r2 = run(ctx, "10 + 20");
  assertEquals(r2.stdout, "30\n");
  destroy(ctx);
});

Deno.test("error output contains ansi codes", async () => {
  const ctx = await newRepl();
  const r = run(ctx, "unknown_variable");
  assertEquals(r.result, REPL_ERROR);
  assertMatch(r.stderr, /\x1b\[/, "expected ANSI codes in error output");
  destroy(ctx);
});

Deno.test("load with errors returns null", async () => {
  const ctx = await loadWasm();
  const source = "pub fn f(x) { x + 1 }\npub fn g() { unknown }";
  const [codePtr, codeLen] = encodeString(ctx.exports, source);
  const [cfgPtr, cfgLen] = encodeString(ctx.exports, "");
  const repl = ctx.exports.repl_new(codePtr, codeLen, cfgPtr, cfgLen);
  ctx.exports.string_deallocate(codePtr, codeLen);
  ctx.exports.string_deallocate(cfgPtr, cfgLen);
  assertEquals(repl, 0, "repl_new should return null for code with errors");
});

Deno.test("load without errors", async () => {
  const ctx = await newRepl("pub fn f(x: Int) -> Int { x + 1 }");
  assertEquals(ctx.repl !== 0, true, "repl_new should return non-null");
  const r = run(ctx, "f(10)");
  assertEquals(r.result, REPL_OK);
  assertEquals(r.stdout, "11\n");
  destroy(ctx);
});

Deno.test("load with examples", async () => {
  const source = `import sgleam/check

pub fn add(a: Int, b: Int) -> Int {
  a + b
}

pub fn add_examples() {
  check.eq(add(1, 2), 3)
  check.eq(add(0, 0), 0)
}
`;
  const ctx = await loadWasm();
  const [codePtr, codeLen] = encodeString(ctx.exports, source);
  const [cfgPtr, cfgLen] = encodeString(ctx.exports, "");
  const repl = ctx.exports.repl_new(codePtr, codeLen, cfgPtr, cfgLen);
  ctx.exports.string_deallocate(codePtr, codeLen);
  ctx.exports.string_deallocate(cfgPtr, cfgLen);
  assertEquals(repl !== 0, true);
  const stdout = ctx.stdout.join("");
  assertEquals(
    stdout.includes("2 tests"),
    true,
    `expected test output, got: ${stdout}`,
  );
  ctx.exports.repl_destroy(repl);
});

Deno.test("circle image produces SVG", async () => {
  const ctx = await newRepl();
  const r = run(
    ctx,
    "import sgleam/image\nimport sgleam/stroke\nimage.circle(30, stroke.red)",
  );
  assertEquals(r.result, REPL_OK);
  assertEquals(
    r.svgs.length > 0,
    true,
    `expected SVG, got none. stdout: ${r.stdout}`,
  );
  assertEquals(r.svgs[0].includes("<svg"), true, "expected SVG content");
  destroy(ctx);
});

Deno.test("wedge image produces SVG", async () => {
  const ctx = await newRepl();
  const r = run(
    ctx,
    "import sgleam/image\nimport sgleam/fill\nimage.wedge(40, 90, fill.red)",
  );
  assertEquals(r.result, REPL_OK);
  assertEquals(r.svgs.length > 0, true, "expected SVG output");
  destroy(ctx);
});

Deno.test("add_curve renders", async () => {
  const ctx = await newRepl();
  const r = run(
    ctx,
    "import sgleam/image\nimport sgleam/stroke\nimage.add_curve(image.rectangle(100, 100, stroke.black), 20, 20, 0, 0.333, 80, 80, 0, 0.333, stroke.red)",
  );
  assertEquals(r.result, REPL_OK);
  assertEquals(r.stderr, "", `unexpected stderr: ${r.stderr}`);
  destroy(ctx);
});

Deno.test("format code", async () => {
  const ctx = await loadWasm();
  const input = "pub fn f( x : Int ) { x+1 }";
  const [ptr, len] = encodeString(ctx.exports, input);
  const resultPtr = ctx.exports.format(ptr, len);
  ctx.exports.string_deallocate(ptr, len);
  assertEquals(resultPtr !== 0, true, "format should return non-null");
  const formatted = readCstr(ctx.exports, resultPtr);
  ctx.exports.cstr_deallocate(resultPtr);
  assertEquals(
    formatted.includes("pub fn f"),
    true,
    "should contain formatted function",
  );
});

Deno.test("sleep works with BigInt", async () => {
  const ctx = await newRepl();
  const r = run(ctx, "import sgleam/system\nsystem.sleep(10)");
  assertEquals(r.result, REPL_OK);
  assertEquals(r.stderr, "", `unexpected stderr: ${r.stderr}`);
  destroy(ctx);
});

Deno.test("sleep works with computed BigInt value", async () => {
  const ctx = await newRepl();
  const r = run(
    ctx,
    "import sgleam/system\nlet ms = 25 + 25\nsystem.sleep(ms)",
  );
  assertEquals(r.result, REPL_OK);
  assertEquals(r.stderr, "", `unexpected stderr: ${r.stderr}`);
  destroy(ctx);
});

Deno.test("sleep works with Number (bigint disabled)", async () => {
  const ctx = await newRepl("", { bigint: false });
  const r = run(ctx, "import sgleam/system\nsystem.sleep(50)");
  assertEquals(r.result, REPL_OK);
  assertEquals(r.stderr, "", `unexpected stderr: ${r.stderr}`);
  destroy(ctx);
});

Deno.test("move_square loads without crash", async () => {
  const ctx = await newRepl(MOVE_SQUARE);
  assertEquals(ctx.repl !== 0, true, "repl_new should return non-null");
  assertEquals(
    ctx.stderr.join(""),
    "",
    `unexpected stderr: ${ctx.stderr.join("")}`,
  );
  destroy(ctx);
});

// Regression: the WASM import for sleep must not collide with the POSIX
// sleep symbol. The wasm32-wasip1 linker replaces an unresolved "sleep"
// with a signature_mismatch stub that traps.
Deno.test("world.run does not crash (sleep regression)", async () => {
  const ctx = await newRepl(MOVE_SQUARE, { interruptAfter: 50 });
  assertEquals(ctx.repl !== 0, true);
  const r = run(ctx, "main()");
  assertEquals(r.svgs.length > 0, true, "expected SVG frames from world.run");
  // check_interrupt fires here, so stderr says "Interrupted."
  destroy(ctx);
});

// The events a handler is not for go by untouched: this world has no
// on_key_down, so the keydown it is given reaches none of its handlers.
Deno.test("on_key_press and on_key_up take their own events", async () => {
  const ctx = await newRepl(KEY_HANDLERS, {
    interruptAfter: 200_000,
    events: [
      { type: KEYDOWN, value: "ArrowLeft" },
      { type: KEYPRESS, value: "a" },
      { type: KEYUP, value: "Enter" },
    ],
  });
  const r = run(ctx, "main()");
  // The last line is the repl echoing what main() gave back.
  assertEquals(r.stdout, 'press Char("a")\nup Enter\nNil\n');
  // The first state, one per handled event, and the one stop_when draws.
  assertEquals(r.svgs.length, 4, `stderr:\n${r.stderr}`);
  destroy(ctx);
});

Deno.test("every key name decodes to its Key", async () => {
  const keys = [...KEY_NAMES, "a"];
  const ctx = await newRepl(keyNamesProgram(keys.length), {
    interruptAfter: 200_000,
    events: keys.map((value) => ({ type: KEYDOWN, value })),
  });
  const r = run(ctx, "main()");
  const expected = [...KEY_NAMES, 'Char("a")', "Nil"]
    .map((k) => `${k}\n`)
    .join("");
  assertEquals(r.stdout, expected, `stderr:\n${r.stderr}`);
  destroy(ctx);
});

Deno.test("pad handlers accept pad and mapped keyboard events", async () => {
  const ctx = await newRepl(PAD_HANDLERS, {
    interruptAfter: 200_000,
    events: [
      { type: PADDOWN, value: "Left" },
      { type: KEYUP, value: "k" },
    ],
  });
  const r = run(ctx, "main()");
  assertEquals(r.stdout, "down Left\nup ActionA\nNil\n");
  // The first state, one per handled event, and the one stop_when draws.
  assertEquals(r.svgs.length, 4, `stderr:\n${r.stderr}`);
  destroy(ctx);
});

Deno.test("keyboard controls use the standard pad mapping", async () => {
  const values = [
    "ArrowUp",
    "w",
    "ArrowDown",
    "s",
    "ArrowLeft",
    "a",
    "ArrowRight",
    "d",
    "z",
    "k",
    "x",
    "l",
  ];
  const ctx = await newRepl(PAD_MAPPINGS, {
    interruptAfter: 200_000,
    events: values.map((value) => ({ type: KEYDOWN, value })),
  });
  const r = run(ctx, "main()");
  assertEquals(
    r.stdout,
    "Up\nUp\nDown\nDown\nLeft\nLeft\nRight\nRight\n" +
      "ActionA\nActionA\nActionB\nActionB\nNil\n",
  );
  destroy(ctx);
});

Deno.test("mworld shares state and renders a view per player", async () => {
  const ctx = await newRepl(MWORLD_SQUARES, {
    interruptAfter: 200_000,
    events: [
      { type: PLAYER_JOIN, player: 1 },
      // A tick before min_players is reached must not change the state.
      { type: TICK },
      { type: PLAYER_JOIN, player: 2 },
      { type: TICK },
      {
        type: KEYDOWN,
        player: 2,
        value: "ArrowLeft",
        shift: true,
      },
      // An input cannot act as a player that has not joined.
      { type: KEYDOWN, player: 3, value: "ArrowLeft" },
      { type: PADDOWN, player: 1, value: "Left" },
      { type: CLOSE },
    ],
  });
  assertEquals(
    ctx.repl !== 0,
    true,
    `mworld source did not compile: ${ctx.stderr.join("")}`,
  );
  const r = run(ctx, "main()");
  assertEquals(r.result, REPL_OK, `stderr: ${r.stderr}`);
  assertEquals(r.stdout, "tick\nNil\n");
  assertEquals(ctx.mworldStarts, [{
    minPlayers: 2,
    maxPlayers: 2,
    tickRate: 100,
  }]);
  assertEquals(ctx.mworldStops.length, 1);
  assertEquals(
    ctx.playerSvgs.map((frame) => frame.player),
    [1, 1, 2, 1, 2, 1, 2, 1, 2],
  );
  assertEquals(
    ctx.playerSvgs[4].svg !== ctx.playerSvgs[6].svg,
    true,
    "expected a mapped key to update the shared world through the pad handler",
  );
  assertEquals(
    ctx.playerSvgs[7].svg !== ctx.playerSvgs[8].svg,
    true,
    "expected the two players to receive different views",
  );
  destroy(ctx);
});

Deno.test("mworld handles join, leave, and close", async () => {
  const ctx = await newRepl(MWORLD_LIFECYCLE, {
    interruptAfter: 200_000,
    events: [
      { type: PLAYER_JOIN, player: 1 },
      { type: PLAYER_JOIN, player: 2 },
      { type: PLAYER_LEAVE, player: 1 },
      { type: CLOSE },
    ],
  });
  const r = run(ctx, "main()");
  assertEquals(r.result, REPL_OK, `stderr: ${r.stderr}`);
  assertEquals(r.stdout, "join 1\njoin 2\nleave 1\nNil\n");
  assertEquals(ctx.playerSvgs.map((frame) => frame.player), [1, 1, 2, 2]);
  assertEquals(ctx.mworldStops.length, 1);
  destroy(ctx);
});

// animate has no stop of its own: it draws until it is interrupted.
Deno.test("animate draws a frame per number", async () => {
  const ctx = await newRepl(ANIMATE, { interruptAfter: 20 });
  const r = run(ctx, "main()");
  assertEquals(
    r.stdout.startsWith("frame 0\nframe 1\nframe 2\n"),
    true,
    `stdout:\n${r.stdout}`,
  );
  assertEquals(r.svgs.length >= 3, true, `got ${r.svgs.length} frames`);
  // The frame is what the image is drawn from, so no two frames are alike.
  assertEquals(r.svgs[0] !== r.svgs[1], true, "expected the frames to differ");
  destroy(ctx);
});

// --- Completion ---

Deno.test("repl_complete returns candidates", async () => {
  const ctx = await newRepl();
  run(ctx, "fn my_func() { 1 }");
  const input = "my_f";
  const [ptr, len] = encodeString(ctx.exports, input);
  const resultPtr = ctx.exports.repl_complete!(ctx.repl, ptr, len, len);
  ctx.exports.string_deallocate(ptr, len);
  assertEquals(resultPtr !== 0, true, "repl_complete should return non-null");
  const result = readCstr(ctx.exports, resultPtr);
  ctx.exports.cstr_deallocate(resultPtr);
  assertEquals(result.startsWith("c "), true, "should start with 'c '");
  assertEquals(
    result.includes("my_func"),
    true,
    `should include my_func, got: ${result}`,
  );
  destroy(ctx);
});

Deno.test("repl_complete counts in bytes, not chars", async () => {
  const ctx = await newRepl();
  run(ctx, "fn my_func() { 1 }");
  // The break char before the word takes three bytes, and the one before
  // that takes two, so a `start` counted in chars would land inside them.
  const input = 'let x = "ol\u00e1\u2026my_f';
  const [ptr, len] = encodeString(ctx.exports, input);
  const resultPtr = ctx.exports.repl_complete!(ctx.repl, ptr, len, len);
  ctx.exports.string_deallocate(ptr, len);
  assertEquals(resultPtr !== 0, true, "repl_complete should return non-null");
  const result = readCstr(ctx.exports, resultPtr);
  ctx.exports.cstr_deallocate(resultPtr);
  assertEquals(
    result.startsWith("c 16\n"),
    true,
    `word should start at byte 16, got: ${result}`,
  );
  assertEquals(
    result.includes("my_func"),
    true,
    `should include my_func, got: ${result}`,
  );
  destroy(ctx);
});

Deno.test("repl_complete keeps the space a candidate ends with", async () => {
  const ctx = await newRepl();
  // The completion offers `:type` with the space that goes after it, and a
  // line is what tells one candidate from the next, so the space arrives.
  const input = ":ty";
  const [ptr, len] = encodeString(ctx.exports, input);
  const resultPtr = ctx.exports.repl_complete!(ctx.repl, ptr, len, len);
  ctx.exports.string_deallocate(ptr, len);
  assertEquals(resultPtr !== 0, true, "repl_complete should return non-null");
  const result = readCstr(ctx.exports, resultPtr);
  ctx.exports.cstr_deallocate(resultPtr);
  assertEquals(result, "c 0\n:type ", `got: ${result}`);
  destroy(ctx);
});

Deno.test("repl_complete survives a cursor inside a char", async () => {
  const ctx = await newRepl();
  // Byte 12 is the middle of the `\u00e1`, which is where a host counting in
  // UTF-16 puts the cursor at the end of this line.
  const input = 'let x = "ol\u00e1';
  const [ptr, len] = encodeString(ctx.exports, input);
  const resultPtr = ctx.exports.repl_complete!(ctx.repl, ptr, len, 12);
  ctx.exports.string_deallocate(ptr, len);
  if (resultPtr !== 0) ctx.exports.cstr_deallocate(resultPtr);
  // The module is still there to answer, which is the whole of the question.
  assertEquals(
    run(ctx, "1 + 1").result,
    0,
    "repl should still run after completing",
  );
  destroy(ctx);
});

Deno.test("repl_complete returns null for no match", async () => {
  const ctx = await newRepl();
  const input = "zzz_no_match";
  const [ptr, len] = encodeString(ctx.exports, input);
  const resultPtr = ctx.exports.repl_complete!(ctx.repl, ptr, len, len);
  ctx.exports.string_deallocate(ptr, len);
  assertEquals(resultPtr, 0, "repl_complete should return null for no match");
  destroy(ctx);
});

Deno.test("repl_complete returns null for empty prefix", async () => {
  const ctx = await newRepl();
  const input = "";
  const [ptr, len] = encodeString(ctx.exports, input);
  const resultPtr = ctx.exports.repl_complete!(ctx.repl, ptr, len, 0);
  ctx.exports.string_deallocate(ptr, len);
  assertEquals(
    resultPtr,
    0,
    "repl_complete should return null for empty input",
  );
  destroy(ctx);
});

// --- Ready ---

Deno.test("repl_ready says what the input still needs", async () => {
  const ctx = await newRepl();
  const cases: [string, number][] = [
    // Finished: run it.
    ["1 + 2", -1],
    ["pub fn f() {\n  1\n}", -1],
    // Waiting on a value, with no bracket open.
    ["let x =", 0],
    // A level per bracket left open, whatever the bracket is.
    ["case x {", 2],
    ["io.println(", 2],
    ["let x = [1,", 2],
    ["pub fn f() {\n  case x {", 4],
    // A bracket the input only mentions opens nothing.
    ["1 + 1 // {", -1],
    // The way out of an input that will not close. With nothing open, a
    // blank line runs it and the error it earns is the engine's to give.
    ["let x =\n", -1],
    // With a bracket open it is a blank line inside the input -- how the
    // user writes a function with two statements.
    ["pub fn f() {\n  let x = 1\n", 2],
  ];
  for (const [input, expected] of cases) {
    const [ptr, len] = encodeString(ctx.exports, input);
    const result = ctx.exports.repl_ready!(ctx.repl, ptr, len, len);
    ctx.exports.string_deallocate(ptr, len);
    assertEquals(result, expected, JSON.stringify(input));
  }
  destroy(ctx);
});

// --- Config ---

Deno.test("repl_new config bigint=true enables BigInt", async () => {
  const ctx = await newRepl("", { bigint: true });
  const r = run(ctx, "1 + 2");
  assertEquals(r.result, REPL_OK);
  assertEquals(r.stdout, "3\n");
  destroy(ctx);
});

Deno.test("repl_new config bigint=false disables BigInt", async () => {
  const ctx = await newRepl("", { bigint: false });
  const r = run(ctx, "1 + 2");
  assertEquals(r.result, REPL_OK);
  assertEquals(r.stdout, "3\n");
  destroy(ctx);
});

// --- Interrupt ---

Deno.test("check_interrupt stops infinite recursion", async () => {
  const ctx = await newRepl("", { interruptAfter: 100 });
  const r = run(ctx, "fn f() { f() } f()");
  assertEquals(r.result, REPL_ERROR);
  assertEquals(
    r.stderr.includes("Interrupted"),
    true,
    `expected 'Interrupted' in stderr, got: ${r.stderr}`,
  );
  destroy(ctx);
});

// --- Stress ---

Deno.test("move_square survives many frames", async () => {
  // The world has no on_tick, so frames are produced only when key
  // handlers run. Feed ArrowRight events (move clamps, so the square
  // sits at the right edge after a few presses without triggering
  // stop_when). Each press renders, so N events => N frames.
  const events = Array.from({ length: 150 }, () => ({
    type: KEYDOWN,
    value: "ArrowRight",
  }));
  const ctx = await newRepl(MOVE_SQUARE, {
    interruptAfter: 15_000,
    events,
  });
  assertEquals(ctx.repl !== 0, true);
  const r = run(ctx, "main()");
  assertEquals(
    r.svgs.length > 100,
    true,
    `expected many SVG frames, got ${r.svgs.length}`,
  );
  destroy(ctx);
});

Deno.test("panic handler intercepts Rust panics", async () => {
  const ctx = await newRepl(); // init is called
  try {
    // Calling string_deallocate with null pointer triggers a panic via assert!(!ptr.is_null())
    ctx.exports.string_deallocate(0, 10);
  } catch (e) {
    // The WASM module execution will abort on panic.
  }
  const stderr = ctx.stderr.join("");
  assertEquals(
    stderr.includes("Fatal compiler bug") ||
      stderr.includes("assertion failed"),
    true,
    `expected formatted panic message in stderr, got: ${stderr}`,
  );
  destroy(ctx);
});

// The cli reads a line at a time, so an input holding several items only
// reaches the repl through this api, which takes the whole of it at once.
Deno.test("pub on a line of its own", async () => {
  for (
    const input of [
      "pub\nfn f() { 1 }\nf()",
      "pub\ttype T {\n  A\n}\nA",
      "pub\nconst c = 1\nc",
      "@internal\npub fn g() { 2 }\ng()",
    ]
  ) {
    const ctx = await newRepl();
    const r = run(ctx, input);
    assertEquals(r.stderr, "", `${input} wrote to stderr`);
    assertEquals(r.stdout.length > 0, true, `${input} produced nothing`);
    destroy(ctx);
  }
});
