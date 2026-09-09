import Foundation

/// What a release changed, read out of the GitHub release body.
///
/// GitHub writes the body from merged pull request titles under the headings in
/// `.github/release.yml`, after whatever the maintainer typed on the draft. The
/// body is drawn as lists inside the update window. Sparkle's own window
/// would show the release page, which is a web page with a header, a sidebar
/// and a sign-in prompt inside an update dialog.
public struct ReleaseNotes: Equatable, Sendable {
    public struct Section: Equatable, Sendable {
        /// Nil for the lines before the first heading, which are the
        /// maintainer's one or two lines about the release.
        public var title: String?
        public var items: [String]

        public init(title: String?, items: [String]) {
            self.title = title
            self.items = items
        }
    }

    public var sections: [Section]

    public init(sections: [Section]) {
        self.sections = sections
    }

    public var isEmpty: Bool { sections.isEmpty }

    /// Headings open sections, bullets are items, and paragraphs are items of
    /// one line. The "by @user in <link>" trailer GitHub adds to every bullet
    /// is dropped, and so is the "Full Changelog" line. A section with
    /// nothing under it, which is what "What's Changed" is once the items sit
    /// under category headings, is dropped too.
    public static func parse(markdown: String) -> ReleaseNotes {
        var sections: [Section] = []
        var current = Section(title: nil, items: [])
        var paragraph: [String] = []

        func closeParagraph() {
            if !paragraph.isEmpty {
                current.items.append(paragraph.joined(separator: " "))
                paragraph = []
            }
        }
        func closeSection() {
            closeParagraph()
            if !current.items.isEmpty { sections.append(current) }
        }

        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                closeParagraph()
                continue
            }
            if line.hasPrefix("<!--") || line.lowercased().hasPrefix("**full changelog**") { continue }
            if let title = heading(line) {
                closeSection()
                current = Section(title: title, items: [])
                continue
            }
            if let item = bullet(line) {
                closeParagraph()
                current.items.append(item)
                continue
            }
            paragraph.append(cleaned(line))
        }
        closeSection()
        return ReleaseNotes(sections: sections)
    }

    private static func heading(_ line: String) -> String? {
        guard line.hasPrefix("#") else { return nil }
        let title = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? nil : cleaned(title)
    }

    private static func bullet(_ line: String) -> String? {
        guard let marker = line.first, "-*+".contains(marker) else { return nil }
        let rest = line.dropFirst()
        guard rest.first == " " else { return nil }
        let item = cleaned(rest.trimmingCharacters(in: .whitespaces))
        return item.isEmpty ? nil : item
    }

    /// Strips the attribution trailer and inline markdown emphasis.
    private static func cleaned(_ text: String) -> String {
        var result = text
        for pattern in [#"\s+by @\S+ in https?://\S+$"#, #"\s+in https?://\S+$"#] {
            result = result.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        result = result.replacingOccurrences(of: "**", with: "")
        return result.trimmingCharacters(in: .whitespaces)
    }
}

/// Fetches a release's notes from the GitHub API.
///
/// Only when the update window is about to show them, never at launch: the
/// app has to start and record with no network at all.
public struct ReleaseNotesLoader: Sendable {
    /// The repository releases are cut from. The appcast lives on its Pages
    /// site and the archives on its releases, so this is already the one
    /// place updates come from.
    public static let repository = "Neeeser/Pipit"

    private let fetch: @Sendable (URL) async throws -> Data

    public init(
        fetch: @escaping @Sendable (URL) async throws -> Data = { url in
            var request = URLRequest(url: url)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 15
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
            return data
        }
    ) {
        self.fetch = fetch
    }

    public static func url(version: String) -> URL? {
        URL(string: "https://api.github.com/repos/\(repository)/releases/tags/v\(version)")
    }

    public func load(version: String) async throws -> ReleaseNotes {
        guard let url = Self.url(version: version) else { throw URLError(.badURL) }
        return try Self.notes(from: try await fetch(url))
    }

    /// The `body` field of a release, parsed.
    public static func notes(from data: Data) throws -> ReleaseNotes {
        struct Release: Decodable {
            var body: String?
        }
        let release = try JSONDecoder().decode(Release.self, from: data)
        return ReleaseNotes.parse(markdown: release.body ?? "")
    }
}
