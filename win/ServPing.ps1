<#
===============================================================================
 ServPing.ps1 — Windows PowerShell 版（对应 bash 版 v3.2.0）
===============================================================================
 Version    : 3.2.0
 Requires   : Windows PowerShell 5.1+ 或 PowerShell 7+；curl.exe
 Encoding   : UTF-8 with BOM（请保持，否则中文注释乱码）
 -------------------------------------------------------------------------------
 用法:

   .\ServPing.ps1 [Host名] [服务名] [选项]      # 位序：先 Host，后服务
   .\ServPing.ps1 -a Host "<名称>" <地址>
   .\ServPing.ps1 -a ServPort <名称> <端口> [描述] [proto] [响应体关键字]
   .\ServPing.ps1 -rm
   .\ServPing.ps1 -l

 配置模型（记录式，一行一条）:
   Host "FnOS"  192.168.1.10
   Host "Local" 127.0.0.1
   ServPort "Self" 5666 "FnOS管理界面" http
   ServPort "Git"  3000 "Gitea服务"    http "Gitea"
   ServPort "SSH"  22   "SSH服务"      tcp

 ★Host 与 ServPort 是两张独立表：Host 是地址簿，ServPort 是服务表。
 命令示例:
   .\ServPing.ps1                 # 缺省 Host × 缺省服务
   .\ServPing.ps1 FnOS git        # 名字大小写不敏感
   .\ServPing.ps1 Git             # 兼容老用法：不是 Host 名则当服务名

 字段顺序（ServPort 第 5 位起可省略）:
   1=名称 2=端口 3=描述 4=proto(http|tcp) 5=响应体关键字

 ★★唯一原则：一律取第一条 —— 缺省 Host / 缺省服务 / 同名只认第一条。
   缺省位写坏直接报错（退出码 2 + 行号），绝不让位给后面。

 选项:
   -a TYPE ...  追加配置（Host | ServPort）
   -rm          删除配置文件
   -H HOST      显式指定 Host（名字或字面地址）
   -s SERVICE   显式指定服务名（解歧义）
   -c N         探测次数（缺省 4）
   -i SEC       探测间隔秒（缺省 1）
   -W SEC       单次超时秒（缺省 5）
   -p PORT      临时覆盖端口
   -f FILE      指定配置文件
   -t           本次强制 tcp 探活
   -l           列出 Hosts 与服务
   -V           版本
   -h           帮助

 配置文件路径: -f > $env:SERVPING_CONFIG > %APPDATA%\ServPing\servping.conf
 退出码: 0 全部成功 / 1 存在失败 / 2 参数或配置错误

 ★口径: http 的 time= 是 HTTP 全链路；tcp 的 time= 只取 curl 的
   %{time_connect}（纯 TCP 握手），两种 time 不可横向比较。
 ★状态码: http 的 2xx/3xx 算健康（3xx 输出 REDIRECT）；4xx/5xx 判失败，
   但响应已收到 ⇒ received 计数、丢包为 0。只有拿不到响应才算丢包。
===============================================================================
#>

#Requires -Version 5.1

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:VERSION = '3.2.0'
$script:PROG = 'ServPing'
$script:DEF_COUNT = 4
$script:DEF_INTERVAL = 1
$script:DEF_TIMEOUT = 5
# Windows 用 %APPDATA%；非 Windows（CI/macOS 验证用）回落到 $HOME，
# 保证脚本在非 Windows 上也能解析与自测（真机上永远走前一支）。
$_base = if ($env:APPDATA) { $env:APPDATA } else { $HOME }
$script:DEF_FILE = Join-Path $_base 'ServPing\servping.conf'

function Die {
    param([string]$Msg)
    [Console]::Error.WriteLine("$($script:PROG): $Msg")
    exit 2
}

function Show-Usage {
    Write-Output @'
ServPing.ps1 [Host名] [服务名] [选项]

  -a TYPE ...  追加配置（Host | ServPort）
  -rm          删除配置文件
  -H HOST      显式指定 Host（名字或字面地址）
  -s SERVICE   显式指定服务名（解歧义）
  -c N         探测次数（缺省 4）
  -i SEC       探测间隔秒（缺省 1）
  -W SEC       单次超时秒（缺省 5）
  -p PORT      临时覆盖端口
  -f FILE      指定配置文件
  -t           本次强制 tcp 探活
  -l           列出 Hosts 与服务
  -V           版本
  -h           帮助

配置: Host/ServPort 记录式，一行一条；默认 %APPDATA%\ServPing\servping.conf
退出码: 0 全成功 / 1 有失败 / 2 参数或配置错误
'@
}

function Get-ConfPath {
    if ($script:Config) { return $script:Config }
    if ($env:SERVPING_CONFIG) { return $env:SERVPING_CONFIG }
    return $script:DEF_FILE
}

# ---------------------------------------------------------------------------
# 参数解析：手动扫 $args，逐字对齐 bash 版 case 结构。
# ★不用 param()/CmdletBinding —— PowerShell 会把 -h 前缀匹配成 -HostName，
#   且 -V 与通用参数 -Version 冲突；手动解析才能保住 bash 的选项语义。
# ---------------------------------------------------------------------------
$script:Add = $null
$script:Remove = 0
$script:HostName = ''
$script:Service = ''
$script:Count = $script:DEF_COUNT
$script:Interval = $script:DEF_INTERVAL
$script:Timeout = $script:DEF_TIMEOUT
$script:Port = ''
$script:Config = ''
$script:TcpOnly = 0
$script:List = 0
$wantVersion = 0
$wantHelp = 0
$Positional = New-Object System.Collections.Generic.List[string]

# ★入口统一字符串化：脚本化调用传 3000 时 $args 元素是 [System.Int32]，
#   直接 .StartsWith() 会抛异常且 $LASTEXITCODE 不设置（大奔 issue #2）。
$av = @($args | ForEach-Object { [string]$_ })
$i = 0
while ($i -lt $av.Count) {
    $t = $av[$i]
    # ★用 string.Equals(Ordinal) 逐分支比较，不用 switch —— PowerShell 的
    #   switch -Exact 对字符串大小写不敏感，-h 会命中 -H（踩过一次）。
    if ([string]::Equals($t, '-a', [StringComparison]::Ordinal)) {
        if (($i + 1) -ge $av.Count) { Die '-a 缺少类型（Host | ServPort）' }
        $script:Add = $av[$i + 1]; $i += 2
        $script:AddArgs = New-Object System.Collections.Generic.List[string]
        $max = if ($script:Add -eq 'Host') { 2 } else { 5 }
        while ($max -gt 0 -and $i -lt $av.Count -and -not $av[$i].StartsWith('-')) {
            [void]$script:AddArgs.Add($av[$i]); $i++; $max--
        }
    }
    elseif ([string]::Equals($t, '-rm', [StringComparison]::Ordinal)) { $script:Remove = 1; $i++ }
    elseif ([string]::Equals($t, '-c', [StringComparison]::Ordinal)) { if (($i+1) -ge $av.Count) { Die '-c 缺少参数' }; $script:Count = $av[$i+1]; $i += 2 }
    elseif ([string]::Equals($t, '-i', [StringComparison]::Ordinal)) { if (($i+1) -ge $av.Count) { Die '-i 缺少参数' }; $script:Interval = $av[$i+1]; $i += 2 }
    elseif ([string]::Equals($t, '-W', [StringComparison]::Ordinal)) { if (($i+1) -ge $av.Count) { Die '-W 缺少参数' }; $script:Timeout = $av[$i+1]; $i += 2 }
    elseif ([string]::Equals($t, '-H', [StringComparison]::Ordinal)) { if (($i+1) -ge $av.Count) { Die '-H 缺少参数' }; $script:HostName = $av[$i+1]; $i += 2 }
    elseif ([string]::Equals($t, '-p', [StringComparison]::Ordinal)) { if (($i+1) -ge $av.Count) { Die '-p 缺少参数' }; $script:Port = $av[$i+1]; $i += 2 }
    elseif ([string]::Equals($t, '-s', [StringComparison]::Ordinal)) { if (($i+1) -ge $av.Count) { Die '-s 缺少参数' }; $script:Service = $av[$i+1]; $i += 2 }
    elseif ([string]::Equals($t, '-f', [StringComparison]::Ordinal)) { if (($i+1) -ge $av.Count) { Die '-f 缺少参数' }; $script:Config = $av[$i+1]; $i += 2 }
    elseif ([string]::Equals($t, '-t', [StringComparison]::Ordinal)) { $script:TcpOnly = 1; $i++ }
    elseif ([string]::Equals($t, '-l', [StringComparison]::Ordinal)) { $script:List = 1; $i++ }
    elseif ([string]::Equals($t, '-V', [StringComparison]::Ordinal)) { $wantVersion = 1; $i++ }
    elseif ([string]::Equals($t, '-h', [StringComparison]::Ordinal) -or [string]::Equals($t, '--help', [StringComparison]::Ordinal)) { $wantHelp = 1; $i++ }
    elseif ([string]::Equals($t, '--', [StringComparison]::Ordinal)) { $i++; while ($i -lt $av.Count) { [void]$Positional.Add($av[$i]); $i++ } }
    else {
        if ($t.StartsWith('-')) { Die "未知选项：${t}（用 -h 看帮助）" }
        if ($Positional.Count -ge 2) { Die "多余的参数：${t}（最多 <Host> [服务] 两个位置参数）" }
        [void]$Positional.Add($t); $i++
    }
}

if ($wantVersion) { Write-Output "$($script:PROG) $($script:VERSION)"; exit 0 }
if ($wantHelp) { Show-Usage; exit 0 }

# ---------------------------------------------------------------------------
# 字符状态机分词（支持双引号包裹空格），禁止 Invoke-Expression。
# 与 bash 版逐字等价：丢弃引号字符，连续空格不产生空字段。
# ---------------------------------------------------------------------------
function Split-Line {
    param([string]$Line)
    $out = New-Object System.Collections.Generic.List[string]
    $cur = ''
    $inq = $false
    foreach ($ch in $Line.ToCharArray()) {
        if ($ch -eq '"') { $inq = -not $inq; continue }
        if (($ch -eq ' ' -or $ch -eq "`t") -and -not $inq) {
            if ($cur -ne '') { [void]$out.Add($cur); $cur = '' }
            continue
        }
        $cur += $ch
    }
    if ($cur -ne '') { [void]$out.Add($cur) }
    return $out
}

# ---------------------------------------------------------------------------
# 配置数组 + 查找（大小写不敏感，对齐 bash 的 tr A-Z a-z）
# ---------------------------------------------------------------------------
$script:Hosts = New-Object System.Collections.Generic.List[object]
$script:Svcs  = New-Object System.Collections.Generic.List[object]
$script:DupHosts = ''
$script:DupNames = ''

function Find-HostIndex {
    param([string]$Name)
    for ($k = 0; $k -lt $script:Hosts.Count; $k++) {
        if ([string]::Equals($script:Hosts[$k].Name, $Name, [StringComparison]::OrdinalIgnoreCase)) { return $k }
    }
    return -1
}
function Find-SvcIndex {
    param([string]$Name)
    for ($k = 0; $k -lt $script:Svcs.Count; $k++) {
        if ([string]::Equals($script:Svcs[$k].Name, $Name, [StringComparison]::OrdinalIgnoreCase)) { return $k }
    }
    return -1
}

function Reset-Config {
    $script:Hosts = New-Object System.Collections.Generic.List[object]
    $script:Svcs = New-Object System.Collections.Generic.List[object]
    $script:DupHosts = ''
    $script:DupNames = ''
}

# 追加写文件：PS5.1 的 Add-Content -Encoding UTF8 会写 BOM，
# 会让下一行配置的键变成 "<BOM>Host" 而匹配失败 —— 用 .NET 明确无 BOM。
function Append-Line {
    param([string]$File, [string]$Line)
    try {
        [System.IO.File]::AppendAllText($File, $Line + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
    } catch { Die "写入失败：${File}" }
}

# load_conf：幂等、坏行必 die（不跳过 = 不静默让缺省位漂移）
function Load-Conf {
    param([string]$File)
    Reset-Config
    if (-not (Test-Path -LiteralPath $File -PathType Leaf)) { return $false }
    $ln = 0
    foreach ($raw in [System.IO.File]::ReadAllLines($File)) {
        $ln++
        $line = $raw.TrimEnd("`r")
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line.StartsWith('#')) { continue }
        $f = @(Split-Line $line)
        if ($f.Count -lt 1) { continue }
        $kw = $f[0]
        switch ($kw) {
            'Host' {
                if ($f.Count -ge 3) {
                    $nh = $f[1]; $ad = $f[2]
                } elseif ($f.Count -eq 2) {
                    $nh = $f[1]; $ad = $f[1]
                } else {
                    Die "配置第 ${ln} 行：Host 缺少地址`n  正确写法：Host 192.168.1.10`n        或  Host `"FnOS`" 192.168.1.10`n  ★Host 写坏了不会跳过、也不会让后面的 Host 顶替缺省位。"
                }
                if ([string]::IsNullOrEmpty($ad)) { Die "配置第 ${ln} 行：Host `"${nh}`" 的地址为空" }
                if ([string]::IsNullOrEmpty($nh)) { Die "配置第 ${ln} 行：Host 名称为空" }
                if ((Find-HostIndex $nh) -ge 0) {
                    $script:DupHosts += " $nh"
                } else {
                    [void]$script:Hosts.Add([pscustomobject]@{ Name = $nh; Addr = $ad })
                }
            }
            'ServPort' {
                if ($f.Count -lt 3) {
                    Die "配置第 ${ln} 行：ServPort 至少需要 <名称> <端口>`n  正确写法：ServPort `"Self`" 5666 `"FnOS管理界面`" [proto] [关键字]"
                }
                $nm = $f[1]; $pt = $f[2]; $ds = ''; $pv = ''; $bd = ''
                if ($f.Count -ge 4) { $ds = $f[3] }
                if ($f.Count -ge 5) { $pv = $f[4] }
                if ($f.Count -ge 6) { $bd = $f[5] }
                if ($pt -notmatch '^\d+$') { Die "配置第 ${ln} 行：ServPort `"${nm}`" 的端口不是数字：'${pt}'" }
                if ([int]$pt -lt 1 -or [int]$pt -gt 65535) { Die "配置第 ${ln} 行：ServPort `"${nm}`" 的端口超出 1-65535：'${pt}'" }
                if ([string]::IsNullOrEmpty($pv)) { $pv = 'http' }
                $pv_raw = $pv
                $pv = $pv.ToLowerInvariant()
                if ($pv -notin @('http', 'tcp')) {
                    Die "配置第 ${ln} 行：ServPort `"${nm}`" 的 proto 非法：'${pv_raw}'`n  proto 只允许 http（缺省）或 tcp。`n  ★若这是从旧版 v1.x 迁来的配置，第 5 位原本是响应体关键字 ——`n    请改成：ServPort `"${nm}`" ${pt} `"${ds}`" http `"${pv_raw}`""
                }
                if ((Find-SvcIndex $nm) -ge 0) {
                    $script:DupNames += " $nm"
                } else {
                    [void]$script:Svcs.Add([pscustomobject]@{ Name = $nm; Port = $pt; Desc = $ds; Proto = $pv; Body = $bd })
                }
            }
        }
    }
    return $true
}

# ---------------------------------------------------------------------------
# -a 追加配置
# ---------------------------------------------------------------------------
function Add-Entry {
    param([string]$File, [string]$Type, [string[]]$Items)
    if ([string]::IsNullOrEmpty($File)) { Die '无法确定配置文件路径' }
    $dir = Split-Path -Parent $File
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
    switch ($Type) {
        'Host' {
            if ($Items.Count -lt 1) { Die '-a Host 需要 <地址> 或 "<名称>" <地址>' }
            if ($Items.Count -ge 2) { $nh = $Items[0]; $ad = $Items[1] } else { $nh = $Items[0]; $ad = $Items[0] }
            if ([string]::IsNullOrEmpty($ad)) { Die 'Host 地址不能为空' }
            [void](Load-Conf $File)
            $existed = (Find-HostIndex $nh) -ge 0
            $before = $script:Hosts.Count
            if ($Items.Count -ge 2) {
                Append-Line $File ('Host "{0}" {1}' -f $nh, $ad)
                Write-Output ('已追加: Host "{0}" {1}' -f $nh, $ad)
            } else {
                Append-Line $File ('Host {0}' -f $ad)
                Write-Output ('已追加: Host {0}    （未给名称，名称缺省 = 地址本身）' -f $ad)
            }
            if ($existed) { Write-Output ('注意: 同名 Host "{0}" 已存在，按"同名只认第一条"，本条不生效。' -f $nh) }
            elseif ($before -eq 0) { Write-Output '本条已生效，并且是**缺省 Host**（第一条）。' }
            else { Write-Output ('本条已生效。用法：{0} {1} <服务名>' -f $script:PROG, $nh) }
        }
        { $_ -in @('ServPort', 'Service') } {
            if ($Items.Count -lt 2) { Die '-a ServPort 需要 <名称> <端口> [描述] [proto] [关键字]' }
            $nm = $Items[0]; $pt = $Items[1]
            $ds = if ($Items.Count -ge 3) { $Items[2] } else { '' }
            $pv = if ($Items.Count -ge 4) { $Items[3] } else { '' }
            $bd = if ($Items.Count -ge 5) { $Items[4] } else { '' }
            if ($pt -notmatch '^\d+$') { Die "端口必须是数字：${pt}" }
            if ([int]$pt -lt 1 -or [int]$pt -gt 65535) { Die "端口必须是 1-65535 的整数：${pt}" }
            if ([string]::IsNullOrEmpty($pv) -and -not [string]::IsNullOrEmpty($ds)) {
                if ($ds.ToLowerInvariant() -in @('http', 'tcp')) { $pv = $ds; $ds = '' }
            }
            if ([string]::IsNullOrEmpty($ds)) { $ds = $nm }
            if ([string]::IsNullOrEmpty($pv)) { $pv = 'http' }
            $pv = $pv.ToLowerInvariant()
            if ($pv -notin @('http', 'tcp')) { Die "proto 只能是 http 或 tcp，收到：${pv}" }
            if ($pv -eq 'tcp' -and -not [string]::IsNullOrEmpty($bd)) {
                Write-Output ('注意: proto=tcp 不校验响应体，已忽略关键字 "{0}"' -f $bd)
                $bd = ''
            }
            [void](Load-Conf $File)
            $existed = (Find-SvcIndex $nm) -ge 0
            if ($bd) {
                Append-Line $File ('ServPort "{0}" {1} "{2}" {3} "{4}"' -f $nm, $pt, $ds, $pv, $bd)
            } elseif ($pv -eq 'http') {
                Append-Line $File ('ServPort "{0}" {1} "{2}"' -f $nm, $pt, $ds)
            } else {
                Append-Line $File ('ServPort "{0}" {1} "{2}" {3}' -f $nm, $pt, $ds, $pv)
            }
            $line = '已追加: ServPort "{0}" {1} "{2}"' -f $nm, $pt, $ds
            if ($pv -ne 'http') { $line += ' ' + $pv }
            if ($bd) { $line += ' "' + $bd + '"' }
            Write-Output $line
            if ($existed) { Write-Output ('注意: 同名 ServPort "{0}" 已存在，按规则**只认第一条**，本条不生效。' -f $nm) }
            else { Write-Output '本条已生效。' }
        }
        default { Die "未知的 -a 类型：${Type}（可用：Host | ServPort）" }
    }
}

function To-Ms {
    param([string]$V)
    $d = 0.0
    [void][double]::TryParse($V, [ref]$d)
    return (($d * 1000).ToString('F2', [Globalization.CultureInfo]::InvariantCulture))
}

function Probe-ErrText {
    param([int]$Rc, [string]$Mode)
    switch ($Rc) {
        0  { return 'tcp connect not established' }
        28 { return $(if ($Mode -eq 'http') { 'Request timeout' } else { 'Connection timeout' }) }
        7  { return 'Connection refused' }
        6  { return 'Could not resolve host' }
        35 { return 'TLS handshake failed' }
        default { return ('curl error {0}' -f $Rc) }
    }
}

# ---------------------------------------------------------------------------
# 探测一次：@{ Ok; Text }
# ★curl 在 PowerShell 里是 Invoke-WebRequest 的 alias，必须显式 curl.exe
# ---------------------------------------------------------------------------
function Invoke-Probe {
    param([string]$Url, [string]$ExpectBody, [string]$Proto, [double]$Sec)
    $body = [System.IO.Path]::GetTempFileName()
    try {
        $w = & $script:CurlBin -s -o $body `
            -w '%{http_code} %{time_total} %{time_connect} %{size_download}' `
            --noproxy '*' --connect-timeout $Sec --max-time $Sec `
            -A "$($script:PROG)/$($script:VERSION)" $Url 2>$null
        $rc = $LASTEXITCODE
        $p = @($w -split '\s+')
        $code = if ($p.Count -ge 1) { $p[0] } else { '000' }
        $t_total = if ($p.Count -ge 2) { $p[1] } else { '0' }
        $t_conn = if ($p.Count -ge 3) { $p[2] } else { '0' }
        $size = if ($p.Count -ge 4) { $p[3] } else { '0' }

        if ($Proto -eq 'tcp') {
            if ($t_conn -ne '0.000000' -and -not [string]::IsNullOrEmpty($t_conn)) {
                $rtt = To-Ms $t_conn
                return @{ Ok = $true; Status = 'OK'; Rtt = $rtt; Size = $size; Code = $code; Text = ('OK|{0}|{1}|{2}' -f $rtt, $size, $code) }
            }
            return @{ Ok = $false; Status = 'NOREPLY'; Rtt = '0.00'; Size = '0'; Code = $code; Text = (Probe-ErrText $rc 'tcp') }
        }

        # 先判「有没有拿到响应」：rc!=0 才算 no reply / 丢包。
        if ($rc -ne 0) {
            return @{ Ok = $false; Status = 'NOREPLY'; Rtt = '0.00'; Size = '0'; Code = $code; Text = (Probe-ErrText $rc 'http') }
        }

        $rtt = To-Ms $t_total
        if ($code -match '^2\d\d$') { $status = 'OK' }
        elseif ($code -match '^3\d\d$') { $status = 'REDIRECT' }
        else {
            $reason = 'HTTP {0} unexpected (expect 2xx/3xx)' -f $code
            return @{ Ok = $false; Status = 'HTTPERR'; Rtt = $rtt; Size = $size; Code = $code; Text = $reason }
        }

        if (-not [string]::IsNullOrEmpty($ExpectBody)) {
            $found = Select-String -LiteralPath $body -SimpleMatch -Quiet -Pattern $ExpectBody
            if (-not $found) {
                $reason = 'body mismatch (expect "{0}")' -f $ExpectBody
                return @{ Ok = $false; Status = 'HTTPERR'; Rtt = $rtt; Size = $size; Code = $code; Text = $reason }
            }
        }
        return @{ Ok = $true; Status = $status; Rtt = $rtt; Size = $size; Code = $code; Text = ('OK|{0}|{1}|{2}' -f $rtt, $size, $code) }
    } finally {
        Remove-Item -LiteralPath $body -Force -ErrorAction SilentlyContinue
    }
}

# ===========================================================================
# 主流程
# ===========================================================================
$CONF = Get-ConfPath

if ($script:Remove -eq 1) {
    if (Test-Path -LiteralPath $CONF) {
        Remove-Item -LiteralPath $CONF -Force
        Write-Output ('已删除配置文件: {0}' -f $CONF)
    } else { Write-Output ('配置文件不存在: {0}' -f $CONF) }
    exit 0
}

if ($script:Add) {
    Add-Entry -File $CONF -Type $script:Add -Items @($script:AddArgs)
    exit 0
}

if (-not (Test-Path -LiteralPath $CONF -PathType Leaf)) {
    Die "没有配置文件：${CONF}`n  请先添加配置，例如：`n    $($script:PROG) -a Host `"FnOS`" 192.168.1.10`n    $($script:PROG) -a ServPort `"Self`" 5666 `"FnOS管理界面`""
}

[void](Load-Conf $CONF)
if ($script:Hosts.Count -eq 0) { Die "配置里没有 Host 记录`n  请先添加：$($script:PROG) -a Host `"FnOS`" 192.168.1.10" }
if ($script:Svcs.Count -eq 0) { Die "配置文件里没有 ServPort 记录：${CONF}`n  请先添加：$($script:PROG) -a ServPort `"Self`" 5666 `"FnOS管理界面`"" }

if ($script:List -eq 1) {
    Write-Output ('配置文件: {0}' -f $CONF)
    Write-Output 'Hosts（* = 缺省，即第一条 Host）:'
    for ($k = 0; $k -lt $script:Hosts.Count; $k++) {
        $mark = if ($k -eq 0) { '*' } else { ' ' }
        $h = $script:Hosts[$k]
        $line = '  {0} {1,-10} {2}' -f $mark, $h.Name, $h.Addr
        if ($h.Name -eq $h.Addr) { $line += '    （未具名，名称=地址）' }
        Write-Output $line
    }
    if ($script:DupHosts) { Write-Output ('未生效（同名 Host 重复）:{0}' -f $script:DupHosts) }
    Write-Output '服务（* = 缺省，即第一条 ServPort）:'
    for ($k = 0; $k -lt $script:Svcs.Count; $k++) {
        $mark = if ($k -eq 0) { '*' } else { ' ' }
        $s = $script:Svcs[$k]
        $line = '  {0} {1,-8} {2,-6} {3,-5} {4}' -f $mark, $s.Name, $s.Port, $s.Proto, $s.Desc
        if ($s.Body) { $line += ('  [body: {0}]' -f $s.Body) }
        Write-Output $line
    }
    if ($script:DupNames) { Write-Output ('未生效（同名重复）:{0}' -f $script:DupNames) }
    Write-Output ('用法: {0} <Host名> [服务名]' -f $script:PROG)
    exit 0
}

# 选 Host / 选服务
$P1 = ''; $P2 = ''
if ($Positional.Count -ge 1) { $P1 = $Positional[0] }
if ($Positional.Count -ge 2) { $P2 = $Positional[1] }
$hostIdx = -1; $hostTmp = ''; $hostLabelTmp = ''
if ($script:HostName) {
    $hi = Find-HostIndex $script:HostName
    if ($hi -ge 0) { $hostIdx = $hi }
    else { $hostTmp = $script:HostName; $hostLabelTmp = $script:HostName }
    if ($P1 -and (Find-HostIndex $P1) -ge 0) { Die "-H 与位置参数 '${P1}' 都指定了 Host，请只留一个" }
    if ($P1) { $P2 = $P1 }
    $P1 = ''
}
if ($hostIdx -lt 0 -and -not $hostTmp -and $P1) {
    $hi = Find-HostIndex $P1
    if ($hi -ge 0) { $hostIdx = $hi; $P1 = '' }
    elseif ($P2) { Die "未知 Host '${P1}'（用 $($script:PROG) -l 看已登记的 Host）" }
}
if ($hostTmp) { $TargetHost = $hostTmp; $HostLabel = $hostLabelTmp }
elseif ($hostIdx -ge 0) { $TargetHost = $script:Hosts[$hostIdx].Addr; $HostLabel = $script:Hosts[$hostIdx].Name }
else { $TargetHost = $script:Hosts[0].Addr; $HostLabel = $script:Hosts[0].Name }

$svcSel = $script:Service
if (-not $svcSel) { if ($P1) { $svcSel = $P1 } elseif ($P2) { $svcSel = $P2 } }
if ($svcSel) {
    $idx = Find-SvcIndex $svcSel
    if ($idx -lt 0) { Die "未知服务 '${svcSel}'。可用：$(($script:Svcs | ForEach-Object { $_.Name }) -join ' ')" }
} else { $idx = 0 }

$DESC = $script:Svcs[$idx].Desc
$PORT = if ($script:Port) { $script:Port } else { $script:Svcs[$idx].Port }
$EXPBODY = $script:Svcs[$idx].Body
if (-not $DESC) { $DESC = $script:Svcs[$idx].Name }
$PROTO = if ($script:Svcs[$idx].Proto) { $script:Svcs[$idx].Proto } else { 'http' }
if ($script:TcpOnly -eq 1) { $PROTO = 'tcp' }

$COUNT = [int]$script:Count
$TIMEOUT = [double]$script:Timeout
$INTERVAL = [double]$script:Interval
if ($COUNT -lt 1) { Die '次数必须 >= 1 的整数' }
if ($TIMEOUT -le 0) { Die '超时必须 > 0' }
# PowerShell 里 curl 是 Invoke-WebRequest 的 alias；Windows 真身叫 curl.exe。
# 非 Windows（CI/macOS 验证）回落到 curl。
$script:CurlBin = if (Get-Command curl.exe -ErrorAction SilentlyContinue) { 'curl.exe' } elseif (Get-Command curl -CommandType Application -ErrorAction SilentlyContinue) { 'curl' } else { $null }
if (-not $script:CurlBin) { Die '需要 curl.exe（Windows 10/11 与 Server 2016+ 自带）' }

$URL = "http://${TargetHost}:${PORT}/"
if ($HostLabel -eq $TargetHost) {
    Write-Output ('PING {0} ({1}:{2}) [{3}]: {4} probes' -f $DESC, $TargetHost, $PORT, $PROTO, $COUNT)
} else {
    Write-Output ('PING {0} ({1} {2}:{3}) [{4}]: {5} probes' -f $DESC, $HostLabel, $TargetHost, $PORT, $PROTO, $COUNT)
}
Write-Output ('# config: {0}' -f $CONF)

$rtts = New-Object System.Collections.Generic.List[double]
$ok = 0
$recv = 0
$lastHttpReason = ''
for ($k = 0; $k -lt $COUNT; $k++) {
    $r = Invoke-Probe -Url $URL -ExpectBody $EXPBODY -Proto $PROTO -Sec $TIMEOUT
    $st = [string]$r.Status
    if ([string]::Equals($st, 'OK', [StringComparison]::Ordinal) -or
        [string]::Equals($st, 'REDIRECT', [StringComparison]::Ordinal)) {
        $recv++
        $ok++
        $rtt = [double]$r.Rtt
        [void]$rtts.Add($rtt)
        if ([string]::Equals($st, 'REDIRECT', [StringComparison]::Ordinal)) {
            Write-Output ('redirect from {0}:{1}: tcp_seq={2} time={3} ms (HTTP {4})' -f `
                $TargetHost, $PORT, $k, $r.Rtt, $r.Code)
        } elseif ($PROTO -eq 'tcp') {
            Write-Output ('connected  from {0}:{1}: tcp_seq={2} time={3} ms' -f $TargetHost, $PORT, $k, $r.Rtt)
        } else {
            Write-Output ('{0} bytes from {1}:{2}: tcp_seq={3} time={4} ms (HTTP {5})' -f `
                $r.Size, $TargetHost, $PORT, $k, $r.Rtt, $r.Code)
        }
    }
    elseif ([string]::Equals($st, 'HTTPERR', [StringComparison]::Ordinal)) {
        $recv++
        [void]$rtts.Add([double]$r.Rtt)
        $lastHttpReason = [string]$r.Text
        Write-Output ('{0} for tcp_seq {1}' -f $r.Text, $k)
    }
    else {
        Write-Output ('{0} for tcp_seq {1}' -f $r.Text, $k)
    }
    if ($k -lt ($COUNT - 1)) { Start-Sleep -Milliseconds ([int]($INTERVAL * 1000)) }
}

# lost = 完全没收到响应的次数，不再把 HTTP 状态码失败算成丢包。
$lost = $COUNT - $recv
$loss = if ($COUNT -gt 0) { ($lost * 100.0 / $COUNT).ToString('F1', [Globalization.CultureInfo]::InvariantCulture) } else { '0.0' }
Write-Output ''
Write-Output ('--- {0}:{1} {2} statistics ---' -f $TargetHost, $PORT, $script:PROG)
Write-Output ('{0} probes transmitted, {1} received, {2}% packet loss' -f $COUNT, $recv, $loss)
if ($rtts.Count -gt 0) {
    $stats = $rtts | Measure-Object -Minimum -Maximum -Average
    $avg = [double]$stats.Average
    $sq = 0.0
    foreach ($v in $rtts) { $sq += [math]::Pow(($v - $avg), 2) }
    $sd = [math]::Sqrt($sq / $rtts.Count)
    $line = '{0}/{1}/{2}/{3}' -f `
        ([double]$stats.Minimum).ToString('F2', [Globalization.CultureInfo]::InvariantCulture), `
        $avg.ToString('F2', [Globalization.CultureInfo]::InvariantCulture), `
        ([double]$stats.Maximum).ToString('F2', [Globalization.CultureInfo]::InvariantCulture), `
        $sd.ToString('F2', [Globalization.CultureInfo]::InvariantCulture)
    Write-Output ('round-trip min/avg/max/stddev = {0} ms' -f $line)
} else {
    Write-Output 'round-trip min/avg/max/stddev = (no reply)'
}

if ($ok -eq $COUNT) { Write-Output ('{0}: OK' -f $DESC); exit 0 }
elseif ($recv -eq 0) { Write-Output ('{0}: FAILED (no reply)' -f $DESC); exit 1 }
elseif ($ok -eq 0) {
    if ([string]::IsNullOrEmpty($lastHttpReason)) { $lastHttpReason = 'HTTP failure' }
    Write-Output ('{0}: FAILED ({1})' -f $DESC, $lastHttpReason); exit 1
}
else { Write-Output ('{0}: DEGRADED ({1}/{2})' -f $DESC, $ok, $COUNT); exit 1 }
