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

The motor is loudest from about 100 Hz to 4 kHz, and its cleanest notes are near 1 kHz. `PLAY`'s
default octave (`O4`, where `A` is 880 Hz) is right in that sweet spot; `O2` and below get quiet.
Each note is played in whole periods of the wave, about 20 ms at a time, the way nospeaker does.

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

## Credits

Haptic motor code adapted from [nospeaker](https://github.com/os6/nospeaker), © Cody Collier, MIT
license.
