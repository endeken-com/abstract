import CryptoKit
import Foundation

/// Where session worktrees live and what their branches are called.
public enum WorktreeNaming {
    /// Tokens: `{home} {repo} {hash} {slug} {branch} {prefix}`.
    public static let defaultTemplate = "{home}/.abstract/worktrees/{repo}-{hash}/{slug}"
    public static let defaultBranchPrefix = "abstract/"

    /// Short, recognizable names for new chats and their worktrees. Use each
    /// city once per project, then combine two short cities when needed.
    public static func cityName(avoiding usedNames: Set<String>) -> String {
        let used = Set(usedNames.map { $0.lowercased() })
        let start = Int.random(in: 0..<cities.count)
        for offset in 0..<cities.count {
            let city = cities[(start + offset) % cities.count]
            if !used.contains(city.lowercased()) { return city }
        }

        let pairCount = pairCities.count * pairCities.count
        let pairStart = Int.random(in: 0..<pairCount)
        for offset in 0..<pairCount {
            let index = (pairStart + offset) % pairCount
            let first = index / pairCities.count
            let second = index % pairCities.count
            if first == second { continue }
            let name = "\(pairCities[first])-\(pairCities[second])"
            if !used.contains(name.lowercased()) { return name }
        }

        let city = cities[start]
        var number = 2
        while used.contains("\(city.lowercased())-\(number)") { number += 1 }
        return "\(city)-\(number)"
    }

    static let cities = [
        "Aachen", "Abuja", "Accra", "Adelaide", "Agra", "Ahmedabad", "Albany", "Alexandria",
        "Algiers", "Amman", "Ankara", "Antalya", "Arequipa", "Athens", "Auckland", "Austin",
        "Baku", "Bamako", "Bandung", "Bangkok", "Barcelona", "Bari", "Basel", "Beijing",
        "Belfast", "Belgrade", "Bergen", "Bern", "Bilbao", "Birmingham", "Bogota", "Bordeaux",
        "Boston", "Braga", "Brisbane", "Bristol", "Brno", "Budapest", "Busan", "Cadiz",
        "Cairo", "Calgary", "Canberra", "Cardiff", "Chengdu", "Chennai", "Chicago", "Chiba",
        "Coimbra", "Cologne", "Colombo", "Cordoba", "Cork", "Curitiba", "Cusco", "Daegu",
        "Dakar", "Dalian", "Dallas", "Delhi", "Denver", "Detroit", "Dhaka", "Dresden",
        "Dubai", "Dublin", "Durban", "Edinburgh", "Edmonton", "Eindhoven", "Erbil", "Essen",
        "Exeter", "Faro", "Fez", "Florence", "Frankfurt", "Freiburg", "Fukuoka", "Gaborone",
        "Galway", "Gdansk", "Geneva", "Genoa", "Ghent", "Glasgow", "Granada", "Graz",
        "Grenoble", "Guangzhou", "Guayaquil", "Hamburg", "Hangzhou", "Hanoi", "Harare", "Havana",
        "Helsinki", "Hilo", "Hobart", "Houston", "Huelva", "Hyderabad", "Ibadan", "Innsbruck",
        "Ipswich", "Islamabad", "Istanbul", "Izmir", "Jaipur", "Jakarta", "Jeddah", "Jodhpur",
        "Juba", "Kampala", "Kanpur", "Karachi", "Katowice", "Kazan", "Khartoum", "Kigali",
        "Kingston", "Kobe", "Kochi", "Kolkata", "Krakow", "Kumasi", "Kyoto", "Lagos",
        "Lahore", "Leeds", "Leicester", "Lille", "Lima", "Linz", "Lisbon", "Liverpool",
        "Ljubljana", "Lome", "London", "Luanda", "Lublin", "Lucknow", "Luxembourg", "Lyon",
        "Macau", "Madrid", "Malaga", "Malmo", "Manaus", "Manila", "Maputo", "Marseille",
        "Medellin", "Mendoza", "Miami", "Milan", "Minsk", "Montreal", "Moscow", "Mumbai",
        "Munich", "Muscat", "Mysore", "Nagoya", "Nairobi", "Nantes", "Naples", "Nashik",
        "Newcastle", "Nice", "Nicosia", "Nijmegen", "Norwich", "Nottingham", "Nuuk", "Oakland",
        "Odense", "Odesa", "Oita", "Oran", "Orlando", "Osaka", "Oslo", "Ottawa",
        "Padua", "Palermo", "Pamplona", "Patna", "Penang", "Perth", "Phoenix", "Pisa",
        "Porto", "Poznan", "Prague", "Pretoria", "Puebla", "Pune", "Qingdao", "Quebec",
        "Quito", "Rabat", "Raleigh", "Ranchi", "Recife", "Rennes", "Reykjavik", "Richmond",
        "Riga", "Riyadh", "Rome", "Rosario", "Rotterdam", "Salem", "Sapporo", "Sarajevo",
        "Seattle", "Sendai", "Seoul", "Seville", "Shanghai", "Shenzhen", "Sofia", "Split",
        "Stockholm", "Stuttgart", "Surat", "Suva", "Sydney", "Tabriz", "Taichung", "Taipei",
        "Tallinn", "Tampa", "Tartu", "Tashkent", "Tehran", "Tirana", "Tokyo", "Toronto",
        "Toulouse", "Trento", "Tripoli", "Tucson", "Tunis", "Turin", "Udaipur", "Uppsala",
        "Utrecht", "Urumqi", "Vadodara", "Valencia", "Vancouver", "Venice", "Veracruz", "Verona",
        "Victoria", "Vienna", "Vilnius", "Vitoria", "Warsaw", "Wellington", "Wroclaw", "Wuhan",
        "Xiamen", "Xian", "Xining", "Yerevan", "Yokohama", "York", "Yuma", "Zagreb",
        "Zanzibar", "Zaragoza", "Zibo", "Zurich",
    ]

    static let pairCities = cities.filter { $0.count <= 7 }

    /// Lowercase ASCII letters and digits joined by single dashes, at most 40
    /// characters, never empty ("session" when nothing usable is left).
    public static func slugify(_ input: String) -> String {
        var out: [UInt8] = []
        var lastDash = true
        for scalar in input.unicodeScalars {
            if scalar.isASCII, let byte = UInt8(exactly: scalar.value), isAlphanumeric(byte) {
                out.append(lowercased(byte))
                lastDash = false
            } else if !lastDash && out.count < 40 {
                out.append(UInt8(ascii: "-"))
                lastDash = true
            }
            if out.count >= 40 { break }
        }
        while out.first == UInt8(ascii: "-") { out.removeFirst() }
        while out.last == UInt8(ascii: "-") { out.removeLast() }
        return out.isEmpty ? "session" : String(decoding: out, as: UTF8.self)
    }

    /// A branch name a model suggested, made safe: lowercase kebab-case
    /// segments, `/` kept between them (`fix/login-button`), at most
    /// `maxLength` characters. nil when nothing usable is left.
    public static func branchSlug(_ input: String, maxLength: Int = 60) -> String? {
        let segments = input.split(separator: "/").map { segment -> String in
            let slug = slugify(String(segment))
            // slugify never returns empty; "session" means nothing was usable.
            return slug == "session" && !segment.lowercased().contains("session") ? "" : slug
        }.filter { !$0.isEmpty }
        var out = segments.joined(separator: "/")
        if out.count > maxLength { out = String(out.prefix(maxLength)) }
        while let last = out.last, last == "-" || last == "/" { out.removeLast() }
        return out.isEmpty ? nil : out
    }

    /// First 8 hex characters of the SHA-256 of `input`. Keeps worktree
    /// directories of same-named repositories apart.
    public static func shortHash(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).prefix(4).map { byte in
            let hex = String(byte, radix: 16)
            return hex.count == 1 ? "0" + hex : hex
        }.joined()
    }

    /// Expand every token in a path or branch template.
    public static func render(
        template: String, home: String, repo: String, hash: String, slug: String, branch: String, prefix: String
    ) -> String {
        template
            .replacingOccurrences(of: "{home}", with: home)
            .replacingOccurrences(of: "{repo}", with: repo)
            .replacingOccurrences(of: "{hash}", with: hash)
            .replacingOccurrences(of: "{slug}", with: slug)
            .replacingOccurrences(of: "{branch}", with: branch)
            .replacingOccurrences(of: "{prefix}", with: prefix)
    }

    private static func isAlphanumeric(_ b: UInt8) -> Bool {
        (0x30...0x39).contains(b) || (0x41...0x5A).contains(b) || (0x61...0x7A).contains(b)
    }

    private static func lowercased(_ b: UInt8) -> UInt8 {
        (0x41...0x5A).contains(b) ? b + 0x20 : b
    }
}
