# Tiny Pointers on the GPU — CUDA Fortran benchmark

A faithful, runnable implementation of the **load-balancing dereference table**
from Bender, Conway, Farach-Colton, Kuszmaul & Tagliavini,
*"Tiny Pointers"*, [arXiv:2111.12800](https://arxiv.org/abs/2111.12800) (§3),
benchmarked head-to-head against a classic **linear-probing open-addressing**
hash table — both running on the GPU.

Tested on: NVIDIA RTX A1000 Laptop (Ampere, cc8.6, 4 GB), nvfortran 26.1, CUDA 13.1.

## Build & run

```
make all                 # builds hashbench + tinyfull (nvfortran -cuda -gpu=cc86 -O3)
./hashbench              # head-to-head: defaults capacity 2^22, bucket size B=16
./hashbench 22 32        # capacity 2^22, bucket size B=32
./hashbench 22 16 csv    # machine-readable CSV (used by the notebook)
./tinyfull 22 16 0.90    # full demo: multi-level table + relaxed retrieval
```

## Jupyter notebook (the full demo)

`tiny_pointers_demo.ipynb` builds both programs, runs them, and plots everything:
head-to-head throughput, the probe-length blow-up, the Theorem-1 tradeoff curve
swept over `B`, the recursive multi-level table driving failures to **zero**, and
the relaxed-retrieval checksum + space comparison. Regenerate / re-run with:

```
python3 build_notebook.py                                  # regenerate the .ipynb
jupyter nbconvert --to notebook --execute --inplace \
        --ExecutePreprocessor.timeout=300 tiny_pointers_demo.ipynb
```

## The idea in one paragraph

To *reference* a slot in an array of `n` elements you normally need a
`log2(n)`-bit pointer. The paper's insight: if a **key `k` owns** the pointer,
then `k` plus a tiny `O(log log n)`-bit hint is enough to recover the location.
Concretely: hash `k` to a **bucket** of `B` slots and store it in any free slot
`j`. The **tiny pointer is just `j`** — `log2(B)` bits, not `log2(n)`.
`DEREFERENCE(k, p)` is the single slot `hash(k)*B + p`: no probing, no
indirection. The price of tininess is that a bucket can fill, so a small
δ-fraction of inserts (`ALLOCATE`s) fail — the paper's Lemma 1.

## What's measured

| column | meaning |
|---|---|
| `ins Mops` | insert throughput, million ops/s (best of 3) |
| `lkup / deref / scan Mops` | lookup throughput |
| `avgprobe / maxprobe` | linear-probing probe-sequence length |
| `alloc-fail%` | fraction of tiny-pointer inserts that found a full bucket |

Three lookup modes: traditional **probe**, tiny-pointer **deref** (O(1), uses the
stored 4-bit hint — the paper's actual claim), and **scan** (bounded `B`-slot
bucket scan with no hint — the apples-to-apples "find by searching").

## Results (capacity 2^22 = 4.19M slots, B=16)

```
load |        TRADITIONAL (linear probing)        |          TINY POINTERS
  %  |  ins Mops  lkup Mops  avgprobe  maxprobe   |  ins Mops  deref Mops  scan Mops  fail%
-----+--------------------------------------------+-------------------------------------------
50   |    860      2306        1.50        61     |    261      2468       1478      0.08
70   |    791      2138        2.17       136     |    187      2502       1250      1.29
80   |    709      1929        2.99       338     |    163      2546       1135      3.10
90   |    546      1503        5.51      1355     |    146      2622       1061      6.00
95   |    366      1001       10.56      3729     |    138      2671       1010      7.85
99   |     88       213       52.53     75651     |    133      2720        939      9.49
```

### Takeaways
- **Bounded vs. unbounded.** Linear probing collapses as the table fills —
  average probe 1.5→52, **max probe 61→75,651**, lookup throughput 2306→213
  Mops. Tiny-pointer `deref` is **flat at ~2500–2700 Mops regardless of load**:
  one memory access, always.
- **The crossover.** At 99% load the traditional table is so degraded that
  tiny-pointer *insert* (133 Mops) also beats linear-probing insert (88 Mops),
  even though tiny inserts contend within a 16-slot bucket.
- **Space.** The external reference shrinks from `log2(n)=22` bits to
  `log2(B)=4` bits — **5.5× smaller** — which is the headline of the paper.
- **The cost.** A 9.5% allocation-failure rate at 99% load. A full dereference
  table (Theorem 1) absorbs this δ-fraction in a small backup structure; here we
  expose it raw to make the tradeoff visible.

### The Theorem-1 tradeoff curve (tiny-pointer size ↔ load factor), at 99% load

| `B` | tiny pointer | space win | alloc-fail % |
|----:|-------------:|----------:|-------------:|
|   8 | 3 bits | 7.3× | 13.5 |
|  16 | 4 bits | 5.5× |  9.5 |
|  32 | 5 bits | 4.4× |  6.6 |
|  64 | 6 bits | 3.7× |  4.5 |

Bigger buckets → smaller failure rate but a wider tiny pointer (`log B`) and
slower inserts (more intra-bucket `atomicCAS` contention). This *is* the
`s = O(log log n + log δ⁻¹)` tradeoff of Theorem 1, measured on real silicon.

## The two extensions (in `tinyfull.cuf`)

**Extension 1 — recursive multi-level table.** Each level catches the previous
level's overflow at per-level load ≈ 0.90, so the residual failure fraction
shrinks geometrically. Measured: **0 failures in 6 levels**, overall load ≈ 85%.
The tiny pointer becomes `(level, slot)` = `log₂(levels)+log₂B` bits — still
`O(log log n)`. This is the paper's recursion that reaches load `1−o(1)`.

**Extension 2 — relaxed retrieval (key-less value store).** The store holds
*values*, not keys; occupancy is a separate array used only to claim slots at
insert. `DEREFERENCE` returns the value from the `(level,slot)` hint with no key
comparison and no probing. Correctness is verified on-device by checksum (PASS).

```
LEVEL,0,4194304,3942738,5.997801,4660352,0.9000
LEVEL,1,251566,236602,0.356770,4939872,0.8491
...
LEVEL,5,5,5,0.000000,4957584,0.8460     <- residual hits 0
DEREF,1314.93,1,7.0,22.0                 <- 1315 Mops, checksum OK, 7-bit ptr vs 22-bit
```

## Reusable module: `tinymap` (generic, device-callable)

`tinymap.cuf` packages the dereference table as a drop-in module. It maps a
**64-bit key → 32-bit slot index**; you keep values in your own array indexed by
that slot, so it's value-type agnostic. Two call styles:

```fortran
use tinymap

! --- device-callable: fuse the lookup into YOUR kernel, no extra launch ---
attributes(global) subroutine my_probe(store, nbkt, B, qkeys, n, out)
  integer(8), device :: store(*), qkeys(n)
  integer, device :: out(n)
  integer, value :: nbkt, B, n
  integer :: tid
  tid = (blockidx%x-1)*blockdim%x + threadidx%x
  if (tid <= n) out(tid) = ttd_find(store, nbkt, B, qkeys(tid))   ! -1 if absent
end subroutine

! --- host bulk helpers ---
type(tiny_map) :: map
call tt_create(map, nkeys, B, 0.90)              ! size for load factor 0.90
call tt_build (map, d_keys, d_rowids, n, nfail)  ! parallel build
call my_probe<<<g,b>>>(map%store, map%nbkt, map%B, d_q, nq, d_out)
call tt_destroy(map)
```

A linear-probe baseline (`lpd_find`/`lpd_insert`, `k_build_lp`) ships in the same
module so you can A/B with identical call sites.

## Worked example: GPU hash JOIN / group-by (`joindemo.cuf`)

Build a table on R=4.19M keys, probe with S=67.1M rows (lookup fused inline),
sweep build load factor, compare vs. linear probing at the same slot budget:

```
load |  TINY: build Mr/s  probe Mr/s |  LP: build Mr/s  probe Mr/s | tt_fail% match%
50   |        175          855       |       440         1612      |  0.08    99.9
90   |        115          631       |       304          901      |  6.00    94.0
99   |        108          598       |        61          163      |  9.50    90.5   <- tiny ~3.7x faster
```

**Honest reading:** linear probing is faster at low/moderate load (simpler, fewer
reads per probe). Tiny pointers win where it matters for a memory-tight,
build-once/probe-many table: at **high load (crossover ~95%)** they beat linear
probing on *both* build and probe (~3.7× probe at 99%), with flat predictable
latency (no probe-length tail) and 4-bit references. The single-level match dip
(90.5% at 99%) is what the multi-level table (`tinyfull`) drives back to 100%.

**Where the impact concentrates:** high-load / bandwidth-bound / latency-sensitive
parallel dictionaries — hash joins & group-bys, dedup/set-membership, graph
frontier dedup & adjacency compression, embedding/feature lookups — *not* a
universal drop-in speedup.

## Worked example 2: paged KV-cache / the "optimal stash" (`kvpage.cuf`)

Makes the paper's external-memory **stash** concrete as a vLLM-style paged
KV-cache (memory management only, no transformer). KV is split into blocks living
in an **HBM pool** (device, fast, scarce) or a **host pinned pool** (real
PCIe = "external memory"); a `tiny_map` directory locates a block with **0
external accesses**, then one access fetches it. Because a KV-cache *cannot drop a
block*, it uses the **reliable 2-level directory** (`ttd_insert_r`/`ttd_find_r`:
bucket + linear-probe overflow = the paper's backup table) — `build fails=0`,
correctness checksum passes.

```
EXP 1 -- gather throughput vs. HBM residency (locate always free):
  HBM%  Mq/s   GB/s   hit%
   0    5.8    5.9     0      all KV over PCIe (slow)
  50   16.6   17.0    50
 100   63.8   65.3   100      all KV in HBM (~11x faster)

EXP 2 -- directory placement (compact resident vs. spilled), by block size:
  block 128 B:  resident 145.8   spilled 42.1   = 3.46x   <- single vs double access
  block 1 KB :  resident  17.7   spilled 13.8   = 1.28x
```

Two lessons: **(1)** residency drives throughput (why you page at all), and
**(2)** a *compact* index stays HBM-resident, so each query is one PCIe access
(data only) — a bulkier spilled index costs a second PCIe hop per lookup, up to
3.5× slower. Shrinking the index (tiny pointers) is what buys the single-access
property. Honest scope: at these sizes the index fits either way, so we *place* it
in host memory to expose the effect; at billion-block scale (LLM serving,
embedding tables) it becomes a hard HBM boundary — a tier jump, not a constant.

## The paper's five applications (§1.2)

The dereference table is the engine behind five data structures the paper calls
out. Two fall out of the work above; the other three are small standalone demos.

| # | Application | Demo | The tiny pointer replaces | Observed |
|---|---|---|---|---|
| 1 | Optimal internal-memory **stash** | `kvpage.cuf` | a full external address | locate in 0 PCIe accesses, fetch in 1 |
| 2 | **Relaxed** retrieval (key-less) | `tinyfull.cuf` §2 | the stored key | value from `(level,slot)`, checksum PASS |
| 3 | Space-efficient **stable** dictionary | `stabledict.cuf` | a relocatable address | **100% vs 0%** handle survival under growth |
| 4 | Space-efficient **dictionary** | `spacedict.cuf` | an 8-byte stored key | ~7× less overhead/key at 8-byte values |
| 5 | Succinct **binary search tree** | `succinctbst.cuf` | two `log n`-bit child pointers | 8 bits vs 21 per child, searches correct |

### #5 — succinct BST (`succinctbst.cuf`)

A node's children are named by their **heap path-id** (`root=1`, left `2p`, right
`2p+1`), which the parent recomputes — so the only thing stored per child is the
small probe-**displacement** to its cell. `DEREFERENCE(child_id, disp) =
(hash(child_id)+disp) mod M` is one access, no probing. Child pointers shrink from
`log n` to `log(maxdisp)` bits; lossless by construction (it's just open
addressing whose displacement we remembered).

```
./succinctbst 1048576 0.70
#  N=1048576  load=0.70  M=1497966  maxdisp=128
#  found=524288 / should=524288  found_ok=1
BST,1048576,0.70,1497966,128,8.,21.,1,796.27   <- 8-bit child ptr vs 21-bit, 61.9% smaller
```

The `maxdisp` (hence the bit width) is set by the load factor — lowering load
shrinks the displacement tail. That *is* the Theorem-1 width↔load tradeoff again.

### #3 — stable dictionary (`stabledict.cuf`)

Hand out each key's tiny pointer as a **durable handle**, then grow the table. The
reliable 2-level table is pre-sized with headroom, so growth touches only empty
cells and every handle stays valid. A linear-probe table must **resize → rehash**
to accept the growth, invalidating every previously-issued address.

```
./stabledict 1048576 1048576           # populate 2^20, then double it
STABLE,1048576,1048576,100.0,0.0,4.,22.   <- tiny 100% stable / LP 0% / handle 4 vs 22 bits
```

### #4 — space-efficient dictionary (`spacedict.cuf`)

Overhead **bits per key** beyond the raw values. A linear-probe table stores the
8-byte key in every slot *and* runs below load 1 (slack); the tiny-pointer relaxed
dict stores no key (the key owns a `log B`-bit pointer). Both are built and the
tiny one is verified to retrieve every value with no key read; the program then
sweeps the value width:

```
./spacedict
SPACEHDR,1048576,1,1                    # tiny_ok=1, lp_ok=1 (both correct)
SPACE,2,72.9,5.8                        # V=2B:  LP 72.9 vs tiny 5.8 bits/key  (12.6x)
SPACE,8,78.2,11.1                       # V=8B:  LP 78.2 vs tiny 11.1          ( 7.0x)
SPACE,64,128.0,60.9                     # V=64B: gap narrows as values dominate
```

The smaller the value, the more the stored 8-byte key dominates the conventional
table's overhead — exactly where storing *no* key wins biggest.

## Files
- `hashbench.cuf` — head-to-head: `hmix` hash, `insert_lp`/`lookup_lp` (traditional),
  `insert_lb`/`deref_lb`/`scan_lb` (tiny-pointer) + host driver/timing/CSV.
- `tinyfull.cuf` — extensions 1 & 2: multi-level dereference table + relaxed retrieval.
- `tinymap.cuf` — **reusable module**: device-callable `ttd_find`/`ttd_insert` +
  host `tt_create`/`tt_build`/`tt_destroy`, plus a linear-probe baseline.
- `joindemo.cuf` — GPU hash join / group-by built on `tinymap`.
- `kvpage.cuf` — paged KV-cache / external-memory stash over a HBM+host tier boundary.
- `succinctbst.cuf` — application #5: succinct binary search tree (tiny child pointers).
- `stabledict.cuf` — application #3: stable dictionary (durable handles under growth).
- `spacedict.cuf` — application #4: space-efficient dictionary (overhead bits/key).
- `build_notebook.py` — generates `tiny_pointers_demo.ipynb`.
- `tiny_pointers_demo.ipynb` — runnable demo with all plots.
- `Makefile`

## Honest caveats / where this is a simplification
- Hash treated as fully random (one fixed 64-bit mix), per the paper's
  "fully independent hash" assumption.
- Keys are stored directly in `hashbench` (a 32-bit key stands in for a
  `log n`-bit reference); bits/key counts the *external* reference width, which
  is the quantity the paper compresses. `tinyfull` drops the stored key entirely
  (relaxed retrieval).
- Relaxed retrieval (`tinyfull` ext 2) has **no membership test** — the `(level,slot)`
  hint is an exact per-key address, not a probabilistic bucket match, so there is no
  checksum-collision risk; but querying a key that was never inserted returns garbage.
  That is the paper's retrieval model (caller owns the hint). Use a key-storing
  dictionary (`spacedict`/`stabledict`, or the reliable table) when you need membership.
- `fail_pct` (`hashbench`) is reproducible to the digit across runs — it is true bucket
  exhaustion (a function of the hash), not an `atomicCAS` race; inserts are lock-free.
- The multi-level sizing (per-level load 0.90) is a practical choice, not a
  tuned optimum; the paper's analysis gives the asymptotic level count.
