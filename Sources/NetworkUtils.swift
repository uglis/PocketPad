import AppKit
import CoreImage
import Darwin
import Foundation

enum NetworkUtils {
    /// Returns the preferred local IPv4 address (prefers Wi-Fi `en0`, then other `en*` interfaces).
    static func localIPv4Address() -> String {
        var addresses: [(name: String, ip: String)] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else {
            return "127.0.0.1"
        }
        defer { freeifaddrs(ifaddr) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let current = ptr {
            let interface = current.pointee
            let flags = Int32(interface.ifa_flags)
            let isUp = (flags & IFF_UP) != 0
            let isRunning = (flags & IFF_RUNNING) != 0
            let isLoopback = (flags & IFF_LOOPBACK) != 0

            if isUp && isRunning && !isLoopback,
               let addr = interface.ifa_addr,
               addr.pointee.sa_family == UInt8(AF_INET) {
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let result = getnameinfo(
                    addr,
                    socklen_t(addr.pointee.sa_len),
                    &hostname,
                    socklen_t(hostname.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                )
                if result == 0 {
                    let ip = String(cString: hostname)
                    let name = String(cString: interface.ifa_name)
                    if !ip.hasPrefix("169.254.") {
                        addresses.append((name: name, ip: ip))
                    }
                }
            }
            ptr = interface.ifa_next
        }

        if let en0 = addresses.first(where: { $0.name == "en0" }) {
            return en0.ip
        }
        if let en = addresses.first(where: { $0.name.hasPrefix("en") }) {
            return en.ip
        }
        return addresses.first?.ip ?? "127.0.0.1"
    }

    static func hostDisplayName() -> String {
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }

    static func generateQRCode(from string: String, size: CGFloat = 220) -> NSImage? {
        guard let data = string.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else {
            return nil
        }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let outputImage = filter.outputImage else { return nil }

        let extent = outputImage.extent.integral
        guard extent.width > 0, extent.height > 0 else { return nil }
        let scale = max(1, floor(size / extent.width))
        let transformed = outputImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        let context = CIContext(options: nil)
        guard let cgImage = context.createCGImage(transformed, from: transformed.extent) else {
            return nil
        }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: size, height: size))
        return image
    }
}
