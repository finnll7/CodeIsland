import CoreLocation
import Foundation
import os.log

private let wxLog = Logger(subsystem: "com.codeisland", category: "weather")

/// Local weather via Open-Meteo (free, keyless) + one-time system location
/// consent. Flow: authorization → requestLocation() → coordinates →
/// Open-Meteo forecast → current temperature + WMO weather code.
///
/// Design mirrors the other ambient monitors: setting-gated, refresh on wake
/// and a 30-minute poll; hides itself when location is unavailable or denied
/// (the settings description points at System Settings).
@MainActor
@Observable
final class WeatherMonitor: NSObject, CLLocationManagerDelegate {
    private(set) var temperature: Int?
    private(set) var weatherCode = 0
    /// Today's high/low (Open-Meteo daily forecast, day 0).
    private(set) var tempMax: Int?
    private(set) var tempMin: Int?
    /// WMO code mapped to a short Chinese description (晴 / 多云 / 小雨 …).
    private(set) var conditionText: String?
    private(set) var locationDenied = false

    var isEnabled: Bool {
        UserDefaults.standard.object(forKey: SettingsKey.showWeather) as? Bool
            ?? SettingsDefaults.showWeather
    }

    var isLive: Bool { isEnabled && temperature != nil }

    private let locationManager = CLLocationManager()
    private var pollTimer: Timer?
    private var activated = false

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyKilometer
        // Same init-order caveat as the other ambient monitors: registerDefaults
        // may run after this init, so isEnabled falls back to the built-in
        // default — and activation must be kicked off here, not by a later
        // defaults-change notification that may never come.
        syncActivation()
    }

    func syncActivation() {
        if isEnabled, !activated {
            activated = true
            start()
        } else if !isEnabled, activated {
            deactivate()
        }
    }

    private func start() {
        startPolling()
        requestLocationAndFetch()
    }

    private func deactivate() {
        pollTimer?.invalidate()
        pollTimer = nil
        temperature = nil
        weatherCode = 0
    }

    private func startPolling() {
        guard pollTimer == nil else { return }
        // Weather changes slowly; Open-Meteo free tier is generous but let's
        // stay polite — 30 minutes.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.requestLocationAndFetch() }
        }
    }

    // MARK: - Location → Fetch

    func requestLocationAndFetch() {
        switch CLLocationManager.authorizationStatus() {
        case .authorizedAlways:
            locationManager.requestLocation()
        case .notDetermined:
            wxLog.notice("requesting when-in-use location authorization")
            locationManager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            locationDenied = true
        @unknown default:
            break
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            let status = CLLocationManager.authorizationStatus()
            wxLog.notice("location authorization \(status.rawValue)")
            if status == .authorizedAlways {
                self.locationDenied = false
                self.locationManager.requestLocation()
            } else if status == .denied {
                self.locationDenied = true
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let coordinate = locations.last?.coordinate else { return }
        Task { @MainActor in
            self.fetchWeather(latitude: coordinate.latitude, longitude: coordinate.longitude)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        wxLog.error("location failed: \(error.localizedDescription, privacy: .public)")
    }

    private func fetchWeather(latitude: Double, longitude: Double) {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.3f", latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.3f", longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code"),
            URLQueryItem(name: "daily", value: "temperature_2m_max,temperature_2m_min"),
            URLQueryItem(name: "forecast_days", value: "1"),
            URLQueryItem(name: "timezone", value: "auto"),
        ]
        guard let url = components.url else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            guard let self, error == nil,
                  let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let current = json["current"] as? [String: Any],
                  let temp = current["temperature_2m"] as? Double,
                  let code = current["weather_code"] as? Int,
                  let daily = json["daily"] as? [String: Any] else {
                wxLog.error("weather fetch failed")
                return
            }
            Task { @MainActor in
                self.temperature = Int(temp.rounded())
                self.weatherCode = code
                self.conditionText = Self.conditionText(forCode: code)
                if let maxArr = daily["temperature_2m_max"] as? [Double], let maxV = maxArr.first {
                    self.tempMax = Int(maxV.rounded())
                }
                if let minArr = daily["temperature_2m_min"] as? [Double], let minV = minArr.first {
                    self.tempMin = Int(minV.rounded())
                }
                wxLog.notice("weather: \(self.temperature ?? 0)°C code=\(self.weatherCode) range=\(self.tempMin ?? 0)-\(self.tempMax ?? 0)")
            }
        }.resume()
    }

    // MARK: - WMO weather code → description / symbol (pure)

    /// WMO code → short Chinese description (card is CN-primary).
    nonisolated static func conditionText(forCode code: Int) -> String? {
        switch code {
        case 0: return "晴"
        case 1: return "大致晴朗"
        case 2: return "多云"
        case 3: return "阴"
        case 45, 48: return "雾"
        case 51, 53, 55: return "毛毛雨"
        case 56, 57: return "冻毛毛雨"
        case 61: return "小雨"
        case 63: return "中雨"
        case 65: return "大雨"
        case 66, 67: return "冻雨"
        case 71: return "小雪"
        case 73: return "中雪"
        case 75: return "大雪"
        case 77: return "雪粒"
        case 80: return "阵雨"
        case 81: return "阵雨"
        case 82: return "强阵雨"
        case 85, 86: return "阵雪"
        case 95: return "雷阵雨"
        case 96, 99: return "雷阵雨伴冰雹"
        default: return nil
        }
    }

    // MARK: - WMO weather code → SF Symbol (pure)

    nonisolated static func symbol(forCode code: Int, isDaytime: Bool = true) -> String {
        switch code {
        case 0: return isDaytime ? "sun.max" : "moon.stars"
        case 1: return isDaytime ? "cloud.sun" : "cloud.moon"
        case 2: return isDaytime ? "cloud.sun" : "cloud.moon"
        case 3: return "cloud"
        case 45, 48: return "cloud.fog"
        case 51...57: return "cloud.drizzle"
        case 61...67: return "cloud.rain"
        case 71...77: return "cloud.snow"
        case 80...82: return "cloud.heavyrain"
        case 85, 86: return "cloud.snow"
        case 95...99: return "cloud.bolt.rain"
        default: return "cloud"
        }
    }
}
