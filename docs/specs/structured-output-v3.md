# Structured Output V3 Spec

## 1. 文档定位

本文档是 `structured-output-improvements.md`（问题清单）和 `structured-output-v2.md`（理想模型）的合并与落地版。

目标：

- 以实际 fixture 数据（359 text + 4 HTML）为依据，不做空中楼阁
- 以 CLI 查词 + Anki 闪卡生成为主要场景，为 library / app 留扩展空间
- 类型数量控制在 ~12 个，不引入当前数据无法填充的字段
- 每个设计决策附带问题描述、受阻 use case、具体改进

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

如果一个字段在 95% 的词条中为 nil（如 `AudioResource`），就不加入 V3。等有真实数据源时再扩展。

### 3.4 结构化到义项级别，不追求更细

义项（Sense）是应用层最常操作的粒度。义项内部的释义文本保持为 String，不再拆分中文/拼音（技术难度高，收益有限）。

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

### 4.3 [P1] `DictionaryBlock` 是万能桶

**现状**

noun block、ORIGIN block、cross reference 共用同一个 struct，靠 `kind` string 区分。导致：

- `name` 字段语义不一致（词性名 / 短语名 / 段落标题 / 空）
- 一半字段只对部分 kind 有意义
- 应用层必须 switch on kind 才能解读任何字段

**受阻 use case**

| Use Case | 说明 |
|----------|------|
| 类型安全消费 | 无法用编译器保证 "partOfSpeech block 一定有词性名" |
| 代码可读性 | 新开发者无法从类型签名理解数据结构 |

**改进**

将 `DictionaryBlock` 拆分为三个不同类型：

- `LexicalEntry`：一个词性块（noun / verb / adjective ...），包含 senses
- `PhraseGroup`：短语/动词短语/派生词组
- `Note`：词源、用法说明、交叉引用

顶层 `DictionaryEntry.entries` 拆为三个具名字段。

---

### 4.4 [P1] name 和 content 信息重复

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

Sense 的 `definition` 不再包含 POS 名称前缀。Note 的 `content` 不再包含 section 标题前缀。解析时剥离。

---

### 4.5 [P1] 发音格式跨路径不一致

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

引入 `Pronunciation` struct，统一归一化。

---

### 4.6 [P1] 同一词条不同词性有不同发音（elaborate 问题）

**现状**

elaborate 的 adjective 读 `/ɪˈlab(ə)rət/`，verb 读 `/ɪˈlabəreɪt/`。公共 API 用内嵌 `|` 分割，导致顶层 pipe split 解析失败：

```json
{
  "headword": "elaborate A. adjective",
  "entries": [{ "name": "transitive verb | bre ɪˈlabəreɪt ..." }]
}
```

headword 被污染，name 包含发音和释义。

**受阻 use case**

| Use Case | 说明 |
|----------|------|
| 基本正确性 | headword 不等于查询词 |
| 发音归属 | 无法知道哪个发音对应哪个词性 |

**改进**

`LexicalEntry` 携带自己的 `pronunciations: [Pronunciation]`。解析器在遇到 POS 块内嵌发音时，将其归到该 LexicalEntry 而非顶层。

---

### 4.7 [P1] HTML 路径 PHRASES/DERIVATIVES 丢失释义

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

`PhraseGroup` 包含 `[PhraseItem]`，每个 item 有 name + definition + examples。

---

### 4.8 [P1] HTML 路径 label 始终为空

**现状**

HTML 路径所有 block 的 `label` 都是 `""`，没有 A/B/C/D。

**受阻 use case**

| Use Case | 说明 |
|----------|------|
| 分区渲染 | "A. noun  B. verb" 的展示依赖 label |
| 两路径一致性 | 同一渲染逻辑无法适用两个路径 |

**改进**

`LexicalEntry.displayIndex: Int`。解析器按 POS 块出现顺序生成 0, 1, 2...。渲染层自行转换为 A, B, C（展示逻辑不硬编码在数据模型中）。

---

### 4.9 [P2] 语域标记未结构化

**现状**

`figurative`、`informal`、`formal` 等嵌入文本中。

```
▸ to contemplate one's navel figurative 陷入冥想
```

**受阻 use case**

| Use Case | 说明 |
|----------|------|
| 过滤正式/非正式 | 学术场景只看 formal |
| 标签渲染 | 用徽章展示语域 |

**改进**

`Sense.registers: [String]`。从 `content` 中提取已知标记词列表。不做 enum（标记词可能很多且不完全可预见），用 String 保持灵活性。

---

### 4.10 [P2] HTML 中语法标注和变形被丢弃

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

### 4.11 [P2] 可数性标记未结构化

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

### 4.12 [P2] `kind` 使用 String 而非 enum

**现状**

`"partOfSpeech"` / `"phrase"` / `"specialSection"` 等为 String。

**改进**

V3 不再使用 `kind` — 不同概念拆为不同类型后，kind 消失。POS 名称用 `PartOfSpeech` enum + `.other(String)` 兜底。

---

## 5. V3 数据模型

### 5.1 类型总览

```
LookupResult                         // 顶层结果
├── HeadwordEntry                    // 一个词条
│   ├── Pronunciation                // 发音
│   ├── LexicalEntry                 // 一个词性块
│   │   ├── Pronunciation            // 该词性特有的发音 (elaborate 场景)
│   │   └── Sense                    // 一个义项
│   ├── PhraseGroup                  // 短语/动词短语/派生词
│   │   └── PhraseItem              // 一个短语条目
│   └── Note                         // 词源/用法说明/交叉引用
├── PartOfSpeech (enum)
├── Countability (enum)
└── SourcePayload                    // raw 数据 (opt-in, debug 用)
```

共 11 个类型 (8 struct + 3 enum)。

### 5.2 类型定义

```swift
// MARK: - 顶层

public struct LookupResult: Codable, Equatable, Sendable {
    /// 用户查询的原始输入
    public let query: String
    /// 匹配到的词条 (通常 1 个，保留数组为未来多词典/多匹配预留)
    public let entries: [HeadwordEntry]
    /// 原始数据 (nil 表示调用方未请求)
    public let source: SourcePayload?
}
```

```swift
// MARK: - 词条

public struct HeadwordEntry: Codable, Equatable, Sendable {
    /// 归一化的词头 (永远等于查询词的规范形式，如 "elaborate"，不会被污染)
    public let headword: String

    /// 词条级发音 (大多数词只在此处提供发音)
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
    /// 词性
    public let partOfSpeech: PartOfSpeech

    /// 该词性块在词条中的出现顺序 (0-based)
    /// 渲染层可将 0→A, 1→B, 2→C 用于展示
    public let displayIndex: Int

    /// 该词性特有的发音 (如 elaborate 的 verb 发音与 adjective 不同)
    /// 为空时应使用 HeadwordEntry.pronunciations
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
    /// 义项编号 (从 1 开始)
    /// 只有一个义项时 number = 1
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

    /// 该组下的所有短语条目
    public let items: [PhraseItem]
}

public struct PhraseItem: Codable, Equatable, Sendable {
    /// 短语名
    public let phrase: String

    /// 释义 (公共 API 路径对 PHRASES 可能只有混合文本，HTML 路径可结构化提取)
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

public enum PartOfSpeech: Codable, Equatable, Sendable {
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
    case other(String)
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

实际数据中：

- 公共 API 的 359 个 fixture 全部是扁平 `①②③`，没有子义项层级
- HTML 路径有 `span.se2` / `t_subsense`，但出现频率极低

引入递归类型会显著增加消费者处理复杂度，而 95%+ 的数据不需要。如果未来 HTML 路径需要子义项，可以在 `Sense` 上加 `subsenses: [Sense]?` 而不破坏现有消费者。

### 6.2 为什么不拆分中文释义和拼音？

`"光亮 guāngliàng"` 中汉字和拼音的边界不是 trivially 可分割的：

- 人名、专有名词中的拉丁字母会和拼音混淆
- 多音字可能需要消歧
- 某些释义没有拼音

收益（纯中文展示、拼音标注）vs 成本（高复杂度启发式解析 + 频繁误判）不匹配。保持 `definition: String`，消费者如需拆分可自行处理。

### 6.3 为什么 `PartOfSpeech` 不区分 transitive/intransitive？

当前公共 API 数据中有丰富的 compound POS："transitive verb"、"intransitive verb"、"modal verb"、"linking verb"、"copular verb"、"reflexive verb" 等。

如果全部枚举会导致 enum 膨胀。更务实的做法：

- `PartOfSpeech` 只枚举基础词性
- 修饰信息（transitive/intransitive/modal 等）放在 `LexicalEntry.grammar` 中
- 或者将完整的原始 POS 描述保留为 `other(String)`

这里选择的方案是：基础词性用 enum，compound POS 归入 `.other("transitive verb")`。理由：应用层通常只关心"这是个动词还是名词"来决定渲染策略，具体的 transitive/intransitive 属于语法细节。

但这是一个可以讨论的点——如果消费场景确实需要区分及物/不及物，可以增加 enum case。

### 6.4 为什么不加 ID？

V2 在每个类型上加了 `id: String` + `Identifiable`。理由是支持书签、UI diffing、缓存。

但当前场景（CLI + Anki）不需要跨会话 stable identity。如果未来做 app，可以在外层包装一个带 ID 的容器，或者用 `headword + displayIndex + senseNumber` 作为 composite key。不需要在数据模型层面引入 ID 生成策略。

### 6.5 为什么不加 Diagnostics？

V2 的 `ParseDiagnostic` 是好想法，但当前阶段：

- 解析器的作者和消费者是同一个人
- 解析不确定性可以通过 `SourcePayload.rawText` 人工检查
- Diagnostics 的粒度（哪些信息需要报告、severity 如何定义）需要消费者反馈来驱动

推迟到有多个消费者或自动化测试需要判断解析质量时引入。

### 6.6 `PhraseGroup` vs 扁平 `[PhraseItem]`

公共 API 的短语混在 specialSection 的文本里，难以按短语逐个拆分。HTML 路径可以按 `span.subEntry` 逐个提取。

设计为 `PhraseGroup` + `[PhraseItem]` 而非扁平列表，是因为：

- 词典中 PHRASES / PHRASAL VERBS / DERIVATIVES 是不同类别的东西
- 消费者可能只关心 PHRASAL VERBS 而不关心 DERIVATIVES
- `PhraseGroup.title` 保留了分类信息

对于公共 API 路径：如果无法按单个短语拆分，允许一个 PhraseItem 的 `phrase` 等于整段文本、`definition` 为 nil。这是 graceful degradation，不丢数据。

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
          "displayIndex": 0,
          "pronunciations": [],
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
          "displayIndex": 0,
          "pronunciations": [],
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
          "displayIndex": 1,
          "pronunciations": [],
          "senses": ["..."],
          "grammar": [],
          "inflections": []
        }
      ],
      "phraseGroups": [
        {
          "title": "PHRASAL VERB",
          "items": [
            {
              "phrase": "light up",
              "definition": null,
              "examples": []
            }
          ]
        }
      ],
      "notes": []
    }
  ],
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
          "partOfSpeech": "other(\"transitive verb\")",
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
          "displayIndex": 0,
          "pronunciations": [],
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
          "displayIndex": 1,
          "pronunciations": [],
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
          ]
        },
        {
          "title": "PHRASAL VERBS",
          "items": [
            {
              "phrase": "run across",
              "definition": "happen to meet or find",
              "examples": ["I just ran across him at the cafeteria"]
            }
          ]
        },
        {
          "title": "DERIVATIVES",
          "items": [
            { "phrase": "runnable", "definition": null, "examples": [] }
          ]
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
  "source": {
    "rawText": null,
    "rawHTML": "<d:entry ...>...</d:entry>"
  }
}
```

---

## 8. 从现有模型到 V3 的映射

| 当前概念 | V3 目标 |
|---------|---------|
| `DictionaryEntry.query` | `LookupResult.query` |
| `DictionaryEntry.headword` | `HeadwordEntry.headword` |
| `DictionaryEntry.pronunciations: [String]` | `HeadwordEntry.pronunciations: [Pronunciation]` |
| `DictionaryEntry.rawText` | `SourcePayload.rawText` (opt-in) |
| `DictionaryBlock` kind=partOfSpeech | `LexicalEntry` |
| `DictionaryBlock` kind=phrase | `PhraseGroup.items` 中的一项 |
| `DictionaryBlock` kind=specialSection, name=ORIGIN | `Note(kind: .etymology)` |
| `DictionaryBlock` kind=specialSection, name=PHRASAL VERBS | `PhraseGroup(title: "PHRASAL VERBS")` |
| `DictionaryBlock` kind=specialSection, name=DERIVATIVES | `PhraseGroup(title: "DERIVATIVES")` |
| `DictionaryBlock` kind=reference | `Note(kind: .reference)` |
| `DictionaryBlock` kind=abbreviation | `LexicalEntry(partOfSpeech: .other("abbreviation"))` |
| `DictionaryBlock` kind=fallback | `LexicalEntry(partOfSpeech: .other("unknown"))` + senses 只有一个元素 |
| `DictionaryBlock` kind=unknown | 同上 |
| `DictionaryBlock.label` (A/B/C) | `LexicalEntry.displayIndex` (0/1/2) |
| `DictionaryBlock.content` (整段文本) | 拆分到 `Sense.definition` + `Sense.examples` |
| `DictionaryBlock.name` (词性名) | `LexicalEntry.partOfSpeech` |

---

## 9. 公共 API 函数签名

```swift
/// 查词并返回结构化结果
public func lookup(
    _ term: String,
    source: LookupSource = .automatic,
    includeSource: Bool = false
) -> LookupResult?

public enum LookupSource: Sendable {
    /// 优先使用私有 API，回退到公共 API
    case automatic
    /// 仅使用公共 API (DCSCopyTextDefinition)
    case publicAPI
    /// 仅使用私有 API (DCSCopyRecordsForSearchString)
    case privateHTML(dictionaryName: String = "New Oxford American Dictionary")
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

- 新增 V3 快照测试，输出 `LookupResult` 的 JSON
- 旧快照通过 `asLegacyEntry()` 继续跑，确保 V1 不回退
- 两套快照并行运行至 V1 正式移除

### 10.3 CLI 输出

CLI 切换到 V3 输出。`--json` 输出 `LookupResult` JSON；`--legacy-json` 输出旧格式。

---

## 11. 优先级总览

| 优先级 | 编号 | 问题 | 路径 |
|:------:|------|------|------|
| P0 | 4.1 | content 未拆分义项 | 公共+私有 |
| P0 | 4.2 | 例句未从释义分离 | 公共+私有 |
| P1 | 4.3 | DictionaryBlock 万能桶 → 拆为三种类型 | 公共+私有 |
| P1 | 4.4 | name/content 信息重复 | 公共+私有 |
| P1 | 4.5 | 发音格式不一致 | 跨路径 |
| P1 | 4.6 | elaborate 多发音问题 | 公共 |
| P1 | 4.7 | HTML PHRASES 丢失释义 | 私有 |
| P1 | 4.8 | HTML label 始终为空 | 私有 |
| P2 | 4.9 | 语域标记未结构化 | 公共+私有 |
| P2 | 4.10 | HTML 语法/变形被丢弃 | 私有 |
| P2 | 4.11 | 可数性未结构化 | 公共+私有 |
| P2 | 4.12 | kind 用 String 非 enum | 公共+私有 |

---

## 12. 不做的事

| 不做 | 理由 |
|------|------|
| `Sense.subsenses: [Sense]` 递归 | 公共 API 数据全部扁平；HTML 子义项极少。等有真实需求再加 |
| `AudioResource` | macOS 词典 API 不提供音频 URL |
| `Identifiable` + ID 生成 | CLI + Anki 不需要跨会话 stable identity |
| `ParseDiagnostic` | 作者=消费者阶段，debug 用 SourcePayload 即可 |
| `DetailLevel` (minimal/standard/extended) | 无法定义各级包含什么，推迟 |
| 中文/拼音拆分 | 边界判断复杂，误判率高，收益有限 |
| `Translation` struct (text + reading + language) | 过度抽象。当前只有一种双语词典 |
