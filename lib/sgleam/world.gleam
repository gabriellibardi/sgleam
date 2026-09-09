import gleam/int
import gleam/list
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

pub type PadEvent {
  PadEvent(event_type: PadEventType, input: PadInput)
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

pub type PadEventType {
  PadDown
  PadUp
}

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

// Shared representation behind World and MultiWorld. It is public only
// inside this package so mworld can reuse it without exposing implementation
// details to programs.
@internal
pub type BaseWorld(a, player) {
  BaseWorld(
    state: a,
    to_image: fn(a, player) -> Image,
    rate: Int,
    min_players: Int,
    max_players: Int,
    players: List(player),
    on_tick: Option(fn(a) -> a),
    stop_when: Option(fn(a) -> Bool),
    on_key_press: Option(fn(a, player, Key) -> a),
    on_key_down: Option(fn(a, player, Key) -> a),
    on_key_up: Option(fn(a, player, Key) -> a),
    on_pad_down: Option(fn(a, player, PadInput) -> a),
    on_pad_up: Option(fn(a, player, PadInput) -> a),
    on_player_join: Option(fn(a, player) -> a),
    on_player_leave: Option(fn(a, player) -> a),
  )
}

@internal
pub fn base_world(
  state: a,
  to_image: fn(a, player) -> Image,
  min_players: Int,
  max_players: Int,
  players: List(player),
) -> BaseWorld(a, player) {
  let min_players = int.max(1, min_players)
  let max_players = int.max(min_players, max_players)
  BaseWorld(
    state:,
    to_image:,
    rate: default_tick_rate,
    min_players:,
    max_players:,
    players:,
    on_tick: None,
    stop_when: None,
    on_key_press: None,
    on_key_down: None,
    on_key_up: None,
    on_pad_down: None,
    on_pad_up: None,
    on_player_join: None,
    on_player_leave: None,
  )
}

pub opaque type World(a) {
  World(BaseWorld(a, Nil))
}

pub fn create(state: a, to_image: ToImage(a)) -> World(a) {
  World(base_world(state, fn(state, _player) { to_image(state) }, 1, 1, [Nil]))
}

pub fn tick_rate(world: World(a), rate: Int) -> World(a) {
  let World(base) = world
  World(BaseWorld(..base, rate: int.clamp(rate, min_tick_rate, max_tick_rate)))
}

pub fn on_tick(world: World(a), handler: OnTick(a)) -> World(a) {
  let World(base) = world
  World(BaseWorld(..base, on_tick: Some(handler)))
}

pub fn stop_when(world: World(a), handler: StopWhen(a)) -> World(a) {
  let World(base) = world
  World(BaseWorld(..base, stop_when: Some(handler)))
}

pub fn on_key_press(world: World(a), handler: OnKey(a)) -> World(a) {
  let World(base) = world
  let adapted = fn(state, _player, key) { handler(state, key) }
  World(BaseWorld(..base, on_key_press: Some(adapted)))
}

pub fn on_key_down(world: World(a), handler: OnKey(a)) -> World(a) {
  let World(base) = world
  let adapted = fn(state, _player, key) { handler(state, key) }
  World(BaseWorld(..base, on_key_down: Some(adapted)))
}

pub fn on_key_up(world: World(a), handler: OnKey(a)) -> World(a) {
  let World(base) = world
  let adapted = fn(state, _player, key) { handler(state, key) }
  World(BaseWorld(..base, on_key_up: Some(adapted)))
}

pub fn on_pad_down(world: World(a), handler: OnPad(a)) -> World(a) {
  let World(base) = world
  let adapted = fn(state, _player, input) { handler(state, input) }
  World(BaseWorld(..base, on_pad_down: Some(adapted)))
}

pub fn on_pad_up(world: World(a), handler: OnPad(a)) -> World(a) {
  let World(base) = world
  let adapted = fn(state, _player, input) { handler(state, input) }
  World(BaseWorld(..base, on_pad_up: Some(adapted)))
}

pub fn run(world: World(a)) {
  let World(base) = world
  show_svg(base)
  let period = ms_per_second / base.rate
  run_loop(base, system.now_ms() + period)
}

fn run_loop(base: BaseWorld(a, Nil), next_tick_at: Int) {
  let now = system.now_ms()
  let #(base, next_tick_at) = case now >= next_tick_at {
    True -> {
      let base = case base.on_tick {
        Some(on_tick) -> {
          let base = BaseWorld(..base, state: on_tick(base.state))
          show_svg(base)
          base
        }
        None -> base
      }
      // Schedule from the deadline (not from now) to absorb minor
      // overruns without drift. If we overran by more than a full
      // period, snap forward so we don't burn ticks catching up.
      let period = ms_per_second / base.rate
      let bumped = next_tick_at + period
      let next = case bumped <= now {
        True -> now + period
        False -> bumped
      }
      #(base, next)
    }
    False -> #(base, next_tick_at)
  }
  let event = get_key_event()
  let #(base, h1) = case base.on_key_down, event {
    Some(handler), Some(event) if event.event_type == KeyDown -> #(
      BaseWorld(..base, state: handler(base.state, Nil, event.key)),
      True,
    )
    _, _ -> #(base, False)
  }
  let #(base, h2) = case base.on_key_press, event {
    Some(handler), Some(event) if event.event_type == KeyPress -> #(
      BaseWorld(..base, state: handler(base.state, Nil, event.key)),
      True,
    )
    _, _ -> #(base, False)
  }
  let #(base, h3) = case base.on_key_up, event {
    Some(handler), Some(event) if event.event_type == KeyUp -> #(
      BaseWorld(..base, state: handler(base.state, Nil, event.key)),
      True,
    )
    _, _ -> #(base, False)
  }
  let event = get_pad_event()
  let #(base, h4) = case base.on_pad_down, event {
    Some(handler), Some(event) if event.event_type == PadDown -> #(
      BaseWorld(..base, state: handler(base.state, Nil, event.input)),
      True,
    )
    _, _ -> #(base, False)
  }
  let #(base, h5) = case base.on_pad_up, event {
    Some(handler), Some(event) if event.event_type == PadUp -> #(
      BaseWorld(..base, state: handler(base.state, Nil, event.input)),
      True,
    )
    _, _ -> #(base, False)
  }
  case h1 || h2 || h3 || h4 || h5 {
    True -> show_svg(base)
    False -> Nil
  }
  case base.stop_when |> option.map(fn(f) { f(base.state) }) {
    Some(True) -> show_svg(base)
    _ -> {
      let wait = int.min(next_tick_at - system.now_ms(), event_polling_delay)
      case wait > 0 {
        True -> system.sleep(wait)
        False -> Nil
      }
      run_loop(base, next_tick_at)
    }
  }
}

fn show_svg(base: BaseWorld(a, Nil)) {
  base.to_image(base.state, Nil) |> image.to_svg |> system.show_svg
}

fn get_key_event() -> Option(KeyEvent) {
  case system.get_key_event() {
    ["keypress", key, ..modifiers] ->
      Some(new_key_event(KeyPress, key, modifiers))
    ["keydown", key, ..modifiers] ->
      Some(new_key_event(KeyDown, key, modifiers))
    ["keyup", key, ..modifiers] -> Some(new_key_event(KeyUp, key, modifiers))
    _ -> None
  }
}

fn get_pad_event() -> Option(PadEvent) {
  case system.get_pad_event() {
    ["paddown", input] ->
      option.map(pad_input_from_string(input), fn(i) { PadEvent(PadDown, i) })
    ["padup", input] ->
      option.map(pad_input_from_string(input), fn(i) { PadEvent(PadUp, i) })
    _ -> None
  }
}

fn pad_input_from_string(input: String) -> Option(PadInput) {
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

fn new_key_event(
  event_type: KeyEventType,
  key: String,
  modifiers: List(String),
) -> KeyEvent {
  KeyEvent(
    event_type,
    key_from_string(key),
    alt: list.contains(modifiers, "alt"),
    ctrl: list.contains(modifiers, "ctrl"),
    shift: list.contains(modifiers, "shift"),
    meta: list.contains(modifiers, "meta"),
    repeat: list.contains(modifiers, "repeat"),
  )
}

fn key_from_string(key: String) -> Key {
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
