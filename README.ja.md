# agent-taskforce

[English](README.md) | [Tiếng Việt](README.vi.md) | **日本語**

割り当てられたタスク（Jira チケット、GitHub issue、または説明文）を受け取り、Pull Request の作成まで進める Claude Code サブエージェントのチームです。人間による承認ゲートが2つあります。単一のリポジトリにも、まとめて変更する複数のリポジトリにも使えます。

## パイプライン

```
/dev-task <チケット | issue | 説明>
   │
   ├─ 1. 依頼の受け取り ────────────── Jira (Atlassian MCP) / GitHub issue (gh) / 説明文
   ├─ 2. dev-planner  (opus)    PLAN → RUN_DIR/plan.md
   ├─ 3. 🛑 人間が計画を承認 ───────── 承認 / 修正 / 中止
   ├─ 4. dev-implementer (sonnet) ──── 1回の呼び出し = 1リポジトリ、全リポジトリで同じブランチ名
   ├─ 5. dev-test-runner (haiku) ───── FAIL → dev-planner DIAGNOSE → fix-N.md → 修正（最大3ラウンド）
   ├─ 6. dev-reviewer (opus) ───────── ロジックのみレビュー → review-N.md（最大2ラウンド）
   ├─ 7. commit + push + gh pr create（リポジトリごと、PR を相互にリンク）
   └─ 8. 🛑 人間が PR をレビュー ───── 自動マージはしない
```

| コンポーネント | ファイル（英語） | 日本語訳 | モデル | 役割 |
|---|---|---|---|---|
| スキル `dev-task` | [SKILL.md](skills/dev-task/SKILL.md) | [ja](docs/ja/skills/dev-task/SKILL.md) | （メインセッション） | Orchestrator: 統括、2つの承認ゲートの維持、進捗報告 |
| `dev-planner` | [dev-planner.md](agents/dev-planner.md) | [ja](docs/ja/agents/dev-planner.md) | opus / high | 調査、計画、テスト失敗の原因分析、再計画 |
| `dev-implementer` | [dev-implementer.md](agents/dev-implementer.md) | [ja](docs/ja/agents/dev-implementer.md) | sonnet / medium | 指示どおりに実装、コミットはしない |
| `dev-test-runner` | [dev-test-runner.md](agents/dev-test-runner.md) | [ja](docs/ja/agents/dev-test-runner.md) | haiku / low | テスト実行、レポート作成、コードは編集しない |
| `dev-reviewer` | [dev-reviewer.md](agents/dev-reviewer.md) | [ja](docs/ja/agents/dev-reviewer.md) | opus / high | ロジック、バグ、リグレッション、リポジトリ間の契約をレビュー |

> Claude Code が実際に読み込むプロンプトは**英語版**です。[docs/ja/](docs/ja/) の日本語訳は読解用で、読み込まれません。両者が食い違う場合は英語版が正となります。

エージェント同士は互いの会話を見られません。すべてのデータは `RUN_DIR` = `~/.claude/dev-task/runs/<TASK_ID>/` 内のファイルを通じて受け渡されます。このディレクトリはどのリポジトリの外にもあります:

```
request.md  plan.md  test-1.md  fix-1.md  test-2.md  review-1.md ...
```

## 必要なもの

- [Claude Code](https://docs.claude.com/en/docs/claude-code)（Opus / Sonnet / Haiku が使えること）
- `git`、および `gh auth login` 済みの [`gh`](https://cli.github.com/)（PR の作成と GitHub issue の読み取りに使用）
- 任意: Atlassian MCP（Jira チケットの読み取り/作成）。ない場合はチケットの内容をチャットに貼り付けてください。

## インストール

### 方法1: プラグイン（推奨）

Claude Code で:

```
/plugin marketplace add thaicpb/agent-taskforce
/plugin install agent-taskforce@thaicpb
```

プラグインとしてインストールした場合、スキルとエージェントにプラグイン名のプレフィックスが付くことがあります（例: `/agent-taskforce:dev-task`、`agent-taskforce:dev-planner`）。

### 方法2: `~/.claude` へのシンボリックリンク（プロンプトを直接編集したい場合）

```bash
git clone https://github.com/thaicpb/agent-taskforce.git
```

```bash
cd agent-taskforce && ./install.sh
```

`./install.sh --force` は同名のファイルを上書きします（`*.bak.<timestamp>` としてバックアップ）。`./install.sh --uninstall` はシンボリックリンクを削除します。両方の方法を同時に使うと同名のエージェントが2組できるため、併用しないでください。

## 使い方

```
/dev-task ABC-123
/dev-task https://github.com/<owner>/<repo>/issues/42
/dev-task 注文一覧ページに日付フィルターを追加する
```

セッションは1つのリポジトリ内で起動するか、複数のリポジトリを含む親ディレクトリで起動してください。後者の場合、planner が影響を受けるリポジトリを特定します。

## 言語設定

出力の種類ごとに言語を設定できます:

| キー | 対象 | `auto` |
|---|---|---|
| `chat` | チャットのメッセージ: 進捗、質問、報告 | チャットで使っている言語 |
| `docs` | `RUN_DIR` 内の `plan.md`、`test-*.md`、`fix-*.md`、`review-*.md` | `chat` と同じ |
| `ticket` | 新規チケット、チケット/issue へのコメント | 同じプロジェクトの最近のチケット、なければ `chat` と同じ |
| `commit` | コミットメッセージ | リポジトリの `git log`。判断できなければ英語 |
| `pr` | PR のタイトル + 本文 | 最近マージされた PR。判断できなければ `commit` と同じ |

値は `auto` または言語名/コード（`ja`、`en`、`vi`、`日本語`…）です。サンプルファイル [examples/dev-task.json](examples/dev-task.json) を参照してください。

ファイルは以下のいずれかに置きます。キーごとに、優先度の高いものから決定されます:

1. 依頼の中で明示する。例: `/dev-task ABC-123、PR は日本語で書いて`
2. `<repo>/.claude/dev-task.json`: `commit` と `pr` のみ、そのリポジトリにのみ適用。複数リポジトリのタスクでリポジトリごとに変えられます
3. `<作業ディレクトリ>/.claude/dev-task.json`
4. `~/.claude/dev-task/config.json`: マシンごとの個人のデフォルト
5. `auto`

例: チャットは日本語、チケットも日本語、コミットと PR は英語:

```json
{ "language": { "chat": "ja", "docs": "ja", "ticket": "ja", "commit": "en", "pr": "en" } }
```

ステータスキーワード（`PASS`、`BLOCKED`、`VERDICT`…）、変数名、計画ファイルのセクション番号は、エージェント同士が出力をパースできるよう常に翻訳されません。コード内のコメントはリポジトリで既に使われている言語に従います。

## カスタマイズ

- **システムマップ:** システム構成（どのリポジトリが何を担当するか、パス、テストコマンド）を説明するスキルがあれば、orchestrator はそのスキルの `SKILL.md` + `references/*.md` を調査前に planner へ渡します。ワークスペースの `CLAUDE.md` / `AGENTS.md` も使われます。
- **スタイルのレビュー:** `dev-reviewer` は、linter、formatter、レビューボットが担当する前提で、スタイル/命名/フォーマットを意図的に無視します。スタイルもレビューしたい場合は [agents/dev-reviewer.md](agents/dev-reviewer.md) を編集してください。
- **コミット/PR の AI 帰属表示:** `CLAUDE.md` またはハーネス設定にあるあなたのルールに従います。プラグイン側では強制しません。
- **モデル / effort / ループ上限:** 各エージェントの frontmatter と、[SKILL.md](skills/dev-task/SKILL.md) 冒頭のループ上限を編集してください。

プロンプトを編集する際は、まず英語版を修正し、その後 `docs/ja/` と `docs/vi/` の翻訳を合わせて更新してください。

## 安全性

- 人間が計画を明示的に承認するまで実装に進みません。
- planner、test runner、reviewer はコードを編集しません。implementer はコミットもブランチの切り替えもしません。
- test runner は依存関係のインストール、コンテナの起動、本番データベースへの書き込みをしません。
- パイプラインは PR で止まります: マージも自動マージもしません。

## ライセンス

[MIT](LICENSE)
