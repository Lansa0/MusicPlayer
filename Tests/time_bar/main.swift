import AVFoundation

let ABSOLUTE_WIDTH = 200

let file1: URL = URL(filePath: "")
let file2: URL = URL(filePath: "")
let file3: URL = URL(filePath: "")

func bar(currentTime: TimeInterval, duration: TimeInterval) {

    func formatTime(_ t: TimeInterval) -> String {
        let total = Int(t)
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    var timeWidth: Int

    let a = formatTime(currentTime)
    let b = formatTime(duration)

    // ━━━━━○---- xx:xx / xx:xx
    // 5 is the padding (4 white spaces + 1 slash)
    // ━━━━━○----1xx:xx2/3xx:xx4
    // Should also work with a longer time
    // ━━━━━○---- xxx:xx / xxx:xx
    timeWidth = a.count + b.count + 5

    let barWidth: Int = ABSOLUTE_WIDTH - timeWidth

    let progress : TimeInterval = currentTime / duration
    let left     : Int = max(0,Int(floor(progress * Double(barWidth)))-1)
    let right    : Int = barWidth - (left+1)

    print("\u{001B}[H\(String(repeating: "━", count: left))○\(String(repeating: "-", count: right)) \(a) / \(b)")
}

func skip(_ ap: AudioPlayer)  {Task{await ap.skip()}}
func Pause(_ ap: AudioPlayer) {Task{await ap.pause()}}


actor AudioPlayer: NSObject, AVAudioPlayerDelegate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var queue: [URL] = []
    private var currentPlayer: AVAudioPlayer?
    private var playing = false
    private var timer: Timer?

    func add(contentsOf url: URL) {
        queue.append(url)

        if !playing {
            playing = true
            Task { await play() }
        }
    }

    private func play() async {
        while let url = queue.first {

            do {
                let player = try AVAudioPlayer(contentsOf: url)
                player.delegate = self

                currentPlayer = player
                player.play()

                self.startTimer()

                await withCheckedContinuation { cont in
                    continuation = cont
                }

                currentPlayer = nil
                queue.removeFirst()

            } catch {
                print(error)
                exit(1)
            }
        }
        playing = false
    }

    func pause() {
        guard let player = currentPlayer else {return}
        if player.isPlaying {player.pause()}
        else {
            player.play()
            startTimer()
        }
    }

    func skip() {
        guard let player = currentPlayer else {return}
        player.stop()
        self.playerDidFinish()
    }


    private func startTimer() {
        Task {
            while let player = self.currentPlayer, player.isPlaying {
                bar(currentTime: player.currentTime, duration: player.duration)
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { await self.playerDidFinish() }
    }

    private func playerDidFinish() {
        continuation?.resume()
        continuation = nil
    }
}

print("\u{001B}[2J\u{001B}[H")

let ap = AudioPlayer()
Task {
    await ap.add(contentsOf: file3)
    await ap.add(contentsOf: file1)
}

var Exit: Bool = false

let input = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: .main)
input.setEventHandler {

    guard let c: String = readLine() else {return}

    if c == "p" {
        Pause(ap)
    }

    else if c == "s" {
        skip(ap)
    }

    else if c == "q" {
        Exit = true
    }

}
input.resume()

while !Exit {
    RunLoop.main.run(mode: .default, before: .distantFuture)
}