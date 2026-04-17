# LLM Features Docs

## 文档定位

本目录记录 anki-mate 引入本地 LLM / `llama.cpp` 后的学习副驾驶能力设计，以及按可并行开发方式拆分的实施计划。

当前目录有两类文档：

- 总览文档：定义产品目标、范围边界、阶段路线图
- 功能岛文档：按相对独立的子能力拆分，便于并行开发

## 文档列表

- [01-overview.md](./01-overview.md)
  - LLM 学习副驾驶的总体需求文档
- [10-ai-suggestion-layer.md](./10-ai-suggestion-layer.md)
  - AI 建议层、采纳工作流、详情页交互与导出挂接
- [20-example-suggestions.md](./20-example-suggestions.md)
  - AI 例句建议能力
- [30-recall-card-draft.md](./30-recall-card-draft.md)
  - Recall Card Draft，含完整拼写、定向字母挖空、短语回忆
- [40-pitfalls-and-usage-notes.md](./40-pitfalls-and-usage-notes.md)
  - 易错点、记忆提示、搭配与常见用法

## 并行开发建议

- `10-ai-suggestion-layer.md` 适合作为基础岛优先开始
- `20-example-suggestions.md`、`30-recall-card-draft.md`、`40-pitfalls-and-usage-notes.md` 可在建议层接口冻结后并行推进
- 若团队人力足够，建议：
  - 开发者 A：建议层、采纳流程、导出挂接
  - 开发者 B：例句建议
  - 开发者 C：Recall Card Draft
  - 开发者 D：易错点 / 记忆提示 / 搭配用法

## 目录说明

用户要求路径为 `docs/sepcs/llm-features/`，本目录按该路径创建，未对路径名做自动纠正。
