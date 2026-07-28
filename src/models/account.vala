namespace Mailficient {
public class Account : Object {
    public string id { get; construct; }
    public string display_name { get; set; }
    public string email { get; set; }
    public string color { get; set; default = "blue"; }

    public Account (string id, string display_name, string email) {
        Object (id: id, display_name: display_name, email: email);
    }
}
}
