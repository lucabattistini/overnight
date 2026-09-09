import Foundation

/// The fixed on-disk locations Overnight uses.
///
/// All three are root-owned. Nothing here is ever written by the app running as the user:
/// only the privileged payload writes them, which is what keeps the file `launchd` executes
/// out of reach of a non-root process.
public enum OvernightPaths {
    public static let bundleIdentifier = "dev.lucabattistini.overnight"
    public static let launchDaemonLabel = "dev.lucabattistini.overnight.restore"

    /// Root-owned, mode 0755. The payload verifies these properties and aborts if they differ
    /// rather than creating or repairing the directory.
    public static let supportDirectory = "/Library/Application Support/Overnight"
    public static let stateFile = supportDirectory + "/state.conf"
    /// The copy of the restore script that `launchd` executes, installed root:wheel 0755.
    public static let installedRestoreScript = supportDirectory + "/overnight-restore.sh"
    public static let launchDaemonPlist = "/Library/LaunchDaemons/\(launchDaemonLabel).plist"

    public static let pmsetExecutable = "/usr/bin/pmset"
}
