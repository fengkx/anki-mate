# Pitfalls vs Usage：边界与 Prompt 定义

## 1. 文档定位

本文只解决一个容易混淆的问题：

- `Pitfalls` 和 `Usage` 到底分别生成什么

这不是 UI 文档，也不是 Recall 文档，而是 Learning Aids 内部最关键的能力边界说明。

## 2. 一句话定义

- `Pitfalls` 回答：这个词最容易错在哪里
- `Usage` 回答：这个词通常该怎么理解和怎么用

两者分别服务于：

- `Pitfalls`
  - 防错
- `Usage`
  - 建模

## 3. 产品角色差异

可将两者理解为：

- `Pitfalls` 是红灯提示
- `Usage` 是方向盘提示

因此它们在用户心智上不应表现为两组相似句子。

`Pitfalls` 的理想效果是：

- 用户看完后知道哪里要小心

`Usage` 的理想效果是：

- 用户看完后知道这个词通常怎么理解、怎么用

## 4. `Pitfalls` 的定义

### 4.1 应该输出什么

`Pitfalls` 允许输出：

- 拼写陷阱
- 易混词
- 中文义项误导
- 常见误用
- 局部高风险提醒

示例：

```text
Do not confuse principal with principle.
The middle "tu" in perpetual is easy to miss.
receive is often misspelled as recive.
```

### 4.2 不应该输出什么

`Pitfalls` 不应输出：

- 完整例句
- 纯搭配清单
- 长篇解释
- 释义复述
- 泛化 usage summary

### 4.3 推荐语气

`Pitfalls` 的语气应更短、更尖锐、更警示。

推荐长度：

- 英文核心句 5 到 12 词
- 中文解释保持短促

## 5. `Usage` 的定义

### 5.1 应该输出什么

`Usage` 允许输出：

- 义项区分
- 使用倾向
- 语义对比
- 典型使用语境

示例：

```text
Often describes ongoing problems or conditions rather than one-time events.
Emphasizes repeated continuation rather than fixed permanence.
Usually used in language-processing contexts when talking about word forms.
```

### 5.2 不应该输出什么

`Usage` 不应输出：

- 拼写纠错提醒
- “不要和 X 混” 式警示句
- 纯搭配列表
- mnemonic 口号
- 完整例句
- dictionary definition 的机械改写

### 5.3 推荐语气

`Usage` 的语气应更归纳、更平稳、更 learner-facing。

推荐长度：

- 英文 8 到 16 词
- 中文解释控制在 1 行到 2 行

## 6. 快速判断法

若一条内容的核心是在说：

- “别在这里犯错”
  - 它属于 `Pitfalls`
- “这个词一般这么理解 / 这么用”
  - 它属于 `Usage`

示例：

- `Do not confuse perpetual with permanent.`
  - `Pitfalls`
- `Often used for ongoing conflict, noise, or recurring problems.`
  - `Usage`
- `The middle letters are easy to miss in spelling.`
  - `Pitfalls`
- `Emphasizes repeated continuation rather than stable permanence.`
  - `Usage`

## 7. 推荐 schema

### 7.1 Pitfalls

推荐结构：

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

推荐 `category`：

- `spelling_trap`
- `confusable_word`
- `meaning_misdirection`
- `common_misuse`

### 7.2 Usage

推荐结构：

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

推荐 `kind`：

- `sense_distinction`
- `usage_tendency`
- `semantic_contrast`
- `register_or_context`

## 8. Prompt 约束建议

### 8.1 Pitfalls 的 system 方向

推荐强调：

- 生成短 learner warnings
- 聚焦 likely mistakes
- 不要例句
- 不要搭配列表
- 不要 definition summary
- 输出 strict JSON only

### 8.2 Usage 的 system 方向

推荐强调：

- 生成短 learner-facing usage cues
- 聚焦 how the word is typically used
- 不要 spelling warnings
- 不要 confusable alerts
- 不要 mnemonic slogans
- 不要 collocation lists
- 不要完整例句
- 输出 strict JSON only

### 8.3 多样性约束

`Pitfalls`：

- 每条聚焦一个不同风险
- 不要用不同说法重复同一错误点

`Usage`：

- 多义项时先覆盖不同义项
- 单义项时再扩展不同 usage angle

## 9. 与其他能力的边界

### 9.1 与 Examples

- `Examples` 给具体语境
- `Usage` 给抽象用法抓手
- `Pitfalls` 给错误风险提醒

### 9.2 与 Collocations

- `Collocations` 给短语或 pattern
- `Usage` 不应退化成 phrase list

### 9.3 与 Recall

`Recall Card` 可以消费：

- 已采纳 `Pitfalls`
- 已采纳 `Usage`
- 已采纳 `Mnemonics`
- 已采纳 `Collocations`

但 Recall 不应直接复制整段 `Usage` 或 `Pitfalls` 原文，而应提炼成更适合主动回忆的提示。

## 10. 验收点

- 开发者能清楚说明 `Pitfalls` 与 `Usage` 的职责差异
- prompt 测试中两者不会大面积串类
- `Pitfalls` 输出更像 warning，而不是 explanation
- `Usage` 输出更像 usage cue，而不是 warning 或 example
- 两者都具备结构化 schema，便于后续排序、测试与导出
