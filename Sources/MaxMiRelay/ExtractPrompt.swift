enum ExtractPrompt {
    static func build(newContent: String, previousContent: String?, sourceApp: String, sourceKey: String) -> String {
        var p = """
        You extract memory facts from a snapshot of what a user is reading on screen.

        Return ONLY a JSON array of strings. Each string is one atomic, self-contained, \
        third-person fact sentence about what the user did, read, or learned — naming the \
        user by their first name (use "The user" if unknown). 2-6 facts for a rich page, \
        [] if there is nothing meaningful (navigation chrome, empty pages, cookie banners).

        Source: \(sourceApp) — \(sourceKey)
        """
        if let prev = previousContent {
            p += """


            PREVIOUS snapshot (already processed — do NOT repeat facts derivable from it):
            ---
            \(prev)
            ---
            Extract ONLY facts that are new in the current snapshot.
            """
        }
        p += """


        CURRENT snapshot:
        ---
        \(newContent)
        ---
        JSON array:
        """
        return p
    }
}
