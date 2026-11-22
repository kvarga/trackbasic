' GRAPHICS.BAS - SCREEN 13 (320x200, 256 colours), with a tone for every ring.

SCREEN 13
RANDOMIZE TIMER

' Rings of colour, each with its own note.
FOR r = 95 TO 5 STEP -6
    c = 32 + (r MOD 72)
    CIRCLE (160, 100), r, c
    PAINT (160, 100 - r + 2), c, c
    SOUND 300 + (100 - r) * 25, .8
NEXT

' Starburst.
FOR a = 0 TO 359 STEP 6
    x = 160 + 150 * COS(a * 3.14159 / 180)
    y = 100 + 95 * SIN(a * 3.14159 / 180)
    LINE (160, 100)-(x, y), 32 + (a \ 6) MOD 24
NEXT
PLAY "T200 O5 L16 CEG>C<GEC"

' Random boxes until a key is pressed.
LOCATE 25, 7: PRINT "Press any key to stop";
DO
    x = RND * 300: y = RND * 180
    LINE (x, y)-(x + RND * 40, y + RND * 30), RND * 255, BF
    t = TIMER: DO: LOOP WHILE TIMER - t < .02
LOOP WHILE INKEY$ = ""
SCREEN 0
