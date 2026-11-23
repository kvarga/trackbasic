' JUKEBOX.BAS - public-domain tunes played on the trackpad with PLAY.
' Each tune is in the key that suits the trackpad glass best, found by playing every key and
' recording it with the MacBook's microphone. The glass is quiet from O4 B to O5 C# and from
' O5 B to O6 C#, so the keys avoid those notes.
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
        PLAY "T150 O5 L4 F#F#GA AGF#E DDEF# F#.E8E2"
        PLAY "F#F#GA AGF#E DDEF# E.D8D2"
    CASE "2"
        PLAY "T110 L16 O5 A#AA#AA# FG#F# D#8 P16 <F#A#>D# F8 P16 <A#>DF F#8 P16 <A#>A#AA#AA# FG#F# D#8 P16 <F#A#>D# F8 P16 <A#>F#F D#4"
    CASE "3"
        PLAY "T140 L4 O4 C#C#G#G#A#A#G#2 F#F#FFD#D#C#2 G#G#F#F#FFD#2 G#G#F#F#FFD#2 C#C#G#G#A#A#G#2 F#F#FFD#D#C#2"
    CASE "4"
        PLAY "T120 L8 O5 D#F#4G# A#.B16A# G#4F C#.D#16F F#4D# D#.D16D# F4D <A#4>D#"
        PLAY "F#4G# A#.B16A# G#4F C#.D#16F F#FD# D.C16D D#4. D#4."
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
