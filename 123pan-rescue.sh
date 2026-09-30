#!/usr/bin/env bash
# =============================================================================
#  123pan-rescue.sh — 123云盘 WebDAV 全量取回 / 备份工具
#
#  把 123云盘「我的文件」完整、可续传、可对账地搬到本地磁盘。
#  为长时间无人值守设计：随时 Ctrl-C，随时重跑续传，全程留下可核对的记录。
#
#  快速开始：
#     ./123pan-rescue.sh            # 交互式菜单（第一次推荐这样用）
#     ./123pan-rescue.sh init       # 配置向导：服务器 / 账号 / 应用密码 / 目标目录
#     ./123pan-rescue.sh all        # 无人值守一条龙：体检 → 清单 → 下载 → 对账
#
#  子命令：
#     init        配置向导（写入 ~/.config/123pan-rescue/config，权限 600）
#     menu        交互式菜单
#     preflight   体检：连通性 / 认证 / 空间 / 权限（不下载任何文件）
#     manifest    拉取云端全量清单（路径 + 大小），后续对账的底账
#     run         下载（按顶层目录分批，可反复重跑续传）
#     status      看进度（秒出）；status deep 会真的逐项核对本地
#     verify      全量对账 + 生成报告（三绿才算成功）
#     crosscheck  与「目录树 txt」交叉核对（可选，只报告不判定）
#     settings    交互式修改并发 / 跳过 / 优先级等
#     reset       清空断点状态（不动任何已下载的文件）
#     all         preflight + manifest + run（run 结尾自带 verify）
#     version / help
#
#  常用参数：
#     -d DIR    目标目录          -t N   并发传输数
#     -u URL    服务器地址        -c N   并发列目录数
#     -a 账号   WebDAV 账号       -l R   限速（如 10M）
#     -P A,B    下载优先级        -s A,B 跳过这些顶层目录
#     -y        所有询问默认同意  -n     演练模式（不落盘）
#     -q        安静模式          --no-color  关闭彩色
#
#  配置优先级：命令行参数 > 环境变量 > 配置文件 > 内置默认
#
#  安全保证：
#     * 只调用 rclone 的 copy / copyto / lsd / lsjson / about，绝不 sync / delete
#     * 续传判定用 --size-only：已存在且大小一致的文件直接跳过
#     * 中断时先把「正在下载的文件」写进检查点，再优雅结束 rclone
#     * 云端清单缩水时拒绝覆盖旧清单（防止漏列被误判成"对账通过"）
# =============================================================================

set -Eeuo pipefail

VERSION="2.0.0"
PROG="$(basename "$0")"
SCRIPT_NAME="$PROG"

# ============================== 交互与颜色 ==================================
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_RST=$'\033[0m'; C_B=$'\033[1m'; C_DIM=$'\033[2m'
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_CYN=$'\033[36m'
else
  C_RST=""; C_B=""; C_DIM=""; C_RED=""; C_GRN=""; C_YEL=""; C_CYN=""
fi
INTERACTIVE=0
[[ -t 0 && -t 1 ]] && INTERACTIVE=1
FORCE_MENU=0
QUIET="${QUIET:-0}"
ASSUME_YES="${ASSUME_YES:-0}"

# ============================== 配置文件 ====================================
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/123pan-rescue"
CONFIG_FILE="${CONFIG_FILE:-$CONFIG_DIR/config}"
DEFAULT_URL="https://webdav.123pan.cn/webdav"
DEFAULT_DEST="$HOME/123pan"

config_get() {  # config_get <key> [默认值]
  local key="$1" def="${2:-}" line val
  [[ -f "$CONFIG_FILE" ]] || { printf '%s' "$def"; return 0; }
  line="$(grep -m1 -E "^[[:space:]]*${key}[[:space:]]*=" "$CONFIG_FILE" 2>/dev/null || true)"
  [[ -n "$line" ]] || { printf '%s' "$def"; return 0; }
  val="${line#*=}"
  val="${val#"${val%%[![:space:]]*}"}"     # 去左空白
  val="${val%"${val##*[![:space:]]}"}"     # 去右空白
  val="${val%\"}"; val="${val#\"}"
  printf '%s' "$val"
}

config_set() {  # config_set <key> <value>   （写单个键，权限 600）
  local key="$1" val="$2" tmp line dir
  dir="$(dirname "$CONFIG_FILE")"      # 以 CONFIG_FILE 为准，允许用户自定义位置
  mkdir -p "$dir" || die "无法创建配置目录：$dir"
  tmp="$(mktemp "$dir/.config.XXXXXX")" || die "无法在 $dir 下创建临时文件"
  if [[ -f "$CONFIG_FILE" ]]; then
    grep -v -E "^[[:space:]]*${key}[[:space:]]*=" "$CONFIG_FILE" > "$tmp" 2>/dev/null || true
  fi
  printf '%s=%s\n' "$key" "$val" >> "$tmp"
  umask 077; mv -f "$tmp" "$CONFIG_FILE"; chmod 600 "$CONFIG_FILE"
}

# ============================== 配置解析 ====================================
# 顺序：命令行 > 环境变量 > 配置文件 > 内置默认。
# 先把环境变量快照下来，否则读完配置文件就分不清"环境给过"和"用的是默认值"。
for _v in WEBDAV_URL WEBDAV_USER WEBDAV_PASS DEST TRANSFERS CHECKERS MAX_ATTEMPTS \
          RETRY_SLEEP BW_LIMIT DRY_RUN VENDOR_CANDIDATES MIN_FREE_FACTOR \
          PRIORITY SKIP_ITEMS ALLOW_SHRINK; do
  if [[ -n "${!_v:-}" ]]; then printf -v "ENV_$_v" '%s' "${!_v}"; fi
done

WEBDAV_URL="${ENV_WEBDAV_URL:-$(config_get webdav_url "$DEFAULT_URL")}"
WEBDAV_USER="${ENV_WEBDAV_USER:-$(config_get webdav_user "")}"
WEBDAV_PASS="${ENV_WEBDAV_PASS:-}"                                   # 明文，仅环境变量给
WEBDAV_PASS_OBSCURED="${ENV_WEBDAV_PASS_OBSCURED:-$(config_get webdav_pass_obscured "")}"
DEST="${ENV_DEST:-$(config_get dest "$DEFAULT_DEST")}"
TRANSFERS="${ENV_TRANSFERS:-$(config_get transfers 4)}"
CHECKERS="${ENV_CHECKERS:-$(config_get checkers 8)}"
MAX_ATTEMPTS="${ENV_MAX_ATTEMPTS:-$(config_get max_attempts 5)}"
RETRY_SLEEP="${ENV_RETRY_SLEEP:-$(config_get retry_sleep 20)}"
BW_LIMIT="${ENV_BW_LIMIT:-$(config_get bw_limit "")}"
DRY_RUN="${ENV_DRY_RUN:-$(config_get dry_run 0)}"
VENDOR_CANDIDATES="${ENV_VENDOR_CANDIDATES:-$(config_get vendor_candidates "other rclone nextcloud")}"
MIN_FREE_FACTOR="${ENV_MIN_FREE_FACTOR:-$(config_get min_free_factor 105)}"
PRIORITY_STR="${ENV_PRIORITY:-$(config_get priority "")}"
SKIP_STR="${ENV_SKIP_ITEMS:-$(config_get skip_items "")}"
ALLOW_SHRINK="${ENV_ALLOW_SHRINK:-$(config_get allow_shrink 0)}"
DEST="${DEST/#\~/$HOME}"                                             # 支持配置里写 ~/xxx

# 逗号分隔 → 数组；没有逗号时按空白切（兼容老写法）。目录名里的空格不会被误切。
split_list() {
  local s="${1:-}" part
  local parts=()
  if [[ "$s" == *,* ]]; then IFS=',' read -ra parts <<< "$s"; else read -ra parts <<< "$s"; fi
  for part in "${parts[@]}"; do
    part="${part#"${part%%[![:space:]]*}"}"
    part="${part%"${part##*[![:space:]]}"}"
    [[ -n "$part" ]] && printf '%s\n' "$part"
  done
  return 0
}
PRIORITY_ITEMS=(); SKIP_ITEMS=()
mapfile -t PRIORITY_ITEMS < <(split_list "$PRIORITY_STR")
mapfile -t SKIP_ITEMS     < <(split_list "$SKIP_STR")

# =============================================================================

REMOTE_NAME="pan123"
ROOT_ITEM="__ROOT__"           # 伪条目：我的文件根目录下的散装文件
STATE_SUBDIR=".from123-state"  # 状态目录名（会被 rclone 排除，不会被当成云端内容）

STATE_DIR="$DEST/$STATE_SUBDIR"
LOG_DIR="$STATE_DIR/logs"
ITEM_DIR="$STATE_DIR/items"
RCLONE_CONF="$STATE_DIR/rclone.conf"
MANIFEST_TSV="$STATE_DIR/manifest.tsv"
MANIFEST_META="$STATE_DIR/manifest.meta"
ROOTFILES="$STATE_DIR/rootfiles.txt"
CHECKPOINT="$STATE_DIR/checkpoint.txt"
SUMMARY="$STATE_DIR/summary.txt"
VERIFY_REPORT="$STATE_DIR/verify-report.txt"
LOCKFILE="$STATE_DIR/lock"
SECRET_FILE="$STATE_DIR/secret"
HELPER="$STATE_DIR/helper.py"
PICKED_VENDOR_FILE="$STATE_DIR/vendor"
FINGERPRINT_FILE="$STATE_DIR/conf.fingerprint"
INFLIGHT_SNAPSHOT="$STATE_DIR/inflight-snapshot.txt"

RCLONE_BIN="${RCLONE_BIN:-rclone}"
PYTHON_BIN="${PYTHON_BIN:-python3}"

CURRENT_RCLONE_PID=""
INTERRUPTED=0
CURRENT_ITEM=""

# ============================== 小工具 =======================================
log()  { (( QUIET )) && return 0; printf '%s[%s]%s %s\n' "$C_DIM" "$(date '+%F %T')" "$C_RST" "$*"; }
ok()   { (( QUIET )) && return 0; printf '%s[%s]%s %s%s%s\n' "$C_DIM" "$(date '+%F %T')" "$C_RST" "$C_GRN" "$*" "$C_RST"; }
warn() { printf '%s[%s] !!%s %s%s%s\n' "$C_DIM" "$(date '+%F %T')" "$C_RST" "$C_YEL" "$*" "$C_RST" >&2; }
die()  { printf '%s[%s] 致命错误:%s %s%s%s\n' "$C_DIM" "$(date '+%F %T')" "$C_RST" "$C_RED" "$*" "$C_RST" >&2; exit 1; }

disp_width() {  # 终端显示宽度（中文/全角记 2 列，ASCII 记 1 列）
  local s="$1" w=0 i c
  for (( i=0; i<${#s}; i++ )); do
    c="${s:i:1}"
    if [[ "$c" == [!\ -~] ]]; then w=$(( w + 2 )); else w=$(( w + 1 )); fi
  done
  printf '%d' "$w"
}

pad() {  # pad <字符串> <目标显示宽度>
  local s="$1" target="$2" w
  w="$(disp_width "$s")"
  printf '%s' "$s"
  while (( w < target )); do printf ' '; w=$(( w + 1 )); done
}

human() {  # 字节 -> 人类可读
  if [[ -z "${1:-}" ]]; then printf '?'; return 0; fi
  "${PYTHON_BIN}" -c 'import sys
n=float(sys.argv[1])
for u in ["B","KiB","MiB","GiB","TiB"]:
    if n<1024 or u=="TiB": print(f"{n:.2f}{u}"); break
    n/=1024' "$1"
}

safe_name() {  # 把任意目录名变成安全文件名（保留可读前缀 + 唯一后缀）
  local n="$1" h
  h="$(printf '%s' "$1" | cksum | cut -d' ' -f1)"
  n="$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_' | cut -c1-60)"
  printf '%s-%s' "${n:-item}" "$h"
}

state_file() { printf '%s/%s.state' "$ITEM_DIR" "$(safe_name "$1")"; }

state_get() {  # state_get <file> <key>
  local f="$1" k="$2"
  [[ -f "$f" ]] || return 0
  sed -n "s/^${k}=//p" "$f" | tail -1
}

state_set() {  # state_set <file> key=value ...
  local f="$1"; shift
  [[ -f "$f" ]] || : > "$f"
  local kv k v tmp="$f.tmp.$$"
  for kv in "$@"; do
    k="${kv%%=*}"; v="${kv#*=}"
    grep -v "^${k}=" "$f" > "$tmp" 2>/dev/null || : > "$tmp"
    printf '%s=%s\n' "$k" "$v" >> "$tmp"
    mv "$tmp" "$f"
  done
}

ensure_dirs() { mkdir -p "$DEST" "$STATE_DIR" "$LOG_DIR" "$ITEM_DIR"; }

# ============================== 密码与配置 ===================================
have_pass_source() {  # 只判断"有没有密码来源"，不调用 rclone
  [[ -n "$WEBDAV_PASS" || -n "$WEBDAV_PASS_OBSCURED" || -f "$SECRET_FILE" ]]
}

resolve_pass_obscured() {  # 输出 rclone 混淆格式的密码，直接写进 rclone 配置
  if [[ -n "$WEBDAV_PASS" ]]; then
    "$RCLONE_BIN" obscure "$WEBDAV_PASS"; return 0
  fi
  if [[ -n "$WEBDAV_PASS_OBSCURED" ]]; then
    printf '%s' "$WEBDAV_PASS_OBSCURED"; return 0
  fi
  if [[ -f "$SECRET_FILE" ]]; then      # 兼容 1.x 版本存在状态目录里的明文密码
    "$RCLONE_BIN" obscure "$(cat "$SECRET_FILE")"; return 0
  fi
  return 1
}

ensure_config() {  # 缺配置时：交互环境自动走向导，非交互环境明确报错
  if [[ -z "$WEBDAV_USER" ]] || ! have_pass_source; then
    if (( INTERACTIVE )) && (( ! ASSUME_YES )); then
      warn "还没有配置（或缺少应用密码），先走一遍配置向导。"
      cmd_init
    else
      die "缺少配置：请先运行 $PROG init，或设置 WEBDAV_URL / WEBDAV_USER / WEBDAV_PASS 环境变量"
    fi
  fi
}

cmd_setpass() {  # 只更新应用密码（其它配置不动）
  local p1 p2
  printf '请输入 123云盘应用密码（在「工具中心 → 第三方挂载 → 授权列表」里复制）: ' >&2
  IFS= read -rs p1 || true; echo >&2
  [[ -n "$p1" ]] || die "密码为空"
  printf '再输一次确认: ' >&2
  IFS= read -rs p2 || true; echo >&2
  [[ "$p1" == "$p2" ]] || die "两次输入不一致"
  local ob
  ob="$("$RCLONE_BIN" obscure "$p1")" || die "rclone obscure 失败"
  config_set webdav_pass_obscured "$ob"
  ok "已更新密码：$CONFIG_FILE（权限 600）"
  echo "   提示：该密码等于云盘授权目录的访问权限，别贴给任何人。" >&2
}

write_conf_to() {  # write_conf_to <配置文件路径> <vendor>
  local path="$1" vendor="$2" obscured
  obscured="$(resolve_pass_obscured)" || die "没有可用密码：请先运行 $PROG init"
  ensure_dirs
  umask 077
  cat > "$path" <<EOF
[$REMOTE_NAME]
type = webdav
url = $WEBDAV_URL
vendor = $vendor
user = $WEBDAV_USER
pass = $obscured
EOF
  chmod 600 "$path"
}

write_conf() { write_conf_to "$RCLONE_CONF" "$1"; }

rclone_cmd() { "$RCLONE_BIN" --config "$RCLONE_CONF" "$@"; }

# rclone 版本能力探测：老版本没有 --log-file-max-size，不能盲目加参数
RCLONE_HAS_LOGSIZE=0
rclone_check_version() {
  local v
  v="$("$RCLONE_BIN" version 2>/dev/null | head -1 | awk '{print $2}')"
  RCLONE_VERSION="${v:-未知}"
  if "$RCLONE_BIN" copy --help 2>/dev/null | grep -q -- '--log-file-max-size'; then
    RCLONE_HAS_LOGSIZE=1
  fi
  case "$RCLONE_VERSION" in
    v1.[0-5].*|v0.*) warn "rclone 版本较老（$RCLONE_VERSION），建议升级到 1.60+：https://rclone.org/install/" ;;
  esac
}

# 逐个 vendor 试认证；成功才把配置落到正式位置（失败时绝不污染正式配置）
probe_vendors() {
  local vendor tryconf="$STATE_DIR/rclone.conf.try"
  local candidates="${VENDOR_CANDIDATES}"
  # 若用户显式指定了单个 vendor（没有空格分隔的候选），就只试它
  for vendor in $candidates; do
    write_conf_to "$tryconf" "$vendor"
    if "$RCLONE_BIN" --config "$tryconf" lsd "$REMOTE_NAME:" >/dev/null 2>"$STATE_DIR/preflight-last.err"; then
      mv -f "$tryconf" "$RCLONE_CONF"
      printf '%s' "$vendor" > "$PICKED_VENDOR_FILE"
      log "认证成功：vendor=$vendor（已写入 $RCLONE_CONF）"
      return 0
    fi
    warn "vendor=$vendor 认证/列目录失败：$(tail -1 "$STATE_DIR/preflight-last.err" 2>/dev/null)"
  done
  rm -f "$tryconf"
  return 1
}

# 凭据指纹：服务器地址/账号/密码/ vendor 任一变化，都必须重新认证，
# 否则会拿旧密码换来的缓存配置"假通过"（自检里踩过这个坑）
cred_fingerprint() {  # $1 = vendor
  { printf '%s\n' "$WEBDAV_URL" "$WEBDAV_USER" "$(resolve_pass_obscured 2>/dev/null || echo '')" "$1"; } \
    | sha256sum | cut -d' ' -f1
}

# 确保远端可用：配置齐备、凭据未变且能列目录；不满足则自动重新探测
prepare_remote() {
  have_pass_source || die "没有可用密码：请先运行 $PROG init（或用 WEBDAV_PASS 环境变量）"
  ensure_dirs
  write_helper
  local vendor="" confv="" want_fp="" have_fp=""
  [[ -f "$PICKED_VENDOR_FILE" ]] && vendor="$(cat "$PICKED_VENDOR_FILE" 2>/dev/null || true)"
  if [[ -n "$vendor" && -f "$RCLONE_CONF" ]]; then
    confv="$(sed -n 's/^vendor = //p' "$RCLONE_CONF" 2>/dev/null | head -1)"
    want_fp="$(cred_fingerprint "$vendor")"
    [[ -f "$FINGERPRINT_FILE" ]] && have_fp="$(cat "$FINGERPRINT_FILE" 2>/dev/null || true)"
    if [[ "$confv" != "$vendor" ]]; then
      warn "配置里的 vendor($confv) 与记录($vendor) 不一致，重新探测"
    elif [[ "$have_fp" != "$want_fp" ]]; then
      warn "服务器地址/账号/密码有变化，重新认证"
    elif rclone_cmd lsd "$REMOTE_NAME:" >/dev/null 2>&1; then
      return 0
    else
      warn "现有配置无法列目录，重新探测 vendor"
    fi
  fi
  if ! probe_vendors; then
    warn "所有 vendor 都没通过。最后一条错误："
    cat "$STATE_DIR/preflight-last.err" 2>/dev/null >&2 || true
    die "WebDAV 认证失败。请确认：① 会员是否已开通（第三方挂载需要会员）② 应用密码是否复制正确 ③ 授权目录选的是不是「我的文件」"
  fi
  vendor="$(cat "$PICKED_VENDOR_FILE" 2>/dev/null || true)"
  cred_fingerprint "$vendor" > "$FINGERPRINT_FILE"
  return 0
}

# 带中断转发的 rclone 调用
rclone_run() {
  local rc=0
  "$RCLONE_BIN" --config "$RCLONE_CONF" "$@" &
  CURRENT_RCLONE_PID=$!
  wait "$CURRENT_RCLONE_PID" || rc=$?
  CURRENT_RCLONE_PID=""
  return $rc
}

on_signal() {
  INTERRUPTED=1
  warn "收到中断信号：先记录正在下载的文件，再优雅结束 rclone（已下载的文件都会保留）…"
  # 关键顺序：rclone 优雅退出时会删掉 *.partial 临时文件，
  # 所以必须“先拍照”再结束它，否则检查点就看不到中断时在下哪个文件。
  snapshot_inflight "$CURRENT_ITEM" || true
  if [[ -n "$CURRENT_RCLONE_PID" ]] && kill -0 "$CURRENT_RCLONE_PID" 2>/dev/null; then
    kill -INT "$CURRENT_RCLONE_PID" 2>/dev/null || true
    local i
    for i in $(seq 1 30); do
      kill -0 "$CURRENT_RCLONE_PID" 2>/dev/null || break
      sleep 1
    done
    if kill -0 "$CURRENT_RCLONE_PID" 2>/dev/null; then
      warn "rclone 未在 30 秒内退出，发送 TERM"
      kill -TERM "$CURRENT_RCLONE_PID" 2>/dev/null || true
    fi
  fi
}
trap on_signal INT TERM

# ============================== python 助手 ==================================
HELPER_VERSION="3"

write_helper() {
  ensure_dirs
  local stamp="$STATE_DIR/helper.version"
  # 版本一致就不重写：既能只读环境下降级工作，也避免每次命令都动磁盘
  if [[ -f "$HELPER" && -f "$stamp" ]] && [[ "$(cat "$stamp" 2>/dev/null)" == "$HELPER_VERSION" ]]; then
    return 0
  fi
  local tmp="$HELPER.tmp.$$"
  if cat > "$tmp" <<'PYEOF'
#!/usr/bin/env python3
# from123.sh 的核对引擎：清单构建 / 逐项核对 / 全量对账 / 目录树交叉核对
import sys, os, json, collections

STATE_SUBDIR = ".from123-state"


def load_manifest(p):
    m = {}
    with open(p, "r", encoding="utf-8", errors="surrogateescape") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line:
                continue
            size, path = line.split("\t", 1)
            m[path] = int(size)
    return m


def local_files(root, skip_state=True):
    out = {}
    if not os.path.isdir(root):
        return out
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        if skip_state:
            dirnames[:] = [d for d in dirnames if d != STATE_SUBDIR]
        for fn in filenames:
            full = os.path.join(dirpath, fn)
            rel = os.path.relpath(full, root)
            try:
                st = os.lstat(full)
            except OSError:
                continue
            if not os.path.isfile(full) or os.path.islink(full):
                continue
            out[rel] = st.st_size
    return out


def local_files_shallow(root):
    """只扫根目录一层，不递归（用于 __ROOT__ 项，避免把整棵树都算成多余文件）"""
    out = {}
    try:
        names = os.listdir(root)
    except OSError:
        return out
    for fn in names:
        if fn == STATE_SUBDIR:
            continue
        full = os.path.join(root, fn)
        try:
            st = os.lstat(full)
        except OSError:
            continue
        if os.path.isfile(full) and not os.path.islink(full):
            out[fn] = st.st_size
    return out


def subset_for(m, item):
    if item == "__ROOT__":
        return {k: v for k, v in m.items() if "/" not in k}
    pref = item + "/"
    return {k: v for k, v in m.items() if k == item or k.startswith(pref)}


def cmd_manifest(src, out_tsv, out_meta):
    with open(src, "r", encoding="utf-8", errors="surrogateescape") as f:
        data = f.read().strip()
    if not data:
        print("FILES=0 BYTES=0")
        open(out_tsv, "w").close()
        with open(out_meta, "w") as g:
            g.write("files=0\nbytes=0\n")
        return 0
    entries = json.loads(data)
    files, dirs = [], 0
    for e in entries:
        if e.get("IsDir"):
            dirs += 1
            continue
        p = e["Path"]
        files.append((p, int(e.get("Size") or 0)))
    _write_manifest(files, out_tsv, out_meta)
    return 0


def _write_manifest(items, out_tsv, out_meta):
    items = sorted(items)
    total = sum(s for _, s in items)
    with open(out_tsv, "w", encoding="utf-8", errors="surrogateescape") as g:
        for p, s in items:
            g.write("%d\t%s\n" % (s, p))
    with open(out_meta, "w", encoding="utf-8") as g:
        g.write("files=%d\nbytes=%d\ndirs=%d\n" % (len(items), total, 0))
    print("FILES=%d BYTES=%d DIRS=0" % (len(items), total))


def cmd_manifest_fragments(fraglist, out_tsv, out_meta):
    """把「每个顶层目录一份 lsjson」合并成总清单。
    fraglist 每行: <前缀>\t<json文件>（前缀为空表示根目录散装文件）"""
    files = []
    with open(fraglist, "r", encoding="utf-8", errors="surrogateescape") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line:
                continue
            prefix, path = line.split("\t", 1)
            try:
                with open(path, "r", encoding="utf-8", errors="surrogateescape") as g:
                    data = g.read().strip()
            except OSError:
                continue
            if not data:
                continue
            for e in json.loads(data):
                if e.get("IsDir"):
                    continue
                p = e["Path"] if not prefix else prefix + "/" + e["Path"]
                files.append((p, int(e.get("Size") or 0)))
    best = {}
    for p, sz in files:
        if p not in best or sz > best[p]:
            best[p] = sz
    _write_manifest(list(best.items()), out_tsv, out_meta)
    return 0


def cmd_manifest_cmp(old_meta, new_meta, allow_shrink):
    """比较新旧清单。缩水说明这次列目录被索引延迟截断了，必须拒绝覆盖，
    否则 verify 会对着"残缺清单"报三绿，看起来成功实则丢数据。"""

    def load(p):
        d = {}
        try:
            with open(p, "r", encoding="utf-8") as f:
                for line in f:
                    if "=" in line:
                        k, v = line.strip().split("=", 1)
                        d[k] = int(v)
        except (OSError, ValueError):
            return None
        return d

    o = load(old_meta)
    n = load(new_meta)
    if o is None:
        print("NO_OLD_MANIFEST")
        return 0
    if n is None:
        print("BAD_NEW_MANIFEST")
        return 3
    df = n.get("files", 0) - o.get("files", 0)
    db = n.get("bytes", 0) - o.get("bytes", 0)
    print("OLD_FILES=%d NEW_FILES=%d DELTA_FILES=%d DELTA_BYTES=%d"
          % (o.get("files", 0), n.get("files", 0), df, db))
    if df < 0 or db < 0:
        if allow_shrink in ("1", "true", "yes"):
            print("SHRINK_ALLOWED")
            return 0
        print("SHRINK_REFUSED")
        return 3
    print("OK")
    return 0


def cmd_topitems(manifest):
    m = load_manifest(manifest)
    agg = collections.Counter()
    cnt = collections.Counter()
    for p, s in m.items():
        if "/" in p:
            top = p.split("/", 1)[0]
        else:
            top = "__ROOT__"
        agg[top] += s
        cnt[top] += 1
    for k, v in sorted(agg.items(), key=lambda x: (-x[1], x[0])):
        print("%s\t%d\t%d" % (k, v, cnt[k]))
    return 0


def _detail(item, exp, got, dest_root, detail_path):
    missing = sorted(k for k in exp if k not in got)
    mismatch = sorted(k for k in exp if k in got and got[k] != exp[k])
    extra = sorted(k for k in got if k not in exp)
    ok_bytes = sum(exp[k] for k in exp if got.get(k) == exp[k])
    d = {
        "item": item,
        "dest": os.path.join(dest_root, item) if item != "__ROOT__" else dest_root,
        "expected_files": len(exp),
        "expected_bytes": sum(exp.values()),
        "present_files": sum(1 for k in exp if got.get(k) == exp[k]),
        "ok_bytes": ok_bytes,
        "missing": missing,
        "mismatch": mismatch,
        "extra": extra,
    }
    if detail_path:
        with open(detail_path, "w", encoding="utf-8", errors="surrogateescape") as g:
            json.dump(d, g, ensure_ascii=False, indent=1)
    return d


def _emit(d):
    print("missing=%d mismatch=%d extra=%d expected_files=%d expected_bytes=%d "
          "present_files=%d ok_bytes=%d" % (
              len(d["missing"]), len(d["mismatch"]), len(d["extra"]),
              d["expected_files"], d["expected_bytes"],
              d["present_files"], d["ok_bytes"]))
    for k in d["missing"][:15]:
        print("MISSING\t%s" % k)
    for k in d["mismatch"][:15]:
        print("MISMATCH\t%s" % k)
    for k in d["extra"][:15]:
        print("EXTRA\t%s" % k)


def cmd_item_check(manifest, item, dest_root, detail_path=""):
    m = load_manifest(manifest)
    exp = subset_for(m, item)
    if item == "__ROOT__":
        got = local_files_shallow(dest_root)
    else:
        # 必须补上 item 前缀，否则本地相对路径与清单全路径永远对不上（曾导致所有条目被判"缺失"）
        raw = local_files(os.path.join(dest_root, item))
        got = {item + "/" + k: v for k, v in raw.items()}
    _emit(_detail(item, exp, got, dest_root, detail_path))
    return 0


def cmd_verify(manifest, dest_root, report_path):
    m = load_manifest(manifest)
    got = local_files(dest_root)
    d = _detail("__ALL__", m, got, dest_root, "")
    # 先把结论打出来：报告写不下去（只读目录 / 磁盘满）时，验收结论也不能丢
    _emit(d)
    try:
        with open(report_path, "w", encoding="utf-8", errors="surrogateescape") as g:
            g.write("# 全量对账报告  %s\n" % __import__("time").strftime("%F %T"))
            g.write("期望文件数: %d\n期望总字节: %d (%s)\n" % (
                d["expected_files"], d["expected_bytes"], _h(d["expected_bytes"])))
            g.write("本地完整文件数: %d\n本地完整字节: %d (%s)\n" % (
                d["present_files"], d["ok_bytes"], _h(d["ok_bytes"])))
            g.write("缺失: %d\n大小不符: %d\n多余(非清单内): %d\n\n" % (
                len(d["missing"]), len(d["mismatch"]), len(d["extra"])))
            for tag, key in (("缺失", "missing"), ("大小不符", "mismatch"), ("多余", "extra")):
                if d[key]:
                    g.write("## %s (%d)\n" % (tag, len(d[key])))
                    for k in d[key][:2000]:
                        g.write("%s\n" % k)
                    if len(d[key]) > 2000:
                        g.write("... 其余 %d 项未列出\n" % (len(d[key]) - 2000))
                    g.write("\n")
        print("REPORT=%s" % report_path)
    except OSError as e:
        print("REPORT_WRITE_FAILED=%s (%s)" % (report_path, e))
    return 0 if (not d["missing"] and not d["mismatch"]) else 2


def cmd_crosscheck(manifest, treefile):
    m = load_manifest(manifest)
    mnames = collections.Counter(os.path.basename(p) for p in m)
    tnames = collections.Counter()
    with open(treefile, "r", encoding="utf-8", errors="surrogateescape") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line.strip():
                continue
            name = None
            i = max(line.rfind("├─"), line.rfind("└─"))
            if i >= 0:
                name = line[i + 2:].strip()
            else:
                s = line.lstrip("│ \t")
                if s and s != line:
                    name = s.strip()
            if not name or name == "我的文件":
                continue
            tnames[name] += 1
    only_tree = tnames - mnames
    only_manifest = mnames - tnames
    print("目录树文件名条目: %d（唯一 %d）" % (sum(tnames.values()), len(tnames)))
    print("云端清单文件数: %d（唯一 %d）" % (sum(mnames.values()), len(mnames)))
    print("仅目录树有: %d 种 / %d 个" % (len(only_tree), sum(only_tree.values())))
    print("仅云端清单有: %d 种 / %d 个" % (len(only_manifest), sum(only_manifest.values())))
    for n, c in list(only_tree.items())[:20]:
        print("TREE_ONLY\t%s" % n)
    for n, c in list(only_manifest.items())[:20]:
        print("MANIFEST_ONLY\t%s" % n)
    return 0


def _h(n):
    n = float(n)
    for u in ("B", "KiB", "MiB", "GiB", "TiB"):
        if n < 1024 or u == "TiB":
            return "%.2f%s" % (n, u)
        n /= 1024


def main():
    if len(sys.argv) < 2:
        print("usage: helper.py <cmd> ...", file=sys.stderr)
        return 64
    cmd = sys.argv[1]
    args = sys.argv[2:]
    fn = {
        "manifest": cmd_manifest,
        "manifest_fragments": cmd_manifest_fragments,
        "manifest_cmp": cmd_manifest_cmp,
        "topitems": cmd_topitems,
        "item_check": cmd_item_check,
        "verify": cmd_verify,
        "crosscheck": cmd_crosscheck,
    }.get(cmd)
    if not fn:
        print("unknown cmd %s" % cmd, file=sys.stderr)
        return 64
    return fn(*args)


if __name__ == "__main__":
    sys.exit(main())
PYEOF
  then
    mv -f "$tmp" "$HELPER" 2>/dev/null && printf '%s' "$HELPER_VERSION" > "$stamp" 2>/dev/null
    return 0
  fi
  rm -f "$tmp" 2>/dev/null || true
  if [[ -f "$HELPER" ]]; then
    warn "helper.py 无法更新（状态目录只读？），继续使用现有版本"
    return 0
  fi
  die "无法写入 $HELPER，请检查状态目录权限"
}

py() { "$PYTHON_BIN" "$HELPER" "$@"; }

# ============================== 前置检查 =====================================
check_dest_sanity() {
  [[ -n "$DEST" ]] || die "DEST 为空"
  [[ "$DEST" != "/" ]] || die "DEST 不能是根目录"
  case "$DEST" in
    /tmp/*|/dev/*|/proc/*|/sys/*) warn "DEST=$DEST 看起来在临时/系统目录上，确认这是你要的吗？" ;;
  esac
  local fs probe="$DEST"
  while [[ ! -e "$probe" && "$probe" != "/" ]]; do probe="$(dirname "$probe")"; done
  fs="$(df --output=fstype "$probe" 2>/dev/null | tail -1 || true)"
  case "$fs" in
    tmpfs|ramfs) die "DEST 落在内存文件系统（$fs）上，会把内存撑爆。请改到真实磁盘，例如 $HOME/123pan" ;;
  esac
}

acquire_lock() {
  ensure_dirs
  exec 9>"$LOCKFILE"
  if ! flock -n 9; then
    die "已有一个 $SCRIPT_NAME 在跑（锁：$LOCKFILE）。要强跑先确认旧进程已停。"
  fi
  printf '%s\n' "$$" > "$STATE_DIR/pid"
}

# ============================== preflight ====================================
cmd_preflight() {
  check_dest_sanity
  ensure_dirs
  log "===== 体检开始 ($PROG v$VERSION) ====="
  command -v "$RCLONE_BIN" >/dev/null || die "找不到 rclone"
  command -v "$PYTHON_BIN" >/dev/null || die "找不到 python3"
  write_helper
  rclone_check_version
  log "rclone: $("$RCLONE_BIN" version | head -1)"
  log "目标目录: $DEST"

  have_pass_source || die "没有可用密码：请先运行 $PROG init（或用 WEBDAV_PASS 环境变量）"
  log "密码: 已就绪（不回显）"
  log "服务器: $WEBDAV_URL   账号: $WEBDAV_USER"

  # 1) 网络可达性（未认证应得 401，说明边缘节点正常）
  local code
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "$WEBDAV_URL" 2>/dev/null || echo "000")"
  case "$code" in
    401|403) log "端点连通性: OK（HTTP $code，需要认证，符合预期）" ;;
    000)     die "连不上 $WEBDAV_URL，检查网络/代理" ;;
    2*)      log "端点连通性: HTTP $code（无需认证或已放行）" ;;
    *)       warn "端点返回 HTTP $code（继续尝试 rclone 认证）" ;;
  esac

  # 2) 认证（不通过会自动逐个 vendor 探测）
  prepare_remote

  # 3) 列顶层，确认真能看到内容
  local tops topcount try
  for try in 1 2 3 4 5; do
    tops="$(rclone_cmd lsf --dirs-only --format p "$REMOTE_NAME:" 2>/dev/null | sed 's:/$::' | sed '/^$/d' || true)"
    [[ -n "$tops" ]] && break
    warn "顶层目录列表为空（第 $try 次）——123云盘 WebDAV 首次索引可能较慢，8 秒后重试"
    sleep 8
  done
  topcount="$(printf '%s\n' "$tops" | sed '/^$/d' | wc -l)"
  if [[ -z "$tops" ]]; then
    warn "始终列不到顶层目录：多半是应用授权目录不是「我的文件」根目录，或云端索引尚未就绪。"
  fi
  log "顶层目录数: $topcount"
  printf '%s\n' "$tops" | sed '/^$/d' | head -40 | sed 's/^/    /'
  local rootf
  rootf="$(rclone_cmd lsf --files-only --format p "$REMOTE_NAME:" 2>/dev/null || true)"
  log "根目录散装文件: $(printf '%s\n' "$rootf" | sed '/^$/d' | wc -l) 个"

  # 4) 空间检查
  local avail
  avail="$(df -B1 --output=avail "$DEST" | tail -1 | tr -d ' ')"
  log "目标盘可用空间: $(human "$avail")"
  if [[ -f "$MANIFEST_META" ]]; then
    local need
    need="$(sed -n 's/^bytes=//p' "$MANIFEST_META")"
    local required=$(( need * MIN_FREE_FACTOR / 100 ))
    log "清单总量: $(human "$need")，需要预留: $(human "$required")"
    if (( avail < required )); then
      die "空间不足：可用 $(human "$avail") < 需要的 $(human "$required")"
    fi
    log "空间检查: 通过"
  else
    log "还没有清单（先跑 manifest 才能做精确空间检查）"
  fi

  # 5) 目标目录可写
  local t="$DEST/.from123-write-test.$$"
  if touch "$t" 2>/dev/null; then rm -f "$t"; log "目标目录可写: OK"; else die "目标目录不可写: $DEST"; fi
  log "===== 体检通过，可以开跑： ./$SCRIPT_NAME run ====="
}

# ============================== manifest =====================================
cmd_manifest() {
  ensure_dirs
  prepare_remote
  log "拉取云端全量清单（这一步只列目录，不下载任何文件）…"
  local fragdir="$STATE_DIR/lsjson"
  rm -rf "$fragdir"; mkdir -p "$fragdir"
  local fraglist="$STATE_DIR/fragments.list"
  local failed="$STATE_DIR/manifest-failed.txt"
  : > "$fraglist"; : > "$failed"

  local tops n=0 dir json rc ok_dirs=0
  tops="$(rclone_cmd lsf --dirs-only --format p "$REMOTE_NAME:" 2>/dev/null | sed 's:/$::' | sed '/^$/d' || true)"
  [[ -n "$tops" ]] || die "顶层目录列表为空：确认应用授权目录选的是「我的文件」根目录"
  while IFS= read -r dir; do
    [[ -n "$dir" ]] || continue
    n=$(( n + 1 ))
    json="$fragdir/dir-$(printf '%03d' "$n").json"
    rc=0
    rclone_run lsjson -R --files-only --no-mimetype --no-modtime \
        --retries 5 --low-level-retries 20 --log-level ERROR \
        "$REMOTE_NAME:$dir" > "$json" || rc=$?
    if [[ $rc -eq 0 ]]; then
      printf '%s\t%s\n' "$dir" "$json" >> "$fraglist"
      ok_dirs=$(( ok_dirs + 1 ))
      log "  已列 [$ok_dirs/$n]: $dir"
    else
      printf '%s\n' "$dir" >> "$failed"
      warn "列目录失败（已记录，重跑 manifest 会补）: $dir (rc=$rc)"
    fi
  done <<< "$tops"

  # 根目录散装文件（非递归）
  local rj="$fragdir/root.json" rrc=0
  rclone_run lsjson --files-only --no-mimetype --no-modtime --log-level ERROR \
      "$REMOTE_NAME:" > "$rj" || rrc=$?
  if [[ $rrc -eq 0 ]]; then
    printf '\t%s\n' "$rj" >> "$fraglist"
  else
    warn "根目录散装文件列取失败（rc=$rrc）"
  fi

  [[ -s "$fraglist" ]] || die "一条都没列成功，请检查认证与授权目录"
  local newtsv="$STATE_DIR/manifest.new.tsv" newmeta="$STATE_DIR/manifest.new.meta"
  local out
  out="$(py manifest_fragments "$fraglist" "$newtsv" "$newmeta")"
  log "本次列取结果: $out"

  # 缩水保护：旧清单在，且新清单更小 => 说明这次是被索引延迟截断的残缺清单，
  # 绝不能覆盖（否则 verify 会对着残缺清单报"三绿"，看似成功实则丢数据）。
  if [[ -f "$MANIFEST_META" ]]; then
    local cmp rc2=0
    cmp="$(py manifest_cmp "$MANIFEST_META" "$newmeta" "${ALLOW_SHRINK:-0}")" || rc2=$?
    printf '%s\n' "$cmp" | sed 's/^/    /'
    if (( rc2 != 0 )); then
      die "拒绝覆盖：新清单比现有清单小（文件数或字节数减少）。这通常是 123云盘 WebDAV 索引延迟造成的漏列——过几分钟重跑 manifest 即可；确实删过文件才用 ALLOW_SHRINK=1 强制覆盖。新清单已留在 $newtsv 供你核对，现有清单未被改动。"
    fi
  fi

  mv -f "$MANIFEST_TSV" "$STATE_DIR/manifest.prev.tsv" 2>/dev/null || true
  mv -f "$MANIFEST_META" "$STATE_DIR/manifest.prev.meta" 2>/dev/null || true
  mv -f "$newtsv" "$MANIFEST_TSV"
  mv -f "$newmeta" "$MANIFEST_META"
  log "清单: $out"
  awk -F'\t' '$2 !~ /\// {print $2}' "$MANIFEST_TSV" > "$ROOTFILES"
  log "根目录散装文件: $(wc -l < "$ROOTFILES") 个"
  log "清单已存: $MANIFEST_TSV"
  local need
  need="$(sed -n 's/^bytes=//p' "$MANIFEST_META")"
  log "云端清单总量: $(human "$need")  ← 可与 123云盘网页显示的「已用容量」交叉验证"
  if [[ -s "$failed" ]]; then
    warn "以下目录本次没列成功，清单不完整，请重跑 manifest："
    sed 's/^/    /' "$failed" >&2
  fi
}

# ============================== 条目顺序 =====================================
item_skipped() {
  local x="$1" k
  for k in "${SKIP_ITEMS[@]:-}"; do
    [[ -n "$k" && "$x" == "$k" ]] && return 0
  done
  return 1
}

ordered_items() {
  local all=() p x found
  mapfile -t all < <(py topitems "$MANIFEST_TSV" | cut -f1)
  local seen=()
  for p in "${PRIORITY_ITEMS[@]}"; do
    found=0
    for x in "${all[@]}"; do [[ "$x" == "$p" ]] && { found=1; break; }; done
    if (( found )); then
      item_skipped "$p" && continue
      printf '%s\n' "$p"; seen+=("$p")
    fi
  done
  # 优先级里没写到的（含未写进优先级的 __ROOT__），按清单给出的顺序补在后面
  for x in "${all[@]}"; do
    found=0
    for p in "${seen[@]}"; do [[ "$x" == "$p" ]] && { found=1; break; }; done
    (( found )) && continue
    item_skipped "$x" && continue
    printf '%s\n' "$x"; seen+=("$x")
  done
}

# ============================== 核对 =========================================
item_check() {  # 输出 machine-readable 一行 + 明细行
  local item="$1" detail="${2:-}"
  py item_check "$MANIFEST_TSV" "$item" "$DEST" "$detail"
}

parse_counts() {  # 从 item_check 输出里取字段： parse_counts "$out" missing
  local out="$1" key="$2"
  printf '%s\n' "$out" | head -1 | tr ' ' '\n' | sed -n "s/^${key}=//p" | head -1
}

item_is_clean() {
  local out; out="$(item_check "$1" 2>/dev/null || true)"
  local miss mism
  miss="$(parse_counts "$out" missing)"; mism="$(parse_counts "$out" mismatch)"
  [[ "${miss:-1}" == "0" && "${mism:-1}" == "0" ]]
}

# ============================== 下载一个条目 =================================
do_item_copy() {
  local item="$1" logf="$2"
  local common=(
    --transfers "$TRANSFERS" --checkers "$CHECKERS"
    --size-only
    --create-empty-src-dirs
    --retries 5 --retries-sleep 10s --low-level-retries 20
    --timeout 5m --contimeout 30s
    --stats 15s --stats-one-line-date --stats-log-level NOTICE
    --log-level INFO
    --log-file "$logf"
  )
  (( RCLONE_HAS_LOGSIZE )) && common+=(--log-file-max-size 64M)
  # 注意：这里不能用 --exclude 等过滤器，因为根目录条目用的是 --files-from，
  # rclone 明令 --files-from 不得与其他过滤器同时出现（否则直接 CRITICAL 退出）。
  # 状态目录本来就不在源目录树里，无需排除。
  # 交互式运行时打开 rclone 的实时进度条（日志文件里的统计行不受影响，仍是取证材料）。
  # 注意 --progress 必须配 --stats：后者已经把统计写进日志，这里只负责屏幕显示。
  if (( INTERACTIVE )) && (( ! QUIET )); then common+=(--progress); fi
  if [[ -n "$BW_LIMIT" ]]; then common+=(--bwlimit "$BW_LIMIT"); fi
  if (( DRY_RUN )); then common+=(--dry-run); fi

  if [[ "$item" == "$ROOT_ITEM" ]]; then
    rclone_run copy "${common[@]}" --files-from "$ROOTFILES" "$REMOTE_NAME:" "$DEST/"
  else
    rclone_run copy "${common[@]}" "$REMOTE_NAME:$item" "$DEST/$item"
  fi
}

snapshot_inflight() {  # 记录此刻正在下载/未完成的文件（含 .partial 临时文件及字节数）
  local item="${1:-}"
  [[ -n "$item" ]] || return 0
  local tmp="$INFLIGHT_SNAPSHOT.tmp"
  {
    printf 'snapshot_item=%s\n' "$item"
    printf 'snapshot_time=%s\n' "$(date '+%F %T')"
    item_check "$item" 2>/dev/null | awk -F'\t' '$1=="MISMATCH"||$1=="EXTRA"{print $1"\t"$2}' | \
    while IFS=$'\t' read -r tag path; do
      [[ -n "$path" ]] || continue
      printf '%s\t%s字节\t%s\n' "$tag" "$(stat -c %s "$DEST/$path" 2>/dev/null || echo '?')" "$path"
    done
  } > "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$INFLIGHT_SNAPSHOT" 2>/dev/null || true
}

write_checkpoint() {  # write_checkpoint <item> <原因> <rclone退出码>
  local item="$1" reason="$2" rc="${3:-}"
  local logf; logf="$LOG_DIR/$(safe_name "$item").log"
  local last_done="" last_stats="" partials="" mismatches="" stat_line
  if [[ -f "$logf" ]]; then
    last_done="$(grep -aE ': Copied \(new\)|: Copied \(replaced existing\)|: Copied \(newer\)' "$logf" 2>/dev/null | tail -1 | sed 's/^[0-9\/: ]*//' || true)"
    # 注意：--stats-one-line-date 输出的是「日期 已传字节, 百分比, 速率, ETA」单行格式，
    # 里面并没有 "Transferred:" 字样（曾因此导致本字段长期为空）。
    last_stats="$(grep -aE '[0-9.]+ [KMG]?i?B/s' "$logf" 2>/dev/null | tail -1 | sed 's/^[0-9\/: ]*//' || true)"
  fi
  local out detail="$STATE_DIR/last-check.json"
  out="$(item_check "$item" "$detail" 2>/dev/null || true)"
  partials="$(printf '%s\n' "$out" | awk -F'\t' '$1=="MISMATCH"{print $2}' | head -10)"
  mismatches="$(printf '%s\n' "$out" | awk -F'\t' '$1=="EXTRA"{print $2}' | head -10)"
  local p_done p_exp b_done b_exp
  p_done="$(parse_counts "$out" present_files)"; p_exp="$(parse_counts "$out" expected_files)"
  b_done="$(parse_counts "$out" ok_bytes)";      b_exp="$(parse_counts "$out" expected_bytes)"
  {
    printf '# 检查点  %s\n' "$(date '+%F %T')"
    printf 'resume_item=%s\n' "$item"
    printf 'reason=%s\n' "$reason"
    printf 'rclone_exit=%s\n' "${rc:-}"
    printf 'last_completed_file=%s\n' "$last_done"
    printf 'last_stats=%s\n' "$last_stats"
    printf 'progress=%s\n' "${p_done}/${p_exp} 文件, ${b_done}/${b_exp} 字节"
    printf 'in_flight_or_partial_files:\n'
    local snap_lines=""
    [[ -f "$INFLIGHT_SNAPSHOT" ]] && snap_lines="$(grep -v '^snapshot_' "$INFLIGHT_SNAPSHOT" 2>/dev/null || true)"
    if [[ -n "$snap_lines" ]]; then
      printf '  # 中断瞬间抓到的在途文件（rclone 退出时会删掉 .partial，这是唯一记录）\n'
      printf '%s\n' "$snap_lines" | sed 's/^/  /'
    fi
    if [[ -n "$partials" ]]; then printf '  %s\n' $partials; fi
    if [[ -z "$snap_lines" && -z "$partials" ]]; then printf '  (无)\n'; fi
    printf 'unexpected_local_files:\n'
    [[ -n "$mismatches" ]] && printf '  %s\n' $mismatches || printf '  (无)\n'
  } > "$CHECKPOINT"
}

print_checkpoint() {
  [[ -f "$CHECKPOINT" ]] || return 0
  log "---- 上次中断时的检查点（用于确认从哪里续）----"
  sed 's/^/    /' "$CHECKPOINT"
  log "------------------------------------------------"
}

process_item() {
  local item="$1"
  local sf; sf="$(state_file "$item")"
  local status; status="$(state_get "$sf" status)"
  local logf="$LOG_DIR/$(safe_name "$item").log"

  if [[ "$status" == "DONE" ]]; then
    if item_is_clean "$item"; then
      log "跳过（已完成且核对通过）: $item"
      return 0
    fi
    warn "状态是已完成，但本地核对不通过，安排补拉: $item"
  fi

  local attempt=0 rc=0 out miss mism
  while :; do
    attempt=$(( attempt + 1 ))
    if (( attempt > MAX_ATTEMPTS )); then
      state_set "$sf" "status=FAILED" "attempts=$attempt" "finished=$(date '+%F %T')"
      warn "放弃 $item（已尝试 $attempt 轮）。稍后重跑 ./$SCRIPT_NAME run 会继续尝试它。"
      return 1
    fi
    CURRENT_ITEM="$item"
    : > "$INFLIGHT_SNAPSHOT"
    state_set "$sf" "status=DOING" "attempts=$attempt" "started=$(date '+%F %T')" "item=$item"
    log "==== 开始第 $attempt 轮: $item ====（日志: $logf）"

    rc=0
    do_item_copy "$item" "$logf" || rc=$?
    CURRENT_ITEM=""

    out="$(item_check "$item" "$STATE_DIR/last-check.json" 2>/dev/null || true)"
    miss="$(parse_counts "$out" missing)";  miss="${miss:-?}"
    mism="$(parse_counts "$out" mismatch)"; mism="${mism:-?}"
    local f_exp f_ok b_exp b_ok
    f_exp="$(parse_counts "$out" expected_files)"
    f_ok="$(parse_counts "$out" present_files)"
    b_exp="$(parse_counts "$out" expected_bytes)"
    b_ok="$(parse_counts "$out" ok_bytes)"

    state_set "$sf" "files_expected=$f_exp" "files_ok=$f_ok" \
                   "bytes_expected=$b_exp" "bytes_ok=$b_ok" \
                   "missing=$miss" "mismatch=$mism" "last_rc=$rc" \
                   "checked=$(date '+%F %T')"

    write_checkpoint "$item" "rclone 退出码=$rc（第 $attempt 轮结束）" "$rc"

    if (( DRY_RUN )); then
      state_set "$sf" "status=DRYRUN" "checked=$(date '+%F %T')"
      log "[演练模式] $item 本轮未落盘。"
      return 0
    fi

    if [[ "$miss" == "0" && "$mism" == "0" ]]; then
      state_set "$sf" "status=DONE" "finished=$(date '+%F %T')"
      log "完成并核对通过: $item（$f_ok 文件 / $(human "$b_ok")）"
      return 0
    fi

    if (( INTERRUPTED )); then
      warn "已中断。$item 还差：缺失 $miss 个、大小不符 $mism 个（检查点已写：$CHECKPOINT）"
      return 130
    fi

    warn "$item 本轮结束但仍不完整：缺失 $miss、大小不符 $mism、rclone 退出码 $rc。${RETRY_SLEEP}s 后续传重试。"
    sleep "$RETRY_SLEEP"
  done
}

fmt_duration() {  # 秒 → 人类可读
  local t="${1:-0}"
  if (( t < 60 )); then printf '%d 秒' "$t"
  elif (( t < 3600 )); then printf '%d 分 %d 秒' $(( t / 60 )) $(( t % 60 ))
  else printf '%d 小时 %d 分' $(( t / 3600 )) $(( (t % 3600) / 60 )); fi
}

cmd_run() {
  RUN_START_TS="$(date +%s)"
  acquire_lock
  [[ -f "$MANIFEST_TSV" ]] || die "还没有清单。先跑： ./$SCRIPT_NAME manifest"
  prepare_remote
  print_checkpoint

  if (( ${#SKIP_ITEMS[@]} )); then
    log "按 SKIP_ITEMS 跳过: ${SKIP_ITEMS[*]}"
  fi
  local items=()
  mapfile -t items < <(ordered_items)
  log "共 ${#items[@]} 项待处理（按不可再生→可再下载的顺序）"

  local total="${#items[@]}" i=0 item
  for item in "${items[@]}"; do
    i=$(( i + 1 ))
    if (( INTERRUPTED )); then
      warn "中断标记已置位，停止调度（第 $i/$total 项：$item）"
      break
    fi
    log "---------- [$i/$total] $item ----------"
    process_item "$item" || true
    if (( INTERRUPTED )); then
      write_checkpoint "$item" "用户中断（调度阶段）" "interrupted"
      break
    fi
  done

  cmd_status
  local end_ts elapsed
  end_ts="$(date +%s)"; elapsed=$(( end_ts - (RUN_START_TS || 0) ))
  if (( INTERRUPTED )); then
    warn "运行被中断（已用时 $(fmt_duration "$elapsed")）。重新运行 $PROG run 即从断点继续，不会重下已完成的文件。"
    echo "   检查点：$CHECKPOINT" >&2
    exit 130
  fi
  log "全部条目已处理完（用时 $(fmt_duration "$elapsed")），开始全量对账…"
  cmd_verify || true
  echo
  ok "下一步："
  echo "   · 数据已落地：$DEST"
  echo "   · 随时复核（纯本地、不耗流量）：$PROG verify"
  echo "   · 建议把云端「第三方挂载」里这次用的应用删除，让这把钥匙失效"
}

# ============================== status / verify ==============================
status_row() {  # status_row <item> <附注>
  local item="$1" note="${2:-}" sf status ok miss mism
  sf="$(state_file "$item")"
  status="$(state_get "$sf" status)"; status="${status:-未开始}"
  if (( STATUS_DEEP )); then
    local out; out="$(item_check "$item" 2>/dev/null || true)"
    ok="$(parse_counts "$out" present_files)"; miss="$(parse_counts "$out" missing)"; mism="$(parse_counts "$out" mismatch)"
  else
    ok="$(state_get "$sf" files_ok)"; miss="$(state_get "$sf" missing)"; mism="$(state_get "$sf" mismatch)"
    ok="${ok:--}"; miss="${miss:--}"; mism="${mism:--}"
  fi
  printf '%s %s %10s %10s %8s %8s  %s\n' \
    "$(pad "$item" 40)" "$(pad "$status" 8)" "${IC[$item]:-?}" "$ok" "$miss" "$mism" "$note"
}

cmd_status() {
  ensure_dirs
  write_helper
  [[ -f "$MANIFEST_META" ]] || { warn "还没有清单，先跑 manifest"; return 1; }
  STATUS_DEEP=0
  [[ "${1:-}" == "deep" ]] && STATUS_DEEP=1
  local exp_files exp_bytes
  exp_files="$(sed -n 's/^files=//p' "$MANIFEST_META")"
  exp_bytes="$(sed -n 's/^bytes=//p' "$MANIFEST_META")"

  if [[ -f "$STATE_DIR/pid" ]]; then
    local rpid; rpid="$(cat "$STATE_DIR/pid" 2>/dev/null || true)"
    if [[ -n "$rpid" ]] && kill -0 "$rpid" 2>/dev/null; then
      printf '运行中: pid=%s\n' "$rpid"
    fi
  fi

  declare -gA IC=() IB=()
  local k b c
  while IFS=$'\t' read -r k b c; do IB["$k"]="$b"; IC["$k"]="$c"; done < <(py topitems "$MANIFEST_TSV")

  local order=() item
  mapfile -t order < <(ordered_items)

  printf '（按实际下载顺序排列）\n'
  printf '%s %s %10s %10s %8s %8s  %s\n' "$(pad '顶层条目' 40)" "$(pad '状态' 8)" "期望文件" "已就绪" "缺失" "大小不符" "备注"
  for item in "${order[@]}"; do status_row "$item" ""; done
  # 被 SKIP_ITEMS 跳过的排在最后标注出来
  for k in "${!IB[@]}"; do
    local hit=0 x
    for x in "${order[@]}"; do [[ "$x" == "$k" ]] && { hit=1; break; }; done
    (( hit )) || status_row "$k" "已跳过(SKIP_ITEMS)"
  done

  printf '\n云端清单: %s 个文件 / %s\n' "$exp_files" "$(human "$exp_bytes")"
  local avail
  avail="$(df -B1 --output=avail "$DEST" | tail -1 | tr -d ' ')"
  printf '目标盘剩余: %s\n' "$(human "$avail")"
  if [[ -f "$CHECKPOINT" ]]; then
    printf '最近检查点: %s\n' "$CHECKPOINT"
  fi
  return 0
}

cmd_verify() {
  ensure_dirs
  write_helper
  [[ -f "$MANIFEST_TSV" ]] || die "还没有清单。先跑： ./$SCRIPT_NAME manifest"
  log "全量对账中（比对 $DEST 与云端清单）…"
  local out rc=0
  out="$(py verify "$MANIFEST_TSV" "$DEST" "$VERIFY_REPORT")" || rc=$?
  printf '%s\n' "$out" | head -20
  local miss mism
  miss="$(parse_counts "$out" missing)"; mism="$(parse_counts "$out" mismatch)"
  if [[ "${miss:-1}" == "0" && "${mism:-1}" == "0" ]]; then
    log "★ 三绿达成：文件数一致、总字节一致、无缺失无大小不符。"
    log "  下一步请做抽样哈希：随机挑几个文件用 cksum/sha256sum 与云端对比（WebDAV 不提供全量哈希）。"
    log "  报告: $VERIFY_REPORT"
    return 0
  fi
  warn "未通过：缺失 ${miss:-?} 个、大小不符 ${mism:-?} 个。"
  warn "重跑 ./$SCRIPT_NAME run 会只补这些文件。报告: $VERIFY_REPORT"
  return 2
}

cmd_crosscheck() {
  ensure_dirs; write_helper
  local tree="${1:-}"
  [[ -n "$tree" && -f "$tree" ]] || die "用法: ./$SCRIPT_NAME crosscheck <目录树.txt>"
  [[ -f "$MANIFEST_TSV" ]] || die "先跑 manifest"
  py crosscheck "$MANIFEST_TSV" "$tree"
}

cmd_reset() {
  ensure_dirs
  warn "将清空断点状态（不动任何已下载文件）：$STATE_DIR"
  read -r -p "确认请输入 yes: " a
  [[ "$a" == "yes" ]] || die "已取消"
  rm -rf "$STATE_DIR"
  log "状态已清空。"
}

# ============================== 帮助与界面 ===================================
usage() {
  cat <<EOF
${C_B}${PROG} v${VERSION}${C_RST} — 123云盘 WebDAV 全量取回 / 备份工具

${C_B}用法${C_RST}
  ${PROG}                        交互式菜单（推荐第一次这样用）
  ${PROG} <子命令> [参数...]     直接执行某个动作

${C_B}子命令${C_RST}
  init        配置向导：服务器 / 账号 / 应用密码 / 目标目录
  menu        交互式菜单
  preflight   体检：连通性 / 认证 / 空间 / 权限（不下载任何文件）
  manifest    拉取云端全量清单（路径 + 大小），后续对账的底账
  run         下载（按顶层目录分批，可反复重跑续传）
  status      看进度；status deep 逐项核对本地（慢一点但准）
  verify      全量对账 + 生成报告（三绿才算成功）
  crosscheck  与「目录树 txt」交叉核对：${PROG} crosscheck 目录树.txt
  settings    交互式修改并发 / 跳过 / 优先级等
  reset       清空断点状态（不动任何已下载的文件）
  all         preflight + manifest + run（run 结尾自带 verify）
  version     显示版本   help 显示本帮助

${C_B}常用参数${C_RST}
  -d, --dest DIR        目标目录（默认 ~/123pan）
  -u, --url URL         WebDAV 地址（默认 https://webdav.123pan.cn/webdav）
  -a, --user 账号       123云盘登录账号（手机号）
  -p, --pass 密码       应用密码（会进 shell 历史，建议用 init）
  -t, --transfers N     并发传输数（默认 4）
  -c, --checkers N      并发列目录数（默认 8）
  -l, --bwlimit RATE    限速，如 10M（默认不限）
  -P, --priority A,B    先下载哪些顶层目录（逗号分隔，可用 ${ROOT_ITEM:-__ROOT__} 表示根目录散装文件）
  -s, --skip A,B        跳过哪些顶层目录
  -y, --yes             所有询问默认同意（无人值守）
  -n, --dry-run         演练模式：只列不落盘
  -q, --quiet           安静模式
      --no-color        关闭彩色输出
      --allow-shrink    允许新清单比旧清单小（确实删过云端文件时才用）

${C_B}配置优先级${C_RST}
  命令行参数 > 环境变量 > 配置文件（${CONFIG_FILE}） > 内置默认

${C_B}典型流程${C_RST}
  ${PROG} init          # 1. 用「第三方挂载 → 授权列表」里的应用密码配置一次
  ${PROG} manifest      # 2. 拉云端清单，与网页显示的已用容量对一下
  ${PROG} run           # 3. 挂机下载，随时 Ctrl-C，重跑即续
  ${PROG} verify        # 4. 对账：文件数 / 总字节 / 无缺失，三绿才算成功
EOF
}

banner() {
  printf '%s%s%s\n' "$C_CYN" "──────────────────────────────────────────────────────────────" "$C_RST"
  printf ' %s%s v%s%s  123云盘 WebDAV 全量取回\n' "$C_B" "$PROG" "$VERSION" "$C_RST"
  printf '%s%s%s\n' "$C_CYN" "──────────────────────────────────────────────────────────────" "$C_RST"
}

mask_user() {  # 手机号只显示首尾，避免截图泄露
  local u="${1:-}"
  if (( ${#u} >= 7 )); then printf '%s****%s' "${u:0:3}" "${u: -4}"; else printf '%s' "$u"; fi
}

# ============================== 配置向导 =====================================
prompt() {  # prompt <提示语> <默认值> → 打印用户输入（默认值回车即用）
  local msg="$1" def="${2:-}" ans=""
  if [[ -n "$def" ]]; then printf '%s [%s]: ' "$msg" "$def" >&2; else printf '%s: ' "$msg" >&2; fi
  IFS= read -r ans || true
  printf '%s' "${ans:-$def}"
}

cmd_init() {
  banner
  echo "配置向导（回车 = 保留方括号里的值）"
  echo

  local url user pass1 pass2 dest cur
  cur="$(config_get webdav_url "$DEFAULT_URL")"
  url="$(prompt 'WebDAV 服务器地址' "$cur")"

  cur="$(config_get webdav_user "${WEBDAV_USER:-}")"
  while :; do
    user="$(prompt '123云盘账号（登录手机号）' "$cur")"
    [[ -n "$user" ]] && break
    warn "账号不能为空"
  done

  echo "应用密码在网页「工具中心 → 第三方挂载 → 授权列表」里复制（不是登录密码）。" >&2
  while :; do
    printf '应用密码（不回显；回车=不改动）: ' >&2
    IFS= read -rs pass1 || true; echo >&2
    if [[ -z "$pass1" ]]; then
      have_pass_source && break
      warn "还没有密码，必须输入一次"; continue
    fi
    printf '再输一次确认: ' >&2
    IFS= read -rs pass2 || true; echo >&2
    [[ "$pass1" == "$pass2" ]] && break
    warn "两次输入不一致，请重来"
  done

  cur="$(config_get dest "$DEFAULT_DEST")"
  dest="$(prompt '下载到哪个目录' "$cur")"
  dest="${dest/#\~/$HOME}"

  config_set webdav_url "$url"
  config_set webdav_user "$user"
  if [[ -n "$pass1" ]]; then
    local ob
    ob="$("$RCLONE_BIN" obscure "$pass1")" || die "rclone obscure 失败"
    config_set webdav_pass_obscured "$ob"
  fi
  config_set dest "$dest"
  # 其余项若配置里还没有，就写一份默认，方便用户手改
  [[ -n "$(config_get transfers)" ]] || config_set transfers "$TRANSFERS"
  [[ -n "$(config_get checkers)" ]]  || config_set checkers "$CHECKERS"
  [[ -n "$(config_get retry_sleep)" ]] || config_set retry_sleep "$RETRY_SLEEP"
  [[ -n "$(config_get max_attempts)" ]] || config_set max_attempts "$MAX_ATTEMPTS"
  [[ -n "$(config_get priority)" ]] || config_set priority "${PRIORITY_STR:-}"
  [[ -n "$(config_get skip_items)" ]] || config_set skip_items "${SKIP_STR:-}"

  echo
  ok "已写入配置：$CONFIG_FILE（权限 600）"
  echo "   提示：应用密码是 rclone 混淆后保存的（只是防止被一眼看穿，并非加密），别外传本文件。"

  # 重新加载本次会话的配置，然后顺手体检一次
  WEBDAV_URL="$url"; WEBDAV_USER="$user"; DEST="$dest"; WEBDAV_PASS=""; WEBDAV_PASS_OBSCURED=""
  if [[ -n "$pass1" ]]; then WEBDAV_PASS="$pass1"; fi
  echo
  if ask_yes "现在就做一次体检（不下载文件）？"; then cmd_preflight; fi
}

ask_yes() {  # ask_yes <问题> → 0=是
  (( ASSUME_YES )) && return 0
  (( INTERACTIVE )) || return 0
  local a; printf '%s [Y/n]: ' "$1" >&2
  IFS= read -r a || true
  [[ -z "$a" || "$a" =~ ^[Yy]$ ]]
}

# ============================== 设置菜单 =====================================
cmd_settings() {
  banner
  while :; do
    echo "当前设置（改动立即写入配置文件）"
    printf '  1) 目标目录        %s\n' "$DEST"
    printf '  2) 并发传输数      %s\n' "$TRANSFERS"
    printf '  3) 并发列目录数    %s\n' "$CHECKERS"
    printf '  4) 限速            %s\n' "${BW_LIMIT:-（不限）}"
    printf '  5) 单目录重试      %s 次，间隔 %s 秒\n' "$MAX_ATTEMPTS" "$RETRY_SLEEP"
    printf '  6) 下载优先级      %s\n' "${PRIORITY_STR:-（未设置，按云端返回顺序）}"
    printf '  7) 跳过目录        %s\n' "${SKIP_STR:-（无）}"
    printf '  8) 重新配置账号/密码\n'
    printf '  0) 返回\n'
    local c; c="$(prompt '选择' '0')"
    case "$c" in
      1) DEST="$(prompt '目标目录' "$DEST")"; DEST="${DEST/#\~/$HOME}"; config_set dest "$DEST" ;;
      2) TRANSFERS="$(prompt '并发传输数（1-16，WebDAV 建议 4）' "$TRANSFERS")"; config_set transfers "$TRANSFERS" ;;
      3) CHECKERS="$(prompt '并发列目录数（建议 8）' "$CHECKERS")"; config_set checkers "$CHECKERS" ;;
      4) BW_LIMIT="$(prompt '限速（如 10M，留空=不限）' "$BW_LIMIT")"; config_set bw_limit "$BW_LIMIT" ;;
      5) MAX_ATTEMPTS="$(prompt '每个目录最多重试次数' "$MAX_ATTEMPTS")"
         RETRY_SLEEP="$(prompt '每轮之间的等待秒数' "$RETRY_SLEEP")"
         config_set max_attempts "$MAX_ATTEMPTS"; config_set retry_sleep "$RETRY_SLEEP" ;;
      6) echo "按「不可再生 → 可再下载」的顺序填写顶层目录名，逗号分隔。" >&2
         echo "用 ${ROOT_ITEM} 表示根目录下的散装文件。例：照片,文档,手机备份,${ROOT_ITEM}" >&2
         PRIORITY_STR="$(prompt '下载优先级' "$PRIORITY_STR")"; config_set priority "$PRIORITY_STR"
         mapfile -t PRIORITY_ITEMS < <(split_list "$PRIORITY_STR") ;;
      7) SKIP_STR="$(prompt '要跳过的顶层目录（逗号分隔）' "$SKIP_STR")"; config_set skip_items "$SKIP_STR"
         mapfile -t SKIP_ITEMS < <(split_list "$SKIP_STR") ;;
      8) cmd_init ;;
      0|"") return 0 ;;
      *) warn "无效选择" ;;
    esac
    echo
  done
}

# ============================== 交互式菜单 ===================================
menu_status_line() {
  local exp_files exp_bytes done_items total_items
  if [[ -f "$MANIFEST_META" ]]; then
    exp_files="$(sed -n 's/^files=//p' "$MANIFEST_META")"
    exp_bytes="$(sed -n 's/^bytes=//p' "$MANIFEST_META")"
    printf ' 云端清单 : %s 个文件 / %s\n' "$exp_files" "$(human "$exp_bytes")"
  else
    printf ' 云端清单 : %s尚未拉取（先做 manifest）%s\n' "$C_YEL" "$C_RST"
  fi
  if [[ -d "$ITEM_DIR" ]]; then
    total_items="$(ls -1 "$ITEM_DIR" 2>/dev/null | wc -l)"
    done_items="$(grep -l '^status=DONE' "$ITEM_DIR"/*.state 2>/dev/null | wc -l)"
    printf ' 下载进度 : 已完成 %s/%s 个顶层目录\n' "$done_items" "$total_items"
  fi
  if [[ -f "$CHECKPOINT" ]]; then
    local ri; ri="$(sed -n 's/^resume_item=//p' "$CHECKPOINT")"
    [[ -n "$ri" ]] && printf ' 断点记录 : 上次停在「%s」（重跑 run 即从此继续）\n' "$ri"
  fi
}

cmd_menu() {
  while :; do
    clear 2>/dev/null || true
    banner
    printf ' 目标目录 : %s\n' "$DEST"
    printf ' 账号     : %s @ %s\n' "$(mask_user "$WEBDAV_USER")" "${WEBDAV_URL#https://}"
    menu_status_line
    printf '%s%s%s\n' "$C_CYN" "──────────────────────────────────────────────────────────────" "$C_RST"
    cat <<EOF
 ${C_B}1${C_RST}) 配置 / 修改配置        ${C_DIM}init${C_RST}
 ${C_B}2${C_RST}) 体检（不下载文件）    ${C_DIM}preflight${C_RST}
 ${C_B}3${C_RST}) 拉取云端清单          ${C_DIM}manifest${C_RST}
 ${C_B}4${C_RST}) 开始 / 继续下载       ${C_DIM}run${C_RST}
 ${C_B}5${C_RST}) 查看进度              ${C_DIM}status${C_RST}
 ${C_B}6${C_RST}) 完整性对账            ${C_DIM}verify${C_RST}
 ${C_B}7${C_RST}) 与目录树交叉核对      ${C_DIM}crosscheck${C_RST}
 ${C_B}8${C_RST}) 高级设置              ${C_DIM}settings${C_RST}
 ${C_B}9${C_RST}) 清空断点状态          ${C_DIM}reset${C_RST}
 ${C_B}0${C_RST}) 退出
EOF
    printf '%s%s%s\n' "$C_CYN" "──────────────────────────────────────────────────────────────" "$C_RST"
    local c; printf '选择 [0-9]: ' >&2
    IFS= read -r c || break
    case "$c" in
      1) cmd_init ;;
      2) ensure_config; cmd_preflight ;;
      3) ensure_config; cmd_manifest ;;
      4) ensure_config; cmd_run || true ;;
      5) cmd_status "${1:-}" ;;
      6) cmd_verify || true ;;
      7) local tf; tf="$(prompt '目录树 txt 的路径' '')"; [[ -n "$tf" ]] && cmd_crosscheck "$tf" ;;
      8) cmd_settings ;;
      9) cmd_reset ;;
      0|q|"") break ;;
      *) warn "无效选择" ;;
    esac
    echo
    printf '按回车返回菜单…' >&2; IFS= read -r _ || true
  done
  return 0
}

# ============================== 参数解析 =====================================
parse_args() {
  while (( $# )); do
    case "$1" in
      -h|--help) usage; exit 0 ;;
      -V|--version) printf '%s %s\n' "$PROG" "$VERSION"; exit 0 ;;
      -d|--dest)     DEST="${2:?--dest 需要参数}"; shift 2 ;;
      --dest=*)      DEST="${1#*=}"; shift ;;
      -u|--url)      WEBDAV_URL="${2:?--url 需要参数}"; shift 2 ;;
      --url=*)       WEBDAV_URL="${1#*=}"; shift ;;
      -a|--user)     WEBDAV_USER="${2:?--user 需要参数}"; shift 2 ;;
      --user=*)      WEBDAV_USER="${1#*=}"; shift ;;
      -p|--pass)     WEBDAV_PASS="${2:?--pass 需要参数}"; shift 2 ;;
      --pass=*)      WEBDAV_PASS="${1#*=}"; shift ;;
      -t|--transfers) TRANSFERS="${2:?}"; shift 2 ;;
      -c|--checkers)  CHECKERS="${2:?}"; shift 2 ;;
      -l|--bwlimit)   BW_LIMIT="${2:?}"; shift 2 ;;
      -P|--priority)  PRIORITY_STR="${2:?}"; shift 2 ;;
      -s|--skip)      SKIP_STR="${2:?}"; shift 2 ;;
      -y|--yes)       ASSUME_YES=1; shift ;;
      -n|--dry-run)   DRY_RUN=1; shift ;;
      -q|--quiet)     QUIET=1; shift ;;
      --no-color)     C_RST=""; C_B=""; C_DIM=""; C_RED=""; C_GRN=""; C_YEL=""; C_CYN=""; shift ;;
      --menu)         FORCE_MENU=1; shift ;;
      --allow-shrink) ALLOW_SHRINK=1; shift ;;
      --)             shift; break ;;
      -*)             die "未知参数：$1（用 --help 看用法）" ;;
      *)              break ;;
    esac
  done
  DEST="${DEST/#\~/$HOME}"
  mapfile -t PRIORITY_ITEMS < <(split_list "$PRIORITY_STR")
  mapfile -t SKIP_ITEMS     < <(split_list "$SKIP_STR")
  REMAINING=("$@")
}

main() {
  parse_args "$@"
  local cmd="${REMAINING[0]:-}"
  local sub="${REMAINING[1]:-}"
  case "$cmd" in
    "")          if (( INTERACTIVE )) || (( FORCE_MENU )); then cmd_menu; else usage; fi ;;
    menu)        cmd_menu ;;
    init)        cmd_init ;;
    preflight|check) ensure_config; cmd_preflight ;;
    manifest|list)   ensure_config; cmd_manifest ;;
    run|download)    ensure_config; cmd_run ;;
    status|st)       cmd_status "$sub" ;;
    verify)          cmd_verify ;;
    crosscheck|tree) cmd_crosscheck "$sub" ;;
    settings|config) cmd_settings ;;
    reset)           cmd_reset ;;
    setpass)         cmd_setpass ;;          # 1.x 兼容别名
    all)             ensure_config; cmd_preflight; cmd_manifest; cmd_run ;;
    version)         printf '%s %s\n' "$PROG" "$VERSION" ;;
    help|-h|--help)  usage ;;
    *) die "未知命令：$cmd（用 --help 看用法）" ;;
  esac
}

main "$@"
