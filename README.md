# Remagic KOReader adapter

面向 reMarkable Paper Pro Move 的独立 KOReader QTFB 适配层。KOReader 由
Remagic Manager 托管，不依赖镇纸、xochitl、Paperweight、einkface 或
`/dev/fb0`。

本项目不包含 KOReader 本体或 QTFB runtime。设备上需要：

- KOReader 本体位于 `/home/root/apps/koreader`；
- Remagic Manager 提供私有的 `/home/root/apps/remagic/shims/qtfb-shim.so` 和 QTFB 服务；
- 本适配器安装到 `/home/root/apps/remagic-koreader/bin/koreader-remagic`。

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

## 安装与检查

```sh
sudo ./scripts/install-device.sh
./scripts/check.sh
```

安装器会执行一次幂等数据迁移。它使用 `PRAGMA integrity_check`、schema、
`book` 和 `page_stat` 验证阅读统计数据库；损坏或空数据库会先备份并隔离，
再从旧安装中选择阅读记录最完整的有效副本。任何通过验证的当前数据库都不会被
覆盖；当前数据库即使采用迁移器尚不认识的新 schema，也只会保留并报告，绝不
自动降级。`docsettings`、`hashdocsettings`、历史等用户数据会递归补齐缺失项，
不覆盖现有文件。永久迁移备份位于
`/home/root/.local/state/remagic-koreader/backups`，普通安装和卸载不得删除。
旧 Paperweight 目录只作为可选迁移来源，KOReader 启动和运行不依赖 Paperweight。
迁移锁记录 owner/PID；并发运行会明确失败，SIGKILL 或断电留下的死 PID 锁会在
内核互斥保护下安全回收，不会永久跳过后续修复。

如果 KOReader 正由 Remagic Manager 托管运行，安装器会在修改任何文件前拒绝
安装并提示先从管理器关闭应用；安装器不会越权终止前台或后台 KOReader。

### 私有中文字体

`scripts/stage-custom-fonts.sh` 会在 manager 构建时把以下字体放入 KOReader 的 `fonts/remagic`，KOReader 菜单中显示字体内部名称：

- 上图东观体：常规、粗体、细体三种规格；
- 方正屏显雅宋简体。

字体二进制不提交到公开仓库。默认读取用户提供的下载路径；换机器时可通过 `KOREADER_DONGGUAN_FONT_DIR` 和 `KOREADER_YASONG_FONT` 指定相同文件，脚本会校验 SHA-256 后再打包。
