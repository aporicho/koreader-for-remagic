# KOReader for ReMagic

面向 reMarkable Paper Pro Move 的 KOReader QTFB 适配层。它让官方 KOReader
作为普通 ReMagic 应用运行，不依赖镇纸、Paperweight、xochitl、einkface 或
`/dev/fb0`。

## 不修改官方 KOReader

程序、适配器和数据分为三个边界：

```text
/home/root/apps/koreader-for-remagic/
├── vendor/releases/<official-release>/koreader/  # 官方本体，只读
└── adapter/releases/<content-hash>/               # ReMagic 适配器，只读

/home/root/.local/share/koreader-for-remagic/data/     # 设置、进度、数据库
/home/root/.local/state/koreader-for-remagic/          # 迁移备份
/home/root/.cache/koreader-for-remagic/                 # 缓存
```

本仓库不包含官方 KOReader，也不会增删或覆盖 vendor 文件。固定的首个官方版本为
`v2026.03-56621d5ee66ad94f4f3e2e6d204e8c34be730343f915edc36bb076a043a2e468`。
ReMagic 构建时校验官方压缩包和完整文件清单，并把 vendor 作为只读运行目录。

适配只使用 KOReader 官方支持的 `KO_HOME/patches` userpatch 入口：

- `10-remagic-environment.lua`：把 `version.log` 重定向到 KO_HOME，并让托管环境
  使用原生 `EXT_FONT_DIR` 外置字体路径；
- `20-remagic-policy.lua`：通过 `plugins_disabled.terminal=true` 禁用 Terminal，
  同时隐藏由 ReMagic 接管的 OTA；
- `21-remagic-lifecycle-v2.lua`：提供语义 ready、保存、前后台、同 PID 开书和
  优雅关闭。

补丁由 wrapper 原子同步到 KO_HOME；旧版 ReMagic 平台补丁会被精确清理，用户的
其他 patch 和 plugin 不受影响。

## ReMagic 交付契约

`manifests/koreader.toml` 是 schema v2 模板。Adapter 路径包含
`__REMAGIC_ADAPTER_RELEASE__`，ReMagic 打包时必须替换为该 release 的内容哈希，
不得在生产 manifest 中留下占位符或改用可变的 `current` 链接。

KOReader 是驻留的 `qtfb_compat` 应用，后台策略为：

```toml
[runtime]
background_execution = "freeze"
```

切后台时 userpatch 先执行 `UIManager:flushSettings()`，再依次报告
`state_saved` 和 `background_ready`。ReMagic 收到确认后撤销显示/输入租约并冻结
systemd cgroup。召回时先解冻，再发送带新 foreground epoch 和 lease 的
`enter_foreground`；KOReader 完成真实重绘后报告新的 `ready`。

生命周期只有一种传输：ReMagic 继承给进程的双向
`REMAGIC_LIFECYCLE_FD`。协议为单行 JSON v2：

```json
{"protocol":2,"request_id":"...","body":{"command":"open_path","app_id":"koreader","generation":1,"foreground_epoch":2,"lease_id":3,"path":"/home/root/books/book.epub"}}
```

支持 `start`、`enter_background`、`enter_foreground`、`open_path` 和 `shutdown`。
generation、foreground epoch 和 display lease 用来拒绝跨重启或跨前台租约的迟到
命令。缺少生命周期 FD 或实例 generation 时 wrapper 会在启动前失败；没有 bridge、
轮询子进程、marker 文件或旧协议降级。

## 启动与书库

ReMagic 执行 adapter release 中的 `bin/koreader-for-remagic`。wrapper 从自身真实目录
找到同 release 的 `libexec` 与 `share`，因此不依赖固定 adapter 版本名。它绕过
上游 `koreader.sh`，直接在以下 QTFB 环境中运行 `reader.lua`：

- `N_RGB565`、原生输入；
- 完整刷新请求透传；
- 禁止 KOReader 抢占输入和修改色深；
- `LD_PRELOAD` 只作用于 reader 进程。

wrapper 只复现上游脚本安全的 `/tmp/koreader.sh` 同步步骤。返回码 85 会原进程
重新启动，其他返回码交回 ReMagic。

每次启动会从 reMarkable `.metadata` 原子生成友好书库视图：优先链接 EPUB，其次
PDF，不修改、移动或删除 xochitl 文件。无参数时进入友好书库；`read 书名` 可以
通过 `open_path` 在同一个驻留 PID 中开书。

## 字体

自定义字体属于 adapter，而不是 vendor。ReMagic 构建时调用：

```sh
scripts/stage-custom-fonts.sh <adapter-release>/share/fonts
```

脚本校验并发布上图东观体三种规格和方正屏显雅宋，同时生成可复验的
`fonts.sha256`。字体二进制不提交到公开仓库。wrapper 将 ReMagic 提供的冒号列表
`REMAGIC_FONT_DIRECTORIES` 转成 KOReader 原生的分号列表 `EXT_FONT_DIR`；官方内置
字体仍正常保留。

## 独立安装与检查

推荐由 ReMagic bundle 部署。独立安装器只适合已有固定 vendor 的环境：

```sh
sudo ./scripts/install-device.sh
./scripts/check.sh
```

安装器不写 vendor，会把 adapter 发布到由源文件内容计算出的
`adapter/releases/standalone-<hash>`，并事务化迁移用户数据。安装进行中、KOReader
仍在运行、vendor 不完整、symlink/特殊文件、数据库校验失败或断电恢复不一致都会
明确拒绝；回滚不会覆盖阅读数据或永久迁移备份。这个备用安装器不发布 ReMagic
manifest；`standalone-*` 需要手工接入兼容的 manifest。日常设备部署应使用 ReMagic
bundle，它会生成 `adapter-*`、固定清单并一次完成接线。

`scripts/check.sh` 覆盖 manifest、wrapper、字体边界、迁移、友好书库、安装事务、
语义 ready、保存、前后台、陈旧 token、开书与关闭。真实 SOCK_SEQPACKET 用例需要
与目标架构兼容的 LuaJIT，可通过 `KOREADER_TEST_LUAJIT` 指定。
