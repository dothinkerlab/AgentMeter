# Codex 自动恢复：P0 验证记录

日期：2026-09-14。状态：只读诊断原型已实现；自动发送未开放，P0 端到端验证未通过。

## 目标与阶段

在 AgentMeter Mac 内实现：真实额度中断 → 等待对应额度恢复 → 向原会话提交一次“继续” → 验证实际运行。

- P0：确认中断事件来源、原会话连接、提交与运行结果。当前新增设置 → ChatGPT →「Codex 自动恢复 · 实验性检测」。
- P1：可靠数据源验证后，实现增量监测、待恢复事件、取消和本地持久化。
- P2：接入账号与额度类别匹配、最新额度复核、单次提交、结果验证。
- P3：权限引导、通知、故障恢复和现有签名公证 DMG 发布流程。

## 本机验证结果

1. 实际宿主为 `/Applications/ChatGPT.app`，其中包含 Codex Framework 与 `Contents/Resources/codex`。不能硬编码只查找 `Codex.app`。
2. Homebrew CLI 为 0.146.0；Desktop 内置 CLI 为 0.153.4。适配协议必须与实际宿主匹配，不能默认使用 PATH 中的 CLI。
3. `codex app-server daemon version` 无法连接默认 `~/.codex/app-server-control/app-server-control.sock`，原因是路径不存在。Desktop 主进程以 app-server 默认 stdio 方式运行；检查未找到它对外监听的命名 Unix socket。这里只能判定本机默认接入不可用，不能推出所有版本均无接入途径。
4. 最近 30 个 JSONL 的只读检查均显示来源为 Codex Desktop，观察到 task_started、task_complete、turn_aborted、token_count 等事件，没有 `event_msg/error`。文本中出现限额关键词，但不能作为系统错误证据。未找到可供脱敏录制的真实结构化额度失败样本。
5. 本轮没有发送消息、开启 daemon、改动 Codex 配置或连接其私有工具 socket，也没有请求辅助功能权限。

## 已实现的诊断

- 用户点击后才运行，不接入后台额度采集循环；不会改变原有通知与额度数据。
- 从运行中应用的 bundle 检测内置 Codex 可执行文件，支持实际的 ChatGPT.app 宿主。
- 使用当前进程的绝对 `CODEX_HOME`，未设置时使用 `~/.codex`。GUI 启动通常不继承 shell 环境；该路径仍不等于已验证的 Desktop 账号/存储匹配。
- 检查默认控制路径是否为 socket，仅报告存在性，不将它视为成功连接。
- 最多枚举 20,000 个目录条目，选择其中最新的最多 30 个 JSONL，每个最多读取末尾 512 KiB。不跟随枚举到的符号链接；目录截断、文件截断、读取失败和残缺记录均明确报告。
- 只统计顶层结构化错误：官方 App Server `turn/completed` 中的 failed + `usageLimitExceeded`；另兼容待验证的 rollout `event_msg/error` 字段。后者是诊断兼容分支，不是已经证明存在的 Desktop 数据源。
- 不搜索用户/助手消息或工具输出中的关键词；不保留路径、线程 ID、正文或凭据，只在内存显示汇总计数。无 CloudKit 接入。
- 所有计数都是历史抽查信息，不是待恢复会话数量；零错误不表示没有中断。

## P0 尚未通过的条件

必须通过以下实测才能开放自动发送：

1. 使用下一次自然发生的限额中断，确认失败事件所在数据源、稳定线程 ID、失败 turn ID，以及它是否在重启后仍可读取。只保存必要的脱敏结构，不保存用户对话。不要为了造样本主动耗尽额度。
2. 在与正常工作隔离的测试会话中验证：连接原 Desktop 执行端、保持工作目录与原权限、提交一次消息、观察相同 turn 的实际输出。不得用另起 CLI 或另一 app-server 进程假装已接入 Desktop。
3. 如果该宿主没有可用的公开连接，验证辅助功能路径能否可靠绑定会话身份、辨别草稿和运行状态；只按用户可见标题或屏幕坐标不能通过验收。
4. 如果限额事件或会话身份仍不可可靠取得，停留在诊断/通知能力，不使用关键词猜测和盲目回车。

## 后续恢复规则

- 默认关闭；开启后默认仅最近一个候选，固定提示词“继续”。
- 所有相关 blocking window 的最晚 reset 仅用于安排检查；reset 后约 20 秒请求新数据，确认账号、额度类别及所有相关窗口恢复。
- 现有 `QuotaSnapshot` 是展示/同步模型，自动恢复需要另行保留仅本地的账号和额度类别依据；不能把任意 Codex 余额当成当前线程额度。
- 发送前再次检查最新 turn、取消状态、活跃状态；用户手动继续、归档、切换账号或有新一轮时作废候选。
- 事件 ID 使用账号本地标识 + thread ID + failed turn ID。发送前写入一次性尝试标记；请求不明时核对原线程，不自动重发。
- 新用户消息仅为 submitted；实际模型/工具活动或正常完成才为 resumed。等待审批、再次受限、状态不明分别处理，不替用户审批。
- 锁屏时辅助功能路径等待解锁，睡眠后重新检查额度与会话；不承诺睡眠期间执行。
- Core 放纯策略与状态机；Mac 放会话数据源、执行器、存储、协调器。会话信息全部本地保留。

## 依据

[官方 App Server 文档](https://learn.chatgpt.com/docs/app-server) 描述了 `account/rateLimits/read`、`thread/read`、`thread/resume`、`turn/start` 和 turn 事件；该文档仍对实验性服务/传输作出限制。存在协议方法不等于已验证可从第三方接入运行中的 Desktop。

本机 0.146.0 和 Desktop 0.153.4 各自生成的 JSON Schema 均确认 `CodexErrorInfo.usageLimitExceeded` 为 camelCase；它不同于上游错误文本中的 snake_case。宿主升级后的协议需再次核验。

## 验证范围

`CodexSessionDiagnosticsTests` 使用合成 fixture 验证结构化匹配、关键词误判、非额度错误、缺失 ID、残缺 JSONL、最新文件选择、读取边界、超长行、符号链接、枚举上限和源文件只读性。合成测试不能替代真实限额恢复验证。

Xcode 26.5 已完成 Mac app 与测试宿主编译，10 个针对性 XCTest 全部通过。测试使用 `CODE_SIGNING_ALLOWED=NO`，产物尚未签名公证。中英文 strings 通过 `plutil -lint`，补丁通过 `git diff --check`。

另将相同 Swift 扫描器编译为临时只读 probe，对本机数据实测：抽查 30 个文件，其中 20 个读取尾部；结构化限额错误 0、读取失败 0、无效/残缺记录 0，目录枚举完整。该结果只是当前抽查范围的结果，不是全历史无错误的断言。
