using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace SnapTrans.Llama;

/// <summary>Windows job object with KILL_ON_JOB_CLOSE: the engine dies with the app even after a crash.</summary>
sealed class ChildLifetime : IDisposable
{
    [StructLayout(LayoutKind.Sequential)] struct Limits {
        public long ProcessTime, JobTime; public uint Flags; public nuint MinWorkingSet, MaxWorkingSet;
        public uint ActiveProcesses; public nuint Affinity; public uint Priority, Scheduling;
    }
    [StructLayout(LayoutKind.Sequential)] struct ExtendedLimits {
        public Limits Basic; public ulong ReadOps, WriteOps, OtherOps, ReadBytes, WriteBytes, OtherBytes;
        public nuint ProcessMemory, JobMemory, PeakProcessMemory, PeakJobMemory;
    }
    [DllImport("kernel32", SetLastError = true)] static extern SafeFileHandle CreateJobObject(nint security, nint name);
    [DllImport("kernel32", SetLastError = true)] static extern bool SetInformationJobObject(SafeFileHandle job, int type, ref ExtendedLimits limits, int size);
    [DllImport("kernel32", SetLastError = true)] static extern bool AssignProcessToJobObject(SafeFileHandle job, nint process);

    readonly SafeFileHandle? job;

    public ChildLifetime(nint process)
    {
        if (!OperatingSystem.IsWindows()) return;
        job = CreateJobObject(0, 0);
        var limits = new ExtendedLimits { Basic = new Limits { Flags = 0x2000 } };
        if (job.IsInvalid || !SetInformationJobObject(job, 9, ref limits, Marshal.SizeOf<ExtendedLimits>()) || !AssignProcessToJobObject(job, process)) {
            var ex = new Win32Exception(); job.Dispose(); throw ex;
        }
    }

    public void Dispose() => job?.Dispose();
}
