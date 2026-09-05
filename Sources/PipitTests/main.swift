import Foundation
import TestKit

// Built by appending rather than by chaining `+`: a single chained expression of
// this length exceeds the type checker's budget on the toolchain CI runs.
var suites: [Suite] = []
suites += MeetingsWindowTests.all
suites.append(LocalPipelineTests.suite)
suites.append(LiveSlackHuddleTests.suite)
suites.append(LiveOpenAITests.suite)
suites.append(LiveEndToEndTests.suite)

let code = await TestRunner.run(suites, arguments: Array(CommandLine.arguments.dropFirst()))
exit(code)
