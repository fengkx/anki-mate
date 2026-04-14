# Structured Output Final Spec

## 1. 文档定位

本文档是 V3（完整问题清单与落地设计）和 V3.1（contract 收敛修订）的合并最终版。

目标：

- 以实际 fixture 数据（359 text + 4 HTML）为依据
- 以 CLI 查词 + Anki 闪卡生成为主要场景，为 library / app 留扩展空间
- 类型数量控制在 ~14 个（9 struct + 5 enum），不引入当前数据无法填充的字段
- 每个设计决策附带问题描述、受阻 use case、具体改进
- 所有 contract 承诺可直接签约，不依赖隐式规则

---

## 2. 当前数据模型

```swift
public struct DictionaryEntry {
    public let query: String
    public let headword: String
    public let pronunciations: [String]
    public let entries: [DictionaryBlock]
    public let rawText: String
}

public struct DictionaryBlock {
    public let label: String   // "A", "B" ... 或 ""
    public let kind: String    // "partOfSpeech" | "phrase" | "specialSection" | ...
    public let name: String    // 词性名 | 短语名 | 段落名 | ""
    public let content: String // 整段未拆分文本
}
```

两个类型，4+4 个字段。简单但对应用层来说几乎无法直接消费。

---

## 3. 设计原则

### 3.1 建模词典领域，而非解析过程

消费者关心的是：词性、义项、例句、短语、词源。不关心 `fallback` / `unknown` / `specialSection` 这些解析器概念。

### 3.2 两条路径，一套输出

公共 API（英汉词典）和私有 API（NOAD 英英）使用同一组类型。字段可以为 nil（数据源不提供），但字段语义不能因来源而异。

### 3.3 只建模能稳定填充的字段

如果一个字段在 95% 的词条中为 nil（如 `AudioResource`），就不加入。等有真实数据源时再扩展。

### 3.4 结构化到义项级别，不追求更细

义项（Sense）是应用层最常操作的粒度。义项内部的释义文本保持为 String，不再拆分中文/拼音（技术难度高，收益有限）。

### 3.5 contract 可直接消费，不依赖隐式规则

消费者不应需要阅读文档才知道如何正确使用一个字段。数据 contract 本身应自洽：每个字段的语义在任何情况下都一致。

---

## 4. 问题清单与改进

### 4.1 [P0] content 未拆分义项

**现状**

所有义项（`①②③`）混在一个 `content: String` 中：

```json
{
  "name": "noun",
  "content": "noun ① uncountable (brightness) 光亮 guāngliàng▸ by the light of the sun ... ② countable (gleam) 光点 ..."
}
```

公共 API 的 359 个 fixture 全部是这种扁平 `①②③` 格式。HTML 路径有 `span.se2` 子义项但数量极少。

**受阻 use case**

| Use Case | 说明 |
|----------|------|
| Anki 闪卡生成 | 一张卡片对应一个义项，当前必须自行按 ①②③ 正则切割 |
| 义项折叠/展开 | UI 按义项分区渲染 |
| 义项搜索 | 定位到具体义项编号 |
| 义项计数 | 统计多义词的义项数 |

**改进**

引入 `Sense` 类型，按 `①②③` 切割为数组。义项内不再做子义项递归（数据不支持稳定提取）。

---

### 4.2 [P0] 例句未从释义中分离

**现状**

例句以 `▸` 嵌入文本中。HTML 路径用 `" | e.g. "` 拼接。

```
(brightness) 光亮 guāngliàng▸ by the light of the sun 借着阳光▸ the light is too bright 光线太亮
```

**受阻 use case**

| Use Case | 说明 |
|----------|------|
| Anki 例句字段 | 闪卡需要独立的例句字段 |
| 例句高亮 | UI 中例句用不同样式 |
| 例句搜索 | 在例句中搜索用法模式 |
| 例句复制 | 单独复制一条例句 |

**改进**

`Sense.examples: [String]`。公共 API 按 `▸` 切割；HTML 路径按 `span.eg span.ex` 提取。

---

### 4.3 [P0] 空数组和 nil 无法区分"没有数据"和"没有解析出来"

**现状**

大量字段用 `[]` 或 `nil` 来表达所有"无值"场景：

- `Sense.examples: []`
- `LexicalEntry.grammar: []`
- `phraseGroups: []`

这会混淆三种完全不同的情况：

1. 源数据里确实没有该信息
2. 当前 lookup 路径不提供该信息
3. 源数据可能有，但解析器当前没有成功提取

**受阻 use case**

| Use Case | 说明 |
|----------|------|
| CLI 输出 | 无法告诉用户"该字段不存在"还是"当前来源未提供" |
| Anki 导出 | 无法决定空字段是否应该 fallback 到 raw/source |
| 回归测试 | 无法识别"解析质量下降但结果仍合法"的退化 |
| 多源调试 | `automatic` 选择了哪条路径、丢了哪些结构化信息，调用方不可见 |

**改进**

不引入完整 `ParseDiagnostic`，只增加一个轻量 metadata/warnings 层：

```swift
public struct LookupMetadata: Codable, Equatable, Sendable {
    public let usedSource: LookupSourceKind
    public let warnings: [String]
}

public enum LookupSourceKind: String, Codable, Sendable {
    case publicAPI
    case privateHTML
}
```

**实现建议**

- 第一阶段 warning 只使用固定 code（String），不做复杂 severity 分级
- 仅在以下情况写 warning：
  - 使用 `automatic` 后发生 source fallback：`"source_fallback"`
  - phrase group 只能保留原始文本：`"phrase_group_unstructured"`
  - sense/example/pronunciation 解析发生明显降级：`"sense_parse_degraded"`

成本低，但已足够让消费者做正确判断。

---

### 4.4 [P0] `PhraseGroup` 的 graceful degradation 会制造伪结构化数据

**现状**

公共 API 路径无法逐个拆短语时，如果构造一个 `PhraseItem` 将整段文本填入 `phrase` 字段、`definition = nil`，则字段在类型上看似结构化，语义上却不是"一个短语条目"。

**受阻 use case**

| Use Case | 说明 |
|----------|------|
| Anki 短语卡 | 会生成标题为整段原文的坏卡片 |
| 短语计数 | 一个大段文本被误算成 1 个短语 |
| 短语搜索/过滤 | `phrase` 字段不再具有"短语名"的稳定语义 |
| UI 展示 | 调用方无法判断这组 items 是否真的可逐项展示 |

**改进**

`PhraseGroup` 同时支持 structured 和 unstructured 两种状态：

```swift
public struct PhraseGroup: Codable, Equatable, Sendable {
    public let title: String
    public let items: [PhraseItem]
    public let rawContent: String?
}
```

约束：

- `items` 非空时，`rawContent` 应为 `nil`
- `rawContent` 非 `nil` 时，`items` 应为空数组

**实现建议**

- HTML 路径优先填 `items`
- 公共 API 路径在无法稳定拆分时，保留 `rawContent`
- 同时在 `metadata.warnings` 中追加 `"phrase_group_unstructured"`

---

### 4.5 [P0] `PartOfSpeech.other("transitive verb")` 丢失基础词性

**现状**

将 `transitive verb` / `intransitive verb` / `modal verb` 等整体塞进 `.other(String)`，会把"这是 verb"这个最基础的信息丢掉。

**受阻 use case**

| Use Case | 说明 |
|----------|------|
| 渲染分组 | UI 想把 noun / verb / adjective 分组展示 |
| 语法规则 | 只有 noun 才渲染 `[C]/[U]`，只有 verb 才渲染语法模式 |
| JSON 消费 | 下游程序无法可靠筛选所有 verb |
| 搜索/统计 | 统计词性分布时，compound POS 被散落到 `.other` |

**改进**

把"基础词性"和"原始 POS 描述"分开：

- `partOfSpeech: PartOfSpeech` — 基础词性 enum（`.verb`）
- `partOfSpeechLabel: String` — 词典原始标签（`"transitive verb"`）

`PartOfSpeech` 定义为无关联值的 `String` raw value enum：

```swift
public enum PartOfSpeech: String, Codable, Sendable {
    case noun, verb, adjective, adverb, pronoun,
         determiner, preposition, conjunction,
         interjection, article, abbreviation, other
}
```

**实现建议**

- 从现有 parser 的 POS 检测结果映射出基础词性
- 映射失败时：`partOfSpeech = .other`, `partOfSpeechLabel = 原始文本`

---

### 4.6 [P1] `DictionaryBlock` 是万能桶

**现状**

noun block、ORIGIN block、cross reference 共用同一个 struct，靠 `kind` string 区分。`name` 字段语义不一致（词性名 / 短语名 / 段落标题 / 空），一半字段只对部分 kind 有意义。

**受阻 use case**

| Use Case | 说明 |
|----------|------|
| 类型安全消费 | 无法用编译器保证 "partOfSpeech block 一定有词性名" |
| 代码可读性 | 新开发者无法从类型签名理解数据结构 |

**改进**

将 `DictionaryBlock` 拆分为三个不同类型：

- `LexicalEntry`：一个词性块
- `PhraseGroup`：短语/动词短语/派生词组
- `Note`：词源、用法说明、交叉引用

---

### 4.7 [P1] name 和 content 信息重复

**现状**

```json
{ "name": "noun", "content": "noun ① uncountable ..." }
{ "name": "ORIGIN", "content": "ORIGIN Old English ..." }
```

**受阻 use case**

| Use Case | 说明 |
|----------|------|
| 直接渲染 | UI 用 name 做标题后，content 开头重复 |
| Anki 字段 | 释义字段不应包含词性前缀 |

**改进**

`Sense.definition` 不再包含 POS 名称前缀。`Note.content` 不再包含 section 标题前缀。解析时剥离。

---

### 4.8 [P1] 发音格式跨路径不一致

**现状**

```
公共 API: ["BrE ˈapl", "AmE ˈæp(ə)l"]       — 前缀 + 裸 IPA
私有 API: ["/rən/"]                            — 斜杠包裹，无方言前缀
```

**受阻 use case**

| Use Case | 说明 |
|----------|------|
| 统一渲染 | UI 组件需要处理两种格式 |
| TTS | IPA 需要统一去掉前缀和斜杠 |
| 按方言过滤 | 判断逻辑因路径而异 |

**改进**

引入 `Pronunciation` struct，统一归一化为 `dialect` + `ipa` + `respelling`。

---

### 4.9 [P1] 同一词条不同词性有不同发音（elaborate 问题）

**现状**

elaborate 的 adjective 读 `/ɪˈlab(ə)rət/`，verb 读 `/ɪˈlabəreɪt/`。公共 API 用内嵌 `|` 分割，导致顶层 pipe split 解析失败：

```json
{
  "headword": "elaborate A. adjective",
  "entries": [{ "name": "transitive verb | bre ɪˈlabəreɪt ..." }]
}
```

**受阻 use case**

| Use Case | 说明 |
|----------|------|
| 基本正确性 | headword 不等于查询词 |
| 发音归属 | 无法知道哪个发音对应哪个词性 |

**改进**

`LexicalEntry` 携带自己的 `pronunciations: [Pronunciation]`。解析器在遇到 POS 块内嵌发音时，将其归到该 LexicalEntry。

---

### 4.10 [P1] 发音继承规则是隐式的，消费成本高

**现状**

如果 `LexicalEntry.pronunciations` 为空，消费者"应使用" `HeadwordEntry.pronunciations`。这条规则只存在于文档里，不存在于数据 contract 本身。

**受阻 use case**

| Use Case | 说明 |
|----------|------|
| UI 渲染 | 渲染某个 lexical entry 时需要记住 fallback 规则 |
| Anki 导出 | 导出单个词性卡片时容易漏发音 |
| JSON 消费 | 不同消费者可能一个做继承，一个直接显示空数组 |

**改进**

`LexicalEntry.pronunciations` 定义为"该词性块的有效发音"，由 SDK 在解析阶段填充：

- 普通词：每个 `LexicalEntry.pronunciations` 与 headword-level 相同
- 多发音词（elaborate）：对应 lexical entry 使用自己独有的发音

代价是存在一些重复数据，但换来消费零成本和稳定渲染行为。

`HeadwordEntry.pronunciations` 仍保留，用于展示词条级概览或需要去重的场景。

---

### 4.11 [P1] `lookup(...) -> LookupResult?` 无法表达错误原因

**现状**

`nil` 可能代表：词典里没有这个词、私有 API 不可用、目标 dictionaryName 不存在、原始文本拿到了但解析失败。

**受阻 use case**

| Use Case | 说明 |
|----------|------|
| CLI 友好报错 | "未找到词条" 和 "私有 API 不可用" 应提示不同信息 |
| 自动回退 | app 需要决定是否切换 source 或降级展示 |
| 测试 | 无法断言失败是 lookup 问题还是 parse 问题 |

**改进**

改为 `throws`，保留同步 API：

```swift
public enum LookupError: Error, Sendable {
    case notFound
    case dictionaryUnavailable(String)
    case sourceUnavailable
    case parseFailed
}
```

- `notFound`：Dictionary Services / private API 都未找到词条
- `dictionaryUnavailable(name)`：请求了特定私有词典但系统未安装
- `sourceUnavailable`：私有 API 无法访问
- `parseFailed`：原始 payload 有值，但无法生成最小可用结构

---

### 4.12 [P1] HTML 路径 PHRASES/DERIVATIVES 丢失释义

**现状**

`HTMLParser.swift` 对 `span.subEntryBlock` 只提取了 `span.l` 名称：

```json
{ "name": "PHRASES", "content": "a run for one's money\nrun dry\nrun high" }
```

HTML 中 `span.df`（释义）和 `span.eg`（例句）数据存在但被丢弃。

**受阻 use case**

| Use Case | 说明 |
|----------|------|
| 短语释义展示 | 用户想看 "a run for one's money" 的意思 |
| Anki 短语卡 | 短语闪卡需要释义 |
| 完整性 | 私有 API 反而比公共 API 信息更少 |

**改进**

`PhraseGroup.items: [PhraseItem]`，每个 item 有 phrase + definition + examples。

---

### 4.13 [P1] HTML 路径 label 始终为空

**现状**

HTML 路径所有 block 的 `label` 都是 `""`，没有 A/B/C/D。

**受阻 use case**

| Use Case | 说明 |
|----------|------|
| 分区渲染 | "A. noun  B. verb" 的展示依赖 label |
| 两路径一致性 | 同一渲染逻辑无法适用两个路径 |

**改进**

`LexicalEntry.displayIndex: Int`。解析器按 POS 块出现顺序生成 0, 1, 2...。渲染层自行转换为 A, B, C。

---

### 4.14 [P2] 语域标记未结构化

**现状**

`figurative`、`informal`、`formal` 等嵌入文本中。

**受阻 use case**

| Use Case | 说明 |
|----------|------|
| 过滤正式/非正式 | 学术场景只看 formal |
| 标签渲染 | 用徽章展示语域 |

**改进**

`Sense.registers: [String]`。从 `content` 中提取已知标记词列表。不做 enum（标记词多且不完全可预见），用 String 保持灵活性。

---

### 4.15 [P2] HTML 中语法标注和变形被丢弃

**现状**

HTML 中 `span.gg`（`[no object]`, `[with object]`）和 `span.infg`（runs, running, ran）未提取。公共 API 不提供此信息。

**受阻 use case**

| Use Case | 说明 |
|----------|------|
| 语法学习 | 展示及物/不及物用法 |
| 变形查询 | 查看一个词的所有形态变化 |

**改进**

`LexicalEntry.grammar: [String]`（如 `["no object"]`）和 `LexicalEntry.inflections: [String]`（如 `["runs", "running", "ran"]`）。公共 API 路径这两个字段为空数组。

---

### 4.16 [P2] 可数性标记未结构化

**现状**

```
noun ① uncountable (brightness) 光亮 ...
noun ② countable (gleam) 光点 ...
```

**受阻 use case**

| Use Case | 说明 |
|----------|------|
| 语法提示 | 义项旁显示 [U]/[C] |
| Anki 语法字段 | 闪卡标注可数性 |

**改进**

`Sense.countability: Countability?`，用 enum 表示。

---

### 4.17 [P2] `kind` 使用 String 而非 enum

**现状**

`"partOfSpeech"` / `"phrase"` / `"specialSection"` 等为 String。

**改进**

不再使用 `kind` — 不同概念拆为不同类型后，kind 消失。POS 用 `PartOfSpeech` enum。

---

## 5. 数据模型

### 5.1 类型总览

```
LookupResult                         // 顶层结果
├── LookupMetadata                   // 数据源 + 解析警告
│   └── LookupSourceKind (enum)
├── HeadwordEntry                    // 一个词条
│   ├── Pronunciation                // 发音 (词条级概览)
│   ├── LexicalEntry                 // 一个词性块
│   │   ├── PartOfSpeech (enum)
│   │   ├── Pronunciation            // 有效发音 (直接消费)
│   │   └── Sense                    // 一个义项
│   │       └── Countability (enum)
│   ├── PhraseGroup                  // 短语/动词短语/派生词
│   │   └── PhraseItem              // 一个短语条目
│   └── Note                         // 词源/用法说明/交叉引用
│       └── NoteKind (enum)
└── SourcePayload                    // raw 数据 (opt-in, debug 用)
```

共 14 个类型（9 struct + 5 enum）。

### 5.2 类型定义

```swift
// MARK: - 顶层

public struct LookupResult: Codable, Equatable, Sendable {
    /// 用户查询的原始输入
    public let query: String

    /// 匹配到的词条 (通常 1 个，保留数组为未来多词典/多匹配预留)
    public let entries: [HeadwordEntry]

    /// 数据源信息与解析警告
    public let metadata: LookupMetadata

    /// 原始数据 (nil 表示调用方未请求 includeSource)
    public let source: SourcePayload?
}

public struct LookupMetadata: Codable, Equatable, Sendable {
    /// 实际使用的数据源
    public let usedSource: LookupSourceKind

    /// 非致命警告 (固定 code，不做 severity 分级)
    /// 已定义 code:
    ///   "source_fallback" — automatic 模式下回退到备选源
    ///   "phrase_group_unstructured" — 短语组无法逐项拆分
    ///   "sense_parse_degraded" — 义项/例句/发音解析精度降低
    public let warnings: [String]
}

public enum LookupSourceKind: String, Codable, Sendable {
    case publicAPI
    case privateHTML
}
```

```swift
// MARK: - 词条

public struct HeadwordEntry: Codable, Equatable, Sendable {
    /// 归一化的词头 (永远等于查询词的规范形式，如 "elaborate"，不会被污染)
    public let headword: String

    /// 词条级发音 (用于概览展示或去重场景)
    public let pronunciations: [Pronunciation]

    /// 各词性块，按词典中出现顺序排列
    public let lexicalEntries: [LexicalEntry]

    /// 短语组 (PHRASES, PHRASAL VERBS, DERIVATIVES)
    public let phraseGroups: [PhraseGroup]

    /// 词源、用法说明、交叉引用等附注
    public let notes: [Note]
}
```

```swift
// MARK: - 词性块

public struct LexicalEntry: Codable, Equatable, Sendable {
    /// 基础词性，用于通用消费逻辑 (分组、条件渲染等)
    public let partOfSpeech: PartOfSpeech

    /// 词典中的原始 POS 标签，保留精细信息
    /// 如 "transitive verb", "modal verb", "plural noun"
    public let partOfSpeechLabel: String

    /// 该词性块在词条中的出现顺序 (0-based)
    /// 渲染层可将 0→A, 1→B, 2→C 用于展示
    public let displayIndex: Int

    /// 该词性块的有效发音
    /// 普通词：与 headword-level 相同
    /// 多发音词 (elaborate)：使用该词性特有的发音
    /// 消费者可直接使用，不需要回退到 HeadwordEntry.pronunciations
    public let pronunciations: [Pronunciation]

    /// 义项列表
    public let senses: [Sense]

    /// 语法模式 (仅 HTML 路径可提供)
    /// 如 ["no object"], ["with object and complement"]
    public let grammar: [String]

    /// 变形 (仅 HTML 路径可提供)
    /// 如 ["runs", "running", "ran"]
    public let inflections: [String]
}
```

```swift
// MARK: - 义项

public struct Sense: Codable, Equatable, Sendable {
    /// 义项编号 (从 1 开始; 只有一个义项时 number = 1)
    public let number: Int

    /// 语义提示 (括号中的辅助说明)
    /// 如 "(brightness)", "(loud cry)"
    public let semanticHint: String?

    /// 释义文本 (不含词性前缀、不含例句、不含义项编号)
    /// 英汉词典: "光亮 guāngliàng"
    /// 英英词典: "the natural agent that stimulates sight"
    public let definition: String

    /// 例句
    public let examples: [String]

    /// 语域/修辞标记
    /// 如 ["figurative"], ["informal", "British"]
    public let registers: [String]

    /// 可数性 (仅名词义项)
    public let countability: Countability?
}
```

```swift
// MARK: - 短语组

public struct PhraseGroup: Codable, Equatable, Sendable {
    /// 组类型: "PHRASES", "PHRASAL VERBS", "DERIVATIVES"
    public let title: String

    /// 能结构化提取时填充
    public let items: [PhraseItem]

    /// 无法逐项拆分时保留原始组文本
    /// 约束: items 非空时为 nil; 非 nil 时 items 为空数组
    public let rawContent: String?
}

public struct PhraseItem: Codable, Equatable, Sendable {
    /// 短语名
    public let phrase: String

    /// 释义 (HTML 路径可结构化提取; 公共 API 路径可能为 nil)
    public let definition: String?

    /// 例句
    public let examples: [String]
}
```

```swift
// MARK: - 附注

public struct Note: Codable, Equatable, Sendable {
    /// 附注类型
    public let kind: NoteKind

    /// 附注内容 (不含 "ORIGIN" 等标题前缀)
    public let content: String
}

public enum NoteKind: String, Codable, Sendable {
    case etymology      // ORIGIN
    case usage          // 用法说明
    case reference      // 交叉引用 (→, see also)
}
```

```swift
// MARK: - 发音

public struct Pronunciation: Codable, Equatable, Sendable {
    /// 方言: "BrE", "AmE", nil
    public let dialect: String?

    /// 纯 IPA (不含斜杠包裹、不含方言前缀)
    /// 公共 API: "ˈapl"
    /// 私有 API: "rən"  (去掉 /.../)
    public let ipa: String

    /// 回拼 (仅 HTML 路径某些词条提供)
    public let respelling: String?
}
```

```swift
// MARK: - Enum 类型

public enum PartOfSpeech: String, Codable, Sendable {
    case noun
    case verb
    case adjective
    case adverb
    case pronoun
    case determiner
    case preposition
    case conjunction
    case interjection
    case article
    case abbreviation
    case other
}

public enum Countability: String, Codable, Sendable {
    case countable
    case uncountable
    case countableAndUncountable
}
```

```swift
// MARK: - 原始数据 (opt-in)

public struct SourcePayload: Codable, Equatable, Sendable {
    public let rawText: String?
    public let rawHTML: String?
}
```

---

## 6. 关键设计决策说明

### 6.1 为什么不用 `Sense.subsenses: [Sense]` 递归？

- 公共 API 的 359 个 fixture 全部是扁平 `①②③`，没有子义项层级
- HTML 路径有 `span.se2` / `t_subsense`，但出现频率极低
- 引入递归类型会显著增加消费者处理复杂度

如果未来需要子义项，可以在 `Sense` 上加 `subsenses: [Sense]?` 而不破坏现有消费者。

### 6.2 为什么不拆分中文释义和拼音？

`"光亮 guāngliàng"` 中汉字和拼音的边界不是 trivially 可分割的。人名、多音字、缺拼音等情况导致启发式解析误判率高。收益（纯中文展示、拼音标注）vs 成本不匹配。

### 6.3 为什么 `partOfSpeech` 和 `partOfSpeechLabel` 分开？

将基础词性（`verb`）和原始标签（`transitive verb`）分开，使得：

- 消费者可以安全按基础词性分组、过滤
- 不丢失原始精细信息
- `PartOfSpeech` enum 保持精简，不膨胀
- JSON 序列化为简单字符串 `"verb"` 而非 `"other(\"transitive verb\")"` — 下游语言友好

### 6.4 为什么不加 ID？

CLI + Anki 不需要跨会话 stable identity。如果未来做 app，可以用 `headword + displayIndex + senseNumber` 作为 composite key。

### 6.5 LookupMetadata 而非 ParseDiagnostic

完整的 diagnostics 体系需要消费者反馈来驱动粒度设计。当前阶段用轻量 warnings（固定 code 数组）即可：

- 成本低（几行代码）
- 足够区分"数据源不提供" vs "解析退化"
- 不引入 severity / location / suggestion 等复杂机制
- 后续可在不破坏 contract 的前提下增加更多 warning code

### 6.6 为什么 `LexicalEntry.pronunciations` 是 effective 值而非继承？

隐式继承规则只存在于文档里，不同消费者容易实现不一致。以少量数据冗余换取：

- 消费者直接使用，零 fallback 逻辑
- 稳定渲染行为
- 更好的 JSON 消费体验

`HeadwordEntry.pronunciations` 仍保留用于概览展示或去重。

### 6.7 为什么 `PhraseGroup` 用 `rawContent` 而非伪 PhraseItem？

伪造一个 `phrase = 整段文本, definition = nil` 的 PhraseItem 会：

- 破坏 `phrase` 字段"短语名"的稳定语义
- 导致消费者无法判断这组 items 是否可逐项展示

`rawContent` 明确表达"无法结构化"，消费者可以清晰分支处理。

### 6.8 为什么 `lookup` 改为 `throws`？

`-> LookupResult?` 的 `nil` 混淆了 4 种完全不同的失败：词条不存在、词典不可用、源不可访问、解析失败。`throws LookupError` 让消费者可以对每种情况做正确处理，覆盖了 CLI 和 library 的所有错误分支。

---

## 7. JSON 输出示例

### 7.1 简单词: apple (公共 API 路径)

```json
{
  "query": "apple",
  "entries": [
    {
      "headword": "apple",
      "pronunciations": [
        { "dialect": "BrE", "ipa": "ˈapl", "respelling": null },
        { "dialect": "AmE", "ipa": "ˈæp(ə)l", "respelling": null }
      ],
      "lexicalEntries": [
        {
          "partOfSpeech": "noun",
          "partOfSpeechLabel": "noun",
          "displayIndex": 0,
          "pronunciations": [
            { "dialect": "BrE", "ipa": "ˈapl", "respelling": null },
            { "dialect": "AmE", "ipa": "ˈæp(ə)l", "respelling": null }
          ],
          "senses": [
            {
              "number": 1,
              "semanticHint": "(fruit)",
              "definition": "苹果 píngguǒ",
              "examples": [],
              "registers": [],
              "countability": null
            },
            {
              "number": 2,
              "semanticHint": "(tree)",
              "definition": "苹果树 píngguǒ shù",
              "examples": [
                "the apple of sb's eye figurative 掌上明珠",
                "there's a bad apple in every bunch 哪儿都有害群之马"
              ],
              "registers": [],
              "countability": null
            }
          ],
          "grammar": [],
          "inflections": []
        }
      ],
      "phraseGroups": [],
      "notes": []
    }
  ],
  "metadata": {
    "usedSource": "publicAPI",
    "warnings": []
  },
  "source": null
}
```

### 7.2 复杂词: light (公共 API 路径，截取 noun 前 3 个义项)

```json
{
  "query": "light",
  "entries": [
    {
      "headword": "light",
      "pronunciations": [
        { "dialect": "BrE", "ipa": "lʌɪt", "respelling": null },
        { "dialect": "AmE", "ipa": "laɪt", "respelling": null }
      ],
      "lexicalEntries": [
        {
          "partOfSpeech": "noun",
          "partOfSpeechLabel": "noun",
          "displayIndex": 0,
          "pronunciations": [
            { "dialect": "BrE", "ipa": "lʌɪt", "respelling": null },
            { "dialect": "AmE", "ipa": "laɪt", "respelling": null }
          ],
          "senses": [
            {
              "number": 1,
              "semanticHint": "(brightness)",
              "definition": "光亮 guāngliàng; (from a source) 光线 guāngxiàn",
              "examples": [
                "by the light of the sun 借着阳光",
                "the light is too bright/dim 光线太亮/暗"
              ],
              "registers": [],
              "countability": "uncountable"
            },
            {
              "number": 2,
              "semanticHint": "(gleam, bright point)",
              "definition": "光点 guāngdiǎn",
              "examples": [
                "she saw a light in the distance 她看见远处有一点亮光",
                "the lights of the city 城市的灯火"
              ],
              "registers": [],
              "countability": "countable"
            },
            {
              "number": 3,
              "semanticHint": "(aspect)",
              "definition": "角度 jiǎodù",
              "examples": [
                "in a good/favourable/new/different light 从好的/有利的/新的/不同的角度"
              ],
              "registers": ["figurative"],
              "countability": "countable"
            }
          ],
          "grammar": [],
          "inflections": []
        },
        {
          "partOfSpeech": "adjective",
          "partOfSpeechLabel": "adjective",
          "displayIndex": 1,
          "pronunciations": [
            { "dialect": "BrE", "ipa": "lʌɪt", "respelling": null },
            { "dialect": "AmE", "ipa": "laɪt", "respelling": null }
          ],
          "senses": ["..."],
          "grammar": [],
          "inflections": []
        }
      ],
      "phraseGroups": [
        {
          "title": "PHRASAL VERB",
          "items": [],
          "rawContent": "light up ① intransitive verb (become bright) «face, eyes» 变明亮 biàn míngliàng ..."
        }
      ],
      "notes": []
    }
  ],
  "metadata": {
    "usedSource": "publicAPI",
    "warnings": ["phrase_group_unstructured"]
  },
  "source": null
}
```

### 7.3 多发音词: elaborate (公共 API 路径)

```json
{
  "query": "elaborate",
  "entries": [
    {
      "headword": "elaborate",
      "pronunciations": [],
      "lexicalEntries": [
        {
          "partOfSpeech": "adjective",
          "partOfSpeechLabel": "adjective",
          "displayIndex": 0,
          "pronunciations": [
            { "dialect": "BrE", "ipa": "ɪˈlab(ə)rət", "respelling": null },
            { "dialect": "AmE", "ipa": "əˈlæb(ə)rət", "respelling": null }
          ],
          "senses": [
            {
              "number": 1,
              "semanticHint": "(detailed)",
              "definition": "精心制作的 jīngxīn zhìzuò de",
              "examples": [],
              "registers": [],
              "countability": null
            }
          ],
          "grammar": [],
          "inflections": []
        },
        {
          "partOfSpeech": "verb",
          "partOfSpeechLabel": "transitive verb",
          "displayIndex": 1,
          "pronunciations": [
            { "dialect": "BrE", "ipa": "ɪˈlabəreɪt", "respelling": null },
            { "dialect": "AmE", "ipa": "əˈlæbəˌreɪt", "respelling": null }
          ],
          "senses": [
            {
              "number": 1,
              "semanticHint": null,
              "definition": "详尽阐述 xiángjìn chǎnshù ‹theory, scheme, hypothesis›",
              "examples": [],
              "registers": [],
              "countability": null
            }
          ],
          "grammar": [],
          "inflections": []
        }
      ],
      "phraseGroups": [],
      "notes": []
    }
  ],
  "metadata": {
    "usedSource": "publicAPI",
    "warnings": []
  },
  "source": null
}
```

### 7.4 HTML 路径: run (带短语释义和变形)

```json
{
  "query": "run",
  "entries": [
    {
      "headword": "run",
      "pronunciations": [
        { "dialect": "AmE", "ipa": "rən", "respelling": null }
      ],
      "lexicalEntries": [
        {
          "partOfSpeech": "verb",
          "partOfSpeechLabel": "verb",
          "displayIndex": 0,
          "pronunciations": [
            { "dialect": "AmE", "ipa": "rən", "respelling": null }
          ],
          "senses": [
            {
              "number": 1,
              "semanticHint": null,
              "definition": "move at a speed faster than a walk, never having both or all the feet on the ground at the same time",
              "examples": [
                "the dog ran across the road",
                "she ran the last few yards, breathing heavily"
              ],
              "registers": [],
              "countability": null
            }
          ],
          "grammar": ["no object"],
          "inflections": ["runs", "running", "ran"]
        },
        {
          "partOfSpeech": "noun",
          "partOfSpeechLabel": "noun",
          "displayIndex": 1,
          "pronunciations": [
            { "dialect": "AmE", "ipa": "rən", "respelling": null }
          ],
          "senses": ["..."],
          "grammar": [],
          "inflections": []
        }
      ],
      "phraseGroups": [
        {
          "title": "PHRASES",
          "items": [
            {
              "phrase": "a run for one's money",
              "definition": "a challenging competition or opponent",
              "examples": ["the Moroccan gave him a run for his money"]
            },
            {
              "phrase": "run dry",
              "definition": "(of a well or river) cease to flow or have any water",
              "examples": []
            }
          ],
          "rawContent": null
        },
        {
          "title": "PHRASAL VERBS",
          "items": [
            {
              "phrase": "run across",
              "definition": "happen to meet or find",
              "examples": ["I just ran across him at the cafeteria"]
            }
          ],
          "rawContent": null
        },
        {
          "title": "DERIVATIVES",
          "items": [
            { "phrase": "runnable", "definition": null, "examples": [] }
          ],
          "rawContent": null
        }
      ],
      "notes": [
        {
          "kind": "etymology",
          "content": "Old English rinnan, irnan (verb), of Germanic origin."
        }
      ]
    }
  ],
  "metadata": {
    "usedSource": "privateHTML",
    "warnings": []
  },
  "source": {
    "rawText": null,
    "rawHTML": "<d:entry ...>...</d:entry>"
  }
}
```

---

## 8. 从现有模型到最终模型的映射

| 当前概念 | 最终目标 |
|---------|---------|
| `DictionaryEntry.query` | `LookupResult.query` |
| `DictionaryEntry.headword` | `HeadwordEntry.headword` |
| `DictionaryEntry.pronunciations: [String]` | `HeadwordEntry.pronunciations: [Pronunciation]` + 传播到各 `LexicalEntry.pronunciations` |
| `DictionaryEntry.rawText` | `SourcePayload.rawText` (opt-in) |
| *(无)* | `LookupResult.metadata` (新增) |
| `DictionaryBlock` kind=partOfSpeech | `LexicalEntry` |
| `DictionaryBlock` kind=phrase | `PhraseGroup.items` 中的一项 |
| `DictionaryBlock` kind=specialSection, name=ORIGIN | `Note(kind: .etymology)` |
| `DictionaryBlock` kind=specialSection, name=PHRASAL VERBS | `PhraseGroup(title: "PHRASAL VERBS")` |
| `DictionaryBlock` kind=specialSection, name=DERIVATIVES | `PhraseGroup(title: "DERIVATIVES")` |
| `DictionaryBlock` kind=reference | `Note(kind: .reference)` |
| `DictionaryBlock` kind=abbreviation | `LexicalEntry(partOfSpeech: .abbreviation)` |
| `DictionaryBlock` kind=fallback / unknown | `LexicalEntry(partOfSpeech: .other, partOfSpeechLabel: "unknown")` + senses 只有一个元素 |
| `DictionaryBlock.label` (A/B/C) | `LexicalEntry.displayIndex` (0/1/2) |
| `DictionaryBlock.content` (整段文本) | 拆分到 `Sense.definition` + `Sense.examples` |
| `DictionaryBlock.name` (词性名) | `LexicalEntry.partOfSpeech` + `LexicalEntry.partOfSpeechLabel` |

---

## 9. API 签名

```swift
/// 查词并返回结构化结果
/// - Throws: `LookupError`
public func lookup(
    _ term: String,
    source: LookupSource = .automatic,
    includeSource: Bool = false
) throws -> LookupResult

public enum LookupSource: Sendable {
    /// 优先使用私有 API，回退到公共 API
    case automatic
    /// 仅使用公共 API (DCSCopyTextDefinition)
    case publicAPI
    /// 仅使用私有 API (DCSCopyRecordsForSearchString)
    case privateHTML(dictionaryName: String = "New Oxford American Dictionary")
}

public enum LookupError: Error, Sendable {
    /// 词典中未找到该词条
    case notFound
    /// 请求的私有词典未安装
    case dictionaryUnavailable(String)
    /// 私有 API 无法访问
    case sourceUnavailable
    /// 原始数据已获取，但无法解析为最小可用结构
    case parseFailed
}
```

不用 async — macOS Dictionary API 是同步的。

原有的低层函数（`lookupDefinition`, `lookupHTML`, `parseDefinition`, `parseHTML`）保留为 internal 或 public 供调试，但不再作为主推 API。

---

## 10. 兼容与迁移

### 10.1 保留 V1 类型

`DictionaryEntry` / `DictionaryBlock` 保留，标记为 deprecated。提供 adapter：

```swift
extension LookupResult {
    /// 转换为旧版数据结构，用于现有 CLI 输出和快照测试的过渡期兼容
    public func asLegacyEntry() -> DictionaryEntry?
}
```

### 10.2 快照测试迁移

- 新增最终版快照测试，输出 `LookupResult` 的 JSON
- 旧快照通过 `asLegacyEntry()` 继续跑，确保 V1 不回退
- 两套快照并行运行至 V1 正式移除

### 10.3 CLI 输出

CLI 切换到最终版输出。`--json` 输出 `LookupResult` JSON；`--legacy-json` 输出旧格式。

### 10.4 推荐实现顺序

1. 改 `lookup` 签名为 `throws`，引入 `LookupError`
2. 引入 `LookupResult` + `LookupMetadata`
3. 将 `DictionaryBlock` 拆分为 `LexicalEntry` / `PhraseGroup` / `Note`
4. 实现 `Sense` 拆分（`①②③` 切割 + `▸` 例句分离）
5. 引入 `Pronunciation` struct，归一化跨路径发音格式
6. 给 `LexicalEntry` 增加 `partOfSpeechLabel`，`PartOfSpeech` 改为无关联值 enum
7. 改 `LexicalEntry.pronunciations` 为 effective 值
8. 给 `PhraseGroup` 增加 `rawContent`
9. HTML 路径提取短语释义/例句、语法标注、变形
10. 提取语域标记和可数性到 `Sense`
11. 补 metadata warning code

---

## 11. 优先级总览

| 优先级 | 编号 | 问题 | 路径 |
|:------:|------|------|------|
| P0 | 4.1 | content 未拆分义项 | 公共+私有 |
| P0 | 4.2 | 例句未从释义分离 | 公共+私有 |
| P0 | 4.3 | 空数组/nil 语义模糊 → LookupMetadata + warnings | 公共+私有 |
| P0 | 4.4 | PhraseGroup 伪结构化 → rawContent | 公共 |
| P0 | 4.5 | other("transitive verb") 丢基础词性 → partOfSpeechLabel | 公共+私有 |
| P1 | 4.6 | DictionaryBlock 万能桶 → 拆为三种类型 | 公共+私有 |
| P1 | 4.7 | name/content 信息重复 | 公共+私有 |
| P1 | 4.8 | 发音格式不一致 | 跨路径 |
| P1 | 4.9 | elaborate 多发音问题 | 公共 |
| P1 | 4.10 | 发音继承隐式 → effective pronunciations | 跨路径 |
| P1 | 4.11 | lookup 返回 nil 无法区分错误 → throws | 公共+私有 |
| P1 | 4.12 | HTML PHRASES 丢失释义 | 私有 |
| P1 | 4.13 | HTML label 始终为空 | 私有 |
| P2 | 4.14 | 语域标记未结构化 | 公共+私有 |
| P2 | 4.15 | HTML 语法/变形被丢弃 | 私有 |
| P2 | 4.16 | 可数性未结构化 | 公共+私有 |
| P2 | 4.17 | kind 用 String 非 enum | 公共+私有 |

---

## 12. 不做的事

| 不做 | 理由 |
|------|------|
| `Sense.subsenses: [Sense]` 递归 | 公共 API 数据全部扁平；HTML 子义项极少。等有真实需求再加 |
| `AudioResource` | macOS 词典 API 不提供音频 URL |
| `Identifiable` + ID 生成 | CLI + Anki 不需要跨会话 stable identity |
| 完整 `ParseDiagnostic` 体系 | 用轻量 `LookupMetadata.warnings` 替代，成本更低且已足够 |
| `DetailLevel` (minimal/standard/extended) | 无法定义各级包含什么，推迟 |
| 中文/拼音拆分 | 边界判断复杂，误判率高，收益有限 |
| `Translation` struct (text + reading + language) | 过度抽象。当前只有一种双语词典 |

---

## 13. Contract 约束总结

| 约束 | 说明 |
|------|------|
| `PhraseGroup`: items/rawContent 互斥 | items 非空 → rawContent = nil; rawContent 非 nil → items = [] |
| `LexicalEntry.pronunciations` 为有效值 | 消费者直接使用，不需要 fallback 到 headword-level |
| `partOfSpeech` / `partOfSpeechLabel` 对齐 | partOfSpeech 为基础词性 enum; partOfSpeechLabel 为原始标签 |
| `Sense.definition` 不含前缀 | 不含词性名、不含义项编号、不含例句 |
| `Note.content` 不含标题 | 不含 "ORIGIN" 等 section 标题前缀 |
| `lookup` throws 而非返回 nil | 4 种 LookupError 覆盖所有失败场景 |
| `metadata.warnings` 使用固定 code | 不做 severity 分级，不做自由文本 |
