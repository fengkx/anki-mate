# LLM 推理性能优化 — 落地方案 (方向 A + B + C)

> 相关文档：[`43-inference-performance-hotspots-and-optimization.md`](./43-inference-performance-hotspots-and-optimization.md)
>
> 本文件是 43 号方向性分析的具体落地方案（方向 A / B / C），包含改动清单、
> commit 粒度、回归和验证标准。方向 D（worker pool）不在本轮范围。

## Context

参照 `43-inference-performance-hotspots-and-optimization.md` 的采样结论:

- 主瓶颈: Metal decode completion (等 GPU), 体现在 `llama_synchronize`
- 次瓶颈: `sampleNextToken` 的 CPU 侧 sampling — 每 token 在 Swift 层新建
  一个 vocab-sized `[llama_token_data]` (~2MB), `.append` 12 万次
- 当前仅有请求级总耗时 (`DispatchTime`), 无法分清"等 GPU"和"sampling CPU"各占多少
- Grammar fallback 最坏一轮 token 内分配两次全词表数组

本轮范围: **方向 A (可观测性) + 方向 B (sampleNextToken 优化) + 方向 C (单请求基线)**,
不做 worker pool / shared-model multi-session。

Baseline 口径: **JSON structured output 单口径, 按 operation 分桶**。沿用
learning-aids E2E 测试作 workload (都走 `responseFormat: .json`), 但要意识到每
`testCase × round` 里其实有 **3 种不同 operation**:

| operation 标签 | 调用 | maxTokens | 每 round 次数 |
|---|---|---|---|
| `generateLearningAids` | `LLMService.generateLearningAids` | (默认) | 1 |
| `judgeSection` | `LLMService.rankLearningAidSection` × {pitfalls, mnemonics, collocations} | 260 | 3 |
| `judgeCombined` | `LLMService.rankLearningAidSectionsCombined` | 420 | 1 |

10 词 × 1 round = **50 次推理**, 不是 20 次。聚合必须按 operation 分桶后再算中位数,
否则三类 prompt / maxTokens 差异巨大的请求会被平均掉。

Profiling 日志输出目标: **独立文件 `/tmp/anki-mate-llm-perf.jsonl`**, 和 client 侧
trace (`/tmp/anki-mate-llm-debug.jsonl`) 分开, 避免跨进程 regular file append 竞态。

Seed 策略: 新增 `DICTKIT_LLM_SEED` 环境变量。日常不设置时沿用现有随机行为 (
`LLAMA_DEFAULT_SEED = 0xFFFFFFFF`, llama.cpp 语义是"每次随机"); 采集阶段可通过
env var 指定 u32 seed, 使优化前/后在同 seed 下可做 bit-level 对比。

成功标准:

- 能用数据量化: 每请求里 promptDecode / sampling / synchronize / decode / tokenToPiece
  各占多少 ms, **按 operation 分桶**
- `sampleNextToken` 的 Swift 层分配从 per-token 降为 per-request
- 默认口径验收: schema 合法 + finish reason 不变 + 性能数据显著改善
- 开启 `DICTKIT_LLM_SEED=<u32>` 时, 优化前后 learning-aids 输出可做 bit-level 对比
  并一致
- JSON structured output 仍能被现有 decoder 解析
- 所有现有测试全绿

---

## 关键文件与参考点

### 需要修改的文件

- `Sources/AnkiMateServer/InferenceEngine.swift` — 主战场
  - `generate(...)` L144–L256
  - `generateStreaming(...)` L258–L357
  - `sampleNextToken(...)` L461–L529
  - `makeSampler(...)` L359–L419
  - `SamplingDefaults.seed` L38 (seed override 读取点)
  - tokenize / prompt decode 段 L165–L195, L278–L303
- `Sources/AnkiMateServer/main.swift` L70 附近 — 加 `ProfileTraceWriter.shared.flush()`
- `Sources/AnkiMateRPC/*` — `GenerateParams` 增加 `operation: String?` (可选, 向后兼容)
- `Sources/AnkiMateLLM/LLMService.swift`
  - `generateLearningAids` 调用点标 `operation: "generateLearningAids"`
  - `rankLearningAidSection` (L2901) 标 `operation: "judgeSection"`
  - `rankLearningAidSectionsCombined` (L2942) 标 `operation: "judgeCombined"`
- `Sources/AnkiMateServer/InferenceServing` protocol — 扩展 `generate`/`generateStreaming`
  签名加入 `requestId: Int?` + `operation: String?` (均默认 `nil`)
- `Sources/AnkiMateServer/RPCDispatcher.swift`
  - `handleGenerate` (L154) 透传 `request.id` 和 `genParams.operation`
  - `generateStreaming` (L40) 透传 `nil` 和 `genParams.operation`
- `Sources/AnkiMateServer/HTTPHandler.swift` — **不改协议**, `/stream` 入口仍直接解
  `GenerateParams`, requestId 为 nil, 但 `operation` 能从 params 拿到

### 新增文件

- `Sources/AnkiMateServer/ProfileTraceWriter.swift` — server-side JSONL 写入器
  - 与 `AnkiMateLLM/LLMDebugTraceWriter` 分开: 它是 actor + internal 可见, 且
    AnkiMateServer target 不依赖 AnkiMateLLM; 跨 target 引用会污染依赖图
  - 写入独立文件 `/tmp/anki-mate-llm-perf.jsonl`, **不共用** client trace 文件
  - 内部串行化: `DispatchQueue(label: "ankimate.profile.writer", qos: .utility)` +
    同步 `appendSync`, 避免进程内并发竞态
  - event 类型固定为 `"inference_perf"`

### 参考现有实现

- `Sources/AnkiMateLLM/LLMDebugTraceWriter.swift`
  - JSONEncoder 配置 `.sortedKeys + .withoutEscapingSlashes` 可照抄
  - `FileHandle.seekToEnd + write(contentsOf:)` append 可照抄 (进程内单 queue 串行, 无竞态)
- `InferenceEngine.resolveThreadSettings(...)` L615–L644 — 环境变量读取风格参考
- 现有环境变量前缀 `DICTKIT_LLM_*` — 新变量沿用

---

## 方向 A: 可观测性 (Profiling)

### A.1 新增环境变量

- `DICTKIT_LLM_PROFILE`
  - `=1` / `=true` / `=yes` (大小写不敏感) 开启; 其他值或未设置关闭
  - `InferenceEngine` 构造时读取并缓存为 `isProfilingEnabled: Bool`, 避免
    hot path 每次做 `ProcessInfo.processInfo.environment` lookup
- `DICTKIT_LLM_SEED` (新增, 可选)
  - 值为十进制 `UInt32`。未设置时保持现有行为 (用 `LLAMA_DEFAULT_SEED = 0xFFFFFFFF`,
    llama.cpp 内部视为随机)
  - 设置时把该值传给 `llama_sampler_init_dist` (L414) 和 `llama_sampler_init_xtc`
    (L398)
  - `InferenceEngine` 构造时读取并缓存为 `samplingSeedOverride: UInt32?`
  - 专用于性能采集和回归对比, 不在生产配置里启用

### A.2 ProfileTraceWriter 定义

新文件 `Sources/AnkiMateServer/ProfileTraceWriter.swift`:

```swift
final class ProfileTraceWriter {
    static let shared = ProfileTraceWriter()
    private let queue = DispatchQueue(label: "ankimate.profile.writer", qos: .utility)
    private let fileURL = URL(fileURLWithPath: "/tmp/anki-mate-llm-perf.jsonl")
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    func record(_ payload: InferencePerfEvent) {
        queue.async { [weak self] in self?.appendSync(payload) }
    }

    /// Block until all pending events are flushed to disk.
    /// Called from server shutdown path and tests.
    func flush() {
        queue.sync { }   // barrier: drains all prior async tasks
    }

    private func appendSync(_ payload: InferencePerfEvent) {
        // FileHandle seekToEnd + write(contentsOf:) + sync
        // 最后一次 write 后调 handle.synchronize() 保证落盘
    }
}
```

Event schema (新增 `operation` 分桶字段 + `seed` 溯源字段):

```json
{
  "event": "inference_perf",
  "timestamp": "2026-04-20T00:24:57.123Z",
  "requestId": 42,
  "operation": "judgeSection",
  "mode": "generate",
  "responseFormatKind": "json",
  "grammarEnabled": false,
  "seed": 4294967295,
  "maxTokens": 260,
  "promptTokens": 512,
  "outputTokens": 96,
  "finishReason": "stop",
  "promptDecodeMs": 210,
  "synchronizeMs": 480,
  "decodeMs": 132,
  "samplingMs": 45,
  "tokenToPieceMs": 3,
  "totalMs": 870,
  "tokensPerSecond": 156.7,
  "samplerPlanStages": ["top_k", "top_p", "min_p", "temp_ext", "dist"]
}
```

字段备注:

- `requestId`: `/stream` 路径无 id 时为 null
- `operation`: 用于 per-operation 分桶聚合; 非 learning-aids 调用可为 null
- `mode`: `generate` 或 `generateStreaming`
- `responseFormatKind`: `text` / `json` / `jsonSchema` / null
- `seed`: 实际传给 dist sampler 的 seed; 便于溯源
- `maxTokens`: 便于校验分桶正确性

字段语义说明:

- `synchronizeMs` = **仅** `llama_synchronize(context)` 调用本身的耗时累加。这是最
  接近"显式等 GPU 完成"的指标。
- `decodeMs` = 每轮循环末尾 `llama_decode(context, batchOfSingleToken)` 的耗时累加。
  这个调用会提交下一步 KV 更新, 内部是否即时完成由 llama.cpp/Metal 决定; **不把它
  标注为"wait"**。
- 判断 GPU 是不是主瓶颈时, 看 `synchronizeMs / totalMs`, 不要用 `synchronizeMs +
  decodeMs` 混合解读。

设计要点:

- 只在 `isProfilingEnabled == true` 时才构造 event 并 `record(...)`
- `record` 是 `async` 入队, 写文件在 utility queue, **不阻塞请求路径**
- per-token hot path 内只做 `var xxxNs: UInt64 += (end - start)` 累加, 不分配对象
- `flush()` 提供同步屏障, 供 shutdown / 测试使用
- 不改现有 RPC response、不改 stderr 日志既有行为
- 关闭 profiling 时, 整条链路零开销 (不 new event、不 encode、不入队)

### A.2.1 Shutdown flush

server 关闭时必须 drain profiling 队列, 否则 E2E 测试末尾几条 event 会丢, 污染聚合结果。

修改点: `Sources/AnkiMateServer/main.swift` L70 附近, 在
`try channel.closeFuture.wait()` 返回后、`syncShutdownGracefully` 前加:

```swift
ProfileTraceWriter.shared.flush()
```

以及 `ParentProcessMonitor` 回调里在 `exit(EXIT_SUCCESS)` 之前也调 flush。
实现上 `flush()` 就是 `queue.sync { }`, 把之前 async 入队的任务全部执行完再返回。
`appendSync` 内部写完后调 `FileHandle.synchronize()` 强制落盘, 避免 VFS buffer 残留。

### A.3 计时埋点方案 (高层 timer, 不做 per-token trace 落盘)

在 `generate` / `generateStreaming` 内部用 `DispatchTime.now().uptimeNanoseconds`
累加 5 段:

| 累加器 | 测量范围 |
|---|---|
| `promptDecodeNs` | `llama_decode(context, promptBatch)` 的单次耗时 (L192 / L300) |
| `synchronizeNs` | 每次 `sampleNextToken` 开头 `llama_synchronize(context)` 累加 (L467) |
| `samplingNs` | `sampleNextToken` 中 `llama_synchronize` 返回后 → 选中 token 之前的纯 CPU 段累加 |
| `decodeNs` | 每轮循环末尾 `llama_decode(context, singleTokenBatch)` 累加 (L235 / L337) |
| `tokenToPieceNs` | `llama_token_to_piece` + `String(cString:)` + 字符串拼接累加 (L226–L229 / L327–L331) |
| `totalMs` | 保持现有 `startTime → endTime` 逻辑 (L155/L247) |

累加器都用 `UInt64`, 避免 Date/Clock/Duration 对象分配。最终转毫秒再填入 event。

### A.4 Request ID 透传

- `InferenceServing.generate(...)` / `generateStreaming(...)` 签名末尾新增
  `requestId: Int?` 参数, 默认 `nil` (所有现有调用零改动即兼容)
- `RPCDispatcher.handleGenerate` (L154) 把 `id` 传入
- `RPCDispatcher.generateStreaming` (L40) 传 `nil`
  - 原因: `/stream` 入口 (`HTTPHandler.handleStreamRequest` L102) 直接解 `GenerateParams`
    而不是 JSON-RPC envelope, **本就没有 id 来源**
  - 不为了关联 id 去改 /stream 协议, 接受 streaming 模式下 profile event `requestId: null`
- Request id 只用于日志关联, 不参与业务逻辑

### A.4.1 Operation 标签透传 (用于分桶)

**目的**: 让聚合脚本能按 `operation` 字段把 `generateLearningAids` /
`judgeSection` / `judgeCombined` 三类请求分开算中位数。

**方案**: 扩展 `AnkiMateRPC.GenerateParams` 加可选字段 `operation: String?`
(默认 `nil`, 向后兼容), 由 client 侧 `LLMService` 在调用 RPC 时填入。

修改链路:

1. `Sources/AnkiMateRPC/*` — `GenerateParams` 增加 `operation: String?`
   (Codable / CodingKeys 记得更新, 旧 client 不带该字段仍可反序列化)
2. `Sources/AnkiMateLLM/LLMService.swift` — 三个调用点补标签:
   - `generateLearningAids` 内部 → `operation: "generateLearningAids"`
   - `rankLearningAidSection` (L2901) → `operation: "judgeSection"`
   - `rankLearningAidSectionsCombined` (L2942) → `operation: "judgeCombined"`
   - 具体调用点在 `generateStructuredOutput` 辅助函数, 把 operation 作参数往下透
3. `Sources/AnkiMateServer/RPCDispatcher.swift` — `handleGenerate` 把
   `genParams.operation` 透给 `engine.generate(..., operation: ...)`
4. `Sources/AnkiMateServer/InferenceEngine.swift` — `generate` /
   `generateStreaming` 签名加 `operation: String? = nil`, 写进 profile event

设计取舍:

- 选"扩展 RPC params"而不是"在聚合时按 maxTokens 启发式分桶": 后者会被 maxTokens
  调整或新增 operation 破坏, 前者是显式契约
- `operation` 为 `String?` 而非 enum: 避免 RPC schema 与业务层耦合,
  未来新增 operation 类型不需要改 RPC 层
- 对于**不是** learning-aids 的其他调用 (现在和未来), `operation` 保持 `nil`,
  聚合脚本分桶时归入 `"unknown"` 桶

### A.5 验证 (A)

- 开启 `DICTKIT_LLM_PROFILE=1` 跑一次 E2E `LLMServiceE2ETests/testLearningAidsJudgeStrategy...`
- `/tmp/anki-mate-llm-perf.jsonl` 出现若干 `inference_perf` 行
- 字段齐全、数值非负、JSON 可解析
- **分桶验证**: `jq '.operation' | sort | uniq -c` 至少应看到
  `generateLearningAids` / `judgeSection` / `judgeCombined` 三类
- 对于 10 词 × 1 round 的 workload, 理论上每个 round 产生
  `1 + 3 + 1 = 5 次`, 10 词 = 50 次; `judgeSection` 占 30、其他两类各 10
- 近似闭合关系: `totalMs ≈ promptDecodeMs + synchronizeMs + decodeMs + samplingMs
  + tokenToPieceMs + overhead`, 其中 overhead < 15%
- 关闭 profiling (`unset DICTKIT_LLM_PROFILE`) 后, 文件无新增 `inference_perf` 行,
  功能行为无差异
- /stream 路径产出的 event `requestId` 为 null, `/` 路径有非空整数 id
- **Shutdown flush 验证**: 测试结束后 event 数量稳定, 连跑 3 次同测试 event 数相同
- **Seed 验证**: 设 `DICTKIT_LLM_SEED=42` 跑两次, 日志里 `seed` 字段均为 42;
  未设时 `seed` 字段为 `4294967295` (`LLAMA_DEFAULT_SEED`)

---

## 方向 B: 优化 sampleNextToken

> 目标: 降低每 token 的 CPU sampling 成本, **不改变采样语义**。

### B.1 Candidate buffer 改为 per-request local scratch

**问题**: 当前 `sampleCandidate` (L475–L485) 每 token 新建 `[llama_token_data]` +
`.append` × vocab_size = 12万次, `var candidates: [llama_token_data] = []` 每
token 一次堆分配 + `reserveCapacity` 实际扩容。

**方案**: 不提升到 `InferenceEngine` 实例字段 (会有跨请求共享的隐含并发约束), 而是
**请求内 local scratch**:

```swift
// 在 generate / generateStreaming 入口、确定 vocabSize 后:
let candidateCapacity = Int(llama_vocab_n_tokens(vocab))
let candidateBuffer = UnsafeMutablePointer<llama_token_data>.allocate(
    capacity: candidateCapacity
)
defer { candidateBuffer.deallocate() }

// 把 candidateBuffer 和 candidateCapacity 传给 sampleNextToken
```

- 每请求只 `allocate` / `deallocate` 一次, 替代旧代码里 per-token `[llama_token_data]` +
  `reserveCapacity` + `append × 12万`
- 无跨请求共享状态 → 无论未来是否引入并发请求、streaming 重入, 都不会有数据竞争
- `sampleNextToken` 里循环写入直接用指针 subscript:
  ```swift
  for i in 0..<vocabSize {
      candidateBuffer[i] = llama_token_data(id: Int32(i), logit: logits[i], p: 0)
  }
  ```
- 构造 `llama_token_data_array` 直接用 `candidateBuffer`, 不再 `withUnsafeMutableBufferPointer`

前置断言: `precondition(vocabSize == candidateCapacity, "vocab size changed mid-request")`。

### B.2 Grammar fallback 保守修复

**当前行为** (`sampleNextToken` L508–L528):

1. 跑一次 `sampleCandidate(applyGrammarFirst: false)` (全链 apply, 不含 grammar)
2. 单 token grammar 验证
3. 如果非法, 再跑一次 `sampleCandidate(applyGrammarFirst: true)` (先 grammar 再全链)

**问题**: 第二次调用等于再次新建 + 填充整个 vocab-sized 数组。

**方案 (保守、语义等价)**:

- buffer 已是 per-request 复用, 第二次调用省掉 `malloc + reserveCapacity + append` 开销
- 但 **仍然** 重填 logits (因为第一次 apply 改过 buffer 里的 logits) + 重跑 grammar+chain
- 语义完全等价于当前行为, 只是去掉 Swift Array 本身的开销
- **不做**"省一次 chain 执行"的激进优化 (会破坏采样语义等价性)

### B.3 裁剪 no-op sampler (条件添加)

当前 `makeSampler` L376–L417 无条件添加以下 stage, 在默认参数下它们本质是 no-op
但每 token 仍要走一次 `llama_sampler_apply`:

| Sampler | 默认值 | no-op 判据 |
|---|---|---|
| `penalties` | repeat=1.0, freq=0, presence=0 | 全默认时不加 |
| `dry` | `dryMultiplier = 0.0` | multiplier = 0 时不加 |
| `top_n_sigma` | `-1.0` | 值 <= 0 时不加 |
| `typical` | `typicalP = 1.0` | >= 1.0 时不加 |
| `xtc` | `xtcProbability = 0.0` | probability = 0 时不加 |

**始终保留**: `top_k` / `top_p` / `min_p` / `temp_ext` / `dist` (或 `greedy`, temp=0 时)

同时在 `SamplerPlan.stageNames` 里记录实际加入的 stage 列表, 填进 profile event 的
`samplerPlanStages`, 方便日志侧复核是否按预期裁剪。

### B.4 次要优化 (generate/generateStreaming loop)

- `var buf = [CChar](repeating: 0, count: 256)` (L225 / L326) 提升到 loop 外一次分配
- `streamedText += String(cString: buf)` (L229 / L331) 改为 `pieces: [String] = []`
  + 最后 `pieces.joined()`; streaming 版保留 `onToken(piece)`
- `var singleToken = [newToken]` (L233 / L335) 改为 `var singleToken = newToken` +
  `withUnsafeMutablePointer(to: &singleToken) { ptr in llama_batch_get_one(ptr, 1) }`,
  避免每 token 一次 `[Int32]` 分配

### B.5 验证 (B)

**正确性回归 (默认口径, seed 未固定)**:

- `swift build && swift test` 全绿
- `LLMServiceE2ETests` 里所有 JSON structured output 相关用例通过
- Profile event 的 `finishReason` 分布优化前后基本一致 (不出现大量 `"length"` 或
  `"error"` 异常)
- Grammar fallback 场景手动验证: 用一个窄 JSON schema (例如只允许特定 enum), profile
  event 里 `grammarEnabled=true` 且仍能 decode 出合法 JSON

**严格回归 (可选, 需 `DICTKIT_LLM_SEED=<u32>`)**:

- 开启 seed override, commit 4+5 前后跑同 workload
- 比对 learning-aids 最终输出 (JSON 结构): 应 bit-level 一致
- 若不一致: 说明 B 的修改破坏了采样语义, 回退并排查
  (最可能的嫌疑: B.2 grammar fallback 或 B.3 no-op sampler 裁剪改变了链行为)

**性能回归** (与方向 C 合并执行): 见下节。

---

## 方向 C: 单请求性能基线 (JSON + per-operation 分桶)

### C.1 口径明确

**只做 JSON structured output 单一口径, 按 operation 分桶**。Workload 固定为:

- `LLMServiceE2ETests/testLearningAidsJudgeStrategyComparisonReportsTimingAndQualityAcrossTenWordsWhenEnabled`
- 10 词 × 1 round × (1 generate + 3 section judge + 1 combined judge) = **50 次推理**
- 分成 3 个 bucket: `generateLearningAids` (10) / `judgeSection` (30) /
  `judgeCombined` (10), 每桶各自算中位数
- 不承诺 text / streaming per-mode 对比

### C.2 前/后采集流程

核心原则: **baseline 和 after 用同一个 instrumentation 版本的 server**, 否则口径不一致。

| 阶段 | Server 版本 | 操作 |
|---|---|---|
| T0 | commit 1+2 已合入 (instrumentation only, 含 seed override + operation 字段) | 跑 3 次 E2E, `DICTKIT_LLM_PROFILE=1 DICTKIT_LLM_SEED=42` → **baseline** |
| T1 | commit 4+5 已合入 (instrumentation + sampling 优化) | 跑 3 次 E2E, 同 env → **after** |
| T2 | — | 按 operation 分桶对比 → 文档 |

**不存在"master 未改动 engine"的 baseline**, 因为那个版本根本没有 profile 数据输出。

每轮采集前:

```sh
rm -f /tmp/anki-mate-llm-perf.jsonl
```

采集时机: server 通过 parent process monitor 退出前, `ProfileTraceWriter.flush()`
会把所有 pending event 写完; 测试脚本在 server 退出后再读文件, 无竞态。

聚合 (per-operation 分桶):

```sh
jq -c 'select(.event=="inference_perf")' /tmp/anki-mate-llm-perf.jsonl \
  | jq -s '
      group_by(.operation)
      | map({
          operation: (.[0].operation // "unknown"),
          count: length,
          median_totalMs:       ([.[].totalMs]       | sort | .[length/2|floor]),
          median_samplingMs:    ([.[].samplingMs]    | sort | .[length/2|floor]),
          median_synchronizeMs: ([.[].synchronizeMs] | sort | .[length/2|floor]),
          median_decodeMs:      ([.[].decodeMs]      | sort | .[length/2|floor]),
          median_tps:           ([.[].tokensPerSecond] | sort | .[length/2|floor])
        })'
```

### C.3 对比表字段 (每 operation 一份)

对 `generateLearningAids` / `judgeSection` / `judgeCombined` 各自填一张:

| 指标 | baseline 中位 | after 中位 | Δ | 相对变化 |
|---|---|---|---|---|
| `totalMs` | | | | |
| `samplingMs` | | | | 目标: **显著下降** |
| `samplingMs / totalMs` | | | | 目标: **占比下降** |
| `synchronizeMs` | | | | 预期变化不大 (GPU 层) |
| `decodeMs` | | | | 预期变化不大 |
| `tokenToPieceMs` | | | | 预期小幅下降 (B.4) |
| `tokensPerSecond` | | | | 目标: **上升** |

### C.4 可选维度 (本轮不执行)

- 不同 `maxTokens` / `contextSize` / `DICTKIT_LLM_THREADS`
- text / streaming harness

### C.5 验收结论

能用数据回答 (**按 operation 分桶分别回答**):

- `synchronizeMs / totalMs` 占比 (衡量 "GPU 是否主瓶颈" 的正确指标)
- `samplingMs` 是否显著下降 (目标: 减半或更好)
- 优化后 learning-aids E2E 中位 wall time 是否稳定改善
- 在 `DICTKIT_LLM_SEED=42` 严格回归下, learning-aids JSON 输出是否 bit-level 等价

---

## 落地顺序 (commit 粒度)

1. **commit 1** — 基础设施, 不产生 perf 事件
   - 新增 `ProfileTraceWriter.swift` + `InferencePerfEvent` 结构体
   - `DICTKIT_LLM_PROFILE` / `DICTKIT_LLM_SEED` 读取 + `isProfilingEnabled` /
     `samplingSeedOverride` 缓存
   - `AnkiMateRPC.GenerateParams` 增加 `operation: String?`
   - `LLMService` 三个调用点加 operation 标签
   - `InferenceServing` 协议 + `InferenceEngine` 两个方法加
     `requestId: Int? = nil` + `operation: String? = nil`
   - `RPCDispatcher.handleGenerate` 透传 `id` + `operation`;
     `generateStreaming` 透传 `nil` + `operation`
   - `main.swift` 加 `ProfileTraceWriter.shared.flush()` 到 shutdown 路径
   - `makeSampler` 使用 `samplingSeedOverride ?? LLAMA_DEFAULT_SEED`
   - 此时没有任何埋点, 只是 pipeline 通了, event schema 完整
2. **commit 2** — 埋点并在请求结束时写 event (完成方向 A)
   - 5 个 `DispatchTime` 累加器
   - 在 `generate` / `generateStreaming` return 前 `ProfileTraceWriter.shared.record(...)`
   - 自验 A.5 (含 operation 分桶、shutdown flush、seed 回显)
3. **commit 3** — 采 baseline T0 (方向 C 第 1 次采集)
   - `rm -f /tmp/anki-mate-llm-perf.jsonl`
   - `DICTKIT_LLM_PROFILE=1 DICTKIT_LLM_SEED=42 swift test --filter ...`
   - 按 operation 分桶聚合, 写 baseline 表到本文件末尾 "Baseline (T0)" 章节
4. **commit 4** — sampling 核心优化 (方向 B.1 + B.2)
   - per-request local candidate buffer
   - grammar fallback 保守修复
5. **commit 5** — no-op sampler 裁剪 + loop 次要优化 (方向 B.3 + B.4)
   - 条件添加 sampler, `samplerPlanStages` 反映真实链
   - buf / pieces / singleToken 三处小优化
   - 严格回归 (seed=42): 确认 learning-aids JSON 输出 bit-level 等价
6. **commit 6** — 采 after T1 + 对比表定稿 (方向 C 第 2 次采集)
   - `rm -f /tmp/anki-mate-llm-perf.jsonl`
   - 同 env 跑 3 次, 按 operation 分桶聚合
   - 对比表按三个 operation 各填一份
   - 若结果理想: 收尾
   - 若 `synchronizeMs / totalMs > 60%`: GPU 层主导, 方向 D 才是下一步投资方向

---

## 风险与缓冲

| 风险 | 处理 |
|---|---|
| `UnsafeMutablePointer` 裸写越界 | `precondition(vocabSize <= candidateCapacity)` |
| `loadModel` 期间 vocab 变化 | per-request local scratch, 不跨请求共享, 天然免疫 |
| Grammar fallback 语义回退 | 保守方案: 第二次 apply 完整重填 logits + 重跑 grammar+chain, 仅省 Swift Array 分配 |
| Profiling 本身扰动测量 | flag 关闭时零代价; per-token 只做 UInt64 累加; event 构造和写入都在请求结束 |
| no-op sampler 裁剪改变输出 | `DICTKIT_LLM_SEED=42` 下 commit 4/5 前后跑严格回归, 要求输出 bit-level 等价 |
| 两进程写同一 jsonl 竞态 | **已消除**: server 和 client 各用独立文件 |
| 跨请求共享 candidateBuffer | **已消除**: 改为 per-request local scratch |
| Streaming 无 requestId | **已接受**: event `requestId: null`, 不改 /stream 协议 |
| `/tmp/anki-mate-llm-perf.jsonl` 被历史数据污染 | 每次采集前 `rm -f`; 文档对比表记录采集时间 |
| Writer async 写可能丢尾部 event | **已修复**: A.2.1 shutdown flush barrier + `FileHandle.synchronize` 落盘 |
| 50 次推理混在一个中位数里 | **已修复**: A.4.1 operation 标签分桶 |
| 当前 seed 实为随机, "bit-level 等价"不可执行 | **已修复**: A.1 新增 `DICTKIT_LLM_SEED` override |
| `operation` 字段下发要改 RPC schema | `GenerateParams.operation: String?` 向后兼容 (缺省 nil), 旧 client 不受影响 |

---

## 明确不做 (本轮)

- shared-model multi-session
- 双 worker process pool (方向 D)
- Speculative decoding
- 动态调整 threads / batch size
- 改 chat template 或 prompt 结构
- 修改 JSON schema bridge
- 为 profiling 新增 HTTP/RPC endpoint
- text / streaming 模式的前后对比 harness
- 改 /stream 协议为 JSON-RPC envelope
- 把 `decodeMs` 解读为 "GPU wait"
- 把 candidateBuffer 做成跨请求共享 scratch
- 把 seed 默认值改成固定 (保持 `LLAMA_DEFAULT_SEED` 默认随机, 避免生产行为变化)
- 把 `operation` 做成强类型 enum (保持 String?, 给上层灵活度)

---

## 验证清单 (End-to-End)

- [ ] `swift build` 通过
- [ ] `swift test` 全绿
- [ ] `DICTKIT_LLM_PROFILE=1 swift test --filter LLMServiceE2ETests` 产出
      `inference_perf` 日志行到 `/tmp/anki-mate-llm-perf.jsonl`
- [ ] 日志字段齐全、数值非负、近似闭合 (overhead < 15%)
- [ ] 连跑 3 次同测试, event 数量稳定一致 (shutdown flush 生效)
- [ ] `jq '.operation' | sort | uniq -c` 至少看到 `generateLearningAids` /
      `judgeSection` / `judgeCombined` 三类, 数量比例 1:3:1
- [ ] 关闭 profiling 时无新增 `inference_perf` 行, 功能行为不变
- [ ] `/` 路径 event 有整数 `requestId`; `/stream` 路径 event `requestId` 为 null
- [ ] JSON structured output 场景可正常 decode
- [ ] `DICTKIT_LLM_SEED=42` 下, commit 4+5 前后 learning-aids JSON 输出 bit-level 等价
- [ ] 未设 `DICTKIT_LLM_SEED` 时, event `seed` 字段为 `4294967295` (`LLAMA_DEFAULT_SEED`)
- [ ] baseline (T0) 和 after (T1) 在同 instrumentation 版本上采集
- [ ] **按 operation 分桶后**, 对比表里 `samplingMs / totalMs` 至少在
      `judgeSection` 桶有明确下降 (该桶请求量最大, 最能代表优化效果)
- [ ] `sampleCandidate` 不再每 token 分配 vocab-sized Swift Array
- [ ] `ProfileTraceWriter` 与 `LLMDebugTraceWriter` 写入互不影响的独立文件

---

## Baseline (T0) — 待 commit 3 后填写

> 采集时间:
>
> Server 版本: commit 1 + commit 2
>
> 环境: `DICTKIT_LLM_PROFILE=1 DICTKIT_LLM_SEED=42`, 3 次 E2E 聚合中位数
>
> 硬件:

### generateLearningAids (n=?)

| 指标 | 中位 |
|---|---|
| `totalMs` | |
| `samplingMs` | |
| `samplingMs / totalMs` | |
| `synchronizeMs` | |
| `decodeMs` | |
| `tokenToPieceMs` | |
| `tokensPerSecond` | |

### judgeSection (n=?)

| 指标 | 中位 |
|---|---|
| `totalMs` | |
| `samplingMs` | |
| `samplingMs / totalMs` | |
| `synchronizeMs` | |
| `decodeMs` | |
| `tokenToPieceMs` | |
| `tokensPerSecond` | |

### judgeCombined (n=?)

| 指标 | 中位 |
|---|---|
| `totalMs` | |
| `samplingMs` | |
| `samplingMs / totalMs` | |
| `synchronizeMs` | |
| `decodeMs` | |
| `tokenToPieceMs` | |
| `tokensPerSecond` | |

---

## After (T1) — 待 commit 6 后填写

> 采集时间:
>
> Server 版本: commit 1 + commit 2 + commit 4 + commit 5
>
> 环境: 同 T0
>
> 硬件: 同 T0

### generateLearningAids (n=?)

| 指标 | baseline 中位 | after 中位 | Δ | 相对变化 |
|---|---|---|---|---|
| `totalMs` | | | | |
| `samplingMs` | | | | |
| `samplingMs / totalMs` | | | | |
| `synchronizeMs` | | | | |
| `decodeMs` | | | | |
| `tokenToPieceMs` | | | | |
| `tokensPerSecond` | | | | |

### judgeSection (n=?)

| 指标 | baseline 中位 | after 中位 | Δ | 相对变化 |
|---|---|---|---|---|
| `totalMs` | | | | |
| `samplingMs` | | | | |
| `samplingMs / totalMs` | | | | |
| `synchronizeMs` | | | | |
| `decodeMs` | | | | |
| `tokenToPieceMs` | | | | |
| `tokensPerSecond` | | | | |

### judgeCombined (n=?)

| 指标 | baseline 中位 | after 中位 | Δ | 相对变化 |
|---|---|---|---|---|
| `totalMs` | | | | |
| `samplingMs` | | | | |
| `samplingMs / totalMs` | | | | |
| `synchronizeMs` | | | | |
| `decodeMs` | | | | |
| `tokenToPieceMs` | | | | |
| `tokensPerSecond` | | | | |

### 结论与下一步决策

> commit 6 完成后填写:
>
> - `samplingMs` 在三个桶的下降幅度:
> - `synchronizeMs / totalMs` 占比:
> - `tokensPerSecond` 改善幅度:
> - 严格回归 (seed=42) 下 JSON 输出是否 bit-level 等价:
> - 是否进入方向 D (双 worker pool):
