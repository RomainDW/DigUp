import Foundation
import DigUpKit

/// Decides what the clipboard history masks (fork). Text and file names by adult sites and explicit words; pictures by
/// EmbeddingGemma 2 itself, zero-shot: the picture's vector against descriptions of explicit and of ordinary pictures,
/// on this Mac, in a worker that quits when it's idle.
nonisolated enum SafetyFilter {
    /// Adult sites: a link to one of them, or to a subdomain, is masked.
    static let domains: Set<String> = [
        "pornhub.com", "xvideos.com", "xnxx.com", "xhamster.com", "redtube.com", "youporn.com", "youjizz.com",
        "spankbang.com", "eporner.com", "tnaflix.com", "beeg.com", "motherless.com", "hqporner.com", "porntrex.com",
        "redgifs.com", "onlyfans.com", "fansly.com", "manyvids.com", "chaturbate.com", "stripchat.com", "bongacams.com",
        "cam4.com", "camsoda.com", "livejasmin.com", "myfreecams.com", "brazzers.com", "realitykings.com",
        "bangbros.com", "naughtyamerica.com", "rule34.xxx", "rule34.paheal.net", "e621.net", "gelbooru.com",
        "nhentai.net", "hentaihaven.xxx", "hanime.tv", "fapello.com", "thothub.to", "coomer.su", "coomer.party",
        "kemono.su", "erome.com", "imagefap.com", "scrolller.com", "porn.com", "tube8.com", "sunporno.com",
        "txxx.com", "upornia.com", "hclips.com", "voyeurhit.com", "jacquieetmichel.net", "jacquieetmicheltv.net",
        "dorcelclub.com", "marcdorcel.com", "fr.xhamster.com", "literotica.com", "fetlife.com", "f95zone.to",
    ]

    /// Explicit words, English and French, matched as whole words. Only unambiguous ones: the model catches the rest by
/// meaning (`ImageSafetyChecker.isExplicit(text:)`), "pipe" or "bite" alone would mask code and English.
    static let words: Set<String> = [
        "porn", "porno", "pornhub", "xxx", "nsfw", "nude", "nudes", "naked", "sex", "sexe", "sexy", "fuck", "fucking",
        "blowjob", "cumshot", "creampie", "milf", "hentai", "rule34", "onlyfans", "boobs", "tits", "pussy",
        "gangbang", "threesome", "orgy", "bdsm", "fetish", "camgirl", "stripper", "horny", "nues", "seins",
        "chatte", "baise", "sodomie", "partouze", "salope", "branlette", "éjac", "ejac", "levrette", "coquin", "coquine", "érotique", "erotique", "sexuel",
        "sexuelle",
    ]

    static func isExplicit(text: String) -> Bool {
        let lowered = text.lowercased()
        if hasAdultLink(lowered) { return true }
        let tokens = lowered.split { !$0.isLetter && !$0.isNumber }
        return tokens.contains { words.contains(String($0)) }
    }

    private static func hasAdultLink(_ text: String) -> Bool {
        guard text.contains(".") else { return false }
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return false
        }
        let range = NSRange(text.startIndex..., in: text)
        for match in detector.matches(in: text, range: range) {
            guard let host = match.url?.host?.lowercased() else { continue }
            let parts = host.split(separator: ".")
            // "fr.pornhub.com" → "fr.pornhub.com", "pornhub.com"
            for start in 0..<max(parts.count - 1, 0) where domains.contains(parts[start...].joined(separator: ".")) {
                return true
            }
            if host.hasSuffix(".xxx") || host.hasSuffix(".porn") || host.hasSuffix(".sex") || host.hasSuffix(".adult") {
                return true
            }
        }
        return false
    }
}

/// Checks pictures with the model's image encoder, and texts by their meaning, one at a time on its own queue. The worker (~0.9 GB with the
/// image encoder) starts on the first picture and quits after `idleSeconds` without one.
nonisolated final class ImageSafetyChecker: @unchecked Sendable {
    static let idleSeconds: Double = 60
    /// How much closer to the explicit descriptions than to the ordinary ones a picture must be to be masked. Measured
    /// 2026-10-16 on 59 ordinary photos and screenshots: the highest scored +0.002. Low on purpose: masking a harmless
    /// picture costs a ⌘U, showing an explicit one costs more.
    static let margin: Float = 0.005

    static let explicit = [
        "a nude photo of a naked person", "explicit pornographic sex scene", "a naked woman showing her breasts",
        "a naked man showing his genitals", "topless woman", "erotic photo of a person in lingerie",
        "close-up of genitals", "hentai, explicit anime pornography", "a nude selfie in a mirror",
    ]
    static let ordinary = [
        "a photo of a person fully clothed", "a screenshot of an app or a website", "a photo of a landscape",
        "a photo of food", "a photo of an animal", "a document or a page of text", "a product photo",
        "a group of friends", "a person at the beach in a swimsuit", "a diagram or a chart", "a logo or an icon",
        "a photo of a city street", "a portrait photo of a face",
    ]

    private let queue = DispatchQueue(label: "DigUp.imageSafety", qos: .utility)
    private let modelsDirectory: URL
    private let logFile: URL
    private var worker: EmbeddingWorker?
    private var labels: (explicit: [[Float]], ordinary: [[Float]])?
    private var textLabels: (explicit: [[Float]], ordinary: [[Float]])?

    static let explicitText = [
        "explicit sexual description of people having sex", "an erotic story", "sexting, a dirty message about sex",
        "texte érotique décrivant un rapport sexuel", "message coquin à caractère sexuel", "a link to a porn video",
        "description of nude bodies and genitals",
    ]
    static let ordinaryText = [
        "source code", "a terminal command", "an email about work", "a message between colleagues", "a link to a website",
        "a shopping list", "an address", "a number or an identifier", "a news article", "a recipe",
        "un message entre amis", "un texte en français sur le travail", "a product description", "notes from a meeting",
        "a romantic message to a partner",
    ]
    /// Texts are masked only when clearly closer to the explicit descriptions: ordinary text is most of what's copied.
    /// Measured 2026-10-16: 24 ordinary texts (code, mails, addresses, links, French and English) at most +0.009,
    /// 6 explicit ones (no listed word in most) from +0.048.
    static let textMargin: Float = 0.025
    private var idleExit: DispatchWorkItem?
    private var failed = false

    init(modelsDirectory: URL, logFile: URL) {
        self.modelsDirectory = modelsDirectory
        self.logFile = logFile
    }

    /// True when the picture looks explicit, false when it doesn't, nil when it couldn't be checked (no model yet, or
    /// the worker failed): the history keeps it masked then.
    func isExplicit(imageAt path: String) async -> Bool? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in continuation.resume(returning: check(path)) }
        }
    }

    /// The same for a text: by meaning, beyond `SafetyFilter`'s words and sites.
    func isExplicit(text: String) async -> Bool? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in continuation.resume(returning: checkText(text)) }
        }
    }

    private func checkText(_ text: String) -> Bool? {
        guard let worker = running(), let textLabels else { return nil }
        defer { scheduleIdleExit() }
        do {
            let passage = Prompts.document(title: nil, text: String(text.prefix(1500)))
            guard let vector = try worker.embedTexts([passage]).first else { return nil }
            let explicit = textLabels.explicit.map { dot($0, vector) }.max() ?? 0
            let ordinary = textLabels.ordinary.map { dot($0, vector) }.max() ?? 0
            log("clipboard: text checked, explicit \(explicit) vs ordinary \(ordinary)")
            return explicit - ordinary > Self.textMargin
        } catch {
            log("clipboard: can't check a text: \(error)")
            stop()
            return nil
        }
    }

    private func check(_ path: String) -> Bool? {
        guard let worker = running(), let labels else { return nil }
        defer { scheduleIdleExit() }
        do {
            guard let vector = try worker.embedImages([path], budget: IndexOptions().photoBudget).first?.vector else {
                return nil
            }
            let explicit = labels.explicit.map { dot($0, vector) }.max() ?? 0
            let ordinary = labels.ordinary.map { dot($0, vector) }.max() ?? 0
            log("clipboard: picture checked, explicit \(explicit) vs ordinary \(ordinary)")
            return explicit - ordinary > Self.margin
        } catch {
            log("clipboard: can't check a picture: \(error)")
            stop()
            return nil
        }
    }

    private func running() -> EmbeddingWorker? {
        if let worker { return worker }
        guard !failed, ModelFiles.missing(in: modelsDirectory).isEmpty else { return nil }
        do {
            var config = WorkerConfig.helper(Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/digup"))
            config.environment["DIGUP_MODELS"] = modelsDirectory.path
            config.log = logFile
            config.qos = .utility
            let worker = try EmbeddingWorker(config, textOnly: false)
            let explicit = try worker.embedTexts(Self.explicit.map(Prompts.query)).map(normalized)
            let ordinary = try worker.embedTexts(Self.ordinary.map(Prompts.query)).map(normalized)
            labels = (explicit, ordinary)
            textLabels = (try worker.embedTexts(Self.explicitText.map(Prompts.query)).map(normalized),
                          try worker.embedTexts(Self.ordinaryText.map(Prompts.query)).map(normalized))
            self.worker = worker
            log("clipboard: picture checker ready")
            return worker
        } catch {
            failed = true
            log("clipboard: picture checker can't start: \(error)")
            return nil
        }
    }

    private func scheduleIdleExit() {
        idleExit?.cancel()
        let exit = DispatchWorkItem { [self] in stop() }
        idleExit = exit
        queue.asyncAfter(deadline: .now() + Self.idleSeconds, execute: exit)
    }

    private func stop() {
        worker?.close()
        worker = nil
        idleExit?.cancel()
        idleExit = nil
    }

    private func normalized(_ vector: [Float]) -> [Float] {
        let length = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return length > 0 ? vector.map { $0 / length } : vector
    }

    private func dot(_ a: [Float], _ b: [Float]) -> Float {
        let b = normalized(b)
        return zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
    }
}

/// The indexed files that look NSFW, by the vectors already in the index (`Engine.refreshFlagged`): search results
/// mask them (thumbnail, preview, name, Quick Look) until ⌘U (fork).
@Observable
final class SafetyIndex {
    static let shared = SafetyIndex()

    var flagged: Set<String> = []
    /// ⌘U in the panel or the window: shown until the panel hides or the window closes.
    var revealed = false

    func hides(_ path: String) -> Bool { !revealed && flagged.contains(path) }
}
