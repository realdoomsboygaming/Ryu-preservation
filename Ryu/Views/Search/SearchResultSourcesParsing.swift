import UIKit
import SwiftSoup

extension SearchResultsViewController {
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
                      let href = try? linkElement.attr("href"),
                      let imageUrl = try? linkElement.select("img").attr("src") else {
                          return nil
                      }

                var title = (try? linkElement.attr("title")).flatMap { $0.isEmpty ? nil : $0 }
                ?? (try? linkElement.select("img").attr("alt")).flatMap { $0.isEmpty ? nil : $0 }
                ?? (try? item.select("p.name > a").text()).flatMap { $0.isEmpty ? nil : $0 }
                ?? ""

                title = title.trimmingCharacters(in: CharacterSet(charactersIn: "\""))

                guard !title.isEmpty else { return nil }
                return (title: title, imageUrl: imageUrl, href: href)
            }
        } catch {
            print("Error parsing GoGoAnime: \(error.localizedDescription)")
            return []
        }
    }

    func parseAnimeHeaven(_ document: Document) -> [(title: String, imageUrl: String, href: String)] {
        do {
            let items = try document.select("div.info3.bc1 div.similarimg")
            return try items.map { item -> (title: String, imageUrl: String, href: String) in
                let linkElement = try item.select("a").first()
                let href = try linkElement?.attr("href") ?? ""
                var imageUrl = try linkElement?.select("img").attr("src") ?? ""
                if !imageUrl.isEmpty && !imageUrl.hasPrefix("http") {
                    imageUrl = "https://animeheaven.me/\(imageUrl)"
                }
                let title = try item.select("div.similarname a.c").text()
                return (title: title, imageUrl: imageUrl, href: href)
            }
        } catch {
            print("Error parsing AnimeHeaven: \(error.localizedDescription)")
            return []
        }
    }

    func parseAnimeFire(_ document: Document) -> [(title: String, imageUrl: String, href: String)] {
        do {
            let items = try document.select("div.card-group div.row div.divCardUltimosEps")
            return try items.compactMap { item -> (title: String, imageUrl: String, href: String)? in
                guard let title = try item.select("div.text-block h3.animeTitle").first()?.text(),
                      let imageUrl = try item.select("article.card a img").first()?.attr("data-src"),
                      let href = try item.select("article.card a").first()?.attr("href")
                else { return nil }
                return (title: title, imageUrl: imageUrl, href: href)
            }
        } catch {
            print("Error parsing AnimeFire: \(error.localizedDescription)")
            return []
        }
    }

    func parseKuramanime(_ document: Document) -> [(title: String, imageUrl: String, href: String)] {
        do {
            let items = try document.select("div#animeList div.col-lg-4")
            return try items.map { item -> (title: String, imageUrl: String, href: String) in
                let title = try item.select("div.product__item__text h5 a").text()
                let imageUrl = try item.select("div.product__item__pic").attr("data-setbg")
                let href = try item.select("div.product__item a").attr("href")
                return (title: title, imageUrl: imageUrl, href: href)
            }
        } catch {
            print("Error parsing Kuramanime: \(error.localizedDescription)")
            return []
        }
    }

    func parseAnime3rb(_ document: Document) -> [(title: String, imageUrl: String, href: String)] {
        do {
            let items = try document.select("section div.my-2")
            return try items.map { item -> (title: String, imageUrl: String, href: String) in
                let title = try item.select("h2.pt-1").text()
                let imageUrl = try item.select("img").attr("src")
                let href = try item.select("a").first()?.attr("href") ?? ""
                return (title: title, imageUrl: imageUrl, href: href)
            }
        } catch {
            print("Error parsing Anime3rb: \(error.localizedDescription)")
            return []
        }
    }

    // Renamed function
    func parseAniList(_ jsonString: String) -> [(title: String, imageUrl: String, href: String)] {
        do {
            guard let jsonData = jsonString.data(using: .utf8) else {
                print("Error converting JSON string to Data")
                return []
            }

            let json = try JSONSerialization.jsonObject(with: jsonData, options: []) as? [String: Any]

            guard let animes = json?["animes"] as? [[String: Any]] else {
                print("Error extracting 'animes' array from JSON")
                return []
            }

            return animes.map { anime -> (title: String, imageUrl: String, href: String) in
                let title = anime["name"] as? String ?? "Unknown Title"
                let imageUrl = anime["poster"] as? String ?? ""
                let href = anime["id"] as? String ?? "" // Use the anime ID (slug) as the href for detail view
                return (title: title, imageUrl: imageUrl, href: href)
            }
        } catch {
            print("Error parsing AniList JSON: \(error.localizedDescription)")
            return []
        }
    }
    func parseAnilibria(_ jsonString: String) -> [(title: String, imageUrl: String, href: String)] {
        guard let jsonData = jsonString.data(using: .utf8) else {
            return []
        }

        do {
            guard let jsonObject = try JSONSerialization.jsonObject(with: jsonData, options: []) as? [String: Any],
                  let list = jsonObject["list"] as? [[String: Any]] else {
                return []
            }

            return list.compactMap { anime -> (title: String, imageUrl: String, href: String)? in
                guard let id = anime["id"] as? Int,
                      let names = anime["names"] as? [String: Any],
                      let posters = anime["posters"] as? [String: Any],
                      let mediumPoster = posters["medium"] as? [String: Any],
                      let imageUrl = mediumPoster["url"] as? String else {
                    return nil
                }

                let title = (names["ru"] as? String) ?? (names["en"] as? String) ?? "Unknown Title"
                let imageURL = "https://anilibria.tv" + imageUrl // Prepend base URL
                let href = String(id) // Use the ID as href for detail view

                return (title: title, imageUrl: imageURL, href: href)
            }
        } catch {
            print("Error parsing Anilibria JSON: \(error.localizedDescription)")
            return []
        }
    }

    func parseAnimeSRBIJA(_ document: Document) -> [(title: String, imageUrl: String, href: String)] {
        do {
            let items = try document.select("div.ani-wrap div.ani-item")
            return try items.map { item -> (title: String, imageUrl: String, href: String) in
                let title = try item.select("h3.ani-title").text()

                let srcset = try item.select("img").attr("srcset")
                let imageUrl = srcset.components(separatedBy: ", ")
                    .last?
                    .components(separatedBy: " ")
                    .first ?? ""

                let imageURL = "https://www.animesrbija.com" + imageUrl // Prepend base URL

                let hrefBase = try item.select("a").first()?.attr("href") ?? ""
                let href = "https://www.animesrbija.com" + hrefBase // Prepend base URL

                return (title: title, imageUrl: imageURL, href: href)
            }
        } catch {
            print("Error parsing AnimeSRBIJA: \(error.localizedDescription)")
            return []
        }
    }

    func parseAniWorld(_ document: Document) -> [(title: String, imageUrl: String, href: String)] {
        // Since AniWorld search requires filtering the full list,
        // the actual filtering should happen *after* parsing the entire list.
        // This function will parse *all* items, and the calling function should filter.
        var results: [(title: String, imageUrl: String, href: String)] = []
        do {
            let genreElements = try document.select("div.genre")
            for genreElement in genreElements {
                let anchorElements = try genreElement.select("a")
                for anchor in anchorElements {
                    let title = try anchor.text()
                    let href = try anchor.attr("href")
                    // Add all results; filtering happens later
                    results.append((
                        title: title,
                        imageUrl: "https://s4.anilist.co/file/anilistcdn/character/large/default.jpg", // Placeholder image
                        href: "https://aniworld.to\(href)" // Prepend base URL
                    ))
                }
            }
        } catch {
            print("Error parsing AniWorld HTML: \(error.localizedDescription)")
        }
        // Return unfiltered list here
        return results
    }


    func parseTokyoInsider(_ document: Document) -> [(title: String, imageUrl: String, href: String)] {
        do {
            let items = try document.select("div#inner_page table[cellpadding='3'] tr")
            return try items.compactMap { item -> (title: String, imageUrl: String, href: String)? in // Use compactMap
                guard let title = try? item.select("a").attr("title"), !title.isEmpty,
                      let imageUrl = try? item.select("img").attr("src"),
                      let hrefBase = try? item.select("a").first()?.attr("href"), !hrefBase.isEmpty else {
                          return nil // Skip if essential info is missing
                      }

                let hrefFull = "https://www.tokyoinsider.com" + hrefBase
                return (title: title, imageUrl: imageUrl, href: hrefFull)
            }
        } catch {
            print("Error parsing TokyoInsider: \(error.localizedDescription)")
            return []
        }
    }

    func parseAniVibe(_ document: Document) -> [(title: String, imageUrl: String, href: String)] {
        do {
            let items = try document.select("div.listupd article")
            return try items.map { item -> (title: String, imageUrl: String, href: String) in
                let title = try item.select("div.tt span").text()

                var imageUrl = try item.select("img").attr("src")
                // Remove size suffix if present (e.g., -110x150)
                imageUrl = imageUrl.replacingOccurrences(of: #"-\d+x\d+(\.\w+)$"#, with: "$1", options: .regularExpression)


                let href = try item.select("a").first()?.attr("href") ?? ""
                let hrefFull = "https://anivibe.net" + href // Prepend base URL
                return (title: title, imageUrl: imageUrl, href: hrefFull)
            }
        } catch {
            print("Error parsing AniVibe: \(error.localizedDescription)")
            return []
        }
    }

    func parseAnimeUnity(_ document: Document) -> [(title: String, imageUrl: String, href: String)] {
        let baseURL = "https://www.animeunity.to/anime/" // Base URL for constructing detail links

        do {
            // Look for the <archivio> tag which holds the JSON data
            let rawHtml = try document.html()

            if let startIndex = rawHtml.range(of: "<archivio")?.upperBound,
               let endIndex = rawHtml.range(of: "</archivio>")?.lowerBound {

                let archivioContent = String(rawHtml[startIndex..<endIndex])

                // Extract the JSON string from the 'records' attribute
                if let recordsStart = archivioContent.range(of: "records=\"")?.upperBound,
                   let recordsEnd = archivioContent[recordsStart...].range(of: "\"")?.lowerBound {

                    // Clean the JSON string (replace HTML entities)
                    let recordsJson = String(archivioContent[recordsStart..<recordsEnd])
                        .replacingOccurrences(of: """, with: "\"") // Correct escaping

                    if let recordsData = recordsJson.data(using: .utf8),
                       let recordsList = try? JSONSerialization.jsonObject(with: recordsData) as? [[String: Any]] {

                        // Map the JSON records to your AnimeItem struct
                        return recordsList.compactMap { record in
                            guard let title = record["title"] as? String, // Or title_eng if preferred
                                  let imageUrl = record["imageurl"] as? String,
                                  let animeID = record["id"] as? Int,
                                  let slug = record["slug"] as? String else {
                                return nil // Skip if essential data is missing
                            }

                            // Construct the detail page URL using the ID and slug
                            let hrefFull = "\(baseURL)\(animeID)-\(slug)"
                            return (title: title, imageUrl: imageUrl, href: hrefFull)
                        }
                    } else {
                        print("Failed to parse JSON records from AnimeUnity")
                    }
                } else {
                    print("Could not find 'records' attribute in <archivio> tag for AnimeUnity")
                }
            } else {
                print("Could not find <archivio> element for AnimeUnity")
            }
            return [] // Return empty if parsing fails at any step
        } catch {
            print("Error parsing AnimeUnity: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - Stub Implementations for Missing Parsers

    func parseAnimeFLV(_ document: Document) -> [(title: String, imageUrl: String, href: String)] {
        print("Warning: parseAnimeFLV called, but using stub implementation.")
        // TODO: Implement actual parsing logic based on AnimeFLV's search results page structure.
        // Example (needs verification):
        // let items = try? document.select("ul.ListAnimes li") ... map items ...
        return [] // Return empty until implemented
    }

    func parseAnimeBalkan(_ document: Document) -> [(title: String, imageUrl: String, href: String)] {
        print("Warning: parseAnimeBalkan called, but using stub implementation.")
        // TODO: Implement actual parsing logic based on AnimeBalkan's search results page structure.
        // Example (needs verification):
        // let items = try? document.select("article.bs") ... map items ...
        return [] // Return empty until implemented
    }

    func parseAniBunker(_ document: Document) -> [(title: String, imageUrl: String, href: String)] {
        print("Warning: parseAniBunker called, but using stub implementation.")
        // TODO: Implement actual parsing logic based on AniBunker's search results page structure.
        // Example (needs verification):
        // let items = try? document.select("div.section--body article") ... map items ...
        return [] // Return empty until implemented
    }
}
