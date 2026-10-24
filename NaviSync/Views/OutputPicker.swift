import AVKit
import SwiftUI

/// The system AirPlay / audio output picker. Lists AirPlay 2 speakers (including Sonos),
/// Apple TVs and, on iOS, Bluetooth devices the system currently offers.
struct OutputPickerButton: View {
    var size: CGFloat = 36

    @Environment(AppModel.self) private var model

    var body: some View {
        RoutePickerRepresentable(player: model.player.avPlayer)
            .frame(width: size, height: size)
            .help("Play on AirPlay, Sonos or Bluetooth speakers")
    }
}

/// "Playing on Kitchen" line, shown when audio goes to something other than the device itself.
struct OutputNameLabel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let name = model.player.externalOutputName {
            Label("Playing on \(name)", systemImage: "hifispeaker.fill")
                .font(.caption)
                .foregroundStyle(.tint)
                .lineLimit(1)
        }
    }
}

#if os(iOS)

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

/// iOS won't let apps connect Bluetooth devices, so this jumps to Settings → Bluetooth instead.
/// "App-prefs:Bluetooth" isn't an official URL; if it's refused we open the Settings app.
struct BluetoothDevicesButton: View {
    var body: some View {
        Button {
            guard let url = URL(string: "App-prefs:Bluetooth") else { return }
            UIApplication.shared.open(url) { opened in
                guard !opened, let fallback = URL(string: UIApplication.openSettingsURLString) else { return }
                UIApplication.shared.open(fallback)
            }
        } label: {
            Image(systemName: "headphones")
                .font(.title3)
                .padding(8)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Bluetooth Settings")
    }
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
