# Codex 自动恢复：P0 验证记录

日期：2026-09-14。状态：只读诊断、P1 增量监测与本地候选队列、P2 纯额度判定/幂等状态机、App Server 只读连接层已实现；原 Desktop 的实时数据源与控制归属尚未验证，自动发送未开放，P0 端到端验证未通过。

> **勘误（2026-09-14 第二轮真实数据核验）**：本文下方“未找到可供脱敏录制的真实结构化额度失败样本”“确认当前兼容的 `event_msg/error` 是否确实写入 Desktop 会话文件”等结论已被实测推翻。要点：(1) 真实样本存在——709 个 rollout 文件（4.00 GB）中有 13 条结构化错误，其中 `usage_limit_exceeded` 8 条，全部来自 `Codex Desktop`；(2) 真实位置是收尾记录 `event_msg/task_complete` 的嵌套字段 `payload.error.codex_error_info`（snake_case），而不是 `event_msg/error`（出现 0 次）；(3) 全量数据中 `method == "turn/completed"` 与 camelCase `codexErrorInfo` 出现 0 次，即 rollout 文件不写运行时 JSON-RPC 信封；(4) 原实现因此无法识别任何真实中断，且会把 `task_complete` 判为“进展”而撤销候选，已修正解析器与诊断分类器。详细证据见 [待验证清单](CODEX_AUTO_RESUME_PENDING_VALIDATION.md)。

## 目标与阶段

2026-09-15 单次恢复验证：用户指定的原 Desktop 会话在最新轮次以 `usage_limit_exceeded` 失败后，经会话控制工具复核额度（短周期使用 6%，周使用 59%，`spendControlReached=false`），发送一次“继续”。宿主返回新轮次 `inProgress`、线程 `active`，无错误。`credits.hasCredits=false` 在此时仍存在，不能独立视为额度耗尽。此验证通过当前 Codex 任务工具执行，不代表 AgentMeter 已接通独立发送入口，也不代表目标任务已完成。解析器对嵌套错误限定 `payload.type == "task_complete"`，其他事件不触发候选。

在 AgentMeter Mac 内实现：真实额度中断 → 等待对应额度恢复 → 向原会话提交一次“继续” → 验证实际运行。

- P0：确认中断事件来源、原会话连接、提交与运行结果。当前新增设置 → ChatGPT →「Codex 自动恢复 · 实验性检测」。
- P1：可靠数据源验证后，实现增量监测、待恢复事件、取消和本地持久化。
- P2：接入账号与额度类别匹配、最新额度复核、单次提交、结果验证。
- P3：权限引导、通知、故障恢复和现有签名公证 DMG 发布流程。

## 本轮新增：持续监测与恢复基础逻辑

设置 → ChatGPT →「Codex 会话监测」提供默认关闭的「记录新的额度中断」开关。首次检查建立现有文件的 EOF 基线；之后跟随 AppModel 原有刷新与唤醒采集，只读取追加的数据，并支持手动立即检查。此开关仅控制观察，不开启自动发送，也不申请辅助功能权限。

- 每次最多枚举 20,000 条目录项，跟踪其中最近的最多 200 个文件；每文件每轮最多消费 512 KiB，每轮读取预算 4 MiB。读取预算、未知格式、残缺行和目录缺失都有状态提示。
- 仅接受 `originator = Codex Desktop` 的 session_meta，核对线程 ID。限额事件要求顶层结构化错误、失败 turn ID 和有效事件时间；聊天正文、普通失败和无日期记录不产生候选。
- 新记录过滤早于监测启用时间的事件。已有文件首次基线之前的错误不会导入，首次检查与启用之间的事件也可能不被导入；界面明确从首次检查后开始观察。
- 本地候选全部是待核验状态，不把本地日志当作账号、额度类别或当前执行端归属的证明。
- 检测到 task_started、task_complete、turn_aborted、user_message 等后续活动时撤销旧候选；取消/失效事件重复出现不会重新入队。默认仅最新候选保留 pending，旧候选不会在最新候选完成后自动接力执行。
- inode 变化、长度缩短、读取位置前 64 字节的 SHA-256 摘要变化都触发重新建立基线，并撤销旧候选。符号链接不参与扫描。部分行只保存偏移量，不保存行内容；过长行增量跳过，避免无限缓存。
- 本地 checkpoint 原子保存队列与读取位置，文件权限 0600，新建目录 0700；不接入 CloudKit。内容限于路径、项目名、线程/turn 标识、时间、状态、偏移和摘要，不保存正文、凭据或部分行。存储上限 4 MiB、候选上限 500，达到上限时不继续加入新候选；不会自动删除去重记录。
- 检查结果先保存再发布；取消或关闭开关会使进行中的旧扫描结果失效。存储损坏不会当成空队列，存储失败暂停监测；关闭后重新开启会重新建立基线。
- Core 的恢复策略独立于展示用 QuotaSnapshot：要求已验证的运行时来源、匹配的账号/limit ID、完整且有效的额度窗口、60 秒以内的新额度和 15 秒以内的原会话状态。缺少任一证据即 needsVerification；全部阻塞窗口最晚 reset + 20 秒只用于安排重新检查，不证明额度已恢复。
- 一次性尝试标记必须由调用方保存后才可发送；submitted 不等于 resumed。仅匹配提交后的 turn ID 的实际运行证明才能标记 resumed。重启遇到 attempting/submitted 会变为 uncertain，不自动重试。这些是已测试的基础逻辑，尚无控制器调用它们发送消息。

代码分布：Core/Automation 放策略与队列；Mac/CodexAutomation 放解析、增量扫描、checkpoint、协调器与设置 UI。实际 Desktop 接入和可靠错误样本仍是下一阶段条件；本轮未改动 Codex 的配置、会话或私有 socket。

## 本机验证结果

### 新增：已有 App Server 的只读连接

设置 → ChatGPT →「Codex 运行连接」提供手动检查。它是连接诊断，不是自动恢复开关。

- 从唯一运行宿主的 bundle 选择内置 CLI，不使用 PATH 中版本可能不同的 CLI。
- 只接受监测 home 下已存在、属于当前用户的默认控制 socket；缺失时直接报告不可用。不会启动/重启 daemon，不会调整 Codex 配置，不会使用 Desktop 私有工具 socket。
- 通过 `codex app-server proxy --sock PATH` 连接已有服务。有限协议流程仅允许 `initialize` → `initialized` → `account/rateLimits/read` → 可选的 `thread/read(includeTurns: false)`。没有通用 RPC 发送入口，也不调用 thread/resume、turn/start 或审批接口。
- 验证 initialize 响应中的 codexHome 与监测目录一致；验证 RPC 响应 ID 和指定线程 ID。拒绝异常响应及服务端操作请求。只忽略通知，不替用户处理审批或凭据刷新请求。
- 连接检查默认 8 秒超时，支持取消；单条响应上限 1 MiB、stdout/stderr 合计上限 2 MiB。stderr 只排空，不记录内容。结束时只终止本次启动的 proxy 子进程，不停止共享服务。
- 额度解析保留 accountId、limit ID 与 primary/secondary 窗口。优先使用 rateLimitsByLimitId；显式空 map 不回退到旧单桶。缺少账号、窗口时长/reset 时间、桶标识冲突或非法数值时不能生成有效判定依据。
- 新增费用/使用限制状态：`spendControlReached` 为 true 或工作区 credits/usage limit 阻塞时，窗口剩余额度不能证明已恢复；字段缺失或未知的新限制类型保持 unknown。Core `CodexResumeQuota` 默认 blockingState 也为 unknown，调用方必须显式提供明确状态。
- UI 只展示连接结果、额度类别数量和线程状态，不展示账号 ID、标题或预览正文，不保存 probe 响应。
- 即使只读检查成功，也不能证明服务由当前 Desktop 执行端持有，或最新失败轮次仍然匹配；probe 结果始终不授权自动恢复，不改变候选的 runtimeEvidenceVerified。

本轮 Computer Use 在访问 `com.openai.codex` 时明确拒绝，原因是该应用不允许通过该工具访问。未尝试通过其他 UI 技术绕过限制，辅助功能路径的实机验证仍未完成。App Server 协议与进程测试使用隔离的模拟子进程，不把模拟成功当成真实 Desktop 自动恢复成功。

1. 实际宿主为 `/Applications/ChatGPT.app`，其中包含 Codex Framework 与 `Contents/Resources/codex`。不能硬编码只查找 `Codex.app`。
2. Homebrew CLI 为 0.146.0；Desktop 内置 CLI 为 0.153.4。适配协议必须与实际宿主匹配，不能默认使用 PATH 中的 CLI。
3. `codex app-server daemon version` 无法连接默认 `~/.codex/app-server-control/app-server-control.sock`，原因是路径不存在。Desktop 主进程以 app-server 默认 stdio 方式运行；检查未找到它对外监听的命名 Unix socket。这里只能判定本机默认接入不可用，不能推出所有版本均无接入途径。
4. 最近 30 个 JSONL 的只读检查均显示来源为 Codex Desktop，观察到 task_started、task_complete、turn_aborted、token_count 等事件，没有 `event_msg/error`。文本中出现限额关键词，但不能作为系统错误证据。~~未找到可供脱敏录制的真实结构化额度失败样本。~~ **已由第二轮全量核验推翻：`event_msg/error` 确实不存在，但结构化额度失败存在于 `task_complete` 的嵌套 `error` 字段中，共 13 条（8 条为 `usage_limit_exceeded`）。**
5. 本轮没有发送消息、开启 daemon、改动 Codex 配置或连接其私有工具 socket，也没有请求辅助功能权限。

## 已实现的诊断

- 用户点击后才运行，不接入后台额度采集循环；不会改变原有通知与额度数据。
- 从运行中应用的 bundle 检测内置 Codex 可执行文件，支持实际的 ChatGPT.app 宿主。
- 使用当前进程的绝对 `CODEX_HOME`，未设置时使用 `~/.codex`。GUI 启动通常不继承 shell 环境；该路径仍不等于已验证的 Desktop 账号/存储匹配。
- 检查默认控制路径是否为 socket，仅报告存在性，不将它视为成功连接。
- 最多枚举 20,000 个目录条目，选择其中最新的最多 30 个 JSONL，每个最多读取末尾 512 KiB。不跟随枚举到的符号链接；目录截断、文件截断、读取失败和残缺记录均明确报告。
- 只统计结构化错误，且从不搜索消息正文与工具输出：**已实测的真实形状**为收尾记录 `event_msg/task_complete` 的嵌套字段 `payload.error.codex_error_info`（值 `usage_limit_exceeded`）；另保留运行时信封 `turn/completed` 中 failed + `codexErrorInfo` 与顶层 `event_msg/error` 两个兼容分支，前者在本机 rollout 文件中出现 0 次，后者为待验证分支。三层都不读文本。
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

P1/P2 基础逻辑：Core 恢复策略/队列 10 项测试、Mac 增量监测/存储/协调器 13 项测试，以及原诊断 10 项回归测试，共 33 项通过。覆盖账户与额度类别不匹配、周限额仍阻塞、过期快照、部分/错误窗口、最新候选策略、乱序活动、恢复去重、JSONL 部分行、截断后重新增长、存储损坏与文件权限。Mac app 编译通过，中英文 strings 和补丁检查通过；未做真实自动恢复端到端测试。

设置预览进程已启动，但 Computer Use 工具在读取界面时超时，未完成设置页面的视觉检查。此项不作为已通过的 UI 验收。

补充本机只读兼容核验：最近 30 个会话头均在 64 KiB 内可读取，均为 Codex Desktop；其中 18 个 `session_id` 与 `id` 不同。30 个头部 `id` 均与文件名及本地只读线程索引中的 id/rollout_path 一致。解析器以 `id` 识别线程，不要求 `session_id` 相等；生产监测不读取该索引数据库。该核验不代表已找到限额错误或已连通原执行端。

只读连接层验证：Mac 三组测试共 32 项通过（连接协议/模拟子进程 9、增量监测 13、原诊断 10），Core 策略 11 项通过，共 43 项。覆盖协议步骤白名单、目录/线程/响应 ID 不一致、服务端额外操作请求、分段输出、超时、取消、进程提前退出、输出上限、缺失 socket、稀疏额度与工作区费用限制。本机默认控制 socket 再次只读检查仍不存在；未启动新的 Codex 服务，未在真实 Desktop 上发送任何消息。中英文资源与补丁检查通过。由于工具禁止访问 Codex UI，辅助功能与视觉检查仍未通过实机验收。
