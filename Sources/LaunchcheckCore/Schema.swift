import Foundation

/// Reads JSON-LD blocks and checks them against what rich results require.
public enum SchemaInspector {
    public struct Result: Equatable, Sendable {
        public var types: [String] = []
        /// (check id, detail)
        public var issues: [Issue] = []
    }

    public struct Issue: Equatable, Sendable {
        public let check: String
        public let detail: String
    }

    /// Types search engines no longer show a rich result for, with what happened to each.
    static let retired: [String: String] = [
        "HowTo": "rich results removed in September 2023",
        "SpecialAnnouncement": "deprecated in July 2025",
        "CourseInfo": "retired in June 2025",
        "EstimatedSalary": "retired in June 2025",
        "LearningVideo": "retired in June 2025",
        "ClaimReview": "no rich result since June 2025",
        "VehicleListing": "retired in June 2025",
        "PracticeProblem": "retired in January 2026",
        "Attorney": "deprecated by Schema.org; use LegalService",
        "FAQPage": "rich results retired in May 2026; harmless to keep",
    ]

    static let localBusinessTypes: Set<String> = [
        "LocalBusiness", "Restaurant", "Dentist", "LegalService", "Store", "MedicalClinic", "Hospital", "AutoDealer", "AutoRepair",
        "HomeAndConstructionBusiness", "Plumber", "Electrician", "RealEstateAgent", "BeautySalon", "HairSalon", "Bakery",
        "CafeOrCoffeeShop", "BarOrPub", "Hotel", "LodgingBusiness", "ProfessionalService", "FinancialService", "TravelAgency",
        "HealthAndBeautyBusiness", "SportsActivityLocation", "ExerciseGym", "FoodEstablishment", "MedicalBusiness", "Physician",
    ]

    public static func inspect(_ blocks: [String]) -> Result {
        var result = Result()
        for block in blocks {
            let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard let json = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8), options: [.fragmentsAllowed]) else {
                result.issues.append(Issue(check: "schema.invalid", detail: "a JSON-LD block is not valid JSON"))
                continue
            }
            let roots = (json as? [Any]) ?? [json]
            for case let root as [String: Any] in roots {
                let graph = root["@graph"] as? [Any]
                if root["@context"] == nil {
                    result.issues.append(Issue(check: "schema.incomplete", detail: "a JSON-LD block has no @context"))
                }
                if graph == nil, root["@type"] == nil {
                    result.issues.append(Issue(check: "schema.incomplete", detail: "a JSON-LD block has no @type"))
                }
                walk(root, into: &result)
            }
        }
        // The same template runs on every page; say each thing once per page.
        var seen = Set<String>()
        result.issues = result.issues.filter { seen.insert($0.check + $0.detail).inserted }
        var seenTypes = Set<String>()
        result.types = result.types.filter { seenTypes.insert($0).inserted }
        return result
    }

    private static func types(of node: [String: Any]) -> [String] {
        if let one = node["@type"] as? String { return [one] }
        return (node["@type"] as? [Any])?.compactMap { $0 as? String } ?? []
    }

    private static func has(_ node: [String: Any], _ key: String) -> Bool {
        guard let value = node[key] else { return false }
        if value is NSNull { return false }
        if let text = value as? String { return !text.trimmingCharacters(in: .whitespaces).isEmpty }
        if let list = value as? [Any] { return !list.isEmpty }
        return true
    }

    private static func walk(_ value: Any, into result: inout Result) {
        if let list = value as? [Any] {
            for item in list { walk(item, into: &result) }
            return
        }
        if let text = value as? String {
            // "[Business Name]", "[Your phone number]" and the like, left over from a template.
            if text.range(of: #"\[[A-Z][A-Za-z ]{2,40}\]"#, options: .regularExpression) != nil {
                result.issues.append(Issue(check: "schema.placeholder", detail: "“\(text.prefix(60))”"))
            }
            return
        }
        guard let node = value as? [String: Any] else { return }

        for type in types(of: node) {
            result.types.append(type)
            if let note = retired[type] {
                result.issues.append(Issue(check: "schema.deprecated", detail: "\(type): \(note)"))
            }
            switch type {
            case "Product":
                for key in ["name", "image", "offers"] where !has(node, key) {
                    result.issues.append(Issue(check: "schema.incomplete", detail: "Product has no \(key)"))
                }
                let offers = (node["offers"] as? [Any]) ?? node["offers"].map { [$0] } ?? []
                for case let offer as [String: Any] in offers where types(of: offer).contains("Offer") || types(of: offer).isEmpty {
                    let priced = has(offer, "price") || has(offer, "priceSpecification")
                    if !priced { result.issues.append(Issue(check: "schema.incomplete", detail: "Product offer has no price")) }
                    if priced, has(offer, "price"), !has(offer, "priceCurrency") {
                        result.issues.append(Issue(check: "schema.incomplete", detail: "Product offer has a price but no priceCurrency"))
                    }
                }
            case "BreadcrumbList":
                let items = (node["itemListElement"] as? [Any]) ?? []
                if items.isEmpty { result.issues.append(Issue(check: "schema.incomplete", detail: "BreadcrumbList has no itemListElement")) }
                for case let item as [String: Any] in items {
                    let named = has(item, "name") || ((item["item"] as? [String: Any]).map { has($0, "name") } ?? false)
                    if !has(item, "position") || !named {
                        result.issues.append(Issue(check: "schema.incomplete", detail: "BreadcrumbList items need a position and a name"))
                        break
                    }
                }
            case "AggregateRating":
                if !has(node, "ratingValue") || !(has(node, "reviewCount") || has(node, "ratingCount")) {
                    result.issues.append(Issue(check: "schema.incomplete", detail: "AggregateRating needs ratingValue and reviewCount"))
                }
            case let local where localBusinessTypes.contains(local):
                for key in ["name", "address"] where !has(node, key) {
                    result.issues.append(Issue(check: "schema.incomplete", detail: "\(local) has no \(key)"))
                }
            default:
                break
            }
        }
        for key in node.keys.sorted() where key != "@context" { walk(node[key] as Any, into: &result) }
    }
}

/// Validates hreflang values such as "en", "en-GB", "zh-Hant-TW" and "x-default".
public enum Hreflang {
    private static let languages: Set<String> = Set("""
    aa ab ae af ak am an ar as av ay az ba be bg bh bi bm bn bo br bs ca ce ch co cr cs cu cv cy da de dv dz ee el en eo es et eu fa ff fi fj fo fr fy ga gd gl gn gu gv ha he hi ho hr ht hu hy hz ia id ie ig ii ik io is it iu ja jv ka kg ki kj kk kl km kn ko kr ks ku kv kw ky la lb lg li ln lo lt lu lv mg mh mi mk ml mn mr ms mt my na nb nd ne ng nl nn no nr nv ny oc oj om or os pa pi pl ps pt qu rm rn ro ru rw sa sc sd se sg si sk sl sm sn so sq sr ss st su sv sw ta te tg th ti tk tl tn to tr ts tt tw ty ug uk ur uz ve vi vo wa wo xh yi yo za zh zu
    """.split(whereSeparator: \.isWhitespace).map(String.init))

    private static let regions: Set<String> = Set("""
    AD AE AF AG AI AL AM AO AQ AR AS AT AU AW AX AZ BA BB BD BE BF BG BH BI BJ BL BM BN BO BQ BR BS BT BV BW BY BZ CA CC CD CF CG CH CI CK CL CM CN CO CR CU CV CW CX CY CZ DE DJ DK DM DO DZ EC EE EG EH ER ES ET FI FJ FK FM FO FR GA GB GD GE GF GG GH GI GL GM GN GP GQ GR GS GT GU GW GY HK HM HN HR HT HU ID IE IL IM IN IO IQ IR IS IT JE JM JO JP KE KG KH KI KM KN KP KR KW KY KZ LA LB LC LI LK LR LS LT LU LV LY MA MC MD ME MF MG MH MK ML MM MN MO MP MQ MR MS MT MU MV MW MX MY MZ NA NC NE NF NG NI NL NO NP NR NU NZ OM PA PE PF PG PH PK PL PM PN PR PS PT PW PY QA RE RO RS RU RW SA SB SC SD SE SG SH SI SJ SK SL SM SN SO SR SS ST SV SX SY SZ TC TD TF TG TH TJ TK TL TM TN TO TR TT TV TW TZ UA UG UM US UY UZ VA VC VE VG VI VN VU WF WS YE YT ZA ZM ZW
    """.split(whereSeparator: \.isWhitespace).map(String.init))

    /// nil when the value is valid, otherwise what is wrong with it.
    public static func problem(with value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed.lowercased() == "x-default" { return nil }
        let parts = trimmed.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard let language = parts.first, !language.isEmpty else { return "empty value" }
        guard languages.contains(language.lowercased()) else {
            return language.count == 2 ? "“\(language)” is not a language code" : "“\(language)” is not a two-letter language code"
        }
        guard parts.count <= 3 else { return "too many parts" }
        for part in parts.dropFirst() {
            if part.count == 4, part.allSatisfy(\.isLetter) { continue }             // a script, as in zh-Hant
            guard regions.contains(part.uppercased()) else {
                return part.lowercased() == "uk" ? "“uk” is not a region code; Britain is GB" : "“\(part)” is not a region code"
            }
        }
        return nil
    }
}
