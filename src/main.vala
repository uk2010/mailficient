int main (string[] args) {
    foreach (var argument in args) {
        if (argument == "--background-send")
            return Mailficient.BackgroundSendRunner.run_once_command ();
        if (argument == "--background")
            return Mailficient.BackgroundSendRunner.run_resident_command ();
    }
    return new Mailficient.MailApplication ().run (args);
}
