# Learning Aids Prompt Iteration Loop

## 文档定位

本文档定义一个面向 `Learning Aids` 生成质量优化的工作循环：

- 运行固定诊断测试
- 阅读报告并做人工评价
- 修改 generator prompt
- 重新运行并比较结果
- 逐轮收敛到更高质量输出

本文重点不是把质量变成脆弱的硬断言，而是建立一个稳定、可重复的人工评估闭环。

相关文档：

- [11-prompt-architecture.md](./11-prompt-architecture.md)
- [12-prompt-quality-baseline-tests.md](./12-prompt-quality-baseline-tests.md)
- [40-pitfalls-and-usage-notes.md](./40-pitfalls-and-usage-notes.md)
- [41-pitfalls-vs-usage.md](./41-pitfalls-vs-usage.md)
- [42-learning-aids-judge-and-storage.md](./42-learning-aids-judge-and-storage.md)

## 目标

这个循环的主要目标是提升 `Learning Aids` 的生成质量，尤其是：

- 信息增量更强，而不是换个说法复述 definition
- 更少出现自指式、空洞式、模板式输出
- `Pitfalls` 更像真实的易错点
- `Mnemonics` 更像真正可记忆的 hook
- `Collocations` 更像真实可复用的 phrase pattern
- 在 accepted learning material 已覆盖某个学习点时，模型要么换角度，要么留空

当前阶段速度不是第一优先级。

## 诊断测试

固定使用下面这个测试作为 prompt 迭代入口：

`testLearningAidsJudgeStrategyComparisonReportsTimingAndQualityAcrossTwoDiagnosticWordsWhenEnabled`

运行命令：

```bash
DICTKIT_RUN_LLM_E2E_TESTS=1 just test-filter testLearningAidsJudgeStrategyComparisonReportsTimingAndQualityAcrossTwoDiagnosticWordsWhenEnabled
```

这个测试的用途不是做严格的质量断言，而是打印一个可阅读 report，供人工判断：

- 生成速度如何
- separate / combined 两种 judge strategy 的表现如何
- 生成候选本身是否有学习价值
- 是否存在 definition paraphrase、无信息量改写、或重复 accepted material 的问题

## 为什么固定这两个诊断词

当前诊断语料是：

- `reluctant`
- `collocation`

它们之所以适合做 prompt 调优入口，是因为它们分别暴露两类高频失败模式：

### `reluctant`

容易退化成：

- definition 改写
- 头词自指
- “think of a reluctant person...” 这种空 mnemonic
- 只是把 hesitant / unwilling 换一层说法

### `collocation`

容易退化成：

- 盯着 definition wording 做无效对比
- 输出“habitual word pairing”同义改写
- 忽略真正有价值的 spelling / phrase pattern 学习点
- 已有 accepted `strong collocation` 时仍重复这个点

如果一个 prompt 能把这两个词跑好，通常说明它已经学会了避免最常见的低增量输出。

## 必须保持的比较前提

做这个测试时，有一个关键前提必须成立：

- 比较 `separateSections` 和 `combinedSections` 时，两种 judge strategy 必须基于同一批 generator 输出候选进行排序

否则会混入两种噪声：

- generator 波动
- judge strategy 差异

这样 report 就不再可信。

换句话说，这个测试里：

- generator 负责“产出候选”
- judge 负责“在候选里做选择”
- 比较 judge strategy 时，不应该每种 strategy 都重新生成一批新候选

## 工作循环

每一轮都按下面的固定顺序走。

### 1. 运行测试

执行：

```bash
DICTKIT_RUN_LLM_E2E_TESTS=1 just test-filter testLearningAidsJudgeStrategyComparisonReportsTimingAndQualityAcrossTwoDiagnosticWordsWhenEnabled
```

记录：

- 当前分支/commit
- 当前模型 ID
- 测试时间
- 是否冷启动模型
- 输出全文

建议把每轮输出单独保存，便于前后对比。

### 2. 阅读 report

不要先改 prompt，先逐项看 report。

重点看四层信息：

- `generated:`
- 每个 strategy 的 `last=` section summary
- `strategy_diff:`
- `rounds:` 明细

人工判断时，先判断 generator 候选质量，再看 judge 选得是否合理。

### 3. 标记失败模式

读完 report 后，不要直接说“质量不好”，而要把问题归类成具体失败模式。

推荐使用下面的标签：

- `definition_paraphrase`
- `self_reference`
- `empty_hook`
- `gloss_wording_chase`
- `accepted_overlap`
- `weak_collocation`
- `non_actionable_pitfall`
- `template_mnemonic`
- `spelling_signal_missing`
- `good_increment`

示例：

- `reluctant` mnemonic: `template_mnemonic`, `self_reference`, `definition_paraphrase`
- `collocation` pitfall: `gloss_wording_chase`, `non_actionable_pitfall`

### 4. 只改一类 prompt 问题

每轮只解决一类问题，不要同时大改所有规则。

推荐优先级：

1. 去掉 definition paraphrase
2. 去掉头词自指和模板 mnemonic
3. 强化 accepted material 去重
4. 强化 positive examples
5. 再考虑 section-specific phrasing 微调

如果一轮同时改太多：

- 很难知道哪条规则生效
- 很难复盘是否真的提升了质量
- 容易把 prompt 改得越来越长但原因不清楚

### 5. 再跑同一个测试

修改后，重新运行同一个诊断测试。

仍然用：

```bash
DICTKIT_RUN_LLM_E2E_TESTS=1 just test-filter testLearningAidsJudgeStrategyComparisonReportsTimingAndQualityAcrossTwoDiagnosticWordsWhenEnabled
```

不要中途换语料，也不要先跳去 10-word corpus。

先让 2-word diagnostic 稳定改善，再扩大范围。

### 6. 比较前后差异

比较时重点看：

- 是否更少出现 definition paraphrase
- 是否更少输出空 mnemonic
- 是否更少追着 glossary wording 打转
- 是否更愿意返回空数组而不是弱输出
- judge 选中的 item 是否更像“如果只保留 1 条，我愿意保留它”

### 7. 记录本轮结论

每轮都写一段简短结论：

- 改了什么
- 解决了什么问题
- 引入了什么副作用
- 下一轮该继续什么

## 如何人工评价输出质量

### 总原则

我们评价的不是“看起来像英文”，而是：

- 是否真正增加了学习价值
- 是否帮用户避免错误、建立记忆钩子、或获取真实搭配模式

### Pitfalls 评价标准

好的 `Pitfall` 应满足至少一条：

- 明确指出一个真实 spelling risk
- 明确指出一个 confusable word
- 明确指出一个具体 misuse pattern
- 能让用户在下次拼写或使用时减少犯错

差的 `Pitfall` 常见表现：

- 只是重述 definition
- 只是说“be careful”
- 对比的是 gloss 里的普通词，不是目标词本身的学习风险
- 太泛，几乎任何词都能套用

示例：

- 好：`easy to miss one of the double l letters`
- 差：`mistake in using habitual vs regular`

### Mnemonics 评价标准

好的 `Mnemonic` 应满足至少一条：

- 有可视化场景
- 有明确 spelling hook
- 有鲜明 contrast hook
- 读完之后能形成一个可回忆的独立 cue

差的 `Mnemonic` 常见表现：

- 把 definition 换句英语再说一遍
- 直接把 headword 塞回句子
- 字母拼读但没有真正记忆点
- 模板句，可迁移到几乎任何词

示例：

- 好：`one collar, two sleeves: neCeSSary`
- 差：`Reluctant = reluctant to start`
- 差：`Think of a reluctant person who does not want to begin`

### Collocations 评价标准

好的 `Collocation` 应满足至少一条：

- 是真实存在、可复用的 phrase pattern
- 能帮助检索某个 sense 的典型用法
- 不是 definition wording 的缩写或回声

差的 `Collocation` 常见表现：

- definition 原词照搬
- `headword + obvious object`
- 已有 accepted collocation 还重复推荐同一点

示例：

- 好：`reluctant to admit`
- 好：`charge a fee`
- 差：`habitual word pairing`

## Prompt 修改原则

主要改动位置：

- `Sources/AnkiMateLLM/Prompts.swift`

必要时配合观察：

- `Sources/AnkiMateLLM/LLMService.swift`
- `Tests/DictKitAppTests/LLMServiceE2ETests.swift`

但当前阶段，质量优化优先从 generator prompt 入手，而不是先改 judge 或 guardrails。

### 原则 1：先写 quality bar，再写禁令

不要一上来全是 `do not`。

先告诉模型什么算好输出：

- 什么叫真正的 pitfall
- 什么叫真正的 mnemonic hook
- 什么叫真正的 collocation pattern

然后再写：

- 什么是弱输出
- 什么情况下应该留空

### 原则 2：负例不够，必须补正例

单靠禁令不够。

必须在 prompt 里给 section-specific 正例，让模型知道“你到底想要哪种增量”。

尤其是：

- `reluctant` 需要一个真正的 image hook 正例
- `collocation` 需要一个真正的 spelling-risk 正例
- `charge` 这类多义项词需要一个能体现 sense retrieval 的 collocation 正例

### 原则 3：accepted material 必须进 generator prompt

如果 generator 看不到 accepted learning material，它就很难主动避开重复学习点。

所以 generator prompt 应显式包含：

- accepted pitfalls
- accepted usage hints
- accepted mnemonics
- accepted collocations

并明确要求：

- 已覆盖的明显学习点不要重复
- 如果换不出新角度，就返回空数组

### 原则 4：允许空，不要强行填满

质量优化时，一个非常重要的方向是：

- 宁可返回空，也不要返回弱 item

这条规则对 `Mnemonic` 和 `Collocation` 尤其重要。

很多差输出的根因不是模型不会，而是 prompt 在暗示“每个 section 最好都来一点”。

### 原则 5：一条 item 只教一个点

好的 learning aid 往往只抓一个学习点。

如果一个 item 同时试图：

- 解释 definition
- 做 mnemonic
- 补 usage
- 再加翻译

通常就会变得冗、散、弱。

## 推荐的 prompt 迭代顺序

### 第 1 轮：加入 accepted material 与 novelty 约束

目标：

- 减少重复 accepted material
- 提高“没有新信息就留空”的倾向

### 第 2 轮：补 section-specific 正例

目标：

- 强化模型对好 pitfall / good mnemonic / good collocation 的具体理解

### 第 3 轮：补 section-specific 负例

目标：

- 明确打掉 `definition paraphrase`
- 明确打掉 `template mnemonic`
- 明确打掉 `gloss wording chase`

### 第 4 轮：只做小修

目标：

- 精修 wording
- 不再大幅增加 prompt 体积
- 避免 prompt 过长导致模型反而抓不到重点

## 什么时候从 2-word 扩展到 10-word

只有在下面条件基本满足后，才进入更大语料：

- `reluctant` 不再稳定产出空洞 mnemonic
- `collocation` 不再稳定追逐 glossary wording
- report 中明显弱输出数量已显著下降
- separate / combined judge 都能在相同候选上做出可解释选择

扩展命令：

```bash
DICTKIT_RUN_LLM_E2E_TESTS=1 just test-filter testLearningAidsJudgeStrategyComparisonReportsTimingAndQualityAcrossTenWordsWhenEnabled
```

## 每轮建议记录模板

```text
Iteration: 2026-04-20 / model=<model-id>
Target test: testLearningAidsJudgeStrategyComparisonReportsTimingAndQualityAcrossTwoDiagnosticWordsWhenEnabled

Observed issues:
- reluctant mnemonic: template_mnemonic, self_reference
- collocation pitfall: gloss_wording_chase

Prompt change:
- add accepted learning material block
- add positive examples for spelling-risk pitfall and vivid mnemonic
- strengthen empty-array guidance when novelty is weak

Result:
- reluctant mnemonic no longer repeats the headword
- collocation pitfall focuses on spelling risk instead of gloss wording
- collocation section may become empty more often, which is acceptable

Next:
- tighten collocation positive examples
- inspect whether judge still prefers overlapping items
```

## 当前阶段的结论

如果目标是提升 `Learning Aids` 生成质量，那么最有效的工作方式不是一次性“大改 prompt”，而是：

- 固定诊断测试
- 固定语料
- 固定人工评价维度
- 一轮只改一类 prompt 问题
- 用 report 前后对比来确认是否真的变好

这是一个质量收敛问题，不是单次 prompt 创作问题。
