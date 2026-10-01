# Swift Testing — the suite moves off XCTest

**Written:** 2026-10-01
**Covers:** one session, from a red `test-quality` gate (130 errors) to 46 of 46 checkers at
0 errors and 0 warnings, with no suppression markers and no checker exclusions.

---

## What happened

The quality gate gained a `test-quality` rule that rejects `import XCTest`. All 130 test
files used it. They are now Swift Testing, and the test count is unchanged: **2,018 tests,
all passing**, in the same five targets.

The conversion was mostly mechanical: a script parsed balanced arguments, so
`XCTAssertEqual(a, b, accuracy: e)` became `#expect(abs(a - b) <= e)`. The residue had to
be fixed by hand:

| residue | count | resolution |
|---|---:|---|
| `XCTSkip` used for "wrong kind of answer" | ~30 | `throw TestFailure(...)`, because that is a failure, not missing data |
| `XCTSkip` for private workbooks | 7 | `.enabled(if:)` traits that name the variable |
| non-literal assertion messages | ~20 | `"\(message)"`, since `Comment` is not a `String` |
| `file:`/`line:` forwarding helpers | 24 files | `sourceLocation: SourceLocation = #_sourceLocation` |
| `setUp`/`tearDown` with IUO state | 1 | `final class` with `init`/`deinit` |
| a test named `repeat` | 1 | `repetition` |

## What the checker could then see

With the assertions in `#expect`, `test-quality` could read inside them for the first time:

- **225 exact float `==`.** Every one had been an exact `XCTAssertEqual` on a result that is
  a whole number by construction (serials, counts, small-integer broadcasts). They became
  `isEqual(to:)` / `isElementwiseEqual(to:)`, which is the same claim, named. None was
  loosened to a tolerance.
- **~320 tests with no `#expect` in the body**, because they asserted through
  `assertNumber`-style helpers. The helpers became predicates in
  `ApproximateExpectations.swift`, and each call site is now an `#expect`.
- **34 `!= nil` lookups.** Each now asserts the canonical name that the lookup resolved to.

## What it found that matters beyond the tests

**`maxNodeDepth = 512` is safe only on an 8 MiB stack.** Under XCTest every test ran on the
main thread. Swift Testing uses the cooperative pool, which has 512 KiB, and eleven depth
tests died with `SIGBUS`. One was 65 nested `IF`s, the largest nesting Excel itself allows.
The tests now run on a thread with the measured stack (`MeasuredStack.swift`), so they
test the bound as it was measured.

**The product exposure is real and still open.** A library user who evaluates inside a
`Task` has the small stack. The fix is the one `maxNodeDepth`'s documentation already
names: an explicit stack in `evaluateNode`. Until then, the advice is to evaluate deep
formulas on a thread with an 8 MiB stack.

## Next

- Decide what to do about the cooperative-pool stack: rewrite `evaluateNode` to use an
  explicit stack, or have the library hop to a large-stack thread itself.
