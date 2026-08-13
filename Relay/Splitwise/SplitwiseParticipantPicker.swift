//
//  SplitwiseParticipantPicker.swift
//  Relay
//
//  The "Split With" control for the draft/manual forms: type to filter, pick a
//  match from the keyboard bar to add it, and keep adding. Picking a group
//  fills the split with its membership and adds a Group row above; from there
//  the two are independent, so a member can be dropped from this one expense
//  while it still books under the group.
//
//  A `Menu` (what this replaced, and what the single-friend surfaces still use)
//  can't do that: it has no text entry, and it closes on every pick. The
//  matches ride in a keyboard toolbar rather than in rows of their own — the
//  same place the Payee field puts its suggestions — so the form's height
//  doesn't jump around while you type.
//

import SwiftUI

struct SplitwiseParticipantPickerRow: View {
    let isLoading: Bool
    let friends: [SplitwiseFriend]
    let groups: [SplitwiseGroup]
    @Binding var selection: SplitwiseSplitSelection
    @Binding var searchText: String
    /// Label for the empty state — "None", or "Default (…)" where an app-wide
    /// default Splitwise friend stands in.
    var emptyLabel: String = "None"
    var isIncomplete: Bool = false

    @FocusState private var isFocused: Bool

    var body: some View {
        Group {
            if selection.groupId != nil {
                groupRow
            }
            participantsRow
        }
    }

    /// Only there once a group is picked: it names the group the expense will
    /// be posted into, and is where it's swapped or dropped. Separate from the
    /// participants below because the two are independent — a member can leave
    /// this one expense without it leaving the group.
    private var groupRow: some View {
        DraftDetailRow(icon: "person.3.fill", title: "Group") {
            Menu {
                ForEach(groups.filter { !$0.memberList.isEmpty }, id: \.id) { group in
                    Button(group.name) { select(group) }
                }
                Divider()
                Button("Remove", role: .destructive) { withAnimation { selection.clearGroup() } }
            } label: {
                MenuPickerLabel {
                    Text(groups.first { $0.id == selection.groupId }?.name ?? String(localized: "Group"))
                }
            }
            .tint(Color.foregroundColor)
        }
        .cardRowBackground()
    }

    /// Who's picked sits on the row's own line, where every other field shows
    /// its value; the entry field goes underneath, so a long list of chips
    /// grows downward instead of squeezing what you're typing.
    private var participantsRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            DraftDetailRow(icon: Const.Symbol.friends, title: "Split With", isIncomplete: isIncomplete) {
                if isLoading, friends.isEmpty, groups.isEmpty {
                    ProgressView()
                } else if chips.isEmpty {
                    Text(emptyLabel)
                } else {
                    SplitwiseChipFlow(spacing: 6) {
                        ForEach(chips) { chip in
                            SplitwiseParticipantChip(title: chip.name) { remove(chip) }
                        }
                    }
                }
            }

            TextField("Add someone", text: $searchText)
                .submitLabel(.done)
                .autocorrectionDisabled()
                .keyboardType(.alphabet)
                .focused($isFocused)
                .onSubmit { addFirstMatch() }
                .toolbar {
                    ToolbarItemGroup(placement: .keyboard) {
                        if isFocused {
                            suggestionsBar
                        }
                    }
                }
                // Lines the field up under the row's label rather than its icon.
                .padding(.leading, 36)
        }
        .padding(.vertical, 3)
        .cardRowBackground()
        .contentShape(Rectangle())
        .onTapGesture { isFocused = true }
    }

    // MARK: - Suggestions

    /// Unlike the Payee field's fixed three slots, this scrolls: the whole
    /// friend list is a legitimate thing to browse when the field is empty.
    ///
    /// Plain text with dividers, no per-item background: the keyboard toolbar
    /// already draws its own capsule, and a capsule per name sat visibly inset
    /// inside it. The dividers carry the separation the backgrounds were doing.
    private var suggestionsBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 0) {
                ForEach(Array(matches.enumerated()), id: \.element.id) { index, match in
                    if index > 0 {
                        Divider().frame(height: 22)
                    }
                    Button {
                        add(match)
                    } label: {
                        VStack(spacing: 1) {
                            Text(match.name)
                                .lineLimit(1)
                            if let subtitle = match.subtitle {
                                Text(subtitle)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .padding(.horizontal, 14)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
        }
        .scrollIndicators(.hidden)
        // The toolbar gives its content no height of its own, and an
        // unconstrained ScrollView in it collapses to nothing.
        .frame(height: 36)
        .frame(maxWidth: .infinity)
        .foregroundStyle(Color.foregroundColor)
    }

    private struct Match: Identifiable, Equatable {
        enum Kind { case person, group }
        let id: Int
        let kind: Kind
        let name: String
        /// Only groups carry one, so a group can't be mistaken for a person.
        let subtitle: String?
    }

    /// The picked group's own members first (they're the ones a group expense
    /// is about, and dropping one has to be undoable even when they aren't a
    /// friend), then friends, then groups. Anyone already on the split drops
    /// out.
    private var matches: [Match] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        let currentUserId = SplitwiseCurrentUserStore.load()?.id

        let memberMatches = (selectedGroup?.others(excluding: currentUserId) ?? [])
            .filter { !selection.contains($0.id) }
            .filter { query.isEmpty || $0.fullName.localizedStandardContains(query) }
            .map { Match(id: $0.id, kind: .person, name: $0.shortName, subtitle: nil) }

        // Matched on the full name but shown as "Alex K.": a surname would cost
        // more of the bar than it's worth, and the initial is enough to tell
        // two Alexes apart.
        //
        // Anyone you're not settled up with comes first — they're who a new
        // expense is most likely for. Within each half the caller's order
        // stands, which is SplitwiseFriendUsageStore's most-recently-split-with
        // ordering.
        let memberIds = Set(memberMatches.map(\.id))
        let (outstanding, settled) = friends.partitionedByBalance
        let friendMatches = (outstanding + settled)
            .filter { !selection.contains($0.id) && !memberIds.contains($0.id) }
            .filter { query.isEmpty || $0.fullName.localizedStandardContains(query) }
            .map { Match(id: $0.id, kind: .person, name: $0.shortName, subtitle: nil) }

        // A group with nobody in it has no one to bill, and the picked group is
        // already shown in its own row, so neither is offered.
        let groupMatches = groups
            .filter { $0.id != selection.groupId && !$0.memberList.isEmpty }
            .filter { group in
                query.isEmpty
                    || group.name.localizedStandardContains(query)
                    || group.memberList.contains { $0.fullName.localizedStandardContains(query) }
            }
            .map {
                Match(
                    id: $0.id,
                    kind: .group,
                    name: $0.name,
                    subtitle: String(localized: "Group · \($0.memberList.count)")
                )
            }

        return memberMatches + friendMatches + groupMatches
    }

    private var selectedGroup: SplitwiseGroup? {
        selection.groupId.flatMap { id in groups.first { $0.id == id } }
    }

    private func add(_ match: Match) {
        switch match.kind {
        case .person:
            withAnimation { selection.add(match.id) }
        case .group:
            guard let group = groups.first(where: { $0.id == match.id }) else { return }
            select(group)
        }
        // Cleared rather than dismissed: the field keeps focus so the next
        // person can be typed straight away.
        searchText = ""
    }

    /// Picking a group puts its whole membership on the split, minus the
    /// signed-in user — they're the payer, not someone the payer owes.
    /// `withAnimation`, like every other mutation here: the Group row and the
    /// per-participant share rows are *List* rows, and List only animates an
    /// insertion when the change arrives in an animated transaction — an
    /// `.animation(value:)` on the list itself doesn't reach them.
    private func select(_ group: SplitwiseGroup) {
        withAnimation {
            selection.setGroup(group.id, memberIds: group.others(excluding: SplitwiseCurrentUserStore.load()?.id).map(\.id))
        }
    }

    /// Return adds the top match, but only as a shortcut for something typed:
    /// on an empty field the key is just "done with the keyboard", and adding
    /// whoever happened to sort first would be a surprise.
    private func addFirstMatch() {
        guard !searchText.trimmingCharacters(in: .whitespaces).isEmpty, let first = matches.first else { return }
        add(first)
    }

    // MARK: - Selection

    private struct Chip: Identifiable {
        let id: Int
        let name: String
    }

    /// Everyone on the split, named from the caches — the friend list first,
    /// then the groups' membership, since a group can contain someone who isn't
    /// a friend. Anyone who resolves to neither still gets a chip: dropping it
    /// would silently un-pick them.
    private var chips: [Chip] {
        selection.participantIds.map { id in
            let name = friends.first { $0.id == id }?.shortName
                ?? groups.lazy.flatMap(\.memberList).first { $0.id == id }?.shortName
                ?? String(localized: "Friend")
            return Chip(id: id, name: name)
        }
    }

    private func remove(_ chip: Chip) {
        withAnimation { selection.remove(chip.id) }
    }
}

/// One picked participant, with its remove button.
private struct SplitwiseParticipantChip: View {
    let title: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
                .lineLimit(1)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Remove \(title)"))
        }
        .font(.subheadline)
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        .background(Color.secondary.opacity(0.15), in: Capsule())
    }
}

/// Wraps chips onto as many lines as they need — `HStack` would push them off
/// the row's trailing edge instead once a few are picked.
private struct SplitwiseChipFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = layoutRows(subviews: subviews, maxWidth: maxWidth)
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: min(width, maxWidth), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in layoutRows(subviews: subviews, maxWidth: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func layoutRows(subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > maxWidth, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
