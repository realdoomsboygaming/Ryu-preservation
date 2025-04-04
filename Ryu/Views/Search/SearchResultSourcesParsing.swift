import UIKit
import SwiftSoup

// Extension to handle parsing logic for different sources within SearchResultsViewController
extension SearchResultsViewController {

    // Parses HTML or JSON string based on the selected source to extract search results.
    // Handles both HTML parsing using SwiftSoup and JSON parsing for specific sources.
    // Note: The 'html' parameter might contain JSON data for specific sources like Anilibria.
    func parseHTML(html: String, for source: MediaSource) -> [(title: String, imageUrl: String, href: String)] {
        // Use a helper function to dispatch to the correct parsing method.
        // Try parsing as HTML first, pass raw string if it fails (for potential JSON sources)
        do {
            let document = try SwiftSoup.parse(html)
            return parseDocument(document, jsonString: nil, for: source)
        } catch {
            // If HTML parsing fails, assume it might be JSON and pass the raw string
            print("Initial HTML parsing failed for source \(source.rawValue), attempting JSON or direct use. Error: \(error)")
            return parseDocument(nil, jsonString: html, for: source)
        }
    }

    // Central parsing dispatcher. It accepts either a SwiftSoup Document (for HTML)
    // or a JSON string and routes to the appropriate source-specific parser.
    private func parseDocument(_ document: Document?, jsonString: String?, for source: MediaSource) -> [(title: String, imageUrl: String, href: String)] {
        switch source {
        case .animeWorld:
            guard let document = document else { return [] }
            return parseAnimeWorld(document)
        case .gogoanime:
            guard let document = document else { return [] }
            return parseGoGoAnime(document)
        case .animeheaven:
            guard let document = document else { return [] }
            return parseAnimeHeaven(document)
        case .animefire:
            guard let document = document else { return [] }
            return parseAnimeFire(document)
        case .kuramanime:
            guard let document = document else { return [] }
            return parseKuramanime(document)
        case .anime3rb:
            guard let document = document else { return [] }
            return parseAnime3rb(document)
        case .hianime:
            // HiAnime (Aniwatch) uses HTML for search results.
             guard let document = document else {
                 // If document is nil, try parsing the jsonString as HTML
                 if let jsonStr = jsonString {
                     do {
                         let doc = try SwiftSoup.parse(jsonStr)
                         // Instantiate Aniwatch service and call its parser
                         let aniwatchService = Aniwatch()
                         return try aniwatchService.parseSearchResults(html: doc.html())
                     } catch {
                         print("Error parsing HiAnime HTML string: \(error.localizedDescription)")
                         return []
                     }
                 }
                 return [] // Return empty if no document and no string provided
             }
             // If document is not nil, parse directly
             do {
                 let aniwatchService = Aniwatch()
                 return try aniwatchService.parseSearchResults(html: document.html())
             } catch {
                 print("Error parsing HiAnime HTML document: \(error.localizedDescription)")
                 return []
             }
        case .anilibria:
            // Anilibria uses JSON API for search
            guard let jsonString = jsonString else { return [] }
            return parseAnilibria(jsonString)
        case .animesrbija:
            guard let document = document else { return [] }
            return parseAnimeSRBIJA(document)
        case .aniworld:
             guard let document = document else { return [] }
             // Parse all results first
             let results = parseAniWorld(document)
             // Apply client-side fuzzy search using the view controller's query
             return fuzzySearch(self.query, in: results)
        case .tokyoinsider:
            guard let document = document else { return [] }
            return parseTokyoInsider(document)
        case .anivibe:
            guard let document = document else { return [] }
            return parseAniVibe(document)
        case .animeunity:
            guard let document = document else { return [] }
            return parseAnimeUnity(document)
        case .animeflv:
            guard let document = document else { return [] }
            return parseAnimeFLV(document)
        case .animebalkan:
            guard let document = document else { return [] }
            return parseAnimeBalkan(document)
        case .anibunker:
            guard let document = document else { return [] }
            return parseAniBunker(document)
        }
    }

    // --- Source-Specific Parsers ---

    func parseAnimeWorld(_ document: Document) -> [(title: String, imageUrl: String, href: String)] {
        do {
            let items = try document.select(".film-list .item")
            return try items.map { item -> (title: String, imageUrl: String, href: String) in
                let title = try item.select("a.name").text()
                let imageUrl = try item.select("a.poster img").attr("src")
                let href = try item.select("a.poster").attr("href")
                return (title: title, imageUrl: imageUrl, href: href)
            }
        } catch {
            print("Error parsing AnimeWorld: \(error.localizedDescription)")
            return []
        }
    }

    func parseGoGoAnime(_ document: Document) -> [(title: String, imageUrl: String, href: String)] {
        do {
            let items = try document.select("ul.items li")
            return try items.compactMap { item -> (title: String, imageUrl: String, href: String)? in
                guard let linkElement = try item.select("a").first(),
                      let href = try? linkElement.attr("href"), !href.isEmpty, // Check href is not empty
                      let imageUrl = try? linkElement.select("img").attr("src"), !imageUrl.isEmpty // Check imageUrl is not empty
                      else {
                          print("Skipping item in GoGoAnime due to missing link, href, or image.")
                          return nil
                      }

                // Try multiple ways to get the title, prioritizing attributes then text
                var title = (try? linkElement.attr("title")).flatMap { $0.isEmpty ? nil : $0 }
                ?? (try? linkElement.select("img").attr("alt")).flatMap { $0.isEmpty ? nil : $0 }
                ?? (try? item.select("p.name > a").text()).flatMap { $0.isEmpty ? nil : $0 }
                ?? ""

                title = title.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) // Clean up potential quotes

                guard !title.isEmpty else {
                    print("Skipping item in GoGoAnime due to missing title.")
                    return nil
                }

                // Ensure href starts with /category/ as expected by later logic
                 let correctedHref = href.starts(with: "/category/") ? href : "/category\(href)"
                 return (title: title, imageUrl: imageUrl, href: correctedHref)
            }
        } catch {
            print("Error parsing GoGoAnime: \(error.localizedDescription)")
            return []
        }
    }

    func parseAnimeHeaven(_ document: Document) -> [(title: String, imageUrl: String, href: String)] {
        do {
            let items = try document.select("div.info3.bc1 div.similarimg") // Container for each item
            return try items.compactMap { item -> (title: String, imageUrl: String, href: String)? in
                // Safely extract link, href, image, and title
                guard let linkElement = try item.select("a").first(),
                      let href = try? linkElement.attr("href"), !href.isEmpty,
                      let imageElement = try linkElement.select("img").first(),
                      var imageUrl = try? imageElement.attr("src"), !imageUrl.isEmpty,
                      let titleElement = try item.select("div.similarname a.c").first(),
                      let title = try? titleElement.text(), !title.isEmpty
                else {
                    print("Skipping item in AnimeHeaven due to missing elements.")
                    return nil
                }

                // Prepend base URL if the image URL is relative
                if !imageUrl.hasPrefix("http") {
                    imageUrl = "https://animeheaven.me/\(imageUrl)"
                }

                return (title: title, imageUrl: imageUrl, href: href)
            }
        } catch {
            print("Error parsing AnimeHeaven: \(error.localizedDescription)")
            return []
        }
    }


    func parseAnimeFire(_ document: Document) -> [(title: String, imageUrl: String, href: String)] {
         do {
            let items = try document.select("div.card-group div.row div.divCardUltimosEps") // Updated selector
            return try items.compactMap { item -> (title: String, imageUrl: String, href: String)? in
                // Use more specific selectors and guard against nil
                guard let titleElement = try item.select("h3.animeTitle a").first(), // Select the 'a' tag within h3
                      let title = try? titleElement.text(), !title.isEmpty,
                      let imageElement = try item.select("img.animeImage").first(), // Select img by class
                      let imageUrl = try? imageElement.attr("data-src"), !imageUrl.isEmpty, // Use data-src
                      let linkElement = try item.select("a").first(), // Get the main link for href
                      let href = try? linkElement.attr("href"), !href.isEmpty
                else {
                    print("Skipping item in parseAnimeFire due to missing elements.")
                    return nil
                }
                return (title: title, imageUrl: imageUrl, href: href)
            }
        } catch {
            print("Error parsing AnimeFire: \(error.localizedDescription)")
            return []
        }
    }

    func parseKuramanime(_ document: Document) -> [(title: String, imageUrl: String, href: String)] {
        do {
            let items = try document.select("div#animeList div.col-lg-4") // Container for each anime item
            return try items.compactMap { item -> (title: String, imageUrl: String, href: String)? in
                 // Safely extract title, image URL, and href
                guard let titleElement = try item.select("h5 a").first(),
                      let title = try? titleElement.text(), !title.isEmpty,
                      let imageContainer = try item.select("div.product__item__pic").first(),
                      let imageUrl = try? imageContainer.attr("data-setbg"), !imageUrl.isEmpty,
                      let linkElement = try item.select("a").first(), // Usually the link wraps the image/title
                      let href = try? linkElement.attr("href"), !href.isEmpty
                else {
                    print("Skipping item in Kuramanime due to missing elements.")
                    return nil
                }
                return (title: title, imageUrl: imageUrl, href: href)
            }
        } catch {
            print("Error parsing Kuramanime: \(error.localizedDescription)")
            return []
        }
    }

    func parseAnime3rb(_ document: Document) -> [(title: String, imageUrl: String, href: String)] {
         do {
             // Updated selector based on potential structures
             let items = try document.select("div.MediaItem, div.poster-card, article.anime-item, section div.my-2")
             guard !items.isEmpty() else {
                  print("No items found for Anime3rb with selectors.")
                  return []
             }

             return try items.compactMap { item -> (title: String, imageUrl: String, href: String)? in
                  // Use specific selectors for title, image, and href within each item, trying multiple common patterns
                  guard let titleElement = try item.select("h2.text-ellipsis, h2.pt-1, .MediaItem__title, .title a").first(),
                        let title = try? titleElement.text(), !title.isEmpty,
                        let imageElement = try item.select("img.MediaItem__cover, img.poster-image, img").first(),
                        let imageUrl = try? imageElement.attr("data-src") ?? imageElement.attr("src"), !imageUrl.isEmpty, // Check data-src then src
                        let linkElement = try item.select("a.MediaItem__link, a.poster-link, a").first(),
                        let href = try? linkElement.attr("href"), !href.isEmpty else {
                      print("Skipping item in Anime3rb due to missing elements.")
                      return nil
                  }
                  return (title: title, imageUrl: imageUrl, href: href)
             }
         } catch {
              print("Error parsing Anime3rb: \(error.localizedDescription)")
              return []
         }
     }

     func parseAnilibria(_ jsonString: String) -> [(title: String, imageUrl: String, href: String)] {
         guard let jsonData = jsonString.data(using: .utf8) else {
            print("Error: Could not convert Anilibria JSON string to Data.")
            return []
         }

         do {
             guard let jsonObject = try JSONSerialization.jsonObject(with: jsonData, options: []) as? [String: Any],
                   let list = jsonObject["list"] as? [[String: Any]] else {
                 print("Anilibria JSON format error or missing 'list'.")
                 return []
             }

             return list.compactMap { anime -> (title: String, imageUrl: String, href: String)? in
                 guard let id = anime["id"] as? Int,
                       let names = anime["names"] as? [String: Any],
                       let posters = anime["posters"] as? [String: Any],
                       let mediumPoster = posters["medium"] as? [String: Any],
                       let posterURLPath = mediumPoster["url"] as? String else {
                     print("Skipping Anilibria item due to missing essential data (id, name, or poster).")
                     return nil
                 }

                 // Prioritize Russian title, fallback to English
                 let title = (names["ru"] as? String) ?? (names["en"] as? String) ?? "Unknown Title"
                 // Ensure the image URL is absolute
                 let imageURL = posterURLPath.starts(with: "http") ? posterURLPath : "https://anilibria.tv" + posterURLPath
                 // Use the anime ID as the href identifier for detail fetching later
                 let href = String(id)

                 return (title: title, imageUrl: imageURL, href: href)
             }
         } catch {
             print("Error parsing Anilibria JSON: \(error.localizedDescription)")
             return []
         }
     }

     func parseAnimeSRBIJA(_ document: Document) -> [(title: String, imageUrl: String, href: String)] {
         do {
             let items = try document.select("div.ani-wrap div.ani-item") // Container for each item
             return try items.compactMap { item -> (title: String, imageUrl: String, href: String)? in
                 guard let titleElement = try item.select("h3.ani-title a").first(), // Title link
                       let title = try? titleElement.text(), !title.isEmpty,
                       let imgElement = try item.select("img").first(), // Image element
                       // Check srcset first, then src as fallback
                       let srcset = try? imgElement.attr("srcset"),
                       let linkElement = try item.select("a").first(), // Main link for href
                       let hrefBase = try? linkElement.attr("href"), !hrefBase.isEmpty
                 else {
                     print("Skipping item in AnimeSRBIJA due to missing elements.")
                     return nil
                 }

                 // Extract the highest resolution image URL from srcset if available
                 var imageUrl = ""
                 if !srcset.isEmpty {
                     imageUrl = srcset.components(separatedBy: ", ")
                         .compactMap { part -> (url: String, width: Int)? in
                             let components = part.split(separator: " ")
                             guard components.count == 2, let widthStr = components.last?.dropLast(), let width = Int(widthStr) else { return nil }
                             return (url: String(components.first ?? ""), width: width)
                         }
                         .max(by: { $0.width < $1.width })?
                         .url ?? (try? imgElement.attr("src")) ?? "" // Fallback to src if srcset parsing fails
                 } else {
                    imageUrl = (try? imgElement.attr("src")) ?? "" // Fallback to src if srcset is empty
                 }

                 guard !imageUrl.isEmpty else {
                    print("Skipping item in AnimeSRBIJA due to missing image URL.")
                    return nil
                 }


                 // Ensure full URLs
                 let fullImageUrl = imageUrl.starts(with: "http") ? imageUrl : "https://www.animesrbija.com" + imageUrl
                 let href = hrefBase.starts(with: "http") ? hrefBase : "https://www.animesrbija.com" + hrefBase

                 return (title: title, imageUrl: fullImageUrl, href: href)
             }
         } catch {
             print("Error parsing AnimeSRBIJA: \(error.localizedDescription)")
             return []
         }
     }

     func parseAniWorld(_ document: Document) -> [(title: String, imageUrl: String, href: String)] {
         var results: [(title: String, imageUrl: String, href: String)] = []
         do {
            // Selector targets the anchor tags directly within the genre divs
             let anchorElements = try document.select("div.genre > a")
             for anchor in anchorElements {
                // Safely extract title and href
                 if let title = try? anchor.text(), !title.isEmpty,
                    let hrefPath = try? anchor.attr("href"), !hrefPath.isEmpty {
                    // Construct full URL and use a placeholder image
                     results.append((
                         title: title,
                         imageUrl: "https://s4.anilist.co/file/anilistcdn/character/large/default.jpg", // Consistent placeholder
                         href: "https://aniworld.to\(hrefPath)"
                     ))
                 } else {
                     print("Skipping item in AniWorld due to missing title or href.")
                 }
             }
         } catch {
             print("Error parsing AniWorld HTML for links: \(error.localizedDescription)")
         }
         // Fuzzy search is applied *after* this function returns in fetchResults
         return results
     }


     func parseTokyoInsider(_ document: Document) -> [(title: String, imageUrl: String, href: String)] {
         do {
             // Select rows specifically containing an anime link
             let items = try document.select("div#inner_page table[cellpadding='3'] tr:has(a[href*='/anime/'])")
             return try items.compactMap { item -> (title: String, imageUrl: String, href: String)? in
                 // Safely extract elements and attributes
                 guard let linkElement = try item.select("a").first(),
                       let title = try? linkElement.attr("title"), !title.isEmpty,
                       let imageElement = try item.select("img").first(),
                       var imageUrl = try? imageElement.attr("src"), !imageUrl.isEmpty,
                       let hrefPath = try? linkElement.attr("href"), !hrefPath.isEmpty
                 else {
                     print("Skipping item in TokyoInsider due to missing elements.")
                     return nil
                 }

                 // Ensure full image URL
                 imageUrl = imageUrl.starts(with: "http") ? imageUrl : "https://www.tokyoinsider.com" + imageUrl
                 // Ensure full href URL
                 let hrefFull = hrefPath.starts(with: "http") ? hrefPath : "https://www.tokyoinsider.com" + hrefPath

                 return (title: title, imageUrl: imageUrl, href: hrefFull)
             }
         } catch {
             print("Error parsing TokyoInsider: \(error.localizedDescription)")
             return []
         }
     }

     func parseAniVibe(_ document: Document) -> [(title: String, imageUrl: String, href: String)] {
         do {
             let items = try document.select("div.listupd article.bs") // Main container for each item
             return try items.compactMap { item -> (title: String, imageUrl: String, href: String)? in
                 // Safely extract the title, image, and href
                 guard let linkElement = try item.select("a").first(), // The main link usually wraps image/title
                       let title = try? linkElement.attr("title"), !title.isEmpty, // Title from 'title' attribute
                       let imageElement = try item.select("img").first(),
                       let imageUrl = try? imageElement.attr("data-src") ?? imageElement.attr("src"), !imageUrl.isEmpty, // data-src then src
                       let hrefPath = try? linkElement.attr("href"), !hrefPath.isEmpty
                 else {
                     print("Skipping item in AniVibe due to missing elements.")
                     return nil
                 }

                 // Construct full URL for href
                 let hrefFull = hrefPath.starts(with: "http") ? hrefPath : "https://anivibe.to" + hrefPath // Verify base URL

                 return (title: title, imageUrl: imageUrl, href: hrefFull)
             }
         } catch {
              print("Error parsing AniVibe: \(error.localizedDescription)")
              return []
         }
     }

    func parseAnimeUnity(_ document: Document) -> [(title: String, imageUrl: String, href: String)] {
         let baseURL = "https://www.animeunity.to" // Base URL for constructing full URLs

         do {
             // Adjust selector based on actual search results page structure
             let items = try document.select("div.archivio-container .item, div.film-list .item") // Try common list item selectors
             guard !items.isEmpty() else {
                  print("No items found for AnimeUnity with selectors.")
                  return []
             }

             return try items.compactMap { item -> (title: String, imageUrl: String, href: String)? in
                  // Safely extract title, image, and href using potential selectors
                  guard let titleElement = try item.select("h3 a, h4 a, .title a").first(), // Common title elements
                        let title = try? titleElement.text(), !title.isEmpty,
                        let imageElement = try item.select("img").first(),
                        let imageUrlPath = try? imageElement.attr("src") ?? imageElement.attr("data-src"), !imageUrlPath.isEmpty, // src or data-src
                        let linkElement = try item.select("a").first(), // Usually the main link element
                        let hrefPath = try? linkElement.attr("href"), !hrefPath.isEmpty
                  else {
                     print("Skipping item in AnimeUnity due to missing elements.")
                     return nil
                  }

                  // Construct full URLs
                  let fullImageUrl = imageUrlPath.starts(with: "http") ? imageUrlPath : baseURL + imageUrlPath
                  let fullHref = hrefPath.starts(with: "http") ? hrefPath : baseURL + hrefPath

                  return (title: title, imageUrl: fullImageUrl, href: fullHref)
             }
         } catch {
              print("Error parsing AnimeUnity: \(error.localizedDescription)")
              return []
         }
     }

     func parseAnimeFLV(_ document: Document) -> [(title: String, imageUrl: String, href: String)] {
         do {
             // Selector for the list items containing search results
             let items = try document.select("ul.ListAnimes li article.Anime")
             return try items.compactMap { item -> (title: String, imageUrl: String, href: String)? in
                 // Safely extract title, image URL, and href
                 guard let titleElement = try item.select("h3.Title").first(),
                       let title = try? titleElement.text(), !title.isEmpty,
                       let imageElement = try item.select("img").first(),
                       let imageUrlPath = try? imageElement.attr("src"), !imageUrlPath.isEmpty,
                       let linkElement = try item.select("a").first(), // Main link for the anime
                       let hrefPath = try? linkElement.attr("href"), !hrefPath.isEmpty
                 else {
                     print("Skipping item in AnimeFLV due to missing elements.")
                     return nil
                 }

                 // Construct full URLs
                 let baseURL = "https://www3.animeflv.net" // Verify this base URL
                 let imageUrl = imageUrlPath.starts(with: "http") ? imageUrlPath : baseURL + imageUrlPath
                 let hrefFull = hrefPath.starts(with: "http") ? hrefPath : baseURL + hrefPath

                 return (title: title, imageUrl: imageUrl, href: hrefFull)
             }
         } catch {
             print("Error parsing AnimeFLV: \(error.localizedDescription)")
             return []
         }
     }

     func parseAnimeBalkan(_ document: Document) -> [(title: String, imageUrl: String, href: String)] {
         do {
             // Selector targets article elements within the list
             let items = try document.select("div.listupd article.bs") // Common list item structure
             return try items.compactMap { item -> (title: String, imageUrl: String, href: String)? in
                 // Safely extract title, image URL, and href
                 guard let titleElement = try item.select("h2 a, .tt a").first(), // Try common title selectors
                       let title = try? titleElement.attr("title").isEmpty == false ? titleElement.attr("title") : titleElement.text(), // Prefer title attribute, fallback to text
                       !title.isEmpty,
                       let imageElement = try item.select("img").first(),
                       let imageUrl = try? imageElement.attr("data-src") ?? imageElement.attr("src"), !imageUrl.isEmpty, // Check data-src first
                       let href = try? titleElement.attr("href"), !href.isEmpty // href is usually on the same 'a' as title
                 else {
                     print("Skipping item in AnimeBalkan due to missing elements.")
                     return nil
                 }
                 return (title: title, imageUrl: imageUrl, href: href)
             }
         } catch {
              print("Error parsing AnimeBalkan: \(error.localizedDescription)")
              return []
         }
     }


     func parseAniBunker(_ document: Document) -> [(title: String, imageUrl: String, href: String)] {
         do {
             // Target article elements within the main content body section
             let items = try document.select("div.section--body article.animeCard") // Adjust if structure differs
             return try items.compactMap { item -> (title: String, imageUrl: String, href: String)? in
                 // Safely extract title, image URL, and href
                 guard let titleElement = try item.select("h4 a, .animeCard__title a").first(), // Common title selectors
                       let title = try? titleElement.text(), !title.isEmpty,
                       let imageElement = try item.select("img").first(),
                       let imageUrl = try? imageElement.attr("src"), !imageUrl.isEmpty,
                       let linkElement = try item.select("a").first(), // Main link often wraps image/title
                       let hrefPath = try? linkElement.attr("href"), !hrefPath.isEmpty
                 else {
                     print("Skipping item in AniBunker due to missing elements.")
                     return nil
                 }

                 // Construct full URL
                 let baseURL = "https://www.anibunker.com" // Verify this base URL
                 let hrefFull = hrefPath.starts(with: "http") ? hrefPath : baseURL + hrefPath

                 return (title: title, imageUrl: imageUrl, href: hrefFull)
             }
         } catch {
              print("Error parsing AniBunker: \(error.localizedDescription)")
              return []
         }
     }

    // Fuzzy search implementation (kept from original)
    private func fuzzySearch(_ query: String, in results: [(title: String, imageUrl: String, href: String)]) -> [(title: String, imageUrl: String, href: String)] {
        let lowercasedQuery = query.lowercased()
        let queryWords = lowercasedQuery.components(separatedBy: .whitespaces).filter { !$0.isEmpty }

        return results.filter { result in
            let title = result.title.lowercased()

            // Direct containment check
            if title.contains(lowercasedQuery) {
                return true
            }

            // Word-based containment check
            let titleWords = title.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            for queryWord in queryWords {
                if titleWords.contains(where: { $0.contains(queryWord) || queryWord.contains($0) }) {
                    return true
                }
            }

            return false
        }.sorted { // Optional: Sort results by relevance (e.g., how closely title matches query)
             $0.title.lowercased().distance(to: lowercasedQuery) < $1.title.lowercased().distance(to: lowercasedQuery)
        }
    }
}

// Helper extension for basic string distance (Levenshtein distance could be more sophisticated)
extension String {
    func distance(to other: String) -> Int {
        // Simple distance: favor exact matches or prefixes
        if self.hasPrefix(other) { return 0 }
        if other.hasPrefix(self) { return 1 }
        return self.count + other.count // Basic difference as a fallback metric
    }
}
