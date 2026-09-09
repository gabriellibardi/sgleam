import gleam/int
import sgleam/fill
import sgleam/image
import sgleam/mworld

const width = 500

const height = 200

const square_size = 30

const step = 10

type State {
  State(player_one_x: Int, player_two_x: Int)
}

pub fn main() {
  mworld.create(State(width / 3, width * 2 / 3), min: 2, max: 2, to_image: draw)
  |> mworld.on_pad_down(move_player)
  |> mworld.on_player_join(reset_player)
  |> mworld.on_player_leave(reset_player)
  |> mworld.run()
}

fn draw(state: State, player: mworld.Player) -> image.Image {
  let #(own_x, other_x) = case mworld.player_index(player) {
    1 -> #(state.player_one_x, state.player_two_x)
    _ -> #(state.player_two_x, state.player_one_x)
  }
  image.empty_scene(width, height)
  |> image.place_image(
    other_x,
    height / 3,
    image.square(square_size, fill.gray),
  )
  |> image.place_image(
    own_x,
    height * 2 / 3,
    image.square(square_size, fill.blue),
  )
}

fn move_player(
  state: State,
  player: mworld.Player,
  input: mworld.PadInput,
) -> State {
  case mworld.player_index(player) {
    1 -> State(..state, player_one_x: move_x(state.player_one_x, input))
    2 -> State(..state, player_two_x: move_x(state.player_two_x, input))
    _ -> state
  }
}

fn move_x(x: Int, input: mworld.PadInput) -> Int {
  let x = case input {
    input if input == mworld.left -> x - step
    input if input == mworld.right -> x + step
    input if input == mworld.action_a -> width / 2
    _ -> x
  }
  int.clamp(x, square_size / 2, width - square_size / 2)
}

fn reset_player(state: State, player: mworld.Player) -> State {
  case mworld.player_index(player) {
    1 -> State(..state, player_one_x: width / 3)
    2 -> State(..state, player_two_x: width * 2 / 3)
    _ -> state
  }
}
