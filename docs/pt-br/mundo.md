# Programas Interativos

O módulo `sgleam/world`{.gleam} permite criar animações e programas interativos usando o padrão "mundo" (big-bang): um estado é transformado em uma imagem, e eventos do usuário produzem um novo estado.

```gleam
import sgleam/world
import sgleam/image
```


## Conceito

Um programa interativo é definido por:

1. **Estado inicial**: qualquer valor Gleam
2. **Função de desenho**: transforma o estado em uma imagem
3. **Funções de evento** (opcionais): atualizam o estado em resposta a ticks do relógio, teclado ou pad virtual
4. **Condição de parada** (opcional): define quando o programa deve parar


## Criando um mundo

```gleam
world.create(estado_inicial, funcao_de_desenho)
|> world.on_tick(funcao_de_tick)
|> world.on_key_press(funcao_de_tecla)
|> world.run()
```


## Animação simples

Para criar uma animação sem interação do usuário, use `world.animate`{.gleam}:

```gleam
import sgleam/fill
import sgleam/image
import sgleam/world

pub fn main() {
  world.animate(desenho)
}

const max = 200

fn desenho(n: Int) {
  let n = n % max
  let n = case n < max / 2 {
    True -> n
    False -> max - n
  }
  image.empty_scene(max, max)
  |> image.overlay(image.circle(n, fill.red))
}
```

A função recebe o número do quadro (iniciando em 0) e retorna a imagem a ser exibida.


## Exemplo completo: bola quicando

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


## API de referência

### Criação

```gleam
world.create(state, to_image)
```
Cria um mundo com estado inicial e função de desenho.

```gleam
world.animate(fn(Int) -> Image)
```
Cria uma animação (recebe o número do quadro).

### Configuração

```gleam
world.tick_rate(world, rate)
```
Define a frequência de chamada de on_tick (1 a 100 por segundo, padrão 28).

```gleam
world.on_tick(world, fn(a) -> a)
```
Define a função chamada a cada tick.

```gleam
world.stop_when(world, fn(a) -> Bool)
```
Define a condição de parada.

### Eventos de teclado

```gleam
world.on_key_press(world, fn(a, Key) -> a)
```
Tecla digitada (caractere).

```gleam
world.on_key_down(world, fn(a, Key) -> a)
```
Tecla pressionada.

```gleam
world.on_key_up(world, fn(a, Key) -> a)
```
Tecla solta.

### Eventos do pad virtual

```gleam
world.on_pad_down(world, fn(a, PadInput) -> a)
```
Botão do pad pressionado ou tecla equivalente pressionada.

```gleam
world.on_pad_up(world, fn(a, PadInput) -> a)
```
Botão do pad solto ou tecla equivalente solta.

### Execução

```gleam
world.run(world)
```
Inicia o programa interativo.

### Teclas

As teclas são representadas pelo tipo `world.Key`{.gleam}:

| Tecla | Valor |
|-------|-------|
| Setas | `ArrowLeft`{.gleam}, `ArrowRight`{.gleam}, `ArrowUp`{.gleam}, `ArrowDown`{.gleam} |
| Enter | `Enter`{.gleam} |
| Espaço | `Char(" ")`{.gleam} |
| Escape | `Escape`{.gleam} |
| Letras/números | `Char("a")`{.gleam}, `Char("1")`{.gleam}, etc. |
| Funções | `F1`{.gleam} a `F12`{.gleam} |
| Outros | `Backspace`{.gleam}, `Tab`{.gleam}, `Delete`{.gleam}, `Home`{.gleam}, `End`{.gleam}, `PageUp`{.gleam}, `PageDown`{.gleam} |

### Entradas do pad

O tipo `world.PadInput`{.gleam} oferece `Up`{.gleam}, `Down`{.gleam},
`Left`{.gleam}, `Right`{.gleam}, `ActionA`{.gleam} e
`ActionB`{.gleam}. As constantes minúsculas `world.up`{.gleam},
`world.down`{.gleam}, `world.left`{.gleam}, `world.right`{.gleam},
`world.action_a`{.gleam} e `world.action_b`{.gleam} representam as mesmas
entradas.

Use os eventos de teclado quando o jogo deve depender de teclas específicas.
Para um jogo controlável tanto pelo teclado quanto pelo pad virtual, implemente
somente os eventos do pad. O sgleam aplica este mapeamento padrão:

| Entrada do pad | Teclas equivalentes |
|----------------|---------------------|
| `Up`{.gleam} | seta para cima, W |
| `Down`{.gleam} | seta para baixo, S |
| `Left`{.gleam} | seta para a esquerda, A |
| `Right`{.gleam} | seta para a direita, D |
| `ActionA`{.gleam} | Z, K |
| `ActionB`{.gleam} | X, L |

Quando há um handler de pad compatível, uma tecla mapeada é entregue a ele em
vez do handler de teclado. Teclas sem mapeamento continuam sendo entregues aos
handlers de teclado. O teclado numérico ainda não faz parte do mapeamento.


## Mundos multijogador

O módulo `sgleam/mworld`{.gleam} mantém um único estado compartilhado para a
partida. Cada evento de entrada informa o jogador que o produziu, e a função
de desenho recebe um `mworld.Player`{.gleam} para produzir a visão daquele
participante.

```gleam
import sgleam/image
import sgleam/mworld

pub fn main() {
  mworld.create(
    estado_inicial,
    min: 2,
    max: 4,
    to_image: desenhar,
  )
  |> mworld.on_pad_down(pad)
  |> mworld.run()
}

fn desenhar(estado, jogador: mworld.Player) -> image.Image {
  // Pode usar mworld.player_index(jogador) para escolher a perspectiva.
  todo
}

fn pad(estado, jogador: mworld.Player, entrada: mworld.PadInput) {
  todo
}
```

`mworld.on_tick`{.gleam} e `mworld.stop_when`{.gleam} operam sobre o estado
compartilhado. `mworld.on_player_join`{.gleam} e
`mworld.on_player_leave`{.gleam} tratam o ciclo de vida dos participantes.
Use `mworld.player_index`{.gleam} para obter o índice estável de um jogador e
`mworld.same_player`{.gleam} para comparar duas identidades.

No modo multijogador, o host controla a fila ordenada de eventos, informa
entradas e conexões e envia os ticks ao mundo. O jogo devolve ao host um SVG
para cada jogador conectado sempre que o estado muda. O mesmo mapeamento de
teclado para pad também vale para `mworld`{.gleam}.
