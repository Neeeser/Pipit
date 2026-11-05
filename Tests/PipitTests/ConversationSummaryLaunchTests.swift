import Foundation
import PipitCore
import PipitIntegrations
import PipitLocalAI
import PipitServices
import Synchronization
import Testing

/// Launch rewrites, backups and the announcements of a failed rewrite.
extension ConversationSummaryRewriteTests {
    @Test("an owed rewrite is paid when the compaction of the last busy recording ends")
    func compactionPaysTheDebt() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        // Recordings with audio on disk, so the compaction is a real job.
        let first = try PipelineFixtures.makeRecordedMeeting(root: root, seconds: 6)
        let second = try PipelineFixtures.makeRecordedMeeting(root: root, seconds: 6)
        for (index, part) in [first, second].enumerated() {
            try part.store.writeCanonicalTranscript(
                CanonicalTranscript(
                    generatedAt: Self.base,
                    utterances: [
                        Utterance(
                            id: "u0", start: 0, end: 5, track: .remote,
                            rawSpeakerLabel: "remote-001_speaker_00",
                            speakerKey: "remote-001_speaker_00", text: "part \(index) words",
                            chunkID: "c1", model: "m")
                    ]))
        }
        _ = try first.store.updateMetadata {
            $0.absorbedMeetingIDs = [second.metadata.id]
            $0.processing = ProcessingStatus(state: .complete, updatedAt: Self.base)
        }
        _ = try second.store.updateMetadata {
            $0.mergedIntoMeetingID = first.metadata.id
            $0.processing = ProcessingStatus(state: .transcribing, updatedAt: Self.base)
        }
        let backend = FakeAIBackend()
        let pipeline = Self.makePipeline(repository: first.repository, backend: backend)
        await pipeline.refreshConversationSummary(meetingID: first.metadata.id)
        #expect(backend.enrichmentRequests.isEmpty)

        _ = try second.store.updateMetadata {
            $0.processing = ProcessingStatus(state: .complete, updatedAt: Self.base)
        }
        let found = try #require(first.repository.findMeeting(id: second.metadata.id, includingMerged: true))
        #expect(AudioCompactor.hasWork(store: found.store, metadata: found.metadata), "a real compaction")
        await pipeline.compactAudio(meetingID: second.metadata.id)

        #expect(backend.enrichmentRequests.count == 1)
    }

    @Test("asking again about a rewrite that needs no key changes nothing and tells nobody")
    func unchangedMissingKeyIsNotAnnounced() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pair = try Self.makeLinkedPair(root: root)
        let backend = FakeAIBackend()
        backend.configured = false
        let announced = Failures()
        let pipeline = Self.makePipeline(
            repository: pair.repository, backend: backend,
            onSummaryRewritten: { announced.add($0) })

        await pipeline.refreshConversationSummary(meetingID: pair.ids[0])
        await pipeline.refreshConversationSummary(meetingID: pair.ids[0])

        #expect(announced.all == [pair.ids[0]], "once, when the missing key was first recorded")
    }

    @Test("a backup that cannot be made stops the rewrite and leaves the summary alone")
    func failedBackupKeepsTheSummary() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pair = try Self.makeLinkedPair(root: root)
        try pair.stores[0].writeSummary("Edited by hand.")
        // A file where the backups folder should be, so no folder can be made.
        let blocked = root.appendingPathComponent("Backups")
        try Data().write(to: blocked)
        let reported = Failures()
        let pipeline = Self.makePipeline(
            repository: pair.repository, backend: FakeAIBackend(), summaryFailures: reported,
            summaryBackups: blocked)

        await pipeline.refreshConversationSummary(meetingID: pair.ids[0])

        #expect(pair.stores[0].readSummaryDocument().summary == "Edited by hand.")
        #expect(reported.all == [pair.ids[0]])
    }

    @Test("a failure that asking again cannot fix stops launch retries until the person asks")
    func givenUpRewriteIsNotRetriedAtLaunch() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pair = try Self.makeLinkedPair(root: root)
        try pair.stores[0].writeSummary("First part only.")
        let backend = FakeAIBackend()
        backend.failEnrichment = .languageModel(provider: "Ollama", failure: .rejected(status: 400))

        await Self.makePipeline(repository: pair.repository, backend: backend)
            .payLaunchSummaryRewrites()
        #expect(backend.enrichmentRequests.count == 1)
        let metadata = try pair.stores[0].readMetadata()
        #expect(metadata.summaryNeedsRewrite == true, "the notice and its button stay")
        #expect(metadata.summaryRewriteGivenUp == true)

        // The next launch, a new run of the pipeline, does not ask again.
        await Self.makePipeline(repository: pair.repository, backend: backend)
            .payLaunchSummaryRewrites()
        #expect(backend.enrichmentRequests.count == 1)

        // The person's own ask does, and clears the decision when it works.
        backend.failEnrichment = nil
        await Self.makePipeline(repository: pair.repository, backend: backend)
            .refreshConversationSummary(meetingID: pair.ids[0])
        #expect(backend.enrichmentRequests.count == 2)
        #expect(try pair.stores[0].readMetadata().summaryRewriteGivenUp == nil)
    }

    @Test("a garbled answer is not a refusal, so launches try again")
    func garbledAnswerIsRetriedAtLaunch() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pair = try Self.makeLinkedPair(root: root)
        try pair.stores[0].writeSummary("First part only.")
        let backend = FakeAIBackend()
        backend.failEnrichment = .malformedResponse(reason: "garbled")

        await Self.makePipeline(repository: pair.repository, backend: backend)
            .payLaunchSummaryRewrites()
        #expect(try pair.stores[0].readMetadata().summaryRewriteGivenUp == nil)
        await Self.makePipeline(repository: pair.repository, backend: backend)
            .payLaunchSummaryRewrites()

        #expect(backend.enrichmentRequests.count == 2)
    }

    @Test("a launch debt paid later after a wait is still not announced")
    func postponedLaunchDebtStaysQuiet() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pair = try Self.makeLinkedPair(root: root, secondState: .transcribing)
        try pair.stores[0].writeSummary("First part only.")
        let backend = FakeAIBackend()
        backend.failEnrichment = .transport(reason: "offline")
        let reported = Failures()
        let pipeline = Self.makePipeline(
            repository: pair.repository, backend: backend, summaryFailures: reported)

        await pipeline.payLaunchSummaryRewrites()
        #expect(backend.enrichmentRequests.isEmpty, "postponed: a part is still processing")
        _ = try pair.stores[1].updateMetadata {
            $0.processing = ProcessingStatus(state: .complete, updatedAt: Self.base)
        }
        await pipeline.process(meetingID: pair.ids[1])

        #expect(backend.enrichmentRequests.count == 1)
        #expect(reported.all.isEmpty)
    }

    @Test("an ask from the person that joins a launch rewrite in flight is announced if it fails")
    func personJoiningALaunchRewriteIsAnnounced() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pair = try Self.makeLinkedPair(root: root)
        try pair.stores[0].writeSummary("First part only.")
        let backend = FakeAIBackend()
        backend.failEnrichment = .transport(reason: "offline")
        let open = Mutex(false)
        backend.enrichInterference = {
            while !open.withLock({ $0 }) { try? await Task.sleep(nanoseconds: 2_000_000) }
        }
        let reported = Failures()
        let pipeline = Self.makePipeline(
            repository: pair.repository, backend: backend, summaryFailures: reported)
        let launch = Task { await pipeline.payLaunchSummaryRewrites() }
        while backend.enrichmentRequests.isEmpty { try await Task.sleep(nanoseconds: 2_000_000) }

        await pipeline.refreshConversationSummary(meetingID: pair.ids[0])
        open.withLock { $0 = true }
        await launch.value

        #expect(reported.all.contains(pair.ids[0]))
    }

    @Test("the launch pass leaves single meetings and conversations without a summary alone")
    func launchPassSkips() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        // Joined, but nothing was ever summarized.
        let pair = try Self.makeLinkedPair(root: root)
        // One meeting with a summary and no other recording.
        let single = try RuntimeFixtures.makeMeeting(
            root: root, clusters: ["remote-001_speaker_00"], title: "Alone",
            startedAt: Self.base.addingTimeInterval(86_400))
        try single.store.writeSummary("A summary.")
        let backend = FakeAIBackend()
        let pipeline = Self.makePipeline(repository: pair.repository, backend: backend)

        await pipeline.payLaunchSummaryRewrites()

        #expect(backend.enrichmentRequests.isEmpty)
        #expect(try pair.stores[0].readMetadata().summaryNeedsRewrite == nil)
        #expect(try single.store.readMetadata().summaryNeedsRewrite == nil)
    }

    @Test("a summary problem says what happened and where to try again, with no promise to retry")
    func summaryProblemWording() {
        let errors: [ProcessingError] = [
            .authenticationFailed, .rateLimited(retryAfter: nil), .serverError(status: 500),
            .transport(reason: "x"), .malformedResponse(reason: "x"),
            .languageModel(provider: "Ollama", failure: .unreachable),
            .languageModel(provider: "Ollama", failure: .rejected(status: 400)),
        ]
        for error in errors {
            let text = error.summaryProblemMessage
            #expect(text.hasSuffix("Open the meeting to write the summary again."), "\(text)")
            #expect(!text.contains("retry"))
            #expect(!text.contains("safe"))
        }
    }

    @Test("the first launch marks every joined conversation that has a summary, once")
    func launchMarksJoinedConversationsOnce() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pair = try Self.makeLinkedPair(root: root)
        // Written after the last part finished, which a date comparison missed.
        try pair.stores[0].writeSummary("First part only.")
        let backend = FakeAIBackend()
        let pipeline = Self.makePipeline(repository: pair.repository, backend: backend)

        await pipeline.payLaunchSummaryRewrites()

        #expect(backend.enrichmentRequests.count == 1, "written again from both parts")
        #expect(try pair.stores[0].readMetadata().summaryNeedsRewrite == nil)

        // Not a second time on a later launch: the conversation says its summary
        // covers its parts, and no file in the archive root is needed to know.
        #expect(try pair.stores[0].readMetadata().summaryCoversParts == true)
        try pair.stores[0].writeSummary("Edited since.")
        await pipeline.payLaunchSummaryRewrites()
        #expect(backend.enrichmentRequests.count == 1)
        let hidden = try FileManager.default.contentsOfDirectory(
            at: pair.repository.archive.root, includingPropertiesForKeys: nil, options: [])
        #expect(!hidden.contains { $0.lastPathComponent.hasPrefix(".summaries") })
    }

    @Test("a conversation rewritten before is not marked again when nothing else records it")
    func rewrittenConversationIsLeftAlone() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pair = try Self.makeLinkedPair(root: root)
        try pair.stores[0].writeSummary("Both parts.")
        _ = try pair.stores[0].updateMetadata { $0.summaryCoversParts = true }
        let backend = FakeAIBackend()

        await Self.makePipeline(repository: pair.repository, backend: backend)
            .payLaunchSummaryRewrites()

        #expect(backend.enrichmentRequests.isEmpty)
    }

    @Test("a link made during the button's request keeps the debt after the request is answered")
    func linkDuringWriteASummaryKeepsTheDebt() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pair = try Self.makeLinkedPair(root: root)
        _ = try pair.stores[0].updateMetadata { $0.summaryNeedsRewrite = true }
        let backend = FakeAIBackend()
        let started = Mutex(false)
        let open = Mutex(false)
        let pipeline = Self.makePipeline(
            repository: pair.repository, backend: backend,
            onSummaryRewriting: { _, running in if running { started.withLock { $0 = true } } })
        let id = pair.ids[0]
        let calls = Mutex(0)
        backend.enrichInterference = {
            let call = calls.withLock {
                $0 += 1
                return $0
            }
            if call == 1 {
                // A link arrives; its payer takes the debt off the list and waits
                // for the job slot this request holds.
                Task { await pipeline.refreshConversationSummary(meetingID: id) }
                while !started.withLock({ $0 }) { try? await Task.sleep(nanoseconds: 2_000_000) }
            } else {
                while !open.withLock({ $0 }) { try? await Task.sleep(nanoseconds: 2_000_000) }
            }
        }

        try await pipeline.generateEnrichment(meetingID: id)

        // The payer's request has not been answered, so the debt is still on disk.
        #expect(try pair.stores[0].readMetadata().summaryNeedsRewrite == true)
        open.withLock { $0 = true }
        var flag = try pair.stores[0].readMetadata().summaryNeedsRewrite
        while backend.enrichmentRequests.count < 2 || flag == true {
            try await Task.sleep(nanoseconds: 5_000_000)
            flag = try pair.stores[0].readMetadata().summaryNeedsRewrite
        }
        #expect(try pair.stores[0].readMetadata().summaryNeedsRewrite == nil)
    }

    @Test("a recording linked and rewritten for while its own request is in flight is asked about twice")
    func linkDuringOwnEnrichmentIsPaidAfterwards() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let earlier = try PipelineFixtures.makeRecordedMeeting(root: root, seconds: 6)
        let later = try PipelineFixtures.makeRecordedMeeting(root: root, seconds: 6)
        let backend = FakeAIBackend()
        let pipeline = Self.makeLocalPipeline(repository: earlier.repository, backend: backend, root: root)
        await pipeline.process(meetingID: later.metadata.id)
        #expect(backend.enrichmentRequests.count == 1)

        let calls = Mutex(0)
        let flagAtRewrite = Mutex<Bool?>(nil)
        let earlierStore = earlier.store
        let earlierID = earlier.metadata.id
        let laterStore = later.store
        let laterID = later.metadata.id
        backend.enrichInterference = {
            let call = calls.withLock {
                $0 += 1
                return $0
            }
            if call == 1 {
                // The finished second recording is linked under the first while
                // the first is being summarized, and a rewrite is asked for.
                _ = try? earlierStore.updateMetadata { $0.absorbedMeetingIDs = [laterID] }
                _ = try? laterStore.updateMetadata { $0.mergedIntoMeetingID = earlierID }
                await pipeline.refreshConversationSummary(meetingID: earlierID)
            } else {
                flagAtRewrite.withLock { $0 = (try? earlierStore.readMetadata())?.summaryNeedsRewrite }
            }
        }

        await pipeline.process(meetingID: earlier.metadata.id)

        #expect(backend.enrichmentRequests.count == 3, "its own, then the rewrite")
        let last = try #require(backend.enrichmentRequests.last)
        #expect(Self.occurrences(of: "we ship friday", in: last.transcript) == 4, "both recordings")
        #expect(flagAtRewrite.withLock { $0 } == true, "owed until the rewrite is answered")
        #expect(try earlier.store.readMetadata().summaryNeedsRewrite == nil)
    }

    @Test("a rewrite that fails at launch posts nothing, and a manual one reports without Retry")
    func failureAnnouncements() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pair = try Self.makeLinkedPair(root: root)
        try pair.stores[0].writeSummary("First part only.")
        let backend = FakeAIBackend()
        backend.failEnrichment = .transport(reason: "offline")
        let retryable = Failures()
        let reported = Failures()
        let pipeline = Self.makePipeline(
            repository: pair.repository, backend: backend, failures: retryable,
            summaryFailures: reported)

        await pipeline.payLaunchSummaryRewrites()
        #expect(backend.enrichmentRequests.count == 1)
        #expect(reported.all.isEmpty, "nobody asked for the launch rewrite")

        await pipeline.refreshConversationSummary(meetingID: pair.ids[0])
        #expect(reported.all == [pair.ids[0]])
        #expect(retryable.all.isEmpty, "Retry would run no rewrite on a finished meeting")
    }

    @Test("a rewrite copies the summary it replaces, hand edits included")
    func rewriteBacksUpTheOldSummary() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pair = try Self.makeLinkedPair(root: root)
        try pair.stores[0].writeSummary("Edited by hand.")
        let backups = root.appendingPathComponent("Backups")
        let pipeline = Self.makePipeline(
            repository: pair.repository, backend: FakeAIBackend(), summaryBackups: backups)

        await pipeline.refreshConversationSummary(meetingID: pair.ids[0])

        let dated = try FileManager.default.contentsOfDirectory(
            at: backups.appendingPathComponent(pair.ids[0]), includingPropertiesForKeys: nil)
        let copy = try #require(dated.first).appendingPathComponent("summary.md")
        #expect(try String(contentsOf: copy, encoding: .utf8).contains("Edited by hand."))
        #expect(pair.stores[0].readSummaryDocument().summary == "Discussed retrieval.")
    }

    @Test("the button path keeps the debt when a newer one is pending")
    func generateEnrichmentKeepsANewerDebt() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        // A part still processing, so the debt stays owed while the button runs.
        let pair = try Self.makeLinkedPair(root: root, secondState: .transcribing)
        _ = try pair.stores[0].updateMetadata { $0.summaryNeedsRewrite = true }
        let backend = FakeAIBackend()
        let pipeline = Self.makePipeline(repository: pair.repository, backend: backend)
        let id = pair.ids[0]
        backend.enrichInterference = {
            await pipeline.refreshConversationSummary(meetingID: id)
        }

        try await pipeline.generateEnrichment(meetingID: id)

        #expect(try pair.stores[0].readMetadata().summaryNeedsRewrite == true)
    }

    @Test("a first recording that summarizes the whole conversation pays the debt it owed")
    func ownEnrichmentPaysTheDebt() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let earlier = try PipelineFixtures.makeRecordedMeeting(root: root, seconds: 6)
        let later = try PipelineFixtures.makeRecordedMeeting(root: root, seconds: 6)
        let backend = FakeAIBackend()
        let pipeline = Self.makeLocalPipeline(repository: earlier.repository, backend: backend, root: root)
        // Linked before either was processed. The second finishes first and
        // owes the conversation a rewrite that cannot run yet.
        _ = try earlier.store.updateMetadata { $0.absorbedMeetingIDs = [later.metadata.id] }
        _ = try later.store.updateMetadata { $0.mergedIntoMeetingID = earlier.metadata.id }
        await pipeline.process(meetingID: later.metadata.id)
        #expect(try earlier.store.readMetadata().summaryNeedsRewrite == true)
        #expect(backend.enrichmentRequests.isEmpty)

        await pipeline.process(meetingID: earlier.metadata.id)

        #expect(backend.enrichmentRequests.count == 1, "one request covers both recordings")
        #expect(try earlier.store.readMetadata().summaryNeedsRewrite == nil)
    }
}
