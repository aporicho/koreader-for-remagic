# Remagic KOReader adapter

面向 reMarkable Paper Pro Move 的独立 KOReader QTFB 适配层。KOReader 由
Remagic Manager 托管，不依赖镇纸、xochitl、Paperweight、einkface 或
`/dev/fb0`。

本项目不包含 KOReader 本体或 QTFB runtime。设备上需要：

- Manager bundle 把 KOReader 本体固定在 `/home/root/apps/remagic-koreader/program`；
  独立安装器则只读使用已有的 `KOREADER_DIR`（默认 `/home/root/apps/koreader`）；
- Remagic Manager 提供私有的 `/home/root/apps/remagic/shims/qtfb-shim.so` 和 QTFB 服务；
- 本适配器安装到 `/home/root/apps/remagic-koreader/bin/koreader-remagic`。

## Remagic 应用交付契约

`manifests/koreader.toml` 使用 schema v2，并把 KOReader 声明为可驻留的
`qtfb_compat` 应用。平台在启动前检查 QTFB、触摸和 v2 生命周期能力；只有
KOReader 的 FileManager 或 ReaderUI 完成第一次真实重绘并报告 `ready` 后，
窗口才可以进入前台。切到后台时进程和书籍保持不变，适配层先调用 KOReader
自带的 `flushSettings()`，随后依次报告 `state_saved` 和 `background_ready`；
恢复前台后同一个 PID 重新绘制，并在重绘完成后再次报告 `ready`。

生命周期协议采用单行 JSON v2 envelope：

```json
{"protocol":2,"request_id":"...","body":{"event":"ready","app_id":"koreader","generation":1}}
{"protocol":2,"request_id":"...","body":{"command":"open_path","app_id":"koreader","generation":1,"path":"/home/root/books/book.epub"}}
```

首选传输是平台继承的双向 `REMAGIC_LIFECYCLE_FD`；Lua userpatch 直接进行
非阻塞读写，不产生轮询子进程。过渡平台也可提供 `REMAGIC_APP_BRIDGE`，其
`emit` 子命令从 stdin 接收一行 envelope，`poll` 子命令向 stdout 返回零到多行
命令。桥接 helper 只在 KOReader 自带的低优先级子进程中运行；默认最多每秒
poll 一次，失败重试同样限频，卡死 worker 会被取消，因此 helper I/O 不会阻塞
阅读 UI。`koreader-lifecycle` 是唯一知道旧 `koreader-ready`/`koreader-exit`
文件的组件；没有 v2 传输时才自动降级，因此旧 Manager 仍可工作。

支持的命令为 `enter_background`、`enter_foreground`、`open_path`、`shutdown`
和初始 `start`。`open_path` 在同一个驻留进程内打开新书或目录，仍受 manifest
允许目录约束。`shutdown` 使用 KOReader 原生 `Exit` 事件保存文档与数据库，
并报告 `state_saved`、`shutdown_complete`；超时后由平台按 manifest 中的
graceful/TERM/KILL 截止时间兜底。
冷启动的书籍路径先由 argv 交给 `reader.lua`，随后同值的 v2 `Start` 只确认而
不重复开书；驻留实例收到 `EnterForeground(open_path)` 时则会在更新 lease 后
打开新书或目录，并以新 token 的真实重绘报告 `ready`。

## 启动行为

管理器调用 `koreader-remagic`。适配器绕过上游 `koreader.sh`，直接运行
`reader.lua`，因此不会探测 framebuffer、修改屏幕深度或启动官方界面服务。
启动前只复现上游脚本安全的重定位步骤：把当前 `koreader.sh` 校验后原子同步到
`/tmp/koreader.sh`，避免 KOReader 把旧副本误判为升级并反复要求完全退出。
每次启动会快速读取官方文档库的 `.metadata`，用 KOReader 自带的 Lua 与
`dkjson` 解析 `DocumentType` 和 `visibleName`，再把 EPUB（优先）或 PDF 以
友好书名链接到 `/home/root/.local/share/remagic-koreader/library`。该目录是
原子切换的只读来源视图；同步过程不会修改、移动或删除 xochitl 中的任何文件。
空书名、控制字符、斜杠和重名都有确定且安全的命名规则。

没有参数时，适配器只打开这个友好书库。如果 `lastdir` 仍在友好书库中则恢复，
任何 xochitl 原始目录、旧 generation 或其他目录都会回退到友好书库，因此不会
再看到 UUID 与 `.thumbnails`。传入受管理器许可的书籍路径时仍可直接打开该书。
若同步遇到写入中的损坏 metadata，会保留并使用上一份完整视图；没有可用旧视图
时才拒绝启动。

QTFB 环境固定使用上游 Paper Pro Move 推荐值：`N_RGB565`、原生输入、
完整刷新请求透传，以及禁止 KOReader 抢占输入和修改色深。`LD_PRELOAD`
只应用于 `reader.lua` 子进程。返回码 85 会重新启动 reader，其他返回码
原样交还给管理器。

管理器部署的固定版本程序位于 `/home/root/apps/remagic-koreader/program`，不会
覆盖已有的 `/home/root/apps/koreader` 或 Paperweight 目录；这些旧目录只作为
一次性数据迁移来源。程序与可写数据强制分离，默认
`KO_HOME` 与 `KOREADER_DATA_DIR` 都是
`/home/root/.local/share/remagic-koreader/data`。适配器、数据迁移器和 KOReader
上游 `datastorage.lua` 因此共同把设置、数据库、历史、剪贴板、词典和 OCR 数据
写入独立目录；若两个环境变量指向不同位置，启动会在任何写入前失败。旧程序树
中的数据会幂等迁移，保持现有阅读记录兼容；故障注入验收则使用另一份临时数据根。
KOReader 会从当前数据目录的 `patches/` 加载 userpatch，因此适配器把自己
`share/patches` 中的只读平台补丁在启动前原子同步到当前 `KO_HOME`：早期补丁
把 `version.log` 重定向到 DataStorage，后期补丁提供生命周期编排；协议编码、
异步 helper 与安全开书分别由适配器 `libexec` 中的小型 Lua 模块实现。字典目录也
默认落在当前数据根。隔离验收因此仍能报告真实 `ready`/后台/关闭事件，同时
不会借用或修改正式程序目录中的补丁、版本日志、字典或阅读数据。

## 安装与检查

```sh
sudo ./scripts/install-device.sh
./scripts/check.sh
```

独立安装器要求设备上已经存在完整 KOReader；默认只读使用
`/home/root/apps/koreader`，也可在安装时显式设置绝对路径 `KOREADER_DIR`。它不打包、
覆盖或写入该程序树，只原子发布适配器目录，并把迁移后的可写数据提交到
`/home/root/.local/share/remagic-koreader/data`。安装前会完成源文件、目标类型、
root 权限和运行进程检查；适配器及数据先在同盘 staging tree 中完成。失败会立即
恢复旧目录，断电留下的 journal 会在下一次安装时幂等恢复；symlink、特殊文件和
仍在运行的 KOReader 都会在任何修改前被拒绝。若检测到 Manager bundle 所拥有的
`adapter/program`，独立安装器也会拒绝覆盖其父目录；Manager bundle 仍是推荐部署方式。

安装器会执行一次幂等数据迁移。它使用 `PRAGMA integrity_check`、schema、
`book` 和 `page_stat` 验证阅读统计数据库；损坏或空数据库会先备份并隔离，
再从旧安装中选择阅读记录最完整的有效副本。任何通过验证的当前数据库都不会被
覆盖；当前数据库即使采用迁移器尚不认识的新 schema，也只会保留并报告，绝不
自动降级。`docsettings`、`hashdocsettings`、历史、剪贴板、自定义词典和 OCR 数据
会递归补齐缺失项，不覆盖现有文件。永久迁移备份位于
`/home/root/.local/state/remagic-koreader/backups`，普通安装和卸载不得删除。
活动数据与备份目录的每一级路径都必须是真实目录，树内也不允许 symlink 或特殊
文件；旧目录中的 symlink（包括选定路径的中间父目录）只会被跳过，不会复制进
活动数据树。
旧 Paperweight 目录只作为可选迁移来源，KOReader 启动和运行不依赖 Paperweight。
托管环境由 Remagic bundle 统一升级，因此隐藏上游 OTA 入口；wrapper 不执行
`koreader.sh` 的 OTA 解包循环。上游 `update_once.marker` 会在构建期结清，托管
环境不支持用户自行加入 `0-*` early-once patch。终端插件也被禁用，因为其
`terminal.pid` 使用程序目录相对路径；普通阅读、词典和所有阅读数据仍写入当前
`KO_HOME`。
schema v2 的数据版本仍为 1，并继续调用同一个幂等迁移器；升级不会改变现有
友好书库、阅读位置、`docsettings`、统计数据库或永久备份目录。
迁移锁记录 owner/PID；并发运行会明确失败，SIGKILL 或断电留下的死 PID 锁会在
内核互斥保护下安全回收，不会永久跳过后续修复。

生产 manifest 明确申请普通出站网络，以支持 OPDS、词典等 KOReader 功能；它不
把 runner 的策略元数据冒充成网络沙箱。自动化验收使用独立 manifest，并由
systemd 的 `IPAddressDeny=any` 建立真实断网边界，所以测试不会访问外网或污染
生产阅读数据。

如果 KOReader 正由 Remagic Manager 托管运行，安装器会在修改任何文件前拒绝
安装并提示先从管理器关闭应用；wrapper 在整个生命周期持有共享部署锁，安装器
对同一 inode 持有全事务独占锁，因此进程检查后的并发启动也无法穿过提交边界。
安装器不会越权终止前台或后台 KOReader。

### 私有中文字体

`scripts/stage-custom-fonts.sh` 会在 manager 构建时把以下字体放入 KOReader 的 `fonts/remagic`，KOReader 菜单中显示字体内部名称：

- 上图东观体：常规、粗体、细体三种规格；
- 方正屏显雅宋简体。

字体二进制不提交到公开仓库。默认读取用户提供的下载路径；换机器时可通过 `KOREADER_DONGGUAN_FONT_DIR` 和 `KOREADER_YASONG_FONT` 指定相同文件，脚本会校验 SHA-256 后再打包。
