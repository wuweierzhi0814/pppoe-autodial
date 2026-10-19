# PPPoE AutoDial

> **Windows 10 / 11 开机、唤醒、掉线自动拨号。有界、可控、不会把端口撞坏。**
>
> Bounded, event-driven PPPoE auto-dial for Windows. It dials after logon, after
> wake-from-sleep, and the moment the link drops — then it stops.

`开机自动拨号` · `宽带自动连接` · `PPPoE 自动重连` · `校园网自动拨号` · `宽带掉线自动重拨` · `rasdial` · `Windows 11`

---

## 它解决什么问题

很多校园网 / 宽带用户碰到的不是"连不上"，而是这两个具体毛病：

1. **开机后第一次拨号必死。** 拨上去几十秒内就被远端断掉，得手动点第二次才稳。
2. **拨号失败几次之后，端口会被"撞坏"**（RAS 错误 651），越重试越连不上。

网上的自动拨号脚本大多只做"循环 `rasdial`"，于是第 2 个问题会被无限放大：
一个守护进程每 20~40 秒猛拨一次，连续几十分钟，端口彻底起不来。

**这个项目的全部设计目标就是：自动连上，同时绝不让第 2 种情况发生。**

---

## 它和一般脚本的区别

| | 常见脚本 | 本项目 |
|---|---|---|
| 触发方式 | 定时轮询 | **事件驱动，0 延迟**：登录 / 休眠唤醒 / **会话断开** |
| 重试 | 无限循环 | **有界**：最多 10 次、8 分钟尝试窗口、25 分钟进程上限 |
| "放弃"的判据 | 失败次数 | **时间**（连续失败满 30 分钟才自锁）—— 次数在开机场景里毫无意义，见下文 |
| 失败后 | 继续拨 | RAS 651/756 或连续失败 30 分钟 → **自锁**，此后拒绝拨号，直到人工解锁 |
| 并发 | 无防护 | 命名互斥体 + 任务 `IgnoreNew` + 756 立即锁 |
| 别的网能用时 | 照样抢 | **不拨**（用 Windows 自己的 NCSI 判定） |
| 卡死 | 只能手动杀 | 任务计划程序层 **30 分钟强制终止** |

---

## 环境要求

- Windows 10 / 11
- **已经建好一个 PPPoE（宽带）拨号连接**，并且**密码已保存**
  - 设置 → 网络和 Internet → 拨号 → 设置新连接 → 连接到 Internet → 宽带(PPPoE)
  - 检验方法：双击那个连接，**如果不需要输入密码就能连上**，说明凭据已保存
- PowerShell 5.1（系统自带）

> 本项目**不存储也不接触你的宽带账号密码**。它调用的是 Windows 自带的拨号组件
> （`rasphone.exe` / `rasdial.exe`），凭据始终由 Windows 保管，脚本从不读取密码。
>
> 宽带**账号名**会被自动从系统事件日志里读出来（Windows 自己在 RasMan 事件
> `20267` 里记录了上一次成功连接的账号），仅用于尝试"带账号名拨号"这一种形式。

---

## 一键安装

1. 下载 / 克隆这个仓库
2. **双击 `install.bat`**
3. UAC 弹窗点【是】
4. 如果探测到多个连接，按提示输入序号

安装器会：

- 自动探测你的 PPPoE 连接名（从 RAS 电话簿和当前 PPP 网卡里找）
- 把脚本复制到 `%ProgramData%\PPPoEAutoDial\`
- 写出 `settings.json`
- 注册计划任务 `PPPoEAutoDial`（登录触发 + 休眠唤醒触发 + 掉线触发）

也可以带参数：

```bat
install.bat -ConnectionName "宽带连接"
install.bat -RunLevelHighest
```

### 验证

```powershell
# 查看任务定义 + 运行状态
powershell -ExecutionPolicy Bypass -File "%ProgramData%\PPPoEAutoDial\Manage-PPPoEAutoDial.ps1" -TaskStatus

# 或
schtasks /query /tn PPPoEAutoDial /v /fo LIST
```

日志在 `%ProgramData%\PPPoEAutoDial\autodial.log`，每一行都会说明它**为什么**做了那个决定。

旁边还有一个 `autodial.heartbeat`：由**独立后台线程**每 30 秒写一行，
**主循环卡住也照样写**。这是区分两种看起来一模一样的故障的唯一手段：

| 现象 | 结论 |
|---|---|
| 心跳继续，但该写 `[OK]` 却没写 | 进程活着，但主循环被卡住了 |
| 心跳停止 | 进程真的没了 |

如果日志写不进去，会转到 `%TEMP%\PPPoEAutoDial-fallback.log`，不会静默丢记录。
**自锁和计数器不会因为"链路自己好了"而自动清零** —— 会话恢复时会清（见下文退出码 7），
但被锁之后必须人工解锁。

### 安全演练（绝不拨号）

```powershell
powershell -ExecutionPolicy Bypass -File "%ProgramData%\PPPoEAutoDial\PPPoEAutoDial.ps1" -DryRun -SimulateSessionDown
```

---

## 它什么时候会醒

| 触发器 | 事件 | 延迟 |
|---|---|---|
| 登录 | `LogonTrigger` | 0 秒 |
| 休眠唤醒 | 系统日志 `Microsoft-Windows-Kernel-Power` **507**（退出 Modern Standby） | 5 秒 |
| **会话断开** | 系统日志 `RasMan` **20268** | 5 秒 |

醒来后脚本自己再等 **20 秒**才首次拨号（`FirstAttemptDelaySeconds`），避免和刚断开的旧会话抢端口。

> **为什么用 Kernel-Power 507 而不是 Power-Troubleshooter？**
> 走 Modern Standby 的机器上 `Microsoft-Windows-Power-Troubleshooter` 事件 ID 1 **完全不产生**，
> 订阅它等于装了个死触发器。开发机上实测：Power-Troubleshooter 7 天 **0 条**，
> Kernel-Power 507 有 **44 条**。

> **为什么用 RasMan 20268 检测断线，而不是拿某个常联网进程当基准？**
> 见下方「断线检测」。

---

## 断线检测

| 方案 | 延迟 | 代价 | 采用 |
|---|---|---|---|
| **RAS 会话状态（`RasEnumConnections`）** | **亚毫秒** | 需 P/Invoke | **✔ 主路径** —— 权威，且**不会卡在网络驱动里** |
| 网卡状态枚举（`GetAllNetworkInterfaces`） | ≤5 秒 | 零流量 | 仅作兜底（原生调用不可用时） |
| **系统事件 `RasMan` 20268** | **0 秒** | **零轮询零流量** | **✔ 采用** |
| TCP 可达性探测 | ≤2 秒 | 极少量 | 仅用于判断"别的路径有没有网" |
| 拿常联网进程当基准（看 TCP 表） | **分钟级** | 复杂 | ✘ 不采用 |

> **为什么主路径不是网卡枚举**：`GetAllNetworkInterfaces()` 要向 NDIS 问遍所有适配器，
> 在某些机器上会**长时间阻塞**，而被阻塞的调用**无法被中断** —— 整个 worker 会跟着冻死。
> 从外面看这完全不可见：日志跑了半截就停、永远不写 `[END]`，
> 最后只有任务计划程序的 30 分钟强杀能收场。开发机上实测出现过 4 次。
> `RasEnumConnections` 只跟 RAS 子系统打交道，既快又不会卡在驱动里；
> 原生调用不可用时会自动退回枚举，功能不受影响。

最后一种（用 `GetExtendedTcpTable` 看某个浏览器/客户端是否还有 ESTABLISHED 连接）看起来很聪明，
但有三个硬伤：

1. **进程空闲 ≠ 断网** —— 它没开着连接时无法区分"空闲"和"断网"。
2. **死连接会赖着不走** —— 链路断了以后，TCP 表里的 ESTABLISHED 要等**重传超时**
   （几十秒到几分钟）才消失，天生就慢，与"快速重连"目标相反。
3. **基线选谁？** 任何应用自己都会断、会退出，这个选择本身就是新的故障点。

真正的权威只有两处：**RAS 会话状态本身**，和 **Windows 为它写的事件日志**。

---

## 怎么拨号

这里有一个反直觉的实测结论：**`rasdial` 这一条路从来没成功过。**

2026-10-14 → 10-19，同一台机器、同一个连接、同一套已保存的凭据，`rasdial "连接名"`
一共试了二十多次，**每一次都在 3 秒内返回 RAS 628**（"连接完成前被远程计算机终止"）。
而被排除掉的原因包括：时机太早、端口被占（有一次全程零 `[BUSY]`，端口完全空闲）、
凭据缺失（点连接不需要输密码）—— 全都不是。

同一时刻，系统自带的拨号窗口 **`rasphone -d` 却能成功**。所以工具按**实测成功率**
而不是个人偏好排列了三种形式：

| 顺序 | 命令 | 实测表现 |
|---|---|---|
| **1** | `rasphone -d "连接名"` | **唯一成功过的形式** —— 2026-10-19 两次，各约 **4 秒**，无需任何人点击 |
| 2 | `rasdial "连接名"` | 3 秒内返回 628；留作快速静默兜底 |
| 3+ | `rasphone -d "连接名"` | 回到第一种，直到成功 |

**哪一种是成功的，本轮之后就一直用那一种。**

### 一个值得知道的现象

端口**没就绪**时，`rasphone` 会弹出那个经典的拨号窗口，停在那里等人点"连接"；
端口**一就绪**，它 4 秒就拨完，**根本不出现窗口**。

所以"弹窗口"本身就是"还没好"的信号。工具给 `rasphone` 只留 **12 秒** ——
出窗口就杀掉重试，等端口打开的那一刻再抓。杀掉进程**不会**中止已经在进行的拨号
（实测：进程被杀 12 秒后连接照常建立），所以这条短绳是安全的。

> 为什么不用常驻守护进程反复 `rasdial`？那正是本项目早期把端口反复拨坏
> （RAS 651）的原因。这三种形式的所有尝试都发生在**有界的一次性运行**里：
> 最多 10 次、8 分钟重试窗口、25 分钟进程上限、30 分钟任务级强杀。

---

## 不跟别的网抢

`DialOnlyWhenNoInternet = 1`（默认开启）：

会话不在线时，先判断"这台机器**是否已经通过别的途径**（手机 USB 共享 / WiFi）能上网"。
**能就不拨**，只记一条 `[HOLD]` 日志。

这样你主动断开拨号、改走 USB 共享时，它不会一直把你拽回 PPPoE。

判断使用 **NCSI**（Windows 自己的联网判定，就是任务栏网络图标背后那套）**+ TCP 探测，
两者同时成立才算"有别的网"**：

- NCSI 能识别强制门户，不会被"透明代理假装接收 :53"骗到
- 反过来 NCSI 若卡住误报，TCP 探测会失败 → 照样拨号
- **任一存疑就照拨**，绝不因为误判而静默失效

---

## 全部阈值

改 `%ProgramData%\PPPoEAutoDial\settings.json` 后**下一轮运行即生效，无需重装**。

| 键 | 默认 | 说明 |
|---|---|---|
| `ConnectionName` | 安装时探测 | PPPoE 连接名 |
| `FirstAttemptDelaySeconds` | 20 | 每次被唤醒后，等这么久才首次拨号 |
| `MaxRunSeconds` | 1500 | 单次运行进程寿命上限（25 分钟），到点无条件退出 |
| `RetryWindowSeconds` | 480 | 单次运行的"尝试期"上限（8 分钟）；用尽 → 退出码 8，**不自锁** |
| `MaxAttemptsPerRun` | 10 | 单次运行最多拨号次数 |
| `MinSecondsBetweenAttempts` | 20 | **全局**最小拨号间隔，写在 `state.json` 里跨进程生效 |
| `MaxSecondsBetweenAttempts` | 60 | 退避上限 |
| `AfterFirstFailureWaitSeconds` | 180 | **第一次失败后的长等待**：首拨仍是 20 秒，但失败后先干等 180 秒再试第二次 |
| `StableSeconds` | 600 | 在线连续满 10 分钟视为稳住，本轮结束 |
| `LockAfterFailingSeconds` | 1800 | **时间制自锁**：连续失败满 30 分钟才锁 |
| `LockOnErrorCodes` | `[651, 756]` | 遇到立即自锁（651=端口坏，756=已有拨号在进行） |
| `DialOnlyWhenNoInternet` | 1 | 别的路径能上网就不拨 |
| `DialWithAccountName` | 空 = 自动探测 | 显式传给 `rasdial` 的宽带账号名；留空则从 RasMan 事件日志读取上一次成功连接的账号 |
| `ProbeEndpoints` | 阿里/腾讯/百度 DNS:53 | 可达性探测目标 |

> **为什么第一次失败后要干等 180 秒（而不是 20 秒就再来一次）**
>
> 实测数据（2026-10-14 / 10-15）：掉线后**每一次早拨都返回 RAS 628**
> ——"连接完成前被远程计算机终止"，而且 `rasdial` 的输出显示它**已经走到
> 「正在验证用户名及密码」**，也就是凭据正常提交了，是**对方主动掐断**。
>
> 而链路每次都在**最后一次尝试之后 19–96 秒**自己回来；两次人工点击成功，
> 分别落在我们下一次尝试之前 **24 秒和 31 秒**。
>
> 628 在宽带上的经典含义就是"**账号还在线，端口没释放**"，运营商侧释放上一次会话
> 通常需要 **1.5–3 分钟**。如果反复早拨本身在刷新对方的释放计时器，那"早拨、勤拨"
> 就是自我拆台。这个 180 秒的停顿就是用来打断那个循环的，同时保持"首拨 20 秒"不变。
>
> **它只在"本轮从头到尾还没连上过一次"时生效**。一旦本轮已经连上过（哪怕随后又掉），
> 就回到 20/40/60 秒的正常退避 —— 否则开机那种"连上又断、断了又连"的抖动能被拖成
> 十几分钟。

任务计划程序层面还有一道 OS 强制的保险：

| 设置 | 值 |
|---|---|
| `ExecutionTimeLimit` | **PT30M**（脚本卡死也会被强杀） |
| `MultipleInstancesPolicy` | `IgnoreNew` |
| `RestartOnFailure` | **不设置**（OS 级重试是事故来源） |
| `RunLevel` | `LeastPrivilege`（拨号不需要管理员权限） |

---

## 退出码

| 码 | 含义 | 会自锁吗 |
|---|---|---|
| 0 | 正常结束（稳住了 / 到运行上限 / 急停） | 否 |
| 3 | 已有实例在跑 | 否 |
| 4 | 已锁定，拒绝拨号 | — |
| 5 | 撞到单次次数上限 | 否 |
| 6 | **致命 RAS 码（651/756）** | **是** |
| 7 | **连续失败满 30 分钟** | **是** |
| 8 | **重试窗口耗尽** | **否** |
| 9 | 没配置连接名 | 否 |
| 70 | **未捕获异常**（会被记进日志并附堆栈，不再静默消失） | 否 |

**自锁之后不会自己恢复** —— 必须跑一次解锁，这是刻意的：宁可停住等你，也不自己乱试。

```powershell
powershell -ExecutionPolicy Bypass -File "%ProgramData%\PPPoEAutoDial\Manage-PPPoEAutoDial.ps1" -Reset
```

---

## 紧急停止 / 卸载

```powershell
# 急停：停实例 + 禁用任务 + 写 stop.flag
powershell -ExecutionPolicy Bypass -File "%ProgramData%\PPPoEAutoDial\Manage-PPPoEAutoDial.ps1" -Panic
```

或者直接**双击 `uninstall.bat`**（会先急停再删除任务；日志和配置会保留，
加 `-Purge` 可一并删除）。

---

## 为什么自锁用"时间"而不是"次数"

这是本项目最反直觉、也最重要的一条，来自一次真实测量：

```
07:25:41  开机
07:26:07  登录
07:26:39  首次拨号 -> RAS 628
07:26:58  第 2 次  -> RAS 628
07:27:19  第 3 次  -> RAS 628 -> 自锁(次数制)
07:30:47  连接才真正建立   <- 比它放弃晚 3 分 28 秒
```

**开机后运营商侧有一段约 3.5 分钟的"幽灵会话"窗口，期间拨号必然是 628。**

所以"连续失败 3 次就放弃"是错的 —— 它在硬件根本不可能成功的时刻就判了死刑。
**时间是诚实的判据，次数不是。**

同理，"放弃一次运行"和"判定系统故障"是两件事，所以重试窗口耗尽只退出（码 8），**不自锁**。

---

## 已知限制

- 需要你**先手动建好** PPPoE 连接并保存密码，本工具不代建、不碰凭据。
- 只处理 PPPoE / 宽带拨号连接，不处理 VPN、不处理校园网**门户认证**
- 拨号依赖 Windows 自带的 `rasphone` / `rasdial`。**这两者都拨不通的时候，本项目也拨不通** ——
  它不绕过系统、不模拟协议、不接触账号密码
- 开机后运营商侧通常有一段 **3~6 分钟**的窗口，这期间任何拨号都会失败（实测三次独立复现）。
  工具会在这段时间里持续尝试并在窗口打开时立刻抓住，但**无法缩短这段等待**
  （那类需求请用 srun / Dr.COM 类工具，它们解决的是另一个问题）。
- 自锁后需要人工解锁，不会自愈（刻意如此）。
- 没有图形界面，只有日志和退出码。

## License

MIT —— 见 [LICENSE](LICENSE)。

---

## English

**PPPoE AutoDial** keeps a Windows 10/11 broadband (PPPoE) connection alive without
ever hammering the port.

- **Event-driven**, zero polling: logon, wake-from-sleep (`Kernel-Power` 507) and
  link-drop (`RasMan` 20268) scheduled-task triggers.
- **Bounded**: max 10 dial attempts, 8-minute retry window, 25-minute process cap,
  plus a 30-minute hard kill enforced by Task Scheduler itself.
- **Time-based self-lock**: only 30 minutes of *continuous* failing locks it.
  A failure *count* is meaningless when the carrier needs ~3.5 minutes to release
  the previous session.
- **Never dials when a session is already up**, never runs two instances
  (named mutex + `IgnoreNew` + immediate lock on RAS 651/756).
- **Leaves another working internet path alone** (decided via Windows' own NCSI).

Double-click `install.bat`. It detects your connection name, copies itself to
`%ProgramData%\PPPoEAutoDial` and registers the scheduled task. Requires an
existing PPPoE connection with saved credentials; the tool never touches them.

Logs, thresholds and exit codes are documented above (in Chinese — translations
welcome).
