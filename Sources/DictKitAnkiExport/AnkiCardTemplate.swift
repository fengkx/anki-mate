import Foundation

public enum AnkiCardTemplate {
    public static let modelName = "Anki Mate Basic"

    public static let fields = ["Word", "Phonetic", "Definitions", "Audio"]

    public static let frontTemplate = """
    <div class="front">
      <div class="word">{{Word}}</div>
      <div class="phonetic">{{Phonetic}}</div>
      {{Audio}}
    </div>
    """

    public static let backTemplate = """
    {{FrontSide}}
    <hr id="answer">
    <div class="back">
      {{Definitions}}
    </div>
    """

    public static let css = """
    .card {
      --card-text: #1a1a1a;
      --card-bg: #fafaf8;
      --muted-text: #667085;
      --subtle-text: #475467;
      --support-text: #64748b;
      --body-strong: #0f172a;
      --body-regular: #1f2937;
      --body-soft: #4b5563;
      --accent-blue: #2563eb;
      --answer-blue: #0b3b8c;
      --rule-color: #d7dce4;
      --panel-border: #e2e8f0;
      --panel-border-strong: #dbe4f0;
      --panel-bg: #ffffff;
      --panel-subtle-start: #ffffff;
      --panel-subtle-end: #f8fafc;
      --panel-warm-start: #fff1f2;
      --panel-warm-end: #ffffff;
      --panel-warm-border: #fbcfe8;
      --panel-warm-border-strong: #fb7185;
      --panel-cool-start: #eff6ff;
      --panel-cool-end: #ffffff;
      --panel-cool-border: #bfdbfe;
      --panel-cool-border-strong: #93c5fd;
      --panel-mint-start: #f0fdf4;
      --panel-mint-end: #ffffff;
      --warm-chip-text: #9f1239;
      --warm-chip-bg: #ffe4e6;
      --recall-chip-bg: #dbeafe;
      --chip-text: #475569;
      --chip-bg: #f2f4f7;
      --shadow-soft: 0 1px 2px rgba(15, 23, 42, 0.04);
      --shadow-card: 0 10px 30px rgba(15, 23, 42, 0.05);
      --shadow-card-soft: 0 10px 30px rgba(15, 23, 42, 0.04);
      font-family: -apple-system, "Helvetica Neue", Arial, sans-serif;
      font-size: 18px;
      text-align: left;
      color: var(--card-text);
      background: var(--card-bg);
      padding: 28px 28px 36px;
      max-width: 760px;
      margin: 0 auto;
    }
    .nightMode.card,
    body.nightMode .card,
    .nightMode .card {
      --card-text: #e5e7eb;
      --card-bg: #1f2329;
      --muted-text: #a8b3c7;
      --subtle-text: #c7d0dd;
      --support-text: #93a2b8;
      --body-strong: #f3f7ff;
      --body-regular: #e5ebf5;
      --body-soft: #b8c2d3;
      --accent-blue: #8bb8ff;
      --answer-blue: #b8d6ff;
      --rule-color: #3b4656;
      --panel-border: #3a4453;
      --panel-border-strong: #465469;
      --panel-bg: #2a313b;
      --panel-subtle-start: #313948;
      --panel-subtle-end: #262d36;
      --panel-warm-start: #442530;
      --panel-warm-end: #281f26;
      --panel-warm-border: #8b4057;
      --panel-warm-border-strong: #d66a88;
      --panel-cool-start: #223247;
      --panel-cool-end: #202a36;
      --panel-cool-border: #41658f;
      --panel-cool-border-strong: #5d8dd0;
      --panel-mint-start: #23382d;
      --panel-mint-end: #202923;
      --warm-chip-text: #ffd6e2;
      --warm-chip-bg: #6d2940;
      --recall-chip-bg: #253c57;
      --chip-text: #d9e2ef;
      --chip-bg: #374150;
      --shadow-soft: 0 1px 2px rgba(0, 0, 0, 0.35);
      --shadow-card: 0 10px 30px rgba(0, 0, 0, 0.28);
      --shadow-card-soft: 0 10px 30px rgba(0, 0, 0, 0.22);
    }
    a,
    a:visited {
      color: var(--accent-blue);
    }
    .front { text-align: center; }
    .word { font-size: 34px; font-weight: 750; margin-bottom: 8px; letter-spacing: -0.02em; }
    .phonetic { font-size: 18px; color: var(--muted-text); margin-bottom: 14px; line-height: 1.45; white-space: pre-line; }
    hr#answer { border: none; border-top: 1px solid var(--rule-color); margin: 20px 0 22px; }
    .back { text-align: left; }
    .pos-group { margin-bottom: 18px; padding-bottom: 2px; }
    .pos { font-size: 16px; font-style: italic; color: var(--accent-blue);
           margin: 14px 0 6px; text-transform: lowercase; }
    .senses { padding-left: 22px; margin: 0; }
    .senses li { margin-bottom: 12px; line-height: 1.55; }
    .hint { color: var(--muted-text); font-size: 14px; margin-right: 4px; }
    .register { color: var(--muted-text); font-size: 13px; font-style: italic; margin-right: 4px; }
    .def { }
    .examples { list-style: none; padding-left: 12px; margin-top: 4px; }
    .examples li { color: var(--subtle-text); font-style: italic; font-size: 15px;
                   margin-bottom: 4px; line-height: 1.5; }
    .examples li::before { content: "\\201C"; }
    .examples li::after { content: "\\201D"; }
    .ai-inline-note {
      margin: 0;
      line-height: 1.55;
      color: var(--body-regular);
    }
    .ai-study-layer {
      margin-top: 24px;
      padding-top: 20px;
      border-top: 1px solid var(--rule-color);
    }
    .ai-study-header {
      margin-bottom: 14px;
    }
    .ai-study-kicker {
      font-size: 11px;
      font-weight: 700;
      letter-spacing: 0.08em;
      text-transform: uppercase;
      color: var(--support-text);
      margin-bottom: 4px;
    }
    .ai-study-title {
      margin: 0;
      font-size: 18px;
      font-weight: 750;
      color: var(--body-strong);
      letter-spacing: -0.01em;
    }
    .ai-panel {
      margin-top: 14px;
      padding: 16px 18px;
      border-radius: 18px;
      border: 1px solid var(--panel-border);
      background: linear-gradient(180deg, var(--panel-subtle-start) 0%, var(--panel-subtle-end) 100%);
      box-shadow: var(--shadow-soft);
    }
    .ai-panel-highlight {
      background: linear-gradient(180deg, var(--panel-warm-start) 0%, var(--panel-warm-end) 100%);
      border-color: var(--panel-warm-border);
    }
    .ai-panel-recall {
      background: linear-gradient(180deg, var(--panel-cool-start) 0%, var(--panel-cool-end) 100%);
      border-color: var(--panel-cool-border);
    }
    .ai-panel-header {
      display: flex;
      align-items: flex-end;
      justify-content: space-between;
      gap: 12px;
      flex-wrap: wrap;
      margin-bottom: 12px;
    }
    .ai-panel-eyebrow {
      font-size: 11px;
      font-weight: 700;
      letter-spacing: 0.07em;
      text-transform: uppercase;
      color: var(--support-text);
      margin-bottom: 4px;
    }
    .ai-panel-title {
      margin: 0;
      font-size: 16px;
      font-weight: 700;
      color: var(--body-strong);
    }
    .ai-example-grid {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
      gap: 12px;
    }
    .ai-example-card,
    .ai-learning-block,
    .ai-recall-card {
      padding: 14px;
      border-radius: 14px;
      border: 1px solid var(--panel-border);
      background: var(--panel-bg);
      box-shadow: var(--shadow-soft);
    }
    .ai-example-text {
      font-size: 17px;
      line-height: 1.55;
      color: var(--body-strong);
    }
    .ai-example-translation {
      margin-top: 8px;
      font-size: 15px;
      line-height: 1.55;
      color: var(--subtle-text);
    }
    .ai-learning-grid {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(190px, 1fr));
      gap: 12px;
    }
    .ai-learning-warning {
      background: linear-gradient(180deg, var(--panel-warm-start) 0%, var(--panel-warm-end) 100%);
    }
    .ai-learning-memory {
      background: linear-gradient(180deg, var(--panel-mint-start) 0%, var(--panel-mint-end) 100%);
    }
    .ai-learning-collocation {
      background: linear-gradient(180deg, var(--panel-cool-start) 0%, var(--panel-cool-end) 100%);
    }
    .ai-learning-title {
      margin: 0 0 10px;
      font-size: 14px;
      font-weight: 700;
      color: var(--body-strong);
    }
    .ai-learning-list {
      margin: 0;
      padding: 0;
      list-style: none;
      display: flex;
      flex-direction: column;
      gap: 10px;
    }
    .ai-learning-item {
      margin: 0;
    }
    .ai-learning-text {
      font-size: 15px;
      line-height: 1.6;
      color: var(--body-regular);
    }
    .ai-collocation-phrase {
      display: block;
      font-weight: 600;
      color: var(--body-strong);
      line-height: 1.5;
    }
    .ai-recall-stack {
      display: grid;
      gap: 12px;
    }
    .ai-recall-header {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 8px;
      flex-wrap: wrap;
      margin-bottom: 12px;
    }
    .ai-recall-mode {
      display: inline-flex;
      align-items: center;
      padding: 4px 10px;
      border-radius: 999px;
      font-size: 12px;
      font-weight: 700;
      color: var(--accent-blue);
      background: var(--recall-chip-bg);
    }
    .ai-recall-field + .ai-recall-field {
      margin-top: 10px;
    }
    .ai-recall-prompt-card,
    .ai-recall-answer-card {
      padding: 14px 16px;
      border-radius: 14px;
      border: 1px solid var(--panel-border);
    }
    .ai-recall-prompt-card {
      background: linear-gradient(180deg, var(--panel-warm-start) 0%, var(--panel-warm-end) 100%);
      border-color: var(--panel-warm-border-strong);
      margin-bottom: 10px;
    }
    .ai-recall-answer-card {
      background: linear-gradient(180deg, var(--panel-cool-start) 0%, var(--panel-cool-end) 100%);
      border-color: var(--panel-cool-border-strong);
      margin-bottom: 10px;
    }
    .ai-field-label {
      font-size: 11px;
      font-weight: 700;
      letter-spacing: 0.07em;
      text-transform: uppercase;
      color: var(--support-text);
    }
    .ai-field-value {
      margin-top: 4px;
      font-size: 16px;
      line-height: 1.55;
      color: var(--body-strong);
    }
    .ai-subnote {
      margin-top: 6px;
      font-size: 14px;
      color: var(--body-soft);
      line-height: 1.5;
    }
    .ai-meta-row {
      margin-top: 10px;
      display: flex;
      flex-wrap: wrap;
      gap: 8px;
      align-items: center;
    }
    .ai-tag {
      display: inline-block;
      padding: 2px 7px;
      border-radius: 999px;
      font-size: 10px;
      font-weight: 700;
      letter-spacing: 0.02em;
      color: var(--chip-text);
      background: var(--chip-bg);
      white-space: nowrap;
    }
    """
}

public enum AnkiRecallCardTemplate {
    public static let modelName = "Anki Mate Recall"

    public static let fields = [
        "Prompt",
        "Mode",
        "Instruction",
        "Hint",
        "Answer",
        "SourceWord",
        "Phonetic",
        "Definitions",
        "Audio"
    ]

    public static let frontTemplate = """
    <div class="front recall-shell">
      <div class="recall-eyebrow">Recall Card</div>
      <div class="recall-topline">
        <div class="recall-mode-chip">{{Mode}}</div>
        <div class="recall-stage-chip">Front</div>
      </div>
      <div class="recall-instruction">{{Instruction}}</div>
      <div class="recall-prompt-card">
        <div class="recall-section-label">Prompt</div>
        <div class="recall-front-text">{{Prompt}}</div>
      </div>
      {{#Hint}}
      <div class="recall-support-card">
        <div class="recall-section-label">Hint</div>
        <div class="recall-support-text">{{Hint}}</div>
      </div>
      {{/Hint}}
    </div>
    """

    public static let backTemplate = """
    <div class="front recall-shell">
      <div class="recall-eyebrow">Recall Card</div>
      <div class="recall-topline">
        <div class="recall-mode-chip">{{Mode}}</div>
        <div class="recall-stage-chip">Back</div>
      </div>
      <div class="recall-instruction">{{Instruction}}</div>
      <div class="recall-prompt-card">
        <div class="recall-section-label">Prompt</div>
        <div class="recall-front-text">{{Prompt}}</div>
      </div>
      {{#Hint}}
      <div class="recall-support-card">
        <div class="recall-section-label">Hint</div>
        <div class="recall-support-text">{{Hint}}</div>
      </div>
      {{/Hint}}
    </div>
    <hr id="answer">
    <div class="back recall-answer-shell">
      <div class="recall-answer-card">
        <div class="recall-section-label">Answer</div>
        <div class="recall-answer-text">{{Answer}}</div>
      </div>
      <section class="recall-reference-shell">
        <div class="recall-reference-kicker">Source Entry</div>
        <div class="recall-reference-card">
          <div class="recall-reference-header">
            <div class="recall-source-word">{{SourceWord}}</div>
            <div class="recall-reference-meta">
              {{#Phonetic}}<div class="phonetic recall-phonetic">{{Phonetic}}</div>{{/Phonetic}}
              {{#Audio}}<div class="recall-audio">{{Audio}}</div>{{/Audio}}
            </div>
          </div>
          {{#Definitions}}
          <div class="recall-definitions">
            <div class="recall-section-label">Reference</div>
            {{Definitions}}
          </div>
          {{/Definitions}}
        </div>
      </section>
    </div>
    """

    public static let css = """
    \(AnkiCardTemplate.css)
    .recall-shell,
    .recall-answer-shell {
      text-align: left;
      display: flex;
      flex-direction: column;
      gap: 14px;
    }
    .recall-eyebrow {
      font-size: 12px;
      font-weight: 700;
      letter-spacing: 0.08em;
      text-transform: uppercase;
      color: var(--support-text);
    }
    .recall-topline {
      display: flex;
      justify-content: space-between;
      align-items: center;
      gap: 10px;
      flex-wrap: wrap;
    }
    .recall-mode-chip,
    .recall-stage-chip {
      display: inline-flex;
      align-items: center;
      padding: 6px 12px;
      border-radius: 999px;
      font-size: 12px;
      font-weight: 700;
    }
    .recall-mode-chip {
      color: var(--warm-chip-text);
      background: var(--warm-chip-bg);
    }
    .recall-stage-chip {
      color: var(--chip-text);
      background: var(--chip-bg);
    }
    .recall-instruction {
      font-size: 18px;
      line-height: 1.55;
      color: var(--subtle-text);
    }
    .recall-prompt-card,
    .recall-support-card,
    .recall-answer-card,
    .recall-source-panel {
      padding: 18px 20px;
      border-radius: 20px;
      background: var(--panel-bg);
      border: 1px solid var(--panel-border);
      box-shadow: var(--shadow-card);
    }
    .recall-prompt-card {
      background: linear-gradient(180deg, var(--panel-warm-start) 0%, var(--panel-warm-end) 100%);
      border-color: var(--panel-warm-border-strong);
    }
    .recall-answer-card {
      background: linear-gradient(180deg, var(--panel-cool-start) 0%, var(--panel-cool-end) 100%);
      border-color: var(--panel-cool-border-strong);
    }
    .recall-source-panel {
      display: flex;
      flex-direction: column;
      gap: 8px;
    }
    .recall-reference-shell {
      display: flex;
      flex-direction: column;
      gap: 10px;
    }
    .recall-reference-kicker {
      font-size: 12px;
      font-weight: 700;
      letter-spacing: 0.08em;
      text-transform: uppercase;
      color: var(--support-text);
    }
    .recall-reference-card {
      padding: 20px 22px;
      border-radius: 22px;
      background: linear-gradient(180deg, var(--panel-subtle-end) 0%, var(--panel-bg) 100%);
      border: 1px solid var(--panel-border-strong);
      box-shadow: var(--shadow-card-soft);
    }
    .recall-reference-header {
      display: flex;
      flex-direction: column;
      gap: 8px;
      margin-bottom: 16px;
    }
    .recall-reference-meta {
      display: flex;
      flex-wrap: wrap;
      align-items: center;
      gap: 10px 14px;
    }
    .recall-source-word {
      font-size: 26px;
      font-weight: 760;
      letter-spacing: -0.02em;
      color: var(--body-strong);
    }
    .recall-phonetic {
      margin: 0;
    }
    .recall-audio {
      display: inline-flex;
      align-items: center;
      min-height: 24px;
    }
    .recall-section-label {
      font-size: 11px;
      font-weight: 700;
      letter-spacing: 0.08em;
      text-transform: uppercase;
      color: var(--support-text);
      margin-bottom: 8px;
    }
    .recall-front-text,
    .recall-answer-text {
      font-size: 32px;
      font-weight: 760;
      line-height: 1.22;
      letter-spacing: -0.03em;
      color: var(--body-strong);
      word-break: break-word;
    }
    .recall-answer-text {
      color: var(--answer-blue);
    }
    .recall-support-text {
      font-size: 16px;
      line-height: 1.6;
      color: var(--subtle-text);
    }
    .recall-definitions {
      border-top: 1px solid var(--panel-border);
      padding-top: 16px;
    }
    .recall-definitions .pos-group:first-child .pos {
      margin-top: 0;
    }
    .recall-definitions .ai-study-layer {
      margin-top: 18px;
      padding-top: 18px;
      border-top: 1px solid var(--rule-color);
    }
    """
}
