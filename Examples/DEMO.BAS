' DEMO.BAS - TrackBASIC in 30 seconds.
' Every note you hear is the trackpad's haptic motor.

COLOR 15, 1: CLS
COLOR 14, 1
LOCATE 3, 1: PRINT STRING$(80, 205);
LOCATE 5, 31: PRINT "T R A C K B A S I C"
LOCATE 7, 1: PRINT STRING$(80, 205);
COLOR 15, 1
LOCATE 10, 13: PRINT "QBasic for the Mac, with the trackpad as the PC speaker."
COLOR 11, 1
LOCATE 13, 13: PRINT "PLAY "; CHR$(34); "T150 O5 L4 F#F#GA AGF#E DDEF# F#.E8E2"; CHR$(34)
PLAY "T150 O5 L4 F#F#GA AGF#E DDEF# F#.E8E2"

COLOR 10, 1
LOCATE 15, 13: PRINT "SOUND freq, ticks   ";
PRINT "siren... ";
FOR n = 1 TO 2
    FOR f = 600 TO 1400 STEP 40: SOUND f, .3: NEXT
    FOR f = 1400 TO 600 STEP -40: SOUND f, .3: NEXT
NEXT
PRINT "laser... ";
FOR n = 1 TO 4
    FOR f = 3000 TO 400 STEP -150: SOUND f, .15: NEXT
NEXT
PRINT "coin!"
SOUND 1319, 1.5: SOUND 1760, 6
t = TIMER: DO: LOOP WHILE TIMER - t < .4

SCREEN 13
FOR r = 95 TO 5 STEP -6
    c = 32 + (r MOD 72)
    CIRCLE (160, 100), r, c
    PAINT (160, 100), c, c
    SOUND 300 + (100 - r) * 25, 2
NEXT
FOR a = 0 TO 359 STEP 6
    x = 160 + 150 * COS(a * 3.14159 / 180)
    y = 100 + 95 * SIN(a * 3.14159 / 180)
    LINE (160, 100)-(x, y), 32 + (a \ 6) MOD 24
    SOUND 700 + a * 3, .35
NEXT
LOCATE 25, 9: PRINT "SCREEN 13 - 256 colours";
PLAY "T110 L16 O5 A#AA#AA# FG#F# D#8 P16 <F#A#>D# F8 P16 <A#>DF F#8"
t = TIMER
DO
    x = RND * 300: y = RND * 180
    LINE (x, y)-(x + RND * 40, y + RND * 30), RND * 255, BF
    SOUND 784 + RND * 1000, .6
LOOP WHILE TIMER - t < 2.5

SCREEN 0
COLOR 15, 1: CLS
COLOR 14, 1
LOCATE 8, 1: PRINT STRING$(80, 205);
LOCATE 10, 31: PRINT "T R A C K B A S I C"
LOCATE 12, 1: PRINT STRING$(80, 205);
COLOR 15, 1
LOCATE 15, 23: PRINT "Mute your Mac. It still plays."
COLOR 11, 1
LOCATE 17, 26: PRINT "github.com/kvarga/trackbasic"
PLAY "T160 O5 L8 DF#A>D4<A F#D4."
t = TIMER: DO: LOOP WHILE TIMER - t < 1.2
