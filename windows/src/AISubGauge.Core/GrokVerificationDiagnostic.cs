namespace AISubGauge.Core;

public enum VerificationStage { None, KnownLocation, OpenFile, OpenDirectory, OpenLeaf, FileMetadata, FinalPath, Signature, NativeTrust, NativeSigner, NativeChain, Organization, Publisher, Resolved }

// Opt-in, scoped diagnostic. Never receives file names, credentials or exception messages.
internal sealed class VerificationTrace
{
    internal static readonly AsyncLocal<VerificationTrace?> Current = new();
    internal VerificationStage Stage { get; private set; }
    internal Action<string>? Sink { get; init; }
    internal static void Step(VerificationStage stage)
    {
        if (Current.Value is { } trace) { trace.Stage = stage; trace.Sink?.Invoke($"stage={stage}"); }
    }
    internal static void Exception(Exception error) => Current.Value?.Sink?.Invoke($"exceptionType={error.GetType().Name}");
    internal static void Certificate(string thumbprint) => Current.Value?.Sink?.Invoke($"chainThumbprint={thumbprint}");
    internal static void Organization(string? value) => Current.Value?.Sink?.Invoke(
        "organization=" + (value is GrokPublisher.Organization or CodexPublisher.Organization ? value : value is null ? "MissingOrAmbiguous" : "Other"));
}

public static class GrokVerificationDiagnostic
{
    public static int Run(TextWriter output)
    {
        var previous = VerificationTrace.Current.Value;
        VerificationTrace.Current.Value = new() { Sink = output.WriteLine };
        try
        {
            using var executable = Executables.Open("grok");
            output.WriteLine("result=OK"); return 0;
        }
        catch (SafeFailure error)
        {
            output.WriteLine($"result=Failed status={error.Verification?.Status} stage={error.Verification?.Stage}");
            // Independently diagnose trust even when the resolver cannot acquire an ancestor handle.
            // This result never authorizes execution and does not replace the resolver result.
            string profile = Environment.GetEnvironmentVariable("USERPROFILE") ?? Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            var signature = new AuthenticodeSignatures().Verify(Path.Combine(profile, ".grok", "bin", "grok.exe"));
            VerificationTrace.Organization(CodexPublisher.ReadOrganization(signature.Subject));
            output.WriteLine($"signatureOnly={signature.Status}" +
                (signature.Status == SignatureStatus.Invalid ? $" status={signature.Diagnostic}" : "") +
                $" publisherAccepted={GrokPublisher.Accepts(signature)}");
            return 1;
        }
        finally { VerificationTrace.Current.Value = previous; }
    }
}
