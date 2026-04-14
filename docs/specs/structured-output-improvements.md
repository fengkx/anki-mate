# DictionaryEntry 输出结构改进规格书

## 1. 文档范围

本文档列举当前 `DictionaryEntry` / `DictionaryBlock` 输出结构中存在的问题，给出每个问题对应的应用层 use case，并提出改进建议。分为公共 API 路径和私有 API 路径两部分评价，最后给出统一的目标数据模型。

---

## 2. 当前数据模型

```swift
public struct DictionaryEntry: Codable, Equatable {
    public let query: String
    public let headword: String
    public let pronunciations: [String]
    public let entries: [DictionaryBlock]
    public let rawText: String
}

public struct DictionaryBlock: Codable, Equatable {
    public let label: String    // "A", "B", "C" ... 或 ""
    public let kind: String     // "partOfSpeech" | "phrase" | "specialSection" | "reference" | "abbreviation" | "fallback" | "unknown"
    public let name: String     // 词性名 | 短语名 | 特殊段落名 | ""
    public let content: String  // 整段文本
}
```

---

## 3. 公共 API 路径问题清单

### 3.1 [P0] content 未拆分义项 (sense)

**现状**

`content` 字段将所有义项以 `①②③...` 标记混合在一个 string 中。

```json
{
  "name": "noun",
  "content": "noun ① uncountable (brightness) 光亮 guāngliàng▸ by the light of the sun 借着阳光▸ ... ② countable (gleam) 光点 guāngdiǎn▸ she saw a light in the distance ..."
}
```

**受阻的 use case**

| Use Case | 说明 |
|----------|------|
| 义项级折叠/展开 | UI 需要按义项分区渲染，当前必须自行按 `①②③` 正则切割 |
| 义项搜索 | 在释义中搜索关键词并定位到具体义项编号，当前需要先拆分再搜索 |
| 义项计数 | 统计一个词有多少个义项，当前需要正则计数 |
| 单义项卡片 | 闪卡/记忆应用取单个义项展示，当前无法直接索引 |
| 义项级书签/收藏 | 用户收藏某个具体义项而非整个词条，当前缺乏 stable identifier |

**改进建议**

在 `DictionaryBlock` 内引入 `senses: [Sense]` 数组，每个 `Sense` 表示一个编号义项：

```swift
public struct Sense: Codable, Equatable {
    public let number: Int           // 义项编号: 1, 2, 3...
    public let label: String?        // 语义提示: "(brightness)", "(gleam)", nil
    public let countability: String?  // "countable", "uncountable", "countable and uncountable", nil
    public let definition: String    // 释义文本
    public let examples: [String]    // 例句数组
    public let registers: [String]   // ["figurative"], ["informal"], []
}
```

当义项标记不存在时（如简单词条只有一个释义），`senses` 数组只有一个元素且 `number = 1`。

---

### 3.2 [P0] 例句未从释义中分离

**现状**

例句以 `▸` 符号嵌入 content 文本中，与释义混在一起：

```
noun (fruit) 苹果 píngguǒ▸ the apple of sb's eye figurative 掌上明珠▸ there's a bad apple in every bunch 哪儿都有害群之马
```

**受阻的 use case**

| Use Case | 说明 |
|----------|------|
| 例句高亮渲染 | UI 中例句用斜体/不同颜色展示，当前需按 `▸` 手动拆分 |
| 例句单独展示 | 例句卡片、例句列表等场景需要独立的例句数组 |
| 例句搜索 | 仅在例句中搜索某个用法模式 |
| 例句计数/统计 | 统计词典中例句覆盖情况 |
| 例句复制 | 用户长按复制单条例句 |

**改进建议**

在 `Sense` 结构中将 `examples` 作为独立的 `[String]` 数组字段（见 3.1 的建议结构）。公共 API 路径以 `▸` 为分割标记提取例句；HTML 路径从 `span.eg span.ex` 节点提取。

---

### 3.3 [P1] kind 和 name 使用 String 而非类型安全表示

**现状**

`kind` 是 String 类型，取值为 `"partOfSpeech"` / `"phrase"` / `"specialSection"` / `"reference"` / `"abbreviation"` / `"fallback"` / `"unknown"` 这个封闭集合。`name` 在不同 kind 下语义完全不同。

**受阻的 use case**

| Use Case | 说明 |
|----------|------|
| 编译期安全 | 应用层 switch 处理 kind 时无法获得穷举检查，新增类型不会产生编译错误 |
| API 约定稳定性 | String 拼写错误在运行时才暴露 |
| 自文档化 | 新接入的开发者必须查阅文档才能知道 kind 的合法取值 |

**改进建议**

将 `kind` 改为 enum：

```swift
public enum BlockKind: String, Codable {
    case partOfSpeech
    case phrase
    case specialSection   // PHRASAL VERBS, PHRASES, DERIVATIVES, ORIGIN
    case reference        // 交叉引用 (→, see also)
    case abbreviation
    case fallback         // 无法识别结构的兜底
}
```

JSON 序列化时自动输出为对应的 string，保持 JSON 层面的兼容性。

---

### 3.4 [P1] name 和 content 开头信息重复

**现状**

`name` 提取了词性名，但 `content` 开头仍然包含相同的词性名文本：

```json
{
  "name": "noun",
  "content": "noun ① uncountable (brightness) 光亮 ..."
}
```

specialSection 同理：

```json
{
  "name": "ORIGIN",
  "content": "ORIGIN Old English of Germanic origin."
}
```

**受阻的 use case**

| Use Case | 说明 |
|----------|------|
| 直接渲染 content | 如果 UI 已经用 `name` 渲染了标题，再渲染 content 会出现 "noun noun ①..." 的重复 |
| content 作为纯释义消费 | 应用层需要手动去掉 content 开头的 POS/section 名称前缀 |

**改进建议**

`content`（或引入 senses 后的 `definition` 字段）不再包含 `name` 已承载的信息。解析时将 POS 名称和 section 标记从 content 中剥离。

---

### 3.5 [P1] name 字段在不同 kind 下语义歧义

**现状**

| kind | name 含义 | 示例 |
|------|-----------|------|
| `partOfSpeech` | 词性名 | `"noun"`, `"transitive verb"` |
| `phrase` | 短语本身 | `"what about"`, `"very much"` |
| `specialSection` | 段落标题 | `"PHRASAL VERBS"`, `"ORIGIN"` |
| `abbreviation` | 固定值 `"abbreviation"` | `"abbreviation"` |
| `reference` / `fallback` / `unknown` | 空字符串 | `""` |

**受阻的 use case**

| Use Case | 说明 |
|----------|------|
| 通用字段读取 | 应用层不能统一读取 `name` 字段，必须先判断 `kind` 再解读 `name` 的语义 |
| 类型安全的模式匹配 | 无法用类型系统保证"partOfSpeech block 一定有词性名" |

**改进建议**

方案 A（推荐）：不同 kind 使用不同的具名字段：

```swift
// partOfSpeech block
public let partOfSpeech: String  // "noun", "transitive verb"

// phrase block
public let phraseName: String    // "what about"

// specialSection block
public let sectionTitle: String  // "PHRASAL VERBS", "ORIGIN"
```

方案 B：使用 enum with associated value，让类型系统保证正确性：

```swift
public enum DictionaryBlock: Codable, Equatable {
    case partOfSpeech(label: String, pos: String, senses: [Sense])
    case phrase(name: String, senses: [Sense])
    case specialSection(title: String, content: String)
    case reference(target: String)
    case abbreviation(expansion: String)
    case fallback(content: String)
}
```

---

### 3.6 [P1] 发音格式不一致（跨 API 路径）

**现状**

```
公共 API: ["BrE ˈapl", "AmE ˈæp(ə)l"]
私有 API: ["/rən/"]
```

同一个 `DictionaryEntry` 类型，`pronunciations` 的格式因数据来源不同而不同：
- 公共 API 以 `"BrE "` / `"AmE "` 前缀 + 裸 IPA
- 私有 API 以 `/ /` 包裹 + 可能有/无方言前缀

**受阻的 use case**

| Use Case | 说明 |
|----------|------|
| 统一的发音渲染 | UI 组件需要处理两种格式，增加分支逻辑 |
| 按方言过滤 | 只显示美式/英式发音时，两种路径的判断逻辑不同 |
| TTS 输入 | 传给语音合成引擎的 IPA 需要统一去掉前缀和斜杠 |

**改进建议**

引入结构化的发音类型：

```swift
public struct Pronunciation: Codable, Equatable {
    public let dialect: String?    // "BrE", "AmE", nil
    public let ipa: String         // 纯 IPA 不含斜杠和前缀
    public let respelling: String? // 回拼 (HTML 路径可能提供)
}
```

两个 API 路径的解析器统一输出此格式。

---

### 3.7 [P2] 语域/修辞标记 (register) 未结构化

**现状**

`figurative`、`informal`、`formal`、`literary`、`archaic`、`ironic` 等标记嵌入 content 文本中：

```
▸ to contemplate one's navel figurative 陷入冥想
```

```
▸ to go or be out like a light informal (fall asleep quickly) 很快入睡
```

**受阻的 use case**

| Use Case | 说明 |
|----------|------|
| 过滤正式/非正式用法 | 学术场景只显示 formal 用法，口语场景只显示 informal |
| 语域标签渲染 | 用不同颜色/徽章展示 figurative、informal 等标记 |
| 统计分析 | 分析一个词的用法分布（正式 vs 口语 vs 文学） |

**改进建议**

在 `Sense` 层级提取 `registers: [String]` 字段（见 3.1 建议结构）。可识别的标记列表：

```
formal, informal, literary, archaic, dated, rare, humorous,
figurative, ironic, euphemistic, derogatory, offensive,
technical, dialect, vulgar
```

---

### 3.8 [P2] 中文释义与拼音未分离

**现状**

```
光亮 guāngliàng
```

汉字释义和拼音连写在一起。

**受阻的 use case**

| Use Case | 说明 |
|----------|------|
| 纯中文展示 | 简洁模式下只显示汉字 |
| 拼音标注 | 拼音用不同字号/颜色渲染在汉字上方 (ruby annotation) |
| TTS 输入 | 语音合成只需要中文文本 |
| 拼音学习模式 | 遮盖汉字只显示拼音 |

**改进建议**

在释义层级引入可选的拆分：

```swift
public struct Translation: Codable, Equatable {
    public let text: String       // "光亮"
    public let pinyin: String?    // "guāngliàng"
}
```

技术上，拼音通常紧跟汉字后面，以空格分隔，且全部为带声调的拉丁字母。可用启发式规则（汉字序列后紧跟的拉丁带声调音节序列）提取。

> 注意：此项解析难度较高，拼音和英文上下文可能混淆（如人名），建议作为可选增强，提供 `rawDefinition: String` 作为 fallback。

---

### 3.9 [P2] 可数性标记 (countability) 未结构化

**现状**

```
noun ① uncountable (brightness) 光亮 ...
noun ② countable (gleam) 光点 ...
```

`uncountable` / `countable` / `countable and uncountable` 混在 content 文本中。

**受阻的 use case**

| Use Case | 说明 |
|----------|------|
| 语法提示 | 名词义项旁显示 [U] / [C] 标记 |
| 语法练习 | 根据可数性生成填空题 (a/an vs 不加冠词) |
| 过滤 | 只查看可数名词用法 |

**改进建议**

在 `Sense` 层级提取 `countability: String?` 字段（见 3.1 建议结构）。取值：`"countable"` / `"uncountable"` / `"countable and uncountable"` / `nil`。

---

### 3.10 [P2] 解析异常案例 -- elaborate 的 headword 和 name 污染

**现状**

`elaborate` 的输出中，`headword` 被污染：

```json
{
  "headword": "elaborate A. adjective",
  "entries": [
    {
      "name": "transitive verb | bre ɪˈlabəreɪt, ame əˈlæbəˌreɪt | 详尽阐述 ...",
      "label": "B"
    }
  ]
}
```

`headword` 包含了不属于词头的 "A. adjective"，`name` 包含了发音和释义文本。这是 pipe 分割在多发音词条（adjective 读 `/ɪˈlab(ə)rət/`，verb 读 `/ɪˈlabəreɪt/`）上的解析失败。

**受阻的 use case**

| Use Case | 说明 |
|----------|------|
| 基本正确性 | headword 不等于查询词，匹配逻辑失败 |
| name 作为 POS 标签 | name 包含大量无关文本，无法直接用作 UI 标签 |

**改进建议**

公共 API 路径需要处理"同一词条有多组发音"的情况。当 body 部分内嵌额外的 `|` 分割发音时（如 elaborate 的动词发音与形容词发音不同），应识别为词条内发音变体而非顶层 pipe 分割。

---

## 4. 私有 API 路径额外问题

> 以下问题仅存在于私有 API (HTML) 路径，或在该路径表现更突出。第 3 节中的共性问题同样适用于私有 API 路径。

### 4.1 [P1] PHRASES/DERIVATIVES 丢失释义

**现状**

`HTMLParser.swift` 对 `span.subEntryBlock` 只提取了 `span.l` 的短语/派生词名称：

```json
{
  "kind": "specialSection",
  "name": "PHRASES",
  "content": "a run for one's money\nrun dry\nrun high"
}
```

短语的释义、例句全部丢失。对比之下，公共 API 路径至少保留了短语的完整释义文本。

**受阻的 use case**

| Use Case | 说明 |
|----------|------|
| 短语释义展示 | 用户查询 "run" 想看到 "a run for one's money" 的释义，HTML 路径只有名称 |
| 短语学习 | 短语卡片需要释义和例句 |
| 完整性 | 私有 API 本应提供比公共 API 更丰富的信息，此处反而更少 |

**改进建议**

对 `span.subEntry` 内部按与主义项相同的逻辑提取 `span.df`（释义）和 `span.eg span.ex`（例句），输出为结构化的子条目：

```swift
public struct SubEntry: Codable, Equatable {
    public let name: String            // 短语名: "a run for one's money"
    public let definition: String?     // 释义
    public let examples: [String]      // 例句
}
```

---

### 4.2 [P1] label 字段始终为空

**现状**

HTML 路径所有 `DictionaryBlock.label` 都输出 `""`，没有 A/B/C/D 标签。

**受阻的 use case**

| Use Case | 说明 |
|----------|------|
| POS 块排序与标记 | UI 中 "A. noun  B. verb  C. adjective" 的分区展示，HTML 路径没有标签 |
| 两路径输出一致性 | 应用层无法用同一套渲染逻辑处理两个路径的输出 |

**改进建议**

HTML 路径按 POS 块在文档中的出现顺序自动生成字母标签：第 1 个 POS 块为 "A"，第 2 个为 "B"，以此类推。

---

### 4.3 [P2] HTML 中可获取但被丢弃的语法标注

**现状**

NOAD HTML 中包含丰富的语法标注信息，但当前未提取：

| HTML 元素 | 信息 | 当前状态 |
|-----------|------|----------|
| `span.gg` | `[no object]`, `[with object]`, `[with adverbial]` | 丢弃 |
| `span.infg` | 变形: runs, running, ran | 丢弃 |
| `span.sy` | 语法关系: past, past participle | 丢弃 |
| `span.lbl` | 域标签: informal, dated, archaic | 丢弃 |

**受阻的 use case**

| Use Case | 说明 |
|----------|------|
| 语法学习 | 展示动词的及物/不及物用法模式 |
| 变形查询 | 查看一个词的所有变形 (inflections) |
| 高级过滤 | 按正式/非正式、古语/现代语过滤 |

**改进建议**

在 `DictionaryBlock`（partOfSpeech 类型）中增加可选字段：

```swift
public let grammar: String?              // "[no object]", "[with clause]" 等
public let inflections: [String]?        // ["runs", "running", "ran"]
```

---

### 4.4 [P2] 例句格式使用 ad-hoc 分隔符

**现状**

HTML 路径将例句拼接到释义后面，使用 `" | e.g. "` 作为分隔符：

```
move at a speed faster than a walk | e.g. the dog ran across the road
```

**受阻的 use case**

| Use Case | 说明 |
|----------|------|
| 可靠的例句提取 | 如果释义文本本身包含 ` | e.g. ` 字样，解析会误判 |
| 多例句场景 | 只取了第一条例句，HTML 中可能有多条 |

**改进建议**

不在 string 中用分隔符拼接，改为结构化字段（见 3.1 和 3.2 的建议）。HTML 路径对每个 `span.msDict` 提取所有 `span.eg span.ex` 作为 examples 数组。

---

## 5. 目标数据模型

综合以上改进建议，目标结构：

```swift
// MARK: - 顶层

public struct DictionaryEntry: Codable, Equatable {
    public let query: String
    public let headword: String
    public let pronunciations: [Pronunciation]
    public let blocks: [DictionaryBlock]
    public let rawText: String
}

// MARK: - 发音

public struct Pronunciation: Codable, Equatable {
    public let dialect: String?    // "BrE", "AmE", nil
    public let ipa: String         // 纯 IPA 不含斜杠和前缀
    public let respelling: String? // 回拼 (仅 HTML 路径可能提供)
}

// MARK: - 词条块 (方案 A: struct + enum kind)

public enum BlockKind: String, Codable {
    case partOfSpeech
    case phrase
    case specialSection
    case reference
    case abbreviation
    case fallback
}

public struct DictionaryBlock: Codable, Equatable {
    public let label: String          // "A", "B", ... 或 ""
    public let kind: BlockKind
    public let name: String           // POS 名 | 短语名 | section 标题
    public let senses: [Sense]        // 结构化义项 (partOfSpeech / phrase 有值)
    public let content: String?       // specialSection / reference / fallback 的文本内容
    public let grammar: String?       // "[no object]" 等 (仅 HTML 路径)
    public let inflections: [String]? // 变形 (仅 HTML 路径)
}

// MARK: - 义项

public struct Sense: Codable, Equatable {
    public let number: Int
    public let label: String?          // 语义提示: "(brightness)"
    public let countability: String?   // "countable" | "uncountable" | nil
    public let registers: [String]     // ["figurative", "informal"] | []
    public let definition: String      // 纯释义文本 (不含例句、不含 POS 前缀)
    public let examples: [String]      // 例句数组
}

// MARK: - 特殊段落子条目 (PHRASES / PHRASAL VERBS / DERIVATIVES)

public struct SubEntry: Codable, Equatable {
    public let name: String            // 短语/派生词名
    public let definition: String?     // 释义
    public let examples: [String]      // 例句
}
```

### 5.1 JSON 输出对比示例

**当前 -- `light` noun block (截取)**

```json
{
  "kind": "partOfSpeech",
  "label": "A",
  "name": "noun",
  "content": "noun ① uncountable (brightness) 光亮 guāngliàng▸ by the light of the sun 借着阳光▸ ..."
}
```

**目标 -- 同一数据**

```json
{
  "kind": "partOfSpeech",
  "label": "A",
  "name": "noun",
  "senses": [
    {
      "number": 1,
      "label": "(brightness)",
      "countability": "uncountable",
      "registers": [],
      "definition": "光亮 guāngliàng",
      "examples": ["by the light of the sun 借着阳光"]
    },
    {
      "number": 2,
      "label": "(gleam, bright point)",
      "countability": "countable",
      "registers": [],
      "definition": "光点 guāngdiǎn",
      "examples": [
        "she saw a light in the distance 她看见远处有一点亮光",
        "the lights of the city 城市的灯火"
      ]
    },
    {
      "number": 3,
      "label": "(aspect)",
      "countability": "countable",
      "registers": ["figurative"],
      "definition": "角度 jiǎodù",
      "examples": [
        "in a good/favourable/new/different light 从好的/有利的/新的/不同的角度"
      ]
    }
  ]
}
```

---

## 6. 优先级总览

| 优先级 | 编号 | 问题 | 路径 |
|:------:|------|------|------|
| P0 | 3.1 | content 未拆分义项 | 公共+私有 |
| P0 | 3.2 | 例句未从释义分离 | 公共+私有 |
| P1 | 3.3 | kind/name 用 String 非 enum | 公共+私有 |
| P1 | 3.4 | name 和 content 信息重复 | 公共+私有 |
| P1 | 3.5 | name 在不同 kind 下语义歧义 | 公共+私有 |
| P1 | 3.6 | 发音格式不一致 | 跨路径 |
| P1 | 4.1 | HTML 路径 PHRASES 丢失释义 | 私有 |
| P1 | 4.2 | HTML 路径 label 始终为空 | 私有 |
| P2 | 3.7 | 语域标记未结构化 | 公共+私有 |
| P2 | 3.8 | 中文释义与拼音未分离 | 公共+私有 |
| P2 | 3.9 | 可数性标记未结构化 | 公共+私有 |
| P2 | 3.10 | elaborate 等词解析异常 | 公共 |
| P2 | 4.3 | HTML 中语法标注被丢弃 | 私有 |
| P2 | 4.4 | 例句用 ad-hoc 分隔符拼接 | 私有 |

---

## 7. 兼容性说明

- `rawText` 字段应保留，作为应用层的兜底 fallback。
- 如果义项拆分在某些词条上失败（格式不规则），应保留 `fallback` kind，将原始文本放入 `content`，`senses` 为空数组。
- `BlockKind` 使用 `String` raw value，JSON 序列化结果与当前字符串格式兼容。
- 建议在过渡期同时保留 `content: String?` 字段（标记为 deprecated），给消费者迁移时间。
