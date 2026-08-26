namespace Mailficient {
public class SpellingIssue : Object {
    public string word { get; construct; }
    public int start_offset { get; construct; }
    public int end_offset { get; construct; }
    public Gee.ArrayList<string> suggestions { get; construct; }

    public SpellingIssue (string word, int start_offset, int end_offset,
                          Gee.ArrayList<string>? suggestions = null) {
        Object (word: word, start_offset: start_offset, end_offset: end_offset,
                suggestions: suggestions ?? new Gee.ArrayList<string> ());
    }
}

private class SpellingToken : Object {
    public string word;
    public string key;
    public int start_offset;
    public int end_offset;

    public SpellingToken (string word, int start_offset, int end_offset) {
        this.word = word;
        this.key = word.down ();
        this.start_offset = start_offset;
        this.end_offset = end_offset;
    }
}

// Spell checking never sends message text to a service.  When available, the
// local Enchant/Aspell pipe provides the installed desktop dictionaries and
// corrections.  The small built-in correction table remains useful in a
// minimal sandbox without either executable.
public class LocalSpellChecker : Object {
    private string? executable;
    private bool uses_enchant;
    private Gee.HashSet<string> ignored = new Gee.HashSet<string> ();

    public LocalSpellChecker (bool fallback_only = false) {
        if (fallback_only) return;
        executable = Environment.find_program_in_path ("enchant-2");
        uses_enchant = executable != null;
        if (executable == null)
            executable = Environment.find_program_in_path ("aspell");
    }

    public bool has_system_dictionary {
        get { return executable != null; }
    }

    public void ignore (string word) {
        string key = word.strip ().down ();
        if (key != "") ignored.add (key);
    }

    public async Gee.ArrayList<SpellingIssue> check (
        string text, Cancellable? cancellable = null) throws Error {
        var tokens = tokenize (text);
        if (tokens.size == 0) return new Gee.ArrayList<SpellingIssue> ();
        if (executable == null) return unignored_fallback_issues (tokens);

        var unique_words = new Gee.ArrayList<string> ();
        var unique_keys = new Gee.ArrayList<string> ();
        var seen = new Gee.HashSet<string> ();
        foreach (var token in tokens) {
            if (ignored.contains (token.key) || seen.contains (token.key)) continue;
            seen.add (token.key); unique_words.add (token.word); unique_keys.add (token.key);
        }
        if (unique_words.size == 0) return new Gee.ArrayList<SpellingIssue> ();

        string locale = dictionary_locale ();
        string[] arguments;
        if (uses_enchant)
            arguments = { executable, "-a", "-d", locale };
        else
            arguments = { executable, "-a", "--lang=" + locale, "--encoding=utf-8" };
        var process = new Subprocess.newv (arguments,
            SubprocessFlags.STDIN_PIPE | SubprocessFlags.STDOUT_PIPE |
            SubprocessFlags.STDERR_PIPE);
        var input = new StringBuilder ();
        foreach (var word in unique_words) input.append (word).append_c ('\n');
        string? standard_output;
        string? standard_error;
        yield process.communicate_utf8_async (input.str, cancellable,
            out standard_output, out standard_error);
        if (!process.get_successful () || standard_output == null)
            return unignored_fallback_issues (tokens);

        var misspelled = new Gee.HashSet<string> ();
        var corrections = new Gee.HashMap<string, Gee.ArrayList<string>> ();
        int result_index = 0;
        foreach (string line_value in standard_output.split ("\n")) {
            string line = line_value.strip ();
            if (line == "" || line.has_prefix ("@")) continue;
            if (result_index >= unique_keys.size) break;
            string key = unique_keys[result_index++];
            if (line.has_prefix ("&") || line.has_prefix ("#") ||
                line.has_prefix ("?")) {
                misspelled.add (key);
                corrections[key] = parse_corrections (line);
            }
        }
        // A dictionary/provider error can produce no parseable result lines.
        // Fall back instead of silently claiming that every word is correct.
        if (result_index == 0 && unique_keys.size > 0)
            return unignored_fallback_issues (tokens);

        var issues = new Gee.ArrayList<SpellingIssue> ();
        foreach (var token in tokens) {
            if (!misspelled.contains (token.key) || ignored.contains (token.key)) continue;
            issues.add (new SpellingIssue (token.word, token.start_offset,
                token.end_offset, corrections.has_key (token.key) ?
                copy_suggestions (corrections[token.key]) : null));
        }
        return issues;
    }

    private Gee.ArrayList<SpellingIssue> unignored_fallback_issues (
        Gee.ArrayList<SpellingToken> tokens) {
        var filtered = new Gee.ArrayList<SpellingIssue> ();
        foreach (var issue in fallback_issues (tokens))
            if (!ignored.contains (issue.word.down ())) filtered.add (issue);
        return filtered;
    }

    internal static Gee.ArrayList<SpellingIssue> fallback_check (string text) {
        return fallback_issues (tokenize (text));
    }

    private static Gee.ArrayList<SpellingToken> tokenize (string text) {
        var tokens = new Gee.ArrayList<SpellingToken> ();
        try {
            var address_pattern = new Regex ("(?:https?://|www\\.)\\S+|\\S+@\\S+",
                RegexCompileFlags.CASELESS);
            var excluded = new Gee.ArrayList<int> ();
            MatchInfo address_matches;
            if (address_pattern.match (text, 0, out address_matches)) {
                do {
                    int start_byte; int end_byte;
                    if (address_matches.fetch_pos (0, out start_byte, out end_byte)) {
                        excluded.add (start_byte); excluded.add (end_byte);
                    }
                } while (address_matches.next ());
            }

            var word_pattern = new Regex ("[\\p{L}\\p{M}]+(?:['’\\-][\\p{L}\\p{M}]+)*");
            MatchInfo matches;
            if (!word_pattern.match (text, 0, out matches)) return tokens;
            do {
                int start_byte; int end_byte;
                if (!matches.fetch_pos (0, out start_byte, out end_byte)) continue;
                bool excluded_word = false;
                for (int index = 0; index + 1 < excluded.size; index += 2) {
                    if (start_byte >= excluded[index] && start_byte < excluded[index + 1]) {
                        excluded_word = true; break;
                    }
                }
                if (excluded_word) continue;
                string word = matches.fetch (0);
                if (should_skip_word (word)) continue;
                int start_offset = text.substring (0, start_byte).char_count ();
                tokens.add (new SpellingToken (word, start_offset,
                    start_offset + word.char_count ()));
            } while (matches.next ());
        } catch (RegexError error) {
            warning ("Could not tokenize text for local spell checking: %s", error.message);
        }
        return tokens;
    }

    private static bool should_skip_word (string word) {
        if (word.char_count () <= 1) return true;
        // Short all-capital words are usually initials, project names, or
        // acronyms. Installed dictionaries often flag all three.
        return word.char_count () <= 6 && word == word.up () && word != word.down ();
    }

    private static string dictionary_locale () {
        string? locale = Environment.get_variable ("LC_ALL");
        if (locale == null || locale == "") locale = Environment.get_variable ("LC_MESSAGES");
        if (locale == null || locale == "") locale = Environment.get_variable ("LANG");
        if (locale == null || locale == "" || locale == "C" || locale == "POSIX") return "en_US";
        int dot = locale.index_of (".");
        if (dot >= 0) locale = locale.substring (0, dot);
        int modifier = locale.index_of ("@");
        if (modifier >= 0) locale = locale.substring (0, modifier);
        if (locale == "C" || locale == "POSIX") return "en_US";
        return locale.replace ("-", "_");
    }

    private static Gee.ArrayList<string> parse_corrections (string line) {
        var values = new Gee.ArrayList<string> ();
        int colon = line.index_of (":");
        if (colon < 0 || colon + 1 >= line.length) return values;
        foreach (string candidate in line.substring (colon + 1).split (",")) {
            string value = candidate.strip ();
            if (value == "" || values.contains (value)) continue;
            values.add (value);
            if (values.size == 8) break;
        }
        return values;
    }

    private static Gee.ArrayList<string> copy_suggestions (Gee.ArrayList<string> source) {
        var copy = new Gee.ArrayList<string> ();
        foreach (var value in source) copy.add (value);
        return copy;
    }

    private static Gee.ArrayList<SpellingIssue> fallback_issues (
        Gee.ArrayList<SpellingToken> tokens) {
        var common = new Gee.HashMap<string, string> ();
        common["acommodate"] = "accommodate"; common["acheive"] = "achieve";
        common["adress"] = "address"; common["arguement"] = "argument";
        common["begining"] = "beginning"; common["calender"] = "calendar";
        common["definately"] = "definitely"; common["embarass"] = "embarrass";
        common["enviroment"] = "environment"; common["goverment"] = "government";
        common["independant"] = "independent"; common["maintainance"] = "maintenance";
        common["neccessary"] = "necessary"; common["occured"] = "occurred";
        common["recieve"] = "receive"; common["seperate"] = "separate";
        common["succesful"] = "successful"; common["teh"] = "the";
        common["tomorow"] = "tomorrow"; common["untill"] = "until";
        common["wierd"] = "weird"; common["writting"] = "writing";
        var issues = new Gee.ArrayList<SpellingIssue> ();
        foreach (var token in tokens) {
            if (!common.has_key (token.key)) continue;
            var suggestions = new Gee.ArrayList<string> ();
            suggestions.add (common[token.key]);
            issues.add (new SpellingIssue (token.word, token.start_offset,
                token.end_offset, suggestions));
        }
        return issues;
    }
}

public class ComposeSafetyService : Object {
    public static bool mentions_missing_attachment (string subject, string body,
                                                    bool has_attachment) {
        if (has_attachment) return false;
        string authored = authored_text (subject + "\n" + body).down ();
        if (authored.strip () == "") return false;
        try {
            var negated = new Regex ("\\b(?:no|not|without|don['’]?t|do not)\\s+(?:an?\\s+)?" +
                "(?:attach(?:ed|ment|ments|ing)?|enclos(?:e|ed|ure))\\b",
                RegexCompileFlags.CASELESS);
            string inspected = negated.replace (authored, -1, 0, " ");
            var intent = new Regex ("\\b(?:attach(?:ed|ment|ments|ing)?|enclos(?:e|ed|ure)|" +
                "see\\s+(?:the\\s+)?(?:file|document|pdf|image|photo|screenshot|spreadsheet)|" +
                "included\\s+(?:the\\s+)?(?:file|document|pdf|image|photo|screenshot|spreadsheet))\\b",
                RegexCompileFlags.CASELESS);
            return intent.match (inspected);
        } catch (RegexError error) {
            warning ("Could not inspect attachment wording: %s", error.message);
            return false;
        }
    }

    private static string authored_text (string text) {
        int boundary = text.length;
        foreach (string marker in new string[] {
            "---------- Forwarded message ----------", "\nOn ", "\n>"
        }) {
            int position = text.index_of (marker);
            if (position >= 0 && position < boundary) boundary = position;
        }
        return boundary == text.length ? text : text.substring (0, boundary);
    }
}
}
