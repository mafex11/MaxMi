import Foundation

/// Canonicalizes a browser URL into a STABLE thread key, so a single logical page/place
/// doesn't fracture into dozens of threads when volatile state lives in the URL.
///
/// Evidence (from the live DB) this fixes:
///   - Google Maps: /maps/@13.00,77.71,2550m/data=... changes every pan → 18 threads for one map
///   - Google search: ?q=X&rlz=…&oq=…&gs_lcrp=… → tracking params fracture the same query
///   - Google Docs:  /document/d/<id>/edit?tab=t.abc → same doc, different tab → separate threads
///
/// Strategy: (1) site-specific canonicalization for known offenders, then (2) a generic pass
/// that strips tracking query params. Fragments are KEPT (some apps, e.g. Gmail #inbox, encode
/// identity there). Unparseable URLs pass through untouched.
public enum URLKeyNormalizer {
    /// Query params that are pure tracking/session noise — dropped generically.
    static let trackingParams: Set<String> = [
        "rlz", "oq", "gs_lcrp", "sourceid", "ie", "sei", "ei", "ved", "sca_esv", "gs_lp",
        "entry", "g_ep", "usg", "sa", "aqs", "uact",
        "utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content", "utm_id",
        "fbclid", "gclid", "mc_cid", "mc_eid", "ref", "ref_src", "spm",
    ]

    public static func normalize(_ urlString: String) -> String {
        guard var comps = URLComponents(string: urlString), let host = comps.host?.lowercased() else {
            return urlString
        }
        // ── (1) Site-specific canonicalization ──
        if host.contains("google.") {
            // Maps: collapse the volatile @lat,lng,zoom + /data segment. Keep a named place if present.
            if comps.path.hasPrefix("/maps") {
                if let placeRange = comps.path.range(of: "/maps/place/[^/@]+", options: .regularExpression) {
                    comps.path = String(comps.path[placeRange])   // /maps/place/<name>
                } else {
                    comps.path = "/maps"
                }
                comps.query = nil; comps.fragment = nil
                return rebuild(comps)
            }
            // Search: the query IS the identity — keep only q, drop all tracking.
            if comps.path.hasPrefix("/search"), let q = queryValue(comps, "q") {
                comps.queryItems = [URLQueryItem(name: "q", value: q)]
                comps.fragment = nil
                return rebuild(comps)
            }
            // Docs/Sheets/Slides: /document/d/<id>/... → identity is the doc id.
            if let docRange = comps.path.range(of: "/(document|spreadsheets|presentation)/d/[^/]+", options: .regularExpression) {
                comps.path = String(comps.path[docRange])
                comps.query = nil; comps.fragment = nil
                return rebuild(comps)
            }
        }
        // ── (2) Generic tracking-param strip ──
        if let items = comps.queryItems, !items.isEmpty {
            let kept = items.filter { !trackingParams.contains($0.name.lowercased()) }
            comps.queryItems = kept.isEmpty ? nil : kept
        }
        return rebuild(comps)
    }

    private static func queryValue(_ comps: URLComponents, _ name: String) -> String? {
        comps.queryItems?.first { $0.name == name }?.value
    }

    private static func rebuild(_ comps: URLComponents) -> String {
        comps.string ?? comps.host.map { "https://\($0)\(comps.path)" } ?? ""
    }
}
