# Tripto — App Store Connect Privacy Disclosure

Reference for owner: what to enter in App Store Connect → "App Privacy" section
(the privacy nutrition labels).

## Overview

Tripto collects minimal data, shares it only with invited trip members and
public-link viewers (sanitized), and uses no tracking, analytics, or ads SDKs.
One feature — import (paste or email) — involves third-party processing for
booking extraction.

---

## Data & Privacy: Questions to Answer in App Store Connect

(Copy the relevant bullet points below into App Store Connect's data-collection
form.)

### Does your app collect user data?

**YES.** The following data types are collected and linked to the user's account:

- **Contact Information:**
  - Email address (from Sign in with Apple; may be an Apple private-relay
    address you can revoke).
  - Name (from Sign in with Apple).
  - **Purpose:** Account creation, identification to trip members, invites.
  - **Tracking:** No. **Deletion:** User can delete account in Settings.

- **User Content:**
  - Trip data (itinerary, items: flights, stays, activities with locations,
    confirmation codes, notes, packing lists, trip-member profiles).
  - **Purpose:** App functionality; stored in user's account and synced across
    devices. Shared only with invited trip members (role-based access) and —
    for public share links — a sanitized subset (dates, places, times only; no
    codes, notes, emails, coordinates).
  - **Tracking:** No. **Deletion:** Deleted when user deletes the account.

### Does your app use third-party services or sub-processors for any of the data above?

**YES, for the import feature only.** When a user chooses to import trip details
via paste or email:

- Booking text (including confirmation codes and personal names) is sent to a
  **third-party LLM provider (currently OpenAI)** through **Cloudflare AI
  Gateway** to extract structured booking information. The provider is set by
  the `LLM_MODEL` env var — if you switch providers, update this disclosure.
- **Not automatic:** user must explicitly tap "Import."
- **Not for training:** OpenAI API data is not used to train or improve models
  (per OpenAI's data-usage terms). Reconfirm if the provider changes.
- **No raw storage:** extracted booking details are stored; raw import text is
  not.
- **Request logging disabled:** Cloudflare gateway logs are disabled for this
  endpoint.

### Does your app engage in tracking across other apps or websites?

**NO.** Tripto does not collect advertising identifiers, device identifiers, or
user identifiers for tracking purposes. `NSPrivacyTracking = false` in the app's
privacy manifest.

### Does your app use any required-reason APIs?

**YES:** `NSUserDefaults` to store app-local preferences (last-used time zones,
import-feature tap count). Reason: CA92.1 ("Access info from the app itself").

---

## Checkboxes & Declarations

When completing App Store Connect's form:

- ✅ "App does NOT collect any user data"? **NO** (uncheck).
- ✅ "User data is collected"? **YES** (check).
  - Data types: Email Address, Name, **Other User Content** (booking text &
    trip details).
  - Purpose: App Functionality.
  - Linked to account: Yes.
  - Tracking: No.
- ✅ "Third parties have access to user data"? **YES** (check).
  - Sub-processors: the LLM provider (currently OpenAI), Cloudflare (AI Gateway).
  - Data type: User Content (booking text for import extraction only).
  - Purpose: App Functionality (import feature).
- ✅ "App tracks users across other apps/websites"? **NO** (uncheck).

---

## In-App Disclosure

The import feature displays a one-line notice at the paste point:

> _"Pasted text is sent to an AI service to find your bookings — codes and notes aren't retained beyond that."_

(An expanded version in settings or a help screen can point to the full privacy
policy.)

---

## Notes for Review

**App Review notes (if asked):** Tripto uses AI only to extract booking
information when the user chooses to import; no data is retained after
extraction, and the API does not train on the data.

---

## Links

- **Privacy Policy:** https://tripto.navbytes.io/privacy
- **Support/Contact:** tripto@navbytes.io
- **Data Deletion:** Settings → Delete Account (permanent, immediate).
