# Mac + iPhone 联合发布检查清单

本仓库公开 macOS 伴侣 app 和共享 Core。iPhone 与 Apple Watch 源码不在本仓库，
但公开发布 Mac 新版之前，必须用最终下载的 Mac DMG 与实际 TestFlight iPhone
构建完成端到端验收。

## 建立本门禁的事故

2026-07-27，AgentMeter Release 构建使用的共享模型已经增加字段，但 CloudKit
Production 的 `QuotaSnapshot` Schema 没有同步定义：

- `staleReason`（String）
- `resetCreditsJSON`（String）
- `collectedBy`（String）

Development 测试正常，但 CloudKit 会拒绝包含 Production 未知字段的整条保存。
结果是下载的 Mac app 仍可能显示刚采集到的本地数据，而 TestFlight iPhone、
iPhone Widget、Watch app 和 complication 只能显示旧记录或空状态。

修复时把三个可选字段部署到 Production，并验证 Mac 1.6 (17) 成功写入、Apple
客户端链路成功读取。无需发布客户端补丁，也无需迁移已有记录。

## 经验教训

1. CloudKit Production Schema 是发布产物，必须与 `RecordMapping.Field` 锁步。
2. Debug/Development 测试通过，不能证明 Production 可用。
3. 源码配置不能证明导出产物的 entitlement；必须检查实际 iPhone archive 和
   最终 DMG 中解出的 Mac app。
4. 必须让实际 TestFlight iPhone 包与最终可下载 Mac DMG 成对联调，单独验证任意
   一端都不能证明同步成功。
5. 必须同时覆盖 fresh 和 degraded 写入；`staleReason` 只在失败路径使用，正常
   happy path 可能完全碰不到它。
6. CloudKit 部署预览出现意外 Record Type、索引或 Security Role 时必须停止发布。
7. 必须保存字段列表、部署差异、版本号、entitlement、写入/读取时间、日志和
   Apple 设备截图等验收证据。

## CloudKit Production 门禁

上传任何 Mac 或 iPhone 新版前：

1. 逐字段比较 `RecordMapping.Field`、Development 和 Production。
2. 确认 `QuotaSnapshot` 定义以下业务字段：
   - `tool` — String
   - `plan` — String
   - `windowsJSON` — String
   - `resetCreditsJSON` — String
   - `confidence` — String
   - `staleReason` — String
   - `collectedBy` — String
   - `source` — String
   - `updatedAt` — Date/Time
3. 检查 Development → Production 部署预览。
   - 只允许已确认的新增字段。
   - 出现意外 Record Type、索引或 Security Role 时取消并调查。
4. 新 writer 分发前先完成 Schema 部署。
5. 部署后重新打开 Production Record Type，核对每个字段及类型。

字段在单条记录上可以为空，但 Release app 写入它之前，Production 必须已经有
对应字段定义。

## 最终 Mac 下载产物

必须检验用户实际会下载的同一份 DMG，优先使用 GitHub Draft Release 资产或最终
暂存下载地址：

1. 记录版本、build、下载 URL、校验和及下载时间。
2. 校验 DMG、公证票据、app 签名、Hardened Runtime 和 staple。
3. 从该 DMG 把 app 拖进 `/Applications`；不能用 Xcode 启动的构建代替。
4. 检查解出的 app entitlement，确认
   `com.apple.developer.icloud-container-environment = Production`。
5. 使用发布 QA iCloud 账号启动 app，最多等待一个正常采集周期。
6. 确认日志出现 Production 写入成功，并且没有
   `Cannot create or modify field`、`Unknown field`、Schema rejection 或重复
   CloudKit 保存失败。
7. 同时验证：
   - 一条 fresh 编程套餐快照；
   - 一条指定 QA 的 degraded 快照，并包含 `staleReason`。
8. 适用时验证 Codex 可写入 `resetCreditsJSON`，分设备服务商写入正确的
   `collectedBy` 记录且不会覆盖另一端。

不要为了测试 degraded 路径破坏真实用户凭据；使用专门的发布 QA 账号和凭据。

## 实际 TestFlight iPhone + 配对 Watch

1. 检查将要上传的 iPhone archive/IPA，确认 CloudKit entitlement 为 Production。
2. 通过 TestFlight 安装实际上传的同一 version/build；本地 Release 安装不能代替。
3. 记录 TestFlight 安装时间及 iPhone version/build。
4. 打开 iPhone app 或切回前台，确认它读到最终 DMG Mac app 写入的同一条
   Production 快照：
   - provider 相同；
   - `updatedAt` 相同；
   - 额度数值相同；
   - 重置时间相同。
5. 确认 degraded 快照显示 stale/unknown，而不是 0 或 fresh。
6. 有 Codex reset credit 时确认 iPhone 可以读取。
7. 打开配对 Watch app，确认选择并显示同一快照。
8. 检查/请求刷新 iPhone Widget 与 Watch complication，并为 WidgetKit 调度预留时间。

## 必须保留的发布证据

- CloudKit 部署预览和最终 Production 字段列表截图；
- Mac DMG URL 与校验和；
- Mac、iPhone version/build；
- 两端导出产物的 entitlement 输出；
- Mac fresh 与失败路径成功写入日志；
- iPhone 成功读取时间；
- 适用的 iPhone、Watch app、Widget 和 complication 截图。

## 阻止发布的条件

出现以下任何情况，不得发布 DMG，也不得提交 iPhone 构建：

- Development 与 Production 字段意外不一致；
- 部署预览包含无法解释的类型、索引或角色；
- 任一产物没有证明使用 Production；
- 最终 DMG Mac app 无法写入 fresh 或 degraded 记录；
- 实际 TestFlight 构建无法读取该记录；
- iPhone 与 Mac 的时间戳/数值不一致；
- 日志出现 Production Schema rejection；
- 缺少规定的验收证据。
