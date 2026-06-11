import Foundation
import SwiftUI

/// Synchronous cache for the expensive HTML → AttributedString conversion that
/// formatted Matrix message bodies require.
///
/// **Why synchronous matters.** The conversion uses
/// `NSAttributedString(data:options:)` with the HTML document type, which is
/// slow enough that calling it on every SwiftUI body re-evaluation visibly lags
/// scrolling in busy rooms. An earlier fix moved the work into `.onAppear`,
/// populating an `@State` after the first render. That made each bubble render
/// twice — first with the plain-text fallback (one height), then with the
/// formatted version (potentially a different height). The reflow happened
/// *after* `MessageScrollView`'s scroll-to-bottom fired, leaving the last
/// message clipped below the visible area. Returning a non-nil value on the
/// **first** call for valid HTML keeps the row's height stable across renders
/// so the auto-scroll lands in the right place.
///
/// **Sanitization.** The input is attacker-controlled (any Matrix sender can
/// embed arbitrary HTML in `formatted_body`). `NSAttributedString`'s HTML
/// parser happily issues network requests for `<img src>`, `<link href>`,
/// `<iframe>`, `<style>@import`, etc. — which would leak the reader's IP
/// and exact render timestamp to a malicious sender as soon as the message
/// appears. We strip tags not on the Matrix-allowlist and neutralise hrefs
/// with unsafe schemes before handing bytes to the renderer.
public enum MessageRenderCache {
    private static let cache = NSCache<NSString, AttributedStringBox>()

    public static func attributedString(for formattedBody: String?) -> AttributedString? {
        guard let formattedBody, !formattedBody.isEmpty else { return nil }
        let key = formattedBody as NSString
        if let cached = cache.object(forKey: key) {
            return cached.value
        }
        guard let computed = build(from: formattedBody) else { return nil }
        cache.setObject(AttributedStringBox(value: computed), forKey: key)
        return computed
    }

    private static func build(from html: String) -> AttributedString? {
        let safe = HtmlSanitizer.sanitize(html)
        let wrapped = "<html><body style=\"font-family: -apple-system; font-size: 14px;\">\(safe)</body></html>"
        guard let data = wrapped.data(using: .utf8),
              let nsAttr = try? NSAttributedString(
                  data: data,
                  options: [.documentType: NSAttributedString.DocumentType.html,
                            .characterEncoding: String.Encoding.utf8.rawValue],
                  documentAttributes: nil
              ) else { return nil }
        return try? AttributedString(nsAttr, including: \.swiftUI)
    }

    private final class AttributedStringBox {
        let value: AttributedString
        init(value: AttributedString) { self.value = value }
    }
}

/// Minimal allowlist-based HTML sanitiser for Matrix `formatted_body` content.
///
/// This is intentionally simple — we don't need a full parser because we only
/// care about cutting out the tags that make `NSAttributedString`'s HTML
/// parser do I/O (image/link/style/iframe fetches) or execute script. Anything
/// unrecognised is dropped tag-only; the text between the tags survives.
public enum HtmlSanitizer {
    /// Tags whose entire *content* is discarded along with the tag itself —
    /// these either fire network requests, execute script, or render outside
    /// the normal DOM flow in ways NSAttributedString can't vet.
    private static let blockTags: Set<String> = [
        "script", "style", "iframe", "object", "embed",
        "svg", "math", "template", "noscript",
    ]

    /// Tags we keep. Re-emitted with **all attributes dropped** — inline
    /// `style`/`background` on an allowed tag would otherwise make the
    /// renderer fetch CSS `url()` resources. The only attribute that
    /// survives is a scheme-validated `href` on `a`.
    /// This matches the Matrix spec's `formatted_body` allowlist, minus
    /// `img` (NSAttributedString fetches the URL) and the wrappers we handle
    /// ourselves (`html`, `body`).
    private static let allowedTags: Set<String> = [
        "a", "b", "i", "u", "s", "strong", "em", "del", "code", "pre",
        "blockquote", "p", "br", "hr",
        "h1", "h2", "h3", "h4", "h5", "h6",
        "ul", "ol", "li",
        "table", "thead", "tbody", "tr", "th", "td", "caption",
        "span", "div",
    ]

    /// Schemes we allow on `a href`. Anything else (javascript:, data:,
    /// file:, vbscript:, about:, chrome:) is replaced with `#`.
    private static let safeHrefSchemes: Set<String> = [
        "http", "https", "mailto", "matrix", "mxc",
    ]

    public static func sanitize(_ html: String) -> String {
        // 1. Drop entire dangerous blocks, tag + content. Covers both the
        //    "fetches URL" family (`iframe`, `object`, `embed`, `svg`) and
        //    the "executes code" family (`script`, `style`).
        var s = html
        for tag in blockTags {
            // Non-greedy, DOTALL-like via `[\s\S]` (regex `.` doesn't match
            // newlines by default in Foundation).
            let pattern = "<\\s*\(tag)\\b[^>]*>[\\s\\S]*?<\\s*/\\s*\(tag)\\s*>"
            s = s.replacingOccurrences(
                of: pattern, with: "",
                options: [.regularExpression, .caseInsensitive]
            )
            // And the self-closing / unclosed variant.
            s = s.replacingOccurrences(
                of: "<\\s*\(tag)\\b[^>]*/?>",
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
        }

        // 2. Re-emit allowed tags stripped of every attribute (except a
        //    validated href on `a`); drop disallowed tags, keeping inner
        //    text. Attribute stripping is what prevents inline `style=`/
        //    `background=` from triggering CSS url() fetches, and it
        //    subsumes `on*` handlers and unsafe href schemes — including
        //    entity-encoded ones, since the scheme check runs on the raw
        //    (undecoded) text and only ASCII-letter schemes pass.
        s = rebuildAllowedTags(s)

        return s
    }

    private static func rebuildAllowedTags(_ html: String) -> String {
        var out = ""
        out.reserveCapacity(html.count)
        var i = html.startIndex
        while i < html.endIndex {
            let c = html[i]
            if c != "<" {
                out.append(c)
                i = html.index(after: i)
                continue
            }
            // Find the matching `>` (simple HTML — we don't try to handle
            // angle brackets inside attributes; Matrix content shouldn't
            // have them, and any residual parse error just shows as text).
            guard let gt = html[i...].firstIndex(of: ">") else {
                out.append(c)
                i = html.index(after: i)
                continue
            }
            let tagText = html[html.index(after: i)..<gt]
            let isClosing = tagText.first == "/"
            let name = extractTagName(tagText)
            if allowedTags.contains(name) {
                if isClosing {
                    out.append("</\(name)>")
                } else if name == "a", let href = safeHref(in: tagText) {
                    out.append("<a href=\"\(href)\">")
                } else {
                    out.append("<\(name)>")
                }
            }
            // else: drop the tag, keep surrounding text.
            i = html.index(after: gt)
        }
        return out
    }

    /// Extract the href value from an `<a ...>` tag body and return it only
    /// if it carries an explicit, allowlisted scheme. The check runs on the
    /// raw attribute text: `&#106;avascript:` or `%6aavascript:` never
    /// matches a pure-ASCII-letter scheme, so encoded schemes are rejected
    /// before the HTML parser gets a chance to decode them.
    private static func safeHref(in tag: Substring) -> String? {
        guard let range = tag.range(
            of: "href\\s*=\\s*(\"[^\"]*\"|'[^']*'|[^\\s>]+)",
            options: [.regularExpression, .caseInsensitive]
        ) else { return nil }

        guard let eq = tag[range].firstIndex(of: "=") else { return nil }
        var value = tag[tag.index(after: eq)..<range.upperBound]
            .trimmingCharacters(in: .whitespaces)
        if (value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2)
            || (value.hasPrefix("'") && value.hasSuffix("'") && value.count >= 2)
        {
            value = String(value.dropFirst().dropLast())
        }

        guard let colon = value.firstIndex(of: ":") else { return nil }
        let scheme = value[..<colon].lowercased()
        guard scheme.allSatisfy({ $0.isLetter }), safeHrefSchemes.contains(scheme) else {
            return nil
        }
        // No quotes in the re-embedded value — prevents attribute breakout.
        guard !value.contains("\""), !value.contains("'") else { return nil }
        return value
    }

    private static func extractTagName(_ tag: Substring) -> String {
        var s = tag
        if s.first == "/" { s = s.dropFirst() }
        var name = ""
        for ch in s {
            if ch.isLetter || ch.isNumber { name.append(ch) } else { break }
        }
        return name.lowercased()
    }
}
