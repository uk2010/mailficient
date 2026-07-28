namespace Mailficient {
public class VacationSettings : Object {
    public string account_id { get; construct; }
    public bool enabled { get; set; }
    public int64 starts_at { get; set; }
    public int64 ends_at { get; set; }
    public string subject { get; set; }
    public string body { get; set; }
    public VacationSettings (string account_id, bool enabled = false, int64 starts_at = 0,
                             int64 ends_at = 0, string subject = "Out of office", string body = "") {
        Object (account_id: account_id, enabled: enabled, starts_at: starts_at,
            ends_at: ends_at, subject: subject, body: body);
    }
    public bool active_at (int64 now) {
        return enabled && (starts_at == 0 || starts_at <= now) && (ends_at == 0 || ends_at >= now);
    }
}
}
