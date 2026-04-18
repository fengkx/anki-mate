# anki-mate LLM 学习副驾驶总览

## 1. 前因

当前仓库已经具备本地 LLM 基础设施：

- `llama.cpp` 本地推理
- 模型下载与管理
- 本地 inference server
- 词条详情页中的轻量 AI 助手

但现有 AI 能力仍然偏弱，主要停留在：

- 生成例句
- 优化释义

这对于词典增强有帮助，但对“如何更高效地记住单词并形成可导出的学习材料”支持还不够强。

当前产品的核心工作流仍然是：

1. 查词
2. 收藏单词
3. 导出 Anki

因此引入 LLM 的目标不应是做一个泛聊天助手，而应是围绕背词与制卡工作流，补足词典无法稳定提供的学习层内容。

## 2. 产品目标

本阶段将 LLM 定位为**学习副驾驶**：

- 词典内容仍是权威底座
- AI 内容作为附加学习层存在
- AI 默认提供建议，不直接覆盖正式内容
- 用户负责采纳、编辑、拒绝与导出

目标用户为：

- 中高级英语自学者
- 备考型用户

这类用户的共同需求不是“看更漂亮的解释”，而是：

- 快速得到可记忆、可导出的学习材料
- 强化 recall，而不是只强化 recognition
- 针对易错点做定向训练

## 3. 第一阶段范围

第一阶段优先做**单词级深加工**，不优先做 collection 级批量流水线。

主要入口：

- 单词详情页内联 `AI Assistant`

第一阶段能力范围：

- AI 例句建议
- Recall Card Draft
  - 完整拼写
  - 定向字母挖空
  - 短语回忆
- 易错点与记忆提示
- 搭配与常见用法
- AI 建议层与采纳工作流
- AI 产物与卡片导出挂接

第一阶段不做：

- collection 级批量生成与审核
- AI 自动覆盖词典正式内容
- AI 全自动制卡
- 教练式测验闭环
- 通用 prompt 自定义系统
- 复杂模板编辑器

## 4. 关键产品原则

### 4.1 词典为底，AI 为层

- 原始词典释义、例句、音标保持不变
- AI 只生成学习辅助内容
- 若未来保留 learner-friendly definition，也应视为附加内容，而不是替换词典

### 4.2 建议优先，显式采纳

- AI 结果先进入建议层
- 用户逐条决定是否采纳
- 默认不自动写入正式卡片内容

### 4.3 recall 优先

LLM 功能的判断标准不是“看起来更丰富”，而是：

- 是否帮助用户更快回忆
- 是否帮助用户更好区分易错点
- 是否提升导出到 Anki 后的学习质量

### 4.4 单词级闭环优先

一个词条内应能完成：

1. 查看词典信息
2. 查看 AI 建议
3. 采纳为学习材料
4. 进入卡片预览与导出

### 4.5 Recall 是卡片工作台，不是普通建议列表

- `Examples`、`Learning Aids`、`Usage` 都属于学习材料层
- `Recall Card` 属于卡片编排层
- 因此 `Recall Card` 不应复用普通文本建议的 `Accept / Reject` 交互
- `Recall Card` 采用：
  - 用户主动触发生成
  - 只生成 1 张主草稿
  - 显式保存为正式 Recall Card
  - `Basic + Recall` 并存预览和导出

### 4.6 Learning Aids 优先服务 Recall

- `Pitfalls` 告诉用户哪里容易错
- `Mnemonics` 提供极短的记忆钩子
- `Collocations` 提供高频搭配
- `Recall Card` 可直接生成，但若已有已采纳的 Learning Aids，应优先吸收这些材料
- 这是一种“弱依赖”：
  - 用户不必先做 Learning Aids 才能生成 Recall
  - 但 Learning Aids 会提升 Recall 草稿质量

## 5. 当前拍板的一期信息架构

单词详情页中的 AI Assistant 按两层组织：

- 学习材料层
  - `Examples`
  - `Learning Aids`
    - `Pitfalls`
    - `Mnemonics`
    - `Collocations`
  - `Usage`
- 卡片编排层
  - `Recall Card`

其中：

- `Recall Card` 继续作为一级入口显示，但在交互语义上视为卡片工作台
- `Learning Aids` 是一个一级工作区，而不是三个彼此平级的一级 section
- 默认先帮助用户理解和识别错点，再进入 Recall

建议默认展示顺序：

1. Examples
2. Learning Aids
3. Usage
4. Recall Card

建议默认展开策略：

- `Examples` 默认展开
- `Learning Aids` 默认折叠，但若已有 accepted 内容则展开
- `Usage` 默认折叠，但若已有 accepted 内容则展开
- `Recall Card` 顶层始终可见，但展开后进入较重的工作台形态

### 5.1 运行时行为与降级原则

一期关于 LLM runtime 的产品定义也已经拍板：

- app 启动后可尝试自动激活 inference server，但只在已有可用模型时触发
- 第一笔 AI 请求仍要支持 lazy readiness，不要求用户先去设置页手动启动
- 自动选择模型优先级固定为：
  1. `last successfully loaded`
  2. 当前选中且已下载的模型
  3. registry 中第一个已下载模型
- `LLM Settings` 保留显式控制权：
  - 下载模型
  - 选择模型
  - 启动 / 停止 server
- LLM 不可用时，AI 区域单独降级，不影响：
  - 词典阅读
  - `Standard` 预览
  - 标准导出

详细运行时规范见 [13-runtime-readiness-and-autostart.md](./13-runtime-readiness-and-autostart.md)。

## 6. 功能拆分与并行边界

为支持并行开发，第一阶段拆分为 4 个相对独立的功能岛：

### 岛 1：AI 建议层与采纳工作流

职责：

- 定义建议层与已采纳层
- 扩展详情页 AI 面板
- 支持逐条采纳、编辑、拒绝、重生成
- 将 AI 内容挂接到卡片预览与导出

这是平台型功能岛，优先级最高。

### 岛 2：AI 例句建议

职责：

- 生成高质量学习例句
- 支持多条建议、逐条采纳
- 与词典原始例句清晰区分

### 岛 3：Recall Card Draft

职责：

- 生成 recall 导向卡片草稿
- 支持完整拼写、定向字母挖空、短语回忆
- 产物可直接导出为卡片内容

这是本阶段最核心的新卡型能力。

### 岛 4：Learning Aids

职责：

- 生成拼写易错点、中文误导点、记忆提示
- 生成搭配与常见用法
- 作为 `Learning Aids` 一级工作区中的三类内容展示
- 为 Recall Card 提供更高质量的上下文输入

这三个内容强相关，适合放在一个岛中。

## 6.5 Prompt 设计的渐进式披露

为避免把 prompt 规则散落在各功能岛正文中，一期文档采用单独的渐进式披露结构：

1. `01-overview.md`
   - 只说明产品目标、信息架构与阶段策略
2. `11-prompt-architecture.md`
   - 说明统一 prompt 架构、共享输入上下文与输出 contract
3. `12-prompt-quality-baseline-tests.md`
   - 说明 prompt 效果基线、固定测试语料与可选 E2E 测试策略
4. 各能力专题
   - `20-example-suggestions.md`
   - `30-recall-card-draft.md`
   - `40-pitfalls-and-usage-notes.md`
   - `41-pitfalls-vs-usage.md`

这样做的目的：

- 总览文档保持高层
- prompt 讨论可以持续深化而不污染总览
- 开发实现时可直接定位到对应专题文档

## 6.6 当前到目标的实现收敛方向

现阶段的 spec 已经比部分现有实现更明确，后续实现应按以下方向收敛：

- `Recall Card`
  - 从“多条 suggested / accepted drafts 列表”收敛为“单 `Draft` + 单 `Saved Recall Card` 工作台”
- `Usage` 与 `Learning Aids`
  - 从偏字符串导向的生成与展示，收敛为更稳定的结构化 artifact
- AI Assistant
  - 从“各能力各自生成”收敛为统一的 section/card 交互和一致的降级语义
- runtime behavior
  - 将设置页中的手动控制与详情页中的 lazy readiness 统一到一个可预测的可用性模型

在收敛完成前，代码中若仍存在旧的多-draft recall 路径，应视为遗留实现，而不是一期产品定义。

## 7. 阶段验收标准

第一阶段整体完成的标志：

- 单词详情页可生成 4 类 AI 学习材料
- 每类材料都可逐条采纳、编辑、拒绝
- 被采纳内容可持久化
- 被采纳内容可参与卡片预览与导出
- Recall Card Draft 能区分完整拼写与挖空模式
- Recall Card 采用 `Draft` 与 `Saved Recall Card` 两层
- `Recall` 预览与 `Standard` 预览并存，不相互替代
- 已下载模型存在时，server 可自动进入可用状态
- 没有模型或模型未下载时，产品能清晰降级

## 8. 线框总览

桌面端一期建议线框如下：

```text
+----------------------------------------------------------------------------------+
| Header                                                                           |
|  perpetual                                             [Standard|Recall] [F|B]   |
|  /pəˈpetʃuəl/                                                                   |
+----------------------------------------------------------------------------------+
| Dictionary Content                                                               |
| -------------------------------------------------------------------------------- |
| adjective                                                                        |
| 1. recurring repeatedly ...                                                      |
| 2. never ending ...                                                              |
|                                                                                  |
| Card Preview Area                                                                |
| -------------------------------------------------------------------------------- |
| [Preview Card]                                                                   |
+----------------------------------------------------------------------------------+
| drag handle                                                                      |
+----------------------------------------------------------------------------------+
| AI Assistant                                                                     |
|                                                                                  |
|  [Examples]         2 accepted                               [Regenerate] [v]    |
|  [Learning Aids]    1 pitfall, 1 mnemonic                    [Generate]   [>]    |
|  [Usage]            1 accepted                               [Regenerate] [>]    |
|  [Recall Card]      suggested draft ready                    [Open]       [>]    |
|                                                                                  |
+----------------------------------------------------------------------------------+
```

## 9. 路线图

### Phase 1

单词级 AI 深加工闭环：

- 生成建议
- 采纳建议
- 导出卡片

### Phase 2

collection 级批量工作流：

- 批量生成草稿
- 批量审核
- 批量导出

### Phase 3

更强的复习强化能力：

- 自动建议 recall 强度
- 根据错误模式推荐挖空位
- 生成小测验与复习任务
