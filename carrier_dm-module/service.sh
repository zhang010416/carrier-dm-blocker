#!/system/bin/sh
############################################################
# 运营商 DM 出站阻断  v2.1（三家合集）
#   联通 com.mobiletools.systemhelper
#   移动 com.coloros.regservice        （PMS 层隐藏，界面查不到）
#   电信 com.oppo.ctautoregist
#
#   手段: iptables/ip6tables 按 uid + owner 匹配 -> REJECT
#         + 开机用 dbfix.dex 直接写 LSPosed 的 scope 表
############################################################

MODDIR=${0%/*}
LOG="$MODDIR/log.txt"
UIDDIR="$MODDIR/uid"
XMOD=com.example.carrierdmblocker

PKG_UNICOM=com.mobiletools.systemhelper
PKG_CMCC=com.coloros.regservice
PKG_CT=com.oppo.ctautoregist
PKGS="$PKG_UNICOM $PKG_CMCC $PKG_CT"

UID_MUL=100000
USER_DATA_ROOT=${USER_DATA_ROOT:-/data/user}
MAX_ROUNDS=20
RETRY_SEC=15

mkdir -p "$UIDDIR" 2>/dev/null

log() { echo "[$(date '+%F %T')] $*" >> "$LOG" 2>/dev/null; }
have() { command -v "$1" >/dev/null 2>&1; }

parse_pm() {
  sed -n 's/.*uid:\([0-9]\{1,\}\).*/\1/p' | head -1
}

normalize_appid() {
  n="$1"
  case "$n" in ''|*[!0-9]*) echo ""; return ;; esac
  if [ "$n" -ge "$UID_MUL" ]; then
    n=$((n % UID_MUL))
  fi
  if [ "$n" -lt 10000 ]; then n=""; fi
  echo "$n"
}

appid_of() {
  pkg="$1"
  a=""
  [ -z "$a" ] && a=$(dumpsys package "$pkg" 2>/dev/null | grep -m1 -o 'appId=[0-9]*' | cut -d= -f2)
  [ -z "$a" ] && [ -f /data/system/packages.list ] && \
    a=$(grep "^$pkg " /data/system/packages.list 2>/dev/null | awk '{print $2}')
  if [ -z "$a" ]; then
    raw=""
    have pm   && raw=$(pm list packages -U 2>/dev/null | grep -F "package:$pkg " | parse_pm)
    [ -z "$raw" ] && have cmd && raw=$(cmd package list packages -U 2>/dev/null | grep -F "package:$pkg " | parse_pm)
    a=$(normalize_appid "$raw")
  fi
  [ -z "$a" ] && a=$(stat -c %u "/data/user/0/$pkg" 2>/dev/null)
  [ -z "$a" ] && a=$(stat -c %u "/data/data/$pkg" 2>/dev/null)
  a=$(normalize_appid "$a")
  echo "$a"
}

installed() {
  pkg="$1"
  pm path "$pkg" 2>/dev/null | grep -q '^package:' && return 0
  dumpsys package "$pkg" 2>/dev/null | grep -q -m1 -E 'appId=[0-9]+|userId=[0-9]+|codePath=' && return 0
  [ -f /data/system/packages.list ] && grep -q "^$pkg " /data/system/packages.list 2>/dev/null && return 0
  return 1
}

uids_of() {
  pkg="$1"
  appid=$(appid_of "$pkg")
  [ -z "$appid" ] && return 0
  found=""
  found="$found $appid"
  for d in "$USER_DATA_ROOT"/[0-9]*; do
    [ -d "$d/$pkg" ] || continue
    owner=$(stat -c %u "$d/$pkg" 2>/dev/null)
    case "$owner" in ''|*[!0-9]*) continue ;; esac
    [ "$owner" -lt 10000 ] && continue
    found="$found $owner"
  done
  echo "$found" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' '
}

store_uids() {
  pkg="$1"
  uids=$(uids_of "$pkg")
  if [ -n "$uids" ]; then
    echo "$uids" > "$UIDDIR/$pkg.uids"
    echo "$uids" | awk '{print $1}' > "$UIDDIR/$pkg.uid"
  fi
  echo "$uids"
}

apply_rules() {
  uid="$1"
  if have iptables; then
    iptables -D OUTPUT -m owner --uid-owner "$uid" -j REJECT 2>/dev/null
    iptables -I OUTPUT -m owner --uid-owner "$uid" -j REJECT 2>/dev/null \
      || log "  iptables 添加失败 uid=$uid"
  fi
  if have ip6tables; then
    ip6tables -D OUTPUT -m owner --uid-owner "$uid" -j REJECT 2>/dev/null
    ip6tables -I OUTPUT -m owner --uid-owner "$uid" -j REJECT 2>/dev/null \
      || log "  ip6tables 添加失败 uid=$uid"
  fi
  return 0
}

rules_ok() {
  uid="$1"
  if have iptables && ! iptables -S OUTPUT 2>/dev/null | grep -q -- "--uid-owner $uid"; then
    return 1
  fi
  if have ip6tables && ! ip6tables -S OUTPUT 2>/dev/null | grep -q -- "--uid-owner $uid"; then
    return 1
  fi
  return 0
}

# ---------- 等开机完成 ----------
log "service: waiting for boot_completed"
i=0
while [ "$(getprop sys.boot_completed)" != "1" ] && [ $i -lt 120 ]; do
  sleep 5; i=$((i+1))
done
sleep 20

# ---------- LSPosed scope 自愈 ----------
heal_scope() {
  [ -f "$MODDIR/dbfix.dex" ] || { log "scope: 缺 dbfix.dex，跳过"; return; }
  dumpsys package "$XMOD" >/dev/null 2>&1 || { log "scope: Xposed 模块未安装，跳过"; return; }
  OUT=$(CLASSPATH="$MODDIR/dbfix.dex" app_process /system/bin com.rgs.DbFix 2>&1)
  case "$OUT" in
    *"ERROR"*) log "scope: 读库失败 $(echo "$OUT" | grep ERROR | head -1)" ;;
    *"added"*) log "scope: 已补写 $(echo "$OUT" | grep -c '^added') 条" ;;
    *)         log "scope: 已是完整状态" ;;
  esac
}
heal_scope

# ---------- 逐个目标探测 uid + 加规则 ----------
for p in $PKGS; do
  if ! installed "$p"; then
    log "skip $p（未安装）"
    : > "$UIDDIR/$p.uids"
    : > "$UIDDIR/$p.uid"
    continue
  fi
  n=0
  uids=""
  while [ $n -lt $MAX_ROUNDS ]; do
    uids=$(store_uids "$p")
    [ -n "$uids" ] && break
    n=$((n+1))
    [ $n -eq 1 ] && log "target $p 已安装但 appId 未就绪，等待探测（最多 ${MAX_ROUNDS} 轮）"
    sleep $RETRY_SEC
  done
  if [ -z "$uids" ]; then
    log "WARN $p 已安装但始终取不到 uid，放弃（可手动排查 dumpsys）"
    continue
  fi
  log "target $p uids=$uids"
  for u in $uids; do
    apply_rules "$u"
  done
done

# ---------- 共享配置目录 ----------
for p in $PKGS; do
  mkdir -p "/storage/emulated/0/Android/media/$p/SHBlocker" 2>/dev/null
done

# ---------- 60 秒自愈 ----------
while true; do
  sleep 60
  for p in $PKGS; do
    installed "$p" || continue
    uids=$(uids_of "$p")
    [ -z "$uids" ] && continue
    echo "$uids" > "$UIDDIR/$p.uids"
    for u in $uids; do
      if ! rules_ok "$u"; then
        log "rules missing -> re-apply $p（uid=$u）"
        apply_rules "$u"
      fi
    done
  done
done
