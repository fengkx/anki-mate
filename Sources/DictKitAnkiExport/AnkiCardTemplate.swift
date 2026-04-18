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
      font-family: -apple-system, "Helvetica Neue", Arial, sans-serif;
      font-size: 18px;
      text-align: left;
      color: #1a1a1a;
      background: #fafaf8;
      padding: 28px 28px 36px;
      max-width: 760px;
      margin: 0 auto;
    }
    .front { text-align: center; }
    .word { font-size: 34px; font-weight: 750; margin-bottom: 8px; letter-spacing: -0.02em; }
    .phonetic { font-size: 18px; color: #667085; margin-bottom: 14px; }
    hr#answer { border: none; border-top: 1px solid #d7dce4; margin: 20px 0 22px; }
    .back { text-align: left; }
    .pos-group { margin-bottom: 18px; padding-bottom: 2px; }
    .pos { font-size: 16px; font-style: italic; color: #2563eb;
           margin: 14px 0 6px; text-transform: lowercase; }
    .senses { padding-left: 22px; margin: 0; }
    .senses li { margin-bottom: 12px; line-height: 1.55; }
    .hint { color: #7c8798; font-size: 14px; margin-right: 4px; }
    .register { color: #7c8798; font-size: 13px; font-style: italic; margin-right: 4px; }
    .def { }
    .examples { list-style: none; padding-left: 12px; margin-top: 4px; }
    .examples li { color: #475467; font-style: italic; font-size: 15px;
                   margin-bottom: 4px; line-height: 1.5; }
    .examples li::before { content: "\\201C"; }
    .examples li::after { content: "\\201D"; }
    .ai-inline-note {
      margin: 0;
      line-height: 1.55;
      color: #1f2937;
    }
    .ai-study-layer {
      margin-top: 24px;
      padding-top: 20px;
      border-top: 1px solid #d7dce4;
    }
    .ai-study-header {
      margin-bottom: 14px;
    }
    .ai-study-kicker {
      font-size: 11px;
      font-weight: 700;
      letter-spacing: 0.08em;
      text-transform: uppercase;
      color: #64748b;
      margin-bottom: 4px;
    }
    .ai-study-title {
      margin: 0;
      font-size: 18px;
      font-weight: 750;
      color: #0f172a;
      letter-spacing: -0.01em;
    }
    .ai-panel {
      margin-top: 14px;
      padding: 16px 18px;
      border-radius: 18px;
      border: 1px solid #e2e8f0;
      background: linear-gradient(180deg, #ffffff 0%, #f8fafc 100%);
      box-shadow: 0 1px 2px rgba(15, 23, 42, 0.04);
    }
    .ai-panel-highlight {
      background: linear-gradient(180deg, #fff7ed 0%, #ffffff 100%);
      border-color: #fed7aa;
    }
    .ai-panel-recall {
      background: linear-gradient(180deg, #eff6ff 0%, #ffffff 100%);
      border-color: #bfdbfe;
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
      color: #64748b;
      margin-bottom: 4px;
    }
    .ai-panel-title {
      margin: 0;
      font-size: 16px;
      font-weight: 700;
      color: #0f172a;
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
      border: 1px solid #e2e8f0;
      background: #ffffff;
      box-shadow: 0 1px 2px rgba(15, 23, 42, 0.03);
    }
    .ai-example-text {
      font-size: 17px;
      line-height: 1.55;
      color: #0f172a;
    }
    .ai-example-translation {
      margin-top: 8px;
      font-size: 15px;
      line-height: 1.55;
      color: #475569;
    }
    .ai-learning-grid {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(190px, 1fr));
      gap: 12px;
    }
    .ai-learning-warning {
      background: linear-gradient(180deg, #fff7ed 0%, #ffffff 100%);
    }
    .ai-learning-memory {
      background: linear-gradient(180deg, #f0fdf4 0%, #ffffff 100%);
    }
    .ai-learning-collocation {
      background: linear-gradient(180deg, #eff6ff 0%, #ffffff 100%);
    }
    .ai-learning-title {
      margin: 0 0 10px;
      font-size: 14px;
      font-weight: 700;
      color: #0f172a;
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
      color: #1f2937;
    }
    .ai-collocation-phrase {
      display: block;
      font-weight: 600;
      color: #0f172a;
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
      color: #1d4ed8;
      background: #dbeafe;
    }
    .ai-recall-field + .ai-recall-field {
      margin-top: 10px;
    }
    .ai-field-label {
      font-size: 11px;
      font-weight: 700;
      letter-spacing: 0.07em;
      text-transform: uppercase;
      color: #64748b;
    }
    .ai-field-value {
      margin-top: 4px;
      font-size: 16px;
      line-height: 1.55;
      color: #0f172a;
    }
    .ai-subnote {
      margin-top: 6px;
      font-size: 14px;
      color: #4b5563;
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
      color: #475467;
      background: #f2f4f7;
      white-space: nowrap;
    }
    """
}
