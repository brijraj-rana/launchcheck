import Foundation

/// What one schema.org type asks for, as far as a crawler can tell from the markup alone.
public struct SchemaRule: Equatable, Sendable {
    /// Without these the markup does not qualify for its rich result. Missing ones are a "should fix".
    public let required: [String]
    /// Worth having. Missing ones are only worth a look.
    public let recommended: [String]
    /// True when the required properties are asked of the type wherever it appears. Otherwise only of an item that
    /// stands on its own, since a publisher or an author nested inside an article is often just a name.
    public let everywhere: Bool
    /// The Google result the type can earn, when that is well known.
    public let richResult: String?

    public init(required: [String] = [], recommended: [String] = [], everywhere: Bool = false, richResult: String? = nil) {
        self.required = required
        self.recommended = recommended
        self.everywhere = everywhere
        self.richResult = richResult
    }
}

/// One property of a structured data item, with its value cut short for showing.
public struct SchemaField: Codable, Equatable, Sendable {
    public let name: String
    public let value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

/// One thing a JSON-LD block describes: an Organization, an Article, the Person who wrote it.
public struct SchemaItem: Codable, Equatable, Identifiable, Sendable {
    /// Where it sits: "1.0" is the first item of the first block, "1.0.author" the author inside it.
    public let id: String
    public let types: [String]
    /// The property of its parent that holds it ("author", "publisher"), for a nested item.
    public let role: String?
    public let fields: [SchemaField]
    /// What the type requires and this item lacks, each as a short sentence.
    public let required: [String]
    /// What the type recommends and this item lacks.
    public let recommended: [String]
    /// Anything else worth saying: a retired type, a placeholder left in, a value in the wrong form.
    public let notes: [String]
    /// The Google result the type can earn, when that is well known.
    public let richResult: String?
    public let children: [SchemaItem]

    /// "Article", or "Organization, Brand" for an item of two types.
    public var name: String { types.isEmpty ? "No @type" : types.joined(separator: ", ") }
}

/// One <script type="application/ld+json"> as it was found.
public struct SchemaBlock: Codable, Equatable, Identifiable, Sendable {
    /// Its place on the page, counting from 1.
    public let index: Int
    /// The script as written, for copying. Left out when it is very long.
    public let raw: String?
    /// Why it could not be read, when it could not.
    public let error: String?
    public let items: [SchemaItem]

    public var id: Int { index }
    public var parses: Bool { error == nil }
}

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

    static let articleTypes: Set<String> = ["Article", "BlogPosting", "NewsArticle"]
    static let organizationTypes: Set<String> = ["Organization", "Corporation"]

    /// What each of the common types asks for. Rules that need more than "is the property there" (an offer's price,
    /// a breadcrumb's steps, an FAQ's answers) are written out in `problems(with:top:)`.
    public static let rules: [String: SchemaRule] = {
        var rules: [String: SchemaRule] = [
            "WebSite": SchemaRule(required: ["url"], recommended: ["name"], richResult: "Site name"),
            "Product": SchemaRule(required: ["name", "image", "offers"], recommended: ["description"], everywhere: true, richResult: "Product snippet"),
            "BreadcrumbList": SchemaRule(required: ["itemListElement"], everywhere: true, richResult: "Breadcrumb"),
            "FAQPage": SchemaRule(required: ["mainEntity"], richResult: "FAQ, shown for government and health sites only"),
            "AggregateRating": SchemaRule(everywhere: true, richResult: "Review stars"),
            "Recipe": SchemaRule(richResult: "Recipe"),
            "Event": SchemaRule(richResult: "Event"),
            "JobPosting": SchemaRule(richResult: "Job posting"),
            "VideoObject": SchemaRule(richResult: "Video"),
            "SoftwareApplication": SchemaRule(richResult: "Software app"),
            "Review": SchemaRule(richResult: "Review snippet"),
            "Course": SchemaRule(richResult: "Course list"),
            "ProfilePage": SchemaRule(richResult: "Profile page"),
            "DiscussionForumPosting": SchemaRule(richResult: "Discussion forum"),
        ]
        for type in organizationTypes {
            rules[type] = SchemaRule(recommended: ["name", "url", "logo"], richResult: "Organization logo and knowledge panel")
        }
        for type in articleTypes {
            rules[type] = SchemaRule(recommended: ["headline", "image", "datePublished", "author"], richResult: "Article")
        }
        for type in localBusinessTypes {
            rules[type] = SchemaRule(required: ["name", "address"], everywhere: true, richResult: "Local business")
        }
        return rules
    }()

    /// Properties that hold a date, and ones that hold an address.
    static let dateProperties: Set<String> = ["datePublished", "dateModified", "dateCreated", "uploadDate", "startDate", "endDate", "datePosted", "validThrough"]
    static let addressProperties: Set<String> = ["url", "logo", "image", "contentUrl", "thumbnailUrl", "embedUrl", "sameAs"]

    // MARK: Checking

    public static func inspect(_ blocks: [String]) -> Result {
        var result = Result()
        for block in blocks {
            switch read(block) {
            case .empty:
                continue
            case .unreadable(let detail):
                result.issues.append(Issue(check: "schema.invalid", detail: detail))
            case .roots(let roots):
                for root in roots {
                    result.issues += problems(withBlock: root)
                    for (node, top) in standing(in: root) { walk(node, top: top, into: &result) }
                }
            }
        }
        // The same template runs on every page; say each thing once per page.
        var seen = Set<String>()
        result.issues = result.issues.filter { seen.insert($0.check + $0.detail).inserted }
        var seenTypes = Set<String>()
        result.types = result.types.filter { seenTypes.insert($0).inserted }
        return result
    }

    private enum Reading {
        case empty
        case unreadable(String)
        case roots([[String: Any]])
    }

    private static func read(_ block: String) -> Reading {
        let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }
        if let line = trailingComma(in: trimmed) {
            // The usual slip, and one Foundation lets through on some systems. Search engines do not.
            return .unreadable("a JSON-LD block has a comma before a closing bracket, on line \(line)")
        }
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: Data(trimmed.utf8), options: [.fragmentsAllowed])
        } catch {
            return .unreadable("a JSON-LD block is not valid JSON" + place(of: error))
        }
        guard json is [Any] || json is [String: Any] else {
            // Valid JSON, but a bare string or number describes nothing.
            return .unreadable("a JSON-LD block holds no object")
        }
        return .roots(((json as? [Any]) ?? [json]).compactMap { $0 as? [String: Any] })
    }

    /// What is wrong with a block as a whole, before looking at what it describes.
    private static func problems(withBlock root: [String: Any]) -> [Issue] {
        var issues: [Issue] = []
        let graph = root["@graph"] as? [Any]
        if root["@context"] == nil { issues.append(Issue(check: "schema.incomplete", detail: "a JSON-LD block has no @context")) }
        if graph == nil, types(of: root).isEmpty { issues.append(Issue(check: "schema.incomplete", detail: "a JSON-LD block has no @type")) }
        // Each item in a @graph stands on its own, so each has to say what it is.
        for case let item as [String: Any] in graph ?? [] where types(of: item).isEmpty && !isReference(item) {
            issues.append(Issue(check: "schema.incomplete", detail: "an item in @graph has no @type"))
        }
        return issues
    }

    /// The items of a block that stand on their own: the block itself, or each member of its @graph.
    private static func standing(in root: [String: Any]) -> [(node: [String: Any], top: Bool)] {
        guard let graph = root["@graph"] as? [Any] else { return [(root, true)] }
        var nodes = graph.compactMap { $0 as? [String: Any] }.map { (node: $0, top: true) }
        // Anything else the wrapper carries is still read, as before.
        var rest = root
        rest["@graph"] = nil
        rest["@context"] = nil
        if !rest.isEmpty { nodes.append((rest, false)) }
        return nodes
    }

    private static func walk(_ node: [String: Any], top: Bool, into result: inout Result) {
        result.types += types(of: node)
        result.issues += problems(with: node, top: top)
        for key in node.keys.sorted() where key != "@context" {
            for child in objects(in: node[key] as Any) { walk(child, top: false, into: &result) }
        }
    }

    /// Every object inside a value, however many lists deep.
    private static func objects(in value: Any) -> [[String: Any]] {
        if let node = value as? [String: Any] { return [node] }
        return (value as? [Any])?.flatMap(objects(in:)) ?? []
    }

    /// Everything to say about one item: what its type requires and recommends, retired types, placeholders, values in the wrong form.
    static func problems(with node: [String: Any], top: Bool) -> [Issue] {
        var issues: [Issue] = []
        let reference = isReference(node)

        let kinds = types(of: node)
        for type in kinds {
            if let note = retired[type] { issues.append(Issue(check: "schema.deprecated", detail: "\(type): \(note)")) }
            guard !reference else { continue }
            // A publication marks itself up as both a CreativeWork and a Product so that paywalled articles can say
            // what they belong to. That is not a product for sale, and is not held to a product's list.
            if type == "Product", kinds.contains("CreativeWork") { continue }
            if let rule = rules[type] {
                if rule.everywhere || top {
                    for key in rule.required where !has(node, key) {
                        issues.append(Issue(check: "schema.incomplete", detail: "\(type) has no \(key)"))
                    }
                }
                if top {
                    for key in rule.recommended where !has(node, key) {
                        issues.append(Issue(check: "schema.recommended", detail: "\(type) has no \(key)"))
                    }
                }
            }
            switch type {
            case "Product":
                let offers = (node["offers"] as? [Any]) ?? node["offers"].map { [$0] } ?? []
                for case let offer as [String: Any] in offers where types(of: offer).contains("Offer") || types(of: offer).isEmpty {
                    let priced = has(offer, "price") || has(offer, "priceSpecification")
                    if !priced { issues.append(Issue(check: "schema.incomplete", detail: "Product offer has no price")) }
                    if priced, has(offer, "price"), !has(offer, "priceCurrency") {
                        issues.append(Issue(check: "schema.incomplete", detail: "Product offer has a price but no priceCurrency"))
                    }
                }
            case "BreadcrumbList":
                let items = (node["itemListElement"] as? [Any]) ?? []
                for case let item as [String: Any] in items {
                    let named = has(item, "name") || ((item["item"] as? [String: Any]).map { has($0, "name") } ?? false)
                    if !has(item, "position") || !named {
                        issues.append(Issue(check: "schema.incomplete", detail: "BreadcrumbList items need a position and a name"))
                        break
                    }
                }
                // Every step but the last is a link, so it needs somewhere to go.
                let steps = items.compactMap { $0 as? [String: Any] }
                if steps.count > 1, steps.dropLast().contains(where: { !has($0, "item") }) {
                    issues.append(Issue(check: "schema.incomplete", detail: "BreadcrumbList items before the last need an item address"))
                }
            case "AggregateRating":
                if !has(node, "ratingValue") || !(has(node, "reviewCount") || has(node, "ratingCount")) {
                    issues.append(Issue(check: "schema.incomplete", detail: "AggregateRating needs ratingValue and reviewCount"))
                }
            case "FAQPage" where top:
                let questions = (node["mainEntity"] as? [Any]) ?? node["mainEntity"].map { [$0] } ?? []
                for case let question as [String: Any] in questions {
                    let answers = (question["acceptedAnswer"] as? [Any]) ?? question["acceptedAnswer"].map { [$0] } ?? []
                    let answered = answers.contains { ($0 as? [String: Any]).map { has($0, "text") } ?? false }
                    if !has(question, "name") || !answered {
                        issues.append(Issue(check: "schema.incomplete", detail: "FAQPage questions need a name and an acceptedAnswer with text"))
                        break
                    }
                }
            default:
                break
            }
        }

        // The item's own words: placeholders left from a template, dates and addresses in a form that will be skipped.
        for key in node.keys.sorted() where key != "@context" {
            let texts = (node[key] as? String).map { [$0] } ?? (node[key] as? [Any])?.compactMap { $0 as? String } ?? []
            for text in texts {
                // "[Business Name]", "[Your phone number]" and the like.
                if text.range(of: #"\[[A-Z][A-Za-z ]{2,40}\]"#, options: .regularExpression) != nil {
                    issues.append(Issue(check: "schema.placeholder", detail: "“\(text.prefix(60))”"))
                    continue
                }
                let value = text.trimmingCharacters(in: .whitespaces)
                guard !value.isEmpty else { continue }
                if dateProperties.contains(key), !isDate(value) {
                    issues.append(Issue(check: "schema.values", detail: "\(key) is “\(value.prefix(40))”, not a date written like 2026-02-07"))
                }
                if addressProperties.contains(key), value.hasPrefix("/") || value.hasPrefix("./") || value.hasPrefix("../") {
                    issues.append(Issue(check: "schema.values", detail: "\(key) is “\(value.prefix(60))”, not a full address"))
                }
            }
        }
        return issues
    }

    /// ISO 8601 as structured data uses it: a year, a month or a day, with or without a time.
    static func isDate(_ text: String) -> Bool {
        text.range(of: #"^\d{4}(-\d{2}(-\d{2}([T ]\d{2}:\d{2}(:\d{2}(\.\d+)?)?(Z|[+-]\d{2}:?\d{2})?)?)?)?$"#, options: .regularExpression) != nil
    }

    // MARK: Taking apart

    /// Every block of a page taken apart for showing: its items, their fields, and for each what the checks above say about it.
    public static func outline(_ blocks: [String]) -> [SchemaBlock] {
        var outlined: [SchemaBlock] = []
        var index = 0
        for block in blocks {
            let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            index += 1
            // Kept for copying, unless it is the size of a small book.
            let raw = trimmed.count <= 40_000 ? trimmed : nil
            switch read(block) {
            case .empty:
                continue
            case .unreadable(let detail):
                outlined.append(SchemaBlock(index: index, raw: raw, error: detail.prefix(1).uppercased() + detail.dropFirst() + ".", items: []))
            case .roots(let roots):
                var items: [SchemaItem] = []
                for root in roots {
                    let whole = problems(withBlock: root)
                    for (node, top) in standing(in: root) where top || !types(of: node).isEmpty {
                        var one = item(node, top: top, role: nil, id: "\(index).\(items.count)")
                        // What is wrong with the block as a whole is said on its first item.
                        if items.isEmpty, !whole.isEmpty { one = one.adding(required: whole.map(\.detail)) }
                        items.append(one)
                    }
                }
                outlined.append(SchemaBlock(index: index, raw: raw, error: nil, items: items))
            }
        }
        return outlined
    }

    private static func item(_ node: [String: Any], top: Bool, role: String?, id: String) -> SchemaItem {
        var fields: [SchemaField] = []
        var children: [SchemaItem] = []
        for key in node.keys.sorted() where key != "@context" && key != "@type" {
            let nested = objects(in: node[key] as Any).filter { !types(of: $0).isEmpty }
            for (offset, child) in nested.enumerated() {
                children.append(item(child, top: false, role: key, id: "\(id).\(key)\(nested.count > 1 ? ".\(offset)" : "")"))
            }
            fields.append(SchemaField(name: key, value: short(node[key] as Any)))
        }
        let found = problems(with: node, top: top)
        func details(_ check: String) -> [String] { found.filter { $0.check == check }.map(\.detail) }
        let kinds = types(of: node)
        return SchemaItem(id: id, types: kinds, role: role, fields: fields,
                          required: details("schema.incomplete"), recommended: details("schema.recommended"),
                          notes: (details("schema.deprecated") + details("schema.placeholder").map { "Placeholder left in: \($0)" } + details("schema.values")),
                          richResult: richResult(for: node, top: top), children: children)
    }

    /// Types that earn their result from inside another item: the stars on a product, the trail on a page, the video in an article.
    static let earnsNested: Set<String> = ["AggregateRating", "BreadcrumbList", "VideoObject"]

    /// The Google result an item can earn. An organisation named as a publisher earns nothing by being there, so
    /// nested items are only credited where the result really comes from the nested item.
    private static func richResult(for node: [String: Any], top: Bool) -> String? {
        guard !isReference(node) else { return nil }
        let kinds = types(of: node)
        if kinds.contains("Product"), kinds.contains("CreativeWork") { return nil }
        return kinds.filter { top || earnsNested.contains($0) }.compactMap { rules[$0]?.richResult }.first
    }

    /// A value in a few words: a text cut short, a count for a list, the type for an object.
    static func short(_ value: Any) -> String {
        if value is NSNull { return "null" }
        if let text = value as? String {
            let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return flat.count > 90 ? String(flat.prefix(88)) + "…" : flat
        }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
            return number.stringValue
        }
        if let node = value as? [String: Any] {
            let kinds = types(of: node)
            if !kinds.isEmpty { return kinds.joined(separator: ", ") }
            if isReference(node), let id = node["@id"] as? String { return "→ \(id)" }
            return node.count == 1 ? "1 property" : "\(node.count) properties"
        }
        if let list = value as? [Any] {
            if list.isEmpty { return "empty list" }
            let texts = list.compactMap { $0 as? String }
            if texts.count == list.count {
                let joined = texts.joined(separator: ", ")
                return joined.count <= 90 ? joined : "\(list.count) values, starting with \(short(texts[0]))"
            }
            let kinds = list.compactMap { ($0 as? [String: Any]).flatMap { types(of: $0).first } }
            if kinds.count == list.count, let first = kinds.first, kinds.allSatisfy({ $0 == first }) {
                return list.count == 1 ? first : "\(list.count) × \(first)"
            }
            return list.count == 1 ? short(list[0]) : "\(list.count) items"
        }
        return "\(value)"
    }

    // MARK: Pieces

    private static func types(of node: [String: Any]) -> [String] {
        if let one = node["@type"] as? String { return one.trimmingCharacters(in: .whitespaces).isEmpty ? [] : [one] }
        return (node["@type"] as? [Any])?.compactMap { $0 as? String } ?? []
    }

    /// "near line 4, column 12", when the parser says where it gave up.
    private static func place(of error: Error) -> String {
        let said = ((error as NSError).userInfo["NSDebugDescription"] as? String) ?? ""
        guard let range = said.range(of: #"line \d+, column \d+"#, options: .regularExpression) else { return "" }
        return ", near \(said[range])"
    }

    /// The line of a comma that is followed by nothing but a closing bracket: legal in JavaScript, not in JSON.
    static func trailingComma(in text: String) -> Int? {
        var line = 1
        var inString = false
        var escaped = false
        var commaLine: Int?
        for byte in text.utf8 {
            if byte == UInt8(ascii: "\n") { line += 1 }
            if inString {
                if escaped { escaped = false } else if byte == UInt8(ascii: "\\") { escaped = true } else if byte == UInt8(ascii: "\"") { inString = false }
                continue
            }
            switch byte {
            case UInt8(ascii: "\""):
                inString = true
                commaLine = nil
            case UInt8(ascii: ","):
                commaLine = line
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                if let commaLine { return commaLine }
            case 32, 9, 10, 13:
                break
            default:
                commaLine = nil
            }
        }
        return nil
    }

    /// A node that only points at another one, as in {"@id": "#organization"}.
    private static func isReference(_ node: [String: Any]) -> Bool {
        node.keys.allSatisfy { $0 == "@id" }
    }

    private static func has(_ node: [String: Any], _ key: String) -> Bool {
        guard let value = node[key] else { return false }
        if value is NSNull { return false }
        if let text = value as? String { return !text.trimmingCharacters(in: .whitespaces).isEmpty }
        if let list = value as? [Any] { return !list.isEmpty }
        return true
    }
}

extension SchemaItem {
    fileprivate func adding(required more: [String]) -> SchemaItem {
        SchemaItem(id: id, types: types, role: role, fields: fields, required: more + required, recommended: recommended, notes: notes,
                   richResult: richResult, children: children)
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
