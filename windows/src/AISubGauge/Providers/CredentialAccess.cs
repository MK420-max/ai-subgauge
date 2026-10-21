using System;
using System.IO;
using System.Security.AccessControl;
using System.Security.Principal;

namespace AISubGauge.Providers;

internal enum CredentialKind { Default, Codex }

internal static class CredentialAccess
{
    internal static string UnsafeMessage => I18n.Get("windows.other.users.can.read.the.credential.file.reading.refused.restrict");

    public static void Validate(FileStream file, bool grok = false, CredentialKind kind = CredentialKind.Default,
        string? credentialPath = null)
    {
        using WindowsIdentity identity = WindowsIdentity.GetCurrent();
        SecurityIdentifier user = identity.User ?? throw new QuotaReadException(I18n.Get("windows.could.not.identify.the.current.user.for.the.credential.file"));
        ValidateSecurity(file.GetAccessControl(), user, grok, kind, credentialPath: credentialPath);
    }

    internal static void ValidateDirectorySecurity(RawSecurityDescriptor security, SecurityIdentifier user,
        ILocalGroupInspector? groupInspector = null, string? credentialPath = null)
    {
        bool Trusted(SecurityIdentifier? sid) => sid is not null && (sid.Equals(user) ||
            sid.IsWellKnown(WellKnownSidType.LocalSystemSid) || sid.IsWellKnown(WellKnownSidType.BuiltinAdministratorsSid));
        if (!Trusted(security.Owner) || security.DiscretionaryAcl is null)
            throw new QuotaReadException(UnsafeMessage);
        bool allowCodexSandbox = IsDefaultCodexPath(credentialPath);
        int writes = (int)(FileSystemRights.WriteData | FileSystemRights.AppendData | FileSystemRights.WriteAttributes |
            FileSystemRights.WriteExtendedAttributes | FileSystemRights.Delete | FileSystemRights.DeleteSubdirectoriesAndFiles |
            FileSystemRights.ChangePermissions | FileSystemRights.TakeOwnership) | 0x50000000; // GENERIC_WRITE / ALL
        foreach (GenericAce ace in security.DiscretionaryAcl)
        {
            bool inheritsToFile = (ace.AceFlags & AceFlags.ObjectInherit) != 0;
            bool inheritOnly = (ace.AceFlags & AceFlags.InheritOnly) != 0;
            if (inheritOnly && !inheritsToFile) continue;
            if (ace is not QualifiedAce rule) throw new QuotaReadException(UnsafeMessage);
            // Inherit-only grants still become effective on a newly created auth.json.
            if (inheritsToFile)
                ValidateFileGrant(rule, user, allowCodexSandbox, groupInspector);
            if (!inheritOnly && rule.AceQualifier == AceQualifier.AccessAllowed && !Trusted(rule.SecurityIdentifier) &&
                (rule.AccessMask & writes) != 0)
                throw new QuotaReadException(UnsafeMessage);
        }
    }

    internal static void ValidateSecurity(FileSecurity security, SecurityIdentifier user, bool grok,
        CredentialKind kind = CredentialKind.Default, ILocalGroupInspector? groupInspector = null, string? credentialPath = null)
    {
        var raw = new RawSecurityDescriptor(security.GetSecurityDescriptorBinaryForm(), 0);
        if (raw.DiscretionaryAcl is null) throw new QuotaReadException(UnsafeMessage);
        if (!user.Equals(raw.Owner))
            throw new QuotaReadException(UnsafeMessage);
        bool allowCodexSandbox = kind == CredentialKind.Codex && IsDefaultCodexPath(credentialPath);
        foreach (GenericAce ace in raw.DiscretionaryAcl)
        {
            if ((ace.AceFlags & AceFlags.InheritOnly) != 0) continue;
            // Common/Object ACEs, including callbacks, expose both the qualifier and KnownAce SID/mask.
            // Unknown and Compound ACEs cannot establish a safe grant, even for a trusted SID.
            if (ace is not QualifiedAce rule) throw new QuotaReadException(UnsafeMessage);
            ValidateFileGrant(rule, user, allowCodexSandbox, groupInspector);
        }
    }

    private static void ValidateFileGrant(QualifiedAce rule, SecurityIdentifier user, bool allowCodexSandbox,
        ILocalGroupInspector? groupInspector)
    {
        if (rule.AceQualifier != AceQualifier.AccessAllowed) return;
        SecurityIdentifier sid = rule.SecurityIdentifier;
        var rights = (FileSystemRights)rule.AccessMask;
        bool broad = sid.IsWellKnown(WellKnownSidType.WorldSid) || sid.IsWellKnown(WellKnownSidType.BuiltinUsersSid) ||
            sid.IsWellKnown(WellKnownSidType.AuthenticatedUserSid);
        if (broad && (rights & FileSystemRights.ReadData) != 0)
            throw new QuotaReadException(UnsafeMessage);
        bool trusted = sid.Equals(user) || sid.IsWellKnown(WellKnownSidType.LocalSystemSid) ||
            sid.IsWellKnown(WellKnownSidType.BuiltinAdministratorsSid);
        if (!trusted && allowCodexSandbox)
        {
            const FileSystemRights sandboxRead = FileSystemRights.ReadData | FileSystemRights.ReadExtendedAttributes |
                FileSystemRights.ReadAttributes | FileSystemRights.ReadPermissions | FileSystemRights.ExecuteFile |
                FileSystemRights.Synchronize | unchecked((FileSystemRights)0xA0000000); // GENERIC_READ | GENERIC_EXECUTE
            if ((rights & ~sandboxRead) != 0 ||
                !IsCodexSandboxGroup(sid, groupInspector ?? new WindowsLocalGroupInspector()))
                throw new QuotaReadException(UnsafeMessage);
            return;
        }
        const FileSystemRights sensitive = FileSystemRights.ReadData | FileSystemRights.WriteData | FileSystemRights.AppendData |
            FileSystemRights.Delete | FileSystemRights.ChangePermissions | FileSystemRights.TakeOwnership |
            FileSystemRights.WriteAttributes | FileSystemRights.WriteExtendedAttributes | unchecked((FileSystemRights)0xF0000000);
        if (!trusted && (rights & sensitive) != 0)
            throw new QuotaReadException(UnsafeMessage);
    }

    private static bool IsDefaultCodexPath(string? path)
    {
        if (string.IsNullOrWhiteSpace(path)) return false;
        try
        {
            return LocalFiles.FullPath(path).TrimEnd('\\').Equals(
                LocalFiles.FullPath(CredentialFiles.UserFile(".codex", "auth.json")).TrimEnd('\\'),
                StringComparison.OrdinalIgnoreCase);
        }
        catch (Exception) { return false; } // Unsafe or unverifiable paths never enable the exception.
    }

    private static bool IsCodexSandboxGroup(SecurityIdentifier sid, ILocalGroupInspector inspector)
    {
        try
        {
            if (inspector.GetMachineRole() is not (MachineRole.StandaloneWorkstation or MachineRole.MemberWorkstation or
                MachineRole.StandaloneServer or MachineRole.MemberServer)) return false;
            SecurityIdentifier? machineSid = inspector.GetMachineAccountDomainSid();
            if (machineSid is null || !machineSid.Equals(sid.AccountDomainSid)) return false;
            LocalAccount? group = inspector.LookupAccount(sid);
            if (group is null || (group.Type != SidNameUse.Alias && group.Type != SidNameUse.Group) ||
                !group.Name.Equals("CodexSandboxUsers", StringComparison.OrdinalIgnoreCase)) return false;
            var members = inspector.GetMembers(group.Name);
            if (members is null || members.Count != 2 || members[0].Equals(members[1])) return false;
            bool offline = false, online = false;
            foreach (SecurityIdentifier memberSid in members)
            {
                if (!machineSid.Equals(memberSid.AccountDomainSid)) return false;
                LocalAccount? member = inspector.LookupAccount(memberSid);
                if (member is null || member.Type != SidNameUse.User) return false;
                if (member.Name.Equals("CodexSandboxOffline", StringComparison.OrdinalIgnoreCase)) offline = true;
                else if (member.Name.Equals("CodexSandboxOnline", StringComparison.OrdinalIgnoreCase)) online = true;
                else return false;
            }
            return offline && online;
        }
        catch (Exception) { return false; } // Unavailable or incomplete identity information never grants an exception.
    }

    public static void CheckAfterRefresh(string path)
    {
        // The only permitted modification of auth.json by this application is its DACL after
        // official CLI renewal. Never change its bytes, owner, or another user's credential file.
        using FileStream file = LocalFiles.OpenReadForAclRepair(path, GrokProvider.MaxBytes);
        using WindowsIdentity identity = WindowsIdentity.GetCurrent();
        SecurityIdentifier user = identity.User ?? throw new QuotaReadException(I18n.Get("windows.could.not.verify.grok.credential.permissions"));
        FileSecurity existing = file.GetAccessControl();
        if (!user.Equals(existing.GetOwner(typeof(SecurityIdentifier))))
            throw new QuotaReadException(I18n.Get("windows.the.grok.login.file.owner.changed.after.renewal"));
        try { ValidateSecurity(existing, user, grok: true); }
        catch (QuotaReadException)
        {
            var restricted = new FileSecurity();
            restricted.SetAccessRuleProtection(isProtected: true, preserveInheritance: false);
            restricted.AddAccessRule(new FileSystemAccessRule(user, FileSystemRights.FullControl, AccessControlType.Allow));
            file.SetAccessControl(restricted);
            Validate(file, grok: true);
        }
    }

    internal static void CreatePrivateDirectory(string path)
    {
        using WindowsIdentity identity = WindowsIdentity.GetCurrent();
        SecurityIdentifier user = identity.User ?? throw new QuotaReadException(I18n.Get("windows.could.not.verify.temporary.directory.permissions"));
        var security = new DirectorySecurity();
        security.SetOwner(user);
        security.SetAccessRuleProtection(isProtected: true, preserveInheritance: false);
        security.AddAccessRule(new FileSystemAccessRule(user, FileSystemRights.FullControl,
            InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
        new DirectoryInfo(path).Create(security);
    }
}
