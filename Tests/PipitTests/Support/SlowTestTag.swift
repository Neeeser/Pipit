import Testing

extension Tag {
    /// Suites that run the real echo canceller or the full processing pipeline
    /// over seconds of speech, draw whole windows only to check that they lay
    /// out, or score a whole benchmark transcript. Together they take most of a
    /// full test run.
    ///
    /// Tag a suite with `@Suite("Name", .tags(.slow))` on one line. The tag is
    /// what `scripts/slow-suites.sh` reads to split the run: pull request CI
    /// runs everything else, and the push to main runs these too. SwiftPM
    /// cannot select by tag, so the script finds the tagged suite types in the
    /// sources.
    @Tag static var slow: Self
}
