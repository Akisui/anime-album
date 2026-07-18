# AnimeAlbum

<p align="center">
  <b>English</b> ·
  <a href="#-日本語">日本語</a> ·
  <a href="#-中文">中文</a>
</p>

A photo album app for collecting anime character images, built to feel as close as possible to Apple's native **Photos** app. iOS / iPadOS 18+, SwiftUI + SwiftData.

---

## 🇬🇧 English

### Overview

AnimeAlbum is a dedicated album for anime character pictures. It has a photo stream, user-created albums, drag-to-reorder inside albums, and a full-screen viewer — all tuned to match the native Photos experience.

### Features

- **Library** — photo grid, import from the system Photos picker and from Files, SHA-256 de-duplication, multi-select, delete.
- **Albums** — create / rename / delete, add & remove photos, set a cover, and **drag-to-reorder** powered by `UICollectionView` (the same technology the native Photos app uses) for a truly native feel.
- **Viewer** — a hand-built zoom transition (image grows from its grid cell), paging, pinch / double-tap zoom, pull-to-dismiss, and an immersive top bar that fades or slides depending on context.
- **Gap-based ordering** — album order uses fractional indices, so dragging one photo writes a single record — conflict-friendly for future iCloud sync.
- **CloudKit-ready data model** — the SwiftData schema already follows CloudKit constraints, paving the way for V2 sync.

### Tech stack

- SwiftUI (with targeted UIKit bridges for the reorderable grid and the zoomable image view)
- SwiftData, modeled to stay CloudKit-compatible
- No third-party dependencies

### Build & run

Requires Xcode 16+ and an iOS 18 simulator or device.

```bash
open AnimeAlbum.xcodeproj   # then press ⌘R
```

### Roadmap

- **V2** — iCloud sync across devices (private CloudKit database)
- **V3** — PDF support (import & page-by-page browsing)
- **V3+** — automatic character classification (on-device Vision / Core ML)

---

## 🇯🇵 日本語

### 概要

AnimeAlbum は、アニメキャラクターの画像を集めるための専用アルバムアプリです。写真ストリーム、ユーザー作成のアルバム、アルバム内でのドラッグ並べ替え、全画面ビューアを備え、すべて iOS 標準の「写真」アプリに限りなく近い操作感を目指しています。iOS / iPadOS 18 以上、SwiftUI + SwiftData。

### 機能

- **ライブラリ** — 写真グリッド、システムの写真ピッカーおよびファイルからのインポート、SHA-256 による重複排除、複数選択、削除。
- **アルバム** — 作成 / 名称変更 / 削除、写真の追加・削除、カバー設定、そして `UICollectionView`（標準「写真」アプリと同じ技術）によるネイティブそのものの**ドラッグ並べ替え**。
- **ビューア** — 自作のズーム遷移（グリッドのセルから画像が拡大）、ページめくり、ピンチ / ダブルタップでのズーム、下スワイプで閉じる、文脈に応じてフェードまたはスライドする没入型トップバー。
- **すきま順序（fractional indexing）** — アルバムの並び順は小数インデックスで管理。写真を 1 枚動かしても書き込みは 1 レコードだけ。将来の iCloud 同期でも競合しにくい設計です。
- **CloudKit 対応のデータモデル** — SwiftData のスキーマは最初から CloudKit の制約に準拠しており、V2 の同期にそのまま繋げられます。

### 技術スタック

- SwiftUI（並べ替えグリッドとズーム画像ビューには局所的に UIKit を橋渡し）
- SwiftData（CloudKit 互換を保った設計）
- サードパーティ依存なし

### ビルドと実行

Xcode 16 以上と iOS 18 のシミュレータまたは実機が必要です。

```bash
open AnimeAlbum.xcodeproj   # その後 ⌘R
```

### ロードマップ

- **V2** — 複数端末での iCloud 同期（CloudKit プライベートデータベース）
- **V3** — PDF 対応（インポートとページ単位の閲覧）
- **V3+** — キャラクターの自動分類（オンデバイスの Vision / Core ML）

---

## 🇨🇳 中文

### 概述

AnimeAlbum 是一个专门收藏 anime 角色图片的相册 App。它有照片流、可自建相簿、相簿内可拖拽排序，以及一个全屏查看器 —— 所有交互都尽量对齐 iOS 原生「照片」App 的手感。iOS / iPadOS 18+，SwiftUI + SwiftData。

### 功能

- **图库** — 照片网格，从系统照片选择器和「文件」导入，SHA-256 去重，多选，删除。
- **相簿** — 创建 / 重命名 / 删除、添加与移除照片、设置封面，以及基于 `UICollectionView`（与原生「照片」App 同款技术）的**拖拽排序**，手感与原生一致。
- **查看器** — 自绘的 zoom 过渡（图片从网格单元原位放大）、翻页、捏合 / 双击缩放、下拉关闭，以及按场景淡入淡出或滑动的沉浸式顶部栏。
- **间隙排序（fractional indexing）** — 相簿排序使用小数索引，拖动一张照片只写一条记录 —— 为将来的 iCloud 同步天然抗冲突。
- **CloudKit 兼容的数据模型** — SwiftData 模型从第一天就遵守 CloudKit 约束，为 V2 同步铺好路。

### 技术栈

- SwiftUI（拖拽网格与可缩放图片视图局部桥接 UIKit）
- SwiftData（保持 CloudKit 兼容的建模）
- 零第三方依赖

### 构建与运行

需要 Xcode 16+ 以及 iOS 18 的模拟器或真机。

```bash
open AnimeAlbum.xcodeproj   # 然后按 ⌘R
```

### 路线图

- **V2** — 多端 iCloud 同步（CloudKit 私有数据库）
- **V3** — PDF 支持（导入与按页浏览）
- **V3+** — 角色自动分类（端上 Vision / Core ML）
