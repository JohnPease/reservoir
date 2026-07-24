---
name: ship-story
description: Take a beads story from refinement through a merged-ready PR — orchestrator refines it (product + engineering) into a plan, JP approves, orchestrator delegates implementation to subagents, a code-review pass runs and fixes are applied, a PR opens, then JP gets a summary of changes, manual-test items, and any descoped follow-up beads. Use when JP says "ship <story>", "run the full flow on <story>", or names a beads ID and wants it taken end to end. Do NOT use for a quick fix, a one-off question, or anything JP explicitly wants to hand-implement himself.
---

# ship-story

Runs the standard johnpease/reservoir feature pipeline end to end: refine → plan →
approve → implement → review → PR → report. This is the exact flow used for
reservoir-adq.6.4, adq.6.5, and adq.7 — codified so it doesn't need re-explaining
each time.

**Every phase below waits for JP before advancing to the next**, except phases 3-4
(delegate implementation) and 4-5 (code review), which chain automatically once JP
approves the plan in phase 2. Phase 6 (PR) always happens without asking — opening a
PR is not a merge, and JP reviews it there. Never merge or push directly to `main`
without JP saying so separately.

## Inputs

Args are the beads story ID (e.g. `reservoir-loc.1`) or a description if no bead
exists yet. If no bead exists, create one first (`bd create`) before starting phase 1.

**No args given → pick up "what's next" automatically:**
1. Run `bd ready` and `bd list --status=in_progress`.
2. If something is already `in_progress`, that's what's next — resume it (don't
   start a second thing in parallel). Confirm which phase it's actually at (check
   its notes/PR state, don't assume) before deciding where to re-enter the flow.
3. Otherwise, from `bd ready`: prefer a child of an epic that already has other
   closed/in-progress siblings (continuing an epic beats starting a new one) over
   a same-priority standalone item; among remaining candidates, pick the highest
   priority (P1 before P2 before P3); if still tied, pick whichever has been ready
   longest (oldest `created` date).
4. State which story you picked and why in one sentence before starting phase 1 —
   don't silently start work JP didn't explicitly name.

## Phase 1 — Refine (orchestrator, background)

1. `bd show <id>` to load current scope. If the story has open product questions
   already flagged in its notes, read them — don't re-derive from scratch.
2. `bd update <id> --status=in_progress`.
3. Launch the `orchestrator` subagent (`run_in_background: true`) with a prompt that:
   - Gives it the full current bead content (description, notes, dependencies) —
     it has no memory of this conversation.
   - States explicitly: **refinement only, do not write code, do not implement,
     do not modify beads status beyond what's already set, do not commit anything.**
   - Asks it to route to `product-lead` (scope, UX, personal-MVP proportionality —
     push back on scope creep) and `engineer` (technical feasibility, files touched,
     concrete implementation approach) as needed.
   - Tells it to flag genuine open product/scope questions back to you explicitly
     rather than deciding them itself — you'll take those to JP directly.
   - Asks for a report: resolved scope, concrete acceptance criteria, technical
     approach, files likely touched, and any open questions for JP clearly separated.

Do not do independent research in parallel with this agent on the same files —
you'd duplicate its work. Wait for its notification.

## Phase 2 — Present the plan, get approval

When the orchestrator reports back:
- If it surfaced open questions, put them to JP via `AskUserQuestion` (or plain
  text for open-ended ones) before finalizing anything. If JP's answer changes
  the design materially (as opposed to a simple parameter choice), send it back
  to the orchestrator for another refinement pass rather than deciding the
  redesign yourself.
- Once questions are resolved, present the final plan to JP in your own words —
  don't just paste the subagent's report. Summarize scope, technical approach,
  and files touched concisely.
- **Wait for explicit approval before moving to phase 3.** "Sounds good," "yes,"
  "go ahead" — any clear affirmative counts. Silence or a tangential reply does not.

## Phase 3 — Delegate implementation

Resume the *same* orchestrator agent (by name/agentId — it has the full refinement
context already; don't spawn a fresh one) with:
- Explicit confirmation that JP approved, plus any adjustments from phase 2.
- Instructions to hand implementation to `engineer` with the resolved spec.
- Instructions that the orchestrator has authority to decide implementation-level
  details itself (naming, exact copy, file organization, minor UX judgment calls
  within what's specified) — it should not escalate those back to you. Only a
  genuinely new product/scope question that phase 1-2 didn't already resolve
  should come back.
- Once engineer reports done, hand to `tester`: write/run unit + UI tests for the
  new work, and **run the complete existing test suite**, not just new tests —
  confirm no regressions.
- Explicitly: do NOT push, do NOT open a PR, do NOT merge during this phase —
  commit only, once tests pass. That's phase 6's job, and only after phase 4.

## Phase 4 — Code review, fix everything found

Once the orchestrator reports the implementation done and tested, tell it (same
agent, resumed) to now do a full code-review pass on the complete diff before this
is considered ready for a PR:
- It should look for the standard failure classes already seen repeatedly in this
  project: silently dropped triggers/state, stale cross-instance copies of shared
  state, doc comments that overclaim or go stale after a change, missing busy/
  disabled states on new interactive controls, duplicated styling/logic instead of
  reusing an existing shared component, missing test coverage on new
  persistence-mutating methods.
- Tell it explicitly: **fix everything it finds itself** (same as the last several
  stories) rather than just reporting findings — this phase's job is to leave
  nothing outstanding, not to produce a list for JP to triage.
- After fixes, re-run the full test suite once more to confirm nothing broke.
- Only then commit the fixes (still no push/PR/merge yet).

If a finding turns out to require a genuine product decision to fix correctly
(rare, but happened with the goal/account/badge redesign earlier), that's a
phase-1-and-2-style escalation back to you — the orchestrator should not guess at
a product tradeoff mid-review either.

## Phase 5 — Verify before trusting the "done" report

**Do not take the orchestrator's final report at face value.** Independently, in
this main session:
- `git status`, `git log --oneline -3` — confirm a real commit exists with the
  content claimed.
- Rebuild and re-run the full test suite yourself from a clean `DerivedData`
  (`rm -rf ~/Library/Developer/Xcode/DerivedData/Reservoir-*`) — this has caught
  false "pre-existing flakiness" claims before. Confirm the pass/fail counts match
  what was reported.
- Spot-check any specific claim worth doubting (e.g. "this doesn't touch X" —
  grep for it yourself).
- If a subagent's completion notification lands directly on you instead of
  reaching the orchestrator (a known routing gap in this setup — happens
  regularly), relay its content to the orchestrator yourself via `SendMessage`
  rather than assuming the orchestrator already has it.

Only after this independent check passes, proceed to phase 6.

## Phase 6 — Open the PR

- Push the branch (`git push -u origin <branch>`).
- `gh pr create` with a title following this repo's Conventional Commits style and
  a body covering: summary of what shipped, any bugs found/fixed along the way,
  test plan (what's automated vs. what's manual-verification-only and why).
- This step does NOT require asking first — opening a PR is reversible and
  doesn't touch `main`. Pushing to `main` directly or merging always still
  requires JP's explicit go-ahead, separately, later.

## Phase 7 — Report and follow-ups

Give JP a concise summary covering:
- **What changed** — the real shipped scope, in plain terms, not a copy of commit
  messages.
- **What needs manual testing** — anything the automated suite explicitly
  couldn't cover (e.g. a live Plaid Sandbox round-trip) and why it was scoped
  that way.
- **Follow-up beads** — if anything got descoped, deferred, or found-but-not-fixed
  along the way, file it now with `bd create` (linked to the parent story via
  dependency/notes) rather than letting it evaporate. Say what you filed and why.
- The PR link.

Do not merge, push to `main`, or close the parent epic/bead as part of this
skill — that's JP's call, made in a later, separate turn (matching how every
prior story in this project actually shipped).
