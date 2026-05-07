import Foundation

enum CommandPaletteMode: Equatable {
    case words
    case commands
    case collections
}

enum CommandPaletteSection: String, CaseIterable, Equatable {
    case recentWords = "Recent Words"
    case words = "Words"
    case actions = "Actions"
    case commands = "Commands"
    case collections = "Collections"
    case status = "Status"
}

enum WordAddValidationResult: Equatable {
    case duplicateExistingWord(existingWordID: UUID?)
    case dictionaryMatch(canonicalWord: String?, definition: String?)
    case notFound
    case failed(String)
}

enum LookupValidationState: Equatable {
    case idle
    case checking(query: String)
    case result(query: String, outcome: WordAddValidationResult)
}

struct CommandPaletteWordItem: Identifiable, Equatable {
    let wordID: UUID
    let title: String
    let subtitle: String?
    let trailingText: String?
    let isRecent: Bool

    var id: UUID { wordID }
}

struct CommandPaletteAddWordItem: Identifiable, Equatable {
    let query: String
    let canonicalWord: String?
    let definition: String?

    var id: String {
        "add-word:\(query.lowercased())"
    }
}

enum CommandPaletteAddWordPreviewStatus: Equatable {
    case checking
    case readyToAdd
    case duplicateExistingWord
    case notFound
    case failed
}

struct CommandPaletteAddWordPreview: Equatable {
    let status: CommandPaletteAddWordPreviewStatus
    let query: String
    let canonicalWord: String?
    let definition: String?
    let message: String

    var isAddable: Bool {
        status == .readyToAdd
    }
}

struct CommandPaletteCommandItem: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String
    let systemImage: String
    let keywords: [String]
}

struct CommandPaletteCollectionItem: Identifiable, Equatable {
    let collectionID: UUID
    let title: String
    let subtitle: String?

    var id: UUID { collectionID }
}

struct CommandPaletteInfoItem: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String?
    let systemImage: String
}

enum CommandPaletteItem: Identifiable, Equatable {
    case word(CommandPaletteWordItem)
    case addWord(CommandPaletteAddWordItem)
    case command(CommandPaletteCommandItem)
    case collection(CommandPaletteCollectionItem)
    case info(CommandPaletteInfoItem)

    var id: String {
        switch self {
        case .word(let item):
            return "word:\(item.id.uuidString)"
        case .addWord(let item):
            return item.id
        case .command(let item):
            return "command:\(item.id)"
        case .collection(let item):
            return "collection:\(item.id.uuidString)"
        case .info(let item):
            return "info:\(item.id)"
        }
    }

    var section: CommandPaletteSection {
        switch self {
        case .word(let item):
            return item.isRecent ? .recentWords : .words
        case .addWord:
            return .actions
        case .command:
            return .commands
        case .collection:
            return .collections
        case .info:
            return .status
        }
    }

    var title: String {
        switch self {
        case .word(let item):
            return item.title
        case .addWord(let item):
            return "Add \"\(item.query)\" to current collection"
        case .command(let item):
            return item.title
        case .collection(let item):
            return item.title
        case .info(let item):
            return item.title
        }
    }

    var subtitle: String? {
        switch self {
        case .word(let item):
            return item.subtitle
        case .addWord(let item):
            if let canonicalWord = item.canonicalWord, canonicalWord.caseInsensitiveCompare(item.query) != .orderedSame {
                return "Will be resolved via dictionary as \(canonicalWord)"
            }
            return item.definition ?? "Will be resolved via dictionary"
        case .command(let item):
            return item.subtitle
        case .collection(let item):
            return item.subtitle
        case .info(let item):
            return item.subtitle
        }
    }

    var systemImage: String {
        switch self {
        case .word:
            return "text.book.closed"
        case .addWord:
            return "plus.circle"
        case .command(let item):
            return item.systemImage
        case .collection:
            return "books.vertical"
        case .info(let item):
            return item.systemImage
        }
    }

    var trailingText: String? {
        switch self {
        case .word(let item):
            return item.trailingText
        case .command:
            return "Command"
        case .addWord:
            return "Add"
        case .collection:
            return nil
        case .info:
            return nil
        }
    }

    var isSelectable: Bool {
        switch self {
        case .info:
            return false
        case .word, .addWord, .command, .collection:
            return true
        }
    }
}
