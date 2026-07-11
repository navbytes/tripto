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

**YES, for the remote import path only.** When a user chooses to import trip
details via paste:

**On supported iPhones (iOS 26+ with Apple Intelligence enabled):** import
extraction runs entirely on the device using Apple's built-in language model.
Pasted text never leaves the iPhone, is not sent to any third party, and is
not stored anywhere after extraction.

**On other devices or if on-device processing is unavailable:** booking text
(including confirmation codes and personal names) is sent to a **third-party
LLM provider (currently OpenAI)** through **Cloudflare AI Gateway** to extract
structured booking information. The provider is set by the `LLM_MODEL` env var
— if you switch providers, update this disclosure.

**Both paths:**
- **Not automatic:** user must explicitly tap "Import."
- **Not for training:** OpenAI API data is not used to train or improve models
  (per OpenAI's data-usage terms). Reconfirm if the provider changes. On-device
  processing uses Apple's first-party model and is not used for training.
- **No long-term raw storage:** extracted booking details are stored; raw import text is not retained beyond extraction.
- **Request logging disabled:** Cloudflare gateway logs are disabled for this
  endpoint (remote path only).

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
    trip details).
  - Purpose: App Functionality.
  - Linked to account: Yes.
  - Tracking: No.
- ✅ "Third parties have access to user data"? **YES** (check).
  - Sub-processors: the LLM provider (currently OpenAI), Cloudflare (AI Gateway).
  - Data type: User Content (booking text for paste + email import extraction only).
  - Purpose: App Functionality (import features). Email-import requires explicit consent before use.
- ✅ "App tracks users across other apps/websites"? **NO** (uncheck).

---

## In-App Disclosure

The import feature displays context-dependent notices at the paste point:

**On supported iPhones with Apple Intelligence enabled:**
> _"Processed on this iPhone — text never leaves your device."_

**On other devices or if on-device processing is unavailable:**
> _"Pasted text is sent to an AI service to find your bookings — codes and notes aren't retained beyond that."_

(An expanded version in settings, shown to all users, covers both paths and
can point to the full privacy policy.)

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
