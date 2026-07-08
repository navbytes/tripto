import Foundation

// String-backed enums for the columns SYNC_DESIGN calls out as constrained
// sets (role/category/status/tripType/groupKey). Mirrored models store the
// *raw string* (matching the server's `text ... check (... in (...))`
// columns byte for byte) and expose one of these for ergonomic call sites —
// see e.g. `TripMember.role`. Keeping the stored property a plain `String`
// means an unrecognized value from the server never crashes decoding; it
// just falls back through `?? .someDefault` at the call site.

/// `trip_members.role` / `invites.role` (BUILD_PLAN.md §5.1).
enum TripRole: String, Codable, CaseIterable, Sendable {
    case organizer
    case companion
    case viewer
}

/// `trips.trip_type` (BUILD_PLAN.md §3.3, §5.5).
enum TripType: String, Codable, CaseIterable, Sendable {
    case family
    case friends
    case solo
}

/// `itinerary_items.category` (BUILD_PLAN.md §3.3, §6.1 category colors).
enum ItemCategory: String, Codable, CaseIterable, Sendable {
    case flight
    case hotel
    case activity
    case food
}

/// `itinerary_items.status` (BUILD_PLAN.md §5.6 — suggest-without-editing is
/// v1.5, but the column exists from v1 so it's cheap to add later).
enum ItemStatus: String, Codable, CaseIterable, Sendable {
    case suggested
    case confirmed
}

/// `packing_items.group_key` (BUILD_PLAN.md §3.3; named `group_key` not
/// `group` — `group` is a reserved SQL keyword, RESEARCH_FINDINGS defect #3).
enum PackingGroupKey: String, Codable, CaseIterable, Sendable {
    case documents
    case kids
    case shared
    case clothing
    case custom
}

/// `share_links.scope` — only `view` exists in v1.
enum ShareScope: String, Codable, CaseIterable, Sendable {
    case view
}

// MARK: - Sync bookkeeping enums

/// Every server table this app mirrors locally (SYNC_DESIGN.md "Local
/// store"). Raw values are the exact Postgres table names, since they're
/// used verbatim as the PostgREST resource path and as `OutboxOp.table`.
enum SyncTable: String, Codable, CaseIterable, Sendable {
    case profiles
    case trips
    case tripMembers = "trip_members"
    case tripProfiles = "trip_profiles"
    case itineraryItems = "itinerary_items"
    case packingItems = "packing_items"
    case shareLinks = "share_links"
    case invites
    /// M4: composite PK (`item_id`, `profile_id`), no surrogate `id` column
    /// — see `ItemAssignee`'s doc comment for how this app's single-`rowId`
    /// outbox represents that.
    case itemAssignees = "item_assignees"
}

/// `OutboxOp.op` (SYNC_DESIGN.md "Local store").
enum OutboxOpKind: String, Codable, Sendable {
    case upsert
    case delete
}
