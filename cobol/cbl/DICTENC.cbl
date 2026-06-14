       IDENTIFICATION DIVISION.
       PROGRAM-ID.    DICTENC.
       AUTHOR.        FRASER.
      ******************************************************************
      * Program     : DICTENC.CBL
      * Application : Tiny Pointers lab -- COBOL dictionary encoder
      * Type        : Batch COBOL Program
      * Function    : Dictionary-encode a low-cardinality string COLUMN
      *               (the classic column-store compression) using the
      *               "load-balancing dereference table" of Tiny Pointers
      *               (arXiv:2111.12800, Section 3) as the encode-time
      *               string -> code dictionary.
      *
      *   This is the paper's space-efficient DICTIONARY (application #4)
      *   doing real database work.  A distinct string is hashed to a
      *   BUCKET of B slots and stored in a free slot; the dictionary
      *   packs at high load (no 2x safety margin), lossless via a small
      *   linear-probe OVERFLOW backup, with a bounded <= B lookup.
      *
      *   Pipeline (three flat files, COBOL owns the records):
      *     COLUMN.DAT  -> [encode] -> ENCODED.DAT  + the dictionary
      *     COLUMN.DAT  +  ENCODED.DAT -> [decode] -> round-trip check
      *
      *   Reports: DENSITY (how tightly the dictionary packs),
      *            HANDLE WIDTH (per-row code vs the full string),
      *            and the COLUMN COMPRESSION RATIO.
      ******************************************************************
       ENVIRONMENT DIVISION.
       INPUT-OUTPUT SECTION.
       FILE-CONTROL.
           SELECT COLUMN-FILE
               ASSIGN TO 'data/COLUMN.DAT'
               ORGANIZATION IS LINE SEQUENTIAL
               FILE STATUS IS COL-STATUS.

           SELECT ENCODED-FILE
               ASSIGN TO 'data/ENCODED.DAT'
               ORGANIZATION IS LINE SEQUENTIAL
               FILE STATUS IS ENC-STATUS.

       DATA DIVISION.
       FILE SECTION.

       FD  COLUMN-FILE.
       01  COL-REC.
           05  COL-STR          PIC X(24).

       FD  ENCODED-FILE.
       01  ENC-REC.
           05  EN-CODE          PIC 9(4).

       WORKING-STORAGE SECTION.

      *--- sizing (D distinct values, N rows; dict load = D/(NBKT*B)) --
       01  NBKT                 PIC 9(3) VALUE 35.
       01  BSLOTS               PIC 9(2) VALUE 16.
       01  OVF-CAP              PIC 9(3) VALUE 64.
       01  N-DISTINCT           PIC 9(4) VALUE 500.
       01  N-ROWS               PIC 9(6) VALUE 50000.
       01  STR-BYTES            PIC 9(3) VALUE 24.

      *--- the dictionary : NBKT buckets x BSLOTS slots ---------------
       01  DICT-STORE.
           05  D-BUCKET OCCURS 35 TIMES.
               10  D-SLOT OCCURS 16 TIMES.
                   15  DS-USED  PIC X.
                   15  DS-STR   PIC X(24).
                   15  DS-CODE  PIC 9(4).
       01  BUCKET-OCC.
           05  B-OCC OCCURS 35 TIMES PIC 9(2).

      *--- the backup table : a small linear-probe overflow region ----
       01  OVERFLOW-STORE.
           05  O-CELL OCCURS 64 TIMES.
               10  O-USED       PIC X.
               10  O-STR        PIC X(24).
               10  O-CODE       PIC 9(4).

      *--- code -> string, for DECODE ---------------------------------
       01  CODE-TABLE.
           05  CT-STR OCCURS 500 TIMES PIC X(24).

      *--- the generator's vocabulary of distinct values --------------
       01  VOCAB-TABLE.
           05  VOCAB OCCURS 500 TIMES PIC X(24).

      *--- file status ------------------------------------------------
       01  COL-STATUS           PIC XX VALUE SPACES.
           88  COL-EOF          VALUE '10'.
       01  ENC-STATUS           PIC XX VALUE SPACES.
           88  ENC-EOF          VALUE '10'.

      *--- loop / scratch ---------------------------------------------
       01  WS-EOF               PIC X VALUE 'N'.
           88  EOF-YES          VALUE 'Y'.
       01  WS-I                 PIC 9(9).
       01  WS-J                 PIC 9(4).
       01  WS-K                 PIC 9(3).
       01  WS-S                 PIC 9(6).
       01  WS-BKT               PIC 9(4).
       01  WS-OH                PIC 9(6).
       01  WS-STMP              PIC 9(9).
       01  WS-HV                PIC 9(18).
       01  WS-T                 PIC 9(18).
       01  WS-ORDV              PIC 9(5).
       01  WS-HSTR              PIC X(24).
       01  WS-CODE              PIC 9(4).
       01  WS-FOUND             PIC X VALUE 'N'.
           88  FOUND-YES        VALUE 'Y'.
       01  WS-VZ                PIC 9(3).
       01  WS-VIDX              PIC 9(9).
       01  WS-NEXT-CODE         PIC 9(4) VALUE 0.

      *--- statistics -------------------------------------------------
       01  WS-PLACED-BUCKET     PIC 9(4) VALUE 0.
       01  WS-PLACED-OVF        PIC 9(4) VALUE 0.
       01  WS-HARD-FAIL         PIC 9(4) VALUE 0.
       01  WS-MAX-OCC           PIC 9(2) VALUE 0.
       01  WS-ROW-COUNT         PIC 9(8) VALUE 0.
       01  WS-DEC-COUNT         PIC 9(8) VALUE 0.
       01  WS-MISMATCH          PIC 9(8) VALUE 0.
       01  WS-SAMPLE            PIC 9(2) VALUE 0.

      *--- derived figures for the report -----------------------------
       01  WS-PRIM-CAP          PIC 9(6).
       01  WS-LOAD-PCT          PIC ZZ9.99.
       01  WS-CODEBITS          PIC 9(2) VALUE 1.
       01  WS-POW               PIC 9(9) VALUE 2.
       01  WS-RAW-BYTES         PIC 9(9).
       01  WS-ENC-BYTES         PIC 9(9).
       01  WS-DICT-BYTES        PIC 9(9).
       01  WS-TOTAL-BYTES       PIC 9(9).
       01  WS-RATIO             PIC ZZ9.99.

      *--- edited fields for display ----------------------------------
       01  WS-ED4               PIC ZZZ9.
       01  WS-ED6               PIC ZZZ,ZZ9.
       01  WS-ED9               PIC ZZZ,ZZZ,ZZ9.
       01  WS-ED2               PIC Z9.

       PROCEDURE DIVISION.

       0000-MAIN SECTION.
           PERFORM 1000-GEN-COLUMN
           PERFORM 2000-ENCODE
           PERFORM 3000-DECODE-VERIFY
           PERFORM 9000-REPORT
           STOP RUN.

      ******************************************************************
      *  1000 -- generate a low-cardinality string column
      ******************************************************************
       1000-GEN-COLUMN SECTION.
       1000-GEN.
      *    build the vocabulary of N-DISTINCT distinct values
           PERFORM VARYING WS-I FROM 1 BY 1 UNTIL WS-I > N-DISTINCT
               MOVE WS-I TO WS-VZ
               MOVE SPACES TO VOCAB(WS-I)
               STRING 'CATEGORY-' DELIMITED BY SIZE
                      WS-VZ       DELIMITED BY SIZE
                   INTO VOCAB(WS-I)
           END-PERFORM

      *    write N-ROWS, each picking a vocabulary entry. A multiplier
      *    coprime to N-DISTINCT (257) cycles through ALL distinct values
      *    (so the dictionary really fills), scrambled rather than 1,2,3.
      *    Uniform repetition is the conservative case; real columns are
      *    skewed (Zipf), which only compresses better.
           OPEN OUTPUT COLUMN-FILE
           PERFORM VARYING WS-I FROM 1 BY 1 UNTIL WS-I > N-ROWS
               COMPUTE WS-T = WS-I * 257
               COMPUTE WS-VIDX = FUNCTION MOD(WS-T, N-DISTINCT) + 1
               MOVE VOCAB(WS-VIDX) TO COL-STR
               WRITE COL-REC
           END-PERFORM
           CLOSE COLUMN-FILE.

      ******************************************************************
      *  2000 -- encode COLUMN.DAT through the tiny-pointer dictionary
      ******************************************************************
       2000-ENCODE SECTION.
       2000-ENC.
           PERFORM VARYING WS-I FROM 1 BY 1 UNTIL WS-I > NBKT
               MOVE 0 TO B-OCC(WS-I)
               PERFORM VARYING WS-J FROM 1 BY 1 UNTIL WS-J > BSLOTS
                   MOVE 'N' TO DS-USED(WS-I, WS-J)
               END-PERFORM
           END-PERFORM
           PERFORM VARYING WS-I FROM 1 BY 1 UNTIL WS-I > OVF-CAP
               MOVE 'N' TO O-USED(WS-I)
           END-PERFORM
           MOVE 0 TO WS-NEXT-CODE

           OPEN INPUT COLUMN-FILE
           OPEN OUTPUT ENCODED-FILE
           MOVE 'N' TO WS-EOF
           PERFORM UNTIL EOF-YES
               READ COLUMN-FILE
                   AT END SET EOF-YES TO TRUE
                   NOT AT END
                       ADD 1 TO WS-ROW-COUNT
                       MOVE COL-STR TO WS-HSTR
                       PERFORM 2100-DICT-ENCODE
                       MOVE WS-CODE TO EN-CODE
                       WRITE ENC-REC
               END-READ
           END-PERFORM
           CLOSE COLUMN-FILE
           CLOSE ENCODED-FILE.

      *    look the string up; if new, assign the next sequential code
       2100-DICT-ENCODE.
           PERFORM 2300-HASH
           MOVE 'N' TO WS-FOUND
           PERFORM VARYING WS-J FROM 1 BY 1
                   UNTIL WS-J > BSLOTS OR FOUND-YES
               IF DS-USED(WS-BKT, WS-J) = 'N'
                   MOVE 'Y'     TO DS-USED(WS-BKT, WS-J)
                   MOVE WS-HSTR TO DS-STR(WS-BKT, WS-J)
                   ADD 1 TO WS-NEXT-CODE
                   MOVE WS-NEXT-CODE TO DS-CODE(WS-BKT, WS-J)
                   MOVE WS-HSTR TO CT-STR(WS-NEXT-CODE)
                   MOVE WS-NEXT-CODE TO WS-CODE
                   ADD 1 TO B-OCC(WS-BKT)
                   ADD 1 TO WS-PLACED-BUCKET
                   SET FOUND-YES TO TRUE
               ELSE
                   IF DS-STR(WS-BKT, WS-J) = WS-HSTR
                       MOVE DS-CODE(WS-BKT, WS-J) TO WS-CODE
                       SET FOUND-YES TO TRUE
                   END-IF
               END-IF
           END-PERFORM
           IF B-OCC(WS-BKT) > WS-MAX-OCC
               MOVE B-OCC(WS-BKT) TO WS-MAX-OCC
           END-IF
           IF NOT FOUND-YES
               PERFORM 2200-DICT-ENCODE-OVF
           END-IF.

      *    backup table : linear probe from a second hash of the key
       2200-DICT-ENCODE-OVF.
           COMPUTE WS-T  = WS-HV * 40503
           COMPUTE WS-OH = FUNCTION MOD(WS-T, OVF-CAP)
           MOVE 'N' TO WS-FOUND
           PERFORM VARYING WS-I FROM 0 BY 1
                   UNTIL WS-I >= OVF-CAP OR FOUND-YES
               COMPUTE WS-STMP = WS-OH + WS-I
               COMPUTE WS-S = FUNCTION MOD(WS-STMP, OVF-CAP) + 1
               IF O-USED(WS-S) = 'N'
                   MOVE 'Y'     TO O-USED(WS-S)
                   MOVE WS-HSTR TO O-STR(WS-S)
                   ADD 1 TO WS-NEXT-CODE
                   MOVE WS-NEXT-CODE TO O-CODE(WS-S)
                   MOVE WS-HSTR TO CT-STR(WS-NEXT-CODE)
                   MOVE WS-NEXT-CODE TO WS-CODE
                   ADD 1 TO WS-PLACED-OVF
                   SET FOUND-YES TO TRUE
               ELSE
                   IF O-STR(WS-S) = WS-HSTR
                       MOVE O-CODE(WS-S) TO WS-CODE
                       SET FOUND-YES TO TRUE
                   END-IF
               END-IF
           END-PERFORM
           IF NOT FOUND-YES
               ADD 1 TO WS-HARD-FAIL
               MOVE 0 TO WS-CODE
           END-IF.

      *    rolling hash of WS-HSTR : H = H*31 + ord(ch) mod prime
       2300-HASH.
           MOVE 0 TO WS-HV
           PERFORM VARYING WS-K FROM 1 BY 1 UNTIL WS-K > STR-BYTES
               COMPUTE WS-ORDV = FUNCTION ORD(WS-HSTR(WS-K:1))
               COMPUTE WS-T = WS-HV * 31
               ADD WS-ORDV TO WS-T
               COMPUTE WS-HV = FUNCTION MOD(WS-T, 2147483647)
           END-PERFORM
           COMPUTE WS-BKT = FUNCTION MOD(WS-HV, NBKT) + 1.

      ******************************************************************
      *  3000 -- decode ENCODED.DAT and verify against COLUMN.DAT
      ******************************************************************
       3000-DECODE-VERIFY SECTION.
       3000-DEC.
           OPEN INPUT COLUMN-FILE
           OPEN INPUT ENCODED-FILE
           MOVE 'N' TO WS-EOF
           PERFORM UNTIL EOF-YES
               READ COLUMN-FILE
                   AT END SET EOF-YES TO TRUE
                   NOT AT END
                       READ ENCODED-FILE
                           AT END SET EOF-YES TO TRUE
                           NOT AT END
                               ADD 1 TO WS-DEC-COUNT
                               IF CT-STR(EN-CODE) NOT = COL-STR
                                   ADD 1 TO WS-MISMATCH
                               END-IF
                               PERFORM 3100-SAMPLE
                       END-READ
               END-READ
           END-PERFORM
           CLOSE COLUMN-FILE
           CLOSE ENCODED-FILE.

       3100-SAMPLE.
           IF WS-SAMPLE < 5
               ADD 1 TO WS-SAMPLE
               DISPLAY '   "' COL-STR '" -> code ' EN-CODE
           END-IF.

      ******************************************************************
      *  9000 -- the report : density, handle width, compression
      ******************************************************************
       9000-REPORT SECTION.
       9000-RPT.
           COMPUTE WS-PRIM-CAP = NBKT * BSLOTS
           COMPUTE WS-LOAD-PCT =
                   100.0 * WS-PLACED-BUCKET / WS-PRIM-CAP

      *    code width in bits = smallest c with 2^c >= distinct values
           MOVE 1 TO WS-CODEBITS
           MOVE 2 TO WS-POW
           PERFORM UNTIL WS-POW >= WS-NEXT-CODE
               COMPUTE WS-POW = WS-POW * 2
               ADD 1 TO WS-CODEBITS
           END-PERFORM

           COMPUTE WS-RAW-BYTES  = WS-ROW-COUNT * STR-BYTES
           COMPUTE WS-ENC-BYTES  =
                   (WS-ROW-COUNT * WS-CODEBITS + 7) / 8
           COMPUTE WS-DICT-BYTES = WS-NEXT-CODE * STR-BYTES
           COMPUTE WS-TOTAL-BYTES = WS-ENC-BYTES + WS-DICT-BYTES
           COMPUTE WS-RATIO ROUNDED =
                   WS-RAW-BYTES / WS-TOTAL-BYTES

           DISPLAY ' '
           DISPLAY '==============================================='
           DISPLAY '  DICTENC -- tiny-pointer dictionary encoder'
           DISPLAY '==============================================='
           DISPLAY ' '
           DISPLAY '  ROUND-TRIP (decode == original):'
           MOVE WS-DEC-COUNT TO WS-ED9
           DISPLAY '    rows decoded        : ' WS-ED9
           MOVE WS-MISMATCH TO WS-ED9
           DISPLAY '    mismatches          : ' WS-ED9
                   '   <- 0 = lossless PASS'
           DISPLAY ' '
           DISPLAY '  DENSITY (the encode-time dictionary):'
           MOVE WS-NEXT-CODE TO WS-ED4
           DISPLAY '    distinct values     : ' WS-ED4
           MOVE WS-PRIM-CAP TO WS-ED4
           DISPLAY '    primary capacity    : ' WS-ED4
                   '   (' NBKT ' buckets x ' BSLOTS ')'
           MOVE WS-PLACED-BUCKET TO WS-ED4
           DISPLAY '    placed in buckets   : ' WS-ED4
                   '   load ' WS-LOAD-PCT ' %'
           MOVE WS-PLACED-OVF TO WS-ED4
           DISPLAY '    spilled to backup   : ' WS-ED4
           MOVE WS-HARD-FAIL TO WS-ED4
           DISPLAY '    lost (unplaceable)  : ' WS-ED4
                   '   <- lossless'
           MOVE WS-MAX-OCC TO WS-ED2
           DISPLAY '    max bucket fill     : ' WS-ED2 ' / ' BSLOTS
                   '   (bounded probe, no tail)'
           DISPLAY ' '
           DISPLAY '  HANDLE WIDTH (per row, code vs the string):'
           MOVE WS-CODEBITS TO WS-ED2
           DISPLAY '    full string         : ' STR-BYTES
                   ' bytes (192 bits)'
           DISPLAY '    dictionary code     : ' WS-ED2
                   ' bits   <- the tiny pointer'
           DISPLAY '    dict string->slot   :  4 bits (log2 B)'
                   ' vs a 32-bit pointer'
           DISPLAY ' '
           DISPLAY '  COLUMN COMPRESSION:'
           MOVE WS-RAW-BYTES TO WS-ED9
           DISPLAY '    raw column          : ' WS-ED9 ' bytes'
           MOVE WS-ENC-BYTES TO WS-ED9
           DISPLAY '    encoded codes       : ' WS-ED9 ' bytes'
           MOVE WS-DICT-BYTES TO WS-ED9
           DISPLAY '    + dictionary        : ' WS-ED9 ' bytes'
           MOVE WS-TOTAL-BYTES TO WS-ED9
           DISPLAY '    = total             : ' WS-ED9 ' bytes'
                   '   (' WS-RATIO 'x smaller)'
           DISPLAY ' '
           DISPLAY '  Every row stores the code (the dictionary''s'
           DISPLAY '  tiny pointer), not the string.  The dictionary'
           DISPLAY '  packs at the load shown above, bounded lookup.'
           DISPLAY '==============================================='.
