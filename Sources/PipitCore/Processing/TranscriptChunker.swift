import Foundation

/// Cuts a long transcript into parts a model's context window can hold.
public enum TranscriptChunker {
    /// Parts of at most `limit` characters, split between lines.
    ///
    /// The parts come out near the same size. Filling each to the limit and
    /// leaving the remainder for the last would hand the model a final part of a
    /// few lines, which it summarises as if it were the whole meeting.
    ///
    /// A single line longer than the limit, which a transcript does not
    /// normally have, is cut at a space near the limit rather than dropped.
    public static func split(_ text: String, limit: Int) -> [String] {
        let limit = max(limit, 1)
        let total = text.count
        guard total > limit else { return text.isEmpty ? [] : [text] }

        let partCount = Int((Double(total) / Double(limit)).rounded(.up))

        // The target is worked out again after every cut. Cutting each part just
        // under a fixed target leaves the shortfall to pile up in a last part of
        // a few lines.
        var parts: [String] = []
        var current = ""
        var currentCount = 0
        var remaining = total
        var partsLeft = partCount
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for piece in lines.flatMap({ pieces(of: String($0), limit: limit) }) {
            let pieceCount = piece.count
            let target = partsLeft > 1 ? Int((Double(remaining) / Double(partsLeft)).rounded(.up)) : limit
            if currentCount > 0, currentCount + 1 + pieceCount > min(target, limit) {
                parts.append(current)
                remaining -= currentCount + 1
                partsLeft = max(partsLeft - 1, 1)
                current = ""
                currentCount = 0
            }
            if currentCount > 0 {
                current += "\n"
                currentCount += 1
            }
            current += piece
            currentCount += pieceCount
        }
        if currentCount > 0 { parts.append(current) }
        return parts
    }

    private static func pieces(of line: String, limit: Int) -> [String] {
        guard line.count > limit else { return [line] }
        var pieces: [String] = []
        var rest = Substring(line)
        while rest.count > limit {
            let window = rest.prefix(limit)
            var length = limit
            if let space = window.lastIndex(of: " ") {
                let offset = window.distance(from: window.startIndex, to: space)
                if offset > limit / 2 { length = offset }
            }
            pieces.append(String(rest.prefix(length)))
            rest = rest.dropFirst(length).drop(while: { $0 == " " })
        }
        if !rest.isEmpty { pieces.append(String(rest)) }
        return pieces
    }
}
