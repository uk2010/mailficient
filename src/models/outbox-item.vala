namespace Mailficient {
public enum OutboxDeliveryState { QUEUED, SENDING, ACCEPTED, REJECTED }

public class OutboxItem : Object {
    public Draft draft { get; construct; }
    public int attempts { get; construct; }
    public int64 next_attempt_at { get; construct; }
    public string last_error { get; construct; }
    public OutboxDeliveryState delivery_state { get; construct; }

    public OutboxItem (Draft draft, int attempts, int64 next_attempt_at, string last_error,
                       OutboxDeliveryState delivery_state = OutboxDeliveryState.QUEUED) {
        Object (draft: draft, attempts: attempts, next_attempt_at: next_attempt_at,
                last_error: last_error, delivery_state: delivery_state);
    }

    public bool requires_resend_confirmation () {
        return delivery_state == OutboxDeliveryState.SENDING;
    }

    public bool can_attempt_delivery () {
        return delivery_state != OutboxDeliveryState.ACCEPTED;
    }
}
}
