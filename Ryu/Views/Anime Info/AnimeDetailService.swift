import UIKit
import Alamofire // Ensure Alamofire is imported
import SwiftSoup

// Keep AnimeDetail struct definition
struct AnimeDetail {
    let aliases: String
    let synopsis: String
    let airdate: String
    let stars: String
    let episodes: [Episode] // Uses Ryu's Episode struct
}


class AnimeDetailService {
    // Use the proxy session creator
    static let session = proxySession.createAlamofireProxySession()

    static func fetchAnimeDetails(from href: String, completion: @escaping (Result<AnimeDetail, Error>) -> Void) {
        guard let selectedSource = UserDefaults.standard.selectedMediaSource else {
            completion(.failure(NSError(domain: "AnimeDetailService", code: -1, userInfo: [NSLocalizedDescriptionKey: "No media source selected."])))
            return
        }

        // --- Source-Specific Handling ---
        if selectedSource == .anilibria {
            fetchAnilibriaDetails(href: href, completion: completion)
        } else if selectedSource == .hianime {
             // Use the HiAnimeSource class method
             let hiAnimeSource = HiAnimeSource()
             hiAnimeSource.getAnimeDetails(id: href) { result in // 'href' is the anime ID for HiAnime
                  switch result {
                  case .success(let hiAnimeDetails):
                       // Map HiAnimeDetails to AnimeDetail
                       let mappedEpisodes = hiAnimeDetails.episodes.map { ep -> Episode in
                            // Construct the href needed for fetching sources later
                             let sourcesHref = "/watch/\(hiAnimeDetails.id)?ep=\(ep.id)" // Format expected by episodeSelected
                            return Episode(number: ep.number, href: sourcesHref, downloadUrl: "") // downloadUrl is empty for HiAnime
                       }
                       let details = AnimeDetail(
                            aliases: "", // May need to parse aliases separately if available elsewhere
                            synopsis: hiAnimeDetails.description,
                            airdate: hiAnimeDetails.year,
                            stars: hiAnimeDetails.rating,
                            episodes: mappedEpisodes
                       )
                       completion(.success(details))
                  case .failure(let error):
                       completion(.failure(error))
                  }
             }
        } else {
            // --- Generic HTML Fetching for other sources ---
            fetchGenericDetails(selectedSource: selectedSource, href: href, completion: completion)
        }
    }

    // --- Helper for Anilibria API Fetching ---
    private static func fetchAnilibriaDetails(href: String, completion: @escaping (Result<AnimeDetail, Error>) -> Void) {
        let baseUrl = "https://api.anilibria.tv/v3/title?id="
        let fullUrl: String

        // Extract ID if href is a direct media link (handle potential variations)
        if href.contains("cache.libria.fun") {
            let components = href.components(separatedBy: "/")
            if let tsIndex = components.firstIndex(of: "ts"), tsIndex + 1 < components.count {
                 let idPart = components[tsIndex + 1]
                 // More robustly extract the first sequence of digits as the ID
                  if let extractedId = idPart.components(separatedBy: CharacterSet.decimalDigits.inverted).first(where: { !$0.isEmpty }) {
                       fullUrl = baseUrl + extractedId
                       print("Extracted Anilibria ID: \(extractedId) from href: \(href)")
                  } else {
                       print("Could not extract Anilibria ID from media link: \(href)")
                       completion(.failure(NSError(domain: "Anilibria", code: -2, userInfo: [NSLocalizedDescriptionKey: "Could not determine Anilibria ID from link."])))
                       return
                  }
            } else {
                 print("Could not determine Anilibria ID structure from media link: \(href)")
                 completion(.failure(NSError(domain: "Anilibria", code: -3, userInfo: [NSLocalizedDescriptionKey: "Could not determine Anilibria ID from link."])))
                 return
            }
       } else {
            // Assume href is already the ID
            fullUrl = baseUrl + href
       }


        guard let url = URL(string: fullUrl) else {
             completion(.failure(NSError(domain: "Anilibria", code: -4, userInfo: [NSLocalizedDescriptionKey: "Invalid Anilibria API URL."])))
             return
        }


        session.request(url).responseDecodable(of: AnilibriaResponse.self) { response in
            switch response.result {
            case .success(let anilibriaResponse):
                let aliases = anilibriaResponse.names.en
                let synopsis = anilibriaResponse.description
                let airdate = "\(anilibriaResponse.season.year) \(anilibriaResponse.season.string)"
                let stars = String(anilibriaResponse.inFavorites) // Using favorites count as "stars"

                let episodes = anilibriaResponse.player.list.map { (key, value) -> Episode in
                    let episodeNumber = key
                    // Prioritize FHD, then HD, then SD
                    let selectedUrl = value.hls.fhd ?? value.hls.hd ?? value.hls.sd ?? ""
                    // Prepend base URL for cache server
                    let fullMediaUrl = selectedUrl.isEmpty ? "" : "https://cache.libria.fun\(selectedUrl)"
                    return Episode(number: episodeNumber, href: fullMediaUrl, downloadUrl: "") // downloadUrl not applicable
                }.sorted { Int($0.number) ?? 0 < Int($1.number) ?? 0 } // Sort numerically

                let details = AnimeDetail(aliases: aliases, synopsis: synopsis, airdate: airdate, stars: stars, episodes: episodes)
                completion(.success(details))

            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    // --- Helper for Generic HTML Fetching ---
    private static func fetchGenericDetails(selectedSource: MediaSource, href: String, completion: @escaping (Result<AnimeDetail, Error>) -> Void) {
        let baseUrls: [String] // Use array to potentially handle multiple domains per source
         switch selectedSource {
         case .animeWorld: baseUrls = ["https://www.animeworld.so"] // Ensure www if needed
         case .gogoanime: baseUrls = ["https://anitaku.bz"]
         case .animeheaven: baseUrls = ["https://animeheaven.me/"]
         case .animefire: baseUrls = ["https://animefire.plus"]
         case .kuramanime: baseUrls = ["https://kuramanime.red"]
         case .anime3rb: baseUrls = [""] // Assume absolute URLs or handle differently
         case .animesrbija: baseUrls = ["https://www.animesrbija.com"]
         case .aniworld: baseUrls = ["https://aniworld.to"]
         case .tokyoinsider: baseUrls = ["https://www.tokyoinsider.com"]
         case .anivibe: baseUrls = ["https://anivibe.net"]
         case .animeunity: baseUrls = ["https://www.animeunity.to"]
         case .animeflv: baseUrls = ["https://www3.animeflv.net"]
         case .animebalkan: baseUrls = ["https://animebalkan.gg"] // Use .gg domain
         case .anibunker: baseUrls = ["https://www.anibunker.com"]
         case .hianime, .anilibria: // Should not reach here, but handle defensively
             completion(.failure(NSError(domain: "AnimeDetailService", code: -5, userInfo: [NSLocalizedDescriptionKey: "Internal error: Generic fetch called for API source."])))
             return
         }

        // Construct full URL, handling relative vs absolute href
        let fullUrlString: String
         if href.starts(with: "http") {
              fullUrlString = href // href is already absolute
         } else if let baseUrl = baseUrls.first, !baseUrl.isEmpty {
              // Ensure no double slashes if href starts with /
              let path = href.starts(with: "/") ? href : "/\(href)"
              fullUrlString = baseUrl + path
         } else if !baseUrls.isEmpty && baseUrls.first == "" {
              // Handle sources where href is expected to be absolute even if baseUrl is empty
              fullUrlString = href
         } else {
              print("Error: Cannot construct full URL for source \(selectedSource.rawValue) with href \(href)")
              completion(.failure(NSError(domain: "AnimeDetailService", code: -6, userInfo: [NSLocalizedDescriptionKey: "Cannot construct URL."])))
              return
         }


        guard let url = URL(string: fullUrlString) else {
            completion(.failure(NSError(domain: "AnimeDetailService", code: -7, userInfo: [NSLocalizedDescriptionKey: "Invalid constructed URL: \(fullUrlString)"])))
            return
        }
        
        print("Fetching details from: \(url.absoluteString)")


        session.request(url).responseString { response in
            switch response.result {
            case .success(let html):
                do {
                    let document = try SwiftSoup.parse(html)
                    var aliases = ""
                    var synopsis = ""
                    var airdate = "N/A"
                    var stars = "N/A"
                    var episodes: [Episode] = []

                    // --- Source-Specific Parsing Logic ---
                    switch selectedSource {
                    case .animeWorld:
                        aliases = try document.select("div.widget-title h1").attr("data-jtitle")
                        synopsis = try document.select("div.info div.desc").text()
                        airdate = try document.select("div.row dl.meta dt:contains(Data di Uscita) + dd").first()?.text() ?? "N/A"
                        stars = try document.select("dd.rating span").text()
                    case .gogoanime:
                         aliases = try document.select("div.anime_info_body_bg p.other-name a").text()
                         synopsis = try document.select("div.anime_info_body_bg p:contains(Plot Summary:)").first()?.textNodes().first?.text().trimmingCharacters(in: .whitespacesAndNewlines) ?? (try document.select("div.anime_info_body_bg div.description").text()) // Get text after "Plot Summary:" or fallback
                         airdate = try document.select("p.type:contains(Released:) span").last()?.text() ?? "N/A" // Get text within span
                         stars = "N/A" // Gogo doesn't usually show rating on this page
                    case .animeheaven:
                         aliases = try document.select("div.infodiv div.infotitlejp").text()
                         synopsis = try document.select("div.infodiv div.infodes").text()
                         airdate = try document.select("div.infoyear div.c2").eq(1).text() // Second div.c2 for year
                         stars = try document.select("div.infoyear div.c2").last()?.text() ?? "N/A" // Last div.c2 for rating
                    case .animefire:
                         aliases = try document.select("div.film-stats span:contains(Alternativo) + span").text() // Find span after 'Alternativo'
                         synopsis = try document.select("div.divSinopse span.spanAnimeInfo").text()
                         airdate = try document.select("div.divAnimePageInfo div.animeInfo span.spanAnimeInfo").last()?.text() ?? "N/A"
                         stars = try document.select("div.div_anime_score h4.text-white").text()
                    case .kuramanime:
                         aliases = try document.select("div.anime__details__title span").last()?.text() ?? ""
                         synopsis = try document.select("div.anime__details__text p").text()
                         airdate = try document.select("div.anime__details__widget ul li:contains(Rilis)").first()?.text().replacingOccurrences(of: "Rilis:", with: "").trimmingCharacters(in: .whitespacesAndNewlines) ?? "N/A"
                         stars = try document.select("div.anime__details__widget div.row div.col-lg-6 ul li:contains(Skor)").first()?.text().replacingOccurrences(of: "Skor:", with: "").trimmingCharacters(in: .whitespacesAndNewlines) ?? "N/A"
                    case .anime3rb:
                         // Anime3rb detail pages might vary, adjust selectors as needed
                         aliases = "" // Often no separate alias field shown prominently
                         synopsis = try document.select("p.leading-loose").first()?.text() ?? "No synopsis found." // Common paragraph style
                         airdate = try document.select("td:contains(تاريخ الإصدار) + td").first()?.text() ?? "N/A" // Date row
                         stars = try document.select("div.inline-flex span.ml-1").first()?.text() ?? "N/A" // Rating often near title
                    case .animesrbija:
                          aliases = try document.select("h3.anime-eng-name").text()
                          let rawSynopsis = try document.select("div.anime-description").text()
                          synopsis = rawSynopsis.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                          airdate = try document.select("div.anime-information-col div:contains(Datum:)").first()?.text().replacingOccurrences(of: "Datum:", with: "").trimmingCharacters(in: .whitespaces) ?? "N/A"
                          stars = try document.select("div.anime-information-col div:contains(MAL Ocena:)").first()?.text().replacingOccurrences(of: "MAL Ocena:", with: "").trimmingCharacters(in: .whitespaces) ?? "N/A"
                    case .aniworld:
                         aliases = "" // Often not displayed separately
                         synopsis = try document.select("p.seri_des").text()
                         // Airdate and rating might be harder to parse reliably, use N/A or inspect further
                         airdate = "N/A"
                         stars = "N/A"
                    case .tokyoinsider:
                          aliases = try document.select("tr:contains(Alternative title:) td:nth-child(2)").text() // Get text from second td in that row
                          synopsis = try document.select("tr:contains(Plot Summary:) td").text() // Get text from td in that row
                          airdate = try document.select("tr:contains(Vintage:) td:nth-child(2)").text() // Get text from second td
                          stars = try document.select("tr:contains(Rating:) td:nth-child(2)").text().components(separatedBy: "(").first?.trimmingCharacters(in: .whitespaces) ?? "N/A" // Extract numerical rating
                    case .anivibe:
                          aliases = try document.select("span.alter").text()
                          synopsis = try document.select("div.synp div.entry-content").text()
                          // Extract date and rating from the info block if possible
                           let infoText = try document.select("div.split").text() // Combine info lines
                           airdate = extractDetail(from: infoText, pattern: #"Released:\s*(\d{4})"#) ?? "N/A"
                           stars = "N/A" // Rating often not present or hard to parse consistently
                    case .animeunity:
                          aliases = try document.select("div.title-eng").text() // English title as alias
                          synopsis = try document.select("div.description").text()
                          airdate = try document.select("div.row > div:contains(Data)").first()?.textNodes().last?.text().trimmingCharacters(in: .whitespacesAndNewlines) ?? "N/A"
                          stars = try document.select("div.row > div:contains(Voto)").first()?.textNodes().last?.text().trimmingCharacters(in: .whitespacesAndNewlines) ?? "N/A"
                    case .animeflv:
                           aliases = try document.select("span.TxtAlt").text()
                           synopsis = try document.select("div.Description p").text()
                           airdate = try document.select("span.Date").text() // Get release date if available
                           stars = try document.select("span.vts").first()?.text() ?? "N/A" // Rating
                    case .animebalkan:
                           aliases = "" // Often no separate alias
                           synopsis = try document.select("div.entry-content p").first()?.text() ?? "No synopsis available."
                           airdate = try document.select("div.spe span:contains(Godina:)").first()?.parent()?.text().replacingOccurrences(of: "Godina:", with: "").trimmingCharacters(in: .whitespaces) ?? "N/A"
                           stars = try document.select("div.rating strong").text().replacingOccurrences(of: "Rating ", with: "") ?? "N/A"
                    case .anibunker:
                           aliases = ""
                           synopsis = try document.select("div.sinopse--display p").text()
                           airdate = try document.select("div.field-info:contains(Ano:)").first()?.text().replacingOccurrences(of: "Ano:", with: "").trimmingCharacters(in: .whitespaces) ?? "N/A"
                           stars = try document.select("div.rating-wrap div.rating-score").text() ?? "N/A"

                    case .hianime, .anilibria: break // Should not be handled here
                    }

                    // Fetch episodes using the source-specific logic
                    episodes = self.fetchEpisodes(document: document, for: selectedSource, href: href)

                    // Construct the AnimeDetail object
                    let details = AnimeDetail(aliases: aliases, synopsis: synopsis, airdate: airdate, stars: stars, episodes: episodes)
                    completion(.success(details))

                } catch {
                    completion(.failure(error))
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    // --- Episode Fetching Logic (Moved from AnimeDetailService) ---
    // Keep this function to handle episode list parsing for HTML sources
    private static func fetchEpisodes(document: Document, for source: MediaSource, href: String) -> [Episode] {
         var episodes: [Episode] = []
         do {
             var episodeElements: Elements
             let baseURL = href // Base URL might be needed for relative paths

             switch source {
             case .animeWorld:
                  episodeElements = try document.select("div.server.active[data-name='AW Server'] ul.episodes li.episode a") // More specific selector
             case .gogoanime:
                 // GoGoAnime episode numbers are derived, not directly listed per episode link here
                 episodeElements = try document.select("ul#episode_page a") // Get range elements
                 return episodeElements.flatMap { element -> [Episode] in // Use flatMap
                     guard let startStr = try? element.attr("ep_start"),
                           let endStr = try? element.attr("ep_end"),
                           let start = Int(startStr),
                           let end = Int(endStr) else { return [] }

                     let validStart = min(start, end)
                     let validEnd = max(start, end)

                     // Construct the base href for the anime category
                      let categoryHref: String
                      if let firstLink = try? document.select("div.anime_info_body_bg p.type a").first?.attr("href"), firstLink.contains("/genre/") {
                           // If we can find a genre link, assume the category path is similar
                            // This is fragile; needs verification on GoGoAnime's structure
                            let components = href.split(separator: "/")
                            if components.count >= 2 && components[0] == "category" {
                                 categoryHref = "/category/\(components[1])"
                            } else {
                                 // Fallback or error if category path cannot be determined
                                  print("Warning: Could not determine GoGoAnime category path from href: \(href)")
                                  categoryHref = href // Use original href as fallback (might be wrong)
                            }
                      } else {
                           // Fallback if no genre link found
                           print("Warning: Could not determine GoGoAnime category path from genre links.")
                            categoryHref = href // Use original href as fallback
                      }


                     return (validStart...validEnd).compactMap { episodeNumber in
                         let formattedEpisode = "\(episodeNumber)"
                         guard formattedEpisode != "0" else { return nil }
                          // Construct episode href relative to base URL or use absolute path if possible
                          let episodeHref = "\(categoryHref)-episode-\(episodeNumber)" // Construct the episode link pattern
                          let fullhref = "https://anitaku.bz" + episodeHref // Ensure absolute URL
                         print("Constructed GoGo URL: \(fullhref)")
                         return Episode(number: formattedEpisode, href: fullhref, downloadUrl: "")
                     }
                 }

             case .animeheaven:
                 episodeElements = try document.select("div.infoepbox > div > a") // Selector for episode links
             case .animefire:
                 episodeElements = try document.select("div.div_video_list a")
             case .kuramanime:
                  // Kuramanime episodes might be loaded via JS, check if they are in the initial HTML
                   // If they are within a script or need separate fetching, this needs adjustment.
                    // Assuming they might be in a list initially:
                    episodeElements = try document.select("div#episodeLists a.btn") // Example selector, adjust as needed
             case .anime3rb:
                  episodeElements = try document.select("div.eps-list a.episode-link") // More specific selector
             case .animesrbija:
                  episodeElements = try document.select("ul.anime-episodes-holder li.anime-episode-item a")
             case .aniworld:
                 // AniWorld needs multi-step season fetching, handle separately
                  return fetchAniWorldEpisodesFromDetail(document: document, baseURL: baseURL) // Call helper
             case .tokyoinsider:
                  episodeElements = try document.select("div.episode a.download-link[href*='/episode/']") // Select only episode links
             case .anivibe:
                  episodeElements = try document.select("div.eplister ul li a")
             case .animeunity:
                  // AnimeUnity episodes are embedded in JSON within a tag, requires special parsing
                   return parseAnimeUnityEpisodes(from: document, baseURL: baseURL) // Call helper
             case .animeflv:
                  // AnimeFLV episodes are often in JavaScript, requires special parsing
                   return parseAnimeFLVEpisodes(from: document, baseURL: baseURL) // Call helper
             case .animebalkan:
                 episodeElements = try document.select("div.eplister ul li a")
             case .anibunker:
                 episodeElements = try document.select("div.eps-display a")
             case .hianime, .anilibria: // Should already be handled
                 return []
             }

             // --- Generic Episode Parsing Logic (for sources using standard lists) ---
             episodes = try episodeElements.compactMap { element -> Episode? in
                 let href = try element.attr("href")
                 var number: String = ""
                 var downloadUrl = "" // Assume empty initially

                  // Extract episode number - this varies greatly between sources
                   switch source {
                   case .animeWorld: number = try element.text().replacingOccurrences(of: "Ep. ", with: "")
                   case .animeheaven: number = try element.text().replacingOccurrences(of: "Episode ", with: "") // Example text format
                   case .animefire: number = try element.text().replacingOccurrences(of: "Episódio ", with: "")
                   case .kuramanime: number = try element.text().replacingOccurrences(of: "Ep ", with: "")
                   case .anime3rb: number = try element.select("span").first()?.text().replacingOccurrences(of: "الحلقة ", with: "") ?? ""
                   case .animesrbija: number = try element.select("span.ep-num").text().replacingOccurrences(of: "Epizoda ", with: "")
                   case .tokyoinsider: number = try element.select("strong").text() // Number might be inside strong tag
                   case .anivibe: number = try element.select("div.epl-num").text()
                   case .animebalkan: number = try element.select("div.epl-num").text()
                   case .anibunker: number = try element.select("div.ep_number").text()
                       // Add cases for other sources or refine existing ones
                   default: number = try element.text() // Generic fallback
                   }


                 guard !href.isEmpty, !number.isEmpty, Int(number) != nil || number.lowercased().contains("film") || number.lowercased().contains("ova") else {
                       // print("Skipping invalid episode: Number='\(number)', Href='\(href)' for source \(source.rawValue)")
                       return nil // Skip if essential data is missing or number isn't valid
                   }

                 // Construct full href if needed
                 let fullHref: String
                  if href.starts(with: "http") {
                       fullHref = href
                  } else {
                       // Determine the correct base URL for the source
                        let sourceBaseUrl: String
                        switch source {
                         case .animeWorld: sourceBaseUrl = "https://www.animeworld.so"
                         case .gogoanime: sourceBaseUrl = "https://anitaku.bz" // Handled above, but as example
                         case .animeheaven: sourceBaseUrl = "https://animeheaven.me"
                         case .animefire: sourceBaseUrl = "https://animefire.plus"
                         case .kuramanime: sourceBaseUrl = "https://kuramanime.red"
                         case .anime3rb: sourceBaseUrl = "" // Assume absolute
                         case .animesrbija: sourceBaseUrl = "https://www.animesrbija.com"
                         case .aniworld: sourceBaseUrl = "https://aniworld.to"
                         case .tokyoinsider: sourceBaseUrl = "https://www.tokyoinsider.com"
                         case .anivibe: sourceBaseUrl = "https://anivibe.net"
                         case .animeunity: sourceBaseUrl = "https://www.animeunity.to"
                         case .animeflv: sourceBaseUrl = "https://www3.animeflv.net"
                         case .animebalkan: sourceBaseUrl = "https://animebalkan.gg"
                         case .anibunker: sourceBaseUrl = "https://www.anibunker.com"
                         default: sourceBaseUrl = ""
                        }
                       fullHref = sourceBaseUrl + (href.starts(with: "/") ? href : "/\(href)")
                  }


                 return Episode(number: number, href: fullHref, downloadUrl: downloadUrl)
             }

         } catch {
             print("Error parsing episodes for \(source.rawValue): \(error.localizedDescription)")
         }
         return episodes
     }
    
     // --- Helper function to extract AniWorld seasons and fetch their episodes ---
      private static func fetchAniWorldEpisodesFromDetail(document: Document, baseURL: String) -> [Episode] {
           var allEpisodes: [Episode] = []
           do {
                // 1. Extract Season Links from the main page
                let seasonLinks = try document.select("div.hosterSiteDirectNav ul li a") // Selector for season tabs

                // 2. Fetch episodes for each season concurrently
                 let group = DispatchGroup()
                 let queue = DispatchQueue(label: "com.ryu.aniworld-season-fetch", attributes: .concurrent)
                 let syncQueue = DispatchQueue(label: "com.ryu.aniworld-episode-sync") // For thread-safe array appending

                 for link in seasonLinks {
                      guard let seasonHref = try? link.attr("href"),
                            let seasonTitle = try? link.attr("title") else { continue }

                     let fullSeasonUrl = "https://aniworld.to" + seasonHref // Construct full URL

                      // Extract season number (e.g., "S1", "S2", "F" for Film)
                      let seasonNumber: String
                      if seasonTitle.contains("Filme") {
                           seasonNumber = "F" // Use "F" for movies/films
                      } else if let num = seasonTitle.components(separatedBy: " ").last, Int(num) != nil {
                           seasonNumber = "S\(num)"
                      } else {
                           seasonNumber = "S1" // Default to S1 if number extraction fails
                      }

                      group.enter()
                      queue.async {
                           if let seasonEpisodes = try? fetchAniWorldSeasonEpisodes(seasonUrl: fullSeasonUrl, seasonNumber: seasonNumber) {
                                syncQueue.async {
                                     allEpisodes.append(contentsOf: seasonEpisodes)
                                     group.leave()
                                }
                           } else {
                                print("Failed to fetch episodes for season: \(seasonTitle)")
                                group.leave()
                           }
                      }
                 }

                // 3. Wait for all season fetches to complete
                group.wait() // Wait synchronously

                // 4. Sort all collected episodes
                 allEpisodes.sort { ep1, ep2 in
                      // Custom sort: Films first (F), then seasons (S1, S2...), then episodes numerically
                       let s1 = ep1.number.starts(with: "F") ? -1 : (Int(ep1.number.filter("0123456789".contains).prefix(while: { $0 != "E" })) ?? 0)
                       let s2 = ep2.number.starts(with: "F") ? -1 : (Int(ep2.number.filter("0123456789".contains).prefix(while: { $0 != "E" })) ?? 0)
                       let e1 = Int(ep1.number.split(separator: "E").last ?? "0") ?? 0
                       let e2 = Int(ep2.number.split(separator: "E").last ?? "0") ?? 0

                      if s1 != s2 {
                           return s1 < s2
                      } else {
                           return e1 < e2
                      }
                 }
                return allEpisodes.uniqued(by: \.number) // Ensure uniqueness by episode number


           } catch {
                print("Error parsing AniWorld initial detail page: \(error)")
                return []
           }
      }


     // --- Helper specifically for fetching episodes from an AniWorld SEASON page ---
      private static func fetchAniWorldSeasonEpisodes(seasonUrl: String, seasonNumber: String) throws -> [Episode] {
          guard let url = URL(string: seasonUrl) else { throw URLError(.badURL) }

           // Use synchronous fetch within the background queue of the caller
           // Or adapt this to be async if needed elsewhere
            let (data, _, error) = URLSession.shared.syncRequest(with: URLRequest(url: url)) // Assumes syncRequest extension exists

           if let error = error { throw error }
           guard let htmlData = data, let html = String(data: htmlData, encoding: .utf8) else { throw URLError(.cannotDecodeContentData) }

          let document = try SwiftSoup.parse(html)
          let episodeRows = try document.select("table.seasonEpisodesList tbody tr") // Target table rows

          return try episodeRows.compactMap { row -> Episode? in
              // Extract episode number from the first 'td'
               guard let numberElement = try row.select("td").first(),
                     let episodeNumberStr = try? numberElement.text(),
                     let episodeNumber = Int(episodeNumberStr), // Ensure it's a number
                     let linkElement = try row.select("a").first() else { // Link is usually in the second 'td' within 'a'
                    return nil
               }

              let episodeHref = try linkElement.attr("href")
              let fullEpisodeHref = "https://aniworld.to" + episodeHref

               // Format episode number like S1E01, S1E02 etc.
                let formattedEpisodeNumber = String(format: "%@E%02d", seasonNumber, episodeNumber) // Pad with leading zero


              return Episode(number: formattedEpisodeNumber, href: fullEpisodeHref, downloadUrl: "")
          }
          // Sorting is done after collecting all episodes from all seasons
      }

    // --- Helper for AnimeUnity Episode Parsing ---
    private static func parseAnimeUnityEpisodes(from document: Document, baseURL: String) -> [Episode] {
        var episodes: [Episode] = []
         do {
              let rawHtml = try document.html()
              // Find the video-player tag and extract the episodes JSON string
               if let startIndex = rawHtml.range(of: "<video-player")?.upperBound,
                  let endIndex = rawHtml.range(of: "</video-player>")?.lowerBound {
                    let videoPlayerTagContent = String(rawHtml[startIndex..<endIndex])
                    // Extract the content of the episodes attribute
                     if let episodesStart = videoPlayerTagContent.range(of: "episodes=\"")?.upperBound,
                        let episodesEnd = videoPlayerTagContent[episodesStart...].range(of: "\"")?.lowerBound {
                          let episodesJsonString = String(videoPlayerTagContent[episodesStart..<episodesEnd])
                                                 .replacingOccurrences(of: """, with: "\"") // Decode HTML entities

                         if let episodesData = episodesJsonString.data(using: .utf8),
                            let episodesList = try? JSONSerialization.jsonObject(with: episodesData) as? [[String: Any]] {

                              episodes = episodesList.compactMap { episodeDict in
                                   guard let numberString = episodeDict["number"] as? String, // Number is often a string
                                         let link = episodeDict["link"] as? String else {
                                        print("AnimeUnity: Skipping episode due to missing number or link: \(episodeDict)")
                                        return nil
                                   }

                                   // Construct the full URL if link is relative
                                    let fullHref: String
                                    if link.starts(with: "http") {
                                         fullHref = link
                                    } else {
                                         // AnimeUnity links seem absolute now, but handle relative just in case
                                          fullHref = baseURL + (link.starts(with: "/") ? link : "/\(link)")
                                    }


                                   return Episode(number: numberString, href: fullHref, downloadUrl: "")
                              }
                         } else {
                              print("AnimeUnity: Failed to parse episodes JSON string: \(episodesJsonString)")
                         }
                    } else {
                         print("AnimeUnity: Could not find episodes attribute in video-player tag.")
                    }
               } else {
                    print("AnimeUnity: Could not find video-player tag.")
               }
         } catch {
              print("Error parsing AnimeUnity episodes: \(error)")
         }
        return episodes
    }


    // --- Helper for AnimeFLV Episode Parsing ---
     private static func parseAnimeFLVEpisodes(from document: Document, baseURL: String) -> [Episode] {
         var episodes: [Episode] = []
         do {
             let scripts = try document.select("script")
             var episodeNumbers: [Int] = []
             var animeInfoJsonString: String? = nil

             for script in scripts {
                 let scriptContent = try script.html()
                  // Pattern 1: Extracting from 'var episodes = [[num, id], ...];'
                  let epPattern1 = #"var episodes\s*=\s*(\[\[\d+,\s*\d+\](?:,\s*\[\d+,\s*\d+\])*\]);"#
                  if let regex = try? NSRegularExpression(pattern: epPattern1),
                     let match = regex.firstMatch(in: scriptContent, range: NSRange(scriptContent.startIndex..., in: scriptContent)),
                     let range = Range(match.range(at: 1), in: scriptContent) {
                       let episodesArrayString = String(scriptContent[range])
                       if let data = episodesArrayString.data(using: .utf8),
                          let epArray = try? JSONSerialization.jsonObject(with: data) as? [[Int]] {
                            episodeNumbers = epArray.map { $0[0] }.sorted() // Get the first element (episode number)
                            break // Found the primary episode list
                       }
                  }

                 // Pattern 2: Extracting from 'var anime_info = {...};' (less common for full list, might contain last ep num)
                  let infoPattern = #"var anime_info\s*=\s*(\{.*?\});"# // Capture the JSON object
                  if let regex = try? NSRegularExpression(pattern: infoPattern),
                     let match = regex.firstMatch(in: scriptContent, range: NSRange(scriptContent.startIndex..., in: scriptContent)),
                     let range = Range(match.range(at: 1), in: scriptContent) {
                       animeInfoJsonString = String(scriptContent[range])
                  }
             }

             // If pattern 1 failed, try extracting max episode number from anime_info
             if episodeNumbers.isEmpty, let jsonString = animeInfoJsonString {
                 if let data = jsonString.data(using: .utf8),
                    let infoJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                    let lastEpisodeString = infoJson["last_episode"] as? String, // Or check "total_episodes" etc.
                    let lastEpisode = Int(lastEpisodeString) {
                      episodeNumbers = Array(1...lastEpisode) // Generate sequence if only last number is known
                 } else if let data = jsonString.data(using: .utf8), // Alternative structure check
                             let infoJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                             let lastEpisodeNum = infoJson["lastEpisode"] as? Int { // Check for camelCase key
                     episodeNumbers = Array(1...lastEpisodeNum)
                 }
             }


             if episodeNumbers.isEmpty {
                  print("AnimeFLV: Could not extract episode numbers from scripts.")
                  return []
             }

             // Construct episode URLs based on the anime's base URL (href)
              let animeBaseHref = baseURL.replacingOccurrences(of: "/anime/", with: "/ver/") // Base for episode links

             for number in episodeNumbers {
                 let episodeHref = "\(animeBaseHref)-\(number)"
                 episodes.append(Episode(number: String(number), href: episodeHref, downloadUrl: ""))
             }

         } catch {
             print("Error parsing AnimeFLV episodes: \(error)")
         }
         return episodes
     }
    
    // Helper to extract detail using regex - useful for varied structures like AniVibe
    private static func extractDetail(from text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

}
