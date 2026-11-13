# Tidemark

刻意做小的原生 macOS / iPhone 应用：显示你拥有什么，以最后一次核对时为准。支付宝基金截图本机 OCR 读取持仓，逐项确认后保存为带日期的快照，从不预测或插值。Swift、SwiftUI、Swift Charts、SwiftData、Vision，无第三方依赖。

开工前先读 `docs/STATE.md`（做到哪、下一步）；需要背景时读 `docs/DECISIONS.md`。功能说明见 `README.md`。

## 构建

- `./build.sh build | test | run | clean`，`test` 在本机 Mac 上跑（不用模拟器）；`./build.sh testflight` 归档并上传 iPhone 版。
- 不要构建进同步文件夹：DerivedData 用 `~/Library/Caches/tidemark-dd`。

## 规则

- 新分支命名 `feature/attopos/<简短描述>`；不开 PR，在 Mac 上构建、测试通过后合进 `main` 并 push。
- 不用模拟器，直接装真机测试；每次 build 或测试后立即关闭模拟器、删除构建中间文件。
- commit 和 PR 里不加 Co-Authored-By、Claude-Session 等署名行。
- 代码里尽量不写注释，除非是特别关键的功能。

## 文档同步

- 每次修改在同一个提交里更新 `docs/STATE.md`；做了取舍就在 `docs/DECISIONS.md` 末尾追加一条。纯格式化、依赖升级等可在提交说明里写 `[skip-state]`。
- `docs/STATE.md` 每次整份重写，不往后追加：只写现在、下一步、注意三节，保持在 25 行以内（超出时 commit-msg hook 会提醒）。做完的细节写进提交说明，取舍写进 `docs/DECISIONS.md`（只追加，每条不超过四行）。测试记录这类越积越多的文件只留最近几个版本，更早的移到 `docs/archive/`。
- 这三份文档会自动同步到 Atlas（`~/Developer/atlas-ac`，github.com/Attopos/atlas-ac）和 ACdian 的 Atlas 模块，那边只读，只在这里改。
- 出了错或被纠正，把教训补进本文件的规则。
