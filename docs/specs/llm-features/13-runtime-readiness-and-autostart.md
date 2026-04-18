# Runtime Readiness：Auto-start 与降级

## 1. 文档定位

本文定义 LLM 功能的一期运行时行为：

- inference server 什么时候自动启动
- 自动启动时如何决定使用哪个模型
- 用户仍然保留哪些手动控制
- 模型或 server 不可用时，产品如何降级

它不展开 prompt 设计，也不展开具体能力的 UI 文案。

## 2. 已拍板行为

### 2.1 app 启动时的 auto-start

- app 启动后可以尝试自动激活本地 inference server
- 只有在“至少已有 1 个已下载模型”时才做这件事
- 若当前没有可用模型，启动过程保持静默，不弹出阻断式错误

这一定义的目标是：

- 对已经配置好本地模型的用户，减少首次生成前的等待
- 对尚未配置模型的用户，不把基础查词工作流变成 LLM 配置向导

### 2.2 首次请求的 lazy readiness

- auto-start 只是优化，不是前置依赖
- 第一笔 AI 请求仍必须能自行完成 readiness 检查
- 也就是说，请求路径需要负责：
  - 启动 server
  - 加载目标模型
  - 在失败时返回清晰错误

这保证了：

- 即使 app 启动时没有提前拉起 server，AI 生成功能仍然可用
- 手动停止 server 后，下一次生成仍有恢复路径

### 2.3 自动选择模型的优先级

当系统准备 auto-start 或 lazy load 时，模型选择优先级固定为：

1. `last successfully loaded`
2. `currently selected`，前提是它已经下载完成
3. registry 中第一个已下载模型

这是一期的固定策略，不在本阶段引入更复杂的质量打分或设备画像。

## 3. 用户可见交互

### 3.1 LLM Settings

`LLM Settings` 继续承担显式控制入口：

- 查看下载状态
- 选择默认模型
- 手动启动 / 停止 server
- 查看当前 server 状态

即使存在 auto-start，设置页仍然是运行时状态的显式控制面板。

### 3.2 词条详情页中的 AI Assistant

详情页内的 AI 区域不要求用户先去设置页点“Start Server”。

已拍板交互是：

- 如果模型可用，点击生成可直接进入请求
- 如果模型尚未就绪，系统优先自动补齐 readiness
- 如果最终仍不可用，显示非阻断错误或空态提示，并提供进入设置页的明确方向

不允许的行为：

- 因 server 未启动而让整个详情页不可用
- 因没有模型而阻断普通词典阅读
- 在 app 启动时强行弹出模型配置流程

## 4. 降级原则

LLM 是学习层增强，不是词典的前置依赖。

因此在任何以下场景：

- 没有下载模型
- server 启动失败
- 模型加载失败
- 本地推理临时不可用

产品都应保持：

- 词典内容正常可读
- 标准预览和标准导出可用
- AI 区域单独降级

Recall、Examples、Learning Aids 等 AI 工作区可以不可用，但不能带崩核心查词与导出主路径。

## 5. 验收点

- 当存在已下载模型时，app 启动后可自动激活 inference server
- 当不存在已下载模型时，app 启动保持静默，不出现阻断式报错
- 第一笔 AI 请求可以 lazy 启动 server 并尝试加载模型
- auto-selected model priority 与本文定义一致
- 手动停止 server 后，后续 AI 请求仍有恢复路径
- LLM 不可用时，普通词典与标准导出流程不受影响

## 6. 实施拆分

建议按三个高层切片推进：

- runtime lifecycle
  - 固化 auto-start 触发条件、模型选择优先级与 lazy readiness 语义
- UI readiness
  - 统一设置页与详情页对 server/model 状态的展示和降级文案
- verification
  - 以服务层测试验证 auto-selected model priority 和 lazy startup
  - 以 UI / 状态测试验证不可用时不阻断主工作流
