using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;

namespace AISubGauge.Providers;

internal static class Authenticode
{
    // Confirm the actual publisher independently before changing this central allowlist.
    internal const string XaiPublisher = "X.AI LLC";
    internal const string OpenAiPublisher = "OpenAI, L.L.C.";
    internal const string OpenAiOpCoPublisher = "OpenAI OpCo, LLC";
    internal static readonly IReadOnlyList<string> GrokPublishers = Array.AsReadOnly(new[] { XaiPublisher });
    internal static readonly IReadOnlyList<string> CodexPublishers = Array.AsReadOnly(new[] { OpenAiPublisher, OpenAiOpCoPublisher });
    internal const string CodeSigningOid = "1.3.6.1.5.5.7.3.3";

    internal sealed record SignatureResult(string Status, string? Subject);

    public static void Validate(string path, FileStream lockedFile)
    {
        SignatureResult result = Inspect(path, lockedFile, GrokPublishers);
        if (result.Status != "Valid")
            throw new QuotaReadException(I18n.Get("windows.the.grok.cli.authenticode.signature.is.invalid.or.could.not"));
    }

    internal static void ValidateCodex(string path, FileStream lockedFile)
    {
        if (Inspect(path, lockedFile, CodexPublishers).Status != "Valid")
            throw new QuotaReadException(I18n.Get("windows.codex.signatureRequired"));
    }

    internal static bool MatchesPublisher(X500DistinguishedName subject, IReadOnlyList<string> publishers)
    {
        string? organization = null, commonName = null;
        foreach (X500RelativeDistinguishedName part in subject.EnumerateRelativeDistinguishedNames())
        {
            // Reject ambiguous multi-valued RDNs and duplicate O/CN attributes.
            if (part.HasMultipleElements) return false;
            string? oid = part.GetSingleElementType().Value;
            if (oid == "2.5.4.10")
            {
                if (organization is not null) return false;
                organization = part.GetSingleElementValue();
                if (organization is null) return false;
            }
            else if (oid == "2.5.4.3")
            {
                if (commonName is not null) return false;
                commonName = part.GetSingleElementValue();
                if (commonName is null) return false;
            }
        }
        return publishers.Any(name => string.Equals(organization, name, StringComparison.Ordinal) &&
            string.Equals(commonName, name, StringComparison.Ordinal));
    }

    internal static bool HasCodeSigningEku(X509Certificate2 certificate) => certificate.Extensions
        .OfType<X509EnhancedKeyUsageExtension>().Any(extension => extension.EnhancedKeyUsages
            .Cast<Oid>().Any(oid => oid.Value == CodeSigningOid));

    internal static bool HasTrustedCodeSigningChain(X509Certificate2 certificate)
    {
        if (!HasCodeSigningEku(certificate)) return false;
        using var chain = new X509Chain();
        chain.ChainPolicy.RevocationMode = X509RevocationMode.Online;
        chain.ChainPolicy.RevocationFlag = X509RevocationFlag.ExcludeRoot;
        chain.ChainPolicy.VerificationFlags = X509VerificationFlags.NoFlag;
        chain.ChainPolicy.UrlRetrievalTimeout = TimeSpan.FromSeconds(5);
        chain.ChainPolicy.ApplicationPolicy.Add(new Oid(CodeSigningOid));
        return chain.Build(certificate);
    }

    internal static SignatureResult Inspect(string path, FileStream lockedFile, IReadOnlyList<string> publishers)
    {
        IntPtr filename = Marshal.StringToCoTaskMemUni(path);
        IntPtr fileInfo = IntPtr.Zero;
        var action = new Guid("00AAC56B-CD44-11D0-8CC2-00C04FC295EE");
        var data = new TrustData
        {
            Size = (uint)Marshal.SizeOf<TrustData>(), UiChoice = 2, UnionChoice = 1,
            StateAction = 1, RevocationChecks = 1, ProviderFlags = 0x80 // Online revocation, chain excluding root.
        };
        try
        {
            var file = new TrustFile
            {
                Size = (uint)Marshal.SizeOf<TrustFile>(), Path = filename,
                // WinVerifyTrust cannot hash through the overlapped handle LocalFiles opens (TRUST_E_BAD_DIGEST),
                // so verify by path. lockedFile stays open without write/delete sharing for the whole check
                // and until launch, so the path cannot be replaced in between.
                Handle = IntPtr.Zero
            };
            fileInfo = Marshal.AllocCoTaskMem(Marshal.SizeOf<TrustFile>());
            Marshal.StructureToPtr(file, fileInfo, false);
            data.File = fileInfo;
            int trust = WinVerifyTrust(new IntPtr(-1), ref action, ref data);
            if (trust != 0)
            {
                // Diagnostic only: never use a certificate from this branch to authorize execution.
                string? subject = null;
                try { using X509Certificate signed = X509Certificate.CreateFromSignedFile(path); subject = signed.Subject; }
                catch (CryptographicException) { }
                return new SignatureResult($"InvalidSignature (0x{trust:X8})", subject);
            }
            // Use the signer verified by WinVerifyTrust, not an independently selected embedded certificate.
            IntPtr provider = WTHelperProvDataFromStateData(data.StateData);
            IntPtr signer = provider == IntPtr.Zero ? IntPtr.Zero : WTHelperGetProvSignerFromChain(provider, 0, false, 0);
            IntPtr entry = signer == IntPtr.Zero ? IntPtr.Zero : WTHelperGetProvCertFromChain(signer, 0);
            IntPtr context = entry == IntPtr.Zero ? IntPtr.Zero : Marshal.PtrToStructure<ProviderCertificate>(entry).Certificate;
            if (context == IntPtr.Zero) return new SignatureResult("SignerUnavailable", null);
            using var certificate = new X509Certificate2(context);
            if (!MatchesPublisher(certificate.SubjectName, publishers))
                return new SignatureResult("PublisherNotAllowed", certificate.Subject);
            if (!HasCodeSigningEku(certificate))
                return new SignatureResult("MissingCodeSigningEku", certificate.Subject);
            // WinVerifyTrust (GENERIC_VERIFY_V2, online revocation) already built and validated the chain at the
            // countersigned timestamp. Re-building it against the current clock wrongly rejects timestamped
            // binaries whose signing certificate has since expired (observed with the official codex.exe).
            return new SignatureResult("Valid", certificate.Subject);
        }
        finally
        {
            if (fileInfo != IntPtr.Zero)
            {
                data.StateAction = 2;
                WinVerifyTrust(new IntPtr(-1), ref action, ref data);
                Marshal.FreeCoTaskMem(fileInfo);
            }
            Marshal.FreeCoTaskMem(filename);
        }
    }

    // Only the prefix through pCert is needed from CRYPT_PROVIDER_CERT.
    [StructLayout(LayoutKind.Sequential)]
    private struct ProviderCertificate
    {
        public uint Size;
        public IntPtr Certificate;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct TrustFile
    {
        public uint Size;
        public IntPtr Path;
        public IntPtr Handle;
        public IntPtr KnownSubject;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct TrustData
    {
        public uint Size;
        public IntPtr PolicyCallback;
        public IntPtr SipClient;
        public uint UiChoice;
        public uint RevocationChecks;
        public uint UnionChoice;
        public IntPtr File;
        public uint StateAction;
        public IntPtr StateData;
        public IntPtr UrlReference;
        public uint ProviderFlags;
        public uint UiContext;
        public IntPtr SignatureSettings;
    }

    [DllImport("wintrust.dll", ExactSpelling = true)]
    private static extern int WinVerifyTrust(IntPtr window, ref Guid action, ref TrustData data);

    [DllImport("wintrust.dll", ExactSpelling = true)]
    private static extern IntPtr WTHelperProvDataFromStateData(IntPtr stateData);

    [DllImport("wintrust.dll", ExactSpelling = true)]
    private static extern IntPtr WTHelperGetProvSignerFromChain(IntPtr provider, uint signerIndex,
        [MarshalAs(UnmanagedType.Bool)] bool counterSigner, uint counterSignerIndex);

    [DllImport("wintrust.dll", ExactSpelling = true)]
    private static extern IntPtr WTHelperGetProvCertFromChain(IntPtr signer, uint certificateIndex);
}
