// Runs the UndertoneCore test suite as a plain executable.
//
// Why not a normal test target: `swift test` on the Command Line Tools (no Xcode) builds a Swift Testing
// bundle but never executes it. Swift Testing exposes the same entry point SwiftPM itself calls, so we invoke
// it directly. `swift run UndertoneSelfTest` (i.e. `make test`) runs every @Test in this target and honours
// pass-through flags like `--filter`.
import Foundation
import Testing

let exitCode = await __swiftPMEntryPoint() as CInt
exit(exitCode)
