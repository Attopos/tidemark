# 决策记录

只追加，不改旧条目；推翻旧决定时写一条新的并注明推翻了哪条。

## 2026-11-13 文档进仓库，用 Atlas 汇总

- 背景：希望换 AI 工具后能从断掉的地方立即续上。
- 决定：规则写在 `AGENTS.md`（`CLAUDE.md` 只引用它），进度写在 `STATE.md`，取舍写在 `DECISIONS.md`，和代码一起提交；git hook 督促同步，并自动汇总到 atlas-ac 和 ACdian 的只读 Atlas 模块。
- 放弃的方案：把规则留在某个 AI 工具的设置里（迁移时最容易丢）；在 acdian 里手动维护副本（会和原件不一致）。

## 2026-11-15 iPhone 分析页单独实现

- 决定：iPhone 用新的 PhoneAnalysisView，Mac 仍用 AnalysisView；CashPeriod 增加 week/all/range，Mac 只开放月/年。
- 布局对标 iCost，配色保留 Tidemark 青柠/紫。

## 2026-11-15 iPhone 应用锁与 iCost 格式导出

- 应用锁只在 iPhone，用 LocalAuthentication 的 deviceOwnerAuthentication；开关都要先验证。Mac 的「投资组合锁」是另一回事（只锁投资组合页，iPhone 没有该页），保持不动。
- 导出格式全部取自真实 iCost 导出：表名、21 列与顺序、全文本单元格、支出为负；自写 ZIP+XLSX，不引入依赖。iCost 偶尔写「50.0」这类非规范数字，我们写规范形式，数值相同。

## 2026-11-15 删除标签

- 只删界面、导入和导出里的标签；SwiftData/CloudKit 的 tags 字段保留，避免改模型破坏同步和迁移。导出保留 Tag 列（留空），格式仍与 iCost 一致。

## 2026-11-15 投资组合上 iPhone，功能一致

- 共用一个 AppState、PortfolioSummary（计算）和导入流程，iPhone 只另写布局（PhonePortfolioView）。图片用 PlatformImage 抹平 NSImage/UIImage；拖放和粘贴仅 Mac，iPhone 用相册多选。
- 同步新增资产、持仓、估值三类记录；持仓所在的投资账户不单独同步，按名称+类型在对方设备找或建。服务器结构没有这些类型时只暂停投资组合同步。
- iPhone 自动备份写本机 Documents/Backups（iCloud Drive 根目录需要另开 iCloud Documents 能力）；数据本身已经走 CloudKit。

## 2026-11-15 iPhone 切换标签卡顿

- 真机测得每次切换主线程卡 0.4–0.6 秒：根视图刷新时所有带 @Query 的标签页都重建并重算。用 Equatable 的 StableTab 包住各页，切换只剩 25–110 ms；汇率查找改二分并跳过同币种和零金额。没做共享数据缓存，先看实际体感。

## 2026-11-15 iPhone 自绘页头

- 系统导航栏的边距（16–20pt）改不了，为了让标题和按钮也在 25pt 上，iPhone 全部隐藏系统栏：主页面用共享的 PageTitle，推入的子页和弹窗用 PhoneHeader；隐藏系统栏后靠 UINavigationController 扩展保留右滑返回。

## 2026-11-15 标题按字形对齐

- 文字框贴边时字母本身会因字形左侧留白偏右 1–2pt、因行高顶部留白偏低，所以 PageTitle/PhoneHeader 按字体度量（首字母左侧留白、大写字母高度）补偿，让字母本身落在 25pt 线上；上边距以大写字母顶端为准，i 的点和 l 等升部会略高出。

## 2026-11-15 导出改成 iCost 导入模板

- 推翻当天「导出照 iCost 自己的导出格式」：iCost 帮助文档说它的导出不适合再导入，导入只认模板（file.icostapp.com/icost_template.xlsx）。Tidemark 导出改为模板格式，导入两种都读；转账的具体类型（Lend/Repayment）写在一级分类里以便读回。
- 导入时，指纹不同但「同一秒同类型」且旧指纹已不在文件里的记录视为在 iCost 里改过，原地更新；文件里没有的记录只报告不删除。

## 2026-11-16 录入页共用、同步状态后台写

- iPhone 与 Mac 新增记录都用 QuickEntryView（编辑仍用 TransactionEditor）；输入放进 @Observable EntryInput，按键只重绘键盘；分类统计每次打开读一次。
- 「图片」不存附件（模型没有图片字段，加字段要改 CloudKit 结构），而是截图识别后填入金额、日期、备注、分类。
- 同步轮询无变化时不写 sync-state；写入改到后台串行队列，连续多次只写最新一份。
- 录入页照 iCost 截图 1:1：边距 10pt（不用全局 25pt）、选中色用青柠代替 iCost 的红；右上角在 iCost 是账本，Tidemark 没有账本，改放日期；分类圆圈用按名称匹配的 SF Symbols 线条图标，匹配不到才用 emoji。

## 2026-11-16 字体变轻、变圆

- 用户嫌数字和英文太粗太宽：全 App 改 SF Pro Rounded（根视图 .fontDesign(.rounded)，PageTitle 的字形度量同步用圆体），所有字重降一档（bold→semibold、semibold→medium）。
- 大号金额（≥24pt）用比例数字，列表里的小金额仍用等宽数字以便对齐。圆体没有 condensed 字宽，所以「窄字宽」这一项没做。

## 2026-11-18 账单详情、账户图标、余额对齐 iCost

- 余额差异的根因是 iCost 导出只有账单、没有初始余额和余额调整；不改导入逻辑，按 iCost 截图一次性写入初始余额（只扣已导入账单），iCost 里看不到的账户置 0 归档，导入完成页提示去对账。
- 账户图标按名称/类型自动匹配自绘徽章（品牌色 + 简字/SF Symbols/国旗），不用真实 logo、不加同步字段。
- 详情页的「删除」用紫色而不是 iCost 的红，保持两色系；标签行不做（标签已删除）。

## 2026-11-18 新建账户修正

- 账户按名称参与导入匹配，所以禁止重名；信用/借入账户输入欠款正数、内部存负余额，和列表里显示的「欠款」一致。币种改为列表选择，避免写出 RMB 这类换不了汇率的代码。

## 2026-11-18 开源账户图标、等宽数字

- 自绘徽章被嫌丑，换成 GitHub 上有许可证的 SVG：circle-flags（MIT）、feathermore/Banklogo（MIT）、payment-webfont-cn 与 simple-icons（CC0），银行只裁出徽标部分转 180px PNG；cellier/bank-icon-cn 更全但没有许可证，没用。余额宝没有开源图标，用支付宝字形配橙色。
- 用户要「金融终端式」数字：根视图加 .monospacedDigit()，金额字体一律等宽数字，推翻 11-16「大金额用比例数字」。
- 根视图的 .monospacedDigit() 管不到显式写了 .font(.system(...)) 的文字，所以给所有 .system(size:) 字体都直接加 .monospacedDigit()；DS.money 去掉字重参数，金额只有一种字重；投资组合格子和饼图的「¥32.5k」改成完整金额。
