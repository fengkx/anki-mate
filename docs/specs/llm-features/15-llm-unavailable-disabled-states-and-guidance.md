# 功能岛 1.5：LLM 不可用时的禁用态与友好提示

## 1. 前因

当前仓库已经具备本地 LLM 基础设施，也已经有多个直接依赖 LLM 的用户入口：

- 单词详情页中的 `AI Assistant`
- `Card Preview` 顶部的发音增强动作
- `Recall Card` 生成动作
- 已经存在的 `Agent Chat`
- `AI Settings`

一期产品已经拍板一个关键原则：

- LLM 是学习层增强，不是词典主流程的前置依赖

这意味着：

- 没有模型时，不能把 app 变成配置向导
- server 未启动时，不能阻断普通查词
- LLM 故障时，不能把已经保存的学习材料一并隐藏掉

当前实现已经具备基础降级能力，但禁用态和提示仍有几个明显问题：

- 一部分入口会给出提示，但提示语义过于泛化
- 一部分入口只静默跳过，用户不知道为什么没有结果
- 一部分入口在没有可用模型时，直接把整个 AI 区域替换成空态，导致“查看已保存 AI 内容”和“生成新 AI 内容”被错误耦合
- 不同入口对“无模型 / server 未就绪 / runtime 缺失 / 启动失败”的处理不一致

因此本专题的目标不是新增 AI 能力，而是为所有已上线 LLM 入口补齐统一的：

- 可用性状态模型
- 禁用规则
- 友好提示
- 恢复路径
- 已保存内容可见性规则

## 2. 功能目标

建立一套统一的 LLM 不可用交互规则，使所有现有入口都遵循相同原则：

1. 核心查词、预览、标准导出始终可用
2. LLM 相关动作在不可用时明确禁用，而不是让用户点了才猜原因
3. 禁用原因必须可理解，不只暴露技术错误
4. 提示必须给出下一步动作
5. 已保存 AI 内容在无 LLM 时仍可查看、编辑、删除
6. 自动触发类功能在不可用时保持克制，不制造噪声

## 3. 范围

覆盖内容：

- `AI Assistant` 整体面板的空态、禁用态、错误态
- `Examples` / `Learning Aids` / `Usage` / `Recall Card` 的生成动作
- `Card Preview` 顶部的发音增强自动生成与手动刷新
- `Agent Chat` 入口的可用性判断、禁用说明和恢复路径
- `AI Settings` 中的状态解释与恢复引导
- `Open AI Settings`、`Try Again`、`Download model` 等恢复动作的统一语义
- 已保存 AI 内容在无 LLM 时的可见性与可编辑性

不覆盖内容：

- 具体 prompt 设计
- 模型下载实现细节
- server supervisor 的内部实现
- 新增更多 AI 功能岛
- collection 级批量 AI 流程

## 4. 设计原则

### 4.1 查看已保存内容与生成新内容分离

“有没有可用 LLM”只应影响：

- 新生成
- 重生成
- 自动生成
- Agent 会话继续推理

不应影响：

- 查看已经保存的 AI 结果
- 编辑已经保存的 AI 文本
- 删除已经保存的 AI 内容
- 基于已保存 AI 内容进行卡片预览和导出

### 4.2 先解释状态，再解释技术原因

对普通用户，优先表达：

- 现在能不能用
- 为什么现在不能用
- 下一步该做什么

而不是优先表达：

- RPC 出错
- 端口未监听
- binary missing

技术原因只在设置页或 diagnostics 上下文中展开。

### 4.3 禁用优于失败后补救

若系统在用户点击前已经知道某动作不能完成，应优先：

- 直接禁用按钮
- 给 hover / helper / caption 解释

而不是默认允许点击，再用一个笼统 alert 收尾。

### 4.4 自动触发保持安静，手动触发提供明确反馈

自动触发类动作在不可用时应：

- 默认静默跳过
- 不弹 modal
- 不污染主流程

手动触发类动作在不可用时应：

- 明确说明原因
- 提供恢复动作
- 尽量就地解释，不强迫用户猜测

### 4.5 同类状态在不同入口保持一致语义

“没有模型”不应在一个地方叫：

- `AI is not available`

而在另一个地方只表现为：

- 无文案

统一之后，每个入口可以有不同轻重，但状态含义和用户动作应该一致。

## 5. 统一状态模型

本专题定义以下用户可见状态。

### 5.1 `No Model Configured`

含义：

- 当前没有已下载且可选中的模型

用户应理解为：

- 本地 AI 还没有配置好

推荐动作：

- 去 `AI Settings` 下载并选择模型

### 5.2 `Model Available, Service Idle`

含义：

- 已有可用模型
- server 当前未运行，但可按需 lazy start

用户应理解为：

- AI 还没在后台启动，但点生成时可以自动准备

推荐动作：

- 手动触发时直接允许点击，不需要预先拦住

### 5.3 `Preparing Local AI`

含义：

- 正在启动 server 或加载模型

用户应理解为：

- 本地 AI 正在准备，稍等即可

推荐动作：

- 显示 loading
- 避免重复点击

### 5.4 `Runtime Missing`

含义：

- app bundle 或本地开发环境缺少 AI runtime

用户应理解为：

- 不是“暂时没启动”，而是当前副本本身不完整

推荐动作：

- 重装 / 更新 app
- 本地开发环境重新 build

### 5.5 `Service Failed To Start`

含义：

- server 本应可用，但当前启动失败

用户应理解为：

- 现在这次启动没成功，需要重试

推荐动作：

- `Try Again`
- 若持续失败，引导到设置页 / 重启 app

### 5.6 `AI Temporarily Unavailable`

含义：

- 模型和 runtime 理论上都在，但本次请求失败

用户应理解为：

- 这是临时不可用，不等于数据丢失

推荐动作：

- 重试当前动作
- 必要时打开 `AI Settings`

## 6. 全局禁用与提示规则

### 6.1 当 `No Model Configured`

- 所有“生成 / 重生成 / 开始聊天 / 刷新 AI 发音增强”动作都应禁用
- 禁用态需要有明确理由
- 不应隐藏已保存 AI 内容
- 不应阻断普通词典阅读、标准预览、标准导出

统一文案基调建议：

- 状态说明：`Local AI is not set up yet.`
- 下一步：`Download and select a model in AI Settings.`

### 6.2 当 `Model Available, Service Idle`

- 手动生成动作不禁用
- 首次点击时允许进入 lazy readiness
- 不需要预先弹“请先启动 server”
- 自动生成动作可根据场景选择：
  - 重交互入口：允许 lazy readiness
  - 轻量无感增强：可静默跳过

### 6.3 当 `Preparing Local AI`

- 当前动作进入 loading
- 相同动作禁用，避免重复请求
- 若是面板级动作，不强制把整个页面置灰

### 6.4 当 `Runtime Missing`

- 所有依赖 LLM 的动作禁用
- 应给出比“不可用”更具体的解释
- 优先提供修复方向，而不是只提供重试

### 6.5 当 `Service Failed To Start`

- 当前动作失败后给出就地说明或 alert
- 应允许用户：
  - 重试当前动作
  - 打开 `AI Settings`

### 6.6 当 `AI Temporarily Unavailable`

- 保留用户当前上下文
- 不清空已保存内容
- 不把错误上升成全局不可用状态，除非系统已确认进入 `failed`

## 7. 分入口规格

### 7.1 `AI Assistant`

#### 7.1.1 产品要求

`AI Assistant` 需要拆分两类能力：

- `view existing AI content`
- `generate new AI content`

在 `No Model Configured` 下：

- 面板仍然显示
- 已保存的 `Examples` / `Learning Aids` / `Usage` / `Recall Card` 仍然展示
- 对应 section 的生成按钮禁用
- 面板顶部或相关 section 顶部给出统一说明

推荐表现：

- 面板顶部 inline banner：
  - `Local AI is not set up yet.`
  - `Download and select a model in AI Settings to generate or regenerate AI content.`
  - CTA: `Open AI Settings`
- 各 section 的主动作按钮禁用，并带帮助文案：
  - `Set up local AI in AI Settings to generate examples.`
  - `Set up local AI in AI Settings to generate learning aids.`
  - `Set up local AI in AI Settings to generate a usage cue.`
  - `Set up local AI in AI Settings to draft a recall card.`

在 `Service Failed To Start` / `Runtime Missing` 下：

- 面板仍可查看已保存内容
- 生成动作禁用或失败后提示
- 顶部 banner 语义改为恢复型：
  - `Local AI needs attention before it can generate new content.`
  - CTA: `Open AI Settings`

#### 7.1.2 当前实现现状

当前 `AIContentView` 在 `!llmService.hasModel` 时直接显示一条 no-model 空态，而不是继续展示结构化内容：

- [AIContentView.swift](/Users/fengkx/me/code/anki-mate/Sources/DictKitApp/Views/AIContentView.swift:409)
- [AIContentView.swift](/Users/fengkx/me/code/anki-mate/Sources/DictKitApp/Views/AIContentView.swift:567)

这会导致：

- 无模型时无法查看已保存 AI 内容
- 无模型时也无法删除或编辑已保存 AI 内容

当前 alert 文案也是全局泛化的：

- [LLMGenerationAvailability.swift](/Users/fengkx/me/code/anki-mate/Sources/DictKitApp/Support/LLMGenerationAvailability.swift:3)

#### 7.1.3 建议实现落点

- `Sources/DictKitApp/Views/AIContentView.swift`
  - 把“是否可生成”与“是否展示结构化面板”拆开
  - 新增面板级 unavailable banner
  - 各 section action 按状态禁用
- `Sources/DictKitApp/Support/LLMGenerationAvailability.swift`
  - 从布尔判断升级为更细的 availability reason / user-facing state
- `Sources/DictKitApp/Support/LLMServerStatusGuidance.swift`
  - 复用或抽取用户文案，避免设置页和详情页分叉

### 7.2 `Examples / Learning Aids / Usage / Recall Card` 的手动生成动作

#### 7.2.1 产品要求

当 `No Model Configured`：

- 按钮应禁用，而不是先允许点击
- hover / help 明确说明原因
- 若用户通过键盘触发或其他方式仍进入动作路径，再展示带 CTA 的 alert 作为兜底

当 `Model Available, Service Idle`：

- 按钮保持可用
- 点击后进入 loading
- 不提前要求用户去设置页启动

当 `Service Failed To Start` / `Runtime Missing`：

- 可以禁用并给出原因
- 或允许点击一次后给出更具体错误
- 但不同 section 的用户语义必须一致

#### 7.2.2 当前实现现状

当前手动生成前会先调用：

- `prepareManualGeneration()`

其逻辑是：

- 无模型 -> 直接弹 alert
- server failed -> 直接弹 alert
- server stopped -> 允许继续，走 lazy readiness

对应位置：

- [AIContentView.swift](/Users/fengkx/me/code/anki-mate/Sources/DictKitApp/Views/AIContentView.swift:1100)

这满足了基本功能，但还没有做到：

- 按钮级禁用说明
- 区分不同 unavailable reason 的用户文案

#### 7.2.3 建议实现落点

- `Sources/DictKitApp/Views/AIContentView.swift`
  - 顶层 section action model 增加 `disabledReason`
- `Sources/DictKitApp/Support/LLMGenerationAvailability.swift`
  - 增加针对 action/button 的 explanation API

### 7.3 `Card Preview` 顶部发音增强

#### 7.3.1 产品要求

发音增强是“轻量辅助”，比 `AI Assistant` 更克制。

自动触发时：

- 当 `No Model Configured`：静默跳过
- 当 `Model Available, Service Idle`：不要求必须自动拉起重准备链路，允许静默跳过
- 当 `Service Failed To Start`：静默跳过

手动刷新时：

- 当 `No Model Configured`：按钮禁用，并给 help：
  - `Set up local AI in AI Settings to generate pronunciation aids.`
- 当 `Model Available, Service Idle`：允许点击，走 lazy readiness
- 当 `Runtime Missing` / `Service Failed To Start`：给更具体的恢复说明

已生成的 IPA / stress syllables 在无 LLM 时仍需继续展示。

#### 7.3.2 当前实现现状

当前自动发音增强在不可用时会静默返回：

- [CardPreviewView.swift](/Users/fengkx/me/code/anki-mate/Sources/DictKitApp/Views/CardPreviewView.swift:678)

当前手动刷新走和其他入口相同的 alert 兜底：

- [CardPreviewView.swift](/Users/fengkx/me/code/anki-mate/Sources/DictKitApp/Views/CardPreviewView.swift:852)

这符合“自动安静、手动可恢复”的大方向，但还缺：

- 刷新按钮的显式禁用说明
- 区分无模型和启动失败的不同文案

#### 7.3.3 建议实现落点

- `Sources/DictKitApp/Views/CardPreviewView.swift`
  - 发音刷新按钮增加 disabledReason / help
  - 手动失败时优先展示就地错误，再决定是否 alert
- `Sources/DictKitApp/Support/LLMGenerationAvailability.swift`
  - 为 pronunciation enhancement 提供专用文案

### 7.4 `Agent Chat`

#### 7.4.1 产品要求

`Agent Chat` 已经是现有入口，因此必须纳入同一套可用性规范。

当 `No Model Configured`：

- `Chat` tab 仍可见
- 进入后显示 disabled state，而不是只有空白或误导性 unavailable
- 应明确说明这是“本地 AI 未配置”，不是“当前词条不支持聊天”
- CTA: `Open AI Settings`

当 `Model Available, Service Idle`：

- 允许开始聊天
- 通过第一次请求走 lazy readiness

当 `Runtime Missing` / `Service Failed To Start`：

- 显示恢复导向状态
- 不吞掉具体问题

如果当前词条因业务条件不能聊天，例如：

- 词典 lookup 未完成
- 本地存储不可用

则该状态应和“LLM 不可用”明确区分，不能混在一起。

#### 7.4.2 当前实现现状

当前 `AIContentView` 对 `panelMode == .chat` 的分支只有两类：

- 有 `activeAgentSession` -> 显示 `AgentChatView`
- 否则显示：
  - `Chat is unavailable for the current word.`
  - `Finish the dictionary lookup and keep local storage enabled to use Agent Chat.`

对应位置：

- [AIContentView.swift](/Users/fengkx/me/code/anki-mate/Sources/DictKitApp/Views/AIContentView.swift:411)

但在外层如果 `!llmService.hasModel`，当前会先显示 no-model 空态，`Chat` 分支根本进不去：

- [AIContentView.swift](/Users/fengkx/me/code/anki-mate/Sources/DictKitApp/Views/AIContentView.swift:409)

这说明当前 `Agent Chat` 的“业务不可用”和“LLM 不可用”还没有独立建模。

#### 7.4.3 建议实现落点

- `Sources/DictKitApp/Views/AIContentView.swift`
  - 把 `panelMode == .chat` 的状态拆成：
    - chat business unavailable
    - llm unavailable
    - chat ready
- `Sources/AnkiMateLLM/Agent/AgentSession.swift`
  - 如有需要，补充更明确的 readiness failure surface

### 7.5 `AI Settings`

#### 7.5.1 产品要求

`AI Settings` 是显式控制面板，因此这里的提示可以更完整。

需要明确回答：

1. 现在能不能用
2. 差的是什么
3. 下一步怎么恢复

在 `No Model Configured`：

- 重点是“去下载模型”

在 `Model Available, Service Idle`：

- 重点是“服务当前关闭，但可按需启动”

在 `Runtime Missing`：

- 重点是“当前 app 副本缺组件”

在 `Service Failed To Start`：

- 重点是“当前启动失败，可重试”

#### 7.5.2 当前实现现状

这部分已经是当前实现里最接近目标的区域：

- `Local AI`
- `Current Model`
- `Content Style`

对应位置：

- [LLMSettingsView.swift](/Users/fengkx/me/code/anki-mate/Sources/DictKitApp/Views/LLMSettingsView.swift:100)
- [LLMServerStatusGuidance.swift](/Users/fengkx/me/code/anki-mate/Sources/DictKitApp/Support/LLMServerStatusGuidance.swift:9)

当前仍有一个缺口：

- `No Model Configured` 的说明更多存在于页面结构和模型列表里，但还缺一个更统一的“为什么 AI 入口现在不能生成”的主叙述

#### 7.5.3 建议实现落点

- `Sources/DictKitApp/Views/LLMSettingsView.swift`
  - 在 `Overview` 中强化 no-model 主说明
- `Sources/DictKitApp/Support/LLMServerStatusGuidance.swift`
  - 增补 no-model guidance，避免只有 server state，没有 model availability state

## 8. 文案规范

### 8.1 文案目标

所有文案应同时满足：

- 解释当前状态
- 不夸大故障
- 给出下一步动作
- 避免把用户拖进技术细节

### 8.2 推荐文案库

#### `No Model Configured`

- Title: `Local AI is not set up yet`
- Body: `Download and select a model in AI Settings to generate AI content.`
- CTA: `Open AI Settings`

#### `Model Available, Service Idle`

- Inline helper: `Local AI will start automatically when needed.`

#### `Preparing Local AI`

- Inline helper: `Preparing local AI…`

#### `Runtime Missing`

- Title: `Local AI runtime is missing`
- Body: `This copy of the app is missing the local AI runtime. Reinstall or update the app. If you built from source, run \`just build\` and launch the app again.`
- CTA: `Open AI Settings`

#### `Service Failed To Start`

- Title: `Local AI could not start`
- Body: `Try again. If it keeps failing, restart the app.`
- CTA primary: `Try Again`
- CTA secondary: `Open AI Settings`

#### `AI Temporarily Unavailable`

- Title: `Local AI is temporarily unavailable`
- Body: `Try again in a moment, or open AI Settings if the problem keeps happening.`
- CTA: `Open AI Settings`

### 8.3 文案禁忌

避免直接面向普通用户暴露：

- `RPC`
- `port`
- `binary not found`
- `server not running`

除非在 diagnostics 或开发者上下文中。

## 9. 当前实现差距总结

### 9.1 已满足的部分

- 无模型时 app 启动保持静默，不阻断主流程
- 手动生成支持 lazy readiness
- server failed 时已有基础 alert / status guidance
- 设置页已有较完整的 server guidance

### 9.2 需要补齐的部分

- `AI Assistant` 在无模型时不应完全替换成空态
- 已保存 AI 内容需要在无 LLM 时继续可见
- 生成按钮需要在禁用态前置解释，而不是只靠点击后 alert
- `Agent Chat` 需要把业务不可用与 LLM 不可用分离
- `AI Settings` 需要把 model availability 与 server state 合并成完整可用性叙事
- 全局 alert 文案需要从单一布尔状态升级为细分 reason

## 10. 建议代码落点

建议改动优先级如下。

### 10.1 第一优先级：统一 availability reason

- `Sources/DictKitApp/Support/LLMGenerationAvailability.swift`
- `Sources/DictKitApp/Support/LLMServerStatusGuidance.swift`

职责：

- 建立统一的用户可见 unavailable reason
- 为不同入口提供一致文案

### 10.2 第二优先级：解耦 `AI Assistant` 的展示与生成

- `Sources/DictKitApp/Views/AIContentView.swift`

职责：

- 永远允许查看已保存 AI 内容
- 仅对生成动作做禁用
- 区分 structured panel unavailable 与 chat unavailable

### 10.3 第三优先级：补齐轻入口禁用态

- `Sources/DictKitApp/Views/CardPreviewView.swift`

职责：

- 发音增强刷新按钮的禁用说明
- 手动触发失败时更友好的就地反馈

### 10.4 第四优先级：设置页整合 model + server guidance

- `Sources/DictKitApp/Views/LLMSettingsView.swift`

职责：

- 在 overview 层把“没有模型”和“server 状态”统一讲清楚

## 11. 验收点

- 当没有已下载模型时，普通查词、标准预览、标准导出不受影响
- 当没有已下载模型时，`AI Assistant` 仍能显示已保存 AI 内容
- 当没有已下载模型时，所有生成类动作禁用并提供明确原因
- 当有可用模型但 server 停止时，手动生成动作可直接触发 lazy readiness
- 当 runtime 缺失时，用户看到的是可理解的修复指引，而不是笼统“不可用”
- 当 server 启动失败时，用户可以明确重试或进入 `AI Settings`
- `Agent Chat` 能区分“词条当前不能聊天”和“LLM 当前不可用”
- 自动发音增强在不可用时保持静默，不打断主流程
- 手动发音增强在不可用时有明确提示
- 不同入口对 `No Model Configured` 的用户语义一致

## 12. 非目标

本文不要求：

- 把所有错误都改成 modal
- 在无模型时自动弹出 `AI Settings`
- 为每个 AI 功能分别维护一套独立 unavailable 文案系统
- 在本期引入新的 debug 面板

## 13. 与其他专题的关系

- 与 [13-runtime-readiness-and-autostart.md](./13-runtime-readiness-and-autostart.md) 的关系：
  - 本文继承其 runtime lifecycle 结论
  - 本文补充“用户看到什么”和“入口如何禁用”
- 与 [14-settings-information-architecture.md](./14-settings-information-architecture.md) 的关系：
  - 本文不重写设置页 IA
  - 本文补充“无 LLM 时的解释与恢复路径”
- 与 [10-ai-suggestion-layer.md](./10-ai-suggestion-layer.md) 的关系：
  - 本文补充 AI 工作区在 unavailable 时的统一降级规则

