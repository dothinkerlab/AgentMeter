# Codex 自动恢复：待验证清单

更新日期：2026-09-14（第二轮：真实数据核验）。代码基线：`a47933f`，另有本轮未提交的解析器与测试改动。

目标：真实额度不足导致任务中断后，等待对应额度恢复，在原 Codex Desktop 任务中提交一次“继续”，并确认任务实际恢复运行。

**自动发送仍未实现，真实端到端验证仍未通过。** 本轮完成的是 V01 的真实数据源核验，并据核验结果修正了一个使该功能无法工作的实现缺陷。已实现部分为只读诊断、增量监测、本地候选队列、恢复判定与幂等状态机、App Server 只读连接检查。

## 本轮进展摘要

### 2026-09-16：手动验证反馈与执行流程

- 用户报告手动验证界面成功；测试线程/轮次 ID 未补充，此处记录为用户反馈，不替代发送器实机证据。
- Core 执行器与传输接口已有模拟测试：先持久化尝试再提交、核验线程及新轮次回执、执行验证、取消和未知结果不重试。22 项 Core 恢复相关测试通过。
- 无生产传输实现，未绑定 Mac coordinator。默认控制 socket 本轮复核仍缺失，独立发送继续受阻；V02–V06 不标记通过。
- 后续必须验证条件式发送或其他可靠的并发保护、原宿主身份与候选账号绑定，并把执行器纳入现有 checkpoint 的唯一写入者；不能仅根据读取成功就发送。

### 2026-09-15：用户指定会话的单次恢复

- 原会话最后失败轮次有 `event_msg/task_complete.error.codex_error_info == usage_limit_exceeded`；发送前通过宿主工具复核最新轮次仍为 failed。
- 同一宿主当前额度短周期剩余 94%，周剩余 41%，`spendControlReached=false`。此时 `credits.hasCredits=false`，说明该字段不能单独判定额度中断。
- 用户明确授权后，使用当前 Codex 会话控制工具向原线程发送一次“继续”；宿主返回新轮次 `inProgress`、线程 `active`，无错误。未重复发送，也未使用额度重置信用。
- 此结果是宿主接收并启动新轮次的证据；不代表目标业务任务已完成。AgentMeter 的独立发送器仍未实现，V02–V06 的应用端验收仍待完成。
- 解析器和诊断扫描将嵌套错误限定于 `task_complete`；补测其他事件、手动中断和无额外积分不触发候选。Mac 自动恢复相关回归测试 39 项通过，0 失败。

1. **真实额度中断样本找到了。** 第一轮结论“尚无真实结构化错误样本”已被推翻：对 709 个真实 rollout 文件（合计 4.00 GB）做全量只读枚举，命中 13 条结构化错误记录，其中 `usage_limit_exceeded` 8 条，全部来自 `originator = Codex Desktop`。
2. **真实结构与原实现不一致，原实现无法识别任何真实中断。** 错误不在 `event_msg/error` 记录里，而在收尾的 `event_msg/task_complete` 的嵌套字段 `payload.error.codex_error_info`。全量 4.00 GB 中 `method == "turn/completed"`、camelCase `codexErrorInfo`、`usageLimitExceeded` 的出现次数均为 **0**。
3. **已修正解析器与诊断分类器**，新增真实分支并保留原兼容分支；`task_complete` 携带额度错误时不再被当作“进展”而撤销候选。用同一份真实文件做 A/B 对照，生产诊断代码的结构化限额错误计数由 **0 → 5**。
4. 测试由 44 项增至 **49 项**（Mac，全部通过）；Core 的 Codex 相关测试 **41 项**通过。
5. 自动发送入口仍不存在：连接层仅暴露 4 个只读方法，`canAutomaticallyResume` 恒为 false。

## 本轮发现的实现缺陷（阻塞 V01）

| 项 | 原实现假设 | 真实数据（本机 709 文件 / 4.00 GB） |
| --- | --- | --- |
| 记录类型 | `event_msg`，`payload.type == "error"` | `event_msg`，`payload.type == "task_complete"`；`payload.type == "error"` 出现 0 次 |
| 字段位置 | `payload.codex_error_info` | `payload.error.codex_error_info`；payload 层出现 0 次 |
| 枚举拼写 | `usage_limit_exceeded` / `usageLimitExceeded` | rollout 文件里只有 snake_case；camelCase 属于运行时协议 Schema |
| 顶层 `turn/completed` | 主匹配分支 | 全量 0 次 —— rollout 文件不写 JSON-RPC 运行时信封 |
| 失败记录的归类 | `task_complete` 属于“进展”，会撤销候选 | 失败记录本身就是 `task_complete`，原逻辑会撤销它本应创建的候选 |

影响：修正前，即使真实发生额度中断，监测也不会生成任何候选。这是 V01 阻塞的直接原因，现已修复；但“真实中断 → 生成候选”的现场回放仍未完成（历史记录按设计不会补生成候选，见 V01 说明）。

## 优先级与当前阻塞

| 编号 | 优先级 | 待验证内容 | 当前条件 |
| --- | --- | --- | --- |
| V01 | P0 | 真实额度中断事件及其可靠来源 | **结构化来源已确证并修正解析**；现场中断回放未完成 |
| V02 | P0 | 原 Desktop 执行端的连接与身份 | 本机默认控制 socket 仍不存在；新发现宿主持有的 `~/.codex/ipc/ipc.sock`，但用途与授权未确认 |
| V03 | P0 | 账号、额度类别与会话归属 | 解析与纯策略已有测试，尚未与真实候选绑定 |
| V04 | P0 | 发送前会话状态与最新失败轮次 | 需先补齐运行时证据获取与复核 |
| V05 | P0 | 一次性发送与实际恢复 | 发送器不存在；连接层无发送方法 |
| V06 | P0 | 异常、崩溃与不确定结果处理 | 状态机已有测试，真实发送链路待开发 |
| V07 | 条件 P0 | 辅助功能备选路径 | 当前工具禁止访问 Codex UI；新发现的 socket 不属于已批准路径 |
| V08 | P1 | 监测长期运行、容量与持久化 | 边界测试通过，实机耐久与真实 checkpoint 待验证 |
| V09 | P1 | 设置界面及用户操作 | 文案与状态分层已核查；视觉验收仍未完成 |
| V10 | P1 | 隐私、宿主与版本兼容性 | 隐私面与宿主选择已实测；协议兼容矩阵待建立 |
| V11 | 发布前 | 签名、安装、升级与系统生命周期 | 当前仅完成未签名开发构建 |
| V12 | 发布前 | 完整实机验收 | 依赖前述关键项目通过 |

P0 项未通过前，自动发送应保持不可用。V07 是可选技术路径，不要求在公开连接已满足条件时同时实现。

## V01：真实额度中断数据源

前置条件：等待下一次自然发生的额度中断，不主动消耗额度制造样本。

- [x] 记录宿主及内置 CLI 版本、事件来源、发生时间、线程 ID、失败 turn ID；只保留必要的脱敏结构。已记录：事件来源 `event_msg/task_complete`，8 条记录时间分布在 2026-07-17 至 2026-09-14，`payload.turn_id` 存在，线程 ID 取自 `session_meta.id`（709/709 与 rollout 文件名内嵌 UUID 一致）。未保存任何正文。
- [x] 确认实际错误类型与字段位置，验证 `usageLimitExceeded` 的真实编码；确认当前兼容的 `event_msg/error` 是否确实写入 Desktop 会话文件。结论：**`event_msg/error` 从未写入**（0 次）；真实位置是 `payload.error.codex_error_info`，值为 snake_case。原兼容分支保留但已标注为未观测。
- [x] 确认失败事件重启后仍可读取；若只存在于运行时通知，先开发可靠的事件订阅和落盘方案，再验证断线重连。已验证：7 月与 9 月的失败记录至今可读，属于持久化落盘而非仅运行时通知，因此不触发“另开发事件订阅”分支。
- [x] 验证错误与 `task_complete`、`turn_aborted` 等活动事件的实际先后关系，不因同一失败轮次的收尾事件撤销应保留的候选。已验证顺序：失败记录即收尾的 `task_complete`；3/7 个文件中它就是文件最后一行，其余被 `thread_settings_applied` + `task_started`（用户手动重试）跟随。已修正“自我撤销”并以单元测试断言。
- [x] 验证用户引用错误文本、助手解释限额、工具输出关键词、普通网络错误均不产生候选。真实数据里存在 63 处纯文本命中、分布在 6 个文件（消息正文与工具输出引用错误字符串），均不产生候选；另有 `other` 3 条、`server_overloaded` 2 条非额度错误同样不产生候选。
- [ ] 明确本地 Desktop、CLI、云端任务和子任务的支持范围；无法确认来源的事件不能进入自动发送流程。已量化但未定案：本机 originator 分布为 `Codex Desktop` 691、`codex_cli_rs` 8、`codex_exec` 5、`codex_work_desktop` 4、`codex-tui` 1，当前只接受 `Codex Desktop`。云端任务与子任务（`parent_thread_id` 148、`forked_from_id` 47、`agent_nickname` 27）的取舍尚未决定。

已达成：从真实中断事件稳定识别唯一线程和失败轮次；普通文本不能触发恢复。未达成：**现场级回放**——增量监测在首次检查建立 EOF 基线、且只接受晚于监测启用时间的事件，因此历史样本不会补生成候选，“真实中断 → 入队 → 额度恢复 → 发送”的完整链路仍需一次现场中断才能验证。

## V02：连接原 Desktop 执行端

当前事实（本轮实测）：本机宿主为 `/Applications/ChatGPT.app`（`com.openai.codex`，版本 26.903.71938，CFBundleVersion 8576，Codex Framework 152.0.7977.83），内置 CLI 0.153.4，PATH CLI 0.146.0；默认 `~/.codex/app-server-control/app-server-control.sock` 及其目录**均不存在**。宿主确实在运行，并持有 `~/.codex/ipc/ipc.sock`（类型 socket、属主当前用户、权限 0600）。Desktop 子进程以 `codex app-server --listen stdio://` 方式运行，即不使用命名监听 socket。

- [ ] 找到该版本支持的公开连接方式，并证明连接对应正在使用的 Desktop 执行端及其存储目录。部分进展：`codex app-server proxy --sock <PATH>` 是公开的 proxy 入口，但服务端必须存在控制 socket；`codex app-server daemon version` 实测报 `failed to connect to …app-server-control.sock: No such file or directory`。新发现的 `~/.codex/ipc/ipc.sock` 由宿主主进程持有，但它是宿主自有 IPC，用途与授权未确认，**不得当作已批准的公开接入路径**。
- [ ] 使用实际宿主内置 CLI 完成初始化与只读额度查询；验证目录、响应 ID、线程 ID 校验在真实服务上正常工作。被 socket 缺失阻塞，本轮无法执行。
- [x] 验证相同 `codexHome` 和可读取线程不足以证明执行端归属时，系统会继续阻止自动发送。代码核查：`CodexRuntimeProbeResult.canAutomaticallyResume` 恒为 false，`CodexResumePolicy` 在缺少运行时证据时返回 `needsVerification`；候选始终保持 `runtimeEvidenceVerified = false`。
- [x] 验证宿主退出、重启、多宿主、socket 失效或连接超时均能明确结束检查，且不停止共享服务。由 `CodexRuntimeReadProbeTests` 9 项覆盖（分段输出、超时、取消、进程提前退出、输出上限、缺失 socket）；证据为模拟子进程，非真实 Desktop。
- [x] 确认接入不会另起并行执行器，不以新建 CLI / app-server 能读取历史来代替原任务接入成功。代码核查：只调用 `app-server proxy`，从不执行 daemon start/restart，从不加载或 resume 线程。

未达成：有可重复的原执行端归属证明，并能取得后续发送所需的当前任务状态。只读 probe 成功本身不满足此标准；当前 `canAutomaticallyResume` 始终为 false。

## V03：账号与额度恢复判定

前置条件：先实现真实候选的账号、limit ID、相关窗口及运行时来源证据绑定。当前本地候选保持 `runtimeEvidenceVerified = false`；本轮同时确认，在解析器修正前该候选**根本无法产生**。

- [ ] 将真实失败任务绑定到正确账号和额度类别，覆盖多额度桶、模型对应不同限制、账号切换及目录不匹配。
- [ ] 验证所有相关阻塞窗口均恢复后才能继续；短周期恢复但周额度仍耗尽时保持等待。
- [ ] 验证最晚 reset + 20 秒只触发重新查询，不能直接视为恢复；补齐实际调度与协调器接线。
- [ ] 验证费用限制、工作区 credits / usage 限制、字段缺失、null、新限制类型及数值舍入，不会被误判为可用。
- [ ] 验证额度数据超过 60 秒、早于中断、时间在未来或窗口不完整时停止发送；旧版本缺字段时显示可理解的原因。
- [ ] 核对去重身份设计：当前候选键为 thread ID + failed turn ID，而计划包含账号本地标识；证明跨账号隔离成立，或先补齐账号作用域与迁移逻辑。

通过标准：实际恢复依据来自失败任务对应的账号和额度桶；任何未知条件都不能开放发送，也不自动兑换额度重置次数。现状：纯策略层已有 12 项测试覆盖上述判定，但全部使用合成输入，未与真实账号绑定。

## V04：发送前会话复核

当前只读 `thread/read(includeTurns: false)` 结果不足以证明最新失败轮次仍匹配，也未提供完整归档与执行归属证据。需先开发可靠的证据获取；本轮连接检查因 socket 缺失无法执行，此项无新增证据。

- [ ] 取得新鲜会话状态，确认线程匹配、未归档、空闲且最新轮次仍为目标失败 turn；超过 15 秒的证据不可直接使用。
- [ ] 用户手动继续、输入新消息、取消候选、归档任务或切换账号后，旧候选不再发送。
- [ ] 在“复核结束到发送”之间制造用户操作，验证竞争条件不会向已经变化的任务追加“继续”。
- [ ] 验证默认仅最新候选可恢复；取消或完成最新候选后，旧候选不会自动接力。

通过标准：只有仍符合原始中断条件的最新候选能够提交，用户操作能够可靠使候选失效。现状：本地侧已有“最新候选 + 后续活动失效”测试（真实顺序证据见 V01），但运行时侧证据获取未实现。

## V05：单次发送与运行结果

前置条件：V01–V04 通过；先开发发送器、证据绑定和协调器接线。**本轮确认现有只读连接层不包含发送入口**：协议层只允许 `initialize` / `initialized` / `account/rateLimits/read` / `thread/read`，不暴露 `thread/resume`、`turn/start` 或审批接口。

- [ ] 在隔离的测试任务中，持久化一次性尝试标记后向原任务提交固定文本“继续”，确认恰好提交一次。
- [ ] 确认原工作目录、模型设置、权限与审批策略保持正确，没有并行执行同一任务。
- [ ] 区分请求已提交、排队、等待审批、模型实际运行、再次受限和失败，不能把接口返回成功直接显示为已恢复。
- [ ] 只接受本次提交返回的新 turn ID 对应的模型/工具活动或正常完成作为恢复证据，其他任务通知不改变结果。
- [ ] 验证需要审批时停留在等待状态，不自动批准操作。

通过标准：原任务收到一条“继续”，并有匹配轮次的实际运行证据；失败与等待状态均可见且不误报成功。现状：状态机已实现且被测试，但无调用方，发送器未开发。

## V06：崩溃、断线与结果不确定

- [ ] 分别在写入尝试标记前后、提交过程中、提交成功后但结果未保存时终止 AgentMeter，再重启验证不会重复提交。
- [ ] 验证 attempting / submitted 在重启后转为 uncertain 并持久化，不因下一轮扫描重新尝试。
- [ ] 补齐并验证 uncertain 的核对与用户处理流程；在无法确认上次请求是否生效时不得自动重发。
- [ ] 验证磁盘写入失败、目录无权限、checkpoint 损坏时停止发送，且不会清空去重历史后继续。
- [ ] 验证网络/进程中断、延迟回复、重复通知、提交后立即再次限额及取消与扫描并发。

通过标准：任何单点故障都不会造成重复“继续”；不确定结果有明确状态和可执行的处理方式。现状：Core 状态机测试覆盖 attempting/submitted→uncertain 与不自动重试；`CodexResumeCoordinator` 在存储损坏时暂停监测并关闭开关（已有测试）。真实发送链路待开发。

## V07：辅助功能备选路径（条件项）

仅在无法通过公开连接完成目标时评估。当前 Computer Use 明确禁止访问 `com.openai.codex`，因此该路径尚未实测；不得绕过工具限制。

本轮新增事实：本机存在宿主自有的 `~/.codex/ipc/ipc.sock`（属主当前用户、0600），由主进程持有多路连接。它是宿主内部 IPC，不是已文档化的第三方接入点；在确认其用途与授权前，不应据此认为“已有可用公开连接”，也不应改用它绕过 socket 缺失结论。

- [ ] 验证辅助功能能可靠绑定线程身份，而非仅凭标题或固定屏幕坐标。
- [ ] 验证多窗口、任务切换、输入焦点变化、已有草稿、弹窗和运行中状态，不覆盖草稿或误发到其他任务。
- [ ] 验证权限按需申请、拒绝或撤销后的提示，以及锁屏等待和解锁后的重新复核。

通过标准：会话身份和输入目标可被可靠确认；任何无法确认的状态均停止操作。无法达标时保留诊断能力。

## V08：监测与持久化耐久性

- [ ] 实机长时间运行，覆盖高频追加、多个活跃文件、部分行、超长行、轮转、截断、删除和权限变化。
- [ ] 达到 20,000 条枚举项、200 个跟踪文件、每文件 512 KiB / 每轮 4 MiB 预算时，验证提示准确、扫描有进展且不会长期遗漏某些活跃文件。
- [ ] 验证首次 EOF 基线、关闭再开启及启用到首次检查之间的事件处理符合界面说明。
- [ ] 验证系统时间调整、睡眠和长时间离线后的时间过滤，不意外导入历史错误。
- [ ] 达到 500 个候选或 4 MiB checkpoint 上限后，验证暂停/拒绝写入行为；先补齐必要的容量处理和损坏恢复体验，再验证可用性。
- [x] 在真实文件系统检查文件 0600、新建目录 0700、原子保存及源会话文件只读；确认保存失败不会发布未持久化队列。已由单元测试在真实临时文件系统上断言（保存文件权限 0o600、临时文件 + `rename` 原子替换、检查不修改源文件、先持久化后发布）。注意：**本机尚未产生任何真实 checkpoint**，`~/Library/Application Support/AgentMeter` 不存在，因此应用真实路径上的落盘尚未发生。

通过标准：资源使用有界，截断与遗漏风险明确可见；读取位置和候选始终一致，异常不会丢失去重保护。本轮额外观察：在 11 个真实文件（8 个被截取尾部）上，512 KiB 上限使 2 条真实额度错误落在尾部之外未被计入——截断导致的漏检风险是真实存在的，需在界面与通过标准中明确。

## V09：设置界面与交互

当前设置页预览此前因工具读取超时而未完成视觉验收；本轮未尝试 UI 截图，**视觉验收仍未完成**。

- [ ] 检查中文、英文、浅色、深色及较小窗口下的排版、换行、按钮和状态可读性。
- [ ] 检查默认关闭、立即检查、取消候选、关闭监测，以及扫描进行中重复操作的反馈。
- [ ] 验证无目录、无 socket、格式未知、读取截断、存储失败、容量上限的提示与实际状态一致。
- [x] 确认用户能分辨历史诊断计数、待恢复候选和只读连接结果；当前界面不暗示自动发送已经可用。已按文案核查（非视觉验收）：诊断区写明“历史错误不代表当前仍受限；未发现错误也不代表没有中断”，监测区写明“当前不会自动发送‘继续’”，候选状态为“待核验账号、额度与原会话，尚未恢复”，连接区写明“只读连接成功；尚未验证该服务属于当前 Desktop”。中英文键值齐全。
- [ ] 自动发送实现后，再验证启用入口、等待原因、取消、审批等待和不确定结果的完整交互。

通过标准：设置页没有遮挡或状态误导，用户能理解当前是否会发送以及为什么等待。现状：文案层面达标，视觉与交互层面未验收。

## V10：隐私与兼容性

- [x] 实查 checkpoint、应用日志和同步内容，不保存对话正文、凭据、原始 probe 响应或部分行；会话元数据不进入 CloudKit。已实测：`~/Library/Application Support/AgentMeter` 不存在（从未产生 checkpoint）；`~/Library/Logs/AgentMeter/agent.log` 中 `codex_error_info`、`usage_limit_exceeded`、`thread_id`、`codexSessionMonitoring`、`checkpoint.json` 出现次数均为 0，即监测子系统未向日志写入任何会话信息；`AgentMeterMac/CodexAutomation` 与 Core 的 `Automation` 目录内无任何 CloudKit / `NSUbiquitous` / `CKContainer` 引用。日志中带 `[codex]` 前缀的行属于既有额度功能，不含会话内容。
- [x] 验证真实宿主识别、内置 CLI 选择、自定义 `CODEX_HOME`、GUI 不继承 shell 环境及多宿主情况。已实测：含 `Contents/Resources/codex` 的宿主 bundle 唯一（`/Applications/ChatGPT.app`），多宿主场景不成立；PATH CLI 0.146.0 与内置 CLI 0.153.4 版本不同，印证“必须选用内置 CLI”的必要性；本 shell 中 `CODEX_HOME` 未设置，回落到 `~/.codex`，与 GUI 不继承 shell 环境的行为一致。
- [ ] 建立实际支持的 macOS、宿主和协议版本记录；宿主升级、字段缺失与未知字段时验证保守降级。部分进展：本轮记录了 macOS 26.6.2 (25G83)、宿主 26.903.71938、内置 CLI 0.153.4；协议版本兼容矩阵尚未建立。
- [x] 验证连接检查超时、取消、输出上限及退出后无残留 proxy，不影响共享服务。由 `CodexRuntimeReadProbeTests` 覆盖；证据为模拟子进程。

通过标准：数据仅按设计在本地保存；不支持的宿主或协议能明确报告不可用，不猜测后继续操作。

## V11：安装、升级与系统生命周期

- [ ] 完成签名、公证和 DMG 构建，在实际安装路径启动并验证 Gatekeeper 与权限引导。
- [ ] 验证首次安装、旧版升级、已有 checkpoint 加载及未来格式迁移；不把不兼容状态当成空队列。
- [ ] 验证登录启动、手动退出重启、睡眠唤醒及锁屏；唤醒后重新查询额度和任务状态，不承诺睡眠期间执行。
- [ ] 记录空闲和活跃监测下的 CPU、内存、磁盘读取和查询频率，检查失败后无高频重试循环。
- [ ] 在项目支持的最低 macOS 版本及当前版本完成运行检查。

通过标准：可分发构建能正常安装升级，系统生命周期变化不会产生重复发送或陈旧额度误判。未签名开发构建不能替代此项验收。现状：本轮构建使用 `CODE_SIGNING_ALLOWED=NO`，未签名。

## V12：最终实机验收

- [ ] 完成至少一次自然额度中断 → 生成候选 → 对应额度恢复 → 原任务收到一次“继续” → 匹配新轮次实际运行的完整记录。
- [ ] 复验周额度仍阻塞、用户已手动继续、取消候选、切换账号和重启后不确定状态，确认均不误发。
- [ ] 保存脱敏证据与实际版本，明确失败项、未覆盖场景和支持边界；所有适用的 P0 项通过后才开放自动发送。

现状：不满足。历史样本不能补生成候选（基线机制），因此此项必须等待下一次自然中断。

## 本轮验证记录

### V01-数据源：真实结构化限额错误来源核验

- 日期 / 验证人：2026-09-14 / 自动化只读核验
- 代码提交：`a47933f`（核验），修正见工作区未提交改动
- macOS / 宿主 / 内置 CLI 版本：macOS 26.6.2 (25G83) / ChatGPT.app 26.903.71938 / 内置 CLI 0.153.4（PATH CLI 0.146.0）
- 环境：真实 Desktop rollout 文件，全量 709 个文件 / 4,000 MiB
- 前置条件：只读遍历 `~/.codex/sessions`，不修改任何源文件，不发送任何消息
- 操作步骤：字节级标记计数 → 头部结构核对 → 命中行逐条 JSON 结构导出（仅键名与非敏感枚举值）
- 预期结果：确认 `usageLimitExceeded` 的真实编码与字段位置
- 实际结果：`turn/completed` = 0、`codexErrorInfo` = 0、`usageLimitExceeded` = 0；`codex_error_info` = 13、`usage_limit_exceeded` = 8；结构为 `event_msg/task_complete` + `payload.error.codex_error_info`，全部 originator 为 `Codex Desktop`；`payload.type == "error"` = 0
- 脱敏证据位置：本文件表格与本节结论；未保存原始记录与正文
- 结论：**通过**（数据源确证），并据此判定原解析器存在缺陷
- 遗留问题及下一步：等待一次现场中断做端到端回放

### V01-误判：关键词与文本不得触发候选

- 日期 / 验证人：2026-09-14 / 自动化只读核验
- 环境：真实 Desktop rollout 文件
- 操作步骤：统计除结构化字段外仍命中标记的行（消息正文、工具输出）
- 实际结果：63 处纯文本命中，分布在 6 个文件；非额度错误 `other` 3 条、`server_overloaded` 2 条
- 结论：**通过**（均不产生候选；已补充对应回归测试）
- 遗留问题及下一步：无

### V01-修正 A/B 对照：生产诊断代码在真实文件上的计数

- 日期 / 验证人：2026-09-14 / 生产代码直接回放
- 环境：11 个真实 rollout 文件的只读硬链接（源文件未修改、未复制内容），其中 8 个超过 512 KiB 被截取尾部
- 操作步骤：将 `CodexSessionDiagnostics.swift` 分别以 `git HEAD` 版本与修正后版本编译为只读 harness，对同一输入运行
- 预期结果：修正后应能识别真实样本，修正前应为 0
- 实际结果：修正前 `structuredQuotaErrors = 0`；修正后 `= 5`（`filesInspected = 11`、`malformedLines = 0`、`unreadableFiles = 0` 两者一致）
- 结论：**通过**（缺陷与修复均得到可复现验证）
- 遗留问题及下一步：截断尾部使 2 条真实错误未被计入，需评估尾窗大小或记录位置策略

### V02-连接：宿主、CLI 与控制 socket 实测

- 日期 / 验证人：2026-09-14 / 只读实测
- 环境：真实 Desktop
- 操作步骤：检查宿主 bundle 与版本、宿主内置 CLI 版本、PATH CLI 版本、默认控制 socket 与 `~/.codex` 下所有 Unix socket、运行中进程持有关系；执行 `codex app-server daemon version` 与 `--help`
- 实际结果：默认 `app-server-control` 目录不存在；`daemon version` 报 `No such file or directory`；`proxy --sock <PATH>` 为公开入口；宿主持有 `~/.codex/ipc/ipc.sock`（socket、属主当前用户、0600）；Desktop 以 `app-server --listen stdio://` 运行
- 结论：**阻塞**（无公开可连接的控制 socket；新发现的 socket 属宿主私有 IPC，未确认授权）
- 遗留问题及下一步：确认该版本是否提供其它公开监听方式；在确认前不得改用私有 socket

### V08/V10-隐私与存储实测

- 日期 / 验证人：2026-09-14 / 只读实测
- 操作步骤：检查 AgentMeter 应用支持目录、应用日志中的会话相关标记、Codex 自动化代码中的 CloudKit 引用、本地化资源
- 实际结果：应用支持目录不存在（无 checkpoint）；日志中会话相关标记计数全为 0；无 CloudKit 引用；9 个语种 `Localizable.strings` 通过 `plutil -lint`；`git diff --check` 无输出
- 结论：**隐私面通过**；存储落盘仍属“测试覆盖”，应用真实路径尚未发生
- 遗留问题及下一步：开启监测后复验真实 checkpoint 的权限与内容

### V08/V10-测试回归

- 日期 / 验证人：2026-09-14
- 环境：Xcode 26.5，`CODE_SIGNING_ALLOWED=NO`，`swift test --disable-sandbox`
- 实际结果：Mac `AgentMeterMacTests` 49 项通过（`CodexIncrementalSessionMonitorTests` 16、`CodexRuntimeReadProbeTests` 9、`CodexSessionDiagnosticsTests` 12、`MacHealthIssueTests` 12），0 失败；Core 全量 223 项 / 27 套件通过，其中 Codex 相关 41 项（`CodexResumePolicyTests` 12、`CodexPlanAdapterTests` 9、`CodexResetCreditsAdapterTests` 8、`CodexResetCreditExpiryAlertTests` 6、`CodexResetCreditExpiryReconciliationTests` 6）
- 结论：**通过**（合成样本与模拟进程；不代表真实 Desktop 恢复成功）

## 环境基线（每次实测需重新记录）

| 项 | 本轮实测值 |
| --- | --- |
| macOS | 26.6.2 (25G83)，arm64 |
| 宿主 | `/Applications/ChatGPT.app`，`com.openai.codex`，26.903.71938 (8576)，Codex Framework 152.0.7977.83 |
| 内置 CLI | 0.153.4（`/Applications/ChatGPT.app/Contents/Resources/codex`） |
| PATH CLI | 0.146.0（`/opt/homebrew/bin/codex`） |
| `CODEX_HOME` | 未设置，回落 `~/.codex` |
| 默认控制 socket | 不存在（`~/.codex/app-server-control/` 缺失） |
| 其它 socket | `~/.codex/ipc/ipc.sock`（宿主持有，0600）、`~/.codex/vendor_imports/skills/.git/fsmonitor--daemon.ipc` |
| 会话数据 | 709 个 rollout JSONL，合计 4.00 GB |
| AgentMeter checkpoint | 未创建 |
| 工具链 | Xcode 26.5，Swift 6.3.2 |

## 验证记录模板

每次验证复制以下模板；只有证据满足通过标准时才勾选对应项目。真实数据与合成 fixture 必须分别标注，不在记录中粘贴凭据或完整对话。

```markdown
### Vxx：验证名称

- 日期 / 验证人：
- 代码提交：
- macOS / 宿主 / 内置 CLI 版本：
- 环境：真实 Desktop / 合成样本 / 模拟进程
- 前置条件：
- 操作步骤：
- 预期结果：
- 实际结果：
- 脱敏证据位置：
- 结论：通过 / 失败 / 阻塞 / 尚未实现
- 遗留问题及下一步：
```
