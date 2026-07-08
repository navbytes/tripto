Swift models are hand-written in M1 against **`shared/types/tripto.ts`**
(backend repo — `~/repos/backend/shared/types/tripto.ts`), read as a schema
reference only, not consumed directly (CLAUDE.md "Client conventions").

`supabase gen types --lang=swift` (RESEARCH_FINDINGS.md #9) is a known CLI
bug as of this milestone — Swift typegen was skipped for that reason, so
this directory's `@Model`/DTO pairs were written by hand against the
TypeScript output instead. If the CLI is fixed later, diff its output
against these types rather than replacing this file wholesale — the
SwiftData `@Model`s carry sync bookkeeping (client-generated UUIDs, enum
raw-string accessors) that a generator wouldn't know to produce.

See `docs/SYNC_DESIGN.md` for the sync architecture these models serve.
