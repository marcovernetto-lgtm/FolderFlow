import Foundation

struct ProjectNaming {
    static let preferenceKey = "ProjectNamingPattern"
    static let defaultPattern = "{AA}_{MM}_{NN}_{Nome}"
    static let presets = [defaultPattern, "{AAAA}_{MM}_{NN}_{Nome}", "{AAAA}-{MM}-{GG}_{NN}_{Nome}", "{NN}_{Nome}"]
    static let tokens = ["AA", "AAAA", "MM", "GG", "NN", "Nome"]
    let pattern: String

    private static let tokenRegex = try! NSRegularExpression(pattern: #"\{([^{}]*)\}"#)
    private let fields: [String]

    init(pattern: String = Self.defaultPattern) {
        self.pattern = pattern
        fields = Self.tokenRegex.matches(in: pattern, range: NSRange(pattern.startIndex..., in: pattern)).compactMap {
            Range($0.range(at: 1), in: pattern).map { String(pattern[$0]) }
        }
    }

    var validationError: String? {
        guard pattern.count <= 160, !pattern.isEmpty else { return "Inserisci un formato di massimo 160 caratteri." }
        guard !pattern.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }), !pattern.contains(where: { "/:\\\n\r\0".contains($0) }) else { return "Il formato non può contenere separatori di percorso o ritorni a capo." }
        var literal = pattern
        for field in fields { literal = literal.replacingOccurrences(of: "{\(field)}", with: "") }
        guard !literal.contains("{"), !literal.contains("}") else { return "Controlla le parentesi dei campi." }
        guard fields.allSatisfy(Self.tokens.contains) else { return "Usa solo i campi AA, AAAA, MM, GG, NN e Nome." }
        guard fields.filter({ $0 == "Nome" }).count == 1 else { return "Il formato deve contenere una sola volta {Nome}." }
        guard Set(fields).count == fields.count, !(fields.contains("AA") && fields.contains("AAAA")) else { return "Usa ogni campo una sola volta e scegli AA oppure AAAA." }
        guard !pattern.hasPrefix(".") else { return "Il formato non può creare cartelle nascoste." }
        guard pattern != "{Nome}" else { return "Aggiungi una data, un numero o un prefisso per distinguere i progetti dalle altre cartelle." }
        // Separate variable-length name and number fields so matching is unambiguous.
        for first in ["Nome", "NN"] {
            for second in fields where first != second {
                guard !pattern.contains("{\(first)}{\(second)}"), !pattern.contains("{\(second)}{\(first)}") else {
                    return "Separa Nome e NN dagli altri campi con uno spazio o un simbolo, per esempio _."
                }
            }
        }
        return nil
    }

    static func componentError(_ name: String) -> String? {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "Inserisci il nome del lavoro." }
        guard !name.hasPrefix("."), !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }), !name.contains(where: { "/:\\".contains($0) }) else {
            return "Il nome non può contenere separatori di percorso o caratteri di controllo."
        }
        guard name.utf8.count <= 255 else { return "Il nome della cartella è troppo lungo." }
        return nil
    }

    private var expression: NSRegularExpression? {
        guard validationError == nil else { return nil }
        let tokenRegex = Self.tokenRegex
        var regex = "^", cursor = pattern.startIndex
        for match in tokenRegex.matches(in: pattern, range: NSRange(pattern.startIndex..., in: pattern)) {
            guard let range = Range(match.range, in: pattern), let fieldRange = Range(match.range(at: 1), in: pattern) else { return nil }
            regex += NSRegularExpression.escapedPattern(for: String(pattern[cursor..<range.lowerBound]))
            switch String(pattern[fieldRange]) {
            case "AA": regex += #"([0-9]{2})"#
            case "AAAA": regex += #"([0-9]{4})"#
            case "MM": regex += #"(0[1-9]|1[0-2])"#
            case "GG": regex += #"(0[1-9]|[12][0-9]|3[01])"#
            case "NN": regex += #"([0-9]{2,})"#
            default: regex += #"(.+?)"#
            }
            cursor = range.upperBound
        }
        regex += NSRegularExpression.escapedPattern(for: String(pattern[cursor...])) + "$"
        return try? NSRegularExpression(pattern: regex)
    }

    private func values(in name: String, using compiled: NSRegularExpression? = nil) -> [String: String]? {
        guard Self.componentError(name) == nil, let regex = compiled ?? expression,
              let match = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) else { return nil }
        var result: [String: String] = [:]
        for (index, field) in fields.enumerated() {
            guard let range = Range(match.range(at: index + 1), in: name) else { return nil }
            result[field] = String(name[range])
        }
        guard let title = result["Nome"], Self.componentError(title) == nil else { return nil }
        if let serial = result["NN"], Int(serial) == nil { return nil }
        if let month = result["MM"].flatMap(Int.init), let day = result["GG"].flatMap(Int.init) {
            let year = result["AAAA"].flatMap(Int.init) ?? result["AA"].flatMap(Int.init).map { 2000 + $0 } ?? 2000
            let calendar = Calendar(identifier: .gregorian)
            guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
                  calendar.component(.month, from: date) == month, calendar.component(.day, from: date) == day else { return nil }
        }
        return result
    }

    func matches(_ name: String) -> Bool { values(in: name) != nil }

    func year(in name: String) -> Int? {
        guard let values = values(in: name) else { return nil }
        return values["AAAA"].flatMap(Int.init) ?? values["AA"].flatMap(Int.init).map { 2000 + $0 }
    }

    func name(title: String, date: Date, existingNames: [String]) -> String? {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard validationError == nil, Self.componentError(title) == nil, let compiled = expression else { return nil }
        let calendar = Calendar(identifier: .gregorian)
        let year = calendar.component(.year, from: date)
        let dateValues = ["AA": String(format: "%02d", year % 100), "AAAA": String(format: "%04d", year),
                          "MM": String(format: "%02d", calendar.component(.month, from: date)),
                          "GG": String(format: "%02d", calendar.component(.day, from: date))]
        let numbers = existingNames.compactMap { name -> Int? in
            guard let old = values(in: name, using: compiled), dateValues.allSatisfy({ old[$0.key] == nil || old[$0.key] == $0.value }) else { return nil }
            return old["NN"].flatMap(Int.init)
        }
        let maxNumber = numbers.max() ?? 0
        guard !fields.contains("NN") || maxNumber < Int.max else { return nil }
        var replacements = dateValues
        replacements["NN"] = String(format: "%02ld", maxNumber < Int.max ? maxNumber + 1 : 1)
        replacements["Nome"] = title
        // Replace tokens in the template once: token-like text inside a title stays literal.
        let regex = Self.tokenRegex
        var result = pattern
        for match in regex.matches(in: pattern, range: NSRange(pattern.startIndex..., in: pattern)).reversed() {
            guard let range = Range(match.range, in: result), let fieldRange = Range(match.range(at: 1), in: pattern),
                  let replacement = replacements[String(pattern[fieldRange])] else { return nil }
            result.replaceSubrange(range, with: replacement)
        }
        guard Self.componentError(result) == nil, values(in: result, using: compiled) != nil else { return nil }
        return result
    }
}
