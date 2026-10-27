# Favorites, customer navigation and automatic table accounts

The customer menu has exactly three persistent bottom destinations: Inicio, Favoritos,
and Cuenta. Inicio exposes restaurants and existing order/work/driver entrypoints.
Favoritos filters the restaurant catalog to explicitly saved restaurants. Account settings
and account/order actions are accessible from Cuenta. Search works in both restaurant
views. Saving/removing a favorite requires server confirmation; network failures leave
the saved state unchanged. Favorites belong to the signed-in account and survive reloads
and device changes. Restaurant cards use a separate link and accessible favorite button.

The waiter POS opens a table's menu directly. There is no account picker or button to
open another account. The account summary is refreshed on every table selection, and
waiters can see minimal open-account summaries created by other staff. The database
serializes submissions by restaurant/table and reuses the oldest pending account. Kitchen
still receives a separate ticket per round. A closed account cannot be appended to from a
stale screen; after payment, a later sitting can open a new account. Pickup remains separate.

Historical split/duplicate accounts retain their original balances, kitchen tickets and
payments. They are still visible to cashiers; new waiter rounds use the oldest open account.
Cashier-driven account splitting remains available. No historic accounts were merged.

Validation: executable Node behavior tests for the three destinations, favorite updates
and failure recovery, occupied/empty table selection, closed cash shifts and double taps;
transactional SQL tests for favorite ownership/RLS, invalid targets, two-waiter shared
accounts, separate kitchen tickets, stranger denial, closed accounts and new sittings.
Apply the timestamped favorites migration before releasing the frontend. Service worker
v20 refreshes the installed app's HTML/JS/CSS cache.

## Session startup

Access and registration HTML start with `data-auth-pending`, which synchronously hides
all regular content and shows the logo/name splash before session scripts execute.
A valid saved session is checked with Supabase Auth and routed by account/permissions.
New visitors see the access/registration screen only after the check. Existing owners
opening registration go to their dashboard; signed-in customers choosing business
registration get the completion form. Network failures retain the splash and expose a
retry action after a bounded wait. No fixed artificial splash delay is added.
Eight executable startup tests cover initial hiding, delayed verification, missing
sessions, network failure, owner/staff redirects and business completion.
