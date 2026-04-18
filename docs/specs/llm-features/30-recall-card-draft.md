# 功能岛 3：Recall Card Draft

## 1. 前因

当前导出卡片更偏 recognition，用户更容易形成：

- 看到英文知道中文
- 看到释义觉得自己认识

但真正容易丢分和遗忘的部分通常是 recall：

- 能否完整拼出单词
- 能否记住短语关键部分
- 能否在易错字母处不出错

因此第一阶段最重要的新卡型应是 Recall Card Draft，而不是继续堆叠展示型内容。

## 2. 功能目标

为单词或短语生成 recall 导向卡片草稿，用于后续卡片预览与导出。

第一阶段支持三种模式：

- 完整拼写回忆
- 定向字母挖空
- 短语回忆

但当前拍板的一期重心是：

- 主推 `full spelling`
- 主推 `targeted letter cloze`
- `phrase recall` 先做 schema 支持和弱入口，不做重 UI

## 3. 范围

覆盖内容：

- Recall Card Draft 的生成
- 草稿模式切换与展示
- 完整拼写与挖空拼写的统一承载
- 短语回忆支持
- 与导出层挂接

不覆盖内容：

- 大规模模板自定义
- 批量卡型推荐
- 基于用户历史错误自动调整策略

## 4. 总览实施计划

### 4.1 统一卡型抽象

将 recall 训练抽象为统一草稿，而不是分裂成多套功能：

- `full spelling`
- `targeted letter cloze`
- `phrase recall`

### 4.2 正反面内容

草稿需包含：

- 正面提示
- 背面答案
- 当前卡型模式
- 挖空信息或关键提示

正面提示优先基于：

- 中文义项
- 中文语义提示
- 学习提示语

### 4.3 Recall Prompt 输入策略

Recall prompt 不应再按“给每个 mode 都生成一张”的思路建模，而应围绕单草稿工作台设计。

一期推荐输入：

- `headword`
- `requestedMode`
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

`Recall Card` 不是普通建议列表，而是用户主动触发的卡片工作台。

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

系统可给出默认模式建议：

- 高频短词：完整拼写
- 长词或易错词：定向字母挖空
- 短语：短语回忆

用户可手动切换模式。

一期更保守的默认规则：

- 短词、规则词：优先 `full spelling`
- 长词、双写词、易混元音词、词缀易错词：优先 `targeted letter cloze`
- 短语：schema 支持，但 UI 弱入口

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
Turn this word into an active-recall card.
```

展开态：

```text
Recall Card                                                  [Close] [v]
Train active recall instead of recognition.

Mode
[ Full Spelling ] [ Targeted Letter Cloze ] [ Phrase Recall ]

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
Mode: Targeted Letter Cloze
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
- 草稿至少支持完整拼写与定向字母挖空两种模式
- 草稿对短语类词条可正常工作
- 用户可编辑 Recall Card Draft
- 用户需要显式保存 Recall Card
- 被采纳草稿可参与卡片预览
- 被采纳草稿可进入导出结果
- 切换卡型不会破坏已采纳的其他 AI 内容

## 6. 并行开发边界

该岛依赖：

- AI 建议层

该岛与例句建议、易错点 / 用法模块无强耦合，是最适合独立并行推进的核心功能岛。
