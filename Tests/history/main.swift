import AVFoundation
import SQLite
import CryptoKit
import CommonCrypto

/*
HASH FILES
GET DATETIME
SETUP SQL
*/

/* history
    PRIMARY KEY history_id INTEGER
    FOREIGN KEY file_hash TEXT
    date TEXT
*/

/* files
    PRIMARY KEY file_hash TEXT
    artist_name TEXT
    album_name TEXT
    track_name TEXT
*/

let TEST_DB   = "Tests/history/TestDB.sqlite3"
let TEST_FILE = URL(filePath: "")


/* 
Different methods of hasing here

1. Hash the entire content of the file
2. Hash only the first 128kb of the file
3. Hashing the values of the metadata

*/

func hashFile(file url: URL) -> String {
    do {
        let fileHandle = try FileHandle(forReadingFrom: url)
        defer {try? fileHandle.close()}

        var sha256Hasher = SHA256()

        // while true {
        //     if let dataPortion: Data = try fileHandle.read(upToCount: 1024*1024)/*1MB*/{
        //         if dataPortion.isEmpty {break}
        //         sha256Hasher.update(data: dataPortion)
        //     } else {break}
        // }

        if let dataPortion = try fileHandle.read(upToCount: 128 * 1024) {
            if dataPortion.isEmpty {return ""}
            sha256Hasher.update(data: dataPortion)
        }

        let digest: SHA256.Digest = sha256Hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()

    } catch  {
        print(error)
        exit(1)
    }
}

func hashfile2(artist: String, album: String, track: String, track_num: Int) -> String {
    let s = "\(artist.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))|" +
            "\(album.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)))|" +
            "\(track.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)))|" +
            "\(track_num)"
    let d = Data(s.utf8)

    let digest = SHA256.hash(data: d)
    return digest.map { String(format: "%02x", $0) }.joined()
}


/// Format: MM:DD:YYThh:mm:ss±hh:mm
func getDateTime() -> String {
    let timeFormatter = ISO8601DateFormatter()
    timeFormatter.timeZone = TimeZone.current
    return timeFormatter.string(from: Date())
}

func setupDB() {
    do {
        let db = try Connection(TEST_DB)
        let files = Table("files")
        let history = Table("history")

        let file_hash = SQLite.Expression<String>("file_hash")

        let artist_name = SQLite.Expression<String>("artist_name")
        let album_name = SQLite.Expression<String>("album_name")
        let track_name = SQLite.Expression<String>("track_name")

        let history_id = SQLite.Expression<Int>("history_id")
        let date = SQLite.Expression<String>("date")

        try db.run(files.create(ifNotExists: true) { t in
            t.column(file_hash, primaryKey: true)
            t.column(artist_name)
            t.column(album_name)
            t.column(track_name)
        })

        try db.run(history.create(ifNotExists: true) { t in
            t.column(history_id, primaryKey: true)
            t.column(file_hash)
            t.column(date)
            t.foreignKey(file_hash, references: files, file_hash)
        })


    } catch {
        print(error)
        exit(1)
    }
}

func addFile(file_hash url: String, artist: String, album: String, track: String) {
    do {
        let db = try Connection(TEST_DB)
        let files = Table("files")

        let file_hash = SQLite.Expression<String>("file_hash")
        let artist_name = SQLite.Expression<String>("artist_name")
        let album_name = SQLite.Expression<String>("album_name")
        let track_name = SQLite.Expression<String>("track_name")

        try db.run(files.insert(or: .ignore,
            file_hash <- url,
            artist_name <- artist,
            album_name <- album,
            track_name <- track
        ))

    } catch {
        print(error)
        exit(1)
    }

}

func addHistory(file url: URL) {
    do {
        let db = try Connection(TEST_DB)
        let history = Table("history")

        let file_hash = SQLite.Expression<String>("file_hash")
        let date = SQLite.Expression<String>("date")

        try db.run(history.insert(
            file_hash <- hashFile(file: url),
            date <- getDateTime()
        ))

    } catch  {
        print(error)
        exit(1)
    }
}

class Node: @unchecked Sendable, Codable {
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

}

func scanFiles() -> Node {

    let fileManager = FileManager.default

    var isDirectory: ObjCBool = false
    let musicFolderURL: URL = URL(filePath: "/Users/jayson/Downloads/Music/Downloads")

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

                        // var hash: String?
                        // Task {
                        //     hash = hashFile(file: url)
                        //     semaphore.signal()
                        // }

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
                                guard let trackNumMetadata  = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .id3MetadataTrackNumber).first ??
                                                              metadata.first(where: {($0.key as? String)?.uppercased() == "TRK" && $0.keySpace?.rawValue == "org.id3"}) else {continue}

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
                        // semaphore.wait()

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

                            let hash = hashfile2(
                                artist: artistValue!,
                                album:  albumValue!,
                                track: titleValue!,
                                track_num: trackNumber!
                            )

                            addFile(
                                file_hash: hash,
                                artist: artistValue!,
                                album:  albumValue!,
                                track: titleValue!
                            )

                        } else {
                            filesSkipped += 1
                            print("\u{001B}[1B\u{001B}[16C\(filesSkipped)", terminator: "\u{001B}[1F")
                        }
                        fflush(stdout)

                    }
                }
            }

            print("\u{001B}[1B")

            return rootNode
        } catch {
            print(error)
            exit(1)
        }
    }

    print("Unable to open folder \(musicFolderURL.path())")
    exit(1)
}

setupDB()
_ = scanFiles()