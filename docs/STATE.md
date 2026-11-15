# 状态

更新：2026-11-15

## 现在

从 2026-11-16 起日常记账改用 Tidemark。iCost 最新导出（2026-11-15 22:21，2658 行）已在 iPhone 上导入并同步到 Mac：两边各 2658 条，最新一条 11-15 11:52，一条在 iCost 里改过的账单（11-09 火车 361→581）被原地更新，没有重复。
iPhone 与 Mac 功能一致、布局不同；五个标签页共用 PageTitle，边距 25pt。投资组合在两端同步。
导入：iCost 导出（21 列）和 iCost 导入模板都能读；先显示「将新增/将更新/已存在/文件中没有」再确认；iPhone 可从「文件」选择，或在 iCost 里把文件分享给 Tidemark。
导出：iCost 的导入模板格式（表 icost_template，10 列中文表头，金额为正数），在 iCost「设置 › 账单导入 › 模板导入」可导入；Mac 设置里也能导出。

## 下一步

- 在 iPhone 的 iCost 里试导入一次 Tidemark 导出的文件，确认分类、账户、转账类型都对。
- 用几天看是否有卡顿或记账流程缺口。

## 注意

- 导入前备份：~/Library/Application Support/Tidemark Backups/before-import-20261115/（Mac 与 iPhone 的数据库、当天 JSON 备份）。
- 改过的账单按「同一秒 + 同类型」匹配后原地更新；文件里没有的旧账单只计数不删除。
- 导出给 iCost 时：退款按净额，地址/优惠/手续费/标签不导出（模板没有这些列）；投资记录和余额调整不导出。
- 构建测试通过后直接更新文档、合并进 main 并 push，不用再问。新增同步类型要先跑 TIDEMARK_SYNC_SCHEMA=1 再到 CloudKit Console 部署。
- 调试：TIDEMARK_PERF / TIDEMARK_SHOTS / TIDEMARK_IMPORT_TEST（devicectl -e），仅 Debug 构建。
