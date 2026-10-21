using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Security.AccessControl;
using System.Security.Principal;
using AISubGauge.Providers;
using Xunit;

namespace AISubGauge.Tests;

public sealed class CodexCredentialAccessTests
{
    private static readonly SecurityIdentifier Machine = new("S-1-5-21-100-200-300");
    private static readonly SecurityIdentifier User = new("S-1-5-21-100-200-300-1001");
    private static readonly SecurityIdentifier Group = new("S-1-5-21-100-200-300-1002");
    private static readonly SecurityIdentifier Offline = new("S-1-5-21-100-200-300-1003");
    private static readonly SecurityIdentifier Online = new("S-1-5-21-100-200-300-1004");
    private static readonly SecurityIdentifier Other = new("S-1-5-21-100-200-300-1005");
    private static readonly SecurityIdentifier Foreign = new("S-1-5-21-400-500-600-1002");
    private const int ReadExecute = (int)(FileSystemRights.ReadAndExecute | FileSystemRights.Synchronize);
    private static string DefaultPath => CredentialFiles.UserFile(".codex", "auth.json");

    private static FileSecurity Security(int mask = ReadExecute, SecurityIdentifier? grantee = null, AceFlags flags = AceFlags.None) =>
        Security(new CommonAce(flags, AceQualifier.AccessAllowed, mask, grantee ?? Group, false, null));

    private static FileSecurity Security(GenericAce ace)
    {
        var acl = new RawAcl(GenericAcl.AclRevisionDS, 2);
        acl.InsertAce(0, new CommonAce(AceFlags.None, AceQualifier.AccessAllowed,
            (int)FileSystemRights.FullControl, User, false, null));
        acl.InsertAce(1, ace);
        var raw = new RawSecurityDescriptor(ControlFlags.DiscretionaryAclPresent | ControlFlags.DiscretionaryAclProtected,
            User, null, null, acl);
        var bytes = new byte[raw.BinaryLength];
        raw.GetBinaryForm(bytes, 0);
        var security = new FileSecurity();
        security.SetSecurityDescriptorBinaryForm(bytes);
        return security;
    }

    private static void Validate(FileSecurity security, FakeInspector inspector) =>
        CredentialAccess.ValidateSecurity(security, User, grok: false, kind: CredentialKind.Codex,
            groupInspector: inspector, credentialPath: DefaultPath);

    private static void Reject(FileSecurity security, FakeInspector inspector)
    {
        byte[] before = security.GetSecurityDescriptorBinaryForm();
        QuotaReadException error = Assert.Throws<QuotaReadException>(() => Validate(security, inspector));
        Assert.Equal(CredentialAccess.UnsafeMessage, error.Message);
        Assert.Equal(before, security.GetSecurityDescriptorBinaryForm());
    }

    private static RawSecurityDescriptor DirectoryGrant(GenericAce ace)
    {
        var directory = new RawSecurityDescriptor(Security(grantee: User).GetSecurityDescriptorBinaryForm(), 0);
        directory.DiscretionaryAcl!.InsertAce(0, ace);
        return directory;
    }

    [Theory]
    [InlineData((int)FileSystemRights.ReadData)]
    [InlineData((int)FileSystemRights.WriteData)]
    [InlineData((int)FileSystemRights.AppendData)]
    [InlineData(unchecked((int)0x80000000))] // GENERIC_READ
    [InlineData(0x40000000)] // GENERIC_WRITE
    [InlineData(0x10000000)] // GENERIC_ALL
    public void CodexDirectoryRejectsUntrustedFileInheritanceIncludingInheritOnly(int mask)
    {
        foreach (AceFlags flags in new[] { AceFlags.ObjectInherit, AceFlags.ObjectInherit | AceFlags.InheritOnly,
            AceFlags.ObjectInherit | AceFlags.ContainerInherit | AceFlags.InheritOnly | AceFlags.Inherited })
        foreach (SecurityIdentifier sid in new[] { Other, Group, new SecurityIdentifier(WellKnownSidType.WorldSid, null),
            new SecurityIdentifier(WellKnownSidType.BuiltinUsersSid, null),
            new SecurityIdentifier(WellKnownSidType.AuthenticatedUserSid, null) })
        {
            var directory = DirectoryGrant(new CommonAce(flags, AceQualifier.AccessAllowed, mask, sid, false, null));
            directory.DiscretionaryAcl!.InsertAce(0, new CommonAce(flags, AceQualifier.AccessDenied, mask, sid, false, null));
            Assert.Throws<QuotaReadException>(() => CredentialAccess.ValidateDirectorySecurity(directory, User,
                groupInspector: new FakeInspector(), credentialPath: CredentialFiles.UserFile("custom-codex", "auth.json")));
        }
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void CodexDirectoryUsesDefaultPathAndVerifiedReadOnlySandboxException(bool inheritOnly)
    {
        AceFlags flags = AceFlags.ObjectInherit | (inheritOnly ? AceFlags.InheritOnly : AceFlags.None);
        var directory = DirectoryGrant(new CommonAce(flags, AceQualifier.AccessAllowed, ReadExecute, Group, false, null));
        string before = directory.GetSddlForm(AccessControlSections.All);
        var inspector = new FakeInspector();
        CredentialAccess.ValidateDirectorySecurity(directory, User, inspector, DefaultPath);
        Assert.True(inspector.Calls > 0);
        Assert.Equal(before, directory.GetSddlForm(AccessControlSections.All));
        foreach (string? path in new[] { null, CredentialFiles.UserFile("custom-codex", "auth.json") })
        {
            inspector = new FakeInspector();
            Assert.Throws<QuotaReadException>(() => CredentialAccess.ValidateDirectorySecurity(directory, User, inspector, path));
            Assert.Equal(0, inspector.Calls);
        }
        Assert.Throws<QuotaReadException>(() => CredentialAccess.ValidateDirectorySecurity(directory, User,
            new FakeInspector { Members = new[] { Offline, Online, Other } }, DefaultPath));
        Assert.Throws<QuotaReadException>(() => CredentialAccess.ValidateDirectorySecurity(directory, User,
            new FakeInspector { FailAt = "lookup" }, DefaultPath));
        foreach (int mask in new[] { (int)FileSystemRights.WriteData, (int)FileSystemRights.WriteAttributes,
            (int)FileSystemRights.DeleteSubdirectoriesAndFiles, 0x40000000, 0x10000000, 0x01000000 })
        {
            directory = DirectoryGrant(new CommonAce(flags, AceQualifier.AccessAllowed, ReadExecute | mask, Group, false, null));
            Assert.Throws<QuotaReadException>(() => CredentialAccess.ValidateDirectorySecurity(directory, User,
                new FakeInspector(), DefaultPath));
        }
        directory = DirectoryGrant(new CommonAce(flags, AceQualifier.AccessAllowed, ReadExecute, Foreign, false, null));
        inspector = new FakeInspector();
        inspector.Accounts[Foreign] = new LocalAccount("CodexSandboxUsers", SidNameUse.Alias);
        Assert.Throws<QuotaReadException>(() => CredentialAccess.ValidateDirectorySecurity(directory, User, inspector, DefaultPath));
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void CodexDirectoryChecksObjectAndCallbackFileInheritance(bool callback)
    {
        AceFlags flags = AceFlags.ObjectInherit | AceFlags.InheritOnly;
        foreach (GenericAce ace in new GenericAce[]
        {
            new CommonAce(flags, AceQualifier.AccessAllowed, ReadExecute, Other, callback, null),
            new ObjectAce(flags, AceQualifier.AccessAllowed, ReadExecute, Other,
                ObjectAceFlags.None, Guid.Empty, Guid.Empty, callback, null),
            new CustomAce((AceType)0x7f, flags, new byte[4]),
            new CompoundAce(flags, ReadExecute, CompoundAceType.Impersonation, User)
        })
            Assert.Throws<QuotaReadException>(() => CredentialAccess.ValidateDirectorySecurity(DirectoryGrant(ace), User,
                new FakeInspector(), DefaultPath));
    }

    [Theory]
    [InlineData((int)FileSystemRights.ReadData)]
    [InlineData((int)FileSystemRights.ReadExtendedAttributes)]
    [InlineData((int)FileSystemRights.ReadAttributes)]
    [InlineData((int)FileSystemRights.ReadPermissions)]
    [InlineData((int)FileSystemRights.ExecuteFile)]
    [InlineData((int)FileSystemRights.Synchronize)]
    [InlineData(ReadExecute)]
    [InlineData(unchecked((int)0x80000000))] // GENERIC_READ
    [InlineData(0x20000000)] // GENERIC_EXECUTE
    [InlineData(unchecked((int)0xA0000000))]
    public void CodexAllowsOnlyReadBitsForVerifiedSandboxGroupWithoutChangingSecurity(int mask)
    {
        FileSecurity security = Security(mask);
        byte[] before = security.GetSecurityDescriptorBinaryForm();
        var inspector = new FakeInspector();
        Validate(security, inspector);
        Assert.True(inspector.Calls > 0);
        Assert.Equal(before, security.GetSecurityDescriptorBinaryForm());
        foreach (AceFlags flags in new[] { AceFlags.ObjectInherit, AceFlags.ObjectInherit | AceFlags.InheritOnly })
        {
            var directory = DirectoryGrant(new CommonAce(flags, AceQualifier.AccessAllowed, mask, Group, false, null));
            string beforeDirectory = directory.GetSddlForm(AccessControlSections.All);
            inspector = new FakeInspector();
            CredentialAccess.ValidateDirectorySecurity(directory, User, inspector, DefaultPath);
            Assert.True(inspector.Calls > 0);
            Assert.Equal(beforeDirectory, directory.GetSddlForm(AccessControlSections.All));
        }
    }

    [Fact]
    public void DefaultCodexDirectoryAllowsSandboxReadAndExecuteWithoutChangingSecurity()
    {
        FileSecurity security = Security(); // Synthetic CodexSandboxUsers ReadAndExecute | Synchronize.
        byte[] before = security.GetSecurityDescriptorBinaryForm();
        var directory = new RawSecurityDescriptor(before, 0);
        CredentialAccess.ValidateDirectorySecurity(directory, User);
        Validate(security, new FakeInspector()); // The default auth.json retains its stricter group check.
        var after = new byte[directory.BinaryLength];
        directory.GetBinaryForm(after, 0);
        Assert.Equal(before, after);
    }

    [Theory]
    [InlineData((int)FileSystemRights.WriteData)]
    [InlineData((int)FileSystemRights.AppendData)]
    [InlineData((int)FileSystemRights.WriteAttributes)]
    [InlineData((int)FileSystemRights.WriteExtendedAttributes)]
    [InlineData((int)FileSystemRights.Delete)]
    [InlineData((int)FileSystemRights.DeleteSubdirectoriesAndFiles)]
    [InlineData((int)FileSystemRights.ChangePermissions)]
    [InlineData((int)FileSystemRights.TakeOwnership)]
    [InlineData(0x40000000)] // GENERIC_WRITE
    [InlineData(0x10000000)] // GENERIC_ALL
    public void CodexDirectoryRejectsEveryUntrustedWriteBitIncludingInheritedGrants(int mask)
    {
        foreach (AceFlags flags in new[] { AceFlags.None, AceFlags.Inherited })
        {
            var directory = new RawSecurityDescriptor(Security(mask, flags: flags).GetSecurityDescriptorBinaryForm(), 0);
            // A deny ACE must not hide the unsafe allow grant.
            directory.DiscretionaryAcl!.InsertAce(0, new CommonAce(AceFlags.None, AceQualifier.AccessDenied, mask, Group, false, null));
            Assert.Throws<QuotaReadException>(() => CredentialAccess.ValidateDirectorySecurity(directory, User));
        }
    }

    [Theory]
    [InlineData(WellKnownSidType.LocalSystemSid)]
    [InlineData(WellKnownSidType.BuiltinAdministratorsSid)]
    public void CodexDirectoryAllowsSystemOwnersAndWriters(WellKnownSidType kind)
    {
        var system = new SecurityIdentifier(kind, null);
        var directory = new RawSecurityDescriptor(Security((int)FileSystemRights.FullControl, system).GetSecurityDescriptorBinaryForm(), 0);
        directory.Owner = system;
        CredentialAccess.ValidateDirectorySecurity(directory, User);
    }

    [Fact]
    public void CodexDirectoryRejectsForeignOwnerAndNullDacl()
    {
        var directory = new RawSecurityDescriptor(Security().GetSecurityDescriptorBinaryForm(), 0);
        directory.Owner = Other;
        Assert.Throws<QuotaReadException>(() => CredentialAccess.ValidateDirectorySecurity(directory, User));
        directory.Owner = User;
        directory.DiscretionaryAcl = null;
        Assert.Throws<QuotaReadException>(() => CredentialAccess.ValidateDirectorySecurity(directory, User));
    }

    [Theory]
    [InlineData((int)SidNameUse.Alias)]
    [InlineData((int)SidNameUse.Group)]
    public void CodexAllowsInheritedReadForLocalGroupInEitherMemberOrder(int type)
    {
        var inspector = new FakeInspector { Members = new[] { Online, Offline } };
        inspector.Accounts[Group] = new LocalAccount("CodexSandboxUsers", (SidNameUse)type);
        Validate(Security(flags: AceFlags.Inherited), inspector);
    }

    [Theory]
    [InlineData((int)FileSystemRights.WriteData)]
    [InlineData((int)FileSystemRights.AppendData)]
    [InlineData((int)FileSystemRights.WriteAttributes)]
    [InlineData((int)FileSystemRights.WriteExtendedAttributes)]
    [InlineData((int)FileSystemRights.Delete)]
    [InlineData((int)FileSystemRights.DeleteSubdirectoriesAndFiles)]
    [InlineData((int)FileSystemRights.ChangePermissions)]
    [InlineData((int)FileSystemRights.TakeOwnership)]
    [InlineData(0x40000000)] // GENERIC_WRITE
    [InlineData(0x10000000)] // GENERIC_ALL
    [InlineData(0x01000000)] // ACCESS_SYSTEM_SECURITY is outside the read allowlist too.
    public void CodexRejectsEveryWriteOrUnlistedBitEvenForVerifiedGroup(int mask)
    {
        Reject(Security(mask), new FakeInspector());
        Reject(Security(mask | ReadExecute, flags: AceFlags.Inherited), new FakeInspector());
    }

    [Theory]
    [InlineData(false, false, (int)FileSystemRights.ReadData)]
    [InlineData(false, false, (int)FileSystemRights.WriteData)]
    [InlineData(false, true, (int)FileSystemRights.ReadData)]
    [InlineData(false, true, (int)FileSystemRights.WriteData)]
    [InlineData(true, false, (int)FileSystemRights.ReadData)]
    [InlineData(true, false, (int)FileSystemRights.WriteData)]
    [InlineData(true, true, (int)FileSystemRights.ReadData)]
    [InlineData(true, true, (int)FileSystemRights.WriteData)]
    public void AllServicesRejectOtherUserObjectAndCallbackAllowAces(bool grok, bool callback, int mask)
    {
        foreach (GenericAce ace in new GenericAce[]
        {
            new ObjectAce(AceFlags.None, AceQualifier.AccessAllowed, mask, Other,
                ObjectAceFlags.None, Guid.Empty, Guid.Empty, callback, null),
            new CommonAce(AceFlags.None, AceQualifier.AccessAllowed, mask, Other, callback, null)
        })
        {
            FileSecurity security = Security(ace);
            var raw = new RawSecurityDescriptor(security.GetSecurityDescriptorBinaryForm(), 0);
            Assert.Equal(ace.AceType, raw.DiscretionaryAcl![1].AceType);
            Assert.Throws<QuotaReadException>(() => CredentialAccess.ValidateSecurity(security, User, grok));
            Reject(security, new FakeInspector());
        }
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void CodexChecksObjectAllowMasksForVerifiedGroup(bool callback)
    {
        Validate(Security(new ObjectAce(AceFlags.Inherited, AceQualifier.AccessAllowed, ReadExecute, Group,
            ObjectAceFlags.None, Guid.Empty, Guid.Empty, callback, null)), new FakeInspector());
        Reject(Security(new ObjectAce(AceFlags.Inherited, AceQualifier.AccessAllowed,
            ReadExecute | (int)FileSystemRights.WriteData, Group,
            ObjectAceFlags.None, Guid.Empty, Guid.Empty, callback, null)), new FakeInspector());
    }

    [Fact]
    public void AllServicesRejectUnknownAndCompoundAcesEvenForOwner()
    {
        foreach (GenericAce ace in new GenericAce[]
        {
            new CustomAce((AceType)0x7f, AceFlags.None, new byte[4]),
            new CompoundAce(AceFlags.None, (int)FileSystemRights.ReadData, CompoundAceType.Impersonation, User)
        })
        {
            FileSecurity security = Security(ace);
            var raw = new RawSecurityDescriptor(security.GetSecurityDescriptorBinaryForm(), 0);
            Assert.Equal(ace.AceType, raw.DiscretionaryAcl![1].AceType);
            Assert.Throws<QuotaReadException>(() => CredentialAccess.ValidateSecurity(security, User, grok: false));
            Assert.Throws<QuotaReadException>(() => CredentialAccess.ValidateSecurity(security, User, grok: true));
            Assert.Throws<QuotaReadException>(() => CredentialAccess.ValidateDirectorySecurity(raw, User));
            Reject(security, new FakeInspector());
        }
    }

    [Theory]
    [InlineData((int)MachineRole.BackupDomainController)]
    [InlineData((int)MachineRole.PrimaryDomainController)]
    [InlineData(6)]
    [InlineData(null)]
    public void CodexRejectsDomainControllerOrUnknownRoleBeforeAccountDomainQuery(int? role)
    {
        var inspector = new FakeInspector { Role = role is null ? null : (MachineRole)role.Value };
        Reject(Security(), inspector);
        Assert.Equal(1, inspector.Calls);
    }

    [Theory]
    [InlineData((int)MachineRole.StandaloneWorkstation)]
    [InlineData((int)MachineRole.MemberWorkstation)]
    [InlineData((int)MachineRole.StandaloneServer)]
    [InlineData((int)MachineRole.MemberServer)]
    public void CodexAllowsVerifiedGroupOnNonDomainController(int role) =>
        Validate(Security(), new FakeInspector { Role = (MachineRole)role });

    [Fact]
    public void CodexDefaultPathComparisonNormalizesCaseSegmentsAndTrailingSeparators()
    {
        foreach (string path in new[] { DefaultPath, DefaultPath.ToUpperInvariant(), DefaultPath + "\\",
            DefaultPath.Replace('\\', '/') + "/", CredentialFiles.UserFile(".codex", "unused", "..", "auth.json") })
            CredentialAccess.ValidateSecurity(Security(), User, grok: false, kind: CredentialKind.Codex,
                groupInspector: new FakeInspector(), credentialPath: path);
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData(@".\.codex\auth.json")]
    [InlineData(@"C:auth.json")]
    [InlineData(@"\\server\share\.codex\auth.json")]
    public void CodexRejectsMissingOrUnsafePathWithoutInspectingGroup(string? path)
    {
        var inspector = new FakeInspector();
        Assert.Throws<QuotaReadException>(() => CredentialAccess.ValidateSecurity(Security(), User, grok: false,
            kind: CredentialKind.Codex, groupInspector: inspector, credentialPath: path));
        Assert.Equal(0, inspector.Calls);
    }

    [Fact]
    public void CodexHomeElsewhereUsesStrictValidation()
    {
        string? saved = Environment.GetEnvironmentVariable("CODEX_HOME");
        try
        {
            foreach (string home in new[] { CredentialFiles.UserFile("custom-codex"),
                CredentialFiles.UserFile(".codex-other"), CredentialFiles.UserFile(".codex", "nested") })
            {
                Environment.SetEnvironmentVariable("CODEX_HOME", home);
                var inspector = new FakeInspector();
                Assert.Throws<QuotaReadException>(() => CredentialAccess.ValidateSecurity(Security(), User, grok: false,
                    kind: CredentialKind.Codex, groupInspector: inspector, credentialPath: CredentialFiles.CodexPath));
                Assert.Equal(0, inspector.Calls);
                CredentialAccess.ValidateSecurity(Security(grantee: User), User, grok: false,
                    kind: CredentialKind.Codex, groupInspector: inspector, credentialPath: CredentialFiles.CodexPath);
            }
            Environment.SetEnvironmentVariable("CODEX_HOME", Path.GetDirectoryName(DefaultPath));
            CredentialAccess.ValidateSecurity(Security(), User, grok: false, kind: CredentialKind.Codex,
                groupInspector: new FakeInspector(), credentialPath: CredentialFiles.CodexPath);
        }
        finally { Environment.SetEnvironmentVariable("CODEX_HOME", saved); }
    }

    [Fact]
    public void CodexRejectsExtraMember() =>
        Reject(Security(), new FakeInspector { Members = new[] { Offline, Online, Other } });

    [Fact]
    public void CodexRejectsMissingOrDuplicateMembers()
    {
        Reject(Security(), new FakeInspector { Members = Array.Empty<SecurityIdentifier>() });
        Reject(Security(), new FakeInspector { Members = new[] { Offline } });
        Reject(Security(), new FakeInspector { Members = new[] { Offline, Offline } });
        var inspector = new FakeInspector();
        inspector.Accounts[Online] = new LocalAccount("CodexSandboxOffline", SidNameUse.User);
        Reject(Security(), inspector);
    }

    [Theory]
    [InlineData((int)SidNameUse.Alias)]
    [InlineData((int)SidNameUse.Group)]
    public void CodexRejectsSameNamedForeignAliasOrDomainGroup(int type)
    {
        var inspector = new FakeInspector();
        inspector.Accounts[Foreign] = new LocalAccount("CodexSandboxUsers", (SidNameUse)type);
        Reject(Security(grantee: Foreign), inspector);
    }

    [Theory]
    [InlineData("DifferentGroup", (int)SidNameUse.Alias)]
    [InlineData("CodexSandboxUsers", (int)SidNameUse.User)]
    [InlineData("CodexSandboxUsers", (int)SidNameUse.Domain)]
    [InlineData("CodexSandboxUsers", (int)SidNameUse.Unknown)]
    public void CodexRejectsWrongGroupNameOrAccountType(string name, int type)
    {
        var inspector = new FakeInspector();
        inspector.Accounts[Group] = new LocalAccount(name, (SidNameUse)type);
        Reject(Security(), inspector);
    }

    [Fact]
    public void CodexRejectsDomainUserEvenWithExpectedName()
    {
        var inspector = new FakeInspector { Members = new[] { Offline, Foreign } };
        inspector.Accounts[Foreign] = new LocalAccount("CodexSandboxOnline", SidNameUse.User);
        Reject(Security(), inspector);
    }

    [Theory]
    [InlineData("OtherUser", (int)SidNameUse.User)]
    [InlineData("CodexSandboxOnline", (int)SidNameUse.Alias)]
    [InlineData("CodexSandboxOnline", (int)SidNameUse.Group)]
    [InlineData("CodexSandboxOnline", (int)SidNameUse.Unknown)]
    public void CodexRejectsWrongMemberNameOrNonUserMember(string name, int type)
    {
        var inspector = new FakeInspector();
        inspector.Accounts[Online] = new LocalAccount(name, (SidNameUse)type);
        Reject(Security(), inspector);
    }

    [Fact]
    public void CodexRejectsMissingIdentityOrIncompleteMembershipInformation()
    {
        Reject(Security(), new FakeInspector { MachineSid = null });
        Reject(Security(), new FakeInspector { Members = null });
        var inspector = new FakeInspector();
        inspector.Accounts.Remove(Group);
        Reject(Security(), inspector);
        inspector = new FakeInspector();
        inspector.Accounts.Remove(Online);
        Reject(Security(), inspector);
    }

    [Theory]
    [InlineData("role")]
    [InlineData("machine")]
    [InlineData("lookup")]
    [InlineData("members")]
    [InlineData("member-lookup")]
    public void CodexRejectsInspectorQueryFailure(string step) =>
        Reject(Security(), new FakeInspector { FailAt = step });

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void DefaultAndGrokValidationRejectSameAceWithoutInspectingGroup(bool grok)
    {
        var inspector = new FakeInspector();
        Assert.Throws<QuotaReadException>(() => CredentialAccess.ValidateSecurity(Security(), User, grok, groupInspector: inspector));
        Assert.Equal(0, inspector.Calls);
    }

    [Fact]
    public void CodexStillRejectsForeignOwnerAndNullDacl()
    {
        FileSecurity security = Security();
        security.SetOwner(Other);
        Reject(security, new FakeInspector());
        security = new FileSecurity();
        security.SetSecurityDescriptorSddlForm("O:" + User.Value + "D:NO_ACCESS_CONTROL");
        Reject(security, new FakeInspector());
    }

    [Fact]
    public void ValidGroupDoesNotAuthorizeAnotherAce()
    {
        FileSecurity security = Security();
        security.AddAccessRule(new FileSystemAccessRule(Other, FileSystemRights.ReadData, AccessControlType.Allow));
        Reject(security, new FakeInspector());
        security = Security();
        security.AddAccessRule(new FileSystemAccessRule(Group, FileSystemRights.WriteData, AccessControlType.Allow));
        Reject(security, new FakeInspector());
    }

    [Fact]
    public void PrivateCodexCredentialDoesNotRequireGroupQueries()
    {
        var inspector = new FakeInspector { FailAt = "machine" };
        Validate(Security(grantee: User), inspector);
        Assert.Equal(0, inspector.Calls);
    }

    private sealed class FakeInspector : ILocalGroupInspector
    {
        public MachineRole? Role { get; set; } = MachineRole.StandaloneWorkstation;
        public SecurityIdentifier? MachineSid { get; set; } = Machine;
        public IReadOnlyList<SecurityIdentifier>? Members { get; set; } = new[] { Offline, Online };
        public Dictionary<SecurityIdentifier, LocalAccount> Accounts { get; } = new()
        {
            [Group] = new LocalAccount("CodexSandboxUsers", SidNameUse.Alias),
            [Offline] = new LocalAccount("CodexSandboxOffline", SidNameUse.User),
            [Online] = new LocalAccount("CodexSandboxOnline", SidNameUse.User)
        };
        public int Calls { get; private set; }
        public string? FailAt { get; set; }

        private void Query(string step)
        {
            Calls++;
            if (FailAt == step) throw new Win32Exception(5);
        }

        public SecurityIdentifier? GetMachineAccountDomainSid() { Query("machine"); return MachineSid; }

        public MachineRole? GetMachineRole() { Query("role"); return Role; }

        public LocalAccount? LookupAccount(SecurityIdentifier sid)
        {
            Query(sid.Equals(Group) ? "lookup" : "member-lookup");
            return Accounts.TryGetValue(sid, out LocalAccount? account) ? account : null;
        }

        public IReadOnlyList<SecurityIdentifier>? GetMembers(string localGroupName)
        {
            Query("members");
            Assert.Equal("CodexSandboxUsers", localGroupName);
            return Members;
        }
    }
}
