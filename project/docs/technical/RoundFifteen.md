# Round fifteen — the tail, and whether SUMIF is a SUMIFS

**Status:** answered 2026-09-20. Five of seven findings implemented; two recorded as
scoped gaps below. Round fifteen reads **agreed 276, differed 2**, from 261 and 17.
**Written:** 2026-09-20, before the answers, so the predictions are on the record rather than
reconstructed afterwards.

---

## Why this round exists

A corpus run over 300 workbooks stands at **99.89% agreement** — 4,965 findings across 21
files, from roughly 45,000 at the start of the day. What is left is not one thing:

| Bucket | Cells | What it is |
|---|---:|---|
| `GETPIVOTDATA` | 3,802 | A capability, not a defect — needs a pivot cache |
| `SUMIF` criteria | 672 | One loose inference, described below |
| `SUMIFS` | 240 | Untriaged |
| The tail | ~250 | Three families, traced below |

This round asks about the last two. `GETPIVOTDATA` is a separate piece of work and no
conformance round can settle it, any more than one could settle 3-D references.

## What the tail actually was

**Two of the three families were not what the symptom said**, which is the reason each
question below was traced to a specific cell in a specific workbook before being asked.

### `TEXT` — 22 cells, and the format codes were never the problem

`Dot Com YTD Performance Report 6 20.xlsx!Exec Summary!J8` reads

```
CONCATENATE(TEXT($J$7,"mmm"), "Yr", YEAR($F$4), "ACT")
```

and Excel answers `"MayYr2014ACT"` where this package answers `#VALUE!`.

Every date format code was already right — `TEXT(41640,"mmm")` gives `Jan`,
`TEXT(41640,"dddd")` gives `Wednesday`. The trap is `$J$7`: it is **itself** a `TEXT(...)`
call, caching the string `"May"`. So the real shape is `TEXT("May", "mmm")` — a date format
applied to text. Excel passes the text through. This package answers `#VALUE!` for that and
for every variant tried.

Had the round asked `TEXT(41640,"mmm")` — the obvious reading of the symptom — every row
would have agreed and taught nothing.

### `INDEX` over a failed `MATCH` — 82 cells, and the lookup was empty

`Orders without Shipment Data.xlsx!Definitions!P35` reads

```
INDEX(lookup_ordersURL, MATCH($G35, lookup_shortName, 0))
```

Excel answers `#N/A`; this package answers **blank**. The names resolve to ordinary ranges on
`Sheet1`, and a failed `MATCH` already propagates `#N/A` correctly in isolation. The trap is
`$G35`, which is an **absent cell**.

So the real shape is `MATCH(blank, range, 0)` where the range itself contains a blank. This
package returns **2** — it matches the blank *inside* the range — and `INDEX` dutifully
returns the value there. A lookup that found nothing, wearing the clothes of an empty cell.

The control, the same lookup against a range with no blank in it, correctly answers `#N/A`.
That pins the cause exactly.

### `SUMPRODUCT` over `COLUMN` — 48 cells, and this one is what it looks like

```
SUMPRODUCT((MOD(COLUMN(C38:GT38),2)=$A$1) * (C38:GT38<>"") * (LEFT(C38:GT38,1)="P"))
```

counts 18 where Excel counts 12. Decomposed:

| | ours | expected |
|---|---:|---:|
| `SUM(COLUMN($H:$M))` | **8** | 63 |
| `SUM(MOD(COLUMN($H:$M),2))` | **0** | 3 |
| `SUMPRODUCT((MOD(COLUMN($H:$M),2)=0)*1)` | **1** | 3 |
| `SUMPRODUCT((LEFT($H:$M,1)="P")*1)` | 3 | 3 |

**`COLUMN(range)` returns a scalar — the first column — instead of an array.** `LEFT`
broadcasts correctly, so the fault is isolated to `COLUMN`.

The whole idiom nevertheless answers `3` on the six-cell fixture, which is the right answer
by accident: a scalar `TRUE` multiplied through the array happens to match. That is precisely
how it survived in the corpus as 18-against-12 rather than as something obviously broken.

**Every family above is asked in pieces** — `COLUMN` alone, then `MOD` over it, then the
comparison, then the whole idiom — so a disagreement names its own step. That is the lesson
of the 3-D reference bug, which spent its life inside a `SUM` that merely looked inaccurate.

## Is `SUMIF` a `SUMIFS` with the arguments moved?

The question is not rhetorical. This package very nearly implements them that way, and the
answer decides whether a rule measured for one may be applied to the other — round fourteen
has already shown these two agreeing on something they need not have.

Three candidates, each asked rather than assumed:

**A short `sum_range`.** `SUMIF(A1:A5, ">1", B1)` is documented to extend `B1` to the shape of
the criteria range; `SUMIFS` is documented to require the shapes equal. If so, one answers a
number where the other answers `#VALUE!`, and they are not the same function. *This package
currently answers `0` to both, so it extends neither.*

**An error as the criteria — the one that matters now.** 672 corpus cells read
`SUMIF($G$8:$G$250, #REF!, K$8:K$250)`, Excel cached `0`, and this package answers `#REF!`.

That is the one loose inference left here. An earlier fix propagated an error from *any*
argument position after measuring only the **sum-range** position. Round fourteen then
measured that an error *cell inside* the criteria range propagates nothing — which points the
same way without settling it, because a cell in a range and the whole criteria are different
things.

**The emitted round exposed an inconsistency in this package regardless of Excel's answer:**

| | ours |
|---|---|
| `SUMIF(range, #REF!, sum)` — literal | `#REF!` |
| `SUMIF(range, $N, sum)` where `$N` holds `#REF!` | **`0`** |

Those two should agree whichever way Excel rules, and they do not.

**A blank criteria.** An empty cell as the criterion: matches blanks, matches zero, or matches
nothing? This package answers `2` for `SUMIF` and `SUMIFS` alike, and `1` for `COUNTIF` and
`COUNTIFS` — consistent with itself, unverified against Excel.

## What this package answers today

Recorded before the round so the comparison is honest rather than remembered.

| Family | Rows | Ours |
|---|---:|---|
| `TEXT`, numeric serial | 14 | all correct already |
| `TEXT`, applied to text | 4 | `#VALUE!` throughout |
| `MATCH`/`INDEX`, array constants | 5 | all correct already |
| `MATCH`, blank lookup | 4 | `2`, and `INDEX` returns `20` |
| `SUMPRODUCT`/`COLUMN` | 6 | `COLUMN` scalar; the rest follow from it |
| `SUMIF`/`SUMIFS` pairing | 11 | the two agree everywhere; Excel may not |

## What each answer would mean

- **`TEXT("May","mmm")` returns `"May"`** → text passes through a date format unchanged, and
  22 cells close. If Excel returns `#VALUE!` too, the corpus disagreement is elsewhere again
  and the trace was wrong.
- **`MATCH(blank, range, 0)` is `#N/A`** → a blank lookup matches nothing, including a blank,
  and 82 cells close.
- **`SUM(COLUMN($H:$M))` is 63** → `COLUMN` over a range is an array, and 48 cells close.
- **`SUMIF` and `SUMIFS` diverge on the short `sum_range`** → they are not one function, every
  rule must be measured twice, and the shared implementation here needs separating.
- **`SUMIF(range, #REF!, sum)` is `0`** → the argument-propagation fix over-reached, and the
  criteria position must be excluded from it. 672 cells close.

## A note on what is not written down

Rounds nine through fourteen have no document here. Their record is the CHANGELOG and the
commit messages, which carry the measurements and the reasoning, but there is no single page
for them the way rounds one to eight have in `ExcelEvaluationLimits.md`. That gap is real and
this document does not close it.


---

# What Excel answered

Written after the round, against the predictions above.

## Confirmed, and implemented

| Question | Excel | was |
|---|---|---|
| `TEXT("May","mmm")` | `"May"` | `#VALUE!` |
| `TEXT("hello","0.00")` | `"hello"` | `#VALUE!` |
| `TEXT("2014-01-01","mmm")` | `"Jan"` | `#VALUE!` |
| `MATCH(blank, range-with-blank, 0)` | `#N/A` | `2` |
| `SUMIF(range, #REF!, sum)` | `0` | `#REF!` |
| `SUMIF`/`SUMIFS`, blank criterion | `0` | `2` |
| `COUNTIF`/`COUNTIFS`, blank criterion | `0` | `1` |
| `SUMIFS` with mismatched ranges | `#VALUE!` | a number |

Both traces held: the `TEXT` failure was about its **argument** and not its format codes, and
the `INDEX`/`MATCH` failure was a **blank lookup** and not the lookup functions. Neither would
have been found by asking the obvious reading of the symptom.

**`SUMIF` is not `SUMIFS` with its arguments moved.** Given three keys and a one-cell sum
range, Excel answers `4` for `SUMIF` — stretching the short range — and `#VALUE!` for
`SUMIFS`. Every rule measured for one must now be measured for the other.

One unasked-for finding: `TEXT(1234.5,"#,##0")` is `"1,235"` and this package answered
`"1,234"`, because `NumberFormatter` rounds to even and 1234 is the even neighbour. The two
agree on every value except an exact half.

## Refuted — and this one mattered

**`COLUMN(range)` returning a scalar is correct.**

| | Excel | ours |
|---|---:|---:|
| `SUM(COLUMN($H:$M))` | 8 | 8 |
| `SUMPRODUCT((MOD(COLUMN($H:$M),2)=0)*1)` | 3 | 1 |

The prediction above — that `COLUMN` over a range should be an array — was **wrong**, and
acting on it would have broken the case that already agreed. The real rule is that
**`SUMPRODUCT` evaluates its arguments in array context** and `SUM` does not.

The decomposition is the only reason this was caught. A round asking the whole idiom would
have shown one disagreement and pointed at the wrong function.

# The two scoped gaps

Neither is a defect to patch; both need a structural change, and both are written down rather
than approximated.

## `SUMPRODUCT` does not establish array context — 48 cells

`COLUMN` already receives the unevaluated argument trees through `EvaluationContext`, so it
can see the whole range. What is missing is a way for a *caller* to say it wants array
evaluation.

The seam is narrow — one site builds `EvaluationContext` — but the flag has to thread through
`evaluateNode`, and the rules for when it resets are not obvious: `SUMPRODUCT(SUM(COLUMN(…)))`
must not inherit it. That is a design question about array semantics generally, and doing it
hastily would encode a guess in the one place hardest to measure later.

## `SUMIF` does not stretch a short `sum_range` — part of 912 cells

Excel extends a one-cell `sum_range` to the criteria range's shape. Stretching needs the
**reference** — which cells the range would cover — and an `ExcelFunction` is handed evaluated
values, so the information is gone before the code runs. `GROUPBY` is reached before its
arguments are evaluated for a comparable reason, and the same treatment would serve here.

# What this leaves

Of the corpus residue this round set out to explain:

| | Cells | Status |
|---|---:|---|
| `SUMIF`/`SUMIFS` criteria | 912 | closed |
| `INDEX`/`MATCH` blank lookup | 82 | closed |
| `TEXT` on text | 22 | closed |
| `SUMPRODUCT`/`COLUMN` | 48 | scoped, above |
| `GETPIVOTDATA` | 3,802 | `PivotTableLookup.md` |
