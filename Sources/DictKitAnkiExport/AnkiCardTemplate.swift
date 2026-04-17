import Foundation

public enum AnkiCardTemplate {
    public static let modelName = "Anki Mate Basic"

    public static let fields = ["Word", "Phonetic", "Definitions", "Audio"]

    public static let frontTemplate = """
    <div class="front">
      <div class="word">{{Word}}</div>
      <div class="phonetic">/{{Phonetic}}/</div>
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
      background: #fafafa;
      padding: 20px;
      max-width: 600px;
      margin: 0 auto;
    }
    .front { text-align: center; }
    .word { font-size: 32px; font-weight: 700; margin-bottom: 8px; }
    .phonetic { font-size: 18px; color: #666; margin-bottom: 12px; }
    hr#answer { border: none; border-top: 1px solid #ddd; margin: 16px 0; }
    .back { text-align: left; }
    .pos-group { margin-bottom: 16px; }
    .pos { font-size: 16px; font-style: italic; color: #2563eb;
           margin: 12px 0 4px; text-transform: lowercase; }
    .senses { padding-left: 20px; margin: 0; }
    .senses li { margin-bottom: 10px; }
    .hint { color: #888; font-size: 14px; margin-right: 4px; }
    .register { color: #888; font-size: 13px; font-style: italic; margin-right: 4px; }
    .def { }
    .examples { list-style: none; padding-left: 12px; margin-top: 4px; }
    .examples li { color: #555; font-style: italic; font-size: 15px;
                   margin-bottom: 2px; }
    .examples li::before { content: "\\201C"; }
    .examples li::after { content: "\\201D"; }
    .ai-inline-note {
      margin: 14px 0 0;
      line-height: 1.55;
      color: #374151;
    }
    .ai-supplement-list {
      margin-top: 14px;
      padding-left: 24px;
    }
    .ai-tag {
      display: inline-block;
      margin-left: 8px;
      padding: 1px 6px;
      border-radius: 999px;
      font-size: 10px;
      font-weight: 600;
      letter-spacing: 0.01em;
      color: #6b7280;
      background: #f3f4f6;
      vertical-align: middle;
      white-space: nowrap;
    }
    .examples-supplement li {
      color: #374151;
      font-style: normal;
      margin-bottom: 10px;
      line-height: 1.55;
    }
    .examples-supplement li::before,
    .examples-supplement li::after {
      content: none;
    }
    .ai-subnote {
      margin-top: 4px;
      font-size: 14px;
      color: #4b5563;
      line-height: 1.5;
    }
    .ai-artifact-section {
      margin-top: 18px;
      padding-top: 12px;
      border-top: 1px solid #e5e7eb;
    }
    .ai-artifact-title {
      margin: 0 0 8px;
      font-size: 14px;
      font-weight: 700;
      color: #111827;
    }
    .ai-artifact-list {
      margin: 0;
      padding-left: 20px;
    }
    .ai-artifact-list li {
      margin-bottom: 8px;
      line-height: 1.55;
    }
    .ai-recall-draft {
      line-height: 1.6;
    }
    .ai-recall-mode,
    .ai-collocation-phrase {
      font-weight: 600;
      color: #1f2937;
    }
    """
}
