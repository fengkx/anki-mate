import Foundation
import XCTest
@testable import AnkiMateLLM
@testable import AnkiMateRPC
@testable import DictKitAnkiExport

@MainActor
final class AgentSessionTests: XCTestCase {
    func testReloadLoadsPersistedMessagesAndPendingProposals() throws {
        let persistence = InMemoryAgentPersistence()
        let wordID = UUID()
        let sessionRecord = try persistence.upsertSession(for: wordID)
        let pending = ProposalRecord(
            kind: .example,
            operation: .add,
            payloadJSON: #"{"text":"Apple stock fell sharply.","translation":"苹果公司股价大跌。"}"#,
            diffSummary: "Add business example"
        )
        var applied = ProposalRecord(
            kind: .pitfall,
            operation: .add,
            payloadJSON: #"{"id":"pf-1","text":"Company vs fruit"}"#,
            diffSummary: "Add pitfall"
        )
        applied.decision = .applied

        _ = try persistence.addMessage(sessionID: sessionRecord.id, role: .assistant, content: .actionProposal(pending))
        _ = try persistence.addMessage(sessionID: sessionRecord.id, role: .assistant, content: .actionProposal(applied))

        let sut = AgentSession(
            wordID: wordID,
            persistence: persistence,
            snapshotProvider: StaticSnapshotProvider(),
            generator: RecordingGenerator(result: .init(text: "unused", tokensUsed: 1, durationMs: 1))
        )

        try sut.reload()

        XCTAssertEqual(sut.messages.count, 2)
        XCTAssertEqual(sut.pendingProposals.map(\.diffSummary), ["Add business example"])
    }

    func testSendUserMessagePersistsUserAndAssistantMessagesAndCallsGenerator() async throws {
        let persistence = InMemoryAgentPersistence()
        let generator = RecordingGenerator(
            result: GenerateResult(text: "我会保留商业例句，只缩短第二句。", tokensUsed: 42, durationMs: 12)
        )
        let wordID = UUID()
        let sut = AgentSession(
            wordID: wordID,
            persistence: persistence,
            snapshotProvider: StaticSnapshotProvider(),
            generator: generator
        )

        try sut.reload()
        try await sut.sendUserMessage("把第二个例句换短一点")

        XCTAssertEqual(sut.messages.count, 2)
        XCTAssertEqual(sut.messages[0].role, .user)
        XCTAssertEqual(sut.messages[1].role, .assistant)
        XCTAssertEqual(generator.calls.count, 1)
        XCTAssertTrue(generator.calls[0].contains { $0.role == .system })
        XCTAssertTrue(generator.calls[0].contains { $0.content.contains("把第二个例句换短一点") })
        XCTAssertTrue(generator.calls[0].contains { $0.content.contains("Current card snapshot") })
    }

    func testSendUserMessageWithAttachmentsPassesImagesAndTextFilesToGenerator() async throws {
        let persistence = InMemoryAgentPersistence()
        let attachments = [
            AgentAttachment(
                kind: .image,
                mimeType: "image/png",
                fileName: "card.png",
                relativePath: "agent/session/card.png",
                byteSize: 3,
                width: 20,
                height: 10
            ),
            AgentAttachment(
                kind: .textFile,
                mimeType: "text/markdown",
                fileName: "notes.md",
                relativePath: "agent/session/notes.md",
                byteSize: 12,
                extractedTextPreview: "# Notes",
                characterCount: 12
            ),
        ]
        let attachmentStore = InMemoryAgentAttachmentStore(
            dataByRelativePath: [
                "agent/session/card.png": Data([0x01, 0x02, 0x03]),
                "agent/session/notes.md": Data("# Notes\nhello".utf8),
            ]
        )
        let generator = RecordingGenerator(
            result: GenerateResult(text: "看到了图片和笔记。", tokensUsed: 42, durationMs: 12)
        )
        let wordID = UUID()
        let sut = AgentSession(
            wordID: wordID,
            persistence: persistence,
            snapshotProvider: StaticSnapshotProvider(),
            attachmentStore: attachmentStore,
            generator: generator
        )

        try sut.reload()
        try await sut.sendUserMessage("结合附件解释一下", attachments: attachments)

        guard case .userInput(let text, let persistedAttachments) = sut.messages[0].content else {
            return XCTFail("Expected user input message")
        }
        XCTAssertEqual(text, "结合附件解释一下")
        XCTAssertEqual(persistedAttachments.map(\.fileName), ["card.png", "notes.md"])
        XCTAssertTrue(generator.calls[0].contains { message in
            message.content.parts.contains(.imageURL("data:image/png;base64,AQID"))
        })
        XCTAssertTrue(generator.calls[0].contains { message in
            message.content.plainText.contains("Attached file: notes.md") &&
                message.content.plainText.contains("# Notes\nhello")
        })
    }

    func testSendUserMessageRollsBackMessagesAndRethrowsWhenGenerationFails() async throws {
        let persistence = InMemoryAgentPersistence()
        let wordID = UUID()
        let sut = AgentSession(
            wordID: wordID,
            persistence: persistence,
            snapshotProvider: StaticSnapshotProvider(),
            generator: RecordingGenerator(error: Failure.stub)
        )

        try sut.reload()

        do {
            try await sut.sendUserMessage("帮我缩短 back")
            XCTFail("Expected error to be thrown")
        } catch {
            XCTAssertTrue(error is Failure)
        }

        // The user message should have been rolled back — no messages remain.
        XCTAssertEqual(sut.messages.count, 0)
    }

    func testSendUserMessageWithAttachmentsDeletesImportedFilesWhenGenerationFails() async throws {
        let persistence = InMemoryAgentPersistence()
        let attachment = AgentAttachment(
            kind: .textFile,
            mimeType: "text/plain",
            fileName: "note.txt",
            relativePath: "agent/session/note.txt",
            byteSize: 5,
            extractedTextPreview: "hello",
            characterCount: 5
        )
        let attachmentStore = InMemoryAgentAttachmentStore(
            dataByRelativePath: ["agent/session/note.txt": Data("hello".utf8)]
        )
        let wordID = UUID()
        let sut = AgentSession(
            wordID: wordID,
            persistence: persistence,
            snapshotProvider: StaticSnapshotProvider(),
            attachmentStore: attachmentStore,
            generator: RecordingGenerator(error: Failure.stub)
        )

        try sut.reload()

        do {
            try await sut.sendUserMessage("read this", attachments: [attachment])
            XCTFail("Expected error to be thrown")
        } catch {
            XCTAssertTrue(error is Failure)
        }

        XCTAssertEqual(sut.messages.count, 0)
        XCTAssertEqual(attachmentStore.deletedAttachments, [attachment])
    }

    func testSendUserMessageRethrowsRollbackDeleteFailure() async throws {
        let persistence = InMemoryAgentPersistence()
        persistence.deleteError = Failure.deleteFailed
        let wordID = UUID()
        let sut = AgentSession(
            wordID: wordID,
            persistence: persistence,
            snapshotProvider: StaticSnapshotProvider(),
            generator: RecordingGenerator(error: Failure.stub)
        )

        try sut.reload()

        do {
            try await sut.sendUserMessage("帮我缩短 back")
            XCTFail("Expected error to be thrown")
        } catch {
            XCTAssertEqual(error as? Failure, .deleteFailed)
        }
    }

    func testStreamingDeltasDoNotAppendAfterGenerationFinishes() async throws {
        let persistence = InMemoryAgentPersistence()
        let wordID = UUID()
        let sut = AgentSession(
            wordID: wordID,
            persistence: persistence,
            snapshotProvider: StaticSnapshotProvider(),
            generator: BurstStreamingGenerator(deltaCount: 200)
        )

        try sut.reload()
        try await sut.sendUserMessage("stream")
        for _ in 0..<10 {
            await Task.yield()
        }

        XCTAssertEqual(sut.streamingText, "")
        XCTAssertEqual(sut.streamingReasoning, "")
    }

    func testInterruptGenerationPersistsVisiblePartialAndIgnoresLateDeltas() async throws {
        let persistence = InMemoryAgentPersistence()
        let generator = ControlledStreamingGenerator(
            initialContent: "partial",
            initialReasoning: "thinking",
            result: GenerateResult(text: "final should not persist", tokensUsed: 8, durationMs: 3)
        )
        let wordID = UUID()
        let sut = AgentSession(
            wordID: wordID,
            persistence: persistence,
            snapshotProvider: StaticSnapshotProvider(),
            generator: generator
        )

        try sut.reload()
        let sendTask = Task {
            try await sut.sendUserMessage("stream")
        }

        while sut.streamingText != "partial" {
            await Task.yield()
        }

        sut.interruptGeneration()
        generator.emitLateDelta(content: " late", reasoning: " late reasoning")
        generator.finish()
        try await sendTask.value
        for _ in 0..<10 {
            await Task.yield()
        }

        XCTAssertFalse(sut.isGenerating)
        XCTAssertEqual(sut.streamingText, "")
        XCTAssertEqual(sut.streamingReasoning, "")
        XCTAssertEqual(sut.messages.count, 2)
        XCTAssertEqual(sut.messages[0].role, .user)
        XCTAssertEqual(sut.messages[1].role, .assistant)
        XCTAssertEqual(sut.messages[1].status, .canceled)
        XCTAssertTrue(sut.messages[1].interrupted)
        XCTAssertEqual(sut.messages[1].content, .text("partial", reasoning: "thinking"))
    }

    func testSendUserMessageExecutesReadToolCallsBeforePersistingAssistantReply() async throws {
        let persistence = InMemoryAgentPersistence()
        let generator = RecordingGenerator(
            results: [
                GenerateResult(
                    text: "",
                    tokensUsed: 12,
                    durationMs: 4,
                    toolCalls: [
                        LLMToolCall(id: "call-1", name: "read_card_snapshot", arguments: .object([:]))
                    ]
                ),
                GenerateResult(
                    text: "这张卡目前只有基础释义，我会先基于现有内容给建议。",
                    tokensUsed: 18,
                    durationMs: 6
                )
            ]
        )
        let wordID = UUID()
        let sut = AgentSession(
            wordID: wordID,
            persistence: persistence,
            snapshotProvider: StaticSnapshotProvider(),
            generator: generator
        )

        try sut.reload()
        try await sut.sendUserMessage("先看看这张卡现在长什么样")

        XCTAssertEqual(generator.calls.count, 2)
        XCTAssertEqual(sut.messages.count, 4)
        XCTAssertEqual(sut.messages[0].role, .user)
        XCTAssertEqual(sut.messages[1].role, .assistant)
        XCTAssertEqual(sut.messages[2].role, .tool)
        XCTAssertEqual(sut.messages[3].role, .assistant)

        guard case .toolCall(let name, _) = sut.messages[1].content else {
            return XCTFail("Expected persisted tool call")
        }
        XCTAssertEqual(name, "read_card_snapshot")

        guard case .toolResult(let resultName, let resultJSON, _) = sut.messages[2].content else {
            return XCTFail("Expected persisted tool result")
        }
        XCTAssertEqual(resultName, "read_card_snapshot")
        XCTAssertTrue(resultJSON.contains(#""word":"apple""#))
        XCTAssertTrue(resultJSON.contains(#""structuredJSON":{"word":"apple"}"#))

        XCTAssertTrue(generator.calls[1].contains { $0.role == .tool && $0.content.contains("read_card_snapshot") })
        XCTAssertTrue(generator.calls[1].contains { $0.content.contains(#""word":"apple""#) })
    }

    func testSendUserMessageInjectsRelatedRecallSnapshotIntoPrompt() async throws {
        let persistence = InMemoryAgentPersistence()
        let generator = RecordingGenerator(
            result: GenerateResult(text: "可以，按 recall 挖空来设计。", tokensUsed: 18, durationMs: 6)
        )
        let wordID = UUID()
        let sut = AgentSession(
            wordID: wordID,
            persistence: persistence,
            snapshotProvider: StaticSnapshotProvider(
                relatedSnapshots: [
                    CardRenderSnapshot(
                        kind: .recall,
                        word: "apple",
                        phonetic: "/ˈæp.əl/",
                        wireframe: "RECALL FRONT\np_rpetual\nRECALL BACK\nperpetual",
                        structuredJSON: #"{"kind":"recall","recall":{"front":"p_rpetual","back":"perpetual"}}"#,
                        aiSectionOrder: []
                    )
                ]
            ),
            generator: generator
        )

        try sut.reload()
        try await sut.sendUserMessage("recall card 的挖空我总记错")

        XCTAssertEqual(generator.calls.count, 1)
        let prompt = generator.calls[0].map(\.content.plainText).joined(separator: "\n")
        XCTAssertTrue(prompt.contains("Related card snapshots"))
        XCTAssertTrue(prompt.contains("p_rpetual"))
        XCTAssertTrue(prompt.contains(#""kind":"recall""#))
    }

    func testSendUserMessagePassesLayoutRequestsToAgentPrompt() async throws {
        let persistence = InMemoryAgentPersistence()
        let generator = RecordingGenerator(
            result: GenerateResult(text: "我不能改布局，但可以调整内容。", tokensUsed: 9, durationMs: 2)
        )
        let wordID = UUID()
        let sut = AgentSession(
            wordID: wordID,
            persistence: persistence,
            snapshotProvider: StaticSnapshotProvider(),
            generator: generator
        )

        try sut.reload()
        try await sut.sendUserMessage("把 pitfalls 挪到 examples 前面")

        XCTAssertEqual(generator.calls.count, 1)
        XCTAssertEqual(sut.messages.count, 2)
        XCTAssertEqual(extractText(from: sut.messages[1].content), "我不能改布局，但可以调整内容。")
    }

    func testSendUserMessageDoesNotTreatClozePositionAsLayoutRequest() async throws {
        let persistence = InMemoryAgentPersistence()
        let generator = RecordingGenerator(
            result: GenerateResult(text: "你说的是 recall 挖空的位置。", tokensUsed: 8, durationMs: 2)
        )
        let wordID = UUID()
        let sut = AgentSession(
            wordID: wordID,
            persistence: persistence,
            snapshotProvider: StaticSnapshotProvider(),
            generator: generator
        )

        try sut.reload()
        try await sut.sendUserMessage("我说的挖空位置")

        XCTAssertEqual(generator.calls.count, 1)
        XCTAssertEqual(sut.messages.count, 2)
        XCTAssertEqual(extractText(from: sut.messages[1].content), "你说的是 recall 挖空的位置。")
    }

    func testSendUserMessagePersistsAssistantTextAndPendingProposalForWriteToolCalls() async throws {
        let persistence = InMemoryAgentPersistence()
        let generator = RecordingGenerator(
            result: GenerateResult(
                text: "第二个例句太泛了，换成商业语境会更利于区分 fruit 和 company。",
                tokensUsed: 24,
                durationMs: 8,
                toolCalls: [
                    LLMToolCall(
                        id: "call-4",
                        name: "propose_example",
                        arguments: .object([
                            "operation": .string("replace"),
                            "targetID": .string("ex-2"),
                            "diffSummary": .string("Replace example #2 with a business example"),
                            "rationale": .string("Current example is too generic"),
                            "payload": .object([
                                "text": .string("Apple stock fell sharply after earnings."),
                                "translation": .string("苹果公司财报后股价大跌。")
                            ])
                        ])
                    )
                ]
            )
        )
        let wordID = UUID()
        var sut: AgentSession!
        persistence.onAddMessage = { message in
            guard case .toolCall = message.content else { return }
            XCTAssertTrue(sut.isGenerating)
            XCTAssertTrue(sut.streamingText.isEmpty)
            XCTAssertTrue(sut.streamingReasoning.isEmpty)
        }
        sut = AgentSession(
            wordID: wordID,
            persistence: persistence,
            snapshotProvider: StaticSnapshotProvider(),
            generator: generator
        )

        try sut.reload()
        try await sut.sendUserMessage("把第二个例句换成商业语境")

        XCTAssertEqual(generator.calls.count, 1)
        XCTAssertEqual(sut.messages.count, 4)
        XCTAssertEqual(sut.pendingProposals.count, 1)

        guard case .text(let assistantText, reasoning: _) = sut.messages[1].content else {
            return XCTFail("Expected assistant rationale text")
        }
        XCTAssertTrue(assistantText.contains("商业语境"))

        guard case .toolCall(let toolName, _) = sut.messages[2].content else {
            return XCTFail("Expected tool call trace")
        }
        XCTAssertEqual(toolName, "propose_example")

        guard case .actionProposal(let proposal) = sut.messages[3].content else {
            return XCTFail("Expected proposal message")
        }
        XCTAssertEqual(proposal.kind, .example)
        XCTAssertEqual(proposal.operation, .replace(targetID: "ex-2"))
        XCTAssertEqual(proposal.decision, .pending)
    }

    func testSendUserMessagePersistsNormalizedProposalToolCall() async throws {
        let persistence = InMemoryAgentPersistence()
        let generator = RecordingGenerator(
            result: GenerateResult(
                text: "",
                tokensUsed: 18,
                durationMs: 6,
                toolCalls: [
                    LLMToolCall(
                        id: "call-add",
                        name: "propose_example",
                        arguments: .object([
                            "operation": .string("add"),
                            "targetID": .string("corpus"),
                            "diffSummary": .string("Add an academic example"),
                            "payload": .object([
                                "text": .string("The corpus reveals regional usage patterns.")
                            ])
                        ])
                    )
                ]
            )
        )
        let sut = AgentSession(
            wordID: UUID(),
            persistence: persistence,
            snapshotProvider: StaticSnapshotProvider(),
            generator: generator
        )

        try sut.reload()
        try await sut.sendUserMessage("添加这个例句")

        XCTAssertEqual(sut.messages.count, 3)
        guard case .toolCall(let toolName, let argsJSON) = sut.messages[1].content else {
            return XCTFail("Expected normalized tool call trace")
        }
        XCTAssertEqual(toolName, "propose_example")
        XCTAssertTrue(argsJSON.contains(#""operation":"add""#))
        XCTAssertFalse(argsJSON.contains("targetID"))

        guard case .actionProposal(let proposal) = sut.messages[2].content else {
            return XCTFail("Expected proposal message")
        }
        XCTAssertEqual(proposal.operation, .add)
    }

    func testClearChatKeepsSessionButRemovesMessages() throws {
        let persistence = InMemoryAgentPersistence()
        let attachmentStore = InMemoryAgentAttachmentStore(dataByRelativePath: [:])
        let wordID = UUID()
        let sessionRecord = try persistence.upsertSession(for: wordID)
        _ = try persistence.addMessage(sessionID: sessionRecord.id, role: .user, content: .text("hello"))

        let sut = AgentSession(
            wordID: wordID,
            persistence: persistence,
            snapshotProvider: StaticSnapshotProvider(),
            attachmentStore: attachmentStore,
            generator: RecordingGenerator(result: .init(text: "unused", tokensUsed: 1, durationMs: 1))
        )
        try sut.reload()

        try sut.clearChat()

        XCTAssertNotNil(sut.sessionRecord)
        XCTAssertTrue(sut.messages.isEmpty)
        XCTAssertEqual(attachmentStore.deletedSessionIDs, [sessionRecord.id])
    }

    func testPreviewOverrideRoundTrips() throws {
        let sut = AgentSession(
            wordID: UUID(),
            persistence: InMemoryAgentPersistence(),
            snapshotProvider: StaticSnapshotProvider(),
            generator: RecordingGenerator(result: .init(text: "unused", tokensUsed: 1, durationMs: 1))
        )
        let override = AIArtifacts(
            pitfalls: .init(
                suggested: [PitfallArtifact(id: "pf-1", text: "Company vs fruit")],
                accepted: nil
            )
        )

        sut.setPreviewOverrideArtifacts(override)
        XCTAssertEqual(sut.previewOverrideArtifacts, override)

        sut.clearPreviewOverride()
        XCTAssertNil(sut.previewOverrideArtifacts)
    }

    func testPreviewProposalProjectsArtifactsIntoOverrideState() throws {
        let persistence = InMemoryAgentPersistence()
        let wordID = UUID()
        let session = try persistence.upsertSession(for: wordID)
        let proposal = ProposalRecord(
            kind: .example,
            operation: .replace(targetID: "ex-2"),
            payloadJSON: #"{"text":"Apple stock fell sharply after earnings.","translation":"苹果公司财报后股价大跌。"}"#,
            diffSummary: "Replace example #2 with a business example"
        )
        _ = try persistence.addMessage(sessionID: session.id, role: .assistant, content: .actionProposal(proposal))
        let artifactsManager = InMemoryArtifactsManager(
            artifactsByWordID: [
                wordID: AIArtifacts(
                    exampleSentences: .init(
                        accepted: [
                            ExampleSentenceArtifact(text: "I ate an apple."),
                            ExampleSentenceArtifact(text: "She packed an apple in his lunch.")
                        ]
                    )
                )
            ]
        )
        let sut = AgentSession(
            wordID: wordID,
            persistence: persistence,
            snapshotProvider: StaticSnapshotProvider(),
            artifactsManager: artifactsManager,
            generator: RecordingGenerator(result: .init(text: "unused", tokensUsed: 1, durationMs: 1))
        )

        try sut.reload()
        try sut.previewProposal(proposal.id)

        XCTAssertEqual(
            sut.previewOverrideArtifacts?.acceptedExampleSentences,
            ["I ate an apple.", "Apple stock fell sharply after earnings."]
        )
        XCTAssertEqual(
            sut.previewOverrideArtifacts?.exampleSentences.accepted?[1].translation,
            "苹果公司财报后股价大跌。"
        )
    }

    func testPreviewProposalReportsReadableErrorForMalformedPayload() throws {
        let persistence = InMemoryAgentPersistence()
        let wordID = UUID()
        let session = try persistence.upsertSession(for: wordID)
        let proposal = ProposalRecord(
            kind: .pitfall,
            operation: .add,
            payloadJSON: #"{}"#,
            diffSummary: "Add a pitfall"
        )
        _ = try persistence.addMessage(sessionID: session.id, role: .assistant, content: .actionProposal(proposal))
        let artifactsManager = InMemoryArtifactsManager(artifactsByWordID: [wordID: AIArtifacts()])
        let sut = AgentSession(
            wordID: wordID,
            persistence: persistence,
            snapshotProvider: StaticSnapshotProvider(),
            artifactsManager: artifactsManager,
            generator: RecordingGenerator(result: .init(text: "unused", tokensUsed: 1, durationMs: 1))
        )

        try sut.reload()

        XCTAssertThrowsError(try sut.previewProposal(proposal.id)) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "Invalid proposal payload: missing required field 'text'."
            )
        }
    }

    func testApplyProposalPersistsArtifactsAndMarksProposalApplied() throws {
        let persistence = InMemoryAgentPersistence()
        let wordID = UUID()
        let session = try persistence.upsertSession(for: wordID)
        let proposal = ProposalRecord(
            kind: .example,
            operation: .replace(targetID: "ex-2"),
            payloadJSON: #"{"text":"Apple stock fell sharply after earnings.","translation":"苹果公司财报后股价大跌。"}"#,
            diffSummary: "Replace example #2 with a business example"
        )
        _ = try persistence.addMessage(sessionID: session.id, role: .assistant, content: .actionProposal(proposal))
        let artifactsManager = InMemoryArtifactsManager(
            artifactsByWordID: [
                wordID: AIArtifacts(
                    exampleSentences: .init(
                        accepted: [
                            ExampleSentenceArtifact(text: "I ate an apple."),
                            ExampleSentenceArtifact(text: "She packed an apple in his lunch.")
                        ]
                    )
                )
            ]
        )
        let sut = AgentSession(
            wordID: wordID,
            persistence: persistence,
            snapshotProvider: StaticSnapshotProvider(),
            artifactsManager: artifactsManager,
            generator: RecordingGenerator(result: .init(text: "unused", tokensUsed: 1, durationMs: 1))
        )

        try sut.reload()
        try sut.applyProposal(proposal.id)

        XCTAssertEqual(sut.pendingProposals.count, 0)
        XCTAssertNil(sut.previewOverrideArtifacts)
        XCTAssertEqual(
            try artifactsManager.loadArtifacts(for: wordID).acceptedExampleSentences,
            ["I ate an apple.", "Apple stock fell sharply after earnings."]
        )
        XCTAssertEqual(
            try artifactsManager.loadArtifacts(for: wordID).exampleSentences.accepted?[1].translation,
            "苹果公司财报后股价大跌。"
        )
        XCTAssertTrue(try artifactsManager.loadArtifacts(for: wordID).suggestedExampleSentences.isEmpty)
        guard case .actionProposal(let applied) = sut.messages[0].content else {
            return XCTFail("Expected proposal message")
        }
        XCTAssertEqual(applied.decision, .applied)
        XCTAssertNotNil(applied.decidedAt)
    }

    func testDismissProposalMarksProposalDismissedWithoutMutatingArtifacts() throws {
        let persistence = InMemoryAgentPersistence()
        let wordID = UUID()
        let session = try persistence.upsertSession(for: wordID)
        let proposal = ProposalRecord(
            kind: .usageCue,
            operation: .replace(targetID: "usage-cue"),
            payloadJSON: #"{"text":"Capital-A Apple is the company."}"#,
            diffSummary: "Replace usage cue"
        )
        _ = try persistence.addMessage(sessionID: session.id, role: .assistant, content: .actionProposal(proposal))
        let artifactsManager = InMemoryArtifactsManager(
            artifactsByWordID: [
                wordID: AIArtifacts(
                    definitionNote: .init(accepted: DefinitionNoteArtifact(text: "Usually the fruit."))
                )
            ]
        )
        let sut = AgentSession(
            wordID: wordID,
            persistence: persistence,
            snapshotProvider: StaticSnapshotProvider(),
            artifactsManager: artifactsManager,
            generator: RecordingGenerator(result: .init(text: "unused", tokensUsed: 1, durationMs: 1))
        )

        try sut.reload()
        try sut.dismissProposal(proposal.id)

        XCTAssertEqual(sut.pendingProposals.count, 0)
        XCTAssertEqual(try artifactsManager.loadArtifacts(for: wordID).acceptedDefinitionNoteText, "Usually the fruit.")
        guard case .actionProposal(let dismissed) = sut.messages[0].content else {
            return XCTFail("Expected proposal message")
        }
        XCTAssertEqual(dismissed.decision, .dismissed)
        XCTAssertNotNil(dismissed.decidedAt)
    }

    func testEditLastUserMessagePreservesOriginalConversationWhenResendFails() async throws {
        let persistence = InMemoryAgentPersistence()
        let wordID = UUID()
        let session = try persistence.upsertSession(for: wordID)
        _ = try persistence.addMessage(sessionID: session.id, role: .user, content: .text("原始问题"))
        _ = try persistence.addMessage(sessionID: session.id, role: .assistant, content: .text("原始回答"))
        let sut = AgentSession(
            wordID: wordID,
            persistence: persistence,
            snapshotProvider: StaticSnapshotProvider(),
            generator: RecordingGenerator(error: Failure.stub)
        )

        try sut.reload()

        do {
            try await sut.editLastUserMessage("编辑后的问题")
            XCTFail("Expected error to be thrown")
        } catch {
            XCTAssertTrue(error is Failure)
        }

        XCTAssertEqual(sut.messages.count, 2)
        XCTAssertEqual(sut.messages.map(\.role), [.user, .assistant])
        XCTAssertEqual(extractText(from: sut.messages[0].content), "原始问题")
        XCTAssertEqual(extractText(from: sut.messages[1].content), "原始回答")
    }

    func testEditLastUserMessagePreservesAttachmentsOnSuccess() async throws {
        let persistence = InMemoryAgentPersistence()
        let wordID = UUID()
        let session = try persistence.upsertSession(for: wordID)
        let attachment = AgentAttachment(
            kind: .image,
            mimeType: "image/png",
            fileName: "card.png",
            relativePath: "agent/session/card.png",
            byteSize: 3,
            width: 20,
            height: 10
        )
        let attachmentStore = InMemoryAgentAttachmentStore(
            dataByRelativePath: ["agent/session/card.png": Data([0x01, 0x02, 0x03])]
        )
        _ = try persistence.addMessage(
            sessionID: session.id,
            role: .user,
            content: .userInput(text: "原始问题", attachments: [attachment])
        )
        _ = try persistence.addMessage(sessionID: session.id, role: .assistant, content: .text("原始回答"))
        let generator = RecordingGenerator(
            result: GenerateResult(text: "编辑后回答", tokensUsed: 4, durationMs: 1)
        )
        let sut = AgentSession(
            wordID: wordID,
            persistence: persistence,
            snapshotProvider: StaticSnapshotProvider(),
            attachmentStore: attachmentStore,
            generator: generator
        )

        try sut.reload()
        try await sut.editLastUserMessage("编辑后的问题")

        XCTAssertEqual(sut.messages.count, 2)
        guard case .userInput(let text, let attachments) = sut.messages[0].content else {
            return XCTFail("Expected edited user input to keep attachments")
        }
        XCTAssertEqual(text, "编辑后的问题")
        XCTAssertEqual(attachments, [attachment])
        XCTAssertTrue(generator.calls[0].contains { message in
            message.content.parts.contains(.imageURL("data:image/png;base64,AQID"))
        })
        XCTAssertTrue(attachmentStore.deletedAttachments.isEmpty)
    }

    func testEditLastUserMessageDoesNotDeleteExistingAttachmentsWhenResendFails() async throws {
        let persistence = InMemoryAgentPersistence()
        let wordID = UUID()
        let session = try persistence.upsertSession(for: wordID)
        let attachment = AgentAttachment(
            kind: .image,
            mimeType: "image/png",
            fileName: "card.png",
            relativePath: "agent/session/card.png",
            byteSize: 3,
            width: 20,
            height: 10
        )
        let attachmentStore = InMemoryAgentAttachmentStore(
            dataByRelativePath: ["agent/session/card.png": Data([0x01, 0x02, 0x03])]
        )
        _ = try persistence.addMessage(
            sessionID: session.id,
            role: .user,
            content: .userInput(text: "原始问题", attachments: [attachment])
        )
        _ = try persistence.addMessage(sessionID: session.id, role: .assistant, content: .text("原始回答"))
        let sut = AgentSession(
            wordID: wordID,
            persistence: persistence,
            snapshotProvider: StaticSnapshotProvider(),
            attachmentStore: attachmentStore,
            generator: RecordingGenerator(error: Failure.stub)
        )

        try sut.reload()

        do {
            try await sut.editLastUserMessage("编辑后的问题")
            XCTFail("Expected error to be thrown")
        } catch {
            XCTAssertTrue(error is Failure)
        }

        XCTAssertEqual(sut.messages.count, 2)
        guard case .userInput(let text, let attachments) = sut.messages[0].content else {
            return XCTFail("Expected original user input")
        }
        XCTAssertEqual(text, "原始问题")
        XCTAssertEqual(attachments, [attachment])
        XCTAssertTrue(attachmentStore.deletedAttachments.isEmpty)
    }

    func testRegenerateLastResponsePreservesOriginalAssistantMessageWhenRetryFails() async throws {
        let persistence = InMemoryAgentPersistence()
        let wordID = UUID()
        let session = try persistence.upsertSession(for: wordID)
        _ = try persistence.addMessage(sessionID: session.id, role: .user, content: .text("原始问题"))
        _ = try persistence.addMessage(sessionID: session.id, role: .assistant, content: .text("原始回答"))
        let sut = AgentSession(
            wordID: wordID,
            persistence: persistence,
            snapshotProvider: StaticSnapshotProvider(),
            generator: RecordingGenerator(error: Failure.stub)
        )

        try sut.reload()

        do {
            try await sut.regenerateLastResponse()
            XCTFail("Expected error to be thrown")
        } catch {
            XCTAssertTrue(error is Failure)
        }

        XCTAssertEqual(sut.messages.count, 2)
        XCTAssertEqual(sut.messages.map(\.role), [.user, .assistant])
        XCTAssertEqual(extractText(from: sut.messages[1].content), "原始回答")
    }
}

private func extractText(from content: MessageContent) -> String? {
    guard case .text(let text, reasoning: _) = content else {
        return nil
    }
    return text
}

private struct StaticSnapshotProvider: AgentCardSnapshotProviding {
    var relatedSnapshots: [CardRenderSnapshot] = []

    func snapshot(for wordID: UUID) throws -> CardRenderSnapshot {
        CardRenderSnapshot(
            kind: .standard,
            word: "apple",
            phonetic: "/ˈæp.əl/",
            wireframe: """
            ┌─────────── FRONT ──────────────────────────────┐
            │ apple                                         │
            └───────────────────────────────────────────────┘
            """,
            structuredJSON: #"{"word":"apple"}"#,
            aiSectionOrder: []
        )
    }

    func relatedSnapshots(for wordID: UUID) throws -> [CardRenderSnapshot] {
        relatedSnapshots
    }
}

private final class RecordingGenerator: AgentGenerating {
    let result: GenerateResult?
    let results: [GenerateResult]
    let error: Error?
    private(set) var calls: [[LLMMessage]] = []
    private var nextResultIndex = 0

    init(result: GenerateResult? = nil, results: [GenerateResult] = [], error: Error? = nil) {
        self.result = result
        self.results = results
        self.error = error
    }

    func generate(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]
    ) async throws -> GenerateResult {
        calls.append(messages)
        if let error {
            throw error
        }
        if nextResultIndex < results.count {
            defer { nextResultIndex += 1 }
            return results[nextResultIndex]
        }
        return result ?? GenerateResult(text: "", tokensUsed: 0, durationMs: 0)
    }
}

private final class BurstStreamingGenerator: AgentGenerating {
    let deltaCount: Int

    init(deltaCount: Int) {
        self.deltaCount = deltaCount
    }

    func generate(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]
    ) async throws -> GenerateResult {
        GenerateResult(text: "done", tokensUsed: 1, durationMs: 1)
    }

    func generateStreaming(
        messages: [LLMMessage],
        tools: [LLMToolDefinition],
        onDelta: @escaping @Sendable (String) -> Void,
        onReasoningDelta: @escaping @Sendable (String) -> Void
    ) async throws -> GenerateResult {
        for _ in 0..<deltaCount {
            onDelta("x")
            onReasoningDelta("r")
        }
        return GenerateResult(text: "done", tokensUsed: 1, durationMs: 1)
    }
}

private final class ControlledStreamingGenerator: AgentGenerating, @unchecked Sendable {
    private let initialContent: String
    private let initialReasoning: String
    private let result: GenerateResult
    private var continuation: CheckedContinuation<GenerateResult, Never>?
    private var onDelta: (@Sendable (String) -> Void)?
    private var onReasoningDelta: (@Sendable (String) -> Void)?

    init(initialContent: String, initialReasoning: String, result: GenerateResult) {
        self.initialContent = initialContent
        self.initialReasoning = initialReasoning
        self.result = result
    }

    func generate(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]
    ) async throws -> GenerateResult {
        result
    }

    func generateStreaming(
        messages: [LLMMessage],
        tools: [LLMToolDefinition],
        onDelta: @escaping @Sendable (String) -> Void,
        onReasoningDelta: @escaping @Sendable (String) -> Void
    ) async throws -> GenerateResult {
        self.onDelta = onDelta
        self.onReasoningDelta = onReasoningDelta

        onDelta(initialContent)
        onReasoningDelta(initialReasoning)

        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func emitLateDelta(content: String, reasoning: String) {
        let onDelta = self.onDelta
        let onReasoningDelta = self.onReasoningDelta

        onDelta?(content)
        onReasoningDelta?(reasoning)
    }

    func finish() {
        let continuation = self.continuation
        self.continuation = nil

        continuation?.resume(returning: result)
    }
}

private final class InMemoryAgentPersistence: AgentSessionPersisting {
    private(set) var sessionsByWordID: [UUID: AgentChatSession] = [:]
    private(set) var messagesBySessionID: [UUID: [AgentChatMessage]] = [:]
    var onAddMessage: ((AgentChatMessage) -> Void)?
    var deleteError: Error?

    func upsertSession(for wordID: UUID, preferences: AgentSessionPreferences) throws -> AgentChatSession {
        if var existing = sessionsByWordID[wordID] {
            existing.preferences = preferences
            existing.updatedAt = Date()
            sessionsByWordID[wordID] = existing
            return existing
        }

        let created = AgentChatSession(wordItemID: wordID, preferences: preferences)
        sessionsByWordID[wordID] = created
        return created
    }

    func session(for wordID: UUID) throws -> AgentChatSession? {
        sessionsByWordID[wordID]
    }

    func loadMessages(sessionID: UUID) throws -> [AgentChatMessage] {
        messagesBySessionID[sessionID] ?? []
    }

    func addMessage(
        sessionID: UUID,
        role: AgentChatMessage.Role,
        status: AgentChatMessage.Status,
        content: MessageContent,
        createdAt: Date,
        supersededBy: UUID?,
        interrupted: Bool
    ) throws -> AgentChatMessage {
        let ordinal = (messagesBySessionID[sessionID]?.last?.ordinal ?? 0) + 1
        let message = AgentChatMessage(
            sessionID: sessionID,
            ordinal: ordinal,
            role: role,
            createdAt: createdAt,
            status: status,
            content: content,
            supersededBy: supersededBy,
            interrupted: interrupted
        )
        messagesBySessionID[sessionID, default: []].append(message)
        onAddMessage?(message)
        return message
    }

    func deleteMessages(ids: [UUID]) throws {
        if let deleteError {
            throw deleteError
        }
        for (sessionID, messages) in messagesBySessionID {
            messagesBySessionID[sessionID] = messages.filter { !ids.contains($0.id) }
        }
    }

    func clearMessages(sessionID: UUID) throws {
        messagesBySessionID[sessionID] = []
    }

    func resetSession(for wordID: UUID) throws {
        guard let session = sessionsByWordID.removeValue(forKey: wordID) else { return }
        messagesBySessionID.removeValue(forKey: session.id)
    }

    func updateProposal(messageID: UUID, proposal: ProposalRecord) throws -> AgentChatMessage {
        for (sessionID, messages) in messagesBySessionID {
            guard let index = messages.firstIndex(where: { $0.id == messageID }) else { continue }
            let original = messages[index]
            let updated = AgentChatMessage(
                id: original.id,
                sessionID: original.sessionID,
                ordinal: original.ordinal,
                role: original.role,
                createdAt: original.createdAt,
                status: original.status,
                content: .actionProposal(proposal),
                supersededBy: original.supersededBy,
                interrupted: original.interrupted
            )
            messagesBySessionID[sessionID]?[index] = updated
            return updated
        }
        throw Failure.stub
    }
}

private final class InMemoryAgentAttachmentStore: AgentAttachmentStoring, @unchecked Sendable {
    var dataByRelativePath: [String: Data]
    private(set) var deletedAttachments: [AgentAttachment] = []
    private(set) var deletedSessionIDs: [UUID] = []

    init(dataByRelativePath: [String: Data]) {
        self.dataByRelativePath = dataByRelativePath
    }

    func data(for attachment: AgentAttachment) throws -> Data {
        guard let data = dataByRelativePath[attachment.relativePath] else {
            throw Failure.stub
        }
        return data
    }

    func delete(_ attachments: [AgentAttachment]) throws {
        deletedAttachments.append(contentsOf: attachments)
    }

    func deleteAllAttachments(for sessionID: UUID) throws {
        deletedSessionIDs.append(sessionID)
    }
}

private final class InMemoryArtifactsManager: AgentArtifactsManaging {
    var artifactsByWordID: [UUID: AIArtifacts]

    init(artifactsByWordID: [UUID: AIArtifacts] = [:]) {
        self.artifactsByWordID = artifactsByWordID
    }

    func loadArtifacts(for wordID: UUID) throws -> AIArtifacts {
        artifactsByWordID[wordID] ?? .empty
    }

    func saveArtifacts(_ artifacts: AIArtifacts, for wordID: UUID) throws {
        artifactsByWordID[wordID] = artifacts
    }
}

private enum Failure: LocalizedError {
    case stub
    case deleteFailed

    var errorDescription: String? {
        switch self {
        case .stub:
            return "stub failure"
        case .deleteFailed:
            return "delete failure"
        }
    }
}
