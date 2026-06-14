       IDENTIFICATION DIVISION.
       PROGRAM-ID.    TINYJOIN.
       AUTHOR.        FRASER.
      ******************************************************************
      * Program     : TINYJOIN.CBL
      * Application : Tiny Pointers lab -- COBOL hash-join demo
      * Type        : Batch COBOL Program
      * Function    : A relational JOIN of two flat files using the
      *               "load-balancing dereference table" of
      *               Tiny Pointers (arXiv:2111.12800, Section 3).
      *
      *   Tables : CUSTOMER.DAT (inner / build) joined to
      *            ORDERS.DAT   (outer / probe) on customer id.
      *
      *   The dereference table hashes a key to a BUCKET of B slots and
      *   stores it in any free slot j.  The "tiny pointer" is just j --
      *   ceil(log2 B) bits -- not a full record pointer.  A few buckets
      *   fill up (the paper's delta-fraction); those spill to a small
      *   linear-probe OVERFLOW region (the paper's backup table) so the
      *   join is LOSSLESS.  DEREFERENCE = recompute bucket from the key,
      *   scan <= B slots: a bounded, tail-free probe even at high load.
      *
      *   This is a CPU, single-thread teaching demo: the point is the
      *   STRUCTURE, the DENSITY it reaches, and the tiny HANDLE width --
      *   not raw speed (that is the CUDA Fortran engine next door).
      ******************************************************************
       ENVIRONMENT DIVISION.
       INPUT-OUTPUT SECTION.
       FILE-CONTROL.
           SELECT CUSTOMER-FILE
               ASSIGN TO 'data/CUSTOMER.DAT'
               ORGANIZATION IS LINE SEQUENTIAL
               FILE STATUS IS CUST-STATUS.

           SELECT ORDERS-FILE
               ASSIGN TO 'data/ORDERS.DAT'
               ORGANIZATION IS LINE SEQUENTIAL
               FILE STATUS IS ORD-STATUS.

           SELECT JOINED-FILE
               ASSIGN TO 'data/JOINED.DAT'
               ORGANIZATION IS LINE SEQUENTIAL
               FILE STATUS IS JN-STATUS.

       DATA DIVISION.
       FILE SECTION.

       FD  CUSTOMER-FILE.
       01  CUST-REC.
           05  CR-ID            PIC 9(6).
           05  CR-NAME          PIC X(20).

       FD  ORDERS-FILE.
       01  ORD-REC.
           05  OR-ID            PIC 9(8).
           05  OR-CID           PIC 9(6).
           05  OR-AMT           PIC 9(9).

       FD  JOINED-FILE.
       01  JN-REC.
           05  JN-OID           PIC 9(8).
           05  FILLER           PIC X(1).
           05  JN-CID           PIC 9(6).
           05  FILLER           PIC X(1).
           05  JN-NAME          PIC X(20).
           05  FILLER           PIC X(1).
           05  JN-AMT           PIC 9(9).

       WORKING-STORAGE SECTION.

      *--- sizing (primary load = N-CUST / (NBKT*BSLOTS) ) -------------
      *    plain data items: IBM COBOL 1.2.0 has no level-78 constants.
      *    OCCURS below uses the matching integer literals (640 / 8 / 768).
       01  NBKT                 PIC 9(3) VALUE 640.
       01  BSLOTS               PIC 9    VALUE 8.
       01  OVF-CAP              PIC 9(3) VALUE 768.
       01  N-CUST               PIC 9(4) VALUE 4608.
       01  N-ORDER              PIC 9(5) VALUE 18432.
       01  CUST-BASE            PIC 9(6) VALUE 100000.

      *--- the dereference table : NBKT buckets x BSLOTS slots ---------
       01  PRIMARY-STORE.
           05  P-BUCKET OCCURS 640 TIMES.
               10  P-SLOT OCCURS 8 TIMES.
                   15  P-KEY    PIC 9(6).
                   15  P-NAME   PIC X(20).
       01  BUCKET-OCC.
           05  B-OCC OCCURS 640 TIMES PIC 9(2).

      *--- the backup table : a small linear-probe overflow region ----
       01  OVERFLOW-STORE.
           05  O-CELL OCCURS 768 TIMES.
               10  O-KEY        PIC 9(6).
               10  O-NAME       PIC X(20).

      *--- file status ------------------------------------------------
       01  CUST-STATUS          PIC XX VALUE SPACES.
           88  CUST-OK          VALUE '00'.
           88  CUST-EOF         VALUE '10'.
       01  ORD-STATUS           PIC XX VALUE SPACES.
           88  ORD-OK           VALUE '00'.
           88  ORD-EOF          VALUE '10'.
       01  JN-STATUS            PIC XX VALUE SPACES.

      *--- loop / scratch ---------------------------------------------
       01  WS-EOF               PIC X VALUE 'N'.
           88  EOF-YES          VALUE 'Y'.
       01  WS-I                 PIC 9(9).
       01  WS-J                 PIC 9(4).
       01  WS-S                 PIC 9(6).
       01  WS-BKT               PIC 9(4).
       01  WS-OH                PIC 9(6).
       01  WS-STMP              PIC 9(9).
       01  WS-HV                PIC 9(18).
       01  WS-PLACED            PIC X VALUE 'N'.
           88  PLACED-YES       VALUE 'Y'.
       01  WS-FOUND             PIC X VALUE 'N'.
           88  FOUND-YES        VALUE 'Y'.
       01  WS-STOP              PIC X VALUE 'N'.
           88  STOP-YES         VALUE 'Y'.
       01  WS-RESULT-NAME       PIC X(20).
       01  WS-IDX-Z             PIC 9(6).
       01  WS-SEED              PIC 9(18) VALUE 12345.
       01  WS-CIDX              PIC 9(9).

      *--- statistics -------------------------------------------------
       01  WS-CUST-COUNT        PIC 9(6)  VALUE 0.
       01  WS-PLACED-BUCKET     PIC 9(6)  VALUE 0.
       01  WS-PLACED-OVF        PIC 9(6)  VALUE 0.
       01  WS-HARD-FAIL         PIC 9(6)  VALUE 0.
       01  WS-MAX-OCC           PIC 9(2)  VALUE 0.
       01  WS-ORDER-COUNT       PIC 9(8)  VALUE 0.
       01  WS-MATCH-COUNT       PIC 9(8)  VALUE 0.

      *--- derived figures for the report -----------------------------
       01  WS-PRIM-CAP          PIC 9(7).
       01  WS-LOAD-PCT          PIC ZZ9.99.
       01  WS-OVF-PCT           PIC ZZ9.99.
       01  WS-TINY-BITS-TOT     PIC 9(9).
       01  WS-TINY-BYTES        PIC 9(7).
       01  WS-FULL-BYTES        PIC 9(7).
       01  WS-RATIO             PIC ZZ9.99.
       01  WS-BLEND-BITS        PIC Z9.99.
       01  WS-MATCH-PCT         PIC ZZ9.99.
       01  WS-SAMPLE            PIC 9(2) VALUE 0.

      *--- edited fields for display ----------------------------------
       01  WS-ED6               PIC ZZZ,ZZ9.
       01  WS-ED7               PIC Z,ZZZ,ZZ9.
       01  WS-ED2               PIC Z9.

       PROCEDURE DIVISION.

       0000-MAIN SECTION.
           PERFORM 1000-GEN-DATA
           PERFORM 2000-BUILD-TABLE
           PERFORM 3000-JOIN
           PERFORM 9000-REPORT
           STOP RUN.

      ******************************************************************
      *  1000 -- generate the two relational tables as flat files
      ******************************************************************
       1000-GEN-DATA SECTION.
       1000-GEN.
           OPEN OUTPUT CUSTOMER-FILE
           PERFORM VARYING WS-I FROM 1 BY 1 UNTIL WS-I > N-CUST
               COMPUTE CR-ID = CUST-BASE + WS-I
               MOVE WS-I TO WS-IDX-Z
               MOVE SPACES TO CR-NAME
               STRING 'CUSTOMER-' DELIMITED BY SIZE
                      WS-IDX-Z    DELIMITED BY SIZE
                   INTO CR-NAME
               WRITE CUST-REC
           END-PERFORM
           CLOSE CUSTOMER-FILE

      *    orders reference a random existing customer (Park-Miller LCG)
           OPEN OUTPUT ORDERS-FILE
           PERFORM VARYING WS-I FROM 1 BY 1 UNTIL WS-I > N-ORDER
               COMPUTE WS-SEED = FUNCTION MOD(WS-SEED * 16807, 2147483647)
               COMPUTE WS-CIDX = FUNCTION MOD(WS-SEED, N-CUST) + 1
               COMPUTE OR-ID  = 10000000 + WS-I
               COMPUTE OR-CID = CUST-BASE + WS-CIDX
               COMPUTE OR-AMT = FUNCTION MOD(WS-SEED, 100000000)
               WRITE ORD-REC
           END-PERFORM
           CLOSE ORDERS-FILE.

      ******************************************************************
      *  2000 -- build the dereference table from CUSTOMER.DAT
      ******************************************************************
       2000-BUILD-TABLE SECTION.
       2000-BUILD.
      *    clear the arenas (0 key = empty slot)
           PERFORM VARYING WS-I FROM 1 BY 1 UNTIL WS-I > NBKT
               MOVE 0 TO B-OCC(WS-I)
               PERFORM VARYING WS-J FROM 1 BY 1 UNTIL WS-J > BSLOTS
                   MOVE 0 TO P-KEY(WS-I, WS-J)
               END-PERFORM
           END-PERFORM
           PERFORM VARYING WS-I FROM 1 BY 1 UNTIL WS-I > OVF-CAP
               MOVE 0 TO O-KEY(WS-I)
           END-PERFORM

           OPEN INPUT CUSTOMER-FILE
           MOVE 'N' TO WS-EOF
           PERFORM UNTIL EOF-YES
               READ CUSTOMER-FILE
                   AT END SET EOF-YES TO TRUE
                   NOT AT END
                       ADD 1 TO WS-CUST-COUNT
                       PERFORM 2100-INSERT
               END-READ
           END-PERFORM
           CLOSE CUSTOMER-FILE.

      *    insert current CUST-REC : bucket first, then overflow backup
       2100-INSERT.
           COMPUTE WS-HV  = CR-ID * 2654435761
           COMPUTE WS-BKT = FUNCTION MOD(WS-HV, NBKT) + 1
           MOVE 'N' TO WS-PLACED
           PERFORM VARYING WS-J FROM 1 BY 1
                   UNTIL WS-J > BSLOTS OR PLACED-YES
               IF P-KEY(WS-BKT, WS-J) = 0
                   MOVE CR-ID   TO P-KEY(WS-BKT, WS-J)
                   MOVE CR-NAME TO P-NAME(WS-BKT, WS-J)
                   ADD 1 TO B-OCC(WS-BKT)
                   ADD 1 TO WS-PLACED-BUCKET
                   SET PLACED-YES TO TRUE
               END-IF
           END-PERFORM
           IF B-OCC(WS-BKT) > WS-MAX-OCC
               MOVE B-OCC(WS-BKT) TO WS-MAX-OCC
           END-IF
           IF NOT PLACED-YES
               PERFORM 2200-INSERT-OVF
           END-IF.

      *    backup table : linear probe from a second hash of the key
       2200-INSERT-OVF.
           COMPUTE WS-OH = FUNCTION MOD(CR-ID * 40503, OVF-CAP)
           MOVE 'N' TO WS-PLACED
           PERFORM VARYING WS-I FROM 0 BY 1
                   UNTIL WS-I >= OVF-CAP OR PLACED-YES
               COMPUTE WS-STMP = WS-OH + WS-I
               COMPUTE WS-S = FUNCTION MOD(WS-STMP, OVF-CAP) + 1
               IF O-KEY(WS-S) = 0
                   MOVE CR-ID   TO O-KEY(WS-S)
                   MOVE CR-NAME TO O-NAME(WS-S)
                   ADD 1 TO WS-PLACED-OVF
                   SET PLACED-YES TO TRUE
               END-IF
           END-PERFORM
           IF NOT PLACED-YES
               ADD 1 TO WS-HARD-FAIL
           END-IF.

      ******************************************************************
      *  3000 -- probe with ORDERS.DAT and emit the joined rows
      ******************************************************************
       3000-JOIN SECTION.
       3000-DO-JOIN.
           OPEN INPUT ORDERS-FILE
           OPEN OUTPUT JOINED-FILE
           MOVE 'N' TO WS-EOF
           PERFORM UNTIL EOF-YES
               READ ORDERS-FILE
                   AT END SET EOF-YES TO TRUE
                   NOT AT END
                       ADD 1 TO WS-ORDER-COUNT
                       PERFORM 3100-PROBE
                       IF FOUND-YES
                           ADD 1 TO WS-MATCH-COUNT
                           MOVE OR-ID         TO JN-OID
                           MOVE OR-CID        TO JN-CID
                           MOVE WS-RESULT-NAME TO JN-NAME
                           MOVE OR-AMT        TO JN-AMT
                           MOVE SPACES TO JN-REC(9:1) JN-REC(16:1)
                                          JN-REC(37:1)
                           WRITE JN-REC
                           PERFORM 3200-SAMPLE
                       END-IF
               END-READ
           END-PERFORM
           CLOSE ORDERS-FILE
           CLOSE JOINED-FILE.

      *    DEREFERENCE : recompute the bucket from the key, scan <= B
       3100-PROBE.
           COMPUTE WS-HV  = OR-CID * 2654435761
           COMPUTE WS-BKT = FUNCTION MOD(WS-HV, NBKT) + 1
           MOVE 'N' TO WS-FOUND
           PERFORM VARYING WS-J FROM 1 BY 1
                   UNTIL WS-J > BSLOTS OR FOUND-YES
               IF P-KEY(WS-BKT, WS-J) = OR-CID
                   MOVE P-NAME(WS-BKT, WS-J) TO WS-RESULT-NAME
                   SET FOUND-YES TO TRUE
               END-IF
           END-PERFORM
           IF NOT FOUND-YES
               COMPUTE WS-OH = FUNCTION MOD(OR-CID * 40503, OVF-CAP)
               MOVE 'N' TO WS-STOP
               PERFORM VARYING WS-I FROM 0 BY 1
                       UNTIL WS-I >= OVF-CAP OR FOUND-YES OR STOP-YES
                   COMPUTE WS-STMP = WS-OH + WS-I
                   COMPUTE WS-S = FUNCTION MOD(WS-STMP, OVF-CAP) + 1
                   IF O-KEY(WS-S) = OR-CID
                       MOVE O-NAME(WS-S) TO WS-RESULT-NAME
                       SET FOUND-YES TO TRUE
                   ELSE
                       IF O-KEY(WS-S) = 0
                           SET STOP-YES TO TRUE
                       END-IF
                   END-IF
               END-PERFORM
           END-IF.

      *    keep the first few matches for an on-screen sample
       3200-SAMPLE.
           IF WS-SAMPLE < 5
               ADD 1 TO WS-SAMPLE
               DISPLAY '   order ' OR-ID ' -> cust ' OR-CID
                       ' = ' WS-RESULT-NAME
           END-IF.

      ******************************************************************
      *  9000 -- the report : density + handle width
      ******************************************************************
       9000-REPORT SECTION.
       9000-RPT.
           COMPUTE WS-PRIM-CAP = NBKT * BSLOTS
           COMPUTE WS-LOAD-PCT = 100.0 * WS-PLACED-BUCKET / WS-PRIM-CAP
           COMPUTE WS-OVF-PCT  = 100.0 * WS-PLACED-OVF / OVF-CAP
           COMPUTE WS-MATCH-PCT =
                   100.0 * WS-MATCH-COUNT / WS-ORDER-COUNT

      *    handle width: in-bucket = 3 bits (log2 8), overflow = 10 bits
      *    (log2 768).  Compare to a 4-byte (32-bit) record pointer/RRN.
           COMPUTE WS-TINY-BITS-TOT =
                   WS-PLACED-BUCKET * 3 + WS-PLACED-OVF * 10
           COMPUTE WS-TINY-BYTES = WS-TINY-BITS-TOT / 8
           COMPUTE WS-FULL-BYTES = WS-CUST-COUNT * 4
           COMPUTE WS-RATIO   = WS-FULL-BYTES / WS-TINY-BYTES
           COMPUTE WS-BLEND-BITS = WS-TINY-BITS-TOT / WS-CUST-COUNT

           DISPLAY ' '
           DISPLAY '==============================================='
           DISPLAY '  TINYJOIN -- tiny-pointer hash join (COBOL)'
           DISPLAY '==============================================='
           DISPLAY ' '
           DISPLAY '  Relational JOIN:'
           MOVE WS-ORDER-COUNT TO WS-ED7
           DISPLAY '    ORDERS rows probed  : ' WS-ED7
           MOVE WS-MATCH-COUNT TO WS-ED7
           DISPLAY '    matched (joined)    : ' WS-ED7
                   '   (' WS-MATCH-PCT ' %)'
           DISPLAY ' '
           DISPLAY '  DENSITY (how tightly the table packs):'
           MOVE WS-CUST-COUNT TO WS-ED6
           DISPLAY '    customers placed    : ' WS-ED6
           MOVE WS-PRIM-CAP TO WS-ED6
           DISPLAY '    primary capacity    : ' WS-ED6
                   '   (' NBKT ' buckets x ' BSLOTS ')'
           MOVE WS-PLACED-BUCKET TO WS-ED6
           DISPLAY '    placed in buckets   : ' WS-ED6
                   '   load ' WS-LOAD-PCT ' %'
           MOVE WS-PLACED-OVF TO WS-ED6
           DISPLAY '    spilled to backup   : ' WS-ED6
                   '   (' WS-OVF-PCT ' % of backup used)'
           MOVE WS-HARD-FAIL TO WS-ED6
           DISPLAY '    lost (unplaceable)  : ' WS-ED6
                   '   <- lossless'
           MOVE WS-MAX-OCC TO WS-ED2
           DISPLAY '    max bucket fill     : ' WS-ED2 ' / ' BSLOTS
                   '   (probe is bounded by B, no tail)'
           DISPLAY ' '
           DISPLAY '  HANDLE WIDTH (to point at a customer record):'
           DISPLAY '    full pointer (RRN)  :  32 bits  = 4 bytes each'
           DISPLAY '    tiny pointer        :   3 bits in-bucket,'
           DISPLAY '                          10 bits if in backup'
           DISPLAY '    blended             : ' WS-BLEND-BITS
                   ' bits per customer'
           MOVE WS-FULL-BYTES TO WS-ED7
           DISPLAY '    index of all custs  : full ' WS-ED7 ' bytes'
           MOVE WS-TINY-BYTES TO WS-ED7
           DISPLAY '                          tiny ' WS-ED7 ' bytes'
                   '   (' WS-RATIO 'x smaller)'
           DISPLAY ' '
           DISPLAY '  The key recomputes the bucket, so the stored'
           DISPLAY '  reference is just the slot index -- the paper''s'
           DISPLAY '  tiny pointer -- not a full record address.'
           DISPLAY '==============================================='.
