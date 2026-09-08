import Foundation
import PipitCore

/// Reads what Firefox has written about its own add-ons.
///
/// The sensor connection only says the add-on is talking. It talks when Firefox
/// starts and when a meeting page opens, and after Pipit restarts it waits out a
/// backoff before calling in again, so a silent sensor is not the same thing as
/// a missing add-on. Firefox stores an installed add-on as one file per profile,
/// which answers that immediately.
///
/// The read is not free. macOS 15 treats Firefox's Application Support folder
/// as Firefox's data, and the first read from Pipit raises "Pipit would like
/// to access data from other apps". Declining has no switch in System Settings
/// to undo it, so the read runs only when `FirefoxProfileAccess` says the
/// person allowed it, or when they press the button that asks.
public enum FirefoxProfile {
    /// What one read of the profiles folder found.
    public enum Probe: Sendable, Equatable {
        /// A profile holds the add-on file.
        case installed
        /// The folder was read and no profile holds it, or there is no
        /// Firefox on this Mac.
        case absent
        /// The folder is there and could not be opened. On macOS 15 that is
        /// the App Data protection refusing the read.
        case unreadable
    }

    public static let sensorExtensionID = "sensor@pipit.app"

    public static var profilesDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Firefox/Profiles")
    }

    /// Whether any profile on this Mac holds the add-on.
    ///
    /// A temporary add-on is not on disk, so it reads as absent here and is
    /// recognised by its connection instead.
    public static func probe(
        extensionID: String = sensorExtensionID,
        profilesDirectory: URL = FirefoxProfile.profilesDirectory
    ) -> Probe {
        let manager = FileManager.default
        let profiles: [URL]
        do {
            profiles = try manager.contentsOfDirectory(at: profilesDirectory, includingPropertiesForKeys: nil)
        } catch {
            // A missing folder is a Mac without Firefox profiles. Anything
            // else, permission denied above all, is a folder Pipit was not
            // let into, and saying "no add-on" about it would be a guess.
            return (error as NSError).code == NSFileReadNoSuchFileError ? .absent : .unreadable
        }
        let found = profiles.contains { profile in
            let addOn =
                profile
                .appendingPathComponent("extensions")
                .appendingPathComponent("\(extensionID).xpi")
            return manager.fileExists(atPath: addOn.path)
        }
        return found ? .installed : .absent
    }
}

extension FirefoxProfileAccess {
    /// What a completed read says about future reads. Reading an empty list
    /// is still reading, so only a refusal blocks.
    public static func recorded(from probe: FirefoxProfile.Probe) -> FirefoxProfileAccess {
        probe == .unreadable ? .blocked : .allowed
    }
}
