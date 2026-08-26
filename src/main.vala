int main (string[] args) {
    foreach (var argument in args) {
        if (argument == "--background-send")
            return Mailficient.BackgroundSendRunner.run_once_command ();
        if (argument == "--background")
            return Mailficient.BackgroundSendRunner.run_resident_command ();
    }

    // WebKitGTK uses libsoup in its NetworkProcess. libsoup 3.6 can enter an
    // invalid HTTP/2 read state for responses with trailers, which leaves
    // remote mail images incomplete and can destabilize the helper process.
    // WebKit does not expose a per-request HTTP-version switch, so apply
    // libsoup's supported process-level fallback before WebKit is created.
    // Preserve an inherited diagnostic setting; libsoup treats the variable's
    // presence as enabling the fallback.
    Environment.set_variable ("SOUP_FORCE_HTTP1", "1", false);
    return new Mailficient.MailApplication ().run (args);
}
