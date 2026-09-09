import gleam/int
import sgleam/fill
import sgleam/image
import sgleam/world

const width = 400

const height = 240

const square_size = 30

const step = 10

type State {
  State(x: Int, y: Int, action_pressed: Bool)
}

pub fn main() {
  world.create(State(width / 2, height / 2, False), draw)
  |> world.on_pad_down(pad_down)
  |> world.on_pad_up(pad_up)
  |> world.run()
}

fn draw(state: State) -> image.Image {
  let square_fill = case state.action_pressed {
    True -> fill.gold
    False -> fill.blue
  }
  image.empty_scene(width, height)
  |> image.place_image(state.x, state.y, image.square(square_size, square_fill))
}

fn pad_down(state: State, input: world.PadInput) -> State {
  case input {
    world.Up -> State(..state, y: clamp_y(state.y - step))
    world.Down -> State(..state, y: clamp_y(state.y + step))
    world.Left -> State(..state, x: clamp_x(state.x - step))
    world.Right -> State(..state, x: clamp_x(state.x + step))
    world.ActionA -> State(..state, action_pressed: True)
    world.ActionB -> State(width / 2, height / 2, False)
  }
}

fn pad_up(state: State, input: world.PadInput) -> State {
  case input {
    world.ActionA -> State(..state, action_pressed: False)
    _ -> state
  }
}

fn clamp_x(x: Int) -> Int {
  int.clamp(x, square_size / 2, width - square_size / 2)
}

fn clamp_y(y: Int) -> Int {
  int.clamp(y, square_size / 2, height - square_size / 2)
}
