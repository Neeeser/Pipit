import Foundation
import TestKit

// Built by appending rather than by chaining `+`: a single chained expression of
// this length exceeds the type checker's budget on the toolchain CI runs.
var suites: [Suite] = []
suites += DetectionTests.all
suites += SessionTests.all
suites.append(UITests.suite)
suites.append(DockPresenceTests.suite)
suites.append(SetupFlowTests.suite)
suites += LocalConfigurationTests.all
suites += SpeakerIdentityTests.all
suites.append(VoiceEvidenceTests.suite)
suites += SpeechGateTests.all
suites.append(ReconnectTests.suite)
suites.append(SpeakerGroupingTests.suite)
suites += SensorAttributionTests.all
suites += SpeakerCorrectionTests.all
suites.append(SpeakerSuggestionTests.suite)
suites.append(SpeakerRematchTests.suite)
suites += PeopleDirectoryTests.all
suites += MeetingsWindowTests.all
suites += BackendSelectionTests.all
suites.append(CloudModelTests.suite)
suites += ProcessingTests.all
suites.append(PipelineTests.suite)
suites.append(ReprocessingTests.suite)
suites.append(LocalPipelineTests.suite)
suites.append(LocalModelTests.suite)
suites.append(BenchScorerTests.suite)
suites.append(LiveSlackHuddleTests.suite)
suites.append(LiveOpenAITests.suite)
suites.append(LiveEndToEndTests.suite)

let code = await TestRunner.run(suites, arguments: Array(CommandLine.arguments.dropFirst()))
exit(code)
