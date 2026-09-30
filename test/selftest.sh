#!/usr/bin/env bash
# =============================================================================
#  from123_selftest.sh —— 对本地假 WebDAV 服务器完整验证 from123.sh
#  不接触真实 123云盘，不需要密码，可以随便反复跑。
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"          # test/
ROOT_DIR="$(cd "$HERE/.." && pwd)"             # 仓库根
MAIN="${MAIN:-$ROOT_DIR/123pan-rescue.sh}"
FAKE_ROOT="${FAKE_ROOT:-$ROOT_DIR/.selftest/cloud/我的文件}"
PORT="${PORT:-18089}"
TUSER="tuser"; TPASS="tpass"
BASE="${BASE:-$ROOT_DIR/.selftest/run}"
TREE_TXT="$ROOT_DIR/.selftest/tree.txt"        # 由 make-testdata.sh 生成，用于 crosscheck
DEST="$BASE/dest"

PASS=0; FAIL=0; FAILED_NAMES=()
ok()   { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); FAILED_NAMES+=("$1"); printf '  \033[31mFAIL\033[0m  %s   %s\n' "$1" "${2:-}"; }
warn() { printf '  \033[33mNOTE\033[0m  %s\n' "$1"; }
head2(){ printf '\n\033[1m== %s ==\033[0m\n' "$1"; }

run_main() {  # 用测试环境跑主脚本
  env WEBDAV_URL="http://127.0.0.1:$PORT" WEBDAV_USER="$TUSER" WEBDAV_PASS="$TPASS" \
      DEST="$DEST" BW_LIMIT="${BW_LIMIT:-}" "$MAIN" "$@"
}

cleanup() {
  [[ -n "${SRV_PID:-}" ]] && kill "$SRV_PID" 2>/dev/null
  wait 2>/dev/null
}
trap cleanup EXIT

# ---------------------------------------------------------------- 环境准备
head2 "准备仿真云盘与 WebDAV 服务"
if [[ ! -d "$FAKE_ROOT" ]]; then
  echo "仿真树不存在: $FAKE_ROOT"
  echo "请先运行: $HERE/make-testdata.sh"
  exit 1
fi
EXPECT_FILES=$(find "$FAKE_ROOT" -type f | wc -l)
EXPECT_BYTES=$(find "$FAKE_ROOT" -type f -printf '%s\n' | awk '{s+=$1} END{print s}')
echo "仿真云端: $EXPECT_FILES 文件 / $EXPECT_BYTES 字节"
rm -rf "$BASE"; mkdir -p "$BASE"

# 关掉服务端目录缓存（默认 5 分钟），否则测试里改动目录后清单看不到变化
rclone serve webdav --addr "127.0.0.1:$PORT" --user "$TUSER" --pass "$TPASS" \
  --dir-cache-time 1s --poll-interval 0 "$FAKE_ROOT" \
  > "$BASE/server.log" 2>&1 &
SRV_PID=$!
for i in $(seq 1 40); do
  curl -sS -o /dev/null --max-time 2 "http://127.0.0.1:$PORT" 2>/dev/null && break
  sleep 0.5
done
if curl -sS -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:$PORT" 2>/dev/null | grep -qE '401|200|403'; then
  ok "本地 WebDAV 服务已就绪 (pid=$SRV_PID, port=$PORT)"
else
  bad "本地 WebDAV 服务未就绪"; cat "$BASE/server.log"; exit 1
fi

# ---------------------------------------------------------------- T1 语法
head2 "T1 语法与静态检查"
if bash -n "$MAIN"; then ok "bash -n 语法检查通过"; else bad "bash -n 语法检查失败"; fi
if grep -qE 'rclone_run (sync|delete|purge)|rclone_cmd (sync|delete|purge)' "$MAIN"; then
  bad "脚本里出现了 sync/delete 调用（危险）"
else
  ok "脚本只使用 copy/copyto/lsjson/lsd/about，无 sync/delete"
fi

# ---------------------------------------------------------------- T2 体检正常
head2 "T2 preflight 正常路径"
if run_main preflight > "$BASE/t2.out" 2>&1; then
  ok "preflight 通过"
  grep -q '认证成功' "$BASE/t2.out" && ok "认证成功并自动选定 vendor" || bad "未报告认证成功"
  grep -qE '空间检查|还没有清单' "$BASE/t2.out" && ok "空间检查已执行" || bad "空间检查缺失"
else
  bad "preflight 失败" "$(tail -3 "$BASE/t2.out")"
fi

# ---------------------------------------------------------------- T3 密码错误
head2 "T3 preflight 密码错误（应明确报错并以非 0 退出）"
if env WEBDAV_URL="http://127.0.0.1:$PORT" WEBDAV_USER="$TUSER" WEBDAV_PASS="WRONG-PASS" \
      DEST="$DEST" "$MAIN" preflight > "$BASE/t3.out" 2>&1; then
  bad "密码错误却成功了"
else
  grep -qE 'WebDAV 认证失败|认证/列目录失败' "$BASE/t3.out" && ok "密码错误被正确识别并给出指引" || bad "报错信息不明确" "$(tail -3 "$BASE/t3.out")"
fi

# ------------------------------------------------- T3b 回归：配置不被失败污染
head2 "T3b 回归：认证失败后不得污染正式配置"
if run_main manifest > "$BASE/t3b.out" 2>&1; then
  MF2=$(sed -n 's/.*FILES=\([0-9]*\).*/\1/p' "$BASE/t3b.out" | head -1)
  [[ "$MF2" == "$EXPECT_FILES" ]] && ok "认证失败后 manifest 依然可用且数量正确 ($MF2)" \
    || bad "清单数量不对: 期望 $EXPECT_FILES 得 $MF2"
else
  bad "认证失败后 manifest 崩了（正式配置被污染的回归）" "$(tail -3 "$BASE/t3b.out")"
fi

# ---------------------------------------------------------------- T4 主机不可达
head2 "T4 preflight 主机不可达"
if env WEBDAV_URL="http://127.0.0.1:9/webdav" WEBDAV_USER="$TUSER" WEBDAV_PASS="$TPASS" \
      DEST="$DEST" "$MAIN" preflight > "$BASE/t4.out" 2>&1; then
  bad "不可达却成功了"
else
  ok "不可达被正确拦截"
fi

# ---------------------------------------------------------------- T5 清单
head2 "T5 manifest 清单构建"
if run_main manifest > "$BASE/t5.out" 2>&1; then
  MF=$(sed -n 's/.*FILES=\([0-9]*\).*/\1/p' "$BASE/t5.out" | head -1)
  MB=$(sed -n 's/.*BYTES=\([0-9]*\).*/\1/p' "$BASE/t5.out" | head -1)
  [[ "$MF" == "$EXPECT_FILES" ]] && ok "清单文件数正确 ($MF)" || bad "清单文件数不符: 期望 $EXPECT_FILES 得 $MF"
  [[ "$MB" == "$EXPECT_BYTES" ]] && ok "清单总字节正确 ($MB)" || bad "清单总字节不符: 期望 $EXPECT_BYTES 得 $MB"
  EXP_ROOT=$(find "$FAKE_ROOT" -maxdepth 1 -type f | wc -l)
  GOT_ROOT=$(awk -F'\t' '$2 !~ /\//' "$DEST/.from123-state/manifest.tsv" 2>/dev/null | wc -l)
  [[ "$EXP_ROOT" == "$GOT_ROOT" ]] && ok "根目录散装文件已进清单 ($GOT_ROOT 个)" \
    || bad "根目录散装文件数不符: 期望 $EXP_ROOT 得 $GOT_ROOT"
else
  bad "manifest 失败" "$(tail -3 "$BASE/t5.out")"
fi

# ------------------------------------------------- T16 清单缩水保护（回归）
head2 "T16 清单缩水保护：漏列时不得覆盖旧清单"
DEST4="$BASE/dest-guard"; rm -rf "$DEST4"
D4="env WEBDAV_URL=http://127.0.0.1:$PORT WEBDAV_USER=$TUSER WEBDAV_PASS=$TPASS DEST=$DEST4"
bash -c "$D4 $MAIN manifest" > "$BASE/t16prep.out" 2>&1 \
  && ok "保护测试准备：先建一份完整清单" || bad "保护测试准备失败" "$(tail -3 "$BASE/t16prep.out")"
# 把"上一份清单"抬到比实际更大，等价于这次列目录漏了一部分（不改动仿真树，完全确定）
python3 - "$DEST4/.from123-state/manifest.meta" <<'PYEOF'
import sys
p = sys.argv[1]
keep = [l for l in open(p) if not l.startswith(('files=', 'bytes='))]
open(p, 'w').writelines(keep + ['files=999999\n', 'bytes=999999999999\n'])
PYEOF
if bash -c "$D4 $MAIN manifest" > "$BASE/t16a.out" 2>&1; then
  bad "清单缩水却覆盖成功了（会导致 verify 假三绿）"
else
  grep -q '拒绝覆盖' "$BASE/t16a.out" && ok "缩水时拒绝覆盖旧清单" \
    || bad "缩水时失败原因不明确" "$(tail -3 "$BASE/t16a.out")"
fi
[[ "$(wc -l < "$DEST4/.from123-state/manifest.tsv")" == "$EXPECT_FILES" ]] \
  && ok "现有清单未被改动，仍是完整 $EXPECT_FILES 条" \
  || bad "现有清单被改动了（$(wc -l < "$DEST4/.from123-state/manifest.tsv") 条）"
[[ -f "$DEST4/.from123-state/manifest.new.tsv" ]] \
  && ok "被拒绝的新清单被保留下来供核对" || bad "被拒绝的新清单没有保留"
if bash -c "$D4 ALLOW_SHRINK=1 $MAIN manifest" > "$BASE/t16b.out" 2>&1; then
  ok "显式 ALLOW_SHRINK=1 时允许覆盖（确实删过文件的场景）"
else
  bad "ALLOW_SHRINK=1 时仍被拒绝" "$(tail -3 "$BASE/t16b.out")"
fi

# ---------------------------------------------------------------- T6 空间守卫
head2 "T6 空间不足守卫"
if env WEBDAV_URL="http://127.0.0.1:$PORT" WEBDAV_USER="$TUSER" WEBDAV_PASS="$TPASS" \
      DEST="$DEST" MIN_FREE_FACTOR=100000000 "$MAIN" preflight > "$BASE/t6.out" 2>&1; then
  bad "空间不足却放行了"
else
  grep -q '空间不足' "$BASE/t6.out" && ok "空间不足被拦截" || bad "未给出空间不足提示" "$(tail -3 "$BASE/t6.out")"
fi

# ---------------------------------------------------------------- T7 tmpfs 守卫
head2 "T7 目标盘在内存文件系统上应拒绝"
if env WEBDAV_URL="http://127.0.0.1:$PORT" WEBDAV_USER="$TUSER" WEBDAV_PASS="$TPASS" \
      DEST="/dev/shm/from123-should-fail" "$MAIN" preflight > "$BASE/t7.out" 2>&1; then
  bad "tmpfs 目标却放行了"
else
  grep -q '内存文件系统' "$BASE/t7.out" && ok "tmpfs 目标被拦截" || bad "未拦截 tmpfs" "$(tail -3 "$BASE/t7.out")"
fi

# ---------------------------------------------------------------- T8 中断
head2 "T8 下载中途强杀 → 检查点 + 断点"
# 只清掉已下载内容，保留状态目录（清单/vendor/配置），模拟真实的"关机重来"
find "$DEST" -mindepth 1 -maxdepth 1 -not -name '.from123-state' -exec rm -rf {} + 2>/dev/null
rm -f "$DEST/.from123-state/pid"      # 清掉上一轮遗留的 pid，避免误杀无关进程
# 关键：非交互 shell 用 & 启动的后台进程会继承 SIGINT=SIG_IGN，bash 无法 trap 被忽略的信号。
# 打开 job control（set -m）后，后台作业不再忽略 SIGINT，等价于你前台 Ctrl-C 的真实场景。
set -m
# 显式给出优先级，让 200MB 大文件排在最后，中断点才确定（空优先级时按体积倒序，大文件会第一个跑）
env WEBDAV_URL="http://127.0.0.1:$PORT" WEBDAV_USER="$TUSER" WEBDAV_PASS="$TPASS" \
    DEST="$DEST" BW_LIMIT=3M RETRY_SLEEP=2 MAX_ATTEMPTS=3 \
    PRIORITY="照片,旧电脑备份,番剧合集！,临时中转,写作备份" \
    "$MAIN" run > "$BASE/t8.out" 2>&1 &
RUN_PID=$!
SPID=""
for i in $(seq 1 60); do
  SPID="$(cat "$DEST/.from123-state/pid" 2>/dev/null || true)"
  [[ -n "$SPID" ]] && kill -0 "$SPID" 2>/dev/null && break
  sleep 0.5
done
[[ -n "$SPID" ]] && ok "主脚本写出自身 pid ($SPID)" || bad "没有 pid 文件"
# 等大文件所在目录出现（说明已进入该目录的传输），再打断
for i in $(seq 1 120); do
  if ls "$DEST"/代码备份/ >/dev/null 2>&1; then break; fi
  sleep 0.5
done
sleep 3
kill -INT "$SPID" 2>/dev/null
# 有界等待：最多 90 秒，超时则升级 TERM/KILL，避免自检台挂死
for i in $(seq 1 180); do
  kill -0 "$SPID" 2>/dev/null || break
  sleep 0.5
done
if kill -0 "$SPID" 2>/dev/null; then
  bad "SIGINT 后 90 秒仍在运行，升级 TERM"
  kill -TERM "$SPID" 2>/dev/null; sleep 5
  kill -KILL "$SPID" 2>/dev/null
fi
wait "$RUN_PID"; T8_RC=$?
set +m
[[ "$T8_RC" == "130" ]] && ok "中断后以 130 退出（可辨识）" || bad "中断退出码异常: $T8_RC"

CP="$DEST/.from123-state/checkpoint.txt"
if [[ -f "$CP" ]]; then
  ok "检查点文件已生成"
  for k in resume_item rclone_exit last_completed_file in_flight_or_partial_files progress; do
    grep -q "^$k" "$CP" && ok "检查点含字段 $k" || bad "检查点缺字段 $k"
  done
  # 中断必须真的发生在"正在下大文件"的时刻，检查点里要能看到那个文件
  if awk '/^in_flight_or_partial_files/{f=1;next} /^[a-z_]+[:=]/{f=0} f' "$CP" | grep -q '大文件-200MB.bin'; then
    ok "检查点准确记录了中断时正在下载的文件（大文件-200MB.bin）"
  else
    bad "检查点没有记录中断时正在下载的文件" "$(sed -n '/in_flight_or_partial/,+3p' "$CP" | tr '\n' ' ')"
  fi
  echo "    ---- 检查点内容 ----"; sed 's/^/    /' "$CP"
  # 必须有已完成的文件（说明不是一上来就死）
  DONE_NOW=$(find "$DEST" -type f -not -path "*/.from123-state/*" | wc -l)
  (( DONE_NOW > 0 )) && ok "中断时已落盘 $DONE_NOW 个文件（成果被保留）" || bad "中断时一个文件都没落盘"
else
  bad "检查点文件未生成"
fi

# ---------------------------------------------------------------- T9 续跑
head2 "T9 重跑续传 → 完整拉全"
if run_main run > "$BASE/t9.out" 2>&1; then
  ok "续跑执行完成"
else
  bad "续跑失败" "$(tail -5 "$BASE/t9.out")"
fi
grep -q '跳过（已完成且核对通过）' "$BASE/t9.out" && ok "已完成的目录被跳过（真正的断点续传）" || bad "没有跳过已完成目录，可能重复下载"

# ---------------------------------------------------------------- T10 对账
head2 "T10 verify 全量对账"
if run_main verify > "$BASE/t10.out" 2>&1; then
  grep -q '三绿达成' "$BASE/t10.out" && ok "三绿达成（文件数 + 总字节 + 无缺失）" || bad "未报告三绿"
else
  bad "verify 未通过" "$(tail -5 "$BASE/t10.out")"
fi

# ---------------------------------------------------------------- T11 内容保真
head2 "T11 内容逐字节保真（含中文/特殊字符/深层路径）"
python3 - "$FAKE_ROOT" "$DEST" <<'PY'
import sys, os, hashlib
src, dst = sys.argv[1], sys.argv[2]
SKIP = ".from123-state"
def walk(root):
    out = {}
    for dp, dn, fn in os.walk(root):
        dn[:] = [d for d in dn if d != SKIP]
        for f in fn:
            p = os.path.join(dp, f)
            if os.path.islink(p) or not os.path.isfile(p):
                continue
            rel = os.path.relpath(p, root)
            out[rel] = (os.path.getsize(p), hashlib.md5(open(p,'rb').read()).hexdigest())
    return out
a, b = walk(src), walk(dst)
missing = sorted(set(a) - set(b))
extra   = sorted(set(b) - set(a))
diff    = sorted(k for k in a if k in b and a[k] != b[k])
print(f"    src={len(a)} dst={len(b)} missing={len(missing)} extra={len(extra)} content_diff={len(diff)}")
for k in missing[:5]: print("    MISSING:", k)
for k in extra[:5]:   print("    EXTRA:", k)
for k in diff[:5]:    print("    DIFF:", k)
sys.exit(0 if not (missing or extra or diff) else 1)
PY
if [[ $? -eq 0 ]]; then ok "全部文件内容一致（md5 逐文件比对）"; else bad "内容比对存在差异"; fi

# 空目录保留
EMPTY_OK=1
for d in "照片/empty_album" "临时中转/空目录里面也有/更深一层"; do
  [[ -d "$DEST/$d" ]] || EMPTY_OK=0
done
(( EMPTY_OK )) && ok "空目录被保留" || bad "空目录丢失"

# ---------------------------------------------------------------- T12 幂等
head2 "T12 重复运行幂等（不重下、不删文件）"
BEFORE=$(find "$DEST" -type f -not -path "*/.from123-state/*" | wc -l)
S=$(date +%s)
run_main run > "$BASE/t12.out" 2>&1
E=$(date +%s)
AFTER=$(find "$DEST" -type f -not -path "*/.from123-state/*" | wc -l)
[[ "$BEFORE" == "$AFTER" ]] && ok "文件数不变（$AFTER），没有误删" || bad "文件数变化: $BEFORE -> $AFTER"
(( E - S < 30 )) && ok "第二次运行很快（$((E-S))s），说明全部走跳过路径" || bad "第二次运行耗时 $((E-S))s，疑似重复下载"
grep -c '跳过（已完成且核对通过）' "$BASE/t12.out" | grep -qv '^0$' && ok "逐项跳过生效" || bad "未逐项跳过"

# ---------------------------------------------------------------- T13 演练模式
head2 "T13 dry-run 演练模式不落盘"
DEST2="$BASE/dest-dry"
D13="env WEBDAV_URL=http://127.0.0.1:$PORT WEBDAV_USER=$TUSER WEBDAV_PASS=$TPASS DEST=$DEST2 DRY_RUN=1 BW_LIMIT=20M"
if bash -c "$D13 $MAIN preflight" > "$BASE/t13.out" 2>&1 \
   && bash -c "$D13 $MAIN manifest" >> "$BASE/t13.out" 2>&1 \
   && bash -c "$D13 $MAIN run" >> "$BASE/t13.out" 2>&1; then
  N=$(find "$DEST2" -type f -not -path "*/.from123-state/*" 2>/dev/null | wc -l)
  [[ "$N" == "0" ]] && ok "演练模式未下载任何文件（dry-run 生效）" || bad "演练模式却落了 $N 个文件"
else
  bad "演练模式执行失败" "$(tail -3 "$BASE/t13.out")"
fi

# ---------------------------------------------------------------- T14 并发锁
head2 "T14 并发保护（同一目标只允许一个实例）"
DEST3="$BASE/dest-lock"; rm -rf "$DEST3"
# 先准备好清单，确保失败原因只会是"锁"，而不是"还没有清单"
env WEBDAV_URL="http://127.0.0.1:$PORT" WEBDAV_USER="$TUSER" WEBDAV_PASS="$TPASS" \
    DEST="$DEST3" "$MAIN" manifest > "$BASE/t14prep.out" 2>&1 \
  || bad "锁测试准备阶段 manifest 失败"
# 自检台自己持有同一把 flock，模拟"已有一个实例在跑"，避免依赖时序
exec 8>"$DEST3/.from123-state/lock"
if flock -n 8; then
  if env WEBDAV_URL="http://127.0.0.1:$PORT" WEBDAV_USER="$TUSER" WEBDAV_PASS="$TPASS" \
        DEST="$DEST3" "$MAIN" run > "$BASE/t14b.out" 2>&1; then
    bad "第二个实例没有被拒绝"
  else
    grep -q '已有一个' "$BASE/t14b.out" && ok "第二个实例被锁拒绝（确定性验证）" \
      || bad "第二个实例失败原因不明确" "$(tail -3 "$BASE/t14b.out")"
  fi
  flock -u 8
else
  bad "自检台没能拿到锁（环境异常）"
fi
exec 8>&-
# 锁释放后必须能正常运行
if env WEBDAV_URL="http://127.0.0.1:$PORT" WEBDAV_USER="$TUSER" WEBDAV_PASS="$TPASS" \
      DEST="$DEST3" BW_LIMIT=20M MAX_ATTEMPTS=1 "$MAIN" run > "$BASE/t14c.out" 2>&1; then
  ok "锁释放后可以正常开跑"
else
  bad "锁释放后仍无法运行" "$(tail -3 "$BASE/t14c.out")"
fi

# ---------------------------------------------------------------- T15 状态/交叉核对
head2 "T15 status 与 crosscheck"
run_main status > "$BASE/t15.out" 2>&1 && ok "status 正常输出" || bad "status 失败"
grep -q '云端清单' "$BASE/t15.out" && ok "status 显示清单总量" || bad "status 缺清单信息"
if [[ -f "$TREE_TXT" ]]; then
  if run_main crosscheck "$TREE_TXT" > "$BASE/t15b.out" 2>&1; then
    ok "crosscheck 可运行（对目录树 txt）"
    grep -q 'TREE_ONLY' "$BASE/t15b.out" && ok "crosscheck 能报出「仅目录树有」的差异" \
      || bad "crosscheck 未报出预期差异"
  else
    bad "crosscheck 失败" "$(tail -3 "$BASE/t15b.out")"
  fi
  sed 's/^/    /' "$BASE/t15b.out" | head -5
else
  bad "缺少 $TREE_TXT（先跑 make-testdata.sh）"
fi
# 目录树缺失时不应崩
if run_main crosscheck >/dev/null 2>&1; then bad "缺少参数时 crosscheck 竟成功了"; else ok "crosscheck 缺参数时正确报错"; fi

# ---------------------------------------------------------------- 汇总
head2 "汇总"
printf '  PASS=%d  FAIL=%d\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then printf '  失败项: %s\n' "${FAILED_NAMES[*]}"; exit 1; fi
echo "  全部通过 ✅"
