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
