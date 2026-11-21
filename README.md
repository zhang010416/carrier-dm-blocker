# Carrier DM Blocker

> 一次拦掉三家运营商预装的 **DM（Device Management）** 组件：不采集、不定位、不落库、不发短信、不出网。

[![Xposed API](https://img.shields.io/badge/libxposed-API%20102-brightgreen.svg)](https://github.com/libxposed/api)
[![KernelSU](https://img.shields.io/badge/KernelSU-module-blue.svg)](https://kernelsu.org/)
[![minSdk](https://img.shields.io/badge/minSdk-29-orange.svg)](#兼容性)
[![License](https://img.shields.io/badge/license-MIT-lightgrey.svg)](LICENSE)

---

## 背景

运营商定制机普遍预装了一套 DM 组件，把设备的 **IMEI / IMSI / ICCID / 基站信息 / 经纬度 /
已装应用使用时长 / 流量明细** 定时上报到各自的管理平台。它们在设置里几乎不可见，也没有开关：

| 现象 | 说明 |
|---|---|
| 设置的应用列表里找不到 | 无 activity，或 PMS 层被 ROM 直接过滤 |
| 找不到"关闭"开关 | 有些分支只读系统开机向导状态（过完就开始上报） |
| 停用后仍会拉起 | manifest 里写着 `ForbidStop=true` |

本项目把三家的采集与上报链路同时掐断，**全部离线、不联网、不采集任何数据**。

---

## 覆盖的三个组件

| 厂商 | 包名 | 实测版本 | 上报/注册地址 | 采集内容 |
|---|---|---|---|---|
| 联通 | `com.mobiletools.systemhelper` | 3.0.1-20250822 | `http://dm.wo.com.cn:18080/register` | IMEI / ICCID / IMSI / 基站 / 经纬度 / 应用使用时长 / 流量 |
| 移动 | `com.coloros.regservice` | 16.0.20 | `https://a.fxltsbl.com`（可被云端改写） | IMEI / IMSI / ICCID / 网速 / 锁机信息 / 应用清单 |
| 电信 | `com.oppo.ctautoregist` | 16.1.5 | `https://zzhc.vnet.cn`、`https://typdm.tydevice.com` | IMEI / IMSI / ICCID，另有**卫星/IMS 注册短信** |

三家的共同点：都是 priv-app，都有 `ForbidStop=true`，都只在插对应运营商卡时才真正工作。
区别在于出网方式——联通是单出口 HTTPS+自定义加密，移动是三出口（volley / HttpURLConnection / 无权限 Provider），
电信则多一条 `SmsManager.sendDataMessage` 的短信注册通道。

---

## 架构

```
┌─ 内核层 ── KernelSU 模块 carrier_dm_blocker
│             按 uid 阻断三家的全部 IPv4/IPv6 出站（连 JNI / 短信之外的 native 路径一起拦）
│             每 60 秒自愈，另负责补写 LSPosed 的 scope 表
└─ 应用层 ── LSPosed 模块 CarrierDMBlocker
              三个入口类，各自只管自己那个包：
                ShHook   联通 SystemHelper
                RgsHook  移动 RegService
                CtaHook  电信 CTAutoRegist
```

两层互相独立：只装内核层就已经断网；装应用层则把**采集动作本身**也停掉（不产生数据、不写库、不发短信）。
两层通过共享目录联动，内核模块的「操作」按钮能一次性体检三家的状态。

| 层 | 组件 | 拦什么 | 能单独用吗 |
|---|---|---|---|
| 内核 | KernelSU 模块 `carrier_dm_blocker` | 三个 uid 的全部出站（含 native 层） | ✅ |
| 应用 | LSPosed 模块 `com.example.carrierdmblocker` | 出口 / 采集 / 定位 / 落库 / 短信 / 第三方调用 | ✅ |

---

## 拦截点

### 联通 `com.mobiletools.systemhelper`

全 App 只有一个 HTTP 出口，所以把出口掐住即可；再配合总闸连采集都不做。

| 层 | 目标（混淆名） | 动作 |
|---|---|---|
| L1 | `g1.f.b(String, byte[], byte[]) : boolean` | 返回 `true`（伪装上报成功） |
| L2 总闸 | `e1.b.a(Context, String) : e1.b` | 返回空对象，立即短路 |
| L2 门控 | `f1.a.c` / `g1.l.a` / `GetSignalInfoReceiver.b,c` | 返回 `false` |
| L3 | `GetSignalInfoReceiver.d(回调) : void` | 不执行，百度定位不启动 |
| L4 | `g1.m.c(String)` / `g1.e.b(String) : void` | 不执行 + 启动时清库 |

> **L1 必须返回 `true` 而不是 `false`**：返回 false 会让上层走"落库补报"分支并反复重试。

### 移动 `com.coloros.regservice`

供应商是神州泰岳（Richinfo）的 DM SDK，三处出网 + 一个无权限 Provider。

| 层 | 目标 | 动作 |
|---|---|---|
| L1 | 三处出口（volley / 裸 `HttpURLConnection`） | 直接返回成功，不发包 |
| L2 | 补丁与下载通道 | 关掉动态加载开关，拒绝 `patch.jar` 下载 |
| L3 | 采集入口（SIM 变化 / 网络变化 / 定时） | 不执行 |
| L4 | `cmcc_dm.db` 落库 | 不执行 + 启动清库 |
| L5 | `cn.richinfo.dm.provider.DMProvider.call()` | 返回 null（第三方驱动不了它） |
| UNHIDE | ColorOS 设置侧 `getInstalledPackages` / `AppManagerUtils.isHideApp` 等 6 处 | 让隐藏的包在应用列表里可见 |

### 电信 `com.oppo.ctautoregist`

唯一一条还带**短信**通道的，所以单独拦了发短信的几个方法。

| 层 | 目标 | 动作 |
|---|---|---|
| L1 | `t.j.c(String, byte[])` / `u.a.c(String) : JSONObject` | 返回 null |
| L2 | `ImsSmsSim{1,2}RegisterService` / `SatelliteSmsSim{1,2}RegisterService` 的发短信方法 | 不执行（不发注册短信） |
| L3 | `t.t` 全部 17 个实例方法（IMEI / ICCID / IMSI …） | 返回类型默认值 |
| L4 | `RegisterReceiver.onReceive` + 4 个服务的 `onStartCommand` | 不执行 / `START_NOT_STICKY` |

---

## 目录结构

```
.
├── CarrierDMBlocker/                 # LSPosed 模块（libxposed API 102）
│   └── app/src/main/
│       ├── java/.../ShHook.java      # 联通
│       ├── java/.../RgsHook.java     # 移动
│       ├── java/.../CtaHook.java     # 电信
│       └── resources/META-INF/xposed/
│           ├── java_init.list        # 三个入口类
│           ├── module.prop
│           └── scope.list            # 三个目标包
├── carrier_dm-module/                # KernelSU 模块
│   ├── service.sh                    # 探测 3 个 uid → REJECT → 60s 自愈 → 补 scope
│   ├── action.sh                     # 「操作」按钮：三合一一体检
│   ├── dbfix.dex                     # 直接写 LSPosed 的 scope 表（源码在 dbfix/src）
│   └── post-fs-data.sh / uninstall.sh / skip_mount
├── build_carrier_zip.py              # 打包成可刷入的 zip
│
├── SystemHelperXposed/               # v1.x 联通专用版源码（已归档）
└── kernel-module/                    # v1.x 联通专用版内核模块（已归档）
```

---

## 安装

**1. 应用层**

```bash
adb install -r CarrierDMBlocker-Xposed-2.0.apk
```

装完到 LSPosed 里启用，作用域勾上三个包（移动那个如果界面里看不到，把模块装好后重启一次，
内核模块会自动把 scope 写进 LSPosed 的配置库）。

**2. 内核层**

```bash
adb push CarrierDMBlocker-KernelSU-2.0.zip /data/local/tmp/
adb shell su -c "ksud module install /data/local/tmp/CarrierDMBlocker-KernelSU-2.0.zip"
# 重启生效
```

Magisk 用户把 `ksud module install` 换成在 Magisk 里刷 zip 即可。

---

## 体检

KernelSU 管理器里点该模块的「操作」，或：

```bash
adb shell su -c "sh /data/adb/modules/carrier_dm_blocker/action.sh"
```

```
[1] LSPosed 作用域（直读 modules_config.db）
    exists  com.mobiletools.systemhelper
    exists  com.coloros.regservice
    exists  com.oppo.ctautoregist
    exists  com.android.settings
    状态 : ✅ 完整

[目标] 联通 SystemHelper      uid 10100   IPv4/IPv6 OK   连接: 无   Hook L1=1 L2e=1 L2g=4 L3=1 L4=2
[目标] 移动 RegService        uid 10271   IPv4/IPv6 OK   连接: 无   Hook L1=1 L2=2 L3=40 L4=13 L5=6 UNHIDE=6
[目标] 电信 CTAutoRegist      uid 10104   IPv4/IPv6 OK   连接: 无   Hook L1=2 L2=8 L3=17 L4=5

[结论] ✅ 三家规则在位，当前零外连
```

**怎么读**：

| 现象 | 含义 |
|---|---|
| 规则在、命中数 0、连接表空 | ✅ 最理想：应用层就拦住了，一个包都没发出去 |
| 命中数在涨 | ⚠️ 有路径绕过应用层，被内核兜住（可查 events.log） |
| 规则不见了 | ❌ 被 netd 清了，60 秒守护会补回来 |
| `status.json` 心跳超 10 分钟 | ❌ Xposed 层没工作（进程没跑 / 模块没启用 / 目标已停用） |

---

## 配置

三个开关文件分别在各自目标的媒体目录，改完重启目标进程即可，**不用重刷模块**：

```bash
/storage/emulated/0/Android/media/com.mobiletools.systemhelper/SHBlocker/config.conf
/storage/emulated/0/Android/media/com.coloros.regservice/SHBlocker/config.conf
/storage/emulated/0/Android/media/com.oppo.ctautoregist/SHBlocker/config.conf
```

| 目标 | 键 |
|---|---|
| 联通 | `BLOCK_EGRESS` / `BLOCK_COLLECT` / `BLOCK_LOCATION` / `BLOCK_DB` / `WIPE_DB` |
| 移动 | `BLOCK_EGRESS` / `BLOCK_DOWNLOAD` / `BLOCK_COLLECT` / `BLOCK_DB` / `BLOCK_PROVIDER` / `BLOCK_PATCH` / `WIPE_DB` |
| 电信 | `BLOCK_NET` / `BLOCK_SMS` / `BLOCK_COLLECT` / `BLOCK_TRIGGER` |

同目录下的 `status.json` 是模块写的心跳与统计，`events.log` 是事件流，内核侧体检读它们。

---

## 构建

Xposed 模块（JDK 17 + Android SDK 34）：

```bash
cd CarrierDMBlocker
echo "sdk.dir=/path/to/android-sdk" > local.properties
./gradlew assembleDebug
# 产物：app/build/outputs/apk/debug/app-debug.apk
```

KernelSU 模块：

```bash
python build_carrier_zip.py    # 输出 dist/CarrierDMBlocker-KernelSU-<version>.zip
```

`dbfix.dex` 的重编译（改了模块名或目标包时必须做）：

```bash
javac -source 8 -target 8 -bootclasspath <android.jar> -d dbfix/out dbfix/src/com/rgs/DbFix.java
java -cp <build-tools>/lib/d8.jar com.android.tools.r8.D8 --lib <android.jar> --min-api 29 --output dbfix dbfix/out/com/rgs/*.class
```

---

## 兼容性

| 项 | 实测 | 说明 |
|---|---|---|
| 设备 | OPPO PLP110 / ColorOS 16（Android 16） | |
| 联通目标 | 3.0.1-20250822 | 类名取自该版本 |
| 移动目标 | 16.0.20 / 160000020 | |
| 电信目标 | 16.1.5 / 16001005 | |
| Xposed 框架 | LSPosed（API 102） | 需要支持 libxposed 的版本 |
| root 方案 | KernelSU | Magisk 只换安装方式 |
| 模块 minSdk | 29 | `onPackageReady` 要求 Android 10+ |

**已知限制**：

1. 联通和电信的类名是混淆后的短名（`e1/g1/f1`、`t.j/u.a/t.t`），**OTA 升级后大概率失效**；
   移动侧同理。想抗变更可以接 [DexKit](https://github.com/LuckyPray/DexKit) 按字符串常量搜索。
2. 内核层按 uid 全量阻断，不做协议识别——目标换 uid（重装/换版本）需要重启让 `service.sh` 重新探测。
3. 移动那个包在 PMS 层被 ColorOS 过滤，`pm list packages` 查不到、LSPosed 界面也加不了作用域，
   只能靠内核模块的 `dbfix.dex` 写库；如果哪天 LSPosed 数据被清，重启一次即可恢复。
4. 只覆盖这三个包，不针对任何其他应用。

---

## 验证方法

不想等定时上报，可以直接触发目标进程。三个都可以：

```bash
# 联通（自带测试入口）
adb shell su -c "am start -n com.mobiletools.systemhelper/.Activity.TestActivity"

# 移动（Provider 调用会被 L5 挡掉，但进程会被拉起）
adb shell am start-foreground-service -n com.coloros.regservice/cn.richinfo.dm.service.DMService

# 电信（服务被 L4 挡掉，进程照样起来）
adb shell su -c "am startservice -n com.oppo.ctautoregist/com.oppo.ctautoregist.ImsSmsSim1RegisterService"
```

模块日志在 LSPosed 里：

```bash
adb shell su -c "grep -a carrierdmblocker /data/adb/lspd/log/modules_*.log | tail -30"
```

看到这类行说明当场就断了：

```
[SHBlocker]  L2 entry short-circuit regType= (total 36)
[RGSBlocker] L5 provider call blocked (3)
[CTBlocker]  L4 RegisterReceiver.onReceive blocked (5)
```

---

## 更新内容

### v2.1

- **修复多用户 UID 取错**：`pm list packages -U` 在有多用户的设备（如分身）返回
  `userId × 100000 + appId` 的编码值（实测分身 user10 的电信包为 `1010107`），
  v2.0 把它当成 appId，导致只封了分身、漏掉机主的 `10107`。现在统一把编码值取模
  还原为 appId，并优先用 `dumpsys appId` / `packages.list`，同时遍历所有已存在的
  用户数据目录，**机主与分身两个 UID 全部加入拦截**（如电信 `10107` + `1010107`）。
- **消除开机约 5 分钟空窗**：v2.0 在任一包取不到 uid 时整体等待 20×15s，未安装的
  联通 `SystemHelper` 会把已就绪的移动/电信规则一起拖后。现在改为逐包探测、
  即到即加规则；确认未安装的包立即跳过。
- 自检脚本 `action.sh` 同步支持展示/检查多个 uid（机主 + 分身）。
- 新增 `tests/test_service_uid.sh`：用 mock 覆盖 `pm`/`dumpsys`/`stat`，
  回归验证 PMS 隐藏包穿透、多用户 UID 归一化、机主+分身双覆盖、未装包跳过。
  运行：`bash tests/test_service_uid.sh`。

### v2.0

- **三合一**：三个独立的 Xposed 模块（syshelper / regservice / ctauto）合并为一个 APK，
  三个 `XposedModule` 入口类（`ShHook` / `RgsHook` / `CtaHook`）各管一个包，hook 逻辑保持不变。
- **三合一**：`sh_blocker` / `rgs_blocker` / `cta_blocker` 三个 KernelSU 模块合并为 `carrier_dm_blocker`，
  一次探测三个 uid、一次加规则、一次自愈。
- **新增**电信 `com.oppo.ctautoregist` 的完整拦截（L1 网络 / L2 注册短信 / L3 采集 / L4 触发）。
- 体检脚本重写：一条命令打印三家状态，scope 改为直读 `modules_config.db`（不再依赖只允许
  ADB root shell 的 `lspctl`），新增每个目标的拦截统计。
- `dbfix.dex` 改为按模块名与 4 个作用域写入，开机自动补齐 LSPosed scope。

### v1.0

- 首个版本：联通 `com.mobiletools.systemhelper` 的三层拦截（DNS / 内核 uid 阻断 / LSPosed hook），
  含 L1 出口伪装、L2 总闸与门控、L3 定位、L4 落库，以及 KernelSU 模块的 60 秒自愈与一键体检。

---

## 免责声明

- 本项目用于**自有设备上的隐私控制**：阻止预装组件在用户不知情的情况下采集并外发设备信息。
- 只对上述三个包生效，不修改任何系统文件，不联网，不上传任何数据。
- 使用需要 root，**后果自负**；不同 ROM / 版本可能有差异，请先备份。
- 请勿用于规避运营商合约、伪造设备信息或任何违法用途。

---

## 许可证

[MIT](LICENSE)
