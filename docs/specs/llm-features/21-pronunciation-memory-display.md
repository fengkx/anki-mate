# 功能岛 2.5：音标增强与重音音节记忆显示

## 1. 前因

当前卡片预览顶部已经有一条很轻的发音信息带：

- 显示词典原始发音
- 当词典只有 respelling 而没有真 IPA 时，可手动触发 `Generate IPA`
- 可直接点按扬声器播放发音

这条信息带已经接近用户的注意力中心，属于“高频扫读、低负担”的区域。

因此本功能不应再新增一个独立 `Pronunciation` section，否则会带来两个问题：

- 对当前图卡来说信息块过重，打断主内容阅读
- 发音信息被拆成两处，用户需要在“顶部音标”和“底部发音辅助”之间来回找

本期方案改为：**把“音节切分 + 重音记忆”有机并入现有音标展示行**，继续保持轻交互。

## 2. 功能目标

在不增加新 section 的前提下，为卡片预览顶部的现有发音展示补上一层更适合记忆的发音辅助信息：

- 真 IPA 词典优先，AI 仅兜底
- 新增 `stress syllables`，例如 `im-POR-tant`
- 交互尽量轻，优先自动补齐，不要求用户显式进入一个新的工作流

目标不是做“发音教学面板”，而是做“更适合背卡的发音整理”。

## 3. 范围

覆盖内容：

- 在现有音标行内联显示 `stress syllables`
- 当词典没有该信息时，若本地 LLM server 正在运行，则自动尝试生成一次
- 提供一个轻量刷新按钮，允许用户手动重试生成
- 将生成结果持久化到 AI artifacts
- 在卡片正反面切换、重开 app、重新加载词条后保持结果

不覆盖内容：

- 新增底部 `Pronunciation` section
- 中文提示文案，如“前轻后收”
- 谐音助记
- 单独的设置面板或复杂配置项
- 在 server 未运行时强行拉起一整套重交互流程

## 4. 产品结论

### 4.1 展示原则

最终展示保留为一个统一的发音信息带，不拆区块：

- 词典 dialect badge
- IPA 或词典发音表示
- `stress syllables`
- 播放按钮
- 轻量刷新按钮（仅在适用时显示）

`stress syllables` 的角色不是补充说明，而是直接成为发音主展示的一部分。

### 4.2 记忆格式

统一使用：

- 音节之间以 `-` 连接
- 主重音音节全大写
- 只标主重音，不处理次重音的独立视觉编码

示例：

- `ba-NA-na`
- `im-POR-tant`
- `com-PU-ter`
- `in-for-MA-tion`
- `PHO-to-graph`

不采用：

- `ba-Na-na`
- `Stress: 2nd syllable`
- 中文节奏提示

原因是这些形式要么视觉强调不够，要么与当前卡片的轻量定位不匹配。

## 5. UI 设计

### 5.1 现有信息带上的融合方式

当前 header 中每个 dialect 发音条目的信息顺序为：

`[Dialect] [IPA / dictionary guide] [Generate IPA?] [Speaker]`

本期改为：

`[Dialect] [IPA / dictionary guide] [stress syllables] [Refresh?] [Speaker]`

其中：

- 当已有词典真 IPA 时，继续直接显示 IPA
- 当只有 respelling 时，优先显示词典 guide；若已有 AI 生成 IPA，则显示生成 IPA
- `stress syllables` 紧跟在发音文本之后，作为同一行内的次级信息
- 刷新按钮维持小图标级别，不出现新的大按钮文案

### 5.2 线框图

有词典 IPA 且已有重音音节：

```text
+--------------------------------------------------------------+
| important                                             [Front]|
|                                                            ...|
| [AmE] /ɪmˈpɔːrtənt/  im-POR-tant   [arrow.clockwise] [🔊]    |
+--------------------------------------------------------------+
```

只有词典 respelling，AI 已补齐 IPA 与重音音节：

```text
+--------------------------------------------------------------+
| collocation                                                  |
| [AmE] /ˌkɑləˈkeɪʃən/  col-lo-CA-tion  [arrow.clockwise] [🔊] |
+--------------------------------------------------------------+
```

只有词典 respelling，自动生成尚未完成：

```text
+--------------------------------------------------------------+
| collocation                                                  |
| [AmE] käləˈkāshən   [spinner] [🔊]                            |
+--------------------------------------------------------------+
```

生成失败但不阻断主阅读：

```text
+--------------------------------------------------------------+
| collocation                                                  |
| [AmE] käləˈkāshən   [arrow.clockwise] [🔊]                    |
| Could not generate pronunciation aid.                        |
+--------------------------------------------------------------+
```

### 5.3 视觉层级

- IPA / 词典发音仍是第一视觉重点
- `stress syllables` 用次级样式展示，但不能弱到看不清
- 刷新按钮使用 borderless icon button 或小号 toolbar-style button
- 不再出现新的 `Generate IPA` 大按钮文案

这里的目标是：用户感受到的是“现有发音行更完整了”，而不是“又多了一个 AI 模块”。

## 6. 交互设计

### 6.1 自动生成策略

当满足以下条件时，进入词条预览后自动尝试一次生成：

- 当前词条已完成 lookup
- 尚无 `stress syllables`
- 本地 LLM server 当前处于 running / ready 状态
- 当前没有进行中的同词条同方言生成任务

自动生成只尝试一次，不做页面内无限重试。

### 6.2 手动刷新

无论是以下哪种情况，都允许用户点击轻量刷新按钮：

- 还没有生成结果
- 已有旧结果但用户想重试
- 自动生成失败后想再次尝试

刷新按钮语义统一为：

- “重新生成当前 dialect 的发音增强信息”

不要再拆成：

- `Generate IPA`
- `Generate stress syllables`

对用户来说，这两个动作属于一件事：补齐可记忆的发音表示。

### 6.3 与 server readiness 的关系

本功能采用比 AI Assistant 更轻的策略：

- 若 server 已在运行，自动触发一次生成
- 若 server 未运行，不主动为了该功能把用户拉进一条重的启动链路
- 用户手动点击刷新时，可以复用现有 AI 请求的 lazy readiness

这样做的原因是：

- 自动补齐应该是“无感增强”，不是“副作用很重的后台动作”
- 但既然用户已经显式点击刷新，就允许走正常 AI 请求路径

### 6.4 错误反馈

错误反馈维持轻量：

- 在音标行下方显示短错误文案
- 不弹 modal
- 不占用底部 AI Assistant 区域
- 不影响播放音频和普通卡片预览

## 7. 数据模型

当前仓库已有：

- `generatedIPANotationsByDialect`

本期建议在 AI artifacts 中新增并行字段：

```json
{
  "generatedStressSyllablesByDialect": {
    "AmE": "im-POR-tant"
  }
}
```

建议结构：

```json
{
  "generatedIPANotationsByDialect": {
    "AmE": "ɪmˈpɔːrtənt"
  },
  "generatedStressSyllablesByDialect": {
    "AmE": "im-POR-tant"
  }
}
```

理由：

- 与现有 `generatedIPANotationsByDialect` 保持同构，最容易接入
- 仍是轻量 artifact，不需要引入新的重 schema
- 后续若词典侧提供可用音节重音信息，也可继续复用这个展示层字段

## 8. 生成职责与来源优先级

### 8.1 来源优先级

`IPA`：

1. 词典真 IPA
2. 已持久化的 AI 生成 IPA
3. 当前词典 respelling

`stress syllables`：

1. 词典可直接推导或未来若有结构化字段则优先使用
2. 已持久化的 AI 生成结果
3. 当前会话内新生成结果

### 8.2 AI 的职责边界

AI 负责两类补齐：

- 当词典没有真 IPA 时，生成真实 IPA
- 生成 `stress syllables`

AI 不负责：

- 输出中文提示
- 输出解释文案
- 输出多条候选
- 输出教学段落

建议输出 contract：

```json
{
  "ipa": "ɪmˈpɔːrtənt",
  "stressSyllables": "im-POR-tant"
}
```

当词典已有真 IPA 时，也可以允许 prompt 只生成：

```json
{
  "stressSyllables": "im-POR-tant"
}
```

## 9. 状态机

单个 dialect 的展示状态可抽象为：

1. `dictionary_only`
   - 显示词典发音
   - 若 server 在运行且缺少 `stress syllables`，自动触发生成

2. `generating`
   - 显示词典发音或已生成 IPA
   - 显示 spinner

3. `enhanced`
   - 显示最终发音文本
   - 显示 `stress syllables`
   - 显示刷新按钮

4. `failed`
   - 保留现有发音显示
   - 显示轻错误
   - 显示刷新按钮

这里最重要的是：**失败时绝不让 UI 退化成“发音区域不可用”**。

## 10. 验收点

- 不新增底部 `Pronunciation` section
- `stress syllables` 直接并入现有音标信息带
- 当 server 已运行且结果缺失时，进入词条后自动尝试一次生成
- 用户可通过轻量刷新按钮重试
- 结果可持久化并在重开后恢复
- 当词典已有真 IPA 时，不再要求用户额外点击 `Generate IPA`
- 生成失败不影响：
  - 普通卡片预览
  - 播放发音
  - 词典阅读

## 11. 实施建议

建议按三个小切片推进：

### 11.1 数据与 contract

- 在 `AIArtifacts` 增加 `generatedStressSyllablesByDialect`
- 在 `WordItem` 增加对应访问器与 preferred/lookup helper
- 定义统一 pronunciation enhancement payload

### 11.2 生成与运行时

- 增加生成 `stress syllables` 的 LLM service 能力
- 在 header 音标行接入“server 运行时自动尝试一次”的触发条件
- 手动刷新复用现有 AI readiness 路径

### 11.3 UI 融合

- 收敛现有 `Generate IPA` 大按钮
- 改成 inline `stress syllables + refresh`
- 保持 speaker 与 dialect badge 的现有交互心智

## 12. 设计结论

本功能的最终产品表达不是“新增一个发音模块”，而是：

**把现有发音行升级成更适合背卡的记忆型发音显示。**

用户看到的变化应尽量像这样：

- 以前：`/ɪmˈpɔːrtənt/`
- 现在：`/ɪmˈpɔːrtənt/  im-POR-tant`

而不是：

- 以前一个音标块
- 现在再多一个新的 AI 发音区块
