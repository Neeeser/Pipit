import AppKit
import Foundation
import PipitCore
import PipitServices
import PipitUI
import SwiftUI
import Testing

// The meetings window, and the date an imported recording is filed under.
//
// Both exist because the archive is only navigable if the two things it is
// ordered by are right: when a meeting happened, and who was in it.

private func date(_ text: String) -> Date {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    guard let date = formatter.date(from: text) else {
        preconditionFailure("test date \(text) does not parse")
    }
    return date
}

private func row(
    _ id: String,
    title: String,
    at started: Date,
    state: ProcessingState = .complete,
    speakers: [(String?, Int64?)] = [],
    notes: String = "",
    source: MeetingSource = .googleMeet,
    interrupted: Bool = false,
    archived: Bool = false
) -> MeetingRow {
    MeetingRow(
        summary: MeetingSummary(
            id: id,
            directory: URL(fileURLWithPath: "/tmp/\(id)"),
            title: title,
            startedAt: started,
            durationSeconds: 600,
            source: source,
            provider: .unknown,
            processingState: state,
            wasInterrupted: interrupted,
            hasTranscript: state == .complete,
            recordingCount: 1,
            isArchived: archived
        ),
        speakers: speakers.enumerated().map { index, speaker in
            MeetingRowSpeaker(
                key: "speaker_\(index)",
                displayName: speaker.0,
                identityID: speaker.1.map(IdentityID.init)
            )
        },
        notes: notes
    )
}

// MARK: - the date an import is filed under

@Suite("ImportedRecordingDate")
struct ImportedRecordingDateTests {
    @Test("the file's own timestamp beats the date the copy landed on")
    func theFileSOwnTimestampBeatsTheDateTheCopyLandedOn() async throws {
        let now = date("2026-08-24 15:00:00")
        let chosen = RecordedDatePolicy.choose(
            metadata: date("2026-07-02 09:30:00"),
            filename: date("2026-08-01 12:00:00"),
            fileCreated: now,
            now: now
        )
        #expect(chosen.source == .fileMetadata)
        #expect(chosen.date == date("2026-07-02 09:30:00"))
    }

    @Test("a filename timestamp beats the copy's creation date")
    func aFilenameTimestampBeatsTheCopySCreationDate() async throws {
        // The case this exists for: a voice memo dragged off a phone
        // keeps its name and loses its creation date.
        let now = date("2026-08-24 15:00:00")
        let chosen = RecordedDatePolicy.choose(
            metadata: nil,
            filename: date("2026-08-15 09:12:33"),
            fileCreated: now,
            now: now
        )
        #expect(chosen.source == .filename)
        #expect(chosen.date == date("2026-08-15 09:12:33"))
    }

    @Test("an implausible timestamp is skipped rather than believed")
    func anImplausibleTimestampIsSkippedRatherThanBelieved() async throws {
        let now = date("2026-08-24 15:00:00")
        let epoch = RecordedDatePolicy.choose(
            metadata: Date(timeIntervalSince1970: 0),
            filename: nil,
            fileCreated: date("2026-08-20 08:00:00"),
            now: now
        )
        #expect(epoch.source == .fileCreated, "1970 is a container default, not a date")

        let ahead = RecordedDatePolicy.choose(
            metadata: date("2031-01-01 00:00:00"),
            filename: nil,
            fileCreated: date("2026-08-20 08:00:00"),
            now: now
        )
        #expect(ahead.source == .fileCreated, "five years ahead is a broken clock")

        let nothing = RecordedDatePolicy.choose(
            metadata: nil, filename: nil, fileCreated: nil, now: now
        )
        #expect(nothing.source == .importTime)
        #expect(nothing.date == now)
    }

    @Test("a clock an hour ahead is still a real recording")
    func aClockAnHourAheadIsStillARealRecording() async throws {
        let now = date("2026-08-24 15:00:00")
        let chosen = RecordedDatePolicy.choose(
            metadata: date("2026-08-24 16:00:00"),
            filename: nil, fileCreated: nil, now: now
        )
        #expect(chosen.source == .fileMetadata)
    }

    @Test("the shapes recorders actually write are read out of a filename")
    func theShapesRecordersActuallyWriteAreReadOutOfAFilename() async throws {
        let calendar = RuntimeFixtures.calendar
        func parsed(_ name: String) -> Date? {
            RecordedDatePolicy.dateInFilename(name, calendar: calendar)
        }
        #expect(
            parsed("New Recording 2026-08-15 09.12.33.m4a") == date("2026-08-15 09:12:33"),
            "Apple Voice Memos"
        )
        #expect(
            parsed("20260815_091233.mp3") == date("2026-08-15 09:12:33"),
            "Android recorders and Zoom"
        )
        #expect(
            parsed("meeting-2026-08-15T09-12-33.wav") == date("2026-08-15 09:12:33"),
            "an ISO-ish name with a filesystem-safe time"
        )
        #expect(
            parsed("standup 2026-08-15.m4a") == date("2026-08-15 12:00:00"),
            "a name with no time lands at midday, so the day survives a zone change"
        )
    }

    @Test("a run of digits that is not a date is left alone")
    func aRunOfDigitsThatIsNotADateIsLeftAlone() async throws {
        let calendar = RuntimeFixtures.calendar
        #expect(
            RecordedDatePolicy.dateInFilename("recording 1234567890.m4a", calendar: calendar) == nil,
            "a unix timestamp is not the year 1234"
        )
        #expect(RecordedDatePolicy.dateInFilename("track 03.mp3", calendar: calendar) == nil)
        #expect(
            RecordedDatePolicy.dateInFilename("2026-13-45.m4a", calendar: calendar) == nil,
            "month 13 and day 45 are not a date"
        )
        #expect(RecordedDatePolicy.dateInFilename("call.m4a", calendar: calendar) == nil)
        #expect(
            RecordedDatePolicy.dateInFilename(
                "REC 12345678 2026-08-15.m4a", calendar: calendar
            ) == date("2026-08-15 12:00:00"),
            "a serial number in front of the date does not hide it"
        )
        #expect(
            RecordedDatePolicy.dateInFilename(
                "standup 2026-08-15 47-12.m4a", calendar: calendar
            ) == date("2026-08-15 12:00:00"),
            "a duration where a time would sit does not take the date with it"
        )
    }

    @Test("a metadata string is read, and a bare year is refused")
    func aMetadataStringIsReadAndABareYearIsRefused() async throws {
        #expect(
            RecordedDatePolicy.parseMetadataDate("2026-08-15T09:12:33Z") == date("2026-08-15 09:12:33"),
            "the QuickTime shape"
        )
        #expect(
            RecordedDatePolicy.parseMetadataDate("2026-08-15T09:12:33.500Z") == Date(timeIntervalSince1970: date("2026-08-15 09:12:33").timeIntervalSince1970 + 0.5),
            "fractional seconds"
        )
        #expect(
            RecordedDatePolicy.parseMetadataDate("2026") == nil,
            "a year alone would put the meeting on the first of January"
        )
        #expect(RecordedDatePolicy.parseMetadataDate("") == nil)
    }
}

@Suite("MeetingSource")
struct MeetingSourceTests {
    /// The shape of every application icon this has to key: a coloured plate
    /// with a mark sitting on it, and nothing in the corners.
    @MainActor private static func plateAndMark() -> NSImage {
        let icon = NSImage(size: NSSize(width: 64, height: 64))
        icon.lockFocus()
        NSColor.white.setFill()
        NSBezierPath(
            roundedRect: NSRect(x: 4, y: 4, width: 56, height: 56), xRadius: 12, yRadius: 12
        ).fill()
        NSColor.red.setFill()
        NSBezierPath(ovalIn: NSRect(x: 22, y: 22, width: 20, height: 20)).fill()
        icon.unlockFocus()
        return icon
    }

    /// The image drawn scaled onto a ground, which is what a row does with it.
    @MainActor private static func over(_ image: NSImage, _ ground: NSColor) -> NSBitmapImageRep {
        let side = 152
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        ground.setFill()
        NSRect(x: 0, y: 0, width: side, height: side).fill()
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    private static func colour(
        _ rep: NSBitmapImageRep, _ fx: Double, _ fy: Double
    ) -> (red: Double, green: Double, blue: Double) {
        let x = Int(fx * Double(rep.pixelsWide - 1))
        let y = Int(fy * Double(rep.pixelsHigh - 1))
        guard let colour = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
            return (-1, -1, -1)
        }
        return (Double(colour.redComponent), Double(colour.greenComponent),
                Double(colour.blueComponent))
    }

    @Test("a source filter holds one kind of recording")
    func aSourceFilterHoldsOneKindOfRecording() async throws {
        let now = date("2026-08-24 15:00:00")
        let rows = [
            row("a", title: "Bryn Callister", at: now, source: .slackHuddle),
            row("b", title: "Northwind Daily", at: now, source: .googleMeet),
            row("c", title: "Acme onboarding", at: now, source: .zoom),
        ]
        let visible = MeetingsDirectoryFilter.sections(
            rows, source: .slackHuddle, now: now, calendar: RuntimeFixtures.calendar
        ).flatMap(\.rows)
        #expect(visible.map(\.id) == ["a"])
    }

    @Test("a query narrows within the source that is held")
    func aQueryNarrowsWithinTheSourceThatIsHeld() async throws {
        let now = date("2026-08-24 15:00:00")
        let rows = [
            row("a", title: "Release cut", at: now, source: .slackHuddle),
            row("b", title: "Release cut", at: now, source: .googleMeet),
            row("c", title: "Bryn Callister", at: now, source: .slackHuddle),
        ]
        let visible = MeetingsDirectoryFilter.sections(
            rows, source: .slackHuddle, query: "release", now: now,
            calendar: RuntimeFixtures.calendar
        ).flatMap(\.rows)
        #expect(visible.map(\.id) == ["a"])
    }

    @Test("the source filter composes with the filter above it")
    func theSourceFilterComposesWithTheFilterAboveIt() async throws {
        // Source says where a meeting came from, and the segmented
        // filter says what it needs. Holding one must not lose the
        // other.
        let now = date("2026-08-24 15:00:00")
        let rows = [
            row("a", title: "Named", at: now, speakers: [("Marlow", 1)], source: .slackHuddle),
            row("b", title: "One left", at: now, speakers: [(nil, nil)], source: .slackHuddle),
            row("c", title: "One left", at: now, speakers: [(nil, nil)], source: .zoom),
        ]
        let visible = MeetingsDirectoryFilter.sections(
            rows, filter: .unnamed, source: .slackHuddle, now: now,
            calendar: RuntimeFixtures.calendar
        ).flatMap(\.rows)
        #expect(visible.map(\.id) == ["b"])
    }

    @Test("typing the start of a source name offers it as a filter")
    func typingTheStartOfASourceNameOffersItAsAFilter() async throws {
        #expect(MeetingsDirectoryFilter.suggestedSource(for: "slack") == .slackHuddle)
        #expect(MeetingsDirectoryFilter.suggestedSource(for: "ZO") == .zoom)
        #expect(MeetingsDirectoryFilter.suggestedSource(for: "  face ") == .faceTime)
        #expect(
            MeetingsDirectoryFilter.suggestedSource(for: "huddle") == .slackHuddle,
            "a word inside the name counts, because that is what people call it"
        )
    }

    @Test("nothing is offered over a list of folders")
    func nothingIsOfferedOverAListOfFolders() async throws {
        // The query means folder names there, and taking an offer
        // would throw those words away to hold a filter that narrows
        // no folder.
        #expect(
            MeetingsDirectoryFilter.offeredSource(
                for: "im", held: nil, counts: [.imported: 4], listingFolders: true
            ) == nil
        )
    }

    @Test("nothing is offered for a source the archive has none of")
    func nothingIsOfferedForASourceTheArchiveHasNoneOf() async throws {
        // The menu leaves an empty source out. The offer has to agree,
        // or Return empties the list and says "No Zoom meetings".
        #expect(
            MeetingsDirectoryFilter.offeredSource(
                for: "zo", held: nil, counts: [.manual: 3], listingFolders: false
            ) == nil
        )
    }

    @Test("nothing is offered while a source is already held")
    func nothingIsOfferedWhileASourceIsAlreadyHeld() async throws {
        #expect(
            MeetingsDirectoryFilter.offeredSource(
                for: "slack", held: .zoom, counts: [.slackHuddle: 2], listingFolders: false
            ) == nil
        )
    }

    @Test("the offer is the source the words name")
    func theOfferIsTheSourceTheWordsName() async throws {
        #expect(
            MeetingsDirectoryFilter.offeredSource(
                for: "slack", held: nil, counts: [.slackHuddle: 2], listingFolders: false
            ) == .slackHuddle
        )
    }

    @Test("a whole name beats a word inside another name")
    func aWholeNameBeatsAWordInsideAnotherName() async throws {
        // "m" starts "Manual recording" and also starts the word "Meet".
        // Without a rule the offer flickers between them.
        #expect(MeetingsDirectoryFilter.suggestedSource(for: "m") == .manual)
        #expect(MeetingsDirectoryFilter.suggestedSource(for: "me") == .googleMeet)
    }

    @Test("a query no source is called offers nothing")
    func aQueryNoSourceIsCalledOffersNothing() async throws {
        #expect(MeetingsDirectoryFilter.suggestedSource(for: "northwind") == nil)
        #expect(MeetingsDirectoryFilter.suggestedSource(for: "") == nil)
        #expect(MeetingsDirectoryFilter.suggestedSource(for: "   ") == nil)
    }

    @Test("the menu counts what each source holds")
    func theMenuCountsWhatEachSourceHolds() async throws {
        let now = date("2026-08-24 15:00:00")
        let rows = [
            row("a", title: "One", at: now, source: .slackHuddle),
            row("b", title: "Two", at: now, source: .slackHuddle),
            row("c", title: "Three", at: now, source: .googleMeet),
        ]
        let counts = MeetingsDirectoryFilter.sourceCounts(rows)
        #expect(counts[.slackHuddle] == 2)
        #expect(counts[.googleMeet] == 1)
        #expect(counts[.zoom] == nil, "a source with nothing in it is left out")
    }

    @Test("every source has a name short enough for the row")
    func everySourceHasANameShortEnoughForTheRow() async throws {
        // The row spends a 272 point sidebar on the source, the date,
        // the duration and sometimes a state. "Imported recording ·
        // Aug 30, 11:20 AM · 1h 12m" ran off the end, so the budget is
        // what this holds to rather than the three values that changed.
        for source in MeetingSource.allCases {
            #expect(!source.listName.isEmpty, "\(source) has no name")
            #expect(
                source.listName.count <= 12,
                "\(source) says \"\(source.listName)\", which is \(source.listName.count) characters"
            )
        }
    }

    @Test("search and the offer both know the short name")
    func searchAndTheOfferBothKnowTheShortName() async throws {
        let now = date("2026-08-24 15:00:00")
        let rows = [row("a", title: "Standup", at: now, source: .inPerson)]
        let visible = MeetingsDirectoryFilter.sections(
            rows, query: "in person", now: now, calendar: RuntimeFixtures.calendar
        ).flatMap(\.rows)
        #expect(visible.map(\.id) == ["a"], "the row reads \"In person\"")
        #expect(MeetingsDirectoryFilter.suggestedSource(for: "in person") == .inPerson)
    }

    @Test("only Slack is drawn from an installed application")
    func onlySlackIsDrawnFromAnInstalledApplication() async throws {
        // FaceTime's mark is a plain video camera once its plate comes
        // off, which is the glyph already. Zoom is not worth a mark
        // that shows up only on the Macs that have Zoom installed.
        #expect(SourceMark.bundleIdentifier(for: .slackHuddle) == "com.tinyspeck.slackmacgap")
        for source in MeetingSource.allCases where source != .slackHuddle {
            #expect(SourceMark.bundleIdentifier(for: source) == nil, "\(source) draws its glyph")
        }
    }

    @Test("a source with no application of its own draws its glyph")
    func aSourceWithNoApplicationOfItsOwnDrawsItsGlyph() async throws {
        await MainActor.run {
            for source in MeetingSource.allCases where source != .slackHuddle {
                #expect(SourceMark.icon(for: source) == nil, "\(source) has no icon to read")
            }
        }
    }

    @Test("an application icon keeps its mark and loses its plate")
    func anApplicationIconKeepsItsMarkAndLosesItsPlate() async throws {
        await MainActor.run {
            guard let keyed = SourceMark.plateRemoved(Self.plateAndMark()) else {
                Issue.record("the icon came back with nothing in it")
                return
            }
            // Composited over a known ground rather than read for its
            // alpha. The buffer is premultiplied, so clearing alpha and
            // leaving the colour behind draws the plate back at full
            // strength while every alpha reads zero.
            let drawn = Self.over(keyed, NSColor(calibratedRed: 0, green: 0, blue: 1, alpha: 1))
            let plate = Self.colour(drawn, 0.5, 0.12)
            #expect(
                plate.blue > 0.9 && plate.red < 0.1,
                "the plate is gone, so the ground shows through: \(plate)"
            )
            let mark = Self.colour(drawn, 0.5, 0.5)
            #expect(mark.red > 0.7 && mark.blue < 0.3, "the mark stays: \(mark)")
        }
    }

    @Test("an icon that is all plate keeps nothing and draws its glyph")
    func anIconThatIsAllPlateKeepsNothingAndDrawsItsGlyph() async throws {
        await MainActor.run {
            let plain = NSImage(size: NSSize(width: 64, height: 64))
            plain.lockFocus()
            NSColor.white.setFill()
            NSBezierPath(
                roundedRect: NSRect(x: 4, y: 4, width: 56, height: 56),
                xRadius: 12, yRadius: 12
            ).fill()
            plain.unlockFocus()
            #expect(
                SourceMark.plateRemoved(plain) == nil,
                "an empty mark is worse than the glyph it replaced"
            )
        }
    }

    @Test("backspace drops the held source only when nothing is typed")
    func backspaceDropsTheHeldSourceOnlyWhenNothingIsTyped() async throws {
        // Measured: `onKeyPress(.delete)` never fires for the Delete
        // key here, while the general form receives it as "\u{7F}".
        // The rule is matched on the characters for that reason.
        func drops(_ characters: String, _ query: String, _ held: Bool) -> Bool {
            SearchFieldKey.dropsHeldSource(
                characters: characters, query: query, hasSource: held
            )
        }
        #expect(drops("\u{7F}", "", true))
        #expect(!drops("\u{7F}", "rel", true), "with words typed, backspace edits the words")
        #expect(!drops("\u{7F}", "", false), "and there is nothing to drop")
        #expect(!drops("a", "", true), "another key types")
    }

    @Test("no two sources share a glyph")
    func noTwoSourcesShareAGlyph() async throws {
        // Five of the eight drew the same camera, which is the gap the
        // badge exists to close.
        let symbols = MeetingSource.allCases.map(\.symbolName)
        #expect(Set(symbols).count == MeetingSource.allCases.count)
    }

    @Test("no two sources share a tint")
    func noTwoSourcesShareATint() async throws {
        let tints = MeetingSource.allCases.map(SourceTint.color)
        #expect(Set(tints).count == MeetingSource.allCases.count)
    }
}

@Suite("MeetingsDirectory")
struct MeetingsDirectoryTests {
    @Test("meetings are grouped by when, newest first")
    func meetingsAreGroupedByWhenNewestFirst() async throws {
        let now = date("2026-08-24 15:00:00")
        let calendar = RuntimeFixtures.calendar
        let rows = [
            row("a", title: "Design review", at: date("2026-08-24 14:15:00")),
            row("b", title: "Standup", at: date("2026-08-23 09:32:00")),
            row("c", title: "Weekly sync", at: date("2026-08-19 10:00:00")),
            row("d", title: "July retro", at: date("2026-07-31 16:00:00")),
        ]
        let sections = MeetingsDirectoryFilter.sections(
            rows, now: now, calendar: calendar
        )
        #expect(
            sections.map(\.title) == ["Today", "Yesterday", "Earlier this month",
             MeetingsDirectoryFilter.sectionTitle(
                 for: date("2026-07-31 16:00:00"), now: now, calendar: calendar)]
        )
        #expect(sections.first?.rows.map(\.id) == ["a"])
        #expect(sections.last?.rows.map(\.id) == ["d"])
    }

    @Test("a date ahead of now files under today rather than opening a section above it")
    func aDateAheadOfNowFilesUnderTodayRatherThanOpeningASectionAbove() async throws {
        // An imported file whose device clock ran ahead. The date is
        // kept. The heading is not invented.
        let now = date("2026-08-24 15:00:00")
        let rows = [row("a", title: "Voice memo", at: date("2026-08-24 23:30:00"))]
        let sections = MeetingsDirectoryFilter.sections(
            rows, now: now, calendar: RuntimeFixtures.calendar
        )
        #expect(sections.map(\.title) == ["Today"])
    }

    @Test("the unnamed filter is the list of meetings still asking for a name")
    func theUnnamedFilterIsTheListOfMeetingsStillAskingForAName() async throws {
        let now = date("2026-08-24 15:00:00")
        let rows = [
            row("a", title: "Named throughout", at: now,
                speakers: [("Marlow", 1), ("Bryn", 2)]),
            row("b", title: "One voice left", at: now,
                speakers: [("Marlow", 1), (nil, nil)]),
            row("c", title: "Nobody named", at: now, speakers: [(nil, nil), (nil, nil)]),
        ]
        let visible = MeetingsDirectoryFilter.sections(
            rows, filter: .unnamed, now: now, calendar: RuntimeFixtures.calendar
        ).flatMap(\.rows)
        #expect(visible.map(\.id) == ["b", "c"])
        #expect(visible.map(\.unnamedCount) == [1, 2])
    }

    @Test("needs attention holds a failure and a recording that stopped short")
    func needsAttentionHoldsAFailureAndARecordingThatStoppedShort() async throws {
        // A call that dropped and was rejoined is interrupted forever,
        // and once it has processed there is nothing to act on. Listing
        // it made the filter a drawer nothing ever leaves.
        let now = date("2026-08-24 15:00:00")
        let rows = [
            row("a", title: "Fine", at: now),
            row("b", title: "Failed", at: now, state: .failed),
            row("c", title: "Cut short and unfinished", at: now,
                state: .transcribing, interrupted: true),
            row("d", title: "Rejoined and processed", at: now, interrupted: true),
            row("e", title: "Still working", at: now, state: .transcribing),
        ]
        let visible = MeetingsDirectoryFilter.sections(
            rows, filter: .needsAttention, now: now, calendar: RuntimeFixtures.calendar
        ).flatMap(\.rows)
        #expect(Set(visible.map(\.id)) == ["b", "c"])
    }

    @Test("an archived meeting is in the archived list and no other")
    func anArchivedMeetingIsInTheArchivedListAndNoOther() async throws {
        // Archiving is how a recording is put down. Leaving it under
        // All would make it a badge, and leaving a failed one under
        // Attention would keep work in front of the user that they
        // have already dismissed.
        let now = date("2026-08-24 15:00:00")
        let rows = [
            row("a", title: "Kept", at: now, speakers: [(nil, nil)]),
            row("b", title: "Put down", at: now, state: .failed,
                speakers: [(nil, nil)], archived: true),
        ]
        func visible(_ filter: MeetingsFilter) -> [String] {
            MeetingsDirectoryFilter.sections(
                rows, filter: filter, now: now, calendar: RuntimeFixtures.calendar
            ).flatMap(\.rows).map(\.id)
        }
        #expect(visible(.all) == ["a"])
        #expect(visible(.unnamed) == ["a"], "and it is not work waiting to be done")
        #expect(visible(.needsAttention) == [], "nor a failure still asking for a look")
        #expect(visible(.archived) == ["b"])
    }

    @Test("grouping a year of meetings costs about what grouping one month costs")
    func groupingAYearOfMeetingsCostsAboutWhatGroupingOneMonthCosts() async throws {
        // A month heading is formatted, and a `DateFormatter` built per
        // row cost about 0.13 ms of the main actor each. Search regroups
        // the whole archive on every keystroke, so 500 meetings spread
        // over two years spent 69 ms per keystroke building 500
        // formatters, against 4 ms for the same rows inside one month.
        // Measured against those same-month rows, which take every step
        // of this path except the formatter, so the answer does not
        // depend on how fast the machine is.
        let now = date("2026-08-24 15:00:00")
        func rows(spacing: TimeInterval) -> [MeetingRow] {
            (0..<400).map { index in
                row(
                    "m\(index)", title: "Meeting \(index)",
                    at: now.addingTimeInterval(-Double(index) * spacing)
                )
            }
        }
        func elapsed(_ rows: [MeetingRow]) -> Double {
            let started = Date()
            for _ in 0..<5 {
                _ = MeetingsDirectoryFilter.sections(
                    rows, now: now, calendar: RuntimeFixtures.calendar
                )
            }
            return Date().timeIntervalSince(started)
        }
        _ = elapsed(rows(spacing: 86_400))
        let oneMonth = elapsed(rows(spacing: 3_600))
        let twoYears = elapsed(rows(spacing: 86_400))
        #expect(
            twoYears < oneMonth * 4,
            """
            one formatter per grouping, not per row: \(Int(twoYears * 1_000)) ms \
            against \(Int(oneMonth * 1_000)) ms
            """
        )
    }

    @Test("search covers the title, the notes, the speakers and the transcript")
    func searchCoversTheTitleTheNotesTheSpeakersAndTheTranscript() async throws {
        let now = date("2026-08-24 15:00:00")
        let rows = [
            row("a", title: "Design review", at: now, speakers: [("Nadia Quist", 3)]),
            row("b", title: "Standup", at: now, notes: "Northwind renewal decided"),
            row("c", title: "Weekly sync", at: now),
        ]
        func found(_ query: String, transcripts: [String: String] = [:]) -> [String] {
            MeetingsDirectoryFilter.sections(
                rows, query: query, transcripts: transcripts, now: now,
                calendar: RuntimeFixtures.calendar
            ).flatMap(\.rows).map(\.id)
        }
        #expect(found("design") == ["a"], "the title")
        #expect(found("nadia") == ["a"], "a speaker's name")
        #expect(found("northwind") == ["b"], "the user's own notes")
        #expect(found("alignment") == [], "and nothing else, until the index exists")
        #expect(
            found("alignment", transcripts: ["c": "so the alignment fix landed"]) == ["c"],
            "the words, once the transcripts have been read"
        )
    }
}

@Suite("MeetingsWindow")
struct MeetingsWindowTests {
    /// Waits for work the window model started in the background, for up to ten
    /// seconds. A test that fails says more than one that hangs.
    ///
    /// A passing wait ends as soon as the condition holds, so the budget only
    /// costs time on a real failure. One second was not enough on a loaded CI
    /// runner, where a save and the list reload behind it took longer than that
    /// and the title test failed on three runs out of four.
    @MainActor
    private static func waitFor(_ what: String, until condition: () -> Bool) async {
        for _ in 0..<2_000 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("timed out waiting for \(what)")
    }

    /// A conversation recorded in two halves, each with its own transcript and
    /// its own speaker map, linked as one meeting.
    private static func makeRejoinedCall(root: URL) throws -> (MeetingRepository, String) {
        let repository = MeetingRepository(root: root.appendingPathComponent("Meetings"))
        let started = Date(timeIntervalSince1970: 1_787_070_000)
        let first = try repository.createMeeting(
            source: .googleMeet, provider: .googleMeet, startedAt: started,
            titles: TitleCandidates(provider: "Weekly sync", timestampFallback: "f"), now: started
        )
        let second = try repository.createMeeting(
            source: .googleMeet, provider: .googleMeet,
            startedAt: started.addingTimeInterval(900),
            titles: TitleCandidates(provider: "Weekly sync", timestampFallback: "f"),
            now: started.addingTimeInterval(900)
        )
        for (store, text, at) in [
            (first.store, "before the drop", started),
            (second.store, "after the rejoin", started.addingTimeInterval(900)),
        ] {
            _ = try store.updateMetadata {
                $0.durationSeconds = 600
                $0.processing = ProcessingStatus(state: .complete, updatedAt: at)
            }
            try store.writeCanonicalTranscript(CanonicalTranscript(
                generatedAt: at,
                utterances: [
                    Utterance(
                        id: "\(text)-1", start: 0, end: 30, track: .remote, rawSpeakerLabel: nil,
                        speakerKey: "remote-001_speaker_00", text: text, chunkID: "c", model: "m"
                    ),
                ]
            ))
        }
        // Both halves number their speakers from zero, and only the first has a
        // name for its own.
        var firstMap = SpeakerMap()
        firstMap.assign("Bryn Halloway", to: "remote-001_speaker_00", identityID: IdentityID(2))
        try first.store.writeSpeakerMap(firstMap)

        _ = try second.store.updateMetadata { $0.mergedIntoMeetingID = first.metadata.id }
        _ = try first.store.updateMetadata { $0.absorbedMeetingIDs = [second.metadata.id] }
        return (repository, first.metadata.id)
    }

    /// Accepting a proposed name has to be indistinguishable from choosing it
    /// from the chip's own menu, or the user ends up with two kinds of name and
    /// has to know which is which.
    @MainActor
    private static func acceptingASuggestionNamesLikeAPerson() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = try RuntimeFixtures.makeMeeting(root: root, clusters: ["remote-001_speaker_00"])
        try meeting.store.writeSpeakerSuggestions(SpeakerSuggestionSet(suggestions: [
            SpeakerNameSuggestion(
                label: "remote-001_speaker_00", name: "Nadia Quist", confidence: 0.91,
                quote: "Nadia, what did the renewal come back at?", atSeconds: 12
            ),
        ]))

        let runtime = RuntimeFixtures.makeRuntime(root: root)
        let model = MeetingsWindowModel(runtime: runtime)
        await model.reload()
        model.show(meetingID: meeting.id)
        await waitFor("the pill to reach the strip") {
            model.detail?.speakerSuggestions.count == 1
        }
        guard let row = model.detail?.speakerSuggestions.first else {
            Issue.record("no suggestion on the strip")
            return
        }
        #expect(row.speakerLabel == "Speaker 1", "the pill names the speaker as the chip does")

        model.acceptSuggestion(row)

        await waitFor("the name to reach the speaker map") {
            (try? meeting.store.readSpeakerMap())?.entries["remote-001_speaker_00"] != nil
        }
        let entry = try #require(try meeting.store.readSpeakerMap().entries["remote-001_speaker_00"])
        #expect(entry.displayName == "Nadia Quist")
        // Not `.ai`. After a person agrees to it, it is their answer, and voice
        // learning must weigh it like any other correction.
        #expect(entry.origin == .human)

        // The speaker now has a name, so the pill goes without anything having
        // to remove it.
        await model.detail?.reloadSpeakers()
        #expect(
            model.detail?.speakerSuggestions.isEmpty ?? false,
            "the pill outlived the name it proposed"
        )
    }

    /// Turning one down has to stick across a re-run, or the same wrong name
    /// comes back every time the meeting is reprocessed.
    @MainActor
    private static func aDismissedSuggestionStaysDismissed() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = try RuntimeFixtures.makeMeeting(root: root, clusters: ["remote-001_speaker_00"])
        try meeting.store.writeSpeakerSuggestions(SpeakerSuggestionSet(suggestions: [
            SpeakerNameSuggestion(
                label: "remote-001_speaker_00", name: "Nadia Quist", confidence: 0.91,
                quote: "Nadia, what did the renewal come back at?", atSeconds: 12
            ),
        ]))

        let runtime = RuntimeFixtures.makeRuntime(root: root)
        let model = MeetingsWindowModel(runtime: runtime)
        await model.reload()
        model.show(meetingID: meeting.id)
        await waitFor("the pill to reach the strip") {
            model.detail?.speakerSuggestions.count == 1
        }
        guard let row = model.detail?.speakerSuggestions.first else {
            Issue.record("no suggestion on the strip")
            return
        }

        model.dismissSuggestion(row)
        #expect(model.detail?.speakerSuggestions.isEmpty ?? false)
        // On disk, not just on screen: the speaker still has no name, so
        // nothing else would keep the pill away on the next read.
        #expect(
            meeting.store.readSpeakerSuggestions().dismissedLabels
                .contains("remote-001_speaker_00")
        )
        await model.detail?.reloadSpeakers()
        #expect(
            model.detail?.speakerSuggestions.isEmpty ?? false,
            "a name turned down came back on the next read"
        )
        #expect((try meeting.store.readSpeakerMap().entries["remote-001_speaker_00"]) == nil)
    }

    /// A suggestion belongs to the half of a rejoined call it was made in, and
    /// that half is folded into the first one. The ordinary lookup hides a
    /// folded recording, so dismissing there wrote nothing and the pill came
    /// straight back on the next read.
    @MainActor
    private static func aDismissalOnTheSecondHalfReachesDisk() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try RuntimeFixtures.makeMeeting(
            root: root, clusters: ["remote-001_speaker_00"], title: "Design review",
            startedAt: Date(timeIntervalSince1970: 1_787_066_400)
        )
        let second = try RuntimeFixtures.makeMeeting(
            root: root, clusters: ["remote-001_speaker_00"], title: "Design review, rejoined"
        )
        // Only the second half has anything to propose, so the pill under test
        // can only have come from the folded recording.
        try second.store.writeSpeakerSuggestions(SpeakerSuggestionSet(suggestions: [
            SpeakerNameSuggestion(
                label: "remote-001_speaker_00", name: "Nadia Quist", confidence: 0.91,
                quote: "Nadia, what did the renewal come back at?", atSeconds: 12
            ),
        ]))

        let runtime = RuntimeFixtures.makeRuntime(root: root)
        runtime.combine(meetingID: second.id, into: first.id, reason: "a test")
        let model = MeetingsWindowModel(runtime: runtime)
        await model.reload()
        model.show(meetingID: first.id)
        await waitFor("the pill from the second half to reach the strip") {
            model.detail?.speakerSuggestions.count == 1
        }
        guard let row = model.detail?.speakerSuggestions.first else {
            Issue.record("no suggestion on the strip")
            return
        }
        #expect(row.recordingID == second.id, "the pill belongs to the folded half")

        model.dismissSuggestion(row)

        #expect(
            second.store.readSpeakerSuggestions().dismissedLabels
                .contains("remote-001_speaker_00"),
            "the dismissal never reached the folded recording's own file"
        )
        await model.detail?.reloadSpeakers()
        #expect(
            model.detail?.speakerSuggestions.isEmpty ?? false,
            "the pill came back on the next read"
        )
    }

    /// Clearing a name is a person saying no to it. Nothing automatic puts one
    /// back, and a pill offering the name straight back is that same automatic
    /// naming one step further along.
    @MainActor
    private static func aClearedNameIsNotProposedAgain() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = try RuntimeFixtures.makeMeeting(root: root, clusters: ["remote-001_speaker_00"])
        try meeting.store.writeSpeakerSuggestions(SpeakerSuggestionSet(suggestions: [
            SpeakerNameSuggestion(
                label: "remote-001_speaker_00", name: "Nadia Quist", confidence: 0.91,
                quote: "Nadia, what did the renewal come back at?", atSeconds: 12
            ),
        ]))

        let runtime = RuntimeFixtures.makeRuntime(root: root)
        let model = MeetingsWindowModel(runtime: runtime)
        await model.reload()
        model.show(meetingID: meeting.id)
        await waitFor("the pill to reach the strip") {
            model.detail?.speakerSuggestions.count == 1
        }
        guard let pill = model.detail?.speakerSuggestions.first else {
            Issue.record("no suggestion on the strip")
            return
        }

        // Accept it, then think better of it and take the name off.
        model.acceptSuggestion(pill)
        await waitFor("the name to reach the speaker map") {
            (try? meeting.store.readSpeakerMap())?.entries["remote-001_speaker_00"] != nil
        }
        await model.detail?.reloadSpeakers()
        guard let chip = model.detail?.speakerRows.first(where: {
            $0.clusterID == "remote-001_speaker_00"
        }) else {
            Issue.record("the named cluster is not in the speaker strip")
            return
        }
        model.clearCluster(chip)
        await waitFor("the name to come off") {
            (try? meeting.store.readSpeakerMap())?.clearedKeys
                .contains("remote-001_speaker_00") == true
        }

        await model.detail?.reloadSpeakers()
        #expect(
            model.detail?.speakerSuggestions.isEmpty ?? false,
            "the name the user just took off was offered straight back"
        )
    }

    /// The count decides whether the AI control is drawn at all, so it has to
    /// be the same question the stage asks. Counting rows the strip merely
    /// calls unnamed drew a button for speakers the stage then refused, which
    /// made no request and never went away.
    @MainActor
    private static func theCountMatchesWhatWouldBeAsked() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = try RuntimeFixtures.makeMeeting(
            root: root,
            clusters: [
                SpeakerLabel.localUser, "remote-001_speaker_00", "remote-001_speaker_01",
            ]
        )
        let runtime = RuntimeFixtures.makeRuntime(root: root)

        // The microphone track is never sent, and neither is the bucket for
        // words no interval claimed.
        #expect(
            runtime.unnamedSpeakerCount(inMeeting: meeting.id) == 2,
            "the microphone track or the unattributed bucket was counted"
        )

        var map = try meeting.store.readSpeakerMap()
        map.assign("Nadia Quist", to: "remote-001_speaker_00")
        try meeting.store.writeSpeakerMap(map)
        #expect(runtime.unnamedSpeakerCount(inMeeting: meeting.id) == 1)

        // "Leave unnamed" on the last one. The strip still draws it as unnamed,
        // and the stage will still refuse to ask about it.
        map = try meeting.store.readSpeakerMap()
        map.assign("", to: "remote-001_speaker_01")
        #expect(map.clearedKeys.contains("remote-001_speaker_01"))
        try meeting.store.writeSpeakerMap(map)

        #expect(
            runtime.unnamedSpeakerCount(inMeeting: meeting.id) == 0,
            "a name the user cleared on purpose was counted as work to do"
        )
    }

    /// The summary and the generated notes share one file, and writing it
    /// replaces the whole document. A meeting that got notes and no summary is
    /// exactly what notes on with summaries off produces, and offering to write
    /// a summary there would throw the notes away with nothing asked.
    @MainActor
    private static func theSummaryButtonIsHiddenWhereItWouldEatNotes() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = try RuntimeFixtures.makeMeeting(root: root, clusters: ["remote-001_speaker_00"])
        try meeting.store.writeSummary(
            SummaryDocument(generatedNotes: "- Bryn sends the connector list.").markdown
        )

        let runtime = RuntimeFixtures.makeRuntime(root: root)
        let model = MeetingsWindowModel(runtime: runtime)
        await model.reload()
        model.show(meetingID: meeting.id)
        await waitFor("the pane to read the notes") {
            model.detail?.generatedNotes?.isEmpty == false
        }
        let detail = try #require(model.detail)
        #expect(detail.summary == nil, "the file holds notes, not a summary")
        #expect(
            !detail.canGenerateEnrichment,
            "the button was offered on a meeting whose notes it would replace"
        )
    }

    /// The copy button hands over the document on disk, both halves of a
    /// rejoined call in the order they were recorded.
    ///
    /// Rendering the panel's own lines instead would drop the header, the
    /// participants and the timecodes that `transcript.md` carries, and would
    /// disagree with the file the same meeting's folder holds.
    @MainActor
    private static func copyingTakesTheTranscriptFromDisk() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try RuntimeFixtures.makeMeeting(
            root: root, clusters: ["remote-001_speaker_00"], title: "Design review",
            startedAt: Date(timeIntervalSince1970: 1_787_066_400)
        )
        let second = try RuntimeFixtures.makeMeeting(
            root: root, clusters: ["remote-001_speaker_00"], title: "Design review, rejoined"
        )
        let runtime = RuntimeFixtures.makeRuntime(root: root)
        runtime.combine(meetingID: second.id, into: first.id, reason: "a test")

        let detail = MeetingReviewModel(runtime: runtime, meetingID: first.id)
        #expect(
            detail.transcriptMarkdown() == nil,
            "nothing has rendered the document yet, so there is nothing to copy"
        )

        try first.store.writeTranscriptMarkdown("# Design review\n\nNadia: the renewal.")
        try second.store.writeTranscriptMarkdown("# Design review\n\nNadia: as I was saying.")

        guard let copied = detail.transcriptMarkdown() else {
            Issue.record("the document on disk was not read")
            return
        }
        guard let firstHalf = copied.range(of: "the renewal."),
            let secondHalf = copied.range(of: "as I was saying.")
        else {
            Issue.record("both halves of the call belong in one copy: got \(copied)")
            return
        }
        #expect(firstHalf.lowerBound < secondHalf.lowerBound, "the half recorded first comes first")
    }

    // The window model and the runtime are main-actor types and neither is
    // Sendable, so a helper that holds one across an await has to be isolated
    // to that actor rather than hopping onto it for each statement.

    /// A recording that has just finished has to land on screen even while the
    /// sidebar is filtered to something it is not in. The pane is opened by
    /// identifier rather than through the list, so what the filter is showing
    /// decides nothing about what can be read.
    @MainActor
    private static func aFilteredOutMeetingStillOpens() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = MeetingRepository(root: root.appendingPathComponent("Meetings"))
        let started = Date(timeIntervalSince1970: 1_787_070_000)
        let created = try repository.createMeeting(
            source: .imported, provider: .unknown, startedAt: started,
            titles: TitleCandidates(window: "Voice memo", timestampFallback: "f"), now: started
        )

        let model = MeetingsWindowModel(runtime: RuntimeFixtures.makeRuntime(root: root))
        await model.reload()
        model.filter = .needsAttention
        #expect(model.rows.map(\.id) == [created.metadata.id], "the archive holds it")
        #expect(model.sections.flatMap(\.rows).count == 0, "and the filter is showing nothing")

        model.show(meetingID: created.metadata.id)

        #expect(model.selection == [created.metadata.id])
        #expect(model.detail?.meetingID == created.metadata.id)
        #expect(model.detail?.title == "Voice memo")
        ViewFixtures.render(
            MeetingsWindowView(model: model), size: NSSize(width: 1_120, height: 720)
        )
    }

    /// The case the Unnamed filter exists for. A cluster nobody has named has no
    /// entry in the speaker map at all, so a row built from the map alone
    /// reported nothing to do in exactly the meetings holding the most of it.
    @MainActor
    private static func unnamedVoicesReachTheList() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = try RuntimeFixtures.makeMeeting(
            root: root, clusters: ["remote-001_speaker_00", "remote-001_speaker_01", "local"]
        )
        var map = SpeakerMap()
        map.assign("Bryn Halloway", to: "remote-001_speaker_00", identityID: IdentityID(7))
        try meeting.store.writeSpeakerMap(map)
        try meeting.store.writeNotes("Northwind renewal")

        let rows = await RuntimeFixtures.makeRuntime(root: root).meetingRows()

        #expect(rows.count == 1)
        guard let row = rows.first else { return }
        #expect(row.id == meeting.id)
        #expect(row.namedSpeakers.map(\.displayName) == ["Bryn Halloway"])
        #expect(
            row.namedSpeakers.first?.identityID == IdentityID(7),
            "the identifier travels, so the colour matches the People window"
        )
        #expect(row.unnamedCount == 2, "two clusters, and no name on either")
        #expect(
            row.speakers.count == 3,
            "and the bucket for words no interval claimed is not one of them"
        )
        #expect(row.notes == "Northwind renewal", "which search reads")
        #expect(MeetingsFilter.unnamed.admits(row), "so the filter that lists the work finds it")
    }

    /// A recording that finished after the read began is not in the rows it
    /// returns. Pruning the selection to what the read saw moved the user off
    /// the meeting a notification had just opened.
    @MainActor
    private static func selectionSurvivesAReload() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try RuntimeFixtures.makeMeeting(root: root, clusters: ["local"], title: "Standup")
        let opened = try RuntimeFixtures.makeMeeting(root: root, clusters: ["local"], title: "Design review")

        let model = MeetingsWindowModel(runtime: RuntimeFixtures.makeRuntime(root: root))
        model.show(meetingID: opened.id)
        // The folder goes away between the click and the read, which is what a
        // meeting recorded after the read began looks like from here.
        try FileManager.default.removeItem(at: opened.store.layout.root)
        await model.reload()

        #expect(model.selection == [opened.id])
        #expect(model.detail?.meetingID == opened.id)
    }

    /// The list draws its faces from each meeting's speaker map, and renaming
    /// rewrites that file. Reading the archive again only when the processing
    /// stage changed left the row showing a name the meeting no longer has.
    @MainActor
    private static func aNewNameReachesTheList() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = try RuntimeFixtures.makeMeeting(root: root, clusters: ["remote-001_speaker_00"])

        let model = MeetingsWindowModel(runtime: RuntimeFixtures.makeRuntime(root: root))
        await model.reload()
        #expect(model.rows.first?.namedSpeakers.count == 0, "nobody named yet")

        var map = SpeakerMap()
        map.assign("Nadia Quist", to: "remote-001_speaker_00")
        try meeting.store.writeSpeakerMap(map)
        await model.refresh(meetingID: meeting.id)

        #expect(model.rows.first?.namedSpeakers.map(\.displayName) == ["Nadia Quist"])
        #expect(model.rows.first?.unnamedCount == 0)
    }

    @MainActor
    private static func aNewTitleReachesTheList() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = try RuntimeFixtures.makeMeeting(root: root, clusters: ["local"], title: "Design review")

        let model = MeetingsWindowModel(runtime: RuntimeFixtures.makeRuntime(root: root))
        await model.reload()
        model.show(meetingID: meeting.id)
        model.detail?.title = "Northwind renewal"
        model.detail?.saveEdits()

        await waitFor("the row to take the new title") {
            model.rows.first?.title == "Northwind renewal"
        }
    }

    /// Return in the title field writes immediately rather than waiting for the
    /// debounce. That path wrote the file and told nobody, so the row went on
    /// showing the old title until the archive was read again, which is the one
    /// case where the user is watching for the change.
    @MainActor
    private static func aCommittedTitleReachesTheList() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = try RuntimeFixtures.makeMeeting(root: root, clusters: ["local"], title: "Design review")

        let model = MeetingsWindowModel(runtime: RuntimeFixtures.makeRuntime(root: root))
        await model.reload()
        model.show(meetingID: meeting.id)
        model.detail?.title = "Northwind renewal"
        model.detail?.save()

        await waitFor("the row to take the committed title") {
            model.rows.first?.title == "Northwind renewal"
        }
    }

    /// The window keeps its model when it closes, so the pane is still on the
    /// meeting it was showing when it opens again. Reading only the list left it
    /// on the transcript that did not exist yet.
    @MainActor
    private static func theOpenPaneCatchesUp() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = MeetingRepository(root: root.appendingPathComponent("Meetings"))
        let started = Date(timeIntervalSince1970: 1_787_070_000)
        let created = try repository.createMeeting(
            source: .googleMeet, provider: .unknown, startedAt: started,
            titles: TitleCandidates(provider: "Design review", timestampFallback: "f"), now: started
        )

        let model = MeetingsWindowModel(runtime: RuntimeFixtures.makeRuntime(root: root))
        await model.reload()
        model.show(meetingID: created.metadata.id)
        // Opening the pane starts a read of its own. It has to finish before
        // the transcript lands, or that read is the one that picks it up and
        // the reopen is never tested.
        try? await Task.sleep(for: .milliseconds(50))
        #expect(model.detail?.transcript == nil, "nothing transcribed yet")

        try created.store.writeCanonicalTranscript(CanonicalTranscript(
            generatedAt: started,
            utterances: [Utterance(
                id: "u0", start: 0, end: 4, track: .remote,
                rawSpeakerLabel: "remote-001_speaker_00", speakerKey: "remote-001_speaker_00",
                text: "so the northwind renewal", chunkID: "c1", model: "m"
            )]
        ))
        await model.reload()

        #expect(model.detail?.combinedLines.count == 1)
    }

    /// Renaming a speaker rewrites `transcript.md`, and the words the index
    /// holds are the ones it had before. The rewrite lands after the click, so
    /// the index is read again when the change reports back.
    @MainActor
    private static func searchFollowsARewrittenTranscript() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = try RuntimeFixtures.makeMeeting(root: root, clusters: ["remote-001_speaker_00"])
        try meeting.store.writeTranscriptMarkdown("Speaker 1: the northwind renewal")

        let model = MeetingsWindowModel(runtime: RuntimeFixtures.makeRuntime(root: root))
        await model.reload()
        model.show(meetingID: meeting.id)
        await waitFor("the transcripts to be read") { model.searchesTranscripts }
        model.query = "nadia"
        #expect(model.sections.flatMap(\.rows).count == 0, "that name is not in it yet")

        try meeting.store.writeTranscriptMarkdown("Nadia Quist: the northwind renewal")
        await model.refresh(meetingID: meeting.id)

        #expect(model.sections.flatMap(\.rows).map(\.id) == [meeting.id])
    }

    /// A meeting still being transcribed is in the list before it has any words.
    /// Counting it as read because the index had looked at it once meant its
    /// words were never picked up, and it stayed unsearchable for the life of
    /// the window.
    @MainActor
    private static func aLaterTranscriptJoinsTheSearchIndex() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = try RuntimeFixtures.makeMeeting(root: root, clusters: ["local"], title: "Design review")

        let model = MeetingsWindowModel(runtime: RuntimeFixtures.makeRuntime(root: root))
        await model.reload()
        await waitFor("the first pass over the archive") { model.searchesTranscripts }

        try meeting.store.writeTranscriptMarkdown("Marlow: the northwind renewal")
        await model.reload()
        model.query = "northwind"

        await waitFor("the words to reach the index") {
            model.sections.flatMap(\.rows).map(\.id) == [meeting.id]
        }
    }

    /// A rebuild rewrites `transcript.md` and nothing else watches one finish.
    /// Dropping the words and waiting for the next reload left search answering
    /// from the transcript the meeting used to have.
    @MainActor
    private static func searchFollowsARebuild() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = try RuntimeFixtures.makeMeeting(root: root, clusters: ["local"], title: "Design review")
        try meeting.store.writeTranscriptMarkdown("Marlow: the northwind renewal")

        let model = MeetingsWindowModel(runtime: RuntimeFixtures.makeRuntime(root: root))
        await model.reload()
        await waitFor("the transcripts to be read") { model.searchesTranscripts }
        #expect(model.selection.count == 1, "the first row is selected")

        // Standing in for the assembler, which has no chunks to work from here.
        // What the window owes is the read back, whatever the rebuild wrote.
        try meeting.store.writeTranscriptMarkdown("Marlow: the audio sdk call")
        model.rebuildSelection()
        model.query = "audio sdk"

        await waitFor("the rebuilt words to reach search") {
            model.sections.flatMap(\.rows).map(\.id) == [meeting.id]
        }
    }

    /// A conversation recorded in two halves is one row, and the pane opens on
    /// the half a notification named. Every operation named by that identifier
    /// has to reach the conversation: looking the row up under the folded half's
    /// own identifier found nothing, and placing what came back under the
    /// identifier that was asked for put a second row for one conversation in
    /// the list.
    @MainActor
    private static func aFoldedHalfReachesTheConversationsRow() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try RuntimeFixtures.makeMeeting(
            root: root, clusters: ["remote-001_speaker_00"], title: "Design review"
        )
        let second = try RuntimeFixtures.makeMeeting(
            root: root, clusters: ["remote-001_speaker_00"], title: "Design review, rejoined"
        )

        let runtime = RuntimeFixtures.makeRuntime(root: root)
        let model = MeetingsWindowModel(runtime: runtime)
        await model.reload()
        model.show(meetingID: second.id)
        runtime.combine(meetingID: second.id, into: first.id, reason: "a test")
        await model.reload()

        #expect(model.rows.map(\.id) == [first.id], "one row for the conversation")
        #expect(
            model.detail?.meetingID == second.id,
            "the pane is still keyed on the half it opened on"
        )

        var map = SpeakerMap()
        map.assign("Nadia Quist", to: "remote-001_speaker_00")
        try first.store.writeSpeakerMap(map)
        await model.refresh(meetingID: second.id)

        #expect(model.rows.count == 1, "and not a second row for the same conversation")
        #expect(model.rows.first?.namedSpeakers.map(\.displayName) == ["Nadia Quist"])
    }

    /// A cluster identifier names a speaker inside one recording, and both
    /// halves of a rejoined call number their speakers from zero. Naming a
    /// cluster writes the speaker map of the recording the pane is keyed on, so
    /// counting every line in the conversation carrying that identifier claimed
    /// the change had reached lines in the other half that it had not.
    @MainActor
    private static func aReceiptCountsOneRecordingsLines() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try RuntimeFixtures.makeMeeting(
            root: root, clusters: ["remote-001_speaker_00"], title: "Design review",
            startedAt: Date(timeIntervalSince1970: 1_787_066_400)
        )
        let second = try RuntimeFixtures.makeMeeting(
            root: root, clusters: ["remote-001_speaker_00"], title: "Design review, rejoined"
        )

        let runtime = RuntimeFixtures.makeRuntime(root: root)
        runtime.combine(meetingID: second.id, into: first.id, reason: "a test")
        let model = MeetingsWindowModel(runtime: runtime)
        await model.reload()
        model.show(meetingID: first.id)
        await waitFor("the pane to read both halves") {
            (model.detail?.combinedLines.count ?? 0) > 1 && !(model.detail?.speakerRows.isEmpty ?? true)
        }
        guard let row = model.detail?.speakerRows.first(where: {
            $0.clusterID == "remote-001_speaker_00"
        }) else {
            Issue.record("the cluster is not in the speaker strip")
            return
        }

        model.assignCluster(row, toNewPerson: "Nadia Quist")

        #expect(
            model.receipt?.text == "Named Nadia Quist on 1 line. transcript.md and the speaker map are rewritten."
        )
    }

    /// A correction on a line beats the cluster's own entry, so naming the
    /// cluster around it leaves that line reading exactly as it did. Counting
    /// it made the receipt claim a line nothing had changed.
    @MainActor
    private static func aReceiptLeavesOutLinesAPersonSet() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = MeetingRepository(root: root.appendingPathComponent("Meetings"))
        let started = Date(timeIntervalSince1970: 1_787_070_000)
        let created = try repository.createMeeting(
            source: .googleMeet, provider: .unknown, startedAt: started,
            titles: TitleCandidates(provider: "Design review", timestampFallback: "f"), now: started
        )
        _ = try created.store.updateMetadata {
            $0.durationSeconds = 600
            $0.processing = ProcessingStatus(state: .complete, updatedAt: started)
        }
        func line(_ id: String, _ start: Double, _ end: Double) -> Utterance {
            Utterance(
                id: id, start: start, end: end, track: .remote,
                rawSpeakerLabel: "remote-001_speaker_00", speakerKey: "remote-001_speaker_00",
                text: "the northwind renewal", chunkID: "c1", model: "m"
            )
        }
        let lines = [line("u0", 0, 8), line("u1", 10, 18), line("u2", 20, 28)]
        try created.store.writeCanonicalTranscript(
            CanonicalTranscript(generatedAt: started, utterances: lines)
        )
        // The middle line already belongs to somebody the user named on the
        // line itself, which the cluster's entry does not decide.
        var map = SpeakerMap()
        map.overrideUtterance(
            lines[1],
            with: SpeakerAssignment(displayName: "Owen Pellard", origin: .human),
            at: started
        )
        try created.store.writeSpeakerMap(map)

        let model = MeetingsWindowModel(runtime: RuntimeFixtures.makeRuntime(root: root))
        await model.reload()
        model.show(meetingID: created.metadata.id)
        await waitFor("the pane to read the meeting") {
            !(model.detail?.speakerRows.isEmpty ?? true)
        }
        guard let row = model.detail?.speakerRows.first else {
            Issue.record("the cluster is not in the speaker strip")
            return
        }

        model.assignCluster(row, toNewPerson: "Nadia Quist")

        #expect(
            model.receipt?.text == "Named Nadia Quist on 2 lines. transcript.md and the speaker map are rewritten."
        )
    }

    /// A correction made in the pane is drawn straight away and reaches disk a
    /// moment later, so a receipt taken in between counts what is on screen. The
    /// pane wrote the new name onto the line without recording that a person had
    /// set it, and the next receipt counted a line the cluster's entry no longer
    /// names.
    @MainActor
    private static func aReceiptLeavesOutAFreshCorrection() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = MeetingRepository(root: root.appendingPathComponent("Meetings"))
        let started = Date(timeIntervalSince1970: 1_787_070_000)
        let created = try repository.createMeeting(
            source: .googleMeet, provider: .unknown, startedAt: started,
            titles: TitleCandidates(provider: "Design review", timestampFallback: "f"), now: started
        )
        _ = try created.store.updateMetadata {
            $0.durationSeconds = 600
            $0.processing = ProcessingStatus(state: .complete, updatedAt: started)
        }
        func line(_ id: String, _ key: String, _ start: Double, _ end: Double) -> Utterance {
            Utterance(
                id: id, start: start, end: end, track: .remote, rawSpeakerLabel: key,
                speakerKey: key, text: "the northwind renewal", chunkID: "c1", model: "m"
            )
        }
        // Another speaker between them, so the first line is a turn of its own
        // and can be corrected without taking the third line with it.
        try created.store.writeCanonicalTranscript(CanonicalTranscript(
            generatedAt: started,
            utterances: [
                line("u0", "remote-001_speaker_00", 0, 8),
                line("u1", "remote-001_speaker_01", 10, 18),
                line("u2", "remote-001_speaker_00", 20, 28),
            ]
        ))

        let model = MeetingsWindowModel(runtime: RuntimeFixtures.makeRuntime(root: root))
        await model.reload()
        model.show(meetingID: created.metadata.id)
        await waitFor("the pane to read the meeting") {
            !(model.detail?.speakerRows.isEmpty ?? true)
        }
        let blocks = CombinedLineBlock.blocks(from: model.detail?.combinedLines ?? [])
        guard let first = blocks.first,
              let row = model.detail?.speakerRows.first(where: {
                  $0.clusterID == "remote-001_speaker_00"
              })
        else {
            Issue.record("the meeting did not read back as three turns")
            return
        }
        #expect(first.lines.count == 1, "the first turn is the line being corrected")

        model.detail?.assignBlock(first, toNewPerson: "Owen Pellard")
        model.assignCluster(row, toNewPerson: "Nadia Quist")

        #expect(
            model.receipt?.text == "Named Nadia Quist on 1 line. transcript.md and the speaker map are rewritten."
        )
    }

    /// A call recorded in two halves keeps the second half's words in the
    /// second half's own folder, and the list draws one row for the
    /// conversation. An index built from the first half alone could not find
    /// anything said after the call dropped.
    @MainActor
    private static func searchReachesBothHalvesOfACall() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try RuntimeFixtures.makeMeeting(root: root, clusters: ["local"], title: "Design review")
        let second = try RuntimeFixtures.makeMeeting(
            root: root, clusters: ["local"], title: "Design review, rejoined"
        )
        try first.store.writeTranscriptMarkdown("Marlow: the northwind renewal")
        try second.store.writeTranscriptMarkdown("Marlow: the audio sdk call")

        let runtime = RuntimeFixtures.makeRuntime(root: root)
        runtime.combine(meetingID: second.id, into: first.id, reason: "a test")

        let model = MeetingsWindowModel(runtime: runtime)
        await model.reload()
        await waitFor("the transcripts to be read") { model.searchesTranscripts }
        model.query = "audio sdk"

        #expect(
            model.sections.flatMap(\.rows).map(\.id) == [first.id],
            "a word from after the drop finds the conversation"
        )
    }

    /// The clusters a row counts come from `transcript.json`, which is the one
    /// file in the folder a half-written or hand-edited copy can make
    /// undecodable. Losing the row would take the meeting out of the archive
    /// listing altogether.
    @MainActor
    private static func aCorruptTranscriptKeepsItsRow() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = try RuntimeFixtures.makeMeeting(root: root, clusters: ["remote-001_speaker_00"])
        var map = SpeakerMap()
        map.assign("Bryn Halloway", to: "remote-001_speaker_00", identityID: IdentityID(7))
        try meeting.store.writeSpeakerMap(map)
        try Data(#"{"utterances": [{"speakerK"#.utf8)
            .write(to: meeting.store.layout.canonicalTranscript)

        let rows = await RuntimeFixtures.makeRuntime(root: root).meetingRows()

        #expect(rows.count == 1, "the meeting is still listed")
        #expect(rows.first?.namedSpeakers.map(\.displayName) == ["Bryn Halloway"])
        #expect(rows.first?.unnamedCount == 0, "and nothing is invented to ask about")
    }

    /// The runtime reports a stage boundary and every speaker change for
    /// whichever meeting it happened to, which is not always the one the pane is
    /// showing. Reading the row again only for the pane's own meeting left every
    /// other row in the list describing the meeting as it was when the window
    /// opened, including the state badge on a recording that had finished.
    @MainActor
    private static func anotherMeetingsRowKeepsUp() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let earlier = try RuntimeFixtures.makeMeeting(
            root: root, clusters: ["remote-001_speaker_00"], title: "Standup",
            startedAt: Date(timeIntervalSince1970: 1_787_066_400)
        )
        _ = try RuntimeFixtures.makeMeeting(root: root, clusters: ["remote-001_speaker_00"], title: "Design review")

        let model = MeetingsWindowModel(runtime: RuntimeFixtures.makeRuntime(root: root))
        await model.reload()
        #expect(model.detail?.title == "Design review", "the newest meeting is the one open")

        var map = SpeakerMap()
        map.assign("Nadia Quist", to: "remote-001_speaker_00")
        try earlier.store.writeSpeakerMap(map)
        await model.refresh(meetingID: earlier.id)

        #expect(
            model.rows.first { $0.id == earlier.id }?.namedSpeakers.map(\.displayName) == ["Nadia Quist"]
        )
    }

    /// Combining is done from the pane, and the archive listing hides a folded
    /// continuation. The row for the half that was folded in stayed in the list
    /// until the window was closed and opened again, so one conversation had two
    /// rows and one of them opened a meeting the listing no longer holds.
    @MainActor
    private static func combiningTakesTheFoldedRowOutOfTheList() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try RuntimeFixtures.makeMeeting(
            root: root, clusters: ["local"], title: "Design review",
            startedAt: Date(timeIntervalSince1970: 1_787_066_400)
        )
        let second = try RuntimeFixtures.makeMeeting(
            root: root, clusters: ["local"], title: "Design review, rejoined"
        )
        _ = try second.store.updateMetadata {
            $0.possibleContinuationOf = first.id
            $0.possibleContinuationReason = "the call dropped and was rejoined"
        }

        let model = MeetingsWindowModel(runtime: RuntimeFixtures.makeRuntime(root: root))
        await model.reload()
        model.show(meetingID: second.id)
        model.combineWithEarlier()

        // In the same turn, not after the archive read. The combine is already
        // on disk when the call returns, and a selection left on the folded row
        // dangles on a row about to disappear for as long as the pane takes to
        // reload.
        #expect(model.selection == [first.id], "the conversation's own row is selected")
        await waitFor("the folded recording's row to leave the list") {
            model.rows.map(\.id) == [first.id]
        }
        #expect(model.selection == [first.id], "and the selection survives the read")
    }

    /// Separating is done from the pane too. The recording that comes back is a
    /// row of its own again, and the words it holds are its own. The index entry
    /// for the conversation held both halves, so a word only the second half
    /// said went on matching the first.
    @MainActor
    private static func separatingRestoresTheRowAndTheIndex() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try RuntimeFixtures.makeMeeting(
            root: root, clusters: ["local"], title: "Design review",
            startedAt: Date(timeIntervalSince1970: 1_787_066_400)
        )
        let second = try RuntimeFixtures.makeMeeting(
            root: root, clusters: ["local"], title: "Design review, rejoined"
        )
        try first.store.writeTranscriptMarkdown("Marlow: the northwind renewal")
        try second.store.writeTranscriptMarkdown("Marlow: the audio sdk call")

        let runtime = RuntimeFixtures.makeRuntime(root: root)
        runtime.combine(meetingID: second.id, into: first.id, reason: "a test")

        let model = MeetingsWindowModel(runtime: runtime)
        await model.reload()
        await waitFor("the transcripts to be read") { model.searchesTranscripts }
        model.show(meetingID: first.id)
        model.separate(second.id)

        await waitFor("the separated recording to have a row again") {
            model.rows.count == 2
        }
        model.query = "audio sdk"
        await waitFor("search to answer for the recording holding those words") {
            model.sections.flatMap(\.rows).map(\.id) == [second.id]
        }
    }

    /// A diarizer can emit a label that owns almost none of the transcript: one
    /// cloud-diarized meeting listed eleven speakers, six of them at 0s. The
    /// speaker strip leaves those out, so a row that counted them put the
    /// meeting under Unnamed with nothing in it to name, which is the drawer
    /// nothing ever leaves.
    @MainActor
    private static func aSilentClusterIsNotWorkToDo() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = MeetingRepository(root: root.appendingPathComponent("Meetings"))
        let started = Date(timeIntervalSince1970: 1_787_070_000)
        let created = try repository.createMeeting(
            source: .googleMeet, provider: .unknown, startedAt: started,
            titles: TitleCandidates(provider: "Design review", timestampFallback: "f"), now: started
        )
        _ = try created.store.updateMetadata {
            $0.durationSeconds = 600
            $0.processing = ProcessingStatus(state: .complete, updatedAt: started)
        }
        func line(_ id: String, _ key: String, _ start: Double, _ end: Double) -> Utterance {
            Utterance(
                id: id, start: start, end: end, track: .remote, rawSpeakerLabel: key,
                speakerKey: key, text: "the northwind renewal", chunkID: "c1", model: "m"
            )
        }
        try created.store.writeCanonicalTranscript(CanonicalTranscript(
            generatedAt: started,
            utterances: [
                line("u0", "remote-001_speaker_00", 0, 8),
                line("u1", "remote-001_speaker_01", 8, 8.2),
            ]
        ))
        var map = SpeakerMap()
        map.assign("Bryn Halloway", to: "remote-001_speaker_00", identityID: IdentityID(7))
        try created.store.writeSpeakerMap(map)

        let runtime = RuntimeFixtures.makeRuntime(root: root)
        let strip = await runtime.speakers(inMeeting: created.metadata.id)
            .filter(\.hasSpeechToShow)
        #expect(
            strip.map(\.clusterID) == ["remote-001_speaker_00"],
            "the strip offers nothing to name"
        )

        let rows = await runtime.meetingRows()
        guard let row = rows.first else {
            Issue.record("the meeting is not in the archive")
            return
        }
        #expect(row.unnamedCount == 0, "so the list counts no work either")
        #expect(row.speakers.map(\.key) == ["remote-001_speaker_00"])
        #expect(
            !MeetingsFilter.unnamed.admits(row),
            "and the filter that lists the work does not hold it"
        )
    }

    @MainActor
    private static func aLaterMeetingJoinsTheSearchIndex() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try RuntimeFixtures.makeMeeting(root: root, clusters: ["local"])
        try first.store.writeTranscriptMarkdown("Marlow: the northwind renewal")

        let model = MeetingsWindowModel(runtime: RuntimeFixtures.makeRuntime(root: root))
        await model.reload()
        await waitFor("the first transcript to be read") { model.searchesTranscripts }

        let second = try RuntimeFixtures.makeMeeting(root: root, clusters: ["local"], title: "Weekly sync")
        try second.store.writeTranscriptMarkdown("Marlow: the audio sdk call")
        await model.reload()
        model.query = "audio sdk"

        await waitFor("the new transcript to be read") {
            model.sections.flatMap(\.rows).map(\.id) == [second.id]
        }
    }

    /// The microphone track is named by the pipeline, from the name in Settings,
    /// which is "Me" on a fresh install. That is also the name a cluster with no
    /// entry at all falls back to, so deciding "unnamed" by comparing the two
    /// drew the user's own voice as a voice asking for a name.
    @MainActor
    private static func theMicrophoneTrackIsNotUnnamed() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = try RuntimeFixtures.makeMeeting(
            root: root, clusters: [SpeakerLabel.localUser, "remote-001_speaker_00"]
        )
        // What the assembling stage writes for a meeting recorded from this
        // Mac's microphone.
        var map = SpeakerMap()
        map.entries[SpeakerLabel.localUser] = SpeakerAssignment(
            displayName: "Me", origin: .deterministic
        )
        try meeting.store.writeSpeakerMap(map)

        let rows = await RuntimeFixtures.makeRuntime(root: root).speakers(inMeeting: meeting.id)
        guard let mine = rows.first(where: { $0.clusterID == SpeakerLabel.localUser }) else {
            Issue.record("the microphone track is not in the speaker strip")
            return
        }
        #expect(mine.displayName == "Me")
        #expect(!mine.isUnnamed, "the map named it, whatever the fallback would have been")
        #expect(
            rows.first { $0.clusterID == "remote-001_speaker_00" }?.isUnnamed ?? false,
            "and a cluster the map says nothing about still is"
        )
    }

    /// The index answers under the conversation's identifier and holds every
    /// recording of it, while the pane opened on the half a notification named
    /// is keyed on that half. Dropping the words under the pane's own identifier
    /// removed nothing, so a batch read in flight put the pre-rename transcript
    /// back and search answered from it for the life of the window.
    @MainActor
    private static func namingOnAFoldedHalfDropsTheConversationsWords() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try RuntimeFixtures.makeMeeting(
            root: root, clusters: ["remote-001_speaker_00"], title: "Design review",
            startedAt: Date(timeIntervalSince1970: 1_787_066_400)
        )
        let second = try RuntimeFixtures.makeMeeting(
            root: root, clusters: ["remote-001_speaker_00"], title: "Design review, rejoined"
        )
        try first.store.writeTranscriptMarkdown("Speaker 1: the northwind renewal")
        try second.store.writeTranscriptMarkdown("Speaker 1: the audio sdk call")

        let runtime = RuntimeFixtures.makeRuntime(root: root)
        let model = MeetingsWindowModel(runtime: runtime)
        await model.reload()
        model.show(meetingID: second.id)
        runtime.combine(meetingID: second.id, into: first.id, reason: "a test")
        await model.reload()
        #expect(model.detail?.meetingID == second.id, "the pane is keyed on the half it opened on")

        model.query = "audio sdk"
        await waitFor("both halves to reach the index") {
            model.sections.flatMap(\.rows).map(\.id) == [first.id]
        }
        model.query = ""
        #expect(model.indexHolds(first.id), "the conversation's words are in the index")

        await waitFor("the pane to read the folded half") {
            !(model.detail?.speakerRows.isEmpty ?? true)
        }
        guard let row = model.detail?.speakerRows.first(where: {
            $0.clusterID == "remote-001_speaker_00"
        }) else {
            Issue.record("the cluster is not in the speaker strip")
            return
        }
        model.assignCluster(row, toNewPerson: "Nadia Quist")

        #expect(
            !model.indexHolds(first.id),
            "the rename rewrites transcript.md, so the words the index holds are stale"
        )
    }

    /// The list draws one row for a conversation recorded in two halves, so
    /// reading the first half alone left a voice that only spoke after the drop
    /// in no row at all.
    @MainActor
    private static func bothHalvesReachTheRow() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (_, conversation) = try makeRejoinedCall(root: root)

        let runtime = PipitRuntime(settingsDirectory: root)
        var settings = runtime.settings
        settings.storageRootPath = root.appendingPathComponent("Meetings").path
        runtime.update(settings: settings)

        let rows = await runtime.meetingRows()
        #expect(rows.count == 1, "one row for one conversation")
        guard let row = rows.first else { return }
        #expect(row.id == conversation)
        #expect(row.speakers.count == 2, "one voice from each half")
        #expect(row.namedSpeakers.map(\.displayName) == ["Bryn Halloway"])
        #expect(row.unnamedCount == 1, "the far end after the rejoin")
        #expect(
            Set(row.speakers.map(\.key)).count == 2,
            """
            both halves number their speakers from zero, so the keys are qualified \
            rather than collided
            """
        )
    }

    /// The bug this collapses: a Slack huddle with two people in it came back
    /// with eleven speaker keys, because the local diarizer splits a voice into
    /// several clusters and the huddle names every one of them from its roster.
    /// The strip drew a chip per key, so one person appeared four times.
    @MainActor
    private static func oneAccountIsOneChip() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = try RuntimeFixtures.makeMeeting(
            root: root,
            clusters: [
                "remote-001_speaker_00", "remote-001_speaker_01", "remote-001_speaker_02",
            ]
        )
        try meeting.store.writeSpeakerMap(sensorNamedMap(
            ["remote-001_speaker_00", "remote-001_speaker_01", "remote-001_speaker_02"],
            as: "Bryn Callister", account: "U06"
        ))

        let model = MeetingsWindowModel(runtime: RuntimeFixtures.makeRuntime(root: root))
        await model.reload()
        model.show(meetingID: meeting.id)
        await waitFor("the strip to read the speakers") {
            !(model.detail?.speakerRows.isEmpty ?? true)
        }

        #expect(model.detail?.speakerRows.count == 1, "one person, one chip")
        guard let row = model.detail?.speakerRows.first else { return }
        #expect(row.displayName == "Bryn Callister")
        #expect(
            row.allClusterIDs == ["remote-001_speaker_00", "remote-001_speaker_01", "remote-001_speaker_02"]
        )
        // Three eight-second utterances, so the chip reports what the person
        // said rather than what one of their clusters did.
        #expect(
            abs(row.speechSeconds - 24) <= 0.001,
            "expected \(24) ± \(0.001), got \(row.speechSeconds)"
        )
    }

    /// The chip stands for the person, so renaming it has to reach every key
    /// underneath. Writing only the representative left the other clusters
    /// reading the old name and the chip split back into several on reload.
    @MainActor
    private static func namingOneChipWritesEveryClusterBehindIt() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = try RuntimeFixtures.makeMeeting(
            root: root, clusters: ["remote-001_speaker_00", "remote-001_speaker_01"]
        )
        try meeting.store.writeSpeakerMap(sensorNamedMap(
            ["remote-001_speaker_00", "remote-001_speaker_01"],
            as: "Bryn Callister", account: "U06"
        ))

        let model = MeetingsWindowModel(runtime: RuntimeFixtures.makeRuntime(root: root))
        await model.reload()
        model.show(meetingID: meeting.id)
        await waitFor("the strip to read the speakers") {
            (model.detail?.speakerRows.count ?? 0) == 1
        }
        guard let row = model.detail?.speakerRows.first else {
            Issue.record("the person has no chip")
            return
        }

        model.assignCluster(row, toNewPerson: "Nadia Quist")

        await waitFor("both clusters to take the new name") {
            let map = try? meeting.store.readSpeakerMap()
            return map?.displayName(for: "remote-001_speaker_00") == "Nadia Quist"
                && map?.displayName(for: "remote-001_speaker_01") == "Nadia Quist"
        }
        let map = try #require(try? meeting.store.readSpeakerMap())
        // One person, so one profile. Promoting each cluster's own anonymous
        // voice separately left two profiles holding the same name, and two
        // identical centroids mean the margin gate never recognises either.
        let identities = Set(
            ["remote-001_speaker_00", "remote-001_speaker_01"]
                .compactMap { map.entries[$0]?.identityID }
        )
        #expect(identities.count == 1, "both clusters name the same person")
        #expect(
            model.receipt?.text == "Named Nadia Quist on 2 lines. transcript.md and the speaker map are rewritten."
        )
    }

    /// The voice-matching stage writes the identifier on the one cluster it
    /// scored and the roster names the rest, so the longest-speaking key is
    /// routinely the one without a person behind it. Reading the row off that
    /// key alone drew a grey face for somebody the meeting had already
    /// recognised.
    @MainActor
    private static func theChipKeepsTheIdentityOffAShorterCluster() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = try RuntimeFixtures.makeMeeting(
            root: root, clusters: ["remote-001_speaker_00", "remote-001_speaker_01"]
        )
        // The linked cluster speaks for two seconds and the roster-named one for
        // sixty, so the long key leads the group.
        try meeting.store.writeCanonicalTranscript(CanonicalTranscript(
            generatedAt: Date(timeIntervalSince1970: 1_787_070_000),
            utterances: [
                Utterance(
                    id: "u0", start: 0, end: 2, track: .remote,
                    rawSpeakerLabel: "remote-001_speaker_00", speakerKey: "remote-001_speaker_00",
                    text: "the northwind renewal", chunkID: "c1", model: "m"
                ),
                Utterance(
                    id: "u1", start: 10, end: 70, track: .remote,
                    rawSpeakerLabel: "remote-001_speaker_01", speakerKey: "remote-001_speaker_01",
                    text: "the northwind renewal", chunkID: "c1", model: "m"
                ),
            ]
        ))
        try meeting.store.writeSpeakerMap(sensorNamedMap(
            ["remote-001_speaker_00", "remote-001_speaker_01"],
            as: "Bryn Callister", account: "U06"
        ))

        let runtime = RuntimeFixtures.makeRuntime(root: root)
        let model = MeetingsWindowModel(runtime: runtime)
        await model.reload()
        model.show(meetingID: meeting.id)
        await waitFor("the strip to read the speakers") {
            (model.detail?.speakerRows.count ?? 0) == 1
        }
        // Naming the short cluster on its own is what puts a person behind it
        // and leaves the long one with the roster's name and no identifier.
        runtime.assignSpeaker(
            name: "Bryn Callister", key: "remote-001_speaker_00", meetingID: meeting.id
        )
        await waitFor("the short cluster to gain a person") {
            (try? meeting.store.readSpeakerMap())?
                .entries["remote-001_speaker_00"]?.identityID != nil
        }
        await model.detail?.reloadSpeakers()

        guard let row = model.detail?.speakerRows.first else {
            Issue.record("the person has no chip")
            return
        }
        #expect(model.detail?.speakerRows.count == 1, "still one person")
        #expect(row.clusterID == "remote-001_speaker_01", "the long cluster leads")
        #expect(row.identity != nil, "and the chip keeps the person behind the short one")
    }

    /// A speaker map as the sensor stage writes one: every cluster the client
    /// attributed to an account carries that account's name and identifier.
    private static func sensorNamedMap(
        _ keys: [String], as name: String, account: String
    ) -> SpeakerMap {
        var map = SpeakerMap()
        for key in keys {
            map.assign(
                SpeakerAssignment(
                    displayName: name, origin: .sensor, participantID: account,
                    provenance: SpeakerProvenance(source: .sensor)
                ),
                to: key
            )
        }
        return map
    }

    /// A cluster identifier names a speaker inside one recording, and both
    /// halves of a rejoined call number theirs from zero. A name given to the
    /// voice heard after the drop therefore has to reach the second half's own
    /// speaker map and leave the first half's alone.
    @MainActor
    private static func namingTheSecondHalfWritesItsOwnMap() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (repository, conversation) = try makeRejoinedCall(root: root)

        let model = MeetingsWindowModel(runtime: RuntimeFixtures.makeRuntime(root: root))
        await model.reload()
        model.show(meetingID: conversation)
        await waitFor("the pane to read both halves") {
            (model.detail?.speakerRows.count ?? 0) == 2
        }
        guard let after = model.detail?.speakerRows.first(where: {
            $0.recordingID != conversation
        }) else {
            Issue.record("the voice heard after the rejoin has no chip")
            return
        }
        #expect(after.isUnnamed, "and it is the one asking for a name")

        model.assignCluster(after, toNewPerson: "Nadia Quist")

        guard let logical = repository.logicalMeeting(id: conversation),
              let continuation = logical.continuations.first
        else {
            Issue.record("the conversation lost its second half")
            return
        }
        await waitFor("the name to reach the second half") {
            (try? continuation.store.readSpeakerMap())?
                .displayName(for: "remote-001_speaker_00") == "Nadia Quist"
        }
        #expect(
            (try? logical.primary.store.readSpeakerMap())?
                .displayName(for: "remote-001_speaker_00") == "Bryn Halloway",
            "and the voice heard before the drop keeps the name it already had"
        )
    }

    /// The list counts the work and the strip is where the work is done, so a
    /// meeting the Unnamed filter lists has to offer a chip for every voice it
    /// counted. Reading one recording's speakers made the filter a drawer
    /// nothing ever left: the row said one voice needed a name and the pane it
    /// opened showed one chip that was already named.
    @MainActor
    private static func theStripCoversWhatTheListCounts() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (_, conversation) = try makeRejoinedCall(root: root)

        let runtime = PipitRuntime(settingsDirectory: root)
        var settings = runtime.settings
        settings.storageRootPath = root.appendingPathComponent("Meetings").path
        runtime.update(settings: settings)

        guard let row = await runtime.meetingRows().first else {
            Issue.record("the conversation has no row")
            return
        }
        let strip = await runtime.speakers(inMeeting: conversation).filter(\.hasSpeechToShow)
        #expect(strip.count == row.speakers.count, "the strip draws every voice the row counted")
        #expect(
            strip.filter(\.isUnnamed).count == row.unnamedCount,
            "and the work the list reports is work the strip can do"
        )
        #expect(Set(strip.map(\.id)).count == strip.count, "each chip is its own row")
        #expect(Set(strip.map(\.recordingID)).count == 2, "one from each recording of the call")
        // Both halves call their first speaker the same thing, so an unnamed
        // chip says which half it came from.
        #expect(
            strip.contains { $0.isUnnamed && $0.displayName.hasSuffix("part 2") },
            "got \(strip.map(\.displayName))"
        )
    }

    // MARK: - archiving and trashing

    /// Both halves of a rejoined call are one row, so trashing that row has to
    /// take both folders. Leaving the second half behind would put a recording
    /// in the archive that no row can reach.
    @MainActor
    private static func trashingMovesEveryFolder() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (repository, meetingID) = try makeRejoinedCall(root: root)
        let folders = (repository.logicalMeeting(id: meetingID)?.recordings ?? [])
            .map(\.store.layout.root)
        #expect(folders.count == 2, "a call recorded in two halves")

        let model = MeetingsWindowModel(runtime: RuntimeFixtures.makeRuntime(root: root))
        await model.reload()
        #expect(model.rows.map(\.id) == [meetingID])
        guard let target = model.rows.first else {
            Issue.record("no row to move")
            return
        }

        model.confirmTrash([target])
        guard let pending = model.pendingTrash else {
            Issue.record("the move asks first")
            return
        }
        #expect(pending.title.contains("Weekly sync"), "got \(pending.title)")
        #expect(
            pending.message.contains("moved to the Trash rather than deleted"),
            "the warning says where the files go. got \(pending.message)"
        )
        #expect(pending.folderCount == 2)
        #expect(
            pending.message.contains("2 folders"),
            "and it counts both halves of the call. got \(pending.message)"
        )
        await model.performTrash(pending)

        let trash = RuntimeFixtures.trashDirectory(under: root)
        for folder in folders {
            #expect(
                !FileManager.default.fileExists(atPath: folder.path),
                "\(folder.lastPathComponent) has left the archive"
            )
            #expect(
                FileManager.default.fileExists(
                    atPath: trash.appendingPathComponent(folder.lastPathComponent).path
                ),
                "and is in the Trash, whole, rather than unlinked"
            )
        }
        let moved = MeetingLayout(root: trash.appendingPathComponent(folders[0].lastPathComponent))
        #expect(
            FileManager.default.fileExists(atPath: moved.metadata.path),
            "with the files it held still in it"
        )
        #expect(model.rows.count == 0, "and the list has nothing left")
        #expect(model.selection.isEmpty)
        #expect(model.detail == nil, "the pane is not left reading files that are gone")
        #expect(!model.indexHolds(meetingID), "search does not answer for it either")
    }

    /// Archiving is about the list. Every file stays exactly where it was, and
    /// the Archived filter is where the meeting is put back from.
    @MainActor
    private static func archivingKeepsTheFiles() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = try RuntimeFixtures.makeMeeting(root: root, clusters: ["remote-001_speaker_00"])
        let folder = meeting.store.layout.root

        let model = MeetingsWindowModel(runtime: RuntimeFixtures.makeRuntime(root: root))
        await model.reload()
        guard let target = model.rows.first else {
            Issue.record("nothing recorded")
            return
        }

        model.setArchived(true, [target])
        await waitFor("the archived row to leave the list") {
            model.sections.flatMap(\.rows).isEmpty
        }
        #expect(FileManager.default.fileExists(atPath: folder.path), "the folder is untouched")
        #expect(
            FileManager.default.fileExists(atPath: meeting.store.layout.canonicalTranscript.path),
            "and so is the transcript"
        )
        #expect(model.selection.isEmpty, "and nothing is selected under All")

        model.filter = .archived
        #expect(
            model.sections.flatMap(\.rows).map(\.id) == [meeting.id],
            "the archived list is where it went"
        )

        guard let archived = model.rows.first else {
            Issue.record("the row is gone")
            return
        }
        #expect(archived.isArchived)
        model.setArchived(false, [archived])
        await waitFor("the meeting to come back") {
            model.rows.first?.isArchived == false
        }
        model.filter = .all
        #expect(model.sections.flatMap(\.rows).map(\.id) == [meeting.id])
    }

    /// A right-click on a row that is not selected acts on that row. Acting on
    /// the selection instead would delete meetings the pointer was never over.
    @MainActor
    private static func aRightClickActsOnTheRowUnderIt() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let started = Date(timeIntervalSince1970: 1_787_070_000)
        let first = try RuntimeFixtures.makeMeeting(
            root: root, clusters: ["remote-001_speaker_00"], title: "Design review",
            startedAt: started
        )
        let second = try RuntimeFixtures.makeMeeting(
            root: root, clusters: ["remote-001_speaker_00"], title: "Standup",
            startedAt: started.addingTimeInterval(3_600)
        )

        let model = MeetingsWindowModel(runtime: RuntimeFixtures.makeRuntime(root: root))
        await model.reload()
        model.select(first.id, extending: false)
        guard let other = model.rows.first(where: { $0.id == second.id }) else {
            Issue.record("the second meeting is not in the list")
            return
        }
        #expect(model.contextTargets(for: other).map(\.id) == [second.id])

        model.select(second.id, extending: true)
        #expect(
            Set(model.contextTargets(for: other).map(\.id)) == [first.id, second.id],
            "and a row inside the selection acts on all of it"
        )
    }

    /// The wiring from the window's move through to the voice memory. Without
    /// it a trashed meeting kept counting towards "heard in 3 meetings".
    @MainActor
    private static func trashingDropsTheOccurrences() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = try RuntimeFixtures.makeMeeting(root: root, clusters: ["remote-001_speaker_00"])
        let runtime = RuntimeFixtures.makeRuntime(root: root)
        let store = try #require(runtime.speakerStore)
        let bryn = try await store.createPerson(name: "Bryn")
        try await store.recordOccurrence(
            meetingID: meeting.id, clusterID: "remote-001_speaker_00", track: .remote,
            speechSeconds: 120, embedding: nil, model: nil, resolution: nil,
            identityID: bryn.id, source: .human,
            humanVerified: true, wasExpectedParticipant: false
        )
        #expect(try await store.meetingCount(for: bryn.id) == 1)

        #expect(
            await runtime.trashMeetings([meeting.id])[meeting.id] == .trashed,
            "the folder went"
        )

        #expect(try await store.meetingCount(for: bryn.id) == 0)
    }

    /// The archived flag lives in `metadata.json`, which the pipeline rewrites
    /// at every stage boundary. `updateMetadata` reads, changes and writes the
    /// whole document, so a field it does not know about has to survive that.
    @MainActor
    private static func archivingSurvivesAMetadataWrite() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = try RuntimeFixtures.makeMeeting(root: root, clusters: ["remote-001_speaker_00"])
        let runtime = RuntimeFixtures.makeRuntime(root: root)

        runtime.setArchived(true, meetingIDs: [meeting.id])
        _ = try meeting.store.updateMetadata { $0.durationSeconds = 900 }

        #expect(try meeting.store.readMetadata().isArchived)
        let summary = runtime.repository.summary(forDirectory: meeting.store.layout.root)
        #expect(summary?.isArchived == true, "and the list reads it back")

        runtime.setArchived(false, meetingIDs: [meeting.id])
        #expect(!(try meeting.store.readMetadata().isArchived))
    }

    /// Archiving leaves every file where it is, so a title half-typed when the
    /// row was archived still belongs to a meeting.
    @MainActor
    private static func archivingSavesTheEdit() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = try RuntimeFixtures.makeMeeting(root: root, clusters: ["remote-001_speaker_00"])

        let model = MeetingsWindowModel(runtime: RuntimeFixtures.makeRuntime(root: root))
        await model.reload()
        await waitFor("the pane to open") { model.detail?.title.isEmpty == false }
        model.detail?.title = "Renamed while archiving"
        guard let target = model.rows.first else {
            Issue.record("nothing recorded")
            return
        }

        model.setArchived(true, [target])

        #expect(
            try meeting.store.readMetadata().displayTitle == "Renamed while archiving",
            "the title reached disk before the pane was dropped"
        )
    }

    /// The footer counts against what the filter holds. Against the archive it
    /// read "1 of 2" under All with nothing typed in the search field.
    @MainActor
    private static func theFooterCountsWhatTheFilterHolds() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let started = Date(timeIntervalSince1970: 1_787_070_000)
        _ = try RuntimeFixtures.makeMeeting(
            root: root, clusters: ["remote-001_speaker_00"], title: "Design review",
            startedAt: started
        )
        _ = try RuntimeFixtures.makeMeeting(
            root: root, clusters: ["remote-001_speaker_00"], title: "Standup",
            startedAt: started.addingTimeInterval(3_600)
        )

        let model = MeetingsWindowModel(runtime: RuntimeFixtures.makeRuntime(root: root))
        await model.reload()
        #expect(model.filteredRows.count == 2)
        let both = model.totalDuration

        guard let target = model.rows.first else {
            Issue.record("nothing recorded")
            return
        }
        model.setArchived(true, [target])
        await waitFor("the archived row to leave the list") {
            model.filteredRows.count == 1
        }
        #expect(
            model.sections.flatMap(\.rows).count == model.filteredRows.count,
            "so the footer says one meeting rather than one of two"
        )
        #expect(model.totalDuration < both, "and the total is the time the list adds up to")

        model.filter = .archived
        #expect(model.filteredRows.count == 1)
    }

    /// A move that cannot finish stops before the recording the conversation
    /// started with, so the row that reaches what is left stays in the list.
    /// Nothing about the meeting is forgotten either, because the meeting is
    /// still there.
    @MainActor
    private static func aFolderThatWillNotMoveKeepsItsRow() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        let (repository, meetingID) = try makeRejoinedCall(root: root)
        guard let logical = repository.logicalMeeting(id: meetingID),
              let continuation = logical.continuations.first
        else {
            Issue.record("the call was not recorded in two halves")
            return
        }
        let locked = continuation.store.layout.root
        // Locked the way the Finder locks a file, which is the ordinary reason
        // a folder will not move.
        let unlock = { try? FileManager.default.setAttributes(
            [.immutable: false], ofItemAtPath: locked.path
        ) }
        defer { try? FileManager.default.removeItem(at: root) }
        defer { unlock() }
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: locked.path)

        let runtime = RuntimeFixtures.makeRuntime(root: root)
        let store = try #require(runtime.speakerStore)
        let bryn = try await store.createPerson(name: "Bryn")
        try await store.recordOccurrence(
            meetingID: meetingID, clusterID: "remote-001_speaker_00", track: .remote,
            speechSeconds: 120, embedding: nil, model: nil, resolution: nil,
            identityID: bryn.id, source: .human,
            humanVerified: true, wasExpectedParticipant: false
        )

        let outcome = await runtime.trashMeetings([meetingID])[meetingID]

        #expect(outcome == .folderNotMoved)
        #expect(
            FileManager.default.fileExists(atPath: logical.primary.store.layout.root.path),
            "the recording the conversation started with is still there, so the row still is"
        )
        #expect(
            try await store.meetingCount(for: bryn.id) == 1,
            "and a meeting still in the archive still counts for the people who spoke in it"
        )
    }

    @Test("writing a summary is not offered where it would replace notes")
    func writingASummaryIsNotOfferedWhereItWouldReplaceNotes() async throws {
        try await Self.theSummaryButtonIsHiddenWhereItWouldEatNotes()
    }

    @Test("the unnamed count is what the model would be asked about")
    func theUnnamedCountIsWhatTheModelWouldBeAskedAbout() async throws {
        try await Self.theCountMatchesWhatWouldBeAsked()
    }

    @Test("copying the transcript takes the document on disk")
    func copyingTheTranscriptTakesTheDocumentOnDisk() async throws {
        try await Self.copyingTakesTheTranscriptFromDisk()
    }

    @Test("a dismissal on the second half of a call reaches disk")
    func aDismissalOnTheSecondHalfOfACallReachesDisk() async throws {
        try await Self.aDismissalOnTheSecondHalfReachesDisk()
    }

    @Test("a name the user cleared is not proposed again")
    func aNameTheUserClearedIsNotProposedAgain() async throws {
        try await Self.aClearedNameIsNotProposedAgain()
    }

    @Test("accepting a suggestion names the speaker as a person would")
    func acceptingASuggestionNamesTheSpeakerAsAPersonWould() async throws {
        try await Self.acceptingASuggestionNamesLikeAPerson()
    }

    @Test("a suggestion turned down is not offered again")
    func aSuggestionTurnedDownIsNotOfferedAgain() async throws {
        try await Self.aDismissedSuggestionStaysDismissed()
    }

    @Test("the window opens a meeting that no filter is showing")
    func theWindowOpensAMeetingThatNoFilterIsShowing() async throws {
        try await Self.aFilteredOutMeetingStillOpens()
    }

    @Test("clusters the meeting client gave one person are one chip")
    func clustersTheMeetingClientGaveOnePersonAreOneChip() async throws {
        try await Self.oneAccountIsOneChip()
    }

    @Test("naming that chip writes every cluster behind it")
    func namingThatChipWritesEveryClusterBehindIt() async throws {
        try await Self.namingOneChipWritesEveryClusterBehindIt()
    }

    @Test("the chip keeps the person a shorter cluster was linked to")
    func theChipKeepsThePersonAShorterClusterWasLinkedTo() async throws {
        try await Self.theChipKeepsTheIdentityOffAShorterCluster()
    }

    @Test("the list counts the voices a meeting has not named")
    func theListCountsTheVoicesAMeetingHasNotNamed() async throws {
        try await Self.unnamedVoicesReachTheList()
    }

    @Test("the meeting the pane is showing stays selected when the list is read again")
    func theMeetingThePaneIsShowingStaysSelectedWhenTheListIsReadAgai() async throws {
        try await Self.selectionSurvivesAReload()
    }

    @Test("a name set on a speaker reaches the list without reopening the window")
    func aNameSetOnASpeakerReachesTheListWithoutReopeningTheWindow() async throws {
        try await Self.aNewNameReachesTheList()
    }

    @Test("a title typed into the pane reaches the list")
    func aTitleTypedIntoThePaneReachesTheList() async throws {
        try await Self.aNewTitleReachesTheList()
    }

    @Test("a title committed with Return reaches the list too")
    func aTitleCommittedWithReturnReachesTheListToo() async throws {
        try await Self.aCommittedTitleReachesTheList()
    }

    @Test("a meeting recorded while the window is open joins the search index")
    func aMeetingRecordedWhileTheWindowIsOpenJoinsTheSearchIndex() async throws {
        try await Self.aLaterMeetingJoinsTheSearchIndex()
    }

    @Test("the pane catches up with a meeting that finished while it was closed")
    func thePaneCatchesUpWithAMeetingThatFinishedWhileItWasClosed() async throws {
        try await Self.theOpenPaneCatchesUp()
    }

    @Test("a rewritten transcript is searchable by the words it holds now")
    func aRewrittenTranscriptIsSearchableByTheWordsItHoldsNow() async throws {
        try await Self.searchFollowsARewrittenTranscript()
    }

    @Test("a meeting transcribed after the list was read joins the search index")
    func aMeetingTranscribedAfterTheListWasReadJoinsTheSearchIndex() async throws {
        try await Self.aLaterTranscriptJoinsTheSearchIndex()
    }

    @Test("a rebuilt transcript is searchable by the words it holds now")
    func aRebuiltTranscriptIsSearchableByTheWordsItHoldsNow() async throws {
        try await Self.searchFollowsARebuild()
    }

    @Test("a correction on the second half of a call reaches the conversation's row")
    func aCorrectionOnTheSecondHalfOfACallReachesTheConversationSRow() async throws {
        try await Self.aFoldedHalfReachesTheConversationsRow()
    }

    @Test("a receipt leaves out the lines a person had already set")
    func aReceiptLeavesOutTheLinesAPersonHadAlreadySet() async throws {
        try await Self.aReceiptLeavesOutLinesAPersonSet()
    }

    @Test("a receipt leaves out a line corrected a moment earlier")
    func aReceiptLeavesOutALineCorrectedAMomentEarlier() async throws {
        try await Self.aReceiptLeavesOutAFreshCorrection()
    }

    @Test("naming a speaker reports the lines of the recording it changed")
    func namingASpeakerReportsTheLinesOfTheRecordingItChanged() async throws {
        try await Self.aReceiptCountsOneRecordingsLines()
    }

    @Test("search finds a word said after the call dropped and was rejoined")
    func searchFindsAWordSaidAfterTheCallDroppedAndWasRejoined() async throws {
        try await Self.searchReachesBothHalvesOfACall()
    }

    @Test("a transcript that will not decode still leaves the meeting in the list")
    func aTranscriptThatWillNotDecodeStillLeavesTheMeetingInTheList() async throws {
        try await Self.aCorruptTranscriptKeepsItsRow()
    }

    @Test("a change to a meeting the pane is not showing still reaches its row")
    func aChangeToAMeetingThePaneIsNotShowingStillReachesItsRow() async throws {
        try await Self.anotherMeetingsRowKeepsUp()
    }

    @Test("combining takes the folded recording's row out of the list")
    func combiningTakesTheFoldedRecordingSRowOutOfTheList() async throws {
        try await Self.combiningTakesTheFoldedRowOutOfTheList()
    }

    @Test("separating gives the later recording its row and its words back")
    func separatingGivesTheLaterRecordingItsRowAndItsWordsBack() async throws {
        try await Self.separatingRestoresTheRowAndTheIndex()
    }

    @Test("a cluster that says almost nothing is not counted as work to do")
    func aClusterThatSaysAlmostNothingIsNotCountedAsWorkToDo() async throws {
        try await Self.aSilentClusterIsNotWorkToDo()
    }

    @Test("a call recorded in two halves reports the voices in both")
    func aCallRecordedInTwoHalvesReportsTheVoicesInBoth() async throws {
        try await Self.bothHalvesReachTheRow()
    }

    @Test("the strip offers a chip for every voice the list counts")
    func theStripOffersAChipForEveryVoiceTheListCounts() async throws {
        try await Self.theStripCoversWhatTheListCounts()
    }

    @Test("naming the voice heard after a rejoin writes that half's map")
    func namingTheVoiceHeardAfterARejoinWritesThatHalfSMap() async throws {
        try await Self.namingTheSecondHalfWritesItsOwnMap()
    }

    @Test("the microphone track is not a voice waiting for a name")
    func theMicrophoneTrackIsNotAVoiceWaitingForAName() async throws {
        try await Self.theMicrophoneTrackIsNotUnnamed()
    }

    @Test("naming a speaker on a folded half drops the conversation's words")
    func namingASpeakerOnAFoldedHalfDropsTheConversationSWords() async throws {
        try await Self.namingOnAFoldedHalfDropsTheConversationsWords()
    }

    @Test("a read in flight does not put back words a rewrite has replaced")
    func aReadInFlightDoesNotPutBackWordsARewriteHasReplaced() async throws {
        // The archive-wide read holds the transcript as it was before
        // the rewrite. Merging it back, with the meeting marked as
        // covered, left search answering from the old file for the life
        // of the window, because nothing asks again for a meeting the
        // index believes it holds.
        #expect(
            MeetingsDirectoryFilter.admissible(
                read: ["a": "old words", "b": "untouched"], droppedWhileReading: ["a"]
            ) == ["b": "untouched"]
        )
        #expect(
            MeetingsDirectoryFilter.admissible(
                read: ["a": "words"], droppedWhileReading: []
            ) == ["a": "words"],
            "and an ordinary read is kept whole"
        )
    }

    @Test("moving a meeting to the Trash takes every folder it was recorded in")
    func movingAMeetingToTheTrashTakesEveryFolderItWasRecordedIn() async throws {
        try await Self.trashingMovesEveryFolder()
    }

    @Test("archiving takes the row out of the list and leaves the files alone")
    func archivingTakesTheRowOutOfTheListAndLeavesTheFilesAlone() async throws {
        try await Self.archivingKeepsTheFiles()
    }

    @Test("a right-click acts on the row under the pointer, not the selection")
    func aRightClickActsOnTheRowUnderThePointerNotTheSelection() async throws {
        try await Self.aRightClickActsOnTheRowUnderIt()
    }

    @Test("trashing a meeting stops its voices counting it")
    func trashingAMeetingStopsItsVoicesCountingIt() async throws {
        try await Self.trashingDropsTheOccurrences()
    }

    @Test("a folder that will not move keeps its row and its occurrences")
    func aFolderThatWillNotMoveKeepsItsRowAndItsOccurrences() async throws {
        try await Self.aFolderThatWillNotMoveKeepsItsRow()
    }

    @Test("archiving survives the next write to the meeting's metadata")
    func archivingSurvivesTheNextWriteToTheMeetingSMetadata() async throws {
        try await Self.archivingSurvivesAMetadataWrite()
    }

    @Test("archiving writes what was typed into the pane before it closes it")
    func archivingWritesWhatWasTypedIntoThePaneBeforeItClosesIt() async throws {
        try await Self.archivingSavesTheEdit()
    }

    @Test("the footer counts the meetings the filter holds")
    func theFooterCountsTheMeetingsTheFilterHolds() async throws {
        try await Self.theFooterCountsWhatTheFilterHolds()
    }

    @Test("what the move could not do is said one cause at a time")
    func whatTheMoveCouldNotDoIsSaidOneCauseAtATime() async throws {
        // Every refusal used to read as a recording in progress, which
        // sent the reader looking for a call that had already ended.
        #expect(MeetingsWindowModel.problemText(recording: nil, failed: []) == nil)
        let one = try #require(MeetingsWindowModel.problemText(recording: "Standup", failed: []))
        #expect(one.contains("Standup is being recorded"), "got \(one)")
        let other = try #require(MeetingsWindowModel.problemText(recording: nil, failed: ["Design review"]))
        #expect(
            other.contains("would not move") && !other.contains("being recorded"),
            "a folder that would not move is not a recording. got \(other)"
        )
        let both = try #require(MeetingsWindowModel.problemText( recording: "Standup", failed: ["Design review"]))
        #expect(both.contains("Standup") && both.contains("Design review"))
        let volume = try #require(MeetingsWindowModel.problemText( recording: nil, failed: [], noTrash: ["Design review"]))
        #expect(
            volume.contains("volume with no Trash"),
            "a share with no Trash is not a fault on one meeting. got \(volume)"
        )
    }

    @Test("a row names the day when its heading does not")
    func aRowNamesTheDayWhenItsHeadingDoesNot() async throws {
        // Only Today and Yesterday name a day. Under a month heading a
        // clock time alone left no way to tell which day a meeting was
        // without opening it.
        let now = date("2026-08-24 15:00:00")
        let calendar = RuntimeFixtures.calendar
        for (moment, why) in [
            (date("2026-08-24 14:15:00"), "today"),
            (date("2026-08-23 09:32:00"), "yesterday"),
        ] {
            #expect(
                Format.listDate(moment, now: now, calendar: calendar) == Format.timeOfDay(moment),
                Comment(rawValue: why)
            )
        }
        let older = Format.listDate(
            date("2026-07-31 16:00:00"), now: now, calendar: calendar
        )
        #expect(
            older != Format.timeOfDay(date("2026-07-31 16:00:00")),
            "and anything older carries its date"
        )
        #expect(older.contains("31"), "which names the day: got \(older)")
    }
}
