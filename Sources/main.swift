// v1.3.2

import AVFoundation
import Collections
import ArgumentParser

let DEBUG: Bool = false

let v       : UInt8 = 118
let s       : UInt8 = 115
let q       : UInt8 = 113
let p       : UInt8 = 112
let k       : UInt8 = 107
let j       : UInt8 = 106
let btick   : UInt8 = 96
let V       : UInt8 = 86
let down    : UInt8 = 66
let up      : UInt8 = 65
let space   : UInt8 = 32
let enter   : UInt8 = 10

let BORDER_OFFSET     : Int = 1

let MINIMUM_ROWS      : Int = 5
let MINIMUM_CLOUMNS   : Int = 30

let DOWN_ARROW        : String = "\u{001B}[32m▾\u{001B}[0m"
let RIGHT_ARROW       : String = "▸"

let FILE_NAME_OFFSET  : Int = 5
let QUEUE_NAME_OFFSET : Int = 3

let FILE_HEADER       : String = "FILE━TREE"
let QUEUE_HEADER      : String = "QUEUE━━━━"

/* TODO

Command line arguments
    Music Folder Pathing
Add docs for functions
Work on error handling
Ncurses :>

*/

///////////////////////////////////////////////////////////////////////////
//[ARGUMENT/PARSER]////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////

struct Arguments : ParsableCommand {
    @Flag var scan: Bool = false
}

///////////////////////////////////////////////////////////////////////////
//[TERMINAL]///////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////

class Terminal {
    nonisolated(unsafe) static let shared = Terminal()

    private var OriginalTerm = termios()

    var tooSmall  : Bool = false
    var showQueue : Bool = false

    var rows    : Int = 0
    var columns : Int = 0

    func setupTerminal(view: inout View, rootNode: Node) {
        tcgetattr(STDIN_FILENO, &OriginalTerm)
        print("\u{001B}[?1049h\u{001B}[?25l") // alternate buffer + hide cursor

        // Set terminal to non canonical
        var CopyTerm = OriginalTerm
        CopyTerm.c_lflag &= ~(UInt(ICANON | ECHO))
        CopyTerm.c_cc.6 = 1
        CopyTerm.c_cc.5 = 0
        tcsetattr(STDIN_FILENO, TCSANOW, &CopyTerm)

        if let (rows, columns) = getTerminalSize() {
            self.rows = rows  - 2 - (DEBUG ? 1 : 0)
            self.columns = columns - 2

            view.viewRange = (1, min(self.rows, view.totalRange))

            if rows < MINIMUM_ROWS || columns < MINIMUM_CLOUMNS {
                self.tooSmall = true
                Output.tooSmall()
            } else {
                Output.drawBorder(rows: self.rows, columns: self.columns)

                view.lineDeque.append(contentsOf: rootFile.getNodes(range: view.viewRange))
                Output.fillTree(lines: view.lineDeque)
                Output.setDot(currentLineHeight: 1, previousLineHeight: 1)
            }

            Output.debugLine(view: view)
        }

    }

    func resetTerminal() {
        print("\u{001B}[?25h\u{001B}[?1049l", terminator: "")  // show cursor + original buffer
        tcsetattr(STDIN_FILENO, TCSANOW, &OriginalTerm)
        exit(0)
    }

    func onResize(view: inout View, rootNode: Node, audioPlayer: AudioPlayer) {
        if let (rows, columns) = getTerminalSize() {
            if rows < MINIMUM_ROWS || columns < MINIMUM_CLOUMNS {
                self.tooSmall = true
                Output.tooSmall()

            } else {

                let expanding: Bool = self.rows < (rows - 2)

                self.tooSmall = false
                self.rows = rows - 2 - (DEBUG ? 1 : 0)
                self.columns = columns - 2
                Output.drawBorder(rows: self.rows, columns: self.columns)

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
                        Output.fillQueue(lines: Deque<String>(queue.map{$0.name}))
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
    }

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
//[FILE HANDLER]///////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////

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

    func toggleActive() {active = !active}
    func add(_ node: Node) {self.nodes.append(node)}

    func sort() {
        self.nodes.sort {
            let left = ($0.discNumber ?? Int.max, $0.trackNumber ?? Int.max, $0.name.lowercased())
            let right = ($1.discNumber ?? Int.max, $1.trackNumber ?? Int.max, $1.name.lowercased())
            return left < right
        }
    }

    // Traversal functions

    /// - Returns: Number of active nodes under the root node
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
        rootNode.toggleActive()

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

            encode(root: rootNode)

            return rootNode
        } catch {
            exit(1)
        }
    }
    exit(1)
}

func encode(root: Node) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    do {
        let data = try encoder.encode(root)

        let fileManager = FileManager.default
        let home = FileManager.default.homeDirectoryForCurrentUser
        let configPath = home.appending(path: ".config/Lansa0MusicPlayer/files.json", directoryHint: .notDirectory)

        if !fileManager.fileExists(atPath: configPath.path()) {
            let parent = configPath.deletingLastPathComponent()
            if !fileManager.fileExists(atPath: parent.path()) {
                do {
                    try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
                } catch  {
                    print(error)
                    exit(1)
                }
            }

            let defaultData = "{}".data(using: .utf8)
            fileManager.createFile(atPath: configPath.path(), contents: defaultData)
        }

        try data.write(to: configPath)
    } catch {
        print(error)
        exit(1)
    }
}

func decode() -> Node {
    let decoder = JSONDecoder()

    let home = FileManager.default.homeDirectoryForCurrentUser
    let configPath = home.appending(path: ".config/Lansa0MusicPlayer/files.json", directoryHint: .notDirectory)

    do {
        let data = try Data(contentsOf: configPath)
        let root = try decoder.decode(Node.self, from: data)
        root.toggleActive()

        return root
    } catch {
        print("Error Decoding")
        exit(1)
    }
}

///////////////////////////////////////////////////////////////////////////
//[AUDIO PLAYER]///////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////

actor AudioPlayer: NSObject, AVAudioPlayerDelegate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var queue = Deque<Node>()
    private var playing = false
    private var currentPlayer: AVAudioPlayer?
    private var currentNode: Node?
    private var volume: Float = 1.0

    func add(contentsOf nodes: [Node]) {
        queue.append(contentsOf: nodes)

        if !playing {
            playing = true
            Task { await play() }
        }
    }

    private func play() async {
        while let node = queue.first {

            currentNode = node

            if Terminal.shared.showQueue {
                Output.fillQueue(lines: Deque<String>(queue.map{$0.name}))
            }

            do {
                let player = try AVAudioPlayer(contentsOf: node.url!)
                player.delegate = self

                currentPlayer = player
                player.setVolume(volume, fadeDuration: 0)
                player.play()

                await withCheckedContinuation { cont in
                    continuation = cont
                }

                currentPlayer = nil

            } catch {
                // Do something later
            }

            queue.removeFirst()
        }

        if Terminal.shared.showQueue {
            Output.fillQueue(lines: Deque<String>(queue.map{$0.name}))
        }
        playing = false
    }

    func pause() {
        guard let player = currentPlayer else {return}
        if player.isPlaying { player.pause()}
        else { player.play()}
    }

    func skip() {
        guard let player = currentPlayer else {return}
        player.stop()
        self.playerDidFinish()
    }

    func volume(up: Bool) {
        guard let player = currentPlayer else {return}

        if up {volume = min(1.0, volume + 0.05)}
        else  {volume = max(0.0, volume - 0.05)}

        player.setVolume(volume, fadeDuration: 0)
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { await self.playerDidFinish() }
    }

    private func playerDidFinish() {
        continuation?.resume()
        continuation = nil

    }

}

///////////////////////////////////////////////////////////////////////////
//[OUTPUT]/////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////

struct Output {

    // Trust me, this works
    static func drawBorder(rows: Int, columns: Int) {
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

    static func fillQueue(lines: Deque<String>) {
        let emptyLine = (String(repeating: " ", count: Terminal.shared.columns))
        for rowNum in 0..<Terminal.shared.rows {
            // Need the extra +1 because rowNum starts at 0
            let emptyCursorPos = "\u{001B}[\(rowNum + BORDER_OFFSET + 1);2H"
            let lineCursorPos = "\u{001B}[\(rowNum + BORDER_OFFSET + 1);\(QUEUE_NAME_OFFSET)H"

            if rowNum == 0 && lines.count > 0 {
                print(
                    emptyCursorPos, emptyLine,
                    lineCursorPos, "🎵 ", lines[rowNum].prefix(Terminal.shared.columns - 4), // 4 b/c emojis are weird sizes
                    separator: ""
                )
            } else if rowNum < lines.count {
                print(
                    emptyCursorPos,emptyLine,
                    lineCursorPos,lines[rowNum].prefix(Terminal.shared.columns - 1),
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
        if !DEBUG {return}
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

}

///////////////////////////////////////////////////////////////////////////
//[INPUT]//////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////

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
    static func changeVolume(audioPlayer : AudioPlayer, volumeUp: Bool) {Task {await audioPlayer.volume(up: volumeUp)}}

    static func switchView(view: View, audioPlayer: AudioPlayer) {
        Terminal.shared.showQueue = !Terminal.shared.showQueue
        Output.switchHeader(showQueue: Terminal.shared.showQueue)

        if Terminal.shared.showQueue {
            let semaphore = DispatchSemaphore(value: 0)
            Task {
                let queue = await audioPlayer.queue
                Output.fillQueue(lines: Deque<String>(queue.map{$0.name}))
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

let rootFile: Node = args.scan ? scanFiles() : decode()
let audioPlayer = AudioPlayer()
var filesView = View(totalRange: rootFile.numActiveNodes())

Terminal.shared.setupTerminal(view: &filesView, rootNode: rootFile)
signal(SIGINT)   {_ in Terminal.shared.resetTerminal()}
signal(SIGWINCH) {_ in Terminal.shared.onResize(view: &filesView, rootNode: rootFile, audioPlayer: audioPlayer)}

var Exit: Bool = false

// Using DispatchSource because there's a yielding issue with the line
// read(STDIN_FILENO, &buff, 3) which affects the AVAudioPlayer
// so having a regular while loop doesn't work
let input = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: .main)
input.setEventHandler {

    var buff = [UInt8](repeating: 0, count: 3)
    let n = read(STDIN_FILENO, &buff, 3)
    let key: UInt8

    if n < 1 || Terminal.shared.tooSmall { return }
    else if n == 3 && buff[0] == 27 && buff[1] == 91 {key = buff[2]} // check if arrow key was pressed
    else {key = buff[0]}

    let showQueue: Bool = Terminal.shared.showQueue

    switch key {
        case k,up   : if !showQueue {Input.scrollUp(view: &filesView, rootFile: rootFile)}
        case j,down : if !showQueue {Input.scrollDown(view: &filesView, rootFile: rootFile)}
        case space  : if !showQueue {Input.expandFolder(view: &filesView, rootFile: rootFile)}
        case enter  : if !showQueue {Input.playFiles(view: &filesView,  rootFile: rootFile, audioPlayer: audioPlayer)}
        case p      : Input.pauseTrack(audioPlayer: audioPlayer)
        case s      : Input.skipTrack(audioPlayer: audioPlayer)
        case V      : Input.changeVolume(audioPlayer: audioPlayer, volumeUp: true)
        case v      : Input.changeVolume(audioPlayer: audioPlayer, volumeUp: false)
        case btick  : Input.switchView(view: filesView, audioPlayer: audioPlayer)
        case q      : Input.quit(input: input, Exit: &Exit)
        default: break
    }
}
input.resume()

while !Exit {
    RunLoop.main.run(mode: .default, before: .distantFuture)
}

Terminal.shared.resetTerminal()