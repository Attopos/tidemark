# 状态

更新：2026-11-21

## 现在

日常记账用 Tidemark（从 2026-11-16 起）；iCost 导出（2026-11-15，2658 行）已导入，iPhone 与 Mac 同步一致。
主色调换成用户给的 MP088 配色：草莓粉 #FF5C8D 为主色（收入、正数、选中），蓝灰 #85A3B2/#4F7183 为辅色（支出、负数），深色底 #142030/#1A2A38/#1E3442，浅色底偏暖 #F4EDE6，文字 #142030 / #F4EDE6。只改了 DS 色值（Theme、Bento）和资产类别、账本、账户预设里的硬编码色，token 名（lime、violet）没改。
App 图标：黑底粉色缺口圆环 + 浪（Design/AppIcon 四个 SVG 渲染成 PNG），Mac 本机已重装为新图标；图标仍是 ACdian 的 #D93B86/#141217，未跟主色统一。
iPhone 账本页顶部只剩标题和月份切换；隐藏金额的小眼睛放在各页大金额标签旁。点开账单进入「账单详情」（RecordDetailView，iPhone/Mac 共用），点哪一行只改那一项。
资产页照 iCost 排版，账户图标用开源圆形图标（Resources/AccountIcons，来源见 SOURCES-account-icons.md）；余额已按 iCost 截图对齐（2026-11-18），负债记在「YEB Credit」。
字体 SF Pro Rounded、等宽数字，全站共用字号表 TS 和卡片组件（DesignSystem/TypeScale.swift、Cards.swift，Mac ×1.08）。
录入页一次入账主线程卡顿约 0.14 秒（2026-11-20 真机）。导出仍是 iCost 导入模板（10 列），导入两种格式都读。

## 下一步

- 用户看新配色和新图标（Mac 已装；iPhone 新配色还没发 TestFlight），决定图标是否改用 #FF5C8D/#142030 与主色统一。
- 用户在 iPhone 上看一遍详情页、资产页、字体和录入手感；「YEB Credit」名字暂定。
- 收起录入面板的第一帧仍有约 100 ms（系统模糊和阴影），没再动。

## 注意

- 余额对齐前备份在 ~/Library/Application Support/Tidemark Backups/（before-balances-20261118、before-import-20261115）。账户图标没加模型字段，改类型或名称即可换图标。
- 调试开关（仅 Debug）：TIDEMARK_SHOTS（+_ENTRY、_AMOUNTS）、TIDEMARK_ACCOUNT_SEED、TIDEMARK_PERF*、TIDEMARK_IMPORT_TEST。
- 源码不写注释。新增同步类型要先跑 TIDEMARK_SYNC_SCHEMA=1 再到 CloudKit Console 部署。
- 本地快照测试 ZZSnapshotLocal.testRenderLedger 偶尔超时，重跑即过；合并前以 TEST SUCCEEDED 为准。
