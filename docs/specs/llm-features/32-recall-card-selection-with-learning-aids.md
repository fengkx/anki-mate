# Recall Card：基于 Learning Aids 的变体选择与 Structured Output 实施草案

## 1. 文档定位

本文回答的问题是：

- Recall Card 应如何从“UI 先拍板 mode，再让模型填内容”升级为“模型在约束下选择 mode，并输出单张稳定草稿”

本文默认前提：

- inference server 已支持 `json_schema` 形式的 structured output
- Recall 仍然是“一次只生成 1 张卡”的单卡工作流

本文不重复定义：

- Recall Card 的产品定义与状态机
- cue / hint 的质量标准
- Learning Aids 的产品边界

这些内容仍以：

- [30-recall-card-draft.md](./30-recall-card-draft.md)
- [31-recall-card-generation-rules.md](./31-recall-card-generation-rules.md)
- [40-pitfalls-and-usage-notes.md](./40-pitfalls-and-usage-notes.md)
- [11-prompt-architecture.md](./11-prompt-architecture.md)

为准。

## 2. 现状问题

当前实现存在三个核心问题：

### 2.1 mode 选择位置不对

当前 `Recall` 变体由 UI 层启发式决定：

- phrase -> `phraseRecall`
- 长词 -> `targetedLetterCloze`
- 其他 -> `fullSpelling`

这会导致：

- 变体选择过于粗糙
- 与 accepted 学习材料脱节
- 很难表达“长词但其实不该挖空”的情况

### 2.2 Recall prompt 没有吸收 accepted learning aids

当前 Recall prompt 主要依赖：

- `word`
- `senses`
- `mode`
- `anchor`
- 一个轻量 scaffold

但它没有显式吸收：

- `acceptedPitfalls`
- `acceptedUsageHints`
- `acceptedMnemonics`
- `acceptedCollocations`

这意味着 Recall 卡虽然名义上是下游学习产物，但实际上没有利用用户已经确认过的学习上下文。

### 2.3 当前输出 contract 不承载“为什么选这个 mode”

当前 Recall 输出只有：

- `mode`
- `front`
- `back`
- `hint`
- `anchor`

缺少一层轻量选择理由，导致：

- debug 难
- 测试难
- prompt 漂移后很难判断是 mode 选错还是文案写坏

## 3. 目标与非目标

## 3.1 目标

本次改造目标：

- 让 Recall 变体选择吸收 accepted learning aids
- 让 LLM 在约束下选择 mode，而不是 UI 直接拍板
- 使用 structured output 稳定 Recall 输出 contract
- 保留本地 post-check、repair 和 fallback
- 不扩大 Recall 的工作流复杂度

## 3.2 非目标

本次不做：

- 多张 Recall Card 并行生成
- 基于用户历史错题自动调节 Recall 策略
- 完全删除本地规则系统
- 让模型自由生成多种候选 draft 再做 rerank
- 在导出层重新推断 mode

## 4. 设计总览

目标状态：

1. UI 只负责收集上下文
2. LLMService 负责构建 `RecallGenerationContext`
3. prompt 告诉模型：
   - 可用的 modes
   - 当前 mode prior
   - accepted learning aids
   - 少量事实型 word-level signals
   - 单卡 Recall 的质量边界
4. 模型输出：
   - `draft`
   - `selectionReason`
5. 本地做 contract enforcement
6. 若 structured output 或内容质量失败，则走 rule-based fallback

一句话概括：

- `mode` 从“UI 决定”升级为“模型在规则护栏内决定”

## 5. 决策原则

Recall 变体选择应优先服务“单张卡的主学习目标”。

推荐先抽象为三种主目标：

- `whole_word_recall`
- `local_spelling_calibration`
- `phrase_chunk_retrieval`

再映射到具体 mode：

- `whole_word_recall` -> `full_spelling`
- `local_spelling_calibration` -> `targeted_letter_cloze`
- `phrase_chunk_retrieval` -> `phrase_recall`

这样做的原因：

- 避免模型直接在 UI 名词层面选 mode
- 强迫模型先思考“这张卡到底训练什么”
- 让测试更容易表达意图

## 6. 输入上下文设计

## 6.1 新增 Recall 生成上下文

建议新增：

```swift
public struct LLMRecallGenerationContext: Codable, Equatable, Sendable {
    public let acceptedPitfalls: [String]
    public let acceptedUsageHints: [String]
    public let acceptedMnemonics: [String]
    public let acceptedCollocations: [String]
}
```

约束：

- 只吸收 `accepted`
- 不吸收 `suggested`
- 所有字段都允许为空

## 6.2 新增词形 signals

建议新增：

```swift
public struct LLMRecallWordSignals: Codable, Equatable, Sendable {
    public let isPhrase: Bool
    public let hasRepeatedLetters: Bool
    public let hasConfusableVowelCluster: Bool
}
```

说明：

- `isPhrase`：词中有空格，或上游已知其为短语
- `hasRepeatedLetters`：是否存在双写或更明显的重复字母段
- `hasConfusableVowelCluster`：是否存在 `ie` / `ei` / `oa` / `ou` 等风险片段

这些 signals 不是为了替模型做决定，而是为了让 prompt 更稳定，并减少模型在低价值层面重复推理。

约束：

- 不向模型暴露 `recommendedMode`
- 不向模型暴露 risk score
- 不向模型暴露具体 `maskedSurface`
- 不通过 signal 直接把 LLM 压成模板执行器

## 6.3 prompt 输入裁剪策略

learning aids 进入 prompt 前必须裁剪，避免变成堆料入口。

推荐上限：

- `acceptedPitfalls`: 最多 2 条
- `acceptedUsageHints`: 最多 2 条
- `acceptedMnemonics`: 最多 1 条
- `acceptedCollocations`: 最多 2 条

归一化原则：

- trim whitespace
- 过滤空字符串
- 过滤超长内容
- 不保留编号与标签

## 7. 本地先验：allowed modes 与 mode prior

本次改造不建议完全移除本地先验。

建议保留两层轻量先验：

- `allowedModes`
- `modePrior`

## 7.1 allowed modes

`allowedModes` 是硬约束。

推荐规则：

### 场景 A：明显 phrase

- `allowedModes = [.phraseRecall]`

### 场景 B：明显没有局部拼写校准价值

如果满足以下条件中的多数：

- 没有 accepted pitfalls 指向具体拼写热点
- 不存在明显重复字母或元音簇风险
- 词整体较短，或语义回忆明显比拼写校准更重要

则：

- `allowedModes = [.fullSpelling]`

### 场景 C：存在局部拼写校准的可能

则：

- `allowedModes = [.fullSpelling, .targetedLetterCloze]`

说明：

- `allowedModes` 应尽量收敛，不宜默认对所有词开放全部模式

## 7.2 mode prior

`modePrior` 是软建议，不是硬约束。

推荐规则：

- phrase -> `.phraseRecall`
- accepted pitfalls 明确指向局部字母段，且 signals 明显支持 -> `.targetedLetterCloze`
- 其他 -> `.fullSpelling`

用途：

- 提示模型的默认方向
- 为 fallback 提供默认落点
- 让日志更容易解释当前选择

## 8. LLMService API 草案

建议新增主接口：

```swift
public func generateRecallCardDraft(
    word: String,
    senses: [LLMSensePromptInput],
    context: LLMRecallGenerationContext,
    allowedModes: [LLMRecallCardMode],
    modePrior: LLMRecallCardMode? = nil,
    anchor: LLMAnchorSnapshot? = nil
) async throws -> LLMRecallCardDraft
```

建议旧接口保留一层兼容桥接：

```swift
public func generateRecallCardDraft(
    word: String,
    senses: [LLMSensePromptInput],
    mode: LLMRecallCardMode,
    anchor: LLMAnchorSnapshot? = nil
) async throws -> LLMRecallCardDraft
```

桥接策略：

- `allowedModes = [mode]`
- `modePrior = mode`
- `context = .init()`

这样可以：

- 减少一次性改动面
- 保留旧测试的最小兼容性

## 9. Structured Output 设计

## 9.1 返回 envelope

建议 Recall 不再只返回裸 draft，而是返回 decision envelope：

```swift
public struct RecallCardDraftDecisionEnvelope: Codable, Equatable, Sendable {
    public let draft: LLMRecallCardDraft
    public let selectionReason: LLMRecallSelectionReason?
}
```

其中：

```swift
public struct LLMRecallSelectionReason: Codable, Equatable, Sendable {
    public let primaryGoal: String
    public let evidence: [String]
}
```

约束：

- `selectionReason` 主要用于 debug / log / tests
- 默认不需要写入持久化层

## 9.2 JSON Schema 草案

建议 Recall generation 使用 `json_schema + strict: true`。

推荐 schema 形状：

```json
{
  "type": "object",
  "additionalProperties": false,
  "required": ["draft"],
  "properties": {
    "draft": {
      "type": "object",
      "additionalProperties": false,
      "required": ["mode", "front", "back"],
      "properties": {
        "mode": {
          "type": "string",
          "enum": ["full_spelling", "targeted_letter_cloze", "phrase_recall"]
        },
        "front": {
          "type": "string",
          "minLength": 1,
          "maxLength": 120
        },
        "back": {
          "type": "string",
          "minLength": 1,
          "maxLength": 120
        },
        "hint": {
          "type": ["string", "null"],
          "maxLength": 80
        },
        "anchor": {
          "type": ["object", "null"],
          "additionalProperties": false,
          "required": ["text"],
          "properties": {
            "text": { "type": "string" },
            "note": { "type": ["string", "null"] }
          }
        }
      }
    },
    "selectionReason": {
      "type": ["object", "null"],
      "additionalProperties": false,
      "required": ["primaryGoal", "evidence"],
      "properties": {
        "primaryGoal": {
          "type": "string",
          "enum": [
            "whole_word_recall",
            "local_spelling_calibration",
            "phrase_chunk_retrieval"
          ]
        },
        "evidence": {
          "type": "array",
          "maxItems": 3,
          "items": {
            "type": "string",
            "maxLength": 120
          }
        }
      }
    }
  }
}
```

## 9.3 为什么不用“drafts[]”

Recall 在产品层面仍是单卡工作流。

因此不建议返回：

- 多 mode 候选列表
- multi-draft batch
- ranking 输出

否则会带来：

- UI 状态复杂化
- mode 选择责任不清
- 测试成本升高

## 10. Prompt 设计草案

## 10.1 system prompt

建议方向：

```text
You are a bilingual language learning assistant.
Generate exactly one recall-oriented flashcard draft as strict structured output.
Choose the most appropriate mode from the allowed modes.
Base the choice on the main recall objective, accepted learning aids, and spelling risk.
Do not overpack the front with explanations.
```

## 10.2 user prompt 结构

建议按以下区块组织：

1. Target
2. Sense inventory
3. Accepted learning aids
4. Word signals
5. Allowed modes
6. Mode prior
7. Rules

示意：

```text
Generate exactly 1 recall card draft for the target "collocation".

Sense inventory
1. noun: habitual word pairing

Accepted learning aids
- Pitfalls:
  - Learners often miss the double "l"
  - The middle vowel sequence is easy to get wrong
- Usage hints:
  - Usually refers to natural word pairings
- Mnemonics:
  - co + location of words
- Collocations:
  - strong collocation
  - natural collocation

Word signals
- isPhrase: false
- hasRepeatedLetters: true
- hasConfusableVowelCluster: true

Allowed modes
- full_spelling
- targeted_letter_cloze

Mode prior
- suggested primary mode: targeted_letter_cloze

Rules
- Choose the mode that best matches the main learning objective
- Prefer full_spelling when the learner mainly needs whole-word retrieval
- Prefer targeted_letter_cloze only when there is a clear local spelling hotspot
- Do not choose targeted_letter_cloze only because the word is long
- Use accepted usage hints to narrow the Chinese cue
- Use mnemonics only for a very short hint when useful
- Do not dump learning aids into the front
- Return one draft only
```

## 10.3 prompt 中必须强调的规则

建议加入如下硬规则：

- `mode` must be one of the allowed modes
- choose one primary learning objective first, then choose the mode
- do not choose `targeted_letter_cloze` only because the word is long
- use accepted usage hints to sharpen the Chinese cue, not to write a long explanation
- use mnemonics only for a very short hint
- do not dump pitfalls, usage hints, and collocations into the front
- return exactly one draft

对 `targeted_letter_cloze` 还应补充专门规则：

- choose the gap position yourself; do not expect a pre-selected masked segment
- use exactly one continuous gap
- the gap should usually be 2 or 3 characters long
- prefer internal spelling hotspots such as repeated consonants, confusable vowel clusters, or unstable suffix fragments
- do not default to masking the first letter
- do not hide too much of the word
- do not make the card feel like a puzzle
- keep a clear Chinese cue on the front
- put the masked target surface on the front, not on the back
- keep `back` equal to the exact target with no underscores
- if accepted pitfalls point to a local spelling risk, align the gap with that risk when possible

## 11. 本地 post-check 与 repair

structured output 不是质量保证的终点，Recall 仍然需要本地 post-check。

## 11.1 通用校验

- `mode` 必须在 `allowedModes` 里
- `back` 必须精确等于目标词
- `front` 不能为空
- `hint` 可为空，但若存在应较短

## 11.2 `full_spelling` 校验

不应允许：

- front 暴露完整答案
- front 出现过多英文词形片段
- front 变成解释性摘要

## 11.3 `targeted_letter_cloze` 校验

必须满足：

- `front` 中存在 `_`
- 挖空应为单一连续片段
- 缺口长度优先 `2` 或 `3`
- 不应默认优先挖首字母
- front 仍应保留清晰中文 cue
- `back` 必须保持完整原词，不能带 `_`

若模型输出 drift：

- 不再用 prompt 输入中的预选 mask 修正
- 本地只做质量检查与必要降级
- 若 cloze 质量过低，可降级为 `full_spelling`，或进入 rule-based fallback

## 11.4 hint 校验

建议限制：

- 长度不超过 40 到 60 字符
- 不重复 front
- 不直接暴露完整答案
- 不重复完整 usage summary

## 11.5 降级策略

若 structured output 或 post-check 失败：

1. 若 `modePrior` 存在，先以 `modePrior` 为目标走 rule-based fallback
2. 若 `modePrior` 不存在，使用默认 fallback
3. `targeted_letter_cloze` fallback 继续使用本地稳定 mask

## 12. UI 与调用链改造

## 12.1 UI 层职责变化

UI 不再负责最终决定 Recall mode。

UI 层只负责：

- 提取 `senses`
- 提取 accepted learning aids
- 生成 `allowedModes`
- 生成 `modePrior`
- 发起单次 Recall 生成请求

## 12.2 `AIContentView` / `CardPreviewView`

建议将当前的：

- `defaultRecallMode`

改造为两类值：

- `allowedRecallModes`
- `recallModePrior`

并将 accepted learning aids 从 `item.aiArtifacts` 中提取出来，传给新的 `generateRecallCardDraft(...)`。

## 13. 导出层策略

导出层不应重新判断 Recall mode。

导出继续遵循：

- 保存了什么 accepted Recall draft
- 导出就使用什么 mode / front / back / hint

这样可以保持：

- 用户编辑的结果不被二次覆盖
- 训练与导出的一致性

## 14. 测试方案

## 14.1 Prompt tests

新增测试覆盖：

- prompt 是否包含 accepted pitfalls
- prompt 是否包含 accepted usage hints
- prompt 是否包含 accepted mnemonics
- prompt 是否包含 accepted collocations
- prompt 是否包含 allowed modes
- prompt 是否包含 mode prior
- prompt 是否包含 word signals

## 14.2 LLMService 单测

建议新增：

- 当 mode 不在 `allowedModes` 内时，输出被 reject
- `targeted_letter_cloze` 没有 `_` 时被 reject
- drifted mask 会被 repair
- accepted pitfalls 明确指向局部字母段时，prior 倾向 cloze
- 没有局部风险时，`allowedModes` 只包含 `full_spelling`

## 14.3 E2E baseline

建议至少覆盖五类 baseline：

- 短词、规则词，期望 `full_spelling`
- 长词但无明确局部风险，不应仅因长度切 cloze
- accepted pitfalls 指向局部拼写热点，期望 `targeted_letter_cloze`
- phrase，期望 `phrase_recall`
- 有 spelling signal 但没有 accepted evidence，不应被 signal 带偏

## 14.4 Recall baseline 示例

以下示例用于固定 Recall 选择与输出质量的回归方向。

### A. 应选 `full_spelling`

```yaml
id: recall_perpetual_whole_word
word: perpetual
senses:
  - partOfSpeech: adjective
    definition: 持续不断的；长期不止的
acceptedPitfalls: []
acceptedUsageHints:
  - 常用于表示问题、噪音、争论等持续不止
acceptedMnemonics: []
acceptedCollocations: []
allowedModes: [full_spelling, targeted_letter_cloze]
expected:
  preferredMode: full_spelling
  primaryGoal: whole_word_recall
  frontContains: [持续]
  frontExcludes: [perpetual]
```

```yaml
id: recall_reluctant_not_cloze_by_length
word: reluctant
senses:
  - partOfSpeech: adjective
    definition: 不情愿的；勉强的
acceptedPitfalls: []
acceptedUsageHints:
  - 常接 to do something，表示不愿意做
acceptedMnemonics: []
acceptedCollocations: []
allowedModes: [full_spelling, targeted_letter_cloze]
expected:
  preferredMode: full_spelling
  primaryGoal: whole_word_recall
```

### B. 应选 `targeted_letter_cloze`

```yaml
id: recall_collocation_local_spelling
word: collocation
senses:
  - partOfSpeech: noun
    definition: 固定搭配；常见词语搭配
acceptedPitfalls:
  - 容易漏掉双写的 ll
  - 中间元音和后半段顺序容易写错
acceptedUsageHints:
  - 指自然的词语搭配，不是任意两个词放在一起
acceptedMnemonics: []
acceptedCollocations:
  - strong collocation
allowedModes: [full_spelling, targeted_letter_cloze]
expected:
  preferredMode: targeted_letter_cloze
  primaryGoal: local_spelling_calibration
  cloze:
    required: true
    singleContinuousGap: true
    minGapLength: 2
    maxGapLength: 3
    mustAvoidPrefixGap: true
    mustContainChineseCue: true
```

```yaml
id: recall_receive_ie_order
word: receive
senses:
  - partOfSpeech: verb
    definition: 收到；接收
acceptedPitfalls:
  - i 和 e 的顺序很容易写反
acceptedUsageHints: []
acceptedMnemonics: []
acceptedCollocations: []
allowedModes: [full_spelling, targeted_letter_cloze]
expected:
  preferredMode: targeted_letter_cloze
  primaryGoal: local_spelling_calibration
  cloze:
    required: true
    singleContinuousGap: true
    minGapLength: 2
    maxGapLength: 3
```

### C. 不应被 signal 带偏

```yaml
id: recall_necessary_resist_signal_bias
word: necessary
senses:
  - partOfSpeech: adjective
    definition: 必要的；必需的
acceptedPitfalls: []
acceptedUsageHints:
  - 表示某事是必须的，不可避免的
acceptedMnemonics: []
acceptedCollocations: []
allowedModes: [full_spelling, targeted_letter_cloze]
expected:
  preferredMode: full_spelling
  primaryGoal: whole_word_recall
```

```yaml
id: recall_available_not_auto_cloze
word: available
senses:
  - partOfSpeech: adjective
    definition: 可获得的；可用的
acceptedPitfalls: []
acceptedUsageHints:
  - 常表示资源、信息、人有空或可获得
acceptedMnemonics: []
acceptedCollocations: []
allowedModes: [full_spelling, targeted_letter_cloze]
expected:
  preferredMode: full_spelling
  primaryGoal: whole_word_recall
```

### D. `phrase_recall`

```yaml
id: recall_take_off_phrase
word: take off
senses:
  - partOfSpeech: verb
    definition: 起飞；脱下
acceptedPitfalls: []
acceptedUsageHints:
  - 在飞机语境中表示起飞
acceptedMnemonics: []
acceptedCollocations: []
allowedModes: [phrase_recall]
expected:
  preferredMode: phrase_recall
  primaryGoal: phrase_chunk_retrieval
```

### E. Learning aids 应帮助收束 cue，而不是堆料

```yaml
id: recall_sustain_usage_guided_cue
word: sustain
senses:
  - partOfSpeech: verb
    definition: 支撑；维持；持续遭受
acceptedPitfalls: []
acceptedUsageHints:
  - 在抽象语境里常表示维持某种状态、努力或增长
acceptedMnemonics: []
acceptedCollocations: []
allowedModes: [full_spelling, targeted_letter_cloze]
expected:
  preferredMode: full_spelling
  primaryGoal: whole_word_recall
  frontContains: [维持]
  frontExcludes: [支撑；维持；持续遭受]
```

## 15. 分阶段落地建议

## 15.1 Phase 1

先完成 app 侧 contract 改造：

- 新增 `LLMRecallGenerationContext`
- 新增 `LLMRecallWordSignals`
- 改 Recall prompt
- 改 Recall service 接口
- 改 UI 调用链
- 增加 selectionReason
- 保留 post-check 与 fallback

## 15.2 Phase 2

接通 inference server 的 `json_schema + strict`：

- `RPCDispatcher` 透传 `responseFormat`
- `InferenceEngine` 根据 schema 进行受约束生成
- Recall generation 切到 `json_schema`

## 15.3 Phase 3

按模型能力做 runtime gating：

- 支持 schema 的模型使用 `json_schema`
- 不支持 schema 的模型降级为 `.json`

但无论哪种模式，都保留本地 post-check。

## 16. 拍板建议

建议本次 Recall 改造采用以下原则：

- 不把 mode 选择继续放在 UI 层
- 不把 mode 选择完全无约束地交给模型
- 用 accepted learning aids + allowed modes + mode prior + structured output 一起完成 Recall 生成
- 把 structured output 当作 contract 保证
- 把本地 post-check 当作最终质量护栏

最小可行方向是：

- 让模型在 `allowedModes` 内做选择
- 输出单张 draft 和轻量选择理由
- 本地继续修正 cloze mask 与降级 fallback

这条路径比“继续堆 UI 启发式”更灵活，也比“完全自由生成”更稳。
