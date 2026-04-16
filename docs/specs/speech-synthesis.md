# Speech Synthesis Spec

## 1. 文档定位

本文档记录 `dictkit speech` 语音合成功能的设计决策、架构和关键实现细节。

目标场景：从 macOS 系统词典查询单词发音，通过 `AVSpeechSynthesizer` 合成语音并输出 WAV 文件。主要用于 Anki 卡片批量生成发音音频。

---

## 2. 核心决策

### 2.1 默认使用纯文本朗读，IPA 为可选模式

**问题**

macOS 系统词典（Oxford EC 英汉）的 IPA 标注存在两个问题：

1. **HTML 源返回 respelling 而非 IPA**：私有 HTML API（NOAD）返回的是 respelling 记法（如 `ˈdikSHəˌnerē`），而非真正的 IPA（`ˈdɪkʃəˌnɛri`）。HTML 中的 `<span class="ph t_respell">` 明确标注了这是 respelling。
2. **IPA 标注的浊化 t 问题**：公共 API 返回的 AmE IPA 用 `d` 表示 flap t（如 `ˈɑrdəˌfækt`），`AVSpeechSynthesizer` 会按字面读成硬 `d` 音，听起来像"啊抖fact"而非"啊踢fact"。

**决策**

默认让 `AVSpeechSynthesizer` 直接朗读单词文本（plain text 模式），其内置的英语发音规则在绝大多数情况下比传入 IPA 更自然。通过 `--ipa` flag 可以启用 IPA 模式。

| Flag | useIPA | fallbackPolicy | 行为 |
|------|--------|----------------|------|
| (无) | false | .useHeadwordText | 纯文本朗读，不使用 IPA |
| `--ipa` | true | .useHeadwordText | 使用 IPA 发音；无可用 IPA 时退回纯文本 |
| `--strict` | true | .failIfNoPronunciation | 必须使用 IPA 发音；无可用 IPA 时报错退出 |

### 2.2 IPA 模式下优先使用公共 API

**问题**

`automatic` 源优先查询私有 HTML API，但 HTML 源只有 respelling。公共 API 才返回真正的 IPA。

**决策**

当 `useIPA == true && source == .automatic` 时，先尝试公共 API。如果公共 API 返回了有效 IPA，直接使用；否则退回到原来的 automatic 路径（HTML → 公共 API fallback）。

```
resolveLookup(request):
  if useIPA && source == automatic:
    try publicAPI first → if valid IPA found, use it
  fallthrough to default lookup path
```

### 2.3 Respelling 检测

**问题**

HTML 解析器将 respelling 文本存入 `Pronunciation.ipa` 字段（历史原因，HTML 源不区分 IPA 和 respelling）。需要在 TTS 环节过滤掉 respelling。

**决策**

在 `Pronunciation.ttsIPANotation` 中加入检测：如果字符串包含 ASCII 大写字母（A-Z），判定为 respelling 并返回 `nil`。

依据：真正的 IPA 使用 Unicode 符号（ʃ、θ、ð、ŋ 等），不会出现 ASCII 大写字母。Respelling 使用 ASCII 大写双字母（SH、TH、CH、ZH）表示音素。

```swift
private static func isRespelling(_ text: String) -> Bool {
    text.unicodeScalars.contains { $0.value >= 0x41 && $0.value <= 0x5A }
}
```

此外，IPA 中的可选音素括号（如 `ˈæp(ə)l`）会被剥离为 `ˈæpəl`，因为 `AVSpeechSynthesisIPANotationAttribute` 不支持括号记法。

### 2.4 语音选择优先级

**问题**

`AVSpeechSynthesisVoice.speechVoices()` 返回所有系统语音，默认取第一个匹配语言的语音。在实际系统上，第一个往往是 Eloquence 系列（如 `com.apple.eloquence.en-US.Flo`），这是一种电子感很强的合成语音，单词发音不自然。

**决策**

Voice resolver 按语音质量分级排序，优先选择更自然的语音：

| 优先级 | 类型 | 识别方式 | 示例 |
|--------|------|----------|------|
| 0 | Premium | quality >= 2 | 下载的高质量/增强语音 |
| 1 | Siri | identifier 含 `siri_` | Aaron, Nicky, Martha |
| 2 | Standard Compact | identifier 含 `voice.compact.` | Samantha, Daniel, Karen |
| 3 | Eloquence | identifier 含 `eloquence` | Flo, Eddy, Reed |
| 4 | Novelty | 其他 | Bells, Boing, Whisper |

语言匹配仍然是第一优先级：先按发音的 dialect 确定语言（AmE → en-US, BrE → en-GB），然后在该语言的候选语音中按上述优先级排序。

---

## 3. 架构

### 3.1 文件结构

```
Sources/
├── DictKit/
│   └── Models.swift                    # Pronunciation.ttsIPANotation, isRespelling
├── DictKitSystemDictionary/
│   ├── SpeechModels.swift              # 配置、请求、响应模型
│   ├── SpeechVoiceResolver.swift       # 语音选择和排序
│   ├── SpeechAudioEncoder.swift        # PCM → WAV 编码
│   └── DictionarySpeechClient.swift    # 核心编排：查词 → 解析 → 合成
└── DictKitCLI/
    └── DictKitSpeechCommand.swift      # CLI 入口
```

### 3.2 数据流

```
CLI 输入: dictkit speech [--ipa] [--strict] [--dialect AmE] --output out.wav word
  │
  ▼
DictKitSpeechCommand
  │ 构建 SpeechSynthesisConfiguration (useIPA, fallbackPolicy, voice, dialect)
  │ 构建 LookupSpeechRequest (term, source, selection)
  │
  ▼
DictionarySpeechClient.synthesizeSync()
  │
  ├─ resolveLookup()
  │   ├─ [useIPA + automatic] 先尝试 publicAPI 获取真 IPA
  │   ├─ SystemDictionaryClient.lookup() → LookupResult
  │   ├─ pronunciationCandidates() → 按 selection 过滤
  │   └─ selectPronunciation() → 选中一个 Pronunciation
  │
  ├─ resolve(SpeechRequest)
  │   ├─ [useIPA=false] pronunciation=nil, 纯文本模式
  │   ├─ [useIPA=true]  检查 ttsIPANotation (验证/剥括号/拒绝respelling)
  │   └─ SpeechVoiceResolver.resolveVoice() → 按优先级选语音
  │
  ▼
MainThreadSpeechHelper.synthesize()
  │ 必须在主线程，通过 RunLoop spinning 等待完成
  │
  ├─ AVSpeechUtterance + AVSpeechSynthesisIPANotationAttribute (如有 IPA)
  ├─ AVSpeechSynthesizer.write() → 收集 PCM buffers
  ├─ SpeechDelegate.didFinish → 停止 RunLoop
  │
  ▼
SpeechAudioEncoder.encodeWave()
  │ PCM buffers → 临时 AVAudioFile → 读回 WAV Data
  │
  ▼
写入输出文件 + 可选 JSON 元数据输出
```

### 3.3 主线程约束

`AVSpeechSynthesizer` 的 `write()` 回调和 delegate 回调都依赖主线程的 RunLoop。在 CLI 进程中，主线程没有 RunLoop 在运行，因此需要手动 spin：

```swift
private static func waitUntilCompleted(_ predicate: () -> Bool) throws {
    let deadline = Date().addingTimeInterval(10)
    while !predicate() && Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    guard predicate() else {
        throw SpeechError.synthesisUnavailable
    }
}
```

关键点：
- 使用 delegate 的 `didFinish` 而非零长度 completion buffer 来判断结束（某些 macOS 版本不发送零长度 buffer）
- 10 秒超时防止无限阻塞
- `synthesizeSync()` 直接在主线程调用，避免了 `DispatchSemaphore` + `MainActor` 的死锁问题

### 3.4 WAV 编码

`SpeechAudioEncoder` 通过 `AVAudioFile` 将 PCM buffers 写入临时文件再读回。这是最简单可靠的方式，因为 `AVAudioFile` 会自动处理 RIFF/WAVE 头和 PCM 数据格式。

输出格式取决于 `AVSpeechSynthesizer` 返回的 buffer 格式，通常是 22.05kHz 或 44.1kHz 单声道 Int16 PCM。

---

## 4. CLI 接口

```
USAGE: dictkit speech [--output <path>] [--ipa] [--strict] [--dialect <dialect>]
                      [--lexical-entry <n>] [--source <source>]
                      [--voice-identifier <id>] [--language-hint <code>]
                      [--json] <query>

OPTIONS:
  -o, --output <path>       输出音频文件路径（无扩展名时自动加 .wav）
  --ipa                     使用词典 IPA 标注发音（默认使用纯文本朗读）
  --strict                  无 IPA 时报错退出（隐含 --ipa）
  --dialect <dialect>       优先使用指定方言（AmE / BrE）
  --lexical-entry <n>       从第 n 个词条（0-based）取发音
  --source <source>         查词源：automatic / public / html
  --voice-identifier <id>   指定系统语音 identifier
  --language-hint <code>    语言提示（如 en-US）
  --json                    输出合成元数据 JSON
```

**示例**

```bash
# 默认：纯文本朗读（推荐）
dictkit speech --output ./hello.wav hello

# 使用 IPA 发音
dictkit speech --ipa --output ./hello.wav hello

# 指定方言
dictkit speech --ipa --dialect BrE --output ./hello.wav hello

# 严格模式（无 IPA 则报错）
dictkit speech --strict --output ./hello.wav hello

# 输出 JSON 元数据
dictkit speech --json --output ./hello.wav hello
```

---

## 5. 已知限制和后续方向

### 已知限制

1. **Eloquence 语音质量差**：系统未下载高质量语音时，Siri compact 语音是最佳选择，但仍不如 Premium 语音。可在 `系统设置 → 辅助功能 → 朗读内容 → 系统声音` 中下载高质量语音。
2. **IPA 浊化 t**：AmE IPA 中 flap t 标记为 `d`，`AVSpeechSynthesizer` 无法正确处理。这是系统 TTS 引擎的限制。
3. **Respelling 检测为启发式**：依赖"ASCII 大写字母"这一特征。如果未来出现使用 ASCII 大写的 IPA 变体，可能误判。但在 macOS 词典数据集中验证无误。
4. **单次合成超时 10 秒**：长文本或系统负载高时可能超时。

### 后续可迭代方向

- 支持从外部 JSON 文件批量合成（Anki batch workflow）
- 添加 `--voice` 选项支持按名称（而非 identifier）选择语音
- 支持输出 MP3/AAC 格式（减小文件体积）
- 考虑异步 batch API 避免主线程阻塞
