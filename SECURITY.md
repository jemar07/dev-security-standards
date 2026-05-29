# Multi-Tenant SaaS — Security Standards

> **Stack this document targets:** Next.js (App Router) · Supabase (Postgres + Auth + RLS) · Vercel · AI/LLM features
>
> **How to use:** Add `@/path/to/this/SECURITY.md` to your project's `CLAUDE.md` so every AI session loads these rules automatically. Adapt the placeholder names (`auth_tenant_id()`, `validate_tenant()`, etc.) to match your own helper names.

---

## Core architecture

Two orthogonal isolation axes for any multi-tenant system:

1. **Tenant isolation — HARD WALL.** Every tenant table has a `tenant_id` (or `org_id`). Every read/write is filtered to one tenant by RLS + application-layer scoping + a validated tenant resolver. Tenant A can NEVER see Tenant B's data.
2. **Module/domain separation — SOFT WALL.** Different domains (billing, inventory, messaging, etc.) live in separate Postgres schemas or table namespaces. Within one tenant's data they can communicate. The tenant wall is the security boundary; the domain wall is for code organization.

The tenant wall is non-negotiable. The domain wall is architectural preference.

---

## NEVER — Non-negotiable rules

### Tenant & data access

- **NEVER** read tenant identity from an environment variable that is broadcast to the client bundle (e.g. `NEXT_PUBLIC_ORG_ID`, `NEXT_PUBLIC_TENANT_ID`). These are permanently deleted from the env contract once a proper session-derived resolver is in place.
- **NEVER** trust a `tenant-id` or `org-id` HTTP header without validating it against the authenticated server session.
- **NEVER** accept `tenantId` from a request body without comparing it to `session.tenantId`.
- **NEVER** hardcode a UUID or string literal as a tenant/org fallback (e.g. `'default-org'`, `'00000000-...'`). There is no safe default tenant.
- **NEVER** auto-provision a tenant in `getSession()`. New tenants arrive via an explicit invite or onboarding flow. If no profile exists for an authenticated user, redirect to onboarding — do not silently create a ghost tenant.
- **NEVER** query a tenant table without scoping to `tenant_id` in application code. RLS is defense-in-depth, not a substitute for app-layer scoping.
- **NEVER** build client-side data-fetching helpers that call the database directly with a low-privilege key — go through a server API route that derives tenant identity from the session.

### RLS & database

- **NEVER** add `USING (true)` to a policy on a tenant table. Always use your `auth_tenant_id()` JWT helper.
- **NEVER** create an INSERT or UPDATE policy without `WITH CHECK`. A policy missing `WITH CHECK` lets authenticated users write to any tenant's rows.
- **NEVER** create a `SECURITY DEFINER` function without:
  - `SET search_path = public, <your_schema>` at definition time — prevents search path injection
  - A tenant membership check as the first executable line — prevents cross-tenant escalation via RPC
- **NEVER** write an internal-only `SECURITY DEFINER` function without revoking `EXECUTE` from `anon`, `authenticated`, and `PUBLIC`. Trigger-only functions should only be callable by `postgres`/`service_role`.
- **NEVER** disable RLS on a tenant table, even temporarily for debugging.
- **NEVER** write directly to another domain's tables from a different domain's code. Use an event bus or RPC for cross-domain side effects.

### Webhooks & secrets

- **NEVER** write a webhook auth guard as `if (secret) { verify() }` — this silently passes when the env var is unset. Always fail closed: `if (!secret) return 503`.
- **NEVER** reuse a rotated secret. Once rotated, the old value is dead at the provider.
- **NEVER** commit a secret to git. NEVER log a secret, even a truncated version.
- **NEVER** add a third-party domain to the CSP speculatively — only add when the integration is live and the exact domain is confirmed.

### HTTP & transport

- **NEVER** ship a CSP that is less restrictive than your current production policy. Only ever tighten it.
- **NEVER** set a session cookie without `Secure`, `HttpOnly`, and `SameSite` flags. Never override the auth provider's default cookie config with weaker flags.
- **NEVER** leave a dev/debug route exposed in production without an explicit env guard as the first line of the handler:
  ```ts
  if (process.env.NODE_ENV !== 'development') return new Response(null, { status: 403 })
  ```

### AI features

- **NEVER** accept `tenantId` as an argument to an AI tool handler — always inject it server-side from the validated session.
- **NEVER** expose memory/state writes as a callable AI tool. Only the AI runtime should write to AI memory. Self-modifying agents are hard-prohibited.
- **NEVER** feed tool result data back to the AI without treating it as untrusted. User-controlled fields (notes, comments, documents) can contain injected instructions. The system prompt directive is the primary guard — never pass tool result content as a `system`-role message.
- **NEVER** run a multi-step AI workflow without enforcing a `max_steps` cap and a `timeout_at` deadline. Unbounded loops are a denial-of-wallet attack.

---

## ALWAYS — Mandatory patterns

### 1. Derive tenant identity from the session — never from headers or body

```ts
// ✅ Correct — server-side, session-derived
export async function GET(request: NextRequest) {
  const session = await getServerSession(request)
  if (!session) return new Response(null, { status: 401 })
  const { tenantId, userId, role } = session
  // use tenantId — never trust request.headers or body for it
}

// ❌ Wrong — trusting caller-supplied tenant
const tenantId = request.headers.get('x-tenant-id')
const tenantId = body.tenantId
```

### 2. New tenant tables — 4 standard RLS policies + WITH CHECK on all writes

```sql
-- Required column
ALTER TABLE my_schema.my_table
  ALTER COLUMN tenant_id SET NOT NULL;

ALTER TABLE my_schema.my_table ENABLE ROW LEVEL SECURITY;

-- Replace auth_tenant_id() with your JWT claim helper
CREATE POLICY tenant_select ON my_schema.my_table
  FOR SELECT TO authenticated
  USING (tenant_id = auth_tenant_id());

CREATE POLICY tenant_insert ON my_schema.my_table
  FOR INSERT TO authenticated
  WITH CHECK (tenant_id = auth_tenant_id());

CREATE POLICY tenant_update ON my_schema.my_table
  FOR UPDATE TO authenticated
  USING      (tenant_id = auth_tenant_id())
  WITH CHECK (tenant_id = auth_tenant_id());

CREATE POLICY tenant_delete ON my_schema.my_table
  FOR DELETE TO authenticated
  USING (tenant_id = auth_tenant_id());
```

`auth_tenant_id()` should read from the JWT `app_metadata` claim — not from a session variable that can be spoofed. Build this helper once; use it everywhere.

### 3. SECURITY DEFINER functions — gate on tenant membership first

```sql
CREATE OR REPLACE FUNCTION public.my_cross_domain_op(
  p_tenant_id uuid,
  -- other args
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, my_schema   -- REQUIRED: prevents search path injection
AS $$
BEGIN
  -- REQUIRED first line: verify auth.uid() belongs to p_tenant_id
  PERFORM public.validate_tenant(p_tenant_id);
  -- rest of function body
END;
$$;
```

`validate_tenant()` must verify that `auth.uid()` is an active member of `p_tenant_id`. Service-role callers bypass this check — that is intentional (trusted boundary).

### 4. Every query scoped to tenant_id

```ts
// ❌ Wrong
const { data } = await supabase.from('orders').select('*')

// ✅ Correct
const { data } = await supabase
  .from('orders')
  .select('*')
  .eq('tenant_id', tenantId)
```

RLS catches what the app misses. Both layers are required. Defense in depth.

### 5. Cross-domain side effects — event bus only

```ts
// ✅ Correct — emit an event; the other domain handles it asynchronously
await emitEvent({
  type: 'order_completed',
  tenant_id: tenantId,
  source_domain: 'pos',
  payload: { order_id: order.id },
  actor_id: userId,
})

// ❌ Wrong — writing directly to another domain's table
await supabase.schema('inventory').from('stock_levels').update(...)
```

Events are immutable and append-only. Cross-domain writes via events only — never direct table access.

### 6. Webhook handlers — idempotency before processing

```ts
// Insert first — if the row already exists, 23505 (unique violation) = already processed
const { error } = await db.from('webhook_events_seen').insert({
  provider: 'stripe',
  event_id: event.id,
})
if (error?.code === '23505') return new Response('ok', { status: 200 })

// Only reach here on first delivery
await processEvent(event)
```

The `webhook_events_seen` table needs `PRIMARY KEY (provider, event_id)`. Rows should be purged after 30 days via a scheduled job.

### 7. Audit log for all sensitive operations

```ts
await logAuditEvent({
  tenant_id: tenantId,
  actor_id: userId,
  action: 'update',           // create | update | delete | access
  entity_type: 'user',
  entity_id: targetUserId,
  old_value: before,          // omit for creates
  new_value: after,           // omit for deletes
})
```

**Operations that must always be logged:** user invites/deactivations, role changes, integration connections/disconnections, plan/entitlement changes, financial record modifications, all AI tool invocations, right-to-erasure executions.

---

## Domain boundary rules

| Rule | Description |
|---|---|
| Reads across domains | Allowed — a domain can read another domain's tables |
| Writes across domains | NEVER — use the event bus |
| Schema per domain | Each domain owns its own Postgres schema (e.g. `billing`, `inventory`, `messaging`) |
| Tenant scoping | Every query in every domain must scope to `tenant_id` |

Fill in your own domain → schema → owned tables map as you build.

---

## HTTP security headers

Set in `next.config.ts` so they apply at the CDN level to every response including static files.

```ts
// Minimum required headers
{ key: 'Strict-Transport-Security', value: 'max-age=63072000; includeSubDomains; preload' },
{ key: 'X-Frame-Options',           value: 'DENY' },
{ key: 'X-Content-Type-Options',    value: 'nosniff' },
{ key: 'Referrer-Policy',           value: 'strict-origin-when-cross-origin' },
{ key: 'Content-Security-Policy',   value: csp },   // see below
{ key: 'Permissions-Policy',        value: 'camera=(), microphone=(), geolocation=(), payment=()' },
```

**CSP notes:**
- Start with `default-src 'self'` and add only what you need.
- `unsafe-inline` is required by Next.js App Router for hydration — this is a known gap. Track it as a known open item and plan a nonce-based CSP replacement.
- `frame-src 'none'` and `frame-ancestors 'none'` — block all iframes. Do not relax unless you have an explicit, reviewed reason.
- `upgrade-insecure-requests` — force HTTPS on all subresource loads.
- Add a `report-uri /api/csp-report` endpoint so you have visibility into violations in production.

**Cookies:**
- Session cookies must be `Secure`, `HttpOnly`, `SameSite=Strict` (or `Lax` minimum). Never downgrade these.

**CSRF:**
- `SameSite=Lax/Strict` provides baseline CSRF protection for browser-initiated requests.
- For mutation API routes called from non-browser contexts, verify the `Origin` header matches your allowed domain.

---

## Rate limiting

**Pattern:** sliding window keyed by `(tenant_id:user_id:endpoint)` for authenticated routes; by IP for unauthenticated routes (login, signup, magic link).

**Apply to:**
- All AI/LLM endpoints — cost drain protection
- Auth routes — brute force protection
- Any endpoint that sends SMS, email, or makes paid outbound API calls

**Critical limitation of in-memory rate limiters:** serverless deployments (Vercel, AWS Lambda) spin up multiple instances. An in-memory window is per-process — the effective limit is `limit × N instances`. This is acceptable for accidental flood protection only.

**Required for production:** use a shared Redis-backed store (Upstash Redis, Vercel KV, or equivalent) keyed by `tenant:user:endpoint`. Treat this as a requirement before multi-tenant production load.

---

## Secret lifecycle

| Secret type | Rotation cadence |
|---|---|
| AI API keys (Anthropic, OpenAI, etc.) | 90 days |
| Database service/admin keys | 6 months, or immediately on suspected exposure |
| Webhook signing secrets | Per-provider recommendation, minimum annually |
| Per-tenant third-party tokens | Stored encrypted at rest; rotated on revocation |

**Rules:**
- Use a secrets manager (Doppler, AWS Secrets Manager, 1Password Secrets Automation) as the source of truth. Never manage secrets in `.env` files committed to git.
- Rotation procedure: update secrets manager → verify deployment picks up new value → test an authenticated request end-to-end → then invalidate the old value at the provider.
- Per-tenant third-party credentials (OAuth tokens, API keys for integrated services) must be stored **encrypted at rest** in the database. Never store them in plaintext columns.

---

## AI security rules

The AI is the most powerful actor in any system that has write tools. The tenant wall applies with extra rules on top:

- **Every AI session must be bound to ONE tenant.** The AI cannot choose its own tenant context — inject it from the validated session.
- **Filter the tool set** by `(user capabilities) ∩ (tenant active features) ∩ (registered tools)`. Never give the AI access to tools the user's role doesn't permit.
- **Validate tool arguments** against a schema before execution. Fail closed on invalid arguments.
- **Audit log every tool invocation** — treat AI actions the same as human actions in the audit trail.
- **Prompt injection defense — two layers:**
  1. A `SECURITY_DIRECTIVE` in the system prompt is the **primary control** — explicitly tells the model its tenant context and rules are immutable and cannot be overridden by user messages.
  2. A regex pre-filter on user input is a **fast secondary check** — not the primary defense. Normalize Unicode (NFD/NFC) before running it to defeat homoglyph injection.
- **Indirect prompt injection (OWASP LLM02):** data returning from tool calls (user notes, comments, imported documents) is user-controlled. Never pass it as a `system`-role message. The system prompt must explicitly tell the model to ignore instructions found in tool result data.
- **Multi-step workflows** must enforce `max_steps` and `timeout_at`. No unbounded agentic loops.
- **Usage metering:** every AI call must track token usage against a per-tenant budget. No metering = no cost cap = no billing visibility.

---

## Data retention & right to erasure

GDPR Art. 17 applies to any EU data subject, regardless of where your company is incorporated.

| Category | Action |
|---|---|
| User PII (name, email, contact info) | Hard-delete on erasure request |
| Audit log entries | Pseudonymize only — replace `actor_id` with a hash, preserve the record |
| Financial transaction records | Never purge — 7-year tax retention minimum |
| Payment card data | Never store — use tokenization (Stripe, etc.) |
| AI/ML training data derived from user content | Must be erasable — design with this in mind |

**Erasure mechanism:** build a `delete_tenant_user(tenant_id, user_id)` function that executes hard-delete + pseudonymize in a single transaction, emits an event, and writes an audit log entry. Gate it to admin role only. Build this before onboarding any EU customer.

**Retention cleanup:** implement scheduled jobs (pg_cron, cron endpoint, etc.) for ephemeral data — webhook deduplication tables, session logs, temp files. Don't let these grow unbounded.

---

## Schema migration workflow

**The commit-before-push rule:**

```bash
# 1. Create the migration file
supabase migration new descriptive_name

# 2. Write your SQL, review it

# 3. Commit the file FIRST
git add supabase/migrations/<file>.sql
git commit -m "migration: descriptive_name"

# 4. THEN push to the database
supabase db push
```

If `db push` runs before `git commit`, a lost terminal session leaves the database ahead of git — silent drift between environments. The file must be in git before the database sees it.

**Never use:**
- The Supabase dashboard SQL editor for schema changes (no file trail)
- `execute_sql` MCP tool with DDL (same problem)
- Direct `psql` DDL against a shared/production database

---

## Verification queries — run after every migration

### Are all tenant tables in a schema properly protected?

```sql
-- Replace 'my_schema' with your schema name. Result must be empty.
WITH expected AS (SELECT 'my_schema' AS schema_name)
SELECT
  c.relname AS table_name,
  bool_or(p.polname = 'tenant_select') AS has_select,
  bool_or(p.polname = 'tenant_insert') AS has_insert,
  bool_or(p.polname = 'tenant_update') AS has_update,
  bool_or(p.polname = 'tenant_delete') AS has_delete
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
JOIN expected e ON e.schema_name = n.nspname
JOIN information_schema.columns col
  ON col.table_schema = n.nspname
  AND col.table_name = c.relname
  AND col.column_name = 'tenant_id'  -- or 'org_id' — match your column name
LEFT JOIN pg_policy p ON p.polrelid = c.oid
WHERE c.relkind = 'r' AND c.relrowsecurity
GROUP BY c.relname
HAVING NOT (
  bool_or(p.polname = 'tenant_select')
  AND bool_or(p.polname = 'tenant_insert')
  AND bool_or(p.polname = 'tenant_update')
  AND bool_or(p.polname = 'tenant_delete')
);
```

### Does my SECURITY DEFINER function have search_path set?

```sql
SELECT
  p.proname,
  CASE WHEN p.proconfig IS NULL THEN '❌ MISSING search_path'
       ELSE '✅ ' || array_to_string(p.proconfig, ', ') END AS status
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.prosecdef = true
  AND p.proname = 'your_function_name';
```

### Are there any policies still using unsafe patterns?

```sql
-- Returns any policy using a deprecated/unsafe pattern.
-- Adapt the nspname list to your schemas.
SELECT
  n.nspname AS schema,
  c.relname AS table_name,
  pol.polname AS policy_name,
  pg_get_expr(pol.polqual, pol.polrelid) AS using_expr
FROM pg_policy pol
JOIN pg_class c ON c.oid = pol.polrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname IN ('public', 'billing', 'inventory')  -- add your schemas
  AND (
    -- Old session variable pattern — should use JWT claim helper instead
    pg_get_expr(pol.polqual, pol.polrelid) ILIKE '%current_setting(%tenant%'
    -- Raw JWT parsing — should use auth_tenant_id() helper instead
    OR pg_get_expr(pol.polqual, pol.polrelid) ~ 'auth\.jwt\(\).*tenant'
    -- Open policy — should never exist on a tenant table
    OR pg_get_expr(pol.polqual, pol.polrelid) = 'true'
  );
```

---

## Known open items checklist

Use this as a template. Copy it into your project's security doc and fill in your own triggers.

| Item | Risk | Trigger to fix |
|---|---|---|
| **Distributed rate limiting** — replace in-memory with Redis | Medium | Before second tenant or AI features go public |
| **Nonce-based CSP** — replace `unsafe-inline` | Medium | Before SOC 2 or pen test |
| **CSP violation reporting endpoint** | Low | Same sprint as nonce-based CSP |
| **RLS regression test harness** — automated tests for tenant isolation | Low initially; High at scale | Before second tenant onboarding |
| **Right-to-erasure function** — `delete_user(tenant_id, user_id)` | Low until EU users | Before first EU customer |
| **AI tool result sanitization** — check data flowing back from tools | Medium | Before AI write tools go to production |
| **Secret rotation runbook** | Medium | Before second team member gets secrets access |
| **Dependency vulnerability scanning in CI** | Low | Next CI pipeline touch |
| **AI workflow `max_steps` + `timeout_at`** | Low until agentic features ship | Before agentic features reach production |

---

## AI Agent Security — OWASP Agentic AI (ASI01–ASI10)

Autonomous coding agents introduce a new attack surface not covered by the standard OWASP Top 10. Key risks active in this stack:

- **ASI01 — Prompt Injection via tool results:** Data returned by tools (DB rows, file contents, API responses) can contain injected instructions. The system prompt must explicitly tell the model to ignore instructions found in tool result data. Never pass tool result content as a `system`-role message.
- **ASI02 — Excessive Agency:** Agents that inherit more permissions than the current task requires. Enforce least-privilege per action — scope DB access to the specific tables the task needs, not the full service role.
- **ASI03 — Unbounded agentic loops:** Multi-step AI workflows without `max_steps` and `timeout_at` caps are a denial-of-wallet attack. Every AI workflow must declare both before production.
- **ASI04 — Slopsquatting (supply chain via hallucination):** LLMs generate `import` statements and `package.json` dependencies for packages that don't exist. Attackers register those names with malicious code. **Before installing any AI-suggested package: `npm view <package-name>` — verify it exists and check the publish date and author.**

### RLS mistakes LLMs make — enforced by semgrep
Three patterns LLMs generate incorrectly, now caught by `.semgrep/rama-rules.yml`:
1. **INSERT policy with `USING` instead of `WITH CHECK`** — silently ignored by Postgres; the policy does nothing
2. **`USING (true)` on a tenant table** — every authenticated user sees every row regardless of `org_id`
3. **`SECURITY DEFINER` without `SET search_path`** — search path injection vulnerability

**Full threat model and pre-commit enforcement:** `~/Developer/rama-os/docs/ai-architecture/SECURITY_ARCHITECTURE.md`
**Code quality gates and Semgrep rules:** `~/Developer/rama-os/docs/ai-architecture/CODE_QUALITY_GATES.md`
