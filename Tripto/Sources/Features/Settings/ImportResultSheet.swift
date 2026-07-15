import SwiftUI

/// P6.1 (docs/UX_REDESIGN_ROADMAP.md Phase 6): the branded archive-import
/// result — replaces `SettingsView`'s old plain "Import complete" alert +
/// `ArchiveImportReportSheet` pair (both driven off the same
/// `archiveImportReport != nil` state) with ONE sheet that always shows,
/// scaling from a full skip breakdown down to a one-line success without a
/// separate "is this worth a whole sheet" branch. Reuses
/// `TripArchiveImportReport` (`Support/TripArchive.swift`) — additively
/// extended with `TripArchiveTripSkip.existingLocalTripId` for the "Open
/// trip" recourse below, nothing else changed.
struct ImportResultSheet: View {
    let report: TripArchiveImportReport
    /// Opens the already-imported local trip an `.alreadyImported` skip
    /// points at (`SettingsView` wires this to `AppRouter.openTrip(id:)` —
    /// the same app-wide "go to this trip from wherever you are" mechanism
    /// widget/Spotlight/Siri taps already use, not a bespoke nav path).
    let onOpenTrip: (UUID) -> Void
    /// The primary action. Unlike the top-right "Done" (this sheet's own
    /// `\.dismiss`, which just closes the sheet and stays on Settings),
    /// this ALSO pops `SettingsView` back to Home — `SettingsView` supplies
    /// its own `dismiss()` for this closure, since a child sheet can't reach
    /// a different screen's dismiss action directly.
    let onSeeTrips: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Same `AnyLayout` swap `TripCard.topLayout`/`FirstUpStrip.layout`
    /// already use — three tiles have no room to sit side by side at
    /// accessibility Dynamic Type sizes.
    private var statTileLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.md))
            : AnyLayout(HStackLayout(alignment: .top, spacing: Spacing.xl))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.xl) {
                    header
                    statTiles
                    if !report.tripSkips.isEmpty || !report.itemSkips.isEmpty {
                        skippedSection
                    }
                    if report.zoneAssumedCount > 0 {
                        noteCard(zoneAssumedText)
                    }
                    if report.droppedNotesCount > 0 {
                        noteCard(droppedNotesText)
                    }
                }
                .padding(Spacing.xl)
                // Room for the pinned primary button below.
                .padding(.bottom, Spacing.xxl)
            }
            .background(Palette.paper)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                primaryButton
                    .padding(.horizontal, Spacing.xl)
                    .padding(.top, Spacing.sm)
                    .padding(.bottom, Spacing.sm)
                    .background(.ultraThinMaterial)
            }
        }
        // UX#7's own precedent (the sheet this replaces): its own content is
        // the only signal a VoiceOver user gets that the import finished —
        // announce the headline counts the moment it presents.
        .onAppear {
            AccessibilityNotification.Announcement(summaryAnnouncement).post()
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            ZStack {
                Circle().fill(Palette.amber).frame(width: 40, height: 40)
                Image(systemName: "checkmark")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Palette.onAmber)
            }
            .accessibilityHidden(true)
            Text("Import complete")
                .font(Typo.display(Typo.Size.display))
                .foregroundStyle(Palette.ink)
            Text(Self.subtitleText(tripsImported: report.tripsImported))
                .font(Typo.body())
                .foregroundStyle(Palette.slate)
        }
    }

    /// Pure/testable: `1 trip` reads differently from `20 trips`, and an
    /// all-skipped import (rare — every trip in the archive was itself
    /// already imported/cancelled/dateless) still needs an honest, non-
    /// negative line rather than "your 0 trips are ready."
    static func subtitleText(tripsImported: Int) -> String {
        switch tripsImported {
        case 0: return "Nothing new to add this time \u{2014} see what was skipped below."
        case 1: return "Your trip is ready to explore."
        default: return "Your trips are ready to explore."
        }
    }

    // MARK: - Stat tiles

    /// TRIPS / ITEMS always render (even at zero — an honest count, not a
    /// hidden one); TRAVELLERS omits itself when the import created none,
    /// rather than showing a bare "0 Travellers" tile.
    private var statTiles: some View {
        statTileLayout {
            statTile(value: report.tripsImported, label: report.tripsImported == 1 ? "Trip" : "Trips")
            statTile(value: report.itemsImported, label: report.itemsImported == 1 ? "Item" : "Items")
            if report.profilesImported > 0 {
                statTile(value: report.profilesImported, label: report.profilesImported == 1 ? "Traveller" : "Travellers")
            }
        }
    }

    private func statTile(value: Int, label: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text("\(value)")
                .font(Typo.display(28))
                .monospacedDigit()
                .foregroundStyle(Palette.ink)
            Text(label)
                .font(Typo.body(10.5, weight: .bold))
                .tracking(0.8)
                .textCase(.uppercase)
                .foregroundStyle(Palette.slate)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // VoiceOver: "20 trips", not "20" then a separate "Trips" stop.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(value) \(label.lowercased())")
    }

    // MARK: - Skipped rows

    /// Amber-wash card, ink-filled compact button — the exact recipe
    /// `ItineraryTabView.conflictBanner`/`StayConflicts`' "Review stays"
    /// already established for "heads up, here's a recourse" (P2.1), reused
    /// rather than re-derived: `Palette.ink` on `Palette.amberSoft` measures
    /// ~14.4:1 light / ~10.9:1 dark (independently recomputed against
    /// `Tokens.swift`'s hex values — matches `SettingsView
    /// .conversionPromptFeatureCard`'s own doc-commented figures for this
    /// same pairing); `Palette.paper` on `Palette.ink` (the "Open trip"
    /// button) measures ~16.2:1 light / ~16.1:1 dark.
    private var skippedSection: some View {
        let totalSkips = report.tripSkips.count + report.itemSkips.count
        return VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Skipped \u{00B7} \(totalSkips)")
                .font(Typo.body(10.5, weight: .bold))
                .tracking(0.8)
                .textCase(.uppercase)
                .foregroundStyle(Palette.slate)

            VStack(spacing: 0) {
                ForEach(Array(report.tripSkips.enumerated()), id: \.offset) { index, skip in
                    skipRow(
                        title: skip.title.isEmpty ? "Untitled trip" : skip.title,
                        reasonText: Self.sentenceCased(skip.reason.reportText),
                        recourse: recourse(for: skip)
                    )
                    if index < report.tripSkips.count - 1 || !report.itemSkips.isEmpty {
                        Rectangle().fill(Palette.mist).frame(height: 1)
                    }
                }
                ForEach(Array(report.itemSkips.enumerated()), id: \.offset) { index, skip in
                    skipRow(
                        title: skip.itemLabel,
                        reasonText: "\(Self.sentenceCased(skip.reason.reportText)) \u{2014} "
                            + (skip.tripTitle.isEmpty ? "Untitled trip" : skip.tripTitle),
                        recourse: nil
                    )
                    if index < report.itemSkips.count - 1 {
                        Rectangle().fill(Palette.mist).frame(height: 1)
                    }
                }
            }
            .padding(Spacing.md)
            .background(Palette.elevated, in: RoundedRectangle(cornerRadius: Radii.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Radii.card, style: .continuous)
                    .stroke(Palette.mist, lineWidth: 1)
            }
        }
    }

    private enum SkipRecourse {
        case openTrip(UUID)
    }

    /// Only `.alreadyImported` (with a resolved local trip) has a real
    /// app-side recourse today. `.cancelled`/`.noStartDate`/`.noStartTime`
    /// are explicitly fenced (docs/BACKLOG.md F1/F2 — the schema has
    /// nowhere to import a cancelled status or an undated trip INTO), and
    /// `.missingId`/`.missingTitle`/`.unknownCategory`/`.unreadable` are
    /// untrusted-input gaps nothing client-side can fill in. Every one of
    /// those still gets its own plain-language reason line (`skipRow`
    /// always renders `reasonText`) — just no button.
    private func recourse(for skip: TripArchiveTripSkip) -> SkipRecourse? {
        guard skip.reason == .alreadyImported, let id = skip.existingLocalTripId else { return nil }
        return .openTrip(id)
    }

    private func skipRow(title: String, reasonText: String, recourse: SkipRecourse?) -> some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(title).font(Typo.body(weight: .semibold)).foregroundStyle(Palette.ink)
                Text(reasonText).font(Typo.body(Typo.Size.caption)).foregroundStyle(Palette.slate)
            }
            // One VoiceOver stop for the label pair (UX#7's own precedent);
            // the recourse button (when present) stays its own, separately
            // reachable control, not folded into this same element.
            .accessibilityElement(children: .combine)
            Spacer(minLength: Spacing.sm)
            if case .openTrip(let id) = recourse {
                Button("Open trip") {
                    dismiss()
                    onOpenTrip(id)
                }
                .font(Typo.body(Typo.Size.caption, weight: .bold))
                .foregroundStyle(Palette.paper)
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.xs)
                .background(Palette.ink, in: Capsule())
                .frame(minHeight: 44)
                .contentShape(Capsule())
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, Spacing.sm)
    }

    private func noteCard(_ text: String) -> some View {
        Text(text)
            .font(Typo.body(Typo.Size.caption))
            .foregroundStyle(Palette.ink)
            .padding(Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.amberSoft, in: RoundedRectangle(cornerRadius: Radii.card, style: .continuous))
    }

    private var zoneAssumedText: String {
        let word = report.zoneAssumedCount == 1 ? "item" : "items"
        return "\(report.zoneAssumedCount) \(word) assumed your device time zone \u{2014} check times."
    }

    private var droppedNotesText: String {
        let word = report.droppedNotesCount == 1 ? "trip\u{2019}s notes weren\u{2019}t" : "trips\u{2019} notes weren\u{2019}t"
        return "\(report.droppedNotesCount) \(word) imported \u{2014} Tripto doesn\u{2019}t store trip-level notes yet."
    }

    /// BUILD_PLAN §6.2 sentence case — `reportText` values are already
    /// lowercase; only the first letter needs raising (`.capitalized`
    /// title-cases every word, e.g. "Missing Id").
    static func sentenceCased(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }

    // MARK: - Primary action

    private var primaryButton: some View {
        Button {
            onSeeTrips()
        } label: {
            Text(Self.primaryActionText(tripsImported: report.tripsImported))
                .font(Typo.body(weight: .semibold))
                .foregroundStyle(Palette.onAmber)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Spacing.md)
                .frame(minHeight: 44)
                .background(Palette.amber, in: Capsule())
        }
    }

    /// Pure/testable: the mockup's literal "See your 20 trips" degrades to
    /// a plain "Done" when there's nothing to go see (every trip in this
    /// import was skipped) — "See your 0 trips" would read as broken, not helpful.
    static func primaryActionText(tripsImported: Int) -> String {
        guard tripsImported > 0 else { return "Done" }
        return "See your \(tripsImported) \(tripsImported == 1 ? "trip" : "trips")"
    }

    private var summaryAnnouncement: String {
        let tripWord = report.tripsImported == 1 ? "trip" : "trips"
        let itemWord = report.itemsImported == 1 ? "item" : "items"
        let skipCount = report.tripSkips.count + report.itemSkips.count
        let skipWord = skipCount == 1 ? "item" : "items"
        return "Import complete. \(report.tripsImported) \(tripWord), \(report.itemsImported) \(itemWord) imported. "
            + "\(skipCount) \(skipWord) skipped."
    }
}

#Preview("Small import — degrades without ceremony") {
    Color.clear.sheet(isPresented: .constant(true)) {
        ImportResultSheet(
            report: TripArchiveImportReport(tripsImported: 1, itemsImported: 4, profilesImported: 0),
            onOpenTrip: { _ in },
            onSeeTrips: {}
        )
    }
}

#Preview("Large import — stats + skips") {
    Color.clear.sheet(isPresented: .constant(true)) {
        ImportResultSheet(
            report: TripArchiveImportReport(
                tripsImported: 20, itemsImported: 67, profilesImported: 12,
                tripSkips: [
                    .init(tripId: "1", title: "Parents\u{2019} visit to Hong Kong", reason: .cancelled),
                    .init(tripId: "2", title: "Bangkok", reason: .alreadyImported, existingLocalTripId: UUID()),
                    .init(tripId: "3", title: "", reason: .noStartDate)
                ],
                itemSkips: [
                    .init(tripId: "1", tripTitle: "IndiGo booking", itemId: "i1", itemLabel: "Flight 6E204", reason: .noStartTime)
                ],
                zoneAssumedCount: 3,
                droppedNotesCount: 20
            ),
            onOpenTrip: { _ in },
            onSeeTrips: {}
        )
    }
}
