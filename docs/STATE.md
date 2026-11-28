# 状态

更新：2026-11-29

## 现在

日常记账用 Tidemark（从 2026-11-16 起）；iCost 导出（2026-11-15，2658 行）已导入，iPhone 与 Mac 同步一致。
配色是「中性黑 + 粉」：底色和卡片用近黑（#0E0D10 / #18161B / #221F26，浅色 #F6F5F7 / 白），文字灰阶，粉和 ACdian 一致，深浅色都是 #D93B86，实心粉只留给主按钮（+、完成、导入）和对冲类资产；分段切换选中用中性 DS.selection，侧栏和日历选中用淡粉底 + 粉字。收支语义色（FlowPalette、DS.positive/negative）：支出和负数粉（#D93B86），收入和正数薄荷绿 #3DD9A0（浅色 #0F9E6E）。token 名（lime=粉、violet=灰）没改。
图标：除账户外全站用无色线条 SF Symbols（灰底圆，无 emoji）。分类图标写在分类名里：开头 \u{E000}符号名\u{E001}（CategoryName.symbol/compose），显示、搜索、编辑框和 iCost 导出都去掉；没有标记的名字按关键词匹配（EntryGlyph）。2026-11-24/25 已两轮迁移存量账单（v2 补了香烟、果汁、牛奶等 34 个二级分类）（CategorySymbolMigration，迁移前备份在 Tidemark Backups/before-category-symbols-20261124）。「设置 › 分类」可新建、改名、换图标（改的是账单上的分类名，随普通同步走），图标库 Resources/CategoryIcons 1466 个；还没记过账的新分类只存本机。投资页指数图标是灰色单色。
App 图标：书签「水位」（粗边框空心书签，下半是浪形水面），颜色取自 ACdian 图标（粉 #D93B86、黑 #141217）：iPhone 浅色粉底黑标，深色黑底粉标，Tinted 黑底中灰标（#8E8E8E，和系统图标亮度相近）；Mac 用粉底版。源文件 Design/AppIcon 四个 SVG，候选方案在 Kombai 画布 cnv_e3314b8399f9。
设置里可选默认支出、收入账户（DefaultAccounts，存本机 UserDefaults），录入页和新建账单优先用它，没设或账户已归档才用上次用的。Mac 设置页照 iPhone 改成圆角卡片 + 彩色小图标行，两端都只留短标题，说明段落已删（只在出错时显示一行）。右下角录入按钮只在 Mac 账本页出现（iPhone 本来就只在账本页）。iPhone 账本页顶部只剩标题和月份切换；隐藏金额的小眼睛放在各页大金额标签旁。点开账单进入「账单详情」（RecordDetailView，iPhone/Mac 共用），点哪一行只改那一项；金额类字段用和录入页同一套计算器（CalculatorPad/CalculatorDisplay，原值预填，先按数字替换、先按运算符接着算，C 清空）。Mac 账本页待报销卡片只留 Claimed。字体 SF Pro Rounded、等宽数字，共用字号表 TS 和卡片组件。
资产页照 iCost 排版，账户图标用开源圆形图标（Resources/AccountIcons，来源见 SOURCES-account-icons.md）；余额已按 iCost 截图对齐（2026-11-18），负债记在「YEB Credit」。

## 下一步

- 用户在 TestFlight 1.1.7 (15) 试账单详情里的金额计算器；iCloud Drive/Tidemark 里 11-16、11-18、11-20、11-29 四个备份是测试假数据（2651 条、0 持仓），等用户同意后删除。
- 用户看分类图标、各设一次默认账户，试分类管理和图标库；「YEB Credit」名字暂定。

## 注意

- 余额对齐前备份在 ~/Library/Application Support/Tidemark Backups/（before-balances-20261118、before-import-20261115）。账户图标没加模型字段，改类型或名称即可换图标。
- 调试开关（仅 Debug）：TIDEMARK_SHOTS（+_ENTRY、_AMOUNTS）、TIDEMARK_ACCOUNT_SEED、TIDEMARK_PERF*、TIDEMARK_IMPORT_TEST。
- 跑测试时 app 宿主用内存库、不写自动备份（TidemarkSchema.isTesting）；以前会用假数据覆盖当天 iCloud 备份。当天备份若比已有文件少 5% 以上（至少 20 条）另存为 -smaller.json，不覆盖。源码不写注释。新增同步类型要先跑 TIDEMARK_SYNC_SCHEMA=1 再到 CloudKit Console 部署。
- 本地快照测试 ZZSnapshotLocal.testRenderLedger 偶尔超时，重跑即过；合并前以 TEST SUCCEEDED 为准。
- 新系统 Vision 会把部分右对齐金额倒着读（如「SL DSL$」），ScreenshotOCRService.reread 对这类行裁剪后重识别；数量里的字母 O/l 按 0/1 修正。
