' JUKEBOX.BAS - public-domain tunes played on the trackpad with PLAY.
DECLARE SUB Frame ()

DO
    Frame
    LOCATE 6, 25: PRINT "1  Ode to Joy       (Beethoven)"
    LOCATE 8, 25: PRINT "2  Fur Elise        (Beethoven)"
    LOCATE 10, 25: PRINT "3  Twinkle, Twinkle (traditional)"
    LOCATE 12, 25: PRINT "4  Greensleeves     (traditional)"
    LOCATE 14, 25: PRINT "5  Scale in every octave"
    LOCATE 17, 25: PRINT "Q  Quit"
    LOCATE 20, 25: PRINT "Choose a tune: ";
    DO: k$ = UCASE$(INKEY$): LOOP WHILE k$ = ""
    IF k$ = "Q" OR k$ = CHR$(27) THEN EXIT DO
    LOCATE 22, 25: COLOR 14, 1: PRINT "  Playing... (Ctrl+C stops)  "; : COLOR 15, 1
    SELECT CASE k$
    CASE "1"
        PLAY "T150 O4 L4 EEFG GFED CCDE E.D8D2"
        PLAY "EEFG GFED CCDE D.C8C2"
    CASE "2"
        PLAY "T110 O5 L16 ED#ED#E<B>DC<A8 P16 CEAB8 P16 EG#BB>C8 P16 <E>ED#ED#E<B>DC<A8 P16 CEAB8 P16 E>C<BA4"
    CASE "3"
        PLAY "T140 O4 L4 CCGGAAG2 FFEEDDC2 GGFFEED2 GGFFEED2 CCGGAAG2 FFEEDDC2"
    CASE "4"
        PLAY "T120 O4 L8 A>C4D E.F16E D4<B G.A16B >C4<A A.G#16A B4G# E4A"
        PLAY ">C4D E.F16E D4<B G.A16B >C<B A G#.F#16G# A4.A4."
    CASE "5"
        FOR o = 1 TO 6
            PLAY "T220 L16 O" + LTRIM$(STR$(o)) + "CDEFGAB"
        NEXT
        PLAY "O6 L4 C"
    END SELECT
LOOP
COLOR 7, 0
CLS

SUB Frame
    COLOR 15, 1
    CLS
    LOCATE 2, 20: PRINT CHR$(201); STRING$(38, 205); CHR$(187)
    LOCATE 3, 20: PRINT CHR$(186); "      J U K E B O X   ";
    PRINT CHR$(14); "  trackpad    "; CHR$(186)
    LOCATE 4, 20: PRINT CHR$(200); STRING$(38, 205); CHR$(188)
END SUB
