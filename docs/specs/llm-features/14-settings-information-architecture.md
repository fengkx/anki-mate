# LLM Settings 信息架构与配置项

## 1. 文档定位

本文定义 `LLM Settings` / `AI Settings` 的产品信息架构，重点回答：

- 设置页应优先承载什么，不应承载什么
- 哪些配置项应该默认可见
- 每个配置项面向用户的推荐文案如何表达

本文不重新定义 runtime lifecycle，也不展开具体 prompt 设计。

相关约束仍以：

- [01-overview.md](./01-overview.md)
- [13-runtime-readiness-and-autostart.md](./13-runtime-readiness-and-autostart.md)

为准。

## 2. 产品角色

`LLM Settings` 的主要职责不是“展示所有模型技术参数”，而是帮助用户完成三件事：

1. 知道本地 AI 是否已经可用
2. 在可理解的前提下选好一个合适的模型
3. 在需要时找到少量进阶控制，而不打断主路径

从用户视角看，这个页面首先应该回答：

- 现在能不能用
- 当前在用什么
- 如果还没准备好，下一步从哪里开始

而不是一开始就要求用户理解：

- `temperature`
- `top_p`
- `repeat penalty`
- `context window`

这些参数适合少数进阶用户，但不应成为默认可见主层。

## 3. 设计原则

### 3.1 先服务“能用”，再服务“可调”

设置页的第一目标是帮助用户把本地 AI 用起来，而不是先暴露完整调参面板。

### 3.2 优先表达结果，不优先表达算法

对于大多数用户，`Steadier`、`More varied` 比 `temperature = 0.7` 更容易理解。

### 3.3 默认层保持低负担

主层应只保留“用户能直接做判断”的配置项，避免设置页变成术语堆叠区。

### 3.4 设置页保持克制

设置页不是参数实验台。对于一般用户不容易理解、也不需要频繁调整的项，应优先留在内部默认值里，而不是急着做成可见配置。

### 3.5 设置语气以引导为主，不以命令为主

文案应偏：

- 说明现在的状态
- 提示某项设置会带来什么变化
- 让用户自己决定是否需要调整

而不是直接告诉用户“应该怎么做”。

### 3.6 AI Settings 只聚焦本地 AI

`AI Settings` 的首要任务是帮助用户理解和管理本地 AI 本身：

- 当前是否可用
- 当前在用哪个模型
- 生成风格如何设定
- 模型如何下载、选择与清理

因此不应把与本地 AI 没有直接关系的内容混入这个面板，尤其不应加入会分散注意力的同步、备份或跨设备设置入口。

如果 `Sync`、`WebDAV` 或 backup 相关能力需要引导，应放在自己的设置上下文中解决，而不是占用 `AI Settings` 的信息层级。

## 4. 一期推荐信息架构

推荐把设置页拆成三层：

1. `Overview`
   - 当前服务状态
   - 当前模型
   - 一眼可见的可用性判断
2. `Features`
   - 面向结果的 AI 使用偏好
3. `Models`
   - 下载、删除、选择默认模型
   - 推荐模型标记

其中：

- `Overview` 与 `Models` 属于“把 AI 用起来”的基础层
- `Features` 属于“让 AI 更贴近我的使用方式”
- `AI Settings` 不承担 `Sync` / `WebDAV` / backup 的引导职责

## 5. 页面层级建议

### 5.1 第一屏应该看到什么

第一屏建议固定优先展示：

1. `AI availability`
2. `Current model`
3. `Features`

原因：

- 用户打开设置页，通常先想确认能不能用
- 其次想知道当前正在用哪个模型
- 再往下才是“怎么调得更适合自己”

模型大列表可以继续放在下方，但不应把“当前状态”和“使用偏好”挤到太靠后的位置。

### 5.2 模型管理区与功能偏好区分开

`Model management` 解决的是资源与运行问题：

- 下载
- 删除
- 选择
- 当前状态

`Feature preferences` 解决的是使用体验问题：

- 结果更稳还是更灵活

这两类问题不应混在同一个列表行中。

### 5.3 不让无关能力打断主任务

用户进入 `AI Settings`，通常是在处理以下问题之一：

- 想确认本地 AI 是否已经可用
- 想切换或下载模型
- 想微调生成风格

这时如果界面里混入 `Sync`、backup、WebDAV 等非 AI 核心内容，会造成两个问题：

- 视觉焦点被打散
- 用户会误以为这些内容是启用 AI 的前置条件

因此一期界面中不应在 `AI Settings` 面板里强调 `Sync` 相关内容。

## 6. 配置项设计

以下配置项按“一期推荐可见”与“一期不建议开放”拆分。

### 6.1 默认可见配置项

#### 6.1.1 Local AI status

目的：

- 让用户快速判断本地 AI 是否可用

推荐内容：

- server running / stopped
- 当前端口或简单状态说明
- 如未就绪，说明离可用状态还差什么

推荐文案：

- Section title: `Local AI`
- Ready state: `Ready for local AI features.`
- Running state detail: `The local service is available and can be used when AI content is needed.`
- No model state: `A model can be downloaded here whenever you would like to use local AI features.`
- Stopped state: `The service is currently off. It can be started again when needed.`

不建议：

- 把端口号作为最突出信息
- 用过强的告警语气渲染正常的 stopped 状态

#### 6.1.2 Current model

目的：

- 明确“现在默认会用哪个模型”

推荐内容：

- 当前模型名
- 体积
- 是否已下载
- 是否推荐

推荐文案：

- Section title: `Current Model`
- Helper text when selected: `This model is currently selected for local AI features.`
- Empty state: `A model can be selected after it finishes downloading.`
- Recommended badge: `Recommended`
- Selected badge: `Selected`
- Downloaded badge: `Downloaded`

#### 6.1.3 Content style

目的：

- 用“结果导向”的方式替代直接暴露采样参数

定位：

- 这是最值得优先引入的用户偏好项
- 这是一个全局配置
- 用于控制生成结果更稳妥还是更灵活

推荐方案：

- `Balanced`
- `Steadier`
- `More varied`

推荐交互：

- 使用横向拖动选择
- 视觉上更接近一个连续但有限档位的全局调节器
- 用户拖动时，应始终知道自己更偏向稳妥、中间还是更灵活
- 当前选中的档位名称需要常驻可见

推荐交互文案：

- Section title: `Content Style`
- Helper text: `This setting applies across local AI features.`
- Left label: `Steadier`
- Center label: `Balanced`
- Right label: `More varied`

映射建议：

- `Steadier`
  - 偏低 temperature
  - 更适合定义补充、学习要点、较稳定的卡片文案
- `Balanced`
  - 默认档
- `More varied`
  - 偏高 temperature
  - 更适合例句、记忆钩子等更需要变化的场景

推荐说明文案：

- Summary text: `This changes how steady or varied AI-generated content tends to feel.`
- Caption for `Steadier`: `Often a better fit for more consistent wording.`
- Caption for `Balanced`: `A middle ground for most study tasks.`
- Caption for `More varied`: `Can feel more flexible, especially for creative phrasing.`

产品说明：

- 这是“用户能理解的偏好”
- 底层可由不同能力映射到不同参数，而不是要求用户直接学会调 `temperature`

### 6.2 一期不建议开放为普通设置项的配置项

#### 6.2.1 Temperature

产品判断：

- 可以支持
- 但当前阶段不建议做成普通用户设置项

原因：

- 大部分用户不知道它具体影响什么
- 容易被误用，随后把结果波动理解成产品不稳定

处理建议：

- 先由产品内置默认值控制
- 如未来确实需要开放，再单独评估是否值得进入设置页
- 即使未来开放，也更适合用少量预设档位表达，而不是直接让用户输入技术参数

#### 6.2.2 Top-p / Top-k / repeat penalty

产品判断：

- 一期不建议对普通用户开放

原因：

- 与用户目标距离太远
- 价值远小于理解成本
- 容易把设置页推向“半专业调参工具”

建议：

- 先不进入 UI
- 如确有需要，可保留内部常量或 debug-only 配置

#### 6.2.3 Context size

产品判断：

- 不建议进入普通设置页

原因：

- 这是兼容性与性能权衡项
- 更适合设备画像、内部默认值或 debug 设置

若未来必须开放：

- 也应谨慎评估是否真的需要进入设置页
- 需要明确提示会影响显存 / 内存占用与速度

#### 6.2.4 Download source

产品判断：

- 可以继续保留在设置页，但不需要做成强调性的独立层

推荐文案：

- Title: `Download Source`
- Helper text: `This can stay empty unless a mirror is needed for downloads.`

#### 6.2.5 Debug logs

产品判断：

- 可以继续保留在设置页，但应弱化存在感

推荐文案：

- Title: `Debug Logs`
- Helper text: `This adds extra AI logs to the app log for troubleshooting.`

## 7. 配置分层建议

### 7.1 一期真正值得做进 UI 的配置项

优先级建议：

1. `Content Style`
2. `Download Source`
3. `Debug Logs`

这组配置已经足够形成：

- 一个普通用户可理解的主层
- 一个技术负担较低的设置页

### 7.2 一期不建议急着做进 UI 的配置项

- `Response Length`
- `temperature`
- `top_p`
- `top_k`
- `repeat penalty`
- `context size`
- 任意 prompt 级自定义输入框

原因不是这些项完全没价值，而是它们更像“模型实验工具”，不是成熟 Mac App 面向一般用户的首选设置项。

## 8. 推荐页面结构草案

### 8.1 Overview

- `Local AI`
  - 当前状态
  - Start / Stop
- `Current Model`
  - 已选模型
  - 模型说明

### 8.2 Features

- `Content Style`

### 8.3 Models

- Available models list
  - model name
  - size
  - recommended
  - selected / downloaded status
  - download / select / delete

### 8.4 More Options

- `Download Source`
- `Debug Logs`

## 9. 交互细节建议

### 9.1 不要让每个设置项都像“任务指令”

避免：

- `Choose a model and turn on AI features.`
- `Enable this for better results.`

更适合：

- `A local model can be selected here whenever AI features feel useful.`
- `This can stay off unless you would like extra troubleshooting details.`

### 9.2 主层尽量使用“结果描述”

优先：

- `Steadier`
- `More varied`

弱化：

- `temperature`
- `sampling`
- `penalty`

### 9.3 允许用户不调整任何项

成熟产品的设置页应当允许用户：

- 只下载一个推荐模型
- 不理解任何技术参数
- 仍然顺利使用 AI 功能

因此设置页的成功标准不是“功能都能调”，而是“即使不调也能安心使用”。

## 10. 一期结论

一期推荐把 `LLM Settings` 从“模型管理页”升级为“本地 AI 使用与偏好页”，但仍保持克制：

- 主层先解决可用性、当前模型、使用偏好
- 模型大列表继续承担下载与选择职责
- `Content Style` 作为全局配置，优先做成横向拖动选择
- `Response Length` 暂不作为用户设置项开放
- 不单独保留 `Usage` 这类语义较虚的设置分组
- AI 设置页不额外强调 `Sync`，避免偏离本地 AI 的主任务
- 下载源与日志可以保留，但不需要单独强调一个 `Advanced` 层
- 暂不把 `temperature`、`top_p`、`top_k`、`repeat penalty` 做成普通用户设置

这更符合：

- 一般用户的理解成本
- Mac App 常见的渐进式披露习惯
- anki-mate 当前“学习副驾驶”而非“模型实验台”的产品定位

## 11. 线框图草案

以下线框图用于固定一期 `AI Settings` 的界面重心与信息层级。

### 11.1 桌面宽屏

```text
┌──────────────────────────────────────────────────────────────────────┐
│ AI                                                           [Close] │
│ Set up local AI features and downloads.                             │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  ┌──────────────────────────────┐  ┌──────────────────────────────┐  │
│  │ Local AI                     │  │ Current Model                │  │
│  │ Ready for local AI features. │  │ Gemma 4 E2B Instruct        │  │
│  │ The local service is         │  │ Q6_K · 4.5 GB               │  │
│  │ available when needed.       │  │ [Recommended] [Selected]    │  │
│  │                              │  │ This model is currently     │  │
│  │ ● Running                    │  │ selected for local AI       │  │
│  │                        [Stop]│  │ features.                   │  │
│  └──────────────────────────────┘  └──────────────────────────────┘  │
│                                                                      │
│  ┌────────────────────────────────────────────────────────────────┐  │
│  │ Content Style                                                 │  │
│  │ This setting applies across local AI features.                │  │
│  │                                                                │  │
│  │  Steadier ─────── Balanced ─────── More varied                │  │
│  │            ●                                                   │  │
│  │                                                                │  │
│  │ Often a better fit for more consistent wording.               │  │
│  └────────────────────────────────────────────────────────────────┘  │
│                                                                      │
│  ┌────────────────────────────────────────────────────────────────┐  │
│  │ Available Models                                              │  │
│  │ Download and manage local models                              │  │
│  │                                                                │  │
│  │ Model                          Status              Actions     │  │
│  │ ------------------------------------------------------------   │  │
│  │ Gemma 4 E2B Instruct          [Selected]      [Delete]        │  │
│  │ Q6_K · 4.5 GB · Recommended                                  │  │
│  │ ------------------------------------------------------------   │  │
│  │ Qwen3.5 4B                    [Not downloaded] [Download]     │  │
│  │ Q6_K · 3.5 GB · Recommended                                  │  │
│  │ ------------------------------------------------------------   │  │
│  │ Gemma 4 E4B                   [Downloaded]     [Select][Delete]│ │
│  │ Q4_K_M · 5.0 GB                                             │  │
│  └────────────────────────────────────────────────────────────────┘  │
│                                                                      │
│  ┌────────────────────────────────────────────────────────────────┐  │
│  │ More Options                                                  │  │
│  │ Download Source                                               │  │
│  │ [ hf-mirror.com______________________________ ]               │  │
│  │ This can stay empty unless a mirror is needed for downloads.  │  │
│  │                                                                │  │
│  │ [ ] Enable debug logs                                         │  │
│  │ This adds extra AI logs to the app log for troubleshooting.   │  │
│  └────────────────────────────────────────────────────────────────┘  │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘
```

### 11.2 窄窗口

```text
┌──────────────────────────────────────────────┐
│ AI                                   [Close] │
│ Set up local AI features and downloads.      │
├──────────────────────────────────────────────┤
│ ┌──────────────────────────────────────────┐ │
│ │ Local AI                                 │ │
│ │ Ready for local AI features.             │ │
│ │ ● Running                         [Stop] │ │
│ └──────────────────────────────────────────┘ │
│                                              │
│ ┌──────────────────────────────────────────┐ │
│ │ Current Model                            │ │
│ │ Gemma 4 E2B Instruct                     │ │
│ │ Q6_K · 4.5 GB                            │ │
│ │ [Recommended] [Selected]                 │ │
│ └──────────────────────────────────────────┘ │
│                                              │
│ ┌──────────────────────────────────────────┐ │
│ │ Content Style                            │ │
│ │ This setting applies across local AI     │ │
│ │ features.                                │ │
│ │                                          │ │
│ │ Steadier                                 │ │
│ │ ─────────●─────────                      │ │
│ │ More varied                              │ │
│ │ Balanced                                  │ │
│ │ A middle ground for most study tasks.    │ │
│ └──────────────────────────────────────────┘ │
│                                              │
│ ┌──────────────────────────────────────────┐ │
│ │ Available Models                         │ │
│ │ Gemma 4 E2B Instruct                     │ │
│ │ Q6_K · 4.5 GB                            │ │
│ │ [Recommended] [Selected]        [Delete] │ │
│ │ ---------------------------------------- │ │
│ │ Qwen3.5 4B                               │ │
│ │ Q6_K · 3.5 GB                            │ │
│ │ [Not downloaded]              [Download] │ │
│ └──────────────────────────────────────────┘ │
│                                              │
│ ┌──────────────────────────────────────────┐ │
│ │ More Options                             │ │
│ │ Download Source                          │ │
│ │ [______________________________]         │ │
│ │ [ ] Enable debug logs                    │ │
│ └──────────────────────────────────────────┘ │
└──────────────────────────────────────────────┘
```

### 11.3 线框图说明

- 第一屏优先回答：
  - 本地 AI 是否可用
  - 当前模型是什么
  - 生成风格目前偏向哪一侧
- `Content Style` 位于模型大列表之前，因为它是少数真正值得用户主动调整的全局偏好
- `Available Models` 保持高信息密度列表，而不是继续扩张为大卡片区
- `More Options` 明确降级为次级区块，只承载镜像源和调试日志
- 线框图中不放 `Sync`、`WebDAV`、backup 相关入口，避免偏离 `AI Settings` 的主任务

### 11.4 Content Style 控件说明

一期推荐使用“有限档位的横向滑动选择”，而不是连续数值 slider。

建议档位：

- `Steadier`
- `Balanced`
- `More varied`

推荐原因：

- 更容易理解
- 更符合普通用户对“风格偏好”的认知
- 比直接暴露 `temperature` 更稳定
- 便于未来在不同 AI 能力之间做统一映射

实现语义上更接近：

- 三档全局选择器
- 带滑动手势的 segmented control

而不是：

- 自由数值输入框
- 无刻度连续参数调节器
