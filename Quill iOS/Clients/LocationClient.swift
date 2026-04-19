//
//  LocationClient.swift
//  Quill (iOS)
//
//  One-shot "where am I, roughly, right now?" helper used when a new note
//  is created. Best-effort — returns nil when the user hasn't granted
//  WhenInUse authorization or the lookup fails.
//

import CoreLocation
import Foundation

@MainActor
final class LocationClient: NSObject {
  static let shared = LocationClient()

  private let manager = CLLocationManager()
  private var pendingContinuation: CheckedContinuation<CLLocation?, Never>?

  override private init() {
    super.init()
    manager.delegate = self
    manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
  }

  /// Request a single location fix. Prompts for permission if undetermined.
  /// Returns nil if the user denies, if Location Services is off, or if
  /// the OS times out / errors out.
  func currentPlace() async -> NoteLocation? {
    let status = manager.authorizationStatus

    switch status {
    case .notDetermined:
      manager.requestWhenInUseAuthorization()
      // Don't hang forever waiting for the auth dialog; give up after 10s.
      // If the user approves later, a future recording will try again.
      let approved = await waitForAuthorization(timeout: .seconds(10))
      guard approved else { return nil }
    case .authorizedAlways, .authorizedWhenInUse:
      break
    case .denied, .restricted:
      return nil
    @unknown default:
      return nil
    }

    guard let fix = await requestOneShotLocation() else { return nil }

    let placeName = await reverseGeocode(fix)
    return NoteLocation(
      latitude: fix.coordinate.latitude,
      longitude: fix.coordinate.longitude,
      placeName: placeName
    )
  }

  // MARK: - Internals

  private func requestOneShotLocation() async -> CLLocation? {
    await withCheckedContinuation { continuation in
      self.pendingContinuation = continuation
      manager.requestLocation()
    }
  }

  private func waitForAuthorization(timeout: Duration) async -> Bool {
    // Poll at short intervals — CLLocationManager fires its delegate on the
    // main thread, so checking authorizationStatus is cheap.
    let start = ContinuousClock.now
    while ContinuousClock.now - start < timeout {
      switch manager.authorizationStatus {
      case .authorizedAlways, .authorizedWhenInUse: return true
      case .denied, .restricted: return false
      case .notDetermined: try? await Task.sleep(for: .milliseconds(200))
      @unknown default: return false
      }
    }
    return false
  }

  private func reverseGeocode(_ location: CLLocation) async -> String? {
    do {
      let placemarks = try await CLGeocoder().reverseGeocodeLocation(location)
      guard let p = placemarks.first else { return nil }
      // Prefer "Neighborhood, State" → "City, State" → "Country" in that
      // order. That matches how a human would label a note.
      if let neighborhood = p.subLocality, let admin = p.administrativeArea {
        return "\(neighborhood), \(admin)"
      }
      if let city = p.locality, let admin = p.administrativeArea {
        return "\(city), \(admin)"
      }
      if let city = p.locality {
        return city
      }
      return p.country
    } catch {
      return nil
    }
  }
}

// MARK: - CLLocationManagerDelegate

extension LocationClient: CLLocationManagerDelegate {
  nonisolated func locationManager(
    _ manager: CLLocationManager,
    didUpdateLocations locations: [CLLocation]
  ) {
    let fix = locations.last
    Task { @MainActor in
      self.pendingContinuation?.resume(returning: fix)
      self.pendingContinuation = nil
    }
  }

  nonisolated func locationManager(
    _ manager: CLLocationManager,
    didFailWithError error: Error
  ) {
    Task { @MainActor in
      self.pendingContinuation?.resume(returning: nil)
      self.pendingContinuation = nil
    }
  }
}
