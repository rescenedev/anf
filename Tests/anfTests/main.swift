import Foundation

// Lightweight test runner (no XCTest/Swift-Testing — unavailable on Command Line
// Tools). Run with `swift run anfTests`. Exit code 0 = all passed.

// Perf harnesses, not tests: ANF_BENCH=/big/folder, ANF_BENCH_PDF=/pdf/folder
if let benchPath = ProcessInfo.processInfo.environment["ANF_BENCH"] {
    runNavBench(path: benchPath)
    exit(0)
}
if let pdfPath = ProcessInfo.processInfo.environment["ANF_BENCH_PDF"] {
    runPDFBench(path: pdfPath)
    exit(0)
}
if let soakRoot = ProcessInfo.processInfo.environment["ANF_SOAK"] {
    runSoak(root: soakRoot)
    exit(0)
}
if let copySrc = ProcessInfo.processInfo.environment["ANF_BENCH_COPY"] {
    MainActor.assumeIsolated { runCopyBench(src: copySrc) }
    exit(0)
}
if let ocrRoot = ProcessInfo.processInfo.environment["ANF_BENCH_OCR"] {
    runOCRBench(root: ocrRoot)
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
runTransferTests()
runVolumeDetectionTests()
runL10nTests()
runThumbnailThrottleTests()
runFileTagsTests()
runVaultTests()
runArchiveTests()
MainActor.assumeIsolated { runWorkspacePinTests() }
runQLPreviewSelectionTests()
MainActor.assumeIsolated { runInspectorTests() }
runKeymapTests()
runDocxStructureTests()
runHwpxStructureTests()
runSidebarTests()
runOCRTests()
runVisualIndexTests()
runLLMTests()
runRenameTests()
runTreeTests()
runFileGroupingTests()
runSmartFolderTests()
runPathProbeTests()
runSSHConfigTests()
runScreenshotOrganizerTests()
runRemoteMountTests()
runAIConsentTests()
runVaultGuardTests()
MainActor.assumeIsolated { runUndoCoalesceTests() }
MainActor.assumeIsolated { runNetworkStallTests() }
MainActor.assumeIsolated { runPathEditTests() }
MainActor.assumeIsolated { runTabTitleTests() }
MainActor.assumeIsolated { runPathBarClickTests() }
MainActor.assumeIsolated { runParentRowTests() }
MainActor.assumeIsolated { runPostActionFocusTests() }
MainActor.assumeIsolated { runNavHistoryTests() }
MainActor.assumeIsolated { runSelectionSafetyTests() }
MainActor.assumeIsolated { runPaneTabTests() }
MainActor.assumeIsolated { runListSyncStateTests() }
runFileOpsNamingTests()
runKeybindingMapTests()
runWindowsSystemFilesTests()
runDirectoryWatcherTests()
MainActor.assumeIsolated { runExternalRefreshTests() }
MainActor.assumeIsolated { runWorkspacePersistenceTests() }
runFixVerificationTests()

print("")
if T.failures.isEmpty {
    print("✓ all \(T.checks) checks passed")
    exit(0)
} else {
    T.failures.forEach { print($0) }
    print("\n✗ \(T.failures.count) of \(T.checks) checks failed")
    exit(1)
}
