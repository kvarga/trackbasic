' WORM.BAS - steer with the arrow keys, eat the stars, don't hit the walls.
' Every star chirps on the trackpad.
DEFINT A-Z
RANDOMIZE TIMER
DIM wx(500), wy(500)

COLOR 7, 0: CLS
COLOR 9
LOCATE 2, 1: PRINT CHR$(201); STRING$(78, 205); CHR$(187);
FOR r = 3 TO 23: LOCATE r, 1: PRINT CHR$(186); : LOCATE r, 80: PRINT CHR$(186); : NEXT
LOCATE 24, 1: PRINT CHR$(200); STRING$(78, 205); CHR$(188);

length = 4: head = 0: dx = 1: dy = 0: score = 0
FOR i = 0 TO length - 1: wx(i) = 40 - i: wy(i) = 12: NEXT
GOSUB NewStar
delay! = .12

DO
    COLOR 15: LOCATE 1, 2: PRINT "WORM   Score:"; score; "  Esc quits";
    k$ = INKEY$
    IF k$ = CHR$(27) THEN EXIT DO
    IF k$ = CHR$(0) + "H" AND dy = 0 THEN dx = 0: dy = -1
    IF k$ = CHR$(0) + "P" AND dy = 0 THEN dx = 0: dy = 1
    IF k$ = CHR$(0) + "K" AND dx = 0 THEN dx = -1: dy = 0
    IF k$ = CHR$(0) + "M" AND dx = 0 THEN dx = 1: dy = 0

    ' Move: shift the body, add a new head.
    tailX = wx(length - 1): tailY = wy(length - 1)
    FOR i = length - 1 TO 1 STEP -1: wx(i) = wx(i - 1): wy(i) = wy(i - 1): NEXT
    wx(0) = wx(0) + dx: wy(0) = wy(0) + dy

    ' Crash into a wall or yourself?
    hit = (wx(0) < 2 OR wx(0) > 79 OR wy(0) < 3 OR wy(0) > 23)
    FOR i = 1 TO length - 1
        IF wx(i) = wx(0) AND wy(i) = wy(0) THEN hit = -1
    NEXT
    IF hit THEN EXIT DO

    LOCATE tailY, tailX: PRINT " ";
    COLOR 10: LOCATE wy(0), wx(0): PRINT CHR$(219);
    IF length > 1 THEN COLOR 2: LOCATE wy(1), wx(1): PRINT CHR$(177);

    IF wx(0) = sx AND wy(0) = sy THEN
        score = score + 10
        SOUND 1200, .7: SOUND 1800, .7
        IF length < 500 THEN wx(length) = tailX: wy(length) = tailY: length = length + 1
        IF delay! > .04 THEN delay! = delay! - .005
        GOSUB NewStar
    END IF

    t! = TIMER
    DO: LOOP WHILE TIMER - t! < delay! AND TIMER >= t!
LOOP

FOR f = 900 TO 150 STEP -30: SOUND f, .4: NEXT
COLOR 12: LOCATE 12, 33: PRINT " G A M E   O V E R "
COLOR 7: LOCATE 14, 34: PRINT "Score:"; score
END

NewStar:
    DO
        sx = INT(RND * 76) + 3: sy = INT(RND * 20) + 3
        ok = -1
        FOR i = 0 TO length - 1
            IF wx(i) = sx AND wy(i) = sy THEN ok = 0
        NEXT
    LOOP UNTIL ok
    COLOR 14: LOCATE sy, sx: PRINT "*";
RETURN
