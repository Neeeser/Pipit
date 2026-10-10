import Foundation

/// A person in the people list, as far as comparing names needs.
public struct KnownPerson: Sendable, Equatable {
    public var id: IdentityID
    public var name: String
    public var aliases: [String]

    public init(id: IdentityID, name: String, aliases: [String] = []) {
        self.id = id
        self.name = name
        self.aliases = aliases
    }

    /// Whether this person is called `candidate`, by their name or by an alias.
    public func answers(to candidate: String) -> Bool {
        PersonName.isSame(name, candidate) || aliases.contains { PersonName.isSame($0, candidate) }
    }

    /// Every name this person is known by.
    var names: [String] { [name] + aliases }
}

/// One cluster whose voice resolved to a named person at the high band.
public struct VoiceMatch: Sendable, Equatable {
    public var clusterKey: String
    public var person: KnownPerson
    public var confidence: Double?
    public var speechSeconds: Double
    public var provenance: SpeakerProvenance

    public init(
        clusterKey: String, person: KnownPerson, confidence: Double?,
        speechSeconds: Double, provenance: SpeakerProvenance
    ) {
        self.clusterKey = clusterKey
        self.person = person
        self.confidence = confidence
        self.speechSeconds = speechSeconds
        self.provenance = provenance
    }
}

/// A platform name to record as another name for a person.
public struct AliasRequest: Sendable, Equatable {
    public var identityID: IdentityID
    public var alias: String

    public init(identityID: IdentityID, alias: String) {
        self.identityID = identityID
        self.alias = alias
    }
}

/// Settles what a speaker is called when the meeting client and the voice
/// both have something to say.
///
/// The client gives a name for whoever held the floor, in the form the account
/// was created with. The voice gives a person from the people list, in the form
/// a human typed. They are two readings of the same speech, and the voice is
/// the better one when it is confident: a floor indicator follows whichever
/// tile Meet lit, which can be the wrong one, where a voice at the high band
/// has been right on every call that anyone checked. So a confident voice
/// outranks a client name that names somebody else, and where the two are
/// spellings of one person the client's spelling is recorded as an alias, so
/// the next meeting finds that person without a voice at all.
///
/// Only entries the client wrote on its own are touched. A name a person chose,
/// a platform account a person confirmed, and a name taken off a speaker on
/// purpose all stay as they are.
extension SpeakerMap {
    private enum Relation {
        /// The client's name is one this person answers to.
        case same
        /// A longer or shorter spelling of this person's name that no one else
        /// answers to. Plausible, not proven.
        case compatible
        /// Somebody else's name, or a name nothing in this person's names
        /// could be.
        case different
    }

    /// An entry the meeting client named and nobody has since confirmed.
    private func isPlatformEntry(_ key: String) -> Bool {
        guard let entry = entries[key], entry.origin == .sensor,
            entry.participantID != nil, entry.provenance?.humanVerified != true,
            !clearedKeys.contains(key)
        else { return false }
        return true
    }

    /// Judged on the names alone. An entry can carry an identity from an
    /// earlier pass while the client's name has been written back over it, and
    /// that identity says nothing about whether this name belongs to it.
    private func relation(
        of platformName: String, to person: KnownPerson, among people: [KnownPerson]
    ) -> Relation {
        if person.answers(to: platformName) { return .same }
        // Another known person owns this exact name, so it is not a spelling
        // of this one.
        if people.contains(where: { $0.id != person.id && $0.answers(to: platformName) }) {
            return .different
        }
        if person.names.contains(where: {
            PersonName.isCompatible(platform: platformName, stored: $0)
        }) {
            return .compatible
        }
        return .different
    }

    /// Gives a client-named speaker the person whose name it is, where exactly
    /// one person answers to it.
    ///
    /// Exact means the same string with case and diacritics ignored, against a
    /// name or an alias. A name two people answer to is left alone: picking
    /// one would be a guess dressed as a lookup. Returns how many entries took
    /// a person.
    @discardableResult
    public mutating func linkPlatformNames(to people: [KnownPerson]) -> Int {
        var linked = 0
        for key in entries.keys.sorted() where isPlatformEntry(key) {
            guard var entry = entries[key] else { continue }
            let owners = people.filter { $0.answers(to: entry.displayName) }
            guard owners.count == 1, let owner = owners.first else { continue }
            guard entry.identityID != owner.id || entry.displayName != owner.name else {
                continue
            }
            entry.displayName = owner.name
            entry.identityID = owner.id
            entry.provenance?.identityID = owner.id
            entries[key] = entry
            linked += 1
        }
        return linked
    }

    /// Reconciles client names with voice matches, and returns the aliases to
    /// record.
    ///
    /// Each match is judged on its own cluster. The client's name there is
    /// either one this person answers to, a plausible other spelling of their
    /// name, or somebody else's. The first two put the person's own name and
    /// identity on the speaker, and the second also asks for the alias. The
    /// third gives the speaker to the voice.
    ///
    /// The platform account behind that cluster carries speech the clusters do
    /// not cover, under its own `sensor_` key, so that key follows when every
    /// confident match for the account is one person. Two people matching
    /// within one account says the account's turns are mixed, and the key keeps
    /// the client's name. Clusters of the account that no voice judged keep it
    /// as well, unless they are the same person.
    public mutating func reconcilePlatformNames(
        with matches: [VoiceMatch], among people: [KnownPerson]
    ) -> [AliasRequest] {
        var aliases: [AliasRequest] = []
        var byAccount: [String: [VoiceMatch]] = [:]

        for match in matches.sorted(by: { $0.clusterKey < $1.clusterKey }) {
            guard isPlatformEntry(match.clusterKey), let entry = entries[match.clusterKey],
                let account = entry.participantID
            else { continue }
            byAccount[account, default: []].append(match)
            switch relation(of: entry.displayName, to: match.person, among: people) {
            case .same:
                adopt(match.person, forKey: match.clusterKey)
            case .compatible:
                adopt(match.person, forKey: match.clusterKey)
                aliases.append(
                    AliasRequest(identityID: match.person.id, alias: entry.displayName))
            case .different:
                giveToVoice(match, forKey: match.clusterKey)
            }
        }

        for (account, judged) in byAccount.sorted(by: { $0.key < $1.key }) {
            let voices = Set(judged.map(\.person.id))
            guard voices.count == 1, let lead = judged.max(by: { $0.speechSeconds < $1.speechSeconds })
            else { continue }
            for key in entries.keys.sorted()
            where isPlatformEntry(key) && entries[key]?.participantID == account
                && !judged.contains(where: { $0.clusterKey == key })
            {
                guard let entry = entries[key] else { continue }
                switch relation(of: entry.displayName, to: lead.person, among: people) {
                case .same, .compatible:
                    adopt(lead.person, forKey: key)
                case .different:
                    if key == SpeakerLabel.sensor(participantID: account) {
                        giveToVoice(lead, forKey: key)
                    }
                }
            }
        }
        return aliases
    }

    private mutating func adopt(_ person: KnownPerson, forKey key: String) {
        guard var entry = entries[key] else { return }
        entry.displayName = person.name
        entry.identityID = person.id
        entry.provenance?.identityID = person.id
        entries[key] = entry
    }

    private mutating func giveToVoice(_ match: VoiceMatch, forKey key: String) {
        guard let entry = entries[key] else { return }
        entries[key] = SpeakerAssignment(
            displayName: match.person.name,
            origin: .voiceProfile,
            confidence: match.confidence,
            participantID: entry.participantID,
            identityID: match.person.id,
            provenance: match.provenance
        )
    }
}
