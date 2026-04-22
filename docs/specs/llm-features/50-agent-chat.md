# 功能岛 5：Agent 对话界面

## 1. 前因

当前 `AIContentView` 是结构化面板：用户按下每个模块的 `Regenerate` 才会触发一次性生成，建议以 `suggested` / `accepted` 双列表呈现。它擅长"一次生成一类内容"，但有三类需求承接得不自然：

- 用户想用自然语言表达修改意图，例如"这个例句换成商业语境"、"Back 太啰嗦，砍掉后面两条释义"
- 用户在做卡过程中会临时冒出语言学习问题,例如"apple 和 fruit 的语义包含关系"、"它在商业语境里有哪些 pitfall"
- 用户希望看到建议落到卡片上之后**真的长什么样**,再决定要不要接受,而不是阅读一段文本后再手动去结构化面板里翻

这些需求指向一个新的交互形态：对话 + 卡片差异预览 + 显式确认。与结构化面板并存,不替代。

## 2. 功能目标

在单词详情下方提供一个对话式子面板 `Chat`,让用户能：

- 用自然语言向 Agent 表达"看卡、改卡、问词"意图
- 看到 Agent 基于**当前实际卡片**的回答,而不是基于词典原文的泛解释
- 在应用任何修改之前,于右侧卡片预览看到"应用后"的 diff 效果
- 对每条建议单独决定 apply / dismiss；apply 后数据进入现有 `aiArtifacts.suggested`,再由现有工作流落到 `accepted`
- 把纯学习问答的结论一键转成 pitfall / mnemonic / collocation / usage cue 的 proposal

Agent 以"真实 Anki 用户"视角说话：它假设自己刚做完这张卡、马上就要复习它,因此会本能地反对冗余、关心复习负担、对模糊的 cue 挑剔。

## 3. 范围

覆盖内容：

- `AIContentView` 顶部的 `Structured` / `Chat` 两段式切换
- Chat 面板内的消息列表、上下文条、Action Card、输入区
- `CardPreviewView` 的 diff 预览扩展
- Agent 会话引擎：消息流、tool 调度、proposal 生命周期
- Agent tool 集：读 tool 自动执行、写 tool 走 proposal 确认
- 会话本地持久化(SQLite 新表),与 WebDAV 同步完全隔离
- 会话上下文三层修剪(近 N 轮完整 + 早期摘要 + proposal 决策汇总)
- Agent 遇到布局/样式/模板类请求时的显式拒绝与记录

不覆盖内容：

- 独立 Agent 窗口(先做内嵌,验证后再考虑)
- Agent 自动 apply 写 tool(一律需要用户确认)
- **卡片布局、样式、模板修改**：section 顺序、颜色、字号、间距、CSS、HTML 模板编辑均不做；Agent 遇到此类请求直接拒绝并说明,收集数据为未来版本决策
- 跨词搜索对话、跨词知识库
- 云端模型接入(一期仅本地 llama)
- 会话跨设备同步
- 多会话(一词一会话锁定,未来扩展)
- 图像 / 语音输入
- Agent 主动批量触发(冷启动的欢迎建议可后置)

## 4. 总览实施计划

### 4.1 入口与形态

`AIContentView` 顶部新增一行两段式分段控件 `Structured | Chat`,默认 `Structured` 以匹配老用户肌肉记忆。切换到 `Chat` 时整个内容区替换为 `AgentChatView`,不卸载 `Structured` 的状态(切回去时草稿保留)。

`CardPreviewView` 不变位置、不变默认行为。它接受一个可选的 `overrideArtifacts: AIArtifacts?`。当 Agent 面板 hover 或选中某个 pending proposal 时,`CardPreviewView` 收到"应用后"的 `AIArtifacts` 做渲染,并在预览顶部显示 `Reviewing Agent proposal — [Apply] [Dismiss]` 横幅。

### 4.2 交互原则

- **读 tool 自动执行**：`read_card_snapshot`、`search_dictionary` 等不改数据的 tool 直接执行,结果以 collapsed 小卡显示在对话流里,但不打断对话节奏
- **写 tool 走 proposal**：任何会修改 `aiArtifacts` 的意图都必须先出 `ProposalRecord`,由用户点击 `Apply` 才真正调 `WordListViewModel.saveAISuggested*`
- **一个消息可含多个 proposal**：Agent 一次分析可以出多条修改,每条独立 apply / dismiss,不强制 all-or-nothing
- **语言跟随**：prompt builder 嗅探最近几条用户消息的语言,Agent 用同一种语言回答,不持久化"偏好语言"
- **失败不中断**：tool 执行失败、流式断开、模型不可用都降级为一条 error message,会话仍可继续输入
- **能力边界坦白**：布局/样式/模板类请求不假装能做,Agent 直接拒绝并说明现阶段只能改内容

### 4.3 Agent 身份与 prompt

System prompt 强调四件事：

- **身份**：你是一个正在自己整理 Anki 词卡的学习者；你刚给这个词做完卡片,马上就要用 SRS 复习它
- **偏好**：你讨厌冗余,优先保留最高频 / 最易混的义项；不确定就问,不要乱生成
- **产出**：解释类问题直接回答,修改类请求先说 why(作为复习者会在哪里卡住)再说 what,然后用 `propose_*` tool 产出具体改动
- **能力边界**：你只能修改卡片**内容**(释义、例句、recall、pitfalls、mnemonics、collocations、usage cue)。你**不能**改布局、样式、颜色、字号、section 顺序、模板结构。遇到这类请求时简短说明"一期只支持内容编辑,布局和样式调整暂未开放",不要尝试生成任何相关 proposal

Prompt 每轮动态注入：

- 身份层(静态模板)
- 能力与 tool 说明(含能力边界声明)
- 当前卡片 snapshot：**ASCII wireframe**(见 §4.4) + 结构化 accepted artifacts 列表
- Pending proposals 汇总(避免 Agent 重复提议已在 pending 的内容)
- 近期 applied / dismissed proposals 汇总(让 Agent 避免重复骚扰用户已拒绝的方向)
- 对话历史(经 4.10 的修剪)

### 4.4 卡片 Wireframe 注入

Agent 需要理解的是"卡片最终长什么样",不是"字段里有哪些值"。纯结构化 JSON 让 Agent 在脑里重建空间关系代价高,容易把 `examples[2]` 和视觉上看到的"第二条例句"对不上,也无法感知"这张 Back 是不是太长"。

所以每轮 prompt 注入**两份互补的卡片表示**：

- **ASCII wireframe**：模拟渲染后的视觉形态,让 Agent 看到"最终效果"
- **结构化 JSON**：给 tool 调用用,写 proposal 时从 JSON 抄稳定的 artifact id

两份由同一个 `CardRenderSnapshot` 同步生成,永不手写,永不漂移。

#### 4.4.1 ASCII wireframe 格式

一期固定以下结构,Standard 和 Recall 两种卡型各一套模板。Standard 样例：

```
┌─────────── FRONT ──────────────────────────────┐
│ apple                                           │
│ /ˈæp.əl/                                        │
└─────────────────────────────────────────────────┘
┌─────────── BACK ───────────────────────────────┐
│ [noun]                                          │
│   1. (fruit) a round fruit with red or green   │
│      skin and firm white flesh                  │
│      • An apple a day keeps the doctor away.    │
│      • She packed an apple in his lunch.        │
│   2. (tree) the tree on which this fruit grows  │
│                                                 │
│ [AI · usage cue]                                │
│   Usually the fruit; capital-A Apple refers     │
│   to the company.                               │
│                                                 │
│ [AI · examples] (2 items)                       │
│   • Apple Inc. released a new model. — 苹果…   │
│   • I ate an apple for breakfast.               │
│                                                 │
│ [AI · pitfalls] (1 item)                        │
│ [AI · mnemonics] (empty)                        │
│ [AI · collocations] (2 items)                   │
└─────────────────────────────────────────────────┘
```

Canonical section ordering inside BACK 是 `usageCue → examples → pitfalls → mnemonics → collocations`,与 `AnkiFieldFormatter.aiSupplementHTML` 锁死一致。空态 section 仍列出并标 `(empty)`,非空 section 后缀显示 `(N item/items)`,超过展示上限的内容补 `(N more, collapsed)` 摘要行(一期阈值:examples / pitfalls / mnemonics / collocations 各展示前 3 条)。

Recall 样例：

```
┌─────────── FRONT (Recall · phraseRecall) ──────┐
│ 她每天吃一个 ___ 来保持健康。                   │
│ hint: 一种水果                                  │
└─────────────────────────────────────────────────┘
┌─────────── BACK ───────────────────────────────┐
│ apple                                           │
│ /ˈæp.əl/                                        │
│                                                 │
│ [Source dictionary]                             │
│   noun — a round fruit with red or green skin…  │
└─────────────────────────────────────────────────┘
```

#### 4.4.2 wireframe 生成规则

- **每行宽度**：50 半角字符(东亚字符按 2 宽计算),模拟真实卡片 viewport 的相对占比
- **框线**：用 `┌ ┐ └ ┘ ─ │` 组装,不用 ASCII 替代,保证单一视觉风格
- **section 标签**：词典原生内容前加词性方括号标签 `[noun]` / `[verb]`；AI artifacts 前加 `[AI · xxx]` 前缀
- **senses 编号**：用有序号 `1.` `2.`,与真实卡片 `<ol>` 语义一致
- **semantic hint**：放在释义前的圆括号里,例如 `(fruit)` `(tree)`
- **examples**：以 `•` bullet 渲染,缩进与 sense 内容对齐
- **长文本截断**：单条文本超过三行时,保留前两行并以 `…` 结尾；Agent 需要完整内容时调 `read_card_snapshot`
- **空 section**：依然列出,后缀 `(empty)`,让 Agent 知道"这类 artifact 可填"
- **数量多或不重要时折叠**:超过 3 条或 Agent 很少直接引用的 section(典型是 collocations),显示 `(N items, collapsed)`;Agent 需要细节时调 `read_card_snapshot`
- **音频**:用 `🔊` 标记音频可用,无音频不显示
- **Recall front**:`___` 代表 blank;`hint:` 行只在有 hint 时出现
- **Front / Back 分隔**:用两段独立的框线区,不合并

#### 4.4.3 结构化 JSON 对照

wireframe 之后紧跟结构化快照,让 Agent 有机会对上稳定 id:

```json
{
  "word": "apple",
  "phonetic": "/ˈæp.əl/",
  "senses": [
    { "id": "sense-0-0", "pos": "noun", "definition": "…", "examples": ["…", "…"] },
    { "id": "sense-0-1", "pos": "noun", "definition": "…", "examples": [] }
  ],
  "artifacts": {
    "examples":     [{ "id": "ex-1", "text": "Apple Inc. released a new model.", "translation": "苹果…" }],
    "usageCue":     { "text": "Usually the fruit; capital-A Apple…" },
    "pitfalls":     [{ "id": "pf-1", "text": "…" }],
    "mnemonics":    [],
    "collocations": [{ "id": "co-1", "phrase": "…" }, { "id": "co-2", "phrase": "…" }]
  },
  "recall": { "mode": "phraseRecall", "front": "…", "back": "apple", "hint": "一种水果" }
}
```

Agent 的 `propose_example(operation=replace, targetID=...)` 之类调用必须引用 JSON 里的 `id`,wireframe 只用于认知,不用于 tool 参数。

#### 4.4.4 一致性保证

- wireframe 的 section 顺序、JSON 的 artifacts 键顺序、`AnkiFieldFormatter` 的 `aiSupplementHTML` 输出顺序三者锁死一致
- `CardRenderSnapshotTests` 需断言:给定同一 `WordItem` + `AIArtifacts`,wireframe 与 JSON 描述的 section 数量和顺序完全相同
- wireframe 生成是纯函数,不依赖 UI 渲染状态,离线可测

### 4.5 Tool 集

所有 tool 都映射到已有能力,Agent 不引入新的写路径。

读 tool(自动执行)：

| Tool | 作用 | 来源 |
| --- | --- | --- |
| `read_card_snapshot` | 当前卡片 front / back 纯文本与结构化 artifacts | `AnkiFieldFormatter` + `AIArtifacts` |
| `search_dictionary` | 调系统词典拿原始释义 | `DictKitSystemDictionary` |
| `list_accepted_artifacts` | 列出已 accepted 的各类 artifact | `WordItem.aiArtifacts` |

写 tool(一律走 proposal 确认)：

| Tool | 作用 | 映射到 |
| --- | --- | --- |
| `propose_usage_cue` | 替换 / 删除 usage cue | `saveAISuggestedDefinitionNote` |
| `propose_example` | add / replace / delete 例句 | `saveAISuggestedExampleArtifacts` |
| `propose_recall_draft` | 生成新 Recall 草稿 | `saveAISuggestedRecallCardDrafts` |
| `propose_pitfall` | 学习辅助：易错点 | `saveAISuggestedPitfallArtifacts` |
| `propose_mnemonic` | 学习辅助：记忆提示 | `saveAISuggestedMnemonicArtifacts` |
| `propose_collocation` | 学习辅助：搭配 | `saveAISuggestedCollocationArtifacts` |
| `propose_delete_accepted` | 提议删除某个已 accepted 项 | 对应 `saveAIAccepted*` |

一期**不**引入任何 `propose_layout_*` / `propose_style_*` / `propose_template_*` tool。

Tool 调用走 llama.cpp 原生 function calling:

- Prompt / grammar / 输出解析全部由 `CLlamaChatTemplateBridge` 通过 `common_chat_templates_apply` + `common_chat_parse` 提供;不再有「文本回复 + 尾部 JSON fence」的后处理路径
- `LLMService.generate(messages:tools:toolChoice:parallelToolCalls:responseFormat:...)` 是唯一入口,`tools` / `toolChoice` / `parallelToolCalls` 都是 OpenAI 风格的可选参数
- 当 caller 提供 `responseFormat` 时,结构化输出的 grammar 优先于 template 的 tool grammar,保护已有 structured output 契约
- Streaming 与 tools 互斥:`generateStreaming` + 非空 `tools` 直接抛 `unsupportedResponseFormat`,因为 tool-call 解析需要完整输出。Agent 写 tool 的提议路径因此走 non-streaming `generate`;纯文本解答仍可 streaming

### 4.6 Proposal 生命周期

```
[Agent 产出] -> pending -> (user applies)   -> applied
                        -> (user dismisses) -> dismissed
                        -> (session cleared) -> hard-deleted
```

- `pending`：驻留在 `agent_messages` 里,不写入 `aiArtifacts.suggested`
- `applied`：调对应 `saveAISuggested*` 写进 suggested；message 标 `applied`；原有 suggested → accepted 流程由 `AIContentView` 承接
- `dismissed`：留下记录但不影响卡片；下次 Agent 装配上下文时能看到,避免重复骚扰

### 4.7 Action Card 展示

对话流中的 proposal 用独立样式的卡片渲染,包含：

- 改动类型与目标(`修改 Usage cue` / `新增例句 #3` / `删除 Pitfall "Don't confuse..."`)
- 旧值与新值的对照(删除场景只显示旧值,新增场景只显示新值)
- Agent 给出的 rationale(一行)
- 操作按钮：`Preview` / `Apply` / `Dismiss`；`Preview` 只是把右侧 `CardPreviewView` 切到该 proposal 的 overrideArtifacts,不落盘

### 4.8 能力边界的拒绝处理

Agent 遇到布局/样式/模板类请求时：

- 不调用任何 tool
- 回复一句简短说明,例如"这个属于卡片布局调整,一期还没支持,我只能帮你改内容"
- 同时写入一条 `kind = layout_request_declined` 的 message,payload 记录用户原始请求文本和 Agent 识别到的诉求类型(`layout` / `style` / `template`)
- UI 上这条 message 的展示与普通 Agent 回复一致,无特殊标记；数据仅供未来统计和路线决策使用

判定是否落入"布局类请求"由 Agent 自己的语义判断决定,不做关键词硬匹配。如果 Agent 误判把内容请求当布局拒了,用户可以直接再问一次或改用 Structured 面板,损失可控。

### 4.9 会话粒度

一词一会话。`agent_sessions.word_id` 加 UNIQUE 约束,外键 `ON DELETE CASCADE`。WordItem 被删除时会话自动清理。

用户界面上只有一个 `Clear Chat` 入口,效果为清空 messages 但保留 session 行及其 preferences_json,让"自动执行读 tool"等偏好不被意外重置。另有隐藏入口 `Reset Session` 整行删除,供极端情况。

### 4.10 存储模型

新增两张 SQLite 表到现有 `WordListStore` 的 db：

```sql
CREATE TABLE agent_sessions (
    id TEXT PRIMARY KEY,
    word_id TEXT NOT NULL UNIQUE,
    created_at REAL NOT NULL,
    updated_at REAL NOT NULL,
    schema_version INTEGER NOT NULL,
    preferences_json TEXT,
    FOREIGN KEY (word_id) REFERENCES words(id) ON DELETE CASCADE
);

CREATE TABLE agent_messages (
    id TEXT PRIMARY KEY,
    session_id TEXT NOT NULL,
    ordinal INTEGER NOT NULL,
    role TEXT NOT NULL,
    kind TEXT NOT NULL,
    status TEXT NOT NULL,
    created_at REAL NOT NULL,
    content_json TEXT NOT NULL,
    proposal_decision TEXT,
    tool_name TEXT,
    superseded_by TEXT,
    FOREIGN KEY (session_id) REFERENCES agent_sessions(id) ON DELETE CASCADE
);

CREATE INDEX idx_agent_messages_session_ord ON agent_messages(session_id, ordinal);
CREATE INDEX idx_agent_messages_pending_proposals
    ON agent_messages(session_id) WHERE proposal_decision = 'pending';
```

字段语义：

- `kind`：`text` / `tool_call` / `tool_result` / `proposal` / `summary` / `error` / `layout_request_declined`
- `status`：`pending` / `streaming` / `completed` / `canceled` / `failed`
- `content_json`：序列化的 `MessageContent`(见 §8 Swift 类型草稿)
- `proposal_decision`：`pending` / `applied` / `dismissed`,非 proposal 消息为 NULL；冗余字段便于 pending 扫描
- `tool_name`：便于筛查特定 tool 的历史,非 tool 消息为 NULL
- `superseded_by`：指向一条 `kind=summary` 的 message id,被摘要替代的原始消息不进上下文

Schema 版本：现有 v1 升 v2,迁移脚本仅新增表与索引,不触碰已有数据。

### 4.11 上下文装配与修剪

每轮请求前三层拼装：

- **Layer 1 近期原文**：最近 12 轮对话全文(跳过 `superseded_by IS NOT NULL`),包含完整 tool result
- **Layer 2 早期摘要**：更早的 message 以每 5 轮压成 1 条的比例,通过 `LLMService` 跑一次 summarize 任务,产出 `kind=summary` 的 message 入表,被摘要的原始消息打上 `superseded_by`
- **Layer 3 Proposal 决策汇总**：SQL 实时汇总 applied / dismissed 的 proposal 摘要,以一条合成 system message 形式注入

三层总 token 预算根据模型能力动态上限,超出时优先压缩 Layer 2 与 Layer 3,Layer 1 近期 5 轮强保留。

硬盘保留策略(独立于上下文装配)：

- 默认保留 90 天内的消息
- 每词最多 500 条消息,超出按 ordinal 升序硬删
- 用户可在 AI 设置里调整这两个阈值
- 启动时跑一次 purge,非阻塞

### 4.12 同步隔离

`SyncManifest` / `WordListStore+Sync.swift` 采用**白名单**同步：只导出 `collections` / `words` / `word_payloads` 三张表。`agent_sessions` / `agent_messages` 永不进入 manifest,也不参与 merge。

增加一个断言测试：`SyncManifest.build()` 的输出中不含任何 `agent_` 前缀的字段或表名。新增同步表必须显式加白名单,防止未来误带敏感对话进 WebDAV。

### 4.13 Proposal 应用与对账

Apply 的执行顺序：

1. 调 `viewModel.saveAISuggested*()` 写进 `aiArtifacts.suggested`
2. 成功后更新 `agent_messages.proposal_decision = 'applied'`

两步不在同一事务,因为 `WordListStore` 的写路径本身自包含。后一步失败只会导致该 proposal 在 UI 上仍然显示 pending,不会丢数据。

启动时对账脚本：

- 扫所有 `proposal_decision = 'pending'` 的 proposal
- 比对 payload 的 artifact id 是否已出现在对应 word 的 `aiArtifacts.suggested` 或 `accepted` 中
- 命中则把该 proposal 标为 `applied`

对账也处理用户在 Structured 面板手动操作与 Agent 建议重合的情况：用户直接在结构化面板 Save 了和 Agent 建议一致的例句,下次打开 Chat 时该 proposal 自动显示为已应用。

崩溃恢复：启动时把 `status = 'streaming'` 的消息一律改为 `status = 'canceled'` 并标注 `interrupted: true`。

### 4.14 写入时机

| 事件 | 落盘行为 |
| --- | --- |
| 用户发送消息 | 立即 insert,ordinal 自增 |
| Agent 流式 delta | 不落盘,仅更新内存 |
| 流式完成 | update content_json + status=completed |
| 用户取消流式 | update content_json(当前已收到部分)+ status=canceled |
| 读 tool 执行完 | 立即 insert toolCall + toolResult |
| Agent 产出 proposal | 立即 insert,decision=pending |
| Agent 拒绝布局请求 | 立即 insert kind=layout_request_declined,content_json 含用户原始请求与识别类型 |
| 用户 Apply | 先调 saveAISuggested* 再 update decision=applied |
| 用户 Dismiss | update decision=dismissed |
| Clear Chat | DELETE FROM agent_messages WHERE session_id=?；session 行保留 |
| Reset Session | DELETE FROM agent_sessions WHERE word_id=?(cascade 清 messages) |
| WordItem 删除 | 外键 cascade 自动清理 |

## 5. UI 设计

### 5.1 AgentChatView 布局

```
┌──────────────────────────────────────────────┐
│ [Structured] [ Chat ● ]                      │ ← AIContentView 顶部切换
├──────────────────────────────────────────────┤
│ Context bar: apple · noun · Recall: saved    │
│                                  [snapshot…] │ ← 展开可看 Agent 当前看到的卡片快照
├──────────────────────────────────────────────┤
│                                              │
│  ┌─ Agent ─────────────────────────────┐     │
│  │ 你当前 Back 列了 5 条释义…作为…    │     │
│  │                                      │     │
│  │ ┌─ Proposed edit ─────────────┐    │     │
│  │ │ 修改 Usage cue (替换)        │    │     │
│  │ │ - 旧: ...                   │    │     │
│  │ │ + 新: ...                   │    │     │
│  │ │ 理由: 原释义没区分专名用法  │    │     │
│  │ │ [Preview] [Apply] [Dismiss] │    │     │
│  │ └──────────────────────────────┘    │     │
│  └──────────────────────────────────────┘    │
│                                              │
│  ┌─ You ───────────────────────────────┐     │
│  │ 第二个 example 换成商业语境的       │     │
│  └──────────────────────────────────────┘    │
│                                              │
├──────────────────────────────────────────────┤
│ [@ examples] [@ back] [@ pitfalls]           │ ← 快捷引用
│ ┌──────────────────────────────────────┐    │
│ │ 说点什么…                   (⌘↩ 发送) │    │
│ └──────────────────────────────────────┘    │
└──────────────────────────────────────────────┘
```

### 5.2 组件拆分

SwiftUI view 拆分：

- `AgentChatView`：总容器、与 `AgentSession` 绑定、订阅消息流
- `AgentContextBar`：摘要 + 查看快照浮层
- `AgentMessageList`：滚动容器 + 自动滚底
- `AgentMessageBubble`：普通文本消息气泡(含 `layout_request_declined` 的渲染,不做特殊样式)
- `AgentToolTraceRow`：读 tool 的折叠展示
- `AgentActionCard`：写 tool 的 proposal 卡片,hover 驱动 preview override
- `AgentComposer`：多行输入 + @ 快捷 + 发送 / 取消

### 5.3 Diff 预览联动

`CardPreviewView` 新增可选参数 `overrideArtifacts: AIArtifacts?`。`AgentSession` 暴露 `@Published var previewOverrideArtifacts: AIArtifacts?`,由 `AgentActionCard` 的 hover / focus 事件驱动。

预览处于 override 模式时：

- 顶部出现红色横幅 `Reviewing Agent proposal`
- 预览内容用 `AIArtifacts` 合成结果渲染
- 横幅上的 `Apply` / `Dismiss` 与对应 `AgentActionCard` 的按钮等价
- 离开 hover 或显式点 `Dismiss` 则清除 override,回到 baseline

### 5.4 快捷引用

`AgentComposer` 的 `@` 触发菜单,可插入引用 token：

- `@back` / `@front`：注入当前卡 snapshot
- `@examples[i]`：注入第 i 条 example 的文本
- `@pitfalls` / `@mnemonics` / `@collocations`：注入对应 artifact 列表
- `@recall`：注入当前 Recall draft

引用 token 以可视化 chip 显示在输入区,发送时替换为 Agent 能识别的结构化文本。

## 6. 用户动线

### 6.1 新卡冷启动

1. 用户添加 `apple`,词典查完、自动 IPA 完成
2. 切到 Chat 面板,输入框占位 "帮我给 apple 做一张精简的 Anki 卡"
3. 用户发送,Agent 读 snapshot 后回复分析 + 3 条 proposal
4. 用户 hover 每条 proposal 在右侧预览看效果
5. 用户逐条 Apply,对应内容进入 `aiArtifacts.suggested`
6. 用户切到 Structured 面板或直接在 Chat 内"再 Save"把 suggested 升级为 accepted

### 6.2 微调已有卡

1. 用户选中已做过的词,切 Chat
2. 发 "第二个例句太长了,换个短的"
3. Agent 执行 `read_card_snapshot` 定位 example[1],产出 `propose_example(operation=replace, targetID=...)`
4. 用户 Preview → Apply → 旧 example 进入待替换,新 suggested 插入
5. 用户在 Structured 面板确认 Save 完成整个链路

### 6.3 纯学习问答

1. 用户问 "apple 和 fruit 的语义包含关系"
2. Agent 只回答,不出 proposal
3. 回答末尾 Agent 可以自动附一个小按钮 "把这条差异存成 Pitfall"
4. 用户点击则产生一个 `propose_pitfall`

### 6.4 问完再改

1. 用户问 "这个词在商业语境里会有什么 pitfall",Agent 讲解
2. 用户说 "把你刚说的第二点加到卡里"
3. Agent 产出 `propose_pitfall` proposal
4. 用户 Apply

### 6.5 Recall 重设计

1. 用户说 "现在这张 Recall 卡提示太弱,我每次都能猜到"
2. Agent 读当前 recall draft,提出换 mode(`phraseRecall` → `targetedLetterCloze`)并给出新 front
3. `CardPreviewView` 在 Recall 模式下显示 diff
4. 用户 Apply

### 6.6 被拒绝的布局请求

1. 用户说 "把 pitfalls 挪到 examples 前面"
2. Agent 回 "这个属于卡片布局调整,一期还没支持,我只能帮你改内容"
3. 系统记录一条 `layout_request_declined` message,包含用户原文与识别类型
4. 用户可重述为内容级请求,例如 "那把 pitfall 写得更像 example 一点",Agent 正常响应

## 7. 技术实现路线

### 7.1 Phase 1 — 预览基础设施

- `CardPreviewView` 支持 `overrideArtifacts: AIArtifacts?`,不影响现有调用
- 抽 `CardRenderSnapshot`：给定 `WordItem` + `AIArtifacts` 输出 `{ word, phonetic, frontPlain, backPlain, backMarkdown, artifactsSummary, wireframe, structuredJSON }`
- `CardWireframeRenderer`：纯函数,从 `CardRenderSnapshot` 生成 §4.4.1 / §4.4.2 定义的 ASCII wireframe；Standard / Recall 各一套模板
- 测试：
  - `CardRenderSnapshotTests` 覆盖 standard / recall 两种卡、空 artifacts / 满 artifacts 两种极端
  - `CardWireframeRendererTests`：
    - 固定 fixture 下 wireframe 字符串字节级稳定(snapshot test)
    - 折叠规则:超过 3 条 collocations 时出现 `(N items, collapsed)`
    - 长文本截断:超过三行的释义以 `…` 结尾
    - 空 section 出现 `(empty)` 标签
    - wireframe 中 section 顺序与 structuredJSON.artifacts 键顺序一致

### 7.2 Phase 2 — 会话引擎 + 存储

**进度小结**

- Phase 2a(原生 function calling 接入)已完成：`InferenceEngine` / `RPCDispatcher` / `LLMService` 三层联通；`LLMService.generate(...)` 成为单一生成入口；`tools` / `toolChoice` / `parallelToolCalls` 作为 OpenAI 风格可选参数贯通 RPC wire。
- Phase 2b(chat template bridge 统一化)已完成：`InferenceEngine` 删除所有手写 Gemma `<start_of_turn>` 模板字符串；prompt / grammar / output parse 全部走 `common_chat_templates_apply` + `common_chat_parse` 桥接，普通 chat、structured output、tool calling 共享同一 `runGeneration` 管线。`InferenceEngine.loadModel(...)` 在加载期 eager 初始化 chat template handle，模板不可用即 load 失败，不拖到首次 `generate`。详见 `51-chat-template-bridge-handoff.md`。
- Phase 2c(会话引擎 + 存储)已落一个可用版本：
  - `Sources/AnkiMateLLM/Agent/` 已新增 `AgentSession`、`AgentToolRegistry`、`AgentPromptBuilder`、`AgentSummarizer`、`AgentProposalArtifacts`
  - `Sources/DictKitApp/Persistence/Agent/AgentSessionStore.swift` 已接入 SQLite 会话存储、proposal 对账、message ordinal 与 crash recovery
  - `WordListStore.schemaVersion` 已从 v1 升到 v2，agent 会话表通过增量迁移创建
  - `WordListStore+Sync.swift` / `SyncManifestTests` 已显式把 agent 表排除在同步白名单之外
  - proposal 生命周期已打通：`pending -> applied / dismissed`，`apply` 时写回 `AIArtifacts.suggested`

**Phase 2 的出口条件**(未满足前不进 Phase 3)

- `swift build` + `swift test` 全量通过(期望 306 pass / 12 skip：10 个 E2E 需本地模型；2 个 `XCTSkip` 对应 `WordListViewModelTests.testSelectingWordDoesNotAutoRefreshUntilExplicitlyRequested` 与 `CommandPaletteViewModelTests.testValidationAllowsAddRowWhenDictionaryLookupSucceeds`，与 Phase 2 无关)
- 一次真实 GGUF 加载的 smoke：load 成功后 `chatTemplatesHandle != nil`；调一次 `generate(messages:tools:...)` 肉眼确认 bridge 产 prompt 正确、`GenerateResult.toolCalls` 能正确填充
- `parallelToolCalls` 端到端回归(至少一个 mock 级双 tool_call 用例走通 RPC → 解析 → `LLMToolCall[]`)
- 具体函数指定的 `toolChoice`(形如 `{"type":"function","function":{"name":"foo"}}`)目前降级为 `auto`；如果 Phase 2c 的会话引擎里确有强制调用某 tool 的需求，需在进入 Phase 2c 前先补这个路径

当前状态说明：

- `Agent` 范围的单测已经覆盖 prompt builder、summarizer、tool registry、session store、session proposal lifecycle，并可通过 `swift test --filter Agent`
- 但本节出口条件要求的全量 `swift test`、真实 GGUF smoke、`parallelToolCalls` 端到端验证，仍应在进入收尾阶段前重新 fresh run 一次

**Phase 2c 工作项**

- 新目录 `Sources/AnkiMateLLM/Agent/`
  - `AgentSession.swift`：状态机、消息流、proposal 缓冲
  - `AgentToolRegistry.swift`：tool 定义、dispatcher、读写分派
  - `AgentPromptBuilder.swift`：三层上下文装配 + 能力边界声明
  - `AgentSummarizer.swift`：Layer 2 摘要任务
- 新目录 `Sources/DictKitApp/Persistence/Agent/`
  - `AgentSessionStore.swift`：SQLite CRUD、对账、修剪
- Schema 迁移：`WordListStore.schemaVersion` 1 → 2，新增两表
- 同步白名单：`SyncManifest` / `WordListStore+Sync.swift` 显式排除 agent 表
- 测试：
  - `AgentSessionStoreTests`：CRUD、ordinal、cascade 删除
  - `AgentSessionStoreTests.migrationFromV1`
  - `AgentSessionStoreTests.crashRecovery`
  - `AgentSessionStoreTests.proposalReconciliation`
  - `SyncManifestTests.excludesAgentTables`
  - `AgentContextAssemblyTests`：三层拼装、superseded 跳过、token 预算
  - `AgentPromptBuilderTests`：能力边界声明稳定出现在 system prompt

### 7.3 Phase 3 — Chat UI

当前已落地 MVP：

- `AIContentView` 顶部已有 `Structured` / `Chat` 分段控件
- `Sources/DictKitApp/Views/Agent/AgentChatView.swift` 已提供最小可用的 chat 面板：
  - 消息流
  - tool trace
  - proposal card
  - composer
  - `Clear Chat`
- proposal card 已提供 `Preview` / `Apply` / `Dismiss`
- `CardPreviewView` 已订阅 `AgentSession.previewOverrideArtifacts`，并在 preview override 生效时显示 `Reviewing Agent proposal` 横幅
- `AgentChatSupport.swift` 已把 `WordItem` / `WordListViewModel` / `LLMService` 桥接为 `AgentSession` 所需依赖

尚未达到 spec 里的完整版：

- 还没有按规划拆出 `AgentContextBar`、`AgentMessageList`、`AgentActionCard`、`AgentComposer` 等独立组件
- preview 仍是按钮触发，不是 hover / focus 驱动
- context bar 还没有 snapshot popover
- 还没有 `@front` / `@back` / `@examples[i]` 等快捷引用
- `CardPreviewView` 顶部横幅目前只显示状态，没有 `Apply` / `Dismiss`
- 视图层暂未补快照测试，当前回归仍以 `AgentSession` 级测试为主

### 7.4 Phase 4 — 打磨

- AI 设置里新增 "Agent Chat" 分组：自动读 tool / 历史保留天数 / 历史条数上限 / Clear All Chats
- 导出对话为 markdown
- 启动对账与 purge 的后台执行
- 轻量遥测(本地计数)：proposals_applied / dismissed / edited,`layout_request_declined` 按类型分桶,用于未来调 prompt 与评估 L1/L2 的优先级
- 边缘 case：模型未就绪时的降级提示、`ensureReady` 失败、磁盘满时的 graceful fail

### 7.5 当前实现偏差与后续收口

- `search_dictionary` 这个读 tool 还没接；当前读 tool 只有 `read_card_snapshot`、`list_accepted_artifacts`、`read_recall_card`
- `layout_request_declined` 目前由本地启发式分类短路，不是完全依赖模型语义判断，与 §4.8 的目标实现仍有偏差
- 会话层当前没有使用函数级 `toolChoice=function` 强制某个 tool 出场；如果后续引入强制读 tool 预取，需要先补底层支持
- `AIContentView` 目前在 `!llmService.hasModel` 时直接显示 no-model 面板，导致用户无法在无模型状态下查看既有聊天记录或处理 pending proposal
- `CardPreviewView` 切换 `previewFamily` 时会重建整个 `AgentSession`，会打断进行中的生成并丢失未持久化的瞬时 UI 状态

## 8. 数据类型草稿

以下是一期的 Swift 类型草稿,放在 `Sources/AnkiMateLLM/Agent/` 下。

```swift
struct AgentChatSession: Codable {
    let id: UUID
    let wordItemID: UUID
    let createdAt: Date
    var updatedAt: Date
    var schemaVersion: Int
    var preferences: AgentSessionPreferences
}

struct AgentSessionPreferences: Codable {
    var autoExecuteReadTools: Bool = true
    var maxHistoryMessages: Int = 500
    var maxHistoryAgeDays: Int = 90
}

struct AgentChatMessage: Codable, Identifiable {
    let id: UUID
    let sessionID: UUID
    let ordinal: Int
    let role: Role
    let createdAt: Date
    var status: Status
    var content: MessageContent
    var supersededBy: UUID?

    enum Role: String, Codable { case user, assistant, tool, system }
    enum Status: String, Codable {
        case pending, streaming, completed, canceled, failed
    }
}

enum MessageContent: Codable {
    case text(String)
    case toolCall(name: String, argsJSON: String)
    case toolResult(name: String, resultJSON: String, truncated: Bool)
    case actionProposal(ProposalRecord)
    case summary(String, supersededCount: Int)
    case error(message: String, recoverable: Bool)
    case layoutRequestDeclined(userText: String, detectedKind: DeclinedRequestKind)
}

enum DeclinedRequestKind: String, Codable {
    case layout       // section 顺序、可见性
    case style        // 颜色、字号、间距
    case template     // HTML/CSS、Note Type 结构
    case unknown      // Agent 未能明确分类但判定为非内容类
}

struct ProposalRecord: Codable, Identifiable {
    let id: UUID
    let kind: ProposalKind
    let operation: Operation
    let payloadJSON: String
    let diffSummary: String
    let rationale: String?
    var decision: Decision
    var decidedAt: Date?

    enum ProposalKind: String, Codable {
        case usageCue, example, recallDraft, pitfall, mnemonic, collocation, deleteAccepted
    }

    enum Operation: Codable {
        case add
        case replace(targetID: UUID)
        case delete(targetID: UUID)
    }

    enum Decision: String, Codable {
        case pending, applied, dismissed
    }
}
```

## 9. 测试与验收

### 9.1 契约测试

- Tool schema 稳定性：`AgentToolRegistry` 暴露的 tool 签名不变；一期无任何 `*_layout_*` / `*_style_*` / `*_template_*` tool
- Prompt snapshot：同一输入下系统 prompt 拼装输出稳定(layer 顺序、卡片 snapshot 字段顺序、能力边界声明存在)
- Wireframe 契约：
  - 同一 `WordItem` + `AIArtifacts` 在不同运行中产出字节级相同的 wireframe
  - wireframe 中列出的 section 集合与 structuredJSON.artifacts 键集合一致
  - `AnkiFieldFormatter` 渲染顺序调整时,wireframe 渲染器必须同步改动(契约测试断言两者 section 顺序相同)

### 9.2 存储与迁移测试

- v1 → v2 迁移无损
- 外键 cascade：删 WordItem 后会话与消息消失
- 崩溃恢复：streaming 状态消息重启后一律 canceled
- Purge：超龄或超量数据被清掉,边界不越界

### 9.3 同步隔离测试

- `SyncManifest.build()` 输出不含 `agent_` 前缀
- WebDAV 上传模拟中 agent 表不出现

### 9.4 Proposal 生命周期测试

- pending → applied：`aiArtifacts.suggested` 多出预期 artifact,message decision 更新
- pending → dismissed：suggested 不变,message decision 更新
- 对账：用户在 Structured 手动 save 同内容后,pending 自动变 applied
- 重复提议抑制：Agent 上下文包含最近 applied / dismissed 汇总

### 9.5 能力边界测试

- 构造若干典型布局/样式/模板类请求的 prompt 固件(例如"把 pitfalls 挪到前面"、"字号大一号"、"改成卡片两列布局")
- 断言 Agent 回复中**不含任何 tool call**
- 断言会话中生成了对应 `layout_request_declined` message,且 `detectedKind` 合理
- 允许软断言 Agent 回复语气(包含"不支持"、"暂未开放"之类表达),不做硬匹配

### 9.6 UI 集成测试

- Structured / Chat 切换保留各自状态
- Action Card hover 触发 preview override,离开清除
- Clear Chat 保留 preferences,Reset Session 整行清除
- `layout_request_declined` message 在 UI 中以普通文本气泡渲染,不出现 Action Card

### 9.7 验收标准

一期可发布需满足：

- 无模型 / server 未就绪时 Chat 面板不崩,提示降级信息
- 任何写入 `aiArtifacts` 的路径都来自用户显式 Apply
- 会话数据在本地,WebDAV 同步前后对比 agent 表 0 字节参与
- 上下文装配产出的 prompt 在默认设置下不触发模型 context overflow
- Chat 面板关闭再打开能看到所有历史消息与 pending proposals
- Agent 对布局/样式/模板类请求的拒绝率在内部测试 prompt 集上 ≥ 90%
- 导出到 Anki 的字段内容与现状字节级一致(因为 `AnkiFieldFormatter` 未引入任何布局 state)
