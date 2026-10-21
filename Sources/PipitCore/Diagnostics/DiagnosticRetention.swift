import Foundation

/// Which events files to delete: anything older than 14 days, then the oldest
/// app files until the rest fit in 10 MB.
///
/// Kept apart from the recorder so the arithmetic is tested without writing
/// 10 MB. Age is counted in whole UTC days, the unit a file covers: the files
/// of today and the 13 days before it are kept. The size cap applies to the
/// app's files; the native host caps its own at 256 KB a day, so fourteen of
/// those are bounded already.
public struct DiagnosticRetention: Sendable, Equatable {
    public var maximumDays: Int
    public var maximumAppBytes: Int64

    public init(maximumDays: Int = 14, maximumAppBytes: Int64 = 10 * 1_024 * 1_024) {
        self.maximumDays = maximumDays
        self.maximumAppBytes = maximumAppBytes
    }

    public struct Candidate: Sendable, Equatable {
        public let file: EventFile
        public let bytes: Int64

        public init(file: EventFile, bytes: Int64) {
            self.file = file
            self.bytes = bytes
        }
    }

    /// The files to delete, oldest first.
    ///
    /// `active` is the file being written, which is never deleted: removing it
    /// under the open handle would lose every line written after.
    public func filesToDelete(_ candidates: [Candidate], now: Date, active: EventFile? = nil) -> [EventFile] {
        let today = DiagnosticLayout.date(ofDay: DiagnosticLayout.day(of: now)) ?? now
        let oldestKept = today.addingTimeInterval(-Double(maximumDays - 1) * 86_400)
        let ordered = candidates.sorted { lhs, rhs in
            (lhs.file.day, lhs.file.part) < (rhs.file.day, rhs.file.part)
        }

        var doomed: [EventFile] = []
        var survivors: [Candidate] = []
        for candidate in ordered {
            let day = DiagnosticLayout.date(ofDay: candidate.file.day) ?? .distantPast
            if day < oldestKept, candidate.file != active {
                doomed.append(candidate.file)
            } else {
                survivors.append(candidate)
            }
        }

        var appBytes = survivors.filter { $0.file.family == .app }.reduce(Int64(0)) { $0 + $1.bytes }
        for candidate in survivors where candidate.file.family == .app && candidate.file != active {
            guard appBytes > maximumAppBytes else { break }
            doomed.append(candidate.file)
            appBytes -= candidate.bytes
        }
        return doomed
    }
}
