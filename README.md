# dev-security-standards

Project-agnostic security rules for multi-tenant SaaS built on **Next.js + Supabase + Vercel + AI/LLM features**.

## What this is

A single `SECURITY.md` that every Claude session can auto-load via a one-line `@` import. It covers:

- Multi-tenant isolation architecture (hard tenant wall vs soft domain wall)
- Non-negotiable NEVER rules — tenant access, RLS, webhooks, HTTP, AI
- Mandatory code patterns — session-derived tenant context, RLS template, SECURITY DEFINER gates, webhook idempotency, audit logging, cross-domain events
- HTTP security headers — CSP, HSTS, cookie flags, CSRF
- Rate limiting — pattern, known serverless limitation, Redis upgrade trigger
- Secret lifecycle — rotation cadence, secrets manager rules
- AI security — prompt injection defense, tool scoping, indirect injection (OWASP LLM02), usage metering
- Data retention & GDPR right to erasure
- Schema migration workflow (commit-before-push rule)
- Verification SQL queries — run after every migration
- Known open items checklist — template to track your own gaps

## How to use in a project

### Option A — Local machine (same machine as this repo)

Add one line to your project's `CLAUDE.md`:

```
@~/Developer/dev-security-standards/SECURITY.md
```

Claude auto-loads the full security contract at the start of every session in that project.

### Option B — Any machine / team repo

Clone this repo to a consistent path:

```bash
git clone https://github.com/jemar07/dev-security-standards.git ~/Developer/dev-security-standards
```

Then in your project's `CLAUDE.md`:

```
@~/Developer/dev-security-standards/SECURITY.md
```

Keep the clone updated with `git pull` when rules change.

### Option C — Codex, Gemini CLI, or any agent without `@` imports

Copy the contents of `SECURITY.md` directly into your `AGENTS.md`, system prompt, or equivalent context file.

## What to customize per project

1. **Rename helpers:** `auth_tenant_id()`, `validate_tenant()` → your actual function names
2. **Fill in the domain boundary table** → your module/schema/table ownership map
3. **Fill in the Known Open Items checklist** → your actual gaps with real triggers
4. **Add project-specific secrets** → to the secret lifecycle section
5. **Add your schema names** → to the verification SQL queries

## Stack assumptions

- **Auth:** Supabase Auth with JWT `app_metadata` claims for tenant context
- **Database:** Supabase / Postgres with RLS
- **Frontend:** Next.js App Router
- **Deployment:** Vercel (serverless — affects rate limiting recommendations)
- **AI:** Anthropic Claude via SDK (adapt AI rules to your provider)
- **Secrets:** Doppler or equivalent secrets manager

If your stack differs, the patterns still apply — adapt the implementation details.

## Relationship to project-specific docs

This repo contains **universal rules** that apply regardless of project. Project-specific security docs (e.g. `MULTI_TENANT_SECURITY.md` in `rama-shared`) extend these rules with project-specific details — specific function names, module names, migration history, known regressions.

Think of this as the base class. Your project's security doc is the subclass.
