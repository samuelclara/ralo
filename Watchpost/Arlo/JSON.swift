import Foundation

typealias JSONObject = [String: Any]

extension Dictionary where Key == String, Value == Any {
    func string(_ key: String) -> String? {
        if let value = self[key] as? String { return value }
        if let number = self[key] as? NSNumber { return number.stringValue }
        return nil
    }

    func int(_ key: String) -> Int? {
        if let number = self[key] as? NSNumber { return number.intValue }
        if let text = self[key] as? String { return Int(text) }
        return nil
    }

    func double(_ key: String) -> Double? {
        if let number = self[key] as? NSNumber { return number.doubleValue }
        if let text = self[key] as? String { return Double(text) }
        return nil
    }

    func bool(_ key: String) -> Bool? {
        if let number = self[key] as? NSNumber { return number.boolValue }
        if let text = self[key] as? String { return ["true", "1", "yes"].contains(text.lowercased()) }
        return nil
    }

    func object(_ key: String) -> JSONObject? {
        self[key] as? JSONObject
    }

    func objects(_ key: String) -> [JSONObject] {
        (self[key] as? [Any])?.compactMap { $0 as? JSONObject } ?? []
    }

    func url(_ key: String) -> URL? {
        guard let text = string(key), let url = URL(string: text), url.scheme == "https" else { return nil }
        return url
    }
}
