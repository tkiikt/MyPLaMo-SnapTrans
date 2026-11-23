using System.Security.AccessControl;
using System.Security.Principal;

namespace SnapTrans.Core;

/// <summary>
/// Whether a model file could be replaced by someone other than the current user (or an administrator): true when
/// the file or its folder grants write/delete/permission rights to a broad group such as Everyone, Authenticated Users,
/// Users or Interactive. Many secondary drives (D:\, E:\ ...) are like that by default.
/// </summary>
public static class FolderTrust
{
    [System.Runtime.Versioning.SupportedOSPlatform("windows")]
    static SecurityIdentifier[] BroadGroups() => [
        new(WellKnownSidType.WorldSid, null),                 // Everyone
        new(WellKnownSidType.AuthenticatedUserSid, null),     // Authenticated Users
        new(WellKnownSidType.BuiltinUsersSid, null),          // Users
        new(WellKnownSidType.InteractiveSid, null),           // Interactive
    ];

    static readonly Dictionary<string, (bool Result, DateTime At)> Cache = new(StringComparer.OrdinalIgnoreCase);

    /// <summary>Cached for a minute per file (the settings page asks often; ACLs rarely change).</summary>
    public static bool IsWritableByOthers(string filePath)
    {
        lock (Cache) if (Cache.TryGetValue(filePath, out var c) && DateTime.UtcNow - c.At < TimeSpan.FromMinutes(1)) return c.Result;
        var result = Check(filePath);
        lock (Cache) Cache[filePath] = (result, DateTime.UtcNow);
        return result;
    }

#pragma warning disable CA1416 // enum constants only; used on Windows
    const FileSystemRights Modify = FileSystemRights.WriteData | FileSystemRights.AppendData | FileSystemRights.Delete
        | FileSystemRights.DeleteSubdirectoriesAndFiles | FileSystemRights.ChangePermissions | FileSystemRights.TakeOwnership
        | FileSystemRights.WriteAttributes | FileSystemRights.WriteExtendedAttributes;
#pragma warning restore CA1416

    static bool Check(string filePath)
    {
        if (!OperatingSystem.IsWindows()) return false;
        try {
            var file = new FileInfo(filePath);
            if (file.Exists && Grants(file.GetAccessControl().GetAccessRules(true, true, typeof(SecurityIdentifier)), isFolder: false)) return true;
            var dir = file.Directory;
            return dir != null && dir.Exists && Grants(dir.GetAccessControl().GetAccessRules(true, true, typeof(SecurityIdentifier)), isFolder: true);
        } catch (Exception e) when (e is UnauthorizedAccessException or IOException or InvalidOperationException) {
            return true; // cannot tell: treat as untrusted
        }
    }

    [System.Runtime.Versioning.SupportedOSPlatform("windows")]
    static bool Grants(AuthorizationRuleCollection rules, bool isFolder)
    {
        var broad = BroadGroups();
        foreach (FileSystemAccessRule rule in rules) {
            if (rule.AccessControlType != AccessControlType.Allow || rule.IdentityReference is not SecurityIdentifier sid) continue;
            if (!broad.Contains(sid)) continue;
            // Folder rules only matter if they reach the files in it (object inheritance) or the folder itself.
            if (isFolder && (rule.PropagationFlags & PropagationFlags.InheritOnly) != 0 && (rule.InheritanceFlags & InheritanceFlags.ObjectInherit) == 0) continue;
            if ((rule.FileSystemRights & Modify) != 0) return true;
        }
        return false;
    }
}
