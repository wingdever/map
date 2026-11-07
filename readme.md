# map — 凤岗·龙岗外卖「最后一公里」自用地图

Flutter App，**Linux + Android 双端并行**（编辑/数据链路主要在 Linux，记录/定位链路主要在 Android；
`libre_location` 只有 Android 实现，Linux 上置灰）。

解决封闭小区 / 城中村「只能走特定门 + 门禁时间管制」的最后一公里问题。
规矩与红线见 [`AGENTS.md`](AGENTS.md)，各章设计见 [`docs/design/`](docs/design/)（01~23 章）。

---

## 仓库原则

**只追踪「第一来源」**：人工编写/审查过的源码、脚本、设计文档。
派生文档（AI 会话记录、进度总账、章节索引）、一次性校验脚本、迁移脚本、
二进制产物、含本机环境的配置 —— 一律不进仓库。

因此 **全新 clone 不能直接构建**，需先本地生成被忽略的产物（见下）。

---

## 首次构建

```bash
# 1) 生成 4 个内置底图包（pubspec.yaml 声明为 asset，缺了 flutter build 直接报错）
#    产物：assets/basemap/t22.{60,70}_114.{10,20}.db（共约 38.5 MB）
python3 tool/basemap_pack/build_packs.py --bundled-only

# 2) 恢复 Android 的二进制构建输入（未入库）：gradle-wrapper.jar + 5 个 ic_launcher.png
flutter create --platforms=android .
#   这一步只补齐缺失的平台骨架，不会覆盖已有的 MainActivity / AndroidManifest / res 中
#   用户改过的文件。也可单独恢复 wrapper：cd android && gradle wrapper --gradle-version 9.3.1

# 3) 常规构建
flutter pub get
flutter run                      # Linux
flutter build apk                # Android
```

> 底图包格式版本与用户库 schema 版本是**两条独立时间线**。
> `assets/basemap/` 之外的全省分卷包由 `tool/basemap_pack/build_packs.py` 生成到
> `basemap_out/`（约 2.1 GB），经 `adb push` 放到设备，不进仓库。
> 格式与打包细节见 `docs/design/10-basemap-packs.md`。

### 关于旧数据库

本项目**只构建最新版本**，不做旧库自动升级，仓库也不保存迁移脚本。
当前版本的完整建表语句（DDL 第一来源）在 `lib/core/schema.dart` 的
`userV12Statements`。遇到旧版本库时 App 会**明确报错并拒绝打开**（不会静默毁库），
处理指引就写在报错文本里（`lib/core/schema.dart`）。

---

## 文档地图

| 文件 | 用途 |
|------|------|
| `AGENTS.md` | **基本交互逻辑**（谁跑命令、怎么问、怎么交付）；只留 §0~§7 编号骨架 |
| `docs/design/01~23-*.md` | 各章设计（**第一文档**，改动前先读对应章节） |
| `docs/requirements.md` | 定位功能原始需求 |
| `lib/core/` | 纯 Dart 领域层（零第三方依赖），业务算法与领域划分都在这里 |
| `lib/data/` | DAO / 引擎层；`lib/features/` 是 UI |
| `tool/` | 生成与校验脚本（`basemap_pack/`、`osm_prep/`、`pbf_extract/`） |
| `docs/agent/` | 项目状态、代码风格、领域红线、会话记录（**本地保留、不追踪**） |

> `AGENTS.md` 已按「只负责基本交互逻辑」重写：项目定位、代码风格、35 条领域红线
> 全部迁到 `docs/agent/`（`PROJECT.md` / `CODE-RULES.md` / `MIGRATION-NOTES.md`）
> 并随该目录忽略。因此**公开 clone 里没有红线速查**，`AGENTS.md` §4/§5/§6 只是占位编号；
> 本地维护者动手前请先读 `docs/agent/CODE-RULES.md`。
> `docs/design/` 里有约 22 处引用 `AGENTS.md §1/§2/§3/§4`，故编号保留不改。

---

## 约定（摘要；交互规约见 `AGENTS.md`，项目规则见 `docs/agent/CODE-RULES.md`）

- **不写测试**：`test/` 不维护、不运行；验收靠 `dart analyze lib/` 与真机 `flutter run` 手工实测。
- **schema 变更**：只改 `lib/core/schema.dart` 的 DDL 与 `schemaVersion`；不做程序内数据迁移，
  但「旧库版本不匹配必须明确报错」的守卫保留。
- **数据不能丢**：真库只有 Linux 那份，动 schema 前先 `cp` 一份 `.bak`。
- 所有命令由开发者本人执行，命令清单与期望输出见各章末节。

---

## License

GNU General Public License v3.0 — see `LICENSE`.
