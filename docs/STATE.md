# 状态

更新：2026-11-21

## 现在

日常记账用 Tidemark（从 2026-11-16 起）；iCost 导出（2026-11-15，2658 行）已导入，iPhone 与 Mac 同步一致。
配色是「中性黑 + 粉」：底色和卡片用近黑（#0E0D10 / #18161B / #221F26，浅色 #F6F5F7 / 白），文字灰阶，粉调暗到 #E04A82（浅色 #D63C78），实心粉只留给主按钮（+、完成、导入）和对冲类资产；分段切换选中用中性 DS.selection，侧栏和日历选中用淡粉底 + 粉字。收支语义色（FlowPalette、DS.positive/negative）：支出和负数粉，收入和正数薄荷绿 #3DD9A0（浅色 #0F9E6E）。token 名（lime=粉、violet=灰）没改。
图标：除账户外全站用录入页的无色线条图标（CategoryIcon 走 EntryGlyph，灰底圆，不再显示 emoji，标签也去掉 emoji 前缀）；投资页的指数图标改成灰色单色。
App 图标：黑底粉色缺口圆环 + 浪（Design/AppIcon 四个 SVG 渲染成 PNG），粉色已统一成 #FF3D8A，Mac 本机已重装。
Mac 设置页照 iPhone 改成圆角卡片 + 彩色小图标行，两端都只留短标题，说明段落已删（只在出错时显示一行）。右下角录入按钮只在 Mac 账本页出现（iPhone 本来就只在账本页）。iPhone 账本页顶部只剩标题和月份切换；隐藏金额的小眼睛放在各页大金额标签旁。点开账单进入「账单详情」（RecordDetailView，iPhone/Mac 共用），点哪一行只改那一项。字体 SF Pro Rounded、等宽数字，共用字号表 TS 和卡片组件。
资产页照 iCost 排版，账户图标用开源圆形图标（Resources/AccountIcons，来源见 SOURCES-account-icons.md）；余额已按 iCost 截图对齐（2026-11-18），负债记在「YEB Credit」。

## 下一步

- 用户看新配色和图标（Mac 已装；iPhone 还没发 TestFlight，build 6 是旧粉图标 + 旧青柠界面）。
- 用户在 iPhone 上看一遍详情页、资产页、字体和录入手感；「YEB Credit」名字暂定。

## 注意

- 余额对齐前备份在 ~/Library/Application Support/Tidemark Backups/（before-balances-20261118、before-import-20261115）。账户图标没加模型字段，改类型或名称即可换图标。
- 调试开关（仅 Debug）：TIDEMARK_SHOTS（+_ENTRY、_AMOUNTS）、TIDEMARK_ACCOUNT_SEED、TIDEMARK_PERF*、TIDEMARK_IMPORT_TEST。
- 源码不写注释。新增同步类型要先跑 TIDEMARK_SYNC_SCHEMA=1 再到 CloudKit Console 部署。
- 本地快照测试 ZZSnapshotLocal.testRenderLedger 偶尔超时，重跑即过；合并前以 TEST SUCCEEDED 为准。
