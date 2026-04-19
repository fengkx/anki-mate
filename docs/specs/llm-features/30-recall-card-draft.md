# 功能岛 3：Recall Card Draft

## 1. 前因

当前导出卡片更偏 recognition，用户更容易形成：

- 看到英文知道中文
- 看到释义觉得自己认识

但真正容易丢分和遗忘的部分通常是 recall：

- 能否完整拼出单词
- 能否在易错字母处不出错

因此第一阶段最重要的新卡型应是 Recall Card Draft，而不是继续堆叠展示型内容。

## 2. 功能目标

为单个词条生成一张 `Chinese cue -> English word` 的 recall card 草稿，用于后续卡片预览与导出。

Recall Card 的核心定义是：

- 正面给出中文释义、中文提示或学习线索
- 用户根据正面主动回忆英文单词
- 背面给出英文答案与必要提示

第一阶段支持两种形态：

- `standard recall`
- `targeted letter cloze`

其中：

- `standard recall` 是默认形态
- `targeted letter cloze` 是 Recall Card 的一个变体，而不是独立卡型

## 3. 范围

覆盖内容：

- Recall Card Draft 的生成
- 单卡草稿的展示与编辑
- `standard recall` 与 `targeted letter cloze` 两种变体
- 与导出层挂接

不覆盖内容：

- 大规模模板自定义
- 多张 Recall Card 并行生成
- `phrase recall`
- 基于用户历史错误自动调整策略

## 4. 总览实施计划

### 4.1 单卡定义

Recall Card 是一个明确的反向词汇卡型，而不是泛化的 recall 训练工作台。

一期约束：

- 每个词条最多只有 `1` 张 Recall Card
- Recall Card 的默认目标是“看到中文提示，回忆英文单词”
- `targeted letter cloze` 只作为这张卡的可选变体存在

### 4.2 正反面内容

草稿需包含：

- 正面中文提示
- 背面英文答案
- 当前变体类型
- 必要时附带 hint

正面提示优先基于：

- 中文义项
- 中文语义提示
- 学习提示语

### 4.3 Recall Prompt 输入策略

Recall prompt 应围绕“生成一张反向卡”建模，而不是围绕多 mode 工作台设计。

一期推荐输入：

- `headword`
- `requestedVariant`
- `senses[]`
- `acceptedPitfalls[]`
- `acceptedUsageHints[]`
- `acceptedMnemonics[]`
- `acceptedCollocations[]`
- `anchor?`

其中：

- 只优先吸收 `accepted` 内容，不吸收 `suggested`
- `acceptedLearningAids` 属于弱依赖增强项
- 没有 Learning Aids 时也必须能直接生成 Recall 草稿

### 4.4 交互模型

`Recall Card` 不是普通建议列表，而是用户主动触发的单卡草稿编辑器。

当前拍板交互：

- 用户主动点击 `Generate Recall Card`
- 系统一次只生成 `1` 张主草稿
- 草稿可以编辑
- 用户显式点击保存后，草稿才变成正式 Recall Card
- 正式 Recall Card 才参与主预览和导出

Recall 采用四态模型：

1. `Empty`
2. `Draft`
3. `Saved`
4. `Draft + Saved`

### 4.5 草稿与正式卡的关系

- `Draft`
  - 可以编辑
  - 可以持久化保留
  - 不参与主预览导出
- `Saved Recall Card`
  - 是正式卡
  - 参与 `Recall` 预览
  - 参与导出

编辑已保存 Recall Card 时，不直接改正式卡，而是：

1. 从已保存卡复制出一份 Draft
2. 用户修改 Draft
3. 用户显式点击 `Replace Recall Card`

这样可以避免正式卡被无意覆盖。

### 4.6 默认策略

系统可给出默认变体建议：

- 短词、规则词：优先 `standard recall`
- 长词、双写词、易混元音词、词缀易错词：优先 `targeted letter cloze`

用户可手动切换变体。

这里的切换不是在不同卡型之间切换，而是在同一张 Recall Card 的展示/训练变体之间切换。

### 4.7 targeted letter cloze 的挖空原则

`targeted letter cloze` 的目标不是做谜题，而是校准局部易错拼写。

一期规则：

- 默认只挖 `1` 个连续片段
- 片段长度优先 `2`，最多 `3`
- front 必带中文提示
- 不做随机挖空
- 不做多段挖空
- 不优先挖首字母

优先挖空的位点：

- 双写辅音
- 易混元音组合
- 高频词缀
- 发音弱提示字母段
- 易混词分叉位点

示例：

```text
receive
front: rec__ve + 收到；接收
back: receive

embarrass
front: emba__ass + 使尴尬
back: embarrass

perpetual
front: perpe__al + 持续不断的
back: perpetual
```

因此一期更推荐：

- mask 位置尽量由规则系统先选出
- prompt 主要负责把该 mask 包装成 learner-facing 的 front / hint / back
- 不让模型自由决定多个候选 mask 再二选一

### 4.8 线框图

折叠态：

```text
Recall Card                       suggested draft ready           [Open] [>]
Recall the English word from its Chinese meaning.
```

展开态：

```text
Recall Card                                                  [Close] [v]
Generate one reverse vocabulary card for active recall.

Variant
[ Standard Recall ] [ Targeted Letter Cloze ]

Front
[ editable ]

Back
[ editable ]

Hint
[ editable ]

[Save Recall Card] [Regenerate Draft] [Discard Draft]
```

若已存在已保存卡：

```text
Saved Recall Card
Variant: Targeted Letter Cloze
Front: perpe__al
Back: perpetual
Hint: Focus on the middle "tu" segment.

[Edit Recall Card] [Generate New Draft] [Delete Recall Card]
```

### 4.9 导出作用

被采纳的 Recall Card Draft 将形成新的卡片变体，作为第一阶段最重要的 AI 导出产物。

一期导出策略固定为：

- `Standard` 保留
- `Recall` 作为附加卡型并存导出
- 不做 Recall 替代 Standard

## 5. 验收点

- 用户可为单个词条生成 Recall Card Draft
- 每个词条最多只有一张 Recall Card
- 草稿至少支持 `standard recall` 与 `targeted letter cloze` 两种变体
- 用户可编辑 Recall Card Draft
- 用户需要显式保存 Recall Card
- 被采纳草稿可参与卡片预览
- 被采纳草稿可进入导出结果
- 切换变体不会破坏已采纳的其他 AI 内容

## 6. 并行开发边界

该岛依赖：

- AI 建议层

该岛与例句建议、易错点 / 用法模块无强耦合，是最适合独立并行推进的核心功能岛。
