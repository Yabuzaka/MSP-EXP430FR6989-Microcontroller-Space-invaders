# Space Invaders — MSP430 Assembly

A Space Invaders clone written **entirely in MSP430 assembly** for the **MSP-EXP430FR6989** LaunchPad and **BOOSTXL-EDUMKII** Educational BoosterPack.

There is no graphics library. The 128×128 TFT is driven over SPI by setting a rectangular drawing window and streaming BGR pixel bytes straight to the controller.

## Features

- Title screen: black background, large white alien, `PRESS START`
- Joystick X-axis ship movement with a center dead zone
- One red player bullet at a time
- 6×3 alien formation that walks, drops at the screen edges, and flows into empty cells
- Two asynchronous dark-blue enemy lasers from the lowest living row
- Three lives in the top-left HUD
- 1250 points per kill; winning before 80 formation moves doubles the score
- Win: green score screen, then trophy + `YOU WIN`
- Lose: red score screen, then skull + `GAME OVER`
- S1 returns to the title screen from gameplay or a result screen

## Hardware

| Item | Role |
|---|---|
| MSP-EXP430FR6989 | MCU / LaunchPad |
| BOOSTXL-EDUMKII TFT | 128×128 color LCD over SPI |
| Joystick (ADC12) | Ship left / right |
| S1 — P3.0 | Restart / return to title |
| S2 — P3.1 | Start game / fire |

Buttons are active-low with internal pull-ups (released = 1, pressed = 0).

### Pins used in `main.asm`

| Signal | Pin |
|---|---|
| LCD DC | P2.3 |
| LCD CS | P2.5 |
| LCD backlight | P2.6 |
| LCD RST | P9.4 |
| SPI (UCB0) | P1.4, P1.6, P1.7 |
| Joystick | P9.2, P8.7 (ADC12) |
| S1 / S2 | P3.0, P3.1 |

## Controls

| Input | Action |
|---|---|
| S2 on title | Start |
| Joystick X | Move ship |
| Hold S2 | Fire (only if no player bullet is active) |
| S1 | Return to `PRESS START` |

## How it works

Moving objects are animated by saving the old position, erasing that rectangle, updating coordinates, then redrawing at the new position.

Aliens are stored in an 18-cell alive/dead array. The whole formation is moved with `formation_x` / `formation_y`. When a row hits an edge it drops and reverses. Empty slots flow through the row in the current direction so remaining aliens pack toward the leading edge.

Enemy lasers use separate cooldowns. When a laser is free, the lowest row that still has a living alien is chosen, then a pseudo-random living column in that row. Hits use axis-aligned bounding boxes.

Sprites and text are bitmaps: 16×16 ship and alien, 3×5 font scaled to 3×3 blocks, start-screen alien in 6×6 blocks, trophy/skull in 4×4 blocks.

The main loop polls S1, updates the RNG, reads the joystick, moves the ship, handles fire and bullets, steps the formation, then tries enemy shots.

## File

```
main.asm    full game: init, input, sprites, collision, screens
```

## Build

1. Seat the BOOSTXL-EDUMKII on the LaunchPad headers.
2. Open the project in **Code Composer Studio**.
3. Target the **MSP430FR6989**.
4. Build and flash `main.asm`.

Clock, GPIO, SPI (UCB0), and ADC12 are initialized in assembly. After pin setup, GPIO is unlocked with `LOCKLPM5` (FRAM device).
