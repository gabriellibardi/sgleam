import gleam/int
import gleam/option.{type Option, None, Some}
import sgleam/image.{type Image}
import sgleam/system

pub fn animate(create_image: fn(Int) -> Image) -> Nil {
  animate_loop(create_image, 1000 / 28, 0)
}

fn animate_loop(create_image: fn(Int) -> Image, delay: Int, frame: Int) {
  frame |> create_image |> image.to_svg |> system.show_svg
  system.sleep(delay)
  animate_loop(create_image, delay, frame + 1)
}

pub type KeyEvent {
  KeyEvent(
    event_type: KeyEventType,
    key: Key,
    alt: Bool,
    ctrl: Bool,
    shift: Bool,
    meta: Bool,
    repeat: Bool,
  )
}

pub type Key {
  ArrowLeft
  ArrowRight
  ArrowUp
  ArrowDown
  PageUp
  PageDown
  Home
  End
  Backspace
  Tab
  Enter
  Escape
  Delete
  Insert
  F1
  F2
  F3
  F4
  F5
  F6
  F7
  F8
  F9
  F10
  F11
  F12
  CapsLock
  NumLock
  ScrollLock
  PrintScreen
  Pause
  Shift
  Control
  Alt
  Meta
  Char(String)
}

pub type KeyEventType {
  KeyPress
  KeyDown
  KeyUp
}

pub type PadInput {
  Up
  Down
  Left
  Right
  ActionA
  ActionB
}

pub const up = Up

pub const down = Down

pub const left = Left

pub const right = Right

pub const action_a = ActionA

pub const action_b = ActionB

pub type OnTick(a) =
  fn(a) -> a

pub type StopWhen(a) =
  fn(a) -> Bool

pub type OnKey(a) =
  fn(a, Key) -> a

pub type OnPad(a) =
  fn(a, PadInput) -> a

pub type ToImage(a) =
  fn(a) -> Image

const min_tick_rate = 1

const max_tick_rate = 100

const default_tick_rate = 28

const ms_per_second = 1000

const event_polling_delay = 10

pub opaque type World(a) {
  World(
    state: a,
    to_image: ToImage(a),
    rate: Int,
    on_tick: Option(OnTick(a)),
    stop_when: Option(StopWhen(a)),
    on_key_press: Option(OnKey(a)),
    on_key_down: Option(OnKey(a)),
    on_key_up: Option(OnKey(a)),
    on_pad_down: Option(OnPad(a)),
    on_pad_up: Option(OnPad(a)),
  )
}

pub fn create(state: a, to_image: ToImage(a)) -> World(a) {
  World(
    state:,
    to_image:,
    rate: default_tick_rate,
    on_tick: None,
    stop_when: None,
    on_key_press: None,
    on_key_down: None,
    on_key_up: None,
    on_pad_down: None,
    on_pad_up: None,
  )
}

pub fn tick_rate(world: World(a), rate: Int) -> World(a) {
  World(..world, rate: int.clamp(rate, min_tick_rate, max_tick_rate))
}

pub fn on_tick(world: World(a), handler: OnTick(a)) -> World(a) {
  World(..world, on_tick: Some(handler))
}

pub fn stop_when(world: World(a), handler: StopWhen(a)) -> World(a) {
  World(..world, stop_when: Some(handler))
}

pub fn on_key_press(world: World(a), handler: OnKey(a)) -> World(a) {
  World(..world, on_key_press: Some(handler))
}

pub fn on_key_down(world: World(a), handler: OnKey(a)) -> World(a) {
  World(..world, on_key_down: Some(handler))
}

pub fn on_key_up(world: World(a), handler: OnKey(a)) -> World(a) {
  World(..world, on_key_up: Some(handler))
}

pub fn on_pad_down(world: World(a), handler: OnPad(a)) -> World(a) {
  World(..world, on_pad_down: Some(handler))
}

pub fn on_pad_up(world: World(a), handler: OnPad(a)) -> World(a) {
  World(..world, on_pad_up: Some(handler))
}

pub fn run(world: World(a)) {
  show_svg(world)
  let period = ms_per_second / world.rate
  run_loop(world, system.now_ms() + period)
}

type RuntimeEvent {
  KeyPressInput(Key)
  KeyDownInput(Key)
  KeyUpInput(Key)
  PadDownInput(PadInput)
  PadUpInput(PadInput)
  NoEvent
}

fn run_loop(world: World(a), next_tick_at: Int) {
  let now = system.now_ms()
  let #(world, next_tick_at) = case now >= next_tick_at {
    True -> {
      let world = case world.on_tick {
        Some(on_tick) -> {
          let world = World(..world, state: on_tick(world.state))
          show_svg(world)
          world
        }
        None -> world
      }
      // Schedule from the deadline (not from now) to absorb minor
      // overruns without drift. If we overran by more than a full
      // period, snap forward so we don't burn ticks catching up.
      let period = ms_per_second / world.rate
      let bumped = next_tick_at + period
      let next = case bumped <= now {
        True -> now + period
        False -> bumped
      }
      #(world, next)
    }
    False -> #(world, next_tick_at)
  }
  let #(world, handled) = apply_event(world, get_event())
  case handled {
    True -> show_svg(world)
    False -> Nil
  }
  case world.stop_when |> option.map(fn(f) { f(world.state) }) {
    Some(True) -> show_svg(world)
    _ -> {
      let wait = int.min(next_tick_at - system.now_ms(), event_polling_delay)
      case wait > 0 {
        True -> system.sleep(wait)
        False -> Nil
      }
      run_loop(world, next_tick_at)
    }
  }
}

fn apply_event(world: World(a), event: RuntimeEvent) -> #(World(a), Bool) {
  case event {
    KeyPressInput(key) -> apply_key_handler(world, key, world.on_key_press)
    KeyDownInput(key) ->
      apply_key_or_pad_handler(world, key, world.on_key_down, world.on_pad_down)
    KeyUpInput(key) ->
      apply_key_or_pad_handler(world, key, world.on_key_up, world.on_pad_up)
    PadDownInput(input) -> apply_pad_handler(world, input, world.on_pad_down)
    PadUpInput(input) -> apply_pad_handler(world, input, world.on_pad_up)
    NoEvent -> #(world, False)
  }
}

fn apply_key_or_pad_handler(
  world: World(a),
  key: Key,
  key_handler: Option(OnKey(a)),
  pad_handler: Option(OnPad(a)),
) -> #(World(a), Bool) {
  case pad_input_from_key(key), pad_handler {
    Some(input), Some(handler) -> #(
      World(..world, state: handler(world.state, input)),
      True,
    )
    _, _ -> apply_key_handler(world, key, key_handler)
  }
}

fn apply_key_handler(
  world: World(a),
  key: Key,
  handler: Option(OnKey(a)),
) -> #(World(a), Bool) {
  case handler {
    Some(handler) -> #(World(..world, state: handler(world.state, key)), True)
    None -> #(world, False)
  }
}

fn apply_pad_handler(
  world: World(a),
  input: PadInput,
  handler: Option(OnPad(a)),
) -> #(World(a), Bool) {
  case handler {
    Some(handler) -> #(World(..world, state: handler(world.state, input)), True)
    None -> #(world, False)
  }
}

fn show_svg(world: World(a)) {
  world.state |> world.to_image |> image.to_svg |> system.show_svg
}

fn get_event() -> RuntimeEvent {
  case system.get_event() {
    ["keypress", _player, key, ..] -> KeyPressInput(key_from_string(key))
    ["keydown", _player, key, ..] -> KeyDownInput(key_from_string(key))
    ["keyup", _player, key, ..] -> KeyUpInput(key_from_string(key))
    ["paddown", _player, input] ->
      pad_input_from_string(input)
      |> option.map(PadDownInput)
      |> option.unwrap(NoEvent)
    ["padup", _player, input] ->
      pad_input_from_string(input)
      |> option.map(PadUpInput)
      |> option.unwrap(NoEvent)
    _ -> NoEvent
  }
}

@internal
pub fn pad_input_from_string(input: String) -> Option(PadInput) {
  case input {
    "Up" -> Some(Up)
    "Down" -> Some(Down)
    "Left" -> Some(Left)
    "Right" -> Some(Right)
    "ActionA" -> Some(ActionA)
    "ActionB" -> Some(ActionB)
    _ -> None
  }
}

@internal
pub fn pad_input_from_key(key: Key) -> Option(PadInput) {
  case key {
    ArrowUp | Char("w") | Char("W") -> Some(Up)
    ArrowDown | Char("s") | Char("S") -> Some(Down)
    ArrowLeft | Char("a") | Char("A") -> Some(Left)
    ArrowRight | Char("d") | Char("D") -> Some(Right)
    Char("z") | Char("Z") | Char("k") | Char("K") -> Some(ActionA)
    Char("x") | Char("X") | Char("l") | Char("L") -> Some(ActionB)
    _ -> None
  }
}

@internal
pub fn key_from_string(key: String) -> Key {
  case key {
    "ArrowLeft" -> ArrowLeft
    "ArrowRight" -> ArrowRight
    "ArrowUp" -> ArrowUp
    "ArrowDown" -> ArrowDown
    "PageUp" -> PageUp
    "PageDown" -> PageDown
    "Home" -> Home
    "End" -> End
    "Backspace" -> Backspace
    "Tab" -> Tab
    "Enter" -> Enter
    "Escape" -> Escape
    "Delete" -> Delete
    "Insert" -> Insert
    "F1" -> F1
    "F2" -> F2
    "F3" -> F3
    "F4" -> F4
    "F5" -> F5
    "F6" -> F6
    "F7" -> F7
    "F8" -> F8
    "F9" -> F9
    "F10" -> F10
    "F11" -> F11
    "F12" -> F12
    "CapsLock" -> CapsLock
    "NumLock" -> NumLock
    "ScrollLock" -> ScrollLock
    "PrintScreen" -> PrintScreen
    "Pause" -> Pause
    "Shift" -> Shift
    "Control" -> Control
    "Alt" -> Alt
    "Meta" -> Meta
    other -> Char(other)
  }
}
