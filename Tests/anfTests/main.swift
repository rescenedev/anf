import Foundation

// Lightweight test runner (no XCTest/Swift-Testing — unavailable on Command Line
// Tools). Run with `swift run anfTests`. Exit code 0 = all passed.

// Perf harness, not a test: ANF_BENCH=/big/folder swift run anfTests
if let benchPath = ProcessInfo.processInfo.environment["ANF_BENCH"] {
    runNavBench(path: benchPath)
    exit(0)
}

runFuzzyMatchTests()
runNormalizedRankTests()
runSFTPParseTests()
runDocumentTextTests()
runNormalizationTests()
runSortTests()
runSavedViewTests()
runFastDirReadTests()
runSafetyTests()
runViewModePrefsTests()
runGridSelectionTests()
runTypeaheadTests()
runListingCacheTests()
runListDiffTests()

print("")
if T.failures.isEmpty {
    print("✓ all \(T.checks) checks passed")
    exit(0)
} else {
    T.failures.forEach { print($0) }
    print("\n✗ \(T.failures.count) of \(T.checks) checks failed")
    exit(1)
}
