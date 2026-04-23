# Prompt 效果基线：集成测试方案

## 1. 文档定位

本文定义：

- 如何为 prompt 建立可持续的效果基线
- 哪些测试应该稳定通过
- 哪些测试只能做软性质量判断
- 如何在本地有模型权重时运行可选集成测试

本文不取代：

- [11-prompt-architecture.md](./11-prompt-architecture.md)
  - 定义 prompt 架构与 contract
- [docs/agents/testing.md](/Users/fengkx/me/code/macos-dictkit/docs/agents/testing.md)
  - 定义仓库级测试入口与命令选择

## 2. 为什么需要单独的效果基线

LLM 功能有一个和普通业务逻辑不同的特点：

- 文本生成天然存在波动
- 即便 prompt 没变，不同模型也会有风格差异
- 即便是同一模型，同一 prompt 也可能有轻微随机性

因此 prompt 测试不能简单等同于：

- snapshot 全量比对
- exact string match

如果仍按传统快照思路做，测试会非常脆弱：

- 稍微换个措辞就失败
- 模型升级后大量误报
- 团队会逐渐失去维护测试的意愿

所以我们需要建立的是：

- **效果基线**

也就是：

- 保证关键输出性质稳定
- 保证不能退化到明显坏输出
- 允许在措辞层面保留合理波动

## 3. 基本原则

一期 prompt 效果测试采用 4 条原则：

1. 不测“措辞完全一致”
2. 优先测“结构正确”和“关键行为正确”
3. 对真正需要稳定的规则做硬断言
4. 对难以绝对稳定的语言质量做软断言

## 4. 三层测试金字塔

为避免把所有责任都压到可选 E2E 上，建议采用三层测试：

### 4.1 第 1 层：Prompt contract tests

目的：

- 验证 prompt 文案本身是否包含关键约束

当前仓库已有基础：

- `LLMPromptTests`

这层应继续负责：

- item 数量规则是否写进 prompt
- 多义项覆盖规则是否写进 prompt
- forbidden formatting 规则是否写进 prompt
- structured schema 字段是否出现在 prompt 中

这层优点：

- 快
- 稳
- 不依赖模型权重

这层缺点：

- 不能证明模型真的按 prompt 做了

### 4.2 第 2 层：Structured output normalization tests

目的：

- 验证模型输出即使有轻微污染，也能被稳定提取、解码和清洗

当前仓库已有基础：

- `LLMServiceTests`

这层应负责：

- fenced JSON 提取
- balanced JSON 提取
- schema decode
- normalization
- bad output rejection

这层本质上验证的是：

- “系统对模型不完美输出的韧性”

### 4.3 第 3 层：Prompt quality E2E baseline tests

目的：

- 在真实本地模型上验证 prompt 的最终效果没有明显退化

当前仓库已有基础：

- `LLMServiceE2ETests`

但这层目前更接近 smoke tests，还不是完整 baseline tests。

后续这层应升级为：

- 针对固定测试语料运行真实生成
- 断言结构、覆盖、格式、边界和 recall 规则
- 仅在本地存在可用模型权重时运行

这里需要明确：

- `LLMServiceE2ETests` 当前仍可承担 smoke 角色
- 真正的 baseline 应面向本文定义的目标 contract
- 若仓库中还保留 legacy recall 多 draft 兼容逻辑，它属于 normalization coverage，不属于长期 baseline 目标

## 5. 什么叫“基线”

一期基线不追求：

- 模型逐字输出完全一致
- 每次生成都完全同样的句子

一期基线追求的是：

- 不产生明显坏格式
- 不破坏核心产品定义
- 不丢掉多义项覆盖策略
- 不把不同能力混成一类内容
- Recall 不违反挖空规则

换句话说，基线关注的是：

- **能力边界**
- **输出 contract**
- **最小质量门槛**

## 6. 固定测试语料策略

prompt 效果测试必须基于固定语料，而不是每次随便挑词。

推荐建立一组小而稳定的 `prompt baseline corpus`，覆盖：

### 6.1 单义项词

目的：

- 测试单义项时“最多扩展若干条”的策略

示例：

- `perpetual`
- `lemmatize`

### 6.2 多义项词

目的：

- 测试“优先覆盖不同义项或词性”

示例：

- `light`
- `charge`

### 6.3 易错拼写词

目的：

- 测试 `Pitfalls` 和 `targeted_letter_cloze`

示例：

- `receive`
- `embarrass`
- `perpetual`
- `collocation`
- `lemmatize`

### 6.4 短语词条

目的：

- 测试 `phraseRecall` schema 支持

示例：

- `take off`

### 6.5 易混词

目的：

- 测试 `Pitfalls` 是否能稳定落到 confusable risk

示例：

- `principal`

一期建议保持语料很小：

- 6 到 10 个词条足够

不要一开始做太大 corpus，否则：

- 运行时间会变长
- 模型差异噪声会上升
- 维护成本变高

## 7. 硬断言与软断言

这是整套测试设计里最关键的部分。

### 7.1 硬断言

硬断言用于检查“不能退”的产品规则。

例如：

- 输出可被 decode 为目标 schema
- 输出数量符合上限和下限
- 不出现编号、bullet、`EN:`、`ZH:`、markdown fence
- `senseIndex` 不越界
- 多义项例句数量至少覆盖主要 sense 数
- `Recall` 的 `front/back` 非空
- `targeted_letter_cloze` 只挖 1 个连续片段
- mask 长度优先 2，最多 3
- 不优先挖首字母

这些规则一旦失败，应直接 fail test。

### 7.2 软断言

软断言用于检查“质量有无明显退化”，但不要求完全精确。

例如：

- 例句之间不应高度重复
- `Pitfalls` 应更像 warning，而不是 definition paraphrase
- `Usage` 应更像 usage cue，而不是 example
- `Mnemonics` 应短于 `Usage`
- `Collocations` 不应长成完整句子

软断言推荐做法：

- 通过启发式评分
- 或聚合多个弱规则
- 在 fail 时输出诊断信息

一期建议：

- 软断言仍用 `XCTAssert`，但尽量只保留少量高信号规则
- 不引入复杂 ML judge

## 8. 各能力的 baseline 断言建议

### 8.1 Examples

硬断言：

- 返回 item 数正确
- 每条都包含英文和中文翻译
- 不带编号和标签
- 单义项时不超过 3 条
- 多义项时优先一义一条

软断言：

- 句子之间不完全重复
- 句长在合理范围
- 每条确实包含目标词或短语

### 8.2 Usage

硬断言：

- 输出可 decode 为 `usageHints`
- 不含 example-style 完整长句
- 不含拼写纠错或 `do not confuse`
- 多义项时数量与 sense 覆盖策略一致

软断言：

- 每条更像 usage cue 而不是 definition rewrite
- 不同条目之间的 angle 不完全重复

### 8.3 Pitfalls

硬断言：

- 输出可 decode 为 `pitfalls`
- 不能退化成例句
- 不能退化成搭配列表
- 至少有 1 条是错误风险表达

软断言：

- 更像 warning 句，而不是 explanation
- 对易错词能落到 spelling / confusable / misuse 中之一

### 8.4 Mnemonics

硬断言：

- 输出可 decode
- 每条都较短
- 不退化成 dictionary definition

软断言：

- 具备明显记忆钩子感
- 不与 `Pitfalls` 或 `Usage` 完全同质

### 8.5 Collocations

硬断言：

- 输出可 decode
- 每条更像 phrase 或 pattern，而不是完整句子
- 数量在预期范围内

软断言：

- phrase 之间不完全重复
- 至少有一部分看起来像高频短搭配

### 8.6 Recall Card

硬断言：

- 输出可 decode 为单草稿目标结构
- `front/back` 非空
- `back` 与目标词条一致
- `targeted_letter_cloze` 只含一个 mask 片段
- mask 不为随机多段
- `hint` 不应长成 explanation paragraph

软断言：

- `front` 应有 learner-facing cue
- 有 accepted learning aids 时，draft 有吸收其信息的迹象

## 9. Streaming 场景下如何测

用户已明确要求：

- 能 streaming 的尽量 streaming

这会影响 prompt baseline 设计。

一期建议把 streaming 测试拆为两层：

### 9.1 传输层 streaming 测试

验证：

- 服务端确实产生 delta
- 客户端能逐块接收
- 最终合并文本不为空

这层不负责语言质量。

### 9.2 streaming 最终结果测试

验证：

- streaming 最终合并后的文本仍能进入 decode / normalize 流程
- 最终 artifact 与非 streaming 的 contract 一致

也就是说：

- streaming 是生成体验
- final normalized artifact 才是测试基线对象

不建议把“每个 delta 长什么样”当成稳定基线。

## 10. 为什么不用 exact snapshot

一期不建议做“整段生成文本快照”作为主测试手段。

原因：

- 本地模型输出有天然波动
- 量化版本切换会改变措辞
- 轻微随机性会导致大量误报

只有两类内容适合 snapshot：

- prompt 文本本身
- 结构化 decode 后再排序/清洗过的摘要结果

即便如此，也应优先做规则断言，而不是长文本快照。

## 11. 模型固定策略

为了让基线有意义，可选 E2E 测试必须固定一个基准模型。

当前仓库已经有：

- `ci/llm-e2e-model.lock.json`

一期建议：

- 默认只固定 1 个基准模型
- 该模型作为“prompt baseline reference model”
- 其他模型只做手动抽查，不进入默认质量门槛

原因：

- 多模型同时纳入基线会显著放大不稳定性
- prompt 优化时会很难判断是模型问题还是 prompt 问题

当前建议继续使用：

- `gemma-4-e2b-it-q4km`

后续若 `Qwen3.5 4B/9B` 在真实表现上更稳定，可再评估是否替换 lockfile。

## 12. 测试命令与运行方式

建议保留两类命令：

### 12.1 默认快速测试

- `just test-llm`

职责：

- 运行 `LLMPromptTests`
- 运行 `LLMServiceTests`

### 12.2 可选本地模型 E2E

- `just test-llm-e2e`

职责：

- 运行 pinned model 上的 prompt baseline tests

建议后续新增一层命名约定：

- `LLMServiceSmokeE2ETests`
  - 只做“服务可用、生成不空、schema 可解”
- `LLMPromptBaselineE2ETests`
  - 做真正的 prompt 质量基线

这样可以避免把 smoke 和 baseline 混在一个文件里。

## 13. 失败时应该给出的诊断信息

prompt baseline 测试失败时，不能只报：

- `XCTAssert failed`

建议输出：

- 词条
- sense inventory
- 原始模型输出
- normalize 后结果
- 命中的失败规则
- 当前模型 id

这样失败后才能判断：

- 是 prompt 退化
- 是模型波动
- 是 decode / normalize 缺陷

## 14. 一期落地建议

一期不要求把整套系统一次性做满。

建议分三步落地：

### 第一步

保留现有：

- `LLMPromptTests`
- `LLMServiceTests`
- `LLMServiceE2ETests`

并明确：

- 现有 E2E 属于 smoke，不是基线

### 第二步

新增真正的 `LLMPromptBaselineE2ETests`，优先覆盖：

- `Examples`
- `Usage`
- `Recall targeted_letter_cloze`
- `Pitfalls vs Usage` 边界

这一层应直接使用目标 schema：

- `Usage` 按 `usageHints` JSON 断言
- `Recall` 按单 `draft` 断言

不要让 legacy 多 draft 兼容结构继续定义 baseline 的形状

### 第三步

如有必要，再补：

- streaming final-result baseline tests
- model rotation review 流程

## 15. 验收点

- 团队能区分 prompt contract tests、normalization tests、E2E baseline tests
- 仓库内存在固定的小型 baseline corpus
- baseline 测试以规则断言为主，而不是整段文本快照
- 基准模型被显式固定
- 在本地有模型权重时，可选运行 prompt baseline E2E
- baseline 的 recall contract 以单草稿模型为准
- 失败日志足够支持定位 prompt、模型或 decode 问题
