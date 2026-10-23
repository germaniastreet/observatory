# CONVENTIONS.md — how we work on Observatory
**Binding for every AI agent and human session.** Product/design constraints live in `Observatory/PROJECT_CONSTRAINTS.md` (that file governs *what* we build; this one governs *how* we work).

## Agents & roles (three-agent split)
- **Claude (Xcode coding assistant)** — writes code. One unit of work per fresh chat.
- **ChatGPT** — independent second-opinion review of plans/proposals before implementation.
- **Hermes** — directs work, maintains PLAN.md/DECISIONS.md, verifies claims against real artifacts (build output, test results, git state). Hermes does not edit code.
- **User (Deee Tee)** — approves every device build/install/test and every commit, explicitly, per action. Git operations go through Xcode's GUI, not Terminal.

## Unit-of-work protocol (the chunking rule)
Long chat threads degrade accuracy and inflate cost. Therefore:
1. **One unit of work = one chat thread.** A unit is one item from PLAN.md's queue (or an explicit user-defined task of similar size). Never batch multiple units into one thread.
2. **Kickoff prompt template** for a new Claude chat:
   > Read PLAN.md, CONVENTIONS.md, and DECISIONS.md in the repo root, then the Status section of Observatory/STABILIZATION_AND_EXPRESSION_PLAN.md. We are working on unit **U\<n\>: \<title\>**. Scope: only the files listed for that unit. Propose your approach before editing; when done, follow the exit protocol.
3. **Scope discipline:** touch only files needed for the unit. No opportunistic refactors, renames, or warning cleanup unless that IS the unit.
4. **Exit protocol** (before the thread is closed):
   - Build + run tests; report real numbers, not "should pass."
   - Update PLAN.md current state + unit queue.
   - Update the STABILIZATION plan's Status line if it shipped a piece, and append to `Observatory/VERSION_HISTORY.txt`.
   - If a settled choice changed or a new one was made, add a DECISIONS.md entry.
   - Summarize for the user: what changed, what's verified, what's unverified, what needs approval (commit/device test).
5. **Handoff, not history:** the next thread inherits facts from files, never from a pasted transcript of the previous chat.

## Direction format legend (how instructions to the owner are written)
The owner does not code; all agent-to-owner directions must use this exact format:
- **Step Label** — bold text opening the step; names the phase, is not itself an action.
- **Your Instruction** — regular text stating the action the owner performs.
- **Paste Cue** — parenthetical or trailing clause ending in a colon that names the destination chat (e.g. "paste this into Claude's chat:"). Every Prompt Block must have one.
- **Prompt Block** — quoted/indented block of pre-written text addressed to an agent. The owner copies it verbatim into the named chat field; never requires the owner to understand or edit it.
Steps with no text to copy have no Prompt Block. Never leave a Prompt Block's destination ambiguous.

## Relay protocol (file-first — no pasting transcripts between agents)
Claude, Hermes, and (via the user) ChatGPT all work off the same repo on disk. **Files are the memory; chat threads are disposable.**
- Claude's approach proposals get written to `PROPOSALS/U<n>-proposal.md` in the repo (create the folder on first use) — not just stated in chat.
- Hermes reads proposals, code, git state, and test output **directly from disk**. The user never pastes Claude's responses into a Hermes chat; instead say "Review Claude's U1 proposal" or "Verify Claude's U1 changes."
- ChatGPT is the only agent that can't read disk — it's the sole case where pasting a file's contents is necessary.
- The only thing that travels as a chat paste: short verdicts/instructions (a few sentences), never transcripts or full logs.
- Hermes chats: one per unit/topic; start new ones freely — PLAN.md plus Hermes's persistent memory carry the context, not the chat history.

## Verification standards
- Docs describe **real code, never aspirational code** (policy from PROJECT_ARCHITECTURE.md).
- Every completion report separates: **measured/tested** vs **integration-tested but not validated** vs **unverified**. Never collapse into a single "works" claim.
- Tests run on simulator unless the unit requires the physical device (device runs need user approval; the physical-device test action currently discovers 0 tests — known issue).
- Absence of evidence is a valid result: "no clear pattern" / "insufficient baseline" / "unsupported" are honest outputs, never failures to paper over.

## Cost & context hygiene (for Claude chats)
- Don't paste whole files or full build logs into chat — reference paths, paste only the relevant region.
- Prefer reading PLAN.md/DECISIONS.md over re-asking questions already settled there.
- If a thread grows very long mid-unit, finish at the next natural boundary, run the exit protocol, and continue in a fresh chat.

## Doc map (read order for a new session)
1. `PLAN.md` — current state, open issues, unit queue
2. `CONVENTIONS.md` — this file
3. `DECISIONS.md` — settled choices, don't re-litigate
4. `Observatory/PROJECT_CONSTRAINTS.md` — binding product/design rules
5. `Observatory/STABILIZATION_AND_EXPRESSION_PLAN.md` — active technical plan (Status section first)
6. Everything else (`README`, `ARCHITECTURE`, `ROADMAP`, `PROJECT_STATUS`, `ONBOARDING`, histories) — reference only; some predate current work and may be stale. PLAN.md wins on "current state."
