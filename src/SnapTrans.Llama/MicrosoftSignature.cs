using System.Runtime.InteropServices;
using System.Security.Cryptography.X509Certificates;

namespace SnapTrans.Llama;

/// <summary>
/// Authenticode check for the Visual C++ runtime DLLs that ship next to the engine. Their version follows the build
/// machine's Visual Studio, so a fixed hash would break on every toolset update; instead the file's embedded signature
/// must verify (WinVerifyTrust, offline) and be issued to Microsoft Corporation.
/// </summary>
public static class MicrosoftSignature
{
    public static readonly string[] VcRuntimeFiles = ["msvcp140.dll", "vcruntime140.dll", "vcruntime140_1.dll"];

    public static bool IsVcRuntime(string fileName) => VcRuntimeFiles.Contains(fileName, StringComparer.OrdinalIgnoreCase);

    public static bool IsValidMicrosoftFile(string path)
    {
        if (!OperatingSystem.IsWindows()) return false;
        if (!Verify(path)) return false;
        try {
#pragma warning disable SYSLIB0057 // embedded signer certificate of a PE file
            using var signer = X509Certificate.CreateFromSignedFile(path);
#pragma warning restore SYSLIB0057
            return signer.Subject.Contains("O=Microsoft Corporation", StringComparison.Ordinal);
        } catch (System.Security.Cryptography.CryptographicException) { return false; }
    }

    // ---- WinVerifyTrust (embedded signature only; no network: revocation is not checked) ----
    static readonly Guid GenericVerifyV2 = new("00AAC56B-CD44-11d0-8CC2-00C04FC295EE");

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct FileInfo { public uint cbStruct; public string pcwszFilePath; public nint hFile; public nint pgKnownSubject; }

    [StructLayout(LayoutKind.Sequential)]
    struct TrustData {
        public uint cbStruct; public nint pPolicyCallbackData, pSIPClientData; public uint dwUIChoice, fdwRevocationChecks, dwUnionChoice;
        public nint pFile; public uint dwStateAction; public nint hWVTStateData; public nint pwszURLReference;
        public uint dwProvFlags, dwUIContext; public nint pSignatureSettings;
    }

    [DllImport("wintrust.dll", CharSet = CharSet.Unicode)]
    static extern int WinVerifyTrust(nint hwnd, ref Guid action, ref TrustData data);

    static bool Verify(string path)
    {
        var file = new FileInfo { cbStruct = (uint)Marshal.SizeOf<FileInfo>(), pcwszFilePath = path };
        var filePtr = Marshal.AllocHGlobal(Marshal.SizeOf<FileInfo>());
        try {
            Marshal.StructureToPtr(file, filePtr, false);
            var data = new TrustData {
                cbStruct = (uint)Marshal.SizeOf<TrustData>(), dwUIChoice = 2 /* WTD_UI_NONE */, fdwRevocationChecks = 0 /* WTD_REVOKE_NONE */,
                dwUnionChoice = 1 /* WTD_CHOICE_FILE */, pFile = filePtr, dwStateAction = 1 /* VERIFY */,
                dwProvFlags = 0x1000 /* WTD_CACHE_ONLY_URL_RETRIEVAL */
            };
            var action = GenericVerifyV2;
            int result = WinVerifyTrust(-1, ref action, ref data);
            data.dwStateAction = 2; // WTD_STATEACTION_CLOSE
            WinVerifyTrust(-1, ref action, ref data);
            return result == 0;
        } finally {
            Marshal.DestroyStructure<FileInfo>(filePtr);
            Marshal.FreeHGlobal(filePtr);
        }
    }
}
