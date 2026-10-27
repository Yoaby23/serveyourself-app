# Kitchen scheduling, validated preparation estimates and recipe inventory

## Queue decisions

The queue returns already-preparing tickets first. Pending tickets that have the required
recipe ingredients are ordered before blocked ones. Within each group the manual
priority (Urgent, High, Normal, Postponed) is lexicographic, so waiting time can never
cancel an explicit priority. The remaining order is recommended start time, creation
time and ticket ID. Recommended start is target ready time minus estimated preparation.
Pickup deadlines and recent driver-location ETA remain supported; driver ETA is a
straight-line approximation, not a traffic-aware routing guarantee.

Shortage cards expose ingredient name, required/available/short quantity and unit. Their
start action is disabled in the UI and rejected in the database. Untracked products
(without recipes) are explicitly identified instead of claiming complete inventory control.

## Preparation model

Work units sum quantities plus a small distinct-product term. The regression uses
within-peak-group centering to estimate the quantity coefficient jointly with the peak
effect; it does not add the peak effect twice. The last 500 real observations per
restaurant/service bound training cost. At least 10 observations and a chronological
holdout of at least two are required. Holdout error is computed before refitting on the
full recent data. High validation error rejects model use. Supported predictions also
require three observations in that peak group, quantities inside its observed range and
products present in training. Unsupported cases use configured preparation time.

Predictions are bounded to 5–240 minutes. Preparation start freezes the time, source and
validation-error metadata so a later training update does not relabel an older configured
estimate as a learned one. Actual completed times train one sample per ticket. The UI
reports validation error as historical error, never as a confidence interval.

No observations, ingredients, recipes or stocks are fabricated during deployment.
Configured fallback times remain active until real service generates usable observations.

## Inventory guarantees

Recipes require product and ingredient to belong to the same restaurant, enforced by
RLS and a trigger. Stock, minimums and costs must be finite/nonnegative. Ingredient units
cannot silently change with stock/recipes/history. Clients cannot update stock directly;
adjustments reject excessive quantities and incompatible purchase/waste directions.
Adjustments must use at most three decimal places, matching the stock ledger precision.
Opening stock and adjustments have exact movement records. Ingredient deletion by clients
is disabled to preserve historical movements.

Beginning preparation aggregates shared ingredients across products, locks ingredient
rows in stable UUID order and performs guarded deductions. All deductions, movements,
station statuses and ticket changes commit or roll back together. A unique ticket/ingredient
sale key and the deduction flag prevent double consumption. The first station consumes
for the whole ticket; later stations never consume the ingredients again. Order -> ticket
-> station lock ordering serializes kitchen status aggregation. Replenishment automatically
restores recipe-based availability without overriding manually disabled products.

Pending tickets do not reserve stock. Availability at ordering is a snapshot; preparation
rechecks under locks. Competing requests can wait for replenishment, and the queue shows
why. Paid online orders must still be reconciled if stock changed during checkout: they
receive a pending, visibly blocked ticket. Cashier account splitting does not demand or
consume physical ingredients a second time. Cancellations after cooking do not magically
return used ingredients to stock.

## Verification

`node --test tests/*.test.mjs` covers UI shortage blocking, partial recipe tracking,
validation labels, priority preservation and existing application regressions.
`supabase/tests/kitchen_priority_inventory.sql` executes the stock, accounting, cross-tenant,
priority, model accuracy/validation/fallback, multi-station, financial split and payment
reconciliation cases against actual PostgreSQL functions. Run inside a transaction and
roll it back. The existing payment and shared-table SQL suites are also rerun with the
new migration. No real provider charge/refund is executed by these tests.
