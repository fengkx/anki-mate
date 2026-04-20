import DictKitAnkiExport
import Foundation

public protocol AgentArtifactsManaging {
    func loadArtifacts(for wordID: UUID) throws -> AIArtifacts
    func saveArtifacts(_ artifacts: AIArtifacts, for wordID: UUID) throws
}

enum AgentProposalArtifactsProjector {
    enum Mode {
        case preview
        case persist
    }

    static func project(
        proposal: ProposalRecord,
        onto artifacts: AIArtifacts,
        mode: Mode
    ) throws -> AIArtifacts {
        var updated = artifacts.normalized()

        switch proposal.kind {
        case .usageCue:
            let payload = try decodePayload(DefinitionNoteArtifact.self, from: proposal.payloadJSON)
            applyDefinitionNote(payload, operation: proposal.operation, to: &updated, mode: mode)
        case .example:
            let payload = try decodePayload(ExampleSentenceArtifact.self, from: proposal.payloadJSON)
            applyExample(payload, operation: proposal.operation, to: &updated, mode: mode)
        case .recallDraft:
            let payload = try decodePayload(RecallCardDraft.self, from: proposal.payloadJSON)
            applyRecallDraft(payload, operation: proposal.operation, to: &updated, mode: mode)
        case .pitfall:
            let payload = try decodePayload(PitfallArtifact.self, from: proposal.payloadJSON)
            applyPitfall(payload, operation: proposal.operation, to: &updated, mode: mode)
        case .mnemonic:
            let payload = try decodePayload(MnemonicArtifact.self, from: proposal.payloadJSON)
            applyMnemonic(payload, operation: proposal.operation, to: &updated, mode: mode)
        case .collocation:
            let payload = try decodePayload(CollocationArtifact.self, from: proposal.payloadJSON)
            applyCollocation(payload, operation: proposal.operation, to: &updated, mode: mode)
        case .deleteAccepted:
            let payload = try decodePayload(DeleteAcceptedPayload.self, from: proposal.payloadJSON)
            try applyDeleteAccepted(payload, operation: proposal.operation, to: &updated)
        }

        return updated.normalized()
    }

    private static func applyDefinitionNote(
        _ artifact: DefinitionNoteArtifact,
        operation: ProposalRecord.Operation,
        to artifacts: inout AIArtifacts,
        mode: Mode
    ) {
        let value: DefinitionNoteArtifact? = switch operation {
        case .delete:
            nil
        case .add, .replace:
            artifact
        }
        switch mode {
        case .persist:
            artifacts.definitionNote.suggested = value
        case .preview:
            artifacts.definitionNote.accepted = value
        }
    }

    private static func applyRecallDraft(
        _ artifact: RecallCardDraft,
        operation: ProposalRecord.Operation,
        to artifacts: inout AIArtifacts,
        mode: Mode
    ) {
        let value: [RecallCardDraft]? = switch operation {
        case .delete:
            nil
        case .add, .replace:
            [artifact]
        }
        switch mode {
        case .persist:
            artifacts.recallCardDrafts.suggested = value
        case .preview:
            artifacts.recallCardDrafts.accepted = value
        }
    }

    private static func applyPitfall(
        _ artifact: PitfallArtifact,
        operation: ProposalRecord.Operation,
        to artifacts: inout AIArtifacts,
        mode: Mode
    ) {
        var values = artifactBase(from: artifacts.pitfalls, mode: mode)
        let targetIndex = collectionTargetIndex(operation: operation, prefix: "pf-", ids: values.map(\.id))
        mutateCollection(&values, operation: operation, targetIndex: targetIndex, replacement: artifact)
        assign(values, to: &artifacts.pitfalls, mode: mode)
    }

    private static func applyMnemonic(
        _ artifact: MnemonicArtifact,
        operation: ProposalRecord.Operation,
        to artifacts: inout AIArtifacts,
        mode: Mode
    ) {
        var values = artifactBase(from: artifacts.mnemonics, mode: mode)
        let targetIndex = collectionTargetIndex(operation: operation, prefix: "mn-", ids: values.map(\.id))
        mutateCollection(&values, operation: operation, targetIndex: targetIndex, replacement: artifact)
        assign(values, to: &artifacts.mnemonics, mode: mode)
    }

    private static func applyCollocation(
        _ artifact: CollocationArtifact,
        operation: ProposalRecord.Operation,
        to artifacts: inout AIArtifacts,
        mode: Mode
    ) {
        var values = artifactBase(from: artifacts.collocations, mode: mode)
        let targetIndex = collectionTargetIndex(operation: operation, prefix: "co-", ids: values.map(\.id))
        mutateCollection(&values, operation: operation, targetIndex: targetIndex, replacement: artifact)
        assign(values, to: &artifacts.collocations, mode: mode)
    }

    private static func applyDeleteAccepted(
        _ payload: DeleteAcceptedPayload,
        operation: ProposalRecord.Operation,
        to artifacts: inout AIArtifacts
    ) throws {
        guard case .delete(let targetID) = operation else {
            throw AgentProposalArtifactsError.invalidDeleteOperation
        }
        switch payload.section {
        case .usageCue:
            artifacts.definitionNote.accepted = nil
        case .example:
            var values = artifacts.exampleSentences.accepted ?? []
            removeTarget(&values, targetIndex: resolveSyntheticIndex(targetID, prefix: "ex-"))
            artifacts.exampleSentences.accepted = values.nilIfEmpty
        case .recallDraft:
            artifacts.recallCardDrafts.accepted = nil
        case .pitfall:
            var values = artifacts.pitfalls.accepted ?? []
            removeTarget(&values, targetIndex: resolveArtifactIndex(targetID, prefix: "pf-", values: values.map(\.id)))
            artifacts.pitfalls.accepted = values.nilIfEmpty
        case .mnemonic:
            var values = artifacts.mnemonics.accepted ?? []
            removeTarget(&values, targetIndex: resolveArtifactIndex(targetID, prefix: "mn-", values: values.map(\.id)))
            artifacts.mnemonics.accepted = values.nilIfEmpty
        case .collocation:
            var values = artifacts.collocations.accepted ?? []
            removeTarget(&values, targetIndex: resolveArtifactIndex(targetID, prefix: "co-", values: values.map(\.id)))
            artifacts.collocations.accepted = values.nilIfEmpty
        }
    }

    private static func mutateCollection<Value>(
        _ values: inout [Value],
        operation: ProposalRecord.Operation,
        targetIndex: Int?,
        replacement: Value
    ) {
        switch operation {
        case .add:
            values.append(replacement)
        case .replace:
            if let targetIndex, values.indices.contains(targetIndex) {
                values[targetIndex] = replacement
            } else {
                values.append(replacement)
            }
        case .delete:
            removeTarget(&values, targetIndex: targetIndex)
        }
    }

    private static func collectionTargetIndex(
        operation: ProposalRecord.Operation,
        prefix: String,
        ids: [String?]
    ) -> Int? {
        switch operation {
        case .add:
            return nil
        case .replace(let targetID), .delete(let targetID):
            return resolveArtifactIndex(targetID, prefix: prefix, values: ids)
        }
    }

    private static func removeTarget<Value>(
        _ values: inout [Value],
        targetIndex: Int?
    ) {
        guard let targetIndex, values.indices.contains(targetIndex) else {
            return
        }
        values.remove(at: targetIndex)
    }

    private static func applyExample(
        _ artifact: ExampleSentenceArtifact,
        operation: ProposalRecord.Operation,
        to artifacts: inout AIArtifacts,
        mode: Mode
    ) {
        var values = exampleBase(from: artifacts, mode: mode)
        let targetIndex: Int?
        switch operation {
        case .add:
            targetIndex = nil
        case .replace(let targetID), .delete(let targetID):
            targetIndex = resolveSyntheticIndex(targetID, prefix: "ex-")
        }
        mutateCollection(&values, operation: operation, targetIndex: targetIndex, replacement: artifact)
        assign(values, to: &artifacts.exampleSentences, mode: mode)
    }

    private static func exampleBase(from artifacts: AIArtifacts, mode: Mode) -> [ExampleSentenceArtifact] {
        switch mode {
        case .persist:
            return artifacts.exampleSentences.suggested ?? artifacts.exampleSentences.accepted ?? []
        case .preview:
            return artifacts.exampleSentences.accepted ?? artifacts.exampleSentences.suggested ?? []
        }
    }

    private static func artifactBase<Value>(
        from slot: AIArtifactSlot<[Value]>,
        mode: Mode
    ) -> [Value] where Value: Codable & Equatable & Sendable {
        switch mode {
        case .persist:
            return slot.suggested ?? slot.accepted ?? []
        case .preview:
            return slot.accepted ?? slot.suggested ?? []
        }
    }

    private static func assign<Value>(
        _ values: [Value],
        to slot: inout AIArtifactSlot<[Value]>,
        mode: Mode
    ) where Value: Codable & Equatable & Sendable {
        switch mode {
        case .persist:
            slot.suggested = values.nilIfEmpty
        case .preview:
            slot.accepted = values.nilIfEmpty
        }
    }

    private static func resolveSyntheticIndex(_ targetID: String, prefix: String) -> Int? {
        guard targetID.hasPrefix(prefix),
              let rawIndex = Int(targetID.dropFirst(prefix.count)),
              rawIndex > 0 else {
            return nil
        }
        return rawIndex - 1
    }

    private static func resolveArtifactIndex(
        _ targetID: String,
        prefix: String,
        values: [String?]
    ) -> Int? {
        if let index = values.firstIndex(where: { $0 == targetID }) {
            return index
        }
        return resolveSyntheticIndex(targetID, prefix: prefix)
    }

    private static func decodePayload<T: Decodable>(
        _ type: T.Type,
        from payloadJSON: String
    ) throws -> T {
        guard let data = payloadJSON.data(using: .utf8) else {
            throw AgentProposalArtifactsError.invalidPayload
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

enum AgentProposalArtifactsError: LocalizedError {
    case invalidPayload
    case invalidDeleteOperation

    var errorDescription: String? {
        switch self {
        case .invalidPayload:
            return "Invalid proposal payload."
        case .invalidDeleteOperation:
            return "Delete-accepted proposals must use delete operations."
        }
    }
}

private struct DeleteAcceptedPayload: Decodable {
    let section: Section

    enum Section: String, Decodable {
        case usageCue = "usage_cue"
        case example
        case recallDraft = "recall_draft"
        case pitfall
        case mnemonic
        case collocation
    }
}

private extension Array {
    var nilIfEmpty: Self? { isEmpty ? nil : self }
}
