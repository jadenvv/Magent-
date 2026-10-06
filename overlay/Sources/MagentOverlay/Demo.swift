import AppKit

/// Scripted session for eyeballing the overlay without an agent. Goes through the same
/// line parser as real input, so it doubles as a protocol smoke test.
@MainActor
enum Demo {
    static func run(_ controller: OverlayController) {
        let frame = NSScreen.screens.first?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let w = Int(frame.width), h = Int(frame.height)
        let fieldX = w * 35 / 100, fieldY = h * 40 / 100
        let buttonX = w * 55 / 100, buttonY = h * 55 / 100

        let script: [(Double, String)] = [
            (0.3, #"{"type":"status","state":"running"}"#),
            (0.0, #"{"type":"log","text":"Task: rename today's screenshots to report-N.png"}"#),
            (0.6, #"{"type":"action","text":"Shell: ls ~/Desktop/Screenshot*.png"}"#),
            (0.7, #"{"type":"log","text":"3 files found","level":"ok"}"#),
            (0.5, #"{"type":"action","text":"Open the File menu","rect":{"x":60,"y":4,"w":36,"h":20}}"#),
            (0.5, #"{"type":"click","x":78,"y":14}"#),
            (0.8, #"{"type":"action","text":"Set value of the Name field","rect":{"x":\#(fieldX),"y":\#(fieldY),"w":240,"h":26}}"#),
            (0.8, #"{"type":"log","text":"Name field set to report-1.png","level":"ok"}"#),
            (0.5, #"{"type":"action","text":"Press Rename","rect":{"x":\#(buttonX),"y":\#(buttonY),"w":90,"h":30}}"#),
            (0.4, #"{"type":"click","x":\#(buttonX + 45),"y":\#(buttonY + 15)}"#),
            (0.6, #"{"type":"log","text":"Verify: file renamed","level":"ok"}"#),
            (0.6, #"{"type":"confirm","id":"trash-1","text":"Move 2 duplicate screenshots to the Trash?"}"#),
            (4.0, #"{"type":"action","text":"Shell: mv duplicates to ~/.Trash"}"#),
            (0.8, #"{"type":"log","text":"Done in 4 actions, 1 model call","level":"ok"}"#),
            (0.3, #"{"type":"status","state":"done"}"#),
            (0.0, #"{"type":"caption","text":"Demo finished. Press ⌃⌥⌘K to quit."}"#),
        ]

        Task { @MainActor in
            for (delay, line) in script {
                try? await Task.sleep(for: .seconds(delay))
                // Honor the pause hotkey so it can be tried out in the demo.
                while controller.isPaused { try? await Task.sleep(for: .milliseconds(100)) }
                controller.handle(line: line)
            }
        }
    }
}
