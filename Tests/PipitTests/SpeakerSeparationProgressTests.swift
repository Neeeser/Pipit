import Foundation
import PipitCore
import Testing

@Suite("Speaker separation progress")
struct SpeakerSeparationProgressTests {
    @Test("the download fills the first part, and the compile carries on from there")
    func theDownloadFillsTheFirstPartAndTheCompileCarriesOnFromThere() {
        #expect(SpeakerSeparationProgress.downloading(0) == 0)
        #expect(SpeakerSeparationProgress.downloading(1) == SpeakerSeparationProgress.downloadShare)
        #expect(SpeakerSeparationProgress.compiling(elapsed: 0) == SpeakerSeparationProgress.downloadShare)
    }

    @Test("the compile part keeps moving and never reads as done before it is")
    func theCompilePartKeepsMovingAndNeverReadsAsDoneBeforeItIs() {
        var previous = SpeakerSeparationProgress.compiling(elapsed: 0)
        for second in stride(from: 10.0, through: 900, by: 10) {
            let value = SpeakerSeparationProgress.compiling(elapsed: second)
            #expect(value > previous)
            #expect(value < SpeakerSeparationProgress.ceiling)
            previous = value
        }
    }

    @Test("a typical first load ends with the bar most of the way along")
    func aTypicalFirstLoadEndsWithTheBarMostOfTheWayAlong() {
        // 158 s was the fastest measured compile; it should not end with the
        // bar barely past the download, nor sit near full for minutes before.
        let fastest = SpeakerSeparationProgress.compiling(elapsed: 158)
        #expect(fastest > 0.6 && fastest < 0.9)
        #expect(SpeakerSeparationProgress.compiling(elapsed: 590) > 0.9)
    }
}
