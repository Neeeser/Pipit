import Foundation

/// Attributes speech from what the meeting client reported.
///
/// The sensor timeline is an observation, not a prediction: the client marked
/// who held the floor while the audio was recorded. The diarizer hears the
/// audio, so where a cluster reaches a word the cluster labels it. The sensor
/// fills the words no cluster reaches, and `attribute` gives the clusters the
/// participants' names. A one-to-one call is the exception: the far-end track
/// holds only that one person, so the sensor labels all of it.
///
/// Three products, all pure so they can be tested without audio or a meeting.
///
/// - `wordIntervals` turns the timeline into intervals the transcript assembler
///   aligns words against, keyed on the platform's participant identifier.
/// - `enrollmentIntervals` picks the stretches safe to embed as one person's
///   voice, for the profile that recognises them next time.
/// - `attribute` matches diarization clusters to participants, which names the
///   fallback stretches: a cluster whose turns point at one person names that
///   person's uncovered words too.
///
/// Every rule below exists to make a wrong answer read as no answer. A blank
/// name asks to be filled in; a confident wrong one does not.
public enum SensorAttribution {
    public struct Match: Sendable, Equatable {
        public var clusterID: String
        public var participantID: String
        public var displayName: String?
        /// Share of the cluster's speech the winning participant held.
        public var coverage: Double

        public init(
            clusterID: String, participantID: String,
            displayName: String?, coverage: Double
        ) {
            self.clusterID = clusterID
            self.participantID = participantID
            self.displayName = displayName
            self.coverage = coverage
        }
    }

    public struct Result: Sendable, Equatable {
        public var matches: [Match]
        /// Share of all diarized speech that any turn covered. The guard against
        /// two clocks that disagree.
        public var coverage: Double

        public init(matches: [Match] = [], coverage: Double = 0) {
            self.matches = matches
            self.coverage = coverage
        }
    }

    /// The sensor timeline as it labels words, in the two roles it can play.
    public struct WordSources: Sendable, Equatable {
        /// One participant owns the whole far-end track, so every word is
        /// theirs whatever the diarizer says. Empty unless the client named the
        /// only other person in the call.
        public var authoritative: [DiarizationInterval]
        /// The turns, which label only the words no diarization interval
        /// reaches. See `TranscriptAssembler.assignSpans` for why they do not
        /// outrank the diarizer.
        public var turns: [DiarizationInterval]

        public static let none = WordSources(authoritative: [], turns: [])

        /// The turns refiled under the diarization cluster each person is
        /// matched to, where they are matched to one.
        ///
        /// A turn fills the words no cluster interval reaches, and those words
        /// are the same person's as the cluster that `attribute` names after
        /// them. Filing them under a key of their own showed the person twice:
        /// once as the cluster and once as a sensor speaker. A person with no
        /// matched cluster keeps the sensor key, which is the only one they
        /// have. `owners` maps a participant to the cluster key to use.
        public func rekeyed(owners: [String: String]) -> WordSources {
            guard !owners.isEmpty else { return self }
            let moved = turns.map { turn -> DiarizationInterval in
                guard let id = SpeakerLabel.sensorParticipantID(from: turn.clusterID),
                    let cluster = owners[id]
                else { return turn }
                return DiarizationInterval(
                    start: turn.start, end: turn.end, clusterID: cluster, quality: turn.quality
                )
            }
            return WordSources(authoritative: authoritative, turns: moved)
        }

        public var isEmpty: Bool { authoritative.isEmpty && turns.isEmpty }

        /// The same intervals moved onto a chunk's own clock.
        public func shifted(by offset: Double) -> WordSources {
            func move(_ intervals: [DiarizationInterval]) -> [DiarizationInterval] {
                intervals.map {
                    DiarizationInterval(
                        start: $0.start - offset, end: $0.end - offset,
                        clusterID: $0.clusterID, quality: $0.quality
                    )
                }
            }
            return WordSources(authoritative: move(authoritative), turns: move(turns))
        }
    }

    /// A cluster takes a participant's name when that participant's turns
    /// cover this share of the cluster's speech and hold
    /// `minimumCoveredShare` of the speech any turn covers in it.
    ///
    /// The client marks one floor holder at a time and holds the mark while
    /// several tiles move at once, so on a call where people talk over each
    /// other its turns reach only part of each voice. In the simulated Meet
    /// calls with the most overlap (each far-end person talked over for 58 to
    /// 75% of their speech) the right person's turns covered 28 to 45% of
    /// the large clusters, each one person's voice, 32 to 45% of each cluster
    /// sat under no turn, and a bar of half the cluster left every far-end
    /// word in those calls unnamed.
    public static let minimumClusterCoverage: Double = 0.25
    /// The share of the speech the turns cover in a cluster that the named
    /// participant must hold.
    ///
    /// With the coverage bar this low, the turns that do reach a cluster have
    /// to agree. Against one rival the margin already demands more than this;
    /// the share decides where turns of three or more people reach the
    /// cluster, as when a tile that flickers on from background noise cuts
    /// into everyone's turns. In a replay of the simulated calls with such a
    /// tile on for a second every five seconds, the bar without this share
    /// put wrong names on two clusters and this rule on none. Neither rule
    /// survives a tile on half the time: with two seconds of every four the
    /// half-cluster rule misnamed 17 of 33 clusters and this one 27 of 44.
    public static let minimumCoveredShare: Double = 0.5
    /// How much a turn of the local user counts against a participant. The
    /// local user is not in the far-end mixdown and talks over the far end
    /// all the time, so their turn says little about whose voice a far-end
    /// cluster is. Half weight rather than none, because a cluster the local
    /// user's turns explain best must stay blank (see `attribute`), and
    /// dropping their turns would let second place win it outright.
    public static let selfTurnWeight: Double = 0.5
    /// The bar voice enrolment keeps, and `strict-names` names with: half of
    /// the whole cluster, with the local user's turns at full weight.
    ///
    /// Enrolment stays here because a wrong name on a cluster shows once and
    /// a person can correct it, while a wrong voice in a profile carries the
    /// mistake into every later meeting. The thresholds were set after a
    /// wrong name was enrolled against someone's voice.
    public static let enrollmentClusterCoverage: Double = 0.5
    /// Under either rule, the winner must hold this much more than the
    /// runner-up. Two people splitting a cluster evenly means the diarizer
    /// merged them, and picking the longer half would be a coin flip dressed
    /// as a decision.
    public static let minimumMargin: Double = 1.5
    /// Below this share of speech covered, the two clocks do not describe the
    /// same call and nothing is named.
    public static let minimumTimelineCoverage: Double = 0.15
    /// Seconds of solo, sensor-owned speech a participant needs before their
    /// voice is embedded. Below ten seconds a genuine-score comparison is
    /// unreliable, and a profile seeded from a cough misidentifies its owner.
    public static let minimumEnrollmentSeconds: Double = 6
    /// How much of a turn's end is conceded to the diarizer when attributing
    /// words.
    ///
    /// A turn's end is where the client's indicator moved, sampled at 0.5 s and
    /// released after the voice stopped, so the words at the tail can be the
    /// next speaker's first words. Inside this margin the diarizer decides,
    /// because it hears the voice change.
    ///
    /// Measured against a reference diarization: on the Aug 31 2:14 PM huddle
    /// the client's turn boundaries trail the voice by a median of 1.2 s with a
    /// 90th percentile of 2.6 s, and 27 of 32 matched transitions run late. One
    /// second was inside that, so the tail routinely kept words the next person
    /// said.
    ///
    /// A turn shorter than this now yields nothing rather than half of itself.
    /// The half-turn cap was meant to protect the head of a quick exchange,
    /// where the sensor is the thing that is right, but a turn shorter than the
    /// release is late by more than its own length, so the half that survived
    /// was the previous speaker still talking. A one-second turn at 27.29 s kept
    /// 0.5 s and put "I'm glad we" on the wrong person in the middle of
    /// somebody else's sentence.
    ///
    /// On the words the sensor still claims, so the diarizer's own accuracy is
    /// not in the denominator, this takes attribution from 93.5% to 97.6%
    /// against the reference. The diarizer alone scores 96.6% under the same
    /// harness: the sensor used to be worse than the thing it overrides and is
    /// now better. Whole-transcript accuracy goes 93.4% to 96.3%, with the words
    /// handed to the diarizer rising from 436 to 864.
    ///
    /// Two seconds is a choice rather than a floor. Wrong words run 288, 207,
    /// 174, 167, 160 across tails of 1.0 to 3.0 while right words run 4499,
    /// 4540, 4526, 4503, 4487, so past 2.0 the net is nearly flat and 2.5 is
    /// about as defensible. This keeps the most sensor contribution at the point
    /// where it becomes trustworthy.
    ///
    /// One constant for every client, and Meet was measured rather than assumed.
    /// Its turns are much shorter, a median of 1.5 s against Slack's 2.5 to
    /// 11.5, and 60% of them are inside this concession, so the same number
    /// discards far more of them. It still helps: on the Sep 01 standup, scored
    /// the same way, 83.3% becomes 86.9%, improving monotonically to 2.5 exactly
    /// as it does on Slack. A per-source constant would buy little and would
    /// have to justify two numbers instead of one.
    public static let wordAttributionTailSeconds: Double = 2

    /// How long one turn may run before it stops being an observation.
    ///
    /// A turn says the client marked somebody as holding the floor between two
    /// readings that said so. An indicator that has not moved in five minutes is
    /// more likely stuck than accurate, and a stuck one is not a small error: a
    /// Meet recording produced two turns for a twenty-two minute call, one of
    /// them 863 seconds, and every remote word went to whoever held it while the
    /// diarizer had cleanly separated three voices underneath.
    ///
    /// The longest turn anybody genuinely held, across all eight recordings on
    /// disk with a sensor timeline, is 128 seconds, and the 95th percentiles run
    /// from 19 to 62 seconds. This sits 2.3x above the longest of those and 2.9x
    /// below the stuck one. Applying it changes nothing on any of the seven
    /// healthy recordings, in either word attribution or enrolment.
    ///
    /// A genuine monologue past this loses very little. `attribute` reads the
    /// turns whole, so the speaker's cluster is still matched and still named;
    /// what changes is that the words go to the diarizer, which on one voice
    /// returns that same cluster carrying that same name. Enrolment does lose
    /// the audio, and a person who talks for five unbroken minutes has other
    /// turns to be enrolled from.
    ///
    /// The sample is 15 to 48 minute meetings. Nothing here is validated against
    /// a two-hour all-hands with a single presenter.
    public static let maximumFloorSeconds: Double = 300

    /// Whether a turn is short enough to be a claim about who was speaking.
    static func isFloorObservation(_ turn: SensorTurn) -> Bool {
        turn.duration <= maximumFloorSeconds
    }

    static func attributableEnd(of turn: SensorTurn) -> Double {
        max(turn.start, turn.end - wordAttributionTailSeconds)
    }

    /// The one person the far-end track can hold, where the meeting client
    /// named the whole call and there is one other person in it.
    ///
    /// The far end is a mixdown of everyone but the local user, so a call with
    /// one other person in it holds one voice from beginning to end. Nothing
    /// acoustic has to be worked out: every word on that track is theirs,
    /// including the ones the diarizer never marked as speech.
    ///
    /// It refuses those it has to. The diarizer drops any segment shorter than
    /// a second, so a one-to-one huddle of 10 September 2026 left 82 seconds of
    /// `Mm-hmm` and `Okay` with no name on them and split the rest of the call
    /// into two speakers, one of which was 73 seconds of the same person cut
    /// off the head and tail of their own sentences. Three rows for two people,
    /// and a sixth of what the other person said filed under neither.
    ///
    /// Only where the local user is known, so exactly one tile is marked: by the
    /// client's own flag (Slack's tile identifier says it outright), by the
    /// English "You" Meet writes on the local tile, or by the microphone, which
    /// `RawSensors.markingSelf` applies before this is asked. A roster that
    /// marks nobody could hold the local user as the other person, and their
    /// words would be given to somebody else here, which is the one mistake
    /// this must not make. A third person joining, even briefly, appears in the
    /// roster and ends the one-to-one reading, because the track is no longer
    /// one voice.
    public static func soleRemoteParticipant(sensors: RawSensors) -> SensorParticipant? {
        guard sensors.participants.filter(\.isSelf).count == 1 else { return nil }
        let others = sensors.participants.filter { !$0.isSelf }
        guard others.count == 1, let only = others.first, only.personName != nil else {
            return nil
        }
        // And the client saw them hold the floor at least once. Without it a
        // call the other person sat silent through still produces a speaker
        // keyed to them with no line under it, which `speakerEntries` exists to
        // refuse: a name offered for a voice with no audio behind it.
        guard sensors.turns.contains(where: { $0.participantID == only.id }) else { return nil }
        return only
    }

    /// The last moment the client was still answering about this call.
    ///
    /// A roster is a reading, and a reader that stops answering leaves the
    /// last one it gave standing. `SensorTimeline` already closes an open turn
    /// where the readings stop rather than at the end of the recording, for the
    /// same reason: a call can run for an hour after the client goes quiet.
    /// Nothing past the last turn was observed, so nothing past it is claimed.
    ///
    /// Every turn counts here, including one too long to be a claim about who
    /// held the floor. The question is when the client last said anything at
    /// all, and a stuck indicator still says the client was there. Reading only
    /// the ones `isFloorObservation` keeps put the bound at 20 seconds on a
    /// one-to-one walkthrough where the other person then talked for fifteen
    /// minutes, and handed all fifteen back to the diarizer.
    static func lastObservation(sensors: RawSensors) -> Double? {
        sensors.turns.map(\.end).max()
    }

    /// The sensor timeline as intervals the assembler can align words against.
    ///
    /// Keyed with `SpeakerLabel.sensor`, so speech lands on the platform's own
    /// identifier for the person rather than on a cluster that a re-analysis
    /// renumbers.
    ///
    /// The local user's turns are dropped, not because they are wrong but
    /// because the far-end track cannot contain them: it is a mixdown of
    /// everyone else. A span inside a self turn falls through to the diarizer,
    /// which hears the audio and is the right authority on speech the sensor
    /// cannot explain.
    public static func wordSources(
        sensors: RawSensors, mode: SensorAttributionMode = .current
    ) -> WordSources {
        // The client names clusters and labels no word itself.
        if mode == .diarizerNames { return .none }
        // One other person in the call, so the track holds them and the turns
        // are not needed to say which stretches. An interval per turn would
        // leave everything between them to the diarizer, which is where the
        // backchannels and the split sentences were being lost.
        //
        // Bounded by the last reading rather than run to the end of the track.
        // A roster of two is a claim about the call the client could still see,
        // and a reader that stops answering keeps the last roster it gave: a
        // third person joining after that would have twenty minutes of their
        // speech rendered, exported and offered for voice confirmation under
        // somebody else's name, where the diarizer would at least have given
        // them a cluster of their own. Past the last reading the diarizer
        // decides again.
        //
        // It costs almost nothing where the client keeps answering. Across the
        // five one-to-one huddles on disk the last turn ends at 99.3% to 99.8%
        // of the recording, so what falls back is the last two to ten seconds.
        if let only = soleRemoteParticipant(sensors: sensors),
            let until = lastObservation(sensors: sensors), until > 0
        {
            return WordSources(
                authoritative: [
                    DiarizationInterval(
                        start: 0, end: until,
                        clusterID: SpeakerLabel.sensor(participantID: only.id)
                    )
                ], turns: [])
        }
        let selfIDs = Set(sensors.participants.filter(\.isSelf).map(\.id))
        // Only a participant this build can name. `speakerEntries` already
        // refuses to make a speaker out of one it cannot, so a turn kept here
        // without a name produces words belonging to a speaker that does not
        // exist: they render as `Participant`, and the diarizer's own cluster
        // for the same audio, which a voice profile can still name, is dropped
        // in favour of them. Measured after the icon-ligature refusal landed,
        // that is a transcript of named lines cut apart by nameless fragments.
        //
        // Leaving those words to the diarizer loses the client's word on who
        // held the floor, which is better evidence than acoustics. It is worth
        // less than nothing while there is no name to put on it.
        let named = Set(
            sensors.participants.filter { $0.personName != nil }.map(\.id)
        )
        let turns = sensors.turns
            .filter {
                !selfIDs.contains($0.participantID)
                    && named.contains($0.participantID)
                    && isFloorObservation($0)
            }
            .compactMap { turn -> DiarizationInterval? in
                // The tail belongs to the diarizer. A turn the concession eats
                // whole vanishes with it, which is the point: it is shorter than
                // the indicator's own release, so all of it is late.
                let end = attributableEnd(of: turn)
                guard end > turn.start else { return nil }
                return DiarizationInterval(
                    start: turn.start, end: end,
                    clusterID: SpeakerLabel.sensor(participantID: turn.participantID)
                )
            }
            .sorted { $0.start < $1.start }
        return WordSources(authoritative: [], turns: turns)
    }

    /// Both tiers as one list, for a caller that does not care which is which.
    public static func wordIntervals(
        sensors: RawSensors, mode: SensorAttributionMode = .current
    ) -> [DiarizationInterval] {
        let sources = wordSources(sensors: sensors, mode: mode)
        return sources.authoritative + sources.turns
    }

    /// The stretches safe to embed as one participant's voice.
    ///
    /// Three facts have to agree before a second of audio reaches a profile.
    /// The turn says the client heard this person holding the floor. The
    /// matched clusters, found under the strict coverage and margin guards
    /// (`enrollmentClusterCoverage`),
    /// say which diarized voices those turns dominate, and there can be more
    /// than one: the clusterer is tuned to split a speaker rather than merge
    /// two people. And `soloSpeech` says nobody talked over it. The
    /// intersection of all three is embedded.
    ///
    /// The cluster restriction is not decoration. A turn's end trails the
    /// voice by up to the indicator's release, so its tail can cover the next
    /// speaker's first words: solo speech of a *different* cluster inside the
    /// turn is exactly that tail, and folding it into this person's centroid
    /// puts somebody else's voice in their profile. A participant whose turns
    /// dominate no cluster enrolls nothing.
    ///
    /// Returned keyed with `SpeakerLabel.sensor`, on the meeting timeline.
    /// Participants below `minimumEnrollmentSeconds` of usable audio are left
    /// out entirely rather than enrolled from a fragment.
    public static func enrollmentIntervals(
        sensors: RawSensors, diarized: [DiarizationInterval]
    ) -> [DiarizationInterval] {
        let selfIDs = Set(sensors.participants.filter(\.isSelf).map(\.id))
        // Every cluster a participant's turns dominate, not one. The clusterer
        // is tuned to split a speaker rather than merge two people, so one
        // voice landing in two clusters is the expected case, and keeping only
        // one of them threw away most of that person's enrollable audio.
        var clustersOf: [String: Set<String>] = [:]
        for match in attribute(intervals: diarized, sensors: sensors, mode: .strictNames).matches {
            clustersOf[match.participantID, default: []].insert(match.clusterID)
        }
        let solo = DiarizationInterval.soloSpeech(diarized)
        var byParticipant: [String: [DiarizationInterval]] = [:]
        for turn in sensors.turns
        where !selfIDs.contains(turn.participantID) && isFloorObservation(turn) {
            guard let clusters = clustersOf[turn.participantID] else { continue }
            for interval in solo where clusters.contains(interval.clusterID) {
                let start = max(turn.start, interval.start)
                let end = min(turn.end, interval.end)
                guard end > start else { continue }
                byParticipant[turn.participantID, default: []].append(
                    DiarizationInterval(
                        start: start, end: end,
                        clusterID: SpeakerLabel.sensor(participantID: turn.participantID)
                    )
                )
            }
        }
        var out: [DiarizationInterval] = []
        for (_, intervals) in byParticipant {
            let total = intervals.reduce(0) { $0 + $1.duration }
            guard total >= minimumEnrollmentSeconds else { continue }
            out.append(contentsOf: intervals)
        }
        return out.sorted { $0.start < $1.start }
    }

    /// The speaker-map entries behind the sensor keys word attribution writes.
    ///
    /// One entry per non-self participant whose speech survived attribution and
    /// whose name the client rendered. A participant the client never named gets
    /// no entry: the key still appears in the transcript, renders through the
    /// fallback, and waits for a person to fill it in.
    ///
    /// Keyed on the intervals rather than on the turns. Holding a turn is not
    /// the same as keeping one now that the concession can eat a short turn
    /// whole and the ceiling can refuse a long one, and an entry for a key no
    /// utterance uses is not harmless: it reaches the folder's people list and
    /// the enrichment prompt, and the control that confirms a voice offers a
    /// name with no audio behind it.
    public static func speakerEntries(
        sensors: RawSensors, mode: SensorAttributionMode = .current,
        diarization: RawDiarization? = nil
    ) -> [(key: String, assignment: SpeakerAssignment)] {
        // A participant whose turns fill words under a cluster key has no
        // utterance under a sensor key, so no entry is made for it.
        var owned: Set<String> = []
        if mode != .sensorFirst, let run = diarization?.activeRun(track: .remote) {
            owned = Set(
                clusterOwners(intervals: run.intervals, sensors: sensors, mode: mode).keys)
        }
        let kept = Set(
            wordIntervals(sensors: sensors, mode: mode).compactMap {
                SpeakerLabel.sensorParticipantID(from: $0.clusterID)
            }
        ).subtracting(owned)
        return kept.sorted().compactMap { id in
            guard let name = sensors.participant(id)?.personName else { return nil }
            return (
                key: SpeakerLabel.sensor(participantID: id),
                assignment: SpeakerAssignment(
                    displayName: name,
                    origin: .sensor,
                    participantID: id,
                    provenance: SpeakerProvenance(source: .sensor)
                )
            )
        }
    }

    /// The namespace a platform identifier is durable under, or nil where it
    /// does not outlive one meeting.
    ///
    /// Only Slack today. Its user id is workspace-unique and survives every
    /// meeting, so a handle bound once keeps naming that person. Meet's
    /// `spaces/{space}/devices/{n}` is per-conference: a stored handle never
    /// matches a later meeting, and a row that cannot match again only
    /// misleads. Zoom exposes no identifier at all, so its name-keyed ids are
    /// already the display name and a handle would add nothing to it.
    public static func handleProvider(source: String) -> String? {
        source.hasPrefix("slack") ? "slack" : nil
    }

    /// The diarization cluster each participant is matched to, by participant
    /// identifier, as the key `attribute` names it under.
    ///
    /// A participant matched to no cluster takes the one their turns overlap
    /// most, where they overlap any.
    ///
    /// A participant can be matched to several clusters, because the clusterer
    /// is tuned to split a voice rather than merge two people. The one holding
    /// the most speech stands for them: the words a turn fills go there. Ties
    /// break on the cluster identifier so the result does not depend on
    /// dictionary order.
    public static func clusterOwners(
        intervals: [DiarizationInterval], sensors: RawSensors,
        mode: SensorAttributionMode = .current
    ) -> [String: String] {
        var seconds: [String: Double] = [:]
        for interval in intervals { seconds[interval.clusterID, default: 0] += interval.duration }
        var best: [String: (cluster: String, seconds: Double)] = [:]
        for match in attribute(intervals: intervals, sensors: sensors, mode: mode).matches {
            let held = seconds[match.clusterID] ?? 0
            if let current = best[match.participantID],
                current.seconds > held || (current.seconds == held && current.cluster < match.clusterID)
            {
                continue
            }
            best[match.participantID] = (match.clusterID, held)
        }
        var owners = best.mapValues(\.cluster)
        // A participant no cluster passes the naming guard for still has
        // words a turn fills, and filing them under a key of their own shows
        // the person twice. They go to the cluster holding the largest share
        // of their turns, which names nothing: naming keeps its guards. Only
        // a participant whose turns overlap no cluster keeps the sensor key.
        let selfIDs = Set(sensors.participants.filter(\.isSelf).map(\.id))
        var overlap: [String: [String: Double]] = [:]
        for turn in sensors.turns where isFloorObservation(turn) && !selfIDs.contains(turn.participantID) {
            guard owners[turn.participantID] == nil else { continue }
            for interval in intervals {
                let shared = min(interval.end, turn.end) - max(interval.start, turn.start)
                if shared > 0 {
                    overlap[turn.participantID, default: [:]][interval.clusterID, default: 0] += shared
                }
            }
        }
        for (participant, byCluster) in overlap {
            let ranked = byCluster.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            if let top = ranked.first { owners[participant] = top.key }
        }
        return owners
    }

    public static func attribute(
        intervals: [DiarizationInterval], sensors: RawSensors,
        mode: SensorAttributionMode = .current
    ) -> Result {
        // The local user is not in the far-end mixdown, so they are not one of
        // the voices to be found there. Their turns stay in the overlap below,
        // where they can still stop somebody else's name landing on the local
        // user's speech, but they never become a name.
        let selfIDs = Set(sensors.participants.filter(\.isSelf).map(\.id))
        // The same ceiling word attribution applies. Refusing a stuck turn
        // there and honouring it here was worse than doing neither: the words
        // moved onto cluster keys and those clusters were still named from the
        // turn that had just been refused, so a recording that read one wrong
        // name went on reading it under a different key.
        //
        // What a genuine monologue loses is its name, where that monologue is
        // the only turn its speaker held. That is the honest answer: a client
        // whose indicator did not move for five minutes did not observe who was
        // talking, and an unnamed speaker asks to be filled in.
        let turns = sensors.turns.filter(isFloorObservation)

        guard !intervals.isEmpty, !turns.isEmpty else {
            return Result(coverage: 0)
        }

        var perCluster: [String: [String: Double]] = [:]
        var clusterSeconds: [String: Double] = [:]
        var totalSpeech: Double = 0
        var totalCovered: Double = 0

        for interval in intervals {
            let length = interval.duration
            guard length > 0 else { continue }
            totalSpeech += length
            clusterSeconds[interval.clusterID, default: 0] += length
            for turn in turns {
                let overlap = min(interval.end, turn.end) - max(interval.start, turn.start)
                guard overlap > 0 else { continue }
                perCluster[interval.clusterID, default: [:]][turn.participantID, default: 0] += overlap
                totalCovered += overlap
            }
        }

        let coverage = totalSpeech > 0 ? min(1, totalCovered / totalSpeech) : 0
        guard coverage >= minimumTimelineCoverage else {
            return Result(coverage: coverage)
        }

        var matches: [Match] = []
        for (clusterID, byParticipant) in perCluster {
            let seconds = clusterSeconds[clusterID] ?? 0
            guard seconds > 0 else { continue }
            let strict = mode == .strictNames
            let selfWeight = strict ? 1 : selfTurnWeight
            let weighted = byParticipant.map { key, value in
                (key: key, value: selfIDs.contains(key) ? value * selfWeight : value)
            }
            let ranked = weighted.sorted { lhs, rhs in
                // Ties broken by identifier so the result does not depend on
                // dictionary order.
                lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value
            }
            guard let winner = ranked.first else { continue }
            let runnerUp = ranked.dropFirst().first?.value ?? 0
            if strict {
                guard winner.value / seconds >= enrollmentClusterCoverage else { continue }
            } else {
                let covered = ranked.reduce(0) { $0 + $1.value }
                guard winner.value / seconds >= minimumClusterCoverage,
                    winner.value / covered >= minimumCoveredShare
                else { continue }
            }
            guard runnerUp == 0 || winner.value >= runnerUp * minimumMargin else { continue }
            // A cluster the local user best explains is a cluster this track
            // cannot contain, so it is left blank rather than handed to whoever
            // came second. Dropping their turns instead would have made the
            // runner-up zero and let second place win outright.
            guard !selfIDs.contains(winner.key) else { continue }
            matches.append(
                Match(
                    clusterID: clusterID,
                    participantID: winner.key,
                    displayName: sensors.participant(winner.key)?.personName,
                    coverage: min(1, winner.value / seconds)
                ))
        }
        matches.sort { $0.clusterID < $1.clusterID }
        return Result(matches: matches, coverage: coverage)
    }
}

extension SensorAttribution {
    /// The speaker-map entries a sensor record justifies for diarization
    /// clusters, keyed the way the map keys them.
    ///
    /// This is the fallback half of naming. Word attribution already put sensor
    /// keys on every span a turn covered; what remains keyed to a cluster is
    /// speech the sensor did not see. A cluster one person's turns dominate is
    /// still that person's voice where the readings went dark, so the name
    /// carries over to those stretches too.
    ///
    /// Pure on purpose. The decision of who gets named is the part worth testing,
    /// and keeping it out of the pipeline means it can be tested without audio,
    /// models or a meeting folder. The pipeline's remaining job is to apply
    /// these, which `SpeakerMap.applySuggestion` already governs.
    ///
    /// The local user is marked, not removed. The far-end track is a mixdown of
    /// everyone else, so a turn saying the local user held the floor cannot
    /// explain a voice heard there. Removing those turns looked equivalent and
    /// was not: it left the runner-up at zero, so the margin rule stopped
    /// guarding and second place won the cluster outright.
    /// The record arrives already marked: the pipeline reads it through
    /// `sensorRecord`, which is where the microphone evidence lives. Marking it
    /// again here would need evidence this has no reason to take.
    public static func assignments(
        diarization: RawDiarization, sensors: RawSensors,
        mode: SensorAttributionMode = .current
    ) -> [(key: String, assignment: SpeakerAssignment)] {
        let scoped = sensors
        guard !scoped.turns.isEmpty else { return [] }

        var out: [(key: String, assignment: SpeakerAssignment)] = []
        for run in diarization.activeRuns {
            var result = attribute(intervals: run.intervals, sensors: scoped, mode: mode)
            // Without the client labelling words, a one-to-one call reaches the
            // diarizer, which may split the one far-end voice into several
            // clusters. Whatever it finds on that track is the one other
            // person, so every cluster takes their name.
            if mode == .diarizerNames, run.track == .remote,
                let only = soleRemoteParticipant(sensors: scoped)
            {
                let clusters = Set(run.intervals.map(\.clusterID))
                result.matches = clusters.sorted().map {
                    Match(
                        clusterID: $0, participantID: only.id,
                        displayName: only.personName, coverage: 1
                    )
                }
            }
            for match in result.matches {
                let name = (match.displayName ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                // No name means the client never rendered one. The cluster stays
                // blank rather than taking an opaque platform identifier as a
                // display name.
                guard !name.isEmpty else { continue }
                let seconds = run.intervals
                    .filter { $0.clusterID == match.clusterID }
                    .reduce(0) { $0 + $1.duration }
                out.append(
                    (
                        key: SpeakerLabel.namespaced(chunkID: run.id, rawLabel: match.clusterID),
                        assignment: SpeakerAssignment(
                            displayName: name,
                            origin: .sensor,
                            confidence: match.coverage,
                            participantID: match.participantID,
                            provenance: SpeakerProvenance(
                                source: .sensor, score: match.coverage, speechSeconds: seconds
                            )
                        )
                    ))
            }
        }
        return out
    }
}
