' WELCOME.BAS - press F5 to run.
' Put your Mac on a table, keep your hands off the trackpad, and listen:
' every SOUND, PLAY and BEEP comes out of the trackpad's haptic motor.

CLS
COLOR 14, 1
PRINT STRING$(80, 205);
LOCATE 2, 1: PRINT SPACE$(80);
LOCATE 2, 24: PRINT "T R A C K B A S I C"
PRINT STRING$(80, 205);
COLOR 7, 0
PRINT
PRINT "  Your trackpad has no speaker. It has a small motor that taps the glass so"
PRINT "  you feel a click. Driven fast enough, the glass sings."
PRINT

COLOR 11: PRINT "  1. A sweep, 100 Hz to 4 kHz, with SOUND"
COLOR 7
f = 100
DO WHILE f < 4000
    SOUND f, .4
    f = f * 1.06
LOOP

PRINT
COLOR 11: PRINT "  2. A scale with PLAY"
COLOR 7
PLAY "T180 L8 O4 A# >C D D# F G A A#"

PRINT
COLOR 11: PRINT "  3. Ode to Joy (Beethoven, 1824), in D: the key that suits the glass"
COLOR 7
PLAY "T150 O5 L4 F#F#GA AGF#E DDEF# F#.E8E2"
PLAY "F#F#GA AGF#E DDEF# E.D8D2"

PRINT
COLOR 10
PRINT "  Now try File > Examples, or press Esc and write your own:"
COLOR 15
PRINT "      PLAY "; CHR$(34); "T120 O5 D E F# G A"; CHR$(34)
COLOR 7
BEEP
