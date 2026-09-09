;
; Hardware:
;   - BOOSTXL-EDUMKII TFT LCD controlled by SPI.
;   - Joystick read through ADC12.
;   - S1 / CLEAR button on P3.0 returns to the PRESS START screen.
;   - S2 / FIRE button on P3.1 starts the game and fires.
;
; Game behavior:
;   - Start screen with black background, white alien, and PRESS START.
;   - Player ship moves left/right using the joystick X-axis.
;   - Player fires red bullets upward.
;   - Alien formation moves horizontally, drops at screen edges, and repeats.
;   - Aliens are stored in an alive/dead array.
;   - Enemy lasers are dark blue and fire asynchronously from the lowest alive row.
;   - Ship has 3 lives shown in the top-left corner.
;   - Each alien killed gives 1250 points.
;   - Fast win doubles the score.
;   - Win: green score screen, delay, trophy + YOU WIN.
;   - Lose: red score screen, delay, skull + GAME OVER.
;
; Main drawing strategy:
;   The program does not use a graphics library. It sets a rectangular LCD window
;   and streams BGR color bytes directly through SPI.
;
; Object movement strategy:
;   Moving objects are animated by:
;       1. saving the old position,
;       2. erasing the old rectangle,
;       3. updating coordinates,
;       4. redrawing the object at the new position.
;-------------------------------------------------------------------------------

            .cdecls C,LIST,"msp430.h"

;-------------------------------------------------------------------------------
; Constants
;-------------------------------------------------------------------------------

; LCD control pins.
LCD_DC              .equ    BIT3
LCD_CS              .equ    BIT5
LCD_BL              .equ    BIT6
LCD_RST             .equ    BIT4

; Push buttons.
; Buttons use pull-up logic:
;   released = 1
;   pressed  = 0
CLEAR_BTN           .equ    BIT0        ; P3.0 = S1 / restart
FIRE_BTN            .equ    BIT1        ; P3.1 = S2 / start or fire

; Joystick thresholds.
; The center range between JOY_LOW and JOY_HIGH is a dead zone to avoid drift.
JOY_LOW             .equ    1000
JOY_HIGH            .equ    3000
JOY_STEP            .equ    4

; Player sprite dimensions and limits.
PLAYER_LAST_X       .equ    15          ; 16-pixel sprite: x + 15
PLAYER_LAST_Y       .equ    15          ; 16-pixel sprite: y + 15
PLAYER_Y            .equ    112         ; fixed Y location of the player ship
PLAYER_MAX_X        .equ    112         ; 112 + 15 = 127, right edge of screen
PLAYER_PIXELS       .equ    256         ; 16 * 16

; Life HUD constants.
SHIP_START_LIVES    .equ    3
LIFE_ICON_Y         .equ    1
LIFE_ICON_PIXELS    .equ    25          ; 5 * 5
LIFE1_X             .equ    2
LIFE2_X             .equ    9
LIFE3_X             .equ    16

; Player bullet constants.
BULLET_LAST_X       .equ    3           ; bullet width = 4 pixels
BULLET_LAST_Y       .equ    5           ; bullet height = 6 pixels
BULLET_PIXELS       .equ    24          ; 4 * 6
BULLET_STEP         .equ    6           ; bullet moves upward by this amount
BULLET_START_Y      .equ    106

; Enemy laser constants.
ENEMY_BULLET_LAST_X     .equ    2       ; enemy laser width = 3 pixels
ENEMY_BULLET_LAST_Y     .equ    5       ; enemy laser height = 6 pixels
ENEMY_BULLET_PIXELS     .equ    18      ; 3 * 6
ENEMY_BULLET_STEP       .equ    3       ; enemy laser moves downward by this amount

; Two enemy lasers use different cooldowns to create asynchronous shooting.
ENEMY1_COOLDOWN_RESET   .equ    24
ENEMY2_COOLDOWN_RESET   .equ    39

; Alien formation constants.
ALIEN_PIXELS        .equ    256         ; 16 * 16

ALIEN_COLS          .equ    6
ALIEN_ROWS          .equ    3
ALIEN_COUNT         .equ    18

; Formation movement constants.
; The whole alien group is moved by changing formation_x and formation_y.
FORMATION_START_X   .equ    11
FORMATION_START_Y   .equ    8
FORMATION_MIN_X     .equ    0
FORMATION_MAX_X     .equ    22
FORMATION_STEP      .equ    2           ; horizontal movement per step
FORMATION_DROP      .equ    8           ; vertical drop at the edge
FORMATION_DELAY     .equ    12          ; lower value = faster alien movement

; If the formation reaches this Y value, the player loses.
GAME_OVER_FORM_Y    .equ    57

; Score constants.
ALIEN_POINTS        .equ    1250
FAST_WIN_LIMIT      .equ    80          ; win before this many formation moves -> x2 score

; Final score drawing constants.
SCORE_START_X       .equ    38
SCORE_START_Y       .equ    56
SCORE_DIGIT_SPACING .equ    11
SCORE_PIXEL_PIXELS  .equ    9           ; each digit pixel is scaled to 3x3

;-------------------------------------------------------------------------------
; Start screen constants
;-------------------------------------------------------------------------------

; Start screen alien is drawn with 6x6 blocks.
START_ALIEN_X       .equ    31
START_ALIEN_Y       .equ    10
START_BLOCK         .equ    6
START_BLOCK_PIXELS  .equ    36          ; 6 * 6

; PRESS START text uses a 3x5 pixel font scaled to 3x3 blocks.
START_TEXT_X        .equ    11
START_TEXT_Y        .equ    96
START_TEXT_SPACING  .equ    10
START_SPACE_WIDTH   .equ    8
START_PIXEL_PIXELS  .equ    9           ; 3 * 3

;-------------------------------------------------------------------------------
; Result art constants
;-------------------------------------------------------------------------------

; Trophy and skull art are drawn with 4x4 blocks.
RESULT_BASE_X       .equ    24
RESULT_BASE_Y       .equ    16
RESULT_BLOCK        .equ    4
RESULT_BLOCK_PIXELS .equ    16          ; 4 * 4

RESULT_TEXT_YW_X    .equ    12
RESULT_TEXT_YW_Y    .equ    94

RESULT_TEXT_GO_X    .equ    14
RESULT_TEXT_GO_Y    .equ    94

RESULT_TEXT_SPACING .equ    10
RESULT_TEXT_PIXELS  .equ    9           ; 3 * 3

;-------------------------------------------------------------------------------
; Macros
;-------------------------------------------------------------------------------

; Simple delay macro used during LCD reset/init.
delay       .macro  count
            mov.w   #count, R15
delay_loop? dec.w   R15
            jnz     delay_loop?
            .endm

RST_HIGH    .macro
            bis.b   #LCD_RST, &P9OUT
            .endm

RST_LOW     .macro
            bic.b   #LCD_RST, &P9OUT
            .endm

CS_HIGH     .macro
            bis.b   #LCD_CS, &P2OUT
            .endm

CS_LOW      .macro
            bic.b   #LCD_CS, &P2OUT
            .endm

; Draw one block of the start-screen alien using grid coordinates.
start_block .macro col,row
            mov.b   #(START_ALIEN_X+((col)*(START_BLOCK))), &draw_x
            mov.b   #(START_ALIEN_Y+((row)*(START_BLOCK))), &draw_y
            call    #DrawStartBlock
            .endm

; Draw one block of the trophy/skull using grid coordinates.
result_block .macro col,row
            mov.b   #(RESULT_BASE_X+((col)*(RESULT_BLOCK))), &draw_x
            mov.b   #(RESULT_BASE_Y+((row)*(RESULT_BLOCK))), &draw_y
            call    #DrawResultBlock
            .endm

; LCD configuration helper.
; Sends one command byte followed by optional data bytes.
tft_config  .macro  address, d0, d1, d2, d3, d4, d5, d6, d7, d8, d9, d10, d11, d12, d13, d14, d15
            mov.b   #address, R15
            call    #tft_cmd_sr

            .if $symlen(":d0:") > 0
            mov.b   d0, R15
            call    #tft_data_sr
            .endif
            .if $symlen(":d1:") > 0
            mov.b   d1, R15
            call    #tft_data_sr
            .endif
            .if $symlen(":d2:") > 0
            mov.b   d2, R15
            call    #tft_data_sr
            .endif
            .if $symlen(":d3:") > 0
            mov.b   d3, R15
            call    #tft_data_sr
            .endif
            .if $symlen(":d4:") > 0
            mov.b   d4, R15
            call    #tft_data_sr
            .endif
            .if $symlen(":d5:") > 0
            mov.b   d5, R15
            call    #tft_data_sr
            .endif
            .if $symlen(":d6:") > 0
            mov.b   d6, R15
            call    #tft_data_sr
            .endif
            .if $symlen(":d7:") > 0
            mov.b   d7, R15
            call    #tft_data_sr
            .endif
            .if $symlen(":d8:") > 0
            mov.b   d8, R15
            call    #tft_data_sr
            .endif
            .if $symlen(":d9:") > 0
            mov.b   d9, R15
            call    #tft_data_sr
            .endif
            .if $symlen(":d10:") > 0
            mov.b   d10, R15
            call    #tft_data_sr
            .endif
            .if $symlen(":d11:") > 0
            mov.b   d11, R15
            call    #tft_data_sr
            .endif
            .if $symlen(":d12:") > 0
            mov.b   d12, R15
            call    #tft_data_sr
            .endif
            .if $symlen(":d13:") > 0
            mov.b   d13, R15
            call    #tft_data_sr
            .endif
            .if $symlen(":d14:") > 0
            mov.b   d14, R15
            call    #tft_data_sr
            .endif
            .if $symlen(":d15:") > 0
            mov.b   d15, R15
            call    #tft_data_sr
            .endif
            .endm

;-------------------------------------------------------------------------------
; Data section
;-------------------------------------------------------------------------------

            .def    RESET
            .global _main
            .global __STACK_END
            .sect   .stack

            .data

; Current LCD drawing window.
win_x0              .byte   0
win_y0              .byte   0
win_x1              .byte   0
win_y1              .byte   0

; Current BGR color for rectangle drawing.
cur_B               .byte   0
cur_G               .byte   0
cur_R               .byte   0

; Joystick ADC readings.
joy_x               .word   2000
joy_y               .word   2000

; Player position and lives.
player_x            .byte   56
old_player_x        .byte   56
ship_lives          .byte   SHIP_START_LIVES

; Score variables.
score               .word   0
game_timer          .word   0
score_work          .word   0

; Shared text/digit drawing variables.
digit_x             .byte   0
digit_y             .byte   0
pixel_x             .byte   0
pixel_y             .byte   0

; Player bullet state.
bullet_x            .byte   0
bullet_y            .byte   0
old_bullet_y        .byte   0
bullet_active       .byte   0

; Enemy laser 1 state.
enemy1_x            .byte   0
enemy1_y            .byte   0
old_enemy1_y        .byte   0
enemy1_active       .byte   0
enemy1_cooldown     .byte   ENEMY1_COOLDOWN_RESET

; Enemy laser 2 state.
enemy2_x            .byte   0
enemy2_y            .byte   0
old_enemy2_y        .byte   0
enemy2_active       .byte   0
enemy2_cooldown     .byte   ENEMY2_COOLDOWN_RESET

; Simple pseudo-random state for enemy shooting.
rng_state           .byte   0xA5

; Alien formation position.
; The whole formation is moved by changing formation_x and formation_y.
formation_x         .byte   FORMATION_START_X
formation_y         .byte   FORMATION_START_Y
old_formation_x     .byte   FORMATION_START_X
old_formation_y     .byte   FORMATION_START_Y
formation_dir       .byte   0           ; 0 = moving right, 1 = moving left
formation_tick      .byte   0           ; controls formation movement timing

aliens_remaining    .byte   ALIEN_COUNT
game_over           .byte   0

; General drawing position used by object routines.
draw_x              .byte   0
draw_y              .byte   0

; Alien alive/dead array.
; 1 = alive, 0 = empty space.
AlienAliveArr:
            .byte   1,1,1,1,1,1
            .byte   1,1,1,1,1,1
            .byte   1,1,1,1,1,1

;-------------------------------------------------------------------------------
; Constant data
;-------------------------------------------------------------------------------

            .sect   ".const"
            .align  2

; Bit masks used to test individual bits in sprite bytes.
MaskTable:
            .byte   0x80, 0x40, 0x20, 0x10, 0x08, 0x04, 0x02, 0x01

; Alien placement offsets relative to formation_x / formation_y.
AlienColOffsets:
            .byte   0, 18, 36, 54, 72, 90

AlienRowOffsets:
            .byte   0, 18, 36

; 3x5 digit font.
; Each byte is one row. Lower 3 bits define pixels.
DigitFont3x5:
            .byte   0x07,0x05,0x05,0x05,0x07
            .byte   0x02,0x06,0x02,0x02,0x07
            .byte   0x07,0x01,0x07,0x04,0x07
            .byte   0x07,0x01,0x07,0x01,0x07
            .byte   0x05,0x05,0x07,0x01,0x01
            .byte   0x07,0x04,0x07,0x01,0x07
            .byte   0x07,0x04,0x07,0x05,0x07
            .byte   0x07,0x01,0x01,0x01,0x01
            .byte   0x07,0x05,0x07,0x05,0x07
            .byte   0x07,0x05,0x07,0x01,0x07

; Limited 3x5 font for PRESS START.
; Indexes: 0=P, 1=R, 2=E, 3=S, 4=T, 5=A.
StartLetterFont3x5:
            .byte   0x06,0x05,0x06,0x04,0x04     ; P
            .byte   0x06,0x05,0x06,0x05,0x05     ; R
            .byte   0x07,0x04,0x07,0x04,0x07     ; E
            .byte   0x07,0x04,0x07,0x01,0x07     ; S
            .byte   0x07,0x02,0x02,0x02,0x02     ; T
            .byte   0x07,0x05,0x07,0x05,0x05     ; A

; Limited 3x5 font for result text.
; 0=Y 1=O 2=U 3=W 4=I 5=N 6=G 7=A 8=M 9=E 10=V 11=R 12=!
ResultLetterFont3x5:
            .byte   0x05,0x05,0x02,0x02,0x02     ; Y
            .byte   0x07,0x05,0x05,0x05,0x07     ; O
            .byte   0x05,0x05,0x05,0x05,0x07     ; U
            .byte   0x05,0x05,0x07,0x07,0x05     ; W
            .byte   0x07,0x02,0x02,0x02,0x07     ; I
            .byte   0x05,0x07,0x07,0x07,0x05     ; N
            .byte   0x07,0x04,0x05,0x05,0x07     ; G
            .byte   0x07,0x05,0x07,0x05,0x05     ; A
            .byte   0x05,0x07,0x07,0x05,0x05     ; M
            .byte   0x07,0x04,0x07,0x04,0x07     ; E
            .byte   0x05,0x05,0x05,0x05,0x02     ; V
            .byte   0x06,0x05,0x06,0x05,0x05     ; R
            .byte   0x02,0x02,0x02,0x00,0x02     ; !

; 16x16 alien sprite.
; Each bit represents one pixel.
AlienSprite:
            .byte   0x01, 0x07, 0x0F, 0x1D, 0x3F, 0x6F, 0xED, 0xCF
            .byte   0xCF, 0xED, 0x6F, 0x3F, 0x1D, 0x0F, 0x07, 0x01
            .byte   0x80, 0x80, 0xC0, 0xE0, 0xF0, 0xC0, 0xE0, 0xFC
            .byte   0xFC, 0xE0, 0xC0, 0xF0, 0xE0, 0xC0, 0x80, 0x80

; 16x16 player ship sprite.
; Each bit represents one pixel.
PlayerShip:
            .byte   0x00, 0x00, 0x00, 0x00, 0x0F, 0x1F, 0x1D, 0xFF
            .byte   0xFD, 0x1F, 0x1F, 0x0D, 0x00, 0x00, 0x00, 0x00
            .byte   0x7F, 0x7F, 0x7F, 0x3F, 0xFE, 0xFC, 0xF8, 0xFF
            .byte   0xFF, 0xF8, 0xFC, 0xFE, 0x3F, 0x7F, 0x7F, 0x7F

            .text
            .retain
            .retainrefs

;-------------------------------------------------------------------------------
; Main program
;-------------------------------------------------------------------------------

_main
RESET:
            ; Standard MSP430 startup.
            mov.w   #__STACK_END, SP
            mov.w   #WDTPW+WDTHOLD, &WDTCTL

            ; Hardware initialization.
            call    #InitClock
            call    #SetupGPIO
            call    #SetupSPI
            call    #SetupADC12

            ; Unlock GPIO pins on FRAM MSP devices.
            bic.w   #LOCKLPM5, &PM5CTL0

            ; LCD initialization.
            call    #LCD_Reset
            call    #LCD_Init

            ; Show title screen and wait for S2 before starting.
            call    #ShowStartScreen
            call    #WaitStartButton
            call    #ResetGame

Mainloop:
            ; Main game loop.  Each routine updates one part of the game.
            call    #CheckS1
            call    #UpdateRandom

            call    #ReadJoystick
            call    #UpdatePlayer

            call    #CheckS2_HoldFire
            call    #UpdateBullet

            call    #UpdateEnemy1Bullet
            call    #UpdateEnemy2Bullet

            call    #UpdateFormation

            call    #TryEnemy1Fire
            call    #TryEnemy2Fire

            call    #FrameDelay
            jmp     Mainloop

;-------------------------------------------------------------------------------
; System initialization
;-------------------------------------------------------------------------------

InitClock:
            ; Configure clock source for CPU and peripherals.
            mov.b   #CSKEY_H, &CSCTL0_H
            mov.w   #DCOFSEL_6, &CSCTL1
            mov.w   #SELA__VLOCLK+SELS__DCOCLK+SELM__DCOCLK, &CSCTL2
            mov.w   #DIVA__1+DIVS__1+DIVM__1, &CSCTL3
            clr.b   &CSCTL0_H
            ret

SetupGPIO:
            ; LCD pins as GPIO outputs.
            bis.b   #LCD_DC+LCD_CS+LCD_BL, &P2DIR
            bic.b   #LCD_DC+LCD_CS+LCD_BL, &P2SEL0
            bic.b   #LCD_DC+LCD_CS+LCD_BL, &P2SEL1

            bic.b   #LCD_DC, &P2OUT
            bis.b   #LCD_CS, &P2OUT
            bis.b   #LCD_BL, &P2OUT

            ; LCD reset pin.
            bis.b   #LCD_RST, &P9DIR
            bic.b   #LCD_RST, &P9SEL0
            bic.b   #LCD_RST, &P9SEL1
            bis.b   #LCD_RST, &P9OUT

            ; S1 and S2 as inputs with pull-up resistors.
            bic.b   #CLEAR_BTN+FIRE_BTN, &P3DIR
            bic.b   #CLEAR_BTN+FIRE_BTN, &P3SEL0
            bic.b   #CLEAR_BTN+FIRE_BTN, &P3SEL1
            bis.b   #CLEAR_BTN+FIRE_BTN, &P3REN
            bis.b   #CLEAR_BTN+FIRE_BTN, &P3OUT
            ret

SetupSPI:
            ; Configure UCB0 SPI pins.
            bis.b   #BIT4+BIT6+BIT7, &P1SEL0
            bic.b   #BIT4+BIT6+BIT7, &P1SEL1

            ; UCB0 in reset while configuring.
            mov.w   #UCSWRST, &UCB0CTLW0
            bis.w   #UCSSEL__SMCLK+UCSYNC+UCMODE_0+UCMST+UCMSB, &UCB0CTLW0
            mov.w   #2, &UCB0BRW
            bic.w   #UCSWRST, &UCB0CTLW0
            ret

SetupADC12:
            ; Configure joystick analog input pins.
            bis.b   #BIT2, &P9SEL0
            bis.b   #BIT2, &P9SEL1

            bis.b   #BIT7, &P8SEL0
            bis.b   #BIT7, &P8SEL1

            ; Configure ADC12 for sequence-of-channels mode.
            bic.w   #ADC12ENC, &ADC12CTL0

            mov.w   #ADC12SHT0_2+ADC12ON, &ADC12CTL0
            mov.w   #ADC12SHP+ADC12CONSEQ_1, &ADC12CTL1
            mov.w   #ADC12RES_2, &ADC12CTL2

            ; Read two joystick channels.
            mov.w   #ADC12INCH_10, &ADC12MCTL0
            mov.w   #ADC12INCH_4+ADC12EOS, &ADC12MCTL1

            bis.w   #ADC12ENC, &ADC12CTL0
            ret

;-------------------------------------------------------------------------------
; Start screen / return to start
;-------------------------------------------------------------------------------

ShowStartScreen:
            ; Draw black background, large alien, and PRESS START.
            call    #LCD_FillScreenBlack
            call    #DrawStartAlien
            call    #DrawPressStart
            ret

WaitStartButton:
            ; Wait for S2 press and release.
WaitStartPress:
            bit.b   #FIRE_BTN, &P3IN
            jnz     WaitStartPress

            call    #DebounceDelay

            bit.b   #FIRE_BTN, &P3IN
            jnz     WaitStartPress

WaitStartRelease:
            bit.b   #FIRE_BTN, &P3IN
            jz      WaitStartRelease
            ret

GoToStartScreen:
            ; S1 returns here from gameplay or result screens.
            mov.b   #1, &game_over
            mov.b   #0, &bullet_active
            mov.b   #0, &enemy1_active
            mov.b   #0, &enemy2_active

            call    #ShowStartScreen
            call    #WaitStartButton
            call    #ResetGame
            ret

DrawStartAlien:
            ; Pixel-art alien using 6x6 blocks.
            start_block 2,0
            start_block 8,0

            start_block 3,1
            start_block 7,1

            start_block 2,2
            start_block 3,2
            start_block 4,2
            start_block 5,2
            start_block 6,2
            start_block 7,2
            start_block 8,2

            start_block 1,3
            start_block 2,3
            start_block 4,3
            start_block 5,3
            start_block 6,3
            start_block 8,3
            start_block 9,3

            start_block 0,4
            start_block 1,4
            start_block 2,4
            start_block 3,4
            start_block 4,4
            start_block 5,4
            start_block 6,4
            start_block 7,4
            start_block 8,4
            start_block 9,4
            start_block 10,4

            start_block 0,5
            start_block 2,5
            start_block 3,5
            start_block 4,5
            start_block 5,5
            start_block 6,5
            start_block 7,5
            start_block 8,5
            start_block 10,5

            start_block 0,6
            start_block 2,6
            start_block 8,6
            start_block 10,6

            start_block 2,7
            start_block 3,7
            start_block 7,7
            start_block 8,7
            ret

DrawStartBlock:
            ; Draw one white 6x6 block at draw_x, draw_y.
            mov.b   &draw_x, R12
            mov.b   R12, &win_x0
            add.b   #5, R12
            mov.b   R12, &win_x1

            mov.b   &draw_y, R12
            mov.b   R12, &win_y0
            add.b   #5, R12
            mov.b   R12, &win_y1

            mov.b   #0xFF, &cur_B
            mov.b   #0xFF, &cur_G
            mov.b   #0xFF, &cur_R

            mov.w   #START_BLOCK_PIXELS, R12
            call    #LCD_FillCurrentWindow
            ret

DrawPressStart:
            ; Draw PRESS START using the limited 3x5 font.
            mov.b   #START_TEXT_X, &digit_x
            mov.b   #START_TEXT_Y, &digit_y

            mov.w   #0, R12
            call    #DrawStartLetterAtXY
            add.b   #START_TEXT_SPACING, &digit_x

            mov.w   #1, R12
            call    #DrawStartLetterAtXY
            add.b   #START_TEXT_SPACING, &digit_x

            mov.w   #2, R12
            call    #DrawStartLetterAtXY
            add.b   #START_TEXT_SPACING, &digit_x

            mov.w   #3, R12
            call    #DrawStartLetterAtXY
            add.b   #START_TEXT_SPACING, &digit_x

            mov.w   #3, R12
            call    #DrawStartLetterAtXY
            add.b   #START_TEXT_SPACING, &digit_x

            add.b   #START_SPACE_WIDTH, &digit_x

            mov.w   #3, R12
            call    #DrawStartLetterAtXY
            add.b   #START_TEXT_SPACING, &digit_x

            mov.w   #4, R12
            call    #DrawStartLetterAtXY
            add.b   #START_TEXT_SPACING, &digit_x

            mov.w   #5, R12
            call    #DrawStartLetterAtXY
            add.b   #START_TEXT_SPACING, &digit_x

            mov.w   #1, R12
            call    #DrawStartLetterAtXY
            add.b   #START_TEXT_SPACING, &digit_x

            mov.w   #4, R12
            call    #DrawStartLetterAtXY
            ret

DrawStartLetterAtXY:
            ; Input:
            ;   R12 = letter index in StartLetterFont3x5.
            ;   digit_x, digit_y = draw position.
            ;
            ; Each font pixel becomes a 3x3 white block.
            mov.w   #StartLetterFont3x5, R11
            mov.w   R12, R14

StartLetterPtrLoop:
            cmp.w   #0, R14
            jeq     StartLetterPtrReady
            add.w   #5, R11
            dec.w   R14
            jmp     StartLetterPtrLoop

StartLetterPtrReady:
            clr.w   R6
            mov.w   #5, R5

StartLetterRowLoop:
            mov.b   @R11+, R13
            clr.w   R7
            mov.b   #0x04, R8

StartLetterColLoop:
            bit.b   R8, R13
            jz      StartLetterPixelSkip

            mov.b   &digit_x, R12
            mov.b   R7, R14
            add.b   R14, R14
            add.b   R7, R14
            add.b   R14, R12
            mov.b   R12, &pixel_x

            mov.b   &digit_y, R12
            mov.b   R6, R14
            add.b   R14, R14
            add.b   R6, R14
            add.b   R14, R12
            mov.b   R12, &pixel_y

            push.w  R5
            push.w  R6
            push.w  R7
            push.w  R8
            push.w  R11
            push.w  R13

            call    #DrawStartTextPixel

            pop.w   R13
            pop.w   R11
            pop.w   R8
            pop.w   R7
            pop.w   R6
            pop.w   R5

StartLetterPixelSkip:
            rra.b   R8
            inc.w   R7
            cmp.w   #3, R7
            jlo     StartLetterColLoop

            inc.w   R6
            dec.w   R5
            jnz     StartLetterRowLoop
            ret

DrawStartTextPixel:
            ; Draw one white 3x3 text pixel.
            mov.b   &pixel_x, R12
            mov.b   R12, &win_x0
            add.b   #2, R12
            mov.b   R12, &win_x1

            mov.b   &pixel_y, R12
            mov.b   R12, &win_y0
            add.b   #2, R12
            mov.b   R12, &win_y1

            mov.b   #0xFF, &cur_B
            mov.b   #0xFF, &cur_G
            mov.b   #0xFF, &cur_R

            mov.w   #START_PIXEL_PIXELS, R12
            call    #LCD_FillCurrentWindow
            ret

;-------------------------------------------------------------------------------
; Input
;-------------------------------------------------------------------------------

ReadJoystick:
            ; Start ADC conversion sequence and wait for both channels.
            mov.w   #0, &ADC12IFGR0
            bis.w   #ADC12SC, &ADC12CTL0
            mov.w   #50000, R14

WaitADC:
            bit.w   #BIT1, &ADC12IFGR0
            jnz     ADC_Done
            dec.w   R14
            jnz     WaitADC
            ret

ADC_Done:
            ; Store joystick X and Y readings.
            mov.w   &ADC12MEM0, R12
            mov.w   R12, &joy_x

            mov.w   &ADC12MEM1, R12
            mov.w   R12, &joy_y
            ret

CheckS1:
            ; If S1 is pressed, return to PRESS START.
            bit.b   #CLEAR_BTN, &P3IN
            jnz     S1_NotPressed

            call    #DebounceDelay
            bit.b   #CLEAR_BTN, &P3IN
            jnz     S1_NotPressed

            call    #GoToStartScreen

WaitS1Release:
            bit.b   #CLEAR_BTN, &P3IN
            jz      WaitS1Release

S1_NotPressed:
            ret

CheckS2_HoldFire:
            ; During gameplay, holding S2 fires whenever no player bullet exists.
            cmp.b   #1, &game_over
            jeq     S2_HoldDone

            bit.b   #FIRE_BTN, &P3IN
            jnz     S2_HoldDone

            call    #FireBullet

S2_HoldDone:
            ret

;-------------------------------------------------------------------------------
; Reset game
;-------------------------------------------------------------------------------

ResetGame:
            ; Reset all gameplay state and draw the first frame.
            call    #LCD_FillScreenWhite

            mov.b   #0, &bullet_active

            mov.b   #0, &enemy1_active
            mov.b   #0, &enemy2_active
            mov.b   #ENEMY1_COOLDOWN_RESET, &enemy1_cooldown
            mov.b   #ENEMY2_COOLDOWN_RESET, &enemy2_cooldown

            mov.b   #0, &game_over
            mov.b   #0xA5, &rng_state
            mov.b   #SHIP_START_LIVES, &ship_lives

            mov.w   #0, &score
            mov.w   #0, &game_timer

            mov.b   #FORMATION_START_X, &formation_x
            mov.b   #FORMATION_START_Y, &formation_y
            mov.b   #FORMATION_START_X, &old_formation_x
            mov.b   #FORMATION_START_Y, &old_formation_y
            mov.b   #0, &formation_dir
            mov.b   #0, &formation_tick

            mov.b   #ALIEN_COUNT, &aliens_remaining
            call    #ResetAlienArray

            mov.b   #56, &player_x
            mov.b   #56, &old_player_x

            call    #DrawLivesHUD
            call    #DrawAllAlienCells
            call    #DrawPlayer
            ret

ResetAlienArray:
            ; Set all alien cells back to alive.
            mov.w   #AlienAliveArr, R10
            mov.w   #ALIEN_COUNT, R11

ResetAlienLoop:
            mov.b   #1, 0(R10)
            inc.w   R10
            dec.w   R11
            jnz     ResetAlienLoop
            ret

;-------------------------------------------------------------------------------
; Random
;-------------------------------------------------------------------------------

UpdateRandom:
            ; Small pseudo-random update used for selecting enemy shooting columns.
            mov.b   &rng_state, R12
            mov.b   R12, R13

            rla.b   R12
            rla.b   R12
            add.b   R13, R12
            add.b   #1, R12

            cmp.b   #0, R12
            jne     StoreRandom

            mov.b   #0xA5, R12

StoreRandom:
            mov.b   R12, &rng_state
            ret

;-------------------------------------------------------------------------------
; Player movement
;-------------------------------------------------------------------------------

UpdatePlayer:
            ; Move player left/right based on joystick X value.
            ; The ship only moves if the joystick is outside the dead zone.
            cmp.b   #1, &game_over
            jeq     NoMove

            ; Save old X position so it can be erased.
            mov.b   &player_x, R12
            mov.b   R12, &old_player_x

            ; Right movement.
            cmp.w   #JOY_HIGH, &joy_x
            jlo     CheckMoveLeft

            cmp.b   #PLAYER_MAX_X, &player_x
            jhs     NoMove

            add.b   #JOY_STEP, &player_x
            cmp.b   #PLAYER_MAX_X, &player_x
            jlo     PlayerMoved
            mov.b   #PLAYER_MAX_X, &player_x
            jmp     PlayerMoved

CheckMoveLeft:
            ; Left movement.
            cmp.w   #JOY_LOW, &joy_x
            jhs     NoMove

            cmp.b   #JOY_STEP, &player_x
            jlo     SetPlayerZero

            sub.b   #JOY_STEP, &player_x
            jmp     PlayerMoved

SetPlayerZero:
            ; Clamp at left screen edge.
            cmp.b   #0, &player_x
            jeq     NoMove
            mov.b   #0, &player_x
            jmp     PlayerMoved

NoMove:
            ret

PlayerMoved:
            ; Erase old ship and draw new ship.
            call    #EraseOldPlayer
            call    #DrawPlayer
            ret

;-------------------------------------------------------------------------------
; Player bullet
;-------------------------------------------------------------------------------

FireBullet:
            ; Only one player bullet can be active at a time.
            cmp.b   #1, &bullet_active
            jeq     FireDone

            ; Bullet starts near the center/top of the ship.
            mov.b   &player_x, R12
            add.b   #6, R12
            mov.b   R12, &bullet_x

            mov.b   #BULLET_START_Y, &bullet_y
            mov.b   #BULLET_START_Y, &old_bullet_y
            mov.b   #1, &bullet_active

            call    #DrawBullet

FireDone:
            ret

UpdateBullet:
            ; Move the player bullet upward and test alien collision.
            cmp.b   #1, &game_over
            jeq     BulletDone

            cmp.b   #1, &bullet_active
            jne     BulletDone

            mov.b   &bullet_y, R12
            mov.b   R12, &old_bullet_y

            call    #EraseBullet

            cmp.b   #9, &bullet_y
            jlo     DeactivateBullet

            sub.b   #BULLET_STEP, &bullet_y

            call    #CheckBulletAlienCollision

            cmp.b   #1, &bullet_active
            jne     BulletDone

            call    #DrawBullet
            ret

DeactivateBullet:
            mov.b   #0, &bullet_active

BulletDone:
            ret

;-------------------------------------------------------------------------------
; Enemy fire logic
;-------------------------------------------------------------------------------

TryEnemy1Fire:
            ; Enemy laser 1 fires when inactive and cooldown reaches zero.
            cmp.b   #1, &game_over
            jeq     TryEnemy1Done

            cmp.b   #1, &enemy1_active
            jeq     TryEnemy1Done

            cmp.b   #0, &aliens_remaining
            jeq     TryEnemy1Done

            dec.b   &enemy1_cooldown
            jnz     TryEnemy1Done

            mov.b   #ENEMY1_COOLDOWN_RESET, &enemy1_cooldown

            call    #FindBottomAliveShooterRow
            cmp.b   #1, R12
            jne     TryEnemy1Done

            clr.w   R14
            mov.b   &rng_state, R14
            call    #FindAliveColumnFromRandom

            cmp.b   #1, R12
            jne     TryEnemy1Done

            call    #FireEnemy1FromColumn

TryEnemy1Done:
            ret

TryEnemy2Fire:
            ; Enemy laser 2 uses a different cooldown and random offset.
            cmp.b   #1, &game_over
            jeq     TryEnemy2Done

            cmp.b   #1, &enemy2_active
            jeq     TryEnemy2Done

            cmp.b   #0, &aliens_remaining
            jeq     TryEnemy2Done

            dec.b   &enemy2_cooldown
            jnz     TryEnemy2Done

            mov.b   #ENEMY2_COOLDOWN_RESET, &enemy2_cooldown

            call    #FindBottomAliveShooterRow
            cmp.b   #1, R12
            jne     TryEnemy2Done

            clr.w   R14
            mov.b   &rng_state, R14
            add.w   #3, R14
            call    #FindAliveColumnFromRandom

            cmp.b   #1, R12
            jne     TryEnemy2Done

            call    #FireEnemy2FromColumn

TryEnemy2Done:
            ret

FindBottomAliveShooterRow:
            ; Choose the lowest row that still has at least one alive alien.
            ; Output:
            ;   R12 = 1 if a row was found, 0 otherwise.
            ;   R10 points to start of selected row.
            ;   R8 contains row offset in pixels.
            mov.w   #AlienAliveArr, R10
            add.w   #12, R10
            mov.b   #36, R8
            call    #RowHasAlive
            cmp.b   #1, R12
            jeq     ShooterRowFound

            mov.w   #AlienAliveArr, R10
            add.w   #6, R10
            mov.b   #18, R8
            call    #RowHasAlive
            cmp.b   #1, R12
            jeq     ShooterRowFound

            mov.w   #AlienAliveArr, R10
            mov.b   #0, R8
            call    #RowHasAlive
            cmp.b   #1, R12
            jeq     ShooterRowFound

            mov.b   #0, R12
            ret

ShooterRowFound:
            mov.b   #1, R12
            ret

RowHasAlive:
            ; Check whether a row contains any alive alien.
            push.w  R10
            mov.w   #ALIEN_COLS, R5

RowHasAliveLoop:
            cmp.b   #1, 0(R10)
            jeq     RowAliveYes

            inc.w   R10
            dec.w   R5
            jnz     RowHasAliveLoop

            pop.w   R10
            mov.b   #0, R12
            ret

RowAliveYes:
            pop.w   R10
            mov.b   #1, R12
            ret

FindAliveColumnFromRandom:
            ; Pick a random column, then scan until an alive alien is found.
            ; Input:
            ;   R10 = start of selected row.
            ;   R14 = random seed value.
            ; Output:
            ;   R12 = 1 if alive column found.
            ;   R14 = selected column index.
            and.w   #0x0007, R14

FixRandomCol2:
            cmp.w   #6, R14
            jlo     RandomColReady2

            sub.w   #6, R14
            jmp     FixRandomCol2

RandomColReady2:
            mov.w   #6, R5

FindShooterColLoop2:
            mov.w   R10, R11
            add.w   R14, R11

            cmp.b   #1, 0(R11)
            jeq     ShooterColFound2

            inc.w   R14
            cmp.w   #6, R14
            jlo     ShooterColNoWrap2

            clr.w   R14

ShooterColNoWrap2:
            dec.w   R5
            jnz     FindShooterColLoop2

            mov.b   #0, R12
            ret

ShooterColFound2:
            mov.b   #1, R12
            ret

FireEnemy1FromColumn:
            ; Start enemy laser 1 below the selected alien.
            mov.w   #AlienColOffsets, R11
            add.w   R14, R11
            mov.b   0(R11), R13

            mov.b   &formation_x, R12
            add.b   R13, R12
            add.b   #7, R12
            mov.b   R12, &enemy1_x

            mov.b   &formation_y, R12
            add.b   R8, R12
            add.b   #16, R12
            mov.b   R12, &enemy1_y
            mov.b   R12, &old_enemy1_y

            mov.b   #1, &enemy1_active
            call    #DrawEnemy1Bullet
            ret

FireEnemy2FromColumn:
            ; Start enemy laser 2 below the selected alien.
            mov.w   #AlienColOffsets, R11
            add.w   R14, R11
            mov.b   0(R11), R13

            mov.b   &formation_x, R12
            add.b   R13, R12
            add.b   #7, R12
            mov.b   R12, &enemy2_x

            mov.b   &formation_y, R12
            add.b   R8, R12
            add.b   #16, R12
            mov.b   R12, &enemy2_y
            mov.b   R12, &old_enemy2_y

            mov.b   #1, &enemy2_active
            call    #DrawEnemy2Bullet
            ret

;-------------------------------------------------------------------------------
; Enemy bullet updates
;-------------------------------------------------------------------------------

UpdateEnemy1Bullet:
            ; Move enemy laser 1 downward and check player collision.
            cmp.b   #1, &game_over
            jeq     Enemy1Done

            cmp.b   #1, &enemy1_active
            jne     Enemy1Done

            mov.b   &enemy1_y, R12
            mov.b   R12, &old_enemy1_y

            call    #EraseEnemy1Bullet

            cmp.b   #122, &enemy1_y
            jhs     DeactivateEnemy1

            add.b   #ENEMY_BULLET_STEP, &enemy1_y

            call    #CheckEnemy1PlayerCollision

            cmp.b   #1, &enemy1_active
            jne     Enemy1Done

            call    #DrawEnemy1Bullet
            ret

DeactivateEnemy1:
            mov.b   #0, &enemy1_active

Enemy1Done:
            ret

UpdateEnemy2Bullet:
            ; Move enemy laser 2 downward and check player collision.
            cmp.b   #1, &game_over
            jeq     Enemy2Done

            cmp.b   #1, &enemy2_active
            jne     Enemy2Done

            mov.b   &enemy2_y, R12
            mov.b   R12, &old_enemy2_y

            call    #EraseEnemy2Bullet

            cmp.b   #122, &enemy2_y
            jhs     DeactivateEnemy2

            add.b   #ENEMY_BULLET_STEP, &enemy2_y

            call    #CheckEnemy2PlayerCollision

            cmp.b   #1, &enemy2_active
            jne     Enemy2Done

            call    #DrawEnemy2Bullet
            ret

DeactivateEnemy2:
            mov.b   #0, &enemy2_active

Enemy2Done:
            ret

;-------------------------------------------------------------------------------
; Enemy bullet vs player collision
;-------------------------------------------------------------------------------

CheckEnemy1PlayerCollision:
            ; Bounding-box collision test between enemy laser 1 and player ship.
            clr.w   R4
            mov.b   &player_x, R4
            add.w   #16, R4
            cmp.b   R4, &enemy1_x
            jhs     Enemy1NoHit

            clr.w   R4
            mov.b   &enemy1_x, R4
            add.w   #ENEMY_BULLET_LAST_X, R4
            cmp.b   &player_x, R4
            jlo     Enemy1NoHit

            cmp.b   #PLAYER_Y+16, &enemy1_y
            jhs     Enemy1NoHit

            clr.w   R4
            mov.b   &enemy1_y, R4
            add.w   #ENEMY_BULLET_LAST_Y, R4
            cmp.b   #PLAYER_Y, R4
            jlo     Enemy1NoHit

            call    #HandleShipHit
            ret

Enemy1NoHit:
            ret

CheckEnemy2PlayerCollision:
            ; Bounding-box collision test between enemy laser 2 and player ship.
            clr.w   R4
            mov.b   &player_x, R4
            add.w   #16, R4
            cmp.b   R4, &enemy2_x
            jhs     Enemy2NoHit

            clr.w   R4
            mov.b   &enemy2_x, R4
            add.w   #ENEMY_BULLET_LAST_X, R4
            cmp.b   &player_x, R4
            jlo     Enemy2NoHit

            cmp.b   #PLAYER_Y+16, &enemy2_y
            jhs     Enemy2NoHit

            clr.w   R4
            mov.b   &enemy2_y, R4
            add.w   #ENEMY_BULLET_LAST_Y, R4
            cmp.b   #PLAYER_Y, R4
            jlo     Enemy2NoHit

            call    #HandleShipHit
            ret

Enemy2NoHit:
            ret

;-------------------------------------------------------------------------------
; Ship lives
;-------------------------------------------------------------------------------

HandleShipHit:
            ; Erase active enemy lasers, reduce life count, flash the ship, or end game.
            cmp.b   #1, &enemy1_active
            jne     SkipEraseEnemy1OnHit
            mov.b   &enemy1_y, &old_enemy1_y
            call    #EraseEnemy1Bullet

SkipEraseEnemy1OnHit:
            cmp.b   #1, &enemy2_active
            jne     SkipEraseEnemy2OnHit
            mov.b   &enemy2_y, &old_enemy2_y
            call    #EraseEnemy2Bullet

SkipEraseEnemy2OnHit:
            mov.b   #0, &enemy1_active
            mov.b   #0, &enemy2_active

            cmp.b   #2, &ship_lives
            jlo     ShipHitGameOver

            dec.b   &ship_lives

            call    #DrawLivesHUD
            call    #FlashShip
            call    #DrawPlayer
            ret

ShipHitGameOver:
            mov.b   #0, &ship_lives
            mov.b   #0, &enemy1_active
            mov.b   #0, &enemy2_active
            mov.b   #0, &bullet_active
            mov.b   #1, &game_over

            call    #ShowLoseScreen
            ret

FlashShip:
            ; Simple visual feedback when player takes damage.
            call    #ErasePlayerCurrent
            call    #ShortFlashDelay
            call    #DrawPlayer
            call    #ShortFlashDelay

            call    #ErasePlayerCurrent
            call    #ShortFlashDelay
            call    #DrawPlayer
            call    #ShortFlashDelay
            ret

ShortFlashDelay:
            mov.w   #12000, R15

ShortFlashLoop:
            dec.w   R15
            jnz     ShortFlashLoop
            ret

ErasePlayerCurrent:
            ; Erase player at current x position with a white 16x16 rectangle.
            mov.b   &player_x, &win_x0
            mov.b   #PLAYER_Y, &win_y0

            mov.b   &player_x, R12
            add.b   #PLAYER_LAST_X, R12
            mov.b   R12, &win_x1

            mov.b   #PLAYER_Y+PLAYER_LAST_Y, &win_y1

            mov.b   #0xFF, &cur_B
            mov.b   #0xFF, &cur_G
            mov.b   #0xFF, &cur_R

            mov.w   #PLAYER_PIXELS, R12
            call    #LCD_FillCurrentWindow
            ret

DrawLivesHUD:
            ; Draw three small life boxes at the top-left.
            mov.b   #LIFE1_X, &draw_x
            cmp.b   #1, &ship_lives
            jlo     DrawLife1Empty
            call    #DrawLifeFilled
            jmp     DrawLife2Check

DrawLife1Empty:
            call    #DrawLifeEmpty

DrawLife2Check:
            mov.b   #LIFE2_X, &draw_x
            cmp.b   #2, &ship_lives
            jlo     DrawLife2Empty
            call    #DrawLifeFilled
            jmp     DrawLife3Check

DrawLife2Empty:
            call    #DrawLifeEmpty

DrawLife3Check:
            mov.b   #LIFE3_X, &draw_x
            cmp.b   #3, &ship_lives
            jlo     DrawLife3Empty
            call    #DrawLifeFilled
            ret

DrawLife3Empty:
            call    #DrawLifeEmpty
            ret

DrawLifeFilled:
            ; Filled life icon = black 5x5 square.
            mov.b   &draw_x, R12
            mov.b   R12, &win_x0
            add.b   #4, R12
            mov.b   R12, &win_x1

            mov.b   #LIFE_ICON_Y, &win_y0
            mov.b   #LIFE_ICON_Y+4, &win_y1

            mov.b   #0x00, &cur_B
            mov.b   #0x00, &cur_G
            mov.b   #0x00, &cur_R

            mov.w   #LIFE_ICON_PIXELS, R12
            call    #LCD_FillCurrentWindow
            ret

DrawLifeEmpty:
            ; Empty life icon = white 5x5 square.
            mov.b   &draw_x, R12
            mov.b   R12, &win_x0
            add.b   #4, R12
            mov.b   R12, &win_x1

            mov.b   #LIFE_ICON_Y, &win_y0
            mov.b   #LIFE_ICON_Y+4, &win_y1

            mov.b   #0xFF, &cur_B
            mov.b   #0xFF, &cur_G
            mov.b   #0xFF, &cur_R

            mov.w   #LIFE_ICON_PIXELS, R12
            call    #LCD_FillCurrentWindow
            ret

;-------------------------------------------------------------------------------
; Score / final screens
;-------------------------------------------------------------------------------

AddAlienScore:
            ; Add fixed score when an alien is killed.
            mov.w   &score, R12
            add.w   #ALIEN_POINTS, R12
            mov.w   R12, &score
            ret

ShowWinScreen:
            ; Show final score on green screen, wait, then draw trophy.
            mov.b   #1, &game_over
            mov.b   #0, &bullet_active
            mov.b   #0, &enemy1_active
            mov.b   #0, &enemy2_active

            call    #ApplyWinMultiplier
            call    #LCD_FillScreenGreen
            call    #DrawFinalScore
            call    #DelayResultScreen4s
            call    #DrawWinTrophyScreen
            ret

ShowLoseScreen:
            ; Show final score on red screen, wait, then draw skull.
            mov.b   #1, &game_over
            mov.b   #0, &bullet_active
            mov.b   #0, &enemy1_active
            mov.b   #0, &enemy2_active

            call    #LCD_FillScreenRed
            call    #DrawFinalScore
            call    #DelayResultScreen4s
            call    #DrawLoseSkullScreen
            ret

ApplyWinMultiplier:
            ; If the player wins quickly, double the score.
            mov.w   &game_timer, R12
            cmp.w   #FAST_WIN_LIMIT, R12
            jhs     NoWinMultiplier

            mov.w   &score, R12
            rla.w   R12
            mov.w   R12, &score

NoWinMultiplier:
            ret

DelayResultScreen4s:
            ; Approximate 4-second delay between score screen and result art.
            mov.w   #170, R14

DelayResultOuter:
            mov.w   #60000, R15

DelayResultInner:
            dec.w   R15
            jnz     DelayResultInner

            dec.w   R14
            jnz     DelayResultOuter
            ret

DrawFinalScore:
            ; Convert score into 5 decimal digits and draw them.
            mov.w   &score, R12
            mov.w   R12, &score_work

            mov.b   #SCORE_START_X, &digit_x
            mov.b   #SCORE_START_Y, &digit_y

            mov.w   #10000, R13
            call    #DrawDigitFromBase
            add.b   #SCORE_DIGIT_SPACING, &digit_x

            mov.w   #1000, R13
            call    #DrawDigitFromBase
            add.b   #SCORE_DIGIT_SPACING, &digit_x

            mov.w   #100, R13
            call    #DrawDigitFromBase
            add.b   #SCORE_DIGIT_SPACING, &digit_x

            mov.w   #10, R13
            call    #DrawDigitFromBase
            add.b   #SCORE_DIGIT_SPACING, &digit_x

            mov.w   &score_work, R12
            call    #DrawDigitAtXY
            ret

DrawDigitFromBase:
            ; Repeated subtraction division.
            ; Input:
            ;   R13 = decimal base.
            ; Output:
            ;   R12 = digit.
            clr.w   R12

DigitBaseLoop:
            mov.w   &score_work, R14
            cmp.w   R13, R14
            jlo     DigitBaseDone

            sub.w   R13, R14
            mov.w   R14, &score_work
            inc.w   R12
            jmp     DigitBaseLoop

DigitBaseDone:
            call    #DrawDigitAtXY
            ret

DrawDigitAtXY:
            ; Draw one 3x5 digit scaled to 3x3 pixel blocks.
            mov.w   #DigitFont3x5, R11
            mov.w   R12, R14

DigitPtrLoop:
            cmp.w   #0, R14
            jeq     DigitPtrReady

            add.w   #5, R11
            dec.w   R14
            jmp     DigitPtrLoop

DigitPtrReady:
            clr.w   R6
            mov.w   #5, R5

DigitRowLoop:
            mov.b   @R11+, R13
            clr.w   R7
            mov.b   #0x04, R8

DigitColLoop:
            bit.b   R8, R13
            jz      DigitPixelSkip

            mov.b   &digit_x, R12
            mov.b   R7, R14
            add.b   R14, R14
            add.b   R7, R14
            add.b   R14, R12
            mov.b   R12, &pixel_x

            mov.b   &digit_y, R12
            mov.b   R6, R14
            add.b   R14, R14
            add.b   R6, R14
            add.b   R14, R12
            mov.b   R12, &pixel_y

            push.w  R5
            push.w  R6
            push.w  R7
            push.w  R8
            push.w  R11
            push.w  R13

            call    #DrawScaledScorePixel

            pop.w   R13
            pop.w   R11
            pop.w   R8
            pop.w   R7
            pop.w   R6
            pop.w   R5

DigitPixelSkip:
            rra.b   R8
            inc.w   R7
            cmp.w   #3, R7
            jlo     DigitColLoop

            inc.w   R6
            dec.w   R5
            jnz     DigitRowLoop
            ret

DrawScaledScorePixel:
            ; Draw one black 3x3 block used by score digits.
            mov.b   &pixel_x, R12
            mov.b   R12, &win_x0
            add.b   #2, R12
            mov.b   R12, &win_x1

            mov.b   &pixel_y, R12
            mov.b   R12, &win_y0
            add.b   #2, R12
            mov.b   R12, &win_y1

            mov.b   #0x00, &cur_B
            mov.b   #0x00, &cur_G
            mov.b   #0x00, &cur_R

            mov.w   #SCORE_PIXEL_PIXELS, R12
            call    #LCD_FillCurrentWindow
            ret

;-------------------------------------------------------------------------------
; Result art colors
;-------------------------------------------------------------------------------

SetColorBlack:
            mov.b   #0x00, &cur_B
            mov.b   #0x00, &cur_G
            mov.b   #0x00, &cur_R
            ret

SetColorWhite:
            mov.b   #0xFF, &cur_B
            mov.b   #0xFF, &cur_G
            mov.b   #0xFF, &cur_R
            ret

SetColorGold:
            mov.b   #0x20, &cur_B
            mov.b   #0xC8, &cur_G
            mov.b   #0xF2, &cur_R
            ret

SetColorBrown:
            mov.b   #0x20, &cur_B
            mov.b   #0x8A, &cur_G
            mov.b   #0xB8, &cur_R
            ret

SetColorBlueAccent:
            mov.b   #0xD0, &cur_B
            mov.b   #0x68, &cur_G
            mov.b   #0x08, &cur_R
            ret

SetColorShadowBlue:
            mov.b   #0xE0, &cur_B
            mov.b   #0x78, &cur_G
            mov.b   #0x10, &cur_R
            ret

DrawResultBlock:
            ; Draw one 4x4 result-art block using current color.
            mov.b   &draw_x, R12
            mov.b   R12, &win_x0
            add.b   #3, R12
            mov.b   R12, &win_x1

            mov.b   &draw_y, R12
            mov.b   R12, &win_y0
            add.b   #3, R12
            mov.b   R12, &win_y1

            mov.w   #RESULT_BLOCK_PIXELS, R12
            call    #LCD_FillCurrentWindow
            ret

;-------------------------------------------------------------------------------
; Win trophy screen
;-------------------------------------------------------------------------------

DrawWinTrophyScreen:
            ; Draw trophy and YOU WIN text.
            call    #LCD_FillScreenWhite

            ; Gold fill - cup.
            call    #SetColorGold
            result_block 5,1
            result_block 6,1
            result_block 7,1
            result_block 8,1
            result_block 9,1
            result_block 10,1
            result_block 11,1
            result_block 12,1

            result_block 4,2
            result_block 5,2
            result_block 6,2
            result_block 7,2
            result_block 8,2
            result_block 9,2
            result_block 10,2
            result_block 11,2
            result_block 12,2
            result_block 13,2

            result_block 4,3
            result_block 5,3
            result_block 6,3
            result_block 7,3
            result_block 8,3
            result_block 9,3
            result_block 10,3
            result_block 11,3
            result_block 12,3
            result_block 13,3

            result_block 4,4
            result_block 5,4
            result_block 6,4
            result_block 7,4
            result_block 8,4
            result_block 9,4
            result_block 10,4
            result_block 11,4
            result_block 12,4
            result_block 13,4

            result_block 5,5
            result_block 6,5
            result_block 7,5
            result_block 8,5
            result_block 9,5
            result_block 10,5
            result_block 11,5
            result_block 12,5

            result_block 6,6
            result_block 7,6
            result_block 8,6
            result_block 9,6
            result_block 10,6
            result_block 11,6

            result_block 7,7
            result_block 8,7
            result_block 9,7
            result_block 10,7

            ; Handles.
            result_block 2,2
            result_block 2,3
            result_block 2,4
            result_block 3,2
            result_block 3,4

            result_block 14,2
            result_block 14,3
            result_block 14,4
            result_block 15,2
            result_block 15,4

            ; Stem and base.
            result_block 8,8
            result_block 9,8
            result_block 8,9
            result_block 9,9
            result_block 7,10
            result_block 8,10
            result_block 9,10
            result_block 10,10

            result_block 6,11
            result_block 7,11
            result_block 8,11
            result_block 9,11
            result_block 10,11
            result_block 11,11

            ; Brown shadow.
            call    #SetColorBrown
            result_block 11,2
            result_block 12,2
            result_block 13,2
            result_block 11,3
            result_block 12,3
            result_block 13,3
            result_block 11,4
            result_block 12,4
            result_block 13,4
            result_block 10,5
            result_block 11,5
            result_block 12,5
            result_block 10,6
            result_block 11,6
            result_block 9,7
            result_block 10,7
            result_block 9,8
            result_block 9,9

            ; White highlight.
            call    #SetColorWhite
            result_block 5,2
            result_block 6,2
            result_block 5,3
            result_block 5,4
            result_block 5,5
            result_block 6,5
            result_block 5,6

            ; Blue base.
            call    #SetColorBlueAccent
            result_block 5,12
            result_block 6,12
            result_block 7,12
            result_block 8,12
            result_block 9,12
            result_block 10,12
            result_block 11,12
            result_block 12,12

            ; Black outline.
            call    #SetColorBlack
            result_block 4,1
            result_block 5,1
            result_block 6,1
            result_block 7,1
            result_block 8,1
            result_block 9,1
            result_block 10,1
            result_block 11,1
            result_block 12,1
            result_block 13,1

            result_block 3,2
            result_block 4,2
            result_block 13,2
            result_block 14,2

            result_block 3,3
            result_block 4,3
            result_block 13,3
            result_block 14,3

            result_block 3,4
            result_block 4,4
            result_block 13,4
            result_block 14,4

            result_block 4,5
            result_block 5,5
            result_block 12,5
            result_block 13,5

            result_block 5,6
            result_block 6,6
            result_block 11,6
            result_block 12,6

            result_block 6,7
            result_block 7,7
            result_block 10,7
            result_block 11,7

            ; Handle outline.
            result_block 1,2
            result_block 2,2
            result_block 1,3
            result_block 2,4
            result_block 1,5
            result_block 2,5

            result_block 15,2
            result_block 16,2
            result_block 16,3
            result_block 15,4
            result_block 16,5
            result_block 15,5

            ; Stem/base outline.
            result_block 7,8
            result_block 8,8
            result_block 9,8
            result_block 10,8
            result_block 7,9
            result_block 10,9
            result_block 7,10
            result_block 10,10
            result_block 5,11
            result_block 6,11
            result_block 11,11
            result_block 12,11
            result_block 4,12
            result_block 5,12
            result_block 12,12
            result_block 13,12

            ; Sparkles.
            result_block 1,0
            result_block 0,1
            result_block 1,1
            result_block 2,1
            result_block 1,2

            result_block 16,0
            result_block 15,1
            result_block 16,1
            result_block 17,1
            result_block 16,2

            result_block 15,5
            result_block 14,6
            result_block 15,6
            result_block 16,6
            result_block 15,7

            call    #DrawYouWinText
            ret

;-------------------------------------------------------------------------------
; Lose skull screen
;-------------------------------------------------------------------------------

DrawLoseSkullScreen:
            ; Draw skull and GAME OVER text.
            call    #LCD_FillScreenWhite

            call    #SetColorBlack

            ; Skull head.
            result_block 7,1
            result_block 8,1
            result_block 9,1
            result_block 10,1

            result_block 6,2
            result_block 7,2
            result_block 8,2
            result_block 9,2
            result_block 10,2
            result_block 11,2

            result_block 5,3
            result_block 6,3
            result_block 7,3
            result_block 8,3
            result_block 9,3
            result_block 10,3
            result_block 11,3
            result_block 12,3

            result_block 5,4
            result_block 6,4
            result_block 7,4
            result_block 8,4
            result_block 9,4
            result_block 10,4
            result_block 11,4
            result_block 12,4

            result_block 6,5
            result_block 7,5
            result_block 8,5
            result_block 9,5
            result_block 10,5
            result_block 11,5

            result_block 6,6
            result_block 7,6
            result_block 8,6
            result_block 9,6
            result_block 10,6
            result_block 11,6

            ; Jaw.
            result_block 6,7
            result_block 7,7
            result_block 8,7
            result_block 9,7
            result_block 10,7
            result_block 11,7

            ; Teeth.
            result_block 7,8
            result_block 8,8
            result_block 9,8
            result_block 10,8

            ; Side bones.
            result_block 3,2
            result_block 4,3
            result_block 3,4

            result_block 14,2
            result_block 13,3
            result_block 14,4

            result_block 3,6
            result_block 4,6
            result_block 3,7

            result_block 14,6
            result_block 13,6
            result_block 14,7

            ; Eye holes and nose are white overlays.
            call    #SetColorWhite
            result_block 7,3
            result_block 8,3
            result_block 9,3
            result_block 10,3

            result_block 7,4
            result_block 8,4
            result_block 9,4
            result_block 10,4

            result_block 8,5
            result_block 9,5

            ; Repaint black pixels for skull shape.
            call    #SetColorBlack
            result_block 9,3
            result_block 8,5
            result_block 9,5

            call    #DrawGameOverText
            ret

;-------------------------------------------------------------------------------
; Result text drawing
;-------------------------------------------------------------------------------

DrawYouWinText:
            ; Draw blue shadow first.
            call    #SetColorShadowBlue
            mov.b   #RESULT_TEXT_YW_X+1, &digit_x
            mov.b   #RESULT_TEXT_YW_Y+1, &digit_y

            mov.w   #0, R12
            call    #DrawResultLetterAtXY
            add.b   #RESULT_TEXT_SPACING, &digit_x

            mov.w   #1, R12
            call    #DrawResultLetterAtXY
            add.b   #RESULT_TEXT_SPACING, &digit_x

            mov.w   #2, R12
            call    #DrawResultLetterAtXY
            add.b   #12, &digit_x

            mov.w   #3, R12
            call    #DrawResultLetterAtXY
            add.b   #RESULT_TEXT_SPACING, &digit_x

            mov.w   #4, R12
            call    #DrawResultLetterAtXY
            add.b   #RESULT_TEXT_SPACING, &digit_x

            mov.w   #5, R12
            call    #DrawResultLetterAtXY
            add.b   #RESULT_TEXT_SPACING, &digit_x

            mov.w   #12, R12
            call    #DrawResultLetterAtXY

            ; Draw black foreground text.
            call    #SetColorBlack
            mov.b   #RESULT_TEXT_YW_X, &digit_x
            mov.b   #RESULT_TEXT_YW_Y, &digit_y

            mov.w   #0, R12
            call    #DrawResultLetterAtXY
            add.b   #RESULT_TEXT_SPACING, &digit_x

            mov.w   #1, R12
            call    #DrawResultLetterAtXY
            add.b   #RESULT_TEXT_SPACING, &digit_x

            mov.w   #2, R12
            call    #DrawResultLetterAtXY
            add.b   #12, &digit_x

            mov.w   #3, R12
            call    #DrawResultLetterAtXY
            add.b   #RESULT_TEXT_SPACING, &digit_x

            mov.w   #4, R12
            call    #DrawResultLetterAtXY
            add.b   #RESULT_TEXT_SPACING, &digit_x

            mov.w   #5, R12
            call    #DrawResultLetterAtXY
            add.b   #RESULT_TEXT_SPACING, &digit_x

            mov.w   #12, R12
            call    #DrawResultLetterAtXY
            ret

DrawGameOverText:
            ; Draw blue shadow first.
            call    #SetColorShadowBlue
            mov.b   #RESULT_TEXT_GO_X+1, &digit_x
            mov.b   #RESULT_TEXT_GO_Y+1, &digit_y

            mov.w   #6, R12
            call    #DrawResultLetterAtXY
            add.b   #RESULT_TEXT_SPACING, &digit_x

            mov.w   #7, R12
            call    #DrawResultLetterAtXY
            add.b   #RESULT_TEXT_SPACING, &digit_x

            mov.w   #8, R12
            call    #DrawResultLetterAtXY
            add.b   #RESULT_TEXT_SPACING, &digit_x

            mov.w   #9, R12
            call    #DrawResultLetterAtXY
            add.b   #12, &digit_x

            mov.w   #1, R12
            call    #DrawResultLetterAtXY
            add.b   #RESULT_TEXT_SPACING, &digit_x

            mov.w   #10, R12
            call    #DrawResultLetterAtXY
            add.b   #RESULT_TEXT_SPACING, &digit_x

            mov.w   #9, R12
            call    #DrawResultLetterAtXY
            add.b   #RESULT_TEXT_SPACING, &digit_x

            mov.w   #11, R12
            call    #DrawResultLetterAtXY

            ; Draw black foreground text.
            call    #SetColorBlack
            mov.b   #RESULT_TEXT_GO_X, &digit_x
            mov.b   #RESULT_TEXT_GO_Y, &digit_y

            mov.w   #6, R12
            call    #DrawResultLetterAtXY
            add.b   #RESULT_TEXT_SPACING, &digit_x

            mov.w   #7, R12
            call    #DrawResultLetterAtXY
            add.b   #RESULT_TEXT_SPACING, &digit_x

            mov.w   #8, R12
            call    #DrawResultLetterAtXY
            add.b   #RESULT_TEXT_SPACING, &digit_x

            mov.w   #9, R12
            call    #DrawResultLetterAtXY
            add.b   #12, &digit_x

            mov.w   #1, R12
            call    #DrawResultLetterAtXY
            add.b   #RESULT_TEXT_SPACING, &digit_x

            mov.w   #10, R12
            call    #DrawResultLetterAtXY
            add.b   #RESULT_TEXT_SPACING, &digit_x

            mov.w   #9, R12
            call    #DrawResultLetterAtXY
            add.b   #RESULT_TEXT_SPACING, &digit_x

            mov.w   #11, R12
            call    #DrawResultLetterAtXY
            ret

DrawResultLetterAtXY:
            ; Draw one result-screen letter from ResultLetterFont3x5.
            mov.w   #ResultLetterFont3x5, R11
            mov.w   R12, R14

ResultLetterPtrLoop:
            cmp.w   #0, R14
            jeq     ResultLetterPtrReady
            add.w   #5, R11
            dec.w   R14
            jmp     ResultLetterPtrLoop

ResultLetterPtrReady:
            clr.w   R6
            mov.w   #5, R5

ResultLetterRowLoop:
            mov.b   @R11+, R13
            clr.w   R7
            mov.b   #0x04, R8

ResultLetterColLoop:
            bit.b   R8, R13
            jz      ResultLetterPixelSkip

            mov.b   &digit_x, R12
            mov.b   R7, R14
            add.b   R14, R14
            add.b   R7, R14
            add.b   R14, R12
            mov.b   R12, &pixel_x

            mov.b   &digit_y, R12
            mov.b   R6, R14
            add.b   R14, R14
            add.b   R6, R14
            add.b   R14, R12
            mov.b   R12, &pixel_y

            push.w  R5
            push.w  R6
            push.w  R7
            push.w  R8
            push.w  R11
            push.w  R13

            call    #DrawResultTextPixel

            pop.w   R13
            pop.w   R11
            pop.w   R8
            pop.w   R7
            pop.w   R6
            pop.w   R5

ResultLetterPixelSkip:
            rra.b   R8
            inc.w   R7
            cmp.w   #3, R7
            jlo     ResultLetterColLoop

            inc.w   R6
            dec.w   R5
            jnz     ResultLetterRowLoop
            ret

DrawResultTextPixel:
            ; Draw one 3x3 pixel block using the current text color.
            mov.b   &pixel_x, R12
            mov.b   R12, &win_x0
            add.b   #2, R12
            mov.b   R12, &win_x1

            mov.b   &pixel_y, R12
            mov.b   R12, &win_y0
            add.b   #2, R12
            mov.b   R12, &win_y1

            mov.w   #RESULT_TEXT_PIXELS, R12
            call    #LCD_FillCurrentWindow
            ret

;-------------------------------------------------------------------------------
; Formation movement
;-------------------------------------------------------------------------------

UpdateFormation:
            ; Move alien formation only every FORMATION_DELAY frames.
            cmp.b   #1, &game_over
            jeq     FormationDone

            cmp.b   #0, &aliens_remaining
            jeq     FormationDone

            inc.b   &formation_tick
            cmp.b   #FORMATION_DELAY, &formation_tick
            jlo     FormationDone

            mov.b   #0, &formation_tick
            inc.w   &game_timer

            ; Save old formation position before erasing.
            mov.b   &formation_x, R12
            mov.b   R12, &old_formation_x
            mov.b   &formation_y, R12
            mov.b   R12, &old_formation_y

            call    #EraseAllOldAlienCells

            ; formation_dir = 0 -> right, 1 -> left.
            cmp.b   #0, &formation_dir
            jne     MoveFormationLeft

MoveFormationRight:
            ; Move right until the right boundary is reached.
            cmp.b   #FORMATION_MAX_X, &formation_x
            jhs     DropAndGoLeft

            add.b   #FORMATION_STEP, &formation_x

            cmp.b   #FORMATION_MAX_X, &formation_x
            jlo     ShiftWithRightFlow

            mov.b   #FORMATION_MAX_X, &formation_x

ShiftWithRightFlow:
            call    #ShiftRowsWithFlowOneStep
            jmp     FormationMoved

DropAndGoLeft:
            ; At right edge, move down and switch direction.
            add.b   #FORMATION_DROP, &formation_y
            mov.b   #1, &formation_dir
            jmp     FormationMoved

MoveFormationLeft:
            ; Move left until the left boundary is reached.
            cmp.b   #FORMATION_MIN_X, &formation_x
            jeq     DropAndGoRight

            cmp.b   #FORMATION_STEP, &formation_x
            jlo     SetFormationLeftEdge

            sub.b   #FORMATION_STEP, &formation_x
            jmp     ShiftWithLeftFlow

SetFormationLeftEdge:
            mov.b   #FORMATION_MIN_X, &formation_x

ShiftWithLeftFlow:
            call    #ShiftRowsWithFlowOneStep
            jmp     FormationMoved

DropAndGoRight:
            ; At left edge, move down and switch direction.
            add.b   #FORMATION_DROP, &formation_y
            mov.b   #0, &formation_dir

FormationMoved:
            ; Check invasion line, then redraw formation and active objects.
            call    #CheckFormationGameOver

            cmp.b   #1, &game_over
            jeq     FormationDone

            call    #DrawAllAlienCells

            cmp.b   #1, &bullet_active
            jne     RedrawEnemy1AfterFormation
            call    #DrawBullet

RedrawEnemy1AfterFormation:
            cmp.b   #1, &enemy1_active
            jne     RedrawEnemy2AfterFormation
            call    #DrawEnemy1Bullet

RedrawEnemy2AfterFormation:
            cmp.b   #1, &enemy2_active
            jne     RedrawLivesAfterFormation
            call    #DrawEnemy2Bullet

RedrawLivesAfterFormation:
            call    #DrawLivesHUD

FormationDone:
            ret

CheckFormationGameOver:
            ; If the formation moves too low, the player loses.
            cmp.b   #GAME_OVER_FORM_Y, &formation_y
            jlo     NotGameOverYet

            mov.b   #1, &game_over
            mov.b   #0, &bullet_active
            mov.b   #0, &enemy1_active
            mov.b   #0, &enemy2_active

            call    #ShowLoseScreen

NotGameOverYet:
            ret

;-------------------------------------------------------------------------------
; Alien array shifting
;-------------------------------------------------------------------------------

ShiftRowsWithFlowOneStep:
            ; Move empty spaces through each row according to the current direction.
            cmp.b   #0, &formation_dir
            jeq     ShiftRowsRightFlow
            jmp     ShiftRowsLeftFlow

ShiftRowsRightFlow:
            ; If a row contains pattern 1,0 then change it to 0,1.
            ; This makes aliens flow into empty spaces while moving right.
            mov.w   #AlienAliveArr, R10
            mov.w   #ALIEN_ROWS, R6

ShiftRightRowLoop:
            mov.w   R10, R11
            mov.w   #5, R5

ShiftRightPairLoop:
            mov.b   0(R11), R12
            cmp.b   #1, R12
            jne     ShiftRightNextPair

            mov.b   1(R11), R13
            cmp.b   #0, R13
            jne     ShiftRightNextPair

            mov.b   #0, 0(R11)
            mov.b   #1, 1(R11)
            jmp     ShiftRightNextRow

ShiftRightNextPair:
            inc.w   R11
            dec.w   R5
            jnz     ShiftRightPairLoop

ShiftRightNextRow:
            add.w   #ALIEN_COLS, R10
            dec.w   R6
            jnz     ShiftRightRowLoop
            ret

ShiftRowsLeftFlow:
            ; If a row contains pattern 0,1 then change it to 1,0.
            ; This makes aliens flow into empty spaces while moving left.
            mov.w   #AlienAliveArr, R10
            mov.w   #ALIEN_ROWS, R6

ShiftLeftRowLoop:
            mov.w   R10, R11
            mov.w   #5, R5

ShiftLeftPairLoop:
            mov.b   0(R11), R12
            cmp.b   #0, R12
            jne     ShiftLeftNextPair

            mov.b   1(R11), R13
            cmp.b   #1, R13
            jne     ShiftLeftNextPair

            mov.b   #1, 0(R11)
            mov.b   #0, 1(R11)
            jmp     ShiftLeftNextRow

ShiftLeftNextPair:
            inc.w   R11
            dec.w   R5
            jnz     ShiftLeftPairLoop

ShiftLeftNextRow:
            add.w   #ALIEN_COLS, R10
            dec.w   R6
            jnz     ShiftLeftRowLoop
            ret

;-------------------------------------------------------------------------------
; Collision: player bullet vs alien
;-------------------------------------------------------------------------------

CheckBulletAlienCollision:
            ; Test player bullet against every alive alien cell.
            cmp.b   #0, &aliens_remaining
            jeq     NoAlienHit

            mov.w   #AlienAliveArr, R10
            mov.w   #AlienRowOffsets, R7
            mov.w   #ALIEN_ROWS, R6

CollisionRowLoop:
            mov.b   @R7+, R8
            mov.w   #AlienColOffsets, R9
            mov.w   #ALIEN_COLS, R5

CollisionColLoop:
            mov.b   @R10+, R12
            mov.b   @R9+, R13

            cmp.b   #0, R12
            jeq     CollisionNextCol

            mov.b   &formation_x, R14
            add.b   R13, R14
            mov.b   R14, &draw_x

            mov.b   &formation_y, R15
            add.b   R8, R15
            mov.b   R15, &draw_y

            ; Bounding-box collision test.
            clr.w   R4
            mov.b   &draw_x, R4
            add.w   #16, R4
            cmp.b   R4, &bullet_x
            jhs     CollisionNextCol

            clr.w   R4
            mov.b   &bullet_x, R4
            add.w   #BULLET_LAST_X, R4
            cmp.b   &draw_x, R4
            jlo     CollisionNextCol

            clr.w   R4
            mov.b   &draw_y, R4
            add.w   #16, R4
            cmp.b   R4, &bullet_y
            jhs     CollisionNextCol

            clr.w   R4
            mov.b   &bullet_y, R4
            add.w   #BULLET_LAST_Y, R4
            cmp.b   &draw_y, R4
            jlo     CollisionNextCol

            ; Hit found.
            mov.b   #0, &bullet_active

            dec.w   R10
            mov.b   #0, 0(R10)
            inc.w   R10

            dec.b   &aliens_remaining

            call    #AddAlienScore
            call    #EraseAlienAt

            cmp.b   #0, &aliens_remaining
            jne     AlienHitReturn

            call    #ShowWinScreen

AlienHitReturn:
            ret

CollisionNextCol:
            dec.w   R5
            jnz     CollisionColLoop

            dec.w   R6
            jnz     CollisionRowLoop

NoAlienHit:
            ret

;-------------------------------------------------------------------------------
; Alien cells
;-------------------------------------------------------------------------------

DrawAllAlienCells:
            ; Draw or erase all alien cells based on AlienAliveArr.
            mov.w   #AlienAliveArr, R10
            mov.w   #AlienRowOffsets, R7
            mov.w   #ALIEN_ROWS, R6

DrawCellRowLoop:
            mov.b   @R7+, R8
            mov.w   #AlienColOffsets, R9
            mov.w   #ALIEN_COLS, R5

DrawCellColLoop:
            mov.b   @R10+, R12
            mov.b   @R9+, R13

            mov.b   &formation_x, R14
            add.b   R13, R14
            mov.b   R14, &draw_x

            mov.b   &formation_y, R15
            add.b   R8, R15
            mov.b   R15, &draw_y

            push.w  R5
            push.w  R6
            push.w  R7
            push.w  R8
            push.w  R9
            push.w  R10

            cmp.b   #0, R12
            jeq     DrawEmptyCell
            call    #DrawAlienAt
            jmp     DrawCellReturn

DrawEmptyCell:
            call    #EraseAlienAt

DrawCellReturn:
            pop.w   R10
            pop.w   R9
            pop.w   R8
            pop.w   R7
            pop.w   R6
            pop.w   R5

            dec.w   R5
            jnz     DrawCellColLoop

            dec.w   R6
            jnz     DrawCellRowLoop
            ret

EraseAllOldAlienCells:
            ; Erase every possible alien cell at the previous formation position.
            mov.w   #AlienRowOffsets, R7
            mov.w   #ALIEN_ROWS, R6

EraseOldCellRowLoop:
            mov.b   @R7+, R8
            mov.w   #AlienColOffsets, R9
            mov.w   #ALIEN_COLS, R5

EraseOldCellColLoop:
            mov.b   @R9+, R13

            mov.b   &old_formation_x, R14
            add.b   R13, R14
            mov.b   R14, &draw_x

            mov.b   &old_formation_y, R15
            add.b   R8, R15
            mov.b   R15, &draw_y

            push.w  R5
            push.w  R6
            push.w  R7
            push.w  R8
            push.w  R9

            call    #EraseAlienAt

            pop.w   R9
            pop.w   R8
            pop.w   R7
            pop.w   R6
            pop.w   R5

            dec.w   R5
            jnz     EraseOldCellColLoop

            dec.w   R6
            jnz     EraseOldCellRowLoop
            ret

;-------------------------------------------------------------------------------
; Alien sprite draw / erase
;-------------------------------------------------------------------------------

DrawAlienAt:
            ; Draw 16x16 alien sprite at draw_x, draw_y.
            mov.b   &draw_x, R12
            mov.b   R12, &win_x0
            add.b   #15, R12
            mov.b   R12, &win_x1

            mov.b   &draw_y, R12
            mov.b   R12, &win_y0
            add.b   #15, R12
            mov.b   R12, &win_y1

            call    #LCD_SetWindow

            mov.w   #16, R4
            mov.w   #15, R5

AlienSpriteRowLoop:
            mov.w   #0, R6

AlienSpriteColLoop:
            cmp.w   #16, R6
            jhs     AlienNextRow

            mov.w   #AlienSprite, R11
            add.w   R6, R11

            mov.w   R5, R10
            cmp.w   #8, R10
            jlo     AlienTopHalf

            add.w   #16, R11
            sub.w   #8, R10

AlienTopHalf:
            mov.w   #MaskTable, R13
            add.w   R10, R13

            mov.b   0(R11), R12
            mov.b   0(R13), R14

            bit.b   R14, R12
            jz      AlienPixelWhite

AlienPixelPurple:
            ; Purple pixel: BGR = FF 00 FF.
            mov.b   #0xFF, R15
            call    #tft_data_sr
            mov.b   #0x00, R15
            call    #tft_data_sr
            mov.b   #0xFF, R15
            call    #tft_data_sr
            jmp     AlienPixelDone

AlienPixelWhite:
            ; Background pixel: white.
            mov.b   #0xFF, R15
            call    #tft_data_sr
            mov.b   #0xFF, R15
            call    #tft_data_sr
            mov.b   #0xFF, R15
            call    #tft_data_sr

AlienPixelDone:
            inc.w   R6
            jmp     AlienSpriteColLoop

AlienNextRow:
            dec.w   R5
            dec.w   R4
            jnz     AlienSpriteRowLoop
            ret

EraseAlienAt:
            ; Erase one 16x16 alien cell with white.
            mov.b   &draw_x, R12
            mov.b   R12, &win_x0
            add.b   #15, R12
            mov.b   R12, &win_x1

            mov.b   &draw_y, R12
            mov.b   R12, &win_y0
            add.b   #15, R12
            mov.b   R12, &win_y1

            mov.b   #0xFF, &cur_B
            mov.b   #0xFF, &cur_G
            mov.b   #0xFF, &cur_R

            mov.w   #ALIEN_PIXELS, R12
            call    #LCD_FillCurrentWindow
            ret

;-------------------------------------------------------------------------------
; Player sprite
;-------------------------------------------------------------------------------

DrawPlayer:
            ; Draw 16x16 player ship sprite at player_x, PLAYER_Y.
            mov.b   &player_x, &win_x0
            mov.b   #PLAYER_Y, &win_y0

            mov.b   &player_x, R12
            add.b   #PLAYER_LAST_X, R12
            mov.b   R12, &win_x1

            mov.b   #PLAYER_Y+PLAYER_LAST_Y, &win_y1

            call    #LCD_SetWindow

            mov.w   #16, R4
            mov.w   #15, R5

PlayerSpriteRowLoop:
            mov.w   #0, R6

PlayerSpriteColLoop:
            cmp.w   #16, R6
            jhs     PlayerNextRow

            mov.w   #PlayerShip, R11
            add.w   R6, R11

            mov.w   R5, R10
            cmp.w   #8, R10
            jlo     PlayerTopHalf

            add.w   #16, R11
            sub.w   #8, R10

PlayerTopHalf:
            mov.w   #MaskTable, R13
            add.w   R10, R13

            mov.b   0(R11), R12
            mov.b   0(R13), R14

            bit.b   R14, R12
            jz      PlayerPixelWhite

PlayerPixelBlack:
            ; Ship pixel: black.
            mov.b   #0x00, R15
            call    #tft_data_sr
            mov.b   #0x00, R15
            call    #tft_data_sr
            mov.b   #0x00, R15
            call    #tft_data_sr
            jmp     PlayerPixelDone

PlayerPixelWhite:
            ; Background pixel: white.
            mov.b   #0xFF, R15
            call    #tft_data_sr
            mov.b   #0xFF, R15
            call    #tft_data_sr
            mov.b   #0xFF, R15
            call    #tft_data_sr

PlayerPixelDone:
            inc.w   R6
            jmp     PlayerSpriteColLoop

PlayerNextRow:
            dec.w   R5
            dec.w   R4
            jnz     PlayerSpriteRowLoop
            ret

EraseOldPlayer:
            ; Erase player at old_player_x.
            mov.b   &old_player_x, &win_x0
            mov.b   #PLAYER_Y, &win_y0

            mov.b   &old_player_x, R12
            add.b   #PLAYER_LAST_X, R12
            mov.b   R12, &win_x1

            mov.b   #PLAYER_Y+PLAYER_LAST_Y, &win_y1

            mov.b   #0xFF, &cur_B
            mov.b   #0xFF, &cur_G
            mov.b   #0xFF, &cur_R

            mov.w   #PLAYER_PIXELS, R12
            call    #LCD_FillCurrentWindow
            ret

;-------------------------------------------------------------------------------
; Bullet draw / erase
;-------------------------------------------------------------------------------

DrawBullet:
            ; Draw red player bullet.
            mov.b   &bullet_x, R12
            mov.b   R12, &win_x0
            add.b   #BULLET_LAST_X, R12
            mov.b   R12, &win_x1

            mov.b   &bullet_y, R12
            mov.b   R12, &win_y0
            add.b   #BULLET_LAST_Y, R12
            mov.b   R12, &win_y1

            ; Red in BGR order.
            mov.b   #0x00, &cur_B
            mov.b   #0x00, &cur_G
            mov.b   #0xFF, &cur_R

            mov.w   #BULLET_PIXELS, R12
            call    #LCD_FillCurrentWindow
            ret

EraseBullet:
            ; Erase previous player bullet position.
            mov.b   &bullet_x, R12
            mov.b   R12, &win_x0
            add.b   #BULLET_LAST_X, R12
            mov.b   R12, &win_x1

            mov.b   &old_bullet_y, R12
            mov.b   R12, &win_y0
            add.b   #BULLET_LAST_Y, R12
            mov.b   R12, &win_y1

            mov.b   #0xFF, &cur_B
            mov.b   #0xFF, &cur_G
            mov.b   #0xFF, &cur_R

            mov.w   #BULLET_PIXELS, R12
            call    #LCD_FillCurrentWindow
            ret

DrawEnemy1Bullet:
            ; Draw enemy laser 1 in dark blue.
            mov.b   &enemy1_x, R12
            mov.b   R12, &win_x0
            add.b   #ENEMY_BULLET_LAST_X, R12
            mov.b   R12, &win_x1

            mov.b   &enemy1_y, R12
            mov.b   R12, &win_y0
            add.b   #ENEMY_BULLET_LAST_Y, R12
            mov.b   R12, &win_y1

            ; Dark blue in BGR order.
            mov.b   #0x90, &cur_B
            mov.b   #0x00, &cur_G
            mov.b   #0x00, &cur_R

            mov.w   #ENEMY_BULLET_PIXELS, R12
            call    #LCD_FillCurrentWindow
            ret

EraseEnemy1Bullet:
            ; Erase previous enemy laser 1 position.
            mov.b   &enemy1_x, R12
            mov.b   R12, &win_x0
            add.b   #ENEMY_BULLET_LAST_X, R12
            mov.b   R12, &win_x1

            mov.b   &old_enemy1_y, R12
            mov.b   R12, &win_y0
            add.b   #ENEMY_BULLET_LAST_Y, R12
            mov.b   R12, &win_y1

            mov.b   #0xFF, &cur_B
            mov.b   #0xFF, &cur_G
            mov.b   #0xFF, &cur_R

            mov.w   #ENEMY_BULLET_PIXELS, R12
            call    #LCD_FillCurrentWindow
            ret

DrawEnemy2Bullet:
            ; Draw enemy laser 2 in dark blue.
            mov.b   &enemy2_x, R12
            mov.b   R12, &win_x0
            add.b   #ENEMY_BULLET_LAST_X, R12
            mov.b   R12, &win_x1

            mov.b   &enemy2_y, R12
            mov.b   R12, &win_y0
            add.b   #ENEMY_BULLET_LAST_Y, R12
            mov.b   R12, &win_y1

            ; Dark blue in BGR order.
            mov.b   #0x90, &cur_B
            mov.b   #0x00, &cur_G
            mov.b   #0x00, &cur_R

            mov.w   #ENEMY_BULLET_PIXELS, R12
            call    #LCD_FillCurrentWindow
            ret

EraseEnemy2Bullet:
            ; Erase previous enemy laser 2 position.
            mov.b   &enemy2_x, R12
            mov.b   R12, &win_x0
            add.b   #ENEMY_BULLET_LAST_X, R12
            mov.b   R12, &win_x1

            mov.b   &old_enemy2_y, R12
            mov.b   R12, &win_y0
            add.b   #ENEMY_BULLET_LAST_Y, R12
            mov.b   R12, &win_y1

            mov.b   #0xFF, &cur_B
            mov.b   #0xFF, &cur_G
            mov.b   #0xFF, &cur_R

            mov.w   #ENEMY_BULLET_PIXELS, R12
            call    #LCD_FillCurrentWindow
            ret

;-------------------------------------------------------------------------------
; Screen fill helpers
;-------------------------------------------------------------------------------

LCD_FillScreenBlack:
            ; Fill entire 128x128 screen with black.
            mov.b   #0, &win_x0
            mov.b   #0, &win_y0
            mov.b   #127, &win_x1
            mov.b   #127, &win_y1

            call    #LCD_SetWindow
            mov.w   #16384, R12

FillBlackLoop:
            mov.b   #0x00, R15
            call    #tft_data_sr
            mov.b   #0x00, R15
            call    #tft_data_sr
            mov.b   #0x00, R15
            call    #tft_data_sr
            dec.w   R12
            jnz     FillBlackLoop
            ret

LCD_FillScreenWhite:
            ; Fill entire 128x128 screen with white.
            mov.b   #0, &win_x0
            mov.b   #0, &win_y0
            mov.b   #127, &win_x1
            mov.b   #127, &win_y1

            call    #LCD_SetWindow
            mov.w   #16384, R12

FillWhiteLoop:
            mov.b   #0xFF, R15
            call    #tft_data_sr
            mov.b   #0xFF, R15
            call    #tft_data_sr
            mov.b   #0xFF, R15
            call    #tft_data_sr
            dec.w   R12
            jnz     FillWhiteLoop
            ret

LCD_FillScreenRed:
            ; Fill entire 128x128 screen with red.
            mov.b   #0, &win_x0
            mov.b   #0, &win_y0
            mov.b   #127, &win_x1
            mov.b   #127, &win_y1

            call    #LCD_SetWindow
            mov.w   #16384, R12

FillRedLoop:
            mov.b   #0x00, R15
            call    #tft_data_sr
            mov.b   #0x00, R15
            call    #tft_data_sr
            mov.b   #0xFF, R15
            call    #tft_data_sr
            dec.w   R12
            jnz     FillRedLoop
            ret

LCD_FillScreenGreen:
            ; Fill entire 128x128 screen with green.
            mov.b   #0, &win_x0
            mov.b   #0, &win_y0
            mov.b   #127, &win_x1
            mov.b   #127, &win_y1

            call    #LCD_SetWindow
            mov.w   #16384, R12

FillGreenLoop:
            mov.b   #0x00, R15
            call    #tft_data_sr
            mov.b   #0xFF, R15
            call    #tft_data_sr
            mov.b   #0x00, R15
            call    #tft_data_sr
            dec.w   R12
            jnz     FillGreenLoop
            ret

LCD_FillCurrentWindow:
            ; Fill the current window with current BGR color.
            ; R12 must contain number of pixels to write.
            call    #LCD_SetWindow

FillWindowLoop:
            mov.b   &cur_B, R15
            call    #tft_data_sr
            mov.b   &cur_G, R15
            call    #tft_data_sr
            mov.b   &cur_R, R15
            call    #tft_data_sr

            dec.w   R12
            jnz     FillWindowLoop
            ret

;-------------------------------------------------------------------------------
; LCD_SetWindow
;-------------------------------------------------------------------------------

LCD_SetWindow:
            ; Configure LCD column and row address window.
            ; All following pixel writes go into this rectangle.
            mov.b   #0x2A, R15
            call    #tft_cmd_sr

            mov.b   #0x00, R15
            call    #tft_data_sr

            clr.w   R14
            mov.b   &win_x0, R14
            add.w   #2, R14
            mov.b   R14, R15
            call    #tft_data_sr

            mov.b   #0x00, R15
            call    #tft_data_sr

            clr.w   R14
            mov.b   &win_x1, R14
            add.w   #2, R14
            mov.b   R14, R15
            call    #tft_data_sr

            mov.b   #0x2B, R15
            call    #tft_cmd_sr

            mov.b   #0x00, R15
            call    #tft_data_sr

            ; Y coordinates are transformed for this LCD orientation.
            clr.w   R14
            mov.b   #127, R14
            clr.w   R13
            mov.b   &win_y1, R13
            sub.w   R13, R14
            add.w   #1, R14
            mov.b   R14, R15
            call    #tft_data_sr

            mov.b   #0x00, R15
            call    #tft_data_sr

            clr.w   R14
            mov.b   #127, R14
            clr.w   R13
            mov.b   &win_y0, R13
            sub.w   R13, R14
            add.w   #1, R14
            mov.b   R14, R15
            call    #tft_data_sr

            mov.b   #0x2C, R15
            call    #tft_cmd_sr
            ret

;-------------------------------------------------------------------------------
; LCD low-level functions
;-------------------------------------------------------------------------------

LCD_Reset:
            ; Hardware reset pulse for LCD controller.
            RST_LOW
            delay   3000
            RST_HIGH
            delay   60000
            delay   60000
            ret

LCD_Init:
            ; LCD initialization command sequence.
            tft_config  0x11
            delay   60000
            delay   60000

            tft_config  0xB1,#0x02,#0x35,#0x36
            tft_config  0xB2,#0x02,#0x35,#0x36
            tft_config  0xB3,#0x02,#0x35,#0x36,#0x02,#0x35,#0x36
            tft_config  0xB4,#0x07
            tft_config  0xC0,#0x02,#0x02
            tft_config  0xC1,#0xC5
            tft_config  0xC2,#0x0D,#0x00
            tft_config  0xC3,#0x8D,#0x1A
            tft_config  0xC4,#0x8D,#0xEE
            tft_config  0xC5,#0x51,#0x4D

            tft_config  0xE0,#0x0A,#0x1C,#0x0C,#0x14,#0x33,#0x2B,#0x24,#0x28,#0x27,#0x25,#0x2C,#0x39,#0x00,#0x05,#0x03,#0x0D
            tft_config  0xE1,#0x0A,#0x1C,#0x0C,#0x14,#0x33,#0x2B,#0x24,#0x28,#0x27,#0x25,#0x2C,#0x39,#0x00,#0x05,#0x03,#0x0D

            tft_config  0x3A,#0x06
            tft_config  0x29
            delay   5000
            tft_config  0x36,#0x40
            ret

tft_cmd_sr:
            ; Send one LCD command byte through SPI.
            CS_LOW
            bic.b   #LCD_DC, &P2OUT
            call    #spi_byte
            CS_HIGH
            ret

tft_data_sr:
            ; Send one LCD data byte through SPI.
            CS_LOW
            bis.b   #LCD_DC, &P2OUT
            call    #spi_byte
            CS_HIGH
            ret

spi_byte:
            ; Transmit the byte in R15 using UCB0 SPI.
spiT1:
            bit.w   #UCTXIFG, &UCB0IFG
            jz      spiT1
            mov.b   R15, &UCB0TXBUF

spiT2:
            bit.w   #UCBUSY, &UCB0STATW
            jnz     spiT2
            ret

;-------------------------------------------------------------------------------
; Delays
;-------------------------------------------------------------------------------

DebounceDelay:
            ; Short button debounce delay.
            mov.w   #25000, R15

DebLoop:
            dec.w   R15
            jnz     DebLoop
            ret

FrameDelay:
            ; Small frame delay to stabilize game speed.
            mov.w   #3500, R15

FrameDelayLoop:
            dec.w   R15
            jnz     FrameDelayLoop
            ret

;-------------------------------------------------------------------------------
; Reset vector
;-------------------------------------------------------------------------------

            .sect   ".reset"
            .short  RESET
            .end
