namespace Mailficient {
// NetworkMonitor can emit its first online state immediately after a handler is
// connected. That is discovery, not a reconnect, and must not start expensive
// mail work while the first window is being drawn.
public class StartupSyncGate : Object {
    // Let the first window finish drawing, but do not make startup mail wait
    // ten seconds before the first connection attempt.
    public const uint GRACE_SECONDS = 2;
    private bool enabled;
    private bool last_available;

    public StartupSyncGate (bool initially_available) {
        last_available = initially_available;
    }

    public void enable_reconnect_sync () {
        enabled = true;
    }

    public bool should_sync_for_network_change (bool available) {
        bool reconnected = enabled && !last_available && available;
        last_available = available;
        return reconnected;
    }
}
}
