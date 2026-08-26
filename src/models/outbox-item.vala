namespace Mailficient {
public enum OutboxDeliveryState {
    QUEUED,
    // SMTP may have accepted a SENDING item. It is intentionally never
    // retried automatically. PREPARING is a renewable pre-SMTP claim and is
    // safe to recover after its lease expires.
    SENDING,
    ACCEPTED,
    REJECTED,
    PREPARING
}

public class OutboxItem : Object {
    public Draft draft { get; construct; }
    public int attempts { get; construct; }
    public int64 next_attempt_at { get; construct; }
    public string last_error { get; construct; }
    public OutboxDeliveryState delivery_state { get; construct; }
    public int64 undo_until { get; construct; }

    public OutboxItem (Draft draft, int attempts, int64 next_attempt_at, string last_error,
                       OutboxDeliveryState delivery_state = OutboxDeliveryState.QUEUED,
                       int64 undo_until = 0) {
        Object (draft: draft, attempts: attempts, next_attempt_at: next_attempt_at,
                last_error: last_error, delivery_state: delivery_state,
                undo_until: undo_until);
    }

    public bool requires_resend_confirmation () {
        return delivery_state == OutboxDeliveryState.SENDING;
    }

    public bool can_attempt_delivery () {
        return delivery_state != OutboxDeliveryState.ACCEPTED &&
            delivery_state != OutboxDeliveryState.PREPARING;
    }

    public bool can_undo (int64 now = 0) {
        if (now == 0) now = new DateTime.now_utc ().to_unix ();
        return delivery_state == OutboxDeliveryState.QUEUED && undo_until > now;
    }
}
}
