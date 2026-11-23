' EFFECTS.BAS - classic PC-speaker sound effects, on the trackpad.

CLS
PRINT "Sound effects with SOUND. Press a key between each one."
PRINT

PRINT "Siren..."
FOR n = 1 TO 3
    FOR f = 600 TO 1400 STEP 40: SOUND f, .3: NEXT
    FOR f = 1400 TO 600 STEP -40: SOUND f, .3: NEXT
NEXT
GOSUB WaitKey

PRINT "Laser..."
FOR n = 1 TO 4
    FOR f = 3000 TO 400 STEP -150: SOUND f, .12: NEXT
NEXT
GOSUB WaitKey

PRINT "Bomb dropping..."
FOR f = 2500 TO 300 STEP -12: SOUND f, .25: NEXT
FOR n = 1 TO 40: SOUND 100 + RND * 200, .15: NEXT
GOSUB WaitKey

PRINT "Telephone..."
FOR r = 1 TO 2
    FOR n = 1 TO 15: SOUND 1568, .5: SOUND 1397, .5: NEXT
    SLEEP 1
NEXT
GOSUB WaitKey

PRINT "Coin!"
SOUND 1319, 1.5: SOUND 1760, 5
GOSUB WaitKey

PRINT "Power up!"
FOR n = 0 TO 15
    SOUND 400 * 2 ^ (n / 6), .6
NEXT
PRINT
PRINT "Done."
END

WaitKey:
    PRINT "   (press a key)"
    DO: LOOP WHILE INKEY$ = ""
RETURN
