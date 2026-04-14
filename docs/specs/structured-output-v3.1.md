# Structured Output V3.1 Spec

## 1. 文档定位

本文档是对 `structured-output-v3.md` 的收敛修订版。

目标不是推翻 V3，而是在保持其“足够小、足够实用、以 CLI + Anki 为主”的前提下，修补几个会直接影响 SDK 可用性的 contract 问题。

V3.1 的原则：

- 保留 V3 的主结构：`LookupResult -> HeadwordEntry -> LexicalEntry -> Sense`
- 不引入完整的 diagnostics/identity 体系
- 只增加少量字段，解决真实消费场景中的歧义和退化问题
- 每个改动都必须对应明确的问题点、use case 和可执行的实现策略

---

## 2. V3 的主要问题

### 2.1 [P0] 空数组和 nil 无法区分“没有数据”和“没有解析出来”

**现状**

V3 中大量字段采用：

- `[]`
- `nil`

来表达所有“无值”场景，例如：

- `Sense.examples: []`
- `LexicalEntry.grammar: []`
- `LexicalEntry.inflections: []`
- `phraseGroups: []`

这会混淆三种完全不同的情况：

1. 源数据里确实没有该信息
2. 当前 lookup 路径不提供该信息
3. 源数据可能有，但解析器当前没有成功提取

**受阻 use case**

| Use Case | 说明 |
|----------|------|
| CLI 输出 | 无法告诉用户“该字段不存在”还是“当前来源未提供” |
| Anki 导出 | 无法决定空字段是否应该 fallback 到 raw/source |
| 回归测试 | 无法识别“解析质量下降但结果仍合法”的退化 |
| 多源调试 | `automatic` 选择了哪条路径、丢了哪些结构化信息，调用方不可见 |

**改进**

不引入完整 `ParseDiagnostic`，只增加一个轻量 metadata/warnings 层：

```swift
public struct LookupMetadata: Codable, Equatable, Sendable {
    /// 实际使用的数据源
    public let usedSource: LookupSourceKind

    /// 非致命警告
    /// 例如: "phrases_unstructured_in_public_api"
    public let warnings: [String]
}

public enum LookupSourceKind: String, Codable, Sendable {
    case publicAPI
    case privateHTML
}
```

顶层结果改为：

```swift
public struct LookupResult: Codable, Equatable, Sendable {
    public let query: String
    public let entries: [HeadwordEntry]
    public let metadata: LookupMetadata
    public let source: SourcePayload?
}
```

**实现建议**

- 第一阶段 warning 只使用固定 code，不做复杂 severity 分级
- 仅在以下情况写 warning：
  - 使用 `automatic` 后发生 source fallback
  - phrase group 只能保留原始文本，无法拆成 `PhraseItem`
  - sense/example/pronunciation 解析发生明显降级

这样成本低，但已经足够让 SDK 消费者做正确判断。

---

### 2.2 [P0] `PhraseGroup` 的 graceful degradation 会制造伪结构化数据

**现状**

V3 允许在公共 API 路径无法逐个拆短语时：

- 构造一个 `PhraseItem`
- 其 `phrase` 填整段文本
- `definition = nil`

这会让字段在类型上看似结构化，语义上却不是“一个短语条目”。

**受阻 use case**

| Use Case | 说明 |
|----------|------|
| Anki 短语卡 | 会生成标题为整段原文的坏卡片 |
| 短语计数 | 一个大段文本被误算成 1 个短语 |
| 短语搜索/过滤 | `phrase` 字段不再具有“短语名”的稳定语义 |
| UI 展示 | 调用方无法判断这组 items 是否真的可逐项展示 |

**改进**

`PhraseGroup` 同时支持 structured 和 unstructured 两种状态：

```swift
public struct PhraseGroup: Codable, Equatable, Sendable {
    /// 组类型: "PHRASES", "PHRASAL VERBS", "DERIVATIVES"
    public let title: String

    /// 能结构化提取时填充
    public let items: [PhraseItem]

    /// 无法逐项拆分时保留原始组文本
    public let rawContent: String?
}
```

约束：

- `items` 非空时，`rawContent` 应为 `nil`
- `rawContent` 非 `nil` 时，`items` 应为空数组

**实现建议**

- HTML 路径优先填 `items`
- 公共 API 路径在无法稳定拆分时，保留 `rawContent`
- 同时在 `metadata.warnings` 中追加：
  - `phrase_group_unstructured`

这比伪造一个 `PhraseItem` 更诚实，也更利于应用层分支处理。

---

### 2.3 [P0] `PartOfSpeech.other("transitive verb")` 丢失基础词性

**现状**

V3 试图控制 enum 大小，因此把：

- `transitive verb`
- `intransitive verb`
- `modal verb`
- `linking verb`

整体塞进 `.other(String)`。

这会把“这是 verb”这个最基础、最常消费的信息一起丢掉。

**受阻 use case**

| Use Case | 说明 |
|----------|------|
| 渲染分组 | UI 想把 noun / verb / adjective 分组展示 |
| 语法规则 | 只有 noun 才渲染 `[C]/[U]`，只有 verb 才渲染语法模式 |
| JSON 消费 | 下游程序无法可靠筛选所有 verb |
| 搜索/统计 | 统计词性分布时，compound POS 被散落到 `.other` |

**改进**

把“基础词性”和“原始 POS 描述”分开：

```swift
public struct LexicalEntry: Codable, Equatable, Sendable {
    /// 基础词性，用于通用消费逻辑
    public let partOfSpeech: PartOfSpeech

    /// 词典中的原始 POS 标签
    /// 如 "transitive verb", "modal verb", "plural noun"
    public let partOfSpeechLabel: String

    public let displayIndex: Int
    public let pronunciations: [Pronunciation]
    public let senses: [Sense]
    public let grammar: [String]
    public let inflections: [String]
}
```

其中：

- `partOfSpeech` 只表达基础词性，如 `.verb`
- `partOfSpeechLabel` 保留更细的原始说明

`PartOfSpeech` 定义保持精简：

```swift
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
```

**实现建议**

- 先从现有 parser 的 POS 检测结果映射出基础词性
- 映射失败时：
  - `partOfSpeech = .other`
  - `partOfSpeechLabel = 原始文本`

这样应用层既能安全处理主流场景，也不会损失细节。

---

### 2.4 [P1] 发音继承规则是隐式的，消费成本高

**现状**

V3 规定：

- `HeadwordEntry.pronunciations` 存词条级发音
- `LexicalEntry.pronunciations` 只在特殊情况下填写
- 为空时调用方“应使用” headword-level 发音

这条规则只存在于文档里，不存在于数据 contract 本身。

**受阻 use case**

| Use Case | 说明 |
|----------|------|
| UI 渲染 | 渲染某个 lexical entry 时需要记住 fallback 规则 |
| Anki 导出 | 导出单个词性卡片时容易漏发音 |
| JSON 消费 | 不同消费者可能一个做继承，一个直接显示空数组 |

**改进**

公开 contract 中，`LexicalEntry.pronunciations` 直接定义为“该词性块的有效发音”：

```swift
public struct HeadwordEntry: Codable, Equatable, Sendable {
    public let headword: String
    public let pronunciations: [Pronunciation]
    public let lexicalEntries: [LexicalEntry]
    public let phraseGroups: [PhraseGroup]
    public let notes: [Note]
}

public struct LexicalEntry: Codable, Equatable, Sendable {
    public let partOfSpeech: PartOfSpeech
    public let partOfSpeechLabel: String
    public let displayIndex: Int

    /// 该词性块渲染时应使用的发音
    /// 一般情况下等于词条级发音；特殊情况下可覆盖
    public let pronunciations: [Pronunciation]

    public let senses: [Sense]
    public let grammar: [String]
    public let inflections: [String]
}
```

约束：

- 普通词：每个 `LexicalEntry.pronunciations` 与 headword-level 相同
- 多发音词：对应 lexical entry 使用自己的发音

**实现建议**

- 解析阶段直接填 effective pronunciations
- 不要求消费者再做 fallback

代价是存在一些重复数据，但换来更低的消费复杂度和更稳定的渲染行为，值得。

---

### 2.5 [P1] `lookup(...) -> LookupResult?` 无法表达错误原因

**现状**

V3 的签名：

```swift
public func lookup(
    _ term: String,
    source: LookupSource = .automatic,
    includeSource: Bool = false
) -> LookupResult?
```

`nil` 可能代表：

- 词典里没有这个词
- 私有 API 不可用
- 目标 dictionaryName 不存在
- 原始文本拿到了，但结构化解析失败

**受阻 use case**

| Use Case | 说明 |
|----------|------|
| CLI 友好报错 | “未找到词条” 和 “私有 API 不可用” 应提示不同信息 |
| 自动回退 | app 需要决定是否切换 source 或降级展示 |
| 测试 | 无法断言失败是 lookup 问题还是 parse 问题 |

**改进**

改为 `throws`，保留同步 API：

```swift
public func lookup(
    _ term: String,
    source: LookupSource = .automatic,
    includeSource: Bool = false
) throws -> LookupResult

public enum LookupError: Error, Sendable {
    case notFound
    case dictionaryUnavailable(String)
    case sourceUnavailable
    case parseFailed
}
```

**实现建议**

- `notFound`：Dictionary Services / private API 都未找到词条
- `dictionaryUnavailable(name)`：请求了特定私有词典但系统未安装
- `sourceUnavailable`：私有 API 无法访问
- `parseFailed`：原始 payload 有值，但无法生成最小可用结构

这已经足够覆盖 CLI 和 library 的错误分支，不需要更复杂的 error taxonomy。

---

## 3. V3.1 数据模型

### 3.1 类型总览

```
LookupResult
├── LookupMetadata
├── HeadwordEntry
│   ├── Pronunciation
│   ├── LexicalEntry
│   │   ├── Pronunciation
│   │   └── Sense
│   ├── PhraseGroup
│   │   └── PhraseItem
│   └── Note
├── PartOfSpeech (enum)
├── Countability (enum)
├── LookupSourceKind (enum)
└── SourcePayload
```

比 V3 多出的只有：

- `LookupMetadata`
- `LookupSourceKind`
- `PhraseGroup.rawContent`
- `LexicalEntry.partOfSpeechLabel`

---

### 3.2 类型定义

```swift
// MARK: - Top level

public struct LookupResult: Codable, Equatable, Sendable {
    public let query: String
    public let entries: [HeadwordEntry]
    public let metadata: LookupMetadata
    public let source: SourcePayload?
}

public struct LookupMetadata: Codable, Equatable, Sendable {
    public let usedSource: LookupSourceKind
    public let warnings: [String]
}

public enum LookupSourceKind: String, Codable, Sendable {
    case publicAPI
    case privateHTML
}
```

```swift
// MARK: - Headword

public struct HeadwordEntry: Codable, Equatable, Sendable {
    public let headword: String
    public let pronunciations: [Pronunciation]
    public let lexicalEntries: [LexicalEntry]
    public let phraseGroups: [PhraseGroup]
    public let notes: [Note]
}
```

```swift
// MARK: - Lexical entry

public struct LexicalEntry: Codable, Equatable, Sendable {
    /// 基础词性，用于通用消费
    public let partOfSpeech: PartOfSpeech

    /// 原始词性标签，用于保留精细信息
    public let partOfSpeechLabel: String

    /// 0-based display order
    public let displayIndex: Int

    /// 该词性块的有效发音
    public let pronunciations: [Pronunciation]

    public let senses: [Sense]
    public let grammar: [String]
    public let inflections: [String]
}
```

```swift
// MARK: - Sense

public struct Sense: Codable, Equatable, Sendable {
    public let number: Int
    public let semanticHint: String?
    public let definition: String
    public let examples: [String]
    public let registers: [String]
    public let countability: Countability?
}
```

```swift
// MARK: - Phrase group

public struct PhraseGroup: Codable, Equatable, Sendable {
    public let title: String

    /// Structured items when available
    public let items: [PhraseItem]

    /// Raw group text when per-item parsing is unavailable
    public let rawContent: String?
}

public struct PhraseItem: Codable, Equatable, Sendable {
    public let phrase: String
    public let definition: String?
    public let examples: [String]
}
```

```swift
// MARK: - Notes

public struct Note: Codable, Equatable, Sendable {
    public let kind: NoteKind
    public let content: String
}

public enum NoteKind: String, Codable, Sendable {
    case etymology
    case usage
    case reference
}
```

```swift
// MARK: - Pronunciation

public struct Pronunciation: Codable, Equatable, Sendable {
    public let dialect: String?
    public let ipa: String
    public let respelling: String?
}
```

```swift
// MARK: - Enums

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
// MARK: - Source payload

public struct SourcePayload: Codable, Equatable, Sendable {
    public let rawText: String?
    public let rawHTML: String?
}
```

---

## 4. API 签名

```swift
public func lookup(
    _ term: String,
    source: LookupSource = .automatic,
    includeSource: Bool = false
) throws -> LookupResult

public enum LookupSource: Sendable {
    case automatic
    case publicAPI
    case privateHTML(dictionaryName: String = "New Oxford American Dictionary")
}

public enum LookupError: Error, Sendable {
    case notFound
    case dictionaryUnavailable(String)
    case sourceUnavailable
    case parseFailed
}
```

同步 API 保持不变，只把“失败”从 `nil` 提升为可区分的错误。

---

## 5. 示例约束

### 5.1 `PhraseGroup`

- 可结构化时：
  - `items.count > 0`
  - `rawContent == nil`
- 不可结构化时：
  - `items == []`
  - `rawContent != nil`

### 5.2 `LexicalEntry.pronunciations`

- 永远可直接用于渲染该 lexical entry
- 调用方不需要回退到 headword-level

### 5.3 `partOfSpeech` / `partOfSpeechLabel`

示例：

```json
{
  "partOfSpeech": "verb",
  "partOfSpeechLabel": "transitive verb"
}
```

而不是：

```json
{
  "partOfSpeech": "other(\"transitive verb\")"
}
```

---

## 6. 迁移建议

### 6.1 从 V3 到 V3.1 的改动成本

较低，原因：

- 主体树结构不变
- `Sense`、`Pronunciation`、`Note` 无破坏性重做
- parser 只需补几处字段填充策略

### 6.2 推荐实现顺序

1. 改 `lookup` 签名为 `throws`
2. 给 `LookupResult` 增加 `metadata`
3. 给 `LexicalEntry` 增加 `partOfSpeechLabel`
4. 改 `LexicalEntry.pronunciations` 为 effective 值
5. 给 `PhraseGroup` 增加 `rawContent`
6. 最后补 warning code

这样可以先把 contract 变稳，再补解析精度。

---

## 7. 结论

V3.1 不是更“理想化”的版本，而是更“可签约”的版本。

它解决了 V3 中 4 个最影响 SDK 使用体验的问题：

- 不确定性完全不可见
- phrase 降级语义不诚实
- 基础词性信息丢失
- pronunciation fallback 规则隐式存在
- lookup 失败原因不可区分

同时，它仍然保持：

- 类型总量小
- 与现有 fixture 和 parser 能力对齐
- CLI + Anki 场景优先
- 后续向 app / library 扩展时不需要推翻重来
