# Tripto — Privacy Policy

_Last updated: 8 July 2026_

This is the source of truth for Tripto's privacy policy. It is served (rendered
to HTML) at **https://tripto.navbytes.io/privacy** by the share Worker, and its
URL is the App Store "Privacy Policy URL." Keep this in sync with the App
Privacy answers in `docs/RELEASE_READINESS.md` §4.

---

Tripto helps families and groups organize trips into one shared itinerary. We
collect as little as possible and never sell your data or track you across other
apps or websites.

## Who we are

Tripto is a personal-scale app operated by navbytes. Contact:
**tripto@navbytes.io**.

## What we collect and why

- **Your account.** When you sign in with Apple, we receive your name and an
  email address (which may be an Apple private-relay address you can revoke at
  any time). We use it only to create your account, identify you to people you
  share trips with, and let invited members recognize you. We never email you
  marketing.
- **Your trip content.** The trips, itinerary items (including any locations,
  confirmation codes, and notes you enter), packing lists, and the profiles you
  add for travel companions — including family members who don't use the app.
  This is stored so your trips sync across your devices and to the people you
  invite. It is protected by row-level security so only trip members can read it.

We do **not** collect analytics, advertising identifiers, or location gathered
from your device's sensors. Location text and coordinates only exist if you type
or pick them for an itinerary item.

## When trip data is shared

- **With people you invite.** Trip members you add (as organizer, companion, or
  viewer) can see that trip's contents, according to their role.
- **Through a share link you create.** If you generate an "anyone-can-view"
  link, anyone with that unguessable link can see a **sanitized** version of the
  itinerary — dates, places, and times only. Confirmation codes, notes, exact
  coordinates, and member emails are **never** included on the public link. You
  can revoke a link at any time, which immediately disables it.

We never share your data with advertisers or data brokers.

## Where it's stored

Trip data is stored in a Supabase (PostgreSQL) database and transmitted over
encrypted HTTPS. Your session is kept securely in the iOS Keychain on your
device, and the app keeps a local copy of your trips so they work offline.

## Deleting your data

You can delete your account from **Settings → Delete account** in the app. This
permanently removes your account and any trips you created, along with their
itinerary and packing content. Trips you were only invited to will simply lose
you as a member. Because we offer Sign in with Apple, deleting your account also
revokes Tripto's Apple sign-in token. Deletion is immediate and cannot be undone.

## Children

Tripto lets you add profiles for children as trip participants, but those
profiles are created and managed by an adult account holder; children do not
have their own accounts, and we do not knowingly collect data directly from
children.

## Changes

If this policy changes materially, we'll update the date above and, where
appropriate, note it in the app.

## Contact

Questions about your data: **tripto@navbytes.io**.
