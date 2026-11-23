import PipitCore
import SwiftUI

/// The colour a source draws its badge in.
///
/// Semantic colours rather than each vendor's own, for the reason `FolderTint`
/// uses them: a fixed value at 18 percent fill goes muddy against a dark
/// sidebar, and the glyph is what says which service a recording came from.
/// The colour only has to separate one row from the next.
public enum SourceTint {
    public static func color(_ source: MeetingSource) -> Color {
        switch source.tint {
        case .purple: .purple
        case .green: .green
        case .blue: .blue
        case .mint: .mint
        case .indigo: .indigo
        case .teal: .teal
        case .orange: .orange
        case .pink: .pink
        case .red: .red
        case .yellow: .yellow
        case .cyan: .cyan
        case .brown: .brown
        case .secondary: .secondary
        }
    }
}
