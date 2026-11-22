' GUESS.BAS - guess the number. The trackpad tells you hotter or colder.

RANDOMIZE TIMER
DO
    CLS
    COLOR 14: PRINT "I'm thinking of a number from 1 to 100."
    COLOR 7: PRINT "Higher guesses sound higher. Listen to the trackpad."
    PRINT
    secret = INT(RND * 100) + 1
    tries = 0
    DO
        INPUT "Your guess"; g
        tries = tries + 1
        ' The pitch tells you how close you are.
        SOUND 300 + (100 - ABS(secret - g)) * 15, 3
        IF g < secret THEN
            PRINT "  Too low."
        ELSEIF g > secret THEN
            PRINT "  Too high."
        END IF
    LOOP UNTIL g = secret
    COLOR 10
    PRINT
    PRINT "Got it in"; tries; "tries!"
    PLAY "T180 O4 L8 C E G >C4"
    COLOR 7
    PRINT
    INPUT "Play again (Y/N)"; a$
LOOP WHILE UCASE$(LEFT$(a$, 1)) = "Y"
