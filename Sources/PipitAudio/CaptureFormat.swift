import AVFoundation

/// Builds the in-memory format capture writes with, from what a device reports.
enum CaptureFormat {
    /// Float32, deinterleaved. One and two channels use the standard layouts.
    /// `AVAudioFormat(standardFormatWithSampleRate:channels:)` returns nil above
    /// two channels, and a raw built-in microphone binds with three, so those
    /// get a discrete layout that names no speaker positions.
    static func make(sampleRate: Double, channelCount: Int) -> AVAudioFormat? {
        guard sampleRate > 0, channelCount > 0, channelCount <= Int(UInt16.max) else { return nil }
        let channels = AVAudioChannelCount(channelCount)
        if channelCount <= 2 {
            return AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)
        }
        guard
            let layout = AVAudioChannelLayout(
                layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | AudioChannelLayoutTag(channels)
            )
        else { return nil }
        return AVAudioFormat(standardFormatWithSampleRate: sampleRate, channelLayout: layout)
    }
}
