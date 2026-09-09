import Foundation

/// Realistic `pmset -g custom` output from an Apple silicon MacBook Pro.
///
/// Kept verbatim (tabs and all) so the parser is exercised against the real shape, including
/// the unmanaged keys it has to ignore and the non-numeric `hibernatefile` value.
enum Fixtures {
    static let customLaptop = """
    Battery Power:
     lidwake              1
     autopoweroff         1
     autopoweroffdelay    259200
     standbydelay         10800
     standby              1
     ttyskeepawake        1
     hibernatemode        3
     powernap             0
     gpuswitch            2
     hibernatefile        /var/vm/sleepimage
     highstandbythreshold 50
     displaysleep         5
     sleep                1
     tcpkeepalive         1
     halfdim              1
     acwake               0
     lowpowermode         0
     disksleep            10
    AC Power:
     lidwake              1
     autopoweroff         1
     autopoweroffdelay    259200
     standbydelay         10800
     standby              1
     ttyskeepawake        1
     hibernatemode        3
     powernap             1
     gpuswitch            2
     hibernatefile        /var/vm/sleepimage
     highstandbythreshold 50
     displaysleep         10
     sleep                30
     tcpkeepalive         1
     halfdim              1
     acwake               0
     lowpowermode         0
     disksleep            10
    """

    /// A desktop reports only an AC section.
    static let customDesktop = """
    AC Power:
     womp                 1
     powernap             1
     networkoversleep     0
     disksleep            10
     sleep                60
     displaysleep         10
     ttyskeepawake        1
    """

    /// Some machines do not report `tcpkeepalive` at all.
    static let customNoTCPKeepAlive = """
    Battery Power:
     sleep                1
     disksleep            10
     displaysleep         5
     powernap             0
    AC Power:
     sleep                30
     disksleep            10
     displaysleep         10
     powernap             1
    """

    static let liveSleepDisabledOn = """
    System-wide power settings:
     SleepDisabled\t\t1
    Currently in use:
     standby              1
     Sleep On Power Button 1
     hibernatefile        /var/vm/sleepimage
     powernap             0
     disksleep            0
     sleep                0
     displaysleep         2
    """

    static let liveSleepDisabledOff = """
    System-wide power settings:
     SleepDisabled\t\t0
    Currently in use:
     standby              1
     displaysleep         10
    """

    /// An older macOS that does not surface the flag at all.
    static let liveNoSleepDisabled = """
    System-wide power settings:
     DestroyFVKeyOnStandby 0
    Currently in use:
     standby              1
     displaysleep         10
    """
}
