import Foundation

/// Walks up from a meeting directory to the archive root that owns it.
///
/// The tool is pointed at one meeting, and the commands need the archive so they
/// can open the repository around it. A meeting sits at `<root>/<year>/<month>/<id>`
/// when it has not been filed and at `<root>/Folders/<name>/<id>` when it has.
/// Anything else is read as `<root>/<id>`.
enum MeetingArchiveRoot {
    static func resolve(for meeting: URL) -> URL {
        let parent = meeting.deletingLastPathComponent()
        let grandparent = parent.deletingLastPathComponent()
        if grandparent.lastPathComponent == "Folders" {
            return grandparent.deletingLastPathComponent()
        }
        if isDigits(parent.lastPathComponent, count: 2), isDigits(grandparent.lastPathComponent, count: 4) {
            return grandparent.deletingLastPathComponent()
        }
        return parent
    }

    private static func isDigits(_ text: String, count: Int) -> Bool {
        text.count == count && text.allSatisfy(\.isNumber)
    }
}
