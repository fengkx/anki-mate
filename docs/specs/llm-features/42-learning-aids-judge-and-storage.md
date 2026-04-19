# Learning Aids：Judge Pass 与 JSON Persistence

## 1. 文档定位

本文定义 `Learning Aids` 在一期中的两类实现约束：

- LLM 生成候选后，如何通过 `judge pass` 与本地 guardrails 选出 `recommended` 与 `alternatives`
- 这些 AI artifacts 如何以 SQLite 承载 JSON 的方式持久化

本文不重新定义：

- `Pitfalls`、`Usage`、`Mnemonics`、`Collocations` 各自的产品边界
- `Recall Card` 的产品定义

相关文档仍以：

- [40-pitfalls-and-usage-notes.md](./40-pitfalls-and-usage-notes.md)
- [41-pitfalls-vs-usage.md](./41-pitfalls-vs-usage.md)
- [30-recall-card-draft.md](./30-recall-card-draft.md)
- [31-recall-card-generation-rules.md](./31-recall-card-generation-rules.md)

为准。

## 2. 设计目标

本设计解决的不是“如何再生成更多内容”，而是：

- 当一个 section 里有多条候选时，默认应该推荐哪一条
- 哪些内容虽然可保留，但应降为 `alternative`
- 哪些内容与已有 accepted 材料存在学习点重叠
- 如何在 schema 仍处于演进阶段时，稳定落库

一期目标是：

- 降低用户的采纳决策成本
- 减少重复采纳
- 让 Learning Aids 更直接服务 Recall 与导出质量

## 3. 总体架构

一期采用三段式流程：

1. `Generator LLM`
   - 生成候选 items
   - 输出严格 JSON
   - 不负责最终推荐
2. `Judge LLM`
   - 在候选中选出 `recommended`
   - 标注 `alternative`
   - 标注 overlap hints
   - 不生成新内容
3. `Local Rules`
   - 做结构校验、硬约束、fallback
   - 不重做完整语义排序

原则：

- 语言层判断交给 LLM
- 产品硬边界与稳定性由本地代码保证
- 避免在本地实现一整套脆弱的精细打分系统

## 4. Section 范围

一期适用于：

- `Pitfalls`
- `Usage`
- `Mnemonics`
- `Collocations`

每个 section 独立执行：

- generator pass
- judge pass
- local guardrails

但 judge 在判断 overlap 时可以读取其他相关 section 的 accepted items。

## 5. Generator Pass

### 5.1 职责

`Generator LLM` 只负责生成候选，不负责裁决。

它应：

- 为当前 section 生成 `1-3` 条候选
- 尽量覆盖不同学习点
- 尽量避免与 accepted 内容完全重复
- 输出严格 JSON

它不应：

- 标记 `recommended`
- 输出排序分数
- 发明 overlap 关系
- 改写已 accepted 内容

### 5.2 输入 contract

推荐输入：

```text
- headword
- sectionType
- languagePair
- senses[]
- acceptedItemsInSection[]
- acceptedItemsInRelatedSections[]
```

其中：

- `acceptedItemsInSection[]`
  - 当前 section 已采纳内容
- `acceptedItemsInRelatedSections[]`
  - 与当前 section 容易发生重叠的其他 section accepted 内容

示例：

- `Pitfalls` judge 时，可读取已 accepted `Usage`
- `Usage` judge 时，可读取已 accepted `Pitfalls`
- `Mnemonics` judge 时，可读取已 accepted `Pitfalls`

### 5.3 候选 item 最小字段集

一期建议每条 candidate 至少包含：

```json
{
  "id": "cand_1",
  "text": "Do not confuse perpetual with permanent.",
  "translation": "不要把 perpetual 和 permanent 混淆。",
  "category": "confusable_word",
  "focus": "meaning_contrast",
  "recallRelevant": true,
  "senseIndex": 0
}
```

说明：

- `id`
  - 仅在本次生成批次内唯一
- `text`
  - learner-facing 英文主文本
- `translation`
  - 中文对应解释
- `category` / `kind`
  - 当前 section 内的轻量结构类型
- `focus`
  - 该条内容主要服务的学习点
- `recallRelevant`
  - 该条内容是否直接有助于 recall-oriented 学习动作
- `senseIndex`
  - advisory metadata，不是稳定 identifier

### 5.4 `recallRelevant` 的定义

`recallRelevant` 表示：

- 这条内容是否直接有助于主动回忆
- 是否可能直接改善 `Recall Card` 的 cue、hint 或 variant 选择

它不是：

- 质量分
- 推荐分
- 必然采纳标记

推荐判定方式：

- 若该内容可直接帮助避免 recall 时的典型错误，则通常为 `true`
- 若该内容主要服务理解扩展或语气补充，而非回忆，则通常为 `false`

### 5.5 `senseIndex` 的定位

`senseIndex` 只作为生成时的弱定位信息存在。

它：

- 可以存
- 便于调试与短期上下文推断

它不应：

- 作为长期稳定外键
- 作为 accepted artifact 的强 identity
- 作为 dictionary refresh 后必须 remap 的唯一依据

## 6. Generator Prompt 设计

### 6.1 目标

generator prompt 的目标是：

- 生成短、小、结构化的候选
- 不做推荐决策
- 不越权到 judge 的职责

### 6.2 Prompt 结构

推荐固定为四段：

1. role
2. task
3. constraints
4. output contract

### 6.3 示例：Pitfalls generator

```text
You are generating short learner-facing vocabulary pitfalls.

Task:
Generate up to 3 candidate pitfalls for the given English headword.
Each candidate should teach a different likely mistake.

Constraints:
- Keep each item short and easy to scan.
- Focus on likely mistakes: spelling traps, confusable words, meaning misdirection, or common misuse.
- Do not write full example sentences.
- Do not write broad usage summaries unless they clearly describe a likely misuse.
- Do not rank, recommend, or score the items.
- Avoid repeating accepted material if it adds no new learning value.
- Return JSON only.

Output:
{
  "candidates": [
    {
      "id": "cand_1",
      "text": "...",
      "translation": "...",
      "category": "spelling_trap | confusable_word | meaning_misdirection | common_misuse",
      "focus": "spelling_segment | meaning_contrast | misuse_pattern | usage_context",
      "recallRelevant": true,
      "senseIndex": 0
    }
  ]
}
```

### 6.4 Generator post-check

本地对 generator 输出应至少做：

- JSON parse 校验
- required fields 校验
- section 类型合法性校验
- item 数量上限校验
- 去除空文本或明显损坏项

## 7. Judge Pass

### 7.1 职责

`Judge LLM` 负责在当前 section 的候选中做编辑式选择。

它应：

- 选出最多 `1` 条 `recommended`
- 将其余有效项标为 `alternatives`
- 标注与 accepted items 或高优先候选的 overlap
- 给出一句很短的推荐理由

它不应：

- 改写候选文本
- 新增候选
- 删除候选
- 输出新的学习内容

### 7.2 Judge 输入

推荐输入：

```text
- sectionType
- headword
- senses[]
- candidates[]
- acceptedItemsInSection[]
- acceptedItemsInRelatedSections[]
- product rules
```

judge 的核心问题不是“哪条最正确”，而是：

- 如果用户这一类内容只采纳一条，哪条最值得作为默认推荐

### 7.3 Judge 输出 contract

推荐 schema：

```json
{
  "recommendedId": "cand_2",
  "alternativeIds": ["cand_1", "cand_3"],
  "overlapHints": [
    {
      "candidateId": "cand_1",
      "overlapType": "accepted_overlap",
      "withItemId": "accepted_1",
      "reason": "Covers the same meaning contrast as an accepted pitfall."
    }
  ],
  "whyRecommended": "Most specific and directly useful for recall."
}
```

说明：

- `recommendedId`
  - 最多一个
- `alternativeIds`
  - 剩余有效候选
- `overlapHints`
  - 只用于提示与降权，不用于硬阻止
- `whyRecommended`
  - 一句短理由，不做长解释

### 7.4 Judge 的选择原则

judge 应优先：

- 选择新增学习价值最高的候选
- 选择更短、更具体、更可立即使用的候选
- 选择更有助于 recall 或避免典型错误的候选
- 避免将与 accepted 内容高度重叠的候选标为 `recommended`

judge 不应追求：

- 绝对真理式的“最佳答案”
- 复杂多轮解释

### 7.5 overlap 的定义

judge 应将以下情况视为 overlap 风险：

- 主要在讲同一个 confusable contrast
- 主要在讲同一个 spelling trap
- 主要在讲同一个 usage distinction
- `Mnemonic` 只是对已 accepted `Pitfall` 的换说法

overlap 的判断核心不是：

- 文本是否相似

而是：

- 是否主要在教同一个学习点

### 7.6 Judge Prompt 设计

推荐 prompt 骨架：

```text
You are selecting the most useful learning aid candidate for a vocabulary learner.

Goal:
Pick one candidate as recommended for the current section.
The recommendation should reduce decision cost for the user.

Selection principles:
- Prefer the candidate with the highest added learning value.
- Prefer short, specific, and actionable items.
- Prefer candidates that are more useful for recall or avoiding mistakes.
- Avoid recommending candidates that substantially overlap with already accepted material.
- Overlap is advisory: overlapping items may still remain as alternatives.
- Do not rewrite candidates.
- Do not invent new content.

Output rules:
- Return JSON only.
- Select at most one recommendedId.
- Put all remaining valid items into alternativeIds.
- For overlapping items, include a short overlap reason.
- Keep whyRecommended to one short sentence.
```

## 8. Local Rules

### 8.1 职责边界

`Local Rules` 只负责：

- 结构校验
- 硬约束
- fallback

它不负责：

- 重做完整语义排序
- 重写 judge 的语言判断逻辑

### 8.2 结构校验

judge 输出至少应满足：

- `recommendedId` 若存在，必须出现在 candidates 中
- `alternativeIds` 必须全部合法
- `recommendedId` 不能同时出现在 `alternativeIds`
- `overlapHints` 中的 `candidateId` 必须合法
- `whyRecommended` 不能为空且长度受控

### 8.3 硬约束 guardrails

一期建议至少实现以下 guardrails：

1. 长度限制
   - `Pitfalls` / `Mnemonics` 推荐项不得过长
   - `Usage` 推荐项不得退化成长 explanation
   - `Collocations` 推荐项必须保持短 pattern 形态
2. section 类型一致性
   - `Pitfalls` 中明显像 `Usage summary` 的句子不应成为 `recommended`
   - `Usage` 中明显像 warning 的句子不应成为 `recommended`
3. 完全重复不得推荐
   - 若推荐项与 accepted item 文本完全相同，必须降级
4. generic 空句不得推荐
   - 如 “This is a useful word.” 一类句子
5. 每个 section 最多一个 `recommended`

### 8.4 Local override 原则

本地允许做有限 override，但应保持克制。

推荐 override 场景：

- judge 推荐项明显越过硬边界
- judge 推荐项与 accepted item 高 overlap，且存在更干净的替代项

不推荐的 override：

- 因为轻微偏好差异就重排全部候选
- 用本地规则重做 judge 的细粒度编辑判断

### 8.5 Fallback

若 judge 输出无效，或推荐项被本地 guardrails 打掉，则进入 deterministic fallback。

fallback 应简单、稳定、易解释。

推荐策略：

1. 过滤明显无效项
2. 按 section 类型优先级选第一条
3. 在同优先级内优先更短的项
4. 仍无合规项时，不生成推荐，只保留 alternatives

示例优先级：

- `Pitfalls`
  - `spelling_trap`
  - `confusable_word`
  - `common_misuse`
  - `meaning_misdirection`
- `Usage`
  - `sense_distinction`
  - `usage_tendency`
  - `semantic_contrast`
  - `register_or_context`

### 8.6 Source 标记

推荐在运行时结果中加入：

```json
{
  "selectionSource": "judge_with_guardrails"
}
```

允许值：

- `judge`
- `judge_with_guardrails`
- `deterministic_fallback`

该字段可仅作调试或内部分析使用，不要求显示给用户。

## 9. 存储策略

### 9.1 为什么选择 JSON persistence

`Learning Aids` artifacts 在一期仍处于结构演进阶段：

- metadata 字段仍可能变化
- judge 结果与 overlap hints 仍可能继续扩展
- 各 section 的字段形态不完全一致

因此一期不推荐为每类 artifact 单独设计复杂 SQLite 列结构。

推荐方案：

- SQLite 负责事务、索引与宿主容器
- artifacts 本体以 JSON blob 存在列中

### 9.2 存储原则

推荐采用：

- 一行对应一个词条的 AI artifact 容器
- JSON 作为主数据载体
- 少量宿主字段单独列出，便于查询

### 9.3 推荐宿主表

示例字段：

```text
word_ai_artifacts
- entry_id TEXT PRIMARY KEY
- schema_version INTEGER NOT NULL
- artifacts_json TEXT NOT NULL
- has_accepted_learning_aids INTEGER NOT NULL
- has_saved_recall_card INTEGER NOT NULL
- updated_at TEXT NOT NULL
```

说明：

- `artifacts_json`
  - 主数据 JSON
- `has_accepted_learning_aids`
  - 便于列表页或状态判断
- `has_saved_recall_card`
  - 便于导出入口或预览状态判断

### 9.4 推荐 JSON 结构

```json
{
  "schemaVersion": 1,
  "entryId": "perpetual",
  "learningAids": {
    "pitfalls": {
      "suggested": [],
      "accepted": []
    },
    "usageHints": {
      "suggested": [],
      "accepted": []
    },
    "mnemonics": {
      "suggested": [],
      "accepted": []
    },
    "collocations": {
      "suggested": [],
      "accepted": []
    }
  },
  "selection": {
    "pitfalls": {
      "recommendedId": null,
      "alternativeIds": [],
      "overlapHints": [],
      "whyRecommended": null,
      "selectionSource": "judge"
    }
  },
  "recallCard": {
    "draft": null,
    "saved": null
  }
}
```

### 9.5 单个 artifact 推荐结构

```json
{
  "id": "pitfall_01",
  "text": "Do not confuse perpetual with permanent.",
  "translation": "不要把 perpetual 和 permanent 混淆。",
  "category": "confusable_word",
  "focus": "meaning_contrast",
  "recallRelevant": true,
  "senseRef": {
    "senseIndex": 0,
    "partOfSpeech": "adjective",
    "definitionSnapshot": "持续不断的；没完没了的"
  },
  "createdAt": "2026-04-19T12:00:00Z"
}
```

### 9.6 `senseRef` 与 dictionary refresh

一期推荐存 `senseRef snapshot`，而不是强绑定到词典内部稳定 id。

推荐结构：

```json
{
  "senseRef": {
    "senseIndex": 0,
    "partOfSpeech": "adjective",
    "definitionSnapshot": "持续不断的；没完没了的"
  }
}
```

约束：

- `senseIndex` 是 advisory metadata，不是 stable identifier
- dictionary refresh 后不要求强制 remap
- accepted artifacts 即使无法 remap，也必须可展示、可导出
- remap 若存在，应是 best-effort only

### 9.7 为什么不建议单独做复杂表结构

若一期直接拆成多表与多列：

- migration 成本高
- schema 演进阻力大
- judge / overlap / selection metadata 很难优雅扩展

因此更推荐：

- 逻辑上结构化
- 物理上 JSON 持久化

## 10. Worked Example

词条：`perpetual`

已有 accepted：

```json
[
  {
    "id": "accepted_1",
    "section": "pitfalls",
    "text": "Do not confuse perpetual with permanent.",
    "category": "confusable_word",
    "focus": "meaning_contrast",
    "recallRelevant": true
  }
]
```

generator 产出 `Usage` candidates：

```json
{
  "candidates": [
    {
      "id": "cand_1",
      "text": "Often describes ongoing problems, conflict, or noise.",
      "translation": "常描述持续存在的问题、冲突或噪音。",
      "kind": "usage_tendency",
      "focus": "usage_context",
      "recallRelevant": true,
      "senseIndex": 0
    },
    {
      "id": "cand_2",
      "text": "Emphasizes continuing repetition rather than fixed permanence.",
      "translation": "强调持续反复，而不是固定不变的永久性。",
      "kind": "semantic_contrast",
      "focus": "meaning_contrast",
      "recallRelevant": true,
      "senseIndex": 0
    },
    {
      "id": "cand_3",
      "text": "This is a useful word in many contexts.",
      "translation": "这是一个在很多语境里都很有用的词。",
      "kind": "usage_tendency",
      "focus": "generic_summary",
      "recallRelevant": false,
      "senseIndex": 0
    }
  ]
}
```

judge 可能输出：

```json
{
  "recommendedId": "cand_2",
  "alternativeIds": ["cand_1", "cand_3"],
  "overlapHints": [
    {
      "candidateId": "cand_2",
      "overlapType": "accepted_overlap",
      "withItemId": "accepted_1",
      "reason": "Covers the same contrast as an accepted pitfall."
    }
  ],
  "whyRecommended": "Best captures the core meaning distinction."
}
```

本地 guardrails 可以进一步处理为：

```json
{
  "recommendedId": "cand_1",
  "alternativeIds": ["cand_2"],
  "overlapHints": [
    {
      "candidateId": "cand_2",
      "overlapType": "accepted_overlap",
      "withItemId": "accepted_1",
      "reason": "Covers the same contrast as an accepted pitfall."
    }
  ],
  "whyRecommended": "Adds a cleaner usage cue without repeating accepted contrast.",
  "selectionSource": "judge_with_guardrails"
}
```

这里的关键点不是“本地重做 judge”，而是：

- judge 提供语言层判断
- 本地在强 overlap 明确且存在更干净替代项时做有限修正

## 11. 验收点

- `Learning Aids` 每个 section 可输出最多一条 `recommended`
- judge pass 不改写 candidate 文本
- overlap 只做提示与降权，不做硬阻止
- local rules 能拦截明显越界推荐
- judge 输出损坏时系统可 deterministic fallback
- artifacts 以 SQLite 承载 JSON 的方式持久化
- `senseIndex` 不被当作稳定 identity 使用
- dictionary refresh 不会导致已 accepted AI materials 失效
