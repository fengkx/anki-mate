# Recall Card：生成规则与质量标准

## 1. 文档定位

本文只回答一个问题：

- 在一期产品定义已经收敛后，`Recall Card` 应该如何稳定生成，才能真正成为高质量的反向词汇卡

本文不重复定义：

- LLM runtime 生命周期
- 通用建议层交互
- `Recall Card` 的基础状态机

这些内容仍以：

- [01-overview.md](./01-overview.md)
- [30-recall-card-draft.md](./30-recall-card-draft.md)

为准。

## 2. 一句话定义

`Recall Card` 是一张 `Chinese cue -> English word` 的反向词汇卡。

它的目标不是让用户“看上去认识”，而是让用户在看到中文义项、中文提示或学习线索时，主动回忆出英文单词。

因此一期判断 `Recall Card` 质量的标准，不是文案是否丰富，而是：

- 正面是否足以触发回忆
- 正面是否没有提示过度
- 变体选择是否合理
- hint 是否只在必要时出现

## 3. 产品原则

### 3.1 先服务回忆，不先服务解释

`Recall Card` 的 front 不应退化成：

- 多义项说明大拼盘
- 带完整解释的学习笔记
- 近似词辨析段落

front 的职责只有一个：

- 让用户有足够线索去回忆英文答案

### 3.2 标准形态优先，挖空变体克制

一期默认应优先生成 `standard recall`。

只有在以下情况较明确时，才推荐 `targeted letter cloze`：

- 拼写中存在高风险片段
- 已采纳的 `Pitfalls` 明确指出易错位
- 单词长度或结构使整词回忆成本偏高，但局部校准价值很高

### 3.3 一张卡只表达一个主学习目标

单张 `Recall Card` 不应同时追求：

- 记拼写
- 记全部义项
- 记搭配
- 记辨析

一期原则是：

- 一张卡只围绕一个主回忆目标组织 cue

### 3.4 hint 是补充，不是第二个正面

hint 只用于：

- 提醒一个局部易错点
- 给出一个轻量学习钩子

hint 不应用来：

- 把答案再说一遍
- 再追加一整条 usage summary
- 替代 front 的信息组织责任

## 4. Recall 输入上下文优先级

Recall 生成应优先消费已经被用户确认过的学习材料，而不是消费原始建议。

推荐优先级：

1. `senses[]`
2. `acceptedPitfalls[]`
3. `acceptedUsageHints[]`
4. `acceptedMnemonics[]`
5. `acceptedCollocations[]`
6. `anchor?`

约束：

- 不吸收 `suggested` 内容
- 没有任何 accepted 学习材料时，也必须能直接生成 Recall Card
- accepted 内容只作为增强，不应让 front 变得过重

## 5. Chinese Cue 设计规则

### 5.1 好的 cue 应具备什么

好的 `Chinese cue` 应满足：

- 能快速指向当前目标义项
- 足以触发英文回忆
- 不把答案提示得过满
- 长度短，视觉重心清楚

一期更推荐：

- 中文短义项
- 中文语义提示
- 一句极短的学习线索

### 5.2 不好的 cue 长什么样

应避免以下 front：

- 把多个义项并列塞满
- 同时堆很多括号补充
- 把 `Pitfalls`、`Usage`、`Collocations` 全部拼进去
- 直接把英文词形暴露在 front 中
- 写成解释性段落

### 5.3 多义词的处理

对多义词：

- 优先选最值得学习或最常用的一个主义项
- 不追求一张卡覆盖全部义项
- 若确有必要，使用极短语义限定词缩窄范围

示例：

```text
perpetual
good: 持续不断的；没完没了的
bad: 持续不断的、永久的、长期存在的，也常用于噪音、争论、问题等语境
```

### 5.4 中文提示密度

front 的中文提示应优先做到“够用”，而不是“完整”。

一期建议：

- 默认只保留 1 个主义项或 1 个短语义提示
- 如需补充，再加极短限定词
- 不主动拼接多条同义中文

## 6. Variant 选择规则

### 6.1 `standard recall`

适用场景：

- 短词
- 规则词
- 没有明显局部拼写陷阱的词
- 用户主要需要从中文回忆英文，而不是纠正局部拼写

目标：

- 让用户完整回忆英文词形

示例：

```text
Front: 持续不断的
Back: perpetual
Hint: 
```

### 6.2 `targeted letter cloze`

适用场景：

- 有明确高风险拼写片段
- 已采纳 `Pitfalls` 中存在局部拼写提醒
- 单词长度较长，且错误集中在特定位点

目标：

- 校准局部易错拼写，而不是把整张卡变成谜题

示例：

```text
Front: perpe__al + 持续不断的
Back: perpetual
Hint: Focus on the middle "tu" segment.
```

### 6.3 不应使用 `targeted letter cloze` 的情况

以下情况不建议默认选 cloze：

- 没有明确易错位
- 挖空后只是在增加猜谜感
- front 已经因为中文提示过重而不缺线索
- 目标词过短，cloze 会显得形式大于收益

## 7. Hint 生成边界

### 7.1 什么时候需要 hint

hint 只在以下情况推荐生成：

- 目标词存在局部高风险拼写
- 已采纳 mnemonic 很短且确实有记忆价值
- `targeted letter cloze` 需要一个极短说明来解释挖空重点

### 7.2 什么时候不要 hint

以下情况更推荐空 hint：

- `standard recall` 已经足够清晰
- hint 只能重复 front
- hint 会直接暴露答案主体
- hint 只是在增加解释性负担

### 7.3 hint 的长度与语气

推荐特征：

- 只说一个点
- 尽量短
- 偏提醒而不是偏解释

不推荐：

- 完整句子解释词义
- 多条 bullet
- 再讲一次 usage

## 8. 与 Learning Aids 的关系

Recall Card 不要求用户先采纳 `Learning Aids` 才能生成，但如果已有 accepted 内容，应按以下方式吸收：

- `Pitfalls`
  - 优先用于决定是否切到 `targeted letter cloze`
  - 也可用于生成局部 hint
- `Usage`
  - 优先用于帮助 front 选择更准确的中文义项或语义限定
- `Mnemonics`
  - 只在足够短、足够有钩子时用于 hint
- `Collocations`
  - 一般不直接进入 front
  - 仅在词义很依赖搭配时，作为极短限定信息出现

核心约束：

- Learning Aids 是增强项，不是 front 的堆料入口

## 9. 失败模式

以下输出应被视为低质量或应触发 post-check：

- front 过长，像释义摘要
- front 覆盖多个义项且焦点不清
- hint 直接暴露答案
- cloze 没有明确学习价值，只是随机挖空
- front 混入完整英文答案
- 过度吸收 accepted 内容，导致卡面负担过重

## 10. 推荐 schema 方向

```json
{
  "variant": "standard_recall",
  "front": "持续不断的",
  "back": "perpetual",
  "hint": null,
  "senseIndex": 1
}
```

`targeted_letter_cloze` 示例：

```json
{
  "variant": "targeted_letter_cloze",
  "front": "perpe__al + 持续不断的",
  "back": "perpetual",
  "hint": "Focus on the middle \"tu\" segment.",
  "senseIndex": 1,
  "maskedRange": {
    "start": 5,
    "length": 2
  }
}
```

## 11. 验收点

- 生成的 `Recall Card` 明确服务 `Chinese cue -> English word`
- 默认优先生成 `standard recall`
- 只有在拼写风险明确时才推荐 `targeted letter cloze`
- front 不会退化为多义项堆砌或解释性段落
- hint 只在必要时出现，且不会直接泄露答案
- accepted `Learning Aids` 能提升 Recall 质量，但不会把卡面变重
