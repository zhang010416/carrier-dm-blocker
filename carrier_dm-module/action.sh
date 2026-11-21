#!/system/bin/sh
############################################################
# KernelSU「操作」按钮 -> 三家 DM 一键体检
############################################################
MODDIR=${0%/*}
MLOG="$MODDIR/log.txt"
UIDDIR="$MODDIR/uid"
XMOD=com.example.carrierdmblocker

PKG_UNICOM=com.mobiletools.systemhelper
PKG_CMCC=com.coloros.regservice
PKG_CT=com.oppo.ctautoregist
PKGS="$PKG_UNICOM $PKG_CMCC $PKG_CT"

name_of() {
  case "$1" in
    $PKG_UNICOM) echo "联通 SystemHelper" ;;
    $PKG_CMCC)   echo "移动 RegService" ;;
    $PKG_CT)     echo "电信 CTAutoRegist" ;;
    *)           echo "$1" ;;
  esac
}

uid_of() {
  if [ -f "$UIDDIR/$1.uids" ]; then
    cat "$UIDDIR/$1.uids" 2>/dev/null
  else
    cat "$UIDDIR/$1.uid" 2>/dev/null
  fi
}
line() { echo "────────────────────────────────────"; }

echo "╔══════════════════════════════════════╗"
echo "║  运营商 DM 拦截体检（联通/移动/电信） ║"
echo "╚══════════════════════════════════════╝"
echo "时间: $(date '+%Y-%m-%d %H:%M:%S')"

# ---------- 1. LSPosed 作用域 ----------
line
echo "[1] LSPosed 作用域（直读 modules_config.db）"
if [ -f "$MODDIR/dbfix.dex" ]; then
  OUT=$(CLASSPATH="$MODDIR/dbfix.dex" app_process /system/bin com.rgs.DbFix list 2>&1)
  echo "$OUT" | grep -E "^(exists|missing) " | sed 's/^/    /'
  case "$OUT" in
    *"missing "*)
      echo "    状态 : ⚠️ 有缺失，按下面这条补齐（然后在电脑上重启目标进程）"
      echo "           su -c \"CLASSPATH=$MODDIR/dbfix.dex app_process /system/bin com.rgs.DbFix\"" ;;
    *"ERROR"*)
      echo "    状态 : ❌ 读库失败: $(echo "$OUT" | grep ERROR | head -1)" ;;
    *) echo "    状态 : ✅ 完整（$XMOD → 3 个目标 + settings）" ;;
  esac
else
  echo "    dbfix.dex 缺失"
fi

# ---------- 2. 逐目标 ----------
for p in $PKGS; do
  line
  U=$(uid_of "$p")
  echo "[目标] $(name_of "$p")"
  echo "    包名 : $p"
  if [ -z "$U" ]; then
    echo "    uid  : 取不到（可能未安装）"
    continue
  fi
  echo "    uid  : $U"
  echo "    pid  : $(pidof "$p" 2>/dev/null || echo 未运行)"
  ST=$(dumpsys package "$p" 2>/dev/null | grep -o 'enabled=[0-9]*' | head -1 | cut -d= -f2)
  case "$ST" in
    3) echo "    状态 : 已停用（enabled=3）" ;;
    0) echo "    状态 : 启用（默认）" ;;
    1) echo "    状态 : 启用" ;;
    2) echo "    状态 : 系统禁用" ;;
    4) echo "    状态 : 停用（until-used）" ;;
    *) echo "    状态 : ${ST:-未知}" ;;
  esac

  # 规则 / 连接：逐个 uid（机主 + 分身）检查
  CONN_ALL=""
  for u in $U; do
    R4=0; R6=0
    iptables  -S OUTPUT 2>/dev/null | grep -q -- "--uid-owner $u" && R4=1
    ip6tables -S OUTPUT 2>/dev/null | grep -q -- "--uid-owner $u" && R6=1
    if [ "$R4" = "1" ]; then echo "    IPv4[$u] : OK"; else
      iptables -I OUTPUT -m owner --uid-owner "$u" -j REJECT 2>/dev/null && echo "    IPv4[$u] : 缺失 -> 已补上" || echo "    IPv4[$u] : 缺失 -> 补失败"
    fi
    if [ "$R6" = "1" ]; then echo "    IPv6[$u] : OK"; else
      ip6tables -I OUTPUT -m owner --uid-owner "$u" -j REJECT 2>/dev/null && echo "    IPv6[$u] : 缺失 -> 已补上" || echo "    IPv6[$u] : 缺失 -> 补失败"
    fi
    CONN_ALL="$CONN_ALL$(cat /proc/net/tcp /proc/net/tcp6 2>/dev/null | awk -v u="$u" '$8==u {print $2,$3,$4}')
"
  done
  CONN=$(echo "$CONN_ALL" | grep -v '^$')
  if [ -z "$CONN" ]; then echo "    连接 : 无外连"; else echo "    连接 : ⚠️ 仍有连接"; echo "$CONN" | sed 's/^/           /'; fi

  # Xposed 心跳
  S=/storage/emulated/0/Android/media/$p/SHBlocker/status.json
  if [ -f "$S" ]; then
    UP=$(grep -o '"updated_readable": *"[^"]*"' "$S" 2>/dev/null | sed 's/.*"\([^"]*\)"$/\1/')
    HK=$(grep -o '"hooks": *"[^"]*"' "$S" 2>/dev/null | sed 's/.*"\([^"]*\)"$/\1/')
    STATS=$(sed -n 's/.*"\([a-z_]*\)": *\([0-9][0-9]*\)[,}]*.*/\1=\2/p' "$S" 2>/dev/null | grep -vE "^(pid|updated)=" | tr '\n' ' ')
    echo "    Hook : ${HK:-?}"
    echo "    心跳 : ${UP:-?}"
    echo "    统计 : ${STATS:-无}"
  else
    echo "    Hook : status.json 不存在（目标没启动过 / 模块未启用）"
  fi

  C=/storage/emulated/0/Android/media/$p/SHBlocker/config.conf
  if [ -f "$C" ]; then
    echo "    开关 : $(grep -v '^#' "$C" | grep '=' | tr '\n' ' ')"
  fi
done

# ---------- 3. 模块日志 ----------
line
echo "[日志] 最近 5 条"
tail -5 "$MLOG" 2>/dev/null | grep -v "developer commands are only allowed" | sed 's/^/    /'

# ---------- 结论 ----------
line
echo "[结论]"
BAD=0
for p in $PKGS; do
  U=$(uid_of "$p")
  [ -z "$U" ] && continue
  for u in $U; do
    iptables -S OUTPUT 2>/dev/null | grep -q -- "--uid-owner $u" || BAD=1
    C6=$(cat /proc/net/tcp /proc/net/tcp6 2>/dev/null | awk -v u="$u" '$8==u' | wc -l)
    [ "$C6" -gt 0 ] && BAD=1
  done
done
if [ "$BAD" = "0" ]; then
  echo "    ✅ 三家规则在位，当前零外连"
else
  echo "    ❌ 有目标缺规则或仍有连接，请把上面输出发给维护者"
fi
echo "────────────────────────────────────"
