#!/bin/bash
# service.sh UID 探测逻辑的行为测试。
# 手法：把真实设备上采集的命令输出做成 mock 可执行文件，
#       只 source service.sh 里的纯函数定义（不执行开机主流程），
#       用 mock 覆盖 pm/dumpsys/stat，断言 appid_of / uids_of / installed 的输出。
set -u

SVC="$(cd "$(dirname "$0")/.." && pwd)/carrier_dm-module/service.sh"
MOCK="$(mktemp -d)"
trap 'rm -rf "$MOCK"' EXIT

fail=0
ok()   { echo "  ✅ $*"; }
bad()  { echo "  ❌ $*"; fail=1; }
assert_eq() {
  local desc="$1" expect="$2" got="$3"
  if [ "$expect" = "$got" ]; then ok "$desc (=$got)"; else bad "$desc: 期望[$expect] 实得[$got]"; fi
}

# ---- 造 mock 命令 ----
mkbin() { # name, content
  printf '%s\n' "$2" > "$MOCK/$1"; chmod +x "$MOCK/$1";
}

# 设备真实样本：
#  - regservice:  PMS 隐藏，pm -U 空，dumpsys appId=10210，仅 user0 目录
#  - ctautoregist:pm -U 给分身编码 1010107，dumpsys appId=10107，user0+user10 目录
#  - systemhelper:完全未安装
mkbin dumpsys 'case "$2" in
  com.coloros.regservice) echo "    appId=10210" ;;
  com.oppo.ctautoregist)  echo "    appId=10107" ;;
  *) exit 1 ;;
esac'
mkbin pm 'case "$*" in
  "path com.coloros.regservice") echo "package:/product/app/RegService/RegService.apk" ;;
  # 实测：电信包被禁用后 pm path 返回空（只靠 dumpsys 回退才能判为已安装）
  "path com.oppo.ctautoregist")  exit 1 ;;
  "list packages -U") printf "package:com.coloros.regservice uid:1010210\npackage:com.oppo.ctautoregist uid:1010107\n" ;;
  *) exit 1 ;;
esac'
mkbin cmd 'exit 1'
# 真实调用形如: stat -c %u <path>  ->  $1=-c  $2=%u  $3=path
mkbin stat 'case "$2" in
  %u)
    case "$3" in
      */0/com.coloros.regservice)    echo 10210 ;;
      */10/com.oppo.ctautoregist)    echo 1010107 ;;
      */0/com.oppo.ctautoregist)     echo 10107 ;;
      *) exit 1 ;;
    esac ;;
  *) exit 1 ;;
esac'

# 造用户数据目录
mkdir -p "$MOCK"/data/user/0/com.coloros.regservice
mkdir -p "$MOCK"/data/user/0/com.oppo.ctautoregist
mkdir -p "$MOCK"/data/user/10/com.oppo.ctautoregist

# ---- 从 service.sh 抽取纯函数定义（到第一个「---------- 等开机完成」之前）----
FUNCS="$MOCK/_funcs.sh"
awk '/^# ---------- 等开机完成/{exit} {print}' "$SVC" > "$FUNCS"

# 在受控环境里 source：PATH 指向 mock，重定向所有数据路径到 mock 根
export PATH="$MOCK:$PATH"
UIDDIR="$MOCK/uid"; export UIDDIR

echo "=== 测试 1: normalize_appid（多用户 UID 归一化）==="
source "$FUNCS"
assert_eq "分身编码 1010107 -> appId 10107" "10107" "$(normalize_appid 1010107)"
assert_eq "分身编码 1010210 -> appId 10210" "10210" "$(normalize_appid 1010210)"
assert_eq "机主 appId 10210 原样"          "10210" "$(normalize_appid 10210)"
assert_eq "非法值 -> 空"                    ""      "$(normalize_appid abc)"

echo "=== 测试 2: appid_of（穿透 PMS 隐藏）==="
unset -f appid_of uids_of installed store_uids 2>/dev/null
source "$FUNCS"
assert_eq "regservice 隐藏包仍取到 appId" "10210" "$(appid_of com.coloros.regservice)"
assert_eq "ctautoregist appId(非编码值)"  "10107" "$(appid_of com.oppo.ctautoregist)"
assert_eq "未装包 -> 空"                   ""      "$(appid_of com.mobiletools.systemhelper)"

echo "=== 测试 3: installed ==="
unset -f appid_of uids_of installed 2>/dev/null
source "$FUNCS"
installed com.coloros.regservice && ok "regservice 判定为已安装" || bad "regservice 误判为未安装"
installed com.oppo.ctautoregist  && ok "ctautoregist 判定为已安装" || bad "ctautoregist 误判为未安装"
installed com.mobiletools.systemhelper && bad "未装包误判为已安装" || ok "未装包正确判定为缺失"

echo "=== 测试 4: uids_of（机主 + 分身双覆盖，核心回归）==="
unset -f appid_of uids_of installed 2>/dev/null
# 通过脚本自带的 USER_DATA_ROOT 变量把用户目录指向 mock，无需篡改源码
USER_DATA_ROOT="$MOCK/data/user"; export USER_DATA_ROOT
source "$FUNCS"
GOT_CT=$(uids_of com.oppo.ctautoregist | tr ' ' '\n' | grep -v '^$' | sort -n | tr '\n' ' ' | sed 's/ $//')
assert_eq "ctautoregist 机主+分身双 UID" "10107 1010107" "$GOT_CT"
GOT_CMCC=$(uids_of com.coloros.regservice | tr ' ' '\n' | grep -v '^$' | sort -n | tr '\n' ' ' | sed 's/ $//')
assert_eq "regservice 仅机主 UID" "10210" "$GOT_CMCC"
GOT_NONE=$(uids_of com.mobiletools.systemhelper | tr -d ' \n')
assert_eq "未装包 -> 无 UID" "" "$GOT_NONE"

echo "=========================="
[ "$fail" -eq 0 ] && echo "ALL PASS ✅" || { echo "FAILED ❌"; exit 1; }
