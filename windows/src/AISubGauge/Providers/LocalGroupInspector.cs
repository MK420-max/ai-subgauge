using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;

namespace AISubGauge.Providers;

// Numeric values are the Win32 SID_NAME_USE values returned by LookupAccountSidW.
internal enum SidNameUse { User = 1, Group = 2, Domain = 3, Alias = 4, Unknown = 8 }

// Numeric values are the Win32 DSROLE_MACHINE_ROLE values.
internal enum MachineRole
{
    StandaloneWorkstation = 0, MemberWorkstation = 1, StandaloneServer = 2, MemberServer = 3,
    BackupDomainController = 4, PrimaryDomainController = 5
}

internal sealed record LocalAccount(string Name, SidNameUse Type);

internal interface ILocalGroupInspector
{
    MachineRole? GetMachineRole();
    SecurityIdentifier? GetMachineAccountDomainSid();
    LocalAccount? LookupAccount(SecurityIdentifier sid);
    IReadOnlyList<SecurityIdentifier>? GetMembers(string localGroupName);
}

internal sealed class WindowsLocalGroupInspector : ILocalGroupInspector
{
    public MachineRole? GetMachineRole()
    {
        IntPtr buffer = IntPtr.Zero;
        try
        {
            if (DsRoleGetPrimaryDomainInformation(null, 1, out buffer) != 0 || buffer == IntPtr.Zero) return null;
            // DsRolePrimaryDomainInfoBasic (1): MachineRole is the first DWORD in the returned structure.
            return (MachineRole)Marshal.ReadInt32(buffer);
        }
        finally { if (buffer != IntPtr.Zero) DsRoleFreeMemory(buffer); }
    }

    public SecurityIdentifier? GetMachineAccountDomainSid()
    {
        var attributes = new LsaObjectAttributes { Length = (uint)Marshal.SizeOf<LsaObjectAttributes>() };
        // PolicyAccountDomainInformation (5) is local only after excluding domain controllers.
        if (LsaOpenPolicy(IntPtr.Zero, ref attributes, 1, out IntPtr policy) != 0) return null; // POLICY_VIEW_LOCAL_INFORMATION
        IntPtr buffer = IntPtr.Zero;
        try
        {
            if (LsaQueryInformationPolicy(policy, 5, out buffer) != 0 || buffer == IntPtr.Zero) return null;
            IntPtr sid = Marshal.PtrToStructure<PolicyAccountDomainInfo>(buffer).DomainSid;
            return sid == IntPtr.Zero ? null : new SecurityIdentifier(sid);
        }
        finally
        {
            if (buffer != IntPtr.Zero) LsaFreeMemory(buffer);
            LsaClose(policy);
        }
    }

    public LocalAccount? LookupAccount(SecurityIdentifier sid)
    {
        var bytes = new byte[sid.BinaryLength];
        sid.GetBinaryForm(bytes, 0);
        uint nameLength = 0, domainLength = 0;
        if (LookupAccountSidW(null, bytes, null, ref nameLength, null, ref domainLength, out _) ||
            Marshal.GetLastWin32Error() != 122 || nameLength == 0) return null; // ERROR_INSUFFICIENT_BUFFER
        var name = new StringBuilder(checked((int)nameLength));
        var domain = new StringBuilder(checked((int)domainLength));
        if (!LookupAccountSidW(null, bytes, name, ref nameLength, domain, ref domainLength, out SidNameUse type)) return null;
        return new LocalAccount(name.ToString(), type);
    }

    public IReadOnlyList<SecurityIdentifier>? GetMembers(string localGroupName)
    {
        var members = new List<SecurityIdentifier>();
        UIntPtr resume = UIntPtr.Zero;
        uint status;
        do
        {
            IntPtr buffer = IntPtr.Zero;
            try
            {
                status = NetLocalGroupGetMembers(null, localGroupName, 0, out buffer, uint.MaxValue,
                    out uint count, out _, ref resume);
                if (status != 0 && status != 234) return null; // ERROR_MORE_DATA requires continuing the enumeration.
                if (buffer == IntPtr.Zero && count != 0) return null;
                // LOCALGROUP_MEMBERS_INFO_0 contains just one PSID; copy before freeing the API buffer.
                for (int i = 0; i < checked((int)count); i++)
                {
                    IntPtr sid = Marshal.ReadIntPtr(buffer, checked(i * IntPtr.Size));
                    if (sid == IntPtr.Zero) return null;
                    members.Add(new SecurityIdentifier(sid));
                }
            }
            finally { if (buffer != IntPtr.Zero) NetApiBufferFree(buffer); }
        } while (status == 234);
        return members;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct LsaObjectAttributes
    {
        public uint Length;
        public IntPtr RootDirectory;
        public IntPtr ObjectName;
        public uint Attributes;
        public IntPtr SecurityDescriptor;
        public IntPtr SecurityQualityOfService;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct LsaUnicodeString
    {
        public ushort Length;
        public ushort MaximumLength;
        public IntPtr Buffer;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct PolicyAccountDomainInfo
    {
        public LsaUnicodeString DomainName;
        public IntPtr DomainSid;
    }

    [DllImport("advapi32.dll", ExactSpelling = true)]
    private static extern uint LsaOpenPolicy(IntPtr systemName, ref LsaObjectAttributes attributes, uint desiredAccess, out IntPtr policy);

    [DllImport("advapi32.dll", ExactSpelling = true)]
    private static extern uint LsaQueryInformationPolicy(IntPtr policy, int informationClass, out IntPtr buffer);

    [DllImport("advapi32.dll", ExactSpelling = true)]
    private static extern uint LsaFreeMemory(IntPtr buffer);

    [DllImport("advapi32.dll", ExactSpelling = true)]
    private static extern uint LsaClose(IntPtr policy);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool LookupAccountSidW(string? systemName, byte[] sid, StringBuilder? name, ref uint nameLength,
        StringBuilder? referencedDomainName, ref uint domainLength, out SidNameUse use);

    [DllImport("netapi32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    private static extern uint NetLocalGroupGetMembers(string? serverName, string localGroupName, uint level,
        out IntPtr buffer, uint preferredMaximumLength, out uint entriesRead, out uint totalEntries, ref UIntPtr resumeHandle);

    [DllImport("netapi32.dll", ExactSpelling = true)]
    private static extern uint NetApiBufferFree(IntPtr buffer);

    [DllImport("netapi32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    private static extern uint DsRoleGetPrimaryDomainInformation(string? serverName, int infoLevel, out IntPtr buffer);

    [DllImport("netapi32.dll", ExactSpelling = true)]
    private static extern void DsRoleFreeMemory(IntPtr buffer);
}
