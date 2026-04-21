import XCTest
@testable import DictKitApp

final class AgentMarkdownRendererTests: XCTestCase {
    func testRenderLinesPreservePlainTextLineBreaks() {
        let rendered = AgentMarkdownRenderer.renderLines(
            """
            dismantle 和 demolish 的主要区别在于：
            1. dismantle 更强调拆解过程
            2. demolish 更强调彻底毁坏
            简单总结：
            前者像拆机器，后者像推楼。
            """
        )

        XCTAssertEqual(rendered.count, 5)
        XCTAssertEqual(String(rendered[0].content.characters), "dismantle 和 demolish 的主要区别在于：")
        XCTAssertEqual(String(rendered[1].content.characters), "1. dismantle 更强调拆解过程")
        XCTAssertEqual(String(rendered[4].content.characters), "前者像拆机器，后者像推楼。")
    }

    func testRenderLinesNormalizeBlockMarkdownSyntax() {
        let rendered = AgentMarkdownRenderer.renderLines(
            """
            # Title

            - first
            - second

            ```swift
            print("hello")
            ```
            """
        )

        let visibleLines = rendered.filter { !$0.isBlank }
        XCTAssertEqual(String(visibleLines[0].content.characters), "Title")
        XCTAssertEqual(String(visibleLines[1].content.characters), "• first")
        XCTAssertEqual(String(visibleLines[2].content.characters), "• second")
        XCTAssertEqual(String(visibleLines[3].content.characters), "print(\"hello\")")
        XCTAssertTrue(visibleLines[3].isCode)
    }

    func testRenderLinesNormalizeLatexArrowToken() {
        let rendered = AgentMarkdownRenderer.renderLines(
            """
            *   **Dismantle** $\\rightarrow$ **拆开**
            """
        )

        XCTAssertEqual(String(rendered[0].content.characters), "• Dismantle → 拆开")
    }
}
