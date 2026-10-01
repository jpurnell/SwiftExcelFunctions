import Foundation

/// The stack `FormulaEvaluator.maxNodeDepth` was measured against: the main thread's 8 MiB.
let measuredStackSize = 8 << 20

/// Runs `body` on a thread with ``measuredStackSize`` of stack and returns what it returns.
///
/// **Why the deep tests need this.** `FormulaEvaluator.evaluateNode` recurses, and its
/// node bound was found by bisection on the main thread under XCTest — 8 MiB of stack, dead
/// by about 1,200 frames, so 512 was chosen with better than 2× margin. Swift Testing runs a
/// test on the cooperative pool instead, whose threads have 512 KiB. A debug frame of
/// `evaluateNode` is a few KiB, so on that stack even 65 nested `IF`s — legal in Excel —
/// end in `SIGBUS` rather than an answer.
///
/// So the tests of depth run where the bound was measured, which keeps them testing the
/// bound rather than the test runner's choice of thread. **It does not make a caller on the
/// cooperative pool safe**: that caller has the small stack, and the bound does not fit it.
/// That gap is recorded at `FormulaEvaluator.maxNodeDepth`; the evaluator's own advice to a
/// caller who needs the depth is this same fix, a thread with a larger stack.
///
/// Only the work runs on that thread. The result comes back to the test, and expectations
/// are made there, where Swift Testing knows which test they belong to.
func onMeasuredStack<T: Sendable>(
    _ body: @escaping @Sendable () throws -> T
) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        let thread = Thread {
            continuation.resume(with: Result { try body() })
        }
        thread.stackSize = measuredStackSize
        thread.start()
    }
}
