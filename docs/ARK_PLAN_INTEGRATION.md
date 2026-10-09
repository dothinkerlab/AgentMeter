# 火山方舟套餐接入

当前支持个人版 Ark Coding Plan 和 Ark Agent Plan。企业席位和按 Token 计费的 API 账单不在这次接入范围内。

## 配置与数据路径

在独立 Mac app 的 Provider → Plan 中分别选择套餐，填写火山 Access Key ID 与 Secret Access Key，点击「连接并验证」。需要当前 IAM 身份有对应个人套餐查询权限；普通模型推理 API key 无法替代 AK/SK。

凭据分别存入此 Mac 的 Keychain（非同步、ThisDeviceOnly）。默认关闭采集。iPhone 不配置火山凭据，Watch 不直连火山。Mac 只同步 `QuotaSnapshot`，沿用已有 CloudKit record type 与固定记录 `snapshot-arkCoding` / `snapshot-arkAgent`；凭据和原始响应不进入 CloudKit。

停用或移除凭据清除本机显示缓存并删除对应云端记录；删除失败在后续采集重试。换凭据先清除旧身份快照，失败显示未知，不借用旧账号的数字。取消在途请求并通过代数检查及串行云写入门禁防止旧请求复活记录。离线失败保留同一身份的上次事实并标陈旧。首次启动缓存均先标陈旧，验证成功才恢复为新鲜数据。

只允许同一个套餐由一台 Mac 发布（固定记录沿用现有 Mac-only 模式）。已停用的 Mac 可能在重试云端删除时清除另一台 Mac 的记录，因此不要同时启用多个发布端。

## API 与口径

- 固定 endpoint：`https://ark.cn-beijing.volcengineapi.com/`，POST `{}`，`Version=2024-01-01`。
- Coding Plan：`Action=GetCodingPlanUsage`；`QuotaUsage[].Level` 的 Session / Weekly / Monthly 对应五小时 / 周 / 月，`Percent` 为已用百分比，`ResetTimestamp` 为秒，`UpdateTimestamp` 为毫秒。
- Agent Plan：`Action=GetAFPUsage`；`AFPFiveHour` / `AFPDaily` / `AFPWeekly` / `AFPMonthly` 的 `Used / Quota × 100` 换算已用百分比，`ResetTime` 为毫秒。AFP 是套餐统一额度，不代表按模型的 Token 数或人民币金额。
- AK/SK HMAC-SHA256 签名，scope 为 `日期/cn-beijing/ark/request`；生产传输拒绝重定向。
- 缺少重置时间或零 sentinel 展示未知重置，不按档位推测；无套餐、空窗口、未知窗口或非法数值降级未知/陈旧。后端 Coding 更新时间超过 15 分钟不标新鲜。
- HTTP 429 与 HTTP 200 的业务 Throttling / LimitExceeded 使用 60 / 120 / 240 / 480 / 900 秒退避；动态签名不改变凭据身份，成功后保留原采集频率。

## MiniMax Token Plan 调整

保留文本套餐的五小时/周窗口：优先明确的 `general` 共享池，支持显式 `current_interval_remaining_percent` / `current_weekly_remaining_percent`（转成内部 usedPercent），仍兼容旧 count 字段。支持 M3 与 M2 系列名称。多个模型行只有在实际窗口（比例、重置时间）完全相同时才合并；不同窗口拒绝猜测，不按版本挑选也不相加。图片、视频、音频等独立资源池排除；status=3 未覆盖窗口排除，未知状态降级。

## 验证与发布

两仓库 Core 各自维护，adapter、ToolKind、签名、解析及 fixture 测试保持相同协议。样本 fixture 为依据公开协议构造的测试数据，尚不是用户账户录制结果。测试覆盖签名固定向量、HTTP/业务错误、退避、消歧及停用/换凭据并发。

新增工具复用已有 `QuotaSnapshot` schema，无新增 record type；本次不部署 Production。发布前仍需在 Development 使用真实个人套餐校验 IAM 权限、返回字段与数字，再用同一 Apple ID 验证 Mac → iPhone → Widget / Watch。不要在测试中保存真实 AK/SK 或原始账户响应。

官方依据：[Agent Plan GetAFPUsage](https://docs.volcengine.com/docs/ark/get-afp-usage-api?lang=zh)、[官方 ark-cli usage plan](https://github.com/volcengine/ark-cli/blob/main/skills/arkcli-usage/references/arkcli-usage-plan.md)、[官方 Python SDK 签名实现](https://github.com/volcengine/volc-sdk-python/blob/master/volcengine/auth/SignerV4.py)。
