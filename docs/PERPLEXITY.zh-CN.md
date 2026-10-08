# Perplexity 账户积分

本功能采集网页账户积分，不包含开发者 API 美元余额或 token 成本历史。实现参考 [CodexBar 固定版本](https://github.com/steipete/CodexBar/blob/03a51bdcfc6f6804e005d7e5007de67bac82b494/Sources/CodexBarCore/Resources/Plugins/perplexity.js)。网页接口未公开，可能变动或要求浏览器验证。

## 配置

Mac 设置中启用“Perplexity 账户积分”；采集默认关闭，来源默认 Auto。Auto 通过现有 SweetCookieKit 0.5.5 仅读取 Chrome 的相关会话 Cookie，优先选择 Default profile，否则按名称排序选择首个，并固定该选择。会话过期或 profile 消失时不会切换账号。明确重新连接时可请求 Keychain 授权，后台刷新禁止弹窗。未启用时不读取凭据。

Manual 接受完整 Cookie header（可带 `Cookie:` 前缀）或裸 session token。支持四种 Auth.js／NextAuth 名称与连续编号分块，拒绝换行、控制字符、重复名称、缺失分块及异常输入。仅保留所选会话 Cookie。裸 token 仅在 401／403 认证拒绝后尝试下一个名称。Auto／Manual 不互相回退，也不读取环境变量。自动 Cookie 仅存内存；手动凭据存设备本地、不可同步和迁移的 ThisDeviceOnly Keychain。

固定 GET 端点为 `https://www.perplexity.ai/rest/billing/credits?version=2.18&source=default`，携带 Cookie、Origin 和账户用量页 Referer。临时会话不使用 Cookie 存储或 URL 缓存，拒绝所有重定向。采集不调用推理、购买或修改账户的接口。

## 积分口径与状态

数值使用 Decimal，按积分展示，不换算美元。兼容 snake_case 与 camelCase。周期 grant 汇总；购买池取 purchased grant 汇总与独立购买字段的较大值，避免重复计算；奖励池排除已过期 promotional grant。总消耗按“周期 → 购买 → 奖励”分摊，各池上限为其总量。分池消耗由客户端推算，页面明确说明这一点。各池显示剩余／总量及剩余百分比，仅显示实际返回的续期或到期时间，不为购买积分编造重置日期。

首次失败显示未知；之后失败保留上次成功事实及时间并标陈旧。登录过期、输入异常、访问拒绝、限流、浏览器验证、网络失败、服务异常和响应变化分别处理。紧凑显示优先有额度的周期池，其次购买、奖励。

## 可选显示同步

在一台 Mac 开启“同步 Perplexity 到 iCloud”，与手机使用相同 Apple ID。同步默认关闭。白名单 `PerplexityDisplaySnapshot` 无法携带 Cookie、profile 身份或原始响应。私有 CloudKit 独立 record type 为 `PerplexityDisplaySnapshot`，recordName 为 `credits-perplexity-mac`；字段 `payloadJSON` 是 String，`revision` 是 Timestamp，envelope 版本为 1。

串行最新状态队列只保存显示事实，每两分钟重试，关闭同步后的 tombstone 也会重试。暂停采集保留事实并标暂停。更换来源、profile 或凭据清除旧事实并使在途请求失效；同 profile 的会话替换或外部 Manual 凭据修改，在下一次读取发现时也先清除旧事实，内存指纹不写入磁盘或云端；关闭同步发送 tombstone。修订比较防止旧写入和旧读取复活新 tombstone。iCloud 账号变化清除旧队列／接收缓存，并需重新开启 Mac 同步；无账号绑定的恢复队列被丢弃。

iPhone 只在前台、手动或 BGAppRefresh 刷新时读取云端，将可选 `perplexity` 字段存入既有 schema-v3 display bundle，经 App Group 与 WatchConnectivity 分发。手机和手表不持 Perplexity Cookie、不请求其端点。超过 15 分钟标陈旧。旧 v3 客户端忽略新增字段，v1／v2 迁移保持可用，现有 Jev 和本地账单数据保留。手机 Widget 沿用 Pro 权益，Watch App／complication 免费。

## 验证和发布

Fixture 覆盖精度、字段兼容、三池分摊、购买去重、奖励到期、空池、异常数字、Cookie 名称／分块、传输失败、白名单及 bundle 兼容。Mac 注入测试覆盖固定 profile、来源隔离、授权参数、存储、迟到请求、脱敏诊断、队列重试及 tombstone；手机测试覆盖账号变化、旧缓存保留、陈旧／暂停／关闭与三种主页布局。

普通测试跳过 `MacPerplexityLiveTests`。显式授权后，设置 `TEST_RUNNER_AGENTMETER_PERPLEXITY_LIVE=1`，运行 `xcodebuild ... -only-testing:AgentMeterMacTests/MacPerplexityLiveTests test`。首次明确 Auto 连接可能请求 Chrome Safe Storage 授权，后续后台读取禁止弹窗。测试比较 Auto 与独立 Manual Keychain 往返，并验证后台无弹窗，不输出凭据或积分值。真实验收还需与可见网页积分对照，跳过测试不算通过。若用量页跳到账户设置或不显示积分池，不能据此推断余额为零；网页对照保持待验收，请求失败时按未知／陈旧展示。

**本次实现不会自动部署 Production Schema 或发布。** 新增 Schema 源码位于私有 iOS 仓库 `CloudKitSchema/agentmeter.ckdb`。发布前按[联合发布门禁](RELEASE_CHECKLIST.zh-CN.md)审核和部署新增类型及字段，再用最终下载 DMG、对应 TestFlight iPhone 构建和配对 Watch 对照数值、时间、陈旧状态、暂停／tombstone 与账号切换。保留现有额度及 Jev 记录。

Chrome Safe Storage 同时使用 SweetCookieKit task-local 和旧式 Keychain 禁止交互开关，串行导入并在成功／失败后恢复原设置；对应文件 Keychain 限制见 [Chromium 实现](https://chromium.googlesource.com/chromium/src/crypto/+/refs/heads/main/apple/scoped_keychain_user_interaction_allowed.cc)。
