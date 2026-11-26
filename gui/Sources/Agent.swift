// Talking to the daemon: one request/response round trip over its socket.

import Cocoa

let socketPath = NSHomeDirectory() + "/Library/Application Support/logilight/control.sock"
let languageKey = "language"

/// One request/response round trip with the daemon.
func sendToAgent(_ command: String) -> [String: Any]? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    defer { close(fd) }

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(socketPath.utf8)
    guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
    withUnsafeMutablePointer(to: &address.sun_path) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: pathBytes.count + 1) { chars in
            for (index, byte) in pathBytes.enumerated() {
                chars[index] = CChar(bitPattern: byte)
            }
            chars[pathBytes.count] = 0
        }
    }

    let connected = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
            connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard connected == 0 else { return nil }

    let request = Array((command + "\n").utf8)
    guard write(fd, request, request.count) == request.count else { return nil }

    var buffer = [UInt8]()
    var chunk = [UInt8](repeating: 0, count: 4096)
    while true {
        let count = read(fd, &chunk, chunk.count)
        if count <= 0 {
            break
        }
        buffer.append(contentsOf: chunk[0 ..< count])
        if chunk[count - 1] == 0x0A {
            break
        }
    }
    guard let text = String(bytes: buffer, encoding: .utf8),
          let data = text.data(using: .utf8) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

func hexString(_ color: NSColor) -> String {
    let rgb = color.usingColorSpace(.deviceRGB) ?? NSColor.white
    let red = Int((rgb.redComponent * 255).rounded())
    let green = Int((rgb.greenComponent * 255).rounded())
    let blue = Int((rgb.blueComponent * 255).rounded())
    return String(format: "%02x%02x%02x", red, green, blue)
}

func nsColor(hex: String) -> NSColor {
    let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
    guard cleaned.count == 6, let value = UInt32(cleaned, radix: 16) else { return .white }
    return NSColor(
        srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
        green: CGFloat((value >> 8) & 0xFF) / 255,
        blue: CGFloat(value & 0xFF) / 255,
        alpha: 1
    )
}
