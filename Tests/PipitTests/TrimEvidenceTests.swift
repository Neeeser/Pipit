import Foundation
import PipitCore
import PipitSpeakers
import Testing

/// A trim moves the audio, and the voice memory records where its evidence sits
/// in that audio.
@Suite("TrimEvidence")
struct TrimEvidenceTests {
    private static func enrol(
        _ store: SpeakerStore, name: String, seed: Int, meeting: String, spans: [AudioSpan]
    ) async throws -> IdentityID {
        let person = try await store.createPerson(name: name)
        _ = try await store.enrol(
            VoiceEnrollmentCandidate(
                identityID: person.id, vector: SpeakerFixtures.vector(seed: seed), model: .fluidAudioOffline,
                speechSeconds: AudioSpan.totalDuration(spans), qualityScore: 1, source: .humanConfirmedCluster,
                evidence: [
                    VoiceEvidence(
                        meetingID: meeting, track: .remote, spans: spans, confirmation: .humanConfirmedCluster)
                ]
            ))
        return person.id
    }

    @Test("evidence moves with the audio, and a vector from deleted audio goes")
    func evidenceMovesWithTheAudio() async throws {
        let (store, root) = try SpeakerFixtures.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        // Most of this voice is in the part that is kept, and some of it is not.
        let mostlyKept = try await Self.enrol(
            store, name: "Speaker A", seed: 81, meeting: "m1",
            spans: [AudioSpan(start: 0, end: 100), AudioSpan(start: 200, end: 300)])
        // All of this one is in the part that goes.
        let allRemoved = try await Self.enrol(
            store, name: "Speaker B", seed: 82, meeting: "m1", spans: [AudioSpan(start: 0, end: 100)])
        // The same spans in another meeting, which is not trimmed.
        let elsewhere = try await Self.enrol(
            store, name: "Speaker C", seed: 83, meeting: "m2", spans: [AudioSpan(start: 200, end: 300)])

        try await store.trimEvidence(meetingID: "m1", trimID: "t1", keepingFrom: 150, to: 280)

        let kept = try #require(try await store.storedEmbeddings(of: mostlyKept).first?.evidence.first)
        #expect(kept.spans == [AudioSpan(start: 50, end: 130)], "200 to 280 is now 50 to 130, got \(kept.spans)")
        #expect(kept.standingSpans == kept.spans)
        #expect(
            try await store.storedEmbeddings(of: allRemoved).isEmpty,
            "nothing it was learned from is left, so the vector is retracted")
        let other = try #require(try await store.storedEmbeddings(of: elsewhere).first?.evidence.first)
        #expect(other.spans == [AudioSpan(start: 200, end: 300)], "another meeting is untouched")
    }

    @Test("keeping to the end only moves the start")
    func keepingToTheEndOnlyMovesTheStart() async throws {
        let (store, root) = try SpeakerFixtures.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let person = try await Self.enrol(
            store, name: "Speaker A", seed: 84, meeting: "m1", spans: [AudioSpan(start: 100, end: 400)])
        try await store.trimEvidence(meetingID: "m1", trimID: "t1", keepingFrom: 60, to: nil)
        let evidence = try #require(try await store.storedEmbeddings(of: person).first?.evidence.first)
        #expect(evidence.spans == [AudioSpan(start: 40, end: 340)])
    }

    @Test("the same trim is applied once, however many times it is asked for")
    func theSameTrimIsAppliedOnce() async throws {
        let (store, root) = try SpeakerFixtures.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let person = try await Self.enrol(
            store, name: "Speaker A", seed: 85, meeting: "m1", spans: [AudioSpan(start: 100, end: 400)])
        // A crash after the shift committed, or a second run of the same step,
        // asks again with the same trim.
        try await store.trimEvidence(meetingID: "m1", trimID: "t1", keepingFrom: 60, to: nil)
        try await store.trimEvidence(meetingID: "m1", trimID: "t1", keepingFrom: 60, to: nil)
        let evidence = try #require(try await store.storedEmbeddings(of: person).first?.evidence.first)
        #expect(evidence.spans == [AudioSpan(start: 40, end: 340)], "moved once, got \(evidence.spans)")
    }

    @Test("a speaker heard only in the removed stretch loses the meeting's occurrence, and others lose seconds")
    func occurrencesFollowTheCut() async throws {
        let (store, root) = try SpeakerFixtures.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        for (cluster, seed) in [("remote-001_a", 1), ("remote-001_b", 2), ("remote-001_c", 3)] {
            try await store.recordOccurrence(
                meetingID: "m1", clusterID: cluster, track: .remote, speechSeconds: 100,
                embedding: SpeakerFixtures.vector(seed: seed), model: .fluidAudioOffline, resolution: nil,
                identityID: nil, source: .ai, humanVerified: false, wasExpectedParticipant: false)
        }
        try await store.recordOccurrence(
            meetingID: "m2", clusterID: "remote-001_a", track: .remote, speechSeconds: 100,
            embedding: SpeakerFixtures.vector(seed: 4), model: .fluidAudioOffline, resolution: nil,
            identityID: nil, source: .ai, humanVerified: false, wasExpectedParticipant: false)

        // a is gone from what is kept, b has 30 s left, c is not a diarization
        // cluster and is not mentioned.
        try await store.trimEvidence(
            meetingID: "m1", trimID: "t1", keepingFrom: 10, to: nil,
            clusterSeconds: ["remote-001_a": 0, "remote-001_b": 30])

        let rows = try await store.occurrences(meetingID: "m1")
        #expect(rows.map(\.clusterID).sorted() == ["remote-001_b", "remote-001_c"])
        #expect(rows.first { $0.clusterID == "remote-001_b" }?.speechSeconds == 30)
        #expect(rows.first { $0.clusterID == "remote-001_c" }?.speechSeconds == 100)
        #expect(try await store.occurrences(meetingID: "m2").count == 1, "another meeting is untouched")
    }
}
