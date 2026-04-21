# 功能岛 2.6：带预览对比的词典选择器

## 1. 前因

当前 collection 的词典选择入口位于 `CollectionEditorSheet`，交互形式是一个普通 `Picker`：

- 用户只能看到词典名称
- 看不到不同词典的实际查词效果差异
- 不知道切换后会影响哪些内容
- 这是高影响设置，但缺少足够反馈

而词典选择本质上不是“填一个配置项”，而是“比较不同内容来源后做决策”。

用户真正关心的问题通常是：

- 这个词典更偏英英还是英汉
- 例句质量如何
- 发音展示是否更适合自己
- 有没有短语、用法、词源等附加信息
- 最终做出来的卡片会更接近哪种风格

因此本功能不应继续停留在表单型 `Picker`，而应升级为一个**带实时双栏预览的选择器**。

## 2. 功能目标

在 collection 编辑流程中，把“词典选择”从低反馈配置项升级为高反馈决策界面：

- 支持浏览和搜索可用词典
- 支持对当前词典与候选词典做实时对比
- 支持通过一个示例词快速预览差异
- 支持在不离开编辑 sheet 的前提下完成选择

目标不是做一个通用“词典浏览器”，而是帮助用户更快地回答：

- 我应该给这个 collection 绑定哪个词典
- 切换之后，我得到的词义、例句、发音，以及附加信息会更接近什么风格

## 3. 范围

覆盖内容：

- collection 创建 / 重命名 sheet 中的词典选择 UI 重构
- 可搜索的词典列表
- 示例词驱动的实时预览
- 当前词典 vs 候选词典的双栏对比
- 空状态、加载状态、失败状态

不覆盖内容：

- 跨 collection 的全局默认词典设置
- 多词典同时启用
- 词典打分、排序推荐或智能推荐
- 发音试听、批量比较、历史比较记录
- 针对每个单词的 per-word override

## 4. 产品结论

### 4.1 交互模型

词典选择器采用**左侧列表 + 右侧预览**的双栏布局：

- 左侧负责发现和选择
- 右侧负责验证和比较

不要再使用“下拉框 + 预览按钮”的串行交互。

原因：

- 下拉框适合低影响字段，不适合内容决策
- 预览按钮会把比较行为拆成多步，效率低
- 双栏布局更适合桌面端和 macOS 的扫描式阅读习惯

### 4.2 对比模型

预览区始终围绕两个对象展开：

- `Current`
- `Candidate`

其中：

- `Current` 表示当前 collection 已保存词典
- 若是新建 collection 且尚无已保存值，则 `Current` 视为 `Automatic`
- `Candidate` 表示当前在左侧列表中高亮或选中的词典

右侧默认采用并排双栏比较，而不是 tab 切换。

原因：

- 用户任务是比较，不是单独阅读
- 桌面端空间足够，双栏能显著降低短时记忆负担

### 4.3 预览粒度

右侧预览不应只展示固定三字段。

首版策略改为：

- 默认先展开最常用的数据块
- 右侧允许直接点开并浏览该词典返回的全部结构化数据
- 哪些块出现，取决于该词典当前对这个词实际返回了什么

优先展示的数据块：

- pronunciations
- lexical entries
- senses
- examples
- phrase groups
- notes

不要在 UI 层人为假设每个词典都能稳定提供同一套字段。

原因：

- 不同词典的丰富度天然不同
- 若强行压成固定字段，会把真实差异抹平
- 用户做选择时，恰恰需要看到“这个词典额外多了什么，少了什么”

### 4.4 示例词模型

预览必须由一个“示例词”驱动。

默认值建议：

- 若当前详情上下文可提供最近查过的词，则优先复用
- 否则默认使用 `apple`

用户可手动输入其他词进行比较。

原则：

- 默认词必须高频、稳定、几乎所有词典都有结果
- 用户一旦输入自定义词，在当前 sheet 生命周期内保持该值

### 4.5 Automatic 的展示语义

`Automatic` 不能只显示为空字符串或技术占位。

它在 UI 上应被解释为：

- “Use the system default fallback dictionary”

在预览区中，`Automatic` 实际解析为当前系统默认词典对应的结果。

但在文案层仍应保留 `Automatic` 身份，避免用户误以为它等于一个固定词典名。

## 5. 信息架构

### 5.1 Sheet 总体结构

```text
+----------------------------------------------------------------------------------+
| New Collection / Edit Collection                                                 |
|----------------------------------------------------------------------------------|
| Collection name: [__________________________]                                    |
|                                                                                  |
| Dictionary                                                                       |
| Choose the lookup source for definitions, examples, and pronunciation.           |
|                                                                                  |
| +-----------------------------+  +---------------------------------------------+ |
| | Search dictionaries         |  | Preview                                   | |
| | [ Oxford...            🔍 ] |  |-------------------------------------------| |
| |                             |  | Sample word: [ apple                 ]    | |
| | ○ Automatic                 |  |                                           | |
| |   System default fallback   |  |                                           | |
| |                             |  | +----------------+  +------------------+ | |
| | ● Oxford Dictionary...      |  | | Current        |  | Candidate         | | |
| |   English monolingual       |  | | [Pronunciation]|  | [Pronunciation]   | | |
| |   rich examples, clean IPA  |  | | [LexicalEntry] |  | [LexicalEntry]    | | |
| |                             |  | | [PhraseGroups] |  | [PhraseGroups]    | | |
| | ○ 牛津英汉汉英词典            |  | | [Notes]        |  | [Notes]           | | |
| |   bilingual, CN-friendly    |  | +----------------+  +------------------+ | |
| |                             |  |                                           | |
| | ○ New Oxford American...    |  |                                           | |
| |   system dictionary         |  |                                           | |
| |                             |  |                                           | |
| +-----------------------------+  |                                           | |
|                                  +---------------------------------------------+ |
|                                                                                  |
| Deck description                                                                 |
| [                                                                          ]     |
| [                                                                          ]     |
|                                                                                  |
| [Cancel]                                         [Use Selected Dictionary]       |
+----------------------------------------------------------------------------------+
```

### 5.2 左侧信息层级

左侧列表每个词典项最多显示三层：

1. 主名称
2. 短标签或定位描述
3. 轻量辅助说明

示例：

```text
Oxford Dictionary of English
English monolingual
Rich example coverage
```

```text
牛津英汉汉英词典
Bilingual
Better for CN-first reading
```

首版若拿不到结构化 metadata，可退化为：

- 第一行显示词典名
- 第二行显示基于名称规则推导的轻量标签
- 若无法推导则不显示第二行

### 5.3 右侧预览结构

右侧预览由四个块组成：

1. 预览控制栏
2. 双栏结果卡
3. 状态反馈

预览控制栏包含：

- sample word 输入框
- reload 按钮

双栏结果卡中每一栏不再固定为单一字段列表，而是由一组动态 section 组成。

建议基础 section 顺序：

1. source chip
2. headword summary
3. pronunciations
4. lexical entries
5. phrase groups
6. notes

其中：

- 如果某 section 没有数据，则不显示
- 如果某 section 数据过长，默认折叠，用户可点击展开
- 如果两侧都存在同类 section，则按同一顺序对齐显示
- 如果只有一侧存在，则另一侧显示 `Not available in this dictionary`

原因：

- 保持结果卡本身中性，不污染源内容
- 首版只展示两侧真实返回的数据，不再额外维护差异摘要或视图过滤状态

## 6. 详细线框

### 6.1 默认态

```text
+----------------------------------------------------------------------------------+
| Edit Collection                                                                  |
|                                                                                  |
| Collection name                                                                  |
| [ TOEFL Core Words                                                ]             |
|                                                                                  |
| Dictionary                                                                       |
| Choose the lookup source for definitions, examples, and pronunciation.           |
|                                                                                  |
| +-----------------------------------+  +---------------------------------------+ |
| | Search                            |  | Preview                               | |
| | [ Oxford                     🔍 ] |  | Sample word                           | |
| |                                   |  | [ apple                          ]    | |
| | ● Oxford Dictionary of English    |  |                                       | |
| |   English monolingual             |  |                                       | |
| |                                   |  |                                       | |
| | ○ Automatic                       |  | +----------------+ +----------------+ | |
| |   System default fallback         |  | | Current        | | Candidate      | | |
| |                                   |  | | ODE            | | ODE            | | |
| | ○ 牛津英汉汉英词典                  |  | | Pronunciation  | | Pronunciation  | | |
| |   Bilingual                       |  | | /ˈapəl/        | | /ˈapəl/        | | |
| |                                   |  | | Lexical Entry  | | Lexical Entry  | | |
| | ○ New Oxford American Dictionary  |  | +----------------+ +----------------+ | |
| |   System dictionary               |  |                                       | |
| +-----------------------------------+  | No meaningful difference for this word.| |
|                                        +---------------------------------------+ |
|                                                                                  |
| Deck description                                                                 |
| [                                                                          ]     |
| [                                                                          ]     |
|                                                                                  |
| [Cancel]                                                       [Save]            |
+----------------------------------------------------------------------------------+
```

### 6.2 候选词典与当前词典不同

```text
+----------------------------------------------------------------------------------+
| Preview                                                                           |
|                                                                                  |
| Sample word: [ apple ]                                                           |
|                                                                                  |
| +--------------------------------+  +-----------------------------------------+ |
| | Current                        |  | Candidate                               | |
| | Automatic                      |  | 牛津英汉汉英词典                          | |
| | [Pronunciation]                |  | [Pronunciation]                          | |
| | /ˈapəl/                        |  | /ˈapəl/                                  | |
| | [Lexical Entry: noun]          |  | [Lexical Entry: noun]                    | |
| | a round fruit with red ...     |  | 苹果；苹果树的果实                         | |
| | [Examples]                     |  | [Examples]                               | |
| | Apple trees are ...            |  | This apple is crisp and sweet.          | |
| | [Phrase Groups]                |  | Not available in this dictionary.       | |
| +--------------------------------+  +-----------------------------------------+ |
|                                                                                  |
|                                                                                  |
+----------------------------------------------------------------------------------+
```

### 6.3 搜索无结果

```text
+-----------------------------------+
| Search                            |
| [ longman                    🔍 ] |
|                                   |
| No dictionaries match "longman".  |
| Clear search to see all sources.  |
+-----------------------------------+
```

### 6.4 预览加载中

```text
+---------------------------------------+
| Preview                               |
| Sample word: [ apple ]                |
|                                       |
| Loading preview...                    |
| Comparing current and candidate data. |
+---------------------------------------+
```

### 6.5 示例词无结果

```text
+----------------------------------------------------------------------------------+
| Preview                                                                          |
| Sample word: [ qwertyuiop ]                                                      |
|                                                                                  |
| +--------------------------+  +------------------------------+                   |
| | Current                  |  | Candidate                    |                   |
| | No result for this word. |  | No result for this word.     |                   |
| +--------------------------+  +------------------------------+                   |
|                                                                                  |
| Try a more common word to compare dictionaries.                                  |
+----------------------------------------------------------------------------------+
```

### 6.6 单侧失败

```text
+----------------------------------------------------------------------------------+
| +-------------------------------+  +------------------------------------------+ |
| | Current                       |  | Candidate                                | |
| | /ˈapəl/                       |  | Preview unavailable.                     | |
| | a round fruit ...             |  | Could not load dictionary data.          | |
| | Apple pie ...                 |  |                                          | |
| +-------------------------------+  +------------------------------------------+ |
|                                                                                  |
| You can still save the selection, but preview is incomplete.                     |
+----------------------------------------------------------------------------------+
```

## 7. 视觉与布局规则

### 7.1 Sheet 尺寸

当前 `420` 宽度明显不足以承载比较任务。

建议首版尺寸：

- width: `920` 到 `980`
- minHeight: `620`

原则：

- 这是桌面端高价值编辑 sheet，可以更像一个轻量工作台
- 不要为了维持“小 sheet”而牺牲可读性

### 7.2 列宽比例

建议：

- 左侧列表区约 `34%`
- 右侧预览区约 `66%`

原因：

- 比较阅读的主要注意力在右侧
- 左侧只负责发现和切换，不需要平均分配

### 7.3 视觉权重

视觉重点顺序：

1. 右侧预览卡
2. 左侧当前候选高亮
3. 辅助说明和次级标签

不要让：

- 搜索框
- 描述文案
- deck description

抢走预览区的注意力。

### 7.4 候选状态表达

左侧词典项需要区分三种状态：

- current
- candidate
- current + candidate

建议视觉语义：

- `current`：次级 badge，例如 `Current`
- `candidate`：主选中高亮
- `current + candidate`：同时高亮并显示 `Current`

## 8. 交互设计

### 8.1 进入 sheet

进入 collection editor 时：

- 读取当前 collection 名称、deck description、dictionary selection
- 加载可用词典列表
- 默认把当前词典设为 `candidate`
- 右侧立即发起默认示例词预览

### 8.2 选择词典

点击左侧某个词典项时：

- 更新 `candidate`
- 右侧重算对比预览
- 不立即写入持久化

只有用户点击 `Save / Create` 后才真正持久化。

### 8.3 搜索

搜索只过滤左侧词典项，不修改已选 `candidate`。

若当前 `candidate` 被过滤掉：

- 右侧预览继续保留
- 左侧列表显示过滤结果

原因：

- 搜索是发现动作，不应打断当前比较上下文

### 8.4 输入示例词

用户在 sample word 输入框中提交后：

- 对 `current` 和 `candidate` 重新触发预览
- 若输入为空，不发请求，回退到默认词

建议交互：

- `TextField` + `onSubmit`
- 可加轻量 reload 按钮，但首版不是必须

### 8.5 不做视图过滤

首版不提供 `Overview / Senses / Phrases / Notes` segmented control。

原因：

- 当前预览区已经按实际返回内容分 section 展示
- 额外的视图过滤会引入一层状态，但对 collection 级词典选择的决策收益有限
- 保持预览行为简单：输入示例词、选择候选词典、直接看 current / candidate 两栏结果

### 8.6 右侧直接浏览与点击展开

右侧每个动态 section 都应支持直接点开查看更完整内容。

建议行为：

- 默认只显示每个 section 的前几行
- 点击 section header 或 `Show more` 后展开
- 展开只影响当前 pane，不联动另一侧
- 若某 section 在两侧都存在，可维持并排对比
- 若某 section 只在一侧存在，另一侧显示 `Not available in this dictionary`

这部分交互的目标不是做“摘要卡”，而是让用户能在当前 sheet 里直接看到词典查到的真实数据。

### 8.7 不做差异摘要

首版不提供规则化 `Diff summary`。

原因：

- 自动摘要需要额外维护比较规则，容易变成“看似智能但解释不完整”的判断层
- 当前目标是让用户直接比较词典真实返回内容，而不是替用户下结论
- 当前计划不把摘要作为后续默认 backlog

## 9. 状态机

### 9.1 左侧列表状态

- `idle`
- `loaded`
- `emptySearchResult`
- `loadFailed`

### 9.2 右侧预览状态

对每次示例词比较，右侧状态为：

- `idle`
- `loading`
- `loaded`
- `empty`
- `partialFailure`
- `failure`

其中：

- `empty` 表示两个词典都没有结果
- `partialFailure` 表示一侧成功、一侧失败
- `failure` 表示两侧都失败且无法展示有效预览

### 9.3 保存状态

保存沿用当前 collection editor 提交流程：

- `idle`
- `submitting`
- `failed`

词典预览失败不能阻断保存。

## 10. 数据与实现约束

### 10.1 数据来源

左侧词典列表继续来自：

- `SystemDictionaryClient().listAvailableDictionaries()`

右侧预览建议复用现有 lookup 管线，不新造解析路径。

优先方向：

- 通过现有 `ResolvedLookupService` / `SystemDictionaryClient` 获取结果
- 复用现有 `LookupResult` 解析后字段

不要在 UI 层直接做 HTML 解析或字符串切片。

### 10.2 预览数据结构

建议新增轻量 view data：

```swift
struct DictionaryPreviewComparison: Equatable, Sendable {
    let sampleWord: String
    let current: DictionaryPreviewPane
    let candidate: DictionaryPreviewPane
    let summary: [String]
}

struct DictionaryPreviewPane: Equatable, Sendable {
    let title: String
    let sourceDescription: String?
    let sections: [DictionaryPreviewSection]
    let state: DictionaryPreviewPaneState
}

struct DictionaryPreviewSection: Equatable, Sendable, Identifiable {
    let id: String
    let kind: DictionaryPreviewSectionKind
    let title: String
    let rows: [DictionaryPreviewRow]
    let isExpandable: Bool
}

struct DictionaryPreviewRow: Equatable, Sendable, Identifiable {
    let id: String
    let label: String?
    let value: String
    let emphasis: DictionaryPreviewRowEmphasis
}
```

这里的目标不是引入新的领域模型，而是：

- 保留 `LookupResult` 的结构差异
- 隔离 UI 显示逻辑
- 避免把 `LookupResult` 直接灌进视图

`sections` 应由 `LookupResult` 动态投影得到，而不是由 UI 预设一套固定字段。

### 10.3 动态 section 映射

建议的首版映射规则：

- `HeadwordEntry.pronunciations` -> `pronunciations`
- `HeadwordEntry.lexicalEntries` -> `lexicalEntries`
- `LexicalEntry.senses` -> `senses`
- `Sense.examples` -> `examples`
- `HeadwordEntry.phraseGroups` -> `phraseGroups`
- `HeadwordEntry.notes` -> `notes`

几个关键原则：

- 右侧展示的是“词典查到的数据”
- 不是“为了对比而重新发明一个摘要模型”
- 对比是建立在动态 section 之上的，而不是替代这些 section

### 10.4 元数据推导

若当前系统 API 只能返回词典名称，首版允许在 app 层提供一个轻量 metadata 映射：

- `Automatic` -> `System default fallback`
- 包含 `英汉` -> `Bilingual`
- 包含 `Oxford Dictionary of English` -> `English monolingual`
- 包含 `New Oxford American Dictionary` -> `System dictionary`

这类 metadata 应集中管理，不散落在 SwiftUI view 中。

## 11. 建议组件拆分

建议按以下粒度拆分：

- `CollectionEditorSheet`
- `DictionaryPickerSection`
- `DictionaryListPane`
- `DictionaryListRow`
- `DictionaryPreviewPane`
- `DictionaryPreviewSectionView`
- `DictionaryComparisonView`
- `DictionaryDiffSummaryView`

状态归属建议：

- sheet 级别表单状态仍在 `CollectionEditorSheet`
- 预览加载与比较状态应进入 view model 或专门的 preview model
- 不要把异步查词逻辑塞进多个子 view 的 `task` 里

## 12. 文案建议

推荐文案：

- `Choose the lookup source for definitions, examples, and pronunciation.`
- `Sample word`
- `No meaningful difference for this word.`
- `Try a more common word to compare dictionaries.`
- `Preview unavailable.`

避免：

- 过强推荐语气
- 技术实现导向文案，如 `private HTML lookup failed`

## 13. 实施阶段建议

### 13.1 第一阶段

先完成：

- 双栏布局
- 可搜索列表
- 默认示例词预览
- 动态 section 双栏结果卡
- 加载、失败、部分失败状态反馈

### 13.2 第二阶段

可后续追加：

- 更丰富的词典 metadata
- 分组展示
- 最近使用词典

## 14. 验收标准

本功能完成的标志：

- 用户可以在 collection editor 中扫描所有可用词典，而不是只看下拉菜单
- 用户可以输入一个示例词并看到当前词典与候选词典的并排差异
- 右侧可以直接浏览该词典实际返回的结构化数据，而不只是摘要字段
- 预览能根据词典实际返回内容动态展示 pronunciation、senses、phrases、notes 等区块
- 搜索、切换词典、修改示例词时，右侧预览能稳定刷新
- 预览失败不会阻断保存
- `Automatic` 在 UI 中具有明确、可理解的产品语义

## 15. 测试建议

优先补 view model / preview model 测试，而不是脆弱的 UI snapshot。

至少覆盖：

1. 初始进入 sheet 时，`candidate` 默认等于当前词典
2. 切换候选词典时，预览对比被重新加载
3. 输入示例词时，能正确刷新双侧预览
4. 搜索过滤不会丢失当前 `candidate`
5. 一侧返回 `phraseGroups` 而另一侧没有时，按动态 section 正确渲染
6. 一侧失败时进入 `partialFailure`
7. 双侧无结果时进入 `empty`
8. 点击 section 展开时，只影响当前 pane
9. 预览失败不影响 `Save / Create`
10. `Automatic` 能解析为合理的预览来源

## 16. 与当前实现的收敛方向

当前实现收敛目标明确为：

- 从 `Picker("Dictionary", selection: ...)` 收敛为可比较的双栏选择器
- 从“纯表单字段”收敛为“配置 + 验证”一体化工作区
- 从“只有名称”收敛为“名称 + 内容预期 + 示例词预览 + 动态原始数据浏览”

这次改造的核心价值不在视觉润色，而在于把词典选择从盲选变成可验证选择。
