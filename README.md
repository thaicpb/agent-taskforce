# agent-taskforce

**English** | [Tiếng Việt](README.vi.md) | [日本語](README.ja.md)

A task force of Claude Code subagents that takes an assigned task — a Jira ticket, a GitHub issue, or a plain description — all the way to a pull request, with two human approval gates. Works for a single repository or several repositories changed together.

## Pipeline

```
/dev-task <ticket | issue | description>
   │
   ├─ 1. Take the request ──────────── Jira (Atlassian MCP) / GitHub issue (gh) / description
   ├─ 2. dev-planner (opus)     PLAN → RUN_DIR/plan.md
   ├─ 3. 🛑 HUMAN APPROVES PLAN ────── Approve / Revise / Cancel
   ├─ 4. dev-implementer (sonnet) ──── one call per repository, same branch name everywhere
   ├─ 5. dev-test-runner (haiku) ───── FAIL → dev-planner DIAGNOSE → fix-N.md → fix (max 3 rounds)
   ├─ 6. dev-reviewer (opus) ───────── logic-only review → review-N.md (max 2 rounds)
   ├─ 7. commit + push + gh pr create (per repository, PRs linked to each other)
   └─ 8. 🛑 HUMAN REVIEWS PRS ──────── never auto-merges
```

| Component | File | Default model / effort | Role |
|---|---|---|---|
| Skill `dev-task` | [skills/dev-task/SKILL.md](skills/dev-task/SKILL.md) | (main session) | Orchestrator: coordinates, holds the 2 human gates, reports progress |
| `dev-planner` | [agents/dev-planner.md](agents/dev-planner.md) | opus / medium | Investigates, plans, diagnoses test failures, re-plans |
| `dev-implementer` | [agents/dev-implementer.md](agents/dev-implementer.md) | sonnet / medium | Implements exactly what the instructions say, never commits |
| `dev-test-runner` | [agents/dev-test-runner.md](agents/dev-test-runner.md) | haiku / low | Runs tests, writes reports, never edits code |
| `dev-reviewer` | [agents/dev-reviewer.md](agents/dev-reviewer.md) | opus / medium | Reviews logic, bugs, regressions, cross-repository contracts |

Agents cannot see each other's conversations. All data moves through files in `RUN_DIR` = `~/.claude/dev-task/runs/<TASK_ID>/`, outside every repository:

```
request.md  plan.md  test-1.md  fix-1.md  test-2.md  review-1.md ...
```

## Requirements

- [Claude Code](https://docs.claude.com/en/docs/claude-code) with access to Opus / Sonnet / Haiku
- `git`, and [`gh`](https://cli.github.com/) logged in with `gh auth login` (for opening PRs and reading GitHub issues)
- Optional: Atlassian MCP (to read/create Jira tickets). Without it, paste the ticket content into the chat.

## Installation

### Option 1: plugin (recommended)

In Claude Code:

```
/plugin marketplace add thaicpb/agent-taskforce
/plugin install agent-taskforce@thaicpb
```

When installed as a plugin, the skill and agents may carry the plugin prefix (e.g. `/agent-taskforce:dev-task`, `agent-taskforce:dev-planner`).

### Option 2: symlink into `~/.claude` (to edit prompts in place)

```bash
git clone https://github.com/thaicpb/agent-taskforce.git
```

```bash
cd agent-taskforce && ./install.sh
```

`./install.sh --force` overwrites files with the same name (backing them up as `*.bak.<timestamp>`); `./install.sh --uninstall` removes the symlinks. Do not use both options at once, or you will have two sets of agents with the same names.

## Usage

```
/dev-task ABC-123
/dev-task https://github.com/<owner>/<repo>/issues/42
/dev-task Add a date filter to the order list page
```

Run the session inside one repository, or in a parent directory holding several repositories so the planner can find the affected ones.

## Language configuration

Each kind of output can use its own language:

| Key | Applies to | `auto` |
|---|---|---|
| `chat` | Chat messages: progress, questions, reports | The language you are chatting in |
| `docs` | `plan.md`, `test-*.md`, `fix-*.md`, `review-*.md` in `RUN_DIR` | Same as `chat` |
| `ticket` | New tickets, comments on tickets/issues | Recent tickets in the same project, otherwise same as `chat` |
| `commit` | Commit messages | The repository's `git log`; if unclear, English |
| `pr` | PR title + description | Recently merged PRs; if unclear, same as `commit` |

Values are `auto` or a language name/code (`en`, `vi`, `ja`, `日本語`...). See the sample file [examples/dev-task.json](examples/dev-task.json).

Put the file in one of these places. Each key is resolved separately, highest priority first:

1. Said explicitly in the request, e.g. `/dev-task ABC-123, write the PR in Japanese`
2. `<repo>/.claude/dev-task.json`: only `commit` and `pr`, only for that repository, so each repository in a multi-repo task can differ
3. `<working directory>/.claude/dev-task.json`
4. `~/.claude/dev-task/config.json`: your personal default on each machine
5. `auto`

Example: chat in Vietnamese, tickets in Japanese, commits and PRs in English:

```json
{ "language": { "chat": "vi", "docs": "vi", "ticket": "ja", "commit": "en", "pr": "en" } }
```

Status keywords (`PASS`, `BLOCKED`, `VERDICT`...), variable names, and section numbers in the plan file are never translated, so agents can always parse each other's output. Comments in code follow the language the repository already uses.

## Agent models and effort

The defaults (table above) keep token usage moderate: Opus agents run at `medium` effort. You can override the model and effort of each agent in the same configuration files as the languages, under the `agents` key:

```json
{ "agents": { "dev-planner": { "effort": "high" }, "dev-reviewer": { "model": "opus", "effort": "high" } } }
```

- Keys: `dev-planner`, `dev-implementer`, `dev-test-runner`, `dev-reviewer` (without the plugin prefix). `model` and `effort` are both optional.
- `model`: `opus`, `sonnet`, `haiku`... `effort`: `low`, `medium`, `high`, `xhigh`, `max`.
- Priority, per agent and per field: said explicitly in the request (e.g. `/dev-task ABC-123, use high effort for the planner`) → `<working directory>/.claude/dev-task.json` → `~/.claude/dev-task/config.json` → the agent's frontmatter.
- The orchestrator passes the values as the Agent tool's `model` / `effort` parameters, so this works for plugin installs too, without editing the prompts. If your Claude Code version does not support a parameter, it tells you and falls back to the frontmatter.

Raising `dev-planner` and `dev-reviewer` to `high` helps on large or multi-repository tasks, at a higher token cost.

## Customization

- **System map:** if you have a skill describing your system architecture (which repository does what, paths, test commands), the orchestrator passes its `SKILL.md` + `references/*.md` to the planner before investigation. The workspace's `CLAUDE.md` / `AGENTS.md` are used too.
- **Style review:** `dev-reviewer` deliberately ignores style/naming/formatting, assuming a linter, formatter, or review bot handles it. To review style as well, edit [agents/dev-reviewer.md](agents/dev-reviewer.md).
- **AI attribution in commits/PRs:** follows your rules in `CLAUDE.md` or harness settings. The plugin does not impose any.
- **Model / effort:** see [Agent models and effort](#agent-models-and-effort). With the symlink install you can also change the defaults in each agent's frontmatter.
- **Loop limits:** edit the top of [SKILL.md](skills/dev-task/SKILL.md).

## Safety

- No coding before the human explicitly approves the plan.
- Planner, test runner, and reviewer never edit code. The implementer never commits or switches branches.
- The test runner never installs dependencies, starts containers, or writes to real databases.
- The pipeline stops at the PR: no merging, no auto-merge.

## Translations

The skill and agent prompts are written in English. Reference translations live in [docs/vi/](docs/vi/) (Vietnamese) and [docs/ja/](docs/ja/) (Japanese) — they are for reading only and are not loaded by Claude Code. The English files are the source of truth; when you edit a prompt, update the translations to match.

## License

[MIT](LICENSE)
