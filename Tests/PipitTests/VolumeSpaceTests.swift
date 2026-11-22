import Foundation
import Testing

@testable import PipitCore

@Suite("Volume free space")
struct VolumeSpaceTests {
    @Test("a volume that reports zero for important usage falls back to its plain free space")
    func zeroImportantUsageFallsBackToPlainFreeSpace() {
        #expect(VolumeSpace.freeBytes(importantUsage: 0, available: 5_000_000_000) == 5_000_000_000)
    }

    @Test("a volume that leaves out important usage falls back to its plain free space")
    func missingImportantUsageFallsBackToPlainFreeSpace() {
        #expect(VolumeSpace.freeBytes(importantUsage: nil, available: 5_000_000_000) == 5_000_000_000)
    }

    @Test("important usage wins when the volume reports it")
    func importantUsageWinsWhenReported() {
        #expect(VolumeSpace.freeBytes(importantUsage: 7_000_000_000, available: 5_000_000_000) == 7_000_000_000)
    }

    @Test("a full volume still reads as zero")
    func fullVolumeReadsAsZero() {
        #expect(VolumeSpace.freeBytes(importantUsage: 0, available: 0) == 0)
    }

    @Test("a volume that answers neither reads as unknown")
    func silentVolumeReadsAsUnknown() {
        #expect(VolumeSpace.freeBytes(importantUsage: nil, available: nil) == nil)
    }
}
