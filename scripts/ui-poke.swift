// Sends mouse clicks, drags and key presses, so the build can try the app's interface for real.
//
//   ui-poke click X Y | key CODE | drag X1 Y1 X2 Y2 | sleep SECONDS ...
//
// Coordinates are screen points from the top left. Needs permission to control the computer.
import ApplicationServices
import CoreGraphics
import Foundation

setbuf(stdout, nil)
print("ui-poke: accessibility trusted = \(AXIsProcessTrusted()), may post events = \(CGPreflightPostEventAccess())")

let source = CGEventSource(stateID: .hidSystemState)

func mouse(_ type: CGEventType, _ point: CGPoint) {
    CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?
        .post(tap: .cghidEventTap)
}

func pause(_ seconds: Double) {
    usleep(useconds_t(seconds * 1_000_000))
}

var arguments = Array(CommandLine.arguments.dropFirst())
func number() -> Double {
    guard !arguments.isEmpty, let value = Double(arguments.removeFirst()) else {
        print("ui-poke: expected a number"); exit(2)
    }
    return value
}

while !arguments.isEmpty {
    let command = arguments.removeFirst()
    switch command {
    case "click":
        let point = CGPoint(x: number(), y: number())
        mouse(.mouseMoved, point); pause(0.2)
        mouse(.leftMouseDown, point); pause(0.08)
        mouse(.leftMouseUp, point)
        print("ui-poke: clicked \(point)")
    case "key":
        let code = CGKeyCode(number())
        CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true)?.post(tap: .cghidEventTap)
        pause(0.05)
        CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)?.post(tap: .cghidEventTap)
        print("ui-poke: pressed key \(code)")
    case "drag":
        let from = CGPoint(x: number(), y: number())
        let to = CGPoint(x: number(), y: number())
        mouse(.mouseMoved, from); pause(0.3)
        mouse(.leftMouseDown, from); pause(0.5)
        let steps = 30
        for step in 1...steps {
            let t = CGFloat(step) / CGFloat(steps)
            mouse(.leftMouseDragged, CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t))
            pause(0.03)
        }
        // Linger over the destination so it has time to accept the drop.
        for wiggle in 0..<10 {
            mouse(.leftMouseDragged, CGPoint(x: to.x + CGFloat(wiggle % 2), y: to.y))
            pause(0.1)
        }
        mouse(.leftMouseUp, to)
        print("ui-poke: dragged \(from) to \(to)")
    case "sleep":
        pause(number())
    default:
        print("ui-poke: unknown command \(command)"); exit(2)
    }
}
