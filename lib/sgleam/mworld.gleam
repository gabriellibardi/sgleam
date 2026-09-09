import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import sgleam/image.{type Image}
import sgleam/system
import sgleam/world as single_world

pub type Key =
  single_world.Key

pub type PadInput =
  single_world.PadInput

pub const up = single_world.Up

pub const down = single_world.Down

pub const left = single_world.Left

pub const right = single_world.Right

pub const action_a = single_world.ActionA

pub const action_b = single_world.ActionB

pub opaque type Player {
  Player(index: Int)
}

pub fn player_index(player: Player) -> Int {
  player.index
}

pub fn same_player(first: Player, second: Player) -> Bool {
  first.index == second.index
}

pub type ToImage(a) =
  fn(a, Player) -> Image

pub type OnTick(a) =
  fn(a) -> a

pub type StopWhen(a) =
  fn(a) -> Bool

pub type OnKey(a) =
  fn(a, Player, Key) -> a

pub type OnPad(a) =
  fn(a, Player, PadInput) -> a

pub type OnPlayerEvent(a) =
  fn(a, Player) -> a

const min_tick_rate = 1

const max_tick_rate = 100

const event_polling_delay = 10

// Multiplayer specialization of the same base used by world.World. The
// state is shared by the match; only to_image receives a player so it can
// produce a different view for each participant.
pub opaque type MultiWorld(a) {
  MultiWorld(single_world.BaseWorld(a, Player))
}

pub fn create(
  state: a,
  min min_players: Int,
  max max_players: Int,
  to_image to_image: ToImage(a),
) -> MultiWorld(a) {
  MultiWorld(
    single_world.base_world(state, to_image, min_players, max_players, []),
  )
}

pub fn tick_rate(world: MultiWorld(a), rate: Int) -> MultiWorld(a) {
  let MultiWorld(base) = world
  MultiWorld(
    single_world.BaseWorld(
      ..base,
      rate: int.clamp(rate, min_tick_rate, max_tick_rate),
    ),
  )
}

pub fn on_tick(world: MultiWorld(a), handler: OnTick(a)) -> MultiWorld(a) {
  let MultiWorld(base) = world
  MultiWorld(single_world.BaseWorld(..base, on_tick: Some(handler)))
}

pub fn stop_when(world: MultiWorld(a), handler: StopWhen(a)) -> MultiWorld(a) {
  let MultiWorld(base) = world
  MultiWorld(single_world.BaseWorld(..base, stop_when: Some(handler)))
}

pub fn on_key_press(world: MultiWorld(a), handler: OnKey(a)) -> MultiWorld(a) {
  let MultiWorld(base) = world
  MultiWorld(single_world.BaseWorld(..base, on_key_press: Some(handler)))
}

pub fn on_key_down(world: MultiWorld(a), handler: OnKey(a)) -> MultiWorld(a) {
  let MultiWorld(base) = world
  MultiWorld(single_world.BaseWorld(..base, on_key_down: Some(handler)))
}

pub fn on_key_up(world: MultiWorld(a), handler: OnKey(a)) -> MultiWorld(a) {
  let MultiWorld(base) = world
  MultiWorld(single_world.BaseWorld(..base, on_key_up: Some(handler)))
}

pub fn on_pad_down(world: MultiWorld(a), handler: OnPad(a)) -> MultiWorld(a) {
  let MultiWorld(base) = world
  MultiWorld(single_world.BaseWorld(..base, on_pad_down: Some(handler)))
}

pub fn on_pad_up(world: MultiWorld(a), handler: OnPad(a)) -> MultiWorld(a) {
  let MultiWorld(base) = world
  MultiWorld(single_world.BaseWorld(..base, on_pad_up: Some(handler)))
}

pub fn on_player_join(
  world: MultiWorld(a),
  handler: OnPlayerEvent(a),
) -> MultiWorld(a) {
  let MultiWorld(base) = world
  MultiWorld(single_world.BaseWorld(..base, on_player_join: Some(handler)))
}

pub fn on_player_leave(
  world: MultiWorld(a),
  handler: OnPlayerEvent(a),
) -> MultiWorld(a) {
  let MultiWorld(base) = world
  MultiWorld(single_world.BaseWorld(..base, on_player_leave: Some(handler)))
}

pub fn run(world: MultiWorld(a)) {
  let MultiWorld(base) = world
  system.start_mworld(base.min_players, base.max_players, base.rate)
  run_loop(base)
}

type RuntimeEvent {
  PlayerJoin(Player)
  PlayerLeave(Player)
  Tick
  KeyPress(Player, Key)
  KeyDown(Player, Key)
  KeyUp(Player, Key)
  PadDown(Player, PadInput)
  PadUp(Player, PadInput)
  Close
  NoEvent
}

fn run_loop(base: single_world.BaseWorld(a, Player)) {
  let event = get_runtime_event()
  let #(base, changed) = apply_event(base, event)
  let stopped = base.stop_when |> option.map(fn(f) { f(base.state) })
  case event, stopped {
    Close, _ -> system.stop_mworld()
    _, Some(True) -> {
      show_players(base)
      system.stop_mworld()
    }
    _, _ -> {
      case changed {
        True -> show_players(base)
        False -> Nil
      }
      case event {
        NoEvent -> system.sleep(event_polling_delay)
        _ -> Nil
      }
      run_loop(base)
    }
  }
}

fn apply_event(
  base: single_world.BaseWorld(a, Player),
  event: RuntimeEvent,
) -> #(single_world.BaseWorld(a, Player), Bool) {
  case event {
    PlayerJoin(player) -> join_player(base, player)
    PlayerLeave(player) -> leave_player(base, player)
    Tick ->
      case base.on_tick, list.length(base.players) >= base.min_players {
        Some(handler), True -> #(
          single_world.BaseWorld(..base, state: handler(base.state)),
          True,
        )
        _, _ -> #(base, False)
      }
    KeyPress(player, key) ->
      apply_player_handler(base, player, key, base.on_key_press)
    KeyDown(player, key) ->
      apply_player_handler(base, player, key, base.on_key_down)
    KeyUp(player, key) ->
      apply_player_handler(base, player, key, base.on_key_up)
    PadDown(player, input) ->
      apply_player_handler(base, player, input, base.on_pad_down)
    PadUp(player, input) ->
      apply_player_handler(base, player, input, base.on_pad_up)
    Close | NoEvent -> #(base, False)
  }
}

fn join_player(
  base: single_world.BaseWorld(a, Player),
  player: Player,
) -> #(single_world.BaseWorld(a, Player), Bool) {
  let known = find_player(base.players, player.index)
  case known, list.length(base.players) < base.max_players {
    None, True -> {
      let state = case base.on_player_join {
        Some(handler) -> handler(base.state, player)
        None -> base.state
      }
      #(
        single_world.BaseWorld(
          ..base,
          state:,
          players: list.append(base.players, [player]),
        ),
        True,
      )
    }
    _, _ -> #(base, False)
  }
}

fn leave_player(
  base: single_world.BaseWorld(a, Player),
  player: Player,
) -> #(single_world.BaseWorld(a, Player), Bool) {
  case find_player(base.players, player.index) {
    None -> #(base, False)
    Some(player) -> {
      let state = case base.on_player_leave {
        Some(handler) -> handler(base.state, player)
        None -> base.state
      }
      #(
        single_world.BaseWorld(
          ..base,
          state:,
          players: list.filter(base.players, fn(current) {
            !same_player(current, player)
          }),
        ),
        True,
      )
    }
  }
}

fn apply_player_handler(
  base: single_world.BaseWorld(a, Player),
  player: Player,
  input: input,
  handler: Option(fn(a, Player, input) -> a),
) -> #(single_world.BaseWorld(a, Player), Bool) {
  case find_player(base.players, player.index), handler {
    Some(player), Some(handler) -> #(
      single_world.BaseWorld(..base, state: handler(base.state, player, input)),
      True,
    )
    _, _ -> #(base, False)
  }
}

fn find_player(players: List(Player), index: Int) -> Option(Player) {
  case list.filter(players, fn(player) { player.index == index }) {
    [player, ..] -> Some(player)
    [] -> None
  }
}

fn show_players(base: single_world.BaseWorld(a, Player)) {
  list.each(base.players, fn(player) {
    base.to_image(base.state, player)
    |> image.to_svg
    |> fn(svg) { system.show_player_svg(player.index, svg) }
  })
}

fn get_runtime_event() -> RuntimeEvent {
  case system.get_mworld_event() {
    ["join", player] -> parse_player(player, PlayerJoin)
    ["leave", player] -> parse_player(player, PlayerLeave)
    ["tick"] -> Tick
    ["keypress", player, key, ..] ->
      parse_player_input(player, key_from_string(key), KeyPress)
    ["keydown", player, key, ..] ->
      parse_player_input(player, key_from_string(key), KeyDown)
    ["keyup", player, key, ..] ->
      parse_player_input(player, key_from_string(key), KeyUp)
    ["paddown", player, input] -> parse_pad_event(player, input, PadDown)
    ["padup", player, input] -> parse_pad_event(player, input, PadUp)
    ["close"] -> Close
    _ -> NoEvent
  }
}

fn parse_player(
  value: String,
  event: fn(Player) -> RuntimeEvent,
) -> RuntimeEvent {
  case int.parse(value) {
    Ok(index) if index > 0 -> event(Player(index))
    _ -> NoEvent
  }
}

fn parse_player_input(
  value: String,
  input: input,
  event: fn(Player, input) -> RuntimeEvent,
) -> RuntimeEvent {
  case int.parse(value) {
    Ok(index) if index > 0 -> event(Player(index), input)
    _ -> NoEvent
  }
}

fn parse_pad_event(
  player: String,
  input: String,
  event: fn(Player, PadInput) -> RuntimeEvent,
) -> RuntimeEvent {
  case pad_input_from_string(input) {
    Some(input) -> parse_player_input(player, input, event)
    None -> NoEvent
  }
}

fn pad_input_from_string(input: String) -> Option(PadInput) {
  case input {
    "Up" -> Some(single_world.Up)
    "Down" -> Some(single_world.Down)
    "Left" -> Some(single_world.Left)
    "Right" -> Some(single_world.Right)
    "ActionA" -> Some(single_world.ActionA)
    "ActionB" -> Some(single_world.ActionB)
    _ -> None
  }
}

fn key_from_string(key: String) -> Key {
  case key {
    "ArrowLeft" -> single_world.ArrowLeft
    "ArrowRight" -> single_world.ArrowRight
    "ArrowUp" -> single_world.ArrowUp
    "ArrowDown" -> single_world.ArrowDown
    "PageUp" -> single_world.PageUp
    "PageDown" -> single_world.PageDown
    "Home" -> single_world.Home
    "End" -> single_world.End
    "Backspace" -> single_world.Backspace
    "Tab" -> single_world.Tab
    "Enter" -> single_world.Enter
    "Escape" -> single_world.Escape
    "Delete" -> single_world.Delete
    "Insert" -> single_world.Insert
    "F1" -> single_world.F1
    "F2" -> single_world.F2
    "F3" -> single_world.F3
    "F4" -> single_world.F4
    "F5" -> single_world.F5
    "F6" -> single_world.F6
    "F7" -> single_world.F7
    "F8" -> single_world.F8
    "F9" -> single_world.F9
    "F10" -> single_world.F10
    "F11" -> single_world.F11
    "F12" -> single_world.F12
    "CapsLock" -> single_world.CapsLock
    "NumLock" -> single_world.NumLock
    "ScrollLock" -> single_world.ScrollLock
    "PrintScreen" -> single_world.PrintScreen
    "Pause" -> single_world.Pause
    "Shift" -> single_world.Shift
    "Control" -> single_world.Control
    "Alt" -> single_world.Alt
    "Meta" -> single_world.Meta
    other -> single_world.Char(other)
  }
}
