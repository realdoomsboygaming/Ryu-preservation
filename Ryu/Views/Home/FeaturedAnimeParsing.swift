import UIKit
import SwiftSoup

// Define AnimeItem if it's not defined elsewhere globally
// class AnimeItem: NSObject { // Using NSObject for potential Objective-C compatibility if needed later
//    let title: String
//    let imageURL: String
//    let href: String
//
//    init(title: String, imageURL: String, href: String) {
//        self.title = title
//        self.imageURL = imageURL
//        self.href = href
//        super.init() // Call super.init() for NSObject subclass
//    }
// }
// Assuming AnimeItem is defined elsewhere or like above


extension HomeViewController {
    func getSourceInfo(for source: String) -> (String?, ((Document?, String?) throws -> [AnimeItem])?) {
        switch source {
        case "AnimeWorld":
            return ("https://www.animeworld.so", parseAnimeWorldFeatured)
        case "GoGoAnime":
            return ("https://anitaku.bz/home.html", parseGoGoFeatured)
        case "AnimeHeaven":
            return ("https://animeheaven.me/new.php", parseAnimeHeavenFeatured)
        case "AnimeFire":
            return ("https://animefire.plus/", parseAnimeFireFeatured)
        case "Kuramanime":
            return ("https://kuramanime.red/quick/ongoing?order_by=updated", parseKuramanimeFeatured)
        case "Anime3rb":
            return ("https://anime3rb.com/titles/list?status[0]=upcomming&status[1]=finished&sort_by=addition_date", parseAnime3rbFeatured)
        case "AniList": // Renamed
            return ("https://aniwatch-api-gp1w.onrender.com/anime/home", parseAniListFeatured)
        case "Anilibria":
            return ("https://api.anilibria.tv/v3/title/updates?filter=posters,id,names&limit=20", parseAniLibriaFeatured)
        case "AnimeSRBIJA":
            // Corrected function name reference
            return ("https://www.animesrbija.com/filter?sort=new", parseAnimeSRBIJAFeatured)
        case "AniWorld":
            // Corrected function name reference
            return ("https://aniworld.to/neu", parseAniWorldFeatured)
        case "TokyoInsider":
            // Corrected function name reference
            return ("https://www.tokyoinsider.com/new", parseTokyoFeatured)
        case "AniVibe":
            // Corrected function name reference
            return ("https://anivibe.net/newest", parseAniVibeFeatured)
        case "AnimeUnity":
            return ("https://www.animeunity.to/", parseAnimeUnityFeatured)
        case "AnimeFLV":
            // Corrected function name reference
            return ("https://www3.animeflv.net/", parseAnimeFLVFeatured)
        case "AnimeBalkan":
            // Corrected function name reference
            return ("https://animebalkan.org/animesaprevodom/?status=&type=&order=update", parseAnimeBalkanFeatured)
        case "AniBunker":
            // Corrected function name reference
            return ("https://www.anibunker.com/animes", parseAniBunkerFeatured)
        default:
            return (nil, nil)
        }
    }

    // --- HTML Parsers ---

    func parseAnimeWorldFeatured(_ doc: Document?, _ jsonString: String?) throws -> [AnimeItem] {
        guard let doc = doc else { throw NSError(domain: "ParsingError", code: 0, userInfo: [NSLocalizedDescriptionKey: "HTML Document is nil"]) }
        let animeItems = try doc.select("div.content[data-name=all] div.item")

        return try animeItems.array().compactMap { item in
            let titleElement = try item.select("a.name").first()
            let title = try titleElement?.text() ?? ""

            let imageElement = try item.select("img").first()
            let imageURL = try imageElement?.attr("src") ?? ""

            let hrefElement = try item.select("a.poster").first()
            let href = try hrefElement?.attr("href") ?? ""

            return AnimeItem(title: title, imageURL: imageURL, href: href)
        }
    }

    func parseGoGoFeatured(_ doc: Document?, _ jsonString: String?) throws -> [AnimeItem] {
        guard let doc = doc else { throw NSError(domain: "ParsingError", code: 0, userInfo: [NSLocalizedDescriptionKey: "HTML Document is nil"]) }
        let animeItems = try doc.select("div.last_episodes li")
        return try animeItems.array().compactMap { item in
            let title = try item.select("p.name a").text()

            let imageURL = try item.select("div.img img").attr("src")
            var href = try item.select("div.img a").attr("href")

            if let range = href.range(of: "-episode-\\d+", options: .regularExpression) {
                href.removeSubrange(range)
            }
            href = "/category" + href

            return AnimeItem(title: title, imageURL: imageURL, href: href)
        }
    }

     func parseAnimeHeavenFeatured(_ doc: Document?, _ jsonString: String?) throws -> [AnimeItem] {
         guard let doc = doc else { throw NSError(domain: "ParsingError", code: 0, userInfo: [NSLocalizedDescriptionKey: "HTML Document is nil"]) }
         let animeItems = try doc.select("div.boldtext div.chart.bc1")
         return try animeItems.array().compactMap { item in
             let title = try item.select("div.chartinfo a.c").text()

             let imageURL = try item.select("div.chartimg img").attr("src")
             let image = "https://animeheaven.me/" + imageURL

             let href = try item.select("div.chartimg a").attr("href")

             return AnimeItem(title: title, imageURL: image, href: href)
         }
     }

     func parseAnimeFireFeatured(_ doc: Document?, _ jsonString: String?) throws -> [AnimeItem] {
         guard let doc = doc else { throw NSError(domain: "ParsingError", code: 0, userInfo: [NSLocalizedDescriptionKey: "HTML Document is nil"]) }
         let animeItems = try doc.select("div.container.eps div.card-group div.col-12")
         return try animeItems.array().compactMap { item in

             var title = try item.select("h3.animeTitle").text()
             if let range = title.range(of: "- Episódio \\d+", options: .regularExpression) {
                 title.removeSubrange(range)
             }

             var imageURL = try item.select("article.card img").attr("src") // Changed from data-src

             if imageURL.isEmpty {
                 imageURL = "https://s4.anilist.co/file/anilistcdn/character/large/default.jpg"
             }

             var href = try item.select("article.card a").attr("href")

             if let range = href.range(of: "/\\d+$", options: .regularExpression) {
                 href.replaceSubrange(range, with: "-todos-os-episodios")
             }

             return AnimeItem(title: title, imageURL: imageURL, href: href)
         }
     }

     func parseKuramanimeFeatured(_ doc: Document?, _ jsonString: String?) throws -> [AnimeItem] {
         guard let doc = doc else { throw NSError(domain: "ParsingError", code: 0, userInfo: [NSLocalizedDescriptionKey: "HTML Document is nil"]) }
         let animeItems = try doc.select("div.product__page__content div#animeList div.col-lg-4")
         return try animeItems.array().compactMap { item in

             let title = try item.select("h5 a").text()

             let imageURL = try item.select("div.product__item__pic").attr("data-setbg")

             var href = try item.select("a").attr("href")
             if let range = href.range(of: "/episode/\\d+", options: .regularExpression) {
                 href.removeSubrange(range)
             }

             return AnimeItem(title: title, imageURL: imageURL, href: href)
         }
     }

     func parseAnime3rbFeatured(_ doc: Document?, _ jsonString: String?) throws -> [AnimeItem] {
         guard let doc = doc else { throw NSError(domain: "ParsingError", code: 0, userInfo: [NSLocalizedDescriptionKey: "HTML Document is nil"]) }
         let animeItems = try doc.select("section div.my-2")
         return try animeItems.array().compactMap { item in

             let title = try item.select("h2.pt-1").text()
             let imageUrl = try item.select("img").attr("src")
             let href = try item.select("a").first()?.attr("href") ?? ""
             return AnimeItem(title: title, imageURL: imageUrl, href: href)
         }
     }

    // --- JSON Parsers ---
    func parseAniListFeatured(_ doc: Document?, _ jsonString: String?) throws -> [AnimeItem] {
         guard let jsonString = jsonString, let jsonData = jsonString.data(using: .utf8) else {
             throw NSError(domain: "ParsingError", code: 0, userInfo: [NSLocalizedDescriptionKey: "JSON String is nil or invalid"])
         }
         let json = try JSONSerialization.jsonObject(with: jsonData, options: []) as? [String: Any]
         guard let spotlightAnimes = json?["spotlightAnimes"] as? [[String: Any]] else {
             throw NSError(domain: "ParsingError", code: 0, userInfo: [NSLocalizedDescriptionKey: "Could not find 'spotlightAnimes' in JSON"])
         }
         return spotlightAnimes.compactMap { anime -> AnimeItem? in
             guard let title = anime["name"] as? String,
                   let imageUrl = anime["poster"] as? String,
                   let href = anime["id"] as? String else { return nil }
             // Use the anime ID (slug) as href
             return AnimeItem(title: title, imageURL: imageUrl, href: href)
         }
     }

     func parseAniLibriaFeatured(_ doc: Document?, _ jsonString: String?) throws -> [AnimeItem] {
         guard let jsonString = jsonString, let jsonData = jsonString.data(using: .utf8) else {
             throw NSError(domain: "ParsingError", code: 0, userInfo: [NSLocalizedDescriptionKey: "JSON String is nil or invalid"])
         }
         guard let json = try JSONSerialization.jsonObject(with: jsonData, options: []) as? [String: Any] else {
             throw NSError(domain: "ParsingError", code: 0, userInfo: [NSLocalizedDescriptionKey: "Invalid JSON structure"])
         }
         guard let list = json["list"] as? [[String: Any]] else {
             throw NSError(domain: "ParsingError", code: 0, userInfo: [NSLocalizedDescriptionKey: "Invalid JSON structure: missing or invalid 'list' key"])
         }
         return list.compactMap { item in
             guard let id = item["id"] as? Int,
                   let names = item["names"] as? [String: Any],
                   let title = names["ru"] as? String,
                   let posters = item["posters"] as? [String: Any],
                   let medium = posters["medium"] as? [String: Any],
                   let posterURL = medium["url"] as? String else { return nil }
             let imageURL = "https://anilibria.tv" + posterURL
             let href = String(id) // Use the ID as href
             return AnimeItem(title: title, imageURL: imageURL, href: href)
         }
     }


    // --- More HTML Parsers (Corrected function names) ---
    func parseAnimeSRBIJAFeatured(_ doc: Document?, _ jsonString: String?) throws -> [AnimeItem] { // Corrected name
        guard let doc = doc else { throw NSError(domain: "ParsingError", code: 0, userInfo: [NSLocalizedDescriptionKey: "HTML Document is nil"]) }
        let animeItems = try doc.select("div.ani-wrap div.ani-item")
        return try animeItems.array().compactMap { item in
            let title = try item.select("h3.ani-title").text()
            let srcset = try item.select("img").attr("srcset")
            let imageUrl = srcset.components(separatedBy: ", ").last?.components(separatedBy: " ").first ?? ""
            let imageURL = "https://www.animesrbija.com" + imageUrl
            let hrefBase = try item.select("a").first()?.attr("href") ?? ""
            let href = "https://www.animesrbija.com" + hrefBase
            return AnimeItem(title: title, imageURL: imageURL, href: href)
        }
    }

    func parseAniWorldFeatured(_ doc: Document?, _ jsonString: String?) throws -> [AnimeItem] { // Corrected name
         guard let doc = doc else { throw NSError(domain: "ParsingError", code: 0, userInfo: [NSLocalizedDescriptionKey: "HTML Document is nil"]) }
         let animeItems = try doc.select("div.seriesListSection div.seriesListContainer div")
         return try animeItems.array().compactMap { item in
             let title = try item.select("h3").text()
             let imageUrl = try item.select("img").attr("data-src")
             let imageURL = "https://aniworld.to" + imageUrl
             let hrefBase = try item.select("a").first()?.attr("href") ?? ""
             let href = "https://aniworld.to" + hrefBase
             return AnimeItem(title: title, imageURL: imageURL, href: href)
         }
     }

     func parseTokyoFeatured(_ doc: Document?, _ jsonString: String?) throws -> [AnimeItem] { // Corrected name
         guard let doc = doc else { throw NSError(domain: "ParsingError", code: 0, userInfo: [NSLocalizedDescriptionKey: "HTML Document is nil"]) }
         let animeItems = try doc.select("div#inner_page div.c_h2b, div#inner_page div.c_h2")
         return try animeItems.array().compactMap { item in
             var title = try item.select("a").text()
             if let range = title.range(of: "\\s*(episode|special)", options: .regularExpression, range: nil, locale: nil) {
                 title = title.prefix(upTo: range.lowerBound).trimmingCharacters(in: .whitespaces)
             }
             // Tokyo insider search doesn't easily provide images, using placeholder
             let imageURL = "https://s4.anilist.co/file/anilistcdn/character/large/default.jpg"
             // Extract the anime detail page link (the one without 'episode')
             let links = try item.select("a")
             guard let detailLink = try links.filter({ try !$0.attr("href").contains("/episode/") }).first,
                   let hrefBase = try? detailLink.attr("href") else { return nil } // Skip if no detail link

             let href = "https://www.tokyoinsider.com" + hrefBase
             return AnimeItem(title: title, imageURL: imageURL, href: href)
         }
     }

     func parseAniVibeFeatured(_ doc: Document?, _ jsonString: String?) throws -> [AnimeItem] { // Corrected name
         guard let doc = doc else { throw NSError(domain: "ParsingError", code: 0, userInfo: [NSLocalizedDescriptionKey: "HTML Document is nil"]) }
         let animeItems = try doc.select("div.listupd article")
         return try animeItems.array().compactMap { item in
             let title = try item.select("div.tt span").text()
             var imageUrl = try item.select("img").attr("src")
             imageUrl = imageUrl.replacingOccurrences(of: #"-\d+x\d+(\.\w+)$"#, with: "$1", options: .regularExpression) // Remove size suffix
             let href = try item.select("a").first()?.attr("href") ?? ""
             let hrefFull = "https://anivibe.net" + href // Prepend base URL
             return AnimeItem(title: title, imageURL: imageUrl, href: hrefFull)
         }
     }

     func parseAnimeUnityFeatured(_ doc: Document?, _ jsonString: String?) throws -> [AnimeItem] {
        guard let doc = doc else { throw NSError(domain: "ParsingError", code: 0, userInfo: [NSLocalizedDescriptionKey: "HTML Document is nil"]) }
        let baseURL = "https://www.animeunity.to/anime/"

        do {
            let rawHtml = try doc.html()

            // Find the <layout-items> tag which contains the JSON
            if let startIndex = rawHtml.range(of: "<layout-items")?.upperBound,
               let endIndex = rawHtml.range(of: "</layout-items>")?.lowerBound {

                let layoutContent = String(rawHtml[startIndex..<endIndex])

                // Extract the JSON string from items-json attribute
                if let jsonStart = layoutContent.range(of: "items-json=\"")?.upperBound,
                   let jsonEnd = layoutContent[jsonStart...].range(of: "\"")?.lowerBound {

                    // Clean the JSON string (replace HTML entities like ")
                    let jsonString = String(layoutContent[jsonStart..<jsonEnd])
                        .replacingOccurrences(of: """, with: "\"") // Corrected replacement

                    if let jsonData = jsonString.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                       let data = json["data"] as? [[String: Any]] {

                        return data.compactMap { record in
                            guard let anime = record["anime"] as? [String: Any],
                                  let title = anime["title"] as? String ?? anime["title_eng"] as? String, // Prefer original, fallback to English
                                  let imageUrl = anime["imageurl"] as? String,
                                  let animeID = anime["id"] as? Int,
                                  let slug = anime["slug"] as? String else {
                                return nil
                            }

                            let hrefFull = "\(baseURL)\(animeID)-\(slug)"
                            return AnimeItem(title: title, imageURL: imageUrl, href: hrefFull)
                        }
                    } else {
                         print("Failed to parse items-json from AnimeUnity layout-items")
                    }
                } else {
                     print("Could not find items-json attribute in AnimeUnity layout-items")
                 }
            } else {
                print("Could not find layout-items element for AnimeUnity")
            }
            return []
        } catch {
            print("Error parsing AnimeUnity Featured: \(error.localizedDescription)")
            return []
        }
    }


    // Added Stub Function
    func parseAnimeFLVFeatured(_ doc: Document?, _ jsonString: String?) throws -> [AnimeItem] {
        print("Warning: parseAnimeFLVFeatured called, but using stub implementation.")
        // TODO: Implement actual parsing logic based on AnimeFLV's homepage structure.
        return []
    }

    // Added Stub Function
    func parseAnimeBalkanFeatured(_ doc: Document?, _ jsonString: String?) throws -> [AnimeItem] {
        print("Warning: parseAnimeBalkanFeatured called, but using stub implementation.")
        // TODO: Implement actual parsing logic based on AnimeBalkan's homepage structure.
        return []
    }

    // Added Stub Function
    func parseAniBunkerFeatured(_ doc: Document?, _ jsonString: String?) throws -> [AnimeItem] {
        print("Warning: parseAniBunkerFeatured called, but using stub implementation.")
        // TODO: Implement actual parsing logic based on AniBunker's homepage structure.
        return []
    }
}
