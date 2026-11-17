# agent-taskforce

[English](README.md) | **Tiếng Việt**

Một đội subagent Claude Code nhận việc được giao (vé Jira, GitHub issue hoặc mô tả) và xử lý đến khi có Pull Request, với 2 điểm dừng cho người duyệt. Dùng được cho một repo hoặc nhiều repo cùng thay đổi.

## Pipeline

```
/dev-task <vé | issue | mô tả>
   │
   ├─ 1. Nhận yêu cầu ──────────────── Jira (Atlassian MCP) / GitHub issue (gh) / mô tả
   ├─ 2. dev-planner  (opus)    PLAN → RUN_DIR/plan.md
   ├─ 3. 🛑 NGƯỜI DUYỆT KẾ HOẠCH ───── Duyệt / Sửa / Hủy
   ├─ 4. dev-implementer (sonnet) ──── mỗi lần gọi = 1 repo, cùng tên branch ở mọi repo
   ├─ 5. dev-test-runner (haiku) ───── FAIL → dev-planner DIAGNOSE → fix-N.md → sửa (tối đa 3 vòng)
   ├─ 6. dev-reviewer (opus) ───────── chỉ review logic → review-N.md (tối đa 2 vòng)
   ├─ 7. commit + push + gh pr create (từng repo, liên kết các PR với nhau)
   └─ 8. 🛑 NGƯỜI REVIEW PR ────────── không tự merge
```

| Thành phần | File (tiếng Anh) | Bản dịch | Model | Vai trò |
|---|---|---|---|---|
| Skill `dev-task` | [SKILL.md](skills/dev-task/SKILL.md) | [vi](docs/vi/skills/dev-task/SKILL.md) | (session chính) | Orchestrator: điều phối, giữ 2 điểm dừng, báo tiến độ |
| `dev-planner` | [dev-planner.md](agents/dev-planner.md) | [vi](docs/vi/agents/dev-planner.md) | opus / high | Điều tra, lập kế hoạch, phân tích test fail, lập lại kế hoạch |
| `dev-implementer` | [dev-implementer.md](agents/dev-implementer.md) | [vi](docs/vi/agents/dev-implementer.md) | sonnet / medium | Code đúng theo hướng dẫn, không commit |
| `dev-test-runner` | [dev-test-runner.md](agents/dev-test-runner.md) | [vi](docs/vi/agents/dev-test-runner.md) | haiku / low | Chạy test, ghi báo cáo, không sửa code |
| `dev-reviewer` | [dev-reviewer.md](agents/dev-reviewer.md) | [vi](docs/vi/agents/dev-reviewer.md) | opus / high | Review logic, bug, regression, hợp đồng giữa các repo |

> Prompt mà Claude Code thực sự nạp là bản **tiếng Anh**. Bản dịch tiếng Việt trong [docs/vi/](docs/vi/) chỉ để đọc hiểu, không được nạp. Hai bản lệch nhau thì bản tiếng Anh là chuẩn.

Các agent không thấy hội thoại của nhau. Mọi dữ liệu truyền qua file trong `RUN_DIR` = `~/.claude/dev-task/runs/<TASK_ID>/`, nằm ngoài mọi repo:

```
request.md  plan.md  test-1.md  fix-1.md  test-2.md  review-1.md ...
```

## Yêu cầu

- [Claude Code](https://docs.claude.com/en/docs/claude-code), có quyền dùng các model Opus / Sonnet / Haiku
- `git`, và [`gh`](https://cli.github.com/) đã `gh auth login` (cho bước tạo PR và đọc GitHub issue)
- Tùy chọn: Atlassian MCP (đọc/tạo vé Jira). Không có thì dán nội dung vé vào chat.

## Cài đặt

### Cách 1: plugin (khuyến nghị)

Trong Claude Code:

```
/plugin marketplace add thaicpb/agent-taskforce
/plugin install agent-taskforce@thaicpb
```

Khi cài qua plugin, skill và agent có thể mang tiền tố tên plugin (vd `/agent-taskforce:dev-task`, `agent-taskforce:dev-planner`).

### Cách 2: symlink vào `~/.claude` (để sửa prompt trực tiếp)

```bash
git clone https://github.com/thaicpb/agent-taskforce.git
```

```bash
cd agent-taskforce && ./install.sh
```

`./install.sh --force` sẽ ghi đè file trùng tên (có backup `*.bak.<timestamp>`), còn `./install.sh --uninstall` gỡ các symlink. Không nên dùng cùng lúc cả hai cách vì sẽ có 2 bộ agent trùng tên.

## Sử dụng

```
/dev-task ABC-123
/dev-task https://github.com/<owner>/<repo>/issues/42
/dev-task Thêm bộ lọc theo ngày cho trang danh sách đơn hàng
```

Chạy session ở trong 1 repo, hoặc ở thư mục cha chứa nhiều repo để planner tự xác định repo bị ảnh hưởng.

## Cấu hình ngôn ngữ

Prompt viết bằng tiếng Anh nhưng đầu ra có thể dùng bất kỳ ngôn ngữ nào. Mỗi loại đầu ra đặt ngôn ngữ riêng được:

| Khóa | Áp dụng cho | `auto` |
|---|---|---|
| `chat` | Tin nhắn trong chat: tiến độ, câu hỏi, báo cáo | Theo ngôn ngữ bạn đang chat |
| `docs` | `plan.md`, `test-*.md`, `fix-*.md`, `review-*.md` trong `RUN_DIR` | Giống `chat` |
| `ticket` | Vé tạo mới, comment lên vé/issue | Theo vé gần đây cùng project, không có thì giống `chat` |
| `commit` | Commit message | Theo `git log` của repo, không rõ thì tiếng Anh |
| `pr` | Tiêu đề + mô tả PR | Theo PR merged gần đây, không rõ thì giống `commit` |

Giá trị là `auto` hoặc tên/mã ngôn ngữ (`vi`, `en`, `ja`, `日本語`...). Xem file mẫu [examples/dev-task.json](examples/dev-task.json).

Đặt file ở một trong các vị trí sau. Mỗi khóa xét riêng, ưu tiên từ cao xuống thấp:

1. Nói thẳng trong yêu cầu, vd `/dev-task ABC-123, PR viết tiếng Nhật`
2. `<repo>/.claude/dev-task.json`: chỉ áp dụng `commit` và `pr` cho repo đó, nên mỗi repo trong task nhiều repo có thể khác nhau
3. `<thư mục làm việc>/.claude/dev-task.json`
4. `~/.claude/dev-task/config.json`: mặc định cá nhân trên mỗi máy
5. `auto`

Ví dụ: chat tiếng Việt, vé tiếng Nhật, commit và PR tiếng Anh:

```json
{ "language": { "chat": "vi", "docs": "vi", "ticket": "ja", "commit": "en", "pr": "en" } }
```

Từ khóa trạng thái (`PASS`, `BLOCKED`, `VERDICT`...), tên biến và số thứ tự mục trong file plan luôn giữ nguyên để các agent đọc được của nhau. Comment trong code theo ngôn ngữ đang dùng trong repo.

## Tùy biến

- **Bản đồ hệ thống:** nếu bạn có skill mô tả kiến trúc hệ thống (repo nào làm gì, đường dẫn, lệnh test), orchestrator sẽ chuyển `SKILL.md` + `references/*.md` của skill đó cho planner đọc trước khi điều tra. `CLAUDE.md` / `AGENTS.md` của workspace cũng được dùng.
- **Review style:** `dev-reviewer` cố ý bỏ qua style/naming/format, vì giả định đã có linter, formatter hoặc bot review lo. Muốn review cả style thì sửa [agents/dev-reviewer.md](agents/dev-reviewer.md).
- **Attribution AI trong commit/PR:** theo quy tắc của bạn trong `CLAUDE.md` hoặc cấu hình harness. Plugin không áp đặt.
- **Model / effort / số vòng lặp:** sửa frontmatter của từng agent, và giới hạn vòng lặp ở đầu [SKILL.md](skills/dev-task/SKILL.md).

Khi sửa prompt, hãy sửa bản tiếng Anh trước rồi cập nhật bản dịch trong `docs/vi/` cho khớp.

## An toàn

- Không sang bước code khi người chưa duyệt kế hoạch rõ ràng.
- Planner, test-runner, reviewer không sửa code. Implementer không commit, không đổi branch.
- Test-runner không cài dependency, không khởi động container, không ghi vào DB thật.
- Pipeline dừng ở PR: không merge, không bật auto-merge.

## License

[MIT](LICENSE)
