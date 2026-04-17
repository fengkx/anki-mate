import Foundation

struct CollectionEditorFormData: Equatable, Sendable {
    var collectionName: String
    var deckDescription: String
    var dictionaryName: String

    init(collectionName: String, deckDescription: String, dictionaryName: String) {
        self.collectionName = collectionName
        self.deckDescription = deckDescription
        self.dictionaryName = dictionaryName
    }

    static func defaults(forCollectionName name: String) -> CollectionEditorFormData {
        CollectionEditorFormData(
            collectionName: name,
            deckDescription: "",
            dictionaryName: ""
        )
    }

    var exportSettings: CollectionExportSettings {
        CollectionExportSettings(
            deckName: collectionName,
            deckDescription: deckDescription
        )
    }
}

struct CollectionExportRequest: Equatable, Sendable {
    let collectionID: UUID
    var deckDescription: String
}
