# Pickup names and navigation

POS pickup orders require a trimmed name of 1–80 characters. The current RPC accepts
p_customer_name and validates it server-side. The seven-argument internal helper is no
longer callable by authenticated clients. Existing unnamed orders remain readable.
Names are shown in kitchen, cashier, printout and ready-ticket cards; splitting preserves
the name. Cashier transfers to pickup require a name and use the four-argument RPC.

The POS submission guard starts before asynchronous shift checks. Failure restores the
button and keeps the cart; confirmed success clears the cart to avoid another submission.
This prevents double-click duplicates, but does not provide server-side idempotency after
an ambiguous network disconnect. In that case staff must check accounts before retrying.

Back anchors share a handler: same-origin history is used when available, otherwise
an explicit in-app fallback is used. Admin returns to its actual previous page. Customer
root tabs no longer show a redundant back arrow; personal orders return to Account.
The selected customer section is stored in the URL so a round trip restores the section.

Validation: Node suite covers navigation and submission behavior; transactional SQL
covers missing/long names, persistence, kitchen output, splits, transfers, availability,
permissions and shared table accounts. Existing role/access tests remain in the suite.
Real authenticated device testing for every role is still required before acceptance;
this change is not a guarantee of zero defects or an exhaustive review of every screen.
