import Foundation

// Minimal test harness. SwiftPM and XCTest are not available on every Command Line Tools install, so tests are plain
// executables: `scripts/test.sh` builds and runs them and the exit code reports the result.

nonisolated(unsafe) var checkCount = 0
nonisolated(unsafe) var failureCount = 0

func expect(_ condition: @autoclosure () -> Bool, _ name: String, file: StaticString = #filePath, line: UInt = #line) {
    checkCount += 1
    if !condition() {
        failureCount += 1
        print("FAIL: \(name)  (\((String(describing: file) as NSString).lastPathComponent):\(line))")
    }
}

/// Directory of the repository, derived from this file's location (Tests/HalfLidCoreTests/Harness.swift).
let repositoryRoot: URL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
