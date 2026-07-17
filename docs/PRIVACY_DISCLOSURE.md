# Tripto — App Store Connect Privacy Disclosure

Reference for owner: what to enter in App Store Connect → "App Privacy" section
(the privacy nutrition labels).

## Overview

Tripto collects minimal data. Trip data (notes, confirmation codes, etc.) is
visible only to invited trip members, and public-link viewers see a sanitized
subset. Profile and trip-cover **photos** are the one exception: they live in
a public-read storage bucket at an unguessable address, so anyone holding
that exact URL could view the image even without being a trip member. Photos
are collected only when users explicitly pick or upload them (via system
photo picker or Pexels search); the app performs no library scan, and the
photo picker runs out-of-process requiring no explicit photo-library
permission. Tripto uses no tracking, analytics, or ads SDKs. One feature —
import (paste or email) — involves third-party processing for booking extraction.

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
  - **Photos:** profile avatar photos and trip-cover photos.
    - **Collection:** Only photos the user explicitly picks or uploads. No
      library scanning or enumeration occurs. Avatar photos are selected via
      the system PhotosPicker (runs out-of-process; requires no photo-library
      permission prompt). Trip covers are selected either via PhotosPicker or
      by searching Pexels (proxied through a backend edge function; search
      queries are not logged or stored beyond the edge function's own error
      handling).
    - **Processing:** All photos are downsampled on-device to ~1600px before
      upload, reducing size and protecting privacy by discarding metadata
      (Exif, etc.).
    - **Storage:** Stored in Supabase Storage buckets (`avatars` and `trip-covers`,
      public-read, owner-folder write RLS). Photos live at unguessable URLs
      generated server-side; access control is enforced by RLS on the database
      rows that reference them, not the URLs themselves. Anyone holding an
      image's exact URL can view it without authentication.
  - **Purpose:** App functionality (user profile, trip cover imagery); stored in
    user's account and synced across devices. Trip data (notes, codes, etc.) is
    shared only with invited trip members (role-based access) and — for public
    share links — a sanitized subset (dates, places, times only; no codes,
    notes, emails, coordinates). **Photos are the exception:** they are stored
    at public-read URLs, so anyone holding the exact URL can view the image
    without being a trip member or signing in.
  - **Tracking:** No. **Deletion:** Photos are deleted immediately when the user
    removes them from a profile or trip. Account deletion also purges the user's
    entire photo storage folder (not just database rows). Orphaned objects from
    replaced photos are cleaned up via the account-deletion path.

### Does your app use third-party services or sub-processors for any of the data above?

**YES, for two optional features: remote import and Pexels photo search.**

#### When searching for trip covers via Pexels:

**Optional feature:** users may search the Pexels photo library when choosing a trip cover image. The Pexels API key is server-side only and never enters the app. Search queries are sent to a **Tripto backend edge function (`search-covers`)** which proxies the request to **Pexels** and returns results.

**All paths:**
- **Not automatic:** user must explicitly tap "Search photos" in the trip cover picker.
- **No local logging:** search queries are not logged locally in the app.
- **Edge function logging:** the `search-covers` function logs only error conditions (e.g., Pexels API failures, rate limit status codes) for debugging. Queries themselves are not retained. See `~/repos/backend/projects/tripto/functions/search-covers/` for full logging detail.
- **Photo download:** when a search result is selected, the Pexels image is downloaded, downsampled on-device (no metadata retention), and uploaded to Tripto's own `trip-covers` Supabase Storage bucket. The image then belongs entirely to the user's account, and the Pexels original is no longer accessed.
- **Attribution:** Pexels requires credit to photographers. Tripto displays "Photos provided by Pexels" as a header link in the search sheet and credits each photographer by name on the result card. Credit details are stored alongside the chosen photo for later reference (trip info page) but are optional to display on the final cover image itself.

#### When pasting or importing emails for bookings:

When a user chooses to import trip details via paste:

**On supported iPhones (iOS 26+ with Apple Intelligence enabled):** users choose
where processing happens. The default is on-device: import extraction runs
entirely on the device using Apple's built-in language model. Pasted text never
leaves the iPhone, is not sent to any third party, and is not stored anywhere
after extraction. Users can optionally switch to cloud processing via an in-sheet
picker.

**On other devices, or if the user chooses cloud processing:** booking text
(including confirmation codes and personal names) is sent to a **third-party
LLM provider (currently OpenAI)** through **Cloudflare AI Gateway** to extract
structured booking information. The provider is set by the `LLM_MODEL` env var
— if you switch providers, update this disclosure. On devices without Apple
Intelligence, cloud processing is used automatically with no choice offered.

**All paths:**
- **Not automatic:** user must explicitly tap "Import" (or choose to paste).
- **Consent-gated:** before the first cloud send via any route, a dialog
  discloses third-party processing (on-device path requires no consent).
- **Not for training:** OpenAI API data is not used to train or improve models
  (per OpenAI's data-usage terms). Reconfirm if the provider changes. On-device
  processing uses Apple's first-party model and is not used for training.
- **No long-term raw storage:** extracted booking details are stored; raw import text is not retained beyond extraction.
- **Request logging disabled:** Cloudflare gateway logs are disabled for this
  endpoint (remote path only).
- **No new data recipients:** the choice between on-device and cloud processing
  does not change data types collected or shared — only the processor and path.

### When email import is enabled: Does your app process forwarded emails?

**YES, when email-import address is revealed.** User must explicitly consent
to email processing before the import address is shown. Forwarded emails are
sent to a **third-party LLM provider (currently OpenAI)** through **Cloudflare
AI Gateway** (with logs disabled) for booking-extraction. The provider is set
by the `LLM_MODEL` env var.

**Email handling:**
- **Consent-gated:** address reveal requires affirmative tap on a dialog
  disclosing "third-party AI service," "Cloudflare gateway," "raw email kept
  7 days, then deleted," and "codes stay private to trip members"
  (ImportAddressCard.swift).
- **Raw email retention:** raw_text and raw_html are purged via pg_cron after
  6 days (≤7d guarantee); metadata (subject, timestamp, status) persists for
  audit.
- **Extracted data:** booking details (flight numbers, hotel names, dates,
  confirmation codes parsed from raw text) are stored on the user's trip.
- **Not for training:** OpenAI API terms apply; reconfirm if provider changes.
- **Account deletion:** delete-account scrubs raw_text, raw_html, AND
  parsed_json from email_imports rows (backend PR #7).

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
    trip details), **Photos or Videos** (profile avatar photos & trip-cover
    photos, selected via system picker or Pexels search; no library scan).
  - Purpose: App Functionality.
  - Linked to account: Yes.
  - Tracking: No.
- ✅ "Third parties have access to user data"? **YES** (check).
  - Sub-processors: the LLM provider (currently OpenAI), Cloudflare (AI Gateway),
    and Pexels (during optional cover photo search only).
  - Data types & scope:
    - **LLM provider & Cloudflare:** booking text (paste + email import extraction only).
    - **Pexels:** search queries only (received during the photo search, not the selection or storage phase).
  - Purpose: App Functionality (import features and optional photo search). Email-import
    requires explicit consent before use; Pexels search is optional and implicit
    (user initiates the search).
- ✅ "App tracks users across other apps/websites"? **NO** (uncheck).

---

## In-App Disclosure

The import feature displays context-dependent notices at the paste point,
driven by the active processing route:

**On-device processing (default on supported iPhones with Apple Intelligence):**
> _"Processed on this iPhone — text never leaves your device."_

**Cloud processing (user-selected on supported devices, or automatic on others):**
> _"Pasted text is sent to an AI service to find your bookings — codes and notes aren't retained beyond that."_

**When the text is too long for on-device processing:**
> _"Too long to process on this iPhone — will use the AI service."_

(An expanded version in settings, shown to all users, covers both paths:
"On supported iPhones you choose where processing happens — on-device by
default (never leaves), or cloud AI (via Cloudflare) if you prefer; other
iPhones always use the cloud. It isn't stored in your account afterward,
and we ask permission before the first cloud send.")

---

## Notes for Review

**App Review notes (if asked):** Tripto uses AI only to extract booking
information when the user chooses to import; no data is retained after
extraction, and the API does not train on the data.

---

## Links

- **Privacy Policy:** https://tripto.navbytes.io/privacy
- **Support/Contact:** tripto@navbytes.io
- **Data Deletion:** Settings → Delete Account (permanent, immediate; also
  purges the user's avatar/cover photo storage folders, backend PR #14).
