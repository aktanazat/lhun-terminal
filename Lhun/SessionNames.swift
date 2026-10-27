/// Names for the sessions he starts without naming them: two calm words from outdoors, "brave-meadow", as
/// Rex names its tabs. They are easier to tell apart and to say than tmux's own 1, 2, 3.
enum SessionNames {
    static let adjectives = [
        "amber", "ancient", "autumn", "bold", "brave", "bright", "calm", "clear", "cool", "cosmic", "crisp", "dawn",
        "distant", "drifting", "dusky", "early", "electric", "frosty", "gentle", "golden", "hazy", "hidden", "hollow",
        "humble", "icy", "lucid", "lunar", "mellow", "misty", "morning", "mossy", "noble", "open", "pale", "patient",
        "polar", "quiet", "rising", "rolling", "rustic", "sandy", "serene", "silent", "silver", "sleepy", "slow",
        "snowy", "soft", "solar", "still", "sunny", "swift", "tall", "tidal", "tranquil", "twilight", "velvet",
        "verdant", "wandering", "warm", "wild", "windy", "winter", "wispy",
    ]

    static let nouns = [
        "aspen", "bay", "birch", "brook", "canopy", "canyon", "cedar", "cliff", "cloud", "coast", "cove", "creek",
        "delta", "dune", "fern", "field", "fjord", "forest", "garden", "glacier", "glade", "glen", "grove", "harbor",
        "heath", "hill", "horizon", "island", "juniper", "knoll", "lagoon", "lake", "lotus", "maple", "marsh",
        "meadow", "mesa", "mountain", "oak", "ocean", "orchard", "pasture", "peak", "pine", "plain", "pond",
        "prairie", "rain", "reef", "ridge", "river", "shore", "sky", "spring", "star", "stone", "stream", "summit",
        "thicket", "trail", "tundra", "valley", "willow", "wood",
    ]

    /// A name nothing in `taken` has. It starts at a random pair of words and walks on from there, so it
    /// always ends; with every pair taken it numbers them, "brave-meadow-2".
    static func fresh(avoiding taken: Set<String>, using generator: inout some RandomNumberGenerator) -> String {
        let pairs = adjectives.count * nouns.count
        let start = Int.random(in: 0..<pairs, using: &generator)
        var suffix = ""
        var number = 1
        while true {
            for step in 0..<pairs {
                let pair = (start + step) % pairs
                let name = adjectives[pair / nouns.count] + "-" + nouns[pair % nouns.count] + suffix
                if !taken.contains(name) { return name }
            }
            number += 1
            suffix = "-\(number)"
        }
    }
}
