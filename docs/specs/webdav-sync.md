# WebDAV 跨设备同步 Spec

## 1. 文档定位

本文档记录 anki-mate 跨设备同步功能的技术选型、架构设计和关键决策。目标场景：用户在多台 Mac 上使用 anki-mate 管理词汇，通过 WebDAV 服务（坚果云、Synology、Nextcloud 等）自动同步数据。

---

## 2. 技术选型

### 2.1 为什么是 WebDAV 而不是 CloudKit

**考虑过的方案：**

| 方案 | 优势 | 否决原因 |
|------|------|---------|
| CloudKit CKSyncEngine | Apple 内置同步逻辑，记录级冲突处理 | 锁死 Apple 生态，需要 macOS 14+，需要 Apple Developer Portal 配置 CloudKit Container |
| CoreData + NSPersistentCloudKitContainer | Apple 最成熟的同步方案 | 需要从 SQLite C API 完全迁移到 CoreData，改动量极大 |
| SwiftData + CloudKit | 比 CoreData 更现代 | 同样需要重写存储层，SwiftData 尚不够成熟 |
| iCloud Drive 文件同步 | 实现简单 | **SQLite 并发写入会导致数据库损坏**（Apple 明确反对） |
| 自建服务器 | 完全可控 | 需要运维、认证系统、运营成本 |
| CRDT | 天然解决冲突 | Swift 生态不成熟，音频 BLOB 不适合 CRDT |

**最终选择 WebDAV：** 不锁生态，用户可以使用任何 WebDAV 服务。代价是需要自己实现同步逻辑，但对于单用户词汇 app 的数据规模，逻辑可以保持简单。

### 2.2 为什么不直接同步 SQLite 文件

WebDAV 是文件级操作，最直觉的做法是直接 PUT/GET 整个 SQLite 文件。但这意味着**文件级 last-writer-wins**——两台设备在两次同步之间各自修改了不同的词，后同步的会覆盖先同步的，丢失另一边的修改。

当前方案使用 **JSON manifest + 记录级 last-writer-wins**，两台设备改了不同的词可以正确合并。只有两台设备改了同一个词时才会取 `updatedAt` 较新的版本。

### 2.3 为什么音频文件单独存储

词的音频 BLOB 是 50–200KB/条，1000 个词的音频总计 50–200MB。如果把音频 base64 编码进 manifest.json：

- manifest 文件会膨胀到几百 MB
- 每次同步都要上传/下载完整 manifest（即使只改了一个词的文本）

所以音频按 **SHA-256 内容寻址** 单独存储在 WebDAV 的 `/audio/` 目录下。manifest 里只记录 `audioRef`（hash 值）。好处：

- 同一音频只上传一次（内容寻址天然去重）
- 日常同步只传 manifest JSON（~500KB/千词）+ 真正变化的音频
- 下载前可通过 HEAD 请求检查是否已存在

---

## 3. 架构设计

### 3.1 同步策略：全量 Manifest + 内容寻址音频

```
设备 A                    WebDAV 服务器                 设备 B
SQLite ──export──→  manifest.json + /audio/   ──import──→ SQLite
       ←─import──                             ←─export──
```

每台设备本地维护自己的 SQLite 数据库。同步时：
1. 从 SQLite 导出全量 manifest（所有记录的元数据）
2. 从 WebDAV 拉取远程 manifest
3. 按 UUID 逐条 diff，last-writer-wins 合并
4. 传输新增/变更的音频文件
5. 推送合并后的 manifest

### 3.2 WebDAV 远程目录结构

```
/anki-mate/
├── manifest.json           # 全量状态快照（所有 collections + words 元数据）
├── manifest.lock           # 简易锁文件（防止两台设备同时写 manifest）
├── audio/
│   └── {前2字符}/{SHA-256}.wav   # 内容寻址音频，前 2 字符分目录防止单目录过多文件
└── backups/
    └── manifest-{ISO8601}.json   # 每次同步前自动备份上一版 manifest
```

### 3.3 Manifest 数据格式

```json
{
  "version": 1,
  "deviceId": "A1B2C3D4-...",
  "lastSyncedAt": 1713350000.0,
  "collections": [
    {
      "id": "uuid",
      "name": "German Vocab",
      "dictionaryName": "de-en",
      "ankiDeckName": "German::Vocab",
      "deckDescription": "...",
      "createdAt": 1713350000.0,
      "updatedAt": 1713360000.0,
      "isDeleted": false
    }
  ],
  "words": [
    {
      "id": "uuid",
      "collectionId": "uuid",
      "normalizedWord": "apple",
      "displayWord": "apple",
      "sourceForm": null,
      "inflectionKind": null,
      "expectedPartOfSpeech": null,
      "lookupStateBase64": "base64...",
      "audioRef": "ab3fc7...sha256hex",
      "createdAt": 1713350000.0,
      "updatedAt": 1713355000.0,
      "lastRefreshedAt": null,
      "isDeleted": false
    }
  ]
}
```

关键字段说明：
- **`audioRef`**：音频数据的 SHA-256 hex。实际音频存在 `/audio/ab/ab3fc7...hex.wav`。为 null 表示无音频。
- **`lookupStateBase64`**：SQLite 中 `lookup_state_json` BLOB 的 base64 编码。只在 `loaded` 状态时才序列化（`pending`/`loading`/`failed` 不同步）。
- **`isDeleted`**：软删除 tombstone。详见 3.6。
- **时间戳**：UNIX epoch doubles，与 SQLite 中的 `REAL` 一致，避免时区歧义。

### 3.4 同步流程

```
1. LOCK      PUT manifest.lock（含 deviceId + lockedAt 时间戳）
             如果已存在且 < 2 分钟 → 中止，等待重试
             如果已存在且 ≥ 2 分钟 → 视为过期锁，强制接管

2. PULL      GET manifest.json（404 = 首次同步，视为空 manifest）

3. MERGE     按 UUID 逐条 diff local vs remote：
             - 仅本地存在 → 保留（后续 push）
             - 仅远程存在 → 写入本地
             - 两边都有 → updatedAt 大的赢

4. AUDIO ↓   对 merge 结果中远程新增/变更的 audioRef：
             GET /audio/xx/xxxx.wav → 写入本地 SQLite BLOB

5. APPLY     在一个 SQLite 事务中批量写入远程变更

6. AUDIO ↑   对本地新增/变更的 audioRef：
             HEAD 检查是否已存在 → 不存在则 PUT

7. PUSH      PUT 合并后的 manifest.json

8. UNLOCK    DELETE manifest.lock

9. BACKUP    PUT manifest 副本到 /backups/（异步，best-effort）
```

### 3.5 冲突解决

**策略：记录级 last-writer-wins on `updatedAt`**

```
对于同一 UUID 的记录：
  remote.updatedAt > local.updatedAt → 取远程版本
  local.updatedAt > remote.updatedAt → 保留本地版本（push 时覆盖远程）
  remote.updatedAt == local.updatedAt → 相同，跳过
```

这个策略的限制：
- 依赖设备本地时钟，如果两台设备时钟有显著偏差，可能导致非预期的覆盖
- 对于单用户个人词汇 app，这是可接受的简化

### 3.6 软删除与 tombstone

引入同步后，`DELETE FROM` 改为**软删除**——`UPDATE SET is_deleted = 1, updated_at = now()`。原因：

- 如果直接删除，远程 manifest 里还有这条记录，下次同步会把它重新拉回来
- 软删除产生一个 tombstone，让合并逻辑知道"这条记录在某台设备上被删了"
- 合并时：如果 tombstone 的 `updatedAt` 比对方的活跃记录新 → 删除传播

**Schema 变更（v6 → v7）：**

```sql
ALTER TABLE collections ADD COLUMN is_deleted INTEGER NOT NULL DEFAULT 0;
ALTER TABLE words ADD COLUMN is_deleted INTEGER NOT NULL DEFAULT 0;
ALTER TABLE words ADD COLUMN audio_hash TEXT;
CREATE TABLE sync_metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
```

所有现有查询加上 `WHERE is_deleted = 0`，对上层代码透明。

未来考虑：tombstone 超过 90 天后可清理，但目前未实现。

### 3.7 锁机制

锁是**建议性的（advisory）**，不是强一致的：

```json
// manifest.lock 内容
{ "deviceId": "A1B2C3D4-...", "lockedAt": 1713350000.0 }
```

规则：
- 锁不存在 → 创建，继续同步
- 锁存在且 < 2 分钟 → 中止同步（另一台设备正在同步）
- 锁存在且 ≥ 2 分钟 → 视为过期（设备崩溃或网络中断留下的死锁），强制接管
- 同步完成后无论成功失败都 DELETE 锁

这不是分布式锁，存在竞态条件。但对于单用户低频操作足够。

---

## 4. 凭据存储

WebDAV 的 server URL、username、password 存储在 **macOS Keychain** 中：

- `kSecClass`: `kSecClassGenericPassword`
- `kSecAttrService`: `"com.anki-mate.webdav"`
- `kSecAttrAccount`: `"webdav-url"` / `"webdav-username"` / `"webdav-password"`

写入采用 upsert 模式：先 `SecItemUpdate`，失败则 `SecItemAdd`。用户可在「钥匙串访问.app」中查看和管理这些条目。

---

## 5. 模块结构

```
Sources/DictKitApp/Sync/
├── SyncEngine.swift          # 同步流程编排（3.4 节描述的完整流程）
├── SyncManifest.swift        # Codable manifest 数据类型（3.3 节的 JSON 结构）
├── SyncMerger.swift          # 纯函数 diff + merge（3.5 节的冲突解决）
├── SyncAudioStore.swift      # 内容寻址音频上传/下载（SHA-256 寻址）
├── SyncScheduler.swift       # 定时（10 分钟）+ NWPathMonitor 网络恢复触发
├── SyncStatus.swift          # @MainActor ObservableObject，UI 绑定同步状态
├── WebDAVClient.swift        # URLSession 封装（GET/PUT/DELETE/MKCOL/HEAD）
├── WebDAVCredentials.swift   # Keychain 凭据读写
└── WordListStore+Sync.swift  # WordListStore 的同步扩展（导出/导入/audio hash）

Sources/DictKitApp/Views/
└── SyncSettingsView.swift    # WebDAV 配置 UI（作为 sheet 从侧边栏弹出）
```

**关键设计：SyncMerger 是纯函数**，输入两个 `SyncManifest`，输出 `MergeResult`（含合并后的 manifest + 需要本地应用的变更 + 需要传输的音频 ref）。不依赖任何外部状态，便于单元测试。

---

## 6. UI 入口

同步状态显示在 **CollectionsSidebarView 底部**：

```
┌─ Sidebar ──────────┐
│ Collections    [+]  │
│ 📁 Collection A     │
│ 📁 Collection B     │
│                     │
│─────────────────────│
│ ☁ Synced 10m ago   │  ← 点击打开 SyncSettingsView sheet
└─────────────────────┘
```

状态图标：
- `checkmark.icloud`（绿色）— 已配置，空闲
- `arrow.triangle.2.circlepath.icloud`（蓝色）— 同步中
- `exclamationmark.icloud`（红色）— 同步出错
- `icloud.slash`（灰色）— 未配置

SyncSettingsView sheet 包含：WebDAV URL / 用户名 / 密码输入、Test Connection 按钮、Sync Now 按钮、同步状态和错误信息。

---

## 7. 已知限制与未来改进

| 项目 | 现状 | 未来改进 |
|------|------|---------|
| Tombstone 清理 | 软删除记录永久保留 | 实现 90 天自动清理 |
| 首次同步大量数据 | 一次性上传所有音频 | 分批上传 + 进度展示 |
| 网络重试 | 失败后等下一个 10 分钟周期 | 指数退避重试 |
| 带宽优化 | manifest 每次全量传输 | 考虑 ETag / If-Modified-Since |
| 坚果云限速 | 未处理 | 尊重 Retry-After header，串行上传加延迟 |
| 多设备时钟偏差 | 依赖本地时钟 | 考虑用 manifest 中的逻辑时钟辅助 |
| 孤儿音频清理 | 未实现 | 对比 manifest 中的 audioRef，清理 /audio/ 中无引用的文件 |
| auto-sync 开关 | UI 上没有 | 在 SyncSettingsView 中加 Toggle |
| iOS 支持 | 仅 macOS | WebDAV 方案天然跨平台，需处理 Keychain 差异 |
