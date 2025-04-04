import UIKit
import SwiftSoup

extension HomeViewController {
    func getSourceInfo(for source: String) -> (String?, ((Document) throws -> [AnimeItem])?) {
        switch source {
        case "AnimeWorld":
            return ("https://www.animeworld.so", parseAnimeWorldFeatured)
        case "GoGoAnime":
            return ("https://anitaku.bz/home.html", parseGoGoFeatured) // Use home.html for latest
        case "AnimeHeaven":
            return ("https://animeheaven.me/new.php", parseAnimeHeavenFeatured) // Or use main page if needed
        case "AnimeFire":
            return ("https://animefire.plus/", parseAnimeFireFeatured)
        case "Kuramanime":
            return ("https://kuramanime.red/quick/ongoing?order_by=updated", parseKuramanimeFeatured)
        case "Anime3rb":
            return ("https://anime3rb.com/titles/list?sort_by=addition_date", parseAnime3rbFeatured) // Fetch latest additions
        case "HiAnime":
            return ("https://hianime.to/home", parseHiAnimeFeatured) // Fetch from home page
        case "Anilibria":
            // Anilibria requires API call, not direct HTML parsing for updates
            return ("https://api.anilibria.tv/v3/title/updates?filter=posters,id,names&limit=20", parseAniLibriaFeatured)
        case "AnimeSRBIJA":
            return ("https://www.animesrbija.com/filter?sort=new", paseAnimeSRBIJAFeatured)
        case "AniWorld":
            return ("https://aniworld.to/neu", paseAniWorldFeatured) // 'neu' means new
        case "TokyoInsider":
            return ("https://www.tokyoinsider.com/new", paseTokyoFeatured)
        case "AniVibe":
            return ("https://anivibe.net/newest", paseAniVibeFeatured)
        case "AnimeUnity":
            return ("https://www.animeunity.to/", parseAnimeUnityFeatured) // Home page for latest/featured
        case "AnimeFLV":
            return ("https://www3.animeflv.net/", paseAnimeFLVFeatured) // Home page for latest episodes
        case "AnimeBalkan":
            return ("https://animebalkan.org/animesaprevodom/?status=&type=&order=update", parseAnimeBalknaFreated)
        case "AniBunker":
            return ("https://www.anibunker.com/animes", parseAniBunkerFeatured) // Anime list page, sort might be needed via URL params if available
        default:
            return (nil, nil)
        }
    }

    func parseAnimeWorldFeatured(_ doc: Document) throws -> [AnimeItem] {
        let animeItems = try doc.select("div.widget:has(div.widget-title:contains(Nuove Uscite)) div.popular > div.item") // Target "Nuove Uscite" (New Releases)
        
        return try animeItems.array().compactMap { item in
            guard let titleElement = try item.select("a.name").first(),
                  let imageElement = try item.select("img").first(),
                  let hrefElement = try item.select("a.poster").first() else {
                print("Skipping item in AnimeWorld parsing due to missing elements.")
                return nil
            }
            let title = try titleElement.text()
            let imageURL = try imageElement.attr("src")
            let href = try hrefElement.attr("href")
            
            guard !title.isEmpty, !imageURL.isEmpty, !href.isEmpty else {
                print("Skipping item in AnimeWorld parsing due to empty attributes.")
                return nil
            }
            
            return AnimeItem(title: title, imageURL: imageURL, href: href)
        }
    }

    func parseGoGoFeatured(_ doc: Document) throws -> [AnimeItem] {
        let animeItems = try doc.select("div.last_episodes ul.items li") // Selector for latest episodes
        return try animeItems.array().compactMap { item -> AnimeItem? in
            guard let titleLink = try item.select("p.name a").first(),
                  let imgLink = try item.select("div.img a").first(),
                  let img = try imgLink.select("img").first() else {
                return nil // Skip if essential elements are missing
            }

            let title = try titleLink.text()
            let imageURL = try img.attr("src")
            var href = try imgLink.attr("href")

            // Clean the href to point to the anime category page, not a specific episode
            if let range = href.range(of: "-episode-\\d+", options: .regularExpression) {
                href.removeSubrange(range)
            }
             // Prepend /category/ if it's not already there (assuming GoGo structure)
             if !href.starts(with: "/category/") {
                 href = "/category" + href // Make it relative or handle base URL later
             }


            guard !title.isEmpty, !imageURL.isEmpty, !href.isEmpty else { return nil }
            return AnimeItem(title: title, imageURL: imageURL, href: href)
        }
    }


    func parseAnimeHeavenFeatured(_ doc: Document) throws -> [AnimeItem] {
        let animeItems = try doc.select("div.gridi div.item") // Assuming 'new.php' has this structure
        return try animeItems.array().compactMap { item -> AnimeItem? in
             guard let titleLink = try item.select("div.similardd a.visited").first(),
                   let imgLink = try item.select("a.boxentry").first(),
                   let img = try imgLink.select("img").first() else {
                 print("Skipping item in AnimeHeaven parsing due to missing elements.")
                 return nil
             }
            let title = try titleLink.text()
            var imageURL = try img.attr("src")
             if !imageURL.hasPrefix("http") { // Ensure full URL
                 imageURL = "https://animeheaven.me/" + imageURL.dropFirst(imageURL.starts(with: "/") ? 1 : 0)
             }

            let href = try imgLink.attr("href")

            guard !title.isEmpty, !imageURL.isEmpty, !href.isEmpty else {
                 print("Skipping item in AnimeHeaven parsing due to empty attributes.")
                 return nil
             }

            return AnimeItem(title: title, imageURL: imageURL, href: href)
        }
    }


    func parseAnimeFireFeatured(_ doc: Document) throws -> [AnimeItem] {
        let animeItems = try doc.select("div.card-group div.row div.divCardUltimosEps") // Selector for latest episodes
        return try animeItems.array().compactMap { item -> AnimeItem? in
            guard let titleElement = try item.select("h3.animeTitle").first(),
                  let imgElement = try item.select("article.card img").first(),
                  let linkElement = try item.select("article.card a").first() else {
                return nil
            }

            // Extract title and remove episode part if present
            var title = try titleElement.text()
            if let range = title.range(of: "- Episódio \\d+", options: .regularExpression) {
                title.removeSubrange(range)
            }

            // Get image URL (prefer data-src)
            var imageURL = try imgElement.attr("data-src")
            if imageURL.isEmpty {
                imageURL = try imgElement.attr("src")
            }
             // Add fallback image if still empty
             if imageURL.isEmpty {
                 imageURL = "https://s4.anilist.co/file/anilistcdn/character/large/default.jpg"
             }


            // Get href and clean it to point to the main anime page
            var href = try linkElement.attr("href")
             if let detailPageRange = href.range(of: "/anime/[^/]+$", options: .regularExpression) {
                 // If it already looks like a detail page URL, use it as is
                  // No change needed, assuming format like /anime/your-anime-name
             } else if let epRange = href.range(of: "/video/\\d+$", options: .regularExpression) {
                 // If it's an episode URL like /video/12345, try to convert to /anime/your-anime-name
                 // This requires fetching the episode page or having a known mapping, which is complex here.
                 // For simplicity, we might skip these or try a best guess if the pattern is consistent.
                 // Let's assume for now we only want links that already point to an anime page.
                 // Or, if the pattern is always /anime/slug/video/id, extract the slug part.
                 if let animeSlugRange = href.range(of: "/anime/([^/]+)/video/", options: .regularExpression) {
                      let animeSlug = String(href[animeSlugRange].split(separator: "/")[1])
                      href = "/anime/\(animeSlug)" // Reconstruct potential anime page URL
                 } else {
                      print("Could not reliably determine anime page URL from episode URL: \(href)")
                      return nil // Skip if we can't get the main anime page URL easily
                 }

             } else {
                  // If it's neither, it might be the base URL or something else, skip it.
                  return nil
             }


            guard !title.isEmpty, !imageURL.isEmpty, !href.isEmpty else { return nil }
            return AnimeItem(title: title, imageURL: imageURL, href: href)
        }
    }


    func parseKuramanimeFeatured(_ doc: Document) throws -> [AnimeItem] {
        let animeItems = try doc.select("div.product__page__content div#animeList div.col-lg-4") // Selector might need adjustment for "featured" vs. "ongoing"
        return try animeItems.array().compactMap { item -> AnimeItem? in
             guard let titleLink = try item.select("h5 a").first(),
                   let picDiv = try item.select("div.product__item__pic").first(),
                   let linkElement = try item.select("a").first() else { return nil }

            let title = try titleLink.text()
            let imageURL = try picDiv.attr("data-setbg") // Get background image
            var href = try linkElement.attr("href")

             // Remove potential episode part from href if present
             if let range = href.range(of: "/episode/\\d+", options: .regularExpression) {
                 href.removeSubrange(range)
             }

            guard !title.isEmpty, !imageURL.isEmpty, !href.isEmpty else { return nil }
            return AnimeItem(title: title, imageURL: imageURL, href: href)
        }
    }

    func parseAnime3rbFeatured(_ doc: Document) throws -> [AnimeItem] {
        let animeItems = try doc.select("div.container-content div.lastUpdates div.my-2") // Selector for latest updates
        return try animeItems.array().compactMap { item -> AnimeItem? in
             guard let titleElement = try item.select("h2.text-ellipsis").first(), // Title might be in h2 or h3
                   let imgElement = try item.select("img").first(),
                   let linkElement = try item.select("a").first() else { return nil }

            let title = try titleElement.text()
            let imageURL = try imgElement.attr("src")
            let href = try linkElement.attr("href") // This should already be the anime detail page link

            guard !title.isEmpty, !imageURL.isEmpty, !href.isEmpty else { return nil }
            return AnimeItem(title: title, imageURL: imageURL, href: href)
        }
    }

    func parseHiAnimeFeatured(_ doc: Document) throws -> [AnimeItem] {
        // Using the logic from the source file's search parser as a base
        do {
            var results: [AnimeItem] = []
            // Adjust selector for "Trending", "Latest", or similar section on the homepage
            let items = try doc.select("div.flw-item") // Example: Use the same selector as search, adjust if needed

            for item in items {
                 guard let titleElement = try item.select("h3.film-name a").first(),
                       let imgElement = try item.select("img.film-poster-img").first() else { continue }

                let title = try titleElement.text()
                let idPath = try titleElement.attr("href")
                 // Clean ID path: remove leading slash and any query parameters
                 var id = idPath.starts(with: "/") ? String(idPath.dropFirst()) : idPath
                 if let queryIndex = id.firstIndex(of: "?") {
                     id = String(id[..<queryIndex])
                 }


                var imageURL = try imgElement.attr("data-src")
                if imageURL.isEmpty {
                    imageURL = try imgElement.attr("src")
                }

                 guard !title.isEmpty, !imageURL.isEmpty, !id.isEmpty else { continue }
                 results.append(AnimeItem(title: title, imageURL: imageURL, href: id)) // Use the cleaned ID as href
            }
            return results
        } catch {
            throw HiAnimeError.parsingError("Failed to parse HiAnime featured: \(error.localizedDescription)")
        }
    }

    func parseAniLibriaFeatured(_ jsonString: String) throws -> [AnimeItem] {
        guard let jsonData = jsonString.data(using: .utf8) else {
            throw NSError(domain: "ParsingError", code: 0, userInfo: [NSLocalizedDescriptionKey: "Could not convert JSON string to Data"])
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
                  let title = names["ru"] as? String ?? names["en"] as? String, // Prefer Russian, fallback to English
                  let posters = item["posters"] as? [String: Any],
                  let medium = posters["medium"] as? [String: Any],
                  let posterURL = medium["url"] as? String else {
                return nil
            }

            let imageURL = "https://anilibria.tv" + posterURL // Prepend base URL
            let href = String(id) // Use the ID as href for consistency

            return AnimeItem(title: title, imageURL: imageURL, href: href)
        }
    }

    func paseAnimeSRBIJAFeatured(_ doc: Document) throws -> [AnimeItem] {
        let animeItems = try doc.select("div.ani-wrap div.ani-item")
        return try animeItems.array().compactMap { item -> AnimeItem? in
             guard let titleElement = try item.select("h3.ani-title").first(),
                   let imgElement = try item.select("img").first(),
                   let linkElement = try item.select("a").first() else { return nil }

            let title = try titleElement.text()

            // Extract highest resolution image from srcset
             let srcset = try imgElement.attr("srcset")
             let imageUrl = srcset.components(separatedBy: ", ")
                 .compactMap { part -> (url: String, width: Int)? in
                     let components = part.split(separator: " ")
                     guard components.count == 2, let widthStr = components.last?.dropLast(), let width = Int(widthStr) else { return nil }
                     return (url: String(components.first ?? ""), width: width)
                 }
                 .sorted { $0.width > $1.width } // Sort descending by width
                 .first?.url ?? (try? imgElement.attr("src")) ?? "" // Fallback to src


            let imageURL = "https://www.animesrbija.com" + imageUrl.dropFirst(imageUrl.starts(with: "/") ? 1 : 0) // Ensure full URL

            let hrefBase = try linkElement.attr("href")
            let href = hrefBase // Use relative path, base URL added later if needed

            guard !title.isEmpty, !imageURL.isEmpty, !href.isEmpty else { return nil }
            return AnimeItem(title: title, imageURL: imageURL, href: href)
        }
    }


    func paseAniWorldFeatured(_ doc: Document) throws -> [AnimeItem] {
        let animeItems = try doc.select("div.seriesListSection div.seriesListContainer div") // Selector for items in "Neu auf AniWorld"
        return try animeItems.array().compactMap { item -> AnimeItem? in
            guard let titleElement = try item.select("h3").first(),
                  let imgElement = try item.select("img").first(),
                  let linkElement = try item.select("a").first() else { return nil }

            let title = try titleElement.text()

            let imageUrl = try imgElement.attr("data-src") // Use data-src
            let imageURL = "https://aniworld.to" + imageUrl // Prepend base URL

            let hrefBase = try linkElement.attr("href")
            // No base URL needed here as href is likely relative to the site root
            let href = hrefBase

            guard !title.isEmpty, !imageURL.isEmpty, !href.isEmpty else { return nil }
            return AnimeItem(title: title, imageURL: imageURL, href: href)
        }
    }


    func paseTokyoFeatured(_ doc: Document) throws -> [AnimeItem] {
        // Tokyo Insider "new" page lists episodes, not full anime series.
        // We need to extract the anime title and link to the *anime* page, not the episode page.
        let episodeItems = try doc.select("div#inner_page div.c_h2b, div#inner_page div.c_h2") // Selectors for episode entries
        var animeMap: [String: AnimeItem] = [:] // Use a dictionary to store unique anime by href

        for item in episodeItems {
             guard let linkElement = try item.select("a").first() else { continue }

            var title = try linkElement.text()
             // Remove episode/special indicators from title
             if let range = title.range(of: "\\s*(episode|special)", options: .regularExpression, range: nil, locale: nil) {
                 title = title.prefix(upTo: range.lowerBound).trimmingCharacters(in: .whitespaces)
             }

            // Extract the href to the *anime* page, not the episode page
            var href = try linkElement.attr("href")
             // Example: href might be "/anime/123/some-anime-name/episode/456" -> need "/anime/123/some-anime-name"
             if let epRange = href.range(of: "/episode/") {
                 href = String(href[..<epRange.lowerBound])
             } else if let spRange = href.range(of: "/special/") {
                  href = String(href[..<spRange.lowerBound])
             }
             // Further cleaning might be needed based on URL structure

             // Since the "new" page doesn't have anime images, use a placeholder or fetch later
             let imageURL = "https://s4.anilist.co/file/anilistcdn/character/large/default.jpg"

             // Store unique anime items based on their href
             if !title.isEmpty && !href.isEmpty && animeMap[href] == nil {
                 animeMap[href] = AnimeItem(title: title, imageURL: imageURL, href: href)
             }
        }
        // Return the values (unique anime items) from the dictionary
        return Array(animeMap.values)
    }

    func paseAniVibeFeatured(_ doc: Document) throws -> [AnimeItem] {
        let animeItems = try doc.select("div.listupd article.bs") // Selector for items on "newest" page
        return try animeItems.array().compactMap { item -> AnimeItem? in
             guard let titleElement = try item.select("div.tt span").first(), // Title element
                   let imgElement = try item.select("img").first(),
                   let linkElement = try item.select("a").first() else { return nil }

            let title = try titleElement.text()

            // Get image URL, prefer data-src, replace 'small' if needed
             var imageUrl = try imgElement.attr("data-src")
             if imageUrl.isEmpty {
                 imageUrl = try imgElement.attr("src")
             }
             // Optional: Enhance image quality if possible (example assumes replacing size indicators)
             // imageUrl = imageUrl.replacingOccurrences(of: "-small", with: "-large") // Adjust based on actual URL pattern


            let href = try linkElement.attr("href") // This should be the link to the anime detail page

            guard !title.isEmpty, !imageUrl.isEmpty, !href.isEmpty else { return nil }
            // No base URL needed as href is likely absolute or relative to root
            return AnimeItem(title: title, imageURL: imageUrl, href: href)
        }
    }


    func parseAnimeUnityFeatured(_ doc: Document) throws -> [AnimeItem] {
         let baseURL = "https://www.animeunity.to" // Base URL for constructing full links

         do {
             // Try to find the specific section for new/featured items first
             // Inspect the homepage HTML for selectors like 'latest-episodes', 'featured-anime', etc.
             // Example: Using a hypothetical selector for a "Featured" carousel
             // let featuredItems = try doc.select("div.featured-carousel .item")
             // If that doesn't exist, fallback to a more general selector like latest updates

             // Fallback: Using a common pattern for latest episode updates
             let items = try doc.select("a.video-item-box") // Adjust this selector based on actual homepage structure

             var uniqueAnime = [String: AnimeItem]() // Use dictionary to avoid duplicates if multiple episodes of same anime are listed

             for item in items {
                 guard let titleElement = try item.select("div.video-title").first(),
                       let imgElement = try item.select("img").first() else { continue }

                 var title = try titleElement.text()
                 // Remove potential episode info from title
                 if let range = title.range(of: "Episodio \\d+", options: .regularExpression) {
                     title = title.prefix(upTo: range.lowerBound).trimmingCharacters(in: .whitespaces)
                 }

                 let imageUrl = try imgElement.attr("src")
                 var href = try item.attr("href")

                 // Clean the href to point to the main anime page, not episode
                 // Example: /anime/123-slug/1 -> /anime/123-slug
                 if let lastSlashIndex = href.lastIndex(of: "/"), href.suffix(from: href.index(after: lastSlashIndex)).allSatisfy({ $0.isNumber }) {
                      href = String(href[..<lastSlashIndex])
                 }

                 // Ensure href is relative to root or construct full URL
                 let fullHref = href.starts(with: "http") ? href : (href.starts(with: "/") ? baseURL + href : baseURL + "/" + href)


                 // Add to dictionary only if not already present, based on href
                 if !title.isEmpty, !imageUrl.isEmpty, !fullHref.isEmpty, uniqueAnime[fullHref] == nil {
                     uniqueAnime[fullHref] = AnimeItem(title: title, imageURL: imageUrl, href: href) // Store relative href if base URL is handled later
                 }
             }

             return Array(uniqueAnime.values)

         } catch {
             print("Error parsing AnimeUnity Featured: \(error.localizedDescription)")
             return []
         }
     }

     func paseAnimeFLVFeatured(_ doc: Document) throws -> [AnimeItem] {
         let animeItems = try doc.select("ul.ListEpisodios li") // Selector for latest episodes list
         var uniqueAnime = [String: AnimeItem]()

         for item in animeItems {
             guard let titleElement = try item.select("strong.Title").first(),
                   let imgElement = try item.select("img").first(),
                   let linkElement = try item.select("a").first() else { continue }

             let title = try titleElement.text()
             let imageUrl = try imgElement.attr("src")
             let imageURL = "https://www3.animeflv.net" + imageUrl.dropFirst(imageUrl.starts(with: "/") ? 1 : 0)

             let episodeHref = try linkElement.attr("href")
             // Convert episode href like /ver/slug-1 to anime href /anime/slug
             let animeHref = episodeHref.replacingOccurrences(of: "/ver/", with: "/anime/")
                                       .replacingOccurrences(of: "-\\d+$", with: "", options: .regularExpression)

             let hrefFull = "https://www3.animeflv.net" + animeHref.dropFirst(animeHref.starts(with: "/") ? 1 : 0)

             // Store unique anime based on the cleaned anime href
             if !title.isEmpty, !imageURL.isEmpty, !animeHref.isEmpty, uniqueAnime[animeHref] == nil {
                 uniqueAnime[animeHref] = AnimeItem(title: title, imageURL: imageURL, href: animeHref) // Store relative href
             }
         }
         return Array(uniqueAnime.values)
     }

     func parseAnimeBalknaFreated(_ doc: Document) throws -> [AnimeItem] {
         let animeItems = try doc.select("div.listupd article.bs") // Selector for anime items on the page
         return try animeItems.array().compactMap { item -> AnimeItem? in
              guard let titleElement = try item.select("h2 a").first(), // Title is usually in h2 within the link
                    let imgElement = try item.select("img").first(),
                    let linkElement = try item.select("a").first() else { return nil }

             let title = try titleElement.text()

             // Prefer data-src for image, fallback to src
             var imageUrl = try imgElement.attr("data-src")
             if imageUrl.isEmpty {
                 imageUrl = try imgElement.attr("src")
             }

             let href = try linkElement.attr("href") // This should be the link to the anime detail page

             guard !title.isEmpty, !imageUrl.isEmpty, !href.isEmpty else { return nil }
             return AnimeItem(title: title, imageURL: imageUrl, href: href)
         }
     }


     func parseAniBunkerFeatured(_ doc: Document) throws -> [AnimeItem] {
         // Assuming the /animes page lists anime, potentially sorted by update or popularity
         let animeItems = try doc.select("div.section--body article.anime--poster") // Adjust selector based on actual structure
         return try animeItems.array().compactMap { item -> AnimeItem? in
              guard let titleElement = try item.select("h4 a").first(), // Title likely in h4 inside link
                    let imgElement = try item.select("img").first(),
                    let linkElement = try item.select("a").first() else { return nil }

             let title = try titleElement.text()

             let imageUrl = try imgElement.attr("src") // data-src might also be used

             let href = try linkElement.attr("href") // Should be relative path like /anime/slug
             let hrefFull = "https://www.anibunker.com" + href.dropFirst(href.starts(with: "/") ? 1 : 0) // Construct full URL if needed later, store relative

             guard !title.isEmpty, !imageUrl.isEmpty, !href.isEmpty else { return nil }
             return AnimeItem(title: title, imageURL: imageUrl, href: href) // Store relative href
         }
     }

}
