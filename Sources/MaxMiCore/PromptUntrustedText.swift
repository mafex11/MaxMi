public enum PromptUntrustedText {
    public static func sanitize(_ value: String, nonce: String, maxChars: Int) -> String {
        var result = value.replacingOccurrences(of: nonce, with: "")
        for marker in ["BEGIN_UNTRUSTED_DATA", "END_UNTRUSTED_DATA", "===", "--- BEGIN", "--- END"] {
            result = result.replacingOccurrences(of: marker, with: " ")
        }
        var scalars = String.UnicodeScalarView()
        for scalar in result.unicodeScalars {
            let value = scalar.value
            if scalar == "\n" || !(value < 0x20 || (0x7F...0x9F).contains(value)) {
                scalars.append(scalar)
            } else {
                scalars.append(" " as UnicodeScalar)
            }
        }
        return String(scalars).prefixingEllipsis(maxChars: maxChars)
    }
}

private extension String {
    func prefixingEllipsis(maxChars: Int) -> String {
        let cap = max(0, maxChars)
        guard count > cap else { return self }
        guard cap > 0 else { return "" }
        guard cap > 1 else { return "…" }
        return String(prefix(cap - 1)) + "…"
    }
}
