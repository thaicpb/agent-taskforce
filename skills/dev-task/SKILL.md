---
name: dev-task
description: "Orchestrates a multi-agent pipeline for one development task (one or more repositories): take a request (Jira key/link, GitHub issue, or plain description) → investigate & plan (Opus) → HUMAN APPROVES PLAN → implement (Sonnet) → test (Haiku), with Opus diagnosing failures and writing fix instructions → logic review (Opus) → commit and open a PR per repository → HUMAN REVIEWS PR. Use when the user types /dev-task, or says things like 'hand this task to the agent team', 'take this ticket/issue all the way to a PR', 'investigate, code, test and open a PR for ...'. Works for any kind of project (frontend, backend, infra...)."
argument-hint: "<Jira key/link | GitHub issue link | problem description>"
---

# /dev-task — Pipeline: investigate → plan → implement → test → review → PR

You (the main session) are the **orchestrator**. You do NOT investigate deeply and do NOT write the task's code yourself. All specialist work goes to subagents; you only pass data between steps, hold the 2 human checkpoints, and report progress.

| Role | Subagent | Model |
|---|---|---|
| Planning, test-failure diagnosis | `dev-planner` | opus / high |
| Implementation (one call = one repository) | `dev-implementer` | sonnet / medium |
| Running tests (all affected repositories) | `dev-test-runner` | haiku / low |
| Logic review (all repositories at once) | `dev-reviewer` | opus / high |

When installed as a plugin, subagent names may carry the plugin prefix (e.g. `agent-taskforce:dev-planner`). Use the exact names shown in the session's agent list.

Subagents cannot see this conversation and cannot call each other. All information travels through **files in `RUN_DIR`** plus the prompt you write. Every subagent prompt must include `RUN_DIR`, `DOC_LANGUAGE` (see Languages), the absolute path of each relevant repository, and the paths of the files to read.

Loop limits: **at most 3 test-fix rounds** and **at most 2 review-fix rounds**. When a limit is reached → stop, summarize the current state, and ask the human.

**The repository list (`REPOS`)** is the source of truth for every step after Step 3: take it from the table in section `## 0.` (Affected repositories) of `plan.md` (name, absolute path, base branch, test command, order). A single-repository task has a one-row table; the steps below work the same way.

---

## Languages

Each kind of output has its own language:

| Key | Applies to | `auto` means |
|---|---|---|
| `chat` | Every message to the human: progress, questions, summaries, final report | The language the user is chatting in (or the one required by CLAUDE.md) |
| `docs` | Files in `RUN_DIR` (`request.md`, `plan.md`, `test-*.md`, `fix-*.md`, `review-*.md`) and the reports subagents return | Same as `chat` |
| `ticket` | Creating tickets, commenting on tickets/issues | The language of recent tickets in the same project (if readable), otherwise same as `chat` |
| `commit` | Commit messages | The language of recent `git log` in that repository; if undetermined, English |
| `pr` | PR title + description, `gh pr edit` content | The language of recently merged PRs (`gh pr list --state merged -L 5`); if undetermined, same as `commit` |

Values: `auto`, or any language name/code (`en`, `vi`, `ja`, `English`, `日本語`...).

**Precedence** (highest → lowest), resolved per key:
1. The user states it explicitly in the current request (e.g. "write the PR in Japanese")
2. `<repo>/.claude/dev-task.json` of **that repository** — only `commit` and `pr`, only for that repository (each repository may differ)
3. `<WORKSPACE_ROOT>/.claude/dev-task.json`
4. `~/.claude/dev-task/config.json`
5. `auto`

File format (every key is optional; a missing key falls through to the next level):

```json
{
  "language": {
    "chat": "en",
    "docs": "auto",
    "ticket": "ja",
    "commit": "en",
    "pr": "auto"
  }
}
```

A file that is not valid JSON → tell the human in one line (path + error), ignore that file, and continue.

**Never translated** (the orchestrator and agents parse these mechanically): variable names (`RUN_DIR`, `MODE`...), status keywords (`STATUS`, `PASS`, `FAIL`, `BLOCKED`, `VERDICT`, `APPROVE`, `CHANGES_REQUIRED`, `BLOCKER`, `MAJOR`, `MINOR`, `CODE_BUG`...), field names in report blocks, section numbers (`## 0.`, `## 1.`...) and the column order of the `## 0.` table. Section headings may have their words translated but must keep their numbers. Branch names and `TASK_ID` are always ASCII.

---

## Step 0 — Determine the workspace

- `WORKSPACE_ROOT` = the session's current directory.
- `git rev-parse --show-toplevel`:
  - Succeeds → the session is inside one repository; add it to `CANDIDATE_REPOS`.
  - Fails → the session is in a parent directory holding several repositories (e.g. `~/work/my-org`). Do not stop; the planner will identify the repositories.
- `gh auth status` → if not logged in, warn (the PR step will not work).
- Read the language configuration (levels 1, 3, 4, 5 of Languages; level 2 is read in Step 7 once repositories are known) → determine `CHAT_LANGUAGE`, `DOC_LANGUAGE`, `TICKET_LANGUAGE`. From here on, every message to the human uses `CHAT_LANGUAGE`. Tell the human in one line which language each key uses and where it came from (which file / `auto`).

Do not check git state here; each repository is checked in Step 4, once the affected repositories are known.

## Step 1 — Take the request

**Case A: Jira key or link** (e.g. `ABC-123`, `https://xxx.atlassian.net/browse/ABC-123`)
- Fetch the ticket with the Atlassian MCP (`getJiraIssue`; load it via ToolSearch if deferred). Collect summary, description, acceptance criteria, comments, related links.
- No Atlassian MCP in the session → ask the human to paste the ticket content into the chat.
- `TASK_ID` = the ticket key.

**Case A2: GitHub issue link** (e.g. `https://github.com/<owner>/<repo>/issues/123`)
- `gh issue view <url> --comments` to get the title, body, and comments.
- `TASK_ID` = `GH-<repo>-<issue number>`.

**Case B: plain description**
- Restate the request (goal, scope, completion criteria) and ask the human to confirm it was understood correctly.
- If the session has a way to create tickets (Atlassian MCP `createJiraIssue`, `gh issue create`, or the user's own ticket agent/skill) → offer to create one. If the human agrees → create it from the confirmed summary, written in `TICKET_LANGUAGE` (if the user's own ticket agent/skill prescribes a language, follow it), and use its key as `TASK_ID`.
- No ticket → `TASK_ID` = `NOTICKET-<yyyymmdd>-<short-slug>`.

**Find system-map documents (`CONTEXT_FILES`)**
- Look at the skills available in the session. If a skill describes the system/service the task touches (match by the ticket's project key, service name, or keywords — e.g. a `BILLING-*` ticket or payment-related content → a `billing-system` skill, if the user has one), take the path of its `SKILL.md` and its `references/*.md` files (usually in `~/.claude/skills/<name>/` or `<repo>/.claude/skills/<name>/`).
- Add `CLAUDE.md` / `AGENTS.md` from `WORKSPACE_ROOT` if present.
- Nothing found → leave it empty; the planner will investigate on its own.

Create `RUN_DIR` = `~/.claude/dev-task/runs/<TASK_ID>/` (outside every repository so it never ends up in a commit). Write `RUN_DIR/request.md` (in `DOC_LANGUAGE`; quote the original ticket content verbatim): the confirmed ticket/request, `WORKSPACE_ROOT`, `CANDIDATE_REPOS`, `CONTEXT_FILES`, and the languages determined in Step 0 (so a re-run uses the same ones).

If `RUN_DIR` already exists (re-running an old task): read the existing files, tell the human which step it reached, and ask whether to continue or start over.

## Step 2 — Plan (dev-planner, MODE PLAN)

Call `dev-planner` with `MODE: PLAN`, `WORKSPACE_ROOT`, `RUN_DIR`, `DOC_LANGUAGE`, `CONTEXT_FILES`, `CANDIDATE_REPOS`, and the path of `request.md`.

When the planner finishes, read the table in section `## 0.` of `plan.md` to get `REPOS`. Table missing or malformed → call the planner again asking it to fix the format.

## Step 3 — 🛑 HUMAN APPROVES THE PLAN

Present to the human:
- The path of `plan.md` (as an absolute markdown link so it can be opened)
- **The affected repositories** + implementation/merge order
- The planner's summary: approach, cross-repository contracts (if several repositories), risks, how it will be tested
- The planner's **open questions** (if any), clearly marked as needing an answer

Ask with AskUserQuestion: **Approve** / **Revise plan** (the human writes feedback) / **Cancel**.
- Revise → call `dev-planner` MODE PLAN again with `REVIEW_FEEDBACK` (the feedback verbatim + answers to open questions) → back to Step 3.
- Cancel → stop, keep `RUN_DIR`.
- Do NOT go to Step 4 without an explicit approval from the human.

## Step 4 — Prepare branches and implement (dev-implementer)

**4a. Check and create a branch in each repository in `REPOS`**
- `git -C <path> status --porcelain` → uncommitted changes → ask the human: stop / continue on the current state (for that repository).
- Use **the same branch name** in every repository: `<prefix>/<TASK_ID>-<slug>`. Prefix follows the repository's convention (`git -C <path> branch -r --sort=-committerdate | head`); if unclear, `feature/` or `fix/`.
- `git -C <path> fetch origin <base>` then `git -C <path> switch -c <branch> origin/<base>`. Branch already exists (task re-run) → ask the human whether to reuse it or create a new one.
- If the repository is the session's current repository and the environment has a `propose_branch` tool → use that tool for this repository.

**4b. Implement in table order**
- For each repository in `#` order: call `dev-implementer` with `REPO_ROOT: <path>`, `REPO_NAME: <name>`, `RUN_DIR`, `DOC_LANGUAGE`, `INSTRUCTIONS: RUN_DIR/plan.md`.
- Independent repositories (not depending on each other's contracts) may be called in parallel in one message; the rest sequentially.
- `STATUS: BLOCKED` → hold the remaining repositories, call `dev-planner` MODE REPLAN with the BLOCKED report.
  - `MATERIAL_CHANGE: yes` → back to Step 3 (human re-approves).
  - `MATERIAL_CHANGE: no` → call the implementer again for that repository, tell the human the adjustment in one line, and continue.

## Step 5 — Test (dev-test-runner) and fix loop

Call `dev-test-runner` with `RUN_DIR`, `DOC_LANGUAGE`, `ROUND = n`, `REPOS` (round 1: every repository; later rounds: every repository changed in the previous fix round + repositories depending on their contracts).
- `PASS` → Step 6.
- `NO_TESTS` (in any repository) → tell the human and ask: accept and continue / have the planner add tests.
- `FAIL` / `TIMEOUT` → call `dev-planner` MODE DIAGNOSE with `TEST_REPORT: RUN_DIR/test-<n>.md`, `ROUND: n`. The planner writes `fix-<n>.md`.
  - Classified `CODE_BUG` / `TEST_BUG` / `PLAN_GAP` → for each repository with a section in `fix-<n>.md`: call `dev-implementer` with `REPO_ROOT`, `REPO_NAME`, `INSTRUCTIONS: RUN_DIR/fix-<n>.md` → rerun tests with `ROUND = n+1`.
  - `ENV` / `PRE_EXISTING` → stop and present it to the human for a decision.
  - A `PLAN_GAP` that changes scope or adds a repository → tell the human before fixing.
- `ENV_ERROR` → call `dev-planner` DIAGNOSE to confirm; if it really is the environment (e.g. a container is not running), stop and state exactly what the human needs to do.
- Still failing after 3 rounds → stop, summarize the rounds (links to `test-*.md`, `fix-*.md`), and ask the human.

## Step 6 — Logic review (dev-reviewer)

Call `dev-reviewer` with `RUN_DIR`, `DOC_LANGUAGE`, `ROUND = m`, `REPOS` (full name, path, base branch).
- `APPROVE` → Step 7.
- `CHANGES_REQUIRED` → for each repository in `REPOS_TO_FIX`: call `dev-implementer` with `INSTRUCTIONS: RUN_DIR/review-<m>.md` (fix only that repository's BLOCKER/MAJOR findings) → back to Step 5 (tests) → Step 6 with `ROUND = m+1`.
- More than 2 rounds → stop, present the remaining findings, and ask the human: open the PR with notes / keep fixing / stop.
- `MINOR` findings are not fixed; they only go into the PR description.

## Step 7 — Commit and open PRs (per repository)

For each repository in `#` order:
- Determine `COMMIT_LANGUAGE` and `PR_LANGUAGE` for **this repository** following the precedence in Languages (including `<path>/.claude/dev-task.json`).
- Check `git -C <path> status` and `diff --stat`. Add only files belonging to the task (no junk, `.env`, build output). Unexpected files → ask the human.
- Commit message: follow the repository's format convention (`git -C <path> log --oneline -20`, e.g. Conventional Commits), written in `COMMIT_LANGUAGE`, including `TASK_ID`.
- AI attribution lines (`Co-Authored-By: ...`, `Generated with ...`) in commits and PRs: follow the user's own rules (CLAUDE.md, memory, harness settings). If the user forbids them, never add them; the user's rules always take precedence over defaults.
- `git -C <path> push -u origin <branch>`.
- Open the PR: run `gh pr create --base <base>` **from inside the repository directory** (`cd <path> && gh pr create ...`).
  - Use `.github/pull_request_template.md` if the repository has one (keep the template's section headings). Write the PR title and body in `PR_LANGUAGE`.
  - Content: ticket/issue link, goal, summary of this repository's changes, how it was tested + results, risks, related MINOR findings (if any).

With several repositories, after all PRs are created: `gh pr edit` each PR to add a **"Related PRs"** section (links to the others) and a **"Merge/deploy order"** section per the plan.

If running in the Claude desktop app → for the PR of the session's current repository, call ccd_pr `get_status` / `bind_pr`.

## Step 8 — 🛑 HUMAN REVIEWS THE PRS

Final report:
- PR table: repository, PR link, branch, merge order
- `TASK_ID`, number of test rounds, number of review rounds, error classifications encountered
- What the human should pay attention to during review (risks, assumptions, cross-repository contracts, MINOR findings, anything not verified)
- Link to `RUN_DIR` for the full plan/test/review trail

End of pipeline. Do not merge, do not enable auto-merge.

---

## Progress reporting rules

- Every message to the human is in `CHAT_LANGUAGE`; quotes from files/logs stay verbatim.
- On every step change: one line to the human (e.g. "Planner done: 2 repositories affected, waiting for plan approval", "Test round 2 failed in frontend → Opus is diagnosing").
- Do not paste whole subagent files; give the file link + a summary.
- Never invent subagent results. If a subagent returns the wrong format → call it once more asking for the correct format; if still wrong, tell the human.
