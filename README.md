# PPPoE AutoDial

Windows 上帮你自动拨宽带的小工具。

开机后不用手动点"连接"，掉线了自己接回来，笔记本合盖睡一觉醒来也会自动重连。
它不常驻后台，不装驱动，也**不碰你的宽带密码**。

---

## 它是干什么的

家里的宽带如果是"拨号"式的（PPPoE），每次开机、每次掉线，你都得手动点一下那个连接，
等它转几秒才通。这个工具就是把这一下替你按了。

它会在三个时机醒来：

- **开机登录后** —— 等 20 秒，让桌面先缓过来
- **从睡眠唤醒后** —— 合上笔记本再打开，很常见就是这里掉线
- **宽带掉线时** —— 系统一报告断开，它马上接手

然后它就开始试着拨号。拨通了就安静地待着；拨不通就按节奏再试，试到有结果为止。

---

## 装之前要有什么

- Windows 10 或 11
- 已经建好一个宽带拨号连接，并且**密码已经记住**
  - 怎么确认：双击那个连接，**如果不用输密码就能连上**，就是记住
- 不需要额外装 PowerShell，系统自带

> 这个工具不读取、不保存、不传输你的宽带密码。它只是让 Windows 去拨号，
> 凭据一直由 Windows 自己保管。

---

## 安装

1. 下载这个仓库（点绿色 `Code` 按钮 → `Download ZIP`），解压
2. **双击 `install.bat`**
3. 弹 UAC 时点【是】

装完会显示它找到了哪个连接。如果有多个，会让你选一个。

**如果探测到的连接名不对**，打开 `settings.json`（安装完在
`C:\ProgramData\PPPoEAutoDial\`）把 `ConnectionName` 改成正确的名字。

> 装完之后不会立刻拨号。它在等上面说的那三个时机。

---

## 装好之后会看到什么

平时什么都看不到 —— 没有图标、没有托盘、没有常驻进程。

只有在**掉线**的时候，它才会跑起来几十秒到几分钟，然后退出。
你可以在日志里看到它做了什么（见下面「日志在哪」）。

---

## 掉线时它会做什么

它会尝试拨号，但**不会无限重试**。每一次运行都有明确的上限：

| 限制 | 值 |
|---|---|
| 一次最多拨几次 | 10 次 |
| 最多试多久 | 8 分钟 |
| 一次运行最长活多久 | 25 分钟 |
| 系统强杀兜底 | 30 分钟 |

超过任何一条就停下，等下一次触发。**不会因为反复失败而把自己锁死**，
也不会在你用手机共享网络的时候跟你抢 —— 只要机器还有别的路上网，它就不拨。

拨号时会先试一种**完全不出窗口的方式**；如果那种不行，才会弹出系统自带的拨号窗口
（几秒钟，然后消失）。具体见下一节。

---

## 关于那个会闪的窗口

这是这个项目最别扭的地方，值得单独说。

Windows 拨 PPPoE 有好几条路，它们**看起来一样，实际差别很大**。我们在真机上测出来的是：

| 方式 | 会不会弹窗 | 结果 |
|---|---|---|
| `rasdial 连接名` | 不会 | ❌ 试了二十多次，**每一次都失败**（错误 628） |
| `rasdial 连接名 账号` | 不会 | 这是现在**优先尝试**的方式 |
| `rasphone -d 连接名` | 会弹窗 | ✅ **唯一确认成功过的方式** |

所以现在的顺序是：**先试不弹窗的那种，不行再退回会弹窗的那种**。

如果哪天你看到那个老式拨号窗口闪了一下然后消失，说明：
第一种方式没成，它用了第二种 —— **这是正常行为，不是出错**。

> 想彻底不弹窗，只有一条路：不再借 Windows 的命令行工具，而是直接调用底层拨号接口。
> 那是下一步的事，现在还没做。

---

## 设置项

改 `C:\ProgramData\PPPoEAutoDial\settings.json`，**下一次运行就生效，不用重装**。

```json
{
    "ConnectionName": "你的连接名",
    "DialWithAccountName": "你的宽带账号"
}
```

| 名字 | 是啥 |
|---|---|
| `ConnectionName` | 要拨的那个连接的名字 |
| `DialWithAccountName` | 宽带账号名，用于"不弹窗"的那种拨法。**这不是密码** |

下面这些一般不用动，想调再改：

| 名字 | 默认 | 说明 |
|---|---|---|
| `FirstAttemptDelaySeconds` | 20 | 被叫醒后等多久才开始拨 |
| `MaxAttemptsPerRun` | 10 | 一次运行最多拨几次 |
| `RetryWindowSeconds` | 480 | 一次运行最多试多久（8 分钟） |
| `MaxRunSeconds` | 1500 | 一次运行最长活多久（25 分钟） |
| `MinSecondsBetweenAttempts` | 20 | 两次拨号之间至少隔多久 |
| `MaxSecondsBetweenAttempts` | 60 | 间隔最长到多少 |
| `AfterFirstFailureWaitSeconds` | 180 | 第一次失败后先干等这么久（等运营商释放端口） |
| `StableSeconds` | 600 | 连上后稳多久算"搞定了"（10 分钟） |
| `LockAfterFailingSeconds` | 1800 | 连续失败多久才自锁（30 分钟） |
| `DialOnlyWhenNoInternet` | 1 | 机器还有别的网上，就不拨 |

---

## 日志在哪

```
C:\ProgramData\PPPoEAutoDial\autodial.log
```

每一行都在说它**为什么**做那个决定，不只是做了什么。比如：

```
13:02:19 [DIAL] dialing "dialog" via rasphone (attempt 1/10 ...)
13:03:08 [FAIL] rasphone failed: code=-2 out="timed out after 12s and was killed"
13:07:03 [OK] rasphone reported success after 304s
13:09:27 [OK] session stable for 600s; run complete
```

旁边还有一个 `autodial.heartbeat`，每 30 秒写一行。
它是用来区分"程序卡住了"和"程序死了"的 —— 日志停了但心跳还在，说明程序活着但卡住；
两个都停了，才是真的没了。

---

## 出问题了怎么办

| 情况 | 先看这里 |
|---|---|
| 开机后好几分钟才连上 | **正常**。运营商那边开机后有一段时间不放行（实测 3~6 分钟），工具在这期间一直试 |
| 看到拨号窗口闪出来 | **正常**。说明它在用"会弹窗但能成功"的那种方式 |
| 一直连不上 | 打开日志，看最后几行是什么错误码 |
| 想让它立刻停 | 删掉/重命任务，或者运行 `uninstall.bat` |
| 改了设置没反应 | 设置是下一次运行才生效，不会立刻重来 |

### 紧急停止

```powershell
# 立刻停下并禁用
powershell -File "C:\ProgramData\PPPoEAutoDial\Manage-PPPoEAutoDial.ps1" -Panic
```

### 彻底卸载

双击 `uninstall.bat`，或者在管理员 PowerShell 里：

```powershell
powershell -File "C:\ProgramData\PPPoEAutoDial\Manage-PPPoEAutoDial.ps1" -Uninstall
```

---

## 它做不到的事

- **不管校园网的网页认证**。有些校园网要先在网页上登录，那是另一回事，这个工具不处理。
- **不管 VPN**。只管拨号连接。
- **不能缩短开机的等待**。运营商那边的事，谁都改不了。
- **Windows 自己拨不通的时候，它也拨不通**。它不绕过系统、不模拟协议、不碰密码。

---

## 为什么它这么"绕"

因为这台机器上的 `rasdial` 一直拨不通，而这个事实花了很久才被接受。

一开始以为是拨太早了 —— 于是加了等待。还是 628。
后来以为是端口被占 —— 于是等端口空闲再拨，全程确认没人抢。还是 628。
再后来以为是密码没传对 —— 但点"连接"根本不用输密码。还是 628。

最后换了个思路：**换一种调用方式试试**。`rasphone -d` 一次就成功了。

所以现在的主路径是那个"不那么好看但能用"的窗口方式，而不是那个"看起来更干净"的
命令行方式。这不是偷懒 —— 这是实测结果。

详细的实验记录在提交历史和这个文件的历史版本里。如果你遇到同样的 628，希望这一节能
省你几天。

---

## 许可证

MIT。见 [LICENSE](LICENSE)。

## English

A small Windows tool that dials your PPPoE broadband for you: after logon, after waking
from sleep, and whenever the link drops. It runs as a bounded one-shot task instead of a
resident daemon, never touches your password, and never fights another working internet
connection.

Requires Windows 10/11, PowerShell 5.1, and a PPPoE connection with a saved password.
Double-click `install.bat`.

Known quirk: `rasdial <entry>` fails on this kind of line (RAS 628), so the tool tries
`rasdial <entry> <account>` first and falls back to `rasphone -d`, which may briefly show
the classic dial dialog. Yes, the uglier one works — that is measured, not assumed.
