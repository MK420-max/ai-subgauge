using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;

namespace AISubGauge.Core;

public enum SignatureStatus { Unsigned, Valid, Invalid }
public enum VerificationStatus { Invalid, Unsigned, PublisherMismatch, VerifierBusy, VerifierTimeout, RevocationFailure, RevocationOffline, NoRevocationCheck, NotFound }
public enum ExecutableLocation { LocalAppData, Npm, Override, None }
public sealed record ExecutableVerification(VerificationStatus Status, ExecutableLocation Location, string? Signer = null);
public readonly record struct ExecutableSignature(SignatureStatus Status, X500DistinguishedName? Subject = null,
    IReadOnlyList<string>? ChainThumbprints = null, VerificationStatus Diagnostic = VerificationStatus.Invalid);
public interface IExecutableSignatures { ExecutableSignature Verify(string path); }
public interface IExecutableFiles
{
    IEnumerable<string> Directories(string path);
    Stream OpenRead(string path);
}
public sealed record CliLocations(string Local, string Roaming, string Profile);
public sealed class VerifiedExecutable(string path, bool custom, Stream lease, bool unsigned = false,
    ExecutableLocation location = ExecutableLocation.None, string? signer = null) : IDisposable
{
    public string Path { get; } = path;
    public bool Custom { get; } = custom;
    public bool Unsigned { get; } = unsigned;
    public ExecutableLocation Location { get; } = location;
    public string? Signer { get; } = signer;
    public void Dispose() => lease.Dispose();
}
public sealed class ExecutableResolver(IExecutableFiles files, IExecutableSignatures signatures, CliLocations locations)
{
    public VerifiedExecutable Resolve(string name, string? configured = null, bool allowUnsignedCodexNpm = false)
    {
        if (name is not ("codex" or "grok")) throw new SafeFailure(Fault.SignIn);
        bool custom = !string.IsNullOrWhiteSpace(configured);
        var candidates = custom ? new[] { configured! } : Candidates(name);
        ExecutableVerification failure = new(VerificationStatus.NotFound, custom ? ExecutableLocation.Override : ExecutableLocation.None);
        foreach (string candidate in candidates)
        {
            Stream? lease = null;
            try
            {
                if (!Path.IsPathFullyQualified(candidate) || !Path.GetExtension(candidate).Equals(".exe", StringComparison.OrdinalIgnoreCase)) continue;
                string path = Path.GetFullPath(candidate);
                // A Codex override is the sole exception to the location allowlist, and must be signed by OpenAI.
                if (!(custom && name == "codex") && !KnownLocation(name, path)) continue;
                lease = files.OpenRead(path); // Retain the non-write/non-delete-sharing handle until launch.
                var location = custom ? ExecutableLocation.Override : NpmCodexPaths().Any(p => Same(path, p))
                    ? ExecutableLocation.Npm : ExecutableLocation.LocalAppData;
                failure = new(VerificationStatus.Invalid, location);
                var signature = signatures.Verify(path);
                string? signer = CodexPublisher.ReadOrganization(signature.Subject);
                if (signature.Status == SignatureStatus.Invalid)
                {
                    failure = new(signature.Diagnostic, location, signer);
                    // The verifier is process-wide. Further candidates cannot recover a hung worker.
                    if (signature.Diagnostic is VerificationStatus.VerifierBusy or VerificationStatus.VerifierTimeout) break;
                    continue;
                }
                if (name == "codex")
                {
                    if (signature.Status == SignatureStatus.Valid && !CodexPublisher.Accepts(signature))
                    { failure = new(VerificationStatus.PublisherMismatch, location, signer); continue; }
                    if (signature.Status == SignatureStatus.Unsigned && !(location == ExecutableLocation.Npm && allowUnsignedCodexNpm))
                    { failure = new(VerificationStatus.Unsigned, location); continue; }
                }
                var result = new VerifiedExecutable(path, custom, lease, signature.Status == SignatureStatus.Unsigned, location, signer);
                lease = null; return result;
            }
            catch { /* Fail closed; never include paths or verifier errors in status text. */ }
            finally { lease?.Dispose(); }
        }
        throw new SafeFailure(failure.Status switch
        {
            VerificationStatus.NotFound => Fault.SignIn,
            VerificationStatus.VerifierBusy or VerificationStatus.VerifierTimeout => Fault.VerifierUnresponsive,
            _ => Fault.VerificationFailed
        }, failure);
    }
    private IEnumerable<string> Candidates(string name)
    {
        if (name == "grok") return [Path.Combine(locations.Profile, ".grok", "bin", "grok.exe")];
        string root = Path.Combine(locations.Local, "OpenAI", "Codex", "bin");
        string[] versions;
        try { versions = files.Directories(root).OrderByDescending(p => p, StringComparer.OrdinalIgnoreCase).ToArray(); }
        catch { versions = []; }
        return versions.Select(p => Path.Combine(p, "codex.exe")).Concat(NpmCodexPaths());
    }
    private IEnumerable<string> NpmCodexPaths()
    {
        string modules = Path.Combine(locations.Roaming, "npm", "node_modules", "@openai");
        foreach (var (architecture, triple) in new[] { ("x64", "x86_64-pc-windows-msvc"), ("arm64", "aarch64-pc-windows-msvc") })
        foreach (string package in new[] { "codex", "codex-win32-" + architecture })
            yield return Path.Combine(modules, package, "vendor", triple, "codex", "codex.exe");
    }
    private bool KnownLocation(string name, string path)
    {
        if (name == "grok") return Same(path, Path.Combine(locations.Profile, ".grok", "bin", "grok.exe"));
        if (NpmCodexPaths().Any(p => Same(path, p))) return true;
        string? parent = Path.GetDirectoryName(path);
        if (parent is null || !Same(Path.GetDirectoryName(parent), Path.Combine(locations.Local, "OpenAI", "Codex", "bin")) ||
            !Path.GetFileName(path).Equals("codex.exe", StringComparison.OrdinalIgnoreCase)) return false;
        string hash = Path.GetFileName(parent);
        return hash.Length is >= 7 and <= 128 && hash.All(char.IsAsciiHexDigit);
    }
    private static bool Same(string? a, string b) => string.Equals(a, Path.GetFullPath(b), StringComparison.OrdinalIgnoreCase);
}
internal sealed class ExecutableFiles : IExecutableFiles
{
    public IEnumerable<string> Directories(string path) => Directory.GetDirectories(path);
    public Stream OpenRead(string path) => LocalFiles.OpenRead(path, long.MaxValue);
}
public static class Executables
{
    private static readonly ExecutableResolver Resolver = new(new ExecutableFiles(), new AuthenticodeSignatures(), new(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
        Environment.GetFolderPath(Environment.SpecialFolder.UserProfile)));
    private static int customCodex, customGrok, unsignedCodex;
    public static bool UnsignedCodexInUse => Volatile.Read(ref unsignedCodex) != 0;
    public static bool CustomPathInUse(Vendor vendor) => vendor switch
    {
        Vendor.Codex => Volatile.Read(ref customCodex) != 0,
        Vendor.Grok => Volatile.Read(ref customGrok) != 0,
        _ => false
    };
    public static VerifiedExecutable Open(string name, bool allowUnsignedCodexNpm = false)
    {
        if (name == "codex") { Volatile.Write(ref customCodex, 0); Volatile.Write(ref unsignedCodex, 0); }
        var executable = Resolver.Resolve(name, Environment.GetEnvironmentVariable(name == "codex" ? "CODEX_EXE" : "GROK_EXE"), allowUnsignedCodexNpm);
        if (name == "codex") Volatile.Write(ref unsignedCodex, executable.Unsigned ? 1 : 0);
        if (name == "codex") Volatile.Write(ref customCodex, executable.Custom ? 1 : 0);
        else Volatile.Write(ref customGrok, executable.Custom ? 1 : 0);
        return executable;
    }
    public static Task<VerifiedExecutable> OpenAsync(string name, bool allowUnsignedCodexNpm = false) => Task.Run(() => Open(name, allowUnsignedCodexNpm));
}

public static class CodexPublisher
{
    public const string Organization = "OpenAI OpCo, LLC";
    // Microsoft Identity Verification Root Certificate Authority 2020.
    public const string RootThumbprint = "F40042E2E5F7E8EF8189FED15519AECE42C3BFA2";
    // Microsoft ID Verified Code Signing PCA 2021. Pin issuers, not the rotating three-day leaf.
    public const string IntermediateThumbprint = "8E750F459DAF9A79D6370DB747AD2226866AD818";

    public static bool Accepts(ExecutableSignature signature)
    {
        try
        {
            if (signature.Status != SignatureStatus.Valid || signature.Subject is null ||
                signature.ChainThumbprints is not { Count: >= 3 } chain ||
                !string.Equals(chain[^1], RootThumbprint, StringComparison.Ordinal) ||
                !chain.Skip(1).SkipLast(1).Contains(IntermediateThumbprint, StringComparer.Ordinal)) return false;
            return string.Equals(ReadOrganization(signature.Subject), Organization, StringComparison.Ordinal);
        }
        catch { return false; }
    }
    public static string? ReadOrganization(X500DistinguishedName? subject)
    {
        try
        {
            if (subject is null) return null;
            string? organization = null;
            // Decode the X500DistinguishedName's actual RDNs, not its formatted text. This handles
            // quoted commas/escaped values without mistaking O= inside a CN for an organization.
            foreach (var rdn in subject.EnumerateRelativeDistinguishedNames())
            {
                if (rdn.HasMultipleElements) return null; // Ambiguous names fail closed.
                if (rdn.GetSingleElementType().Value != "2.5.4.10") continue;
                if (organization is not null) return null;
                organization = rdn.GetSingleElementValue();
            }
            return organization;
        }
        catch { return null; }
    }
}

// Bound the entire native operation, including trust-state cleanup. No native work on the UI thread.
public sealed class AuthenticodeSignatures(IExecutableSignatures? verifier = null, TimeSpan? timeout = null, SafeLog? log = null) : IExecutableSignatures
{
    private static readonly SemaphoreSlim Gate = new(1, 1);
    private static int consecutiveBusy;
    internal static bool Idle => Gate.CurrentCount == 1;
    public const uint CacheOnlyUrlRetrieval = 0x1000; // WTD_CACHE_ONLY_URL_RETRIEVAL
    public const uint ProviderFlags = 0x80 | CacheOnlyUrlRetrieval; // Revocation: chain excluding root, cache only.
    private readonly IExecutableSignatures verifier = verifier ?? new NativeAuthenticodeSignatures();
    private readonly TimeSpan timeout = timeout ?? TimeSpan.FromSeconds(5);
    private readonly SafeLog log = log ?? new(new Redactor());
    public ExecutableSignature Verify(string path)
    {
        bool busy, reportBusy = false;
        lock (Gate)
        {
            busy = !Gate.Wait(0);
            if (!busy) consecutiveBusy = 0;
            else if (consecutiveBusy < 3) reportBusy = ++consecutiveBusy == 3;
        }
        if (reportBusy) log.Write(LocalStatus.VerifierBusyRepeated);
        if (busy) return new(SignatureStatus.Invalid, Diagnostic: VerificationStatus.VerifierBusy);
        Task<ExecutableSignature> worker;
        try
        {
            // A timed-out native call cannot safely be aborted. Its worker owns and eventually
            // closes the trust state; its late result is discarded and can never authorize launch.
            worker = Task.Run(() =>
            {
                try { return verifier.Verify(path); }
                catch { return new ExecutableSignature(SignatureStatus.Invalid); }
                finally { Gate.Release(); } // Only the native worker can release after it returns, even after timeout.
            });
        }
        catch { Gate.Release(); return new(SignatureStatus.Invalid); }
        try { return worker.WaitAsync(timeout).GetAwaiter().GetResult(); }
        catch (TimeoutException) { return new(SignatureStatus.Invalid, Diagnostic: VerificationStatus.VerifierTimeout); }
        catch { return new(SignatureStatus.Invalid); }
    }
    public static ExecutableSignature NativeFailure(int status) => new(SignatureStatus.Invalid, Diagnostic: unchecked((uint)status) switch
    {
        0x800B010E => VerificationStatus.RevocationFailure,
        0x80092013 => VerificationStatus.RevocationOffline,
        0x80092012 => VerificationStatus.NoRevocationCheck,
        _ => VerificationStatus.Invalid
    });
}

// Native Windows trust policy; no PowerShell, PATH lookup, packages or certificate-store changes.
internal sealed class NativeAuthenticodeSignatures : IExecutableSignatures
{
    public ExecutableSignature Verify(string path)
    {
        var file = new TrustFile { Size = (uint)Marshal.SizeOf<TrustFile>(), Path = path };
        IntPtr pointer = Marshal.AllocHGlobal(Marshal.SizeOf<TrustFile>());
        bool marshalled = false;
        var data = new TrustData { Size = (uint)Marshal.SizeOf<TrustData>(), UiChoice = 2, UnionChoice = 1,
            File = pointer, StateAction = 1, RevocationChecks = 1, ProviderFlags = AuthenticodeSignatures.ProviderFlags };
        var action = new Guid("00AAC56B-CD44-11d0-8CC2-00C04FC295EE");
        try
        {
            Marshal.StructureToPtr(file, pointer, false); marshalled = true;
            int status = WinVerifyTrust(new IntPtr(-1), ref action, ref data);
            IntPtr provider = data.State == IntPtr.Zero ? IntPtr.Zero : WTHelperProvDataFromStateData(data.State);
            IntPtr signerPointer = provider == IntPtr.Zero ? IntPtr.Zero : WTHelperGetProvSignerFromChain(provider, 0, false, 0);
            // Only explicit TRUST_E_NOSIGNATURE with no signer certificate counts as unsigned.
            if (status == unchecked((int)0x800B0100))
            {
                bool noSigner = signerPointer == IntPtr.Zero || Marshal.PtrToStructure<ProviderSigner>(signerPointer).CertCount == 0;
                return new(noSigner ? SignatureStatus.Unsigned : SignatureStatus.Invalid);
            }
            if (status != 0 || signerPointer == IntPtr.Zero) return AuthenticodeSignatures.NativeFailure(status);
            var signer = Marshal.PtrToStructure<ProviderSigner>(signerPointer);
            if (signer.Error != 0 || signer.CertCount is 0 or > 64 || signer.CertChain == IntPtr.Zero) return new(SignatureStatus.Invalid);
            var chain = new List<string>(); X500DistinguishedName? subject = null;
            for (int i = 0; i < signer.CertCount; i++)
            {
                var entry = Marshal.PtrToStructure<ProviderCertificate>(IntPtr.Add(signer.CertChain, checked(i * Marshal.SizeOf<ProviderCertificate>())));
                if (entry.Certificate == IntPtr.Zero || entry.Error != 0) return new(SignatureStatus.Invalid);
                using var cert = new X509Certificate2(entry.Certificate);
                if (i == 0) subject = new X500DistinguishedName(cert.SubjectName.RawData);
                chain.Add(cert.Thumbprint);
            }
            return new(SignatureStatus.Valid, subject, chain.ToArray());
        }
        catch { return new(SignatureStatus.Invalid); }
        finally
        {
            try
            {
                if (marshalled)
                {
                    data.StateAction = 2; // WTD_STATEACTION_CLOSE, after copying the trusted signer/chain.
                    if (WinVerifyTrust(new IntPtr(-1), ref action, ref data) != 0) throw new CryptographicException();
                }
            }
            finally
            {
                if (marshalled) Marshal.DestroyStructure<TrustFile>(pointer);
                Marshal.FreeHGlobal(pointer);
            }
        }
    }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct TrustFile { public uint Size; [MarshalAs(UnmanagedType.LPWStr)] public string Path; public IntPtr Handle, KnownSubject; }
    [StructLayout(LayoutKind.Sequential)]
    private struct TrustData
    {
        public uint Size; public IntPtr PolicyCallback, SipClient; public uint UiChoice, RevocationChecks, UnionChoice;
        public IntPtr File; public uint StateAction; public IntPtr State, Url; public uint ProviderFlags, UiContext; public IntPtr SignatureSettings;
    }
    // wintrust.h CRYPT_PROVIDER_SGNR / CRYPT_PROVIDER_CERT; BOOLs are 32-bit integers.
    [StructLayout(LayoutKind.Sequential)]
    private struct ProviderSigner
    {
        public uint Size; public System.Runtime.InteropServices.ComTypes.FILETIME VerifyAsOf; public uint CertCount;
        public IntPtr CertChain; public uint SignerType; public IntPtr Signer; public uint Error, CounterSignerCount;
        public IntPtr CounterSigners, ChainContext;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct ProviderCertificate
    {
        public uint Size; public IntPtr Certificate; public int Commercial, TrustedRoot, SelfSigned, TestCertificate;
        public uint RevokedReason, Confidence, Error; public IntPtr TrustListContext; public int TrustListSigner;
        public IntPtr CtlContext; public uint CtlError; public int IsCyclic; public IntPtr ChainElement;
    }
    [DllImport("wintrust.dll", ExactSpelling = true)]
    private static extern IntPtr WTHelperProvDataFromStateData(IntPtr state);
    [DllImport("wintrust.dll", ExactSpelling = true)]
    private static extern IntPtr WTHelperGetProvSignerFromChain(IntPtr provider, uint signer, [MarshalAs(UnmanagedType.Bool)] bool counterSigner, uint counterSignerIndex);
    [DllImport("wintrust.dll", ExactSpelling = true)]
    private static extern int WinVerifyTrust(IntPtr window, ref Guid action, ref TrustData data);
}
