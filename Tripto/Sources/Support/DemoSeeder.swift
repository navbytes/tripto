#if DEBUG
import CoreGraphics
import Foundation
import Nuke
import SwiftData
import UIKit

/// Home's DEBUG "Seed demo trip" action — a 14-day, ~40-item trip used for
/// perf and screenshot passes on the M2 timeline. Deliberately includes the
/// exact ACCEPTANCE.md "(a)" JFK→LIS flight (2026-05-14 08:20
/// `America/New_York` → 20:15 `Europe/Lisbon`) plus a Madrid side trip and
/// the return leg, so the seeded trip alone exercises multiple tz-crossing
/// pairs, a multi-night hotel stay, and a mix of items with/without
/// confirmation codes — everything the timeline needs to render.
///
/// Writes go through the exact same path every other mutation in the app
/// uses (SwiftData insert on the main context, then `SyncEngine.enqueue`
/// per row) so this also doubles as a real end-to-end sync exercise, not
/// just local fixture data.
enum DemoSeeder {
    /// Returns the new trip's id (so callers — the DEBUG menu's toast-free
    /// button, and the verification drill's launch-argument autopilot below
    /// this file — can navigate straight to it) or `nil` if there's no
    /// signed-in user to attribute the trip to.
    @discardableResult
    @MainActor
    static func seed(modelContext: ModelContext, syncEngine: SyncEngine?, authManager: AuthManager) async -> UUID? {
        guard let userId = authManager.userId else { return nil }
        // P8a avatar-photos capture set: primes Nuke's in-memory image cache
        // BEFORE the idempotence guard below can early-return — that guard
        // (correctly) skips re-running every showcase further down on the
        // SECOND+ launch against an already-seeded store, but each launch is
        // its own fresh process with its own empty memory cache (Nuke's
        // on-disk `DataCache` writes are staged and flushed asynchronously —
        // confirmed via its own source — so a launch that both primes AND
        // screenshots in one process works by accident, while a later,
        // separate launch that only reads finds nothing there). Cheap and
        // idempotent to redo every launch (an in-memory dictionary write),
        // unlike the one-time row creation below.
        if ProcessInfo.processInfo.arguments.contains("-uitestSeedAvatarShowcase") {
            primeAvatarShowcaseImageCache(userId: userId)
        }
        // P8b photo-covers capture set: same "prime the memory cache on
        // EVERY launch, before the idempotence guard below" reasoning as the
        // avatar showcase above — own flag, additive. Routed through a tiny
        // wrapper (rather than an inline `if` here, like the avatar one
        // above) so `seed()`'s own cyclomatic complexity — already close to
        // this file's configured ceiling from five prior showcase-flag
        // checks — doesn't grow by another branch for a sixth.
        primeCoverShowcaseImageCacheIfFlagged()
        // Idempotence guard, checked against the STORE (not callers' @Query
        // state, which can be un-hydrated at launch — the W1-B evidence run
        // caught a double-seed race exactly that way: two "Lisbon" rows from
        // two launches). If the demo trip already exists, return its id so
        // autopilot navigation still works. DEBUG-only code; a real user trip
        // titled "Lisbon" being mistaken for the fixture is acceptable here.
        let demoTitle = "Lisbon"
        let existing = FetchDescriptor<Trip>(predicate: #Predicate { $0.title == demoTitle })
        if let hit = try? modelContext.fetch(existing).first {
            return hit.id
        }
        let now = Date()

        let nyTz = TimeZone(identifier: "America/New_York")!
        let lisbonTz = TimeZone(identifier: "Europe/Lisbon")!
        let madridTz = TimeZone(identifier: "Europe/Madrid")!

        var deviceCalendar = Calendar(identifier: .gregorian)
        deviceCalendar.timeZone = .current

        let tripStartDay = DayDate(year: 2026, month: 5, day: 14)
        let tripEndDay = DayDate(year: 2026, month: 5, day: 27) // 14 days inclusive

        let tripId = UUID()
        let trip = Trip(
            id: tripId, title: "Lisbon", destination: "Lisbon, Portugal", countryCode: "PT",
            startDate: tripStartDay.asDate(calendar: deviceCalendar),
            endDate: tripEndDay.asDate(calendar: deviceCalendar),
            coverGradient: "dusk", tripTypeRaw: TripType.family.rawValue, createdBy: userId,
            createdAt: now, updatedAt: now, updatedBy: nil
        )
        // A *local-only* provisional organizer membership for offline role-
        // gating, exactly like the real create path (TripFormView.save) — it's
        // inserted locally but never pushed; the server's trip-creation trigger
        // seats the real organizer trip_members row (and a linked trip_profiles
        // row) when the trip inserts, and the next pull reconciles this to it.
        // The organizer's profile is therefore NOT built here — it arrives from
        // the trigger with a stable server id, which is why demo assignments/
        // packing only ever reference the non-app profiles below.
        let member = TripMember(
            id: UUID(), tripId: tripId, userId: userId, roleRaw: TripRole.organizer.rawValue, createdAt: now
        )
        // UX P4 Share screenshot (docs/UX_REDESIGN_ROADMAP.md P4.1's inline
        // role-chip `Menu`): a second, local-only membership so that Menu
        // has a non-self row to render/demo against at all — until a real
        // companion actually joins, the trigger-created membership table
        // only ever has the signed-in organizer locally (see `member`'s own
        // doc comment), so there was nothing else to show the feature on.
        // Same "local-only, never enqueued" shape as `member`: this
        // `userId` isn't a real account, so pushing it would 23503 on
        // `trip_members`' FK to `profiles`. `createdAt` is `now` + 1s
        // (strictly after the organizer's) so `tripCreatorId`/`sortedMembers`
        // resolve unambiguously.
        let companionMember = TripMember(
            id: UUID(), tripId: tripId, userId: UUID(), roleRaw: TripRole.companion.rawValue,
            createdAt: now.addingTimeInterval(1)
        )
        // M4 family layer: two non-app profiles (BUILD_PLAN.md §3.3/§5.3) —
        // the kids/grandparents the "Just mine" filter and packing list are
        // built for, seeded the same way a real organizer would add them
        // via `ShareTripView`'s "Add someone without the app".
        // P7d award-audit: this used to seed "Meera (7)" — a bare, unlabeled
        // "(7)" (BUILD_PLAN's own illustrative age flavor for the kid-profile
        // example) that rendered raw wherever `displayName` shows
        // (PackingListView's reassign picker, ShareTripView's people list) —
        // indistinguishable from an item count or any other stray number.
        // `TripProfile` has no `age` field (BUILD_PLAN §3.3) and no real UI
        // surfaces one, so there was nothing to label; cut at the source
        // instead of patching every render call site.
        let meeraProfile = TripProfile(
            id: UUID(), tripId: tripId, displayName: "Meera", avatarColor: "plum",
            linkedUserId: nil, createdAt: now
        )
        let grandmaProfile = TripProfile(
            id: UUID(), tripId: tripId, displayName: "Grandma", avatarColor: "sky",
            linkedUserId: nil, createdAt: now
        )

        var items: [ItineraryItem] = []
        items.append(contentsOf: flights(tripId: tripId, userId: userId, now: now, nyTz: nyTz, lisbonTz: lisbonTz, madridTz: madridTz))
        items.append(contentsOf: hotels(tripId: tripId, userId: userId, now: now, lisbonTz: lisbonTz, madridTz: madridTz))
        items.append(contentsOf: fillerItems(
            tripId: tripId, tripStartDay: tripStartDay, userId: userId, now: now, lisbonTz: lisbonTz, madridTz: madridTz
        ))
        // A dedicated, unambiguous kid-tagged item (BUILD_PLAN.md §5.4) —
        // clearer for the verify-drill screenshot than reaching into the
        // sprawling filler pool by fragile index/title matching.
        let napItem = familyDemoItem(tripId: tripId, userId: userId, now: now, lisbonTz: lisbonTz)
        items.append(napItem)
        // Transport (the 5th category): a same-zone Lisbon rental car, so the
        // drill/screenshots exercise the teal car icon + its detail card.
        var lisbonCalendar = Calendar(identifier: .gregorian)
        lisbonCalendar.timeZone = lisbonTz
        let carPickup = lisbonCalendar.date(from: DateComponents(year: 2026, month: 5, day: 16, hour: 10, minute: 0)) ?? now
        let carDropoff = lisbonCalendar.date(from: DateComponents(year: 2026, month: 5, day: 16, hour: 18, minute: 30)) ?? now
        items.append(makeItem(
            tripId: tripId, category: .transport, title: "Rental car",
            startsAt: carPickup, endsAt: carDropoff, tz: lisbonTz.identifier,
            locationName: "Lisbon Airport", confirmation: "HZ-40192",
            details: ItemDetails(arrivalTz: lisbonTz.identifier, provider: "Hertz", dropoffLocation: "Lisbon Airport"),
            userId: userId, now: now
        ))
        // Tag two existing filler items in place — `details` is a computed
        // get/set property over the full `ItemDetails` struct
        // (`ItineraryItem+Details.swift`), so mutating just `.tags` here
        // preserves whatever address/ticketRef/etc. the filler loop already
        // set, exactly like a real edit through `AddItemSheet` would.
        let strollerItem = items.first { $0.title == "Oceanário de Lisboa" }
        strollerItem?.details.tags = [ItemTag.strollerOk.rawValue]
        let kidsMenuItem = items.first { $0.category == .food }
        kidsMenuItem?.details.tags = [ItemTag.kidsMenu.rawValue]

        // M4: item_assignees — "Just mine" needs at least one item per
        // profile so every chip has something to filter to.
        var assignees: [ItemAssignee] = [ItemAssignee(itemId: napItem.id, profileId: meeraProfile.id)]
        if let strollerItem {
            assignees.append(ItemAssignee(itemId: strollerItem.id, profileId: meeraProfile.id))
        }
        if let kidsMenuItem {
            assignees.append(ItemAssignee(itemId: kidsMenuItem.id, profileId: meeraProfile.id))
            assignees.append(ItemAssignee(itemId: kidsMenuItem.id, profileId: grandmaProfile.id))
        }
        if let outboundFlight = items.first(where: { $0.title == "TAP TP1234" }) {
            assignees.append(ItemAssignee(itemId: outboundFlight.id, profileId: grandmaProfile.id))
        }

        // M4: a dozen packing items across every group_key, some already
        // packed (for a meaningful progress bar) and some assigned. Assigned
        // only to the non-app profiles (Meera/Grandma) — the organizer's own
        // profile is trigger-created server-side (see the note above), so it
        // has no stable local id to reference until the first pull.
        let packing = packingItems(
            tripId: tripId, userId: userId, now: now, meeraId: meeraProfile.id, grandmaId: grandmaProfile.id
        )

        // -uitestSeedToday: shift the whole fixture forward by whole days so
        // the JFK→LIS flight lands on the sim's *today* — the now-line,
        // travel-day tear-off, and Live Activity are undemoable against the
        // fixed May dates otherwise. Flat 86400s multiples are exact here:
        // the fixture's zones (NY/Lisbon/Madrid) are all already on summer
        // time in May, so no DST boundary is crossed by the shift. The
        // hotel/stay detail strings inside `details` keep their May wording —
        // cosmetic only, acceptable for demo evidence. Default seeding (DEBUG
        // menu, existing drills) is unchanged.
        if ProcessInfo.processInfo.arguments.contains("-uitestSeedToday") {
            let fixtureStart = tripStartDay.asDate(calendar: deviceCalendar)
            let todayStart = deviceCalendar.startOfDay(for: now)
            let deltaDays = deviceCalendar.dateComponents([.day], from: fixtureStart, to: todayStart).day ?? 0
            let delta = TimeInterval(deltaDays) * 86_400
            trip.startDate = trip.startDate.addingTimeInterval(delta)
            trip.endDate = trip.endDate.addingTimeInterval(delta)
            for item in items {
                item.startsAt = item.startsAt.addingTimeInterval(delta)
                if let ends = item.endsAt { item.endsAt = ends.addingTimeInterval(delta) }
            }
        }

        modelContext.insert(trip)
        modelContext.insert(member) // local-only; never enqueued (see note above)
        modelContext.insert(companionMember) // local-only; never enqueued (see note above)
        modelContext.insert(meeraProfile)
        modelContext.insert(grandmaProfile)
        try? modelContext.save()

        guard let syncEngine else { return tripId }
        // Push the trip first so its trigger seats the organizer server-side
        // before the non-app profiles (whose INSERT RLS requires organizer),
        // then the flush below guarantees ordering. `member` is deliberately
        // NOT pushed — the trigger owns the real organizer row.
        await syncEngine.enqueueUpsert(table: .trips, rowId: trip.id, tripId: trip.id, payload: trip.toDTO())
        await syncEngine.enqueueUpsert(table: .tripProfiles, rowId: meeraProfile.id, tripId: tripId, payload: meeraProfile.toDTO())
        await syncEngine.enqueueUpsert(table: .tripProfiles, rowId: grandmaProfile.id, tripId: tripId, payload: grandmaProfile.toDTO())
        // `item_assignees`/`packing_items` below FK-reference both
        // `trip_profiles.id` and (for assignees) `itinerary_items.id` — an
        // explicit synchronous flush per phase, rather than trusting the
        // debounced queue's FIFO-by-`createdAt` ordering across a burst of
        // ~70 same-instant enqueues, so a same-batch sibling row is
        // guaranteed to exist server-side before anything references it.
        // DEBUG-only seeding; `flushPush()` is the same push the debounced
        // timer would eventually call, just awaited synchronously here.
        await syncEngine.flushPush()

        for item in items { modelContext.insert(item) }
        try? modelContext.save()
        for item in items {
            await syncEngine.enqueueUpsert(table: .itineraryItems, rowId: item.id, tripId: tripId, payload: item.toDTO())
        }
        await syncEngine.flushPush()

        for assignee in assignees { modelContext.insert(assignee) }
        for packingItem in packing { modelContext.insert(packingItem) }
        try? modelContext.save()
        for assignee in assignees {
            await syncEngine.enqueueUpsert(table: .itemAssignees, rowId: assignee.id, tripId: tripId, payload: assignee.toDTO())
        }
        for packingItem in packing {
            await syncEngine.enqueueUpsert(table: .packingItems, rowId: packingItem.id, tripId: tripId, payload: packingItem.toDTO())
        }
        await syncEngine.flushPush()

        // UX P5 verify wave (docs/UX_REDESIGN_ROADMAP.md Phase 5): "Lisbon"
        // alone can only ever occupy ONE HomeRegisterKind at a time, so
        // there was nothing to screenshot "the full register stack"
        // against — these four companion trips fill in the rest. See
        // `seedRegisterShowcaseTrips`'s own doc comment for which register
        // each one earns (and the one that can never coexist with `.now`).
        //
        // Opt-in via `-uitestSeedRegisterShowcase` (same "DemoSeeder reads
        // ProcessInfo directly" recipe as `-uitestSeedToday` above), NOT
        // unconditional: `HomeView.applyUITestAutopilotIfNeeded`'s
        // `-uitestOpenFirstTrip` targets `trips.first?.id` (`@Query(sort:
        // \Trip.startDate)`) on every launch OTHER than the very first
        // empty-store one — which, once the multi-year "been" trips below
        // exist, is an earlier startDate than Lisbon's, not Lisbon itself.
        // Every one of `TriptoUITests`' other cases relies on that hook
        // reliably reopening "Lisbon" specifically; gating this whole
        // showcase behind an explicit flag those tests never pass keeps
        // their fixture (and `trips.first`) exactly as before this file's
        // change. Confirmed live: unguarded, this flipped `-
        // uitestOpenFirstTrip` onto the showcase's own earliest-dated past
        // trip for every test after the first in a shared-store run.
        if ProcessInfo.processInfo.arguments.contains("-uitestSeedRegisterShowcase") {
            await seedRegisterShowcaseTrips(modelContext: modelContext, syncEngine: syncEngine, userId: userId, now: now)
        }
        // UX P6 trust suite (docs/UX_REDESIGN_ROADMAP.md Phase 6): own flag,
        // same "DemoSeeder reads ProcessInfo directly, additive" recipe as
        // `-uitestSeedRegisterShowcase` above — see `seedP6TrustShowcase`'s
        // own doc comment for what it adds and why it's gated separately.
        if ProcessInfo.processInfo.arguments.contains("-uitestSeedP6TrustShowcase") {
            await seedP6TrustShowcase(modelContext: modelContext, syncEngine: syncEngine, userId: userId, now: now)
        }
        // P7 award-audit capture set: own flag, same "own flag, additive"
        // recipe as the two above — see `seedNextRegisterShowcase`'s own
        // doc comment for why the "next" register needs an isolated seed
        // rather than folding into `seedRegisterShowcaseTrips`.
        if ProcessInfo.processInfo.arguments.contains("-uitestSeedNextRegisterShowcase") {
            await seedNextRegisterShowcase(modelContext: modelContext, syncEngine: syncEngine, userId: userId, now: now)
        }
        // P8a avatar-photos capture set: own flag, same "own flag, additive"
        // recipe as the three showcases above.
        if ProcessInfo.processInfo.arguments.contains("-uitestSeedAvatarShowcase") {
            await seedAvatarShowcase(modelContext: modelContext, syncEngine: syncEngine, userId: userId, now: now)
        }
        // P8b photo-covers capture set: own flag, same "own flag, additive"
        // recipe as the four showcases above. NOTE (out of this change's
        // file scope): unlike those four, this flag is deliberately NOT
        // added to `HomeView.applyUITestAutopilotIfNeeded`'s own
        // `showcaseFlags` reset array (`HomeView.swift`) — that file sits
        // outside this pass's scope (TriptoTests/TriptoUITests + this file,
        // additively, only). Every capture test that uses this flag must
        // therefore launch on its own FRESH install (never combined with
        // `-uitestOpenFirstTrip` or another showcase flag in one SHARED
        // store) to avoid the exact `trips.first` sort-order landmine that
        // array exists to prevent for the other four (see
        // `seedRegisterShowcaseTrips`'s own doc comment above) — flagged in
        // the Tester report as the one-line fix that would close this gap
        // for a shared-store run. Routed through a tiny wrapper (see
        // `primeCoverShowcaseImageCacheIfFlagged`'s own doc comment for why)
        // rather than an inline `if` here.
        await seedCoverShowcaseIfFlagged(modelContext: modelContext, syncEngine: syncEngine, userId: userId, now: now)
        return tripId
    }

    // MARK: - P8a avatar-photos capture set (Settings profile photo, a
    // people list/AvatarStack with a photo + an initials avatar side by
    // side, TripProfileFormSheet with a photo)

    /// Fixed, deterministic path strings (never a fresh random `UUID()`) —
    /// the same two paths `primeAvatarShowcaseImageCache` (must run on
    /// EVERY launch, before the outer idempotence guard) and
    /// `seedAvatarShowcase` (row creation, once ever) both need to agree
    /// on; a fresh random path from either side would leave the other's
    /// cache entry/row pointing nowhere.
    private static func avatarShowcaseOwnPhotoPath(userId: UUID) -> String { "\(userId.uuidString)/uitest-own-photo.jpg" }
    private static let avatarShowcaseAshaPhotoPath = "uitest-fixed-asha/uitest-asha-photo.jpg"

    /// `AvatarStorage.publicURL(for:)` always builds a real
    /// `https://…supabase.co/…` URL (no test-only override hook — `Config
    /// .SUPABASE_URL` is a fixed `static let`), so there's no path string
    /// this seed could write that a live request would ever resolve, and
    /// `TriptoUITests` must stay hermetic (CLAUDE.md). Instead of a network
    /// fetch, this primes Nuke's own `ImagePipeline.shared` MEMORY cache
    /// directly, in-process, for the exact URL each seeded `avatarPath`
    /// derives to, with a synthetic in-memory image — `AvatarPhotoCircle`'s
    /// `LazyImage(url:)` then finds a cache hit and renders it with zero
    /// network involved. Deliberately the MEMORY cache, never the on-disk
    /// `DataCache` `AppImagePipeline` also configures — `DataCache`'s
    /// own writes are staged and flushed asynchronously (confirmed against
    /// its own source, `Caching/DataCache.swift`), so priming it here has
    /// no guarantee of finishing before this process ends; called fresh on
    /// EVERY launch instead (see this function's call site, before `seed`'s
    /// own idempotence guard) sidesteps that entirely — cheap, since it's
    /// just an in-memory dictionary write. `AppImagePipeline.configured`
    /// (P8b: renamed from `AvatarImagePipeline` — same one shared pipeline)
    /// is force-referenced FIRST so the `DataCache`-backed pipeline swap
    /// (which replaces `ImagePipeline.shared` wholesale) has already
    /// happened before this primes it — priming the stock default pipeline
    /// instead would be silently discarded the moment any
    /// `AvatarPhotoCircle` first renders and triggers the swap.
    private static func primeAvatarShowcaseImageCache(userId: UUID) {
        _ = AppImagePipeline.configured
        guard let photo = syntheticAvatarPhoto() else { return }
        for path in [avatarShowcaseOwnPhotoPath(userId: userId), avatarShowcaseAshaPhotoPath] {
            if let url = AvatarStorage.publicURL(for: path) {
                ImagePipeline.shared.cache[url] = ImageContainer(image: photo)
            }
        }
    }

    /// A dedicated "Osaka Weekend" trip with exactly two travellers (one
    /// photo, one initials-only) rather than reusing "Lisbon"'s own Meera/
    /// Grandma pair — `ShareTripView`'s per-traveller role-chip `Menu`
    /// shares one fixed "Role: Traveller" accessibility label with every
    /// OTHER traveller row (never the person's name), and every other
    /// showcase in this file already depends on Meera/Grandma's exact
    /// existing shape; a THIRD occupant would only add more ambiguity there
    /// for no capture this set needs. Row creation only, run once ever
    /// (gated by the SAME outer idempotence guard every other showcase in
    /// this file already relies on) — unlike this file's own cache-priming
    /// above, a `TripProfile`/`Profile` row only needs to exist once:
    /// SwiftData's `try? modelContext.save()` is synchronous, so (unlike
    /// Nuke's `DataCache`) it reliably persists before this process ends.
    private static func seedAvatarShowcase(modelContext: ModelContext, syncEngine: SyncEngine, userId: UUID, now: Date) async {
        // Settings' own "Profile" section: `seed()` above deliberately never
        // creates the organizer's own `Profile` row (its own doc comment —
        // it's server-trigger-created, absent from this no-pull hermetic
        // harness), so there'd otherwise be nothing for `SettingsView
        // .myProfile` to seed the photo picker from. Local-only, same
        // "never enqueued" convention as `member`/`companionMember` above —
        // this row exists purely for local rendering, not a sync exercise.
        let profile = Profile(
            id: userId, displayName: "Naveen", avatarColor: "amber",
            avatarPath: avatarShowcaseOwnPhotoPath(userId: userId), createdAt: now, updatedAt: now
        )
        modelContext.insert(profile)
        try? modelContext.save()

        let tripId = UUID()
        let trip = Trip(
            id: tripId, title: "Osaka Weekend", destination: "Osaka, Japan", countryCode: "JP",
            startDate: now.addingTimeInterval(10 * 86_400), endDate: now.addingTimeInterval(13 * 86_400),
            coverGradient: "moss", tripTypeRaw: TripType.family.rawValue, createdBy: userId,
            createdAt: now, updatedAt: now, updatedBy: nil
        )
        let member = TripMember(id: UUID(), tripId: tripId, userId: userId, roleRaw: TripRole.organizer.rawValue, createdAt: now)
        let asha = TripProfile(
            id: UUID(), tripId: tripId, displayName: "Asha", avatarColor: "plum",
            avatarPath: avatarShowcaseAshaPhotoPath, linkedUserId: nil, createdAt: now
        )
        let kiran = TripProfile(
            id: UUID(), tripId: tripId, displayName: "Kiran", avatarColor: "sky",
            linkedUserId: nil, createdAt: now.addingTimeInterval(1)
        )
        let activity = makeItem(
            tripId: tripId, category: .activity, title: "Osaka Castle",
            startsAt: now.addingTimeInterval(10 * 86_400 + 10 * 3600), endsAt: nil, tz: TimeZone.current.identifier,
            locationName: "Osaka Castle", confirmation: nil, details: .empty, userId: userId, now: now
        )

        modelContext.insert(trip)
        modelContext.insert(member) // local-only; never enqueued (see `seed()`'s own `member` doc comment)
        modelContext.insert(asha)
        modelContext.insert(kiran)
        modelContext.insert(activity)
        try? modelContext.save()

        await syncEngine.enqueueUpsert(table: .trips, rowId: tripId, tripId: tripId, payload: trip.toDTO())
        await syncEngine.enqueueUpsert(table: .tripProfiles, rowId: asha.id, tripId: tripId, payload: asha.toDTO())
        await syncEngine.enqueueUpsert(table: .tripProfiles, rowId: kiran.id, tripId: tripId, payload: kiran.toDTO())
        await syncEngine.flushPush()
        await syncEngine.enqueueUpsert(table: .itineraryItems, rowId: activity.id, tripId: tripId, payload: activity.toDTO())
        await syncEngine.flushPush()
    }

    /// A soft gradient swatch — deliberately not a flat color (every
    /// avatar's own initials fallback already is one), so a screenshot
    /// reads unambiguously as "a photo," never mistaken for a second
    /// initials circle.
    private static func syntheticAvatarPhoto() -> UIImage? {
        let size = 240
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        let colors = [
            CGColor(red: 0.98, green: 0.62, blue: 0.25, alpha: 1), CGColor(red: 0.16, green: 0.35, blue: 0.75, alpha: 1)
        ]
        guard let gradient = CGGradient(colorsSpace: colorSpace, colors: colors as CFArray, locations: [0, 1]) else { return nil }
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 0), end: CGPoint(x: size, y: size), options: [])
        guard let cgImage = context.makeImage() else { return nil }
        return UIImage(cgImage: cgImage)
    }

    // MARK: - P8b photo-covers capture set (Home card with a photo cover +
    // a gradient-only control side by side, trip hero with a photo, a
    // "been" row with a photo thumb, `TripFormView` already showing
    // Change/Remove photo) — same "own flag, additive" recipe as every
    // other showcase in this file.

    /// Fixed, deterministic path (never a fresh random `UUID()`) — same
    /// "both the cache-priming side and the row-creation side must agree on
    /// the exact same string" reasoning as `avatarShowcaseOwnPhotoPath`/
    /// `avatarShowcaseAshaPhotoPath` above. One path reused across every
    /// trip in this showcase that needs a photo (unlike the per-person
    /// avatar paths, which have to stay visually distinct side by side —
    /// none of this showcase's photo trips are ever framed together in the
    /// same screenshot, so there's nothing for one shared image to visually
    /// collide with).
    private static let coverShowcasePhotoPath = "uitest-fixed-cover/uitest-cover-photo.jpg"

    /// A simple sky/sea/sun block-shape scene — deliberately real hard-edged
    /// SHAPES, not a smooth blend like `syntheticAvatarPhoto()` above (see
    /// `primeCoverShowcaseImageCache`'s own doc comment for why that
    /// generator specifically doesn't fit here): confirmed empirically to
    /// read as unambiguously "a photo" next to any of the app's own three
    /// smooth `CoverGradient` tokens once composited through `CoverImage`.
    private static func syntheticCoverPhoto() -> UIImage? {
        let size = 320
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(red: 0.55, green: 0.75, blue: 0.92, alpha: 1)) // sky
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        context.setFillColor(CGColor(red: 0.09, green: 0.28, blue: 0.45, alpha: 1)) // sea band
        context.fill(CGRect(x: 0, y: 0, width: size, height: size / 3))
        context.setFillColor(CGColor(red: 0.98, green: 0.72, blue: 0.28, alpha: 1)) // sun
        context.fillEllipse(in: CGRect(x: size / 2 - 40, y: size / 2, width: 80, height: 80))
        guard let cgImage = context.makeImage() else { return nil }
        return UIImage(cgImage: cgImage)
    }

    /// `seed()`'s own flag-check wrapper for `primeCoverShowcaseImageCache`
    /// — a plain unconditional call from `seed()`, not an inline `if` there,
    /// so that function's cyclomatic complexity (already close to this
    /// file's configured ceiling from five prior showcase-flag checks)
    /// doesn't grow by a sixth branch for this one. Same reasoning applies
    /// to `seedCoverShowcaseIfFlagged` below.
    private static func primeCoverShowcaseImageCacheIfFlagged() {
        if ProcessInfo.processInfo.arguments.contains("-uitestSeedCoverShowcase") {
            primeCoverShowcaseImageCache()
        }
    }

    /// Same "prime Nuke's in-process MEMORY cache instead of a live fetch"
    /// reasoning as `primeAvatarShowcaseImageCache` above (that function's
    /// own doc comment covers the full "why memory cache / why every
    /// launch / why `AppImagePipeline.configured` first" rationale — not
    /// repeated here; `CoverStorage.publicURL(for:)`, not `AvatarStorage`'s,
    /// is the one difference). Uses its OWN `syntheticCoverPhoto()` image
    /// below rather than reusing `syntheticAvatarPhoto()`: that generator is
    /// a smooth two-color gradient, indistinguishable at a glance from the
    /// app's own `CoverGradient` tokens — fine for an avatar (the
    /// alternative there is a FLAT initials color), but it would defeat the
    /// whole point of this showcase's "photo vs. gradient-only control"
    /// side-by-side comparison.
    private static func primeCoverShowcaseImageCache() {
        _ = AppImagePipeline.configured
        guard let photo = syntheticCoverPhoto() else { return }
        if let url = CoverStorage.publicURL(for: coverShowcasePhotoPath) {
            ImagePipeline.shared.cache[url] = ImageContainer(image: photo)
        }
    }

    /// Three small trips: an "ahead" one WITH a photo cover (Home card +
    /// trip hero + `TripFormView` edit already showing Change/Remove photo
    /// — `coverImagePath` is seeded straight onto the row, so no
    /// `PhotosPicker` interaction is ever needed to reach that state), a
    /// plain "ahead" one with NO photo (the gradient-only control, framed
    /// side by side with the first on Home — same "put the comparison in
    /// one shot" recipe `seedAvatarShowcase`'s own "Osaka Weekend"
    /// photo-vs-initials pairing already uses), and a "been" one WITH a
    /// photo cover (the 44pt thumb render, `CoverImage`'s `resizeTo`
    /// branch). Dates chosen so neither ahead trip ever matches
    /// `TripMergeDetection.isDuplicate` (different destinations AND
    /// non-identical date ranges) — nothing here should ever surface the P6
    /// duplicate-trip merge strip.
    private static func seedCoverShowcase(modelContext: ModelContext, syncEngine: SyncEngine, userId: UUID, now: Date) async {
        var deviceCalendar = Calendar(identifier: .gregorian)
        deviceCalendar.timeZone = .current
        let today = deviceCalendar.startOfDay(for: now)

        let photoTripId = UUID()
        let photoTrip = Trip(
            id: photoTripId, title: "Zanzibar Escape", destination: "Zanzibar, Tanzania", countryCode: "TZ",
            startDate: deviceCalendar.date(byAdding: .day, value: 18, to: today) ?? today,
            endDate: deviceCalendar.date(byAdding: .day, value: 24, to: today) ?? today,
            coverGradient: "dusk", tripTypeRaw: TripType.family.rawValue, createdBy: userId,
            createdAt: now, updatedAt: now, updatedBy: nil, coverImagePath: coverShowcasePhotoPath
        )
        let photoMember = TripMember(id: UUID(), tripId: photoTripId, userId: userId, roleRaw: TripRole.organizer.rawValue, createdAt: now)
        // Real items — not just this trip's date-range gap-fill — so the
        // itinerary tab has genuine scrollable content to collapse the hero
        // against (the "trip hero ... collapsed state" capture). A
        // multi-night hotel stay is the deliberate choice over more bare
        // activities: it renders its own "staying — night N of M" strip for
        // EVERY night it spans (`ItineraryDayBucketing`), which is what
        // actually pushes total content past one screen's height — a single
        // short activity plus gap-fill "Free day" rows alone measured out
        // to fit on one screen with nothing left to scroll.
        let photoTripActivityDay = deviceCalendar.date(byAdding: .day, value: 19, to: today) ?? today
        let photoTripActivity = makeItem(
            tripId: photoTripId, category: .activity, title: "Stone Town walking tour",
            startsAt: deviceCalendar.date(bySettingHour: 10, minute: 0, second: 0, of: photoTripActivityDay) ?? photoTripActivityDay,
            endsAt: nil, tz: TimeZone.current.identifier, locationName: "Stone Town, Zanzibar", confirmation: nil,
            details: .empty, userId: userId, now: now
        )
        let photoTripCheckIn = deviceCalendar.date(byAdding: .day, value: 18, to: today) ?? today
        let photoTripCheckOut = deviceCalendar.date(byAdding: .day, value: 24, to: today) ?? today
        let photoTripHotel = makeItem(
            tripId: photoTripId, category: .hotel, title: "Zanzibar Beach Resort",
            startsAt: deviceCalendar.date(bySettingHour: 15, minute: 0, second: 0, of: photoTripCheckIn) ?? photoTripCheckIn,
            endsAt: deviceCalendar.date(bySettingHour: 11, minute: 0, second: 0, of: photoTripCheckOut) ?? photoTripCheckOut,
            tz: TimeZone.current.identifier, locationName: "Nungwi, Zanzibar", confirmation: "ZB-4471",
            details: .empty, userId: userId, now: now
        )

        let controlTripId = UUID()
        let controlTrip = Trip(
            id: controlTripId, title: "Helsinki Weekend", destination: "Helsinki, Finland", countryCode: "FI",
            startDate: deviceCalendar.date(byAdding: .day, value: 30, to: today) ?? today,
            endDate: deviceCalendar.date(byAdding: .day, value: 33, to: today) ?? today,
            coverGradient: "moss", tripTypeRaw: TripType.family.rawValue, createdBy: userId,
            createdAt: now.addingTimeInterval(1), updatedAt: now, updatedBy: nil
        )
        let controlMember = TripMember(id: UUID(), tripId: controlTripId, userId: userId, roleRaw: TripRole.organizer.rawValue, createdAt: now)

        modelContext.insert(photoTrip)
        modelContext.insert(photoMember) // local-only; never enqueued (see `seed()`'s own `member` doc comment)
        modelContext.insert(controlTrip)
        modelContext.insert(controlMember) // local-only; never enqueued
        try? modelContext.save()

        await syncEngine.enqueueUpsert(table: .trips, rowId: photoTripId, tripId: photoTripId, payload: photoTrip.toDTO())
        await syncEngine.enqueueUpsert(table: .trips, rowId: controlTripId, tripId: controlTripId, payload: controlTrip.toDTO())
        await syncEngine.flushPush()

        modelContext.insert(photoTripActivity)
        modelContext.insert(photoTripHotel)
        try? modelContext.save()
        await syncEngine.enqueueUpsert(
            table: .itineraryItems, rowId: photoTripActivity.id, tripId: photoTripId, payload: photoTripActivity.toDTO()
        )
        await syncEngine.enqueueUpsert(
            table: .itineraryItems, rowId: photoTripHotel.id, tripId: photoTripId, payload: photoTripHotel.toDTO()
        )
        await syncEngine.flushPush()

        // A "been" trip WITH a photo cover — same fixed-calendar-year shape
        // `seedPastTrip` above uses (a real "been" register needs a fixed
        // year, not one relative to `now`), built by hand here since that
        // helper has no `coverImagePath` parameter of its own to pass one
        // through.
        let beenTripId = UUID()
        let beenTrip = Trip(
            id: beenTripId, title: "Santorini Sunset", destination: "Santorini, Greece", countryCode: "GR",
            startDate: DayDate(year: 2025, month: 11, day: 10).asDate(calendar: deviceCalendar),
            endDate: DayDate(year: 2025, month: 11, day: 13).asDate(calendar: deviceCalendar),
            coverGradient: "plum", tripTypeRaw: TripType.family.rawValue, createdBy: userId,
            createdAt: now, updatedAt: now, updatedBy: nil, coverImagePath: coverShowcasePhotoPath
        )
        let beenMember = TripMember(id: UUID(), tripId: beenTripId, userId: userId, roleRaw: TripRole.organizer.rawValue, createdAt: now)
        modelContext.insert(beenTrip)
        modelContext.insert(beenMember) // local-only; never enqueued
        try? modelContext.save()
        await syncEngine.enqueueUpsert(table: .trips, rowId: beenTripId, tripId: beenTripId, payload: beenTrip.toDTO())
        await syncEngine.flushPush()
    }

    /// `seed()`'s own flag-check wrapper — see `primeCoverShowcaseImage
    /// CacheIfFlagged`'s doc comment for why this is a plain unconditional
    /// call from `seed()` rather than an inline `if` there.
    private static func seedCoverShowcaseIfFlagged(modelContext: ModelContext, syncEngine: SyncEngine, userId: UUID, now: Date) async {
        if ProcessInfo.processInfo.arguments.contains("-uitestSeedCoverShowcase") {
            await seedCoverShowcase(modelContext: modelContext, syncEngine: syncEngine, userId: userId, now: now)
        }
    }

    // MARK: - UX P7 "next" register showcase (Home, countdown ring + FIRST UP)

    /// A single upcoming (never live) trip so `ahead.first` earns `.next`
    /// (the countdown ring + "FIRST UP" strip) — the one register kind
    /// `seedRegisterShowcaseTrips` below deliberately never shows: a live
    /// trip's `startDate` always sorts ahead of a future one
    /// (`HomeTripOrdering.ahead`'s own doc comment), so `.now` and `.next`
    /// can never both render off one seed, and that showcase's own "Tokyo
    /// Sprint" is deliberately live. That function's doc comment says as
    /// much: `.next` was, until now, covered only by
    /// `HomeRegistersTests.testFirstAheadTripThatIsUpcomingIsNext` — a
    /// logic-only unit test, never a visual capture. Own flag, own trip, no
    /// live trip anywhere in this seed — the countdown ring has nothing to
    /// lose to. One confirmed flight (`HomeFirstUp.pick`'s own
    /// `status == .confirmed && startsAt >= now` filter) gives "FIRST UP"
    /// real content instead of an empty strip.
    private static func seedNextRegisterShowcase(modelContext: ModelContext, syncEngine: SyncEngine, userId: UUID, now: Date) async {
        var deviceCalendar = Calendar(identifier: .gregorian)
        deviceCalendar.timeZone = .current
        let today = deviceCalendar.startOfDay(for: now)
        let tripId = UUID()
        let startDate = deviceCalendar.date(byAdding: .day, value: 12, to: today) ?? today
        let endDate = deviceCalendar.date(byAdding: .day, value: 16, to: today) ?? today
        let trip = Trip(
            id: tripId, title: "Marrakech Long Weekend", destination: "Marrakech, Morocco", countryCode: "MA",
            startDate: startDate, endDate: endDate, coverGradient: "dusk",
            tripTypeRaw: TripType.family.rawValue, createdBy: userId,
            createdAt: now, updatedAt: now, updatedBy: nil
        )
        let member = TripMember(id: UUID(), tripId: tripId, userId: userId, roleRaw: TripRole.organizer.rawValue, createdAt: now)
        let tz = TimeZone.current.identifier

        var flightDetails = ItemDetails.empty
        flightDetails.airline = "Royal Air Maroc"; flightDetails.flightNo = "AT201"
        flightDetails.fromIATA = "JFK"; flightDetails.toIATA = "RAK"
        let flight = makeItem(
            tripId: tripId, category: .flight, title: "Royal Air Maroc AT201",
            startsAt: deviceCalendar.date(bySettingHour: 9, minute: 15, second: 0, of: startDate) ?? startDate,
            endsAt: nil, tz: tz, locationName: "JFK", confirmation: "MK55210",
            details: flightDetails, userId: userId, now: now
        )

        await pushShowcaseTrip(trip, member: member, items: [flight], modelContext: modelContext, syncEngine: syncEngine)
    }

    // MARK: - UX P6 trust-suite showcase (import-result / merge / dedupe)

    /// Two same-dates/same-destination "ahead" trips so `TripMergeDetection
    /// .survivorByShellId` finds a real adjacent pair to fuse a
    /// `DuplicateTripStrip` under on Home (P6.2's merge strip + 6s countdown
    /// screenshots), plus two similarly-named `TripProfile` rows on one of
    /// them so `ProfileDedupe.duplicatePairs` has something for
    /// `ShareTripView`'s dedupe banner + review sheet to surface (P6.3).
    /// Dated relative to `Date()`, not fixed like the flights/hotels above —
    /// same reasoning as `seedRegisterShowcaseTrips`'s own doc comment: this
    /// must stay a genuine "ahead" (never "been") pair no matter when the
    /// seed actually runs. Both trips get a LOCAL-only organizer
    /// `TripMember` for `userId` (same "never enqueued" shape as `member`
    /// above) — `HomeView.canMergeTrips`/`ShareTripView`'s dedupe banner are
    /// both organizer-gated, and this is the signed-in user on every launch
    /// `-uitestAutoSignIn` drives.
    ///
    /// Own flag rather than folding into `seedRegisterShowcaseTrips`: same
    /// "`-uitestOpenFirstTrip` targets `trips.first?.id`" landmine that
    /// function's own doc comment already flags — an uninvolved test opting
    /// into the register showcase alone must not also gain a duplicate-trip
    /// pair (or vice versa) it never asked for.
    private static func seedP6TrustShowcase(modelContext: ModelContext, syncEngine: SyncEngine, userId: UUID, now: Date) async {
        var deviceCalendar = Calendar(identifier: .gregorian)
        deviceCalendar.timeZone = .current
        let today = deviceCalendar.startOfDay(for: now)
        let start = deviceCalendar.date(byAdding: .day, value: 20, to: today) ?? today
        let end = deviceCalendar.date(byAdding: .day, value: 25, to: today) ?? today

        let firstId = UUID()
        let first = Trip(
            id: firstId, title: "Bali Family Trip", destination: "Bali, Indonesia", countryCode: "ID",
            startDate: start, endDate: end, coverGradient: "moss", tripTypeRaw: TripType.family.rawValue,
            createdBy: userId, createdAt: now, updatedAt: now, updatedBy: nil
        )
        let firstMember = TripMember(id: UUID(), tripId: firstId, userId: userId, roleRaw: TripRole.organizer.rawValue, createdAt: now)
        // P6.3: two profiles on the SAME trip sharing a normalized display
        // name (trim + lowercase — `ProfileDedupe.normalizedKey`) — reads as
        // a realistic "typed the same family member in twice" duplicate
        // (trailing space, invisible in the UI) rather than an obvious typo.
        let priya = TripProfile(id: UUID(), tripId: firstId, displayName: "Priya", avatarColor: "plum", linkedUserId: nil, createdAt: now)
        let priyaAgain = TripProfile(
            id: UUID(), tripId: firstId, displayName: "Priya ", avatarColor: "sky", linkedUserId: nil,
            createdAt: now.addingTimeInterval(1)
        )

        let secondId = UUID()
        let second = Trip(
            id: secondId, title: "Bali Getaway", destination: "Bali, Indonesia", countryCode: "ID",
            startDate: start, endDate: end, coverGradient: "dusk", tripTypeRaw: TripType.family.rawValue,
            createdBy: userId, createdAt: now.addingTimeInterval(1), updatedAt: now, updatedBy: nil
        )
        let secondMember = TripMember(id: UUID(), tripId: secondId, userId: userId, roleRaw: TripRole.organizer.rawValue, createdAt: now)

        modelContext.insert(first)
        modelContext.insert(firstMember) // local-only; never enqueued (see note above)
        modelContext.insert(priya)
        modelContext.insert(priyaAgain)
        modelContext.insert(second)
        modelContext.insert(secondMember) // local-only; never enqueued
        try? modelContext.save()

        await syncEngine.enqueueUpsert(table: .trips, rowId: firstId, tripId: firstId, payload: first.toDTO())
        await syncEngine.enqueueUpsert(table: .trips, rowId: secondId, tripId: secondId, payload: second.toDTO())
        await syncEngine.enqueueUpsert(table: .tripProfiles, rowId: priya.id, tripId: firstId, payload: priya.toDTO())
        await syncEngine.enqueueUpsert(table: .tripProfiles, rowId: priyaAgain.id, tripId: firstId, payload: priyaAgain.toDTO())
        await syncEngine.flushPush()
    }

    // MARK: - UX P5 register showcase (Home one-list, three registers)
    //
    // Additive to the "Lisbon" fixture above (docs/UX_REDESIGN_ROADMAP.md
    // Phase 5 verify wave): on its own, "Lisbon" can only ever occupy ONE
    // `HomeRegisterKind` at a time (whichever its own fixed May 2026 dates
    // happen to fall into on the day this runs), so there was nothing to
    // screenshot "the full register stack" against. These four companion
    // trips are dated relative to `Date()` (unlike Lisbon's fixed dates) so
    // "live"/"future" stay true no matter when the seed actually runs.
    //
    // `.next` (the "FIRST UP" strip) is the one `HomeRegisterKind` that can
    // NEVER render alongside `.now` in the same screenshot: `HomeRegister
    // .kind` only ever grants either one to `ahead.first`, and a live
    // trip's `startDate` (always `<= today`) permanently outranks any
    // future trip for that single slot (`HomeTripOrdering.ahead`'s own doc
    // comment — "a live trip's startDate is always <= today, so it sorts to
    // position 0 for free"). Not an omission here — `Tokyo Sprint` (live)
    // and `Kyoto Autumn` (future) below prove `.now` + `.plain` coexist;
    // `.next` alone is already covered by `HomeRegistersTests.swift`'s
    // `testFirstAheadTripThatIsUpcomingIsNext`.
    private static func seedRegisterShowcaseTrips(modelContext: ModelContext, syncEngine: SyncEngine, userId: UUID, now: Date) async {
        var deviceCalendar = Calendar(identifier: .gregorian)
        deviceCalendar.timeZone = .current
        let today = deviceCalendar.startOfDay(for: now)

        await seedLiveTrip(modelContext: modelContext, syncEngine: syncEngine, userId: userId, now: now, today: today, deviceCalendar: deviceCalendar)
        await seedFutureTrip(modelContext: modelContext, syncEngine: syncEngine, userId: userId, now: now, today: today, deviceCalendar: deviceCalendar)
        // Dec 31 / Jan 1 back to back, on purpose: the exact "been"
        // year-boundary case the P5 verify wave flagged (does a trip ending
        // right at the New Year land under the right sticky year header?) —
        // `HomeView.beenYears` groups by `Calendar.current.component(.year,
        // from: trip.endDate)`, so this is the most direct way to exercise
        // it live in a UI test.
        await seedPastTrip(
            modelContext: modelContext, syncEngine: syncEngine, userId: userId, now: now,
            title: "Rome Christmas", destination: "Rome, Italy", countryCode: "IT", coverGradient: "plum",
            start: DayDate(year: 2025, month: 12, day: 24), end: DayDate(year: 2025, month: 12, day: 31),
            deviceCalendar: deviceCalendar
        )
        await seedPastTrip(
            modelContext: modelContext, syncEngine: syncEngine, userId: userId, now: now,
            title: "Seoul New Year", destination: "Seoul, South Korea", countryCode: "KR", coverGradient: "moss",
            start: DayDate(year: 2026, month: 1, day: 1), end: DayDate(year: 2026, month: 1, day: 3),
            deviceCalendar: deviceCalendar
        )
        // P7 award-audit capture set: more 2025 "been" trips, additive — the
        // archive already had 2 distinct years (2025/2026 above, plus the
        // base "Lisbon" fixture itself, whose fixed May 2026 dates have
        // since aged into "been" too), but only 1 row apiece — not enough
        // rows for a whole screen, let alone proving a header stays pinned
        // WHILE scrolling through its own section (confirmed empirically: a
        // 3-row 2025 still let the entire archive fit within about 1.5
        // screens, so "one page down" always showed everything at once,
        // headers included, with nothing genuinely stuck). 2025 now carries
        // 6 rows — comfortably taller than one screen by itself — so
        // scrolling through it necessarily catches the "2025" header
        // pinned at the top with several of its own rows still sliding by
        // underneath, not just visible once.
        await seedPastTrip(
            modelContext: modelContext, syncEngine: syncEngine, userId: userId, now: now,
            title: "Barcelona Long Weekend", destination: "Barcelona, Spain", countryCode: "ES", coverGradient: "dusk",
            start: DayDate(year: 2025, month: 8, day: 15), end: DayDate(year: 2025, month: 8, day: 18),
            deviceCalendar: deviceCalendar
        )
        await seedPastTrip(
            modelContext: modelContext, syncEngine: syncEngine, userId: userId, now: now,
            title: "Prague Spring Break", destination: "Prague, Czechia", countryCode: "CZ", coverGradient: "plum",
            start: DayDate(year: 2025, month: 4, day: 3), end: DayDate(year: 2025, month: 4, day: 6),
            deviceCalendar: deviceCalendar
        )
        await seedPastTrip(
            modelContext: modelContext, syncEngine: syncEngine, userId: userId, now: now,
            title: "Amsterdam Canals", destination: "Amsterdam, Netherlands", countryCode: "NL", coverGradient: "moss",
            start: DayDate(year: 2025, month: 6, day: 6), end: DayDate(year: 2025, month: 6, day: 9),
            deviceCalendar: deviceCalendar
        )
        await seedPastTrip(
            modelContext: modelContext, syncEngine: syncEngine, userId: userId, now: now,
            title: "Vienna Weekend", destination: "Vienna, Austria", countryCode: "AT", coverGradient: "dusk",
            start: DayDate(year: 2025, month: 9, day: 19), end: DayDate(year: 2025, month: 9, day: 21),
            deviceCalendar: deviceCalendar
        )
        await seedPastTrip(
            modelContext: modelContext, syncEngine: syncEngine, userId: userId, now: now,
            title: "Dublin St. Patrick's", destination: "Dublin, Ireland", countryCode: "IE", coverGradient: "plum",
            start: DayDate(year: 2025, month: 3, day: 15), end: DayDate(year: 2025, month: 3, day: 17),
            deviceCalendar: deviceCalendar
        )
        await seedPastTrip(
            modelContext: modelContext, syncEngine: syncEngine, userId: userId, now: now,
            title: "Edinburgh Fringe", destination: "Edinburgh, Scotland", countryCode: "GB", coverGradient: "moss",
            start: DayDate(year: 2025, month: 8, day: 2), end: DayDate(year: 2025, month: 8, day: 5),
            deviceCalendar: deviceCalendar
        )
    }

    /// The `.now` register: today sits comfortably mid-trip (day 4 of 8),
    /// with 3 confirmed items today — P5.3's inline mini-list needs at
    /// least that many to also show "+K more today" — plus one each on the
    /// surrounding days so `DayProgressBar` has real done/upcoming segments
    /// either side of "now", not just a single-day trip.
    private static func seedLiveTrip(
        modelContext: ModelContext, syncEngine: SyncEngine, userId: UUID, now: Date, today: Date, deviceCalendar: Calendar
    ) async {
        let tripId = UUID()
        let trip = Trip(
            id: tripId, title: "Tokyo Sprint", destination: "Tokyo, Japan", countryCode: "JP",
            startDate: deviceCalendar.date(byAdding: .day, value: -3, to: today) ?? today,
            endDate: deviceCalendar.date(byAdding: .day, value: 4, to: today) ?? today,
            coverGradient: "plum", tripTypeRaw: TripType.family.rawValue, createdBy: userId,
            createdAt: now, updatedAt: now, updatedBy: nil
        )
        let member = TripMember(id: UUID(), tripId: tripId, userId: userId, roleRaw: TripRole.organizer.rawValue, createdAt: now)
        let tz = TimeZone.current.identifier

        // A named struct, not a 4-tuple (`large_tuple`'s own configured cap
        // is 3 — `.swiftlint.yml`) — same "Draft" local-struct convention
        // `packingItems` below already uses for the same reason.
        struct TodayPlanEntry {
            let hour: Int
            let category: ItemCategory
            let title: String
            let location: String
        }
        var items: [ItineraryItem] = []
        let todaysPlan: [TodayPlanEntry] = [
            TodayPlanEntry(hour: 8, category: .food, title: "Tsukiji breakfast", location: "Tsukiji Outer Market, Tokyo"),
            TodayPlanEntry(hour: 13, category: .activity, title: "teamLab Planets", location: "Toyosu, Tokyo"),
            TodayPlanEntry(hour: 19, category: .food, title: "Ramen crawl", location: "Shinjuku, Tokyo")
        ]
        for plan in todaysPlan {
            items.append(makeItem(
                tripId: tripId, category: plan.category, title: plan.title,
                startsAt: deviceCalendar.date(bySettingHour: plan.hour, minute: 0, second: 0, of: today) ?? today,
                endsAt: nil, tz: tz, locationName: plan.location, confirmation: nil,
                details: .empty, userId: userId, now: now
            ))
        }
        if let yesterday = deviceCalendar.date(byAdding: .day, value: -1, to: today) {
            items.append(makeItem(
                tripId: tripId, category: .activity, title: "Senso-ji Temple",
                startsAt: deviceCalendar.date(bySettingHour: 10, minute: 0, second: 0, of: yesterday) ?? yesterday,
                endsAt: nil, tz: tz, locationName: "Asakusa, Tokyo", confirmation: nil,
                details: .empty, userId: userId, now: now
            ))
        }
        if let tomorrow = deviceCalendar.date(byAdding: .day, value: 1, to: today) {
            items.append(makeItem(
                tripId: tripId, category: .activity, title: "Mount Fuji day trip",
                startsAt: deviceCalendar.date(bySettingHour: 7, minute: 0, second: 0, of: tomorrow) ?? tomorrow,
                endsAt: nil, tz: tz, locationName: "Kawaguchiko", confirmation: "TKT-9001",
                details: .empty, userId: userId, now: now
            ))
        }

        await pushShowcaseTrip(trip, member: member, items: items, modelContext: modelContext, syncEngine: syncEngine)
    }

    /// A `.plain` ahead card ~6 weeks out (never `.next` — see this
    /// section's own doc comment above) with a real flight + hotel, so it
    /// reads as a genuine upcoming trip rather than filler.
    ///
    /// P7 award-audit capture set: `endDate` is one day past the hotel's own
    /// checkout (`checkOutDay` below), additive — the itinerary tab's
    /// gap-fill (`ItineraryDayBucketing.sections(tripEnd:)`) renders any day
    /// in `tripStart...tripEnd` no item touches as a quiet "Free day" row,
    /// and this trip previously had none: every day was either the check-in,
    /// an in-between "staying \u{2014} night N of M" strip, or the checkout
    /// itself. The extra day now sits right after checkout, adjacent to the
    /// last staying strip, so one scroll position shows both a stay strip
    /// and a genuinely empty day slot together.
    private static func seedFutureTrip(
        modelContext: ModelContext, syncEngine: SyncEngine, userId: UUID, now: Date, today: Date, deviceCalendar: Calendar
    ) async {
        let tripId = UUID()
        let startDate = deviceCalendar.date(byAdding: .day, value: 45, to: today) ?? today
        let endDate = deviceCalendar.date(byAdding: .day, value: 52, to: today) ?? today
        let trip = Trip(
            id: tripId, title: "Kyoto Autumn", destination: "Kyoto, Japan", countryCode: "JP",
            startDate: startDate, endDate: endDate, coverGradient: "moss",
            tripTypeRaw: TripType.family.rawValue, createdBy: userId,
            createdAt: now, updatedAt: now, updatedBy: nil
        )
        let member = TripMember(id: UUID(), tripId: tripId, userId: userId, roleRaw: TripRole.organizer.rawValue, createdAt: now)
        let tz = TimeZone.current.identifier

        var flightDetails = ItemDetails.empty
        flightDetails.airline = "ANA"; flightDetails.flightNo = "NH1"
        flightDetails.fromIATA = "JFK"; flightDetails.toIATA = "KIX"
        let flight = makeItem(
            tripId: tripId, category: .flight, title: "ANA NH1",
            startsAt: deviceCalendar.date(bySettingHour: 11, minute: 30, second: 0, of: startDate) ?? startDate,
            endsAt: nil, tz: tz, locationName: "JFK", confirmation: "KY7731",
            details: flightDetails, userId: userId, now: now
        )
        let checkOutDay = deviceCalendar.date(byAdding: .day, value: 6, to: startDate) ?? startDate
        let hotel = makeItem(
            tripId: tripId, category: .hotel, title: "Kyoto Ryokan",
            startsAt: deviceCalendar.date(bySettingHour: 15, minute: 0, second: 0, of: startDate) ?? startDate,
            endsAt: deviceCalendar.date(bySettingHour: 11, minute: 0, second: 0, of: checkOutDay) ?? checkOutDay,
            tz: tz, locationName: "Higashiyama, Kyoto", confirmation: "RY-2201",
            details: .empty, userId: userId, now: now
        )

        await pushShowcaseTrip(trip, member: member, items: [flight, hotel], modelContext: modelContext, syncEngine: syncEngine)
    }

    /// A "been" register row — `start`/`end` are `DayDate` (the same
    /// tz-less "just a day" type `Trip.startDate`/`endDate` themselves use,
    /// `DayDate.swift`'s own doc comment), not relative-to-`now` like the
    /// live/future trips above: a past trip's whole point here is a FIXED
    /// year for the "been" section's sticky year headers to group.
    private static func seedPastTrip(
        modelContext: ModelContext, syncEngine: SyncEngine, userId: UUID, now: Date,
        title: String, destination: String, countryCode: String, coverGradient: String,
        start: DayDate, end: DayDate, deviceCalendar: Calendar
    ) async {
        let tripId = UUID()
        let startInstant = start.asDate(calendar: deviceCalendar)
        let trip = Trip(
            id: tripId, title: title, destination: destination, countryCode: countryCode,
            startDate: startInstant, endDate: end.asDate(calendar: deviceCalendar),
            coverGradient: coverGradient, tripTypeRaw: TripType.family.rawValue, createdBy: userId,
            createdAt: now, updatedAt: now, updatedBy: nil
        )
        let member = TripMember(id: UUID(), tripId: tripId, userId: userId, roleRaw: TripRole.organizer.rawValue, createdAt: now)
        let tz = deviceCalendar.timeZone.identifier

        let plan: [(dayOffset: Int, category: ItemCategory, title: String)] = [
            (0, .activity, "Arrival"), (1, .food, "Welcome dinner"),
            (1, .activity, "Old town walk"), (2, .food, "Farewell lunch")
        ]
        let items = plan.map { entry -> ItineraryItem in
            let day = deviceCalendar.date(byAdding: .day, value: entry.dayOffset, to: startInstant) ?? startInstant
            return makeItem(
                tripId: tripId, category: entry.category, title: entry.title,
                startsAt: deviceCalendar.date(bySettingHour: 12, minute: 0, second: 0, of: day) ?? day,
                endsAt: nil, tz: tz, locationName: destination, confirmation: nil,
                details: .empty, userId: userId, now: now
            )
        }

        await pushShowcaseTrip(trip, member: member, items: items, modelContext: modelContext, syncEngine: syncEngine)
    }

    /// One trip + its organizer membership (local-only, never enqueued —
    /// same reasoning as `seed()`'s own `member` above) + its items, pushed
    /// through the exact same insert-then-enqueue path every other mutation
    /// in the app uses.
    private static func pushShowcaseTrip(
        _ trip: Trip, member: TripMember, items: [ItineraryItem], modelContext: ModelContext, syncEngine: SyncEngine
    ) async {
        modelContext.insert(trip)
        modelContext.insert(member)
        for item in items { modelContext.insert(item) }
        try? modelContext.save()

        await syncEngine.enqueueUpsert(table: .trips, rowId: trip.id, tripId: trip.id, payload: trip.toDTO())
        await syncEngine.flushPush()
        for item in items {
            await syncEngine.enqueueUpsert(table: .itineraryItems, rowId: item.id, tripId: trip.id, payload: item.toDTO())
        }
        await syncEngine.flushPush()
    }

    // MARK: - M4 family layer (non-app profiles, item_assignees, packing)

    /// One clean, unambiguous nap-tagged activity assigned to the (non-app)
    /// "Meera" profile — see the doc comment where this is called.
    private static func familyDemoItem(tripId: UUID, userId: UUID, now: Date, lisbonTz: TimeZone) -> ItineraryItem {
        var lisbonCalendar = Calendar(identifier: .gregorian)
        lisbonCalendar.timeZone = lisbonTz
        var details = ItemDetails.empty
        details.tags = [ItemTag.nap.rawValue]
        return makeItem(
            tripId: tripId, category: .activity, title: "Quiet time",
            startsAt: instant(2026, 5, 15, 15, 0, calendar: lisbonCalendar), endsAt: nil,
            tz: lisbonTz.identifier, locationName: "Memmo Alfama, Lisbon", confirmation: nil,
            details: details, userId: userId, now: now
        )
    }

    private static func packingItems(
        tripId: UUID, userId: UUID, now: Date, meeraId: UUID, grandmaId: UUID
    ) -> [PackingItem] {
        struct Draft {
            let label: String
            let group: PackingGroupKey
            let assignee: UUID?
            let isDone: Bool
        }
        let drafts: [Draft] = [
            // Unassigned, not the organizer's own profile — see the doc
            // comment where this function is called.
            Draft(label: "Passports (all 5)", group: .documents, assignee: nil, isDone: true),
            Draft(label: "Travel insurance printout", group: .documents, assignee: nil, isDone: true),
            Draft(label: "Boarding passes", group: .documents, assignee: nil, isDone: false),
            Draft(label: "Meera\u{2019}s car seat", group: .kids, assignee: meeraId, isDone: false),
            Draft(label: "Stroller (compact)", group: .kids, assignee: meeraId, isDone: false),
            Draft(label: "Snacks & activities for the flight", group: .kids, assignee: nil, isDone: true),
            Draft(label: "Universal power adapters \u{d7}3", group: .shared, assignee: nil, isDone: false),
            Draft(label: "Sunscreen (family size)", group: .shared, assignee: grandmaId, isDone: true),
            Draft(label: "First-aid kit", group: .shared, assignee: nil, isDone: false),
            Draft(label: "Rain jackets", group: .clothing, assignee: nil, isDone: false),
            Draft(label: "Swimwear", group: .clothing, assignee: grandmaId, isDone: true),
            Draft(label: "Portable phone charger", group: .custom, assignee: nil, isDone: false)
        ]
        return drafts.map { draft in
            PackingItem(
                id: UUID(), tripId: tripId, label: draft.label, groupKeyRaw: draft.group.rawValue,
                assigneeProfileId: draft.assignee, isDone: draft.isDone, createdBy: userId,
                createdAt: now, updatedAt: now, updatedBy: nil
            )
        }
    }

    // MARK: - Named items (ACCEPTANCE.md's exact flight, tz-crossing legs, multi-night stays)

    private static func flights(
        tripId: UUID, userId: UUID, now: Date, nyTz: TimeZone, lisbonTz: TimeZone, madridTz: TimeZone
    ) -> [ItineraryItem] {
        var nyCalendar = Calendar(identifier: .gregorian); nyCalendar.timeZone = nyTz
        var lisbonCalendar = Calendar(identifier: .gregorian); lisbonCalendar.timeZone = lisbonTz
        var madridCalendar = Calendar(identifier: .gregorian); madridCalendar.timeZone = madridTz

        // Outbound — ACCEPTANCE.md "(a)" Case A1, verbatim.
        var outbound = ItemDetails.empty
        outbound.airline = "TAP Air Portugal"; outbound.flightNo = "TP1234"
        outbound.fromIATA = "JFK"; outbound.toIATA = "LIS"
        outbound.seat = "14C"; outbound.terminal = "1"; outbound.gate = "22"
        outbound.arrivalTz = lisbonTz.identifier
        let outboundFlight = makeItem(
            tripId: tripId, category: .flight, title: "TAP TP1234",
            startsAt: instant(2026, 5, 14, 8, 20, calendar: nyCalendar),
            endsAt: instant(2026, 5, 14, 20, 15, calendar: lisbonCalendar),
            tz: nyTz.identifier, locationName: "JFK", confirmation: "QK7P2M",
            details: outbound, userId: userId, now: now
        )

        // Lisbon → Madrid side trip.
        var toMadrid = ItemDetails.empty
        toMadrid.airline = "Iberia"; toMadrid.flightNo = "IB3411"
        toMadrid.fromIATA = "LIS"; toMadrid.toIATA = "MAD"; toMadrid.seat = "9A"
        toMadrid.arrivalTz = madridTz.identifier
        let toMadridFlight = makeItem(
            tripId: tripId, category: .flight, title: "Iberia IB3411",
            startsAt: instant(2026, 5, 21, 9, 0, calendar: lisbonCalendar),
            endsAt: instant(2026, 5, 21, 11, 40, calendar: madridCalendar),
            tz: lisbonTz.identifier, locationName: "LIS", confirmation: "MAD4471",
            details: toMadrid, userId: userId, now: now
        )

        // Madrid → Lisbon return leg.
        var toLisbon = ItemDetails.empty
        toLisbon.airline = "Iberia"; toLisbon.flightNo = "IB3418"
        toLisbon.fromIATA = "MAD"; toLisbon.toIATA = "LIS"; toLisbon.seat = "9A"
        toLisbon.arrivalTz = lisbonTz.identifier
        let toLisbonFlight = makeItem(
            tripId: tripId, category: .flight, title: "Iberia IB3418",
            startsAt: instant(2026, 5, 23, 18, 0, calendar: madridCalendar),
            endsAt: instant(2026, 5, 23, 18, 45, calendar: lisbonCalendar),
            tz: madridTz.identifier, locationName: "MAD", confirmation: "LIS9982",
            details: toLisbon, userId: userId, now: now
        )

        // Return — westbound "go back" crossing (ACCEPTANCE.md "(a)" chip math, opposite direction).
        var homeward = ItemDetails.empty
        homeward.airline = "TAP Air Portugal"; homeward.flightNo = "TP1235"
        homeward.fromIATA = "LIS"; homeward.toIATA = "JFK"
        homeward.seat = "12A"; homeward.terminal = "1"
        homeward.arrivalTz = nyTz.identifier
        let homewardFlight = makeItem(
            tripId: tripId, category: .flight, title: "TAP TP1235",
            startsAt: instant(2026, 5, 27, 11, 0, calendar: lisbonCalendar),
            endsAt: instant(2026, 5, 27, 14, 25, calendar: nyCalendar),
            tz: lisbonTz.identifier, locationName: "LIS", confirmation: "AA2201",
            details: homeward, userId: userId, now: now
        )

        return [outboundFlight, toMadridFlight, toLisbonFlight, homewardFlight]
    }

    private static func hotels(
        tripId: UUID, userId: UUID, now: Date, lisbonTz: TimeZone, madridTz: TimeZone
    ) -> [ItineraryItem] {
        var lisbonCalendar = Calendar(identifier: .gregorian); lisbonCalendar.timeZone = lisbonTz
        var madridCalendar = Calendar(identifier: .gregorian); madridCalendar.timeZone = madridTz

        var room1 = ItemDetails.empty; room1.room = "412"
        let hotel1 = makeItem(
            tripId: tripId, category: .hotel, title: "Memmo Alfama",
            startsAt: instant(2026, 5, 14, 16, 0, calendar: lisbonCalendar),
            endsAt: instant(2026, 5, 17, 11, 0, calendar: lisbonCalendar),
            tz: lisbonTz.identifier, locationName: "Alfama, Lisbon", confirmation: "HTL-88213",
            details: room1, userId: userId, now: now
        )

        // No confirmation on this one — exercises "items without confirmations".
        var room2 = ItemDetails.empty; room2.room = "205"
        let hotel2 = makeItem(
            tripId: tripId, category: .hotel, title: "LX Boutique Hotel",
            startsAt: instant(2026, 5, 17, 15, 0, calendar: lisbonCalendar),
            endsAt: instant(2026, 5, 21, 11, 0, calendar: lisbonCalendar),
            tz: lisbonTz.identifier, locationName: "Alcântara, Lisbon", confirmation: nil,
            details: room2, userId: userId, now: now
        )

        var room3 = ItemDetails.empty; room3.room = "1102"
        let hotel3 = makeItem(
            tripId: tripId, category: .hotel, title: "Gran Meliá Palacio de los Duques",
            startsAt: instant(2026, 5, 21, 15, 0, calendar: madridCalendar),
            endsAt: instant(2026, 5, 23, 11, 0, calendar: madridCalendar),
            tz: madridTz.identifier, locationName: "Centro, Madrid", confirmation: "MAD-77120",
            details: room3, userId: userId, now: now
        )

        var room4 = ItemDetails.empty; room4.room = "308"
        let hotel4 = makeItem(
            tripId: tripId, category: .hotel, title: "Memmo Alfama",
            startsAt: instant(2026, 5, 23, 19, 0, calendar: lisbonCalendar),
            endsAt: instant(2026, 5, 27, 11, 0, calendar: lisbonCalendar),
            tz: lisbonTz.identifier, locationName: "Alfama, Lisbon", confirmation: nil,
            details: room4, userId: userId, now: now
        )

        // UX P2 milestone (docs/UX_REDESIGN_ROADMAP.md Phase 2, P2.1): an
        // accidental duplicate booking for the exact same nights as
        // `hotel1` — the seed's own instance of `StayConflicts`' "Two stays
        // overlap all N nights" scenario, so the conflict banner + per-card
        // flag have something to show in the P1+P2 milestone screenshots
        // (Tester, verify wave). Purely additive: every other seeded item
        // above is unchanged.
        var room1Duplicate = ItemDetails.empty; room1Duplicate.room = "12"
        let hotel1Duplicate = makeItem(
            tripId: tripId, category: .hotel, title: "Alfama Guesthouse",
            startsAt: instant(2026, 5, 14, 16, 0, calendar: lisbonCalendar),
            endsAt: instant(2026, 5, 17, 11, 0, calendar: lisbonCalendar),
            tz: lisbonTz.identifier, locationName: "Alfama, Lisbon", confirmation: "AG-30071",
            details: room1Duplicate, userId: userId, now: now
        )

        return [hotel1, hotel2, hotel3, hotel4, hotel1Duplicate]
    }

    // MARK: - Filler activities/food (spread across the trip's remaining days)

    private static let samplePlaces: [(title: String, location: String, category: ItemCategory)] = [
        ("Belém Tower", "Belém, Lisbon", .activity),
        ("Pastéis de Belém", "Belém, Lisbon", .food),
        ("LX Factory", "Alcântara, Lisbon", .activity),
        ("Time Out Market", "Cais do Sodré, Lisbon", .food),
        ("Tram 28 ride", "Graça, Lisbon", .activity),
        ("Cervejaria Ramiro", "Intendente, Lisbon", .food),
        ("São Jorge Castle", "Alfama, Lisbon", .activity),
        ("Pink Street night out", "Cais do Sodré, Lisbon", .food),
        ("Oceanário de Lisboa", "Parque das Nações, Lisbon", .activity),
        ("Ginjinha tasting", "Rossio, Lisbon", .food),
        ("Sintra day trip", "Sintra", .activity),
        ("Fado night", "Alfama, Lisbon", .food),
        ("Museu Nacional do Azulejo", "Xabregas, Lisbon", .activity),
        ("Mercado da Ribeira", "Cais do Sodré, Lisbon", .food),
        ("Prado Museum", "Retiro, Madrid", .activity),
        ("Mercado de San Miguel", "Centro, Madrid", .food),
        ("Retiro Park", "Retiro, Madrid", .activity),
        ("Botín — world's oldest restaurant", "Centro, Madrid", .food)
    ]

    private static func fillerItems(
        tripId: UUID, tripStartDay: DayDate, userId: UUID, now: Date, lisbonTz: TimeZone, madridTz: TimeZone
    ) -> [ItineraryItem] {
        // dayOffset from trip start (day 0 = May 14); Madrid days (7, 8) use
        // Europe/Madrid, everything else Europe/Lisbon — matching the
        // Madrid side trip's own dates above. Per-day hour lists (rather
        // than one fixed [9, 13, 19] for every day) so a travel day's
        // filler doesn't overlap a flight that hasn't landed yet: day 0's
        // single item sits after the evening arrival, and day 7's two
        // items sit after the ~11:40 Madrid landing.
        let schedule: [(dayOffset: Int, count: Int, hours: [Int])] = [
            (0, 1, [21]),
            (1, 3, [9, 13, 19]), (2, 3, [9, 13, 19]), (3, 3, [9, 13, 19]),
            (4, 3, [9, 13, 19]), (5, 3, [9, 13, 19]), (6, 3, [9, 13, 19]),
            (7, 2, [14, 20]),
            (9, 3, [9, 13, 19]), (10, 3, [9, 13, 19]), (11, 3, [9, 13, 19]), (12, 3, [9, 13, 19]),
            (13, 1, [9])
        ]
        var items: [ItineraryItem] = []
        var poolIndex = 0

        for (dayOffset, count, hours) in schedule {
            let madridDay = dayOffset == 7 || dayOffset == 8
            let tz = madridDay ? madridTz : lisbonTz
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = tz

            for slot in 0..<count {
                let place = samplePlaces[poolIndex % samplePlaces.count]
                let hour = hours[slot % hours.count]
                let startsAt = dateAt(daysAfter: dayOffset, hour: hour, minute: 0, calendar: calendar, tripStartDay: tripStartDay)

                var details = ItemDetails.empty
                var confirmation: String?
                if place.category == .activity {
                    details.address = place.location
                    // Roughly half of activities carry a ticket reference —
                    // exercises "with/without confirmations" in the seed.
                    if poolIndex.isMultiple(of: 2) {
                        let ref = "TKT-\(1000 + poolIndex)"
                        details.ticketRef = ref
                        confirmation = ref
                    }
                } else {
                    details.address = place.location
                    details.partySize = 4
                    details.reservationName = "Naveen"
                    // Food never carries a confirmation code (matches
                    // AddItemSheet's own food form, which has no
                    // confirmation field).
                }

                items.append(makeItem(
                    tripId: tripId, category: place.category, title: place.title,
                    startsAt: startsAt, endsAt: nil, tz: tz.identifier, locationName: place.location,
                    confirmation: confirmation, details: details, userId: userId, now: now
                ))
                poolIndex += 1
            }
        }
        return items
    }

    /// EI-2 (`docs/EMAIL_IMPORT_PLAN.md`) verify-drill only: seeds one
    /// `status: .suggested` item on an *existing* trip so the review
    /// banner/inbox/confirm/dismiss flow can be exercised end-to-end in the
    /// simulator — nothing writes `'suggested'` for real until EI-1's
    /// `ingest-email` edge function ships. Mirrors `seed(...)`'s own
    /// "same write path as any other mutation" rule (SwiftData insert, then
    /// `SyncEngine.enqueue`), so this also exercises the confirm flow's real
    /// outbox push, not just local state. Returns the new item's id, or
    /// `nil` if there's no signed-in user to attribute it to.
    @discardableResult
    @MainActor
    static func seedSuggestedItem(
        tripId: UUID, modelContext: ModelContext, syncEngine: SyncEngine?, authManager: AuthManager
    ) async -> UUID? {
        guard let userId = authManager.userId else { return nil }
        let now = Date()
        var details = ItemDetails.empty
        details.airline = "Skyline Air"
        details.flightNo = "SK 204"
        details.fromIATA = "JFK"
        details.toIATA = "LIS"
        let item = ItineraryItem(
            id: UUID(), tripId: tripId, categoryRaw: ItemCategory.flight.rawValue, title: "Skyline Air SK 204",
            startsAt: now.addingTimeInterval(3 * 24 * 3600), endsAt: now.addingTimeInterval(3 * 24 * 3600 + 8 * 3600),
            tz: TimeZone.current.identifier, locationName: "JFK",
            locationLat: nil, locationLng: nil, confirmation: "SKY204X", notes: nil,
            detailsJSON: "{}", statusRaw: ItemStatus.suggested.rawValue, createdBy: userId,
            createdAt: now, updatedAt: now, updatedBy: nil
        )
        item.details = details
        modelContext.insert(item)
        do {
            try modelContext.save()
        } catch {
            return nil
        }
        let dto = item.toDTO()
        let rowId = item.id
        await syncEngine?.enqueueUpsert(table: .itineraryItems, rowId: rowId, tripId: tripId, payload: dto)
        return rowId
    }

    // MARK: - Helpers

    private static func makeItem(
        tripId: UUID, category: ItemCategory, title: String, startsAt: Date, endsAt: Date?, tz: String,
        locationName: String, confirmation: String?, details: ItemDetails, userId: UUID, now: Date
    ) -> ItineraryItem {
        let item = ItineraryItem(
            id: UUID(), tripId: tripId, categoryRaw: category.rawValue, title: title,
            startsAt: startsAt, endsAt: endsAt, tz: tz, locationName: locationName,
            locationLat: nil, locationLng: nil, confirmation: confirmation, notes: nil,
            detailsJSON: "{}", statusRaw: ItemStatus.confirmed.rawValue, createdBy: userId,
            createdAt: now, updatedAt: now, updatedBy: nil
        )
        item.details = details
        return item
    }

    private static func instant(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, calendar: Calendar) -> Date {
        var components = DateComponents()
        components.year = year; components.month = month; components.day = day
        components.hour = hour; components.minute = minute
        return calendar.date(from: components) ?? .now
    }

    private static func dateAt(daysAfter dayOffset: Int, hour: Int, minute: Int, calendar: Calendar, tripStartDay: DayDate) -> Date {
        let base = tripStartDay.asDate(calendar: calendar)
        let shifted = calendar.date(byAdding: .day, value: dayOffset, to: base) ?? base
        var components = calendar.dateComponents([.year, .month, .day], from: shifted)
        components.hour = hour
        components.minute = minute
        return calendar.date(from: components) ?? shifted
    }
}
#endif
