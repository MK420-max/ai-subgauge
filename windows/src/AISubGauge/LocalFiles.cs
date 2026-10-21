using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using Microsoft.Win32.SafeHandles;
using AISubGauge.Providers;

namespace AISubGauge;

// Windows-only file access: do not follow links before validating the opened target.
internal static class LocalFiles
{
    private const uint OpenReparsePoint = 0x00200000;
    private const uint BackupSemantics = 0x02000000;
    private const uint Overlapped = 0x40000000;

    public static string FullPath(string path)
    {
        // Only drive-qualified DOS paths; reject UNC, device namespaces, ADS and DOS aliases.
        if (!Path.IsPathFullyQualified(path) || path.Length < 3 || !char.IsAsciiLetter(path[0]) ||
            path[1] != ':' || (path[2] != '\\' && path[2] != '/') || path.IndexOf(':', 2) >= 0)
            throw new IOException(I18n.Get("windows.the.file.path.must.be.an.absolute.local.path"));
        string fullPath = Path.GetFullPath(path).Replace('/', '\\');
        foreach (string part in fullPath.Substring(3).Split('\\', StringSplitOptions.RemoveEmptyEntries))
        {
            string name = part.Split('.')[0];
            if (part.EndsWith(' ') || part.EndsWith('.') || part.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0 ||
                name.Equals("CON", StringComparison.OrdinalIgnoreCase) || name.Equals("PRN", StringComparison.OrdinalIgnoreCase) ||
                name.Equals("AUX", StringComparison.OrdinalIgnoreCase) || name.Equals("NUL", StringComparison.OrdinalIgnoreCase) ||
                name.Equals("CONIN$", StringComparison.OrdinalIgnoreCase) || name.Equals("CONOUT$", StringComparison.OrdinalIgnoreCase) ||
                (name.Length == 4 && (name.StartsWith("COM", StringComparison.OrdinalIgnoreCase) ||
                    name.StartsWith("LPT", StringComparison.OrdinalIgnoreCase)) && (name[3] is >= '1' and <= '9' or '¹' or '²' or '³')))
                throw new IOException(I18n.Get("windows.the.file.path.contains.an.unsafe.name"));
        }
        DriveType drive = new DriveInfo(fullPath.Substring(0, 3)).DriveType;
        if (drive is DriveType.Network or DriveType.Unknown or DriveType.NoRootDirectory)
            throw new IOException(I18n.Get("windows.the.file.must.be.on.a.local.disk"));
        return fullPath;
    }

    public static bool Exists(string path)
    {
        try { using FileStream file = OpenRead(path, 1_048_576); return true; }
        catch (FileNotFoundException) { return false; }
        catch (DirectoryNotFoundException) { return false; }
    }

    public static FileStream OpenRead(string path, long maximum) => Open(path, maximum, createNew: false);

    internal static CodexCredentialLock OpenCodexCredential(string path, long maximum)
    {
        string fullPath = FullPath(path);
        string parent = Path.GetDirectoryName(fullPath) ?? throw new IOException(I18n.Get("windows.missing.file.directory"));
        using WindowsIdentity identity = WindowsIdentity.GetCurrent();
        SecurityIdentifier user = identity.User ?? throw new QuotaReadException(CredentialAccess.UnsafeMessage);
        var directories = new List<SafeFileHandle>();
        FileStream? file = null;
        void LockAndValidate(string directory)
        {
            // Retain every component through CLI exit; refresh writes are allowed, deletion is not.
            // FILE_LIST_DIRECTORY participates in sharing checks; READ_CONTROL alone is metadata access.
            LockDirectory(directory, directories, access: 0x00020001, share: (uint)FileShare.ReadWrite);
            RawSecurityDescriptor security = ReadSecurity(directories[^1]);
            if (directory.Equals(parent, StringComparison.OrdinalIgnoreCase))
                CredentialAccess.ValidateDirectorySecurity(security, user, credentialPath: fullPath);
            else
            {
                try { ValidateInstallSecurity(security, user, ancestor: true); }
                catch (IOException) { throw new QuotaReadException(CredentialAccess.UnsafeMessage); }
            }
        }
        try
        {
            string directory = fullPath.Substring(0, 3);
            LockAndValidate(directory);
            foreach (string part in parent.Substring(3).Split('\\', StringSplitOptions.RemoveEmptyEntries))
            {
                directory = Path.Combine(directory, part);
                LockAndValidate(directory);
            }
            // Only an absent leaf is optional. A missing directory must release locks and fail closed.
            try { file = OpenFile(fullPath, maximum, createNew: false, share: (uint)FileShare.ReadWrite); }
            catch (FileNotFoundException) { }
            if (file is not null)
                CredentialAccess.Validate(file, kind: CredentialKind.Codex, credentialPath: fullPath);
            return new CodexCredentialLock(file, directories);
        }
        catch
        {
            file?.Dispose();
            for (int index = directories.Count - 1; index >= 0; index--) directories[index].Dispose();
            throw;
        }
    }

    internal sealed class CodexCredentialLock : IDisposable
    {
        private readonly FileStream? _file;
        private readonly List<SafeFileHandle> _directories;
        internal bool HasCredential => _file is not null;

        public CodexCredentialLock(FileStream? file, List<SafeFileHandle> directories)
        {
            _file = file;
            _directories = directories;
        }

        public void Dispose()
        {
            try { _file?.Dispose(); }
            finally { for (int index = _directories.Count - 1; index >= 0; index--) _directories[index].Dispose(); }
        }
    }

    internal static void WithProtectedExecutable(string path, string installationRoot, Action register, string? trustedAncestor = null)
    {
        string full = FullPath(path), root = FullPath(installationRoot).TrimEnd('\\');
        // Tests can anchor ACL checks at a private fixture directory instead of a shared %TEMP%.
        // Production never supplies this parameter and checks security back to the drive root.
        string? boundary = trustedAncestor is null ? null : FullPath(trustedAncestor).TrimEnd('\\');
        if (boundary is not null && !root.Equals(boundary, StringComparison.OrdinalIgnoreCase) &&
            !root.StartsWith(boundary + "\\", StringComparison.OrdinalIgnoreCase))
            throw new IOException("The trusted ancestor must contain the installation root.");
        if (!full.StartsWith(root + "\\", StringComparison.OrdinalIgnoreCase) ||
            !Path.GetFileName(full).Equals("AISubGauge.exe", StringComparison.OrdinalIgnoreCase))
            throw new IOException("Launch at login requires a protected installation in LocalAppData\\Programs\\AISubGauge.");
        using WindowsIdentity identity = WindowsIdentity.GetCurrent();
        SecurityIdentifier user = identity.User ?? throw new IOException("Cannot identify the installation owner.");
        var directories = new List<SafeFileHandle>();
        void LockAndValidate(string directory, bool ancestor)
        {
            LockDirectory(directory, directories, access: 0x00020000);
            if (boundary is null || directory.TrimEnd('\\').Equals(boundary, StringComparison.OrdinalIgnoreCase) ||
                directory.StartsWith(boundary + "\\", StringComparison.OrdinalIgnoreCase))
                ValidateInstallSecurity(ReadSecurity(directories[^1]), user,
                    ancestor && !directory.TrimEnd('\\').Equals(boundary, StringComparison.OrdinalIgnoreCase));
        }
        try
        {
            string parent = Path.GetDirectoryName(full)!;
            string directory = full.Substring(0, 3);
            LockAndValidate(directory, ancestor: true);
            foreach (string part in parent.Substring(3).Split('\\', StringSplitOptions.RemoveEmptyEntries))
            {
                directory = Path.Combine(directory, part);
                bool ancestor = !directory.Equals(root, StringComparison.OrdinalIgnoreCase) &&
                    !directory.StartsWith(root + "\\", StringComparison.OrdinalIgnoreCase);
                LockAndValidate(directory, ancestor);
            }
            using SafeFileHandle image = OpenHandle(full, 0x80020000, 1, 3, OpenReparsePoint);
            ValidateHandle(image, full, directory: false);
            ValidateInstallSecurity(ReadSecurity(image), user);
            register(); // Keep the image and every ancestor locked through the registry write.
        }
        finally { for (int index = directories.Count - 1; index >= 0; index--) directories[index].Dispose(); }
    }

    internal static void ValidateInstallSecurity(RawSecurityDescriptor security, SecurityIdentifier user, bool ancestor = false)
    {
        static bool SystemTrusted(SecurityIdentifier sid) => sid.IsWellKnown(WellKnownSidType.LocalSystemSid) ||
            sid.IsWellKnown(WellKnownSidType.BuiltinAdministratorsSid) ||
            sid.Value == "S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464"; // TrustedInstaller
        bool Trusted(SecurityIdentifier? sid) => sid is not null && (sid.Equals(user) || SystemTrusted(sid));
        if (!Trusted(security.Owner) || security.DiscretionaryAcl is null)
            throw new IOException("The startup installation has an unsafe owner or DACL.");
        int writes = (int)(FileSystemRights.WriteData | FileSystemRights.AppendData | FileSystemRights.WriteAttributes |
            FileSystemRights.WriteExtendedAttributes | FileSystemRights.Delete | FileSystemRights.DeleteSubdirectoriesAndFiles |
            FileSystemRights.ChangePermissions | FileSystemRights.TakeOwnership) | 0x50000000; // GENERIC_WRITE / ALL
        // Above the installation root, creating a new sibling cannot replace an existing component.
        // Still reject delete-child, delete, owner/DACL/attribute writes and generic write/all.
        if (ancestor) writes &= ~(int)(FileSystemRights.WriteData | FileSystemRights.AppendData);
        foreach (GenericAce ace in security.DiscretionaryAcl)
        {
            if ((ace.AceFlags & AceFlags.InheritOnly) != 0) continue;
            if (ace is not QualifiedAce qualified) throw new IOException("Unsupported installation ACE.");
            if (qualified.AceQualifier == AceQualifier.AccessAllowed && !Trusted(qualified.SecurityIdentifier) &&
                (qualified.AccessMask & writes) != 0)
                throw new IOException("Other users can modify the startup installation.");
        }
    }

    private static RawSecurityDescriptor ReadSecurity(SafeFileHandle handle)
    {
        uint error = GetSecurityInfo(handle, 1, 5, out _, out _, out _, out _, out IntPtr descriptor); // FILE, OWNER | DACL
        try
        {
            if (error != 0 || descriptor == IntPtr.Zero) throw new IOException("Cannot verify installation permissions.");
            int size = checked((int)GetSecurityDescriptorLength(descriptor));
            byte[] bytes = new byte[size];
            Marshal.Copy(descriptor, bytes, 0, size);
            return new RawSecurityDescriptor(bytes, 0);
        }
        finally { if (descriptor != IntPtr.Zero) LocalFree(descriptor); }
    }

    public static FileStream CreateStatusFile(string path)
    {
        string fullPath = FullPath(Path.GetFullPath(path));
        if (CredentialFiles.IsProtectedPath(fullPath))
            throw new IOException(I18n.Get("windows.status.reports.cannot.be.written.to.credential.paths"));
        return Open(fullPath, long.MaxValue, createNew: true);
    }

    internal static FileStream OpenReadForAclRepair(string path, long maximum) => Open(path, maximum, false, repairAcl: true);

    private static FileStream Open(string path, long maximum, bool createNew, bool repairAcl = false)
    {
        string fullPath = FullPath(path);
        var directories = new List<SafeFileHandle>();
        try
        {
            string parent = Path.GetDirectoryName(fullPath) ?? throw new IOException(I18n.Get("windows.missing.file.directory"));
            string directory = fullPath.Substring(0, 3);
            LockDirectory(directory, directories);
            foreach (string part in parent.Substring(3).Split('\\', StringSplitOptions.RemoveEmptyEntries))
            {
                directory = Path.Combine(directory, part);
                // Create exactly one component; never follow an existing leaf link to create its target.
                if (createNew && !CreateDirectoryW(directory, IntPtr.Zero) && Marshal.GetLastWin32Error() != 183)
                    throw new IOException(I18n.Get("windows.could.not.safely.create.the.status.report.directory"));
                LockDirectory(directory, directories);
            }
            return OpenFile(fullPath, maximum, createNew, repairAcl);
        }
        finally { for (int index = directories.Count - 1; index >= 0; index--) directories[index].Dispose(); }
    }

    private static FileStream OpenFile(string fullPath, long maximum, bool createNew, bool repairAcl = false, uint share = 1)
    {
        SafeFileHandle? handle = null;
        try
        {
            handle = OpenHandle(fullPath, createNew ? 0x40000000u : 0x80000000u | (repairAcl ? 0x00040000u : 0u),
                createNew ? 0u : share, createNew ? 1u : 3u, OpenReparsePoint | Overlapped);
            ulong length = ValidateHandle(handle, fullPath, directory: false);
            if (length > (ulong)maximum) throw new IOException(I18n.Get("windows.the.local.file.exceeds.the.read.limit"));
            var stream = new FileStream(handle, createNew ? FileAccess.Write : FileAccess.Read, 4096, isAsync: true);
            handle = null; // FileStream now owns the handle.
            return stream;
        }
        finally { handle?.Dispose(); }
    }

    private static void LockDirectory(string path, List<SafeFileHandle> directories, uint access = 0, uint share = 1)
    {
        SafeFileHandle handle = OpenHandle(path, access, share, 3, OpenReparsePoint | BackupSemantics);
        try { ValidateHandle(handle, path, directory: true); directories.Add(handle); }
        catch { handle.Dispose(); throw; }
    }

    private static SafeFileHandle OpenHandle(string path, uint access, uint share, uint disposition, uint flags)
    {
        SafeFileHandle handle = CreateFileW(path, access, share, IntPtr.Zero, disposition, flags, IntPtr.Zero);
        if (!handle.IsInvalid) return handle;
        int error = Marshal.GetLastWin32Error();
        handle.Dispose();
        if (error == 2) throw new FileNotFoundException(I18n.Get("windows.local.file.not.found"));
        if (error == 3) throw new DirectoryNotFoundException(I18n.Get("windows.local.directory.not.found"));
        throw new IOException(I18n.Get("windows.could.not.safely.open.the.local.file"));
    }

    private static ulong ValidateHandle(SafeFileHandle handle, string expectedPath, bool directory)
    {
        if (GetFileType(handle) != 1 || !GetFileInformationByHandle(handle, out FileInformation info) ||
            (info.Attributes & (FileAttributes.ReparsePoint | FileAttributes.Device)) != 0 ||
            ((info.Attributes & FileAttributes.Directory) != 0) != directory)
            throw new IOException(I18n.Get("windows.the.local.path.must.be.an.ordinary.file.or.directory"));
        var finalPath = new StringBuilder(32768);
        uint count = GetFinalPathNameByHandleW(handle, finalPath, (uint)finalPath.Capacity, 0);
        string actual = finalPath.ToString();
        if (count == 0 || count >= (uint)finalPath.Capacity || !actual.StartsWith(@"\\?\", StringComparison.Ordinal) ||
            !FullPath(actual.Substring(4)).TrimEnd('\\').Equals(expectedPath.TrimEnd('\\'), StringComparison.OrdinalIgnoreCase))
            throw new IOException(I18n.Get("windows.file.openedPathMismatch"));
        return ((ulong)info.SizeHigh << 32) | info.SizeLow;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct FileInformation
    {
        public FileAttributes Attributes;
        public System.Runtime.InteropServices.ComTypes.FILETIME CreationTime;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastAccessTime;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWriteTime;
        public uint VolumeSerialNumber;
        public uint SizeHigh;
        public uint SizeLow;
        public uint NumberOfLinks;
        public uint IndexHigh;
        public uint IndexLow;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
    private static extern SafeFileHandle CreateFileW(string path, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CreateDirectoryW(string path, IntPtr security);

    [DllImport("kernel32.dll", ExactSpelling = true, SetLastError = true)]
    private static extern uint GetFileType(SafeFileHandle handle);

    [DllImport("kernel32.dll", ExactSpelling = true, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetFileInformationByHandle(SafeFileHandle handle, out FileInformation information);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
    private static extern uint GetFinalPathNameByHandleW(SafeFileHandle handle, StringBuilder path, uint length, uint flags);

    [DllImport("advapi32.dll", ExactSpelling = true)]
    private static extern uint GetSecurityInfo(SafeFileHandle handle, int objectType, uint information,
        out IntPtr owner, out IntPtr group, out IntPtr dacl, out IntPtr sacl, out IntPtr descriptor);

    [DllImport("advapi32.dll", ExactSpelling = true)]
    private static extern uint GetSecurityDescriptorLength(IntPtr descriptor);

    [DllImport("kernel32.dll", ExactSpelling = true)]
    private static extern IntPtr LocalFree(IntPtr pointer);
}
