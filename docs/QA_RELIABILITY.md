# QA reliability release

This release fixes business onboarding after Google sign-in, retry-safe customer orders,
payment state regression, durable refund recovery, kitchen sound and sync feedback,
restaurant-local report dates, report pagination/error handling, CSV formulas, token
persistence errors, and offline cache behavior.

## Verification

- `node --test tests/*.test.mjs` includes executable behavior tests, not just source assertions.
- `supabase/tests/qa_reliability.sql` runs inside a transaction and must be rolled back.
  It checks real database functions with disposable fixtures, self/other account isolation,
  request deduplication, payment ordering, refund retries and report day boundaries.
- Apply the timestamped QA migration before deploying the changed Edge Functions/frontend.
- Deploy all seven Edge Functions, preserving their existing `verify_jwt` settings.

## Recovery operations

A refund intent is saved before calling Mercado Pago. If the network or database fails,
retry the same cancellation action. The endpoint checks provider state and uses the same
idempotency key. The webhook can finish the pending operation too. Payment state,
cancellation and delivery event commit in one database transaction. Orders with a pending
refund cannot advance delivery/preparation. Provider-pending refunds are not reported as
completed. Refund operations are private and are accessible only to the service role.

Customer retry IDs are stored before creating an order and are deduplicated under a
Postgres transaction lock. If a checkout request fails, retrying the same cart reuses the
order. A confirmed checkout preference is reused rather than requested again.

## Intentional public views

`public_qr_restaurants`, `public_qr_products` and `public_restaurants` intentionally expose
fixed public projections while keeping private profile rows protected. Do not switch them
to invoker mode and broadly allow profile SELECT: authenticated users have broader table
column grants, so that would expose private profile columns. Their Supabase advisor
warnings need to be interpreted against the explicit projections, not blindly suppressed.
Anonymous execution of privileged internal trigger functions is revoked by this release.

## Remaining acceptance checks

Automated tests do not replace Google OAuth sign-in on real accounts, Mercado Pago sandbox
charges/refunds, OneSignal delivery, physical printers, mobile device checks or load tests.
No real charge or refund was generated during automated verification. An end-to-end
production certification requires those acceptance checks with configured service accounts.
