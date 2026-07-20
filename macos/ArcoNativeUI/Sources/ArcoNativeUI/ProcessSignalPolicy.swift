import Darwin

public enum ArcoProcessSignalPolicy {
    public static func install() {
        signal(SIGPIPE, SIG_IGN)
    }
}
