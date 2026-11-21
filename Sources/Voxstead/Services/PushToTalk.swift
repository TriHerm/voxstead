import Carbon
import Foundation

@MainActor
final class PushToTalk {
    private var registration: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let onChange: (Bool) -> Void
    private var isPressed = false

    init(onChange: @escaping (Bool) -> Void) { self.onChange = onChange }

    func register() throws {
        guard registration == nil else { return }
        var specification = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        let target = GetApplicationEventTarget()
        let result = InstallEventHandler(target, { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr, id.signature == 0x434C4F53, id.id == 1 else {
                return OSStatus(eventNotHandledErr)
            }
            let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            let owner = Unmanaged<PushToTalk>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { owner.changed(pressed) }
            return noErr
        }, specification.count, &specification, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard result == noErr else { throw WorkspaceError("Could not enable the dictation shortcut.") }

        let id = EventHotKeyID(signature: 0x434C4F53, id: 1)
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_D), UInt32(controlKey | optionKey), id, target, 0, &registration)
        guard status == noErr else {
            if let handler { RemoveEventHandler(handler) }
            handler = nil
            throw WorkspaceError("Could not register ⌃⌥D. It may already be in use.")
        }
    }

    private func changed(_ pressed: Bool) {
        guard pressed != isPressed else { return }
        isPressed = pressed
        onChange(pressed)
    }
}
