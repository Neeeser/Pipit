import Foundation

/// The `.zip` **Export Diagnostics** saves.
///
/// One folder, `Pipit-Diagnostics-<UTC time>`, holding:
///
/// - `report.json`: the report, pretty-printed, to read;
/// - `report.json.gz`: the exact body **Send** uploads, so an exported report
///   can be attached to an issue or sent later unchanged;
/// - `README.txt`: what each section is and what a report never holds.
///
/// An export carries a note and a contact address only when the person typed
/// them, as a sent report does.
public enum DiagnosticExport {
    /// `Pipit-Diagnostics-20261021T031816Z.zip`. The time is UTC, written
    /// without colons, which the Finder shows as slashes.
    public static func fileName(createdAt: Date) -> String {
        folderName(createdAt: createdAt) + ".zip"
    }

    static func folderName(createdAt: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: createdAt)
        let stamp = String(
            format: "%04d%02d%02dT%02d%02d%02dZ", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
            parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0
        )
        return "Pipit-Diagnostics-\(stamp)"
    }

    /// The archive's entries, in the order they are written.
    public static func entries(_ bundle: DiagnosticBundle) throws -> [DiagnosticArchive.Entry] {
        let folder = folderName(createdAt: bundle.report.createdAt)
        let encoder = DiagnosticCoding.makeReportEncoder()
        encoder.outputFormatting.insert(.prettyPrinted)
        var pretty = try encoder.encode(bundle.report)
        pretty.append(0x0A)
        return [
            DiagnosticArchive.Entry(name: "\(folder)/report.json", contents: pretty),
            DiagnosticArchive.Entry(name: "\(folder)/report.json.gz", contents: bundle.gzipped),
            DiagnosticArchive.Entry(name: "\(folder)/README.txt", contents: Data(readme.utf8)),
        ]
    }

    /// The `.zip` file's bytes.
    public static func archive(_ bundle: DiagnosticBundle) throws -> Data {
        try DiagnosticArchive(entries: try entries(bundle), modified: bundle.report.createdAt).data()
    }

    /// What the README says. Plain text, wrapped for a terminal.
    public static let readme = """
        Pipit diagnostic report
        =======================

        report.json      The report, formatted to read.
        report.json.gz   The same report, compressed, exactly as Pipit sends it.

        Sections of report.json
        -----------------------

        app            Pipit's version, build number, source commit, and
                       whether this is a release or a development build.
        system         macOS version and build, the Mac's model identifier
                       (such as Mac15,3), processor type, memory, processor
                       cores, free disk space as a range, and the language
                       code of the first preferred language.
        summary        A snapshot taken when the report was made:
          settings       Switches, choices and numbers from Settings. Text
                         you typed appears only as a count or a yes/no.
          permissions    Each macOS permission and whether it is granted.
          models         On-device speech models, their state, revision
                         and size.
          browserAddOns  Each browser add-on, whether it is connected, and
                         its version.
          storage        How many meetings there are, and free disk space
                         as a range.
          recentFailures Processing steps that failed, as a category code.
          diagnostics    How many events are in the report, how many were
                         left out to fit, and how many were lost.
        events         What Pipit did, one line per event: launches,
                       recordings starting and stopping, processing steps,
                       model installs, add-on connections, and error codes.
        crashes        Crashes of Pipit's own programs: where in Pipit's
                       code each one happened, as offsets, without names.
        note, contact  Present only when you typed them.

        Never included
        --------------

        Recordings, transcripts, summaries, notes, meeting titles, names of
        people or devices, calendar events, file paths, web addresses, API
        keys, model names you typed, and the text of error messages.

        Identifiers in a report are random and new for each launch,
        recording, processing attempt and report. None of them follows this
        Mac from one report to the next.

        """
}
