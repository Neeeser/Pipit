import Foundation

/// Free space on the volume a folder is on.
public enum VolumeSpace {
    /// Free bytes on the volume holding `url`, or nil when the volume did not
    /// answer, which is what a network mount does.
    public static func freeBytes(at url: URL) -> Int64? {
        let values = try? url.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]
        )
        return freeBytes(
            importantUsage: values?.volumeAvailableCapacityForImportantUsage,
            available: values?.volumeAvailableCapacity
        )
    }

    /// Picks between the two answers a volume gives.
    ///
    /// Important-usage capacity counts space the system would purge for the
    /// user, so it is the better answer when there is one. Some volumes report
    /// it as zero or leave it out while the plain capacity is real, and a zero
    /// there would show a volume with room on it as full.
    static func freeBytes(importantUsage: Int64?, available: Int?) -> Int64? {
        if let importantUsage, importantUsage > 0 { return importantUsage }
        if let available { return Int64(available) }
        return importantUsage
    }
}
