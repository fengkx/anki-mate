# Speech Specs

## 文档定位

这里汇总语音生成与 app 集成相关 spec。

## 渐进式披露阅读顺序

1. 先看语音能力本身
   - [speech-synthesis.md](../speech-synthesis.md)
2. 再看 app 侧集成
   - [app-speech-integration.md](../app-speech-integration.md)

## 目录结构

```text
docs/specs/speech/
├── README.md
└── related specs at docs/specs/
    ├── speech-synthesis.md
    └── app-speech-integration.md
```

## 目录说明

- 语音能力和 app 集成分层看，先能力后接入
- 如果是实现问题，通常还要回到 `Sources/DictKitSystemDictionary` 和 `Sources/DictKitApp`

