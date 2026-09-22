import Foundation
#if canImport(os)
import os
#endif

/// A line of the report, which is this program's *output* rather than its logging.
///
/// The same seam the oracle tool draws: what a caller asked for goes to stdout, and anything
/// about how the run went goes to stderr and the system log. `print()` cannot tell the two
/// apart, which is why the gate refuses it.
func say(_ line: String) {
    FileHandle.standardOutput.write(Data((line + "\n").utf8))
}

/// Writes one line to stderr, and to the system log where there is one.
func report(_ message: String) {
    FileHandle.standardError.write(Data(("model-simulation: " + message + "\n").utf8))
    #if canImport(os)
    // Public privacy: a path the operator named and this program's account of it.
    Logger(subsystem: "ModelSimulation", category: "run")
        .error("\(message, privacy: .public)")
    #endif
}
