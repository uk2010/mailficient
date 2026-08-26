namespace Mailficient {
public class QuickStepService : Object {
    private CacheDatabase cache;
    public QuickStepService (CacheDatabase cache) { this.cache = cache; }

    public int execute (QuickStep step, Gee.Iterable<Message> messages) throws MailError {
        int applied = 0;
        foreach (var summary in messages) {
            var message = cache.find_cached_message (summary.id) ?? summary;
            if (step.account_id != "" && step.account_id != message.account_id) continue;
            MailRuleService.apply_operations (cache, message, step.operations); applied++;
        }
        return applied;
    }
}
}
