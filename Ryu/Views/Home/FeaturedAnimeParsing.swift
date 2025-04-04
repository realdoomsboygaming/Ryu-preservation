import UIKit
import SwiftSoup

extension HomeViewController {

    // Central dispatcher for getting URL and parsing strategy based on source
    func getSourceInfo(for source: String) -> (String?, ((Document) throws -> [AnimeItem])?) {
        switch source {
        case "AnimeWorld":
            return ("https://www.animeworld.so", parseAnimeWorldFeatured)
        case "GoGoAnime":
            return ("https://anitaku.bz/home.html", parseGoGoFeatured) // Use home page for featured
        case "AnimeHeaven":
            return ("https://animeheaven.me/new.php", parseAnimeHeavenFeatured) // Use new releases page
        case "AnimeFire":
            return ("https://animefire.plus/", parseAnimeFireFeatured)
        case "Kuramanime":
            return ("https://kuramanime.red/quick/ongoing?order_by=updated", parseKuramanimeFeatured) // Use ongoing/updated
        case "Anime3rb":
             // Using search results page sorted by date as a proxy for featured/recent
             return ("https://anime3rb.com/titles/list?status[0]=upcomming&status[1]=finished&sort_by=addition_date", parseAnime3rbFeatured)
        case "HiAnime":
            return ("https://hianime.to/home", parseHiAnimeFeatured) // Use home page
        case "Anilibria":
             // Use the API endpoint for recent updates
            return ("https://api.anilibria.tv/v3/title/updates?filter=posters,id,names&limit=20", parseAniLibriaFeatured)
        case "AnimeSRBIJA":
             // Using filter page sorted by new as a proxy
            return ("https://www.animesrbija.com/filter?sort=new", paseAnimeSRBIJAFeatured)
        case "AniWorld":
            return ("https://aniworld.to/neu", paseAniWorldFeatured) // Use 'new' page
        case "TokyoInsider":
             return ("https://www.tokyoinsider.com/new", paseTokyoFeatured) // Use 'new' page
        case "AniVibe":
            return ("https://anivibe.net/newest", paseAniVibeFeatured) // Use 'newest' page
        case "AnimeUnity":
             return ("https://www.animeunity.to/", parseAnimeUnityFeatured) // Use home page
        case "AnimeFLV":
             return ("https://www3.animeflv.net/", paseAnimeFLVFeatured) // Use home page
        case "AnimeBalkan":
            return ("https://animebalkan.org/animesaprevodom/?status=&type=&order=update", parseAnimeBalknaFreated)
        case "AniBunker":
            return ("https://www.anibunker.com/animes", parseAniBunkerFeatured) // Use main anime list page
        default:
            return (nil, nil)
        }
    }

    // --- Specific Parsing Functions ---

    func parseAnimeWorldFeatured(_ doc: Document) throws -> [AnimeItem] {
        let animeItems = try doc.select("div.content[data-name=all] div.item") // Selector for featured on AnimeWorld

        return try animeItems.array().compactMap { item in
            let titleElement = try item.select("a.name").first()
            let title = try titleElement?.text() ?? ""

            let imageElement = try item.select("img").first()
            let imageURL = try imageElement?.attr("src") ?? ""

            let hrefElement = try item.select("a.poster").first()
            let href = try hrefElement?.attr("href") ?? "" // This is the path for details

            return AnimeItem(title: title, imageURL: imageURL, href: href)
        }
    }

    func parseGoGoFeatured(_ doc: Document) throws -> [AnimeItem] {
         // Selector for "Recent Release" on GoGoAnime homepage
         let animeItems = try doc.select("div.last_episodes ul.items li")
         return try animeItems.array().compactMap { item in
             let title = try item.select("p.name a").text()
             let imageURL = try item.select("div.img img").attr("src")
             var href = try item.select("div.img a").attr("href")

             // Clean href to get the anime category link, remove episode part
             if let range = href.range(of: "-episode-\\d+", options: .regularExpression) {
                 href.removeSubrange(range)
             }
              // Prepend '/category' if it's missing, assuming it's needed for detail view
              if !href.starts(with: "/category") && !href.starts(with: "http") {
                  href = "/category" + href
              }


             return AnimeItem(title: title, imageURL: imageURL, href: href)
         }
     }

    func parseAnimeHeavenFeatured(_ doc: Document) throws -> [AnimeItem] {
        let animeItems = try doc.select("div.iepbox") // Selector for new episodes section

        // Use a Set to store unique anime hrefs to avoid duplicates if multiple episodes of the same anime are listed
        var uniqueHrefs = Set<String>()
        var uniqueAnimeItems: [AnimeItem] = []

        for item in animeItems.array() {
            let title = try item.select("div.iepbox-detail a").text()
            var imageURL = try item.select("div.iepbox-thumbnail img").attr("src")
             if !imageURL.hasPrefix("http") {
                 imageURL = "https://animeheaven.me/" + imageURL // Prepend base URL if needed
             }
            let animeHref = try item.select("div.iepbox-detail a").attr("href") // Link to the anime detail page

             // Only add if we haven't seen this anime page link before
             if !animeHref.isEmpty && uniqueHrefs.insert(animeHref).inserted {
                 uniqueAnimeItems.append(AnimeItem(title: title, imageURL: imageURL, href: animeHref))
             }
        }
        return uniqueAnimeItems
    }


    func parseAnimeFireFeatured(_ doc: Document) throws -> [AnimeItem] {
        // Selector for the main featured/latest section on AnimeFire
         let animeItems = try doc.select("div.container.pt-4 div.row.ml-1.mr-1 div.col-6.col-md-4.col-lg-3.mb-3")
         var uniqueHrefs = Set<String>()
         var uniqueAnimeItems: [AnimeItem] = []


         for item in animeItems.array() {
             let title = try item.select("div.card-body a.link-dark").text()
             let imageURL = try item.select("img.image_thumb").attr("data-src") // Use data-src for lazy loading
             let href = try item.select("a").first()?.attr("href") ?? "" // Link should be on the main 'a' tag


             if !href.isEmpty && uniqueHrefs.insert(href).inserted {
                  uniqueAnimeItems.append(AnimeItem(title: title, imageURL: imageURL, href: href))
              }
         }
        return uniqueAnimeItems
    }

    func parseKuramanimeFeatured(_ doc: Document) throws -> [AnimeItem] {
        // Using the provided selector which seems to target an "ongoing" list
        let animeItems = try doc.select("div.product__page__content div#animeList div.col-lg-4")
        return try animeItems.array().compactMap { item in

            let title = try item.select("h5 a").text()
            let imageURL = try item.select("div.product__item__pic").attr("data-setbg") // Lazy loaded image
            let href = try item.select("a").first?.attr("href") ?? "" // Link to details page

            // No cleaning needed if href already points to the main anime page

            return AnimeItem(title: title, imageURL: imageURL, href: href)
        }
    }

    func parseAnime3rbFeatured(_ doc: Document) throws -> [AnimeItem] {
         // Using the selector for the general titles list page
         let animeItems = try doc.select("section div.my-2") // Outer container for each item
         return try animeItems.array().compactMap { item in
             let title = try item.select("h2.text-ellipsis").text() // Title element
             let imageURL = try item.select("img").attr("src") // Image source
             let href = try item.select("a").first()?.attr("href") ?? "" // Link to details

             return AnimeItem(title: title, imageURL: imageURL, href: href)
         }
     }


     func parseHiAnimeFeatured(_ doc: Document) throws -> [AnimeItem] {
         // Target the "Trending" section on the homepage (adjust selector if needed)
         let animeItems = try doc.select("#trending-home div.flw-item") // Example selector, needs verification
         var uniqueHrefs = Set<String>()
         var uniqueAnimeItems: [AnimeItem] = []

         for item in animeItems.array() {
             guard let titleElement = try item.select("h3.film-name a").first(),
                   let title = try? titleElement.text(),
                   let href = try? titleElement.attr("href"), // This href is likely the anime ID/slug
                   let imgElement = try item.select("img.film-poster-img").first(),
                   let imageURL = try? imgElement.attr("data-src").isEmpty ? imgElement.attr("src") : imgElement.attr("data-src")
             else { continue }

             // Clean href to get the ID/slug used for details page
             let cleanedHref = href.replacingOccurrences(of: "/watch/", with: "").components(separatedBy: "?").first ?? href

             if !cleanedHref.isEmpty && uniqueHrefs.insert(cleanedHref).inserted {
                 uniqueAnimeItems.append(AnimeItem(title: title, imageURL: imageURL, href: cleanedHref))
             }
         }
         return uniqueAnimeItems
     }


    func parseAniLibriaFeatured(_ doc: Document) throws -> [AnimeItem] {
        // This function expects JSON string parsed from the body, not a SwiftSoup Document
        guard let preElement = try doc.select("body").first() else {
            throw NSError(domain: "ParsingError", code: 0, userInfo: [NSLocalizedDescriptionKey: "Could not find body element in document"])
        }
        let jsonString = try preElement.html() // Get the JSON string
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
                  let title = names["ru"] as? String ?? names["en"] as? String, // Prefer Russian title, fallback to English
                  let posters = item["posters"] as? [String: Any],
                  let medium = posters["medium"] as? [String: Any], // Using medium poster
                  let posterURL = medium["url"] as? String else {
                return nil
            }
            let imageURL = "https://anilibria.tv" + posterURL // Prepend base URL
            let href = String(id) // Use the ID as href for detail fetching
            return AnimeItem(title: title, imageURL: imageURL, href: href)
        }
    }

    func paseAnimeSRBIJAFeatured(_ doc: Document) throws -> [AnimeItem] {
        let animeItems = try doc.select("div.ani-wrap div.ani-item") // Selector for anime items on the filter page
        return try animeItems.array().compactMap { item in

            let title = try item.select("h3.ani-title").text()

            // Extract image URL from srcset (often contains multiple sizes)
            let srcset = try item.select("img").attr("srcset")
            // Get the last URL listed in srcset, typically the largest one
            let imageUrl = srcset.components(separatedBy: ", ")
                .last?
                .components(separatedBy: " ")
                .first ?? "" // Fallback to empty string if parsing fails

            // Prepend base URL if necessary
            let imageURL = "https://www.animesrbija.com" + imageUrl

            let hrefBase = try item.select("a").first()?.attr("href") ?? ""
            let href = "https://www.animesrbija.com" + hrefBase // Full link to details

            return AnimeItem(title: title, imageURL: imageURL, href: href)
        }
    }

    func paseAniWorldFeatured(_ doc: Document) throws -> [AnimeItem] {
         let animeItems = try doc.select("div.seriesListContainer > div > a") // More specific selector for the links
         return try animeItems.array().compactMap { item in
             let title = try item.select("h3").text()
             // Image is often lazy-loaded, check data-src first
             let imageUrl = try item.select("img").attr("data-src")
             let imageURL = "https://aniworld.to" + imageUrl // Prepend base URL

             let hrefBase = try item.attr("href") // Get href from the 'a' tag itself
             let href = "https://aniworld.to" + hrefBase

             return AnimeItem(title: title, imageURL: imageURL, href: href)
         }
     }


     func paseTokyoFeatured(_ doc: Document) throws -> [AnimeItem] {
         // Target the rows containing new episode links
         let animeItems = try doc.select("div#inner_page div.c_h2b, div#inner_page div.c_h2") // Selectors for rows
         var uniqueHrefs = Set<String>()
         var uniqueAnimeItems: [AnimeItem] = []

         for item in animeItems.array() {
             guard let linkElement = try item.select("a").first() else { continue }

             var title = try linkElement.text()
             // Clean up title by removing episode/special info
             if let range = title.range(of: "\\s*(episode|special)", options: .regularExpression | .caseInsensitive) {
                 title = title.prefix(upTo: range.lowerBound).trimmingCharacters(in: .whitespaces)
             }
              if title.isEmpty { continue } // Skip if title becomes empty after cleaning

             // Image URL seems static or unavailable in this structure
             let imageURL = "https://s4.anilist.co/file/anilistcdn/character/large/default.jpg" // Fallback image

             let hrefBase = try linkElement.attr("href")
             // Construct the link to the *anime detail page*, not the episode page
             // Assuming the detail page URL structure is like /anime/123/anime-title
             let detailHref: String
             let components = hrefBase.split(separator: "/")
             if components.count >= 3 && components[0] == "anime" && components[2] == "episode" {
                 detailHref = "/anime/\(components[1])/\(components[3])" // Reconstruct base anime URL (adjust if needed)
             } else {
                  detailHref = hrefBase // Fallback if structure is different
             }

             let fullHref = "https://www.tokyoinsider.com" + detailHref

              // Add only unique anime based on their detail page href
             if uniqueHrefs.insert(fullHref).inserted {
                  uniqueAnimeItems.append(AnimeItem(title: title, imageURL: imageURL, href: fullHref))
             }
         }
         return uniqueAnimeItems
     }


     func paseAniVibeFeatured(_ doc: Document) throws -> [AnimeItem] {
          let animeItems = try doc.select("div.listupd article.bs") // Selector for items in the list
          return try animeItems.array().compactMap { item -> AnimeItem? in
              guard let title = try? item.select("div.tt span").text(), !title.isEmpty,
                    let imageElement = try? item.select("img").first(),
                    let imageUrl = try? imageElement.attr("src"), !imageUrl.isEmpty, // Use src directly if data-src isn't present
                    let href = try? item.select("a").first()?.attr("href"), !href.isEmpty
              else {
                  return nil // Skip if essential data is missing
              }

              // Prepend base URL if href is relative
              let hrefFull = href.starts(with: "http") ? href : "https://anivibe.net" + href

              return AnimeItem(title: title, imageURL: imageUrl, href: hrefFull)
          }
      }


      func parseAnimeUnityFeatured(_ doc: Document) throws -> [AnimeItem] {
          let baseURL = "https://www.animeunity.to/anime/"

          do {
              // Look for a script tag containing JSON data, a common pattern
              let scripts = try doc.select("script").filter { try $0.html().contains("window.__NUXT__") || $0.html().contains("latest_episodes") || $0.html().contains("highlighted") } // Add keywords

              for script in scripts {
                  let scriptContent = try script.html()

                  // Try to extract JSON data (this requires inspecting the actual script content)
                  // Example: Look for a variable assignment like 'var latestEpisodes = [...]'
                  // This part is highly specific to the website's implementation
                  if let jsonData = extractJsonFromScript(scriptContent, variableName: "highlighted") { // Try 'highlighted' first
                      let items = parseAnimeUnityJsonData(jsonData, baseURL: baseURL)
                      if !items.isEmpty { return items }
                  }
                  if let jsonData = extractJsonFromScript(scriptContent, variableName: "latest_episodes") { // Fallback
                       let items = parseAnimeUnityJsonData(jsonData, baseURL: baseURL)
                       if !items.isEmpty { return items }
                   }
                   // Add more extraction attempts if needed
              }

              // Fallback to parsing HTML elements if script parsing fails
              print("Could not find or parse featured JSON data from scripts, attempting HTML parsing.")
               // Example fallback selector (adjust based on AnimeUnity's homepage structure)
               let animeItems = try doc.select("div.highlighted-container div.card-anime") // Adjust selector
               var uniqueHrefs = Set<String>()
               var uniqueAnimeItems: [AnimeItem] = []


               for item in animeItems.array() {
                   guard let title = try? item.select(".card-title").text(), !title.isEmpty,
                         let styleAttr = try? item.select(".card-image").attr("style"),
                         let imageUrl = extractImageUrlFromStyle(styleAttr), !imageUrl.isEmpty,
                         let hrefSuffix = try? item.attr("href"), !hrefSuffix.isEmpty // href might be relative
                   else { continue }

                   let hrefFull = hrefSuffix.starts(with: "http") ? hrefSuffix : "https://www.animeunity.to" + hrefSuffix

                   if uniqueHrefs.insert(hrefFull).inserted {
                       uniqueAnimeItems.append(AnimeItem(title: title, imageURL: imageUrl, href: hrefFull))
                   }
               }
               if !uniqueAnimeItems.isEmpty { return uniqueAnimeItems }


              print("Failed to extract featured anime from AnimeUnity using known methods.")
              return []

          } catch {
              print("Error parsing AnimeUnity: \(error.localizedDescription)")
              return []
          }
      }

      // Helper function to extract JSON from script content
      private func extractJsonFromScript(_ scriptContent: String, variableName: String) -> Data? {
          let pattern = "var \(variableName)\\s*=\\s*(\\[.*?\\]);" // Adjust pattern based on actual variable assignment
          guard let regex = try? NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators),
                let match = regex.firstMatch(in: scriptContent, range: NSRange(scriptContent.startIndex..., in: scriptContent)),
                let range = Range(match.range(at: 1), in: scriptContent) else {
              return nil
          }
          let jsonString = String(scriptContent[range])
          return jsonString.data(using: .utf8)
      }
    
      // Helper function to parse the extracted JSON data
      private func parseAnimeUnityJsonData(_ jsonData: Data, baseURL: String) -> [AnimeItem] {
          guard let recordsList = try? JSONSerialization.jsonObject(with: jsonData) as? [[String: Any]] else {
              return []
          }
          return recordsList.compactMap { record in
              // Adapt keys based on the actual JSON structure found in the script
               let animeDict = record["anime"] as? [String: Any] ?? record // Handle cases where 'anime' key might not exist
               guard let title = animeDict["title"] as? String ?? animeDict["title_eng"] as? String, // Check for English title too
                     let imageUrl = animeDict["imageurl"] as? String,
                     let animeID = animeDict["id"] as? Int,
                     let slug = animeDict["slug"] as? String else {
                   return nil
               }
               let hrefFull = "\(baseURL)\(animeID)-\(slug)"
              return AnimeItem(title: title, imageURL: imageUrl, href: hrefFull)
          }
      }
    
      // Helper to extract URL from style attribute (e.g., background-image: url(...))
      private func extractImageUrlFromStyle(_ style: String) -> String? {
          let pattern = "background-image:\\s*url\\(['\"]?([^'\"]+)['\"]?\\)"
          guard let regex = try? NSRegularExpression(pattern: pattern),
                let match = regex.firstMatch(in: style, range: NSRange(style.startIndex..., in: style)),
                let range = Range(match.range(at: 1), in: style) else {
              return nil
          }
          return String(style[range])
      }


     func paseAnimeFLVFeatured(_ doc: Document) throws -> [AnimeItem] {
          let animeItems = try doc.select("ul.ListEpisodios li a") // Selector for latest episode links
          var uniqueHrefs = Set<String>()
          var uniqueAnimeItems: [AnimeItem] = []

          for item in animeItems.array() {
              let title = try item.select("strong.Title").text() // Get anime title from the link's strong tag
              let imageUrl = try item.select("img").attr("src") // Get image
              let imageURL = "https://www3.animeflv.net" + imageUrl // Prepend base URL

              let episodeHref = try item.attr("href") // e.g., /ver/idoly-pride-5
              // Convert episode href to anime detail href (e.g., /anime/5848/idoly-pride)
              // This usually involves removing the episode number and changing /ver/ to /anime/
              let components = episodeHref.split(separator: "-")
              guard components.count > 1 else { continue } // Need at least title and episode number
              let animePath = "/anime/" + components.dropLast().joined(separator: "-").replacingOccurrences(of: "/ver/", with: "") // Simplified, might need ID extraction if structure changes

              let animeDetailHref = "https://www3.animeflv.net" + animePath

              if uniqueHrefs.insert(animeDetailHref).inserted {
                   uniqueAnimeItems.append(AnimeItem(title: title, imageURL: imageURL, href: animeDetailHref))
               }
          }
          return uniqueAnimeItems
      }


      func parseAnimeBalknaFreated(_ doc: Document) throws -> [AnimeItem] {
          let animeItems = try doc.select("div.listupd article.bs") // Selector for items
          return try animeItems.array().compactMap { item in
              let title = try item.select("h2").text()
              let imageUrl = try item.select("img").attr("data-src") // Use data-src for lazy loaded images
              let href = try item.select("a").first()?.attr("href") ?? "" // Link to details page

              guard !href.isEmpty else { return nil } // Skip if href is missing

              return AnimeItem(title: title, imageURL: imageUrl, href: href)
          }
      }

      func parseAniBunkerFeatured(_ doc: Document) throws -> [AnimeItem] {
          let animeItems = try doc.select("div.section--body article") // Container for each anime item
          return try animeItems.array().compactMap { item -> AnimeItem? in
              guard let title = try? item.select("h4").text(), !title.isEmpty,
                    let imageElement = try? item.select("img").first(),
                    let imageUrl = try? imageElement.attr("src"), !imageUrl.isEmpty,
                    let href = try? item.select("a").first()?.attr("href"), !href.isEmpty
              else {
                  return nil // Skip if essential data is missing
              }

              // Prepend base URL if href is relative
              let hrefFull = href.starts(with: "http") ? href : "https://www.anibunker.com" + href

              return AnimeItem(title: title, imageURL: imageUrl, href: hrefFull)
          }
      }
}
