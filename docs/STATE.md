# 状态

更新：2026-11-21

## 现在

日常记账用 Tidemark（从 2026-11-16 起）；iCost 导出（2026-11-15，2658 行）已导入，iPhone 与 Mac 同步一致。
App 图标换成黑粉配色（参照 ACdian）：黑底粉色缺口圆环 + 环内一道浪。源文件在 Design/AppIcon（ios、ios-dark、ios-tinted、mac 四个 SVG），PNG 由 SVG 渲染后放进 AppIcon.appiconset。
iPhone 账本页顶部只剩标题和月份切换；隐藏金额的小眼睛放在各页大金额标签旁。点开账单进入「账单详情」（RecordDetailView，iPhone/Mac 共用），点哪一行只改那一项。
资产页照 iCost 排版，账户图标用开源圆形图标（Resources/AccountIcons，来源见 SOURCES-account-icons.md）；余额已按 iCost 截图对齐（2026-11-18），负债记在「YEB Credit」。
字体 SF Pro Rounded、等宽数字，全站共用字号表 TS 和卡片组件（DesignSystem/TypeScale.swift、Cards.swift，Mac ×1.08）。
录入页一次入账主线程卡顿约 0.14 秒（2026-11-20 真机）。导出仍是 iCost 导入模板（10 列），导入两种格式都读。

## 下一步

- 用户在 iPhone 上看新图标（TestFlight）在主屏、深色和着色模式下的效果，再决定是否细调；年轮方向的备选方案还在讨论。
- 用户在 iPhone 上看一遍详情页、资产页、字体和录入手感；「YEB Credit」名字暂定。
- 收起录入面板的第一帧仍有约 100 ms（系统模糊和阴影），没再动。

## 注意

- 余额对齐前备份在 ~/Library/Application Support/Tidemark Backups/（before-balances-20261118、before-import-20261115）。账户图标没加模型字段，改类型或名称即可换图标。
- 调试开关（仅 Debug）：TIDEMARK_SHOTS（+_ENTRY、_AMOUNTS）、TIDEMARK_ACCOUNT_SEED、TIDEMARK_PERF*、TIDEMARK_IMPORT_TEST。
- 源码不写注释。新增同步类型要先跑 TIDEMARK_SYNC_SCHEMA=1 再到 CloudKit Console 部署。
- 本地快照测试 ZZSnapshotLocal.testRenderLedger 偶尔超时，重跑即过；合并前以 TEST SUCCEEDED 为准。
