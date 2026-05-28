# ENGINEERING_RULEBOOK.md

> For: Claude Code, OpenAI Codex, Cursor, GitHub Copilot, Gemini CLI — every AI agent on this repo.  
> Stack target: Next.js (App Router) · TypeScript (strict) · Tailwind · Supabase · pnpm · Turborepo  
> Project-agnostic template — adapt placeholder values marked with `<angle-brackets>` to your project.

---

## Load Order — Read These First

1. `ENGINEERING_RULEBOOK.md` (this file)
2. `SECURITY.md` — security rules are non-negotiable and override everything else

---

## Agent Operating Mode

### Verify before asserting
- **NEVER** state a file, function, type, route, or table exists without using a tool to verify it first.
- **NEVER** claim something doesn't exist without running `find <project-root> -name "*keyword*"` first.
- **NEVER** chain reasoning on an unverified first step. If step 1 required a guess, stop and verify.
- Say "I don't know" before guessing. Say "I'm not sure" before speculating. Never fabricate.

### Scope discipline
- Stay within the stated task. **Do not modify files outside the stated scope without explicit approval.**
- Refactoring adjacent code requires approval. A bug fix in `foo.ts` is not a mandate to clean up `bar.ts`.
- One task = one coherent change. No "while I'm here" additions.

### Context discipline
- Read the file before editing it. Never edit based on assumption of what it contains.
- Read `SECURITY.md` before writing any API route, migration, webhook handler, or auth logic.
- Check for existing implementations before proposing new ones.

---

## Stack & Commands

**Package manager:** `pnpm` only — never `npm` or `yarn`

```bash
doppler run -- pnpm dev                              # dev server (secrets injected by Doppler)
pnpm exec vitest run src/.../file.test.ts            # single-file test (fast — use during work)
pnpm test                                            # full suite
pnpm type-check                                      # tsc --noEmit
pnpm lint                                            # eslint
```

**Monorepo layout (adapt to your project):**
- `apps/web` — Next.js app
- `packages/ui` — shared components
- `packages/db` — Supabase client and generated types
- `packages/config` — shared ESLint and TypeScript config

**Secrets:** All secrets live in Doppler — project `<doppler-project-name>`, configs `dev` / `prd`.  
Never create `.env.local` files. Never commit secrets to git.

---

## Architecture Laws

Non-negotiable structural rules. No exceptions without explicit approval.

### Layer separation
- **Business logic** lives in `lib/`. Never in `app/` route handlers or React components.
- **Database access** lives in `packages/db/` or server-only `lib/db/`. Never in components, never client-side for tenant data.
- **Components** receive props and fire events. No Supabase calls, no `fetch()`, no business logic.
- **API routes are thin:** parse input → call `lib/` function → return response. No logic in the handler itself.

### Dependency direction
- `app/` imports from `lib/` and `packages/`. `lib/` imports from `packages/`. `packages/` never imports from `app/` or `lib/`.
- Circular dependencies are a build error. Fix the structure — do not work around it.
- Domain logic never imports directly from infrastructure (Supabase client, HTTP clients) — always through an abstraction.

### Module boundaries
- Never add an unrelated function to an existing module. Create a new one.
- No catch-all `utils.ts` or `helpers.ts` at repo root. Name by domain: `lib/auth/`, `lib/content/`, `lib/billing/`.
- Never import across package boundaries except through each package's `index.ts` barrel export.

### Data model integrity
- Database schema (Supabase generated types) and application domain types are separate. Never return raw DB rows from API endpoints — always map to a typed response schema.
- Migrations are append-only. Never edit an existing migration file. Create a new one.
- Every new table with `org_id` column: RLS enabled + 4 standard policies before shipping. See `SECURITY.md`.

---

## Code Quality Standards

### Size limits — hard caps
| Unit | Limit | Action when exceeded |
|------|------:|----------------------|
| Function | 40 lines | Extract |
| React component | 150 lines | Decompose |
| File | 300 lines | Split by concern |
| Nesting depth | 3 levels | Use guard clauses |

### Naming
- Functions: verb phrases — `getUserProfile()`, not `getProfile()` or `handle()`.
- Booleans: predicates — `isLoading`, `hasError`, `canSubmit`. Never `flag`, `status`, `check`.
- Banned generic names: `data`, `result`, `temp`, `obj`, `thing`, `info`.
- Allowed abbreviations: `ctx`, `req`, `res`, `err`, `id`, `org`, `db`. Nothing else.

### TypeScript
- Strict mode is on. `exactOptionalPropertyTypes: true`. `noUncheckedIndexedAccess: true`.
- **No `any`.** Use `unknown` and narrow with type guards.
- No `@ts-ignore` without a comment explaining the compiler's limitation.
- No type assertions (`as SomeType`) without a comment justifying it.
- Use Zod for runtime validation at all external boundaries. Infer TypeScript types from Zod schemas — never duplicate.

### Error handling
- Validate at system boundaries (API route inputs, webhook payloads, external API responses). Trust internal data.
- Guard clauses at function entry — return early on invalid state. No wrapping the entire function body in `if (valid)`.
- Error messages name the specific value that failed: `Expected amount to be a positive integer, got ${value}` — not `Invalid input`.
- `catch (e) {}` is banned. Caught exceptions must be handled or re-thrown with context added.

### Design
- **YAGNI**: implement only what the current task requires. No speculative abstractions, plugin systems, or "future-proofing."
- **DRY**: before writing any utility, search the codebase. Duplication is a code review blocker.
- **KISS**: the simplest solution that satisfies requirements wins. Clever code is a liability.
- **Single responsibility**: if naming a function or class requires "and", split it.

### Comments
Write no comments by default. The only acceptable comment is a WHY that is not obvious from the code — a hidden constraint, a subtle invariant, a third-party bug workaround. What the code does is not a valid comment subject.

---

## Testing Standards

- Test the **public contract and observable behavior**, not implementation internals. Tests must survive a refactor of internals.
- Run the single-file test command during work. Run `pnpm test` before commit.
- **Every new API route must cover:** happy path · auth failure (401/403) · invalid input (400) · IDOR — request a resource owned by user A while authenticated as user B, expect 403 or 404.
- Coverage theater is not coverage. A test that calls every line but asserts nothing catches nothing.
- AI-generated tests that pin implementation details (verify that a specific internal function was called) are invalid.

---

## Security — Quick Reference

**Read `SECURITY.md` before writing any API route, migration, webhook handler, or auth logic.**

Hard stops (full rules with examples in `SECURITY.md`):
- NEVER accept `orgId` from request body or params — derive from your session helper only
- NEVER write `USING (true)` on a tenant table policy
- NEVER disable RLS on any table
- NEVER return raw DB rows from an API endpoint — map to typed response schemas first
- NEVER use the Supabase anon key to fetch tenant data client-side
- NEVER expose the service role key to the client or prefix it `NEXT_PUBLIC_`
- NEVER write `process.env.SECRET || 'fallback'` — throw on startup if the env var is missing
- NEVER use `fetch(userSuppliedUrl)` without an allowlist check (SSRF vector)
- NEVER use `path.join(base, userInput)` without asserting the resolved path stays within `base`
- NEVER write a webhook handler that doesn't fail closed: `if (!secret) return new Response('', { status: 503 })`
- NEVER hardcode credentials, UUIDs, or secrets in source files, config, or CI pipelines
- NEVER store OAuth tokens, API keys, or PII in plaintext columns — encrypt at the application layer

---

## Anti-Drift & Anti-Slop Rules

These rules exist to prevent the documented failure modes of AI-assisted development: architectural drift, code churn, and pattern fragmentation.

### Pattern consistency
- Before implementing anything, search for the existing pattern. Use it — don't invent a new one.
- One way to do each thing. If two patterns exist for the same concern, flag it before adding a third.
- New architectural patterns require explicit approval.

### Anti-hallucination
- NEVER assert what a function does, what a type looks like, or what a table column is named without reading the source.
- NEVER suggest installing a package without verifying it exists on npm/jsr and checking the current version (do not rely on training memory for versions).
- NEVER describe how something in this codebase works from memory — read it first.

### No theater
- Do not generate tests that exist to satisfy coverage metrics rather than validate behavior.
- No dead code, commented-out code, or `TODO: implement later` stubs.
- No speculative interfaces, abstract base classes, or factory patterns unless ≥ 3 concrete implementations exist today.

### Scope lock
- Do not refactor, rename, or clean up code outside the task scope. Flag it — don't fix it silently.
- Do not add logging, metrics, or observability to files you're editing unless that is the stated task.
- Do not add error handling for scenarios that are impossible given the current data flow and types.

---

## No Hardcoded Data — Ever

One of the most common AI coding failures: stub/demo data ships to production because it looked intentional and passed review.

- **NEVER** hardcode data inline in components, routes, or hooks. Components receive data via props or fetch it via an API/query hook.
- **NEVER** create mock or stub data in production files (`src/`, `app/`, `lib/`). Test fixtures belong in `__tests__/` or `test/fixtures/` only.
- **NEVER** use placeholder strings that belong in a database: no `"John Doe"`, `"example@email.com"`, `"Demo Company"`, `"Lorem ipsum"` in `src/`.
- **NEVER** mix seed data with migration files. Migrations are schema only. Data seeding lives in `supabase/seed.sql`.
- **If real data isn't available yet:** render an empty state + loading skeleton. Hardcoded data is not a valid placeholder — it ships as-is and survives code review because it looks intentional.

```tsx
// ❌ Wrong — ships to production with fake data
const clients = [{ id: 1, name: "Acme Corp" }, { id: 2, name: "Demo Client" }]

// ✅ Correct — empty state until real data loads
const { data: clients, isLoading } = useClients(org_id)
if (isLoading) return <ClientListSkeleton />
if (!clients?.length) return <EmptyState message="No clients yet" />
```

---

## Pre-Commit Checklist

Run through this before every commit that touches components, API routes, database schema, or auth logic:

- [ ] No hardcoded data, placeholder strings, or mock arrays in `src/` files
- [ ] All new functions under 40 lines — extracted if exceeded
- [ ] No business logic in `app/` route handlers or React components
- [ ] No raw DB rows returned from API endpoints — mapped to typed response schemas
- [ ] No new pattern introduced without checking if one already exists
- [ ] Every new API route has: happy path + auth failure + invalid input + IDOR test
- [ ] No secrets, credentials, or UUIDs hardcoded anywhere in staged files
- [ ] RLS enabled + all 4 policies on any new table with `org_id`
- [ ] Session helper (`requireOrg()` or equivalent) called first in every new API route
- [ ] `pnpm type-check` passes — no TypeScript errors
- [ ] `pnpm lint` passes — no lint errors
- [ ] At least one test covers the changed code path

---

## Supabase & Migrations

```bash
cd <project-root>
supabase migration new descriptive_name   # creates timestamped migration file
# edit the file with your SQL
supabase db push                          # apply to dev (<dev-supabase-ref>)

# Push to prod (<prod-supabase-ref>):
supabase link --project-ref <prod-supabase-ref>
supabase db push
supabase link --project-ref <dev-supabase-ref>   # always re-link to dev after
git add supabase/migrations/<file>.sql && git commit
```

**Doppler is per-project.** `doppler run --` injects only the secrets from the project linked in `.doppler.yaml`. No secrets are shared across projects unless explicitly configured with `--project <other>`.

- CLI is always linked to **dev**. Never push to prod without explicitly relinking.
- Read-only queries (`SELECT` via `execute_sql` MCP) are allowed. DDL via MCP is banned.

---

## Permissions

```
✅ AUTO-APPROVED
   Read any file · Run lint / type-check / single-file tests
   Run read-only SQL queries (SELECT via MCP execute_sql)
   Grep / search the codebase
   Edit files within the stated task scope

⚠️ ASK FIRST
   Install or remove a package
   Create a new file outside the stated task scope
   Run the full test suite
   Push to a git remote
   Run supabase db push (dev)
   Add a new architectural pattern to the codebase
   Widen any security boundary (CSP, CORS, RLS policies, cookie flags)

🚫 NEVER WITHOUT EXPLICIT APPROVAL
   Force push any branch
   Drop, truncate, or rename a database table
   Disable RLS on any table, even temporarily
   Run supabase db push against prod without explicitly relinking first
   Commit .env files, secrets, or credentials
   Apply migrations via MCP tools (apply_migration, execute_sql with DDL)
   Delete or edit existing migration files
   Modify SECURITY.md
```
