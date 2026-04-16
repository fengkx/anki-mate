# DictKitApp 集成 Spec

## 1. 文档定位

本文档记录 DictKitApp（macOS SwiftUI 桌面应用）在集成系统词典查询和语音合成过程中的关键设计决策、踩坑记录和架构说明。

目标场景：用户在 GUI 中输入单词列表，应用逐个查询 macOS 系统词典并展示释义卡片，支持发音播放和批量导出 Anki `.apkg` 文件。

---

## 2. 核心决策

### 2.1 DictPrivate Header 内存管理：`DCSDictionaryGetName` 的 CF 命名约定

**问题**

`DictPrivate.h` 声明的 `DCSDictionaryGetName` 最初被标注了 `NS_RETURNS_RETAINED`。根据 Core Foundation 命名约定：

- **"Get" rule**：函数名含 `Get` 表示返回 **borrowed reference**，调用方**不拥有**对象。
- **"Copy"/"Create" rule**：函数名含 `Copy` 或 `Create` 表示返回 **owned reference**，调用方**必须释放**。

错误地将 `NS_RETURNS_RETAINED` 加在 `Get` 函数上，等于告诉 ARC「你拥有这个对象」。ARC 在作用域结束时会插入一次 `release`，但实际上这是 borrowed reference——底层并没有对应的 `retain`。结果就是 over-release，导致 dangling pointer。

**现象**

`SystemDictionaryClient.lookupHTMLRecord()` 中调用 `DCSDictionaryGetName(pointer)` 将返回值桥接为 Swift `String` 时，偶现 EXC_BAD_ACCESS 崩溃。崩溃栈指向 `objc_release`，典型的 over-release 症状。

**决策**

移除 `DCSDictionaryGetName` 上的 `NS_RETURNS_RETAINED`，使其符合 CF "Get" 命名约定——返回 borrowed reference，ARC 不会插入额外 `release`。

```c
// ✅ 正确：Get = borrowed reference，无需 NS_RETURNS_RETAINED
extern NSString* _Nullable DCSDictionaryGetName(DCSDictRef dict);

// 对比：Copy = owned reference，需要 NS_RETURNS_RETAINED
extern id DCSCopyAvailableDictionaries(void) NS_RETURNS_RETAINED;
extern NSString* DCSRecordCopyData(id record) NS_RETURNS_RETAINED;
```

同理，`DCSRecordGetString` 也遵循 Get 规则，不加 `NS_RETURNS_RETAINED`。

> **经验法则**：给私有 API 写头文件时，严格按 CF 命名约定决定内存语义。名字里有 `Get` 就是 borrowed，有 `Copy`/`Create` 就是 owned。标错方向比不标更危险。

### 2.2 CoreServices 线程安全与序列化查询队列

**问题**

CoreServices 的私有字典 API（`DCSCopyAvailableDictionaries`、`DCSCopyRecordsForSearchString`、`DCSDictionaryGetName`）**不是线程安全的，也不可重入**。

在 SwiftUI 的 `@MainActor` 上下文中，用户快速输入多个单词时会触发多个 `Task {}`。Swift 并发的 `Task {}` 在 `@MainActor` 上通过挂起点交替执行——如果两个 lookup task 都在调用 CoreServices API 时交替运行，就会触发 reentrancy 问题，导致崩溃或数据损坏。

**决策**

实现一个序列化查询队列（serialized lookup queue），确保同一时刻只有一个 lookup 在进行：

```swift
// WordListViewModel.swift
private var lookupQueue: [WordItem] = []
private var isLookupRunning = false

private func enqueueLookup(_ item: WordItem) {
    item.lookupState = .loading
    lookupQueue.append(item)
    processNextLookup()
}

private func processNextLookup() {
    guard !isLookupRunning, let item = lookupQueue.first else { return }
    lookupQueue.removeFirst()
    isLookupRunning = true

    Task {
        do {
            let result = try dictionaryClient.lookup(item.word, source: .automatic)
            item.lookupState = .loaded(result)
        } catch {
            item.lookupState = .failed(error.localizedDescription)
        }
        isLookupRunning = false
        processNextLookup()  // 处理队列中下一个
    }
}
```

关键点：
- `isLookupRunning` 在 `@MainActor` 上同步检查和设置，不需要锁。
- `processNextLookup()` 在每次 lookup 完成后递归调用自身，形成 FIFO 队列。
- 用户感知上所有单词都在 `.loading` 状态，但底层严格串行。

### 2.3 异步语音合成：用 Continuation 替代 RunLoop 自旋

**问题**

`AVSpeechSynthesizer` 的 `speak()` 和 `write()` 都是异步回调式 API，通过 `AVSpeechSynthesizerDelegate` 通知完成。CLI 场景下使用 `RunLoop.current.run(mode:before:)` 自旋等待回调，但在 SwiftUI 应用中，自旋 RunLoop 会阻塞 `@MainActor`，导致 UI 冻结。

**决策**

使用 `withCheckedThrowingContinuation` 将回调式 API 桥接为 Swift async/await，实现非阻塞等待：

```swift
// AVSpeechSynthesizerEngine — private actor
func speak(_ request: ResolvedSpeechRequest) async throws {
    try await withCheckedThrowingContinuation { continuation in
        Task { @MainActor in
            let synthesizer = AVSpeechSynthesizer()
            let delegate = AsyncSpeechDelegate()
            delegate.onFinish = { continuation.resume() }
            delegate.onCancel = {
                continuation.resume(throwing: SpeechError.synthesisUnavailable)
            }
            synthesizer.delegate = delegate
            synthesizer.speak(Self.makeUtterance(from: request))
            delegate.retainedSynthesizer = synthesizer
            delegate.retainedSelf = delegate
        }
    }
}
```

`Task { @MainActor in ... }` 确保 `AVSpeechSynthesizer` 在主线程创建和操作（AppKit/AVFoundation 要求）。外层 `withCheckedThrowingContinuation` 挂起调用者，直到 delegate 回调 `resume`。

### 2.4 Delegate 生命周期：`retainedSelf` 模式

**问题**

`AVSpeechSynthesizer.delegate` 属性是 `weak`。如果 delegate 对象在 continuation 闭包中创建为局部变量，一旦出了作用域就会被 ARC 释放，synthesizer 的 delegate 变成 `nil`，回调永远不会触发，continuation 永远不会 resume——造成 hang。

**决策**

让 delegate 自持引用（self-retain），并在回调触发后清除：

```swift
private final class AsyncSpeechDelegate: NSObject, AVSpeechSynthesizerDelegate {
    var onFinish: (() -> Void)?
    var onCancel: (() -> Void)?
    var retainedSynthesizer: AVSpeechSynthesizer?  // 防止 synthesizer 被回收
    var retainedSelf: AsyncSpeechDelegate?          // 防止 delegate 被回收

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                           didFinish utterance: AVSpeechUtterance) {
        retainedSynthesizer = nil  // 打破循环引用
        onFinish?()
        retainedSelf = nil         // 释放自持引用
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                           didCancel utterance: AVSpeechUtterance) {
        retainedSynthesizer = nil
        onCancel?()
        retainedSelf = nil
    }
}
```

生命周期链：`delegate.retainedSelf → delegate → retainedSynthesizer → synthesizer`。回调触发后，先清 `retainedSynthesizer` 再清 `retainedSelf`，两个对象都会在回调结束后被 ARC 正常回收。

> **注意**：`retainedSelf` 创建了一个有意的 retain cycle，这是 `weak delegate` 场景下的标准解法。关键是必须在回调中清除，否则永远泄漏。

### 2.5 音频合成：空 Buffer 信号与 `didResume` 防护

**问题**

`AVSpeechSynthesizer.write()` API 通过回调分批返回 `AVAudioPCMBuffer`。文档没有明确说明何时所有音频数据已发送完毕。实际行为：最后一个回调会传入 `frameLength == 0` 的空 buffer 作为结束信号。

同时，`write()` 的 completion 顺序不确定——空 buffer 回调和 `didFinish` delegate 回调可能以任意顺序到达，如果两个都触发 `continuation.resume()`，就会 double-resume，导致 crash。

**决策**

1. 以 `frameLength == 0` 作为音频数据结束信号，收到时立即编码并 resume。
2. 用 `didResume` 布尔标志防止 double-resume：

```swift
func synthesize(_ request: ResolvedSpeechRequest) async throws -> SynthesizedSpeechPayload {
    try await withCheckedThrowingContinuation { continuation in
        Task { @MainActor in
            var buffers: [AVAudioPCMBuffer] = []
            var didResume = false

            let finish = {
                guard !didResume else { return }
                didResume = true
                let audioData = try SpeechAudioEncoder.encodeWave(from: buffers)
                continuation.resume(returning: SynthesizedSpeechPayload(...))
            }

            delegate.onFinish = finish
            delegate.onCancel = {
                guard !didResume else { return }
                didResume = true
                continuation.resume(throwing: SpeechError.synthesisUnavailable)
            }

            synthesizer.write(utterance) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength > 0 {
                    buffers.append(Self.copyBuffer(pcm))
                } else {
                    finish()  // 空 buffer = 音频结束
                }
            }
        }
    }
}
```

`copyBuffer` 对每个 PCM buffer 做深拷贝——`write()` 回调中的 buffer 可能在回调返回后被复用或释放，必须拷贝后才能安全持有。

### 2.6 延迟音频合成（Deferred Audio Synthesis）

**问题**

最初的设计在 lookup 阶段就同时合成音频。但 `AVSpeechSynthesizer` 操作相对耗时，且并非每个单词都需要音频（用户可能只是浏览释义）。在 lookup 阶段就合成音频会：
1. 拖慢 lookup 队列的吞吐。
2. 浪费 CPU 和内存。

**决策**

将音频合成推迟到实际需要时（播放或导出），lookup 阶段只查询词典释义：

- **播放**：`playPronunciation(for:)` 在用户点击发音按钮时按需调用 `speechClient.speak()`。
- **导出**：`exportToAnki()` 在导出时批量合成还没有音频的单词。

```swift
// makeSpeechRequest 从已有的 lookupResult 构建请求
// 避免 DictionarySpeechClient 内部再次调用线程不安全的 CoreServices API
private func makeSpeechRequest(for item: WordItem) -> SpeechRequest? {
    guard let result = item.lookupResult else { return nil }
    let pronunciation = result.entries.first.flatMap { entry in
        entry.pronunciations.first ?? entry.lexicalEntries.first?.pronunciations.first
    }
    return SpeechRequest(text: item.word, pronunciation: pronunciation, sourceLabel: "dictionary")
}
```

这里有一个关键细节：`makeSpeechRequest` 从 ViewModel 已缓存的 `LookupResult` 中提取发音信息，**而不是让 `DictionarySpeechClient` 自己去做字典查询**。这避免了从 async 上下文中调用线程不安全的 CoreServices API。

### 2.7 构建系统：`--product` vs `--target` 与 `just run-app`

**问题**

SPM 的 `swift build --target DictKitApp` 只编译 target 但**不链接**为可执行文件。要得到可运行的二进制，必须用 `swift build --product DictKitApp`。

此外，macOS 的 SwiftUI 应用需要 `.app` bundle 结构才能正确获得 Dock 图标、窗口焦点等系统行为。直接运行 `.build/debug/DictKitApp` 二进制虽然能跑，但行为异常。

**决策**

1. `Package.swift` 中将 `DictKitApp` 同时声明为 `.executableTarget`（编译目标）和 `.executable` product（可链接产物）：

```swift
products: [
    .executable(name: "DictKitApp", targets: ["DictKitApp"])
],
targets: [
    .executableTarget(
        name: "DictKitApp",
        dependencies: ["DictKit", "DictKitSystemDictionary", "DictKitAnkiExport"]
    )
]
```

2. `justfile` 中 `run-app` recipe 完成完整的构建-打包-启动流程：

```bash
run-app:
    pkill -9 -f 'DictKitApp\.app' 2>/dev/null || true   # 杀掉旧实例
    swift build --product DictKitApp                      # 用 --product 链接
    mkdir -p .build/DictKitApp.app/Contents/MacOS
    cp .build/debug/DictKitApp .build/DictKitApp.app/Contents/MacOS/
    # 写入 Info.plist（CFBundleIdentifier, NSHighResolutionCapable 等）
    open -n .build/DictKitApp.app                         # -n 强制启动新实例
```

`open -n` 的 `-n` flag 强制 macOS 启动一个新的应用实例，而不是激活已有的。这对开发调试很重要——否则 macOS 可能会复用一个旧的缓存进程。

---

## 3. 架构与数据流

```
┌────────────────────────────────────────────────────────────┐
│                     DictKitApp (SwiftUI)                   │
│                                                            │
│  ┌──────────────┐    ┌──────────────────────────────────┐  │
│  │ ContentView  │───▶│    WordListViewModel (@MainActor)│  │
│  │ CardPreview  │    │                                  │  │
│  │ BatchInput   │    │  words: [WordItem]               │  │
│  └──────────────┘    │  lookupQueue / isLookupRunning   │  │
│                      │                                  │  │
│                      │  addWord() ──▶ enqueueLookup()   │  │
│                      │                  │               │  │
│                      │            processNextLookup()   │  │
│                      │                  │               │  │
│                      └──────────────────┼───────────────┘  │
│                                         │                  │
│                    ┌────────────────────┼──────────┐       │
│                    │        Lookup      │  Speech  │       │
│                    ▼                    ▼          │       │
│  ┌─────────────────────┐  ┌────────────────────┐  │       │
│  │SystemDictionaryClient│  │DictionarySpeechClient│ │       │
│  │                     │  │                    │  │       │
│  │ lookup() ───────────┤  │ speak() ───────┐   │  │       │
│  │  └▶ lookupHTMLRecord│  │ synthesize() ──┤   │  │       │
│  │     └▶ CoreServices │  │                ▼   │  │       │
│  │        Private APIs  │  │ AVSpeechSynth- │   │  │       │
│  └─────────────────────┘  │ esizerEngine   │   │  │       │
│                           │ (private actor) │   │  │       │
│                           │   └▶ continuation  │  │       │
│                           │   └▶ AsyncSpeech-  │  │       │
│                           │      Delegate      │  │       │
│                           └────────────────────┘  │       │
│                    ┌──────────────────────────────┘       │
│                    ▼                                      │
│  ┌─────────────────────┐                                  │
│  │  AnkiExporter       │  exportToAnki()                  │
│  │  └▶ batch synthesize│  └▶ synthesize missing audio     │
│  │  └▶ write .apkg     │  └▶ pack cards + audio → .apkg  │
│  └─────────────────────┘                                  │
└────────────────────────────────────────────────────────────┘

数据流：
  用户输入 ──▶ addWord()
          ──▶ enqueueLookup() ──▶ [序列化队列]
          ──▶ SystemDictionaryClient.lookup() (CoreServices)
          ──▶ WordItem.lookupState = .loaded(LookupResult)

  用户点击发音 ──▶ makeSpeechRequest(from: cached LookupResult)
              ──▶ DictionarySpeechClient.speak()
              ──▶ AVSpeechSynthesizerEngine (continuation + delegate)

  用户导出 ──▶ batch synthesizeAudio() (延迟合成)
          ──▶ AnkiExporter.export() ──▶ .apkg 文件
```

---

## 4. 已知限制

| 限制 | 说明 |
|------|------|
| CoreServices 单线程 | 所有字典查询必须串行，不能利用多核并行加速。大量单词时 lookup 较慢。 |
| AVSpeechSynthesizer 主线程要求 | synthesizer 和 delegate 必须在 `@MainActor` 上操作，async engine 通过 `Task { @MainActor in }` 保证。 |
| `MainThreadSpeechHelper` 保留 | CLI 的 `synthesizeSync()` 仍使用 RunLoop 自旋方式，仅用于 CLI 路径。App 侧完全使用 continuation 方案。两套实现并存。 |
| `.app` bundle 手动打包 | `justfile` 中手动创建 `.app` 目录结构和 `Info.plist`，没有使用 Xcode 项目。如需 sandbox、notarization 等需改用 xcodebuild。 |
| 空 buffer 结束信号 | `write()` API 的空 `frameLength` 结束信号依赖观察到的行为，Apple 文档未明确承诺。如果未来 OS 版本行为变化，`didFinish` 回调是兜底。 |
