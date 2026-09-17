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
struct WiFiNameSettingsRow: View {
  @StateObject private var permission = WiFiNamePermission()

  var body: some View {
    LabeledContent("Wi-Fi name:") {
      VStack(alignment: .leading, spacing: 8) {
        Text(permission.isAuthorised ? "Access allowed" : "Permission required")
        Text(
          "macOS requires Location Services permission to show your Wi-Fi network name. Argus does not request or store your location."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        Button(
          permission.status == .notDetermined
            ? "Allow Wi-Fi Name…" : "Open Location Services Settings…"
        ) {
          permission.request()
        }
      }
    }
    .accessibilityElement(children: .contain)
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))
    { _ in
      permission.refresh()
    }
  }
}
