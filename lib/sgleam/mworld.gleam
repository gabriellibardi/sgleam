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

const default_tick_rate = 28

const event_polling_delay = 10

pub opaque type MultiWorld(a) {
  MultiWorld(
    state: a,
    to_image: ToImage(a),
    rate: Int,
    min_players: Int,
    max_players: Int,
    players: List(Player),
    on_tick: Option(OnTick(a)),
    stop_when: Option(StopWhen(a)),
    on_key_press: Option(OnKey(a)),
    on_key_down: Option(OnKey(a)),
    on_key_up: Option(OnKey(a)),
    on_pad_down: Option(OnPad(a)),
    on_pad_up: Option(OnPad(a)),
    on_player_join: Option(OnPlayerEvent(a)),
    on_player_leave: Option(OnPlayerEvent(a)),
  )
}

pub fn create(
  state: a,
  min min_players: Int,
  max max_players: Int,
  to_image to_image: ToImage(a),
) -> MultiWorld(a) {
  let min_players = int.max(1, min_players)
  let max_players = int.max(min_players, max_players)
  MultiWorld(
    state:,
    to_image:,
    rate: default_tick_rate,
    min_players:,
    max_players:,
    players: [],
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

pub fn tick_rate(world: MultiWorld(a), rate: Int) -> MultiWorld(a) {
  MultiWorld(..world, rate: int.clamp(rate, min_tick_rate, max_tick_rate))
}

pub fn on_tick(world: MultiWorld(a), handler: OnTick(a)) -> MultiWorld(a) {
  MultiWorld(..world, on_tick: Some(handler))
}

pub fn stop_when(world: MultiWorld(a), handler: StopWhen(a)) -> MultiWorld(a) {
  MultiWorld(..world, stop_when: Some(handler))
}

pub fn on_key_press(world: MultiWorld(a), handler: OnKey(a)) -> MultiWorld(a) {
  MultiWorld(..world, on_key_press: Some(handler))
}

pub fn on_key_down(world: MultiWorld(a), handler: OnKey(a)) -> MultiWorld(a) {
  MultiWorld(..world, on_key_down: Some(handler))
}

pub fn on_key_up(world: MultiWorld(a), handler: OnKey(a)) -> MultiWorld(a) {
  MultiWorld(..world, on_key_up: Some(handler))
}

pub fn on_pad_down(world: MultiWorld(a), handler: OnPad(a)) -> MultiWorld(a) {
  MultiWorld(..world, on_pad_down: Some(handler))
}

pub fn on_pad_up(world: MultiWorld(a), handler: OnPad(a)) -> MultiWorld(a) {
  MultiWorld(..world, on_pad_up: Some(handler))
}

pub fn on_player_join(
  world: MultiWorld(a),
  handler: OnPlayerEvent(a),
) -> MultiWorld(a) {
  MultiWorld(..world, on_player_join: Some(handler))
}

pub fn on_player_leave(
  world: MultiWorld(a),
  handler: OnPlayerEvent(a),
) -> MultiWorld(a) {
  MultiWorld(..world, on_player_leave: Some(handler))
}

pub fn run(world: MultiWorld(a)) {
  system.start_mworld(world.min_players, world.max_players, world.rate)
  run_loop(world)
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

fn run_loop(world: MultiWorld(a)) {
  let event = get_runtime_event()
  let #(world, changed) = apply_event(world, event)
  let stopped = world.stop_when |> option.map(fn(f) { f(world.state) })
  case event, stopped {
    Close, _ -> system.stop_mworld()
    _, Some(True) -> {
      show_players(world)
      system.stop_mworld()
    }
    _, _ -> {
      case changed {
        True -> show_players(world)
        False -> Nil
      }
      case event {
        NoEvent -> system.sleep(event_polling_delay)
        _ -> Nil
      }
      run_loop(world)
    }
  }
}

fn apply_event(
  world: MultiWorld(a),
  event: RuntimeEvent,
) -> #(MultiWorld(a), Bool) {
  case event {
    PlayerJoin(player) -> join_player(world, player)
    PlayerLeave(player) -> leave_player(world, player)
    Tick ->
      case world.on_tick, list.length(world.players) >= world.min_players {
        Some(handler), True -> #(
          MultiWorld(..world, state: handler(world.state)),
          True,
        )
        _, _ -> #(world, False)
      }
    KeyPress(player, key) ->
      apply_player_handler(world, player, key, world.on_key_press)
    KeyDown(player, key) ->
      apply_key_or_pad_handler(
        world,
        player,
        key,
        world.on_key_down,
        world.on_pad_down,
      )
    KeyUp(player, key) ->
      apply_key_or_pad_handler(
        world,
        player,
        key,
        world.on_key_up,
        world.on_pad_up,
      )
    PadDown(player, input) ->
      apply_player_handler(world, player, input, world.on_pad_down)
    PadUp(player, input) ->
      apply_player_handler(world, player, input, world.on_pad_up)
    Close | NoEvent -> #(world, False)
  }
}

fn join_player(world: MultiWorld(a), player: Player) -> #(MultiWorld(a), Bool) {
  let known = find_player(world.players, player.index)
  case known, list.length(world.players) < world.max_players {
    None, True -> {
      let state = case world.on_player_join {
        Some(handler) -> handler(world.state, player)
        None -> world.state
      }
      #(
        MultiWorld(
          ..world,
          state:,
          players: list.append(world.players, [player]),
        ),
        True,
      )
    }
    _, _ -> #(world, False)
  }
}

fn leave_player(
  world: MultiWorld(a),
  player: Player,
) -> #(MultiWorld(a), Bool) {
  case find_player(world.players, player.index) {
    None -> #(world, False)
    Some(player) -> {
      let state = case world.on_player_leave {
        Some(handler) -> handler(world.state, player)
        None -> world.state
      }
      #(
        MultiWorld(
          ..world,
          state:,
          players: list.filter(world.players, fn(current) {
            !same_player(current, player)
          }),
        ),
        True,
      )
    }
  }
}

fn apply_player_handler(
  world: MultiWorld(a),
  player: Player,
  input: input,
  handler: Option(fn(a, Player, input) -> a),
) -> #(MultiWorld(a), Bool) {
  case find_player(world.players, player.index), handler {
    Some(player), Some(handler) -> #(
      MultiWorld(..world, state: handler(world.state, player, input)),
      True,
    )
    _, _ -> #(world, False)
  }
}

fn apply_key_or_pad_handler(
  world: MultiWorld(a),
  player: Player,
  key: Key,
  key_handler: Option(OnKey(a)),
  pad_handler: Option(OnPad(a)),
) -> #(MultiWorld(a), Bool) {
  case single_world.pad_input_from_key(key), pad_handler {
    Some(input), Some(handler) ->
      apply_player_handler(world, player, input, Some(handler))
    _, _ -> apply_player_handler(world, player, key, key_handler)
  }
}

fn find_player(players: List(Player), index: Int) -> Option(Player) {
  case list.filter(players, fn(player) { player.index == index }) {
    [player, ..] -> Some(player)
    [] -> None
  }
}

fn show_players(world: MultiWorld(a)) {
  list.each(world.players, fn(player) {
    world.to_image(world.state, player)
    |> image.to_svg
    |> fn(svg) { system.show_player_svg(player.index, svg) }
  })
}

fn get_runtime_event() -> RuntimeEvent {
  case system.get_event() {
    ["join", player] -> parse_player(player, PlayerJoin)
    ["leave", player] -> parse_player(player, PlayerLeave)
    ["tick"] -> Tick
    ["keypress", player, key, ..] ->
      parse_player_input(player, single_world.key_from_string(key), KeyPress)
    ["keydown", player, key, ..] ->
      parse_player_input(player, single_world.key_from_string(key), KeyDown)
    ["keyup", player, key, ..] ->
      parse_player_input(player, single_world.key_from_string(key), KeyUp)
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
  case single_world.pad_input_from_string(input) {
    Some(input) -> parse_player_input(player, input, event)
    None -> NoEvent
  }
}
