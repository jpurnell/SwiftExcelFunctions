/// A test reached a value it cannot go on from.
///
/// Thrown where a helper expected one shape of answer and got another — a function that
/// should return a number returning text, an audit with no finding to judge. That is a
/// failure, not a reason to stop looking, so it is thrown rather than skipped: Swift
/// Testing records a thrown error as an issue against the test, with this description.
struct TestFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
