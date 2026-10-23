# Mac 电脑上的后续任务（M3.6：完整 iOS 16.7.16 用户态 → 锁屏/主屏）

> 交接时间：2026-10-23。此文档面向在 **macOS** 上继续本项目的场景。
> 你现在的 Windows/WSL 环境已经完成的成果见 `00-START-HERE.md` 与
> `docs/HackiOS-MIX2S-调研报告.md`。

## 0. 前置条件

| 项 | 要求 |
|---|---|
| macOS | 13 Ventura 或更新（Apple Silicon / Intel 均可） |
| 工具 | `xcode-select --install`（hdiutil、newfs_hfs、rsync、python3） |
| 磁盘 | **至少 30 GB 空闲**（IPSW DMG 解压后约 7.5 GB，HFSX 镜像用 16 GB 稀疏，sparse 输出约 8 GB） |
| 手机 | MIX 2S（polaris），已解锁；fastboot：`brew install android-platform-tools` |
| 网络 | 能访问 `updates.cdn-apple.com`（Apple IPSW CDN） |

## 1. 取源码

```sh
git clone https://github.com/WuuuWeiii/ios-sweet
cd ios-sweet
```

或者解压本包里的 `src/ios-sweet-src.tar.gz`（内容相同，已含全部补丁
`xnu/patches/0099..0108` 和 Mac 脚本 `tools/mkiosroot-macos.sh`、
`tools/img2simg.py`）。

## 2. 取 IPSW 里的三个 DMG（iPhone X / iPhone10,3 / iOS 16.7.16 / 20H392）

IPSW 地址（6,171,035,648 B）：

```
https://updates.cdn-apple.com/2025FallFCS/fullrestores/122-77006/1158E502-D76D-4226-AA06-ED5E30CD1111/iPhone10,3,iPhone10,6_16.7.16_20H392_Restore.ipsw
```

**方式 A（推荐，只拉需要的 3 个文件，约 7.5 GB）** —— 用仓库自带工具按 HTTP
Range 直接提取，不需要下载 6.17 GB 整包：

```sh
URL='https://updates.cdn-apple.com/2025FallFCS/fullrestores/122-77006/1158E502-D76D-4226-AA06-ED5E30CD1111/iPhone10,3,iPhone10,6_16.7.16_20H392_Restore.ipsw'
mkdir -p ipsw && cd ipsw
python3 ../tools/remotezip.py "$URL" 087-86698-044.dmg .   # OS        4.73 GB
python3 ../tools/remotezip.py "$URL" 087-86593-047.dmg .   # SystemOS  2.74 GB
python3 ../tools/remotezip.py "$URL" 087-86715-047.dmg .   # AppOS       10 MB
```

**方式 B**：浏览器/curl 下载整包后 `unzip`，同样得到上面 3 个文件。

文件名↔组件对应关系来自 `BuildManifest.plist`（本包 `ipsw/BuildManifest.plist`
就是从该 IPSW 里提取的，可直接 `plutil -p` 查看）：

| IPSW 文件 | 组件 | 大小 |
|---|---|---|
| `087-86698-044.dmg` | `OS`（系统卷） | 4,730,814,044 B |
| `087-86593-047.dmg` | `Cryptex1,SystemOS` | 2,743,074,816 B |
| `087-86715-047.dmg` | `Cryptex1,AppOS` | 10,485,760 B |
| `087-86622-047.dmg` | RestoreRamDisk（不用） | 109,051,931 B |
| `087-86719-047.dmg` | RestoreRamDisk（不用） | 106,954,779 B |

## 3. 在 Mac 上生成 iOS 根卷（HFSX，大小写敏感 + 日志）

```sh
sudo ./tools/mkiosroot-macos.sh \
    ipsw/087-86698-044.dmg ipsw/087-86593-047.dmg ipsw/087-86715-047.dmg \
    ios16-root.img 16G
```

脚本流程（等价于 Linux 版 `tools/mkiosroot.sh`）：

1. `mkfile -n 16g` 建稀疏 raw 文件 → `hdiutil attach -imagekey diskimage-class=CRawDiskImage -nomount`；
2. `newfs_hfs -s -J -v iOSRoot` 格式化为大小写敏感、带日志的 HFS+；
3. `hdiutil attach` 三个 DMG（UDIF 不行则回退 `CRawDiskImage` 方式挂载 raw APFS）；
4. `rsync -aH --numeric-ids` 合并：OS → 根；SystemOS → `/private/preboot/Cryptexes/OS`；AppOS → `.../App`；
5. 硬链接 dyld 共享缓存到 `/System/Library/Caches/com.apple.dyld`，并把 cryptex 里根卷缺失的文件硬链接回根；
6. 建 logd 存储目录（uid/gid 272）与无密码 system keybag；
7. 自动运行 `tools/sweet-root-tweaks.py`（跳过 Setup、激活状态、launchd 容错、去掉基带/camera 相关崩溃守护进程等）；
8. `fsck_hfs` 校验。

> 若 `hdiutil attach` 报 "no mountable file systems"：先 `hdiutil imageinfo <dmg>`
> 看类型；cryptex DMG 是 raw APFS，用脚本里的回退分支（`CRawDiskImage`）。
> macOS 13+ 原生支持 APFS 读写。

## 4. 转成 fastboot 能刷的 Android sparse 镜像

```sh
python3 tools/img2simg.py ios16-root.img ios16-root.simg
```

`img2simg.py` 是本包提供的纯 Python 实现（Mac 上一般没有 Android SDK 的
`img2simg` 可执行文件），输出与官方工具格式一致；已用 8 MB 混合镜像做过
往返校验。

## 5. 刷入并启动

> ⚠️ **会清空 Android 的 userdata**。刷机前先备份串号分区：
> ```sh
> fastboot getvar all > getvar.txt        # 至少保存下来
> fastboot oem ...                        # 若已解锁，persist/modemst/fsg 可用 fastboot 读回备份（机型相关）
> ```
> 想恢复 Android 时刷 MIUI fastboot 线刷包即可。

```sh
# 1) 手机进 fastboot（长按 电源+音量下，或 adb reboot bootloader）
fastboot devices

# 2) 刷根卷（约 7 分钟，不要拔线）
fastboot -S 512M flash userdata ios16-root.simg

# 3) 启动（二选一）
fastboot boot artifacts/shim-ios-full.img    # cpus=6，SMC PSCI；首次启动会尝试启动 6 个 A55
fastboot boot artifacts/shim-ios-1cpu.img    # 单核兜底，先确认能到锁屏
```

> 小米 fastboot 在大量刷写后常挂起：长按 **电源+音量下** 重新进 fastboot，
> 然后 `fastboot boot ...` 即可，不需要重刷。

首次启动约 **4–5 分钟**（Apple logo），随后出现 **锁屏**，上滑解锁。

启动参数（已写进 payload，供排查时参考）：

```
debug=0xc serial=3 cpus=6 keepsyms=1 -enable_kprintf_spam -noprogress
rd=ufsroot0 unentitled_ios_sim_launch=1 ignition_level=1
wdt_test=no_user_checkin ufsrw=1 rootrw=1 launchd_unsecure_cache=1
wdt=-1 sweetfb_noconsole=1 sweetfb_hz=30 sweet_psci=smc
```

| 参数 | 作用 |
|---|---|
| `rd=ufsroot0 ufsrw=1 rootrw=1` | 根卷用 userdata 分区的 HFSX（可读写） |
| `cpus=6` | 启动 6 个 A55；`cpus=1` 为兜底 |
| `launchd_unsecure_cache=1` | 无 AMFI 时 launchd 接受 job cache |
| `wdt=-1 wdt_test=no_user_checkin` | 关闭硬件 watchdog |
| `sweetfb_noconsole=1` | 不把内核文本画到 GUI 上；日志仍写入持久环，panic 会画出来 |
| `sweet_psci=smc` | PSCI 走 SMC（真机）；QEMU 验证时用 `hvc` |

## 6. 读内核日志（真机）

```sh
# 需要临时启动 OrangeFox recovery（不动系统分区）
fastboot boot recovery/recovery.img
tools/sweet-log-pull.sh logs/boot.txt      # 从 userdata 末尾取 4 MiB console ring
adb reboot bootloader
python3 tools/sweet-crash.py ...           # 符号化 CRASH 报告（可选）
```

## 7. 先在不写 userdata 的情况下验证内核（可选）

本包 `artifacts/` 里有两个**内存盘**镜像，不刷任何分区，`fastboot boot` 直接用：

| 镜像 | 用途 |
|---|---|
| `shim-hw-0108-1cpu.img` | 安全单核 + 32 MB HFS 内存盘根：屏幕上应出现 `*** SWEET userspace: init running as PID 1 ***`（已验证于 QEMU） |
| `shim-hw-0108-8cpu.img` | 8 核 ADT：真机验证 **PSCI CPU_ON over SMC**；日志会打印 `SWEET CPU: cpu=1 CPU_ON target=0x100 ... conduit=smc`，随后 `rc=0`/`came alive` 或 panic 报错码 |

## 8. 当前状态与已知问题（交接时）

- ✅ CI（Apple clang / macos-14）已能构建 POLARIS 内核（补丁 0099–0108），
  最新产物 `artifacts/kernel.development.polaris`（17,206,296 B）。
- ✅ QEMU 端到端验证：HFS+ RAM 盘根挂载 → exec `/sbin/launchd` → PID1 运行；
  8 核 SMP（`8/8 CPUs initialized, SGI1 verified`）通过。
- ✅ 真机：内核日志、PE 初始化、RAM 盘根、exec、PID1 均已跑通（0105 内核）。
- ⏳ 真机 SMP（PSCI CPU_ON over SMC）尚未验证 —— 用 `shim-hw-0108-8cpu.img` 看结果；
  若 panic 显示 `PSCI CPU_ON rc=N`，把 N 反馈出来即可据此调整（rc=-1 表示
  monitor 不支持，可试 `sweet_psci=hvc`）。
- ⏳ 完整 iOS 根卷尚未构建（`mkiosroot.sh` 是 Linux 工具链，本包提供了 Mac 版脚本，
  但**未在真 Mac 上实测**；构建中如遇 hdiutil/APFS 挂载问题按第 3 节备注处理）。

## 9. 文件清单

```
mac-transfer/
├── 00-START-HERE.md              ← 先读这个（包说明与操作顺序）
├── README-MAC.md                 ← 本文件
├── artifacts/
│   ├── kernel.development.polaris   0108 CI 内核（17.2 MB）
│   ├── shim-hw-0108-1cpu.img        安全单核 + RAM 盘根（50.8 MB）
│   ├── shim-hw-0108-8cpu.img        SMP 测试（8 核 ADT, SMC PSCI）
│   ├── shim-ios-full.img            完整 iOS 启动（rd=ufsroot0, cpus=6）
│   ├── shim-ios-1cpu.img            完整 iOS 启动（单核兜底）
│   └── root-hfs.raw                 32 MB HFS+ RAM 盘根（自建 init）
├── scripts/
│   ├── mkiosroot-macos.sh        Mac 版根卷构建（本包新增）
│   ├── img2simg.py               raw → Android sparse（纯 Python）
│   └── flash-and-boot.sh         刷机/启动辅助（带清空提示）
├── src/
│   ├── ios-sweet-src.tar.gz      完整源码快照（不含 .git）
│   └── ios-sweet.bundle          git bundle（含 3 个本地提交历史）
├── docs/
│   ├── HackiOS-MIX2S-调研报告.md 全项目调研与里程碑记录
│   ├── hw0102.jpg / hw0104.jpg   真机屏幕照片（内核日志阶段）
│   ├── qemu-0105.png             QEMU 中 PID1 上屏
│   └── qemu-smp8h.png            QEMU 8 核 SMP 成功
├── ipsw/
│   ├── BuildManifest.plist       从 IPSW 提取（DMG 名字映射）
│   └── IPSW-URL.txt              下载地址与校验和
└── SHA256SUMS.txt                包内大文件校验和
```
