import Foundation

/// Which file sits at a path, as far as the file system can say without
/// reading it.
///
/// A browser keeps its sensor relay running for as long as the browser stays
/// open. A new Pipit replaces the relay's file underneath it: for Safari the
/// extension inside the app is replaced by the install, and for Firefox and
/// Chrome the browser runs a copy in Application Support that the new Pipit
/// writes over at launch. The old process then no longer matches any signature
/// on disk, so the app refuses every connection it makes until the browser is
/// restarted. The relay compares the identity it started from with what is at
/// its path now and exits once they differ, which lets the browser start the
/// new one.
public struct FileIdentity: Sendable, Equatable {
    public let device: UInt64
    public let inode: UInt64
    public let size: Int64
    public let modifiedSeconds: Int
    public let modifiedNanoseconds: Int

    /// Nil when nothing is at the path or it cannot be read.
    public init?(path: String) {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        device = UInt64(bitPattern: Int64(info.st_dev))
        inode = UInt64(info.st_ino)
        size = Int64(info.st_size)
        modifiedSeconds = info.st_mtimespec.tv_sec
        modifiedNanoseconds = info.st_mtimespec.tv_nsec
    }

    /// Whether the file at `path` is no longer this one: replaced, rewritten,
    /// or removed.
    public func isReplaced(at path: String) -> Bool {
        FileIdentity(path: path) != self
    }
}
