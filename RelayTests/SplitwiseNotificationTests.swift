//
//  SplitwiseNotificationTests.swift
//  RelayTests
//
//  Covers the two pieces of the Activity feed that aren't just plumbing: the
//  hand-rolled parser for the notification `content` HTML (see
//  SplitwiseNotificationContent.swift for why it isn't
//  NSAttributedString's), and the rule deciding which entries may offer
//  "Restore" (SplitwiseActivityItem).
//

import Foundation
import SwiftUI
import Testing
@testable import Relay

struct SplitwiseNotificationContentTests {
    /// `String(characters)` rather than `.description`, which would also spell
    /// out the attribute runs.
    private func plainText(_ attributed: AttributedString) -> String {
        String(attributed.characters)
    }

    @Test
    func stripsTagsAndKeepsText() {
        let parsed = SplitwiseNotificationContent.attributedString(
            from: "<strong>You</strong> added <strong>Groceries</strong>."
        )
        #expect(plainText(parsed) == "You added Groceries.")
    }

    @Test
    func marksStrongRunsAsBold() {
        let parsed = SplitwiseNotificationContent.attributedString(from: "<strong>You</strong> paid")
        let boldRun = parsed.runs.first { $0.inlinePresentationIntent == .stronglyEmphasized }

        #expect(boldRun.map { String(parsed[$0.range].characters) } == "You")
        // The trailing " paid" must not inherit the closed tag's styling.
        #expect(parsed.runs.count { $0.inlinePresentationIntent == .stronglyEmphasized } == 1)
    }

    @Test
    func composesNestedStrikeAndStrong() {
        let parsed = SplitwiseNotificationContent.attributedString(
            from: "deleted <strike><strong>Dinner</strong></strike>"
        )
        guard let run = parsed.runs.first(where: { $0.strikethroughStyle != nil }) else {
            Issue.record("expected a struck-through run")
            return
        }
        #expect(String(parsed[run.range].characters) == "Dinner")
        // The inner <strong> has to survive the outer </strike> closing.
        #expect(run.inlinePresentationIntent == .stronglyEmphasized)
    }

    @Test
    func closesByTagNameRatherThanStackOrder() {
        // Splitwise's tag set doesn't promise well-nested output, so a closing
        // tag has to pop its own style, not whatever was pushed last.
        let parsed = SplitwiseNotificationContent.attributedString(
            from: "<strong><strike>a</strong>b</strike>c"
        )
        #expect(plainText(parsed) == "abc")
        for run in parsed.runs where String(parsed[run.range].characters) == "c" {
            #expect(run.inlinePresentationIntent == nil)
            #expect(run.strikethroughStyle == nil)
        }
    }

    @Test
    func rendersBreakAsNewline() {
        let parsed = SplitwiseNotificationContent.attributedString(from: "commented:<br>nice")
        #expect(plainText(parsed) == "commented:\nnice")
    }

    @Test
    func decodesEntitiesWithoutDoubleUnescaping() {
        let parsed = SplitwiseNotificationContent.attributedString(from: "&quot;Bar &amp; Grill&quot; &amp;lt;")
        #expect(plainText(parsed) == "\"Bar & Grill\" &lt;")
    }

    /// Splitwise's greens and reds are re-tinted to Relay's own money colors
    /// rather than rendered as sent — see
    /// `SplitwiseNotificationContent.semanticColor(inFontTag:)`.
    ///
    /// `##"…"##`, not `#"…"#`: the `"#` in `color="#5BC5A7"` would close a
    /// single-pound raw string right there.
    @Test
    func retintsFontColorsToTheAppsMoneyColors() {
        let green = SplitwiseNotificationContent.attributedString(from: ##"<font color="#5BC5A7">you get back</font>"##)
        #expect(green.runs.first { $0.foregroundColor != nil }?.foregroundColor == Color.accentColor)
        #expect(plainText(green) == "you get back")

        let red = SplitwiseNotificationContent.attributedString(from: ##"<font color="#FF652F">you owe</font>"##)
        #expect(red.runs.first { $0.foregroundColor != nil }?.foregroundColor == .red)
        #expect(plainText(red) == "you owe")
    }

    /// A color that's neither leaves the run at the row's own text color — and
    /// in particular doesn't reset an enclosing `<small>` back to primary.
    @Test
    func leavesOtherFontColorsUntinted() {
        let grey = SplitwiseNotificationContent.attributedString(from: ##"<font color="#888888">detail</font>"##)
        #expect(grey.runs.allSatisfy { $0.foregroundColor == nil })
        #expect(plainText(grey) == "detail")

        let nested = SplitwiseNotificationContent.attributedString(from: ##"<small><font color="#767676">note</font></small>"##)
        #expect(nested.runs.allSatisfy { $0.foregroundColor == .secondary })
    }

    /// An unrecognized or malformed tag must never cost the reader the text
    /// inside it — this is untrusted remote content, and a dropped run would
    /// silently change what the entry says.
    @Test
    func keepsTextInsideUnknownAndMalformedTags() {
        #expect(plainText(SplitwiseNotificationContent.attributedString(from: "<em>a</em>b")) == "ab")
        #expect(plainText(SplitwiseNotificationContent.attributedString(from: "5 < 6 and 7 > 2")) == "5 < 6 and 7 > 2")
        #expect(plainText(SplitwiseNotificationContent.attributedString(from: "a</strong>b")) == "ab")
        #expect(plainText(SplitwiseNotificationContent.attributedString(from: "<strong>a")) == "a")
        #expect(plainText(SplitwiseNotificationContent.attributedString(from: "")) == "")
    }

    /// An unclosed `<tag` must not consume the rest of the string looking for
    /// a `>` — the text after it, and any real tags in it, still have to come
    /// through.
    @Test
    func stopsAnUnclosedTagAtTheNextBracket() {
        let parsed = SplitwiseNotificationContent.attributedString(from: "a <foo b <strong>c</strong>")
        #expect(plainText(parsed) == "a <foo b c")

        let boldRun = parsed.runs.first { $0.inlinePresentationIntent == .stronglyEmphasized }
        #expect(boldRun.map { String(parsed[$0.range].characters) } == "c")
    }
}

struct SplitwiseActivityItemTests {
    private func notification(id: Int, kind: SplitwiseNotificationKind, expenseId: Int?, ageInHours: Double) -> SplitwiseNotification {
        SplitwiseNotification(
            id: id,
            type: kind.rawValue,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000).addingTimeInterval(-ageInHours * 3600),
            content: "whatever",
            source: expenseId.map { SplitwiseNotification.Source(type: "Expense", id: $0) }
        )
    }

    @Test
    func offersRestoreForADeletedExpense() {
        let items = SplitwiseActivityItem.items(for: [
            notification(id: 1, kind: .expenseDeleted, expenseId: 77, ageInHours: 1),
        ])
        #expect(items.first?.restorableExpenseId == 77)
    }

    @Test
    func doesNotOfferRestoreForOtherEntryKinds() {
        let items = SplitwiseActivityItem.items(for: [
            notification(id: 1, kind: .expenseAdded, expenseId: 77, ageInHours: 1),
            notification(id: 2, kind: .commentAdded, expenseId: 77, ageInHours: 2),
            notification(id: 3, kind: .groupDeleted, expenseId: nil, ageInHours: 3),
        ])
        #expect(items.allSatisfy { $0.restorableExpenseId == nil })
    }

    /// A delete entry Splitwise didn't attach an expense to has nothing to
    /// call `undelete_expense` with.
    @Test
    func doesNotOfferRestoreWithoutAnExpenseSource() {
        let items = SplitwiseActivityItem.items(for: [
            notification(id: 1, kind: .expenseDeleted, expenseId: nil, ageInHours: 1),
        ])
        #expect(items.first?.restorableExpenseId == nil)
    }

    /// Splitwise leaves the "deleted" entry in the feed after a restore and
    /// adds a separate "undeleted" one, so the older delete must stop offering
    /// an action that would now be a no-op.
    @Test
    func withdrawsRestoreOnceALaterUndeleteExists() {
        let items = SplitwiseActivityItem.items(for: [
            notification(id: 2, kind: .expenseUndeleted, expenseId: 77, ageInHours: 1),
            notification(id: 1, kind: .expenseDeleted, expenseId: 77, ageInHours: 2),
        ])
        #expect(items.first { $0.id == 1 }?.restorableExpenseId == nil)
    }

    @Test
    func keepsRestoreForARedeleteAfterARestore() {
        let items = SplitwiseActivityItem.items(for: [
            notification(id: 3, kind: .expenseDeleted, expenseId: 77, ageInHours: 1),
            notification(id: 2, kind: .expenseUndeleted, expenseId: 77, ageInHours: 2),
            notification(id: 1, kind: .expenseDeleted, expenseId: 77, ageInHours: 3),
        ])
        #expect(items.first { $0.id == 3 }?.restorableExpenseId == 77)
        #expect(items.first { $0.id == 1 }?.restorableExpenseId == nil)
    }

    /// An undelete of a *different* expense must not suppress this one's
    /// restore.
    @Test
    func scopesUndeleteToItsOwnExpense() {
        let items = SplitwiseActivityItem.items(for: [
            notification(id: 2, kind: .expenseUndeleted, expenseId: 99, ageInHours: 1),
            notification(id: 1, kind: .expenseDeleted, expenseId: 77, ageInHours: 2),
        ])
        #expect(items.first { $0.id == 1 }?.restorableExpenseId == 77)
    }

    /// The `type` list is documented as incomplete, so a value Relay doesn't
    /// know still has to decode and show — just with the generic icon.
    @Test
    func showsUnknownTypesWithFallbackIcon() throws {
        let json = """
        { "notifications": [ { "id": 5, "type": 99, "created_at": "2026-07-25T10:00:00Z", "content": "new thing" } ] }
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(SplitwiseNotificationsResponse.self, from: Data(json.utf8))
        let items = SplitwiseActivityItem.items(for: decoded.notifications)

        #expect(items.count == 1)
        #expect(items.first?.systemImage == Const.Symbol.activity)
        #expect(items.first?.restorableExpenseId == nil)
        #expect(String(try #require(items.first).content.characters) == "new thing")
    }
}
