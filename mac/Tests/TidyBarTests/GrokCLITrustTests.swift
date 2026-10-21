import Foundation
import Testing
@testable import TidyBar

extension TidyBarTests {
    @Test func grokCodesignArgumentsUseAnInlineStrictRequirement() {
        let file = URL(fileURLWithPath: "/tmp/grok fixture")
        #expect(GrokCLITrust.codesignArguments(for: file) == [
            "--verify", "--strict", "-R", "=" + GrokCLITrust.requirement, file.path
        ])
    }

    @Test func grokRequirementRejectsAppleCodeWithoutARequirementSyntaxFailure() throws {
        let file = URL(fileURLWithPath: "/bin/ls")
        func codesign(_ arguments: [String]) throws -> Int32 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            process.arguments = arguments
            process.environment = CLIEnvironment.minimal()
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
            return process.terminationStatus
        }
        #expect(try codesign(["--verify", "--strict", "-R", "=anchor apple", file.path]) == 0)
        // Exit 3 means valid signed code failed the requirement, not a signature or syntax error.
        #expect(try codesign(GrokCLITrust.codesignArguments(for: file)) == 3)
        #expect(throws: (any Error).self) { try GrokCLITrust.verifySignature(file) }
    }
}
