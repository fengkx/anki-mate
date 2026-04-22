# 失败样本驱动的 Prompt 优化收敛方案

## 文档定位

本文定义一个更贴近当前产品阶段的 prompt 优化原则：

- 从 benchmark 失败样本和 tracing log 反推 prompt 问题
- 优先修复真正影响产品生成质量和执行稳定性的 prompt 设计问题
- 不为了通过 benchmark 去反向修改产品目标

本文不取代：

- [11-prompt-architecture.md](./11-prompt-architecture.md)
  - 定义通用 prompt 架构
- [12-prompt-quality-baseline-tests.md](./12-prompt-quality-baseline-tests.md)
  - 定义 prompt baseline 与测试分层
- [31-recall-card-generation-rules.md](./31-recall-card-generation-rules.md)
  - 定义 Recall Card 的产品质量标准
- [44-learning-aids-prompt-iteration-loop.md](./44-learning-aids-prompt-iteration-loop.md)
  - 定义 Learning Aids 的迭代闭环

本文只回答一个问题：

- 根据当前 benchmark 的真实失败 case，下一轮 prompt 优化最该怎么收敛

## 当前前提

本轮优化必须建立在以下已拍板前提上：

- 产品目标不变，不能为了 benchmark 结果去改产品定义
- benchmark 的主要职责是输出报告和 tracing，帮助后续 prompt 优化
- 生成效果不好应尽量记录为报告问题，而不是阻塞 benchmark 执行
- 真正应阻塞执行的，仍然是：
  - 完全请求超时
  - 服务层直接报错
  - 结构化输出无法落地，导致产品无法继续

换句话说，benchmark 在当前阶段首先是诊断工具，不是最终裁判。

## 失败样本给出的核心结论

基于当前 benchmark 失败 case，可以把问题分成三类。

### 1. Recall 的主问题是“字段角色不清”

最典型样本是 `receive`：

- plan 阶段已经给出中文 cue
- draft 阶段模型却把 `back` 写成中文“收到”
- 甚至进一步把中文 cue 当成目标去做 cloze

这说明当前 prompt 虽然规则很多，但没有把下面这件事钉死：

- `front` 是中文回忆提示
- `back` 永远是英文目标词
- `targeted_letter_cloze` 只能对英文目标做缺字，不是对中文 cue 做缺字

这不是词义理解差，而是 prompt contract 在字段语义上仍有歧义。

### 2. Recall 的次问题是“两阶段 + 长规则 + schema”让小模型超载

最典型样本是 `collocation`：

- 模型在 reasoning 里已经开始摇摆 mode
- 最终 JSON 结构也开始不稳定
- 输出既在做 mode 选择，又在解释理由，又在重写 cue，又在包装 draft

这类失败不是单一字段写错，而是模型在一轮生成里承担了过多任务。

当前 recall 流程要求模型同时完成：

- 选择 mode
- 解释为什么选这个 mode
- 生成 cue plan
- 再根据 cue plan 包装最终 card

对小模型来说，这个链条太长，任何一步漂移都可能导致最终 draft 无法 decode。

### 3. Learning Aids 和 Example 的问题更多是“质量 bar 没被模型真正执行”

典型现象：

- `principal` 的 `learning_aids` 仍然输出 fenced JSON
- `perpetual` 单义词有时只给 2 条例句
- 个别 `learning_aids` 仍会产出低增量 collocation 或 mnemonic

这类问题说明：

- prompt 虽然写了很多规则
- 但真正对模型行为起作用的只有少数最前面的强约束
- 长篇说明和过多 examples 不一定会提升质量，反而会稀释重点

## 优化总原则

### 1. 先消除歧义，再提升文案细腻度

当前最优先的是稳定性，不是“更聪明的文案”。

因此下一轮 prompt 优化优先级应是：

1. 让模型明确知道每个字段的职责
2. 让模型少做几步推理
3. 让真正重要的规则出现在最短、最硬的位置
4. 最后再考虑措辞和风格细节

### 2. 不靠继续堆长规则解决问题

当前失败已经证明：

- “再补 10 条规则”不是可靠解法
- 小模型会抓不住关键点，或者只抓住前几条

下一轮的方向应是：

- 规则更少
- 字段语义更直白
- 给出极短正例
- 删除重复解释

### 3. prompt 只负责模型擅长的部分

如果某个字段：

- 产品不展示
- 服务端可以稳定推断
- 或者本地规则更可靠

那就不应继续要求模型生成它。

LLM 应主要负责：

- 生成 learner-facing cue
- 在给定约束下包装最终文本

而不是负责：

- 输出冗长解释性元数据
- 同时承担选择、解释、包装多个环节

## Recall Prompt 收敛方案

Recall 是本轮第一优先级。

### 1. 明确 front / back / cloze 的职责

Recall prompt 必须把下面三件事写成最短、最硬的 contract：

- `front` 是中文提示面，用来触发英文回忆
- `back` 必须原样返回英文目标词或英文目标词组
- `targeted_letter_cloze` 只能隐藏英文目标中的字母，不能修改中文 cue

建议 prompt 直接显式传入两个语义源，而不是只靠自然语言描述：

```text
English target: receive
Chinese learner cue: 收到
```

这样模型更难把 cue 误认为答案本体。

### 2. 用极短正例代替一长串解释

Recall prompt 中最有价值的不是更多规则，而是每个 mode 各给一个短正例。

例如：

```text
full_spelling
front: 收到 · 拼出完整英文单词
back: receive

targeted_letter_cloze
front: 收到 · rec__ve
back: receive

phrase_recall
front: 飞机起飞 · 回忆完整英文词组
back: take off
```

这些正例比长篇规则更能防止：

- `back` 被翻译成中文
- cloze 落到中文 cue 上
- phrase recall 被误写成概念解释

### 3. 降低模型需要生成的中间元信息

当前 `selectionReason` 和 `cuePlan` 对产品显示不是硬依赖。

因此下一轮实现应以“最小模型输出”为目标：

- plan 阶段只保留：
  - `selectedMode`
  - `normalizedCue`
- `selectionReason` 仍可保留给调试与回显使用，但不应继续扩成更重的中间推理负担
- `semanticSource` 如无必要，也可由服务端按输入来源推断

这可以显著降低 recall plan 阶段的失败面。

### 4. 单一 allowed mode 时，不再让模型“假装做选择题”

当产品已经确定：

- `take off` 只能走 `phrase_recall`

那 prompt 就不应继续让模型：

- 看多个 mode 名称
- 解释为什么选这个 mode
- 再返回一个看似“经过选择”的答案

此时更合理的方式是直接写死：

- current mode: `phrase_recall`
- do not consider any other mode

这样更符合第一性原理：

- 产品已经决定的，就不要再交给模型“重新决定一次”

### 5. Recall 的优化目标

Recall prompt 优化后，至少应稳定满足：

- `receive` 不再把 `back` 写成中文
- `receive` 的 cloze 只作用于英文目标
- `take off` 在单 mode 情况下不再 mode 漂移
- `collocation` 不再因为 schema 与中间解释字段过重而 invalid

## Learning Aids Prompt 收敛方案

Learning Aids 的目标不是“填满 section”，而是“宁可空，也不要低增量”。

当前问题不是没有规则，而是规则太多，重点太散。

### 1. 把最重要的约束提前，并压缩成最少几条

generator prompt 最前面应优先保留：

- Return a raw JSON object only. No markdown fences.
- Empty arrays are better than weak items.
- Do not repeat accepted material in another wording or another language.
- A collocation must teach a reusable phrase pattern, not restate the definition.
- A mnemonic must still work when the headword is hidden.

其余长篇 rules 应压缩，避免模型注意力被稀释。

### 2. 缩短 examples 区块

当前 examples 太长，会带来两个副作用：

- 模型把 examples 当成可套模板的文案素材
- 关键规则被 examples 吞掉

下一轮应只保留：

- 每个 section 1 个好例子
- 每个 section 1 个坏例子

并且只保留真正对应高频失败模式的例子。

### 3. 继续依赖 judge 和 local filter 兜底

Learning Aids 不需要把所有质量约束都压到 generator prompt 上。

更合理的分工是：

- generator 负责给出少量候选
- judge 负责推荐默认项
- local filter 继续剔除明显低增量输出

这样可以避免 prompt 越写越长，却仍然把所有质量责任都丢给第一轮生成。

### 4. Learning Aids 的优化目标

优化后应优先改善：

- fenced JSON 明显减少
- 已被 accepted material 覆盖的点更少重复出现
- collocation 更少退化为 definition example
- mnemonic 更少退化为口号式、抽象式、头词依赖式线索

## Example Sentences Prompt 收敛方案

Example 的问题当前不是第一优先级。

### 1. 不为了 benchmark 去强行要求单义词给满数量

当前单义词例句 prompt 允许：

- `1..3`

这和当前产品阶段更一致：

- 宁可少一点，也不要为了凑数写重复句

因此不建议为了 `perpetual` 这类 benchmark case，把产品 prompt 改成“必须 3 条”。

### 2. 只做轻量澄清，不做强收紧

如果要微调，建议只增加一句偏好：

- two strong contexts are better than three repetitive ones

这样可以：

- 保持当前产品目标
- 也让 benchmark 读报告时更容易解释为什么少于上限不一定是坏事

## Benchmark 与 Prompt 优化的关系

benchmark 在当前阶段不应主导 prompt 设计，而应服务于 prompt 设计。

因此要明确三条边界：

### 1. prompt 优化以产品真实调用为准

benchmark case 必须先对齐产品真实 prompt 路径。

如果 benchmark 调的是另一套 prompt，那么它只能诊断 benchmark 自己，不能诊断产品。

### 2. benchmark 优先记录失败模式，而不是过度裁判质量

当前 benchmark 更适合输出：

- 请求输入
- 原始输出
- decode / normalize / post-check 结果
- warnings
- failure 分类

而不是把大量主观质量问题都升格为 hard fail。

### 3. prompt 迭代应围绕真实失败模式做小步收敛

每轮只处理一类问题，例如：

1. Recall 中英混淆
2. Recall schema 负担过重
3. Learning Aids fenced JSON
4. Learning Aids accepted overlap

不要一轮同时大改所有 prompt。

## 实施优先级

下一轮 prompt 优化建议按以下顺序推进：

### P0：Recall 稳定性

- 压缩 recall plan / draft prompt
- 强化 front/back 角色定义
- 给每个 mode 提供极短正例
- 降低模型必须返回的中间元信息

### P1：Learning Aids generator 收敛

- 把最关键约束提前
- 缩短 examples 区块
- 继续依赖 judge / filter 做第二层筛选

### P2：Example 轻量微调

- 保持单义词宁缺毋滥
- 只做轻量偏好澄清

## 验收方式

本轮不以“所有 benchmark case 全绿”为验收标准。

更合理的验收是：

### Recall

- `receive` 不再出现中文 `back`
- `receive` 不再把中文 cue 当成 cloze 目标
- `take off` 单 mode 时不再漂移
- `collocation` 的 recall draft invalid 率明显下降

### Learning Aids

- fenced JSON 显著减少
- 明显弱输出减少
- accepted overlap 的重复项减少

### Example

- 单义词少量输出仍被接受
- 输出自然性不下降

## 非目标

本轮不做以下事情：

- 不调整产品 UI 或交互定义
- 不引入新的学习能力分类
- 不为了 benchmark 通过率去改产品输出目标
- 不把报告层扩成完整质量裁判系统

当前阶段最重要的是：

- 让 prompt 更符合产品第一性原理
- 让 benchmark 更真实记录失败模式
- 让后续每轮优化都有可解释的收敛方向
