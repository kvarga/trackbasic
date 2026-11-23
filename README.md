# TrackBASIC

A QBasic-style IDE and interpreter for macOS whose PC speaker is your **MacBook trackpad**.

`SOUND`, `PLAY` and `BEEP` don't go to the speakers: they drive the Force Touch trackpad's haptic
motor hundreds or thousands of times a second, so the glass itself makes the sound. Mute your Mac and
it still plays. The motor code comes from [nospeaker](https://github.com/os6/nospeaker) by Cody
Collier (MIT).

## Build and run

Needs Xcode or the Command Line Tools (`xcode-select --install`).

```sh
./build.sh run
```

This builds `TrackBASIC.app` for Apple Silicon and Intel and opens it with `WELCOME.BAS` loaded. Press
**F5** to run it. Put the Mac on a table and keep your hands off the glass: it's much louder that way.

## Using it

| Key | |
|---|---|
| Alt (Option) or F10 | Enter the menu bar; arrows and Enter to pick, Esc to leave. Alt+letter opens a menu. The mouse works too |
| F5 / ⌘R | Run |
| Ctrl+C / ⌘. | Stop a running program |
| F4 | Show the output screen |
| F9 | Sound output: Trackpad → Speakers (square wave) → Off |
| F1 | Help: every supported statement and function |
| Ctrl+Y | Delete a line |
| ⌘N / ⌘O / ⌘S | New, open, save `.BAS` files |
| ⌘V | Paste |

**File > Examples** has: WELCOME, JUKEBOX (public-domain tunes), PIANO (play the trackpad from the
keyboard), EFFECTS (sirens, lasers, phones), GUESS, GRAPHICS (SCREEN 13) and WORM (a real-time game).

On a Mac without a Force Touch trackpad, sound goes to the speakers as a square wave instead.

## What's supported

- Text mode 80×25 with 16 colours and code page 437 (box drawing and blocks drawn so lines join up)
- `SCREEN 12` (640×480×16) and `SCREEN 13` (320×200×256) with `PSET`, `LINE` (B/BF), `CIRCLE`,
  `PAINT`, `POINT`
- `IF`/`ELSEIF`/`ELSE` (block and single line), `SELECT CASE`, `FOR`, `DO`/`LOOP`, `WHILE`/`WEND`,
  `GOTO`, `GOSUB`, `ON … GOTO`, line numbers and labels
- `SUB` and `FUNCTION` with recursion and by-reference arguments, `SHARED`, `CONST`, `DIM`/`REDIM`,
  multi-dimensional arrays, `DEFINT`, type suffixes `$ % & ! #`
- `PRINT` (zones, `TAB`, `SPC`, `USING`), `INPUT`, `LINE INPUT`, `INKEY$`, `LOCATE`, `COLOR`, `CLS`,
  `VIEW PRINT`, `DATA`/`READ`/`RESTORE`, `RND`/`RANDOMIZE` (QBasic's own generator), `TIMER`, `SLEEP`
- `SOUND`, `BEEP`, and the full `PLAY` language: notes, `O < > L T P N`, dots, `MN ML MS`, and `MB`
  for background music

Not supported: file I/O (`OPEN`), `PEEK`/`POKE`, `DRAW`, `GET`/`PUT`, user-defined `TYPE`s, error
trapping (`ON ERROR`).

## Sound notes

The sound settings were tuned by playing melodies on the trackpad and recording them with the
MacBook's own microphone (`--listen`, below). Measured on a MacBook Pro (MacBookPro18,4):

- **One actuation is one short burst.** However long it's asked to last, the motor sounds for about
  30 ms, so a note is a stream of 15 ms actuations, each a whole number of periods of the wave.
- **Full strength stalls the driver.** Up to level 0.6 the driver takes an actuation every ~9 ms; at 1.0
  it slows to one every ~30 ms. At 1.0, Ode to Joy played 42–60% too slowly and every note stuttered at
  about 29 Hz. TrackBASIC plays at 0.7, the loudest level that stays steady, and times each note by
  the real clock, so a slower driver can't make the tempo drag.
- **The glass has favourite notes.** Loudest from `O4 G` to `O5 A#` (784–1865 Hz), peaking at
  `O5 G` (1568 Hz); quiet from `O4 B` to `O5 C#` and from `O5 B` to `O6 C#`. Choosing a key that avoids
  the quiet spots helps a lot: Ode to Joy in D major (`O5`) has its weakest note 6 dB stronger than in
  C major, and it's 3 dB louder overall.

The other examples got the same treatment: every key of each tune was scored against the measured
note levels, then the best ones were recorded and compared with the originals. Für Elise moved up 6
semitones (+3.7 dB, weakest note +5.7 dB), Greensleeves up 6 (+1.2 dB, the right pitch heard loudest
twice as often), Twinkle up 1 (+1 dB), WELCOME's scale to B♭ (+2.9 dB). EFFECTS' coin and telephone
moved out of the 1 kHz dead spot (+4.6 dB and +3.5 dB).

For Ode to Joy, compared with the first version: about 1 dB louder on average, on tempo instead of
42–60% slow, notes that swing 8 dB in level instead of 22 dB, rests between notes about twice as deep
(−11 dB against −6 dB), and the right pitch heard loudest on 17–23 of 30 notes instead of 5–7.

MultitouchSupport is a private framework, so a macOS update could break the trackpad sound. The motor
is never driven past its normal maximum strength.

## Development

Two headless modes help with testing:

```sh
swiftc -swift-version 5 Sources/*.swift -o build/dev
build/dev --dump PROGRAM.BAS --silent --keys "typed|input|"   # run, print the text screen
build/dev --png out.png PROGRAM.BAS                           # render the editor to a PNG
```

In `--keys`, `|` is Enter. `--timeout SECONDS` stops a program that waits forever.

Two more modes measure the trackpad itself (they need microphone access):

```sh
build/dev --listen "T150 O5 L4 F#F#GA AGF#E"     # play + record; score each note
build/dev --listen "…" --style level=0.7,seg=0.015 --peaks --env
build/dev --bench                                # how fast the driver takes actuations
```

`--listen` reports each note's level, how much of it is the note's harmonics, which pitch is heard
loudest, flutter (level swing within a note), the silence between notes, and whether it kept tempo.
`--style` tries other motor settings (`level`, `seg`, `periods`, `partials=1:1;2:0.5`, `sustain`,
`decay`); `--peaks` lists each note's strongest frequencies; `--env` prints the level every 10 ms.

## Credits

Haptic motor code adapted from [nospeaker](https://github.com/os6/nospeaker), © Cody Collier, MIT
license.
