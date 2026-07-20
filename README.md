# Remagic KOReader adapter

独立的 reMarkable Paper Pro Move KOReader 适配层。它复用设备的
`xochitl + paperweight + einkfaceclient` 显示宿主，并向 Remagic Manager
提供一个可注册的前台应用入口。

本项目不包含 KOReader 本体，也不管理 MagicPaper 或 Remagic Manager。

## 安装

将 `scripts/koreader-remagic` 安装到 `/home/root/apps/remagic-koreader/bin/`，
将 `manifests/koreader.toml` 复制到 Remagic Manager 的应用 manifest 目录，
然后执行 `remagicctl reload`。
