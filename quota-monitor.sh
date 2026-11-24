#!/usr/bin/env bash
# quota-monitor.sh -- sing-box 流量限制监控（vps-singbox-duo）
#
# 由安装脚本在设定限额（非 9999）时部署：
#   quota-monitor.sh            每 5 分钟由 cron 调用：累计用量，超限自动停服
#   quota-monitor.sh status     查看当月用量、限额与服务状态
#   quota-monitor.sh --reset    手动清零当月用量并恢复服务
#   quota-monitor.sh --restore  手动恢复服务（不清零；仍超限会在下次检查时再次停服）
#
# 统计方式：nftables 按端口双向计数（进方向 dport + 出方向 sport），
# 每次读取与上次的差值累加进状态文件，可正确处理计数器清零与机器重启。
# 限制：按节点端口总量统计，不按 UUID 区分用户；多用户共用一个端口时，
# 限额是全节点共用的。详见 README 的流量限制一节。
set -u

CONF="/etc/sing-box/quota.conf"
STATE_DIR="/var/lib/sing-box-quota"
STATE_FILE="$STATE_DIR/usage.json"
LOG_FILE="/var/log/sing-box-quota.log"
DISABLED_FLAG="$STATE_DIR/disabled"
SERVICE="sing-box"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

load_conf() {
  [[ -f "$CONF" ]] || return 1
  QUOTA_GB="$(awk -F= '/^QUOTA_GB=/{print $2}' "$CONF")"
  PORTS="$(awk -F= '/^PORTS=/{print $2}' "$CONF" | tr -d '"')"
  [[ "$QUOTA_GB" =~ ^[0-9]+$ ]] || return 1
  [[ -n "$PORTS" ]] || return 1
  return 0
}

service_active() {
  systemctl is-active --quiet "$SERVICE" 2>/dev/null
}

# 读取 nft 计数、更新状态文件，输出 STATUS / USED_BYTES / QUOTA_BYTES / MONTH
py_check() {
  QUOTA_PORTS="$PORTS" QUOTA_GB="$QUOTA_GB" STATE_FILE="$STATE_FILE" python3 - <<'PYEOF'
import json, os, subprocess, sys
from datetime import date

state_file = os.environ["STATE_FILE"]
ports = os.environ["QUOTA_PORTS"].split()
quota_gb = int(os.environ["QUOTA_GB"])
month = date.today().strftime("%Y-%m")

def fail(msg):
    print("STATUS=ERROR")
    print("MESSAGE=" + msg)
    sys.exit(0)

try:
    out = subprocess.run(["nft", "-j", "list", "table", "inet", "singbox_quota"],
                         capture_output=True, text=True, timeout=15)
except Exception as e:
    fail("nft 执行失败: %s" % e)
if out.returncode != 0:
    fail("nft 读取失败: " + (out.stderr or "").strip()[:200])

current = {}
try:
    data = json.loads(out.stdout)
except Exception as e:
    fail("nft 输出解析失败: %s" % e)
for obj in data.get("nftables", []):
    rule = obj.get("rule")
    if not rule:
        continue
    comment = rule.get("comment", "")
    if not comment.startswith("quota:"):
        continue
    key = comment[len("quota:"):]
    for expr in rule.get("expr", []):
        counter = expr.get("counter")
        if counter:
            current[key] = current.get(key, 0) + int(counter.get("bytes", 0))

try:
    with open(state_file, "r") as f:
        state = json.load(f)
except Exception:
    state = {"month": month, "used_bytes": 0, "last_counters": {}}

rolled = False
if state.get("month") != month:
    # 月份切换：清零用量，以当前计数器为新月起点；不把旧计数带入新月
    rolled = True
    state = {"month": month, "used_bytes": 0, "last_counters": dict(current)}
else:
    last = state.get("last_counters", {})
    used = int(state.get("used_bytes", 0))
    for key in ports:
        cur = current.get(key, 0)
        prev = int(last.get(key, 0))
        delta = cur - prev
        if delta < 0:
            delta = cur  # 计数器被清零（重启/规则重载），按当前值计入
        used += delta
        last[key] = cur
    state["used_bytes"] = used
    state["last_counters"] = last
    state["month"] = month

os.makedirs(os.path.dirname(state_file), exist_ok=True)
with open(state_file, "w") as f:
    json.dump(state, f)

quota_bytes = quota_gb * 1024 * 1024 * 1024
used = int(state.get("used_bytes", 0))
print("STATUS=" + ("RESET" if rolled else ("EXCEEDED" if used >= quota_bytes else "OK")))
print("USED_BYTES=%d" % used)
print("QUOTA_BYTES=%d" % quota_bytes)
print("MONTH=" + month)
PYEOF
}

# 打印当月用量（人类可读）
py_status() {
  QUOTA_GB="$QUOTA_GB" STATE_FILE="$STATE_FILE" python3 - <<'PYEOF'
import json, os
from datetime import date

state_file = os.environ["STATE_FILE"]
quota_gb = int(os.environ["QUOTA_GB"])
month = date.today().strftime("%Y-%m")
try:
    with open(state_file, "r") as f:
        state = json.load(f)
except Exception:
    state = {"month": month, "used_bytes": 0}
used = int(state.get("used_bytes", 0))
quota_bytes = quota_gb * 1024 * 1024 * 1024
gb = 1024 * 1024 * 1024
print("当月：%s" % month)
print("限额：%d GB" % quota_gb)
print("已用：%.2f GB（%d 字节）" % (used / gb, used))
print("剩余：%.2f GB" % max(0, (quota_bytes - used) / gb))
print("进度：%.1f%%" % (used / quota_bytes * 100 if quota_bytes else 0))
PYEOF
}

# 清零当月用量（状态文件重置为当前计数器起点）
py_reset() {
  QUOTA_PORTS="$PORTS" STATE_FILE="$STATE_FILE" python3 - <<'PYEOF'
import json, os, subprocess, sys
from datetime import date

state_file = os.environ["STATE_FILE"]
ports = os.environ["QUOTA_PORTS"].split()
month = date.today().strftime("%Y-%m")
current = {}
try:
    out = subprocess.run(["nft", "-j", "list", "table", "inet", "singbox_quota"],
                         capture_output=True, text=True, timeout=15)
    data = json.loads(out.stdout)
    for obj in data.get("nftables", []):
        rule = obj.get("rule")
        if not rule:
            continue
        comment = rule.get("comment", "")
        if not comment.startswith("quota:"):
            continue
        key = comment[len("quota:"):]
        for expr in rule.get("expr", []):
            counter = expr.get("counter")
            if counter:
                current[key] = current.get(key, 0) + int(counter.get("bytes", 0))
except Exception:
    pass
state = {"month": month, "used_bytes": 0, "last_counters": current}
os.makedirs(os.path.dirname(state_file), exist_ok=True)
with open(state_file, "w") as f:
    json.dump(state, f)
print("OK")
PYEOF
}

cmd="${1:-check}"

case "$cmd" in
  status)
    load_conf || { echo "未配置流量限制（$CONF 不存在或无效）。"; exit 0; }
    if [[ "$QUOTA_GB" -ge 9999 ]]; then
      echo "流量限制：不限（9999）。"
      exit 0
    fi
    py_status
    if service_active; then
      echo "服务状态：运行中"
    else
      echo "服务状态：已停止"
    fi
    if [[ -f "$DISABLED_FLAG" ]]; then
      echo "限额停用：是（超限自动停服，需手动恢复或等下月 1 号）"
    else
      echo "限额停用：否"
    fi
    ;;
  --reset)
    load_conf || { echo "未配置流量限制（$CONF 不存在或无效）。" >&2; exit 1; }
    py_reset >/dev/null
    rm -f "$DISABLED_FLAG"
    systemctl start "$SERVICE" 2>/dev/null || true
    log "手动清零当月用量，服务已恢复"
    echo "已清零当月用量，服务已恢复。"
    ;;
  --restore)
    rm -f "$DISABLED_FLAG"
    systemctl start "$SERVICE" 2>/dev/null || true
    log "手动恢复服务（用量不清零）"
    echo "服务已恢复（用量不清零；仍超限会在下次检查时再次停服）。"
    ;;
  check|"")
    load_conf || exit 0
    if [[ "$QUOTA_GB" -ge 9999 ]]; then
      exit 0
    fi
    out="$(py_check)"
    eval "$(printf '%s\n' "$out" | grep -E '^(STATUS|USED_BYTES|QUOTA_BYTES|MONTH)=')"
    case "${STATUS:-ERROR}" in
      ERROR)
        log "检查失败：$out"
        exit 1
        ;;
      RESET)
        if [[ -f "$DISABLED_FLAG" ]]; then
          rm -f "$DISABLED_FLAG"
          systemctl start "$SERVICE" 2>/dev/null || true
          log "月份已切换（$MONTH），用量已清零，服务已恢复"
        else
          log "月份已切换（$MONTH），用量已清零"
        fi
        ;;
      EXCEEDED)
        used_gb="$(awk -v b="$USED_BYTES" 'BEGIN {printf "%.2f", b/1024/1024/1024}')"
        quota_gb="$(awk -v b="$QUOTA_BYTES" 'BEGIN {printf "%.2f", b/1024/1024/1024}')"
        if [[ ! -f "$DISABLED_FLAG" ]]; then
          systemctl stop "$SERVICE" 2>/dev/null || true
          touch "$DISABLED_FLAG"
          log "当月用量 ${used_gb} GB 已达限额 ${quota_gb} GB，服务已自动停止"
        elif service_active; then
          systemctl stop "$SERVICE" 2>/dev/null || true
          log "当月用量仍超限（${used_gb}/${quota_gb} GB），服务被手动启动后再次停止"
        fi
        ;;
      OK)
        ;;
    esac
    ;;
  *)
    echo "用法：$0 [status|--reset|--restore]" >&2
    exit 1
    ;;
esac
