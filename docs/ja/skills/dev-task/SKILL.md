---
name: dev-task
description: "1つの開発タスク（1つまたは複数のリポジトリ）のためのマルチエージェントパイプラインを統括する: 依頼を受け取る（Jira のキー/リンク、GitHub issue、または説明文） → 調査と計画（Opus） → 人間が計画を承認 → 実装（Sonnet） → テスト（Haiku）、失敗時は Opus が原因を分析して修正指示を書く → ロジックレビュー（Opus） → リポジトリごとにコミットして PR を作成 → 人間が PR をレビュー。ユーザーが /dev-task と入力したとき、または「このタスクをエージェントチームに任せて」「このチケット/issue を PR まで進めて」「調査、実装、テストして ... の PR を作って」などと言ったときに使う。あらゆる種類のプロジェクト（フロントエンド、バックエンド、インフラ…）で使える。"
argument-hint: "<Jira のキー/リンク | GitHub issue のリンク | 問題の説明>"
---

> **参考用の日本語訳です。** Claude Code はこのファイルを読み込みません。原文は [skills/dev-task/SKILL.md](../../../../skills/dev-task/SKILL.md) です。両者が食い違う場合は英語版が正となります。

# /dev-task — パイプライン: 調査 → 計画 → 実装 → テスト → レビュー → PR

あなた（メインセッション）は **orchestrator** である。深い調査も、タスクのコードを書くことも自分ではしない。専門的な作業はすべてサブエージェントに任せ、あなたはステップ間でデータを受け渡し、人間による2つのチェックポイントを守り、進捗を報告するだけである。

| 役割 | サブエージェント | デフォルトのモデル / effort |
|---|---|---|
| 計画、テスト失敗の原因分析 | `dev-planner` | opus / medium |
| 実装（1回の呼び出し = 1リポジトリ） | `dev-implementer` | sonnet / medium |
| テスト実行（影響を受ける全リポジトリ） | `dev-test-runner` | haiku / low |
| ロジックレビュー（全リポジトリを一括） | `dev-reviewer` | opus / medium |

デフォルト値は各エージェントの frontmatter による。ユーザーはエージェントごとにモデルと effort を上書きできる（エージェントのモデルと effort の項を参照）。

プラグインとしてインストールした場合、サブエージェント名にプラグインのプレフィックスが付くことがある（例: `agent-taskforce:dev-planner`）。セッションのエージェント一覧に表示される正確な名前を使うこと。

サブエージェントはこの会話を見られず、互いを呼び出すこともできない。すべての情報は **`RUN_DIR` 内のファイル**と、あなたが書くプロンプトを通じて伝わる。すべてのサブエージェントのプロンプトには、`RUN_DIR`、`DOC_LANGUAGE`（言語の項を参照）、関係する各リポジトリの絶対パス、読むべきファイルのパスを含めること。すべてのサブエージェント呼び出しには、ステップ0で決めたモデル/effort の上書きも反映させる（エージェントのモデルと effort の項を参照）。

ループの上限: **テスト修正は最大3ラウンド**、**レビュー修正は最大2ラウンド**。上限に達したら → 停止し、現状をまとめて人間に確認する。

**リポジトリ一覧（`REPOS`）** はステップ3以降のすべてのステップにおける正とする: `plan.md` のセクション `## 0.`（影響を受けるリポジトリ）の表から取得する（名前、絶対パス、ベースブランチ、テストコマンド、順序）。単一リポジトリのタスクでは表が1行になるだけで、以下のステップは同じように動く。

---

## 言語

出力の種類ごとに言語を設定できる:

| キー | 対象 | `auto` の意味 |
|---|---|---|
| `chat` | 人間へのすべてのメッセージ: 進捗、質問、要約、最終報告 | ユーザーがチャットで使っている言語（または CLAUDE.md が指定する言語） |
| `docs` | `RUN_DIR` 内のファイル（`request.md`、`plan.md`、`test-*.md`、`fix-*.md`、`review-*.md`）とサブエージェントが返すレポート | `chat` と同じ |
| `ticket` | チケットの作成、チケット/issue へのコメント | 同じプロジェクトの最近のチケットの言語（読める場合）、なければ `chat` と同じ |
| `commit` | コミットメッセージ | そのリポジトリの最近の `git log` の言語。判断できなければ英語 |
| `pr` | PR のタイトル + 本文、`gh pr edit` の内容 | 最近マージされた PR の言語（`gh pr list --state merged -L 5`）。判断できなければ `commit` と同じ |

値: `auto`、または任意の言語名/コード（`en`、`vi`、`ja`、`English`、`日本語`…）。

**優先順位**（高 → 低）、キーごとに決定する:
1. ユーザーが現在の依頼で明示した場合（例: 「PR は日本語で書いて」）
2. **そのリポジトリ**の `<repo>/.claude/dev-task.json` — `commit` と `pr` のみ、そのリポジトリにのみ適用（リポジトリごとに異なってよい）
3. `<WORKSPACE_ROOT>/.claude/dev-task.json`
4. `~/.claude/dev-task/config.json`
5. `auto`

ファイル形式（すべてのキーは省略可能。欠けたキーは次のレベルに委ねる）:

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

有効な JSON でないファイル → 人間に1行で伝え（パス + エラー）、そのファイルは無視して続行する。

**翻訳しないもの**（orchestrator とエージェントが機械的にパースするため）: 変数名（`RUN_DIR`、`MODE`…）、ステータスキーワード（`STATUS`、`PASS`、`FAIL`、`BLOCKED`、`VERDICT`、`APPROVE`、`CHANGES_REQUIRED`、`BLOCKER`、`MAJOR`、`MINOR`、`CODE_BUG`…）、レポートブロックのフィールド名、セクション番号（`## 0.`、`## 1.`…）、`## 0.` の表の列順。セクション見出しは文言を翻訳してよいが、番号は残すこと。ブランチ名と `TASK_ID` は常に ASCII。

---

## エージェントのモデルと effort

各エージェントの frontmatter がデフォルトのモデルと effort を定める。ユーザーは言語の項と同じ設定ファイルの `agents` キーで、エージェントごとに上書きできる:

```json
{
  "agents": {
    "dev-planner": { "model": "opus", "effort": "high" },
    "dev-reviewer": { "effort": "high" },
    "dev-test-runner": { "model": "sonnet" }
  }
}
```

- キー: プラグインのプレフィックスを除いたエージェント名（`dev-planner`、`dev-implementer`、`dev-test-runner`、`dev-reviewer`）。どちらのフィールドも省略可能。
- `model`: Agent ツールが受け付けるモデルのエイリアス（例: `opus`、`sonnet`、`haiku`）。`effort`: `low`、`medium`、`high`、`xhigh`、`max` のいずれか。

**優先順位**（高 → 低）、エージェントごと・フィールドごとに決定する:
1. ユーザーが現在の依頼で明示した場合（例: 「planner は effort high で」）
2. `<WORKSPACE_ROOT>/.claude/dev-task.json`
3. `~/.claude/dev-task/config.json`
4. エージェントの frontmatter（デフォルト）

1回のエージェント呼び出しが複数のリポジトリにまたがりうるため、`<repo>/.claude/dev-task.json` はここでは使わない。

適用方法:
- レベル 1-3 から決まったフィールド → そのエージェントへの**すべての**呼び出しで、Agent ツールの `model` / `effort` パラメータとして渡す（この設定がパラメータを指定せよという明示的な指示にあたる）。レベル 4 から決まったフィールド → パラメータを渡さず、frontmatter を適用させる。
- 未知のエージェント名、または上記の一覧にない `effort` の値 → 人間に1行で伝え、そのフィールドを無視する。
- このセッションの Agent ツールにそのパラメータがない、または値を拒否された → 人間に1行で伝え、パラメータなしでエージェントを呼び出す（frontmatter が適用される）。

---

## ステップ 0 — ワークスペースの確定

- `WORKSPACE_ROOT` = セッションのカレントディレクトリ。
- `git rev-parse --show-toplevel`:
  - 成功 → セッションは1つのリポジトリ内にある。それを `CANDIDATE_REPOS` に追加する。
  - 失敗 → セッションは複数のリポジトリを含む親ディレクトリにある（例: `~/work/my-org`）。停止せず、planner にリポジトリを特定させる。
- `gh auth status` → ログインしていなければ警告する（PR のステップが動かない）。
- 言語設定を読む（言語の項のレベル 1、3、4、5。レベル 2 はリポジトリが確定するステップ7で読む） → `CHAT_LANGUAGE`、`DOC_LANGUAGE`、`TICKET_LANGUAGE` を決める。以降、人間へのメッセージはすべて `CHAT_LANGUAGE` を使う。各キーがどの言語を使い、どこから来たか（どのファイル / `auto`）を人間に1行で伝える。
- `agents` の設定を読む（エージェントのモデルと effort の項を参照） → `AGENT_OVERRIDES` を決める。各エージェントが使うモデル/effort とその出どころ（依頼 / どのファイル / frontmatter のデフォルト）を人間に1行で伝える。

ここでは git の状態を確認しない。各リポジトリは、影響を受けるリポジトリが確定した後のステップ4で確認する。

## ステップ 1 — 依頼を受け取る

**ケース A: Jira のキーまたはリンク**（例: `ABC-123`、`https://xxx.atlassian.net/browse/ABC-123`）
- Atlassian MCP（`getJiraIssue`。遅延ロードなら ToolSearch で読み込む）でチケットを取得する。概要、説明、受け入れ条件、コメント、関連リンクを集める。
- セッションに Atlassian MCP がない → チケットの内容をチャットに貼り付けるよう人間に頼む。
- `TASK_ID` = チケットキー。

**ケース A2: GitHub issue のリンク**（例: `https://github.com/<owner>/<repo>/issues/123`）
- `gh issue view <url> --comments` でタイトル、本文、コメントを取得する。
- `TASK_ID` = `GH-<repo>-<issue 番号>`。

**ケース B: 説明文**
- 依頼（目的、範囲、完了条件）を言い直し、正しく理解できているか人間に確認する。
- セッションにチケットを作成する手段がある場合（Atlassian MCP の `createJiraIssue`、`gh issue create`、またはユーザー自身のチケット用エージェント/スキル） → 作成を提案する。人間が同意したら → 確認済みの要約から `TICKET_LANGUAGE` で作成し（ユーザー自身のチケット用エージェント/スキルが言語を指定していればそれに従う）、そのキーを `TASK_ID` とする。
- チケットなし → `TASK_ID` = `NOTICKET-<yyyymmdd>-<短いスラッグ>`。

**システムマップのドキュメント（`CONTEXT_FILES`）を探す**
- セッションで使えるスキルを確認する。タスクが関わるシステム/サービスを説明するスキルがあれば（チケットのプロジェクトキー、サービス名、キーワードで照合する — 例: `BILLING-*` のチケットや決済関連の内容 → ユーザーが持っていれば `billing-system` スキル）、その `SKILL.md` と `references/*.md` のパスを取得する（通常は `~/.claude/skills/<name>/` または `<repo>/.claude/skills/<name>/`）。
- `WORKSPACE_ROOT` に `CLAUDE.md` / `AGENTS.md` があれば追加する。
- 何も見つからない → 空のままにする。planner が自分で調査する。

`RUN_DIR` = `~/.claude/dev-task/runs/<TASK_ID>/` を作成する（コミットに混入しないよう、すべてのリポジトリの外）。`RUN_DIR/request.md` を書く（`DOC_LANGUAGE` で。元のチケット内容は原文のまま引用する）: 確認済みのチケット/依頼、`WORKSPACE_ROOT`、`CANDIDATE_REPOS`、`CONTEXT_FILES`、ステップ0で決めた言語と `AGENT_OVERRIDES`（再実行時に同じものを使うため）。

`RUN_DIR` が既に存在する場合（過去のタスクの再実行）: 既存ファイルを読み、どのステップまで進んでいたかを人間に伝え、続行するかやり直すかを確認する。

## ステップ 2 — 計画（dev-planner、MODE PLAN）

`dev-planner` を `MODE: PLAN`、`WORKSPACE_ROOT`、`RUN_DIR`、`DOC_LANGUAGE`、`CONTEXT_FILES`、`CANDIDATE_REPOS`、`request.md` のパスを付けて呼び出す。

planner が完了したら、`plan.md` のセクション `## 0.` の表を読んで `REPOS` を得る。表がない、または形式が崩れている → 形式を直すよう planner を再度呼び出す。

## ステップ 3 — 🛑 人間が計画を承認

人間に提示する:
- `plan.md` のパス（開けるよう絶対パスの markdown リンクで）
- **影響を受けるリポジトリ** + 実装/マージの順序
- planner の要約: 方針、リポジトリ間の契約（複数リポジトリの場合）、リスク、テスト方法
- planner の**未解決の質問**（あれば）。回答が必要であることを明示する

AskUserQuestion で確認する: **承認** / **計画を修正**（人間がフィードバックを書く） / **中止**。
- 修正 → `dev-planner` を MODE PLAN で `REVIEW_FEEDBACK`（フィードバックの原文 + 未解決の質問への回答）を付けて再度呼び出す → ステップ3に戻る。
- 中止 → 停止し、`RUN_DIR` は残す。
- 人間の明示的な承認なしにステップ4へ進んではならない。

## ステップ 4 — ブランチの準備と実装（dev-implementer）

**4a. `REPOS` の各リポジトリを確認してブランチを作成する**
- `git -C <path> status --porcelain` → 未コミットの変更がある → 人間に確認する: 停止 / 現状のまま続行（そのリポジトリについて）。
- すべてのリポジトリで**同じブランチ名**を使う: `<prefix>/<TASK_ID>-<slug>`。プレフィックスはリポジトリの慣習に従う（`git -C <path> branch -r --sort=-committerdate | head`）。不明なら `feature/` または `fix/`。
- `git -C <path> fetch origin <base>` の後に `git -C <path> switch -c <branch> origin/<base>`。ブランチが既に存在する（タスクの再実行） → 再利用するか新規作成するかを人間に確認する。
- そのリポジトリがセッションのカレントリポジトリで、環境に `propose_branch` ツールがある場合 → このリポジトリにはそのツールを使う。

**4b. 表の順序で実装する**
- `#` の順に各リポジトリについて: `dev-implementer` を `REPO_ROOT: <path>`、`REPO_NAME: <name>`、`RUN_DIR`、`DOC_LANGUAGE`、`INSTRUCTIONS: RUN_DIR/plan.md` を付けて呼び出す。
- 独立したリポジトリ（互いの契約に依存しないもの）は1つのメッセージで並列に呼び出してよい。それ以外は順番に。
- `STATUS: BLOCKED` → 残りのリポジトリを保留し、BLOCKED レポートを付けて `dev-planner` を MODE REPLAN で呼び出す。
  - `MATERIAL_CHANGE: yes` → ステップ3に戻る（人間が再承認）。
  - `MATERIAL_CHANGE: no` → そのリポジトリについて implementer を再度呼び出し、調整内容を人間に1行で伝えて続行する。

## ステップ 5 — テスト（dev-test-runner）と修正ループ

`dev-test-runner` を `RUN_DIR`、`DOC_LANGUAGE`、`ROUND = n`、`REPOS`（ラウンド1: 全リポジトリ。以降のラウンド: 前回の修正ラウンドで変更された全リポジトリ + それらの契約に依存するリポジトリ）を付けて呼び出す。
- `PASS` → ステップ6へ。
- `NO_TESTS`（いずれかのリポジトリで） → 人間に伝えて確認する: 受け入れて続行 / planner にテストを追加させる。
- `FAIL` / `TIMEOUT` → `dev-planner` を MODE DIAGNOSE で `TEST_REPORT: RUN_DIR/test-<n>.md`、`ROUND: n` を付けて呼び出す。planner が `fix-<n>.md` を書く。
  - 分類が `CODE_BUG` / `TEST_BUG` / `PLAN_GAP` → `fix-<n>.md` にセクションがある各リポジトリについて: `dev-implementer` を `REPO_ROOT`、`REPO_NAME`、`INSTRUCTIONS: RUN_DIR/fix-<n>.md` を付けて呼び出す → `ROUND = n+1` でテストを再実行。
  - `ENV` / `PRE_EXISTING` → 停止し、判断を仰ぐため人間に提示する。
  - スコープを変える、またはリポジトリを追加する `PLAN_GAP` → 修正の前に人間に伝える。
- `ENV_ERROR` → 確認のため `dev-planner` を DIAGNOSE で呼び出す。本当に環境の問題（例: コンテナが起動していない）なら、停止して人間がすべきことを正確に伝える。
- 3ラウンド後も失敗する → 停止し、各ラウンドをまとめて（`test-*.md`、`fix-*.md` へのリンク）、人間に確認する。

## ステップ 6 — ロジックレビュー（dev-reviewer）

`dev-reviewer` を `RUN_DIR`、`DOC_LANGUAGE`、`ROUND = m`、`REPOS`（名前、パス、ベースブランチをすべて）を付けて呼び出す。
- `APPROVE` → ステップ7へ。
- `CHANGES_REQUIRED` → `REPOS_TO_FIX` の各リポジトリについて: `dev-implementer` を `INSTRUCTIONS: RUN_DIR/review-<m>.md` を付けて呼び出す（そのリポジトリの BLOCKER/MAJOR の指摘のみ修正） → ステップ5（テスト）に戻る → `ROUND = m+1` でステップ6。
- 2ラウンドを超えた → 停止し、残っている指摘を提示して人間に確認する: 注記付きで PR を作成 / 修正を続ける / 停止。
- `MINOR` の指摘は修正しない。PR の本文に記載するだけ。

## ステップ 7 — コミットと PR 作成（リポジトリごと）

`#` の順に各リポジトリについて:
- 言語の項の優先順位（`<path>/.claude/dev-task.json` を含む）に従い、**このリポジトリ**の `COMMIT_LANGUAGE` と `PR_LANGUAGE` を決める。
- `git -C <path> status` と `diff --stat` を確認する。タスクに属するファイルだけを追加する（ゴミ、`.env`、ビルド成果物は含めない）。想定外のファイル → 人間に確認する。
- コミットメッセージ: リポジトリの形式の慣習に従い（`git -C <path> log --oneline -20`、例: Conventional Commits）、`COMMIT_LANGUAGE` で書き、`TASK_ID` を含める。
- コミットと PR における AI の帰属表示行（`Co-Authored-By: ...`、`Generated with ...`）: ユーザー自身のルール（CLAUDE.md、メモリ、ハーネスの設定）に従う。ユーザーが禁止していれば決して付けない。ユーザーのルールは常にデフォルトより優先される。
- `git -C <path> push -u origin <branch>`。
- PR を作成する: `gh pr create --base <base>` を**リポジトリのディレクトリ内から**実行する（`cd <path> && gh pr create ...`）。
  - リポジトリに `.github/pull_request_template.md` があれば使う（テンプレートのセクション見出しは残す）。PR のタイトルと本文は `PR_LANGUAGE` で書く。
  - 内容: チケット/issue へのリンク、目的、このリポジトリの変更の要約、テスト方法 + 結果、リスク、関連する MINOR の指摘（あれば）。

複数リポジトリの場合、すべての PR を作成した後: 各 PR を `gh pr edit` で編集し、**「関連 PR」**セクション（他の PR へのリンク）と、計画に沿った**「マージ/デプロイ順序」**セクションを追加する。

Claude デスクトップアプリで実行している場合 → セッションのカレントリポジトリの PR について、ccd_pr の `get_status` / `bind_pr` を呼び出す。

## ステップ 8 — 🛑 人間が PR をレビュー

最終報告:
- PR の表: リポジトリ、PR リンク、ブランチ、マージ順序
- `TASK_ID`、テストのラウンド数、レビューのラウンド数、遭遇したエラー分類
- レビュー時に人間が注意すべき点（リスク、前提、リポジトリ間の契約、MINOR の指摘、未検証の事項）
- 計画/テスト/レビューの全記録のための `RUN_DIR` へのリンク

パイプラインの終了。マージしない。自動マージも有効にしない。

---

## 進捗報告のルール

- 人間へのメッセージはすべて `CHAT_LANGUAGE` で。ファイル/ログからの引用は原文のまま。
- ステップが変わるたびに: 人間に1行で伝える（例: 「planner 完了: 影響リポジトリ2件、計画の承認待ち」「テストラウンド2が frontend で失敗 → planner が原因分析中」）。
- サブエージェントのファイル全体を貼り付けない。ファイルのリンク + 要約を示す。
- サブエージェントの結果を捏造しない。サブエージェントが誤った形式で返した場合 → 正しい形式を求めてもう一度だけ呼び出す。それでも誤っていれば人間に伝える。
