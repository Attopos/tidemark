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
