import Foundation
import Security
import Testing
@testable import TidyBar

extension TidyBarTests {
    @Test func grokCodesignArgumentsUseAnInlineStrictRequirement() {
        let file = URL(fileURLWithPath: "/tmp/grok fixture")
        #expect(GrokCLITrust.codesignArguments(for: file) == [
            "--verify", "--strict", "-R", "=" + GrokCLITrust.requirement, file.path
        ])
    }

    @Test func grokRequirementSyntaxIsValidWithoutTrustEvaluation() throws {
        var requirement: SecRequirement?
        #expect(SecRequirementCreateWithString(GrokCLITrust.requirement as CFString, [], &requirement) == errSecSuccess)
        _ = try #require(requirement)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["AISUBGAUGE_TRUST_INTEGRATION"] == "1",
                   "Set AISUBGAUGE_TRUST_INTEGRATION=1 to evaluate the local Apple trust chain"))
    func grokRequirementRejectsAppleCodeWithoutARequirementSyntaxFailure() throws {
        let file = URL(fileURLWithPath: "/bin/ls")
        func codesign(_ arguments: [String]) throws -> (status: Int32, error: String) {
            let process = Process(), error = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            process.arguments = arguments
            process.environment = CLIEnvironment.minimal()
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = error
            try process.run()
            let data = error.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }
        #expect(try codesign(["--verify", "--strict", "-R", "=anchor apple", file.path]).status == 0)
        let result = try codesign(GrokCLITrust.codesignArguments(for: file))
        #expect(result.status != 0)
        #expect(!result.error.localizedCaseInsensitiveContains("syntax error"))
        #expect(throws: (any Error).self) { try GrokCLITrust.verifySignature(file) }
    }
}
