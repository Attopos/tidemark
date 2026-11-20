# 状态

更新：2026-11-20

## 现在

日常记账用 Tidemark（从 2026-11-16 起）；iCost 导出（2026-11-15，2658 行）已导入，iPhone 与 Mac 同步一致。 iPhone 账本页顶部只剩标题和右上角的月份切换（‹ 月份 › + 日历），截图导入和搜索已删（截图识别仍在录入页「图片」）；隐藏金额的小眼睛统一放在各页大金额的标签旁（账本「支出」、资产「净资产」、分析和投资卡片标题旁），页面标题栏不再放眼睛。
点开任一账单进入「账单详情」（照 iCost）：编辑/删除 + 分组卡片（类型、账本、日期、金额、币种、账户、备注、图片、地址、优惠/退款/手续费/报销、不计入开关），iPhone 和 Mac 共用 RecordDetailView。 点哪一行只改那一项（RecordFieldEditor：类型选分类、日期、金额、币种、账户带图标、到账、备注、地址、优惠/退款/手续费、报销），转账的类型和「编辑」按钮仍打开完整编辑器。 录入页账户用 AccountIcon，点开是带图标的账户列表（AccountPickerSheet）。
资产页照 iCost 排版：净资产卡、借入/借出、分组「资金账户 (n)」+ 余额；账户图标用开源圆形图标（Resources/AccountIcons，来源和许可证见 SOURCES-account-icons.md）：各大银行徽标、微信/支付宝/Visa 等、各币种现金用圆形国旗，按名称和类型匹配，匹配不到用首字母。
账户余额已对齐 iCost 截图（2026-11-18）：iCost 导出不带初始余额，所以按「iCost 余额 − 已导入账单」写入各账户的初始余额；iCost 资产页里没有的账户余额置 0 并归档；负债 ¥267.29 记在新建的信用账户「YEB Credit」。Tidemark 里 11-15 之后的新账单照常叠加（YEB 因此比 iCost 少 ¥322.41）。
新建账户照 iCost 分两步（AccountEditor.swift）：先「选择类型」（45 种，资金/信用/储值/借出/借入分组，带图标），再填分组卡片表单（名称、余额或欠款、币种、卡号、类型、描述、信用卡额度和账单日），名称实时匹配银行图标；编辑用同一张表单。重名不能保存，信用/借入填欠款正数。
字体：SF Pro Rounded，全 App 数字统一：所有字体等宽数字、金额一律 DS.money 常规字重、完整写法（¥32,451.48，不用 k），只有图表坐标轴用简写；字重再降一档（semibold→medium，medium→regular）；iPhone 边距 25pt、分组标题与卡片左对齐、滚动条隐藏。 iPhone 分析页更紧凑：卡片字号约 ×0.88、内边距约 ×0.78、图表高度 165/205pt（PhoneCard 与投资页共用，投资页卡片标题也随之变小）。
录入页性能（2026-11-20 真机，所有标签页都打开过）：一次入账主线程卡顿从约 4.2 秒降到约 0.14 秒；数字键按下即响应。做法：自动备份改后台、同步只扫本次改动的记录、资产/分析页隐藏时不重算（ModelFeed + 结果缓存）、账本只读当前周期的记录、入账在面板收起或「已记 n 笔」徽章动画结束后才写入。动画：数字滚动、按键回弹、再记时卡片轻跳 + 徽章、完成时面板收起后新账单滑入。
导出仍是 iCost 导入模板（10 列），导入两种格式都读，往返测试通过；导入后提示「余额不一致去对账」。

## 下一步

- 用户在 iPhone 上看一遍详情页、资产页、字体和录入手感；「YEB Credit」名字暂定，可改名或改成花呗。
- 收起录入面板的第一帧仍有约 100 ms，是系统渲染背景模糊和阴影，没再动。

## 注意

- 余额对齐前备份：~/Library/Application Support/Tidemark Backups/before-balances-20261118/（Mac 数据库）；导入前备份在 before-import-20261115/。 账户图标没加模型字段（加字段要部署 CloudKit 结构），改类型或名称即可换图标。
- 调试：TIDEMARK_SHOTS 现在也截详情页的三个单项编辑（+TIDEMARK_SHOTS_ENTRY 截录入页）；TIDEMARK_ACCOUNT_SEED（Mac，JSON 按名称设余额/类型/卡号/归档，余额只扣已导入的 iCost 账单）、TIDEMARK_SHOTS（+TIDEMARK_SHOTS_AMOUNTS 显示金额，含详情页截图）、TIDEMARK_PERF*（PERF_ENTRY 会真的存两条 note=perf-probe 的账单再删掉；PERF_TABS=1 先打开所有标签页）、TIDEMARK_IMPORT_TEST，仅 Debug。
- 构建测试通过后直接更新文档、合并进 main 并 push。新增同步类型要先跑 TIDEMARK_SYNC_SCHEMA=1 再到 CloudKit Console 部署。
