import EventKit
import Foundation

/// Weather from Open-Meteo (free, no API key). The city comes from --city, or from the Mac's
/// time zone (e.g. Europe/Berlin → Berlin), so no location permission is needed.
final class Weather {
    private let lock = NSLock()
    private var current: [String: Any] = [:]
    private let city: String
    private var coords: (lat: Double, lon: Double, name: String)?

    init(city: String?) {
        self.city = city ?? TimeZone.current.identifier.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? "London"
    }

    func start() {
        refresh()
        Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func snapshot() -> [String: Any] { lock.lock(); defer { lock.unlock() }; return current }

    private func get(_ url: String, _ done: @escaping ([String: Any]) -> Void) {
        guard let u = URL(string: url) else { return }
        URLSession.shared.dataTask(with: u) { data, _, _ in
            if let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { done(obj) }
        }.resume()
    }

    private func refresh() {
        guard let coords else {
            let q = city.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? city
            get("https://geocoding-api.open-meteo.com/v1/search?name=\(q)&count=1") { [weak self] obj in
                guard let self, let r = (obj["results"] as? [[String: Any]])?.first,
                      let lat = r["latitude"] as? Double, let lon = r["longitude"] as? Double else { return }
                self.coords = (lat, lon, (r["name"] as? String) ?? self.city)
                self.refresh()
            }
            return
        }
        let url = "https://api.open-meteo.com/v1/forecast?latitude=\(coords.lat)&longitude=\(coords.lon)" +
            "&current=temperature_2m,weather_code,is_day&daily=temperature_2m_max,temperature_2m_min,precipitation_probability_max" +
            "&timezone=auto&forecast_days=1"
        get(url) { [weak self] obj in
            guard let self, let cur = obj["current"] as? [String: Any], let daily = obj["daily"] as? [String: Any] else { return }
            let first = { (k: String) in (daily[k] as? [Double])?.first }
            let code = (cur["weather_code"] as? Int) ?? 0
            var w: [String: Any] = ["city": coords.name, "code": code, "day": (cur["is_day"] as? Int) == 1,
                                    "summary": Weather.describe(code)]
            if let t = cur["temperature_2m"] as? Double { w["temp"] = t }
            if let hi = first("temperature_2m_max") { w["high"] = hi }
            if let lo = first("temperature_2m_min") { w["low"] = lo }
            if let rain = first("precipitation_probability_max") { w["rain"] = rain }
            self.lock.lock(); self.current = w; self.lock.unlock()
        }
    }

    /// WMO weather codes → short labels.
    static func describe(_ code: Int) -> String {
        switch code {
        case 0: return "Clear"
        case 1, 2: return "Partly cloudy"
        case 3: return "Cloudy"
        case 45, 48: return "Fog"
        case 51...57: return "Drizzle"
        case 61...67, 80...82: return "Rain"
        case 71...77, 85, 86: return "Snow"
        case 95...99: return "Thunderstorm"
        default: return "—"
        }
    }
}

/// Today's and tomorrow's upcoming events from the Mac's calendars (EventKit expands repeating events,
/// which AppleScript can't). Needs Calendar access; the usage text lives in the embedded Info.plist.
final class Agenda {
    private let store = EKEventStore()
    private let lock = NSLock()
    private var events: [[String: Any]] = []
    private var granted = false
    private(set) var status = "pending"

    func start() {
        store.requestFullAccessToEvents { [weak self] ok, _ in
            guard let self else { return }
            self.granted = ok
            self.status = ok ? "ok" : "denied"
            if !ok { print("⚠️  Calendar access denied — allow it in System Settings → Privacy & Security → Calendars.") }
            self.refresh()
        }
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: nil) { [weak self] _ in self?.refresh() }
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func snapshot() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return ["status": status, "events": events]
    }

    private func refresh() {
        guard granted else { return }
        let cal = Calendar.current, now = Date()
        let end = cal.date(byAdding: .day, value: 2, to: cal.startOfDay(for: now))!
        let pred = store.predicateForEvents(withStart: cal.startOfDay(for: now), end: end, calendars: nil)
        let list = store.events(matching: pred)
            .filter { $0.endDate > now }
            .sorted { ($0.isAllDay ? 0 : 1, $0.startDate) < ($1.isAllDay ? 0 : 1, $1.startDate) }
            .prefix(8)
            .map { e -> [String: Any] in
                var color = "#64d2ff"
                if let c = e.calendar.color?.usingColorSpace(.sRGB) {
                    color = String(format: "#%02x%02x%02x", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
                }
                return ["title": e.title ?? "Event", "start": e.startDate.timeIntervalSince1970 * 1000,
                        "end": e.endDate.timeIntervalSince1970 * 1000, "allDay": e.isAllDay, "color": color]
            }
        lock.lock(); events = Array(list); lock.unlock()
    }
}
