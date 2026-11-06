import Foundation
import Network

/// Finds the IP of any Sonos speaker on the local network via Bonjour (`_sonos._tcp`).
/// One speaker is enough: it reports all rooms in the household.
enum SonosDiscovery {
    static func findHost(timeout: TimeInterval = 8) async -> String? {
        await withCheckedContinuation { continuation in
            HostFinder(timeout: timeout) { continuation.resume(returning: $0) }.start()
        }
    }
}

private final class HostFinder {
    private let queue = DispatchQueue(label: "navisync.sonos.discovery")
    private let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_sonos._tcp", domain: "local."), using: .tcp)
    private let timeout: TimeInterval
    private var completion: ((String?) -> Void)?
    private var connections: [NWConnection] = []
    private var seen: Set<NWEndpoint> = []

    init(timeout: TimeInterval, completion: @escaping (String?) -> Void) {
        self.timeout = timeout
        self.completion = completion
    }

    // The handlers below retain `self` until `finish` runs, which keeps the finder alive.
    func start() {
        browser.browseResultsChangedHandler = { results, _ in
            results.forEach(self.handle)
        }
        browser.start(queue: queue)
        queue.asyncAfter(deadline: .now() + timeout) { self.finish(nil) }
    }

    private func handle(_ result: NWBrowser.Result) {
        guard seen.insert(result.endpoint).inserted else { return }

        // Sonos usually publishes its device description URL in the TXT record.
        if case .bonjour(let txt) = result.metadata, let location = txt["location"],
           let host = URL(string: location)?.host {
            finish(host)
            return
        }

        // Otherwise resolve the service by connecting to it and reading the peer address.
        let parameters = NWParameters.tcp
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        let connection = NWConnection(to: result.endpoint, using: parameters)
        connection.stateUpdateHandler = { [weak connection] state in
            guard case .ready = state,
                  case .hostPort(let host, _)? = connection?.currentPath?.remoteEndpoint else { return }
            self.finish(Self.string(from: host))
        }
        connections.append(connection)
        connection.start(queue: queue)
    }

    private func finish(_ host: String?) {
        guard let completion else { return }
        self.completion = nil
        browser.browseResultsChangedHandler = nil
        browser.cancel()
        for connection in connections {
            connection.stateUpdateHandler = nil
            connection.cancel()
        }
        connections = []
        completion(host)
    }

    private static func string(from host: NWEndpoint.Host) -> String? {
        switch host {
        case .ipv4(let address): return "\(address)".components(separatedBy: "%").first
        case .name(let name, _): return name
        default: return nil
        }
    }
}
