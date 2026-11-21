import CryptoKit
import Foundation
import Network

final class WebSocketServer {
    private let queue = DispatchQueue(label: "com.xinque.pocketpad.server", qos: .userInteractive)
    private var listener: NWListener?
    private var clients: [ObjectIdentifier: ClientSession] = [:]
    private let input: InputController
    private let htmlProvider: () -> Data
    private let iconPngData: Data?
    private var cachedRawHTML: Data?
    private var cachedGzipHTML: Data?

    private(set) var port: UInt16
    var requirePIN: Bool = true
    var pinCode: String
    var onClientsChanged: ((Int) -> Void)?
    var onServerReady: ((UInt16) -> Void)?

    init(port: UInt16 = 8765, pinCode: String, input: InputController, htmlProvider: @escaping () -> Data, iconPngData: Data?) {
        self.port = port
        self.pinCode = pinCode
        self.input = input
        self.htmlProvider = htmlProvider
        self.iconPngData = iconPngData
    }

    func start() {
        queue.async { [weak self] in
            self?.tryStart(startingPort: self?.port ?? 8765, attemptsLeft: 10)
        }
    }

    private func tryStart(startingPort: UInt16, attemptsLeft: Int) {
        guard attemptsLeft > 0, let nwPort = NWEndpoint.Port(rawValue: startingPort) else { return }
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = 15
        let params = NWParameters(tls: nil, tcp: tcpOptions)
        params.allowLocalEndpointReuse = true

        do {
            let listener = try NWListener(using: params, on: nwPort)
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.port = startingPort
                    DispatchQueue.main.async {
                        self.onServerReady?(startingPort)
                    }
                case .failed:
                    listener.cancel()
                    self.tryStart(startingPort: startingPort &+ 1, attemptsLeft: attemptsLeft - 1)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] conn in
                self?.handleNewConnection(conn)
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            tryStart(startingPort: startingPort &+ 1, attemptsLeft: attemptsLeft - 1)
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.listener?.cancel()
            self.listener = nil
            for session in self.clients.values {
                session.close()
            }
            self.clients.removeAll()
            self.notifyClientCount()
        }
    }

    func disconnectAllClients() {
        queue.async { [weak self] in
            guard let self else { return }
            for session in self.clients.values {
                session.close()
            }
            self.clients.removeAll()
            self.notifyClientCount()
        }
    }

    private func handleNewConnection(_ connection: NWConnection) {
        let session = ClientSession(
            connection: connection,
            queue: queue,
            server: self,
            input: input
        )
        let id = ObjectIdentifier(session)
        clients[id] = session
        session.onClosed = { [weak self] in
            guard let self else { return }
            self.clients.removeValue(forKey: id)
            self.notifyClientCount()
        }
        session.start()
    }

    fileprivate func notifyClientCount() {
        let activeCount = clients.values.filter { $0.isAuthenticatedWebSocket }.count
        DispatchQueue.main.async { [weak self] in
            self?.onClientsChanged?(activeCount)
        }
    }

    private func gzipData(_ raw: Data) -> Data? {
        if let cached = cachedRawHTML, cached == raw, let gz = cachedGzipHTML {
            return gz
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        proc.arguments = ["-c", "-6"]
        let inPipe = Pipe()
        let outPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        do {
            try proc.run()
            DispatchQueue.global(qos: .userInitiated).async {
                inPipe.fileHandleForWriting.write(raw)
                try? inPipe.fileHandleForWriting.close()
            }
            let compressed = outPipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            if proc.terminationStatus == 0 && !compressed.isEmpty {
                cachedRawHTML = raw
                cachedGzipHTML = compressed
                return compressed
            }
        } catch {}
        return nil
    }

    fileprivate func serveHTTPResponse(path: String, acceptGzip: Bool) -> Data {
        let cleanPath = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? "/"

        switch cleanPath {
        case "/", "/index.html":
            let raw = htmlProvider()
            if acceptGzip, let gz = gzipData(raw) {
                return httpResponse(status: "200 OK", contentType: "text/html; charset=utf-8", body: gz, contentEncoding: "gzip")
            }
            return httpResponse(status: "200 OK", contentType: "text/html; charset=utf-8", body: raw)

        case "/manifest.webmanifest":
            let manifest = """
            {
              "name": "PocketPad 无线触控板",
              "short_name": "PocketPad",
              "start_url": "/",
              "display": "standalone",
              "orientation": "any",
              "background_color": "#0D0F13",
              "theme_color": "#0D0F13",
              "icons": [
                { "src": "/apple-touch-icon.png", "sizes": "180x180", "type": "image/png" },
                { "src": "/icon.svg", "sizes": "any", "type": "image/svg+xml" }
              ]
            }
            """
            return httpResponse(status: "200 OK", contentType: "application/manifest+json; charset=utf-8", body: Data(manifest.utf8))

        case "/apple-touch-icon.png":
            if let png = iconPngData {
                return httpResponse(status: "200 OK", contentType: "image/png", body: png)
            }
            return httpResponse(status: "404 Not Found", contentType: "text/plain", body: Data("Not Found".utf8))

        case "/icon.svg":
            let svg = """
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 180 180">
              <rect width="180" height="180" rx="40" fill="#18191C"/>
              <rect x="20" y="20" width="140" height="106" rx="18" fill="#23262C" stroke="#3A3F4B" stroke-width="2"/>
              <circle cx="90" cy="73" r="14" fill="none" stroke="#38BDF8" stroke-width="3"/>
              <circle cx="90" cy="73" r="4" fill="#38BDF8"/>
              <rect x="20" y="136" width="66" height="24" rx="8" fill="#2B2E35"/>
              <rect x="94" y="136" width="66" height="24" rx="8" fill="#2B2E35"/>
            </svg>
            """
            return httpResponse(status: "200 OK", contentType: "image/svg+xml", body: Data(svg.utf8))

        case "/health":
            let json = "{\"ok\":true,\"host\":\"\(NetworkUtils.hostDisplayName())\"}"
            return httpResponse(status: "200 OK", contentType: "application/json", body: Data(json.utf8))

        default:
            return httpResponse(status: "404 Not Found", contentType: "text/plain", body: Data("Not Found".utf8))
        }
    }

    private func httpResponse(status: String, contentType: String, body: Data, contentEncoding: String? = nil) -> Data {
        var header =
            "HTTP/1.1 \(status)\r\n" +
            "Content-Type: \(contentType)\r\n" +
            "Content-Length: \(body.count)\r\n"
        if let enc = contentEncoding {
            header += "Content-Encoding: \(enc)\r\n"
        }
        header +=
            "Cache-Control: no-cache\r\n" +
            "Connection: close\r\n\r\n"
        var data = Data(header.utf8)
        data.append(body)
        return data
    }
}

private final class ClientSession {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private weak var server: WebSocketServer?
    private let input: InputController
    private var buffer = Data()
    private var isWebSocket = false
    private var isClosed = false
    private(set) var isAuthenticatedWebSocket = false
    var onClosed: (() -> Void)?

    init(connection: NWConnection, queue: DispatchQueue, server: WebSocketServer, input: InputController) {
        self.connection = connection
        self.queue = queue
        self.server = server
        self.input = input
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.close() }
            if case .cancelled = state { self?.close() }
        }
        connection.start(queue: queue)
        receiveNext()
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        if isAuthenticatedWebSocket {
            isAuthenticatedWebSocket = false
            input.systemAction("release_drag")
        }
        connection.cancel()
        onClosed?()
    }

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self, !self.isClosed else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                if self.isWebSocket {
                    self.processWebSocketFrames()
                } else {
                    self.processHTTPRequest()
                }
            }
            if isComplete || error != nil {
                self.close()
                return
            }
            if !self.isClosed {
                self.receiveNext()
            }
        }
    }

    private func processHTTPRequest() {
        let delimiter = Data([13, 10, 13, 10]) // \r\n\r\n
        guard let range = buffer.range(of: delimiter) else {
            if buffer.count > 16384 { close() }
            return
        }
        let headerData = buffer.subdata(in: 0..<range.lowerBound)
        buffer.removeSubrange(0..<range.upperBound)

        guard let headerText = String(data: headerData, encoding: .utf8) else {
            close()
            return
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            close()
            return
        }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            close()
            return
        }
        let path = String(parts[1])

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if let colon = line.firstIndex(of: ":") {
                let k = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let v = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                headers[k] = v
            }
        }

        if headers["upgrade"]?.lowercased() == "websocket",
           let secKey = headers["sec-websocket-key"] {
            upgradeToWebSocket(secKey: secKey, path: path)
            return
        }

        guard let server else { close(); return }
        let acceptGzip = headers["accept-encoding"]?.lowercased().contains("gzip") ?? false
        let response = server.serveHTTPResponse(path: path, acceptGzip: acceptGzip)
        // Send graceful TCP FIN (.finalMessage) and wait for peer close (5s safety timeout)
        connection.send(content: response, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in
            self?.queue.asyncAfter(deadline: .now() + 5.0) {
                self?.close()
            }
        })
    }

    private func upgradeToWebSocket(secKey: String, path: String) {
        let magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let digest = Insecure.SHA1.hash(data: Data((secKey + magic).utf8))
        let acceptKey = Data(digest).base64EncodedString()

        let handshake =
            "HTTP/1.1 101 Switching Protocols\r\n" +
            "Upgrade: websocket\r\n" +
            "Connection: Upgrade\r\n" +
            "Sec-WebSocket-Accept: \(acceptKey)\r\n\r\n"

        isWebSocket = true
        connection.send(content: Data(handshake.utf8), completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else {
                self?.close()
                return
            }
            let queryPin = self.extractQueryParam(from: path, name: "pin")
            self.evaluateInitialAuth(providedPin: queryPin)
            if !self.buffer.isEmpty {
                self.processWebSocketFrames()
            }
        })
    }

    private func extractQueryParam(from path: String, name: String) -> String? {
        guard let comps = URLComponents(string: "http://localhost" + path) else { return nil }
        return comps.queryItems?.first(where: { $0.name == name })?.value
    }

    private func evaluateInitialAuth(providedPin: String?) {
        guard let server else { return }
        if !server.requirePIN || providedPin == server.pinCode {
            isAuthenticatedWebSocket = true
            server.notifyClientCount()
            sendJSON([
                "type": "auth_ok",
                "host": NetworkUtils.hostDisplayName(),
                "accessibility": InputController.hasAccessibilityPermission(prompt: false)
            ])
        } else {
            sendJSON([
                "type": "auth_required",
                "host": NetworkUtils.hostDisplayName()
            ])
        }
    }

    private func processWebSocketFrames() {
        while buffer.count >= 2 {
            let b0 = buffer[buffer.startIndex]
            let b1 = buffer[buffer.startIndex + 1]
            let opcode = b0 & 0x0F
            let isMasked = (b1 & 0x80) != 0
            var payloadLen = Int(b1 & 0x7F)
            var offset = 2

            if payloadLen == 126 {
                guard buffer.count >= 4 else { return }
                payloadLen = (Int(buffer[buffer.startIndex + 2]) << 8) | Int(buffer[buffer.startIndex + 3])
                offset = 4
            } else if payloadLen == 127 {
                guard buffer.count >= 10 else { return }
                var len64: UInt64 = 0
                for i in 0..<8 {
                    len64 = (len64 << 8) | UInt64(buffer[buffer.startIndex + 2 + i])
                }
                if len64 > 1_048_576 { close(); return }
                payloadLen = Int(len64)
                offset = 10
            }

            let maskLen = isMasked ? 4 : 0
            let totalLen = offset + maskLen + payloadLen
            guard buffer.count >= totalLen else { return }

            var payload = Data(count: payloadLen)
            if isMasked {
                let maskStart = buffer.startIndex + offset
                let mask = [
                    buffer[maskStart],
                    buffer[maskStart + 1],
                    buffer[maskStart + 2],
                    buffer[maskStart + 3]
                ]
                let dataStart = maskStart + 4
                for i in 0..<payloadLen {
                    payload[i] = buffer[dataStart + i] ^ mask[i & 3]
                }
            } else {
                let dataStart = buffer.startIndex + offset
                payload = buffer.subdata(in: dataStart..<(dataStart + payloadLen))
            }

            buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + totalLen))

            switch opcode {
            case 0x1: // Text frame
                if let text = String(data: payload, encoding: .utf8) {
                    handleMessage(text)
                }
            case 0x8: // Close
                sendFrame(opcode: 0x8, payload: Data())
                close()
                return
            case 0x9: // Ping -> Pong
                sendFrame(opcode: 0xA, payload: payload)
            default:
                break
            }
        }
    }

    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else {
            return
        }

        if type == "ping" {
            sendJSON(["type": "pong"])
            return
        }

        if type == "auth" {
            let pin = obj["pin"] as? String ?? ""
            guard let server else { return }
            if !server.requirePIN || pin == server.pinCode {
                isAuthenticatedWebSocket = true
                server.notifyClientCount()
                sendJSON([
                    "type": "auth_ok",
                    "host": NetworkUtils.hostDisplayName(),
                    "accessibility": InputController.hasAccessibilityPermission(prompt: false)
                ])
            } else {
                sendJSON(["type": "auth_error", "message": "配对码不正确"])
            }
            return
        }

        guard isAuthenticatedWebSocket else {
            sendJSON(["type": "auth_required", "host": NetworkUtils.hostDisplayName()])
            return
        }

        switch type {
        case "move":
            let dx = (obj["dx"] as? NSNumber)?.doubleValue ?? 0
            let dy = (obj["dy"] as? NSNumber)?.doubleValue ?? 0
            input.moveBy(dx: dx, dy: dy)

        case "scroll":
            let dx = (obj["dx"] as? NSNumber)?.doubleValue ?? 0
            let dy = (obj["dy"] as? NSNumber)?.doubleValue ?? 0
            input.scroll(dx: dx, dy: dy)

        case "click":
            let button = obj["button"] as? String ?? "left"
            let count = (obj["count"] as? NSNumber)?.intValue
            input.click(button: button, count: count)

        case "down":
            let button = obj["button"] as? String ?? "left"
            input.mouseDown(button: button)

        case "up":
            let button = obj["button"] as? String ?? "left"
            input.mouseUp(button: button)

        case "text":
            let str = obj["text"] as? String ?? ""
            let enter = (obj["enter"] as? Bool) ?? false
            input.typeText(str, pressEnter: enter)

        case "key":
            if let key = obj["key"] as? String {
                let mods = obj["mods"] as? [String] ?? []
                input.pressKey(key, modifiers: mods)
            }

        case "media":
            if let key = obj["key"] as? String {
                input.mediaKey(key)
            }

        case "action":
            if let action = obj["action"] as? String {
                input.systemAction(action)
            }

        default:
            break
        }
    }

    private func sendJSON(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return }
        sendFrame(opcode: 0x1, payload: data)
    }

    private func sendFrame(opcode: UInt8, payload: Data) {
        guard !isClosed else { return }
        var frame = Data()
        frame.append(0x80 | opcode)
        let count = payload.count
        if count < 126 {
            frame.append(UInt8(count))
        } else if count < 65536 {
            frame.append(126)
            frame.append(UInt8((count >> 8) & 0xFF))
            frame.append(UInt8(count & 0xFF))
        } else {
            frame.append(127)
            for shift in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((UInt64(count) >> UInt64(shift)) & 0xFF))
            }
        }
        frame.append(payload)
        connection.send(content: frame, completion: .idempotent)
    }
}
