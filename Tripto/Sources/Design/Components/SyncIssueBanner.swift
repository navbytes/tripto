import SwiftUI

/// Non-blocking "some changes couldn't be saved" banner (FIX #1: previously
/// `SyncStore.markPermanentFailure` recorded a `SyncIssue` row that nothing
/// ever surfaced — the optimistic edit stayed on screen with no signal the
/// server never got it). Shown whenever `SyncStatus.syncIssues` is
/// non-empty — mirrors `SyncBanner`'s layout/placement, but in the rose
/// warning treatment (`PaletteExtras.swift`) rather than amber, since "we
/// gave up, you may need to act" is more urgent than "temporarily offline."
/// Tapping opens `SyncIssuesSheet`.
struct SyncIssueBanner: View {
    @Environment(SyncStatus.self) private var syncStatus
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPresentingDetails = false

    var body: some View {
        Button {
            isPresentingDetails = true
        } label: {
            HStack(spacing: Spacing.sm) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text(SyncIssuePresentation.bannerText(count: syncStatus.syncIssues.count))
                    .font(Typo.body(Typo.Size.caption, weight: .semibold))
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .opacity(0.7)
            }
            .foregroundStyle(Palette.rose)
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.sm)
            .background(Palette.roseSoft)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(SyncIssuePresentation.bannerText(count: syncStatus.syncIssues.count))
        .accessibilityHint("Opens details, with options to retry or dismiss")
        .accessibilityAddTraits(.isButton)
        .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: syncStatus.syncIssues.count)
        .sheet(isPresented: $isPresentingDetails) {
            SyncIssuesSheet()
        }
    }
}

/// Sheet listing every outstanding `SyncIssue` (opened by tapping
/// `SyncIssueBanner`): what couldn't be saved, why, how long ago, and
/// per-issue "Try again" (retriable issues only) / "Dismiss", plus a
/// toolbar "Dismiss all." Reads `syncEngine`/`syncStatus` straight from the
/// environment the same way every other sheet in this app does (e.g.
/// `AddItemSheet`), rather than being handed them as init params.
struct SyncIssuesSheet: View {
    @Environment(\.syncEngine) private var syncEngine
    @Environment(SyncStatus.self) private var syncStatus
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if syncStatus.syncIssues.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(syncStatus.syncIssues) { issue in
                            issueRow(issue)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .background(Palette.paper)
            .navigationTitle("Couldn\u{2019}t save")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
                if !syncStatus.syncIssues.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Dismiss all", role: .destructive) {
                            Task { await syncEngine?.dismissAllIssues() }
                        }
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: Spacing.sm) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 32))
                .foregroundStyle(Palette.slate)
            Text("Nothing outstanding")
                .font(Typo.body(weight: .semibold))
                .foregroundStyle(Palette.slate)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func issueRow(_ issue: SyncIssueSnapshot) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            HStack {
                Text(SyncIssuePresentation.title(forTable: SyncTable(rawValue: issue.tableRaw)).capitalized)
                    .font(Typo.body(weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Spacer()
                Text(issue.at, style: .relative)
                    .helperTextStyle()
            }
            Text(SyncIssuePresentation.message(retriable: issue.retriable))
                .font(Typo.body(Typo.Size.caption))
                .foregroundStyle(Palette.slate)
            HStack(spacing: Spacing.lg) {
                if issue.retriable {
                    Button("Try again") {
                        Task {
                            await syncEngine?.retryIssue(id: issue.id, rowId: issue.rowId, tableRaw: issue.tableRaw)
                        }
                    }
                    .foregroundStyle(Palette.amber)
                }
                Button("Dismiss") {
                    Task { await syncEngine?.dismissIssue(id: issue.id) }
                }
                .foregroundStyle(Palette.slate)
            }
            .font(Typo.body(Typo.Size.caption, weight: .semibold))
            .buttonStyle(.borderless)
            .padding(.top, Spacing.xxs)
        }
        .padding(.vertical, Spacing.xs)
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    let status = SyncStatus()
    status.setIssues([
        SyncIssueSnapshot(
            id: UUID(), rowId: UUID(), tableRaw: "itinerary_items",
            message: "gave up after 8 attempts: timed out", at: .now.addingTimeInterval(-120), retriable: true
        ),
        SyncIssueSnapshot(
            id: UUID(), rowId: UUID(), tableRaw: "trips",
            message: "new row violates row-level security policy (code 42501)", at: .now.addingTimeInterval(-3600),
            retriable: false
        ),
    ])
    return VStack {
        SyncIssueBanner()
        Spacer()
    }
    .padding(.top, Spacing.xl)
    .background(Palette.paper)
    .environment(status)
}
