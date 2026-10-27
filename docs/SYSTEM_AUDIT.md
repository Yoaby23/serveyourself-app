# System consolidation and security review

Implemented:
- One owner feature hub in funciones.html. Legacy admin home URLs redirect there;
  product/settings pages remain linked. Shared navigation avoids duplicate hub links.
- One phone/address editor in the existing personal profile; work Cuenta links to it.
  Saving requires a returned profile row, preventing false success on denied/no-op writes.
- Retired direct public access to seven legacy order/kitchen RPCs. Helpers remain
  callable inside privileged canonical RPCs, preserving ticket and table workflows.
- Removed both table and column UPDATE grants on orders. State transitions must pass
  through authorized RPCs, including inventory checks and kitchen transitions.
- CSP blocks object embeds, external base URLs and framing. This is limited hardening,
  not a complete script CSP: inline scripts and handlers still need a separate migration.
- Six indexes cover restaurant/customer/driver history, open tables, product catalogs
  and employee access. RLS caches statement-constant identity checks.

Validation: Node regression suite; transaction/rollback SQL tests for API permissions,
shared table accounts, favorites, inventory, kitchen scheduling and reliability.
The table test creates both rounds under authenticated privileges, not administrator.

Remaining / limits:
- Leaked-password protection is disabled in Supabase Auth. The available connector
  cannot update Auth settings. Enable it in the project's Authentication settings;
  availability can depend on plan. No billing changes were made.
- Three intentional public projection views use owner privileges. They expose selected
  restaurant/menu fields, not entire private profiles. Do not blindly switch these to
  invoker: private profile RLS would make the public catalog disappear. A future schema
  split can place public business data in separately protected tables.
- Security-definer API warnings remain for the legitimate authorized RPC surface;
  a warning count is not a count of exploitable vulnerabilities.
- Private payment/OAuth/idempotency tables have RLS and no client policies by design.
- Unindexed foreign-key and overlapping-policy advisories outside hot paths remain;
  indexes should follow measured usage, rather than duplicating every possible index.
- No claim of zero vulnerabilities or complete physical-device/payment-provider QA.
