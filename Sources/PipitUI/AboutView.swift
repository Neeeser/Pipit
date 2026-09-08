import AppKit
import PipitCore
import PipitServices
import SwiftUI

/// The application's name, icon, and version.
struct AboutView: View {
    let runtime: PipitRuntime

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 2) {
                Text("Pipit").font(.title2.weight(.semibold))
                Text(Self.version).font(.callout).foregroundStyle(.secondary)
                Text("Records your meetings.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String
        let build = info?["CFBundleVersion"] as? String
        switch (short, build) {
        case (let short?, let build?): return "Version \(short) (\(build))"
        case (let short?, nil): return "Version \(short)"
        // A debug binary run outside the bundle has neither.
        default: return "Development build"
        }
    }
}
