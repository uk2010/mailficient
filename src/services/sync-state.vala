namespace Mailficient {
public enum SyncPhase { IDLE, CONNECTING, SYNCHRONIZING, OFFLINE, PARTIAL, FAILED }
public class SyncState : Object {
    public SyncPhase phase { get; set; default = SyncPhase.IDLE; }
    public double progress { get; set; default = 0; }
    public string detail { get; set; default = ""; }
    // These counters describe the complete inventory for the current bounded
    // backend pass. AccountSyncService combines successive passes into one
    // stable, account-wide progress total.
    public int messages_to_download { get; set; default = 0; }
    public int messages_downloaded { get; set; default = 0; }
    public bool busy { get { return phase == SyncPhase.CONNECTING || phase == SyncPhase.SYNCHRONIZING; } }
}
}
