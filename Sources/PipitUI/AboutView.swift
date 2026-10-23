import AppKit
import SwiftUI

/// The application's name, version, and links, under the ridges and the bird
/// from the website's hero.
///
/// The window keeps the website's palette in light and dark appearance alike,
/// because the scene is a picture rather than chrome.
struct AboutView: View {
    static let size = NSSize(width: 440, height: 430)

    private static let sceneHeight: CGFloat = 236
    /// Where the bird stands, as a fraction of the window's width.
    private static let perch: CGFloat = 0.76
    private static let birdWidth: CGFloat = 104

    private static let website = URL(string: "https://pipit-website.vercel.app")!
    private static let privacy = URL(string: "https://pipit-website.vercel.app/privacy")!
    private static let source = URL(string: "https://github.com/Neeeser/Pipit")!
    private static let license = URL(string: "https://github.com/Neeeser/Pipit/blob/main/LICENSE")!

    var info: AboutInfo = .current

    var body: some View {
        VStack(spacing: 0) {
            scene
            details
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(Palette.night)
        .ignoresSafeArea()
    }

    private var scene: some View {
        let width = Self.size.width
        let scale = width / AboutLandscape.width
        let sun = AboutLandscape.sun
        let front = AboutLandscape.layers.last?.ridge ?? []
        let perchX = width * Self.perch
        let perchHeight = AboutLandscape.height(of: front, at: perchX / scale) * scale
        return ZStack(alignment: .topLeading) {
            LinearGradient(
                stops: [
                    .init(color: Palette.skyTop, location: 0),
                    .init(color: Palette.skyMiddle, location: 0.3),
                    .init(color: Palette.horizon, location: 0.52),
                    .init(color: Palette.dusk, location: 0.72),
                ],
                startPoint: .top, endPoint: .bottom
            )
            Circle()
                .fill(Palette.sun)
                .frame(width: sun.radius * 2 * scale, height: sun.radius * 2 * scale)
                .position(x: sun.x * scale, y: Self.sceneHeight - sun.y * scale)
            ForEach(Array(AboutLandscape.layers.enumerated()), id: \.offset) { _, layer in
                LayerShape(layer: layer).fill(layer.color)
            }
            if let bird = NSImage(named: NSImage.Name("pipit-bird")) {
                let height = Self.birdWidth * bird.size.height / max(bird.size.width, 1)
                Image(nsImage: bird)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: Self.birdWidth, height: height)
                    .shadow(color: Palette.night.opacity(0.25), radius: 6, y: 4)
                    // The perch drawn under the bird's feet sinks a little
                    // into the ridge so it reads as standing on it.
                    .position(x: perchX, y: Self.sceneHeight - perchHeight - height / 2 + 6)
            }
        }
        .frame(width: width, height: Self.sceneHeight)
        .clipped()
        .accessibilityHidden(true)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Pipit")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .tracking(-0.6)
                .foregroundStyle(Palette.cream)
            if let version = info.versionLine {
                HStack(spacing: 10) {
                    Text(version).textSelection(.enabled)
                    if let commit = info.commit {
                        AboutLink(title: "Commit \(commit.prefix(7))", destination: Self.commitURL(commit))
                            .foregroundStyle(Palette.haze)
                    }
                }
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(Palette.haze)
                .padding(.top, 2)
            }
            Text("Records your meetings and saves the transcript and notes as files.")
                .font(.system(size: 13))
                .foregroundStyle(Palette.mist)
                .fixedSize(horizontal: false, vertical: true)
                // Two even lines instead of a long one and an orphan.
                .frame(maxWidth: 260, alignment: .leading)
                .padding(.top, 12)
            Spacer(minLength: 12)
            HStack(spacing: 20) {
                AboutLink(title: "Website", destination: Self.website)
                AboutLink(title: "Source code", destination: Self.source)
                AboutLink(title: "Privacy", destination: Self.privacy)
            }
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(Palette.gold)
            HStack(spacing: 4) {
                if let copyright = info.copyright { Text(copyright + ".") }
                AboutLink(title: "MIT License", destination: Self.license)
            }
            .font(.system(size: 11))
            .foregroundStyle(Palette.haze.opacity(0.8))
            .padding(.top, 14)
        }
        .padding(.horizontal, 28)
        .padding(.top, 2)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private static func commitURL(_ commit: String) -> URL {
        source.appendingPathComponent("commit").appendingPathComponent(commit)
    }

    /// The website's colors, from its design tokens and hero gradient.
    private enum Palette {
        static let night = Color(red: 26 / 255, green: 45 / 255, blue: 92 / 255)
        static let skyTop = Color(red: 143 / 255, green: 181 / 255, blue: 230 / 255)
        static let skyMiddle = Color(red: 188 / 255, green: 210 / 255, blue: 238 / 255)
        static let horizon = Color(red: 232 / 255, green: 238 / 255, blue: 244 / 255)
        static let dusk = Color(red: 249 / 255, green: 231 / 255, blue: 196 / 255)
        static let sun = Color(red: 255 / 255, green: 243 / 255, blue: 209 / 255)
        static let cream = Color(red: 251 / 255, green: 244 / 255, blue: 230 / 255)
        static let haze = Color(red: 169 / 255, green: 195 / 255, blue: 234 / 255)
        static let mist = Color(red: 207 / 255, green: 216 / 255, blue: 236 / 255)
        static let gold = Color(red: 244 / 255, green: 194 / 255, blue: 90 / 255)
    }
}

/// What the About window says about this copy of Pipit, from its Info.plist.
struct AboutInfo {
    var version: String?
    var build: String?
    /// The full commit the build came from.
    var commit: String?
    var copyright: String?

    /// "Version 0.1.9 (442)", or nothing for a binary run outside the bundle,
    /// which has no Info.plist to read.
    var versionLine: String? {
        guard let version else { return nil }
        guard let build else { return "Version \(version)" }
        return "Version \(version) (\(build))"
    }

    static var current: AboutInfo {
        let plist = Bundle.main.infoDictionary
        func value(_ key: String) -> String? {
            guard let text = plist?[key] as? String, !text.isEmpty else { return nil }
            return text
        }
        // A build from a tree with no git stamps "unknown".
        let commit = value("PipitGitCommit").flatMap { $0 == "unknown" ? nil : $0 }
        return AboutInfo(
            version: value("CFBundleShortVersionString"),
            build: value("CFBundleVersion"),
            commit: commit,
            copyright: value("NSHumanReadableCopyright")
        )
    }
}

/// A text link in the About window. It takes its font and color from the
/// surrounding view.
private struct AboutLink: View {
    let title: String
    let destination: URL
    @Environment(\.openURL) private var openURL
    @State private var hovering = false

    var body: some View {
        Button(title) { openURL(destination) }
            .buttonStyle(.plain)
            .underline(hovering)
            .onHover { hovering = $0 }
            .pointerStyle(.link)
            .help(destination.absoluteString)
    }
}
