---
name: dev-task
description: "Điều phối pipeline nhiều agent cho một task phát triển (một hoặc nhiều repo): nhận yêu cầu (link/key Jira, GitHub issue hoặc mô tả) → điều tra & lập kế hoạch (Opus) → NGƯỜI DUYỆT KẾ HOẠCH → code (Sonnet) → test (Haiku), test fail thì Opus phân tích và chỉ cách sửa → review logic (Opus) → commit, tạo PR cho từng repo → NGƯỜI REVIEW PR. Dùng khi user gõ /dev-task, hoặc nói 'giao task này cho team agent', 'làm vé/issue này từ đầu đến PR', 'điều tra, code, test rồi tạo PR cho ...'. Dùng cho mọi loại dự án (frontend, backend, infra...)."
argument-hint: "<link/key Jira | link GitHub issue | mô tả vấn đề>"
---

> **Bản dịch tiếng Việt để tham khảo.** Claude Code không nạp file này. Bản gốc là [skills/dev-task/SKILL.md](../../../../skills/dev-task/SKILL.md); hai bản lệch nhau thì bản tiếng Anh là chuẩn.

# /dev-task — Pipeline điều tra → kế hoạch → code → test → review → PR

Bạn (session chính) là **orchestrator**. Bạn KHÔNG tự điều tra sâu, KHÔNG tự viết code của task. Mọi việc chuyên môn giao cho subagent, bạn chỉ chuyển dữ liệu giữa các bước, giữ 2 điểm dừng cho người, và báo cáo tiến độ.

| Vai trò | Subagent | Model |
|---|---|---|
| Lập kế hoạch, phân tích lỗi test | `dev-planner` | opus / high |
| Viết code (mỗi lần gọi = 1 repo) | `dev-implementer` | sonnet / medium |
| Chạy test (mọi repo liên quan) | `dev-test-runner` | haiku / low |
| Review logic (mọi repo cùng lúc) | `dev-reviewer` | opus / high |

Khi cài qua plugin, tên subagent có thể mang tiền tố plugin (vd `agent-taskforce:dev-planner`). Dùng đúng tên xuất hiện trong danh sách agent của session.

Subagent không thấy hội thoại này và không gọi được nhau. Mọi thông tin truyền qua **file trong `RUN_DIR`** + prompt bạn viết. Prompt gọi subagent phải luôn có `RUN_DIR`, `DOC_LANGUAGE` (xem mục Ngôn ngữ), đường dẫn tuyệt đối của repo liên quan, và đường dẫn file cần đọc.

Giới hạn vòng lặp: **test-fix tối đa 3 vòng**, **review-fix tối đa 2 vòng**. Hết lượt → dừng, tóm tắt hiện trạng và hỏi người.

**Danh sách repo (`REPOS`)** là nguồn sự thật cho mọi bước sau Bước 3: lấy từ bảng ở mục `## 0.` (Repo bị ảnh hưởng) trong `plan.md` (tên, đường dẫn tuyệt đối, base branch, lệnh test, thứ tự). Vé chỉ 1 repo thì bảng có 1 dòng, các bước bên dưới chạy y như vậy.

---

## Ngôn ngữ

Mỗi loại đầu ra có ngôn ngữ riêng:

| Khóa | Áp dụng cho | `auto` nghĩa là |
|---|---|---|
| `chat` | Mọi tin nhắn gửi người: báo tiến độ, câu hỏi, tóm tắt, báo cáo cuối | Ngôn ngữ người dùng đang chat (hoặc quy định trong CLAUDE.md) |
| `docs` | File trong `RUN_DIR` (`request.md`, `plan.md`, `test-*.md`, `fix-*.md`, `review-*.md`) và báo cáo subagent trả về | Giống `chat` |
| `ticket` | Tạo vé mới, comment lên vé/issue | Ngôn ngữ của vé gần đây cùng project (nếu đọc được), không thì giống `chat` |
| `commit` | Commit message | Ngôn ngữ của `git log` gần đây trong repo đó, không xác định được thì tiếng Anh |
| `pr` | Tiêu đề + mô tả PR, nội dung `gh pr edit` | Ngôn ngữ của PR merged gần đây (`gh pr list --state merged -L 5`), không xác định được thì giống `commit` |

Giá trị: `auto`, hoặc tên/mã ngôn ngữ bất kỳ (`vi`, `en`, `ja`, `Tiếng Việt`, `日本語`...).

**Thứ tự ưu tiên** (cao → thấp), áp dụng cho từng khóa riêng:
1. Người dùng nói rõ trong yêu cầu hiện tại (vd "PR viết tiếng Nhật")
2. `<repo>/.claude/dev-task.json` của **chính repo đó** — chỉ áp dụng `commit`, `pr` cho repo đó (mỗi repo có thể khác nhau)
3. `<WORKSPACE_ROOT>/.claude/dev-task.json`
4. `~/.claude/dev-task/config.json`
5. `auto`

Định dạng file (mọi khóa đều tùy chọn, thiếu khóa nào thì xét tầng tiếp theo):

```json
{
  "language": {
    "chat": "vi",
    "docs": "auto",
    "ticket": "ja",
    "commit": "en",
    "pr": "auto"
  }
}
```

File không phải JSON hợp lệ → báo người 1 dòng (đường dẫn + lỗi), bỏ qua file đó và đi tiếp.

**Phần luôn giữ nguyên, không dịch** (orchestrator và các agent đọc máy móc): tên biến (`RUN_DIR`, `MODE`...), từ khóa trạng thái (`STATUS`, `PASS`, `FAIL`, `BLOCKED`, `VERDICT`, `APPROVE`, `CHANGES_REQUIRED`, `BLOCKER`, `MAJOR`, `MINOR`, `CODE_BUG`...), tên field trong khối báo cáo, số thứ tự mục (`## 0.`, `## 1.`...) và thứ tự cột của bảng mục `## 0.`. Tiêu đề mục được dịch phần chữ, phải giữ số thứ tự. Tên branch, `TASK_ID` luôn dùng ASCII.

---

## Bước 0 — Xác định không gian làm việc

- `WORKSPACE_ROOT` = thư mục hiện tại của session.
- `git rev-parse --show-toplevel`:
  - Thành công → session đang ở trong 1 repo; đưa repo đó vào `CANDIDATE_REPOS`.
  - Thất bại → session đang ở thư mục cha chứa nhiều repo (vd `~/work/my-org`). Không dừng; repo sẽ do planner xác định.
- `gh auth status` → chưa login thì cảnh báo (bước tạo PR sẽ không chạy được).
- Đọc cấu hình ngôn ngữ (tầng 1, 3, 4, 5 của mục Ngôn ngữ; tầng 2 đọc ở Bước 7 khi đã biết repo) → xác định `CHAT_LANGUAGE`, `DOC_LANGUAGE`, `TICKET_LANGUAGE`. Từ đây mọi tin nhắn gửi người dùng `CHAT_LANGUAGE`. Báo người 1 dòng: ngôn ngữ đang dùng cho từng khóa và lấy từ đâu (file nào / `auto`).

Không kiểm tra trạng thái git ở bước này; kiểm tra từng repo ở Bước 4, khi đã biết repo nào bị ảnh hưởng.

## Bước 1 — Nhận yêu cầu

**Trường hợp A: link hoặc key Jira** (vd `ABC-123`, `https://xxx.atlassian.net/browse/ABC-123`)
- Lấy vé bằng Atlassian MCP (`getJiraIssue`; load qua ToolSearch nếu đang deferred). Lấy summary, description, acceptance criteria, comment, link liên quan.
- Session không có Atlassian MCP → nhờ người dán nội dung vé vào chat.
- `TASK_ID` = key vé.

**Trường hợp A2: link GitHub issue** (vd `https://github.com/<owner>/<repo>/issues/123`)
- `gh issue view <url> --comments` để lấy tiêu đề, nội dung, comment.
- `TASK_ID` = `GH-<repo>-<số issue>`.

**Trường hợp B: mô tả trực tiếp**
- Tóm tắt lại yêu cầu (mục tiêu, phạm vi, tiêu chí hoàn thành) và hỏi người xác nhận đã hiểu đúng.
- Nếu session có cách tạo vé (Atlassian MCP `createJiraIssue`, `gh issue create`, hoặc agent/skill tạo vé riêng của người dùng) → đề xuất tạo vé. Người đồng ý → tạo với nội dung đã tóm tắt, viết bằng `TICKET_LANGUAGE` (agent/skill tạo vé riêng có quy định ngôn ngữ thì theo nó), lấy key làm `TASK_ID`.
- Không tạo vé → `TASK_ID` = `NOTICKET-<yyyymmdd>-<slug-ngắn>`.

**Tìm tài liệu bản đồ hệ thống (`CONTEXT_FILES`)**
- Xem danh sách skill đang có trong session. Skill nào mô tả hệ thống/dịch vụ mà vé đụng tới (khớp theo project key của vé, tên dịch vụ, từ khóa trong vé — vd vé `BILLING-*` hoặc nội dung về thanh toán → skill `billing-system` nếu người dùng có) thì lấy đường dẫn `SKILL.md` và các file `references/*.md` của nó (thường ở `~/.claude/skills/<tên>/` hoặc `<repo>/.claude/skills/<tên>/`).
- Thêm `CLAUDE.md` / `AGENTS.md` của `WORKSPACE_ROOT` nếu có.
- Không tìm được gì thì để rỗng; planner sẽ tự điều tra.

Tạo `RUN_DIR` = `~/.claude/dev-task/runs/<TASK_ID>/` (ngoài mọi repo để không lẫn vào commit). Ghi `RUN_DIR/request.md` (bằng `DOC_LANGUAGE`; nội dung gốc của vé giữ nguyên văn): nội dung vé/yêu cầu đã xác nhận, `WORKSPACE_ROOT`, `CANDIDATE_REPOS`, `CONTEXT_FILES`, và các ngôn ngữ đã xác định ở Bước 0 (để chạy lại task dùng đúng như cũ).

Nếu `RUN_DIR` đã tồn tại (chạy lại task cũ): đọc các file có sẵn, báo người đang ở bước nào và hỏi tiếp tục hay làm lại từ đầu.

## Bước 2 — Lập kế hoạch (dev-planner, MODE PLAN)

Gọi `dev-planner` với `MODE: PLAN`, `WORKSPACE_ROOT`, `RUN_DIR`, `DOC_LANGUAGE`, `CONTEXT_FILES`, `CANDIDATE_REPOS`, đường dẫn `request.md`.

Sau khi planner xong, đọc bảng ở mục `## 0.` trong `plan.md` để lấy `REPOS`. Bảng thiếu/sai format → gọi lại planner yêu cầu sửa đúng format.

## Bước 3 — 🛑 NGƯỜI DUYỆT KẾ HOẠCH

Trình bày cho người:
- Đường dẫn `plan.md` (dạng link markdown tuyệt đối để mở được)
- **Danh sách repo bị ảnh hưởng** + thứ tự triển khai/merge
- Tóm tắt planner trả về: phương án, hợp đồng giữa các repo (nếu nhiều repo), rủi ro, cách test
- **Câu hỏi mở** của planner (nếu có), nêu rõ cần người trả lời

Hỏi bằng AskUserQuestion: **Duyệt** / **Sửa kế hoạch** (người ghi góp ý) / **Hủy**.
- Sửa → gọi lại `dev-planner` MODE PLAN kèm `REVIEW_FEEDBACK` (nguyên văn góp ý + câu trả lời cho câu hỏi mở) → quay lại Bước 3.
- Hủy → dừng, giữ nguyên `RUN_DIR`.
- KHÔNG sang bước 4 khi chưa có chữ "duyệt" rõ ràng từ người.

## Bước 4 — Chuẩn bị branch và viết code (dev-implementer)

**4a. Kiểm tra và tạo branch cho từng repo trong `REPOS`**
- `git -C <path> status --porcelain` → có thay đổi chưa commit → hỏi người: dừng / tiếp tục trên trạng thái hiện tại (cho repo đó).
- Branch dùng **cùng một tên** ở mọi repo: `<prefix>/<TASK_ID>-<slug>`. Prefix theo quy ước repo (`git -C <path> branch -r --sort=-committerdate | head`); không rõ thì `feature/` hoặc `fix/`.
- `git -C <path> fetch origin <base>` rồi `git -C <path> switch -c <branch> origin/<base>`. Branch đã tồn tại (chạy lại task) → hỏi người dùng lại hay tạo mới.
- Repo là repo hiện tại của session và môi trường có tool `propose_branch` → dùng tool đó cho repo này.

**4b. Viết code theo thứ tự trong bảng**
- Với mỗi repo theo thứ tự #: gọi `dev-implementer` với `REPO_ROOT: <path>`, `REPO_NAME: <tên>`, `RUN_DIR`, `DOC_LANGUAGE`, `INSTRUCTIONS: RUN_DIR/plan.md`.
- Các repo độc lập (không phụ thuộc hợp đồng của nhau) có thể gọi song song trong cùng 1 message; còn lại gọi tuần tự.
- `STATUS: BLOCKED` → dừng các repo phía sau, gọi `dev-planner` MODE REPLAN kèm báo cáo BLOCKED.
  - `MATERIAL_CHANGE: yes` → quay lại Bước 3 (người duyệt lại).
  - `MATERIAL_CHANGE: no` → gọi lại implementer cho repo đó, báo người 1 dòng về điều chỉnh, rồi tiếp tục.

## Bước 5 — Test (dev-test-runner) và vòng sửa

Gọi `dev-test-runner` với `RUN_DIR`, `DOC_LANGUAGE`, `ROUND = n`, `REPOS` (vòng 1: mọi repo; vòng sau: mọi repo có thay đổi ở vòng sửa trước + repo phụ thuộc hợp đồng của chúng).
- `PASS` → Bước 6.
- `NO_TESTS` (ở repo nào) → báo người, hỏi: chấp nhận đi tiếp / yêu cầu planner bổ sung test.
- `FAIL` / `TIMEOUT` → gọi `dev-planner` MODE DIAGNOSE với `TEST_REPORT: RUN_DIR/test-<n>.md`, `ROUND: n`. Planner ghi `fix-<n>.md`.
  - Phân loại `CODE_BUG` / `TEST_BUG` / `PLAN_GAP` → với mỗi repo có mục trong `fix-<n>.md`: gọi `dev-implementer` với `REPO_ROOT`, `REPO_NAME`, `INSTRUCTIONS: RUN_DIR/fix-<n>.md` → chạy test lại với `ROUND = n+1`.
  - `ENV` / `PRE_EXISTING` → dừng, trình bày cho người quyết định.
  - `PLAN_GAP` làm đổi phạm vi hoặc thêm repo → báo người trước khi sửa.
- `ENV_ERROR` → gọi `dev-planner` DIAGNOSE để xác nhận; nếu đúng là môi trường (vd container chưa chạy) thì dừng, nói rõ cần người làm gì.
- Quá 3 vòng mà vẫn fail → dừng, tóm tắt các vòng (link `test-*.md`, `fix-*.md`) và hỏi người.

## Bước 6 — Review logic (dev-reviewer)

Gọi `dev-reviewer` với `RUN_DIR`, `DOC_LANGUAGE`, `ROUND = m`, `REPOS` (đầy đủ tên, đường dẫn, base branch).
- `APPROVE` → Bước 7.
- `CHANGES_REQUIRED` → với mỗi repo trong `REPOS_TO_FIX`: gọi `dev-implementer` với `INSTRUCTIONS: RUN_DIR/review-<m>.md` (chỉ sửa BLOCKER/MAJOR của repo đó) → quay lại Bước 5 (test) → Bước 6 với `ROUND = m+1`.
- Quá 2 vòng → dừng, trình bày findings còn lại và hỏi người: tạo PR kèm ghi chú / tiếp tục sửa / dừng.
- Finding `MINOR` không sửa, chỉ đưa vào mô tả PR.

## Bước 7 — Commit và tạo PR (từng repo)

Với mỗi repo theo thứ tự #:
- Xác định `COMMIT_LANGUAGE` và `PR_LANGUAGE` cho **repo này** theo thứ tự ưu tiên ở mục Ngôn ngữ (có xét `<path>/.claude/dev-task.json`).
- Xem `git -C <path> status` và `diff --stat`. Chỉ add file thuộc task (không add file rác, `.env`, file build). Có file lạ → hỏi người.
- Commit message: theo quy ước định dạng của repo (`git -C <path> log --oneline -20`, vd Conventional Commits), viết bằng `COMMIT_LANGUAGE`, có `TASK_ID`.
- Dòng attribution AI (`Co-Authored-By: ...`, `Generated with ...`) trong commit và PR: tuân theo quy tắc của người dùng (CLAUDE.md, memory, cấu hình harness). Người dùng cấm thì tuyệt đối không thêm; quy tắc của người dùng luôn ưu tiên hơn mặc định.
- `git -C <path> push -u origin <branch>`.
- Tạo PR: chạy `gh pr create --base <base>` **từ trong thư mục repo** (`cd <path> && gh pr create ...`).
  - Dùng template `.github/pull_request_template.md` nếu repo có (giữ nguyên tiêu đề mục của template). Tiêu đề và nội dung PR viết bằng `PR_LANGUAGE`.
  - Nội dung: link vé/issue, mục tiêu, tóm tắt thay đổi của repo này, cách test + kết quả, rủi ro, finding MINOR liên quan (nếu có).

Khi có nhiều repo, sau khi tạo xong tất cả PR: `gh pr edit` từng PR để thêm mục **"PR liên quan"** (link các PR còn lại) và **"Thứ tự merge/deploy"** theo plan.

Đang trong Claude desktop app → với PR của repo hiện tại của session, gọi `get_status` / `bind_pr` của ccd_pr.

## Bước 8 — 🛑 NGƯỜI REVIEW PR

Báo cáo cuối:
- Bảng PR: repo, link PR, branch, thứ tự merge
- `TASK_ID`, số vòng test, số vòng review, phân loại lỗi đã gặp
- Những điểm cần người chú ý khi review (rủi ro, giả định, hợp đồng giữa các repo, MINOR findings, phần chưa kiểm chứng được)
- Link `RUN_DIR` để xem toàn bộ plan/test/review

Kết thúc pipeline. Không merge, không tự bật auto-merge.

---

## Quy tắc báo cáo tiến độ

- Mọi tin nhắn cho người viết bằng `CHAT_LANGUAGE`; trích file/log thì giữ nguyên văn.
- Mỗi khi chuyển bước: 1 dòng cho người (vd "Planner xong: 2 repo bị ảnh hưởng, chờ duyệt kế hoạch", "Test vòng 2 fail ở frontend → Opus đang phân tích").
- Không dán lại toàn bộ nội dung file từ subagent; đưa link file + tóm tắt.
- Không bịa kết quả subagent. Subagent trả về không đúng format → gọi lại một lần với yêu cầu đúng format, vẫn sai thì báo người.
