//
//  SplitwiseNotificationContent.swift
//  Relay
//
//  Turns a Splitwise notification's `content` HTML into an AttributedString
//  for SplitwiseActivityView's rows.
//
//  Hand-rolled rather than NSAttributedString's `.html` document type, which
//  pulls in the WebKit-backed importer, must run on the main thread, and takes
//  milliseconds per string — far too much for 50 list rows. Splitwise documents
//  the exact, tiny tag set it emits, so one pass covers all of it.
//
//  Deliberately lenient, since this is untrusted remote text: an unknown tag is
//  dropped but its inner text kept, a stray `<` renders literally, and an
//  unbalanced closing tag is ignored. Worst case a run renders unstyled.
//

import SwiftUI

nonisolated enum SplitwiseNotificationContent {
    /// A stack, so nesting composes instead of the inner tag replacing the outer
    /// one — Splitwise emits `<strike><strong>…</strong></strike>` for a deleted
    /// expense's description.
    private enum Style {
        case bold
        case strikethrough
        case small
        /// Nil for a `<font>` whose color Relay doesn't translate: it still belongs
        /// on the stack so its `</font>` pops itself, but it must leave the run's
        /// color alone rather than overriding an enclosing `<small>`.
        case color(Color?)

        /// So a closing tag pops the matching entry rather than whatever's on top.
        var tagName: String {
            switch self {
            case .bold: "strong"
            case .strikethrough: "strike"
            case .small: "small"
            case .color: "font"
            }
        }
    }

    static func attributedString(from html: String) -> AttributedString {
        var result = AttributedString()
        var styles: [Style] = []
        /// Flushed as one run once the styles are about to change.
        var pending = ""

        func flushPending() {
            guard !pending.isEmpty else { return }
            var run = AttributedString(decodingEntities(in: pending))
            run.mergeAttributes(container(for: styles))
            result += run
            pending = ""
        }

        var index = html.startIndex
        while index < html.endIndex {
            guard html[index] == "<", let end = tagEnd(in: html, openedAt: index) else {
                pending.append(html[index])
                index = html.index(after: index)
                continue
            }
            flushPending()
            let tag = html[html.index(after: index)..<end].trimmingCharacters(in: .whitespaces)
            if tag.hasPrefix("/") {
                let name = canonicalName(of: String(tag.dropFirst()))
                // Innermost first, and only when actually open — a stray closing
                // tag mustn't pop something it didn't open.
                if let match = styles.lastIndex(where: { $0.tagName == name }) {
                    styles.remove(at: match)
                }
            } else if let opened = style(forTag: tag) {
                styles.append(opened)
            } else if canonicalName(of: tag) == "br" {
                // Not a style, and self-closing — nothing to push.
                result += AttributedString("\n")
            }
            index = html.index(after: end)
        }
        flushPending()
        return result
    }

    /// The `>` closing the tag at `start`, or nil when that `<` isn't opening a
    /// tag and should render as itself.
    ///
    /// Both rejections matter for an unescaped `<` in real text — an expense
    /// called "1 < 2 but 3 > 2", say. Requiring a letter or `/` next rules that
    /// one out, and stopping at the next `<` keeps a genuinely unclosed tag from
    /// swallowing the rest of the string up to some unrelated `>`.
    private static func tagEnd(in html: String, openedAt start: String.Index) -> String.Index? {
        let nameStart = html.index(after: start)
        guard nameStart < html.endIndex, html[nameStart].isLetter || html[nameStart] == "/" else { return nil }
        guard let end = html[nameStart...].firstIndex(where: { $0 == ">" || $0 == "<" }), html[end] == ">" else { return nil }
        return end
    }

    /// Nil for a tag carrying no styling (`<br>`) or one Relay doesn't recognize,
    /// in which case only the tag is dropped and its inner text still renders.
    private static func style(forTag tag: String) -> Style? {
        switch canonicalName(of: tag) {
        case "strong": .bold
        case "strike": .strikethrough
        case "small": .small
        case "font": .color(semanticColor(inFontTag: tag))
        default: nil
        }
    }

    /// Lowercased, with attributes and any self-closing slash stripped, and HTML
    /// synonyms folded onto one spelling so `</b>` closes `<strong>`.
    private static func canonicalName(of tag: String) -> String {
        let name = tag.prefix { !$0.isWhitespace && $0 != "/" }.lowercased()
        switch name {
        case "b": return "strong"
        case "s", "del": return "strike"
        default: return name
        }
    }

    private static func container(for styles: [Style]) -> AttributeContainer {
        var container = AttributeContainer()
        for style in styles {
            switch style {
            // `inlinePresentationIntent` rather than an explicit bold font, so the
            // run keeps whatever font the row applies from outside.
            case .bold: container.inlinePresentationIntent = .stronglyEmphasized
            case .strikethrough: container.strikethroughStyle = .single
            case .small: container.foregroundColor = .secondary
            case .color(let color): if let color { container.foregroundColor = color }
            }
        }
        return container
    }

    /// Maps Splitwise's greens (money coming back) to the accent color and its
    /// reds/oranges (money owed) to `.red`, rather than using the hex directly:
    /// Splitwise picks its colors against a white background, so a literal hex
    /// lands anywhere from washed-out to invisible in dark mode. Nil for
    /// everything else, leaving the run at the row's own text color.
    ///
    /// Channels are compared against each other rather than matched to known
    /// hexes, since Splitwise uses several shades and documents none as fixed.
    /// The margin keeps a near-grey from reading as either.
    private static func semanticColor(inFontTag tag: String) -> Color? {
        guard let colorAttribute = tag.range(of: "color", options: .caseInsensitive) else { return nil }
        let value = tag[colorAttribute.upperBound...].drop { $0 == " " || $0 == "=" || $0 == "\"" || $0 == "'" || $0 == "#" }
        let hex = value.prefix(while: \.isHexDigit)
        guard hex.count == 6, let bits = UInt32(hex, radix: 16) else { return nil }
        let red = Int((bits >> 16) & 0xFF)
        let green = Int((bits >> 8) & 0xFF)
        let margin = 24
        if green > red + margin { return Color.accentColor }
        if red > green + margin { return .red }
        return nil
    }

    /// `&amp;` is last on purpose: decoding it first would turn a
    /// double-escaped `&amp;lt;` into `&lt;` and then into `<`, showing markup
    /// the sender had escaped.
    private static let entities: [(escaped: String, character: String)] = [
        ("&lt;", "<"),
        ("&gt;", ">"),
        ("&quot;", "\""),
        ("&#39;", "'"),
        ("&apos;", "'"),
        ("&nbsp;", "\u{00A0}"),
        ("&amp;", "&"),
    ]

    private static func decodingEntities(in text: String) -> String {
        guard text.contains("&") else { return text }
        return entities.reduce(text) { $0.replacingOccurrences(of: $1.escaped, with: $1.character) }
    }
}
