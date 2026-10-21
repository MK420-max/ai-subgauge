using System;
using System.IO;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Threading;
using System.Threading.Tasks;
using AISubGauge.Providers;
using Microsoft.Win32;
using Xunit;

namespace AISubGauge.Tests;

public sealed class SecurityHardeningTests
{
    private static readonly SecurityIdentifier User = new("S-1-5-21-100-200-300-1001");
    private static readonly SecurityIdentifier Other = new("S-1-5-21-100-200-300-1002");

    private static FileSecurity Security(SecurityIdentifier owner, SecurityIdentifier grantee, FileSystemRights rights)
    {
        var security = new FileSecurity();
        security.SetOwner(owner);
        security.SetAccessRuleProtection(true, false);
        security.AddAccessRule(new FileSystemAccessRule(User, FileSystemRights.FullControl, AccessControlType.Allow));
        security.AddAccessRule(new FileSystemAccessRule(grantee, rights, AccessControlType.Allow));
        return security;
    }

    [Theory]
    [InlineData(FileSystemRights.ReadData)]
    [InlineData(FileSystemRights.WriteData)]
    [InlineData(FileSystemRights.AppendData)]
    [InlineData(FileSystemRights.Delete)]
    [InlineData(FileSystemRights.ChangePermissions)]
    [InlineData(FileSystemRights.TakeOwnership)]
    public void EveryServiceRejectsOtherUserReadOrWriteAccess(FileSystemRights rights)
    {
        FileSecurity security = Security(User, Other, rights);
        Assert.Throws<QuotaReadException>(() => CredentialAccess.ValidateSecurity(security, User, grok: false));
        Assert.Throws<QuotaReadException>(() => CredentialAccess.ValidateSecurity(security, User, grok: true));
    }

    [Fact]
    public void EveryServiceRejectsForeignOwnershipAndNullDacl()
    {
        Assert.Throws<QuotaReadException>(() => CredentialAccess.ValidateSecurity(
            Security(Other, User, FileSystemRights.Read), User, grok: false));
        var security = new FileSecurity();
        security.SetSecurityDescriptorSddlForm("O:" + User.Value + "D:NO_ACCESS_CONTROL");
        Assert.Throws<QuotaReadException>(() => CredentialAccess.ValidateSecurity(security, User, grok: false));
    }

    [Fact]
    public void EveryServiceRejectsGenericWriteAndReadGrants()
    {
        foreach (string rights in new[] { "GA", "GR", "GW" })
        {
            var security = new FileSecurity();
            security.SetSecurityDescriptorSddlForm("O:" + User.Value + "D:(A;;FA;;;" + User.Value + ")(A;;" + rights + ";;;" + Other.Value + ")");
            Assert.Throws<QuotaReadException>(() => CredentialAccess.ValidateSecurity(security, User, grok: false));
        }
    }

    [Theory]
    [InlineData(WellKnownSidType.LocalSystemSid)]
    [InlineData(WellKnownSidType.BuiltinAdministratorsSid)]
    public void EveryServiceAllowsExpectedSystemPrincipals(WellKnownSidType kind) =>
        CredentialAccess.ValidateSecurity(Security(User, new SecurityIdentifier(kind, null), FileSystemRights.FullControl), User, grok: false);

    [Theory]
    [InlineData(WellKnownSidType.WorldSid)]
    [InlineData(WellKnownSidType.BuiltinUsersSid)]
    [InlineData(WellKnownSidType.AuthenticatedUserSid)]
    public void StartupRejectsBroadWriteAcesIncludingInheritedOnes(WellKnownSidType kind)
    {
        var broad = new SecurityIdentifier(kind, null);
        FileSecurity security = Security(User, broad, FileSystemRights.Modify);
        var descriptor = new RawSecurityDescriptor(security.GetSecurityDescriptorBinaryForm(), 0);
        Assert.Throws<IOException>(() => LocalFiles.ValidateInstallSecurity(descriptor, User));
        Assert.Throws<IOException>(() => LocalFiles.ValidateInstallSecurity(descriptor, User, ancestor: true));
        var acl = new RawAcl(2, 1);
        acl.InsertAce(0, new CommonAce(AceFlags.Inherited, AceQualifier.AccessAllowed,
            (int)FileSystemRights.DeleteSubdirectoriesAndFiles, broad, false, null));
        descriptor.DiscretionaryAcl = acl;
        Assert.Throws<IOException>(() => LocalFiles.ValidateInstallSecurity(descriptor, User, ancestor: true));
    }

    [Fact]
    public void StartupAllowsPrivateAclButRejectsForeignOwnerAndNullDacl()
    {
        FileSecurity security = Security(User, User, FileSystemRights.FullControl);
        var descriptor = new RawSecurityDescriptor(security.GetSecurityDescriptorBinaryForm(), 0);
        LocalFiles.ValidateInstallSecurity(descriptor, User);
        descriptor.Owner = Other;
        Assert.Throws<IOException>(() => LocalFiles.ValidateInstallSecurity(descriptor, User));
        descriptor.Owner = User;
        descriptor.DiscretionaryAcl = null;
        Assert.Throws<IOException>(() => LocalFiles.ValidateInstallSecurity(descriptor, User));
    }

    [Fact]
    public void StartupAcceptsDriveRootAppendDataAndInheritOnlyModify()
    {
        // The C:\ root grants Authenticated Users create-subdirectory rights on the root,
        // plus Modify for newly inherited children, not Modify on the root itself.
        var descriptor = new RawSecurityDescriptor(
            "O:BAG:BAD:(A;;FA;;;SY)(A;;FA;;;BA)(A;;0x4;;;AU)(A;OICIIO;0x1301bf;;;AU)");
        LocalFiles.ValidateInstallSecurity(descriptor, User, ancestor: true);
        Assert.Throws<IOException>(() => LocalFiles.ValidateInstallSecurity(descriptor, User));
    }

    [Fact]
    public void PrivateFixtureDirectoryBlocksInheritedForeignModifyAces()
    {
        string parent = SettingsAndAutoStartTests.NewDirectory();
        DirectorySecurity security = new DirectoryInfo(parent).GetAccessControl();
        security.AddAccessRule(new FileSystemAccessRule(Other, FileSystemRights.Modify,
            InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
        new DirectoryInfo(parent).SetAccessControl(security);
        string home = Path.Combine(parent, "selftest-home");
        CredentialAccess.CreatePrivateDirectory(home);
        Assert.True(new DirectoryInfo(home).GetAccessControl().AreAccessRulesProtected);
        string path = Path.Combine(home, "synthetic.json");
        File.WriteAllText(path, "synthetic credential fixture");
        using FileStream file = LocalFiles.OpenRead(path, 1024);
        CredentialAccess.Validate(file, grok: false);
        CredentialAccess.Validate(file, grok: true);
    }

    [Theory]
    [InlineData("ancestor")]
    [InlineData("directory")]
    [InlineData("executable")]
    public void UnsafeStartupDoesNotWriteRunAndRemovesRecognizedOldEntries(string unsafeTarget)
    {
        string subkey = @"Software\AISubGauge.Tests\" + Guid.NewGuid().ToString("N");
        try
        {
            using RegistryKey key = Registry.CurrentUser.CreateSubKey(subkey);
            string root = SettingsAndAutoStartTests.NewDirectory();
            string installation = Path.Combine(root, "Programs", "AISubGauge");
            CredentialAccess.CreatePrivateDirectory(installation);
            string exe = Path.Combine(installation, "AISubGauge.exe");
            File.WriteAllText(exe, "synthetic executable fixture");
            var auto = new AutoStart(key, installationRoot: installation, trustedAncestor: root);
            string outside = Path.Combine(root, "AISubGauge.exe");
            File.WriteAllText(outside, "synthetic executable fixture");
            Assert.Throws<IOException>(() => auto.Apply(true, outside));
            Assert.Null(auto.Command);
            var rule = new FileSystemAccessRule(new SecurityIdentifier(WellKnownSidType.WorldSid, null),
                FileSystemRights.WriteData, AccessControlType.Allow);
            if (unsafeTarget != "executable")
            {
                string target = unsafeTarget == "ancestor" ? root : installation;
                DirectorySecurity security = new DirectoryInfo(target).GetAccessControl();
                security.AddAccessRule(rule);
                new DirectoryInfo(target).SetAccessControl(security);
            }
            else
            {
                FileSecurity security = new FileInfo(exe).GetAccessControl();
                security.AddAccessRule(rule);
                new FileInfo(exe).SetAccessControl(security);
            }
            key.SetValue("WindowsQuotaTray", "\"C:\\Old App\\WindowsQuotaTray.exe\"");
            key.SetValue("AISubGauge", "\"C:\\Old App\\AISubGauge.exe\"");
            key.SetValue("UnrelatedValue", "\"C:\\Old App\\WindowsQuotaTray.exe\"");
            Assert.Throws<IOException>(() => auto.Migrate(exe));
            Assert.Null(key.GetValue("WindowsQuotaTray"));
            Assert.True(auto.LegacyRemoved);
            Assert.Null(auto.Command);
            Assert.NotNull(key.GetValue("UnrelatedValue"));
            key.SetValue("WindowsQuotaTray", "\"C:\\Other\\other.exe\"");
            key.SetValue("AISubGauge", "\"C:\\Other\\other.exe\"");
            Assert.Throws<IOException>(() => auto.Apply(true, exe));
            Assert.NotNull(key.GetValue("WindowsQuotaTray"));
            Assert.Equal("\"C:\\Other\\other.exe\"", auto.Command);
            auto.Apply(false, outside); // Disabling must work even from an unprotected copy.
        }
        finally { Registry.CurrentUser.DeleteSubKeyTree(subkey, false); }
    }

    [Fact]
    public async Task StreamingReadAbortsAtLimitPlusOneRatherThanTheEntireInput()
    {
        using var stream = new MemoryStream(new byte[100_000]);
        await Assert.ThrowsAsync<QuotaReadException>(() => GrokProvider.ReadBoundedAsync(stream, 10_000, CancellationToken.None));
        Assert.Equal(10_001L, stream.Position);
        stream.Position = 0;
        Assert.Throws<InvalidDataException>(() => SharedResources.ReadBounded(new MemoryStream(new byte[SharedResources.MaxBytes + 1])));
    }

    [Fact]
    public void OversizedSettingsAreRejectedBeforeMigrationAndOriginalIsPreserved()
    {
        string root = SettingsAndAutoStartTests.NewDirectory();
        string legacy = Path.Combine(root, "WindowsQuotaTray", "settings.json");
        Directory.CreateDirectory(Path.GetDirectoryName(legacy)!);
        byte[] bytes = new byte[SharedResources.MaxBytes + 1];
        File.WriteAllBytes(legacy, bytes);
        Assert.Null(AppSettings.Load(root).LaunchAtLogin);
        Assert.Equal(bytes, File.ReadAllBytes(legacy));
        Assert.False(File.Exists(Path.Combine(root, "AISubGauge", "settings.json")));
    }
}
