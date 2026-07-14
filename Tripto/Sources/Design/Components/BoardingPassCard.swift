import Foundation
import SwiftUI

/// Compact boarding-pass rendering of a flight (docs/UX_REDESIGN_ROADMAP.md
/// Phase 1; design/ux-redesign-2026-07/tripto-redesign.html, "Itinerary ·
/// Trip detail" note 7). Shared by the itinerary timeline
/// (`TimelineCardRow`, flights only) and — Phase 3 — the add-flight form's
/// live preview, so it is deliberately input-driven with no `ItineraryItem`
/// coupling: `BoardingPassContent` (`TimelineModels.swift`) adapts an item
/// into `Model`.
///
/// Anatomy: a carrier eyebrow (airline + flight number), large Fraunces
/// airport codes each with a local time + GMT offset beneath, a computed
/// duration centered on a dashed route line, and a perforated-edge footer
/// carrying the landing note when present. No booking codes here —
/// `BookingDetailView` owns those.
struct BoardingPassCard: View {
    struct Endpoint: Equatable {
        let code: String
        /// Accessibility-only (never shown on the compact face, matching
        /// the mockup) — the a11y sentence prefers a real place name over
        /// spelling out a 3-letter code.
        let name: String?
        let date: Date
        let timeZone: TimeZone
    }

    struct Model: Equatable {
        let carrierLine: String
        let origin: Endpoint
        let destination: Endpoint
        /// `TZShiftChip.landingText(for:)`'s own wording, unmodified — `nil`
        /// when the flight lands in the same zone it departed from.
        let footerText: String?
    }

    let model: Model
    /// D4 ("now" presence) parity: `CategoryIconTile`/`RailNode`'s dimmed
    /// pattern, applied here to the pass's own accent surfaces (shadow, the
    /// leg/footer glyph, the "+Nd" badge) — never to the time/code text
    /// itself, which AA requires stays untouched.
    var isPast: Bool = false
    /// See `TimelineCardRow.typeSize`'s doc comment — threaded through so a
    /// live Dynamic Type change is never missed by an ancestor's
    /// `.equatable()` short-circuit, and so the route restacks to a
    /// vertical layout at accessibility sizes.
    var typeSize: DynamicTypeSize = .large

    @ScaledMetric(relativeTo: .body) private var routeIconSize: CGFloat = 13
    @ScaledMetric(relativeTo: .body) private var footerIconSize: CGFloat = 12

    private var isAXSize: Bool { typeSize.isAccessibilitySize }

    /// The pass's one accent color for decorative glyphs/badges — `amberInk`
    /// at rest (the codebase's existing AA-safe amber-as-ink convention),
    /// desaturating to `slate` when past (D4).
    private var accentInk: Color { isPast ? Palette.slate : Palette.amberInk }

    private var dayBadgeText: String? {
        BoardingPassMath.dayBadgeText(
            departure: model.origin.date, departureTz: model.origin.timeZone,
            arrival: model.destination.date, arrivalTz: model.destination.timeZone
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Spacing.md) {
                eyebrow
                routeBody
            }
            .padding(Spacing.md)
            footerView
        }
        .background(Palette.elevated, in: RoundedRectangle(cornerRadius: Radii.card, style: .continuous))
        // D4: shadow removed rather than faded, same de-elevation
        // `TimelineCardRow.card` already applies to every other category.
        .shadow(color: Palette.shadow.opacity(isPast ? 0 : 0.08), radius: 6, y: 3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityParts(for: model).joined(separator: ", "))
    }

    private var eyebrow: some View {
        Text(model.carrierLine.uppercased())
            .font(Typo.body(10, weight: .bold))
            .tracking(0.8)
            .foregroundStyle(Palette.slate)
            .lineLimit(isAXSize ? 2 : 1)
    }

    /// Findings F1/finding 1 precedent (`TimelineCardRow`/`BookingDetailView
    /// .flightHeader`): "give up on side-by-side, go vertical" once
    /// accessibility Dynamic Type sizes kick in — two fixed endpoint blocks
    /// either side of a fixed-width route line have nowhere to reflow.
    @ViewBuilder
    private var routeBody: some View {
        if isAXSize {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                endpointBlock(model.origin, isDestination: false, alignment: .leading)
                durationBlock
                endpointBlock(model.destination, isDestination: true, alignment: .leading)
            }
        } else {
            HStack(alignment: .top, spacing: Spacing.sm) {
                endpointBlock(model.origin, isDestination: false, alignment: .leading)
                Spacer(minLength: Spacing.xs)
                durationBlock
                Spacer(minLength: Spacing.xs)
                endpointBlock(model.destination, isDestination: true, alignment: .trailing)
            }
        }
    }

    private func endpointBlock(_ endpoint: Endpoint, isDestination: Bool, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 3) {
            Text(endpoint.code)
                .font(Typo.display(26).monospacedDigit())
                .foregroundStyle(isPast ? Palette.slate : Palette.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            HStack(spacing: 4) {
                Text(ItineraryTimeZone.timeString(endpoint.date, in: endpoint.timeZone))
                    .font(Typo.body(15, weight: .bold).monospacedDigit())
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                // Phase 3 (docs/UX_REDESIGN_ROADMAP.md): "+1d badge anchored
                // to the arrival time when it crosses midnight" — the same
                // pure `BoardingPassMath.dayBadgeText` backs both.
                if isDestination, let dayBadgeText {
                    Text(dayBadgeText)
                        .font(Typo.body(9.5, weight: .heavy))
                        .foregroundStyle(accentInk)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(isPast ? Palette.mist : Palette.amberSoft, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }
            // "each with its local time + GMT offset label beneath" — a
            // universally-readable numeric offset, deliberately not
            // `ItineraryTimeZone.zoneLabel`'s abbreviation (a boarding pass
            // reads to any traveler, not just one who already knows what
            // "ICT" means).
            Text(BoardingPassMath.gmtOffsetLabel(for: endpoint.timeZone, at: endpoint.date).uppercased())
                .font(Typo.body(9.5, weight: .bold))
                .tracking(0.4)
                .foregroundStyle(Palette.slate)
                .lineLimit(isAXSize ? 2 : 1)
                .minimumScaleFactor(isAXSize ? 0.85 : 1)
        }
        .frame(maxWidth: isAXSize ? .infinity : nil, alignment: alignment == .leading ? .leading : .trailing)
    }

    /// The dashed "leg" between the two airport codes, with the computed
    /// duration centered beneath it — decorative connector, spoken instead
    /// as part of the pass's own combined `accessibilityLabel`.
    private var durationBlock: some View {
        VStack(spacing: 4) {
            ZStack {
                dashedRule
                Image(systemName: "airplane")
                    .font(.system(size: routeIconSize))
                    .foregroundStyle(accentInk)
                    .rotationEffect(.degrees(90))
                    .padding(.horizontal, 3)
                    .background(Palette.elevated)
            }
            Text(BoardingPassMath.durationText(from: model.origin.date, to: model.destination.date))
                .font(Typo.body(10.5, weight: .bold).monospacedDigit())
                .foregroundStyle(Palette.slate)
                .lineLimit(1)
                .fixedSize()
        }
        .frame(width: isAXSize ? nil : 64)
        .accessibilityHidden(true)
    }

    /// Perforated-edge footer (BookingDetailView.stubContent's own notch
    /// recipe: two circles cut from the surrounding screen color, straddling
    /// a dashed top border) — only rendered when the flight actually has a
    /// landing note to show.
    @ViewBuilder
    private var footerView: some View {
        if let footerText = model.footerText {
            HStack(alignment: .top, spacing: Spacing.xs) {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: footerIconSize, weight: .semibold))
                    .foregroundStyle(accentInk)
                    .accessibilityHidden(true)
                Text(footerText)
                    .font(Typo.body(11.5, weight: .semibold))
                    .foregroundStyle(Palette.slate)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, Spacing.md)
            .padding(.top, Spacing.md)
            .padding(.bottom, Spacing.sm + 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) { dashedRule }
            .overlay(alignment: .top) {
                HStack {
                    Circle().fill(Palette.paper).frame(width: 16, height: 16).offset(y: -8)
                    Spacer()
                    Circle().fill(Palette.paper).frame(width: 16, height: 16).offset(y: -8)
                }
            }
        }
    }

    /// Shared dashed-rule shape — same `Rectangle.fill(mist).frame(height:
    /// 1).overlay(dash-stroked Rectangle)` recipe as `BookingDetailView
    /// .dashedRule`, sized by whatever container it's placed in (the leg's
    /// fixed width, or the footer's full width via `.overlay`).
    private var dashedRule: some View {
        Rectangle()
            .fill(Palette.mist)
            .frame(height: 1)
            .overlay {
                Rectangle()
                    .stroke(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(Palette.mist)
            }
    }

    /// One coherent VoiceOver sentence's parts (docs/UX_REDESIGN_ROADMAP.md
    /// Phase 1: "departure, arrival, duration, landing note") — this view's
    /// own `.accessibilityLabel` joins them directly; a timeline row
    /// (`TimelineCardRow.a11yLabel`) folds them into its single combined
    /// label instead of exposing a second element, since its own outer
    /// `.accessibilityElement(children: .ignore)` already collapses the
    /// whole row to one VoiceOver stop.
    static func accessibilityParts(for model: Model) -> [String] {
        var parts = [model.carrierLine]
        parts.append("departs \(endpointSentence(model.origin))")
        let offset = BoardingPassMath.dayOffset(
            departure: model.origin.date, departureTz: model.origin.timeZone,
            arrival: model.destination.date, arrivalTz: model.destination.timeZone
        )
        let dayNote: String
        if offset > 0 {
            dayNote = ", \(offset) day\(offset == 1 ? "" : "s") later"
        } else if offset < 0 {
            dayNote = ", \(abs(offset)) day\(abs(offset) == 1 ? "" : "s") earlier"
        } else {
            dayNote = ""
        }
        parts.append("arrives \(endpointSentence(model.destination))\(dayNote)")
        parts.append("duration \(BoardingPassMath.spokenDuration(from: model.origin.date, to: model.destination.date))")
        if let footerText = model.footerText { parts.append(footerText) }
        return parts
    }

    private static func endpointSentence(_ endpoint: Endpoint) -> String {
        let place = endpoint.name ?? endpoint.code
        let time = ItineraryTimeZone.timeString(endpoint.date, in: endpoint.timeZone)
        let zone = BoardingPassMath.gmtOffsetLabel(for: endpoint.timeZone, at: endpoint.date)
        return "\(place) \(time) \(zone)"
    }
}

/// Pure math behind the pass — deterministic `(Date, TimeZone) -> X`
/// transforms with no `Calendar.current`/`TimeZone.current` baked in, same
/// discipline as `ItineraryTimeZone`/`PassEffects`. Kept alongside the view
/// it exclusively backs rather than in `Models/`, since it's boarding-pass
/// presentation math (a GMT-offset label, a duration string), not itinerary
/// domain logic.
enum BoardingPassMath {
    static func durationComponents(from departure: Date, to arrival: Date) -> (hours: Int, minutes: Int) {
        let totalMinutes = max(0, Int((arrival.timeIntervalSince(departure) / 60).rounded()))
        return (totalMinutes / 60, totalMinutes % 60)
    }

    /// "2h 40m" / "3h" / "45m" — the pass's compact duration label.
    static func durationText(from departure: Date, to arrival: Date) -> String {
        let (hours, minutes) = durationComponents(from: departure, to: arrival)
        switch (hours, minutes) {
        case (0, _): return "\(minutes)m"
        case (_, 0): return "\(hours)h"
        default: return "\(hours)h \(minutes)m"
        }
    }

    /// "2 hours 40 minutes" — the same duration, spoken for VoiceOver.
    static func spokenDuration(from departure: Date, to arrival: Date) -> String {
        let (hours, minutes) = durationComponents(from: departure, to: arrival)
        var parts: [String] = []
        if hours > 0 { parts.append("\(hours) hour\(hours == 1 ? "" : "s")") }
        if minutes > 0 || hours == 0 { parts.append("\(minutes) minute\(minutes == 1 ? "" : "s")") }
        return parts.joined(separator: " ")
    }

    /// Whole-calendar-day offset between the arrival's local day (in
    /// `arrivalTz`) and the departure's local day (in `departureTz`) —
    /// positive when arrival reads as a later date (the common eastbound
    /// "+1d" case), negative when earlier (a westbound date-line crossing).
    static func dayOffset(departure: Date, departureTz: TimeZone, arrival: Date, arrivalTz: TimeZone) -> Int {
        let depDay = ItineraryTimeZone.localDay(of: departure, in: departureTz)
        let arrDay = ItineraryTimeZone.localDay(of: arrival, in: arrivalTz)
        return ItineraryDayBucketing.dayCount(from: depDay, to: arrDay, calendar: Calendar(identifier: .gregorian))
    }

    /// "+1d" next to the arrival time when it lands on a later local day
    /// than departure; "\u{2212}1d" for the rarer westbound case. `nil` when
    /// arrival is the same local day — no badge.
    static func dayBadgeText(departure: Date, departureTz: TimeZone, arrival: Date, arrivalTz: TimeZone) -> String? {
        let offset = dayOffset(departure: departure, departureTz: departureTz, arrival: arrival, arrivalTz: arrivalTz)
        guard offset != 0 else { return nil }
        return offset > 0 ? "+\(offset)d" : "\u{2212}\(abs(offset))d"
    }

    /// "GMT+8" / "GMT-5" / "GMT+5:30" — deliberately not
    /// `ItineraryTimeZone.zoneLabel`'s abbreviation; see `endpointBlock`'s
    /// doc comment for why the pass wants the numeric offset instead.
    static func gmtOffsetLabel(for tz: TimeZone, at date: Date) -> String {
        let totalSeconds = tz.secondsFromGMT(for: date)
        guard totalSeconds != 0 else { return "GMT" }
        let sign = totalSeconds < 0 ? "-" : "+"
        let absMinutes = abs(totalSeconds) / 60
        let hours = absMinutes / 60
        let minutes = absMinutes % 60
        return minutes == 0 ? "GMT\(sign)\(hours)" : "GMT\(sign)\(hours):\(String(format: "%02d", minutes))"
    }
}
