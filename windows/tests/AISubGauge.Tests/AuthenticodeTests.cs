using System;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using AISubGauge.Providers;
using Xunit;

namespace AISubGauge.Tests;

public sealed class AuthenticodeTests
{
    [Theory]
    [InlineData("CN=X.AI LLC, O=X.AI LLC, C=US", true)]
    [InlineData("C=US, O=X.AI LLC, CN=X.AI LLC", true)]
    [InlineData("CN=Evil X.AI LLC Fan, O=Evil", false)]
    [InlineData("CN=X.AI LLC, O=Evil X.AI LLC", false)]
    [InlineData("CN=Evil, O=X.AI LLC", false)]
    [InlineData("CN=x.ai llc, O=X.AI LLC", false)]
    [InlineData("CN=X.AI LLC, O=x.ai llc", false)]
    [InlineData("CN=X.AI LLC", false)]
    [InlineData("O=X.AI LLC", false)]
    [InlineData("CN=xAI, O=xAI", false)]
    [InlineData("CN=SpaceX, O=SpaceX", false)]
    [InlineData("CN=X.AI LLC, CN=Evil, O=X.AI LLC", false)]
    [InlineData("CN=X.AI LLC, O=X.AI LLC, O=Evil", false)]
    [InlineData("CN=\"X.AI LLC, O=X.AI LLC\", O=Evil", false)]
    public void GrokRequiresExactCaseSensitiveOrganizationAndCommonName(string subject, bool expected) =>
        Assert.Equal(expected, Authenticode.MatchesPublisher(new X500DistinguishedName(subject), Authenticode.GrokPublishers));

    [Theory]
    [InlineData("CN=\"OpenAI, L.L.C.\", O=\"OpenAI, L.L.C.\", C=US", true)]
    [InlineData("CN=\"OpenAI OpCo, LLC\", O=\"OpenAI OpCo, LLC\", C=US", true)]
    [InlineData("CN=\"OpenAI, L.L.C. Fan\", O=Evil", false)]
    [InlineData("CN=\"OpenAI, L.L.C.\", O=\"OpenAI OpCo, LLC\"", false)]
    [InlineData("CN=\"openai, l.l.c.\", O=\"OpenAI, L.L.C.\"", false)]
    [InlineData("CN=X.AI LLC, O=X.AI LLC", false)]
    public void CodexUsesItsOwnExactPublisherAllowlist(string subject, bool expected) =>
        Assert.Equal(expected, Authenticode.MatchesPublisher(new X500DistinguishedName(subject), Authenticode.CodexPublishers));

    [Theory]
    [InlineData(null, false)]
    [InlineData("1.3.6.1.5.5.7.3.1", false)]
    [InlineData(Authenticode.CodeSigningOid, true)]
    public void LeafCertificateMustExplicitlyIncludeCodeSigningEku(string? eku, bool expected)
    {
        using RSA key = RSA.Create(2048);
        var request = new CertificateRequest("CN=X.AI LLC, O=X.AI LLC", key, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        if (eku is not null)
            request.CertificateExtensions.Add(new X509EnhancedKeyUsageExtension(new OidCollection { new Oid(eku) }, true));
        using X509Certificate2 certificate = request.CreateSelfSigned(DateTimeOffset.UtcNow.AddMinutes(-1), DateTimeOffset.UtcNow.AddDays(1));
        Assert.Equal(expected, Authenticode.HasCodeSigningEku(certificate));
        Assert.False(Authenticode.HasTrustedCodeSigningChain(certificate)); // A matching self-signed leaf is still untrusted.
    }
}
