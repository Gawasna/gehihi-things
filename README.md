# Gehihi-Things

> **Behavior Containment & Hard-Gate System for Gemini Coding Agent (a.k.a "Gehihi")**

---

## 1. Lý do tồn tại (The "Why")

Gemini coding agent (thường bị mỉa mai là **"gehihi"**) vốn có những đặc tính cố hữu trong cộng đồng lập trình:
- **Nói một đằng, làm một nẻo:** Vâng dạ hứa hẹn nhưng không thực thi, tạo cảm giác hoàn thành giả tạo (agent theater).
- **Quy trình hên xui và cẩu thả:** Lúc nhớ lúc quên, bỏ qua kiểm tra, stage bừa bãi bằng `git add .`, commit cả file rác, file nhạy cảm và secret.
- **Nghịch lý văn bản (Prompt/Rule Paradox):** Trong khi các mô hình khác tuân thủ rule và workflow rất tốt, việc nhồi nhét quy trình dài dòng vào context của Gemini lại phản tác dụng. Lúc nó đọc, lúc nó lờ đi; context càng phình to thì nó càng mất định hướng và mất kiểm soát.

**Kết luận nền tảng:**  
> **Không thể kiểm soát Gehihi bằng lời khuyên hay rule/prompt suông.**  
> Cách duy nhất để đưa Gehihi vào kỷ luật là **kiểm soát cứng ở tầng runtime (Hard Gates via PreToolUse Hooks)**: Chặn lệnh trước khi chạy, bắt buộc dừng lại đối chất (force_ask), từ chối thẳng thừng mọi hành vi gian dối và chỉ nạp context tối thiểu khi cần thiết.

`gehihi-things` ra đời không phải để làm thêm một bộ tài liệu hướng dẫn, mà là một **hệ thống module cưỡng chế hành vi (Behavior Containment Modules)** được đóng gói sẵn để người dùng nhúng vào `.agents/` của bất kỳ dự án nào.

---

## 2. Hệ sinh thái Module ("Things")

- **`Gehihi Commit Gate` (`commit-gate`):** Chặn `git add .` / `-A`, cấm stage tệp rác và secret, chặn commit message mơ hồ/diễn xuất bot, chặn force-push, và ép đối chất checklist trước khi commit.
*(Các Things khác đang tiếp tục được phát triển)*

---

## 3. Cài đặt

```powershell
Invoke-RestMethod -Uri "https://raw.githubusercontent.com/Gawasna/gehihi-things/main/install.ps1" | Invoke-Expression
```

Script sẽ mở menu tương tác, chọn gói cần cài.

Chạy tự động (không hiện menu):
```powershell
& ([scriptblock]::Create((Invoke-RestMethod -Uri "https://raw.githubusercontent.com/Gawasna/gehihi-things/main/install.ps1"))) -Package commit-gate
```

Hoặc qua biến môi trường:
```powershell
$env:GEHIHI_PACKAGE="commit-gate"; Invoke-RestMethod -Uri "https://raw.githubusercontent.com/Gawasna/gehihi-things/main/install.ps1" | Invoke-Expression
```