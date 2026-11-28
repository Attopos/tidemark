# Tidemark

刻意做小的原生 macOS / iPhone 应用：显示你拥有什么，以最后一次核对时为准。支付宝基金截图本机 OCR 读取持仓，逐项确认后保存为带日期的快照，从不预测或插值。Swift、SwiftUI、Swift Charts、SwiftData、Vision，无第三方依赖。

开工前先读 `docs/STATE.md`（做到哪、下一步）；需要背景时读 `docs/DECISIONS.md`。功能说明见 `README.md`。

## 构建

- `./build.sh build | test | run | clean`，`test` 在本机 Mac 上跑（不用模拟器）；`./build.sh testflight` 归档并上传 iPhone 版。
- 不要构建进同步文件夹：DerivedData 用 `~/Library/Caches/tidemark-dd`。

## 规则

- 新分支命名 `feature/attopos/<简短描述>`；不开 PR，在 Mac 上构建、测试通过后自动更新文档、合进 `main` 并 push，不用再问。
- 不用模拟器，也不再装 iPhone 真机测试（2026-11-29 起）：Mac 上测试通过就合进 main，用 `./build.sh testflight` 发 TestFlight（脚本自己加 build 号并提交，不要手动改），不用再问；每次 build 或测试后立即关闭模拟器、删除构建中间文件。
- commit 和 PR 里不加 Co-Authored-By、Claude-Session 等署名行。
- 代码里尽量不写注释，除非是特别关键的功能。
- Tidemark/Resources 下的文件打包时会被拍平到 app 根目录，文件名必须全局唯一（例如来源说明写成 SOURCES-<目录>.md），否则 Debug 能编过、TestFlight 归档会报 Multiple commands produce。
- 测试宿主就是真 app：凡是启动时会写文件、跑迁移、改数据库的逻辑，都要用 TidemarkSchema.isTesting 挡住，否则 `./build.sh test` 会动到真实数据和 iCloud 备份。
- 合并前先确认 `./build.sh test` 的结果真是 TEST SUCCEEDED，不要把 `test | grep` 直接用 `&&` 接合并（grep 总是成功）；被 gitignore 的本地测试文件（TidemarkTests/ZZLocal*）也会参与编译，改公共 API 时一起改。

## 文档同步

- 每次修改在同一个提交里更新 `docs/STATE.md`；做了取舍就在 `docs/DECISIONS.md` 末尾追加一条。纯格式化、依赖升级等可在提交说明里写 `[skip-state]`。
- `docs/STATE.md` 每次整份重写，不往后追加：只写现在、下一步、注意三节，保持在 25 行以内（超出时 commit-msg hook 会提醒）。做完的细节写进提交说明，取舍写进 `docs/DECISIONS.md`（只追加，每条不超过四行）。测试记录这类越积越多的文件只留最近几个版本，更早的移到 `docs/archive/`。
- 这三份文档会自动同步到 Atlas（`~/Developer/atlas-ac`，github.com/Attopos/atlas-ac）和 ACdian 的 Atlas 模块，那边只读，只在这里改。
- 出了错或被纠正，把教训补进本文件的规则。
