import Foundation

var OriginalTerm = termios()

func enableScrolling(ogT: inout termios) {
    tcgetattr(STDIN_FILENO, &ogT)
    print("\u{001B}[?1049h\u{001B}[?25l")

    var CopyTerm = ogT
    CopyTerm.c_lflag &= ~(UInt(ICANON | ECHO))
    CopyTerm.c_cc.6 = 1
    CopyTerm.c_cc.5 = 0
    tcsetattr(STDIN_FILENO, TCSANOW, &CopyTerm)

    print("\u{001B}[?1000h")
    print("\u{001B}[?1006h")
}

func disableScrolling(ogT: inout termios) {
    print("\u{001B}[?25h\u{001B}[?1049l", terminator: "")
    tcsetattr(STDIN_FILENO, TCSANOW, &ogT)

    print("\u{001B}[?1000l")
    print("\u{001B}[?1006l")
}

func getScroll(buffer: [UInt8]) -> UInt8 {
    var index = 3
    var cb = ""

    while index < buffer.count, buffer[index] != 0x3B {
        let scaler = UnicodeScalar(buffer[index])
        cb.append(Character(scaler))
        index += 1
    }

    return UInt8(cb) ?? 0
}

enableScrolling(ogT: &OriginalTerm)
signal(SIGINT) {_ in disableScrolling(ogT: &OriginalTerm);exit(0)}

while true {

    var buff = [UInt8](repeating: 0, count: 32)
    let n = read(STDIN_FILENO, &buff, 32)
    var key: UInt8 

    if n < 1 {continue}
    else if n == 3 && buff.starts(with: [27,91]) {key = buff[2]}
    else if buff.starts(with: [0x1B, 0x5B, 0x3C]) {key = getScroll(buffer: buff) + 3} // Temp +3 bc of conflitions
    else {key = buff[0]}

    switch key {
        case 107, 65, 67: print("SCROLL UP")
        case 106, 66, 68: print("SCROLL DOWN")
        default: break
    }

}

