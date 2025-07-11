import AVFoundation

class Node : Codable {
    let url: URL?
    let name: String
    let trackNumber: Int?
    let discNumber: Int?
    private(set) var active: Bool = false
    private(set) var nodes: [Node]

    init(name str: String, url: URL? = nil, trackNumber: Int? = nil, discNumber: Int? = nil) {
        self.url = url
        self.name = str
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.nodes = []
    }

    func add(_ node: Node) {self.nodes.append(node)}

    func sort() {
        self.nodes.sort {
            let left = ($0.discNumber ?? Int.max, $0.trackNumber ?? Int.max, $0.name.lowercased())
            let right = ($1.discNumber ?? Int.max, $1.trackNumber ?? Int.max, $1.name.lowercased())
            return left < right
        }
    }

    func toggleActive() {active = !active}

    func traverse() {
        var nodeStack: [(node: Node, depth: Int)] = [(self, 0)]

        while let (node, depth) = nodeStack.popLast() {

            print(String(repeating: " ", count: depth), node.name)
            for i in stride(from: node.nodes.count-1, through: 0, by: -1) {
                nodeStack.append((node.nodes[i], depth+1))
            }

        }

    }

    enum CodingKeys: String, CodingKey {
        case name
        case url
        case nodes
        case trackNumber
        case discNumber
    }
}

func scanFiles() -> Node {

    let fileManager = FileManager.default
    guard let DownloadsURL: URL = fileManager.urls(for:.downloadsDirectory, in:.userDomainMask).first else {exit(1)}

    var isDirectory: ObjCBool = false
    let musicFolderURL: URL = DownloadsURL
        .appending(component: "Music", directoryHint: .isDirectory)
        .appending(component: "Downloads", directoryHint: .isDirectory)

    if fileManager.fileExists(atPath: musicFolderURL.path(), isDirectory: &isDirectory) && isDirectory.boolValue {

        let rootNode = Node(name: "All Music")

        var folderStack: [URL] = [musicFolderURL]

        do {
            var fileCount: Int = 0
            var filesSkipped: Int = 0

            print("Files Loaded  :\nFiles Skipped :", terminator: "\u{001B}[1F")

            while !folderStack.isEmpty {
                let folder: URL = folderStack.popLast()!

                let fileURLS: [URL] = try fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])

                for url: URL in fileURLS {
                    if (try url.resourceValues(forKeys: [.isDirectoryKey])).isDirectory! {
                        folderStack.append(url)

                    } else if url.pathExtension == "mp3" {
                        let asset = AVURLAsset(url: url)
                        let semaphore = DispatchSemaphore(value: 0)

                        var fileSkipped: Bool = true

                        var artistValue : String?
                        var albumValue  : String?
                        var titleValue  : String?
                        var trackNumber : Int?
                        var discNumber  : Int?

                        Task {
                            for format in try await asset.load(.availableMetadataFormats) {
                                let metadata = try await asset.loadMetadata(for: format)

                                guard let artistMetadata    = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .id3MetadataBand).first ??
                                                              AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierArtist).first else {continue}
                                guard let albumMetadata     = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierAlbumName).first else {continue}
                                guard let titleMetadata     = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierTitle).first else {continue}
                                guard let trackNumMetadata  = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .id3MetadataTrackNumber).first else {continue}


                                fileSkipped = false

                                artistValue = try await artistMetadata.load(.stringValue)!
                                albumValue  = try await albumMetadata.load(.stringValue)!
                                titleValue  = try await titleMetadata.load(.stringValue)!

                                let trackNumString = try await trackNumMetadata.load(.stringValue)!
                                trackNumber = Int(trackNumString.split(separator: "/", maxSplits: 2, omittingEmptySubsequences: true)[0])!

                                if let discNumMetaData = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .id3MetadataPartOfASet).first {
                                    let discNumberString = try await discNumMetaData.load(.stringValue)!
                                    discNumber = Int(discNumberString.split(separator: "/", maxSplits: 2, omittingEmptySubsequences: true)[0])!
                                }

                            }
                            semaphore.signal()
                        }
                        semaphore.wait()

                        if !fileSkipped {

                            let artistNode: Node
                            if let nodeIndex = rootNode.nodes.firstIndex(where: {$0.name == artistValue!}) {
                                artistNode = rootNode.nodes[nodeIndex]
                            } else {
                                artistNode = Node(name: artistValue!)
                                rootNode.add(artistNode)
                            }

                            let albumNode: Node
                            if let nodeIndex = artistNode.nodes.firstIndex(where: {$0.name == albumValue!}) {
                                albumNode = artistNode.nodes[nodeIndex]
                            } else {
                                albumNode = Node(name: albumValue!)
                                artistNode.add(albumNode)
                            }

                            let trackNode: Node = Node(name: titleValue!, url: url, trackNumber: trackNumber, discNumber: discNumber)
                            albumNode.add(trackNode)

                            fileCount += 1
                            print("\u{001B}[16C\(fileCount)", terminator: "\r")
                        } else {
                            filesSkipped += 1
                            print("\u{001B}[1B\u{001B}[16C\(filesSkipped)", terminator: "\u{001B}[1F")
                        }
                        fflush(stdout)

                    }
                }
            }

            print("\u{001B}[1B")
 
            // Deeply sort node
            var nodeStack: [Node] = [rootNode]
            nodeStack.reserveCapacity(fileCount)
            while let node = nodeStack.popLast() {
                node.sort()
                nodeStack.append(contentsOf: node.nodes)
            }

            return rootNode
        } catch {
            exit(1)
        }
    }
    exit(1)
}

func encode(root: Node) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    do {
        let data = try encoder.encode(root)
        try data.write(to: URL(filePath: "Tests/url_serialization/files.json"))
    } catch  {
        exit(1)
    }
}

func decode() -> Node {
    let decoder = JSONDecoder()
    do {
        let data = try Data(contentsOf: URL(filePath: "Tests/url_serialization/files.json"))
        let root = try decoder.decode(Node.self, from: data)

        return root
    } catch  {
        exit(1)
    }
}

let root = decode()
root.traverse()


// let root = scanFiles()

// let TestNode = Node(name: "ABC",trackNumber: 1, discNumber: 1)
// encode(root: root)