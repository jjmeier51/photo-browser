import Foundation

/// "Surprise Me" for Edit / Create with AI: a random photo-shoot prompt of a woman posing — a look,
/// a setting, a pose, light and a camera, drawn from the banks below and written out in the voice
/// each model answers best. Two moods: **alluring** (dressed, editorial, magnetic rather than
/// revealing) and **sexy** — whose wardrobe depends on the model: Nano Banana (Gemini) refuses
/// underwear and see-through, so there it stays **clothed** (tight workout sets, bodycon, swimwear,
/// tight jeans, wedding dresses, sundresses, pyjamas); Seedream also draws the **intimate** tier
/// (bra-and-brief sets, thongs, slips, lace, sheer layers). Glamour-shoot wardrobe only — no
/// nudity or sexual acts — and Astria's own moderation still applies. The banks combine into far more
/// than hundreds of distinct prompts, and ~60 hand-written "signature" scenes are mixed in for shots
/// a recipe wouldn't produce. The user's references, size and aspect are untouched — the prompt
/// just lands in the field (and is sent) exactly as a typed one would be.
///
/// The banks below are the **built-in** set. With a drive open they are written once to
/// `Surprise Prompts.json` at the drive root, and from then on that file is the bank the user edits
/// (`Bank`, `load(root:)`); the built-in lists only fill whatever the file leaves empty.
///
/// Model voices: **Nano Banana 2 / 2.1** want one flowing, concrete paragraph (a scene described,
/// not a keyword list, with the camera and light stated in sentences); **Seedream 5.0 Pro** does
/// best subject-first in short labelled sentences with explicit style words. Edit prompts keep the
/// woman in the photo and restyle everything around her; Create prompts with references point at
/// "the woman in the reference images" (the FaceID mentions are prepended by `AIExtend`).
nonisolated enum SurprisePrompts {
    enum Mood: String, CaseIterable, Identifiable, Sendable {
        case any = "Any", alluring = "Alluring", sexy = "Sexy"
        var id: String { rawValue }
    }
    enum Flow: Sendable { case create, edit }
    enum Heat: String, Codable, Sendable { case alluring, sexy }
    /// What a model will accept. Nano Banana (Gemini) refuses underwear / lingerie / see-through, so
    /// its sexy looks stay **clothed** (tight workout sets, bodycon, swimwear, tight jeans, pyjamas…);
    /// Seedream also takes the **intimate** tier (bra-and-brief sets, thongs, slips, sheer layers).
    enum Tier: String, Codable, Sendable { case clothed, intimate }

    // MARK: - The bank: built in, or the drive's "Surprise Prompts.json"

    /// Every list a prompt is drawn from. `Bank.builtIn` is the one compiled into the app; the drive's
    /// file (`fileName` at the drive root) holds exactly the same shape, so the user can edit, add to
    /// or trim it in any text editor. A list left empty in the file falls back to the built-in list
    /// (`filled()`), so a file holding only `signatures` still works. Decoding is lenient: a missing
    /// key is an empty list, a missing `heat` is alluring, a missing `tier` is clothed.
    nonisolated struct Bank: Codable, Sendable {
        var subjects: [String] = []
        var looks: [Look] = []
        var settings: [Setting] = []
        var poses: [Pose] = []
        var lights: [String] = []
        var cameras: [String] = []
        var finishes: [String] = []
        var hair: [String] = []
        var signatures: [Signature] = []

        init() {}
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            subjects = try c.decodeIfPresent([String].self, forKey: .subjects) ?? []
            looks = try c.decodeIfPresent([Look].self, forKey: .looks) ?? []
            settings = try c.decodeIfPresent([Setting].self, forKey: .settings) ?? []
            poses = try c.decodeIfPresent([Pose].self, forKey: .poses) ?? []
            lights = try c.decodeIfPresent([String].self, forKey: .lights) ?? []
            cameras = try c.decodeIfPresent([String].self, forKey: .cameras) ?? []
            finishes = try c.decodeIfPresent([String].self, forKey: .finishes) ?? []
            hair = try c.decodeIfPresent([String].self, forKey: .hair) ?? []
            signatures = try c.decodeIfPresent([Signature].self, forKey: .signatures) ?? []
        }

        static let builtIn: Bank = {
            var b = Bank()
            b.subjects = SurprisePrompts.subjects
            b.looks = SurprisePrompts.looks
            b.settings = SurprisePrompts.settings
            b.poses = SurprisePrompts.poses
            b.lights = SurprisePrompts.lights
            b.cameras = SurprisePrompts.cameras
            b.finishes = SurprisePrompts.finishes
            b.hair = SurprisePrompts.hairNotes
            b.signatures = SurprisePrompts.signatures
            return b
        }()

        var isEmpty: Bool {
            subjects.isEmpty && looks.isEmpty && settings.isEmpty && poses.isEmpty && lights.isEmpty
                && cameras.isEmpty && finishes.isEmpty && hair.isEmpty && signatures.isEmpty
        }
        /// This bank with every empty list taken from the built-in one.
        func filled() -> Bank {
            var b = self
            let d = Bank.builtIn
            if b.subjects.isEmpty { b.subjects = d.subjects }
            if b.looks.isEmpty { b.looks = d.looks }
            if b.settings.isEmpty { b.settings = d.settings }
            if b.poses.isEmpty { b.poses = d.poses }
            if b.lights.isEmpty { b.lights = d.lights }
            if b.cameras.isEmpty { b.cameras = d.cameras }
            if b.finishes.isEmpty { b.finishes = d.finishes }
            if b.hair.isEmpty { b.hair = d.hair }
            if b.signatures.isEmpty { b.signatures = d.signatures }
            return b
        }
    }

    /// The prompt file at the top of the drive. Hidden from the grid like the gallery sidecars
    /// (`GalleryCategories.sidecarNames`).
    static let fileName = "Surprise Prompts.json"
    static func driveFile(root: URL) -> URL { root.appendingPathComponent(fileName) }

    nonisolated struct Loaded: Sendable {
        let bank: Bank
        let note: String?          // why the drive's file isn't in use, for the screen's footer
        let fromDrive: Bool
    }

    /// The bank to draw from: the drive's file when a drive is open (written with the built-in bank the
    /// first time, so there is always a complete file to edit), else the built-in. Blocking file I/O —
    /// call off the main actor. Cached by the file's size and modification date, so a tap only
    /// re-reads after the file changed.
    static func load(root: URL?) -> Loaded {
        guard let root else { return Loaded(bank: .builtIn, note: nil, fromDrive: false) }
        let file = driveFile(root: root)
        let fm = FileManager.default
        guard fm.fileExists(atPath: file.path) else {
            do {
                let enc = JSONEncoder()
                enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
                try DriveWriter.writeDataSync(try enc.encode(Bank.builtIn), to: file)
                return Loaded(bank: .builtIn, note: nil, fromDrive: true)
            } catch {
                return Loaded(bank: .builtIn, note: "“\(fileName)” couldn't be written to the drive (\(error.localizedDescription)). Using the built-in prompts.", fromDrive: false)
            }
        }
        let attrs = try? fm.attributesOfItem(atPath: file.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let modified = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let stamp = "\(size)|\(modified)"
        if let cached = cache.get(path: file.path, stamp: stamp) { return cached }
        let loaded: Loaded
        do {
            let bank = try JSONDecoder().decode(Bank.self, from: try Data(contentsOf: file))
            loaded = bank.isEmpty
                ? Loaded(bank: .builtIn, note: "“\(fileName)” on the drive has no prompts in it. Using the built-in prompts.", fromDrive: false)
                : Loaded(bank: bank.filled(), note: nil, fromDrive: true)
        } catch {
            loaded = Loaded(bank: .builtIn, note: "“\(fileName)” on the drive couldn't be read — \(describe(error)). Using the built-in prompts until it's fixed.", fromDrive: false)
        }
        cache.set(path: file.path, stamp: stamp, loaded)
        return loaded
    }

    private static func describe(_ error: Error) -> String {
        if let e = error as? DecodingError {
            switch e {
            case .dataCorrupted(let ctx): return "not valid JSON (\(ctx.debugDescription))"
            case .keyNotFound(let key, _): return "an entry is missing “\(key.stringValue)”"
            case .typeMismatch(_, let ctx), .valueNotFound(_, let ctx):
                return "an entry has the wrong shape (\(ctx.debugDescription))"
            @unknown default: return "\(e)"
            }
        }
        return error.localizedDescription
    }

    private nonisolated final class LoadCache: @unchecked Sendable {
        private let lock = NSLock()
        private var path = "", stamp = ""
        private var loaded: Loaded?
        func get(path p: String, stamp s: String) -> Loaded? {
            lock.lock(); defer { lock.unlock() }
            return (p == path && s == stamp) ? loaded : nil
        }
        func set(path p: String, stamp s: String, _ l: Loaded) {
            lock.lock(); defer { lock.unlock() }
            path = p; stamp = s; loaded = l
        }
    }
    private static let cache = LoadCache()

    // MARK: - Public

    /// One random prompt from `bank`. `references` is how many reference images the user picked
    /// (Create only).
    static func random(mood: Mood, flow: Flow, model: AIExtend.AIModel, references: Int,
                       bank: Bank = .builtIn) -> String {
        var g = SystemRandomNumberGenerator()
        return random(mood: mood, flow: flow, model: model, references: references, bank: bank, using: &g)
    }

    static func random<G: RandomNumberGenerator>(mood: Mood, flow: Flow, model: AIExtend.AIModel,
                                                 references: Int, bank: Bank = .builtIn, using g: inout G) -> String {
        let bank = bank.filled()
        let heat: Heat = mood == .any ? (Bool.random(using: &g) ? .alluring : .sexy)
                                      : (mood == .sexy ? .sexy : .alluring)
        let subject = subjectPhrase(flow: flow, references: references, bank: bank, using: &g)
        let intimateOK = allowsIntimate(model)
        // One in four draws is a hand-written scene; the rest are composed from the banks.
        if Int.random(in: 0..<4, using: &g) == 0,
           let sig = bank.signatures.filter({ $0.heat == heat && (intimateOK || $0.tier == .clothed) }).randomElement(using: &g) {
            return finish(scene: sig.text.replacingOccurrences(of: "{subject}", with: subject),
                          flow: flow, model: model, composed: false)
        }
        // A user's list can have nothing for this mood and model (say, only intimate looks on Nano
        // Banana); the built-in list then fills that slot rather than failing.
        let look = bank.looks.filter { $0.heat == heat && (intimateOK || $0.tier == .clothed) }.randomElement(using: &g)
            ?? Bank.builtIn.looks.filter { $0.heat == heat && (intimateOK || $0.tier == .clothed) }.randomElement(using: &g)!
        let setting = bank.settings.randomElement(using: &g)!
        let pose = bank.poses.filter { $0.heat == heat || $0.heat == .alluring }.randomElement(using: &g)
            ?? Bank.builtIn.poses.filter { $0.heat == heat || $0.heat == .alluring }.randomElement(using: &g)!
        let light = bank.lights.randomElement(using: &g)!
        let camera = bank.cameras.randomElement(using: &g)!
        let finishNote = bank.finishes.randomElement(using: &g)!
        let hair = Bool.random(using: &g) ? bank.hair.randomElement(using: &g) : nil

        let scene: String
        switch voice(for: model) {
        case .nanoBanana:
            // A single described moment: who, wearing what, where, doing what, lit how, shot how.
            scene = "\(cap(subject)), \(look.text)\(hair.map { ", \($0)" } ?? ""). \(cap(setting.text)). \(cap(pose.text)). \(cap(light)). \(cap(camera)). \(cap(finishNote))."
        case .seedream:
            scene = "Subject: \(subject)\(hair.map { ", \($0)" } ?? ""). Outfit: \(look.text). Scene: \(setting.text). Pose: \(pose.text). Lighting: \(light). Camera: \(camera). Style: \(finishNote)."
        }
        return finish(scene: scene, flow: flow, model: model, composed: true)
    }

    // MARK: - Assembly

    /// Nano Banana (Gemini) refuses lingerie / underwear / see-through; Seedream and Flux take it.
    static func allowsIntimate(_ model: AIExtend.AIModel) -> Bool { voice(for: model) == .seedream }

    private enum Voice { case nanoBanana, seedream }
    private static func voice(for model: AIExtend.AIModel) -> Voice {
        switch model {
        case .nanoBanana21, .nanoBanana2: return .nanoBanana
        case .seedream5Pro, .seedream5Lite, .seedream45, .flux: return .seedream
        }
    }

    private static func subjectPhrase<G: RandomNumberGenerator>(flow: Flow, references: Int, bank: Bank, using g: inout G) -> String {
        switch flow {
        case .edit:
            return "the same woman as in this photo, her face, features, hair and body kept exactly as they are"
        case .create:
            if references > 0 {
                return references == 1
                    ? "the woman from the reference image, her face and features exactly as shown"
                    : "the woman from the reference images, her face and features exactly as shown"
            }
            return bank.subjects.randomElement(using: &g) ?? Bank.builtIn.subjects.randomElement(using: &g)!
        }
    }

    private static func finish(scene: String, flow: Flow, model: AIExtend.AIModel, composed: Bool) -> String {
        let lead: String
        switch (flow, voice(for: model)) {
        case (.edit, .nanoBanana):
            lead = "Edit this photo into a new shot of the same woman — keep her identity exactly (face, features, hair colour, skin, body) and change everything else as described: "
        case (.edit, .seedream):
            lead = "Photo edit, same person. Keep the woman's identity exactly as in the input image (face, features, hair colour, skin, body); restyle the outfit, scene, pose and light as follows. "
        case (.create, .nanoBanana):
            lead = "A photorealistic photograph. "
        case (.create, .seedream):
            lead = "Photorealistic photograph. "
        }
        let tail = voice(for: model) == .nanoBanana
            ? " Real skin texture with pores and fine detail, no beauty-filter smoothing, natural sensor grain, a slightly imperfect handheld feel. No text, logos or watermarks."
            : " Ultra-detailed, true-to-life skin texture (pores, fine lines, no retouching plastic), subtle film grain, natural colour. No text, logos or watermarks."
        return lead + scene + tail
    }

    private static func cap(_ s: String) -> String {
        guard let f = s.first else { return s }
        return f.uppercased() + s.dropFirst()
    }

    // MARK: - Banks

    /// The entry shapes, as they appear in the JSON file: `{"heat","tier","text"}`, `{"text"}`,
    /// `{"heat","text"}`. Decoding tolerates a missing `heat` (alluring) and `tier` (clothed).
    nonisolated struct Look: Codable, Sendable {
        let heat: Heat; var tier: Tier; let text: String
        init(heat: Heat, tier: Tier = .clothed, text: String) { self.heat = heat; self.tier = tier; self.text = text }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            heat = try c.decodeIfPresent(Heat.self, forKey: .heat) ?? .alluring
            tier = try c.decodeIfPresent(Tier.self, forKey: .tier) ?? .clothed
            text = try c.decode(String.self, forKey: .text)
        }
    }
    nonisolated struct Setting: Codable, Sendable {
        let text: String
        init(text: String) { self.text = text }
    }
    nonisolated struct Pose: Codable, Sendable {
        let heat: Heat; let text: String
        init(heat: Heat, text: String) { self.heat = heat; self.text = text }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            heat = try c.decodeIfPresent(Heat.self, forKey: .heat) ?? .alluring
            text = try c.decode(String.self, forKey: .text)
        }
    }
    nonisolated struct Signature: Codable, Sendable {
        let heat: Heat; var tier: Tier; let text: String
        init(heat: Heat, tier: Tier = .clothed, text: String) { self.heat = heat; self.tier = tier; self.text = text }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            heat = try c.decodeIfPresent(Heat.self, forKey: .heat) ?? .alluring
            tier = try c.decodeIfPresent(Tier.self, forKey: .tier) ?? .clothed
            text = try c.decode(String.self, forKey: .text)
        }
    }

    /// Who she is when there's no reference to copy (Create only).
    private static let subjects: [String] = [
        "a woman in her late twenties with long dark wavy hair and olive skin",
        "a tall woman in her early thirties with a sharp blonde bob and freckles",
        "a woman in her mid-twenties with natural curly black hair and deep brown skin",
        "a woman around thirty with auburn hair in loose waves and pale skin",
        "an East Asian woman in her late twenties with sleek shoulder-length black hair",
        "a South Asian woman in her thirties with long thick black hair and warm brown skin",
        "a Latina woman in her mid-twenties with dark brown hair pulled into a low bun",
        "a woman in her thirties with a platinum pixie cut and strong cheekbones",
        "a curvy woman in her late twenties with honey-blonde beach waves",
        "a petite woman in her twenties with a jet-black blunt fringe and porcelain skin",
        "an athletic woman in her thirties with light brown hair in a high ponytail",
        "a woman in her forties with silver-streaked dark hair and an easy confident face",
        "a Black woman in her early thirties with a close-cropped natural cut and gold hoops",
        "a Middle Eastern woman in her late twenties with long glossy dark hair and strong brows",
        "a redhead in her mid-twenties with shoulder-length waves and a dusting of freckles",
        "a mixed-race woman in her thirties with chestnut curls and a wide bright smile",
        "a Scandinavian woman in her twenties with ash-blonde hair and grey-blue eyes",
        "a woman around thirty-five with a dark glossy lob and a slow knowing smile",
        "a woman in her late twenties with box braids gathered over one shoulder",
        "a tall woman in her early thirties with wavy caramel hair and sun-kissed skin",
        "a woman in her twenties with a sleek dark ponytail and dramatic winged liner",
        "a woman in her thirties with soft brown curls and a gap-toothed grin",
        "an Afro-Latina woman in her late twenties with voluminous dark curls",
        "a woman in her early thirties with a copper-red shag cut and green eyes",
        "a woman in her mid-thirties with long straight black hair and a serene face",
        "a woman in her twenties with a honey-brown balayage and a small nose stud",
        "a woman around thirty with a dark bob tucked behind one ear and bare, glowing skin",
        "a woman in her late twenties with strawberry-blonde hair in a loose plait",
        "a woman in her thirties with dark hair slicked back wet-look and a bold red lip",
        "a woman in her early thirties with a soft brunette shag and minimal makeup",
        // Added from the prompt-bank additions file (Oct 2026)
        "a woman in her early twenties with a bleach-blonde bob and freckled pale skin, slender and athletic",
        "a woman in her late thirties with a jet-black blunt fringe and olive skin, tall with strong shoulders",
        "a woman in her mid forties with silver-streaked chestnut curls and warm brown skin, soft and curvy",
        "a woman in her mid twenties with waist-length box braids and deep ebony skin, lean and long-limbed",
        "a woman in her late twenties with a dark messy bun and honey-toned skin, compact dancer's build",
        "a woman in her fifties with a sharp grey pixie cut and freckled porcelain skin, elegant and slim",
        "a woman in her thirties with wet-look auburn waves and sun-tanned skin, full-figured hourglass",
        "a woman in her early forties with long raven hair and golden-brown skin, sculpted and statuesque",
        "a woman in her mid thirties with platinum pin curls and pale skin, tattooed and soft-bellied",
        "a woman in her twenties with short curly black hair and cool dark skin, small-busted and compact",
        "a woman in her late forties with a long grey braid and weathered olive skin, rangy and strong",
        "a woman in her thirties with strawberry-blonde waves and freckled shoulders, pear-shaped and soft",
        "a woman in her twenties with a blunt black chin-length bob and porcelain skin, tall and willowy",
        "a woman in her sixties with a white updo and lined mahogany skin, graceful and slender",
    ]

    /// Outfit and styling. Alluring = dressed and editorial; sexy = glamour-shoot revealing.
    private static let looks: [Look] = [
        // Alluring
        .init(heat: .alluring, text: "wearing an oversized ivory cashmere sweater that slips off one shoulder, bare legs, no jewellery"),
        .init(heat: .alluring, text: "in a tailored black tuxedo jacket with nothing but a thin gold chain visible at the neckline and wide-leg trousers"),
        .init(heat: .alluring, text: "wearing a bias-cut emerald silk midi dress with thin straps and strappy heels"),
        .init(heat: .alluring, text: "in a crisp white oversized men's shirt, sleeves rolled, tucked into high-waisted vintage jeans"),
        .init(heat: .alluring, text: "wearing a camel wool trench coat belted at the waist over a black turtleneck, knee boots"),
        .init(heat: .alluring, text: "in a slinky champagne satin slip dress under a chunky charcoal cardigan"),
        .init(heat: .alluring, text: "wearing a red off-the-shoulder knit dress that hugs her shape, hair down"),
        .init(heat: .alluring, text: "in a black leather biker jacket over a white ribbed tank and faded denim"),
        .init(heat: .alluring, text: "wearing a floral chiffon maxi dress with a deep V neckline and a wide-brim straw hat"),
        .init(heat: .alluring, text: "in a fitted ribbed cream knit co-ord — long skirt and cropped sweater — and gold hoops"),
        .init(heat: .alluring, text: "wearing a structured navy blazer dress with a cinched waist and pointed pumps"),
        .init(heat: .alluring, tier: .intimate, text: "in a sheer black blouse over a simple black bralette, high-waisted cigarette trousers"),
        .init(heat: .alluring, text: "wearing a soft grey linen jumpsuit, belted, sleeves pushed up, barefoot"),
        .init(heat: .alluring, text: "in a vintage band tee knotted at the waist with leather trousers and combat boots"),
        .init(heat: .alluring, text: "wearing a backless black evening gown with a draped cowl at the spine"),
        .init(heat: .alluring, text: "in a cropped white tennis dress with a pleated skirt and a visor pushed into her hair"),
        .init(heat: .alluring, text: "wearing a cosy oatmeal cable-knit sweater and tiny shorts, thick socks"),
        .init(heat: .alluring, text: "in a dusty-pink silk blouse half-unbuttoned, tucked into a pencil skirt"),
        .init(heat: .alluring, text: "wearing a fitted black turtleneck, a mini skirt and sheer black tights"),
        .init(heat: .alluring, text: "in a loose white cotton sundress with thin straps, hair windswept"),
        .init(heat: .alluring, text: "wearing a bronze sequinned cocktail dress that catches every light"),
        .init(heat: .alluring, text: "in black yoga leggings and a matching sports bra under an open hoodie"),
        .init(heat: .alluring, tier: .intimate, text: "wearing a pinstripe waistcoat with nothing underneath and matching trousers, hair pinned up"),
        .init(heat: .alluring, text: "in a lilac tulle midi skirt with a plain white bodysuit"),
        .init(heat: .alluring, text: "wearing a cream silk pyjama set, top loosely buttoned, hair tousled"),
        .init(heat: .alluring, text: "in a form-fitting burgundy velvet dress with long sleeves and a thigh-high slit"),
        .init(heat: .alluring, text: "wearing a denim jacket over a black slip dress and white sneakers"),
        .init(heat: .alluring, text: "in a sage-green wrap dress tied at the hip, espadrille wedges"),
        .init(heat: .alluring, text: "wearing a black halter-neck jumpsuit with a plunging front and a thin gold belt"),
        .init(heat: .alluring, tier: .intimate, text: "in a white ribbed tank, no bra, and loose grey sweatpants, hair in a messy bun"),
        .init(heat: .alluring, text: "wearing a fur-collared black coat open over a simple black dress"),
        .init(heat: .alluring, text: "in a corseted floral cotton dress with puff sleeves, cottagecore"),
        .init(heat: .alluring, text: "wearing a long camel knit dress with a side slit and a wide leather belt"),
        .init(heat: .alluring, text: "in a cropped leather jacket over a lace-trimmed camisole and a satin midi skirt"),
        .init(heat: .alluring, text: "wearing a black one-shoulder cocktail dress with a single statement earring"),
        .init(heat: .alluring, text: "in a slouchy beige trench worn as a dress, cinched, bare legs, pointed mules"),
        .init(heat: .alluring, text: "wearing a crisp pale-blue shirt dress, top buttons undone, sleeves rolled"),
        .init(heat: .alluring, text: "in a fitted houndstooth skirt suit with a cropped jacket, retro sixties"),
        .init(heat: .alluring, text: "wearing an oversized vintage denim shirt, bare legs, cowboy boots"),
        .init(heat: .alluring, tier: .intimate, text: "in a sheer polka-dot blouse over a nude slip, pleated trousers"),
        .init(heat: .alluring, text: "wearing a gold lamé column gown with a high neck and open back"),
        .init(heat: .alluring, text: "in a cropped cream cardigan buttoned low and a flowing floral skirt"),
        .init(heat: .alluring, text: "wearing a black turtleneck bodysuit and high-waisted wide-leg white trousers"),
        .init(heat: .alluring, text: "in a slip dress in liquid silver with a cropped faux-fur jacket"),
        .init(heat: .alluring, text: "wearing a soft pink mohair sweater that falls off one shoulder, bare legs"),
        .init(heat: .alluring, text: "in a tailored khaki safari shirt dress, belted, sleeves rolled"),
        .init(heat: .alluring, text: "wearing a strapless black satin column dress with elbow-length gloves"),
        .init(heat: .alluring, text: "in a loose linen shirt tied at the waist over a black bikini top and linen trousers"),
        .init(heat: .alluring, text: "wearing a dark green silk blouse tucked into tan leather trousers"),
        .init(heat: .alluring, text: "in a 1950s-style polka-dot halter dress with a full skirt and red lips"),
        .init(heat: .alluring, text: "wearing an open-knit crochet dress over a nude slip, beachy"),
        .init(heat: .alluring, text: "in a slim black pantsuit with a lace camisole under the jacket"),
        .init(heat: .alluring, text: "wearing a white tank top and low-rise cargo trousers, Y2K"),
        .init(heat: .alluring, text: "in a cropped grey sweatshirt and bike shorts, fresh from a run"),
        .init(heat: .alluring, text: "wearing a red silk scarf top tied at the back and high-waisted black trousers"),
        .init(heat: .alluring, text: "in a long sheer-sleeved black lace dress with a modest neckline"),
        .init(heat: .alluring, text: "wearing a boxy men's overcoat over a slip dress and sneakers"),
        .init(heat: .alluring, text: "in an ivory bridal-style satin gown with a draped neckline, no veil"),
        .init(heat: .alluring, text: "wearing a chocolate-brown leather midi skirt and a thin ribbed knit"),
        .init(heat: .alluring, text: "in a sheer white embroidered kaftan over a swimsuit, beach-club"),
        // Sexy
        .init(heat: .sexy, text: "in a black string bikini, wet hair slicked back, droplets on her skin"),
        .init(heat: .sexy, text: "wearing a plunging red one-piece swimsuit cut high on the hip"),
        .init(heat: .sexy, tier: .intimate, text: "in a lace-trimmed black satin slip, one strap fallen off her shoulder"),
        .init(heat: .sexy, tier: .intimate, text: "wearing a sheer black lace bodysuit under an open oversized blazer, bare legs"),
        .init(heat: .sexy, text: "in a white crochet bikini and a sheer sarong knotted low on the hip"),
        .init(heat: .sexy, text: "wearing a boned black corset top with low-rise leather trousers"),
        .init(heat: .sexy, text: "in a tiny ivory silk cami and matching shorts, hair messy, bare feet"),
        .init(heat: .sexy, text: "wearing a bronze metallic bikini with gold body chains"),
        .init(heat: .sexy, text: "in a backless black mini dress cut down to the base of the spine, heels"),
        .init(heat: .sexy, text: "wearing a cropped white shirt knotted under the bust and high-cut bikini bottoms"),
        .init(heat: .sexy, text: "in a nude-toned strapless bodycon dress that fits like a second skin"),
        .init(heat: .sexy, tier: .intimate, text: "wearing a wet white tank top that clings, and black bikini bottoms"),
        .init(heat: .sexy, tier: .intimate, text: "in a red lace bralette and a sheer black chiffon robe slipping off her shoulders"),
        .init(heat: .sexy, tier: .intimate, text: "wearing an oversized men's white shirt unbuttoned to the navel and nothing else visible, bare legs"),
        .init(heat: .sexy, text: "in a leopard-print bikini and oversized sunglasses"),
        .init(heat: .sexy, text: "wearing a black velvet mini dress with a corseted bodice and a high slit"),
        .init(heat: .sexy, text: "in a cut-out black swimsuit with side straps and a gold chain belt"),
        .init(heat: .sexy, tier: .intimate, text: "wearing a cropped grey hoodie and black lace underwear, bare legs, thigh-high socks"),
        .init(heat: .sexy, tier: .intimate, text: "in a glossy black latex-look mini skirt and a sheer mesh top over a black bralette"),
        .init(heat: .sexy, tier: .intimate, text: "wearing a champagne silk slip dress cut on the bias with a thigh-high slit, no bra"),
        .init(heat: .sexy, tier: .intimate, text: "in a pale pink lace lingerie set under an unbuttoned pastel cardigan"),
        .init(heat: .sexy, text: "wearing a halter-neck emerald bikini and a stack of thin gold bangles"),
        .init(heat: .sexy, tier: .intimate, text: "in a sheer black mesh maxi dress over a black bandeau and high-waist briefs"),
        .init(heat: .sexy, text: "wearing a micro mini denim skirt and a tied-up gingham crop top"),
        .init(heat: .sexy, text: "in a white one-piece swimsuit with a plunging neckline and cut-out waist"),
        .init(heat: .sexy, text: "wearing a strappy black bodysuit with a deep V and sheer stockings"),
        .init(heat: .sexy, tier: .intimate, text: "in a silk kimono robe open over a matching lace bralette and shorts"),
        .init(heat: .sexy, text: "wearing a crystal-mesh mini dress over a nude bodysuit, party-ready"),
        .init(heat: .sexy, text: "in a red string bikini top and loose unbuttoned denim cut-offs"),
        .init(heat: .sexy, tier: .intimate, text: "wearing a lace-up black mini dress with a corset back, bare shoulders"),
        .init(heat: .sexy, tier: .intimate, text: "in a knit bralette and a long sheer skirt that shows the bikini beneath"),
        .init(heat: .sexy, tier: .intimate, text: "wearing a sheer white sundress backlit so her silhouette shows through"),
        .init(heat: .sexy, text: "in a black bandeau bikini with a sheer long-sleeved mesh cover-up"),
        .init(heat: .sexy, text: "wearing an oversized sports jersey as a dress, bare legs, sneakers"),
        .init(heat: .sexy, text: "in a satin corset mini dress in deep plum with a sweetheart neckline"),
        .init(heat: .sexy, text: "wearing a cropped leather jacket over a black bikini top and cut-offs"),
        .init(heat: .sexy, text: "in a tiny ribbed white tank and striped cotton pyjama shorts, bed-head hair"),
        .init(heat: .sexy, text: "wearing a cowl-neck metallic halter dress with a bare back, heels"),
        .init(heat: .sexy, text: "in a monokini with a deep front cut and a wide-brim black hat"),
        .init(heat: .sexy, text: "wearing a cropped cashmere cardigan buttoned once and matching mini shorts"),
        .init(heat: .sexy, tier: .intimate, text: "in a sheer black blouse worn open over a black bra and a leather pencil skirt"),
        .init(heat: .sexy, tier: .intimate, text: "wearing a wet-look black one-piece and dripping hair, just out of the pool"),
        .init(heat: .sexy, text: "in a red bodycon midi dress with a square neckline and strappy sandals"),
        .init(heat: .sexy, text: "wearing a gold chainmail halter top and black trousers"),
        .init(heat: .sexy, tier: .intimate, text: "in a white lace bralette and high-waisted linen trousers, open blouse over the top"),
        .init(heat: .sexy, text: "wearing a cheeky-cut tangerine bikini and a towel over one shoulder"),
        .init(heat: .sexy, tier: .intimate, text: "in a black slip dress with lace trim, sheer at the hem, barefoot"),
        .init(heat: .sexy, tier: .intimate, text: "wearing a cropped turtleneck sweater and lace briefs, long bare legs"),
        .init(heat: .sexy, text: "in a sheer sequin mini dress over a nude slip, nightclub"),
        .init(heat: .sexy, text: "wearing a bikini top under a sheer, soaked white shirt, hair dripping"),
        .init(heat: .sexy, text: "in a satin bustier and high-waisted wide trousers, red lipstick"),
        .init(heat: .sexy, text: "wearing a backless halter mini dress in liquid black satin"),
        .init(heat: .sexy, text: "in a cropped pink mohair sweater, a mini skirt and knee-high boots"),
        .init(heat: .sexy, text: "wearing a plunging black swimsuit with a sheer black sarong"),
        .init(heat: .sexy, tier: .intimate, text: "in a lace bodysuit under an oversized unbuttoned flannel shirt"),
        .init(heat: .sexy, text: "wearing a bandage-style white mini dress with a cut-out midriff"),
        .init(heat: .sexy, tier: .intimate, text: "in a cherry-red lingerie set under a sheer black mesh dress"),
        .init(heat: .sexy, text: "wearing a strapless gold bikini and a sheer white beach shirt"),
        .init(heat: .sexy, tier: .intimate, text: "in a black mini dress with a lace-up front and a deep V"),
        .init(heat: .sexy, tier: .intimate, text: "wearing a thin ribbed cami, no bra, and low-slung silk pyjama trousers"),
        // Sexy, clothed (what Nano Banana will accept)
        .init(heat: .sexy, text: "in a matching black seamless workout set — high-waisted leggings and a scoop sports bra — that shows every line"),
        .init(heat: .sexy, text: "wearing a tight white ribbed crop top and skin-tight light-wash jeans, belly bare"),
        .init(heat: .sexy, text: "in a fitted satin wedding dress with a plunging back and a long train, veil off"),
        .init(heat: .sexy, text: "wearing a thin-strapped cotton sundress that clings in the breeze, no shoes"),
        .init(heat: .sexy, text: "in a cropped grey tank and tiny pink running shorts, ponytail swinging"),
        .init(heat: .sexy, text: "wearing a skin-tight black mock-neck bodycon dress to mid-thigh and heels"),
        .init(heat: .sexy, text: "in a short silk pyjama set, shirt tied at the waist, bare legs"),
        .init(heat: .sexy, text: "wearing tight black leather trousers and a cropped white tank, barefoot"),
        .init(heat: .sexy, text: "in an off-the-shoulder lace-trimmed wedding gown with a corseted bodice, hair up"),
        .init(heat: .sexy, text: "wearing a cropped lilac workout top and matching bike shorts, glowing after a run"),
        .init(heat: .sexy, text: "in a tight denim mini skirt and a tied white blouse showing her midriff"),
        .init(heat: .sexy, text: "wearing an oversized men's pyjama shirt as a dress, top buttons undone, bare legs"),
        .init(heat: .sexy, text: "in a backless ivory slip-style wedding dress, bias cut, pearl earrings"),
        .init(heat: .sexy, text: "wearing a cropped tennis polo and a very short pleated skirt, white sneakers"),
        .init(heat: .sexy, text: "in a tight red bodycon midi dress with cut-out sides"),
        .init(heat: .sexy, text: "wearing a sleeveless ribbed knit mini dress that hugs every curve"),
        .init(heat: .sexy, text: "in a cropped yoga top and high-waisted flared leggings, mid-stretch"),
        .init(heat: .sexy, text: "wearing skin-tight dark jeans and a tiny black halter top, heels"),
        .init(heat: .sexy, text: "in a short satin nightdress-style sundress in pale blue, straps thin"),
        .init(heat: .sexy, text: "wearing a cropped hoodie and tight bike shorts, socks pulled up"),
        .init(heat: .sexy, text: "in a long-sleeved black bodycon gown with a leg slit to the hip"),
        .init(heat: .sexy, text: "wearing a white tank top tucked into tight cut-off denim shorts, cowboy boots"),
        .init(heat: .sexy, text: "in a satin wrap mini dress in emerald that slips off one shoulder"),
        .init(heat: .sexy, text: "wearing flannel pyjama bottoms and a tight white baby tee, hair messy"),
        .init(heat: .sexy, text: "in a strapless tight cream bandage dress to the knee"),
        // Sexy, intimate (Seedream only)
        .init(heat: .sexy, tier: .intimate, text: "in a matching black lace bra and thong set, nothing else, bare feet"),
        .init(heat: .sexy, tier: .intimate, text: "wearing a white cotton bralette and high-cut white briefs, an open cardigan"),
        .init(heat: .sexy, tier: .intimate, text: "in a red satin bra and matching briefs with a thin garter belt and sheer stockings"),
        .init(heat: .sexy, tier: .intimate, text: "wearing a sheer black lace teddy, one strap fallen"),
        .init(heat: .sexy, tier: .intimate, text: "in a pale pink babydoll nightie with lace trim and matching briefs"),
        .init(heat: .sexy, tier: .intimate, text: "wearing a black thong and a cropped white tank, seen from behind"),
        .init(heat: .sexy, tier: .intimate, text: "in a sheer burgundy lace bodysuit with a plunging neckline"),
        .init(heat: .sexy, tier: .intimate, text: "wearing a nude mesh bra and briefs set, barely there"),
        .init(heat: .sexy, tier: .intimate, text: "in an emerald silk bra and tap shorts, a loose robe sliding off"),
        .init(heat: .sexy, tier: .intimate, text: "wearing a black satin push-up bra under a sheer white blouse, tight jeans"),
        .init(heat: .sexy, tier: .intimate, text: "in a lace-up black corset with matching briefs and sheer thigh-highs"),
        .init(heat: .sexy, tier: .intimate, text: "wearing a strappy black bra and thong under an open oversized shirt"),
        .init(heat: .sexy, tier: .intimate, text: "in a white lace bridal bra and briefs set with a sheer robe, wedding morning"),
        .init(heat: .sexy, tier: .intimate, text: "wearing a cheeky cotton underwear set and knee socks, sleepy"),
        .init(heat: .sexy, tier: .intimate, text: "in a sheer black mesh bodysuit with a bra beneath, heels"),
        // Added from the prompt-bank additions file (Oct 2026)
        .init(heat: .alluring, text: "in a black wool turtleneck, wide charcoal trousers and gold hoops"),
        .init(heat: .alluring, text: "in a cream silk shirt buttoned to the throat, tucked into high-waist navy trousers"),
        .init(heat: .alluring, text: "wearing a camel double-breasted coat over a burgundy slip of a dress"),
        .init(heat: .alluring, text: "in a knitted oatmeal cardigan and pleated midi skirt with brogues"),
        .init(heat: .alluring, text: "in a boxy tweed blazer, dark denim and loafers, hair tucked behind one ear"),
        .init(heat: .alluring, text: "wearing a rust corduroy pinafore over a striped cotton tee"),
        .init(heat: .alluring, text: "in a navy silk blouse and grey pencil skirt with a thin leather belt"),
        .init(heat: .alluring, text: "wearing a long olive trench, belted, over knee-high boots"),
        .init(heat: .alluring, text: "in a white broderie-anglaise sundress and woven straw wedges"),
        .init(heat: .alluring, text: "wearing a charcoal turtleneck dress, opaque tights and ankle boots"),
        .init(heat: .alluring, text: "in a cropped denim jacket over a floral prairie dress"),
        .init(heat: .alluring, text: "in a lavender linen co-ord, boxy shirt and shorts, flat sandals"),
        .init(heat: .alluring, text: "wearing a black polo neck under a sleeveless rust suede vest, dark jeans"),
        .init(heat: .alluring, text: "wearing a cream blazer dress cinched with a gold chain belt"),
        .init(heat: .alluring, text: "in a forest-green velvet blazer and black silk trousers"),
        .init(heat: .alluring, text: "wearing a beige linen shirt dress, sleeves rolled, tan sandals"),
        .init(heat: .alluring, text: "in a tailored ivory jumpsuit with a wide leather belt"),
        .init(heat: .alluring, text: "wearing a red cable-knit sweater and straight-leg blue jeans"),
        .init(heat: .alluring, text: "in a mustard raincoat and wellington boots on a wet street"),
        .init(heat: .alluring, text: "wearing a navy sailor top and white sailor trousers"),
        .init(heat: .alluring, text: "in a tweed hacking jacket, jodhpurs and tall brown boots"),
        .init(heat: .alluring, text: "wearing a burgundy leather biker jacket over a grey slip dress"),
        .init(heat: .alluring, text: "in a pale blue oxford shirt knotted at the waist over chinos"),
        .init(heat: .alluring, text: "wearing a black silk wrap dress and pearl studs"),
        .init(heat: .alluring, text: "in a wool cape coat and leather gloves with riding boots"),
        .init(heat: .alluring, text: "wearing a chunky knit half-zip and tailored shorts, canvas sneakers"),
        .init(heat: .alluring, text: "in a scarf-printed silk blouse and corduroy trousers"),
        .init(heat: .alluring, text: "wearing a terracotta linen suit, sleeves pushed up"),
        .init(heat: .alluring, text: "in a lace-trimmed white cotton blouse and long dark skirt"),
        .init(heat: .alluring, text: "wearing a vintage grey flannel suit with a loosened tie"),
        .init(heat: .alluring, text: "in an emerald satin blouse and black leather midi skirt"),
        .init(heat: .alluring, text: "wearing a quilted olive gilet over a cream roll-neck and jeans"),
        .init(heat: .sexy, text: "wearing a high-cut black one-piece swimsuit and oversized sunglasses"),
        .init(heat: .sexy, text: "in a tiny red string bikini with a gold body chain"),
        .init(heat: .sexy, text: "wearing a ribbed grey gym set, sports bra and leggings, trainers"),
        .init(heat: .sexy, text: "wearing a bodycon black bandage dress and strappy heels"),
        .init(heat: .sexy, text: "in a cropped tank and low-slung baggy jeans, midriff bare"),
        .init(heat: .sexy, text: "wearing a satin slip dress with a thigh slit and ankle-strap sandals"),
        .init(heat: .sexy, text: "in tight white jeans and a knotted checked shirt"),
        .init(heat: .sexy, text: "wearing a leopard-print mini dress with bare legs"),
        .init(heat: .sexy, text: "in a fitted white shirt, black mini skirt and sheer tights"),
        .init(heat: .sexy, text: "wearing a bandeau top and high-waist denim shorts"),
        .init(heat: .sexy, text: "in a pale pink tennis dress, pleated and short, with sweatbands"),
        .init(heat: .sexy, text: "wearing a lacy white wedding dress with a deep V back"),
        .init(heat: .sexy, text: "wearing a ruched coral off-shoulder midi dress"),
        .init(heat: .sexy, text: "in a black halter swimsuit with a cut-out waist"),
        .init(heat: .sexy, text: "wearing a tiny denim skirt, white crop top and cowboy boots"),
        .init(heat: .sexy, text: "in a sheer mesh top over a nude camisole and leather trousers"),
        .init(heat: .sexy, text: "wearing a green satin slip dress and a fur stole"),
        .init(heat: .sexy, text: "wearing a cream chunky knit sweater dress and bare legs"),
        .init(heat: .sexy, text: "wearing a long silk gown with a plunging back and split"),
        .init(heat: .sexy, text: "in a black leather pencil skirt and a cropped turtleneck"),
        .init(heat: .sexy, text: "wearing a polka-dot bikini with a knotted shirt over it"),
        .init(heat: .sexy, text: "in a strapless blue bodycon mini dress and clear heels"),
        .init(heat: .sexy, tier: .intimate, text: "wearing a pale yellow sundress with thin straps and no bra"),
        .init(heat: .sexy, text: "in a matching lilac knit set, cropped top and high-waist shorts"),
        .init(heat: .sexy, text: "wearing tight black riding trousers and a white shirt tied at the waist"),
        .init(heat: .sexy, text: "in a sheer white shirt open over a black bikini and linen shorts"),
        .init(heat: .sexy, text: "wearing an ivory lace bridal corset top and satin mini skirt"),
        .init(heat: .sexy, tier: .intimate, text: "in a black lace bra and matching high-waist briefs"),
        .init(heat: .sexy, tier: .intimate, text: "in a red lace balconette bra and a tiny thong"),
        .init(heat: .sexy, tier: .intimate, text: "in a nude seamless thong and a cropped white vest, no bra"),
        .init(heat: .sexy, tier: .intimate, text: "wearing black leather harness straps over a lace bralette"),
        .init(heat: .sexy, tier: .intimate, text: "wearing a satin chemise with lace at the hem and bare legs"),
        .init(heat: .sexy, tier: .intimate, text: "in a pale pink cotton bra, frilly knickers and ankle socks"),
        .init(heat: .sexy, tier: .intimate, text: "wearing a fishnet body stocking over a black bra and briefs"),
        .init(heat: .sexy, tier: .intimate, text: "in a white lace corset, matching thong and stockings"),
        .init(heat: .sexy, tier: .intimate, text: "wearing a silky black slip dress with nothing beneath it"),
        .init(heat: .sexy, tier: .intimate, text: "in a cropped mesh bra and lace-up briefs"),
        .init(heat: .sexy, tier: .intimate, text: "wearing a velvet bodysuit with the zip front pulled low"),
        .init(heat: .sexy, tier: .intimate, text: "in a sheer chiffon babydoll and thong"),
        .init(heat: .sexy, tier: .intimate, text: "in a lace basque, suspenders and stockings"),
        .init(heat: .sexy, tier: .intimate, text: "wearing a wet white t-shirt and black briefs"),
        .init(heat: .sexy, tier: .intimate, text: "in a black leather bra, leather skirt and thigh-high boots"),
        .init(heat: .sexy, tier: .intimate, text: "wearing an open satin shirt and a lace thong"),
        .init(heat: .sexy, tier: .intimate, text: "wearing a satin bralette and boxer shorts, barefoot"),
        .init(heat: .sexy, tier: .intimate, text: "wearing a latex bra and high-waist latex briefs"),
        .init(heat: .sexy, tier: .intimate, text: "in a lace teddy with a low back and thigh-high stockings"),
        .init(heat: .sexy, tier: .intimate, text: "wearing a plain grey cotton thong and a chunky knit cardigan"),
        .init(heat: .sexy, tier: .intimate, text: "in a strappy cage bra and briefs"),
        .init(heat: .sexy, tier: .intimate, text: "wearing a dripping wet black bikini with a sheer cover-up"),
    ]

    /// Where. Each already carries its own ambience; the light bank adds the specific lighting.
    private static let settings: [Setting] = [
        .init(text: "in a sunlit loft apartment with tall windows, bare floorboards and a linen sofa"),
        .init(text: "on a white-sand beach at the water's edge, turquoise shallows behind her"),
        .init(text: "in a seamless grey studio with nothing but a single stool"),
        .init(text: "on a Paris balcony with wrought-iron railings and zinc rooftops behind"),
        .init(text: "by an infinity pool at a hillside villa overlooking the sea"),
        .init(text: "in the back seat of a vintage black Mercedes at night, city lights sliding past"),
        .init(text: "on a rooftop at dusk with the skyline glittering behind her"),
        .init(text: "in a neon-lit Tokyo alley slick with rain"),
        .init(text: "in a hotel bathroom with a marble tub, steam on the mirror"),
        .init(text: "on a wooden dock at a still lake at dawn, mist on the water"),
        .init(text: "in an overgrown summer garden among tall grass and wildflowers"),
        .init(text: "in an unmade bed with white linen, morning light through gauze curtains"),
        .init(text: "in a dim jazz bar, red leather booth, a cocktail on the table"),
        .init(text: "on a cobblestone street in Rome beside a Vespa"),
        .init(text: "in a greenhouse full of ferns and condensation-fogged glass"),
        .init(text: "on a yacht deck under full sun, open water behind her"),
        .init(text: "in a dusty desert at golden hour with distant mesas"),
        .init(text: "in a kitchen with open shelves and a bowl of citrus on the counter"),
        .init(text: "on a fire escape above a brick street, laundry lines and pigeons"),
        .init(text: "in a wood-panelled library with a rolling ladder and green lamps"),
        .init(text: "by a hotel-room window with sheer curtains and a city view at night"),
        .init(text: "on a cliff path above the sea, wind pulling at her hair"),
        .init(text: "in a vintage diner booth with chrome trim and a milkshake"),
        .init(text: "in a cabin by a wood stove with a sheepskin rug"),
        .init(text: "in a pink-tiled 1970s bathroom with a round mirror"),
        .init(text: "on a tennis court in late afternoon, long shadows across the clay"),
        .init(text: "in the surf at sunset, waves breaking around her knees"),
        .init(text: "at a white marble bar in a grand hotel lobby"),
        .init(text: "on the steps of a Georgian townhouse with a black door"),
        .init(text: "in a Mediterranean courtyard with lemon trees and terracotta"),
        .init(text: "on a nightclub dance floor under a mirror ball"),
        .init(text: "in a convertible parked on a coastal highway, top down"),
        .init(text: "in a photographer's studio with a dark painted canvas backdrop"),
        .init(text: "in a penthouse living room with floor-to-ceiling glass and a grand piano"),
        .init(text: "on a velvet chaise in a Victorian drawing room"),
        .init(text: "in a boxing gym, heavy bags and chalk dust in the air"),
        .init(text: "on a snowy Alpine terrace wrapped in a blanket, mountains behind"),
        .init(text: "in a laundromat at night, rows of washers humming"),
        .init(text: "in a sun-bleached beach hut doorway, sand on the floor"),
        .init(text: "on a motel balcony with a flickering sign and a palm tree"),
        .init(text: "in a Moroccan riad with zellige tiles and a plunge pool"),
        .init(text: "at a kitchen island at midnight, fridge light the only lamp"),
        .init(text: "on a London street in the rain under a black umbrella"),
        .init(text: "in a field of lavender in Provence, afternoon haze"),
        .init(text: "in a dressing room with a bulb-lined mirror and racks of clothes"),
        .init(text: "on a Brooklyn stoop with a coffee, trees in leaf"),
        .init(text: "in a Scandinavian apartment, pale wood and a single monstera"),
        .init(text: "on a hotel pool lounger with a striped towel and a paperback"),
        .init(text: "in a vineyard at harvest, rows of vines running to the hills"),
        .init(text: "in a vintage elevator with brass doors and a mirrored wall"),
        .init(text: "on a rocky cove at low tide with tide pools shining"),
        .init(text: "in a dark hotel corridor with a long red carpet"),
        .init(text: "in a tropical outdoor shower surrounded by banana leaves"),
        .init(text: "backstage at a fashion show amid rails and steam"),
        .init(text: "on a 1970s shag carpet in front of a wall of vinyl records"),
        .init(text: "at a rooftop pool party, string lights and a DJ booth"),
        .init(text: "on a country road beside a red pickup truck at sunset"),
        .init(text: "in an art gallery, white walls and one enormous canvas"),
        .init(text: "in a sauna doorway with cedar walls and soft steam"),
        .init(text: "on a sailing boat's bow, sea spray and bright sky"),
        .init(text: "in a Lisbon tram with wooden seats and open windows"),
        .init(text: "in a dim bedroom lit by a single string of fairy lights"),
        .init(text: "on a city crosswalk mid-stride, taxis blurred behind her"),
        .init(text: "in a hammock between palms, white sand below"),
        .init(text: "on a hotel bed scattered with room-service trays and champagne"),
        .init(text: "in a florist's shop among buckets of peonies and eucalyptus"),
        .init(text: "in a backyard pool at night, underwater lights glowing"),
        .init(text: "on a marble staircase in a grand villa"),
        .init(text: "at a Miami beach wall painted in pastel stripes"),
        .init(text: "in a cosy bookshop corner with an armchair and a reading lamp"),
        // Added from the prompt-bank additions file (Oct 2026)
        .init(text: "at a neon-lit karaoke bar, red vinyl booths, late night"),
        .init(text: "in a steamy tiled bathroom with a clawfoot tub"),
        .init(text: "on a rooftop terrace above a hot city, string lights overhead"),
        .init(text: "by a mossy stone wall in an overgrown English garden"),
        .init(text: "on a fishing boat deck, nets coiled, grey North Sea light"),
        .init(text: "on a black sand beach under a cliff, wind-blown"),
        .init(text: "in a hotel room with heavy curtains and a gilt mirror"),
        .init(text: "by the pool of a faded Miami art-deco motel"),
        .init(text: "in a green room backstage with mirrors and costume rails"),
        .init(text: "on a wheat-coloured field track at the edge of harvest"),
        .init(text: "in a chintzy country-house drawing room with chipped gilding"),
        .init(text: "at a night market of paper lanterns and steam"),
        .init(text: "in a concrete parking garage, painted arrows and sodium light"),
        .init(text: "on a lava-rock shore with surf breaking behind"),
        .init(text: "in a paper-strewn artist's studio with easels and turpentine"),
        .init(text: "at a temple courtyard with stone lions and incense smoke"),
        .init(text: "in a nightclub cloakroom, mirrored and dim"),
        .init(text: "on a desert highway shoulder beside a dented car"),
        .init(text: "in a vintage train carriage with brass fittings and green velvet seats"),
        .init(text: "by a canal in a low European city, moored barges"),
        .init(text: "in a gym with rubber mats and iron plates"),
        .init(text: "on a balcony in a dense old town, laundry lines above"),
        .init(text: "at a fairground at dusk, ferris wheel lights blurring"),
        .init(text: "in a Japanese ryokan room with tatami and paper screens"),
        .init(text: "on a sailboat heeled over, spray across the deck"),
        .init(text: "in a purple-lit photo booth and arcade"),
        .init(text: "by a frozen waterfall, ice columns and blue shadow"),
        .init(text: "in a whitewashed Greek alley of bougainvillea and blue doors"),
        .init(text: "at a racetrack paddock with hay bales and clipped hedges"),
        .init(text: "on a stone stair in a rainy Sicilian courtyard"),
    ]

    private static let poses: [Pose] = [
        .init(heat: .alluring, text: "she leans back on her hands and laughs at something off-camera"),
        .init(heat: .alluring, text: "she stands with one hand in her hair, looking straight into the lens"),
        .init(heat: .alluring, text: "she walks toward the camera mid-stride, hair moving"),
        .init(heat: .alluring, text: "she sits on the floor, knees drawn up, chin resting on them"),
        .init(heat: .alluring, text: "she glances back over her shoulder, half a smile"),
        .init(heat: .alluring, text: "she leans against the wall, arms loosely crossed, weight on one hip"),
        .init(heat: .alluring, text: "she holds a coffee with both hands and looks out of frame"),
        .init(heat: .alluring, text: "she sits sideways on a chair, one arm draped over its back"),
        .init(heat: .alluring, text: "she stretches her arms overhead, eyes closed, soft smile"),
        .init(heat: .alluring, text: "she twirls so the skirt flares, caught mid-spin"),
        .init(heat: .alluring, text: "she perches on the edge of a table, legs crossed at the ankle"),
        .init(heat: .alluring, text: "she lies on her stomach reading, feet kicked up behind her"),
        .init(heat: .alluring, text: "she stands in profile, looking down, hair falling across her face"),
        .init(heat: .alluring, text: "she tucks her hair behind her ear and looks up at the camera"),
        .init(heat: .alluring, text: "she sits cross-legged, elbows on knees, direct gaze"),
        .init(heat: .alluring, text: "she leans in the doorway, one shoulder on the frame"),
        .init(heat: .alluring, text: "she rests her chin on her hand, elbow on the table, amused"),
        .init(heat: .alluring, text: "she shields her eyes from the sun with one hand, squinting and smiling"),
        .init(heat: .alluring, text: "she lies back in the grass, arms behind her head"),
        .init(heat: .alluring, text: "she stands tall with hands in her pockets, chin slightly raised"),
        .init(heat: .alluring, text: "she caught mid-laugh, hand half-covering her mouth"),
        .init(heat: .alluring, text: "she sits on the steps, elbows on her knees, hands clasped"),
        .init(heat: .alluring, text: "she dances alone, eyes closed, lost in it"),
        .init(heat: .alluring, text: "she leans over a railing looking out, seen from behind and the side"),
        .init(heat: .alluring, text: "she kneels on the bed, hands on her thighs, calm gaze"),
        .init(heat: .alluring, text: "she stands with her back to the camera and turns her head to look back"),
        .init(heat: .alluring, text: "she sits with legs stretched out, ankles crossed, leaning on one arm"),
        .init(heat: .alluring, text: "she adjusts an earring, eyes on the lens"),
        .init(heat: .alluring, text: "she lies on her side propped on one elbow"),
        .init(heat: .alluring, text: "she stands at the window with a hand on the glass, lost in thought"),
        .init(heat: .sexy, text: "she arches her back slightly, one hand on her hip, chin down, eyes up at the lens"),
        .init(heat: .sexy, text: "she lies across the bed on her back, head tipped toward the camera, hair spilling"),
        .init(heat: .sexy, text: "she kneels up tall, hands sliding up through her hair, a slow gaze"),
        .init(heat: .sexy, text: "she sits with one knee up and the other leg stretched, leaning back on her palms"),
        .init(heat: .sexy, text: "she walks out of the water toward the camera, hands wringing out her hair"),
        .init(heat: .sexy, text: "she lies on her front propped on her elbows, legs crossed behind her in the air"),
        .init(heat: .sexy, text: "she stands with her back arched against the wall, one knee bent, foot on the wall"),
        .init(heat: .sexy, text: "she looks over her bare shoulder at the camera, lips parted"),
        .init(heat: .sexy, text: "she sits on the pool edge, legs in the water, leaning back and laughing"),
        .init(heat: .sexy, text: "she straddles a chair backwards, arms folded on the backrest, chin on her arms"),
        .init(heat: .sexy, text: "she lets the strap slide off her shoulder and holds the camera's gaze"),
        .init(heat: .sexy, text: "she stretches like a cat on the bed, mid-yawn, playful"),
        .init(heat: .sexy, text: "she crouches at the shoreline, hands on her knees, wet hair pushed back"),
        .init(heat: .sexy, text: "she lies in the shallows, propped on one elbow, waves washing over her legs"),
        .init(heat: .sexy, text: "she stands hip-cocked with a hand grazing her collarbone, direct gaze"),
        .init(heat: .sexy, text: "she sits on the counter, legs crossed high, leaning forward toward the lens"),
        .init(heat: .sexy, text: "she bites her lip softly and looks up from under her lashes"),
        .init(heat: .sexy, text: "she lies on a lounger, one arm thrown over her head, sunglasses pushed up"),
        .init(heat: .sexy, text: "she leans forward on all fours on the bed, eyes locked on the camera"),
        .init(heat: .sexy, text: "she stands in the doorway holding the frame, weight on one hip, a slow smile"),
        .init(heat: .sexy, text: "she sits on the floor against the bed, knees apart, elbows on knees"),
        .init(heat: .sexy, text: "she tips her head back, throat exposed, eyes half closed"),
        .init(heat: .sexy, text: "she runs a hand down her side, looking away, caught in the moment"),
        .init(heat: .sexy, text: "she lies on her back on the lounger with one knee raised, looking at the lens upside down"),
        .init(heat: .sexy, text: "she sits sideways in the car seat with the door open, legs out, head tilted"),
        .init(heat: .sexy, text: "she walks away from the camera and looks back, hips swaying"),
        .init(heat: .sexy, text: "she rests back on her elbows at the water's edge, chin tilted to the sun"),
        .init(heat: .sexy, text: "she stands in the shower doorway, hair dripping, a towel held loosely"),
        .init(heat: .sexy, text: "she lies diagonally across white sheets, one leg bent, the sheet pulled up to her waist"),
        .init(heat: .sexy, text: "she perches on the arm of the sofa, one foot on the cushion, leaning in"),
        // Added from the prompt-bank additions file (Oct 2026)
        .init(heat: .alluring, text: "she sits on a low wall, ankles crossed, looking off frame"),
        .init(heat: .alluring, text: "she perches on a stool, one heel hooked on the rung"),
        .init(heat: .alluring, text: "she lifts a cup to her lips, gaze over the rim"),
        .init(heat: .alluring, text: "she leans on a railing, elbows wide, laughing softly"),
        .init(heat: .alluring, text: "she adjusts a cufflink, head turned, profile to camera"),
        .init(heat: .alluring, text: "she sits cross-legged on the floor, back straight, hands on knees"),
        .init(heat: .alluring, text: "she stands in a doorway with light behind her, a silhouette"),
        .init(heat: .alluring, text: "she crouches to tie a shoelace, hair falling forward"),
        .init(heat: .alluring, text: "she holds a book half-closed, thumb marking the page"),
        .init(heat: .alluring, text: "she turns mid-conversation, one hand raised"),
        .init(heat: .alluring, text: "she stands with one hand on a chair back, weight shifted"),
        .init(heat: .alluring, text: "she looks up from under her brow, still and direct"),
        .init(heat: .alluring, text: "she steps from a car, one leg swinging out, hand on the frame"),
        .init(heat: .alluring, text: "she leans out of an open window, forearms on the sill"),
        .init(heat: .alluring, text: "she walks past a wall, one palm trailing along it"),
        .init(heat: .alluring, text: "she stands with her hands behind her head, elbows out"),
        .init(heat: .alluring, text: "she kneels to pet a dog, looking up at camera"),
        .init(heat: .sexy, text: "she pulls her hair up off her neck with both hands, chest lifted"),
        .init(heat: .sexy, text: "she bends at the waist toward camera, cleavage and thighs in frame"),
        .init(heat: .sexy, text: "she sits on her heels, knees apart, hands flat on her thighs"),
        .init(heat: .sexy, text: "she stretches both arms overhead, top riding up"),
        .init(heat: .sexy, text: "she leans forward onto a table, chest low, hips high"),
        .init(heat: .sexy, text: "she pulls a shirt off one shoulder, mouth open"),
        .init(heat: .sexy, text: "she looks back from all fours, hair falling across her face"),
        .init(heat: .sexy, text: "she rises onto her toes, reaching up, body stretched long"),
        .init(heat: .sexy, text: "she kneels upright with thighs parted, shoulders rolled back"),
        .init(heat: .sexy, text: "she turns away and arches, hands pressed to her lower back"),
        .init(heat: .sexy, text: "she sits on the floor with knees drawn up and apart, arms wrapped round them"),
    ]

    private static let lights: [String] = [
        "soft window light from the left, gentle falloff into shadow",
        "golden-hour sun low behind her, rim-lit hair, a warm flare in the corner of the frame",
        "overcast daylight, even and flattering, no hard shadows",
        "a single tungsten lamp, warm and dim, deep shadows elsewhere",
        "harsh midday sun with crisp shadows and squinting brightness",
        "neon reflections in magenta and cyan from signs out of frame",
        "candlelight from a cluster of candles on the table, flickering warmth",
        "blue hour after sunset, cool ambient light and a warm interior glow",
        "a large softbox from above and to the right, beauty-dish catchlights",
        "dappled sunlight through leaves moving across her skin",
        "backlight through sheer curtains, a soft halo around her",
        "the glow of a laptop screen in a dark room",
        "hard direct on-camera flash, paparazzi style, slightly blown highlights",
        "a ring light's circular catchlight in her eyes, even and clean",
        "moonlight and a single streetlamp, cool and grainy",
        "fire glow from a wood stove, orange and shifting",
        "fluorescent tube light, slightly green, unglamorous and real",
        "late-afternoon sun through blinds, striped shadows across her",
        "underwater pool lights from below, rippling on her skin",
        "a red darkroom safelight bathing everything in one colour",
        "bright bounced beach light, sand acting as a huge reflector",
        "the headlights of a parked car behind the camera",
        "a dim bar's pendant lamps, pools of amber light",
        "morning fog diffusing the sun into a pale glow",
        "mixed light: cool daylight from the window, warm lamp on her face",
        "sunset bouncing off water, orange glitter in the background",
        "a bare bulb overhead, dramatic downward shadows",
        "stage light from one side, the other side falling into black",
        "a photographer's strobe with a gelled blue background light",
        "soft pink dawn light through an east window",
        // Added from the prompt-bank additions file (Oct 2026)
        "soft north-facing window light, shadow falling across one eye",
        "neon pink and blue sign spill across her face",
        "candlelight from below, flickering amber",
        "light through lace curtains, dappled and soft",
        "car headlights raking past, long streaks",
        "backlit doorway, blown highlights and lens haze",
        "sodium streetlamp amber, deep night behind",
        "pool water reflected light, caustics rippling up the wall",
        "rain-washed dawn light, silvery and low contrast",
    ]

    private static let cameras: [String] = [
        "shot on a 35mm film camera with an 85mm lens at f/1.8, shallow depth of field",
        "shot on a Leica with a 50mm lens, wide open, slight vignette",
        "shot on a medium-format digital camera, 80mm lens, razor-sharp eyes",
        "shot on an iPhone in portrait mode, natural and casual",
        "shot on a Contax T2 point-and-shoot with flash, 90s snapshot feel",
        "shot on Kodak Portra 400 film, 35mm, soft grain and warm tones",
        "shot on a 24mm lens from low angle, slight wide-angle stretch, full body",
        "shot at 135mm from across the room, compressed background",
        "shot on a Polaroid 600 instant camera, soft and square",
        "shot on a Hasselblad with a 110mm lens, tight waist-up framing",
        "shot handheld with a 35mm lens, slight motion blur in the background",
        "shot from a high angle looking down, 50mm lens",
        "shot through a doorway with the frame edges soft in the foreground",
        "shot on Cinestill 800T film, halation on the lights",
        "shot on a 70-200mm at 200mm, creamy out-of-focus background",
        "shot on a Fuji X100 with a 23mm lens, close and intimate",
        "shot on a disposable camera with flash, grainy and candid",
        "shot on a Canon 5D with a 50mm f/1.2, dreamy bokeh",
        "shot from ground level with a 28mm lens, legs long in the frame",
        "shot as a three-quarter-length portrait at 85mm, eye level",
        // Added from the prompt-bank additions file (Oct 2026)
        "shot on Fuji Pro 400H, medium format, airy pastel palette",
        "shot on Ilford HP5 black and white, 50mm, coarse grain",
        "shot on a 105mm macro, shallow focus on the eyes",
        "shot on a Hasselblad, square crop, 80mm",
        "shot at 50mm, eye level, natural perspective",
        "shot on expired film with light leaks and colour shift",
        "shot from behind at 70mm, over-the-shoulder framing",
    ]

    private static let finishes: [String] = [
        "a high-end fashion-editorial look",
        "a candid, caught-in-the-moment feel",
        "a glossy magazine-cover polish",
        "a lo-fi personal-snapshot feel",
        "a cinematic film-still mood",
        "a sun-drenched lifestyle-campaign look",
        "a moody, intimate, late-night atmosphere",
        "a crisp, clean commercial beauty look",
        "a nostalgic early-2000s print feel",
        "a timeless black-and-white silver-gelatin print",
        "a vivid, saturated summer-travel look",
        "a soft, romantic, slightly hazy look",
        // Added from the prompt-bank additions file (Oct 2026)
        "a warm editorial gloss",
        "a gritty documentary feel",
        "a faded 70s magazine look",
        "a high-fashion matte look",
        "a soft dreamy pastel look",
        "a harsh flash paparazzi feel",
        "a creamy mid-century studio look",
        "a cold Nordic moody look",
        "a sunburnt holiday-snapshot feel",
        "a moody chiaroscuro look",
        "a grainy black-and-white reportage feel",
        "a lush saturated tropical look",
        "a faded Polaroid instant feel",
        "a smoky nightclub look",
        "a clean minimal studio look",
        "a rustic earthy film look",
        "a delicate blown-out high-key feel",
    ]

    private static let hairNotes: [String] = [
        "hair loose and a little windswept",
        "hair in a sleek low bun",
        "hair pulled into a high ponytail",
        "hair wet and combed straight back",
        "hair in soft old-Hollywood waves",
        "hair half up with loose strands around her face",
        "hair in a messy bun with pieces falling",
        "hair tucked under a baseball cap",
        "hair in two loose braids",
        "hair tied with a silk scarf",
        "hair freshly blow-dried and glossy",
        "hair piled up and held with a claw clip",
        // Added from the prompt-bank additions file (Oct 2026)
        "hair loose and damp, pushed back off the face",
        "hair tucked behind both ears with a slight wave",
        "hair in a side part, glossy and straight",
        "hair in a braided crown with wisps at the temples",
        "hair wind-tangled and unstyled",
        "hair in a half-up style tied with a silk ribbon",
    ]

    /// Hand-written scenes, `{subject}` is replaced with the subject phrase.
    private static let signatures: [Signature] = [
        .init(heat: .alluring, text: "{subject} on a rainy Paris evening, hurrying under the awning of a café in a camel trench and red lipstick, laughing as she shakes the rain from her umbrella; wet pavement reflecting café light; 50mm, wide open, street-photography feel."),
        .init(heat: .alluring, text: "{subject} sitting on the floor of a record shop in a vintage band tee and jeans, sleeves of LPs around her, holding one up to the camera with a grin; warm tungsten light, Portra 400 grain."),
        .init(heat: .alluring, text: "{subject} on a dawn beach wrapped in an oversized cream knit, hair tangled by the wind, holding a paper cup of coffee with both hands, looking out to sea; pale pink light, 85mm."),
        .init(heat: .alluring, text: "{subject} mid-twirl in a long floral skirt in a lavender field, skirt flaring, eyes closed, afternoon haze, shot from low with a 35mm lens."),
        .init(heat: .alluring, text: "{subject} leaning on the open window of a vintage Fiat on a Tuscan road in a white sundress and sunglasses, one arm resting on the door, cypress trees behind; golden hour."),
        .init(heat: .alluring, text: "{subject} in a black tuxedo jacket and nothing visible beneath, sitting on a grand piano stool with one elbow on the keys, a champagne coupe beside her; a single warm spotlight, black background."),
        .init(heat: .alluring, text: "{subject} at a kitchen island in an oversized white shirt, barefoot, cutting a grapefruit, morning sun across the counter, a candid half-smile; iPhone portrait mode."),
        .init(heat: .alluring, text: "{subject} on a fire escape at dusk in a silk slip and a leather jacket, sitting with her legs dangling through the rails, city lights coming on; 35mm, slight grain."),
        .init(heat: .alluring, text: "{subject} in a sheer black blouse and tailored trousers at a jazz bar, lit by a red pendant lamp, leaning back in the booth with one arm along the leather; 50mm, moody."),
        .init(heat: .alluring, text: "{subject} on a wooden dock at a misty lake in a grey hoodie and socks, legs pulled up, looking back over her shoulder at the camera; cool blue dawn, 85mm."),
        .init(heat: .alluring, text: "{subject} in a bronze sequin dress on a rooftop at midnight, caught mid-laugh with a sparkler in hand, skyline soft behind; on-camera flash, paparazzi energy."),
        .init(heat: .alluring, text: "{subject} in a ribbed cream knit co-ord sitting cross-legged on an unmade bed with a book, hair in a claw clip, gauze-curtain light; Polaroid feel."),
        .init(heat: .alluring, text: "{subject} walking a cobbled Lisbon street in a red midi dress and white sneakers, looking back at the camera, yellow tram blurred behind; bright hard sun."),
        .init(heat: .alluring, text: "{subject} in a cropped tennis dress on a clay court at golden hour, racket over her shoulder, squinting into the sun with a grin; long shadows, 135mm."),
        .init(heat: .alluring, text: "{subject} in a backless black gown on a marble staircase, seen from behind as she turns her head, one hand on the banister; chandelier light, medium format."),
        .init(heat: .alluring, text: "{subject} at a Moroccan riad in a white linen jumpsuit, sitting on the edge of the plunge pool with her feet in the water, zellige tiles everywhere; dappled light."),
        .init(heat: .alluring, text: "{subject} in a camel coat on a London street in the rain, sharing her umbrella with no one, hair curling in the damp, red bus blurred behind; 50mm."),
        .init(heat: .alluring, text: "{subject} on a yacht bow in a navy one-piece and a white linen shirt flying open, hair whipping, squinting and laughing into the wind; bright sun, wide lens."),
        .init(heat: .alluring, text: "{subject} in a vintage pinstripe waistcoat and trousers in a wood-panelled library, one foot on the rolling ladder, reading with a slight frown; green lamp light."),
        .init(heat: .alluring, text: "{subject} in a silk pyjama set on a hotel balcony at sunrise, holding the railing, hair down, city waking below; soft pink light, Portra."),
        .init(heat: .alluring, text: "{subject} in a lilac tulle skirt and white bodysuit in a florist's, arms full of peonies, laughing; soft overcast window light."),
        .init(heat: .alluring, text: "{subject} in a black turtleneck and mini skirt sitting in the back of a yellow cab at night, looking out of the window, neon sliding over her face; Cinestill 800T."),
        .init(heat: .alluring, text: "{subject} in a sage wrap dress on a Mediterranean terrace, leaning on a whitewashed wall with the sea behind, hair tied with a scarf; midday light, 35mm."),
        .init(heat: .alluring, text: "{subject} in a cropped sweatshirt and bike shorts stretching on a sunlit yoga mat by a big window, mid-laugh at the camera; natural light, candid."),
        .init(heat: .alluring, text: "{subject} in a red velvet dress at a candle-lit dinner table, chin on her hand, holding the camera's eye over the rim of a wine glass; warm, dim, 85mm."),
        .init(heat: .alluring, text: "{subject} in a white tank and cargo trousers on a Brooklyn stoop with an iced coffee, early-2000s print feel, flash in daylight."),
        .init(heat: .alluring, text: "{subject} in an oatmeal cable-knit and thick socks curled in an armchair by a wood stove, a mug steaming, looking at the lens over the rim; fire glow."),
        .init(heat: .alluring, text: "{subject} in a gold lamé column gown in an empty art gallery, standing before an enormous canvas, seen from behind with her head turned; even gallery light."),
        .init(heat: .alluring, text: "{subject} in a denim jacket over a slip dress on a coastal highway convertible, top down, hand out catching the wind, hair everywhere; sunset."),
        .init(heat: .alluring, text: "{subject} in a 1950s polka-dot halter dress in a chrome diner booth, straw in her milkshake, mock-serious stare; Kodachrome colour."),
        .init(heat: .sexy, text: "{subject} in a black string bikini walking out of turquoise water toward the camera, wringing out her hair, droplets catching the sun; hard midday light, 85mm."),
        .init(heat: .sexy, text: "{subject} in a champagne satin slip lying across white hotel sheets, one strap off her shoulder, head tipped toward the lens, morning light through gauze; 50mm, soft."),
        .init(heat: .sexy, tier: .intimate, text: "{subject} in a lace bodysuit under an open black blazer, sitting on a kitchen counter at midnight with the fridge door open, its light the only lamp; moody, grainy."),
        .init(heat: .sexy, text: "{subject} in a red plunging one-piece on a hotel pool lounger, one arm over her head, sunglasses pushed up, shot from above; bright bounced light."),
        .init(heat: .sexy, tier: .intimate, text: "{subject} in a wet white tank top and black bikini bottoms at the shoreline, crouched with hands on her knees, hair slicked back, laughing; golden hour."),
        .init(heat: .sexy, tier: .intimate, text: "{subject} in a cropped grey hoodie and lace briefs sitting on the floor against the bed, knees apart, elbows on knees, a slow gaze; single warm lamp."),
        .init(heat: .sexy, text: "{subject} in a backless black mini dress leaning over a hotel balcony rail at night, seen from behind and turning to look back, city glittering; flash plus ambient."),
        .init(heat: .sexy, text: "{subject} in a white crochet bikini in a hammock between palms, one leg hanging down, arm over her eyes against the sun; dappled light, 35mm."),
        .init(heat: .sexy, text: "{subject} in a black velvet corset mini dress in a dim red-lit bar, straddling a bar stool backwards with her arms on the backrest; Cinestill halation."),
        .init(heat: .sexy, tier: .intimate, text: "{subject} in an unbuttoned oversized white shirt and nothing else visible, standing at a window with sheer curtains, backlit silhouette, hand on the glass; soft morning haze."),
        .init(heat: .sexy, text: "{subject} in a leopard bikini and oversized sunglasses lying on her front on a striped towel, propped on elbows, feet kicked up; hard sun, sand reflector."),
        .init(heat: .sexy, tier: .intimate, text: "{subject} in a sheer black mesh dress over a bandeau and briefs on a nightclub floor under a mirror ball, mid-dance, eyes closed; strobe freeze."),
        .init(heat: .sexy, tier: .intimate, text: "{subject} in a silk kimono robe falling off her shoulders over a lace set, kneeling up on a bed strewn with room-service trays, laughing; warm lamp light."),
        .init(heat: .sexy, text: "{subject} in a wet black one-piece climbing out of a night pool lit from below, water streaming off her, looking straight up at the lens; underwater glow."),
        .init(heat: .sexy, text: "{subject} in a tiny white tank and pyjama shorts stretching like a cat across the bed at sunrise, mid-yawn; pale pink light, candid."),
        .init(heat: .sexy, tier: .intimate, text: "{subject} in a red lace bralette under a sheer chiffon robe sitting sideways in a vintage car with the door open, legs out, head tilted; headlight glow."),
        .init(heat: .sexy, text: "{subject} in a cut-out black swimsuit on a yacht deck lying on her back with one knee raised, looking at the camera upside down; full sun, wide lens."),
        .init(heat: .sexy, text: "{subject} in a glossy black mini skirt and mesh top in a rain-slick Tokyo alley, leaning back against the wall with one foot on it, neon pink and cyan on her skin."),
        .init(heat: .sexy, text: "{subject} in a cropped cashmere cardigan buttoned once and matching shorts, lying on a shag carpet in front of a wall of records, one arm behind her head; tungsten warmth."),
        .init(heat: .sexy, text: "{subject} in a bronze metallic bikini and gold body chains in the desert at golden hour, standing hip-cocked, hand at her collarbone, mesas behind; long shadows."),
        .init(heat: .sexy, tier: .intimate, text: "{subject} in a sheer white sundress in the surf at sunset, backlit so her silhouette shows through, walking away and looking back; orange glitter on the water."),
        .init(heat: .sexy, tier: .intimate, text: "{subject} in a lace-trimmed black slip in a steamy hotel bathroom, sitting on the edge of a marble tub with wet hair, towel in one hand; soft diffused light."),
        .init(heat: .sexy, text: "{subject} in a cropped leather jacket over a bikini top and cut-offs on a motel balcony, leaning on the rail under a flickering sign; night, grainy."),
        .init(heat: .sexy, text: "{subject} in a strappy black bodysuit and sheer stockings on a velvet chaise, lying on her side propped on an elbow, one knee drawn up; candlelight."),
        .init(heat: .sexy, text: "{subject} in a halter emerald bikini on a rocky cove at low tide, sitting back on her elbows with her chin tilted to the sun; bright, crisp."),
        .init(heat: .sexy, text: "{subject} in a plum satin corset dress in a mirrored vintage elevator, hands on the brass rail, reflections multiplying her; warm bulb light."),
        .init(heat: .sexy, tier: .intimate, text: "{subject} in a knit bralette and a long sheer skirt walking a white-sand beach at dusk, skirt blowing, seen from a low wide angle; blue hour."),
        .init(heat: .sexy, text: "{subject} in a thin ribbed cami and silk pyjama trousers at a hotel window at night, sheer curtain in one hand, city lights beyond; cool and warm mixed light."),
        .init(heat: .sexy, text: "{subject} in a cheeky-cut tangerine bikini at an outdoor tropical shower, water running over her, banana leaves around, laughing with her eyes closed; dappled sun."),
        .init(heat: .sexy, text: "{subject} in a crystal-mesh mini dress over a nude bodysuit on a penthouse sofa at 3 a.m., shoes kicked off, legs tucked under her, a tired smile; lamp light, flash fill."),
        // Added from the prompt-bank additions file (Oct 2026)
        .init(heat: .alluring, tier: .intimate, text: "{subject} in a pinstripe waistcoat and matching wide trousers with no shirt beneath, perched on the arm of a leather chesterfield with one bare foot dangling, mid-laugh at something off-frame; late window light raking across the room, 50mm, quiet editorial calm."),
        .init(heat: .alluring, text: "{subject} crossing a wet cobbled street in a long olive trench and tall boots, collar up, shopping bag swinging, hair damp; flat overcast grey light, 35mm, focus on her turned profile as she passes a lamppost."),
        .init(heat: .alluring, text: "{subject} on a sunlit greenhouse bench between ferns and tomato vines, in a linen shirt dress with the sleeves rolled, reading a seed packet; dappled green light through glass, 85mm, sweat at her hairline."),
        .init(heat: .alluring, text: "{subject} in a boxy tweed blazer and dark denim, sitting on the hood of a dusty car on an empty desert highway, boots crossed at the ankle, chin tilted to the sun; hard midday light, 28mm from below."),
        .init(heat: .alluring, text: "{subject} in a knitted oatmeal cardigan and pleated midi skirt, leaning over a library table under a green bankers lamp, one hand flat on an open page; warm pooled light, 50mm, dust drifting in the air."),
        .init(heat: .alluring, text: "{subject} in a navy sailor top and white trousers on a heeled sailboat, hair blown sideways, gripping the rail with both hands and squinting; bright overcast sea light, 35mm, spray across the deck."),
        .init(heat: .sexy, text: "{subject} in a tiny red string bikini and gold body chain, stretched on black sand beneath a cliff, one knee bent, sunglasses pushed into her hair; hard low sun, 85mm, salt drying on her skin."),
        .init(heat: .sexy, text: "{subject} in a bodycon black bandage dress and strappy heels, backed against a mirrored nightclub cloakroom wall, hips cocked, drink in one hand; pink neon spill, 35mm, flash-lit highlights on bare shoulders."),
        .init(heat: .sexy, text: "{subject} in a wet white shirt over a black bikini, climbing out of a rooftop pool at dusk, water sheeting off her, fabric clinging transparent; city glow and blue hour, 50mm, hair slicked back."),
        .init(heat: .sexy, text: "{subject} in a high-cut black one-piece lying on a hot concrete diving board, knees bent and toes pointed, arched off the surface; hard sun with deep blue water below, 24mm from the side."),
        .init(heat: .sexy, text: "{subject} in tight white jeans and a knotted checked shirt, bent over the open bonnet of a muscle car at a roadside motel, denim pulling across her arse; flickering vacancy sign light, 35mm, night."),
        .init(heat: .sexy, text: "{subject} in a sheer white shirt open over a black bikini, straddling a backwards chair in a bare loft, elbows on the backrest, chin on her hands; tall window light, 85mm, dust and long shadows."),
        .init(heat: .sexy, text: "{subject} in a tiny denim skirt and white crop top with cowboy boots, leaning back on her palms in the bed of a pickup at a fairground, legs long; blurred ferris wheel lights behind, 50mm, flash."),
        .init(heat: .sexy, text: "{subject} in a pale pink tennis dress, pleated and short, crouched at the baseline of an empty court, racket across her thighs, flushed and breathless; hard late sun, 135mm, long shadows."),
        .init(heat: .sexy, text: "{subject} in a strapless blue bodycon mini dress, stepping out of a vintage car inside a paper-strewn studio, one hand on the door, thigh leading; tungsten lamps, 35mm, wide and close."),
        .init(heat: .sexy, text: "{subject} in an ivory lace bridal corset top and satin mini skirt, sitting on the floor of a chintzy drawing room, veil discarded beside her, garter showing; soft window light, 50mm, cool and posh."),
        .init(heat: .sexy, tier: .intimate, text: "{subject} in a black lace bra and high-waist briefs, kneeling on a rumpled bed, tugging the waistband straight, looking down at herself; warm bedside lamp, 85mm, shadow falling across her breasts."),
        .init(heat: .sexy, tier: .intimate, text: "{subject} in a red lace balconette bra and a tiny thong, face down on grey sheets with her feet crossed in the air, chin propped on her hands, arse raised; soft side light, 50mm, mid-laugh."),
        .init(heat: .sexy, tier: .intimate, text: "{subject} in a sheer black bodysuit with a deep plunge, standing in a steamy tiled bathroom with one foot on the tub rim, hair dripping; fogged window light, 35mm, condensation on the lens."),
        .init(heat: .sexy, tier: .intimate, text: "{subject} in a white lace corset, matching thong and stockings, sitting on a wooden stool with knees wide and back straight, hands gripping the seat behind her; hard flash, 50mm, deep shadow."),
        .init(heat: .sexy, tier: .intimate, text: "{subject} in a satin chemise with lace at the hem, lying on her side on a velvet sofa, one arm folded under her head, strap off the shoulder; candlelight, 50mm, amber skin and slow breathing."),
        .init(heat: .sexy, tier: .intimate, text: "{subject} in a latex bra and high-waist latex briefs, on all fours on a polished concrete floor, back arched, looking back between her arms; hard key light, 35mm, glossy stretched highlights."),
        .init(heat: .sexy, tier: .intimate, text: "{subject} in a fishnet body stocking over a black bra and briefs, standing against a bare brick wall, hands above her head, hips pushed forward; blue-hour window light, 50mm, moody and dim."),
        .init(heat: .sexy, tier: .intimate, text: "{subject} in a cropped mesh bra and lace-up briefs, straddling a chair with her arse barely on the seat, thighs spread, drink forgotten on the table; tungsten glow, 85mm, glossy and close."),
        .init(heat: .sexy, tier: .intimate, text: "{subject} in a wet white t-shirt and black briefs, standing on a fire escape in the rain, fabric transparent and clinging, one hand pushing hair from her face; sodium streetlight, 35mm, dripping."),
        .init(heat: .sexy, tier: .intimate, text: "{subject} in a nude seamless thong and cropped white vest with no bra, lying back on a laundromat bench, knees up, feet braced on a machine door; buzzing fluorescent light, 50mm."),
        .init(heat: .sexy, tier: .intimate, text: "{subject} in a lace teddy with a low back and thigh-high stockings, bent over a kitchen counter at midnight, weight on her forearms, hips high; fridge light and one warm bulb, 35mm."),
    ]
}
