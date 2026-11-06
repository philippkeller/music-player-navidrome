import AVKit
import MediaPlayer
import SwiftUI

/// The system AirPlay / audio output picker. Lists AirPlay 2 speakers, Apple TVs and,
/// on iOS, Bluetooth devices the system currently offers. Sonos has its own `SonosButton`.
struct OutputPickerButton: View {
    var size: CGFloat = 36

    @Environment(AppModel.self) private var model

    var body: some View {
        RoutePickerRepresentable(player: model.player.avPlayer)
            .frame(width: size, height: size)
            .help("Play on AirPlay or Bluetooth speakers")
    }
}

/// "Playing on Kitchen" line, shown when audio goes to something other than the device itself.
struct OutputNameLabel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let error = model.player.sonosError {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
        } else if let name = model.player.sonosRoom?.name ?? model.player.externalOutputName {
            Label("Playing on \(name)", systemImage: "hifispeaker.fill")
                .font(.caption)
                .foregroundStyle(.tint)
                .lineLimit(1)
        }
    }
}

/// The Sonos room's volume; only shown while playing on Sonos.
struct SonosVolumeSlider: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let player = model.player
        if player.sonosRoom != nil {
            HStack(spacing: 10) {
                Image(systemName: "speaker.fill")
                Slider(value: Binding(get: { player.sonosVolume }, set: { player.setSonosVolume($0) }), in: 0...100)
                Image(systemName: "speaker.wave.3.fill")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

/// Plays on a Sonos room directly over the network, also on speakers without AirPlay.
struct SonosButton: View {
    @Environment(AppModel.self) private var model
    @State private var showRooms = false

    var body: some View {
        let active = model.player.sonosRoom != nil
        Button { showRooms.toggle() } label: {
            Image(systemName: active ? "hifispeaker.fill" : "hifispeaker")
                .foregroundStyle(active ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.borderless)
        .help("Play on Sonos")
        .popover(isPresented: $showRooms, arrowEdge: .top) {
            SonosRoomList()
                .frame(minWidth: 300, minHeight: 320)
                .presentationDetents([.medium, .large])
        }
    }
}

private struct SonosRoomList: View {
    /// The last speaker that answered, or the address typed in by hand.
    private static let hostKey = "sonosHost"

    @Environment(AppModel.self) private var model
    @State private var rooms: [SonosRoom] = []
    @State private var isSearching = true
    @State private var host = UserDefaults.standard.string(forKey: Self.hostKey) ?? ""

    var body: some View {
        let player = model.player
        List {
            Section("Play on") {
                row(thisDevice, selected: player.sonosRoom == nil) { player.disconnectSonos() }
                ForEach(rooms) { room in
                    row(room.name, selected: player.sonosRoom == room) { player.connectSonos(room) }
                }
                if isSearching {
                    HStack { ProgressView().controlSize(.small); Text("Looking for Sonos…") }
                }
            }
            if player.sonosRoom != nil {
                Section("Volume") {
                    SonosVolumeSlider()
                }
            }
            if !isSearching, rooms.isEmpty {
                Section {
                    TextField("Speaker IP address", text: $host)
                        .autocorrectionDisabled()
                    Button("Connect") { Task { await search() } }
                        .disabled(host.isEmpty)
                } header: {
                    Text("Not found")
                } footer: {
                    Text("Be on the same Wi-Fi and allow Local Network access for NaviSync in Settings → Privacy & Security. You can also type in a speaker's IP address (Sonos app → Settings → About Your System).")
                }
            }
        }
        .task {
            await search()
            await player.refreshSonosVolume()
        }
    }

    private var thisDevice: String {
        #if os(iOS)
        return "This iPhone"
        #else
        return "This Mac"
        #endif
    }

    private func row(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                if selected { Image(systemName: "checkmark") }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Tries the known speaker first (instant), then Bonjour.
    private func search() async {
        isSearching = true
        defer { isSearching = false }
        let typed = host.trimmingCharacters(in: .whitespaces)
        if !typed.isEmpty, await load(from: typed) { return }
        if let found = await SonosDiscovery.findHost() { _ = await load(from: found) }
    }

    private func load(from address: String) async -> Bool {
        guard let found = try? await SonosClient(host: address).rooms(), !found.isEmpty else { return false }
        rooms = found
        host = address
        UserDefaults.standard.set(address, forKey: Self.hostKey)
        return true
    }
}

#if os(iOS)

/// Invisible while playing on Sonos. Lets the player set the iPhone's own volume, which needs this
/// system view's slider, and keeps iOS from showing its volume overlay for the iPhone's volume.
struct SonosVolumeKeys: UIViewRepresentable {
    let player: PlayerController

    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        player.setSystemVolume = { [weak view] volume in
            view?.subviews.compactMap { $0 as? UISlider }.first?.value = volume
        }
        // The first look at the volume happens before this view exists.
        DispatchQueue.main.async { player.recenterIfAtLimit() }
        return view
    }

    func updateUIView(_ view: MPVolumeView, context: Context) {}
}

private struct RoutePickerRepresentable: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = false
        view.tintColor = .label
        view.activeTintColor = .tintColor
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}

#else

private struct RoutePickerRepresentable: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.player = player
        view.isRoutePickerButtonBordered = false
        return view
    }

    func updateNSView(_ view: AVRoutePickerView, context: Context) {
        view.player = player
    }
}

/// Mac only: reconnect paired Bluetooth headphones / speakers that aren't connected right now.
struct BluetoothDevicesButton: View {
    @State private var bluetooth = BluetoothAudioDevices()
    @State private var showList = false

    var body: some View {
        Button { showList.toggle() } label: {
            Image(systemName: "headphones")
        }
        .buttonStyle(.borderless)
        .help("Connect a Bluetooth device")
        .popover(isPresented: $showList, arrowEdge: .top) {
            BluetoothDeviceList(bluetooth: bluetooth)
                .frame(width: 280)
                .onAppear { bluetooth.refresh() }
        }
    }
}

private struct BluetoothDeviceList: View {
    let bluetooth: BluetoothAudioDevices

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Bluetooth Devices")
                .font(.headline)
                .padding([.horizontal, .top], 12)
                .padding(.bottom, 6)

            if bluetooth.devices.isEmpty {
                Text("No paired Bluetooth audio devices. Pair one in System Settings → Bluetooth first.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(12)
            } else {
                ForEach(bluetooth.devices) { device in
                    Button {
                        bluetooth.toggle(device)
                    } label: {
                        HStack {
                            Image(systemName: "headphones")
                                .foregroundStyle(device.isConnected ? Color.accentColor : .secondary)
                            Text(device.name).lineLimit(1)
                            Spacer()
                            if bluetooth.busyID == device.id {
                                ProgressView().controlSize(.small)
                            } else if device.isConnected {
                                Text("Connected").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .contentShape(Rectangle())
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                    .disabled(bluetooth.busyID != nil)
                }
            }

            if let error = bluetooth.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
            }
        }
        .padding(.bottom, 10)
    }
}

#endif
