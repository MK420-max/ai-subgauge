import Foundation

/// Pass local runtime settings explicitly; never inherit unrelated credentials or telemetry.
enum CLIEnvironment {
    static func minimal(from environment: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        let allowed: Set<String> = ["HOME", "PATH", "USER", "LOGNAME", "LANG", "LC_ALL", "LC_CTYPE", "TMPDIR"]
        return environment.filter { allowed.contains($0.key) }
    }

    static func codex(from environment: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var result = minimal(from: environment)
        // npm's launcher uses /usr/bin/env node; never let an inherited PATH select it.
        result["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        result["CODEX_HOME"] = environment["CODEX_HOME"]
        return result
    }

    static func grok(from environment: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var result = minimal(from: environment)
        // Keep the official store location shared by login and usage reads.
        for key in ["GROK_HOME", "GROK_AUTH_PATH"] { result[key] = environment[key] }
        result["GROK_OAUTH2_ISSUER"] = "https://auth.x.ai"
        result["GROK_TELEMETRY_ENABLED"] = "0"
        result["GROK_EXTERNAL_OTEL"] = "0"
        result["GROK_LOG_FILE"] = "/dev/null"
        result["RUST_LOG"] = "off"
        return result
    }
}
