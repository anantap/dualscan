import AppKit
import SwiftUI

/// Single keys for the main window. They are not menu shortcuts, because a
/// menu shortcut without ⌘ would also fire while typing a roll name.
enum KeyCommand: Equatable {
    case previous(extend: Bool), next(extend: Bool)
    case toggleQueue, startQueue, rotate, beforeAfter, eject, cancel

    /// What a key press means, or nil to let it through.
    static func from(_ e: NSEvent) -> KeyCommand? {
        let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
        let shift = mods == [.shift]
        guard mods.isEmpty || shift else { return nil }
        switch e.keyCode {
        case 123: return .previous(extend: shift)       // ←
        case 124: return .next(extend: shift)           // →
        case 36, 76: return mods.isEmpty ? .startQueue : nil   // Return, Enter
        case 53: return .cancel                         // Esc
        default: break
        }
        guard mods.isEmpty else { return nil }
        switch e.charactersIgnoringModifiers?.lowercased() {
        case "q": return .toggleQueue
        case "r": return .rotate
        case "b": return .beforeAfter
        case "e": return .eject
        default: return nil
        }
    }
}

extension AppModel {
    /// Does what a key asks; returns false when it does not apply right now,
    /// so the key goes on to the rest of the window.
    @discardableResult
    func perform(_ k: KeyCommand) -> Bool {
        guard mode == .working else { return false }
        switch k {
        case .previous(let extend), .next(let extend):
            let step = { if case .next = k { return 1 } else { return -1 } }()
            let i = selectedIndex + step
            guard frames.indices.contains(i) else { return true }
            select(i, modifiers: extend ? .shift : [])
        case .toggleQueue:
            if !selectedToQueue.isEmpty { selectedToQueue.forEach(addToQueue) }
            else if !selectedInQueue.isEmpty { selectedInQueue.forEach(removeFromQueue) }
        case .startQueue:
            guard !queue.isEmpty, !queueRunning, !previewRunning else { return false }
            startQueue()
        case .rotate:
            guard selected.display != nil else { return false }
            rotateSelected()
        case .beforeAfter:
            guard selected.isScanned else { return false }
            showBefore.toggle()
        case .eject:
            guard capabilities.eject, !queueRunning, !previewRunning else { return false }
            eject()
        case .cancel:
            guard picking != nil else { return false }
            picking = nil
        }
        return true
    }
}

/// Listens for the single keys while the main window is in front, nothing is
/// being typed and no sheet or popover is open.
struct KeyboardCommands: ViewModifier {
    @Environment(AppModel.self) private var model
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
                    // Only the main window itself: not a popover, sheet or alert.
                    guard let window = e.window, window === NSApp.mainWindow, window.isKeyWindow, window.attachedSheet == nil,
                          !(window.firstResponder is NSText), !model.showExport,
                          let k = KeyCommand.from(e) else { return e }
                    return model.perform(k) ? nil : e
                }
            }
            .onDisappear {
                if let monitor { NSEvent.removeMonitor(monitor) }
            }
    }
}
