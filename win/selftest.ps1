<#
 ServPing.ps1 自测（Windows PowerShell 5.1+ / PowerShell 7+）
 全部在本机回环上跑，不访问外网。
 退出码: 0 全通过 / 1 有失败 / 2 环境不满足

 ★负对照原则（2026-11-17 从 bash 版继承）：两个 Host 必须在被测维度
   （地址）上取值不同 —— HA=127.0.0.1 / HB=127.0.0.2，
   否则"用哪台 Host"的断言恒真，注入缺陷仍全绿。
#>

$ErrorActionPreference = 'Continue'
$SUT = Join-Path $PSScriptRoot 'ServPing.ps1'
if (-not (Test-Path -LiteralPath $SUT)) {
    [Console]::Error.WriteLine("找不到被测脚本: $SUT"); exit 2
}
# 用当前 PowerShell 宿主跑子进程（跨平台：Windows 叫 powershell.exe/pwsh.exe）
$PW = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
if (-not $PW) { $PW = 'pwsh' }

$WORK = Join-Path ([System.IO.Path]::GetTempPath()) ('servping-ps-test-' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $WORK -Force)

$script:PASS = 0; $script:FAIL = 0; $script:SKIP = 0
$script:FailedNames = New-Object System.Collections.Generic.List[string]
$script:Servers = New-Object System.Collections.Generic.List[object]

function Cleanup {
    foreach ($p in $script:Servers) {
        try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch {}
    }
    Remove-Item -LiteralPath $WORK -Recurse -Force -ErrorAction SilentlyContinue
}
trap { Cleanup; throw }

function Ok([string]$n) { $script:PASS++; Write-Output ('  ok    ' + $n) }
function Bad([string]$n, [string]$why) {
    $script:FAIL++; $script:FailedNames.Add("    - $n")
    Write-Output ('  FAIL  ' + $n); Write-Output ('         ' + $why)
}
function Sk([string]$n, [string]$why) { $script:SKIP++; Write-Output ('  skip  ' + $n + ' —— ' + $why) }
function Expect-Rc([string]$n, [int]$want, [int]$got) {
    if ($want -eq $got) { Ok $n } else { Bad $n "期望退出码 $want，实际 $got" }
}
function Expect-Has([string]$n, [string]$text, [string]$needle) {
    if ($text.Contains($needle)) { Ok $n } else { Bad $n "输出里没有 '$needle'" }
}
function Expect-Hasnt([string]$n, [string]$text, [string]$needle) {
    if ($text.Contains($needle)) { Bad $n "输出里不该出现 '$needle'" } else { Ok $n }
}
function Cfg([string]$file, [string]$content) {
    [System.IO.File]::WriteAllText($file, $content, (New-Object System.Text.UTF8Encoding($false)))
}
# 跑 SUT：$cfg 用 -f 注入配置文件，其余参数原样传
function Run-Sut([string]$cfg, [string[]]$args2) {
    $all = @('-f', $cfg) + $args2
    $out = & $PW -NoProfile -File $SUT @all 2>&1 | Out-String
    return @{ rc = $LASTEXITCODE; out = $out }
}
function Free-Port {
    $l = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $l.Start(); $p = $l.LocalEndpoint.Port; $l.Stop(); return $p
}

function Start-Http([int]$port, [string]$dir) {
    if (-not (Get-Command python3 -ErrorAction SilentlyContinue)) { return $null }
    $p = Start-Process -FilePath 'python3' `
        -ArgumentList @('-m', 'http.server', "$port", '--bind', '127.0.0.1', '--directory', $dir) `
        -PassThru -RedirectStandardOutput (Join-Path $WORK 'http.out') `
        -RedirectStandardError (Join-Path $WORK 'http.err')
    $script:Servers.Add($p)
    Start-Sleep -Milliseconds 700
    return $p
}
function Start-SilentTcp([int]$port) {
    if (-not (Get-Command python3 -ErrorAction SilentlyContinue)) { return $null }
    # 写到文件再跑，避免把多行 python 塞进 -c 的转义陷阱
    $svc = Join-Path $WORK 'silent_tcp.py'
    $code = @"
import socket
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('127.0.0.1', $port))
s.listen(8)
while True:
    try:
        c, a = s.accept()
        c.close()
    except Exception:
        pass
"@
    [System.IO.File]::WriteAllText($svc, $code, (New-Object System.Text.UTF8Encoding($false)))
    $p = Start-Process -FilePath 'python3' -ArgumentList @($svc) -PassThru
    $script:Servers.Add($p)
    Start-Sleep -Milliseconds 700
    return $p
}

Write-Output "ServPing.ps1 自测 —— $SUT"
Write-Output "工作目录: $WORK`n"

# ===========================================================================
# 组 1：配置解析与命令行语义（纯本地，不联网、不起服务）
# ===========================================================================
Write-Output '[组 1] 配置解析与命令行语义'

$r = Run-Sut (Join-Path $WORK 'none.conf') @('-c','1')
Expect-Rc '配置文件不存在 -> rc 2' 2 $r.rc

Cfg (Join-Path $WORK 'c1.conf') "Host`n"
$r = Run-Sut (Join-Path $WORK 'c1.conf') @('-l')
Expect-Rc 'Host 缺地址 -> rc 2' 2 $r.rc

Cfg (Join-Path $WORK 'c2.conf') "Host 127.0.0.1`nServPort `"X`"`n"
$r = Run-Sut (Join-Path $WORK 'c2.conf') @('-l')
Expect-Rc 'ServPort 缺字段 -> rc 2' 2 $r.rc

Cfg (Join-Path $WORK 'c3.conf') "Host 127.0.0.1`nServPort `"X`" abc`n"
$r = Run-Sut (Join-Path $WORK 'c3.conf') @('-l')
Expect-Rc '端口非数字 -> rc 2' 2 $r.rc

Cfg (Join-Path $WORK 'c4.conf') "Host 127.0.0.1`nServPort `"X`" 80 `"d`" zzz`n"
$r = Run-Sut (Join-Path $WORK 'c4.conf') @('-l')
Expect-Rc 'proto 非法 -> rc 2' 2 $r.rc
Expect-Has 'proto 非法给 v1.x 修正行' $r.out 'http "zzz"'

# ★负对照核心：HA / HB 地址必须不同，否则"用哪台 Host"断言恒真
Cfg (Join-Path $WORK 'e.conf') @'
Host "HA" 127.0.0.1
Host "HB" 127.0.0.2
ServPort "sa" 1 "A"
ServPort "sb" 2 "B"
'@
$r = Run-Sut (Join-Path $WORK 'e.conf') @('-c','1','-W','1')
Expect-Has '无参数 -> 缺省 Host(HA) × 缺省服务(sa)' $r.out 'PING A (HA 127.0.0.1:1)'

$r = Run-Sut (Join-Path $WORK 'e.conf') @('HB','sb','-c','1','-W','1')
Expect-Has '两位置参数 -> HB + sb' $r.out 'PING B (HB 127.0.0.2:2)'

$r = Run-Sut (Join-Path $WORK 'e.conf') @('sb','-c','1','-W','1')
Expect-Has '只给服务名 -> 缺省 Host(HA) × sb' $r.out 'PING B (HA 127.0.0.1:2)'

$r = Run-Sut (Join-Path $WORK 'e.conf') @('HB','-c','1','-W','1')
Expect-Has '只给 Host 名 -> HB × 缺省服务(sa)' $r.out 'PING A (HB 127.0.0.2:1)'

$r = Run-Sut (Join-Path $WORK 'e.conf') @('hb','SB','-c','1','-W','1')
Expect-Has '名字大小写不敏感' $r.out 'PING B (HB 127.0.0.2:2)'

$r = Run-Sut (Join-Path $WORK 'e.conf') @('-H','HB','-s','sb','-c','1','-W','1')
Expect-Has '-H + -s 合法' $r.out '(HB 127.0.0.2:2)'

$r = Run-Sut (Join-Path $WORK 'e.conf') @('-H','127.0.0.1','-s','SB','-c','1','-W','1')
Expect-Has '-H 给字面地址可用' $r.out '(127.0.0.1:2)'

$r = Run-Sut (Join-Path $WORK 'e.conf') @('-H','HA','HB','-c','1','-W','1')
Expect-Rc '-H 与位置 Host 冲突 -> rc 2' 2 $r.rc

$r = Run-Sut (Join-Path $WORK 'e.conf') @('-l')
Expect-Has '-l 标缺省 *' $r.out '* HA'
Expect-Has '-l 含 proto 列' $r.out 'http'

# 同名只认第一条
Cfg (Join-Path $WORK 'dup.conf') @'
Host "HA" 127.0.0.1
Host "HA" 127.0.0.2
ServPort "s" 1 "first"
ServPort "s" 2 "second"
'@
$r = Run-Sut (Join-Path $WORK 'dup.conf') @('-l')
Expect-Has '同名 Host 只认第一条' $r.out '127.0.0.1'
Expect-Has '重复 Host 汇总提示' $r.out '未生效（同名 Host 重复）: HA'
Expect-Has '重复 ServPort 汇总提示' $r.out '未生效（同名重复）: s'

# 坏缺省不让位
Cfg (Join-Path $WORK 'bad.conf') @'
Host
Host "OK" 127.0.0.2
ServPort "s" 1
'@
$r = Run-Sut (Join-Path $WORK 'bad.conf') @('-l')
Expect-Rc '坏 Host 不让位 -> rc 2' 2 $r.rc
Expect-Has '坏行带行号' $r.out '第 1 行'

# -V / -h（PS 专属坑：-h 曾被 -H 前缀匹配吃掉）
$r = Run-Sut (Join-Path $WORK 'e.conf') @('-V')
Expect-Has '-V 版本' $r.out 'ServPing 3.0.0'
$r = Run-Sut (Join-Path $WORK 'e.conf') @('-h')
Expect-Has '-h 帮助' $r.out '-a TYPE'

# ===========================================================================
# 组 2：真实探测（python3 起本地监听）
# ===========================================================================
Write-Output "`n[组 2] 真实探测（本机回环）"
# ★不能只看 Get-Command：Windows Store 的 python3.exe 是占位符（执行无任何输出），
#   会让组 2 全部假失败。必须实测它能执行代码才算可用。
$pyOk = $false
if (Get-Command python3 -ErrorAction SilentlyContinue) {
    try {
        $probe = & python3 -c 'print(12345)' 2>$null
        if (("$probe").Trim() -eq '12345') { $pyOk = $true }
    } catch {}
}
if (-not $pyOk) {
    Sk '组 2 全部' '无可用 python3（Windows Store 占位符不算）'
} else {
    $www = Join-Path $WORK 'www'
    [void](New-Item -ItemType Directory -Path $www -Force)
    [System.IO.File]::WriteAllText((Join-Path $www 'index.html'), 'Gitea-OK', (New-Object System.Text.UTF8Encoding($false)))
    $pHttp = Free-Port
    $null = Start-Http $pHttp $www

    Cfg (Join-Path $WORK 'h.conf') @"
Host "Loop" 127.0.0.1
ServPort "Web" $pHttp "本地HTTP" http "Gitea-OK"
"@
    $r = Run-Sut (Join-Path $WORK 'h.conf') @('Loop','Web','-c','2','-i','0')
    Expect-Rc 'HTTP 200 + body 命中 -> rc 0' 0 $r.rc
    Expect-Has 'HTTP 输出含 HTTP 200' $r.out '(HTTP 200)'
    Expect-Has 'HTTP 统计 0% 丢包' $r.out '0.0% packet loss'

    # body 不匹配必须失败（反向配对）
    Cfg (Join-Path $WORK 'b.conf') @"
Host "Loop" 127.0.0.1
ServPort "Web" $pHttp "本地HTTP" http "NOT-PRESENT"
"@
    $r = Run-Sut (Join-Path $WORK 'b.conf') @('Loop','Web','-c','1','-W','2')
    Expect-Rc 'body 不匹配 -> rc 1' 1 $r.rc
    Expect-Has 'body 不匹配报文字' $r.out 'body mismatch'

    # 关闭端口 -> 诚实失败
    Cfg (Join-Path $WORK 'f.conf') @'
Host "Loop" 127.0.0.1
ServPort "Dead" 1 "关闭端口"
'@
    $r = Run-Sut (Join-Path $WORK 'f.conf') @('Loop','Dead','-c','1','-W','2')
    Expect-Rc '关闭端口 -> rc 1' 1 $r.rc
    # 跨 OS 差异：macOS/Linux 关闭端口回 RST(curl 7=refused)；
    # 某些 Windows 虚机网络策略是静默 DROP(curl 28=timeout)。两者都是诚实失败。
    if ($r.out -match 'Connection refused|Request timeout|Connection timeout') {
        Ok '关闭端口有明确失败原因'
    } else {
        Bad '关闭端口有明确失败原因' $r.out
    }

    # 静默 TCP 服务：curl 会报 52 但 time_connect 非零 ⇒ tcp 模式应判成功
    $pTcp = Free-Port
    $null = Start-SilentTcp $pTcp
    Cfg (Join-Path $WORK 't.conf') @"
Host "Loop" 127.0.0.1
ServPort "Quiet" $pTcp "静默TCP" tcp
"@
    $r = Run-Sut (Join-Path $WORK 't.conf') @('Loop','Quiet','-c','1','-W','2')
    Expect-Rc '静默 TCP 握手成功 -> rc 0' 0 $r.rc
    Expect-Has 'TCP 输出 connected' $r.out 'connected  from'
}

# ---------------------------------------------------------------------------
Cleanup
Write-Output ''
Write-Output ("PASS={0}  FAIL={1}  SKIP={2}" -f $script:PASS, $script:FAIL, $script:SKIP)
if ($script:FAIL -gt 0) {
    Write-Output '失败项:'
    foreach ($n in $script:FailedNames) { Write-Output $n }
    exit 1
}
exit 0
