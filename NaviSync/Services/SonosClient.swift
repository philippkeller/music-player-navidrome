import Foundation

struct SonosError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// A Sonos room (zone group), addressed via its coordinator.
struct SonosRoom: Identifiable, Hashable, Codable {
    /// RINCON_… id of the group coordinator.
    let id: String
    let name: String
    /// IP of the coordinator; all commands for the room go here.
    let host: String
}

/// What the speaker is doing right now.
struct SonosStatus {
    let currentURI: String
    let state: String
    /// 1-based position in the speaker's queue.
    let track: Int
    let position: Double
    let duration: Double
    /// Subsonic id of the playing song, read from its stream URL.
    let songID: String?

    var isPlaying: Bool { state == "PLAYING" || state == "TRANSITIONING" }
    var isBuffering: Bool { state == "TRANSITIONING" }

    func isPlayingQueue(of room: SonosRoom) -> Bool { currentURI == "x-rincon-queue:\(room.id)#0" }
}

/// Talks directly to one speaker over the LAN with UPnP on port 1400 (no AirPlay, no Sonos cloud).
/// The speaker streams the songs straight from the Navidrome server.
struct SonosClient {
    let host: String

    private static let session = URLSession(configuration: .ephemeral)
    private static let avTransport = (path: "/MediaRenderer/AVTransport/Control",
                                      urn: "urn:schemas-upnp-org:service:AVTransport:1")
    private static let renderingControl = (path: "/MediaRenderer/RenderingControl/Control",
                                           urn: "urn:schemas-upnp-org:service:RenderingControl:1")
    private static let zoneGroupTopology = (path: "/ZoneGroupTopology/Control",
                                            urn: "urn:schemas-upnp-org:service:ZoneGroupTopology:1")
    private static let instance = ("InstanceID", "0")
    /// Starting a stream makes the speaker contact the server first, which can take a few seconds.
    private static let startTimeout: TimeInterval = 20

    @discardableResult
    private func call(_ service: (path: String, urn: String), _ action: String, _ args: [(String, String)] = [],
                      timeout: TimeInterval = 4) async throws -> [String: String] {
        guard let url = URL(string: "http://\(host):1400\(service.path)") else {
            throw SonosError(message: "Invalid speaker address: \(host)")
        }
        let argXML = args.map { "<\($0.0)>\(xmlEscape($0.1))</\($0.0)>" }.joined()
        let body = """
            <?xml version="1.0" encoding="utf-8"?>\
            <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">\
            <s:Body><u:\(action) xmlns:u="\(service.urn)">\(argXML)</u:\(action)></s:Body></s:Envelope>
            """

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"\(service.urn)#\(action)\"", forHTTPHeaderField: "SOAPACTION")
        request.httpBody = Data(body.utf8)

        let (data, response) = try await Self.session.data(for: request)
        let fields = LeafXMLParser.parse(data)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let code = fields["errorCode"].map { ", UPnP error \($0)" } ?? ""
            throw SonosError(message: "\(action) failed (HTTP \(status)\(code))")
        }
        return fields
    }

    // MARK: Rooms

    /// All rooms in the household. One speaker is enough to ask.
    func rooms() async throws -> [SonosRoom] {
        let result = try await call(Self.zoneGroupTopology, "GetZoneGroupState")
        return ZoneGroupParser.parse(result["ZoneGroupState"] ?? "")
    }

    // MARK: Playback

    func play() async throws {
        try await call(Self.avTransport, "Play", [Self.instance, ("Speed", "1")], timeout: Self.startTimeout)
    }

    func pause() async throws {
        try await call(Self.avTransport, "Pause", [Self.instance])
    }

    func seek(to seconds: Double) async throws {
        let total = Int(max(0, seconds))
        let target = String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
        try await call(Self.avTransport, "Seek", [Self.instance, ("Unit", "REL_TIME"), ("Target", target)],
                       timeout: Self.startTimeout)
    }

    /// Replaces the speaker's queue. `speakerID` is the RINCON_… id of the coordinator that owns it.
    func replaceQueue(_ tracks: [SonosTrack], speakerID: String) async throws {
        try await call(Self.avTransport, "RemoveAllTracksFromQueue", [Self.instance])
        try await add(tracks)
        try await call(Self.avTransport, "SetAVTransportURI", [
            Self.instance, ("CurrentURI", "x-rincon-queue:\(speakerID)#0"), ("CurrentURIMetaData", ""),
        ])
    }

    /// Adds to the queue at a 1-based position; 0 appends.
    func add(_ tracks: [SonosTrack], at position: Int = 0) async throws {
        // Sonos accepts at most 16 tracks per call; URIs and metadata are space-separated (like SoCo does it).
        for start in stride(from: 0, to: tracks.count, by: 16) {
            let chunk = tracks[start..<min(start + 16, tracks.count)]
            try await call(Self.avTransport, "AddMultipleURIsToQueue", [
                Self.instance, ("UpdateID", "0"), ("NumberOfURIs", String(chunk.count)),
                ("EnqueuedURIs", chunk.map(\.uri).joined(separator: " ")),
                ("EnqueuedURIsMetaData", chunk.map(\.metadata).joined(separator: " ")),
                ("ContainerURI", ""), ("ContainerMetaData", ""),
                ("DesiredFirstTrackNumberEnqueued", String(position == 0 ? 0 : position + start)),
                ("EnqueueAsNext", "0"),
            ], timeout: 10)
        }
    }

    /// Removes the track at a 0-based queue index.
    func removeTrack(at index: Int) async throws {
        try await call(Self.avTransport, "RemoveTrackFromQueue", [
            Self.instance, ("ObjectID", "Q:0/\(index + 1)"), ("UpdateID", "0"),
        ])
    }

    /// Goes to a 0-based queue index and position, and starts playing if asked to.
    func start(index: Int, at position: Double, play shouldPlay: Bool) async throws {
        try await call(Self.avTransport, "Seek", [Self.instance, ("Unit", "TRACK_NR"), ("Target", String(index + 1))])
        guard position > 0 else {
            if shouldPlay { try await play() }
            return
        }
        // Some states refuse a time seek before playing, so check again afterwards.
        try? await seek(to: position)
        guard shouldPlay else { return }
        try await play()
        if try await status().position < position - 5 { try await seek(to: position) }
    }

    func status() async throws -> SonosStatus {
        async let media = call(Self.avTransport, "GetMediaInfo", [Self.instance])
        async let transport = call(Self.avTransport, "GetTransportInfo", [Self.instance])
        async let info = call(Self.avTransport, "GetPositionInfo", [Self.instance])
        let (mediaInfo, transportInfo, positionInfo) = try await (media, transport, info)
        return SonosStatus(
            currentURI: mediaInfo["CurrentURI"] ?? "",
            state: transportInfo["CurrentTransportState"] ?? "",
            track: Int(positionInfo["Track"] ?? "") ?? 0,
            position: Self.seconds(positionInfo["RelTime"]),
            duration: Self.seconds(positionInfo["TrackDuration"]),
            songID: URLComponents(string: positionInfo["TrackURI"] ?? "")?
                .queryItems?.first { $0.name == "id" }?.value)
    }

    /// "0:03:12" → 192. Anything else (e.g. "NOT_IMPLEMENTED") → 0.
    private static func seconds(_ time: String?) -> Double {
        let parts = (time ?? "").split(separator: ":").compactMap { Double($0) }
        guard parts.count == 3 else { return 0 }
        return parts[0] * 3600 + parts[1] * 60 + parts[2]
    }

    // MARK: Volume

    func volume() async throws -> Int {
        let result = try await call(Self.renderingControl, "GetVolume", [Self.instance, ("Channel", "Master")])
        return Int(result["CurrentVolume"] ?? "") ?? 0
    }

    func setVolume(_ volume: Int) async throws {
        try await call(Self.renderingControl, "SetVolume",
                       [Self.instance, ("Channel", "Master"), ("DesiredVolume", String(volume))])
    }
}

/// A plain HTTP(S) track plus the DIDL-Lite metadata Sonos shows while it plays.
struct SonosTrack {
    let uri: String
    let metadata: String

    init(url: URL, mimeType: String, title: String, artist: String?, album: String?, duration: Int?, artURL: URL?) {
        uri = url.absoluteString
        let duration = duration.map { String(format: " duration=\"%d:%02d:%02d\"", $0 / 3600, $0 / 60 % 60, $0 % 60) } ?? ""
        let optional = [
            artist.map { "<dc:creator>\(xmlEscape($0))</dc:creator>" },
            album.map { "<upnp:album>\(xmlEscape($0))</upnp:album>" },
            artURL.map { "<upnp:albumArtURI>\(xmlEscape($0.absoluteString))</upnp:albumArtURI>" },
        ].compactMap { $0 }.joined()
        metadata = """
            <DIDL-Lite xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" \
            xmlns:r="urn:schemas-rinconnetworks-com:metadata-1-0/" xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/">\
            <item id="-1" parentID="-1" restricted="true">\
            <res protocolInfo="http-get:*:\(mimeType):*"\(duration)>\(xmlEscape(uri))</res>\
            <dc:title>\(xmlEscape(title))</dc:title>\(optional)\
            <upnp:class>object.item.audioItem.musicTrack</upnp:class></item></DIDL-Lite>
            """
    }
}

private func xmlEscape(_ string: String) -> String {
    string
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "'", with: "&apos;")
}

/// Flattens a SOAP response into `[elementName: text]` for all leaf elements.
private final class LeafXMLParser: NSObject, XMLParserDelegate {
    private var fields: [String: String] = [:]
    private var text: String?

    static func parse(_ data: Data) -> [String: String] {
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        let delegate = LeafXMLParser()
        parser.delegate = delegate
        parser.parse()
        return delegate.fields
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text?.append(string)
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if let text { fields[name] = text }
        text = nil
    }
}

/// Parses the ZoneGroupState XML into rooms (one per group, addressed via its coordinator).
private final class ZoneGroupParser: NSObject, XMLParserDelegate {
    private struct Member {
        let uuid: String
        let name: String
        let host: String?
        let visible: Bool
    }

    private var rooms: [SonosRoom] = []
    private var coordinator: String?
    private var members: [Member] = []

    static func parse(_ xml: String) -> [SonosRoom] {
        guard let data = xml.data(using: .utf8) else { return [] }
        let parser = XMLParser(data: data)
        let delegate = ZoneGroupParser()
        parser.delegate = delegate
        parser.parse()
        return delegate.rooms.sorted { $0.name < $1.name }
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        switch name {
        case "ZoneGroup":
            coordinator = attributes["Coordinator"]
            members = []
        case "ZoneGroupMember":
            guard let uuid = attributes["UUID"] else { return }
            members.append(Member(
                uuid: uuid,
                name: attributes["ZoneName"] ?? "Sonos",
                host: attributes["Location"].flatMap { URL(string: $0)?.host },
                visible: attributes["Invisible"] != "1" && attributes["IsZoneBridge"] != "1"))
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        guard name == "ZoneGroup" else { return }
        defer { coordinator = nil; members = [] }
        guard let leader = members.first(where: { $0.uuid == coordinator }), let host = leader.host else { return }
        var names: [String] = []
        for member in members where member.visible && !names.contains(member.name) {
            names.append(member.name)
        }
        guard !names.isEmpty else { return }
        rooms.append(SonosRoom(id: leader.uuid, name: names.joined(separator: " + "), host: host))
    }
}
