import Darwin

let countdown = CountdownStateTests()
let storage = LocalStorageTests()
let plugins = PluginRegistryTests()

var checks: [(String, () throws -> Void)] = [
    ("Deadline and expiry", countdown.testDeadlineSurvivesSleepAndCompletesWithoutTicks),
    ("Pause and resume", countdown.testPauseResumeDoesNotCountPausedTime),
    ("Persisted deadline", countdown.testPersistenceRetainsDeadlineRatherThanStaleRemainingTime),
    ("Malformed countdown state", countdown.testInvalidPersistedStateIsRejected),
    ("Pause after expiry", countdown.testPauseAfterDeadlineFinishes),
    ("Clock adjustment", countdown.testBackwardClockAdjustmentKeepsStateValid),
    ("Local persistence and corruption protection", storage.testMissingStateRoundTripAndCorruptFilePreservation),
    ("Atomic state replacement", storage.testAtomicReplacementUpdatesExistingValidState),
    ("Local state size limit", storage.testSizeLimitRejectsBeforeDecoding),
    ("Local state symlink rejection", storage.testSymlinkedStateAndDataRootAreRejected),
    ("Import, upgrade and downgrade rejection", plugins.testImportUpgradeAndRejectionKeepExistingVersion),
    ("Manifest-only import", plugins.testImportsOnlyManifestAndNeverCopiesExecutableFiles),
    ("Manifest validation", plugins.testPathTraversalAndUnsupportedCapabilitiesAreRejected),
    ("Plugin symlink rejection", plugins.testSymlinkedManifestAndDestinationAreRejected),
    ("Oversized update preserves installed plugin", plugins.testOversizedImportPreservesInstalledManifest),
    ("Plugin upgrades retain the original template", plugins.testNativeTemplateUpgradeCannotChangeCapabilities),
    ("Storage ranking, sparse files, limits and symlink handling", checkStorageAnalysis),
    ("Storage rejects replaced files and redirected directories", checkStorageItemReplacement),
    ("Storage treemap preserves occupied-space proportions", checkStorageTreemap),
    ("Remember local share content and clear the selection", checkLANSharePersistence),
    ("System status preference migration and independent display settings", checkStatusPreferences),
    ("General preferences persist and select the app language", checkGeneralPreferences),
    ("System status rates across attach, counter reset and wake", checkStatusTransferRates),
    ("System process CPU precision, resident memory fallback and ranking", checkProcessReadings),
    ("IP normalization, WebRTC comparison and custom target validation", checkIPDiagnostics),
    ("Finder clipboard formats and collision-safe creation", checkFinderTools),
    ("Menu bar expansion rules and multi-display shelf placement", checkMenuBarLayout),
    ("Zsh startup discovery, recursive references, and safe saves", checkZshConfiguration),
    ("Running apps group duplicate installations and nested helpers by software", checkRunningAppGroups),
    ("Stable update discovery, version ordering, and failure handling", checkSoftwareUpdate),
]

if CommandLine.arguments.contains("--lan-share") {
    checks.append(("LAN HTTP links, files, folders, text, and shutdown", checkLANShareHTTP))
}

var failures = 0
for (name, check) in checks {
    do {
        try check()
        print("PASS \(name)")
    } catch {
        failures += 1
        print("FAIL \(name): \(error)")
    }
}
print("\(checks.count - failures)/\(checks.count) checks passed")
exit(failures == 0 ? EXIT_SUCCESS : EXIT_FAILURE)

struct CheckFailure: Error, CustomStringConvertible {
    let description: String

    init(_ message: String, file: String = #fileID, line: UInt = #line) {
        description = "\(file):\(line): \(message)"
    }
}

func expect(_ condition: Bool, file: String = #fileID, line: UInt = #line) throws {
    guard condition else { throw CheckFailure("Expected true", file: file, line: line) }
}

func expectFalse(_ condition: Bool, file: String = #fileID, line: UInt = #line) throws {
    try expect(!condition, file: file, line: line)
}

func expectNil<T>(_ value: T?, file: String = #fileID, line: UInt = #line) throws {
    try expect(value == nil, file: file, line: line)
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, file: String = #fileID, line: UInt = #line) throws {
    guard actual == expected else {
        throw CheckFailure("Expected \(expected), got \(actual)", file: file, line: line)
    }
}

func expectError<T>(
    _ operation: @autoclosure () throws -> T,
    _ message: String = "Expected an error",
    verify: ((Error) throws -> Void)? = nil,
    file: String = #fileID,
    line: UInt = #line
) throws {
    do {
        _ = try operation()
    } catch {
        try verify?(error)
        return
    }
    throw CheckFailure(message, file: file, line: line)
}
