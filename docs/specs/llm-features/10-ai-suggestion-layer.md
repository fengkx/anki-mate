# 功能岛 1：AI 建议层与采纳工作流

## 1. 前因

当前产品虽然已有 AI 能力，但更接近“点一下生成一段内容”，而不是稳定的学习材料工作流。

如果没有建议层与采纳工作流，后续新增任何 AI 能力都会面临同样问题：

- 生成结果放哪里
- 用户如何决定是否采用
- 如何避免 AI 直接污染正式词条内容
- 如何挂接卡片预览与导出

因此该功能岛的目标不是新增某一类 AI 内容，而是为所有 AI 学习能力提供统一承载层。

## 2. 功能目标

建立一个可复用的 AI 建议层，使单词详情页中的 AI 能力都能遵循统一流程：

1. 生成建议
2. 展示建议
3. 用户采纳 / 编辑 / 拒绝
4. 已采纳内容进入正式学习材料
5. 正式学习材料参与卡片预览与导出

## 3. 范围

覆盖内容：

- 单词详情页 AI 面板重构
- 建议态与已采纳态的区分
- 通用的采纳、编辑、拒绝、清空、重生成流程
- AI 内容与导出层的挂接

不覆盖内容：

- 各具体 AI 内容的 prompt 设计
- collection 级批量工作流
- 高级模板编辑器

## 4. 总览实施计划

### 4.1 数据分层

围绕每个词条建立两层 AI 数据：

- `suggested`
  - 刚生成、尚未确认
- `accepted`
  - 用户已采纳、可进入卡片导出

### 4.2 UI 分层

将当前 `AI Assistant` 扩展为稳定的信息架构。

顶层不按“模型输出类型”分，而按“用户任务”分：

- `Examples`
- `Learning Aids`
- `Usage`
- `Recall Card`

其中：

- `Learning Aids` 内部再分：
  - `Pitfalls`
  - `Mnemonics`
  - `Collocations`
- `Recall Card` 是一级入口，但不是普通文本列表 section，而是展开后进入的小型卡片工作台

各工作区的通用状态：

- 空态
- 生成中
- 有建议
- 已采纳
- 错误态

### 4.3 顶层 section 呈现方式

每个一级工作区都以“可折叠的 card”呈现，而不是：

- tabs
- 没有边界的纯标题分组
- 完全展开的大长页

每个 card 标题区包含：

- 工作区标题
- 一句短说明或状态摘要
- 右侧主动作按钮
- 折叠 / 展开控制

折叠状态下只显示摘要，例如：

- `Examples · 2 accepted`
- `Learning Aids · empty`
- `Usage · 1 accepted`
- `Recall Card · suggested draft ready`

### 4.4 Recall Card 的特殊形态

`Recall Card` 虽然保留为一级入口，但它不复用普通建议列表的交互。

折叠态：

- 显示工作区标题
- 显示状态摘要
- 显示 `Generate Recall Card` 或 `Open`

展开态：

- 进入一个小型编辑工作台
- 编辑字段包括：
  - mode
  - front
  - back
  - hint
- 不使用普通文本建议的 `Accept / Reject`

### 4.5 线框图

```text
AI Assistant
========================================================================

Examples                                  2 accepted             [v]
See the word in natural context.

  Suggested
  [example item]

  Accepted
  [example item]


Learning Aids                          1 pitfall, 1 mnemonic     [>]
Spot spelling traps, memory hooks, and common collocations.


Usage                                     1 accepted             [>]
Generate a short learner-facing usage note.


Recall Card                         suggested draft ready        [>]
Turn this word into an active-recall card.
```

### 4.6 交互动作

对每条建议提供统一动作：

- 采纳
- 编辑后采纳
- 拒绝
- 重生成
- 清空已采纳内容

但 `Recall Card` 不适用这组文案，详见 `30-recall-card-draft.md`。

### 4.7 导出挂接

将已采纳 AI 内容挂接到卡片导出链路，确保 AI 结果不是只停留在 UI 展示。

## 5. 验收点

- 单词详情页中的 AI 内容能区分“建议”和“已采纳”
- 顶层工作区按 `Examples / Learning Aids / Usage / Recall Card` 组织
- 用户可以逐条采纳、编辑、拒绝 AI 内容
- 用户采纳后的内容在重新打开应用后仍然存在
- 已采纳内容能进入卡片预览
- 已采纳内容能进入导出结果
- 清空已采纳内容不会误删词典原始内容
- 模型未就绪时，面板能给出明确降级提示

## 6. 并行开发边界

该功能岛适合作为平台层先行。

对其他岛提供的依赖是：

- 建议态与采纳态的统一承载
- 通用的详情页 AI 模块 UI
- 通用的导出挂接点

该岛完成后，其余内容岛可以分别接入，而无需彼此等待。
