# Tidemark

> A tidemark is the line the water leaves behind: proof of where the level
> stood at a given moment, never a guess at where it is going.

Tidemark is a deliberately small, native macOS app that does one thing: show
what you own, as of the last time you checked. Drop in an Alipay fund
screenshot and on-device OCR reads every holding; you confirm each field
before anything is saved, and every value is kept as a dated snapshot, never
projected or interpolated. Daily bookkeeping stays in iCost.

Built with Swift, SwiftUI, Swift Charts, SwiftData, and the Vision framework.
No Electron, no web views, no third-party dependencies.

## What it does

1. **Portfolio board** — total value in CNY or USD, allocation by risk
   exposure, and the holdings under each exposure. Every number is the whole
   portfolio at one moment: each holding carried from its latest dated
   valuation and converted at today's rate. The board says how much of the
   total is older than a week, shows the unrealized profit the sources
   report, and, if you set target weights in Settings, how far each exposure
   has drifted (flagged once outside the 5/25 rebalancing band).
2. **History** — total value on every day something was valued. Values are
   carried forward between valuations, never interpolated or projected.
3. **Screenshot OCR** (`⌘I`, drag-drop, or paste) — Vision reads an Alipay
   fund list or a Binance asset list; you review every parsed field next to
   the screenshot, then confirm. An existing holding gets a new dated
   valuation (same-day re-imports update in place); an unknown one becomes a
   new entry. Low-confidence fields are flagged. A similar but not identical
   name is only offered as a suggestion. When the screenshot shows an account
   total, it is checked against the rows. Holdings the screenshot no longer
   shows are listed so you can mark them as sold.
4. **Sold holdings keep their history** — "Mark as sold" records a zero
   valuation and takes the holding off the board; past totals stay right, and
   importing the asset again reopens it. Delete is for mistaken entries.

Settings: language (English / 中文 / Español, switching live) and target
allocation. Right-click a holding to change its exposure, rename it, correct
its balance, mark it as sold or delete it.

To work alongside iCost, use macOS
window tiling (Window → Move & Resize → Left & Right, or `fn ⌃ ←` / `fn ⌃ →`).

## Build & run

Requirements: **Xcode 16.4 or newer** (built with Xcode 26.4.1), macOS 15+.

```bash
open Tidemark.xcodeproj   # then press ⌘R
```

> **Note if this folder lives in a cloud-synced location (Google Drive, Dropbox):**
> building *into* a synced folder lets the sync daemon's extended attributes break
> code-signing. Use Xcode's default DerivedData, or pass
> `-derivedDataPath ~/Library/Caches/tidemark-dd` to xcodebuild.

Or use the helper script. This Mac is short on memory and disk, so every
command cleans up when it ends, whether it succeeds, fails, or is stopped
with Ctrl-C, and then prints free disk space (`df -h`):

```bash
./build.sh build   # Debug build
./build.sh test    # run the tests on this Mac (no simulator)
./build.sh run     # build, install to ~/Applications/Tidemark.app, launch
./build.sh clean   # only clean up
./build.sh test --keep   # skip cleanup to debug a build
```

Cleanup deletes `~/Library/Caches/tidemark-dd` (keeping its small
`ModuleCache.noindex` so the next build is faster), Xcode's own
`~/Library/Developer/Xcode/DerivedData/Tidemark-*` when it belongs to this
project, `./build`, and `*.profraw` coverage files. It shuts down any booted
simulator and quits Simulator. `run` deletes intermediates only after the app
is copied to `~/Applications`. Simulator runtimes and devices, the installed
app, its data, and source files are never touched. Tidemark is a macOS app,
so tests always run on the Mac itself.

Tests (OCR layout parser, number extraction, a live Vision round-trip, and the
create-vs-update commit invariant):

```bash
xcodebuild -project Tidemark.xcodeproj -scheme Tidemark \
  -derivedDataPath ~/Library/Caches/tidemark-dd test
```

The real-screenshot test needs three local, git-ignored fixtures in
`TidemarkTests/`: `alipay-fixture-1.webp`, `alipay-fixture-2.webp`, and
`alipay-fixture-expected.json` (the funds and amounts those screenshots show;
the format is documented in `AlipayLiveScreenshotTests.swift`). Without them the
test is skipped; the other OCR/parser/commit tests run independently.

## Data

Everything is stored locally in SwiftData
(`~/Library/Containers/com.tidemark.app/…/default.store`). Builds from before
the rename used the bundle identifier `com.personalfinanceos.app`; to carry that
data over, quit Tidemark and copy `default.store*` from
`~/Library/Containers/com.personalfinanceos.app/Data/Library/Application Support/`
into the same path under `com.tidemark.app`. The schema
still carries the tables of earlier, broader versions of the app (transactions
imported from iCost, FX rate history, import records), so existing databases
open unchanged; the UI reads and writes only assets, holdings, and their
valuation snapshots. FX conversion for non-CNY holdings uses seeded approximate
rates.
