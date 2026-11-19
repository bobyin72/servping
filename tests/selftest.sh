#!/usr/bin/env bash
# ============================================================================
# ServPing 自测 —— 全部在本机回环上跑，不访问外网
# ----------------------------------------------------------------------------
# 用法:  tests/selftest.sh [-v]
# 退出码: 0 全通过（含 skip 到 0 个失败）  1 有失败  2 环境不满足
#
# 分两组:
#   组 1  配置与命令行语义（纯本地，不联网、不起服务）
#   组 2  真实探测（需要 python3 起本地监听；没有 python3 则整组 skip）
# ============================================================================
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
SUT="$HERE/../ServPing"
[ -f "$SUT" ] || { printf '找不到被测脚本: %s\n' "$SUT" >&2; exit 2; }
[ -x "$SUT" ] || chmod +x "$SUT" 2>/dev/null

WORK=$(mktemp -d "${TMPDIR:-/tmp}/servping-test.XXXXXX") || exit 2
SRV_PIDS=""
cleanup() {
    [ -n "$SRV_PIDS" ] && kill $SRV_PIDS 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

PASS=0; FAIL=0; SKIP=0; FAILED_NAMES=""
ok()   { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); FAILED_NAMES="$FAILED_NAMES
    - $1"; printf '  FAIL  %s\n         %s\n' "$1" "${2:-}"; }
skip() { SKIP=$((SKIP + 1)); printf '  skip  %s —— %s\n' "$1" "${2:-}"; }

# 断言退出码
expect_rc() { # <名称> <期望> <实际>
    if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "期望退出码 $2，实际 $3"; fi
}
# 断言输出包含子串
expect_has() { # <名称> <文本> <子串>
    case "$2" in
        *"$3"*) ok "$1" ;;
        *) bad "$1" "输出里没有 '$3'" ;;
    esac
}
# 断言输出不包含子串
expect_hasnt() { # <名称> <文本> <子串>
    case "$2" in
        *"$3"*) bad "$1" "输出里不该出现 '$3'" ;;
        *) ok "$1" ;;
    esac
}
# 断言文件包含匹配行
expect_file_has() { # <名称> <文件> <字符串>
    if grep -qF -- "$3" "$2" 2>/dev/null; then ok "$1"; else bad "$1" "$2 里没有 '$3'"; fi
}

cfg() { # <文件> <内容>   写配置（覆盖）
    printf '%s' "$2" > "$1"
}

printf 'ServPing 自测 —— %s\n' "$SUT"
printf '工作目录: %s\n\n' "$WORK"

# ===========================================================================
# 组 1：配置与命令行语义
# ===========================================================================
printf '[组 1] 配置解析与命令行语义\n'

# ---- 配置错误必须退出码 2 ----
"$SUT" -f "$WORK/none.conf" -c 1 >/dev/null 2>&1
expect_rc '配置文件不存在 -> rc 2' 2 $?

cfg "$WORK/c1.conf" 'Host
'
"$SUT" -f "$WORK/c1.conf" -l >/dev/null 2>&1
expect_rc 'Host 缺地址 -> rc 2' 2 $?

cfg "$WORK/c2.conf" 'Host 127.0.0.1
ServPort "X"
'
"$SUT" -f "$WORK/c2.conf" -l >/dev/null 2>&1
expect_rc 'ServPort 缺字段 -> rc 2' 2 $?

cfg "$WORK/c3.conf" 'Host 127.0.0.1
ServPort "X" abc
'
"$SUT" -f "$WORK/c3.conf" -l >/dev/null 2>&1
expect_rc '端口非数字 -> rc 2' 2 $?

cfg "$WORK/c4.conf" 'Host 127.0.0.1
ServPort "X" 80 "d" zzz
'
out=$("$SUT" -f "$WORK/c4.conf" -l 2>&1); rc=$?
expect_rc 'proto 非法 -> rc 2' 2 "$rc"
expect_has 'proto 非法时报错含行号' "$out" '第 2 行'
expect_has 'proto 非法时给出修正行' "$out" 'http "zzz"'

# ---- -a 追加的三种写法 ----
cfg "$WORK/a.conf" ''
"$SUT" -f "$WORK/a.conf" -a Host "Foo" 1.2.3.4 >/dev/null 2>&1
expect_file_has '具名 Host 写入格式' "$WORK/a.conf" 'Host "Foo" 1.2.3.4'

"$SUT" -f "$WORK/a.conf" -a Host 5.6.7.8 >/dev/null 2>&1
expect_file_has '旧式 Host（单参数）写入格式' "$WORK/a.conf" 'Host 5.6.7.8'

"$SUT" -f "$WORK/a.conf" -a ServPort "SSH" 22 tcp >/dev/null 2>&1
expect_file_has '省略描述直接给 proto' "$WORK/a.conf" 'ServPort "SSH" 22 "SSH" tcp'

"$SUT" -f "$WORK/a.conf" -a ServPort "Web" 80 "网页" http "marker" >/dev/null 2>&1
expect_file_has 'proto + 响应体关键字都写入' "$WORK/a.conf" 'ServPort "Web" 80 "网页" http "marker"'

# ---- 同名只认第一条 ----
out=$("$SUT" -f "$WORK/a.conf" -a ServPort "SSH" 2222 "重复" 2>&1)
expect_has '同名服务提示不生效' "$out" '本条不生效'
cfg "$WORK/d.conf" 'Host 127.0.0.1
ServPort "Dup" 1 "先"
ServPort "Dup" 2 "后"
'
out=$("$SUT" -f "$WORK/d.conf" -l 2>&1)
expect_has '同名服务在 -l 里列出未生效项' "$out" '未生效（同名重复）: Dup'
expect_has '-l 里缺省行指向第一条（端口 1）' "$out" '* Dup      1'

# ---- 缺省 = 各自第一条 ----
cfg "$WORK/e.conf" 'Host "HA" 127.0.0.1
Host "HB" 127.0.0.2
ServPort "SA" 1 "sa"
ServPort "SB" 2 "sb"
'
out=$("$SUT" -f "$WORK/e.conf" -c 1 -W 1 2>&1)
expect_has '无参数 -> 缺省 Host 与缺省服务' "$out" 'PING sa (HA 127.0.0.1:1)'

out=$("$SUT" -f "$WORK/e.conf" HB SB -c 1 -W 1 2>&1)
expect_has '两个位置参数 -> Host + 服务' "$out" 'PING sb (HB 127.0.0.2:2)'

out=$("$SUT" -f "$WORK/e.conf" sb -c 1 -W 1 2>&1)
expect_has '只给服务名 -> 用缺省 Host（兼容老用法）' "$out" 'PING sb (HA 127.0.0.1:2)'

out=$("$SUT" -f "$WORK/e.conf" hb -c 1 -W 1 2>&1)
expect_has '只给 Host 名 -> 用缺省服务' "$out" 'PING sa (HB 127.0.0.2:1)'

out=$("$SUT" -f "$WORK/e.conf" hB sB -c 1 -W 1 2>&1)
expect_has '名字大小写不敏感' "$out" 'PING sb (HB 127.0.0.2:2)'

# ---- 错误用法 ----
out=$("$SUT" -f "$WORK/e.conf" NoSvc -c 1 2>&1); rc=$?
expect_rc '未知服务 -> rc 2' 2 "$rc"
out=$("$SUT" -f "$WORK/e.conf" NoHost SA -c 1 2>&1); rc=$?
expect_rc '未知 Host -> rc 2' 2 "$rc"
out=$("$SUT" -f "$WORK/e.conf" -H HB HA -c 1 2>&1); rc=$?
expect_rc '-H 与位置 Host 冲突 -> rc 2' 2 "$rc"
expect_has '冲突提示点名了那个参数' "$out" '都指定了 Host'

# -H 指 Host、位置参数留给服务，是合法组合（不该判冲突）
out=$("$SUT" -f "$WORK/e.conf" -H HB SA -c 1 -W 1 2>&1); rc=$?
expect_has '-H + 位置服务名 合法' "$out" '(HB 127.0.0.2:1)'

out=$("$SUT" -f "$WORK/e.conf" -H 127.0.0.1 -s SB -c 1 -W 1 2>&1)
expect_has '-H 给字面地址可用' "$out" '(127.0.0.1:2)'

# ---- -l 的缺省标记 ----
out=$("$SUT" -f "$WORK/e.conf" -l 2>&1)
marks=$(printf '%s\n' "$out" | grep -c '^  \* ')
if [ "$marks" = "2" ]; then ok '-l 里缺省标记恰好 2 个（Host + 服务）'
else bad '-l 里缺省标记数量' "期望 2，实际 $marks"; fi

# ---- 端口范围 1-65535（大奔 issue #2 的配套校验）----
cfg "$WORK/pr0.conf" 'Host 127.0.0.1
ServPort "Bad" 0 "x"
'
out=$("$SUT" -f "$WORK/pr0.conf" -l 2>&1); rc=$?
expect_rc '配置端口 0 -> rc 2' 2 "$rc"
expect_has '配置端口 0 报范围' "$out" '1-65535'

cfg "$WORK/pr65536.conf" 'Host 127.0.0.1
ServPort "Bad" 65536 "x"
'
out=$("$SUT" -f "$WORK/pr65536.conf" -l 2>&1); rc=$?
expect_rc '配置端口 65536 -> rc 2' 2 "$rc"

out=$("$SUT" -f "$WORK/a.conf" -a ServPort "Bad" 65536 >/dev/null 2>&1); rc=$?
expect_rc '-a 端口越界 -> rc 2' 2 "$rc"

# ---- 版本单一口径闸门（大奔 issue #3）----
out=$("$SUT" -V 2>&1)
expect_has '-V 自报 3.2.0' "$out" 'ServPing 3.2.0'
expect_file_has 'bash 版本常量 = 3.2.0' "$SUT" 'VERSION="3.2.0"'
expect_file_has 'PS 版本常量 = 3.2.0' "$HERE/../win/ServPing.ps1" '$script:VERSION = '"'"'3.2.0'"'"''
expect_file_has 'PS 头部注释 = v3.2.0' "$HERE/../win/ServPing.ps1" '对应 bash 版 v3.2.0'
expect_hasnt 'bash 无残留 3.0.0 版本常量' "$out" 'ServPing 3.0.0'

# ===========================================================================
# 组 2：真实探测
# ===========================================================================
printf '\n[组 2] 真实探测（本机回环）\n'

if ! command -v python3 >/dev/null 2>&1; then
    skip 'HTTP 探测' '没有 python3'
    skip 'TCP 探测' '没有 python3'
else
    free_port() {
        python3 - <<'PY'
import socket
s = socket.socket(); s.bind(('127.0.0.1', 0)); print(s.getsockname()[1]); s.close()
PY
    }
    wait_port() { # <port> <秒>
        local i=0
        while [ "$i" -lt "$2" ]; do
            if python3 -c "import socket,sys; s=socket.socket(); s.settimeout(0.2)
try:
    s.connect(('127.0.0.1', $1)); sys.exit(0)
except Exception: sys.exit(1)" 2>/dev/null; then return 0; fi
            sleep 0.1; i=$((i + 1))
        done
        return 1
    }

    # ---- HTTP 服务 ----
    mkdir -p "$WORK/www"
    printf 'servping-marker\n' > "$WORK/www/index.html"
    P_HTTP=$(free_port)
    python3 -m http.server "$P_HTTP" --bind 127.0.0.1 --directory "$WORK/www" \
        >/dev/null 2>&1 &
    SRV_PIDS="$SRV_PIDS $!"

    if wait_port "$P_HTTP" 50; then
        cfg "$WORK/h.conf" "Host \"Loop\" 127.0.0.1
ServPort \"Web\" $P_HTTP \"网页\" http
"
        out=$("$SUT" -f "$WORK/h.conf" Loop Web -c 1 -W 2 2>&1); rc=$?
        expect_rc 'HTTP 200 -> rc 0' 0 "$rc"
        expect_has 'HTTP 模式报状态码' "$out" '(HTTP 200)'
        expect_has '结论行 OK' "$out" '网页: OK'

        out=$("$SUT" -f "$WORK/h.conf" -p "$P_HTTP" -s Web -c 1 -W 1 2>&1)
        expect_has '-p 覆盖端口生效' "$out" "127.0.0.1:$P_HTTP"

        # ---- 302 重定向：健康，但必须单独标 REDIRECT，且绝不算丢包 ----
        cat > "$WORK/redir.py" <<'PY'
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(302)
        self.send_header('Location', '/target')
        self.send_header('Content-Length', '0')
        self.end_headers()
    def log_message(self, *args):
        pass
HTTPServer(('127.0.0.1', int(sys.argv[1])), H).serve_forever()
PY
        P_RED=$(free_port)
        python3 "$WORK/redir.py" "$P_RED" >/dev/null 2>&1 &
        SRV_PIDS="$SRV_PIDS $!"
        if wait_port "$P_RED" 50; then
            cfg "$WORK/r.conf" "Host \"Loop\" 127.0.0.1
ServPort \"Redir\" $P_RED \"重定向\" http
"
            out=$("$SUT" -f "$WORK/r.conf" Loop Redir -c 1 -W 2 2>&1); rc=$?
            expect_rc 'HTTP 302 -> rc 0' 0 "$rc"
            expect_has '302 输出 redirect from' "$out" 'redirect from'
            expect_has '302 显示 HTTP 302' "$out" '(HTTP 302)'
            expect_has '302 不算丢包' "$out" '0.0% packet loss'
            expect_has '302 received=1' "$out" '1 probes transmitted, 1 received'
            expect_hasnt '302 不报 no reply' "$out" 'no reply'
            expect_has '302 结论 OK' "$out" '重定向: OK'
        else
            skip 'HTTP 302 探测' '本地重定向服务没起来'
        fi

        # ---- 500：失败，但响应已收到，不能报 no reply / 丢包 ----
        cat > "$WORK/err500.py" <<'PY'
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(500)
        self.send_header('Content-Length', '2')
        self.end_headers()
        self.wfile.write(b'ER')
    def log_message(self, *args):
        pass
HTTPServer(('127.0.0.1', int(sys.argv[1])), H).serve_forever()
PY
        P_500=$(free_port)
        python3 "$WORK/err500.py" "$P_500" >/dev/null 2>&1 &
        SRV_PIDS="$SRV_PIDS $!"
        if wait_port "$P_500" 50; then
            cfg "$WORK/e500.conf" "Host \"Loop\" 127.0.0.1
ServPort \"Fail500\" $P_500 \"错误500\" http
"
            out=$("$SUT" -f "$WORK/e500.conf" Loop Fail500 -c 1 -W 2 2>&1); rc=$?
            expect_rc 'HTTP 500 -> rc 1' 1 "$rc"
            expect_has '500 报真实 HTTP 原因' "$out" 'HTTP 500 unexpected (expect 2xx/3xx)'
            expect_has '500 不算丢包' "$out" '0.0% packet loss'
            expect_has '500 received=1' "$out" '1 probes transmitted, 1 received'
            expect_hasnt '500 不报 no reply' "$out" 'no reply'
            expect_has '500 结论含状态码' "$out" 'FAILED (HTTP 500 unexpected'
        else
            skip 'HTTP 500 探测' '本地错误服务没起来'
        fi

        # 响应体关键字：命中 / 未命中
        cfg "$WORK/b1.conf" "Host 127.0.0.1
ServPort \"Web\" $P_HTTP \"网页\" http \"servping-marker\"
"
        "$SUT" -f "$WORK/b1.conf" -c 1 -W 2 >/dev/null 2>&1
        expect_rc '响应体关键字命中 -> rc 0' 0 $?

        cfg "$WORK/b2.conf" "Host 127.0.0.1
ServPort \"Web\" $P_HTTP \"网页\" http \"no-such-marker\"
"
        out=$("$SUT" -f "$WORK/b2.conf" -c 1 -W 2 2>&1); rc=$?
        expect_rc '响应体关键字不命中 -> rc 1' 1 "$rc"
        expect_has '不命中时说明是 body mismatch' "$out" 'body mismatch'
    else
        skip 'HTTP 探测' '本地 HTTP 服务没起来'
    fi

    # ---- 静默 TCP 服务（连上但不回数据）----
    P_TCP=$(free_port)
    python3 - "$P_TCP" <<'PY' >/dev/null 2>&1 &
import socket, sys
port = int(sys.argv[1])
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('127.0.0.1', port)); s.listen(8)
conns = []
while True:
    c, _ = s.accept()
    conns.append(c)          # 接受连接但什么都不发
PY
    SRV_PIDS="$SRV_PIDS $!"

    if wait_port "$P_TCP" 50; then
        cfg "$WORK/t.conf" "Host 127.0.0.1
ServPort \"Silent\" $P_TCP \"静默服务\" tcp
"
        out=$("$SUT" -f "$WORK/t.conf" -c 1 -W 2 2>&1); rc=$?
        expect_rc 'tcp 模式对静默服务 -> rc 0' 0 "$rc"
        expect_has 'tcp 模式输出 connected' "$out" 'connected  from'

        out=$("$SUT" -f "$WORK/t.conf" -c 1 -W 2 -s Silent -t 2>&1)
        expect_rc '-t 强制 tcp 同一个靶 -> rc 0' 0 $?

        cfg "$WORK/t2.conf" "Host 127.0.0.1
ServPort \"Silent\" $P_TCP \"静默服务\" http
"
        out=$("$SUT" -f "$WORK/t2.conf" -c 1 -W 1 2>&1); rc=$?
        expect_rc '同一静默靶用 http 判 -> rc 1' 1 "$rc"
    else
        skip 'TCP 探测' '本地静默服务没起来'
    fi

    # ---- 关闭的端口：两种模式都应失败且不是 "HTTP 000" ----
    P_CLOSED=$(free_port)
    cfg "$WORK/x.conf" "Host 127.0.0.1
ServPort \"Dead\" $P_CLOSED \"关了\" http
ServPort \"DeadT\" $P_CLOSED \"关了tcp\" tcp
"
    out=$("$SUT" -f "$WORK/x.conf" -c 1 -W 1 2>&1); rc=$?
    expect_rc '关闭端口（http）-> rc 1' 1 "$rc"
    expect_has '关闭端口报 Connection refused' "$out" 'Connection refused'
    out=$("$SUT" -f "$WORK/x.conf" DeadT -c 1 -W 1 2>&1); rc=$?
    expect_rc '关闭端口（tcp）-> rc 1' 1 "$rc"
fi

# ===========================================================================
printf '\n-------------------------------------------------\n'
printf '通过 %d / 失败 %d / 跳过 %d\n' "$PASS" "$FAIL" "$SKIP"
if [ "$FAIL" -gt 0 ]; then
    printf '失败项:%s\n' "$FAILED_NAMES"
    exit 1
fi
printf '全部通过。\n'
exit 0
