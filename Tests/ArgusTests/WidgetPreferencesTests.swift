import Foundation
import Testing

@Suite("Widget preferences")
@MainActor
struct WidgetPreferencesTests {
  @Test
  func usesStableDefaults() {
    withDefaults { defaults in
      let preferences = WidgetPreferences(defaults: defaults)

      #expect(preferences.enabledWidgets.contains(.cpu))
      #expect(preferences.enabledWidgets.contains(.memory))
      #expect(preferences.enabledWidgets.contains(.network))
      #expect(preferences.refreshRate == .balanced)
      #expect(preferences.graphPeriod == .threeMinutes)
      #expect(preferences.animateChanges)
      #expect(preferences.showPublicIP)
    }
  }

  @Test
  func persistsEveryUserSetting() {
    withDefaults { defaults in
      let preferences = WidgetPreferences(defaults: defaults)
      preferences.setEnabled(true, for: .storage)
      preferences.setEnabled(false, for: .memory)
      preferences.setRefreshRate(.everySecond)
      preferences.setGraphPeriod(.fiveMinutes)
      preferences.setAnimateChanges(false)
      preferences.setShowPublicIP(false)

      let restored = WidgetPreferences(defaults: defaults)
      #expect(restored.isEnabled(.storage))
      #expect(!restored.isEnabled(.memory))
      #expect(restored.refreshRate == .everySecond)
      #expect(restored.graphPeriod == .fiveMinutes)
      #expect(!restored.animateChanges)
      #expect(!restored.showPublicIP)
    }
  }

  @Test
  func keepsAtLeastOneWidgetEnabled() {
    withDefaults { defaults in
      let preferences = WidgetPreferences(defaults: defaults)
      for widget in WidgetKind.allCases where widget != .cpu {
        preferences.setEnabled(false, for: widget)
      }

      preferences.setEnabled(false, for: .cpu)
      #expect(preferences.enabledWidgets == [.cpu])
    }
  }

  private func withDefaults(
    _ body: (UserDefaults) -> Void
  ) {
    let suiteName = "com.maxmoon.argus.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }
    body(defaults)
  }
}
