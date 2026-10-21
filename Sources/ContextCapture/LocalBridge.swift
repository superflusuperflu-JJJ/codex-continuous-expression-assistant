import Foundation
import Network

final class LocalBridge {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "capture.bridge")
    private let handler: ([String: Any], @escaping ([String: Any]) -> Void) -> Void
    private var connections: [UUID: NWConnection] = [:]
    init(handler: @escaping ([String: Any], @escaping ([String: Any]) -> Void) -> Void) { self.handler = handler }

    func start(socketURL: URL, failure: @escaping (String) -> Void) throws {
        try? FileManager.default.removeItem(at: socketURL)
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .unix(path: socketURL.path)
        let listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { state in if case .failed(let error) = state { failure(error.localizedDescription) } }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            let id = UUID(); self.connections[id] = connection
            connection.start(queue: self.queue)
            self.receive(connection, id: id, buffer: Data())
        }
        listener.start(queue: queue); self.listener = listener
    }

    private func receive(_ connection: NWConnection, id: UUID, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, finished, error in
            guard let self else { return }
            var accumulated = buffer; if let data { accumulated.append(data) }
            if accumulated.count > 12 * 1024 * 1024 { connection.cancel(); self.connections.removeValue(forKey:id); return }
            if let newline = accumulated.firstIndex(of: 10) {
                do {
                    let object = try JSONSerialization.jsonObject(with: accumulated[..<newline]) as? [String: Any] ?? [:]
                    DispatchQueue.main.async {
                        self.handler(object) { response in
                            let encoded = (try? JSONSerialization.data(withJSONObject: response)) ?? Data("{}".utf8)
                            connection.send(content: encoded + Data([10]), completion: .contentProcessed { _ in
                                connection.cancel(); self.queue.async { self.connections.removeValue(forKey:id) }
                            })
                        }
                    }
                } catch { connection.cancel(); self.connections.removeValue(forKey:id) }
            } else if finished || error != nil { connection.cancel(); self.connections.removeValue(forKey:id) }
            else { self.receive(connection, id:id, buffer:accumulated) }
        }
    }
}
