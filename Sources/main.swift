// v1.9.13

import AVFoundation
import Collections
import ArgumentParser
import SQLite
import CryptoKit

let FILES_PATH  : String = ".config/Lansa0MusicPlayer/files.json"
let CONFIG_PATH : String = ".config/Lansa0MusicPlayer/config.json"

/* TODO
    Add (better) docs for functions
    Work on error handling (might be good enough)
    Argument help messages
    Now Playing widget (??)
    Flatten tree array ?

    Rework path argument
*/

///////////////////////////////////////////////////////////////////////////
//[ARGUMENT/PARSER]////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////

struct Config: Codable {
    var path: String
}

struct Arguments : ParsableCommand {
    @Flag var scan: Bool = false

    @Flag(
        name: [.customLong("scroll-off")],
        help: ArgumentHelp("Turns off scroll wheel/pad based navigation")
    )
    var scrollOff: Bool = false

    @Flag var debug: Bool = false

    @Option(
        help: ArgumentHelp("Sets the path to where mp3 files will be searched")
    )
    var path: String? = nil

    @Flag(help: ArgumentHelp("User manual"))
    var manual: Bool = false

    func setup() {
        if let inputPath = self.path {

            let fileManager = FileManager.default
            let home = FileManager.default.homeDirectoryForCurrentUser
            let configPath = home.appending(path: CONFIG_PATH, directoryHint: .notDirectory)

            do {
                let parent = configPath.deletingLastPathComponent()
                try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)

                let encoder = JSONEncoder()

                let config = Config(path: inputPath)
                let data = try encoder.encode(config)
                try data.write(to: configPath)

            } catch {
                Arguments.exit(withError: error)
            }

            Arguments.exit()
        }

        else if manual {
            Output.userManual()
            Arguments.exit()
        }

        Terminal.shared.debug = debug
    }

}

///////////////////////////////////////////////////////////////////////////
//[TERMINAL]///////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////

class Terminal {
    nonisolated(unsafe) static let shared = Terminal()

    private let MINIMUM_ROWS    : Int = 5
    private let MINIMUM_COLUMNS : Int = 30

    private let ROW_ADJUSTMENT    : Int = 3 // 2 Borders + 1 Progress bar
    private let COLUMN_ADJUSTMENT : Int = 2 // 2 Borders

    private var OriginalTerm = termios()

    var debug     : Bool = false
    var tooSmall  : Bool = false
    var showQueue : Bool = false

    var rows    : Int = 0
    var columns : Int = 0

    var lastKnownCurrentTime : TimeInterval?
    var lastKnownDuration    : TimeInterval?

    /// - Parameters:
    ///   - view: Current view parameters
    ///   - rootNode: root, node
    ///
    /// Sets the terminal to an appropriate form
    /// and figures out the inital size of the terminal.
    /// As well as rendering the inital content
    func setup(view: inout View, rootNode: Node) {
        tcgetattr(STDIN_FILENO, &OriginalTerm)
        print("\u{001B}[?1049h\u{001B}[?25l")   // alternate buffer + hide cursor
        print("\u{001B}[?1000h\u{001B}[?1006h") // enable scrolling

        // Set terminal to non canonical
        var CopyTerm = OriginalTerm
        CopyTerm.c_lflag &= ~(UInt(ICANON | ECHO))
        CopyTerm.c_cc.6 = 1
        CopyTerm.c_cc.5 = 0
        tcsetattr(STDIN_FILENO, TCSANOW, &CopyTerm)

        guard let (rows,columns) = getTerminalSize() else {return}

        self.rows = rows - ROW_ADJUSTMENT - (self.debug ? 1 : 0)
        self.columns = columns - COLUMN_ADJUSTMENT

        view.viewRange = (1, min(self.rows, view.totalRange))

        if rows < MINIMUM_ROWS || columns < MINIMUM_COLUMNS {
            self.tooSmall = true
            Output.tooSmall()
        } else {
            Output.drawBorder(rows: self.rows, columns: self.columns)
            Output.progressBar(currentTime: nil, duration: nil)

            view.lineDeque.append(contentsOf: rootFile.getNodes(range: view.viewRange))
            Output.fillTree(lines: view.lineDeque)
            Output.setDot(currentLineHeight: 1, previousLineHeight: 1)
        }

        Output.debugLine(view: view)

    }

    /// - Parameter msg: Final message before the program terminates, where you'll see what error occurred
    func resetTerminal(msg: String = "Program exited") {
        print("\u{001B}[?25h\u{001B}[?1049l", terminator: "")   // show cursor + original buffer
        print("\u{001B}[?1000l\u{001B}[?1006l", terminator: "") // disable scrolling

        tcsetattr(STDIN_FILENO, TCSANOW, &OriginalTerm)

        print(msg)
        exit(0)
    }

    /// - Parameters:
    ///   - view: Current view parameters
    ///   - rootNode: root, node
    ///   - audioPlayer: player, audio
    /// 
    /// Handles how the program should display itself when the user sizes the terminal
    func onResize(view: inout View, rootNode: Node, audioPlayer: AudioPlayer) {
        guard let (rows, columns) = getTerminalSize() else {return}

        if rows < MINIMUM_ROWS || columns < MINIMUM_COLUMNS {
            self.tooSmall = true
            Output.tooSmall()
        }
        else {

            let expanding: Bool = self.rows < (rows - ROW_ADJUSTMENT)

            self.tooSmall = false
            self.rows = rows - ROW_ADJUSTMENT - (self.debug ? 1 : 0)
            self.columns = columns - COLUMN_ADJUSTMENT

            Output.drawBorder(rows: self.rows, columns: self.columns)
            Output.progressBar(currentTime: self.lastKnownCurrentTime, duration: self.lastKnownDuration)

            // Refer to Tests/window_size/main.swift to make sense of this
            if expanding {
                if view.viewRange.min > 1 {
                    let Point = view.viewRange.min + view.relativeLineNum - 1
                    view.viewRange.max = view.viewRange.min + self.rows
                    if view.viewRange.max > view.totalRange {
                        let leftover = view.viewRange.max - view.totalRange
                        view.viewRange.max = view.totalRange
                        view.viewRange.min = max(view.viewRange.min + 1 - leftover, 1)
                        view.relativeLineNum = Point - view.viewRange.min + 1
                    }
                } else {
                    view.viewRange.max = min(view.totalRange, self.rows)
                }
            }
            else {
                if !(view.viewRange.min == 1 && view.viewRange.max == view.totalRange) {
                    view.viewRange.max = view.viewRange.min + self.rows - 1
                } else {
                    view.viewRange.max = min(view.totalRange, self.rows)
                }
                view.relativeLineNum = min(view.relativeLineNum, self.rows)
            }

            view.lineDeque.removeAll(keepingCapacity: true)
            view.lineDeque.append(contentsOf: rootFile.getNodes(range: view.viewRange))

            if showQueue {
                let semaphore = DispatchSemaphore(value: 0)
                Task {
                    let queue = await audioPlayer.queue
                    let looping = await audioPlayer.looping
                    Output.fillQueue(lines: Deque<String>(queue.map{$0.name}), looping: looping)
                    semaphore.signal()
                }
                semaphore.wait()
            } else {
                Output.fillTree(lines: view.lineDeque)
                Output.setDot(currentLineHeight: view.relativeLineNum, previousLineHeight: view.relativeLineNum)
            }

        }

        Output.debugLine(view: view)

    }

    /// - Returns: The current size of the terminal in rows (height) and columns (width)
    private func getTerminalSize() -> (rows: Int, columns: Int)? {
        var w = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &w) == 0 {
            let rows    = Int(w.ws_row)
            let columns = Int(w.ws_col)
            return (rows,columns)
        }
        return nil
    }
}

///////////////////////////////////////////////////////////////////////////
//[DATABASE HANDLER]///////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////

class Database {
    nonisolated(unsafe) static let shared = Database()

    private var dbPath: String?
    private var persistantConnection: Connection?

    private let files   = Table("files")
    private let history = Table("history")

    private let file_hash   = SQLite.Expression<String>("file_hash")
    private let artist_name = SQLite.Expression<String>("artist_name")
    private let album_name  = SQLite.Expression<String>("album_name")
    private let track_name  = SQLite.Expression<String>("track_name")
    private let history_id  = SQLite.Expression<Int>("history_id")
    private let date        = SQLite.Expression<String>("date")

    func setup() {
        do {

            guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {exit(1)}

            let dirURL = appSupport.appendingPathComponent("Lansa0MusicPlayer")
            try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true, attributes: nil)

            let dbURL = dirURL.appendingPathComponent("history.sqlite3")
            if !FileManager.default.fileExists(atPath: dbURL.path) {
                FileManager.default.createFile(atPath: dbURL.path(), contents: nil, attributes: nil)
            }

            self.dbPath = dbURL.path
            let db = try Connection(self.dbPath!)

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

    func openConnection() {do {self.persistantConnection = try Connection(self.dbPath!)} catch {print(error);exit(1)}}
    func closeConnection() {self.persistantConnection = nil}

    /// - Parameters:
    ///   - hash: Hashed contents of the files metadata
    ///   - artist: Artist name
    ///   - album: Album Name
    ///   - track: Track Name
    ///
    /// Inserts given file data into the files table of the database for cross reference of played tracks
    ///
    /// Very sensitive to changes in metadata. Two different files with identical metadata will
    /// result in the same hash, regardless if the audio data is the same. Two different files
    /// with identical audio data but any differences in metadata (i.e extra spaces, misspelling,
    /// special character) excluding case sensitivity will result in a different hash
    func addFile(file_hash hash: String, artist: String, album: String, track: String) {
        do {
            if self.persistantConnection == nil {
                self.persistantConnection = try Connection(self.dbPath!)
            }
            guard let db = self.persistantConnection else {return}

            try db.run(files.insert(or: .ignore,
                file_hash <- hash,
                artist_name <- artist,
                album_name <- album,
                track_name <- track
            ))

        } catch {
            print(error)
            exit(1)
        }
    }

    /// - Parameter hash: Hashed contents of the files metadata
    ///
    /// Stores file hash and date time into the history table of the database
    ///
    /// Use the hash to cross reference the data with the files table
    func addHistory(file_hash hash: String) {
        do {
            let db = try Connection(self.dbPath!)

            let timeFormatter = ISO8601DateFormatter()
            timeFormatter.timeZone = TimeZone.current
            let dateTime: String = timeFormatter.string(from: Date())

            try db.run(history.insert(
                file_hash <- hash,
                date <- dateTime
            ))

        } catch {
            Terminal.shared.resetTerminal(msg: error.localizedDescription)
        }
    }

}

///////////////////////////////////////////////////////////////////////////
//[FILE HANDLER]///////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////

class Node: @unchecked Sendable, Codable {
    let url: URL?
    let file_hash: String?
    let name: String
    let trackNumber: Int?
    let discNumber: Int?
    private(set) var active: Bool = false
    private(set) var nodes: [Node]

    init(name str: String, url: URL? = nil, file_hash: String? = nil, trackNumber: Int? = nil, discNumber: Int? = nil) {
        self.url = url
        self.file_hash = file_hash
        self.name = str
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.nodes = []
    }

    func toggleActive() {active = !active}
    func add(_ node: Node) {self.nodes.append(node)}

    /// Sorts nodes based on disc number, then track number, then name
    func sort() {
        self.nodes.sort {
            let left = ($0.discNumber ?? Int.max, $0.trackNumber ?? Int.max, $0.name.lowercased())
            let right = ($1.discNumber ?? Int.max, $1.trackNumber ?? Int.max, $1.name.lowercased())
            return left < right
        }
    }

    // Traversal functions

    /// - Returns: Number of active nodes under the root node
    /// 
    /// (Does not count active nodes whose parent node is inactive)
    func numActiveNodes() -> Int {
        var count: Int = 0
        var nodeStack: [Node] = [self]
        while let node = nodeStack.popLast() {
            if node.active {
                nodeStack.append(contentsOf: node.nodes)
            }
            count += 1
        }
        return count
    }

    /// Activates all the children under the root while also giving an ordered
    /// array of all leaf nodes (track nodes)
    /// - Returns: All leaf nodes under the root (track nodes)
    func activateAllChildren() -> [Node] {
        var ret: [Node] = []

        var nodeStack: [Node] = [self]

        while let node: Node = nodeStack.popLast() {

            if node.url != nil {ret.append(node)}
            else if !node.active {node.toggleActive()}

            nodeStack.append(contentsOf: node.nodes.reversed())
        }

        return ret
    }

    /// - Parameter at: Position of the node within the tree
    /// - Returns: Node at given position
    func getNode(at: Int) -> Node {
        var nodeStack: [Node] = [self]
        var position: Int = 1

        while let node = nodeStack.popLast() {
            if position == at {return node}

            if node.active {
                nodeStack.append(contentsOf: node.nodes.reversed())
            }
            position += 1
        }

        // Pretty sure this won't run if i set everything else up correctly
        return Node(name: "")
    }

    /// - Parameter at: Position of the node within the tree
    /// - Returns: Formatted name of the node at given position
    func getNodeName(at: Int) -> String {
        var nodeStack: [(node: Node, depth: Int, numChildren: Int)] = [(self, 0, self.nodes.count)]
        var position: Int = 1

        while let (node, depth, numChildren) = nodeStack.popLast() {
            if position == at {
                return node.createString(depth, numChildren)
            }

            if node.active {
                for i in stride(from: node.nodes.count-1, through: 0, by: -1) {
                    nodeStack.append((node.nodes[i], depth+1, node.nodes.count))
                }
            }
            position += 1
        }

        // Pretty sure this won't run if i set everything else up correctly
        return ""
    }

    func getNodes(range: (min: Int, max: Int)) -> [String] {
        var ret: [String] = []

        var nodeStack: [(node: Node, depth: Int, numChildren: Int)] = [(self, 0, self.nodes.count)]
        var position: Int = 1

        while let (node, depth, numChildren) = nodeStack.popLast() {
            if position > range.max {break}

            if position >= range.min {
                let nameString: String = node.createString(depth, numChildren)
                ret.append(nameString)
            }

            if node.active {
                for i in stride(from: node.nodes.count-1, through: 0, by: -1) {
                    nodeStack.append((node.nodes[i], depth+1, node.nodes.count))
                }
            }
            position += 1
        }

        return ret
    }

    private func createString(_ depth: Int, _ numChildren: Int) -> String {
        let DOWN_ARROW  : String = "\u{001B}[32m▾\u{001B}[0m"
        let RIGHT_ARROW : String = "▸"

        var str: String = String(repeating: "  ", count: depth)

        if self.nodes.count > 0 {
            str += "\(self.active ? DOWN_ARROW : RIGHT_ARROW) \(self.name)"
        } else {
            let numDigits: Int = max(2, numChildren > 0 ? Int(log10(Double(numChildren))) + 1 : 1)
            let formattedNum: String = String(format: "%0\(numDigits)d", self.trackNumber!)
            str += "  \(formattedNum). \(self.name)"
        }

        return str
    }

    enum CodingKeys: String, CodingKey {
        case name
        case url
        case file_hash
        case nodes
        case trackNumber
        case discNumber
    }

}

struct FileHandler {

    static func scanFiles() -> Node {

        let fileManager = FileManager.default
        let home = FileManager.default.homeDirectoryForCurrentUser
        let configPath = home.appending(path: CONFIG_PATH, directoryHint: .notDirectory)

        let decoder = JSONDecoder()
        let configData: Config

        do {
            let jsonData = try Data(contentsOf: configPath)
            configData = try decoder.decode(Config.self, from: jsonData)
        } catch {
            print(error)
            exit(1)
        }

        var isDirectory: ObjCBool = false
        let musicFolderURL: URL = URL(filePath: configData.path)

        if fileManager.fileExists(atPath: musicFolderURL.path(), isDirectory: &isDirectory) && isDirectory.boolValue {

            let rootNode = Node(name: "All Music")
            rootNode.toggleActive()

            var folderStack: [URL] = [musicFolderURL]

            do {
                var fileCount: Int = 0
                var filesSkipped: Int = 0

                print("Files Loaded  :\nFiles Skipped :", terminator: "\u{001B}[1F")

                Database.shared.openConnection()

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

                            if !fileSkipped {

                                let hash: String = hashFile(
                                    artist: artistValue!,
                                    album:  albumValue!,
                                    track: titleValue!,
                                    track_num: trackNumber!
                                )

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

                                let trackNode: Node = Node(
                                    name: titleValue!,
                                    url: url,
                                    file_hash: hash,
                                    trackNumber: trackNumber,
                                    discNumber: discNumber
                                )
                                albumNode.add(trackNode)

                                Database.shared.addFile(
                                    file_hash: hash,
                                    artist: artistValue!,
                                    album:  albumValue!,
                                    track: titleValue!
                                )

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

                Database.shared.closeConnection()
                print("\u{001B}[1B")

                // Deeply sort node
                var nodeStack: [Node] = [rootNode]
                nodeStack.reserveCapacity(fileCount)
                while let node = nodeStack.popLast() {
                    node.sort()
                    nodeStack.append(contentsOf: node.nodes)
                }

                self.encodeNode(root: rootNode)

                return rootNode
            } catch {
                print(error)
                exit(1)
            }
        }

        print("Unable to open folder \(musicFolderURL.path())")
        exit(1)
    }

    static private func hashFile(artist: String, album: String, track: String, track_num: Int) -> String {
        let s = "\(artist.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))|" +
                "\(album.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)))|" +
                "\(track.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)))|" +
                "\(track_num)"
        let d = Data(s.utf8)

        let digest = SHA256.hash(data: d)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static private func encodeNode(root: Node) {
        let fileManager = FileManager.default
        let home = FileManager.default.homeDirectoryForCurrentUser
        let configPath = home.appending(path: FILES_PATH, directoryHint: .notDirectory)

        do {
            let parent = configPath.deletingLastPathComponent()
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)

            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys

            let data = try encoder.encode(root)
            try data.write(to: configPath)

        } catch {
            print(error)
            exit(1)
        }
    }

    static func decodeNode() -> Node {
        let decoder = JSONDecoder()
        let home = FileManager.default.homeDirectoryForCurrentUser
        let configPath = home.appending(path: FILES_PATH, directoryHint: .notDirectory)

        do {
            let data = try Data(contentsOf: configPath)
            let root = try decoder.decode(Node.self, from: data)
            root.toggleActive()

            return root
        } catch {
            print(error)
            exit(1)
        }
    }

}

///////////////////////////////////////////////////////////////////////////
//[AUDIO PLAYER]///////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////

actor AudioPlayer: NSObject, AVAudioPlayerDelegate {
    private let VOLUME_INCREMENT : Float = 0.05

    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var queue = Deque<Node>()
    private var playing = false
    private var currentPlayer: AVAudioPlayer?
    private var volume: Float = 0.5
    private var skipTracking: Bool = false
    private(set) var looping: Bool = false

    func add(contentsOf nodes: [Node]) {
        self.queue.append(contentsOf: nodes)

        if !self.playing {
            self.playing = true
            Task { await play() }
        }
    }

    private func play() async {
        while let node = self.queue.first {

            if Terminal.shared.showQueue {
                Output.fillQueue(lines: Deque<String>(queue.map{$0.name}), looping: looping)
            }

            do {
                let player = try AVAudioPlayer(contentsOf: node.url!)
                player.delegate = self

                self.currentPlayer = player
                player.setVolume(volume, fadeDuration: 0)
                player.play()

                self.startTimer()

                await withCheckedContinuation { cont in self.continuation = cont }

                Output.progressBar(currentTime: nil, duration: nil)

                if !self.skipTracking {
                    Database.shared.addHistory(file_hash: node.file_hash!)
                }
                self.skipTracking = false

            } catch {
                Terminal.shared.resetTerminal(msg: error.localizedDescription)
            }

            if !self.looping {
                _ = self.queue.popFirst()
            }

        }

        if Terminal.shared.showQueue {
            Output.fillQueue(lines: Deque<String>(self.queue.map{$0.name}), looping: looping)
        }
        playing = false
    }

    func pause() {
        guard let player = self.currentPlayer else {return}
        if player.isPlaying { player.pause() }
        else {
            player.play()
            self.startTimer()
        }
    }

    func skip() {
        guard let player = self.currentPlayer else {return}

        if player.currentTime > (player.duration / 2) {
            self.skipTracking = false
        } else {
            self.skipTracking = true
        }

        self.looping = false

        player.stop()
        self.playerDidFinish()
    }

    func clearQueue() {
        self.queue.removeAll(keepingCapacity: true)
        if Terminal.shared.showQueue {
            Output.fillQueue(lines: Deque<String>(self.queue.map{$0.name}), looping: looping)
        }

        self.skip()
    }

    func toggleLoop() {
        self.looping = !self.looping

        if Terminal.shared.showQueue {
            // I could just make a new function that will only rewrite the very top line instead of the entire queue but nah
            Output.fillQueue(lines: Deque<String>(self.queue.map{$0.name}), looping: looping)
        }

    }

    func volume(up: Bool) {
        guard let player = self.currentPlayer else {return}

        if up {self.volume = min(1.0, self.volume + self.VOLUME_INCREMENT)}
        else  {self.volume = max(0.0, self.volume - self.VOLUME_INCREMENT)}

        player.setVolume(self.volume, fadeDuration: 0)
    }

    private func startTimer() {
        Task {
            while let player = self.currentPlayer, player.isPlaying {
                Output.progressBar(currentTime: player.currentTime, duration: player.duration)
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
            }
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { await self.playerDidFinish() }
    }

    private func playerDidFinish() {
        self.continuation?.resume()
        self.continuation = nil
        self.currentPlayer = nil
    }

}

///////////////////////////////////////////////////////////////////////////
//[OUTPUT]/////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////

struct Output {
    private static let BORDER_OFFSET : Int = 1

    private static let FILE_HEADER  : String = "FILE━TREE"
    private static let QUEUE_HEADER : String = "QUEUE━━━━"

    private static let FILE_NAME_OFFSET  : Int = 5
    private static let QUEUE_NAME_OFFSET : Int = 3

    static func userManual() {
        print("""
        -- Setup --

            If this is your first time using, run the --path argument
            and set it to the path to the folder with your music downloads

            Then run the --scan argument to scan the files inside the set
            folder. This will automatically take you to the player once
            scanning is finished

        -- Tracking --

            W.I.P

        -- Navigation --

            j | Down Arrow | Down Scroll : Scroll down
            k | Up Arrow | Up Scroll : Scroll up
            Space : Expand/Collapse folder
            Enter : Add track to queue
                    If used on a folder, add all tracks under the folder
                    Automatically expands folder
            ` (backtick) : Switches view between queue and file tree

        -- Playback --

            p : Pause player
            s : Skip current track
            c : Clear queue
            v (lowercase) : Volume down
            V (uppercase) : Volume up

        -- Misc --

            q : quit

        """)
    }

    // Trust me, this works
    static func drawBorder(rows: Int, columns: Int) {
        // -10 is the length of FILE_HEADER / QUEUE_HEADER plus the border
        print("\u{001B}[2J\u{001B}[H┏\(Terminal.shared.showQueue ? QUEUE_HEADER : FILE_HEADER)━\(String(repeating: "━", count: columns-10))┓")
        for _ in 0..<rows {print("┃\(String(repeating: " ", count: columns))┃")}
        print("┗\(String(repeating: "━", count: columns))┛",terminator: "")
        fflush(stdout)
    }

    static func fillTree(lines: Deque<String>) {
        let emptyLine = (String(repeating: " ", count: Terminal.shared.columns))
        for rowNum in 0..<Terminal.shared.rows {
            // Need the extra +1 because rowNum starts at 0
            let emptyCursorPos = "\u{001B}[\(rowNum + BORDER_OFFSET + 1);2H"
            let lineCursorPos = "\u{001B}[\(rowNum + BORDER_OFFSET + 1);\(FILE_NAME_OFFSET)H"

            if rowNum < lines.count {
                print(
                    emptyCursorPos,emptyLine,
                    lineCursorPos,lines[rowNum].prefix(Terminal.shared.columns - 3), // 3 is the indent between border and string
                    separator: ""
                )
            } else {
                print(emptyCursorPos,emptyLine,separator: "")
            }
        }
    }

    static func fillQueue(lines: Deque<String>, looping: Bool) {
        let emptyLine = (String(repeating: " ", count: Terminal.shared.columns))
        for rowNum in 0..<Terminal.shared.rows {
            // Need the extra +1 because rowNum starts at 0
            let emptyCursorPos = "\u{001B}[\(rowNum + BORDER_OFFSET + 1);2H"
            let lineCursorPos = "\u{001B}[\(rowNum + BORDER_OFFSET + 1);\(QUEUE_NAME_OFFSET)H"

            if rowNum == 0 && lines.count > 0 {
                let status  : String = looping ? "🎵 🔁 " : "🎵 "
                let spacing : Int = looping ? 7 : 4

                print(
                    emptyCursorPos, emptyLine,
                    lineCursorPos, status, lines[rowNum].prefix(Terminal.shared.columns - spacing),
                    separator: ""
                )
            }
            else if rowNum < lines.count {
                print(
                    emptyCursorPos,emptyLine,
                    lineCursorPos,lines[rowNum].prefix(Terminal.shared.columns - BORDER_OFFSET),
                    separator: ""
                )
            } else {
                print(emptyCursorPos,emptyLine,separator: "")
            }

        }
    }

    static func setDot(currentLineHeight: Int, previousLineHeight: Int) {
        print("\u{001B}[\(previousLineHeight+BORDER_OFFSET);2H  \u{001B}[\(currentLineHeight+BORDER_OFFSET);2H •")
    }

    static func tooSmall() {print("\u{001B}[2J\u{001B}[HTOO SMALL!")}
    static func switchHeader(showQueue: Bool) {print("\u{001B}[;2H", showQueue ? QUEUE_HEADER : FILE_HEADER, separator: "")}

    static func debugLine(view: View) {
        if !Terminal.shared.debug {return}
        let rows: Int = Terminal.shared.rows
        let columns: Int = Terminal.shared.columns

        print(
            "\u{001B}[\(rows+3);H",
            String(repeating: " ",count: columns+2),
            "\u{001B}[\(rows+3);H",
            "ROWS: \(rows), UPPER: \(view.viewRange.min), LOWER : \(view.viewRange.max), MAX : \(view.totalRange), LINE NUM : \(view.relativeLineNum)",
            separator: "",
            terminator: ""
        )
        fflush(stdout)
    }

    static func progressBar(currentTime: TimeInterval?, duration: TimeInterval?) {
        Terminal.shared.lastKnownCurrentTime = currentTime
        Terminal.shared.lastKnownDuration = duration

        if let currentTime = currentTime, let duration = duration {

            func formatTime(_ t: TimeInterval) -> String {
                let total = Int(t)
                let minutes = total / 60
                let seconds = total % 60
                return String(format: "%02d:%02d", minutes, seconds)
            }

            var timeWidth: Int

            let a = formatTime(currentTime)
            let b = formatTime(duration)

            // +5 refer to Tests/time_bar/main.swift
            timeWidth = a.count + b.count + 5

            let barWidth: Int = Terminal.shared.columns + 2 - timeWidth
            let progress : TimeInterval = currentTime / duration
            let left     : Int = max(0,Int(floor(progress * Double(barWidth)))-1)
            let right    : Int = barWidth - (left+1)

            print(
                "\u{001B}[\(Terminal.shared.rows+3);H\(String(repeating: "━", count: left))○\(String(repeating: "-", count: right)) \(a) / \(b)",
                terminator: ""
            )
        }
        else {
            print(
                "\u{001B}[\(Terminal.shared.rows+3);H\(String(repeating: " ", count: Terminal.shared.columns + 2))",
                terminator: ""
                )
        }
        fflush(stdout)
    }

}

///////////////////////////////////////////////////////////////////////////
//[INPUT]//////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////

enum Keys {
    case v
    case s
    case q
    case p
    case k
    case j
    case btick // `
    case tilde // ~
    case V
    case down
    case up
    case space
    case enter
    case c
    case l

    private static let KeyCodes: [UInt8 : Keys] = [
        118 : .v,
        115 : .s,
        113 : .q,
        112 : .p,
        107 : .up,
        106 : .down,
        96  : .btick,
        126 : .tilde,
        86  : .V,
        32  : .space,
        10  : .enter,
        99  : .c,
        108 : .l
    ]

    static func getKeyboardInput(c: UInt8) -> Keys? {
        return KeyCodes[c]
    }

    static func getScrollInput(buffer: [UInt8]) -> Keys? {
        var index = 3
        var cb = ""

        while index < buffer.count, buffer[index] != 0x3B {
            let scaler = UnicodeScalar(buffer[index])
            cb.append(Character(scaler))
            index += 1
        }

        guard let cb = UInt8(cb) else {return nil}
        return cb == 64 ? Keys.up : Keys.down
    }

}

struct View {
    var lineDeque       : Deque<String> = []
    var relativeLineNum : Int = 1
    var totalRange      : Int
    var viewRange       : (min: Int, max: Int) = (0,0)

    init(totalRange: Int) {
        lineDeque.reserveCapacity(100) // random number tbh
        self.totalRange = totalRange
    }
}

struct Input {

    static func scrollUp(view: inout View, rootFile: Node) {
        if view.relativeLineNum == 1 {
            if view.viewRange.min == 1 { return }

            view.viewRange.min -= 1
            view.viewRange.max -= 1

            _ = view.lineDeque.popLast()
            let newLine = rootFile.getNodeName(at: view.viewRange.min)
            view.lineDeque.prepend(newLine)

            Output.fillTree(lines: view.lineDeque)
            Output.setDot(currentLineHeight: view.relativeLineNum, previousLineHeight: view.relativeLineNum)

        } else {
            view.relativeLineNum -= 1
            Output.setDot(currentLineHeight: view.relativeLineNum, previousLineHeight: view.relativeLineNum + 1)
        }
        Output.debugLine(view: view)
    }

    static func scrollDown(view: inout View, rootFile: Node) {
        if view.relativeLineNum == view.totalRange {
            return
        } else if view.relativeLineNum == Terminal.shared.rows {
            if view.viewRange.max == view.totalRange { return }

            view.viewRange.min += 1
            view.viewRange.max += 1

            _ = view.lineDeque.popFirst()
            let newLine = rootFile.getNodeName(at: view.viewRange.max)
            view.lineDeque.append(newLine)

            Output.fillTree(lines: view.lineDeque)
            Output.setDot(currentLineHeight: view.relativeLineNum, previousLineHeight: view.relativeLineNum)

        } else {
            view.relativeLineNum += 1
            Output.setDot(currentLineHeight: view.relativeLineNum, previousLineHeight: view.relativeLineNum - 1)
        }
        Output.debugLine(view: view)
    }

    static func expandFolder(view: inout View, rootFile: Node) {
        let nodePos: Int = view.viewRange.min + view.relativeLineNum - 1
        rootFile.getNode(at: nodePos).toggleActive()

        let oldRange: Int = view.totalRange
        let newRange: Int = rootFile.numActiveNodes()

        // No change (somehow)
        if oldRange == newRange {return}

        // Collapse Folder
        if oldRange > newRange && view.viewRange.max > newRange {
            let Point = view.viewRange.min + view.relativeLineNum - 1
            view.viewRange = (max(1, newRange - Terminal.shared.rows + 1), newRange)
            view.relativeLineNum = Point - view.viewRange.min + 1
        }

        // Expand Folder
        else if oldRange < newRange && oldRange < Terminal.shared.rows {
            view.viewRange = (min: 1, max: min(newRange, Terminal.shared.rows))
        }

        view.totalRange = newRange

        view.lineDeque.removeAll(keepingCapacity: true)
        view.lineDeque.append(contentsOf: rootFile.getNodes(range: view.viewRange))

        Output.fillTree(lines: view.lineDeque)
        Output.setDot(currentLineHeight: view.relativeLineNum, previousLineHeight: view.relativeLineNum)
        Output.debugLine(view: view)
    }

    static func playFiles(view: inout View, rootFile: Node, audioPlayer: AudioPlayer) {
        let nodePos: Int = view.viewRange.min + view.relativeLineNum - 1
        let nodes: [Node] = rootFile.getNode(at: nodePos).activateAllChildren()
        let semaphore = DispatchSemaphore(value: 0)

        Task {
            await audioPlayer.add(contentsOf: nodes)
            semaphore.signal()
        }

        let oldRange: Int = view.totalRange
        let newRange: Int = rootFile.numActiveNodes()

        // No change (somehow)
        if oldRange == newRange {return}

        // Collapse Folder
        // Don't think this runs in this context but i just my copied the code from expandFolder()
        // because it uses the same functionality
        if oldRange > newRange && view.viewRange.max > newRange {
            view.viewRange = (max(1, newRange - Terminal.shared.rows + 1), newRange)
        }

        // Expand Folder
        else if oldRange < newRange && oldRange < Terminal.shared.rows {
            view.viewRange = (min: 1, max: min(newRange, Terminal.shared.rows))
        }

        view.totalRange = newRange

        view.lineDeque.removeAll(keepingCapacity: true)
        view.lineDeque.append(contentsOf: rootFile.getNodes(range: view.viewRange))

        semaphore.wait()

        Output.fillTree(lines: view.lineDeque)
        Output.setDot(currentLineHeight: view.relativeLineNum, previousLineHeight: view.relativeLineNum)
        Output.debugLine(view: view)
    }

    static func pauseTrack(audioPlayer: AudioPlayer) {Task {await audioPlayer.pause()}}
    static func skipTrack(audioPlayer: AudioPlayer)  {Task {await audioPlayer.skip()}}
    static func clearQueue(audioPlayer: AudioPlayer) {Task {await audioPlayer.clearQueue()}}
    static func changeVolume(audioPlayer: AudioPlayer, volumeUp: Bool) {Task {await audioPlayer.volume(up: volumeUp)}}
    static func toggleLoop(audioPlayer: AudioPlayer) {Task { await audioPlayer.toggleLoop()}}

    static func switchView(view: View, audioPlayer: AudioPlayer) {
        Terminal.shared.showQueue = !Terminal.shared.showQueue
        Output.switchHeader(showQueue: Terminal.shared.showQueue)

        if Terminal.shared.showQueue {
            let semaphore = DispatchSemaphore(value: 0)
            Task {
                let queue = await audioPlayer.queue
                let looping = await audioPlayer.looping
                Output.fillQueue(lines: Deque<String>(queue.map{$0.name}), looping: looping)
                semaphore.signal()
            }
            semaphore.wait()
        } else {
            Output.fillTree(lines: view.lineDeque)
            Output.setDot(currentLineHeight: view.relativeLineNum, previousLineHeight: view.relativeLineNum)
        }
    }

    static func quit(input: DispatchSourceRead, Exit: inout Bool) {
        Exit = true
        input.cancel()
        CFRunLoopStop(CFRunLoopGetCurrent())
    }

}

///////////////////////////////////////////////////////////////////////////
//[MAIN]///////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////

let args = Arguments.parseOrExit()
args.setup()

Database.shared.setup()

let rootFile: Node = args.scan ? FileHandler.scanFiles() : FileHandler.decodeNode()
let audioPlayer = AudioPlayer()
var filesView = View(totalRange: rootFile.numActiveNodes())

Terminal.shared.setup(view: &filesView, rootNode: rootFile)
signal(SIGINT)   {_ in Terminal.shared.resetTerminal()}
signal(SIGWINCH) {_ in Terminal.shared.onResize(view: &filesView, rootNode: rootFile, audioPlayer: audioPlayer)}

var Exit: Bool = false

// Using DispatchSource because there's a yielding issue with the line
// read(STDIN_FILENO, &buff, 3) which affects the AVAudioPlayer
// so having a regular while loop doesn't work
let input = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: .main)
input.setEventHandler {

    var buff = [UInt8](repeating: 0, count: 32)
    let n = read(STDIN_FILENO, &buff, 32)
    let key: Keys

    // invalid
    if n < 1 || Terminal.shared.tooSmall { return }

    // scroll input
    else if buff.starts(with: [0x1B, 0x5B, 0x3C]) && !args.scrollOff {
        guard let _key = Keys.getScrollInput(buffer: buff) else {return}
        key = _key
    }
    // arrow key input
    else if n == 3 && buff.starts(with: [27, 91]) {
        key = (buff[2] == 65) ? Keys.up : Keys.down
    }
    // normal key input
    else {
        guard let _key = Keys.getKeyboardInput(c: buff[0]) else {return}
        key = _key
    }

    let showQueue: Bool = Terminal.shared.showQueue

    switch key {
        case .up    : if !showQueue {Input.scrollUp(view: &filesView, rootFile: rootFile)}
        case .down  : if !showQueue {Input.scrollDown(view: &filesView, rootFile: rootFile)}
        case .space : if !showQueue {Input.expandFolder(view: &filesView, rootFile: rootFile)}
        case .enter : if !showQueue {Input.playFiles(view: &filesView,  rootFile: rootFile, audioPlayer: audioPlayer)}
        case .btick,
             .tilde : Input.switchView(view: filesView, audioPlayer: audioPlayer)
        case .p     : Input.pauseTrack(audioPlayer: audioPlayer)
        case .s     : Input.skipTrack(audioPlayer: audioPlayer)
        case .c     : Input.clearQueue(audioPlayer: audioPlayer)
        case .V     : Input.changeVolume(audioPlayer: audioPlayer, volumeUp: true)
        case .v     : Input.changeVolume(audioPlayer: audioPlayer, volumeUp: false)
        case .l     : Input.toggleLoop(audioPlayer: audioPlayer)
        case .q     : Input.quit(input: input, Exit: &Exit)

        default: break
    }

}
input.resume()

while !Exit {
    RunLoop.main.run(mode: .default, before: .distantFuture)
}

Terminal.shared.resetTerminal()