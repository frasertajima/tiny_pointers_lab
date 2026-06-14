# Tiny-pointer database demos in COBOL

Two self-contained IBM COBOL batch programs that put the *Tiny Pointers*
dereference table to work on real records, in the language that owns them:

- **`TINYJOIN`** — a relational **hash JOIN** of two flat files.
- **`DICTENC`** — **dictionary-encode** a string column (column-store compression),
  the single best fit for tiny pointers (the paper's space-efficient dictionary).

```
make run         # builds and runs both
make run-join    # just TINYJOIN
make run-dict    # just DICTENC
```

Tested with **IBM COBOL for Linux 1.2.0** (`cob2`).

---

# DICTENC — dictionary encoder

A low-cardinality string **column** is compressed by replacing every value with a
small integer **code** and keeping one dictionary of the distinct strings — exactly
how Parquet / ClickHouse / column stores shrink string columns. The encode-time
**string → code dictionary is the tiny-pointer dereference table**: it packs the
distinct values near 90% load (no 2× safety margin), lossless via a small overflow
backup. The common (in-bucket) lookup is bounded by `≤ B`; the small spilled
fraction is a short linear probe in the backup. **The per-row code *is* the tiny
pointer.**

Pipeline (three flat files): `COLUMN.DAT —[encode]→ ENCODED.DAT (+ dictionary)`,
then `COLUMN.DAT + ENCODED.DAT —[decode]→` round-trip check.

## Sample output

```
  ROUND-TRIP (decode == original):
    rows decoded        :      50,000
    mismatches          :           0   <- 0 = lossless PASS

  DENSITY (the encode-time dictionary):
    distinct values     :  500
    primary capacity    :  560   (035 buckets x 16)
    placed in buckets   :  491   load  87.67 %
    spilled to backup   :    9                      <- the paper's delta-fraction
    lost (unplaceable)  :    0   <- lossless
    max bucket fill     : 16 / 16   (bounded probe, no tail)

  HANDLE WIDTH (per row, code vs the string):
    full string         : 024 bytes (192 bits)
    dictionary code     :  9 bits   <- the tiny pointer
    dict string->slot   :  4 bits (log2 B) vs a 32-bit pointer

  COLUMN COMPRESSION:
    raw column          :   1,200,000 bytes
    encoded codes       :      56,250 bytes
    + dictionary        :      12,000 bytes
    = total             :      68,250 bytes   ( 17.58x smaller)
```

## What it shows

- **Density.** 500 distinct values pack into a 560-slot table at **87.7% load**;
  only **9** spill to the backup, **0 lost**. That 9 is the paper's δ-fraction of
  full-bucket allocations, caught losslessly by the overflow region.
- **Handle width.** Each row stores a **9-bit code** instead of a 192-bit string;
  inside the dictionary, a string is referenced by a **4-bit** slot-in-bucket
  (`log₂ B`) rather than a 32-bit pointer, because the string rehashes to its bucket.
- **Compression.** ~**17.6× smaller** column, and it **round-trips exactly**
  (50,000 rows decoded, 0 mismatches).

## Honest notes

- Uniform repetition is the **conservative** case; real columns are skewed (Zipf),
  which compresses *better*. We use a coprime-multiplier index so all 500 distinct
  values actually appear (the dictionary genuinely fills).
- **The 17.58× is an information-theoretic figure** — the bits *per reference*, the
  exact quantity the paper compresses. The demo file is *not* bit-packed: COBOL
  `PICTURE` fields align to byte boundaries, so `ENCODED.DAT` stores a 4-digit
  display code per row and is really **250,000 bytes** on disk. A production column
  store realises the figure by bit-masking/shifting several 9-bit codes into dense
  byte blocks before writing; `cob2` can do this but it is left out here for clarity.
- **The paper assumes a near-random (fully-independent) hash.** Our `H·31 + ord(ch)`
  rolling hash is a stand-in that happens to spread these keys well (9 spills at
  87.7%). On adversarial real data — shared prefixes/suffixes, trailing pad — a weak
  hash clusters: the backup fills *and* its linear-probe chains lengthen toward
  `O(backup)`. The right fixes are a strong hash (FNV-1a / MurmurHash3 in a shared
  paragraph) to meet the paper's assumption, and — at scale — the **multi-level
  recursion** (see `tinyfull.cuf`), not just a bigger flat backup.

---

# TINYJOIN — a tiny-pointer hash join in COBOL

A self-contained IBM COBOL batch program that performs a **relational JOIN** of
two flat files using the **load-balancing dereference table** of
*Tiny Pointers* ([arXiv:2111.12800](https://arxiv.org/abs/2111.12800), §3) — the
same data structure as the CUDA Fortran engine one directory up, here on the CPU
in the language that owns the records.

```
make run        # generates the two tables, builds the table, joins, reports
```

Tested with **IBM COBOL for Linux 1.2.0** (`cob2`).

## What it does

1. **Generates two relational tables** as `LINE SEQUENTIAL` files:
   `CUSTOMER.DAT` (4,608 rows, the inner/build side) and `ORDERS.DAT`
   (18,432 rows, the outer/probe side; each order references a random customer).
2. **Builds the dereference table** from `CUSTOMER.DAT`: hash the customer id to a
   **bucket of B=8 slots**, store it in any free slot `j`. The **tiny pointer is
   `j`** — `log₂8 = 3` bits, not a full record address. A handful of buckets fill;
   those keys spill to a small **linear-probe overflow region** (the paper's backup
   table) so nothing is ever lost.
3. **Joins** by probing with each order: recompute the bucket from the key and scan
   `≤ B` slots — a bounded, tail-free `DEREFERENCE`. Writes `JOINED.DAT`.
4. **Reports density + handle width.**

## Sample output

```
  Relational JOIN:
    ORDERS rows probed  :    18,432
    matched (joined)    :    18,432   (100.00 %)

  DENSITY (how tightly the table packs):
    customers placed    :   4,608
    primary capacity    :   5,120   (640 buckets x 8)
    placed in buckets   :   4,608   load  90.00 %
    spilled to backup   :       2   (  0.26 % of backup used)
    lost (unplaceable)  :       0   <- lossless
    max bucket fill     :  8 / 8   (probe is bounded by B, no tail)

  HANDLE WIDTH (to point at a customer record):
    full pointer (RRN)  :  32 bits  = 4 bytes each
    tiny pointer        :   3 bits in-bucket, 10 bits if in backup
    blended             :  3.00 bits per customer
    index of all custs  : full    18,432 bytes
                          tiny     1,730 bytes   ( 10.65x smaller)
```

## The two things it makes visible

- **Density.** The primary table runs at **90% load** and the join is still
  **lossless** — the overflow backup catches the few full-bucket spills. No 2×
  safety margin needed.
- **Handle width.** To point at a customer you store only the **slot index**
  (3 bits), because the *key* recomputes the bucket — vs a 32-bit record
  pointer/RRN. Over all customers that is a **~10× smaller** index.

## Honest notes (so this doesn't oversell the paper)

- **This is a structure demo, not a speed demo.** Single-threaded COBOL gets none
  of the GPU's lock-free / coalesced advantages. What carries over to the CPU is
  the *bounded probe* (cache-friendly, no probe-length tail) and the *small,
  durable handle*. For throughput, the CUDA Fortran engine next door is the path.
- **Why only 2 spills at 90% load?** The customer ids are sequential and we use a
  Fibonacci (golden-ratio) multiplicative hash, which distributes sequential keys
  almost perfectly — so very few buckets exceed 8. With **random or adversarial
  keys** (UUIDs, alphanumeric storefront ids, legacy account numbers) the spill
  rate rises toward the ~6% the GPU benchmark saw at 90% load with a fully-random
  hash. That is exactly *why the backup region exists*: it turns the paper's
  δ-fraction of allocation failures into a lossless table — and **the backup here
  is already sized for that worst case, not the lucky one**: `OVF-CAP = 768` is
  16.7% of the 4,608 keys, well above the ~6% (≈276) a random distribution needs.
  The 0.26% is only how little of it the Fibonacci case happens to use.
- **The probe side does not own a tiny pointer.** An order arrives with a *key*,
  so the join probes by a bounded `≤ B` bucket scan, not the O(1) `deref` that
  needs a stored hint. The flat single-access `deref` applies to the build-once /
  own-the-handle path (e.g. a secondary index handing slots to later query steps),
  not the join probe — same distinction as the GPU `joindemo`.

## How it fits the z/OS polyglot model

COBOL owns the record layouts, the file I/O, and the batch orchestration; the
dereference table is a portable data structure expressed in working-storage. The
same shape, scaled out with lock-free atomics on the GPU, is `joindemo.cuf` /
`tinymap.cuf`. This is the small end of that spectrum — the idea made concrete on
real records, in COBOL.

## Files
- `cbl/DICTENC.cbl`  — dictionary encoder (generate → encode → decode-verify → report).
- `cbl/TINYJOIN.cbl` — hash join (generate → build → join → report).
- `Makefile` — `make run` / `run-join` / `run-dict` (sets the IBM STL `VFS_IO_*` env).
- `data/` — generated `.DAT` files (CUSTOMER/ORDERS/JOINED, COLUMN/ENCODED).
