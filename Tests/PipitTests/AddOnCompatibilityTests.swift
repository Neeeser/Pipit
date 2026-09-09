import Foundation
import PipitCore
import PipitServices
import Testing

@Suite("AddOnCompatibility")
struct AddOnCompatibilityTests {
    @Test("an add-on is judged against the protocol number, not the app version")
    func anAddOnIsJudgedAgainstTheProtocolNumberNotTheAppVersion() async throws {
        // Most app releases leave the add-on alone, so a version comparison
        // would ask for an update on every release. Only the number moves.
        #expect(SensorProtocol.compatibility(of: SensorProtocol.required) == .current)
        #expect(SensorProtocol.compatibility(of: SensorProtocol.required - 1) == .behind)
        #expect(SensorProtocol.compatibility(of: SensorProtocol.required + 1) == .ahead)
        #expect(SensorProtocol.compatibility(of: nil) == nil, "an add-on that never reported is not judged")
    }

    @Test("an add-on signed before the number existed reads as the first shape")
    func anAddOnSignedBeforeTheNumberExistedReadsAsTheFirstShape() async throws {
        let line = Data(
            #"{"type":"hello","hello":{"browser":"firefox","extensionVersion":"0.1.1.87","hostVersion":"1.0.0"}}"#
                .utf8)
        guard case .hello(let hello) = try SensorTransport.decodeLine(line) else {
            Issue.record("expected a hello")
            return
        }
        #expect(hello.protocolVersion == nil)
        #expect(SensorProtocol.compatibility(of: hello.protocolVersion ?? SensorProtocol.unnumbered) == .behind)

        let numberedLine =
            #"{"type":"hello","hello":{"browser":"firefox","extensionVersion":"0.2.0.90","#
            + #""hostVersion":"1.0.0","protocolVersion":2}}"#
        let numbered = Data(numberedLine.utf8)
        guard case .hello(let current) = try SensorTransport.decodeLine(numbered) else {
            Issue.record("expected a hello")
            return
        }
        #expect(current.protocolVersion == 2)
    }

    @Test("the status says the add-on needs updating from what it last reported")
    func theStatusSaysTheAddOnNeedsUpdatingFromWhatItLastReported() async throws {
        // Read from the latch rather than the live connection, because the
        // add-on takes up to a minute to call back after Pipit restarts, and
        // the update window that asks for it opens on that restart.
        var status = RuntimeStatus()
        #expect(!status.firefoxAddOnNeedsUpdate, "nothing is asked of a machine that never had the add-on")

        status.firefoxSensorHasConnected = true
        status.firefoxAddOnProtocol = SensorProtocol.unnumbered
        #expect(status.firefoxAddOnNeedsUpdate)
        #expect(!status.firefoxAddOnIsAhead)

        status.firefoxAddOnProtocol = SensorProtocol.required
        #expect(!status.firefoxAddOnNeedsUpdate)

        status.firefoxAddOnProtocol = SensorProtocol.required + 1
        #expect(status.firefoxAddOnIsAhead)
        #expect(!status.firefoxAddOnNeedsUpdate)
    }

    @Test("the settings file keeps what the add-on last reported")
    func theSettingsFileKeepsWhatTheAddOnLastReported() async throws {
        var settings = AppSettings()
        #expect(settings.firefoxAddOnProtocol == nil)
        settings.firefoxAddOnProtocol = 2
        settings.firefoxAddOnVersion = "0.2.0.90"
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(decoded.firefoxAddOnProtocol == 2)
        #expect(decoded.firefoxAddOnVersion == "0.2.0.90")

        // A file written before the fields existed decodes with nothing reported.
        let older = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"version":3}"#.utf8))
        #expect(older.firefoxAddOnProtocol == nil)
    }
}
