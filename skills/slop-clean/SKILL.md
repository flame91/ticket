---
name: slop-clean
description: AI-generated code-smell detection criteria. Use when removing AI artifacts from changed files. Triggers on /flow:slop-clean and any "remove AI slop / clean up AI artifacts" request.
---

# Slop-clean

Detection rulebook for the `flow:slop-cleaner` subagent. Each invocation processes **exactly one file**. When in doubt, **skip** — false negatives (left-in slop) are cheap; false positives (removed real logic) are not.

## Detection categories

### 1. Useless comments

**Remove**:
- Comments that restate the code: `count += 1  # increment count`
- Trivial docstrings: `"""Returns the user."""` on `def get_user(self): return self._user`
- Section dividers: `# ===== HELPERS =====`, `// ---- types ----`
- Commented-out code blocks (without an explicit "kept on purpose" rationale on the same line)
- TODOs without a concrete plan: `# TODO: improve later`, `// TODO: refactor`
- Vague "important" callouts: `# Note: this matters` with no follow-up reason

**Keep**:
- Comments explaining **why** (business rule, edge case, workaround, gotcha)
- Issue / ticket references: `# See OTH202405-123`, `// gh#456`
- Non-obvious algorithm or regex explanations
- Comments matching an established style already used in the file
- Type-only comments required by tooling (e.g. `// @ts-expect-error <reason>`)

### 2. Over-defensive code

**Remove**:
- Null / undefined guards on values that the static type already guarantees
- `try` / `catch` (or `try` / `except`) wrapping code that cannot throw at runtime (literal accesses, pure arithmetic, statically-typed returns)
- `isinstance` / `typeof` checks for parameters whose type is already pinned by the signature
- Unused backward-compat shims (`const _oldName = newName` with no callers, `# deprecated, kept for compat`)
- "Removed" / "deleted" comments standing in for absent code
- Re-exports of unused items
- Obviously duplicated tests, redundant assertions on the same property

**Keep**:
- Validation at system boundaries (HTTP request payloads, external API responses, parsed user input, env vars)
- Error handling for I/O, network, filesystem, subprocess, DB calls
- Null checks on nullable DB columns or ORM-loaded relations
- Defensive parsing where upstream data is known to be inconsistent (call out the upstream in the kept comment)

### 3. Excessive nesting

**Refactor**:
- Two-or-more levels of `if` nesting → guard clauses / early returns
  ```ts
  // before
  if (user) { if (user.id) { return fetch(user.id); } }
  // after
  if (!user?.id) return;
  return fetch(user.id);
  ```
- Nested loops with conditionals → extract to a helper or a comprehension where idiomatic
- Deep ternaries (`a ? b : c ? d : e`) → explicit if/else or a lookup table

### 4. Always exclude (do not flag as slop)

- BDD test markers: `// #given`, `# given`, `# when`, `# then`
- Issue / ticket / PR links inside comments
- License / copyright headers
- Generated-file banners (`// AUTO-GENERATED — DO NOT EDIT`)
- Translation / localization key tables — they look repetitive but are intentional

## Project-specific rules (aesthetic-clinic)

These come from the project `AGENTS.md`. Any change that would violate one of them is **not slop removal** — stop and report it as an out-of-scope finding instead of editing.

- **i18n**: never inline a user-facing string. If you find a string literal that should be a translation key, do **not** delete the string — leave it and report it as an i18n violation.
- **Color tokens**: never replace a Tailwind class that maps to a CSS variable (e.g. `text-gray-900`) with a hex literal or vice versa. Treat both directions as out-of-scope.
- **Module boundaries**: a feature module importing logic / components from another feature module is a structural defect, not slop. Do not "clean it up" with a quick rename — report and stop.
- **Type safety**: type hints / TypeScript types stay. Removing `: string` "because it's redundant" is forbidden. Same for explicit React prop interfaces.
- **Server-first**: do not collapse a server component into a client component (or vice versa) under the name of "simpler". Component placement is intentional.

## Process for a single file

1. **Read** the entire file once before editing. Note the language, framework, and any in-file conventions (comment style, import order, naming).
2. **Scan** for the four detection categories above. Build a candidate list with line numbers and category.
3. **For each candidate, ask three questions**:
   - Does removing this change runtime behaviour for any input?
   - Would removing it break a test that exists or might exist?
   - Is this idiom intentional in this codebase even though it looks like slop elsewhere?
   - **If any answer is "maybe" — skip and record the reason.**
4. **Edit** with the Edit tool. One logical change per edit. Do not bundle unrelated cleanups.
5. **Report** in the output format below. Skipped candidates are first-class output, not noise — they tell the reviewer what you saw and chose not to touch.

## Output format

Return **English** markdown to the orchestrator:

```
## slop-clean: <relative file path>

### Summary
- Candidates found: N
- Removed: M
- Skipped (safety): K
- Out-of-scope findings: Z

### Removed
1. [<category>] L<line>–<line>
   Before: <one-line excerpt>
   After:  <one-line excerpt>
   Why slop: <one sentence>
   Why safe: <one sentence>

### Skipped
1. L<line> — <reason for not touching>

### Out-of-scope findings (no edit applied)
1. L<line> — <i18n / color-token / module-boundary / type-safety violation>: <description>
```

If the file is clean, output:

```
## slop-clean: <relative file path>

### Result
No slop detected. <Optional one-sentence justification.>
```

## Hard rules

- **One file per invocation.** If multiple paths arrive in the prompt, refuse and tell the caller to dispatch one agent per file.
- Never run `git add`, `git commit`, `git push`, or any test / build / lint script. Editing only.
- Never modify files outside the path the caller named.
- Never alter public API signatures, exported names, or React component prop types.
- Never remove `// @ts-expect-error`, `// eslint-disable-*`, `# noqa`, or similar directives — those carry intent.
- If the file is generated (header banner, `dist/`, `build/`, `.next/`, lockfiles, snapshots), refuse and report it as out of scope.

---

NOTICE: Detection categories were inspired by oh-my-openagent's `ai-slop-remover` skill (https://github.com/code-yeongyu/oh-my-openagent), licensed under SUL-1.0. This file is a clean-room reformulation written for the `flow` plugin's conventions and the aesthetic-clinic project's rules; no source text is copied verbatim.
