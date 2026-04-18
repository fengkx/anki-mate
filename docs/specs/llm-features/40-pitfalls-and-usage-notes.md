# 功能岛 4：易错点、记忆提示与搭配用法

## 1. 前因

很多用户不是“不认识这个词”，而是：

- 拼写总错
- 中文理解有偏差
- 不知道该怎么用
- 记不住真正该记的点

词典能提供释义和部分例句，但通常不会直接告诉用户：

- 最容易错在哪里
- 记忆时应该抓什么
- 高频搭配应如何优先学习

这正是 LLM 最适合补齐的一层。

## 2. 功能目标

为每个词条提供三类附加学习材料：

- 易错点
- 记忆提示
- 搭配与常见用法

它们的角色不是替代词典，而是作为学习层补充，帮助用户更高效地记忆和使用。

当前拍板的一期产品定义中，这三类内容统一归于一级工作区 `Learning Aids`。

## 3. 范围

覆盖内容：

- 易错点生成
- 记忆提示生成
- 搭配与常见用法生成
- 作为卡片备注、提示或背面补充内容展示

不覆盖内容：

- 完整近义词辨析系统
- 专门的考试知识库
- 复杂多轮解释交互

## 4. 总览实施计划

### 4.1 易错点

重点输出：

- 拼写易错位
- 易混词风险
- 中文义项误导点
- 常见误用点

`Pitfalls` 的产品定义不是“再解释一遍词义”，而是：

- 这个词最容易错在哪里
- 用户最可能写错、认错、用错的地方是什么

推荐内容形态为短句提示，不超过 1 到 2 行。

示例：

```text
perpetual
- 不要和 permanent 混。perpetual 强调持续不止。
- 拼写时容易漏掉中间的 "tu"。

principal
- 不要和 principle 混。principal 可作“主要的/校长”。

receive
- 注意 i 和 e 的顺序，不要写成 recive。
```

`Pitfalls` 的工作重点是“防错”，而不是“再解释一次这个词的意思”。

### 4.2 Usage Hint

`Usage` 的职责与 `Pitfalls` 不同，它回答的是：

- 这个词通常该怎么理解
- 这个词通常怎么用
- 多义项时应该抓住什么区别

`Usage` 更像短的 learner-facing usage cue，而不是：

- 例句
- 拼写提醒
- 搭配列表
- mnemonic 口诀

示例：

```text
perpetual
- 强调持续不断，而不只是长期保持不变。
- 常用于持续存在的问题、冲突或噪音。

lemmatize
- 常指把词还原到基本形式，多用于语言处理语境。
```

`Usage` 与 `Pitfalls` 的精确边界见 [41-pitfalls-vs-usage.md](./41-pitfalls-vs-usage.md)。

### 4.3 记忆提示

重点输出：

- 极短的 mnemonic 风格提示
- 面向记忆而不是面向解释
- 便于放入卡片 hint 区

### 4.4 搭配与常见用法

重点输出：

- 高频 collocation
- 常见 phrase pattern
- 简短用法提示

### 4.5 Recall 与 Learning Aids 的关系

`Learning Aids` 与 `Recall Card` 不是平行关系。

- `Learning Aids` 提供：
  - 哪里容易错
  - 怎么记
  - 常怎么搭配
- `Recall Card` 消费这些内容来生成更高质量的主动回忆卡

这是弱依赖关系：

- 用户可以直接生成 Recall Card
- 若已有已采纳的 Learning Aids，Recall 生成时应优先吸收这些内容

### 4.6 Prompt 方向

Learning Aids 相关 prompt 一期应遵循：

- `Pitfalls` 与 `Usage` 分离建模，避免混成同类字符串
- `Pitfalls` 更像短 warning
- `Usage` 更像短 usage cue
- `Collocations` 不应塞进 `Usage`
- `Mnemonics` 不应退化为 definition paraphrase

### 4.7 线框图

`Learning Aids` 作为一级工作区时，建议线框如下：

```text
Learning Aids                                            [Generate] [v]
Spot spelling traps, memory hooks, and common collocations.

  Pitfalls
  --------------------------------------------------------------------------
  Suggested
  - Do not confuse perpetual with permanent.
    [Accept] [Reject]

  Accepted
  - The middle "tu" is easy to miss in spelling.
    [Delete]

  Mnemonics
  --------------------------------------------------------------------------
  Suggested
  - Think: repeated forever.
    [Accept] [Reject]

  Collocations
  --------------------------------------------------------------------------
  Suggested
  - perpetual debate
    [Accept] [Reject]
```

### 4.8 导出作用

被采纳内容可分别进入：

- Hint / Note 区
- 背面的 usage 区

使卡片不仅有词义，还有“最该记住的点”和“最常怎么用”。

## 5. 验收点

- 用户可为单个词条生成易错点、记忆提示、搭配用法
- 三类内容能在 UI 中清晰区分
- 用户可逐条采纳、编辑、拒绝
- 被采纳内容可持久化
- 被采纳内容可进入卡片预览与导出
- 清空某一类内容不会影响其他已采纳 AI 内容

## 6. 并行开发边界

该岛依赖：

- AI 建议层

内部三块内容强相关，适合由同一开发者或同一小组负责；与 Recall Card Draft、例句建议相对独立，可并行推进。
