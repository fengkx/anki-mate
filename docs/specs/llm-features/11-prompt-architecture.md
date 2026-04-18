# Prompt 设计：统一架构与 Contract

## 1. 文档定位

本文件只回答一个问题：

- anki-mate 的 LLM prompt 应该如何稳定设计，才能长期支撑多个学习能力

它不展开某个具体能力的 UI 细节，也不取代各功能岛文档。

建议阅读顺序：

1. 先看 [01-overview.md](./01-overview.md)
2. 再看本文
3. 然后进入对应能力专题

## 2. 为什么需要统一 prompt 架构

当前仓库已经有：

- 例句生成
- Usage Hint 生成
- Recall Card Draft 生成
- Learning Aids 生成

如果每一类能力都各自堆 prompt 文案，会很快出现这些问题：

- 输入字段不一致
- 输出格式不稳定
- 不同能力之间边界混乱
- 很难做自动化测试
- 换模型后行为漂移难以定位

因此 prompt 设计必须从“写一段文案”升级为“定义一套稳定 contract”。

## 3. 五层 prompt 架构

一期统一采用五层设计：

1. `Role layer`
2. `Task layer`
3. `Input contract layer`
4. `Output contract layer`
5. `Post-check layer`

### 3.1 Role layer

这是相对稳定的 system prompt 层，定义模型的身份与行为边界。

统一原则：

- 模型不是泛聊天助手
- 模型是 bilingual vocabulary learning copilot
- 目标是生成可学习、可采纳、可导出的学习材料
- 优先：
  - correctness
  - clarity
  - recall usefulness
- 不输出自我解释
- 不输出 markdown fence
- 不输出无关寒暄

### 3.2 Task layer

这一层定义“当前能力到底要解决什么学习问题”。

每类能力必须先有清晰产品定义，再写 prompt：

- `Examples`
  - 生成自然、可学习、尽量覆盖不同义项的例句
- `Usage`
  - 生成帮助用户理解如何使用该词的短提示
- `Pitfalls`
  - 生成帮助用户避免常见错误的短警示
- `Mnemonics`
  - 生成极短记忆钩子
- `Collocations`
  - 生成高频搭配与短 pattern
- `Recall Card`
  - 生成可保存为正式卡片的主动回忆草稿

### 3.3 Input contract layer

所有 prompt 应尽量共享同一套上游上下文，而不是每个能力手工拼接字段。

推荐统一输入上下文：

```text
PromptContext
- headword
- languagePair
- senses[]
  - partOfSpeech
  - definition
  - semanticHint?
- dictionaryExamples[]?
- acceptedExamples[]?
- acceptedUsageHints[]?
- acceptedLearningAids
  - pitfalls[]
  - mnemonics[]
  - collocations[]
- recallMode?
- anchor?
```

说明：

- `accepted` 比 `suggested` 更适合作为下游生成上下文
- `Recall` 应优先吸收 `acceptedLearningAids`
- `anchor` 只用于 display snapshot，不参与 fuzzy remap

### 3.4 Output contract layer

prompt 的目标不是“生成一段看起来不错的话”，而是“生成可以直接进入 UI 的结构化数据”。

统一原则：

- 字段语义稳定
- 字段值可直接显示
- 不让模型自创格式
- 能够被自动校验
- 尽量带 `senseIndex`，便于多义项覆盖与测试

推荐方向：

- `Examples`：使用 JSON
- `Usage`：从 plain lines 演进为 JSON
- `Learning Aids`：继续使用结构化 JSON
- `Recall`：生成单草稿 JSON，而不是多 mode 批量结果

这里的重点不是一次性重写所有实现，而是先冻结目标 contract。
即使仓库中仍有旧的 plain-text 或 multi-draft 路径，后续 prompt 和测试也应以本文 schema 作为目标行为。

### 3.5 Post-check layer

不要把 prompt 视为唯一质量保证手段。

生成后必须有轻量 post-check：

- 过滤编号、标签、markdown
- 校验 item 数量
- 校验 `senseIndex` 是否越界
- 校验 Recall draft 的 mode/front/back/hint 是否齐全
- 校验 targeted letter cloze 是否满足一期规则
- 对明显坏输出做 reject / retry / sanitize

## 4. 通用 prompt 设计原则

### 4.0 Prompt Authoring Hygiene

除了模型行为约束，prompt 在代码里的组织方式也需要稳定。

Swift 多行字符串在这些场景下很脆弱：

- 条件片段插入
- 大段 JSON 示例内联
- 多层插值与缩进混写
- retry / fallback 文案直接嵌进同一个 `""" ... """`

因此实现层建议遵循以下约定：

- 超过约 8 行、或包含条件分支的 prompt，不要写成单个三引号字符串
- 优先按段落构造，再统一 `join`
- `Dialect`、`Sense inventory`、`Existing IPA` 这类块优先用统一 helper 生成
- JSON 示例单独作为一个稳定片段，不和条件逻辑混写
- `Rules` 优先由字符串数组生成，避免手工维护长段 bullet 文本

推荐模式：

```swift
let prompt = PromptText.join([
    "Task sentence.",
    PromptText.labeledBlock("Sense inventory", value: senseInventoryText(from: senses)),
    jsonSchemaBlock,
    PromptText.labeledBlock("Rules", value: PromptText.bulletList(ruleLines))
])
```

目标不是减少 prompt 内容，而是把 Swift 语法边界和 prompt 内容边界分开，降低编译期字符串错误。

### 4.1 先定义任务，再写文案

任何 prompt 变更都应先回答：

- 这个能力解决什么学习问题
- 不解决什么问题
- 与相邻能力的边界是什么

### 4.2 负向约束比正向鼓励更重要

本地小模型很容易滑向：

- 解释型废话
- 编号列表
- 自创标签
- 混入其他能力的内容

因此每类 prompt 都必须明确写出：

- `Do not write example sentences`
- `Do not output collocation lists`
- `Do not add labels`
- `Return JSON only`

### 4.3 多义项优先覆盖，不优先凑数量

对多义项词，优先规则：

- 先覆盖主要义项
- 再考虑补充数量
- 若只有一个义项，再在单义项内扩展不同上下文或不同 usage angle

### 4.4 Recall 优先稳定，不优先花样

Recall 类任务是高度受约束的生成。

一期原则：

- 一次只生成 1 张 Recall draft
- 不要求模型同时产出多个 mode
- `targeted_letter_cloze` 应尽量 rule-first
- prompt 更适合负责 learner-facing packaging，而不是自由决定 mask 策略

## 5. 推荐 schema 方向

### 5.1 Examples

```json
{
  "examples": [
    {
      "english": "The debate became a perpetual source of disagreement.",
      "translation": "这场争论成了持续不断的分歧来源。",
      "senseIndex": 2
    }
  ]
}
```

### 5.2 Usage

```json
{
  "usageHints": [
    {
      "text": "Often describes ongoing problems or conditions rather than one-time events.",
      "translation": "常描述持续存在的问题或状态，而不是一次性事件。",
      "kind": "usage_tendency",
      "senseIndex": 2
    }
  ]
}
```

### 5.3 Pitfalls

```json
{
  "pitfalls": [
    {
      "summary": "Do not confuse perpetual with permanent.",
      "translation": "不要把 perpetual 和 permanent 混淆。",
      "category": "confusable_word",
      "senseIndex": 2
    }
  ]
}
```

### 5.4 Recall

```json
{
  "draft": {
    "mode": "targeted_letter_cloze",
    "front": "perpe__al + 持续不断的",
    "back": "perpetual",
    "hint": "Focus on the middle tu segment.",
    "anchor": null
  }
}
```

## 6. 测试导向要求

prompt 设计需要天然支持可选 E2E 测试。

目标不是要求每个模型都输出完全一致文本，而是验证：

- 输出 schema 是否稳定
- 是否满足 item 数量约束
- 是否覆盖多义项策略
- 是否避免编号、标签、markdown
- `targeted_letter_cloze` 是否满足规则
- `Pitfalls` 与 `Usage` 是否没有明显串类

这些测试只在本地存在可用模型权重时运行。

更完整的测试分层方案见：

- [12-prompt-quality-baseline-tests.md](./12-prompt-quality-baseline-tests.md)

## 7. 当前对实现的直接要求

基于现阶段讨论，后续实现应逐步收敛到以下方向：

- `Usage` 从 plain lines 改成 structured JSON
- `Pitfalls` 与 `Usage` 分离 schema，不再都退化成普通字符串
- `Recall` 从“多 mode 批量生成”收敛为“单 draft 生成”
- 下游 UI 与导出逻辑优先使用结构化字段，而不是再做字符串二次解析
- `PromptContext` 以 accepted artifacts 为主输入，不让 suggested 内容污染下游生成
- legacy multi-draft wording 只允许短期存在于兼容层，不应继续扩散到新 prompt / 新测试

## 8. 验收点

- 每类 LLM 能力都能指出自己的产品目标与禁止越界项
- prompt 设计能明确映射到统一输入上下文
- 输出结构能够被程序稳定解析
- 多义项覆盖策略在 `Examples` 和 `Usage` 上可被自动验证
- `Recall` 生成遵循单草稿工作台模型
- legacy multi-draft prompt contract 不再作为目标行为新增依赖
- prompt 相关 E2E 测试具备可选运行路径
