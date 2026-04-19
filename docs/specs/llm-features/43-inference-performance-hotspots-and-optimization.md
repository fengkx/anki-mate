# Inference Performance Hotspots And Optimization

## 文档定位

本文档记录 `AnkiMateServer` 在真实运行负载下的采样结果、当前已确认的性能瓶颈，以及后续优化与验证方案。

目标不是直接拍板某个大改架构，而是先把以下问题说清楚：

- 当前瓶颈到底在哪里
- 哪些优化方向是可验证、可落地的
- 如何判断优化确实生效
- 何时才值得继续投入更复杂的并发架构

## 背景与采样上下文

本次分析基于真实运行中的 server 进程，而不是静态代码推断。

采样对象与环境：

- workload: `DictKitAppTests.LLMServiceE2ETests/testLearningAidsJudgeStrategyComparisonReportsTimingAndQualityAcrossTenWordsWhenEnabled`
- process: `.build/debug/AnkiMateServer`
- sampling command: `sample <pid> 5 1`
- sample output: `/tmp/AnkiMateServer_2026-04-20_002457_TV8B.sample.txt`

运行期确认事实：

- 进程已加载 `libggml-metal`、`libllama`
- 进程已打开本地 `.gguf` 模型文件
- 进程已使用 Metal 编译缓存

这说明当前路径确实启用了 Metal / GPU offload，而不是纯 CPU 推理。

## 当前瓶颈结论

### 1. 主瓶颈是 Metal decode completion

采样热点链路集中在：

- `InferenceEngine.generate(...)`
- `InferenceEngine.sampleNextToken(...)`
- `llama_context::synchronize()`
- `ggml_metal_synchronize`
- `-[_MTLCommandBuffer waitUntilCompleted]`

可对应到当前实现中的关键同步点：

- [Sources/AnkiMateServer/InferenceEngine.swift](/Users/fengkx/me/code/anki-mate/Sources/AnkiMateServer/InferenceEngine.swift:467)

结论：

- 单 token 生成过程中，大量时间消耗在等待 Metal command buffer 完成
- 当前 wall-clock 主成本来自 GPU 侧 decode 完成等待
- 问题不是 HTTP/RPC 层串行，也不是 CPU 线程数没有配够

### 2. 次瓶颈是 CPU sampling path

采样同时表明，`sampleNextToken` 内部的 `sampleCandidate` 也是显著热点。

当前实现每个 token 都会：

1. 读取 logits
2. 遍历整个 vocab
3. 构造新的 `[llama_token_data]`
4. 应用 grammar sampler / sampler chain
5. grammar 不满足时可能再次采样

对应热点代码位于：

- [Sources/AnkiMateServer/InferenceEngine.swift](/Users/fengkx/me/code/anki-mate/Sources/AnkiMateServer/InferenceEngine.swift:478)

结论：

- 当前 CPU 侧 sampling 具有明显的 `O(vocab_size)` per-token 成本
- Swift 层数组分配、填充和重复采样是可疑热点
- 这部分虽然不是最大热点，但属于高 ROI 的优化入口

### 3. 非主要瓶颈

当前不应作为第一优先优化对象的部分：

- `HTTPHandler`
- `RPCDispatcher`
- `RPCClient actor`
- NIO event loop
- 单纯增加 CPU 线程数

这些部分没有在采样中表现出与生成主路径同量级的耗时。

## 性能形态判断

当前 server 的生成节拍更接近：

1. GPU 执行 decode
2. CPU 等待 GPU 完成
3. CPU 做 sampling / grammar 约束
4. 再进入下一个 token 的 decode

这意味着：

- 当前是单 session、逐 token 的 autoregressive 节拍
- “只利用一核”不是根因，而是现象
- shared-model multi-session 不会天然消除当前主热点
- 多 session 的价值更偏向提升多请求总吞吐，而不是提升单请求速度

## 优化目标

后续优化应先解决两个问题：

1. 把单请求的 token 节拍拆清楚并量化
2. 优先优化当前已确认的热点，而不是先做高复杂度架构重构

优先级排序：

1. 增强可观测性
2. 优化 `sampleNextToken`
3. 建立单请求性能基线
4. 验证双 worker 并发吞吐
5. 仅在必要时重新评估 shared-model multi-session

## 优化方向 A：增强可观测性

### 目标

在 `InferenceEngine.generate` 和 `generateStreaming` 中记录请求级性能指标，至少拆分出以下阶段：

- prompt tokenization time
- prompt decode time
- generated token count
- total decode loop time
- total sampling time
- average ms/token
- tokens/s
- grammar-enabled vs non-grammar

### 设计约束

- 不修改现有 JSON-RPC 返回结构
- 优先使用结构化日志
- 默认低开销，可通过环境变量开启
- 不记录逐 token 明细 trace，避免观测本身扰动结果

### 建议接口

新增环境变量：

- `DICTKIT_LLM_PROFILE=1`
- `DICTKIT_LLM_PROFILE_VERBOSE=1`

建议日志字段：

- request id
- mode: `generate` / `streamGenerate`
- response format kind
- prompt token count
- output token count
- prompt decode ms
- sampling ms
- decode wait ms
- total duration ms
- tokens/s

### 如何验证生效

用当前 E2E workload 连续运行 3 次，确认：

- 每次请求都有完整指标输出
- 指标非负且字段齐全
- 各阶段时间能基本闭合
- 开启 profiling 后不出现功能回退

### 验收标准

能明确回答：

- prompt 阶段占比多少
- decode wait 占比多少
- sampling 占比多少
- grammar 请求是否显著更慢

## 优化方向 B：优化 `sampleNextToken`

### 目标

降低每 token 的 CPU sampling 成本，重点是：

- 降低全 vocab candidate 构造成本
- 降低 Swift 层分配与填充开销
- 降低 grammar fallback 的重复工作

### 建议实现范围

1. 复用 candidate buffer

- 将 vocab-sized candidate buffer 变成 request-local 可复用状态
- 不要每个 token 新建完整 `[llama_token_data]`

2. 收紧临时对象分配

- 复查 `sampleCandidate` 周围的数组与闭包分配
- 减少 Swift 层多余包装

3. 区分 grammar 与 non-grammar 路径

- 单独统计 grammar 请求的 sampling 开销
- 若 grammar fallback 成本过高，再针对 grammar 做后续专项优化

4. 保持采样语义不变

- 不改变 greedy / temperature / penalties / grammar 的行为语义
- 不修改上层 prompt contract

### 如何验证生效

固定以下条件进行前后对比：

- 同一模型
- 同一 prompt 集合
- 同一 temperature
- 同一 response format
- 同一 max tokens

记录并比较：

- total sampling time
- average ms/token
- end-to-end wall time
- tokens/s

同时分别覆盖：

- text generation
- `responseFormat: .json`
- streaming generation

### 验收标准

- `sampling time / total time` 显著下降
- 单请求 wall time 有稳定改善
- 输出语义无明显非预期变化
- structured output 仍可成功解码

### 回归检查

- 现有 LLM E2E 测试可通过
- 结构化输出可成功 decode
- grammar 请求不出现合法性退化
- 重新采样后，`sampleCandidate` 热点权重下降

## 优化方向 C：建立单请求性能基线

### 目标

确认当前 `waitUntilCompleted` 占比是“模型 / Metal 的正常行为”还是“存在异常高的同步成本”。

### 基线维度

- 不同 `maxTokens`
- 不同 `responseFormat`
- 不同 `contextSize`
- 可选不同 `DICTKIT_LLM_THREADS`
- 可选不同 `DICTKIT_LLM_THREADS_BATCH`
- 保持同一模型

### 记录指标

- 平均 tokens/s
- total wall time
- total sampling time
- total decode wait time
- memory footprint
- grammar enabled ratio

### 如何验证生效

对固定 workload 连续运行 3 到 5 次，使用中位数做比较，必要时记录波动范围。

### 验收标准

能明确判断：

- decode wait 是否远大于 sampling
- context size 是否显著放大延迟
- grammar 模式是否改变热点结构

## 优化方向 D：验证双 worker 并发吞吐

### 目标

验证“同时生成多个词”时，总完成时间是否能通过双 worker 获得真实改善。

这一步是吞吐验证，不是默认产品化方案。

### 建议实现范围

- 新增一个最小实验性 `2-worker process pool`
- 每个 worker 独立进程、独立模型、独立 context / sampler 状态
- 调度策略可使用简单的 `round-robin` 或 `choose-idle`
- 不要求先引入复杂优先级或抢占

### 本阶段明确不做

- 不做 shared-model multi-session
- 不做单进程共享 model 的 session manager
- 不做复杂队列调度

### 如何验证生效

设计固定并发 workload，例如：

- 同时生成多个词
- 同时触发 examples / usage / learning aids 等多个 AI 任务

比较以下两种模式：

- 单 worker 串行
- 双 worker 并发

记录：

- 总 wall-clock completion time
- p50 / p95 request latency
- per-worker memory footprint
- tokens/s
- failure / timeout rate

### 验收标准

- 若双 worker 对总完成时间有稳定且明显改善，说明“并发吞吐”方向值得继续投入
- 若改善弱、争用重或内存成本不可接受，则不继续优先投资更复杂的 multi-session

## 何时重新评估 shared-model multi-session

只有在以下前提满足时，才进入 shared-model multi-session 设计阶段：

- 单请求热点已通过观测明确拆分
- `sampleNextToken` 已完成一轮优化
- 双 worker 实验已证明多请求并发对业务有稳定收益
- 当前进一步成本主要来自进程复制、模型驻留或 worker 成本，而不是已知热点实现低效

进入该阶段前必须明确回答：

- 是否真的需要共享 model weights
- GPU / Metal 是否还有足够空间让多 session 获益
- session 隔离、取消、load / unload barrier 如何定义
- per-session sampler / grammar state 如何管理
- admission control / backpressure 如何设计

如果上述前提不成立，不进入 multi-session 设计。

## 测试与验证方案

### A. 观测正确性测试

覆盖场景：

- 普通文本生成
- JSON structured output
- streaming 生成

验证点：

- profiling 日志字段齐全
- 数值非负且可闭合
- 开启 profiling 不影响功能正确性

### B. Sampling 优化回归测试

覆盖场景：

- temperature > 0
- greedy
- grammar enabled
- grammar disabled

验证点：

- 输出仍可被现有 structured decoder 正确解析
- finish reason 没有异常变化
- 不引入非法 token 选择或崩溃

### C. 单请求性能基线测试

建议 workload：

- 当前 `LLMServiceE2ETests` 中 learning-aids 相关测试
- 再补一个纯文本流式生成场景

验证点：

- 优化前后中位数 wall time
- tokens/s
- sampling time 占比
- decode wait 占比

### D. 双 worker 并发实验测试

覆盖场景：

- 同时生成多个词
- 同时触发多个不同 AI 任务

验证点：

- 总完成时间是否改善
- p95 latency 是否可接受
- 内存 / 显存成本是否可接受
- 稳定性无明显退化

## 成功标准

### 阶段 1：观测成功

- 能稳定输出请求级性能统计
- 能基于数据区分 decode wait 与 sampling 开销
- 不再依赖 `htop` 或静态代码推断瓶颈

### 阶段 2：单请求优化成功

- `sampleNextToken` 热点占比下降
- 单请求平均耗时有稳定改善
- 功能正确性与 structured output 无明显回退

### 阶段 3：并发方向验证成功

- 能明确回答双 worker 是否对“同时生成多个词”有稳定收益
- 若收益不明显，则停止继续投入 multi-session
- 若收益明显，再进入更复杂架构评估

## 当前拍板结论

截至本次分析，当前已明确：

- `AnkiMateServer` 当前主瓶颈是 Metal decode completion，而不是 HTTP/RPC 层
- 当前次瓶颈是 `sampleNextToken` 的 CPU sampling 实现
- 第一波优化应优先做观测与 sampling 优化
- 对“同时生成多个词”的并发收益，应先用 `2-worker process pool` 验证
- shared-model multi-session 是后续可选方向，但不是当前第一优先
