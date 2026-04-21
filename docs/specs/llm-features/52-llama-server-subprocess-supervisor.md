# llama-server 子进程监管方案

> 状态：proposal
> 关联文档：`13-runtime-readiness-and-autostart.md`、`50-agent-chat.md`、`51-chat-template-bridge-handoff.md`
> 最后更新：2026/04/20

## 1. 背景

当前 `AnkiMateServer` 直接链接 `libllama`，自行负责：

- prompt 拼装
- chat template 应用
- grammar / json schema 约束
- tool calling 解析
- 输出反解析

这条链路的问题已经暴露得很明确：

- 不同模型的 chat template 行为差异大
- reasoning / channel token / tool-call 包装格式并不稳定
- 一旦 llama.cpp 上游在 `common_chat_templates_apply` / `common_chat_parse`、PEG arena、tool-call 编码上调整细节，下游就要继续追 ABI / 行为
- `Usage`、tool call、structured output 这些需求叠加后，服务端维护成本已经明显高于收益

用户目标已经明确：

- `AnkiMateServer` 继续作为本项目自己的控制面
- 模型启动、停止、切换等生命周期仍然通过 JSON-RPC 管
- 真正的推理由上游 `llama-server` 负责
- 业务调用直接复用 `llama-server` 的 OpenAI-compatible `/v1/chat/completions`
- 不再自己维护 parser / template / grammar / tool-call 解析链路

## 2. 拍板结论

一期直接采用 **子进程监管方案**，不做“动态链接 llama-server 进程内复用”的路线。

原因很直接：

1. `llama-server` 本身是一个可执行程序，不是为下游 embedding 设计的稳定 library API。
2. 即使把 `server.cpp` 和相关文件硬塞进本工程，仍然要自己承受上游内部 API、全局状态、HTTP 层、router 行为变更带来的维护成本。
3. 真正想复用的是“上游已经跑通的 API 行为与解析行为”，而不是把上游的 server 代码重新 fork 一份到本工程里继续养。
4. 子进程边界最清晰：崩溃隔离、日志隔离、升级边界清晰，和现有 `ServerProcessManager` 的产品模型也一致。

因此本方案的最终形态是：

- `AnkiMateServer` 变成 **supervisor + proxy**
- `llama-server` 变成 **被监管的内部子进程**
- `AnkiMateServer` 对外同时提供：
  - JSON-RPC 控制面
  - OpenAI-compatible `/v1/chat/completions` 数据面
- App 调用层逐步改成直接请求 `AnkiMateServer` 的 `/v1/chat/completions`
- 现有 JSON-RPC `generate` 保留一个兼容层，过渡期内部转发到同一个 OpenAI 请求

## 3. 非目标

本方案不做以下事情：

- 不把 `llama-server` 改造成动态库并直接嵌入当前进程
- 不继续扩展 `CLlamaChatTemplateBridge`
- 不继续维护自定义 PEG / parser blob / generation prompt 适配
- 不自行实现 OpenAI tool-call 解析
- 不在本阶段引入多后端抽象层（例如 vLLM / Ollama / LM Studio）

## 4. 目标架构

### 4.1 逻辑结构

```text
anki-mate app
    |
    |  JSON-RPC: health / loadModel / unloadModel / shutdown
    |  HTTP:     /v1/chat/completions
    v
AnkiMateServer
    |
    |  supervise + proxy
    v
llama-server (child process)
    |
    |  upstream OpenAI-compatible API
    v
/v1/chat/completions
```

### 4.2 职责边界

`AnkiMateServer` 负责：

- 对外端口监听
- JSON-RPC 控制面
- `llama-server` 子进程的启动 / 停止 / 监控
- 选模型、切模型、等待 ready
- 将外部 `/v1/chat/completions` 请求转发给内部 `llama-server`
- 将上游错误规范化后回传
- 统一日志、生命周期、健康检查

`llama-server` 负责：

- chat template 应用
- OpenAI-compatible 请求解析
- structured output / `response_format`
- tool calling
- chat completion 响应格式
- token usage / timings / finish reason

### 4.3 核心原则

- 控制面和数据面分离
- parser / template / tool-call 行为全部以 upstream 为准
- 模型切换通过监管层完成，不让 app 直接感知内部子进程
- 对调用方尽量保持稳定，内部实现可替换

## 5. 为什么不做进程内动态链接

理论上存在两条“非子进程”路线，但都不值得做。

### 5.1 直接链接 `libllama`

这其实就是当前路线。问题已经验证过：

- 你能复用的是底层推理 API
- 你复用不到 `llama-server` 现成的 OpenAI 兼容层行为
- 上层 parser / template / tool-call 仍然要自己兜底

这条路与“不要自己维护 parser 链路”的目标直接冲突。

### 5.2 把 `llama-server` 源码嵌进工程

这本质上是在下游 fork 一个 `llama-server`：

- 需要自己处理它的 HTTP server 生命周期
- 需要解决和当前 NIO server 的耦合
- 需要持续跟进上游 `tools/server` 目录的内部重构
- 升级时 merge 成本高
- 一旦只 patch 了一点点，很快又会回到“自己维护 parser 链路”的老路上

所以这里不把它当可行主线，只作为明确放弃的备选。

## 6. 运行时设计

### 6.1 进程拓扑

- app 只启动一个 `AnkiMateServer`
- `AnkiMateServer` 按需启动一个 `llama-server`
- `llama-server` 绑定到 `127.0.0.1` 的内部随机端口
- 外部调用方永远只连 `AnkiMateServer`

### 6.2 端口策略

`AnkiMateServer`：

- 对外公开端口，维持现有发现方式

`llama-server`：

- 内部端口固定由 supervisor 分配
- 不对 app 暴露
- 只允许 loopback 访问

### 6.3 模型生命周期

监管层只维护一个“当前激活模型”概念。

状态机：

```text
stopped
  -> starting-supervisor-child
  -> no-model
  -> loading-model
  -> ready(model=A)
  -> switching(model=B)
  -> ready(model=B)
  -> stopping
  -> stopped
```

语义约束：

- `loadModel(modelA)`：若子进程未启动，先启动 `llama-server`，再 load
- `loadModel(modelA)`：若当前就是 `modelA` 且状态 ready，直接幂等成功
- `loadModel(modelB)`：若当前为 `modelA`，执行显式切换
- `unloadModel()`：卸载当前模型，但 supervisor 进程保留
- `shutdown()`：停止 `llama-server` 子进程并关闭 `AnkiMateServer`

### 6.4 切模型策略

这里采用 **router mode 优先，重启兜底**。

优先策略：

- 以 router mode 启动 `llama-server`，即启动时不指定单模型
- 通过 `/models/load` 与 `/models/unload` 控制模型
- `/v1/chat/completions` 请求体中的 `model` 字段由 `AnkiMateServer` 统一注入

兜底策略：

- 如果本地 vendored 版本或某些平台行为不稳定，允许降级为“切模型即重启 `llama-server` 单模型实例”
- 该策略放在 supervisor 内部，不影响外部 API

默认仍以 router mode 为主，因为它最符合“控制面走 JSON-RPC，推理面走 chat completions”的职责划分。

## 7. API 设计

### 7.1 对外保留的 JSON-RPC 方法

保留：

- `health`
- `loadModel`
- `unloadModel`
- `shutdown`

兼容保留：

- `generate`

其中：

- `generate` 仅作为过渡兼容层
- 新代码不再把 `generate` 当主调用入口
- 它内部转发成一次 `/v1/chat/completions` 请求，然后再映射回现有 `GenerateResult`

### 7.2 对外新增的数据面

`AnkiMateServer` 新增原样暴露：

- `POST /v1/chat/completions`

可选后续补充：

- `GET /v1/models` 或 `/models`
- `POST /v1/embeddings`

但本阶段最小闭环只要求 `chat/completions`。

### 7.3 `health` 语义

`health` 返回的 `status` 语义需要调整为监管态而不是当前 engine 态：

- `no_model`: `llama-server` 已启动但当前无模型
- `loading_model`: 正在 load / switch
- `ready`: 当前模型可接受 chat completions

可选扩展字段：

- `supervisorPid`
- `childPid`
- `childPort`
- `modelId`
- `backend = "llama-server"`

## 8. 调用层迁移方案

### 8.1 目标状态

`LLMService` 的生成调用不再走 JSON-RPC `generate`，而是：

1. 通过 JSON-RPC `health` / `loadModel` / `unloadModel` / `shutdown` 控制运行时
2. 通过 HTTP `POST /v1/chat/completions` 发送实际生成请求

### 8.2 过渡期兼容

为了避免一口气改太多层，分两步：

#### Phase A

- `AnkiMateServer` 先实现 supervisor + `/v1/chat/completions` 代理
- 现有 `LLMService.generate(...)` 仍然可以继续调用 JSON-RPC `generate`
- `generate` 内部只是 adapter，不再碰 `InferenceEngine`

#### Phase B

- `LLMService.generate(...)` 直接改为调用 `AnkiMateServer` 的 `/v1/chat/completions`
- RPC `generate` 只保留给旧调用方或测试
- 业务主路径彻底从 JSON-RPC 生成接口迁移出去

最终推荐状态是 Phase B。

### 8.3 请求映射

现有 `GenerateParams` 可映射为：

```json
{
  "model": "<currently loaded model id>",
  "messages": [...],
  "tools": [...],
  "tool_choice": "auto",
  "parallel_tool_calls": false,
  "response_format": {...},
  "max_tokens": 256,
  "temperature": 0.7,
  "stream": false
}
```

映射规则：

- `prompt + systemPrompt`：若 `messages == nil`，由调用层先合成为 OpenAI 风格 `messages`
- `messages`：优先使用调用方显式传入值
- `toolChoice`：映射到 `tool_choice`
- `parallelToolCalls`：映射到 `parallel_tool_calls`
- `responseFormat`：按 OpenAI/llama-server 兼容格式透传
- `maxTokens`：映射到 `max_tokens`

### 8.4 响应映射

从 upstream chat completion 提取：

- `choices[0].message.content` -> `GenerateResult.text`
- `choices[0].message.tool_calls` -> `GenerateResult.toolCalls`
- `choices[0].finish_reason` -> `GenerateResult.finishReason`
- `usage.total_tokens` 或相关 usage 字段 -> `GenerateResult.tokensUsed`
- `timings` 或本地耗时 -> `GenerateResult.durationMs`

如果上游返回 SSE streaming：

- Phase A 可以先不支持由 `AnkiMateServer` 透传 streaming 给旧 RPC `generate`
- 但 `/v1/chat/completions` 直通路径应该从第一天支持上游 streaming

## 9. `AnkiMateServer` 内部模块拆分

建议新增以下组件。

### 9.1 `LlamaServerSupervisor`

职责：

- 启动 `llama-server` 子进程
- 监控退出
- 解析 ready 信号
- 维护 child port / pid
- 发送 `/models/load`、`/models/unload`
- 做 health probe

核心接口建议：

```swift
protocol LlamaServerSupervising: AnyObject {
    var state: LlamaServerState { get }
    var loadedModelPath: String? { get }

    func startIfNeeded() async throws
    func stop() async
    func loadModel(path: String, contextSize: Int, gpuLayers: Int) async throws
    func unloadModel() async throws
    func ensureReadyForInference() async throws
    func makeBaseURL() throws -> URL
}
```

### 9.2 `LlamaServerProxyClient`

职责：

- 组装到内部 `llama-server` 的 HTTP 请求
- 转发 `/v1/chat/completions`
- 解析上游错误
- 提供 typed adapter 给 RPC `generate`

### 9.3 `OpenAICompatibilityAdapter`

职责：

- `GenerateParams` <-> chat completions request
- chat completions response <-> `GenerateResult`

这个层要纯数据转换，不碰进程生命周期。

### 9.4 `RPCDispatcher`

变更后只负责：

- 控制面 RPC 分发
- 调 supervisor
- 兼容层 `generate` 转发

### 9.5 `HTTPHandler`

变更后支持两类请求：

- `POST /`：JSON-RPC
- `POST /v1/chat/completions`：直接代理到 `llama-server`

## 10. `llama-server` 启动参数建议

最小建议：

```text
llama-server
  --host 127.0.0.1
  --port <internal-port>
  --jinja
  --no-webui
```

router mode 下附加：

- 不传 `-m`
- 根据需要传 `-c <context>`、`-ngl <gpuLayers>` 作为默认 preset
- 若需要限定模型目录，可传 `--models-dir <dir>`

注意点：

- `--jinja` 应显式开启，避免继续走旧模板行为
- 若通过本地绝对路径管理模型，需确认 router mode 能正确识别本地模型来源；否则采用 supervisor 重启单模型模式兜底
- `DYLD_LIBRARY_PATH` / `DYLD_FALLBACK_LIBRARY_PATH` 继续沿用当前 `ServerProcessManager` 的动态库注入逻辑

## 11. 错误处理

### 11.1 子进程未启动

对 `/v1/chat/completions`：

- 如果存在已选模型且允许 lazy startup，先尝试自动启动 + load
- 若失败，返回 OpenAI 风格错误对象

对 JSON-RPC：

- `health` 明确体现 `no_model` / `failed`
- `loadModel` 返回详细错误

### 11.2 子进程异常退出

`AnkiMateServer` 必须：

- 记录 child exit code
- 将状态切为 failed/no-model
- 让下一次 `loadModel` 或生成请求可以触发恢复

### 11.3 上游 4xx / 5xx

不自己重写语义，优先透传：

- HTTP path：尽量原样返回上游 OAI-compatible error body
- RPC path：把上游错误包装进 `inferenceError(...)`

## 12. 并发与序列化

一期约束：

- 模型 lifecycle 操作串行化
- `loadModel` / `unloadModel` / `shutdown` 与推理请求互斥
- 普通 `/v1/chat/completions` 请求允许并发，前提是当前 child 已 ready

实现建议：

- supervisor 内部使用单 actor 持有状态
- `switch model` 期间新请求直接失败或等待，不能同时把一半请求打到旧模型、一半打到新模型

## 13. 迁移时需要删除的旧实现

以下内容应从主路径移除：

- `InferenceEngine` 中直接 `llama_model_load_from_file` / `llama_decode` / sampler 驱动推理的路径
- `InferenceEngine+ToolCalls.swift`
- `CLlamaChatTemplateBridge`
- 与 parser blob / chat_parse / generation_prompt 相关的桥接测试
- 任何为了兼容某个模型输出格式而增加的字符串后处理逻辑

保留或复用：

- `ServerProcessManager` 的二级进程动态库环境注入思路
- `RPCDispatcher` 的控制面契约
- `AnkiMateRPC` 里的共享请求/响应模型

## 14. 实施步骤

### Step 1

引入 `LlamaServerSupervisor`，在 `AnkiMateServer` 内部启动并管理 `vendor/llama-install/bin/llama-server`。

验收：

- `health` 正常
- `loadModel` / `unloadModel` 幂等
- `shutdown` 可正确结束 child

### Step 2

让 `HTTPHandler` 支持 `/v1/chat/completions` 代理。

验收：

- curl 到 `AnkiMateServer` 的 `/v1/chat/completions` 能拿到 upstream 响应
- tools / `response_format` / `finish_reason` 行为与直连 `llama-server` 一致

### Step 3

把 JSON-RPC `generate` 改成 compatibility adapter，彻底绕过 `InferenceEngine`。

验收：

- 原有 app 调用无需立刻修改即可继续工作
- 生成结果来自 upstream chat completions 映射

### Step 4

修改 `AnkiMateLLM` / `LLMService` 主调用链，直接请求 `AnkiMateServer` 的 `/v1/chat/completions`。

验收：

- 业务主路径不再依赖 RPC `generate`
- agent tool calling、structured output、usage 生成都走同一条 upstream API

### Step 5

删除废弃的 direct-libllama inference 路径和桥接层。

验收：

- `AnkiMateServer` 不再链接 `CLlamaChatTemplateBridge`
- `InferenceEngine` 若保留，只作为极薄兼容壳或被完全删除

## 15. 测试策略

### 15.1 单元测试

- `OpenAICompatibilityAdapterTests`
  - `GenerateParams -> request body`
  - `chat completion response -> GenerateResult`
- `LlamaServerSupervisorTests`
  - 状态机
  - 幂等 load/unload
  - child crash 恢复

### 15.2 集成测试

- `RPCDispatcherTests`
  - `loadModel` / `unloadModel` / `shutdown`
  - `generate` 兼容层
- `HTTPHandlerTests`
  - `/v1/chat/completions` 代理
  - 上游错误透传

### 15.3 端到端 smoke

至少覆盖：

- plain chat completion
- `response_format = json_schema`
- tool calling
- 模型切换后再次生成
- child 被杀后自动恢复

## 16. 风险

### 16.1 router mode 与本地模型路径的适配风险

如果 router mode 对当前本地模型目录/路径管理不顺手，需要尽快切到“单模型 child + 切换即重启”模式，不要为了保 router mode 继续引入复杂 shim。

### 16.2 双协议共存复杂度

短期内既有 JSON-RPC 又有 `/v1/chat/completions`。这会增加一点维护面，但这是合理过渡成本，目的是让调用层可以渐进迁移。

### 16.3 流式代理

如果 `AnkiMateServer` 继续基于当前 NIO HTTP handler，自行透传 SSE 要注意不要把 chunk 聚合坏。必要时先把非流式打通，再补 streaming 透传。

## 17. 最终建议

最终推荐架构不是“把 llama-server 拉进本进程”，而是：

- 保留 `AnkiMateServer` 这个产品层控制面
- 把 `llama-server` 当内部 runtime
- 一切生成都统一走 upstream `/v1/chat/completions`
- 自己只维护 lifecycle、routing、compatibility adapter

这样才能真正停止维护 parser/template/tool-call 细节，同时还保住当前项目需要的模型启动、停止、切换与 app 内状态控制。
