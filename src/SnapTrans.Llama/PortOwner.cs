using System.Net;
using System.Runtime.InteropServices;

namespace SnapTrans.Llama;

/// <summary>
/// Which process is listening on a local TCP port (IPv4, GetExtendedTcpTable / TCP_TABLE_OWNER_PID_LISTENER).
/// Used to prove that 127.0.0.1:port really is our llama-server child before any credential or text is sent.
/// </summary>
public static class PortOwner
{
    const int AF_INET = 2, TCP_TABLE_OWNER_PID_LISTENER = 3;

    [StructLayout(LayoutKind.Sequential)]
    struct Row { public uint State, LocalAddr, LocalPort, RemoteAddr, RemotePort, OwningPid; }

    [DllImport("iphlpapi.dll", SetLastError = true)]
    static extern uint GetExtendedTcpTable(nint table, ref int size, bool order, int af, int tableClass, uint reserved);

    /// <summary>PIDs listening on <paramref name="address"/>:<paramref name="port"/> (or on 0.0.0.0:port).</summary>
    public static IReadOnlyList<int> ListenersOf(IPAddress address, int port)
    {
        if (!OperatingSystem.IsWindows()) return [];
        int size = 0;
        GetExtendedTcpTable(0, ref size, false, AF_INET, TCP_TABLE_OWNER_PID_LISTENER, 0);
        for (int attempt = 0; attempt < 4; attempt++) {
            var buffer = Marshal.AllocHGlobal(size);
            try {
                uint rc = GetExtendedTcpTable(buffer, ref size, false, AF_INET, TCP_TABLE_OWNER_PID_LISTENER, 0);
                if (rc == 122 /* ERROR_INSUFFICIENT_BUFFER */) continue;
                if (rc != 0) return [];
                int count = Marshal.ReadInt32(buffer);
                var result = new List<int>();
                var target = BitConverter.ToUInt32(address.GetAddressBytes());
                int rowSize = Marshal.SizeOf<Row>();
                for (int i = 0; i < count; i++) {
                    var row = Marshal.PtrToStructure<Row>(buffer + 4 + i * rowSize);
                    int rowPort = (int)(((row.LocalPort & 0xFF) << 8) | ((row.LocalPort >> 8) & 0xFF));
                    if (rowPort == port && (row.LocalAddr == target || row.LocalAddr == 0)) result.Add((int)row.OwningPid);
                }
                return result;
            } finally { Marshal.FreeHGlobal(buffer); }
        }
        return [];
    }
}
