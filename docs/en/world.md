# Interactive Programs

The `sgleam/world`{.gleam} module allows you to create animations and interactive programs using the "world" (big-bang) pattern: a state is transformed into an image, and user events produce a new state.

```gleam
import sgleam/world
import sgleam/image
```


## Concept

An interactive program is defined by:

1. **Initial state**: any Gleam value
2. **Drawing function**: transforms the state into an image
3. **Event functions** (optional): update the state in response to clock ticks, keyboard input, or virtual pad input
4. **Stop condition** (optional): defines when the program should stop


## Creating a world

```gleam
world.create(initial_state, drawing_function)
|> world.on_tick(tick_function)
|> world.on_key_press(key_function)
|> world.run()
```


## Simple animation

To create an animation without user interaction, use `world.animate`{.gleam}:

```gleam
import sgleam/fill
import sgleam/image
import sgleam/world

pub fn main() {
  world.animate(draw)
}

const max = 200

fn draw(n: Int) {
  let n = n % max
  let n = case n < max / 2 {
    True -> n
    False -> max - n
  }
  image.empty_scene(max, max)
  |> image.overlay(image.circle(n, fill.red))
}
```

The function receives the frame number (starting at 0) and returns the image to be displayed.


## Complete example: bouncing ball

```gleam
import gleam/int
import sgleam/fill
import sgleam/image
import sgleam/world

const width = 600
const height = 400
const radius = 20

type Ball {
  Ball(x: Int, y: Int, vx: Int, vy: Int)
}

pub fn main() {
  world.create(Ball(100, 100, 3, 4), draw)
  |> world.on_tick(tick)
  |> world.on_key_down(on_key)
  |> world.run()
}

fn draw(ball: Ball) -> image.Image {
  image.empty_scene(width, height)
  |> image.place_image(ball.x, ball.y, image.circle(radius, fill.red))
}

fn tick(ball: Ball) -> Ball {
  let x = ball.x + ball.vx
  let y = ball.y + ball.vy
  let vx = case x < radius || x > width - radius {
    True -> 0 - ball.vx
    False -> ball.vx
  }
  let vy = case y < radius || y > height - radius {
    True -> 0 - ball.vy
    False -> ball.vy
  }
  Ball(x, y, vx, vy)
}

fn on_key(ball: Ball, key: world.Key) -> Ball {
  case key {
    world.Char("r") -> Ball(100, 100, 3, 4)
    _ -> ball
  }
}
```


## API reference

### Creation

```gleam
world.create(state, to_image)
```
Creates a world with an initial state and a drawing function.

```gleam
world.animate(fn(Int) -> Image)
```
Creates an animation (receives the frame number).

### Configuration

```gleam
world.tick_rate(world, rate)
```
Sets the on_tick call frequency (1 to 100 per second, default 28).

```gleam
world.on_tick(world, fn(a) -> a)
```
Sets the function called on each tick.

```gleam
world.stop_when(world, fn(a) -> Bool)
```
Sets the stop condition.

### Keyboard events

```gleam
world.on_key_press(world, fn(a, Key) -> a)
```
Key typed (character).

```gleam
world.on_key_down(world, fn(a, Key) -> a)
```
Key pressed down.

```gleam
world.on_key_up(world, fn(a, Key) -> a)
```
Key released.

### Virtual pad events

```gleam
world.on_pad_down(world, fn(a, PadInput) -> a)
```
Pad button or equivalent keyboard key pressed.

```gleam
world.on_pad_up(world, fn(a, PadInput) -> a)
```
Pad button or equivalent keyboard key released.

### Execution

```gleam
world.run(world)
```
Starts the interactive program.

### Keys

Keys are represented by the `world.Key`{.gleam} type:

| Key | Value |
|-----|-------|
| Arrows | `ArrowLeft`{.gleam}, `ArrowRight`{.gleam}, `ArrowUp`{.gleam}, `ArrowDown`{.gleam} |
| Enter | `Enter`{.gleam} |
| Space | `Char(" ")`{.gleam} |
| Escape | `Escape`{.gleam} |
| Letters/numbers | `Char("a")`{.gleam}, `Char("1")`{.gleam}, etc. |
| Function keys | `F1`{.gleam} to `F12`{.gleam} |
| Others | `Backspace`{.gleam}, `Tab`{.gleam}, `Delete`{.gleam}, `Home`{.gleam}, `End`{.gleam}, `PageUp`{.gleam}, `PageDown`{.gleam} |

### Pad inputs

The `world.PadInput`{.gleam} type provides `Up`{.gleam}, `Down`{.gleam},
`Left`{.gleam}, `Right`{.gleam}, `ActionA`{.gleam}, and
`ActionB`{.gleam}. The lowercase constants `world.up`{.gleam},
`world.down`{.gleam}, `world.left`{.gleam}, `world.right`{.gleam},
`world.action_a`{.gleam}, and `world.action_b`{.gleam} represent the same
inputs.

Use keyboard events when a game should depend on specific keys. To make a game
controllable with either the keyboard or the virtual pad, implement only the
pad events. Sgleam applies this standard mapping:

| Pad input | Equivalent keys |
|-----------|-----------------|
| `Up`{.gleam} | up arrow, W |
| `Down`{.gleam} | down arrow, S |
| `Left`{.gleam} | left arrow, A |
| `Right`{.gleam} | right arrow, D |
| `ActionA`{.gleam} | Z, K |
| `ActionB`{.gleam} | X, L |

When a matching pad handler is present, a mapped key is delivered to it instead
of the keyboard handler. Unmapped keys continue to reach keyboard handlers. The
numeric keypad is not part of the mapping yet.


## Multiplayer worlds

The `sgleam/mworld`{.gleam} module keeps one shared state for the match. Each
input event identifies the player that produced it, and the drawing function
receives an `mworld.Player`{.gleam} so it can produce that participant's view.

```gleam
import sgleam/image
import sgleam/mworld

pub fn main() {
  mworld.create(
    initial_state,
    min: 2,
    max: 4,
    to_image: draw,
  )
  |> mworld.on_pad_down(pad)
  |> mworld.run()
}

fn draw(state, player: mworld.Player) -> image.Image {
  // mworld.player_index(player) can select the player's perspective.
  todo
}

fn pad(state, player: mworld.Player, input: mworld.PadInput) {
  todo
}
```

`mworld.on_tick`{.gleam} and `mworld.stop_when`{.gleam} operate on the shared
state. `mworld.on_player_join`{.gleam} and
`mworld.on_player_leave`{.gleam} handle the participant lifecycle. Use
`mworld.player_index`{.gleam} to obtain a player's stable index and
`mworld.same_player`{.gleam} to compare two identities.

In multiplayer mode the host controls the ordered event queue, reports input
and connection events, and sends ticks to the world. Whenever state changes,
the game sends the host one SVG for each connected player. The same keyboard to
pad mapping also applies to `mworld`{.gleam}.
