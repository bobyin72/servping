# ServPing

[![CI](https://github.com/bobyin72/servping/actions/workflows/ci.yml/badge.svg)](https://github.com/bobyin72/servping/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

> `tcpping` 的通用、人机友好版本 —— 用 TCP / HTTP 探测代替 ICMP，输出格式仿 `ping`。

单文件 bash 脚本，零编译、零依赖（只要 `curl`），支持**多台主机 × 多个服务**的交叉探测。

[English](README.en.md) · 中文

---

## 为什么不用 `ping` / `tcpping`

| 工具 | 能告诉你 | 不能告诉你 |
|---|---|---|
| `ping` | 主机在线 | ICMP 常被防火墙拦；端口/服务是否可用 |
| `tcpping` | TCP 端口能握手 | 服务是否**真的**正常工作（HTTP 状态、响应内容）；多服务管理 |
| **ServPing** | 端口通 **且** 服务对（状态码 / 响应体）；多主机多服务命名；仿 ping 统计 | — |

## 特性

- **仿 ping 输出**：`PING ... bytes from ... time=x ms` + `min/avg/max/stddev` 统计 + 结论行
- **两种判活语义**：`proto=http` 校验 HTTP 2xx/3xx（3xx 记为 `REDIRECT` 且算健康；可再加响应体关键字）；`proto=tcp` 只判三次握手
- **具名主机地址簿**：`ServPing nas git` —— 先 Host 后服务，服务表与主机表正交
- **配置写坏不静默**：坏行带**行号**报错并退出 2，还会给出可直接抄的修正行
- **可移植**：macOS 自带 bash 3.2 与各种 Linux bash 都能跑（不用关联数组、不依赖 `date +%N`）
- **自测套件**：bash 62 条 / PowerShell 56 条断言，全在本机回环上跑，不需要外网

## 快速开始

```bash
git clone https://github.com/bobyin72/servping.git
cd servping
sudo install -m 755 ServPing /usr/local/bin/ServPing
```

最小配置（也可以完全用命令生成，见下）：

```bash
ServPing -a Host "NAS"   192.168.1.10
ServPing -a Host "Local" 127.0.0.1
ServPing -a ServPort "Web" 80 "NAS 管理界面"
ServPing -a ServPort "Git" 3000 "Gitea" http "Gitea"
ServPing -a ServPort "SSH" 22   "SSH"   tcp

ServPing nas git        # 探 NAS 上的 Gitea
ServPing local ssh      # 探本机 SSH（只测握手）
```

输出：

```
$ ServPing nas git
PING Gitea (NAS 192.168.1.10:3000) [http]: 4 probes
# config: /usr/local/etc/servping.conf
15834 bytes from 192.168.1.10:3000: tcp_seq=0 time=12.41 ms (HTTP 200)
15834 bytes from 192.168.1.10:3000: tcp_seq=1 time=11.98 ms (HTTP 200)
15834 bytes from 192.168.1.10:3000: tcp_seq=2 time=12.06 ms (HTTP 200)
15834 bytes from 192.168.1.10:3000: tcp_seq=3 time=12.22 ms (HTTP 200)

--- 192.168.1.10:3000 ServPing statistics ---
4 probes transmitted, 4 received, 0.0% packet loss
round-trip min/avg/max/stddev = 11.98/12.17/12.41/0.17 ms
Gitea: OK
```

## 配置

记录式，一行一条，默认路径 `/usr/local/etc/servping.conf`。

```
Host "NAS"   192.168.1.10
Host "Local" 127.0.0.1

ServPort "Web" 80   "NAS 管理界面" http
ServPort "Git" 3000 "Gitea"       http "Gitea"
ServPort "SSH" 22   "SSH"         tcp
```

### 两张独立的表

| 表 | 作用 | 命令里的位置 |
|---|---|---|
| `Host` | 地址簿：名字 → 地址 | 第 1 个位置参数 |
| `ServPort` | 服务表：名字 → 端口 / 协议 / 校验规则 | 第 2 个位置参数 |

两张表**正交**：同一套服务名可以套到任意一台主机上。`ServPing local git` 就是拿 Git 服务去敲 `127.0.0.1:3000`。

### `Host` 两种写法

```
Host "NAS" 192.168.1.10     # 具名（推荐），命令里用 NAS
Host 192.168.1.10           # 旧式，名称缺省 = 地址本身
```

### `ServPort` 字段

| 位 | 字段 | 说明 |
|---|---|---|
| 2 | 名称 | 命令里用的服务名，大小写不敏感 |
| 3 | 端口 | 数字 |
| 4 | 描述 | 可选，缺省同名称 |
| 5 | `proto` | 可选，`http`（缺省）/ `tcp` |
| 6 | 响应体关键字 | 可选，仅 `http` 生效 |

### 配置查找顺序

`-f 指定` > `$SERVPING_CONFIG` > `/usr/local/etc/servping.conf`

### ★唯一原则：一律取第一条

| 对象 | 规则 |
|---|---|
| 缺省 Host | 第一条 `Host` |
| 缺省服务 | 第一条 `ServPort` |
| 同名 Host / 同名 ServPort | 各自只认第一条（后面的保留在文件里但不生效） |

**缺省位写坏了直接报错，绝不让位给后面** —— 让位会让"缺省"随配置顺序悄悄漂移，那本身就是一种假阴性：你以为在测 A，其实在测 B。

## 用法

```bash
ServPing                     # 缺省 Host × 缺省服务
ServPing nas                 # NAS × 缺省服务
ServPing nas git             # NAS × Git
ServPing NAS GIT             # 大小写不敏感
ServPing git                 # 兼容：第 1 个词不是 Host 名 ⇒ 当服务名
ServPing -H Local -s Web     # 显式指定，绕开一切歧义
ServPing -l                  # 列出 Hosts 与服务
ServPing -h                  # 完整帮助
```

### 位置参数的歧义

第 1 个位置参数**先按 Host 名解析，解析不到才当服务名**。所以 `ServPing git` 在"没有叫 git 的主机"时，仍然按服务名处理。

若某个名字**同时**是主机名和服务名，它会被判为主机名。两种解法：

```bash
ServPing -s Git              # 强制当服务名，主机用缺省的
ServPing -H Git -s Web       # 两边都显式指定
```

### 选项

| 选项 | 说明 |
|---|---|
| `-H HOST` | 指定主机（已登记的名字，或字面地址） |
| `-s SERVICE` | 指定服务名 |
| `-c N` | 探测次数（缺省 4） |
| `-i SEC` | 间隔秒（缺省 1） |
| `-W SEC` | 单次超时秒（缺省 5） |
| `-p PORT` | 临时覆盖端口（不写配置） |
| `-f FILE` | 指定配置文件 |
| `-t` | 本次强制按 tcp 判活 |
| `-a TYPE ...` | 追加配置：`Host` / `ServPort` |
| `-rm` | 删除配置文件 |
| `-l` | 列出主机与服务 |
| `-V` / `-h` | 版本 / 帮助 |

### 退出码

| 码 | 含义 |
|---|---|
| 0 | 全部成功 |
| 1 | 存在失败（含全部失败） |
| 2 | 参数或配置错误 |

## 两种 `time=` 口径，别混着比

| proto | `time=` 含义 | 量级 |
|---|---|---|
| `http` | TCP 建连 + 请求往返 + 响应传输 | 取决于服务端处理 + 网络往返 |
| `tcp` | 只含 TCP 三次握手 | 可与 `ping` / `tcpping` 类比 |

**两者不可横向比较。** 脚本会告诉你哪种模式有自己的名字（`[http]` / `[tcp]`）。

### `tcp` 判活口径

成功条件：**curl 退出码为 0，或 `%{time_connect}` 非零**（非零即 `connect()` 已成功返回）。

因此服务接受连接但不响应 HTTP 时（SSH、MySQL、Redis 等），curl 会报 52 / 56 / 28 之类的错误码，**但握手本身是通的，仍判成功** —— 这正是 tcp 模式要的语义。反之：

- `Connection refused` → 失败
- `Could not resolve host` → 失败
- 连接超时（`time_connect` 为 0）→ 失败

### HTTP 状态与丢包口径（重要）

| 情况 | 输出 | 算成功 | 计入 received | 计入 packet loss |
|---|---|---|---|---|
| 2xx | `... bytes from ... (HTTP 200)` | 是 | 是 | 否 |
| 3xx | `redirect from ... (HTTP 302)` | 是 | 是 | 否 |
| 4xx/5xx | `HTTP 500 unexpected (expect 2xx/3xx)` | 否 | 是 | 否 |
| 连不上 / 超时 | `Connection refused` / `Request timeout` | 否 | 否 | 是 |

** rationale**：HTTP→HTTPS、跳登录页、跳管理界面都是正常部署形态（nginx 默认就会 302），把它们报成 `100% packet loss` 会把排障方向带偏到网线/防火墙。丢包只描述"根本没拿到响应"。

## 自测

```bash
tests/selftest.sh
```

bash 62 条断言，分两组：

- **组 1** 配置与命令行语义（不联网、不起服务）：坏行报错、端口范围、缺省选择、同名规则、`-a` 写入格式、错误退出码、版本一致性
- **组 2** 真实探测（需 `python3`，用它起本地 HTTP / 302 / 500 / 静默 TCP 服务）：HTTP 200、302 重定向、500 失败、响应体命中与未命中、tcp 握手、关闭端口

没有 `python3` 时组 2 自动 skip，组 1 仍会跑。退出码 0 = 无失败。

## Windows / PowerShell

`win/` 目录提供**原生 PowerShell 版**，与 bash 版行为逐条对齐（同一配置模型、同一 `curl` 判据、同一退出码契约），不是包一层 bash：

| 文件 | 用途 |
|---|---|
| `win/ServPing.ps1` | 主脚本，Windows PowerShell 5.1+ / PowerShell 7+，需 `curl.exe`（Win10/11 与 Server 2016+ 自带） |
| `win/ServPing.cmd` | 双击入口：优先 `pwsh.exe`，回落 `powershell.exe` 5.1；只请求一次提权 |
| `win/selftest.ps1` | PowerShell 版自测（组 1 配置语义 + 组 2 环境允许时的真实探测，共 56 条） |
| `win/DESIGN.md` | 移植语义对照表（内部设计文档） |

```powershell
# 直接运行
.\win\ServPing.ps1 -a Host "NAS" 192.168.1.10
.\win\ServPing.ps1 -a ServPort "Web" 80 "NAS 管理界面"
.\win\ServPing.ps1 nas web

# 双击 win\ServPing.cmd 也可；配置默认在 %APPDATA%\ServPing\servping.conf
# 自测
powershell -ExecutionPolicy Bypass -File .\win\selftest.ps1
```

配置查找顺序：`-f` > `$env:SERVPING_CONFIG` > `%APPDATA%\ServPing\servping.conf`。
**注意**：`curl` 在 PowerShell 里是 `Invoke-WebRequest` 的别名，脚本内部显式调用 `curl.exe`；手工验证时也要写 `curl.exe`。

已在 **Windows PowerShell 5.1 真机**与 **PowerShell 7** 双版本实测：自测全过，探测逻辑（HTTP 200 / 302 / 500 / 响应体校验 / TCP 握手 / 退出码）行为与 bash 版一致。CI 在 `windows-latest` 上同时跑 5.1 与 7。

## 已知限制

- `tcp` 模式**不校验协议内容**：端口通但服务挂错，tcp 看不出来。要防这种情况用 `http` + 响应体关键字。
- 没有并发：多个服务要多次调用（这是刻意的 —— 仿 ping 的语义是"逐包"）。
- `-p` / `-H` 只影响本次，不写配置。
- 依赖 `curl` 的 `%{time_connect}`：极老的 curl（< 7.19）可能不支持。

## 发布检查清单（防版本漂移）

发版前逐条打勾，任一项未过不得打 tag：

- [ ] `ServPing:VERSION`、`win/ServPing.ps1:$script:VERSION`、PS 头部注释 **三处 version 一致且等于本次 tag**
- [ ] `ServPing -V` 与 `win/ServPing.ps1 -V` 均输出 `ServPing <version>`
- [ ] `tests/selftest.sh` 与 `win/selftest.ps1` 的版本一致性断言全过
- [ ] 双平台自测无 FAIL（bash / PowerShell 5.1 / PowerShell 7）
- [ ] Release zip 从 annotated tag 导出，不从工作区快照导出
- [ ] 发布后从公开 `releases/download` URL 下载回来，`cmp` + sha256 双验

## License

[MIT](LICENSE)
