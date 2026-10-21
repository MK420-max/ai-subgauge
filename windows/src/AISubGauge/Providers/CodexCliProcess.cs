using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading.Tasks;
using Microsoft.Win32.SafeHandles;

namespace AISubGauge.Providers;

// Owns the CLI and every descendant, even after the original parent exits.
internal sealed class CodexCliProcess : IDisposable
{
    private readonly SafeFileHandle _job;
    private SafeProcessHandle? _process;
    private bool _assigned;
    private readonly AnonymousPipeServerStream _input = new(PipeDirection.Out, HandleInheritability.Inheritable);
    private readonly AnonymousPipeServerStream _output = new(PipeDirection.In, HandleInheritability.Inheritable);
    private readonly AnonymousPipeServerStream _error = new(PipeDirection.In, HandleInheritability.Inheritable);
    internal StreamWriter StandardInput { get; }
    internal Stream StandardOutput => _output;
    internal Stream StandardError => _error;
    internal int Id { get; private set; }

    internal CodexCliProcess()
    {
        _job = CreateJobObjectW(IntPtr.Zero, null); // Unnamed and non-inheritable.
        if (_job.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
        var limits = new ExtendedLimitInformation();
        limits.BasicLimitInformation.LimitFlags = 0x00002000; // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
        if (!SetInformationJobObject(_job, 9, ref limits, (uint)Marshal.SizeOf<ExtendedLimitInformation>()))
        {
            int error = Marshal.GetLastWin32Error();
            _job.Dispose();
            throw new Win32Exception(error);
        }
        StandardInput = new StreamWriter(_input, new UTF8Encoding(false), leaveOpen: true);
    }

    internal void Start(ProcessStartInfo info)
    {
        // Only the three stdio handles may be inherited: never the job or credential locks.
        IntPtr attributes = IntPtr.Zero, handles = IntPtr.Zero, environment = IntPtr.Zero;
        bool initialized = false;
        try
        {
            nuint size = 0;
            InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref size);
            attributes = Marshal.AllocHGlobal(checked((int)size));
            if (!InitializeProcThreadAttributeList(attributes, 1, 0, ref size))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            initialized = true;
            handles = Marshal.AllocHGlobal(3 * IntPtr.Size);
            IntPtr[] stdio = { _input.ClientSafePipeHandle.DangerousGetHandle(),
                _output.ClientSafePipeHandle.DangerousGetHandle(), _error.ClientSafePipeHandle.DangerousGetHandle() };
            Marshal.Copy(stdio, 0, handles, stdio.Length);
            if (!UpdateProcThreadAttribute(attributes, 0, 0x00020002, handles, (nuint)(3 * IntPtr.Size), IntPtr.Zero, IntPtr.Zero))
                throw new Win32Exception(Marshal.GetLastWin32Error()); // PROC_THREAD_ATTRIBUTE_HANDLE_LIST
            var startup = new StartupInfoEx
            {
                StartupInfo = new StartupInfo
                {
                    Size = (uint)Marshal.SizeOf<StartupInfoEx>(), Flags = 0x00000100, // STARTF_USESTDHANDLES
                    StandardInput = stdio[0], StandardOutput = stdio[1], StandardError = stdio[2]
                },
                AttributeList = attributes
            };
            environment = Marshal.StringToHGlobalUni(string.Join("\0", info.Environment
                .OrderBy(pair => pair.Key, StringComparer.OrdinalIgnoreCase)
                .Select(pair => pair.Key + "=" + pair.Value)) + "\0\0");
            var command = new StringBuilder(string.Join(" ", new[] { info.FileName }.Concat(info.ArgumentList).Select(QuoteArgument)));
            // CREATE_SUSPENDED | CREATE_UNICODE_ENVIRONMENT | EXTENDED_STARTUPINFO_PRESENT | CREATE_NO_WINDOW
            if (!CreateProcessW(info.FileName, command, IntPtr.Zero, IntPtr.Zero, true, 0x08080404,
                environment, info.WorkingDirectory, ref startup, out ProcessInformation created))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            _process = new SafeProcessHandle(created.Process, ownsHandle: true);
            Id = checked((int)created.ProcessId);
            using var thread = new SafeFileHandle(created.Thread, ownsHandle: true);
            // No CLI instruction (and therefore no child creation) can run before assignment succeeds.
            if (!AssignProcessToJobObject(_job, _process))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            _assigned = true;
            if (ResumeThread(thread) == uint.MaxValue)
                throw new Win32Exception(Marshal.GetLastWin32Error());
        }
        finally
        {
            _input.DisposeLocalCopyOfClientHandle();
            _output.DisposeLocalCopyOfClientHandle();
            _error.DisposeLocalCopyOfClientHandle();
            if (initialized) DeleteProcThreadAttributeList(attributes);
            if (attributes != IntPtr.Zero) Marshal.FreeHGlobal(attributes);
            if (handles != IntPtr.Zero) Marshal.FreeHGlobal(handles);
            if (environment != IntPtr.Zero) Marshal.FreeHGlobal(environment);
        }
    }

    internal uint ActiveProcesses
    {
        get
        {
            if (!QueryInformationJobObject(_job, 1, out BasicAccountingInformation accounting,
                (uint)Marshal.SizeOf<BasicAccountingInformation>(), IntPtr.Zero))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            return accounting.ActiveProcesses;
        }
    }

    internal int[] GetProcessIds()
    {
        // JOBOBJECT_BASIC_PROCESS_ID_LIST: two DWORDs followed by ULONG_PTR entries.
        const int headerSize = 2 * sizeof(uint);
        int capacity = 1;
        while (true)
        {
            int length = checked(headerSize + capacity * IntPtr.Size);
            IntPtr buffer = Marshal.AllocHGlobal(length);
            try
            {
                if (!QueryInformationJobObject(_job, 3, buffer, (uint)length, IntPtr.Zero)) // JobObjectBasicProcessIdList
                {
                    int error = Marshal.GetLastWin32Error();
                    if (error is not (122 or 234)) throw new Win32Exception(error); // INSUFFICIENT_BUFFER / MORE_DATA
                    capacity = checked(capacity * 2);
                    continue;
                }
                uint assigned = unchecked((uint)Marshal.ReadInt32(buffer));
                uint count = unchecked((uint)Marshal.ReadInt32(buffer, sizeof(uint)));
                if (count < assigned)
                {
                    capacity = checked((int)assigned);
                    continue;
                }
                var ids = new int[checked((int)count)];
                for (int index = 0; index < ids.Length; index++)
                    ids[index] = checked((int)(nuint)Marshal.ReadIntPtr(buffer, headerSize + index * IntPtr.Size));
                return ids;
            }
            finally { Marshal.FreeHGlobal(buffer); }
        }
    }

    internal async Task TerminateAndWaitAsync(TimeSpan timeout)
    {
        if (!TerminateJobObject(_job, 1)) throw new Win32Exception(Marshal.GetLastWin32Error());
        // Assignment failure leaves only a suspended, never-executed root outside the job.
        if (!_assigned && _process is not null && !TerminateProcess(_process, 1))
        {
            int error = Marshal.GetLastWin32Error();
            if (WaitForSingleObject(_process, 0) != 0) throw new Win32Exception(error);
        }
        var timer = Stopwatch.StartNew();
        while (true)
        {
            uint active = ActiveProcesses;
            uint root = _process is null ? 0 : WaitForSingleObject(_process, 0);
            if (root == uint.MaxValue) throw new Win32Exception(Marshal.GetLastWin32Error());
            if (active == 0 && root == 0) return;
            if (timer.Elapsed >= timeout) throw new TimeoutException();
            await Task.Delay(25).ConfigureAwait(false);
        }
    }

    // CommandLineToArgvW / CRT quoting, including trailing slashes and embedded quotes.
    private static string QuoteArgument(string value)
    {
        var quoted = new StringBuilder("\"");
        int slashes = 0;
        foreach (char character in value)
        {
            if (character == '\\') { slashes++; continue; }
            quoted.Append('\\', character == '"' ? slashes * 2 + 1 : slashes);
            quoted.Append(character);
            slashes = 0;
        }
        return quoted.Append('\\', slashes * 2).Append('"').ToString();
    }

    public void Dispose()
    {
        // Production calls this only after an empty-job confirmation; closing is also a crash fallback.
        try { _job.Dispose(); }
        finally
        {
            using (_process)
            using (_error)
            using (_output)
            {
                // A terminated CLI may have closed stdin during a pending write.
                try { StandardInput.Dispose(); }
                catch (ObjectDisposedException) { }
                catch (IOException) { }
                finally
                {
                    try { _input.Dispose(); }
                    catch (ObjectDisposedException) { }
                    catch (IOException) { }
                }
            }
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct BasicLimitInformation
    {
        public long PerProcessUserTimeLimit, PerJobUserTimeLimit;
        public uint LimitFlags;
        public nuint MinimumWorkingSetSize, MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public nuint Affinity;
        public uint PriorityClass, SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct IoCounters
    {
        public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount;
        public ulong ReadTransferCount, WriteTransferCount, OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ExtendedLimitInformation
    {
        public BasicLimitInformation BasicLimitInformation;
        public IoCounters IoInfo;
        public nuint ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct BasicAccountingInformation
    {
        public long TotalUserTime, TotalKernelTime, ThisPeriodTotalUserTime, ThisPeriodTotalKernelTime;
        public uint TotalPageFaultCount, TotalProcesses, ActiveProcesses, TotalTerminatedProcesses;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct StartupInfo
    {
        public uint Size;
        public IntPtr Reserved, Desktop, Title;
        public uint X, Y, XSize, YSize, XCountChars, YCountChars, FillAttribute, Flags;
        public ushort ShowWindow, ReservedSize;
        public IntPtr ReservedBytes, StandardInput, StandardOutput, StandardError;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct StartupInfoEx
    {
        public StartupInfo StartupInfo;
        public IntPtr AttributeList;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ProcessInformation
    {
        public IntPtr Process, Thread;
        public uint ProcessId, ThreadId;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true, ExactSpelling = true)]
    private static extern SafeFileHandle CreateJobObjectW(IntPtr securityAttributes, string? name);
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetInformationJobObject(SafeFileHandle job, int informationClass,
        ref ExtendedLimitInformation information, uint length);
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool AssignProcessToJobObject(SafeFileHandle job, SafeProcessHandle process);
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool TerminateJobObject(SafeFileHandle job, uint exitCode);
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool QueryInformationJobObject(SafeFileHandle job, int informationClass,
        out BasicAccountingInformation information, uint length, IntPtr returnLength);
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool QueryInformationJobObject(SafeFileHandle job, int informationClass,
        IntPtr information, uint length, IntPtr returnLength);
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool InitializeProcThreadAttributeList(IntPtr list, int count, uint flags, ref nuint size);
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool UpdateProcThreadAttribute(IntPtr list, uint flags, nuint attribute,
        IntPtr value, nuint size, IntPtr previousValue, IntPtr returnSize);
    [DllImport("kernel32.dll")]
    private static extern void DeleteProcThreadAttributeList(IntPtr list);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true, ExactSpelling = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CreateProcessW(string application, StringBuilder command, IntPtr processAttributes,
        IntPtr threadAttributes, [MarshalAs(UnmanagedType.Bool)] bool inheritHandles, uint creationFlags,
        IntPtr environment, string directory, ref StartupInfoEx startup, out ProcessInformation process);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint ResumeThread(SafeFileHandle thread);
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool TerminateProcess(SafeProcessHandle process, uint exitCode);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint WaitForSingleObject(SafeProcessHandle process, uint milliseconds);
}
