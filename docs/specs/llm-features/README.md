# LLM Features Docs

## 文档定位

本目录记录 anki-mate 引入本地 LLM / `llama.cpp` 后的学习副驾驶能力设计，以及按可并行开发方式拆分的实施计划。

当前目录有三类文档：

- 总览文档：定义产品目标、范围边界、阶段路线图
- 运行时文档：定义模型可用性、server auto-start 与降级行为
- prompt 设计文档：定义生成策略、输入输出 contract 与能力边界
- 功能岛文档：按相对独立的子能力拆分，便于并行开发

## 渐进式披露阅读顺序

建议按以下顺序阅读，而不是一次读完整个目录：

1. 先看产品总览
   - [01-overview.md](./01-overview.md)
2. 再看运行时与可用性约束
   - [13-runtime-readiness-and-autostart.md](./13-runtime-readiness-and-autostart.md)
3. 再看统一 prompt 架构
   - [11-prompt-architecture.md](./11-prompt-architecture.md)
   - [12-prompt-quality-baseline-tests.md](./12-prompt-quality-baseline-tests.md)
4. 然后根据具体能力进入对应专题
   - 例句： [20-example-suggestions.md](./20-example-suggestions.md)
   - 发音增强： [21-pronunciation-memory-display.md](./21-pronunciation-memory-display.md)
   - Recall： [30-recall-card-draft.md](./30-recall-card-draft.md)
   - Learning Aids 总览： [40-pitfalls-and-usage-notes.md](./40-pitfalls-and-usage-notes.md)
   - `Pitfalls` 与 `Usage` 的精确定义： [41-pitfalls-vs-usage.md](./41-pitfalls-vs-usage.md)
5. 最后再回到建议层与 UI 工作流
   - [10-ai-suggestion-layer.md](./10-ai-suggestion-layer.md)

## 文档列表

- [01-overview.md](./01-overview.md)
  - LLM 学习副驾驶的总体需求文档与当前拍板的一期产品策略
- [13-runtime-readiness-and-autostart.md](./13-runtime-readiness-and-autostart.md)
  - 本地 inference server 的 auto-start、模型选择优先级与不可用时的产品降级
- [11-prompt-architecture.md](./11-prompt-architecture.md)
  - 统一 prompt 设计原则、共享输入上下文、输出 schema 与 post-check 策略
- [12-prompt-quality-baseline-tests.md](./12-prompt-quality-baseline-tests.md)
  - Prompt 效果基线、可选本地模型 E2E、硬断言与软断言的分层测试方案
- [10-ai-suggestion-layer.md](./10-ai-suggestion-layer.md)
  - AI 建议层、采纳工作流、详情页信息架构与线框图
- [20-example-suggestions.md](./20-example-suggestions.md)
  - AI 例句建议能力与多义项覆盖策略
- [21-pronunciation-memory-display.md](./21-pronunciation-memory-display.md)
  - 发音增强与重音音节记忆显示；强调与现有音标行的轻量融合
- [22-dictionary-selection-preview.md](./22-dictionary-selection-preview.md)
  - collection 编辑流程中的带预览对比的词典选择器
- [30-recall-card-draft.md](./30-recall-card-draft.md)
  - Recall Card 的产品定义、状态机、草稿与保存交互，以及 recall prompt 输入策略
- [40-pitfalls-and-usage-notes.md](./40-pitfalls-and-usage-notes.md)
  - Learning Aids 的顶层定义：易错点、记忆提示、搭配与常见用法
- [41-pitfalls-vs-usage.md](./41-pitfalls-vs-usage.md)
  - `Pitfalls` 与 `Usage` 的产品边界、句式差异与推荐 schema

## 当前拍板结论

截至当前讨论，一期产品层面已明确：

- LLM 的角色是学习副驾驶，不是泛聊天助手
- 主工作流固定为：查词 -> 生成学习材料 -> 采纳/编辑 -> 预览 -> 导出
- `Recall Card` 是一期核心能力，但它不是普通文本建议列表，而是用户主动触发的卡片草稿工作台
- `Recall Card` 一次只生成 1 张草稿，采用 `Draft` 与 `Saved Recall Card` 分层
- `Basic` 与 `Recall` 导出并存，不做替代
- `phraseRecall` 一期先做 schema 支持和弱入口，不做重 UI
- `Learning Aids` 作为一级工作区承载：
  - Pitfalls
  - Mnemonics
  - Collocations
- `anchor` 只作为 optional snapshot 存储，不做 fuzzy remap
- app 启动后可在后台自动激活 inference server，但前提是至少已有 1 个可用模型
- 首次 AI 请求仍必须支持 lazy `ensureReady`，不能依赖用户先手动启动 server
- auto-selected model priority 固定为：
  - `last successfully loaded`
  - `currently selected` if downloaded
  - `first downloaded` in registry order
- 模型不可用时必须静默降级到普通词典工作流，不阻断查词、预览或标准导出
- prompt 设计采用“角色层 -> 任务层 -> 输入 contract -> 输出 contract -> post-check”五层结构
- prompt 效果测试采用“三层金字塔”：contract -> normalization -> E2E baseline
- `Usage` 必须与 `Pitfalls`、`Examples`、`Collocations` 保持清晰边界
- `Recall` 一次只生成 1 张草稿，后续 prompt 应围绕单草稿工作台建模，而不是多 mode 批量生成

## 并行开发建议

- `10-ai-suggestion-layer.md` 适合作为基础岛优先开始
- `20-example-suggestions.md`、`30-recall-card-draft.md`、`40-pitfalls-and-usage-notes.md` 可在建议层接口冻结后并行推进
- 若团队人力足够，建议：
  - 开发者 A：建议层、采纳流程、导出挂接
  - 开发者 B：例句建议
  - 开发者 C：Recall Card Draft
  - 开发者 D：易错点 / 记忆提示 / 搭配用法

## 目录说明

当前正式目录为 `docs/specs/llm-features/`。
