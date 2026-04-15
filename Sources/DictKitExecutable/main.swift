import DictKitCLI

if #available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *) {
    DictKitCommand.main()
} else {
    fatalError("dictkit requires macOS 10.15 or newer")
}
