/*
YES i know this is very messy
YES i know this doesn't match how the main code flows
YES i know this may not be the most optimal solution
YES i know i have the writing skills of an 9th grader
YES i'm stupid
NOO i will not clean this

Testing for terminal window size changed
- Render correctly sized borders
- Modify the view
*/

import Foundation

var ROWS    : Int = 0
var COLUMNS : Int = 0

struct View {
    var lines: [String] = []
    var relativeLineNum: Int = 1
    var range: (upper: Int, lower: Int) = (0,0)
}

var view = View()

var tiny: Bool = false

let MAX: Int = 50
let PlaceHolderLines = (1...MAX).map { "LINE \($0)" }

var OriginalTerm = termios()
tcgetattr(STDIN_FILENO, &OriginalTerm)
print("\u{001B}[?1049h\u{001B}[?25l") // alternate buffer (how tf did it take me so long to find this) + hide cursor

// Set terminal to non canonical
var CopyTerm = OriginalTerm
CopyTerm.c_lflag &= ~(UInt(ICANON | ECHO))
CopyTerm.c_cc.6 = 1
CopyTerm.c_cc.5 = 0
tcsetattr(STDIN_FILENO, TCSANOW, &CopyTerm)

func onResize(ROWS: inout Int, COLUMNS: inout Int, view: inout View, tiny: inout Bool) {
    if let (rows, columns) = getTerminalSize() {
        if rows < 5 || columns < 13 {
            tiny = true
            tooSmall()
        } else {
            tiny = false

            let expanding = ROWS < (rows - 3)
            ROWS = rows - 3         // -3 Accounting for the border + debugging line (-2 without debug line)
            COLUMNS = columns - 2   // -2 For Border

            drawBorder(rows: ROWS, columns: COLUMNS)

            // Effectively if view.range == nil
            // Only runs once then never again (hopefully)
            if view.range == (0,0) {
                view.range = (1,min(ROWS,MAX))
            }

            // Monster Resize logic (i'm too small brain to simplify right now)
            else {

                /* EXPAND WINDOW SIZE
                INTRO:

                ROWS = 10, Range = (30,39)
                EXPAND RANGE BY 5
                ROWS = 15, Range = (25,39)
                Simply subtract (39 - 15) + 1 to get 25 rows, with 0 leftover

                ROWS = 10, Range = (5,14)
                EXPAND RANGE BY 10
                ROWS = 20, Range = (1,21)
                Subtracting (14 - 20) + 1 gives -5, but we can't have negative
                rows so we need to find (-5 + x = 1 -> x = 1 + 5 = 6) so our
                leftover is now 6. We set the upper view range to 1 and then add
                our lower range to leftover + 1, hence (14 + 6 + 1 = 21)

                FORMULA:

                So getting the new view range should be

                Upper = Lower - RANGE + 1
                if Upper < 1 then
                    Leftover = 1 - Upper
                    Upper = 1
                    Lower = Lower + Leftover + 1
                end

                EXAMPLES:

                ex 1.
                (Upper: 30, Lower: 39) : Range = 10
                Range += 5 (Range = 15)
                Upper = 39 - 15 + 1 = 25
                Upper > 1
                ∴ Leftover = 0
                ∴ Upper = 25
                ∴ Lower = 39
                (Upper: 25, Lower: 39) : Range = 15

                ex 2.
                (Upper: 5, Lower: 14) : Range = 10
                Range += 10 (Range = 20)
                Upper = 14 - 20 + 1 = -5
                Upper < 1
                ∴ Leftover = 1 - (-5) = 6
                ∴ Upper = 1
                ∴ Lower = 14 + 6 + 1 = 21
                (Upper: 1, Lower: 21) : Range = 20

                SPECIAL CASE:

                If Upper is already 1 then lower is just equal to the range

                ADJUSTING RELATIVE LINE NUMBER
                INTRO:

                ROWS = 10, Range = (30,39), RLN = 2 -> Pointing to 31
                EXPAND RANGE BY 5
                ROWS = 15, Range = (25,39), RLN = 7 -> Remains pointing to 31
                Add the range increase to the relative line number

                ROWS = 10, Range = (5,14), RLN = 7 -> Pointing to 11
                EXPAND RANGE BY 10
                ROWS = 20, Range = (1,21), RLN = 10 -> Remains pointing to 11
                Just adding the increase is gonna give 17 so that won't work

                Instead if we store what the value of the RLN is pointing
                to and then subtract that by the new upper bound we can get
                the new relative line number. Since the RLN was pointing at
                11 and our new upper range is 1 we get (11 - 1 = 10) which
                can be simplified to RLN = Point - 1.
                But by the first example we see that (31 - 25 = 6) which
                isn't 7. So we check if there was any leftovers, if none
                add 1

                EXTENDED FORMULA:

                Point = Upper + RLN - 1
                Upper = Lower - RANGE + 1
                if Upper < 1 then
                    Leftover = 1 - Upper
                    Upper = 1
                    Lower = Lower + Leftover + 1
                    RLN = Point - 1
                else
                    RLN = Point - Upper + 1
                end

                ALTERNATIVE METHOD
                INTRO:

                ROWS = 10, Range = (30,39), MAX 50
                EXPAND RANGE BY 5
                ROWS = 15, Range = (30,44)
                Add the extension to the lower view range or 
                upper + range - 1 

                ROWS = 10, Range = (30,39), MAX 40
                EXPAND RANGE BY 5
                ROWS = 15, Range = (26,40)
                Add the extended range to the lower view
                (30 + 15 = 45) clamp that to 40 with 5 leftover then
                subtract the leftover to the upper and add 1
                (30 - 5 + 1 = 26)

                FORMULA:

                Lower = Upper + ROWS
                if Lower > MAX then
                    Leftover = Lower - MAX
                    Lower = MAX
                    Upper = Upper - Leftover + 1
                end

                */
                if expanding {
                    // if view.range.upper != 1 {
                    //     let Point = view.range.upper + view.relativeLineNum - 1
                    //     view.range.upper = view.range.lower - ROWS + 1
                    //     if view.range.upper < 1 {
                    //         let Leftover = 1 - view.range.upper
                    //         view.range.upper = 1
                    //         view.range.lower += Leftover + 1
                    //         view.relativeLineNum = Point - 1
                    //     } else {
                    //         view.relativeLineNum = Point - view.range.upper + 1
                    //     }
                    // } else {
                    //     view.range.lower = min(MAX,ROWS)
                    // }

                    if view.range.upper > 1 {
                        let Point = view.range.upper + view.relativeLineNum - 1
                        view.range.lower = view.range.upper + ROWS
                        if view.range.lower > MAX {
                            let leftover = view.range.lower - MAX
                            view.range.lower = MAX
                            view.range.upper = max(view.range.upper + 1 - leftover,1)
                            view.relativeLineNum = Point - view.range.upper + 1
                        }
                    } else {
                        view.range.lower = min(MAX,ROWS)
                    }

                }

                /* SHRINK WINDOW SIZE
                INTRO:

                ROWS = 15, Range = (25,39)
                SHRINK RANGE BY 5
                ROWS = 10, Range = (30,39)

                The upper view range should be locked when
                shrinking

                */
                else {
                    // if (view.range.lower - view.range.upper + 1) < ROWS {
                    if !(view.range.upper == 1 && view.range.lower == MAX) {
                        view.range.lower = view.range.upper + ROWS - 1
                    } else {
                        view.range.lower = min(MAX,ROWS)
                    }
                    view.relativeLineNum = min(view.relativeLineNum,ROWS)
                }

                view.lines = Array(PlaceHolderLines[view.range.upper-1..<view.range.lower])
                fill(lines: view.lines, ROWS: ROWS, COLUMNS: COLUMNS)
                setDot(currentLineHeight: view.relativeLineNum, previousLineHeight: view.relativeLineNum)

            }

            debugLine(ROWS: ROWS, view: view,COLUMNS: COLUMNS)
            fflush(stdout)
        }
    }
}

func getTerminalSize() -> (rows: Int, columns: Int)? {
    var w = winsize()
    if ioctl(STDOUT_FILENO, TIOCGWINSZ, &w) == 0 {
        let rows    = Int(w.ws_row)
        let columns = Int(w.ws_col)
        return (rows,columns)
    }
    return nil
}

func drawBorder(rows: Int, columns: Int) {
    print("\u{001B}[H┏FILE━TREE━\(String(repeating: "━", count: columns-10))┓")
    for _ in 0..<rows {print("┃\(String(repeating: " ", count: columns))┃")}
    print("┗\(String(repeating: "━", count: columns))┛",terminator: "")

}

func debugLine(ROWS: Int, view: View, COLUMNS: Int) {
    print(
        "\u{001B}[\(ROWS+3);H",
        String(repeating: " ",count: COLUMNS+2),
        "\u{001B}[\(ROWS+3);H",
        "ROWS: \(ROWS), UPPER: \(view.range.upper), LOWER : \(view.range.lower), LINE NUM : \(view.relativeLineNum)",
        separator: "",
        terminator: ""
    )
}

func fill(lines: [String], ROWS: Int, COLUMNS: Int) {
    let emptyLine = String(repeating: " ", count: COLUMNS-4)
    for i in 0..<ROWS {
        let cursorPos = "\u{001B}[\(i+2);5H"
        if i < lines.count {
            print(cursorPos,emptyLine,cursorPos,lines[i],separator: "")
        } else {
            print(cursorPos,emptyLine,separator: "")
        }
    }
}

func tooSmall() {
    print("\u{001B}[2J\u{001B}[HTOO SMALL!")
}

func setDot(currentLineHeight: Int, previousLineHeight: Int) {
    print("\u{001B}[\(previousLineHeight+1);2H  \u{001B}[\(currentLineHeight+1);2H •")
}

func scrollUp(view: inout View, ROWS: Int, COLUMNS: Int) {
    if view.relativeLineNum == 1 {
        if view.range.upper == 1 { return }

        view.range.lower -= 1
        view.range.upper -= 1
        view.lines = Array(PlaceHolderLines[view.range.upper-1..<view.range.lower])
        fill(lines: view.lines, ROWS: ROWS, COLUMNS: COLUMNS)

    } else {
        view.relativeLineNum -= 1
        setDot(currentLineHeight: view.relativeLineNum, previousLineHeight: view.relativeLineNum + 1)
    }

    debugLine(ROWS: ROWS, view: view,COLUMNS: COLUMNS)
    fflush(stdout)
}

func scrollDown(view: inout View, ROWS: Int, COLUMNS: Int) {
    if view.relativeLineNum == MAX {
        return
    } else if view.relativeLineNum == ROWS {
        if view.range.lower == MAX { return }

        view.range.upper += 1
        view.range.lower += 1
        view.lines = Array(PlaceHolderLines[view.range.upper-1..<view.range.lower])
        fill(lines: view.lines, ROWS: ROWS, COLUMNS: COLUMNS)

    } else {
        view.relativeLineNum += 1
        setDot(currentLineHeight: view.relativeLineNum, previousLineHeight: view.relativeLineNum - 1)
    }

    debugLine(ROWS: ROWS, view: view,COLUMNS: COLUMNS)
    fflush(stdout)
}

signal(SIGWINCH) { _ in onResize(ROWS: &ROWS, COLUMNS: &COLUMNS, view: &view, tiny: &tiny)}
onResize(ROWS: &ROWS, COLUMNS: &COLUMNS, view: &view, tiny: &tiny)

if !tiny {
    view.lines = Array(PlaceHolderLines[view.range.upper-1..<view.range.lower])
    fill(lines: view.lines, ROWS: ROWS, COLUMNS: COLUMNS)
    setDot(currentLineHeight: 1, previousLineHeight: 1)
    // fflush(stdout)
}

let k: UInt8 = 107
let j: UInt8 = 106

var shouldExit: Bool = false
let input = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: .main)
input.setEventHandler {

    var buff = [UInt8](repeating: 0, count: 1)
    let n = read(STDIN_FILENO, &buff, 1)
    if n < 1 || tiny { return }

    switch buff[0] {
        case k: scrollUp(view: &view, ROWS: ROWS, COLUMNS: COLUMNS)
        case j: scrollDown(view: &view, ROWS: ROWS, COLUMNS: COLUMNS)
            // view.relativeLineNum = min(view.relativeLineNum + 1, ROWS)
            // debugLine(ROWS: ROWS, view: view,COLUMNS: COLUMNS)
            // fflush(stdout)

        case 10:
            shouldExit = true
            input.cancel()
            CFRunLoopStop(CFRunLoopGetCurrent())

        default: break
    }

}
input.resume()

while !shouldExit {
    RunLoop.main.run(mode: .default, before: .distantFuture)
}

print("\u{001B}[?25h\u{001B}[?1049l", terminator: "")  // show cursor + original buffer
tcsetattr(STDIN_FILENO, TCSANOW, &OriginalTerm)