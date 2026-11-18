# ServPing Windows 版设计对照表（内部设计文档）

> bash 版源码权威：`../ServPing`（v3.0.0，731 行）
> 本文件是移植依据，不是用户文档。任何语义分歧以 bash 版为准。

## 1. 版本与常量

| bash | PowerShell |
|---|---|
| `VERSION="3.0.0"` | `$script:VERSION = '3.0.0'` |
| `PROG="ServPing"` | `$script:PROG = 'ServPing'` |
| `DEF_FILE="/usr/local/etc/servping.conf"` | `Join-Path $env:APPDATA 'ServPing\servping.conf'` |
| `DEF_COUNT=4 / DEF_INTERVAL=1 / DEF_TIMEOUT=5` | 同值 |
| `die()` → stderr + exit 2 | `function Die { param($msg) [Console]::Error.WriteLine("$PROG: $msg"); exit 2 }` |

配置路径优先级（三层，不变）：`-f` > `$env:SERVPING_CONFIG` > 默认。

## 2. 配置解析（最高风险区）

bash 用 `line_fields()` = awk 状态机分词（双引号包裹空格，输出 0x1F 分隔），**不用 eval**——配置文件内容不会被执行。
PS 版必须保持"配置不是代码"这条安全属性：**禁止 `Invoke-Expression`**。用 `ConvertFrom-String` 风格的字符状态机逐字扫描：

```
Tokenize-Line(line) -> string[]
  cur=''; inQuote=$false
  for each char c:
    if c=='\"': inQuote = !inQuote; continue
    if (c==' ' or '\t') and !inQuote:
      if cur != '': out += cur; cur=''
      continue
    cur += c
  if cur != '': out += cur
  return out
```

注意：bash 版**丢弃引号字符本身**，且连续空格不产生空字段——必须逐字一致。

### 加载语义（`Load-Conf`，幂等）
- 每次调用先清空 7 个数组与计数（bash 版修过的动态作用域 bug 教训：所有函数内变量必须先声明为 local/局部）。
- `Host` 两写法：字段数≥3 → 名称=第2、地址=第3；字段数==2 → 名称=地址=第2；否则 die 带行号，提示两种正确写法。
- `ServPort` 字段：1=名 2=端口 3=描述 4=proto 5=body；字段数<3 die；端口必须纯数字（正则 `^\d+$`）；proto 小写化，`http|tcp` 之外 die，且旧版 v1.x 迁移提示要逐字保留（含可抄的修正行）。
- 同名只认第一条：重复项记入 `$script:DUP_HOSTS/$DUP_NAMES`，**保留在文件里但不进数组**。
- **坏行一律 die 退出码 2，绝不跳过**（跳过 = 缺省位被后面的记录顶替 = 静默走偏）。

## 3. 数据结构

bash 的 7 个并行数组 → PS 用两个 `List[PSCustomObject]`：

| Host 对象 | ServPort 对象 |
|---|---|
| Name, Addr | Name, Port, Desc, Proto, Body |

索引查找函数 `Find-HostIndex` / `Find-SvcIndex` 用 `StringComparison.OrdinalIgnoreCase` 对齐 bash 的 `tr A-Z a-z`（大小写不敏感）。

## 4. 探测（`Invoke-Probe`）

**关键坑**：PowerShell 里 `curl` 是 `Invoke-WebRequest` 的 alias，**必须显式 `curl.exe`**。

```
$w = & curl.exe -s -o $body -w '%{http_code} %{time_total} %{time_connect} %{size_download}' `
       --noproxy '*' --connect-timeout $TIMEOUT --max-time $TIMEOUT `
       -A "$PROG/$VERSION" $url 2>$null
$rc = $LASTEXITCODE
```
- `-w` 失败时照样输出，先取 `$LASTEXITCODE` 再解析四段（`time_total`/`time_connect`/`size_download`）。
- tcp 判据：`time_connect != '0.000000'` → OK（即使 rc=52/56/28）；否则按 rc 映射错误文案（0/28/7/6/其他）。
- http 判据：rc!=0 → 按 rc 映射（28/7/6/35/其他）；code!='200' → `HTTP xxx unexpected (expect 200)`；有 body 关键字时用 `Select-String -SimpleMatch -Quiet`（对齐 grep -qF）校验。
- 返回字符串 `OK|time|size|code` 或错误文本，调用方用 rc 判定——与 bash 完全同构。
- `to_ms`：`$v * 1000` 格式化 `F2`，与 awk `printf "%.2f"` 对齐（注意 PowerShell 用当前区域小数点，必要时 `[CultureInfo]::InvariantCulture`）。

## 5. 选项解析

逐字对齐：`-a/--add` `-rm/--remove` `-c` `-i` `-W` `-H` `-p` `-s` `-f` `-t` `-l` `-V` `-h` `--`。
- `-a Host` 收 1~2 个参数；`-a ServPort` 收 2~5 个（第3位若为 http/tcp 且第4位空 → 让位给 proto）；这些"连续非选项参数"逻辑必须一致。
- 位置参数最多 2 个；`-H` 与位置 Host 同时给 → die。
- 第 1 个位置参数先按 Host 名解析，解析不到才当服务名（保老用法 `ServPing Git`）。

## 6. `-a` 追加（`Add-Entry`）

- 先 `mkdir -p (Split-Path $file -Parent)`，文件不存在也能追加。
- 追加前先 `Load-Conf` 判重与判缺省位（bash 版 `before=${#HOST_ADDR[@]}` 的等价）。
- 写入格式逐字一致：
  - `Host "名" 地址` / `Host 地址`
  - `ServPort "名" 端口 "描述"`（http 无 body 时省略 proto）/ 有 proto / 有 body 时全写
- 提示文案逐字一致：重复→"只认第一条，本条不生效"；第一条→"缺省 Host（第一条）"。

## 7. `-l` 列表

输出格式对齐 bash 的 printf 宽度：`%-10s` / `%-8s` / `%-6s` / `%-5s` → PS `-f` 格式化字符串同宽。
`*` 标第一条；未具名 Host 附"（未具名，名称=地址）"；重复项汇总行；末尾用法行。

## 8. 主循环与统计

- PING 头两分支（具名/未具名）逐字对齐。
- 每次 `Invoke-Probe`，成功解析 `OK|rtt|size|code` 并打印；失败直接打印错误文本。
- `sleep $INTERVAL` → `Start-Sleep -Seconds $INTERVAL`。
- 统计：`awk` 算丢包率与 min/avg/max/stddev → PowerShell 用 `[math]::Sqrt` 与 `Measure-Object`，格式 `F1`/`F2` 对齐。
- 结论行与退出码：`OK→0`、`FAILED (no reply)→1`、`DEGRADED (n/m)→1`。

## 9. 自测（tests/selftest.ps1）

移植 bash 版 40 条断言。**保留负对照原则**：两个 Host 必须在被测维度（地址）上取值不同（如 127.0.0.1 vs 127.0.0.2），否则断言恒真——这是 2026-11-17 抓到过真 bug 的判据，不能丢。

## 10. CI

`matrix.os` 增加 `windows-latest`；新增 step：
```
- name: 自测 (PowerShell)
  shell: pwsh
  run: ./tests/selftest.ps1
```
Windows runner 自带 curl.exe；用 `curl.exe --version` 验证。
