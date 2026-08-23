namespace Mailficient {
public class SmartMailbox : Object {
    public int64 id { get; construct; }
    public string name { get; construct; }
    public string query { get; construct; }

    public SmartMailbox (int64 id, string name, string query) {
        Object (id: id, name: name, query: query);
    }
}
}
