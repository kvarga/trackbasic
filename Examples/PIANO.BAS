' PIANO.BAS - play the trackpad from the keyboard.
' White keys: A S D F G H J K L ;    Black keys: W E   T Y U   O P
' Z / X change octave, Esc quits.

DIM freq(12)
FOR i = 0 TO 12: freq(i) = 261.63 * 2 ^ (i / 12): NEXT
whiteKeys$ = "ASDFGHJKL;"
whiteSemi$ = "00020405070911121416"   ' semitones above C, two digits each
blackKeys$ = "WETYUOP"
blackSemi$ = "01030608101315"
octave = 1

COLOR 15, 1: CLS
LOCATE 2, 30: PRINT "T R A C K P I A N O"
LOCATE 4, 12: PRINT "White: A S D F G H J K L ;    Black: W E  T Y U  O P"
LOCATE 5, 12: PRINT "Z / X: octave down / up        Esc: quit"

' Draw the keyboard.
COLOR 0, 7
FOR k = 0 TO 9
    FOR r = 8 TO 17
        LOCATE r, 15 + k * 5: PRINT CHR$(179); "    ";
    NEXT
    LOCATE 18, 15 + k * 5: COLOR 1, 7: PRINT CHR$(179); " "; MID$(whiteKeys$, k + 1, 1); "  "; : COLOR 0, 7
NEXT
COLOR 0, 7
FOR k = 0 TO 9
    IF k <> 2 AND k <> 6 AND k <> 9 THEN
        FOR r = 8 TO 13
            LOCATE r, 18 + k * 5: PRINT STRING$(3, 219);
        NEXT
    END IF
NEXT

DO
    COLOR 14, 1: LOCATE 21, 33: PRINT " Octave:"; octave + 4; " "
    DO: k$ = UCASE$(INKEY$): LOOP WHILE k$ = ""
    IF k$ = CHR$(27) THEN EXIT DO
    semi = -1
    p = INSTR(whiteKeys$, k$)
    IF p > 0 THEN semi = VAL(MID$(whiteSemi$, p * 2 - 1, 2))
    p = INSTR(blackKeys$, k$)
    IF p > 0 THEN semi = VAL(MID$(blackSemi$, p * 2 - 1, 2))
    IF k$ = "Z" AND octave > -1 THEN octave = octave - 1
    IF k$ = "X" AND octave < 3 THEN octave = octave + 1
    IF semi >= 0 THEN
        f = 261.63 * 2 ^ (semi / 12) * 2 ^ octave
        LOCATE 23, 30: COLOR 11, 1: PRINT USING " Note #### Hz "; f
        SOUND f, 3
    END IF
LOOP
COLOR 7, 0: CLS
