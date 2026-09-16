# Desktop 保持运行时恢复会话：queue 实测

日期：2026-09-16。本机 Desktop 内置 CLI 0.153.4 的公开 `codex queue` 命令已完成一次原线程提交与执行验证。它是下一阶段首选发送适配器，无需先接通 App Server 控制 socket。真实额度中断到自动恢复的整体验收尚未完成。

## 实测证据

此前 `codex exec resume` 返回 active writer 冲突；用户退出 Desktop 后 CLI 测试成功。独立执行端无法抢占，不代表所有公开命令都不能提交。

本轮宿主 CLI 顶层 help 列出 queue，子命令 help 为 `Queue a message for an existing session`。实际只执行一次：

```bash
/Applications/ChatGPT.app/Contents/Resources/codex queue \
  --thread 019fdcb3-13aa-74f2-ac90-5bbd931dd40c \
  --message '本轮仅测试 Desktop 保持运行时接收 CLI 排队消息。不要调用任何工具，不要执行命令、修改文件、提交或部署。只回复“QUEUE-20260916-A 验证成功”，然后结束。'
```

- 发送前原线程 idle、上一轮 completed。
- 命令退出码 0，返回排队消息 ID `01a0aa82-a4d3-7020-9873-2e6b502c0345` 和正确线程 ID。
- 宿主报告原线程 active，新轮次 `01a0aa82-a53e-7522-ade7-bd37b2b8ddbe`，随后 completed、无错误。
- 原 rollout 北京时间 21:58:03.842 写入 task_started；21:58:08.941 写入测试消息；21:58:16.975 写入助手精确回复 `QUEUE-20260916-A 验证成功`；21:58:17.003 写入 task_complete，error 为空。
- 没有调用 send_message_to_thread 代发、退出 Desktop、启动 daemon、改锁、操作 UI 或连接私有 IPC。
- 只验证 Desktop 运行且目标线程空闲时的行为，未测试正在执行、等待审批、睡眠/锁屏或 Desktop 退出场景。没有主动制造额度耗尽。
- 排队消息 ID 不等于新轮次 ID。成功入队不等于实际执行。

## 路径比较

| 路径 | 结论 |
| --- | --- |
| exec resume | 独立执行进程，已有 active writer 时发生冲突 |
| queue | 本机已验证原 Desktop 线程接收并执行 |
| App Server proxy | 默认 socket 缺失，但不再是 queue 路径的前置条件 |
| remote-control / 新建 daemon | 有公开命令，尚无证据可附着现有 Desktop，本轮未启用 |
| thread/unsubscribe | 只取消调用连接自己的订阅，不能替 Desktop 取消所有订阅 |
| UI 输入 | 当前工具禁止访问 Codex UI，本轮未使用 |

官方 App Server 文档说明共享服务传输、thread/resume、turn/start 和 unsubscribe 的卸载等待，不能证明当前 Desktop 开放外部入口。queue 的决定性证据来自本机 help 和真实执行记录。

参考：
- https://learn.chatgpt.com/docs/app-server
- https://learn.chatgpt.com/docs/developer-commands
- https://learn.chatgpt.com/docs/changelog （官方检索命中 0.149.0 的 #39034：Dispatch queued messages written by other processes；只作实现线索）

## 接入计划

1. 新增 `CodexQueueSender`，以 Process 参数数组调用宿主 CLI。先确认版本支持 queue，只传精确 UUID 与固定“继续”，不改模型/权限，不拼接 shell。
2. 保留最新失败轮次和实时额度复核。queue 不依赖 socket，不代表候选账号与额度绑定已解决；只有匹配账号、bucket、时效的额度证据才允许自动发送。
3. 发送前持久化 attempting，成功后保存 queued message ID。现有执行器假定立即返回 turnID，必须调整为“已入队、等待轮次”的阶段，不能把 message ID 当作 turnID。
4. 从发送前 offset 读取原 rollout，关联消息、新轮次及助手/工具活动。还需核对事件中是否保留 queued message ID；无法可靠关联时标记 uncertain，不能从重复文案猜测归属。
5. 未见公开幂等键、条件式入队或取消入队选项。超时可能已入队，禁止重试或切换 CLI；复核与入队存在竞态，不宣称 exactly-once。
6. 先做主动点击“通过 Desktop 队列恢复一次”，实机通过后接自动调度，暂不对未验证场景默认启用。

剩余验收：回执关联、超时与崩溃恢复、并发用户输入、真实额度恢复、线程未加载、Desktop 退出/锁屏/睡眠和版本兼容性。
