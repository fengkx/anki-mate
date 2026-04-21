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

- `AnkiMateServer` 变成 **supervisor + control-plane endpoint**
- `llama-server` 变成 **被监管的内部子进程**
- `AnkiMateServer` 对外提供 JSON-RPC 控制面，并通过 `health` 暴露当前 `inferencePort`
- App 调用层通过 JSON-RPC 管理生命周期，通过 `http://127.0.0.1:<inferencePort>/v1/chat/completions` 直连数据面
- 生成主路径不再经过 JSON-RPC 代理，也不再要求 `AnkiMateServer` 自己转发 OpenAI 请求

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
    | \
    |  \  HTTP: POST /v1/chat/completions
    |   \
    |    v
    |  llama-server (child process)
    |      ^
    |      |  child port via `health.inferencePort`
    v      |
AnkiMateServer
    |
    |  JSON-RPC: health / loadModel / unloadModel / shutdown
    v
supervisor
```

### 4.2 职责边界

`AnkiMateServer` 负责：

- 对外端口监听
- JSON-RPC 控制面
- `llama-server` 子进程的启动 / 停止 / 监控
- 选模型、切模型、等待 ready
- 通过 `health` 向调用方暴露当前 `inferencePort`
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
- 模型切换通过监管层完成，但推理请求直接走 child 的 loopback 端口
- `health` 是调用方发现当前数据面端点的唯一入口
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
- `llama-server` 绑定到 `127.0.0.1` 的内部端口；当前实现使用 `AnkiMateServer` 实际控制面端口 `+ 1`
- app 通过 `health.inferencePort` 发现数据面端口
- chat completion 请求直接发往 `llama-server` child port

### 6.2 端口策略

`AnkiMateServer`：

- 对外公开控制面端口，维持现有发现方式

`llama-server`：

- 内部端口由 `AnkiMateServer` 启动时确定，并传给 supervisor
- 通过 `health.inferencePort` 暴露给 app
- 只允许 loopback 访问

### 6.3 模型生命周期

监管层只维护一个“当前激活模型”概念。

状态机：

```text
stopped
  -> starting
  -> ready(model=A, port=P)
  -> stopped

ready(model=A)
  -> starting
  -> ready(model=B, port=P)

starting / ready
  -> failed(message)

failed(message)
  -> starting
  -> ready(model=A, port=P)
  -> stopped
```

语义约束：

- `loadModel(modelA)`：若子进程未启动，直接以 `-m modelA` 启动 `llama-server`
- `loadModel(modelA)`：若当前就是 `modelA` 且状态 ready，直接幂等成功
- `loadModel(modelB)`：若当前为 `modelA`，先停止 child，再以 `-m modelB` 重启 child
- `unloadModel()`：停止 child，并将 supervisor 状态置为 `stopped`
- `shutdown()`：停止 `llama-server` 子进程并关闭 `AnkiMateServer`

### 6.4 切模型策略

当前采用 **单模型 child + 切换即重启**。

当前策略：

- 启动 `llama-server` 时传入 `-m <modelPath>`
- 切换模型时停止旧 child，再启动新 child
- `/v1/chat/completions` 请求体中的 `model` 字段由调用层显式填写

这比 router mode 少一层动态加载行为，代价是模型切换需要重启 child。

## 7. API 设计

### 7.1 对外保留的 JSON-RPC 方法

保留：

- `health`
- `loadModel`
- `unloadModel`
- `shutdown`

### 7.2 对外使用的数据面

数据面由 `llama-server` child 直接提供：

- `POST /v1/chat/completions`

可选后续补充：

- `GET /v1/models` 或 `/models`
- `POST /v1/embeddings`

但本阶段最小闭环只要求 `chat/completions`，且端口通过 `health.inferencePort` 发现。

### 7.3 `health` 语义

`health` 返回的 `status` 语义需要调整为监管态而不是当前 engine 态：

- `no_model`: `llama-server` 已启动但当前无模型
- `loading_model`: 正在 load / switch
- `ready`: 当前模型可接受 chat completions

可选扩展字段：

- `supervisorPid`
- `childPid`
- `inferencePort`
- `modelId`
- `backend = "llama-server"`

## 8. 调用层迁移方案

### 8.1 目标状态

`LLMService` 的生成调用采用两段式：

1. 通过 JSON-RPC `health` / `loadModel` / `unloadModel` / `shutdown` 控制运行时
2. 在 `loadModel` 成功后通过 `health.inferencePort` 发现并缓存 child port
3. 后续通过 HTTP `POST /v1/chat/completions` 发送实际生成请求

### 8.2 当前约束

- `LLMService.generate(...)` 仍然是 app 内部的统一入口
- 但它底层已拆成“控制面 RPC + 数据面直连 child port”
- `AnkiMateServer` 不承担 OpenAI 请求代理职责

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

- streaming 直接走 child port，不经过 supervisor 中转
- 调用层需要处理 child 重启或模型切换导致的流中断

## 9. 模块拆分

建议新增以下组件。

### 9.1 `LlamaServerSupervisor`

职责：

- 启动 `llama-server` 子进程
- 监控退出
- 解析 ready 信号
- 维护 child port / pid
- 做 health probe

核心接口建议：

```swift
protocol LlamaServerSupervising: AnyObject {
    var state: LlamaServerState { get }
    var loadedModelPath: String? { get }
    var childPort: Int? { get }

    func loadModel(path: String, contextSize: Int, gpuLayers: Int) async throws
    func unloadModel() async
    func shutdown() async
}
```

### 9.2 `LLMService` / `RPCClient`

职责：

- 通过 `health` 发现 `inferencePort`
- 组装发往 child `llama-server` 的 HTTP 请求
- 调用 `/v1/chat/completions`
- 解析上游错误并映射到 app 内部结果类型

### 9.3 `RPCDispatcher`

职责：

- 控制面 RPC 分发
- 调 supervisor

### 9.4 `HTTPHandler`

变更后只支持控制面请求：

- `POST /`：JSON-RPC

## 10. `llama-server` 启动参数建议

最小建议：

```text
llama-server
  --host 127.0.0.1
  --port <internal-port>
  --jinja
  --no-webui
  --reasoning off
  --flash-attn on
  -m <model-path>
  -c <context-size>
  -ngl <gpu-layers>
```

注意点：

- `--jinja` 应显式开启，避免继续走旧模板行为
- 当前通过本地绝对路径传 `-m <model-path>`
- `DYLD_LIBRARY_PATH` / `DYLD_FALLBACK_LIBRARY_PATH` 继续沿用当前 `ServerProcessManager` 的动态库注入逻辑

## 11. 错误处理

### 11.1 子进程未启动

对 `/v1/chat/completions`：

- 调用层在 `loadModel` 后通过 `health` 缓存 `inferencePort`
- 生成请求发送前只检查本地缓存是否存在，不会每次重新 probe child
- 若当前无缓存端口，应先走 `loadModel` 或返回明确错误

对 JSON-RPC：

- `health` 明确体现 `no_model` / `loading_model` / `ready`
- `loadModel` 返回详细错误

### 11.2 子进程异常退出

`AnkiMateServer` 必须：

- 记录 child exit code
- 将内部状态切为 `failed(message)`；当前 `health` 会把非 starting / ready 状态映射为 `no_model`
- 下一次显式 `loadModel` 可以触发恢复
- 当前生成请求不会自动刷新 `health` 或重启 child；如果还持有旧端口，通常会得到 transport error

### 11.3 上游 4xx / 5xx

不自己重写语义，优先透传：

- child data-plane path：尽量原样返回上游 OAI-compatible error body
- 调用层只做必要的 transport / decode 包装

## 12. 并发与序列化

当前约束：

- 常规 app 主路径按“先 lifecycle，后推理”顺序调用
- supervisor 内部尚未提供显式 request queue / actor serialization
- `loadModel` / `unloadModel` / `shutdown` 与正在进行的推理请求没有服务器侧互斥保护
- 普通 `/v1/chat/completions` 请求允许并发，前提是当前 child 已 ready

后续若要支持并发控制面请求，需要补：

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

让 `health` 暴露 `inferencePort`，并确认调用层可以发现 child 数据面端口。

验收：

- `health` 能返回当前 child port
- app 能基于该端口构造数据面请求

### Step 3

修改 `AnkiMateLLM` / `LLMService` 主调用链，直接请求 `http://127.0.0.1:<inferencePort>/v1/chat/completions`。

验收：

- 业务主路径不再经过 `AnkiMateServer` 的数据面代理
- agent tool calling、structured output、usage 生成都走同一条 upstream API

### Step 4

删除废弃的 direct-libllama inference 路径和桥接层。

验收：

- `AnkiMateServer` 不再链接 `CLlamaChatTemplateBridge`
- `InferenceEngine` 若保留，只作为极薄兼容壳或被完全删除

## 15. 测试策略

### 15.1 单元测试

- `LlamaServerSupervisorTests`
  - 状态机
  - 幂等 load/unload
  - child crash 恢复
- `RPCClient` / `LLMService` tests
  - `health.inferencePort` 发现
  - chat completion response -> `GenerateResult`
  - 上游错误映射

### 15.2 集成测试

- `RPCDispatcherTests`
  - `loadModel` / `unloadModel` / `shutdown`
  - `health` 返回 `inferencePort`
- `HTTPHandlerTests`
  - `POST /` JSON-RPC 路由

### 15.3 端到端 smoke

至少覆盖：

- plain chat completion
- `response_format = json_schema`
- tool calling
- 模型切换后再次生成
- child 被杀后 `health` 不再返回 `inferencePort`，旧端口生成请求返回可诊断错误

## 16. 风险

### 16.1 单模型 child 的切换成本

当前已经采用单模型 child。风险不在 router mode 兼容性，而在模型切换成本、child 启动时间和端口占用失败。

### 16.2 双协议共存复杂度

控制面和数据面分离在长期上是正确的，但意味着调用层要同时处理 supervisor 状态和 child 端口发现。需要确保 `health`、模型切换和端口缓存始终一致。

### 16.3 流式直连

streaming 不再由 `AnkiMateServer` 代理，因此不会有 supervisor 级 chunk 聚合问题；但 child 重启、切模型或端口变化会直接中断现有流，调用层需要能识别并恢复。

### 16.4 child crash 后的缓存端口

`LLMService` 当前缓存 `inferencePort`，生成前不会每次重新 `health`。如果 child 异常退出，后续生成可能先打到旧端口并失败；后续可以考虑在 transport failure 后清空缓存并重新走 `loadModel`。

## 17. 最终建议

最终推荐架构不是“把 llama-server 拉进本进程”，而是：

- 保留 `AnkiMateServer` 这个产品层控制面
- 把 `llama-server` 当内部 runtime
- 一切生成都统一走 upstream `/v1/chat/completions`
- 自己只维护 lifecycle、端口发现与调用层适配

这样才能真正停止维护 parser/template/tool-call 细节，同时还保住当前项目需要的模型启动、停止、切换与 app 内状态控制。
