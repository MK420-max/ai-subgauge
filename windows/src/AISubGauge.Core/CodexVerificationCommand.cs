namespace AISubGauge.Core;

public static class CodexVerificationCommand
{
    public static int Run(Func<VerifiedExecutable> resolve, TextWriter output)
    {
        string result; ExecutableLocation location; string? signer;
        int exitCode;
        try
        {
            using var executable = resolve();
            result = "Accepted"; location = executable.Location; signer = executable.Signer; exitCode = 0;
        }
        catch (SafeFailure error)
        {
            var failure = error.Verification ?? new(VerificationStatus.Invalid, ExecutableLocation.None);
            result = "Rejected:" + failure.Status; location = failure.Location; signer = null; exitCode = 4;
        }
        catch { result = "Rejected:Invalid"; location = ExecutableLocation.None; signer = null; exitCode = 4; }
        // Certificate names are untrusted. Never allow extra lines, paths or output-field injection.
        if (string.IsNullOrEmpty(signer) || signer.Length > 160 || signer.Any(c => char.IsControl(c) || "\\/:=<>".Contains(c))) signer = "-";
        output.WriteLine($"codex-verify: {result} location={location} signer={signer}");
        return exitCode;
    }
}
