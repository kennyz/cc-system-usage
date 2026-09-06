import Foundation

/// Optional user settings at ~/.config/menumon/config.json:
///
///     {
///       "pricing": { "claude-opus-5": { "input": 5, "output": 25 } },
///       "fiveHourCostBudget": 12.50,
///       "fiveHourTokenBudget": 0
///     }
///
/// `pricing` values are USD per million tokens; cache rates are derived
/// (read 0.1x input, write 1.25x for 5m TTL / 2x for 1h TTL).
struct Config {
    var fiveHourCostBudget: Double = 0     // 0 = no budget gauge
    var fiveHourTokenBudget: Int = 0

    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/menumon/config.json")
    }

    static func load() -> Config {
        var config = Config()
        guard let data = try? Data(contentsOf: url),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return config }

        if let budget = root["fiveHourCostBudget"] as? Double { config.fiveHourCostBudget = budget }
        if let budget = root["fiveHourTokenBudget"] as? Int { config.fiveHourTokenBudget = budget }

        if let pricing = root["pricing"] as? [String: [String: Double]] {
            var overrides: [String: ModelPrice] = [:]
            for (model, rates) in pricing {
                guard let input = rates["input"], let output = rates["output"] else { continue }
                overrides[model] = ModelPrice(input: input, output: output, estimated: false)
            }
            Pricing.overrides = overrides
        }
        return config
    }
}
