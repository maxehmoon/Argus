import AppKit
import CoreLocation
import SwiftUI

@MainActor
final class WiFiNamePermission: NSObject, ObservableObject, CLLocationManagerDelegate {
  static let didChange = Notification.Name("ArgusWiFiNamePermissionDidChange")
  @Published private(set) var status: CLAuthorizationStatus = .notDetermined
  private let manager = CLLocationManager()

  override init() {
    super.init()
    manager.delegate = self
    refresh()
  }

  var isAuthorised: Bool {
    status == .authorizedAlways
  }

  func request() {
    // macOS protects SSIDs with Location Services. Request permission only
    // after the user chooses this action; never start location updates.
    if status == .notDetermined {
      manager.requestWhenInUseAuthorization()
    } else if let url = URL(
      string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")
    {
      NSWorkspace.shared.open(url)
    }
  }

  func refresh() {
    let current = manager.authorizationStatus
    guard current != status else { return }
    status = current
    NotificationCenter.default.post(name: Self.didChange, object: nil)
  }

  nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    Task { @MainActor [weak self] in self?.refresh() }
  }
}

@MainActor
struct WiFiNameSettingsSection: View {
  @StateObject private var permission = WiFiNamePermission()

  var body: some View {
    Section {
      HStack {
        Text("Wi-Fi network name")
        Spacer()
        Text(permission.isAuthorised ? "Allowed" : "Not allowed")
          .foregroundStyle(.secondary)
      }
      Button(
        permission.status == .notDetermined
          ? "Allow Wi-Fi Name…" : "Open Location Services Settings…"
      ) {
        permission.request()
      }
    } header: {
      Text("Wi-Fi")
    } footer: {
      Text(
        "macOS requires Location Services permission to show your Wi-Fi name. Argus does not request or store your location. Other network readings work without this permission."
      )
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))
    { _ in
      permission.refresh()
    }
  }
}
