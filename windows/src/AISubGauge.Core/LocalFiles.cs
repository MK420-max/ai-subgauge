using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;


namespace AISubGauge.Core;

// Shared preflight for settings and offline exports, including existing ancestors.
public static class LocalPathSafety
{
    public static void RejectReparsePoints(string path)
    {
        for (string? current = Path.GetFullPath(path); current is not null; current = Path.GetDirectoryName(current))
        {
            try
            {
                if ((File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0)
                    throw new IOException("Reparse points are not allowed.");
            }
            catch (FileNotFoundException) { }
            catch (DirectoryNotFoundException) { }
        }
    }
}

// Windows-only file access: do not follow links before validating the opened target.
internal sealed class LocalFileFailure(VerificationStatus status) : IOException("Local file access failed.")
{
    internal VerificationStatus Status { get; } = status;
}
internal readonly record struct ExecutableFileIdentity(string FullPath, uint VolumeSerial, ulong FileIndex, ulong Size, ulong LastWriteTime);
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
            throw new IOException("文件路径必须为本机绝对路径。");
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
                throw new IOException("文件路径含有不安全的名称。");
        }
        DriveType drive = new DriveInfo(fullPath.Substring(0, 3)).DriveType;
        if (drive is DriveType.Network or DriveType.Unknown or DriveType.NoRootDirectory)
            throw new IOException("文件必须位于本机磁盘。");
        return fullPath;
    }

    public static bool Exists(string path)
    {
        try { using FileStream file = OpenRead(path, 1_048_576); return true; }
        catch (Exception) { return false; }
    }

    public static FileStream OpenRead(string path, long maximum) => Open(path, maximum, createNew: false);

    internal static ExecutableFileIdentity Identity(string path, SafeFileHandle handle)
    {
        string fullPath = FullPath(path);
        ValidateHandle(handle, fullPath, directory: false);
        if (!GetFileInformationByHandle(handle, out FileInformation info))
            throw new IOException("Cannot read executable identity.");
        return new(fullPath.ToUpperInvariant(), info.VolumeSerialNumber,
            ((ulong)info.IndexHigh << 32) | info.IndexLow,
            ((ulong)info.SizeHigh << 32) | info.SizeLow,
            ((ulong)(uint)info.LastWriteTime.dwHighDateTime << 32) | (uint)info.LastWriteTime.dwLowDateTime);
    }

    private static FileStream Open(string path, long maximum, bool createNew)
    {
        string fullPath = FullPath(path);
        var directories = new List<SafeFileHandle>();
        SafeFileHandle? handle = null;
        try
        {
            string parent = Path.GetDirectoryName(fullPath) ?? throw new IOException("缺少文件目录。");
            string directory = fullPath.Substring(0, 3);
            // Keep each ancestor open without write/delete sharing until the leaf is open and checked.
            // This prevents an ordinary directory/junction replacement between check and open.
            LockDirectory(directory, directories);
            foreach (string part in parent.Substring(3).Split('\\', StringSplitOptions.RemoveEmptyEntries))
            {
                directory = Path.Combine(directory, part);
                // Create exactly one component; never follow an existing leaf link to create its target.
                if (createNew && !CreateDirectoryW(directory, IntPtr.Zero) && Marshal.GetLastWin32Error() != 183)
                    throw new IOException("无法安全创建状态报告目录。");
                LockDirectory(directory, directories);
            }
            VerificationTrace.Step(VerificationStage.OpenLeaf);
            handle = OpenHandle(fullPath, createNew ? 0x40000000u : 0x80000000u,
                createNew ? 0u : 1u, createNew ? 1u : 3u, OpenReparsePoint | Overlapped);
            ulong length = ValidateHandle(handle, fullPath, directory: false);
            if (length > (ulong)maximum) throw new IOException("本地文件超过读取上限。");
            var stream = new FileStream(handle, createNew ? FileAccess.Write : FileAccess.Read, 4096, isAsync: true);
            handle = null; // FileStream now owns the handle.
            return stream;
        }
        finally
        {
            handle?.Dispose();
            for (int index = directories.Count - 1; index >= 0; index--) directories[index].Dispose();
        }
    }

    private static void LockDirectory(string path, List<SafeFileHandle> directories)
    {
        VerificationTrace.Step(VerificationStage.OpenDirectory);
        SafeFileHandle handle = OpenHandle(path, 0, 1, 3, OpenReparsePoint | BackupSemantics);
        try { ValidateHandle(handle, path, directory: true); directories.Add(handle); }
        catch { handle.Dispose(); throw; }
    }

    private static SafeFileHandle OpenHandle(string path, uint access, uint share, uint disposition, uint flags)
    {
        SafeFileHandle handle = CreateFileW(path, access, share, IntPtr.Zero, disposition, flags, IntPtr.Zero);
        if (!handle.IsInvalid) return handle;
        int error = Marshal.GetLastWin32Error();
        VerificationTrace.Current.Value?.Sink?.Invoke("openFailure=" + (error switch { 2 => "FileNotFound", 3 => "DirectoryNotFound", 5 => "AccessDenied", 32 => "SharingViolation", _ => "Other" }));
        handle.Dispose();
        if (error == 2) throw new FileNotFoundException("未找到本地文件。");
        if (error == 3) throw new DirectoryNotFoundException("未找到本地目录。");
        if (error is 5 or 32) throw new LocalFileFailure(error == 5 ? VerificationStatus.AccessDenied : VerificationStatus.SharingViolation);
        throw new IOException("无法安全打开本地文件。");
    }

    private static ulong ValidateHandle(SafeFileHandle handle, string expectedPath, bool directory)
    {
        VerificationTrace.Step(VerificationStage.FileMetadata);
        if (GetFileType(handle) != 1 || !GetFileInformationByHandle(handle, out FileInformation info) ||
            (info.Attributes & (FileAttributes.ReparsePoint | FileAttributes.Device)) != 0 ||
            ((info.Attributes & FileAttributes.Directory) != 0) != directory)
            throw new IOException("本地路径必须为普通文件或目录，不能使用重解析点或设备。");
        VerificationTrace.Step(VerificationStage.FinalPath);
        var finalPath = new StringBuilder(32768);
        uint count = GetFinalPathNameByHandleW(handle, finalPath, (uint)finalPath.Capacity, 0);
        string actual = finalPath.ToString();
        VerificationTrace.Current.Value?.Sink?.Invoke($"finalPathLength={count} extendedDosPrefix={actual.StartsWith(@"\\?\", StringComparison.Ordinal)} directory={directory}");
        if (count == 0 || count >= (uint)finalPath.Capacity || !actual.StartsWith(@"\\?\", StringComparison.Ordinal) ||
            !FullPath(actual.Substring(4)).TrimEnd('\\').Equals(expectedPath.TrimEnd('\\'), StringComparison.OrdinalIgnoreCase))
            throw new IOException("打开后的本地路径与请求路径不一致。");
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
}

