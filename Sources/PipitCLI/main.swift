import Foundation
import PipitCLIKit

// The `pipit` command. Everything it does lives in PipitCLIKit so the test
// suite can run it; this file only connects it to the terminal.

let result = PipitCommandLine.run(Array(CommandLine.arguments.dropFirst()), environment: .live())
FileHandle.standardOutput.write(Data(result.standardOutput.utf8))
FileHandle.standardError.write(Data(result.standardError.utf8))
exit(result.exitCode)
