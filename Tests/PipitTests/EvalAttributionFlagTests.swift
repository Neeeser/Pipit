import Foundation
import PipitCore
import Testing

@testable import PipitEval

/// `pipit-eval --attribution` changes what a run measures, so a command that
/// would ignore it refuses it, and a reprocess that would write the app's own
/// meetings refuses any mode but the one the app runs.
@Suite("Eval attribution flag")
struct EvalAttributionFlagTests {
    @Test("only bench and reprocess accept an attribution mode")
    func onlyBenchAndReprocessAcceptAnAttributionMode() {
        #expect(Arguments.attributionRefusal(command: "bench") == nil)
        #expect(Arguments.attributionRefusal(command: "reprocess") == nil)
        for command in ["echo", "aec", "gate", "reanalyze", "live", "summaries", "voices"] {
            #expect(
                Arguments.attributionRefusal(command: command) != nil,
                "\(command) ignores the flag, so it must refuse it")
        }
    }

    @Test("a reprocess in the app's own archive keeps to the mode the app runs")
    func aReprocessInTheAppsOwnArchiveKeepsToTheModeTheAppRuns() {
        let app = URL(fileURLWithPath: "/Users/someone/Documents/Pipit/Meetings")
        let copy = URL(fileURLWithPath: "/Users/someone/Documents/experiment/Meetings")
        #expect(
            ReprocessCommand.refusal(attribution: .sensorFirst, archive: app, appArchive: app) != nil)
        #expect(
            ReprocessCommand.refusal(attribution: .current, archive: app, appArchive: app) == nil)
        #expect(
            ReprocessCommand.refusal(attribution: .sensorFirst, archive: copy, appArchive: app) == nil)
    }
}
