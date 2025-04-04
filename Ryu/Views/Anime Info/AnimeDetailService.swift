import UIKit
import Alamofire
import SwiftSoup

struct AnimeDetail {
    let aliases: String
    let synopsis: String
    let airdate: String
    let stars: String
    let episodes: [Episode]
}

class AnimeDetailService {
    static let session = proxySession.createAlamofireProxySession()

    static func fetchAnimeDetails(from href: String, completion: @escaping (Result<AnimeDetail, Error>) -> Void) {
        guard let selectedSource = UserDefaults.standard.selectedMediaSource else {
            completion(.failure(NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "No media source selected."])))
            return
        }

        // Base URL mapping (Adjust or make more robust if needed)
        let baseUrls: [MediaSource: String] = [
            .animeWorld: "https://animeworld.so",
            .gogoanime: "https://anitaku.bz", // Or other potential domains
            .animeheaven: "https://animeheaven.me/",
            .anilist: "https://aniwatch-api-gp1w.onrender.com/anime/info?id=", // API endpoint
            .anilibria: "https://api.anilibria.tv/v3/title?id=", // API endpoint
            .animefire: "https://animefire.plus/",
            .kuramanime: "https://kuramanime.red", // Use base URL, search/list page might be needed for initial discovery
            .anime3rb: "https://anime3rb.com", // Use base URL
            .animesrbija: "https://www.animesrbija.com", // Use base URL
            .aniworld: "https://aniworld.to", // Use base URL
            .tokyoinsider: "https://www.tokyoinsider.com", // Use base URL
            .anivibe: "https://anivibe.net", // Use base URL
            .animeunity: "https://www.animeunity.to", // Use base URL
            .animeflv: "https://www3.animeflv.net", // Use base URL
            .animebalkan: "https://animebalkan.org", // Use base URL
            .anibunker: "https://www.anibunker.com" // Use base URL
        ]

        let baseUrl = baseUrls[selectedSource] ?? "" // Default to empty if not mapped
        var fullUrlString: String

        // Source-specific URL construction
        switch selectedSource {
        case .anilibria:
            // Extract ID if it's a specific cache URL
            if href.hasPrefix("https://cache.libria.fun/videos/media/ts/") {
                let components = href.components(separatedBy: "/")
                if let tsIndex = components.firstIndex(of: "ts"),
                   tsIndex + 1 < components.count {
                    // Extract only digits for the ID
                    let extractedId = components[tsIndex + 1].components(separatedBy: CharacterSet.decimalDigits.inverted).joined() // Fixed conditional binding
                    if !extractedId.isEmpty {
                         fullUrlString = baseUrl + extractedId
                    } else {
                         completion(.failure(NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "Could not extract Anilibria ID (empty after filtering)."])))
                         return
                    }
                } else {
                    completion(.failure(NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "Could not extract Anilibria ID."])))
                    return
                }
            } else if let _ = Int(href) { // If href is already just the ID
                fullUrlString = baseUrl + href
            } else {
                // If href is a full URL to the release page, we might need to fetch it first to get the ID
                // For now, assuming only ID-based fetching is supported for details API
                completion(.failure(NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unsupported Anilibria URL format for details API."])))
                return
            }
        case .anilist:
            // Extract ID for API call
            // Example ID format: steinsgate-3
            func extractIdentifier(from fullUrl: String) -> String? {
                if let watchRange = fullUrl.range(of: "/watch/") {
                    let potentialIdPart = String(fullUrl[watchRange.upperBound...])
                    // The ID is the part before the first '?'
                    return String(potentialIdPart.split(separator: "?")[0])
                }
                // Handle case where URL might be like /anime/steinsgate-3
                if let animeRange = fullUrl.range(of: "/anime/") {
                     let potentialIdPart = String(fullUrl[animeRange.upperBound...])
                     return potentialIdPart // Assume the rest is the ID
                 }

                // Check if href itself looks like an ID (no slashes, maybe contains '-')
                if !fullUrl.contains("/") && fullUrl.contains("-") {
                     return fullUrl
                 }

                return nil
            }

            if let identifier = extractIdentifier(from: href) {
                fullUrlString = baseUrl + identifier
            } else if !href.contains("/") { // Assume href is just the ID if no slashes
                fullUrlString = baseUrl + href
            }
             else {
                 completion(.failure(NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid AniList URL format."])))
                 return
             }

        default:
            // Default construction for most HTML sources
            if !baseUrl.isEmpty && !href.hasPrefix("http") {
                 fullUrlString = baseUrl + (href.hasPrefix("/") ? href : "/\(href)")
             } else {
                 fullUrlString = href // Assume href is already a full URL
             }
        }

        guard let fullUrl = URL(string: fullUrlString) else {
            completion(.failure(NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid final URL constructed: \(fullUrlString)"])))
            return
        }

        print("Fetching details from: \(fullUrl.absoluteString) for source: \(selectedSource.rawValue)")

        // --- Data Fetching and Parsing ---
        if selectedSource == .anilibria {
            session.request(fullUrl).responseDecodable(of: AnilibriaResponse.self) { response in
                switch response.result {
                case .success(let anilibriaResponse):
                    let aliases = anilibriaResponse.names.en
                    let synopsis = anilibriaResponse.description
                    let airdate = "\(anilibriaResponse.season.year) \(anilibriaResponse.season.string)"
                    let stars = String(anilibriaResponse.inFavorites) // Using favorites count as 'stars' for consistency

                    let episodes = anilibriaResponse.player.list.compactMap { (key, value) -> Episode? in // Use compactMap
                        guard let episodeNumber = Int(key) else { return nil } // Ensure key is an Int
                        let fhdUrl = value.hls.fhd.flatMap { URL(string: "https://cache.libria.fun\($0)") }
                        let hdUrl = value.hls.hd.flatMap { URL(string: "https://cache.libria.fun\($0)") }
                        let sdUrl = value.hls.sd.flatMap { URL(string: "https://cache.libria.fun\($0)") }
                        // Prioritize qualities, ensure URL is valid
                        guard let selectedUrl = (fhdUrl ?? hdUrl ?? sdUrl)?.absoluteString else { return nil }
                        return Episode(number: String(episodeNumber), href: selectedUrl, downloadUrl: "") // Download URL might need separate logic
                    }.sorted { $0.episodeNumber < $1.episodeNumber } // Sort numerically

                    let details = AnimeDetail(aliases: aliases, synopsis: synopsis, airdate: airdate, stars: stars, episodes: episodes)
                    completion(.success(details))
                case .failure(let error):
                    completion(.failure(error))
                }
            }
        } else if selectedSource == .anilist {
            session.request(fullUrl).responseJSON { response in // Keep responseJSON for now
                switch response.result {
                case .success(let json):
                    guard
                        let jsonDict = json as? [String: Any],
                        let animeInfo = jsonDict["anime"] as? [String: Any],
                        let infoDict = animeInfo["info"] as? [String: Any], // Corrected path
                        let moreInfo = animeInfo["moreInfo"] as? [String: Any]
                    else {
                        completion(.failure(NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid AniList JSON format."])))
                        return
                    }

                    let description = infoDict["description"] as? String ?? "No description available."
                    let name = infoDict["name"] as? String ?? "Unknown Title"
                    let premiered = moreInfo["premiered"] as? String ?? "N/A"
                    // Safely access malscore, handle different types
                    let malscore: String
                    if let scoreDouble = moreInfo["malscore"] as? Double {
                        malscore = String(format: "%.2f", scoreDouble)
                    } else if let scoreString = moreInfo["malscore"] as? String {
                        malscore = scoreString
                    } else {
                        malscore = "N/A"
                    }


                    let aliases = name // Assuming 'name' is the primary alias
                    let airdate = premiered
                    let stars = malscore

                    // Use the original href (which might contain episode info for context) to fetch episodes
                    fetchAniListEpisodes(from: href) { result in // Pass original href
                        switch result {
                        case .success(let episodes):
                            let details = AnimeDetail(aliases: aliases, synopsis: synopsis, airdate: airdate, stars: stars, episodes: episodes)
                            completion(.success(details))
                        case .failure(let error):
                            completion(.failure(error))
                        }
                    }
                case .failure(let error):
                    completion(.failure(error))
                }
            }
        } else {
            // HTML Parsing for other sources
            session.request(fullUrl).responseString { response in
                switch response.result {
                case .success(let html):
                    do {
                        let document = try SwiftSoup.parse(html)
                        var aliases: String = ""
                        var synopsis: String = ""
                        var airdate: String = ""
                        var stars: String = ""
                        var episodes: [Episode] = [] // Initialize episodes

                        // --- Source-specific HTML parsing logic ---
                        switch selectedSource {
                         case .animeWorld:
                             aliases = try document.select("div.widget-title h1").attr("data-jtitle")
                             synopsis = try document.select("div.info div.desc").text()
                             airdate = try document.select("div.row dl.meta dt:contains(Data di Uscita) + dd").first()?.text() ?? ""
                             stars = try document.select("dd.rating span").text()
                         case .gogoanime:
                             aliases = try document.select("div.anime_info_body_bg p.other-name a").text()
                             // Combine all paragraphs within the description div
                             synopsis = try document.select("div.anime_info_body_bg div.description p").array().map { try $0.text() }.joined(separator: "\n")
                             airdate = try document.select("p.type:contains(Released:)").first()?.text().replacingOccurrences(of: "Released: ", with: "") ?? ""
                             stars = try document.select("p.type:contains(Status:)").first()?.text().replacingOccurrences(of: "Status: ", with: "") ?? "" // Using Status as 'stars'
                         case .animeheaven:
                             aliases = try document.select("div.infodiv div.infotitlejp").text()
                             synopsis = try document.select("div.infodiv div.infodes").text()
                             airdate = try document.select("div.infoyear div.c2").eq(1).text()
                             stars = try document.select("div.infoyear div.c2").last()?.text() ?? ""
                         case .animefire:
                             aliases = try document.select("div.mr-2 h6.text-gray").text()
                             synopsis = try document.select("div.divSinopse span.spanAnimeInfo").text()
                             airdate = try document.select("div.divAnimePageInfo div.animeInfo span.spanAnimeInfo").last()?.text() ?? ""
                             stars = try document.select("div.div_anime_score h4.text-white").text()
                         case .kuramanime:
                              aliases = try document.select("div.anime__details__title span").last()?.text() ?? ""
                              synopsis = try document.select("div.anime__details__text p").text()
                              // Safely find and extract the date
                              airdate = try document.select("div.anime__details__widget ul li:has(div:containsOwn(Date aired:)) div.col-9").first()?.text().components(separatedBy: "to").first?.trimmingCharacters(in: .whitespaces) ?? ""
                              stars = try document.select("div.anime__details__widget ul li:has(div:containsOwn(Score:)) div.col-9").first()?.text() ?? ""
                          case .anime3rb:
                              aliases = "" // Often no specific alias field
                              synopsis = try document.select("p.leading-loose").first()?.text() ?? "" // More specific selector if possible
                              airdate = try document.select("div.flex.items-center.gap-2 span:contains(تاريخ)").first()?.nextElementSibling()?.text() ?? "" // Find based on label
                              stars = try document.select("div.flex.items-center.gap-2 span:contains(التقييم)").first()?.nextElementSibling()?.text() ?? "" // Find based on label
                          case .animesrbija:
                               aliases = try document.select("h3.anime-eng-name").text()
                               let rawSynopsis = try document.select("div.anime-description").text()
                               synopsis = rawSynopsis // Keep raw text, cleaning might remove important info
                               airdate = try document.select("div.anime-information-col div:containsOwn(Datum:)").first()?.text().replacingOccurrences(of: "Datum:", with: "").trimmingCharacters(in: .whitespaces) ?? ""
                               stars = try document.select("div.anime-information-col div:containsOwn(MAL Ocena:)").first()?.text().replacingOccurrences(of: "MAL Ocena:", with: "").trimmingCharacters(in: .whitespaces) ?? ""
                          case .aniworld:
                              aliases = try document.select("div.seriesDetails span > i").first()?.text() ?? "" // Get original title
                              synopsis = try document.select("p.seri_des").text()
                              airdate = try document.select("div.genres + div > span").eq(1).text() // Get year
                              stars = try document.select("div.rating span > span").first()?.text() ?? "" // Get rating score (Corrected selector)
                          case .tokyoinsider:
                              aliases = "" // No clear alias field usually
                              synopsis = try document.select("div#synopsis > p").text() // More specific selector
                              airdate = try document.select("div.static_single:contains(Vintage) span.static_single_val").text()
                              stars = try document.select("div.static_single:contains(Rating) span.static_single_val").text().components(separatedBy: "(").first?.trimmingCharacters(in: .whitespaces) ?? "" // Extract score
                          case .anivibe:
                              aliases = try document.select("span.alter").text()
                              synopsis = try document.select("div.synp div.entry-content").text()
                              airdate = try document.select("div.spe span:contains(Aired:)").first()?.ownText() ?? "" // Extract aired date
                              stars = try document.select("div.spe span:contains(Rating:)").first()?.ownText() ?? "" // Extract rating
                          case .animeunity:
                              aliases = "" // Often no alias
                              synopsis = try document.select("div.description").text()
                              airdate = try document.select("div.extra span:contains(Anno)").first()?.ownText() ?? ""
                              stars = try document.select("div.score > strong").text() // Get score
                          case .animeflv:
                               aliases = try document.select("span.TxtAlt").text()
                               synopsis = try document.select("div.Description p").text()
                               airdate = try document.select("span.Date").text() // Assuming Date span exists
                               stars = try document.select("span.vtprmd").text() // Assuming rating span exists
                           case .animebalkan:
                                aliases = ""
                                synopsis = try document.select("div.entry-content p").text() // More specific p tag
                                airdate = try document.select("div.spe span:contains(Godina:)").first()?.ownText() ?? ""
                                stars = try document.select("div.spe span:contains(Ocena:)").first()?.ownText() ?? ""
                           case .anibunker:
                                aliases = ""
                                synopsis = try document.select("div.sinopse--display p").text()
                                airdate = try document.select("div.field-info:contains(Ano:)").first()?.text().replacingOccurrences(of: "Ano: ", with: "") ?? ""
                                stars = try document.select("div.rating-average span").text() // Find rating average

                         // Should not be reached here for API sources
                         case .anilist, .anilibria:
                             throw NSError(domain: "ParsingError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Incorrect parsing path for API source."])
                         }


                        // Fetch episodes using the common fetchEpisodes function
                        episodes = self.fetchEpisodes(document: document, for: selectedSource, href: href)

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
    }


    // Fetch episodes specifically for AniList (HiAnime API)
    static func fetchAniListEpisodes(from href: String, completion: @escaping (Result<[Episode], Error>) -> Void) {
         let baseUrl = "https://aniwatch-api-gp1w.onrender.com/anime/episodes/" // API endpoint for episodes

         let fullUrlString: String
          // Extract the core ID part from the href (e.g., "steinsgate-3" from "/watch/steinsgate-3?ep=...")
          if let watchRange = href.range(of: "/watch/") {
              let potentialIdPart = String(href[watchRange.upperBound...])
              let idPart = String(potentialIdPart.split(separator: "?")[0]) // Get part before '?'
              fullUrlString = baseUrl + idPart
          } else if let infoRange = href.range(of: "/info?id=") {
               // Handle case where href is like ".../info?id=steinsgate-3"
               let idPart = String(href[infoRange.upperBound...])
               fullUrlString = baseUrl + idPart
           } else if !href.contains("/") { // Assume href is just the ID if no slashes
               fullUrlString = baseUrl + href
           } else {
               completion(.failure(NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid AniList href format for episode fetching."])))
               return
           }

         guard let fullUrl = URL(string: fullUrlString) else {
              completion(.failure(NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid final URL for AniList episodes: \(fullUrlString)"])))
              return
          }

         session.request(fullUrl).responseJSON { response in // Keep responseJSON for now
             switch response.result {
             case .success(let json):
                 guard
                     let jsonDict = json as? [String: Any],
                     let episodesArray = jsonDict["episodes"] as? [[String: Any]]
                 else {
                     completion(.failure(NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid AniList episode JSON format."])))
                     return
                 }

                 let episodes = episodesArray.compactMap { episodeDict -> Episode? in
                     guard
                         let episodeId = episodeDict["episodeId"] as? String, // ID for fetching sources
                         let number = episodeDict["number"] as? Int
                     else {
                         return nil
                     }

                     let episodeNumber = "\(number)"
                     // Construct the href needed for *fetching sources*
                     // The episodeId from the episodes endpoint seems to be the parameter needed for the source fetch
                     // Example source fetch URL: https://aniwatch-api-gp1w.onrender.com/anime/episode-srcs?id=tv/steinsgate-3?ep=13499
                     let hrefForSources = "https://aniwatch-api-gp1w.onrender.com/anime/episode-srcs?id=\(episodeId)"

                     return Episode(number: episodeNumber, href: hrefForSources, downloadUrl: "") // href is now the source fetch URL
                 }.sorted { $0.episodeNumber < $1.episodeNumber } // Sort numerically

                 completion(.success(episodes))

             case .failure(let error):
                 completion(.failure(error))
             }
         }
     }

     // Common Episode Fetching Logic (with Source Differentiation)
    private static func fetchEpisodes(document: Document, for source: MediaSource, href: String) -> [Episode] {
        var episodes: [Episode] = []
        do { // Add do-catch block here
            var episodeElements: Elements?
            var downloadUrlElement: String? = nil // Make optional
            let baseURL = href // Use the provided href as the base for resolving relative paths

            switch source {
            case .animeWorld:
                episodeElements = try document.select("div.server.active ul.episodes li.episode a")
            case .gogoanime:
                let totalEpisodesString = try document.select("#episode_page li a").last()?.attr("ep_end") ?? "0"
                let totalEpisodes = Int(totalEpisodesString) ?? 0
                let animeIDPart = href.replacingOccurrences(of: "/category/", with: "")
                episodes = (1...totalEpisodes).map {
                    let episodeHref = "https://anitaku.bz/\(animeIDPart)-episode-\($0)"
                    return Episode(number: "\($0)", href: episodeHref, downloadUrl: "")
                }
                return episodes
            case .animeheaven:
                episodeElements = try document.select("div.infoepisode a.pull-left")
            case .animefire:
                episodeElements = try document.select("div.div_video_list a")
            case .kuramanime:
                let episodeContent = try document.select("div#episodeListsSection a.follow-btn").attr("data-content")
                let episodeDocument = try SwiftSoup.parse(episodeContent)
                episodeElements = try episodeDocument.select("a.btn")
            case .anime3rb:
                episodeElements = try document.select("div.absolute.overflow-hidden div a.gap-3")
            case .animesrbija:
                episodeElements = try document.select("ul.anime-episodes-holder li.anime-episode-item")
            case .aniworld:
                 // Move the AniWorld fetching logic here, inside the do-catch
                 let seasonUrls = try extractSeasonUrls(document: document)
                 let sortedSeasonUrls = seasonUrls.sorted { pair1, pair2 in
                     let season1 = pair1.0
                     let season2 = pair2.0
                     if season1 == "F" { return false } // Film comes last
                     if season2 == "F" { return true }
                     return (Int(season1.dropFirst()) ?? 0) < (Int(season2.dropFirst()) ?? 0)
                 }
                 let group = DispatchGroup()
                 var allEpisodes: [Episode] = []
                 let queue = DispatchQueue(label: "com.aniworld.fetch", attributes: .concurrent)
                 let syncQueue = DispatchQueue(label: "com.aniworld.sync") // For thread-safe appending

                 for (seasonNumber, seasonUrl) in sortedSeasonUrls {
                     group.enter()
                     queue.async {
                         defer { group.leave() } // Ensure leave is always called
                         do {
                             if let seasonEpisodes = try? fetchAniWorldSeasonEpisodes(seasonUrl: seasonUrl, seasonNumber: seasonNumber) {
                                 syncQueue.async { // Safely append to shared array
                                     allEpisodes.append(contentsOf: seasonEpisodes)
                                 }
                             }
                         } catch {
                              print("Error fetching AniWorld season \(seasonNumber): \(error)")
                          }
                     }
                 }
                 group.wait() // Wait for all season fetches to complete
                 // Sort numerically based on extracted episode number after SxE format
                 return allEpisodes.sorted {
                      $0.episodeNumber < $1.episodeNumber
                  }.uniqued(by: \.number) // Keep unique episode numbers
            case .tokyoinsider:
                episodeElements = try document.select("div.episode a[href*='/episode/']") // Select only episode links
            case .anivibe, .animebalkan:
                episodeElements = try document.select("div.eplister ul li a")
            case .animeunity:
                 do {
                      let rawHtml = try document.html()
                      if let startIndex = rawHtml.range(of: "<video-player")?.upperBound,
                         let endIndex = rawHtml.range(of: "</video-player>")?.lowerBound {
                           let videoPlayerContent = String(rawHtml[startIndex..<endIndex])
                           if let episodesStart = videoPlayerContent.range(of: "episodes=\"")?.upperBound,
                              let episodesEnd = videoPlayerContent[episodesStart...].range(of: "\"")?.lowerBound {
                                // Corrected replacingOccurrences call
                                let episodesJson = String(videoPlayerContent[episodesStart..<episodesEnd]).replacingOccurrences(of: """, with: "\"")
                                if let episodesData = episodesJson.data(using: .utf8),
                                   let episodesList = try? JSONSerialization.jsonObject(with: episodesData) as? [[String: Any]] {
                                     episodes = episodesList.compactMap { episodeDict in
                                         guard let number = episodeDict["number"] as? String,
                                               let slug = episodeDict["slug"] as? String else { return nil }
                                         let hrefEp = "\(href)/\(slug)" // Construct detail URL
                                         return Episode(number: number, href: hrefEp, downloadUrl: "")
                                     }
                                     return episodes.sorted { $0.episodeNumber < $1.episodeNumber } // Sort numerically
                                 }
                            }
                      }
                      print("Could not extract episodes from AnimeUnity video-player tag.")
                      return [] // Return empty if extraction failed
                  } catch {
                       print("Error parsing AnimeUnity episodes: \(error.localizedDescription)")
                       return []
                   }
            case .animeflv:
                 do {
                      let rawHtml = try document.html()
                      // Corrected Regex with proper escaping
                       let pattern = "\\[\"(\\d+)\",\"([^\"]+)\"\\]" // Capture number and the string ID
                      let regex = try NSRegularExpression(pattern: pattern)
                      let matches = regex.matches(in: rawHtml, range: NSRange(rawHtml.startIndex..., in: rawHtml))

                      guard !matches.isEmpty else {
                          print("No episodes found via regex for AnimeFLV.")
                          return []
                      }

                      let modifiedBaseURL = baseURL.replacingOccurrences(of: "/anime/", with: "/ver/")

                      episodes = matches.compactMap { match in
                          guard match.numberOfRanges == 3, // Expect 3 ranges: full match, group 1 (number), group 2 (id)
                                let numberRange = Range(match.range(at: 1), in: rawHtml),
                                let _ = Range(match.range(at: 2), in: rawHtml) // Use the ID if needed later, for now just the number
                          else { return nil }

                          let episodeNumberStr = String(rawHtml[numberRange])
                          // Construct the href using the episode number
                          let hrefEp = "\(modifiedBaseURL)-\(episodeNumberStr)"
                          return Episode(number: episodeNumberStr, href: hrefEp, downloadUrl: "")
                      }
                      // Sort numerically
                      return episodes.sorted { $0.episodeNumber < $1.episodeNumber }

                  } catch {
                      print("Error parsing AnimeFLV episodes via regex: \(error.localizedDescription)")
                      return []
                  }
            case .anibunker:
                episodeElements = try document.select("div.eps-display a")
            // API sources handled elsewhere
             case .anilist, .anilibria:
                 return [] // Explicitly return empty for API sources
            }

            // Common HTML element parsing (refined)
            guard let elements = episodeElements else { return [] }
            episodes = elements.compactMap { element -> Episode? in
                 do {
                     var episodeText: String?
                     var hrefEp: String?
                     let sourceBaseURL: String? // Specific base URL for resolving relative links

                     switch source {
                     case .animeWorld:
                         episodeText = try element.text()
                         hrefEp = try element.attr("href")
                         sourceBaseURL = "https://animeworld.so"
                     case .animeheaven:
                         episodeText = try element.select("div.watch2").text()
                         hrefEp = try element.attr("href")
                         sourceBaseURL = "https://animeheaven.me"
                     case .animefire:
                         let titleText = try element.text()
                         episodeText = titleText.components(separatedBy: " ").last ?? ""
                         hrefEp = try element.attr("href")
                         sourceBaseURL = "https://animefire.plus"
                     case .kuramanime:
                         episodeText = try element.text().replacingOccurrences(of: "Ep ", with: "")
                         hrefEp = try element.attr("href")
                         sourceBaseURL = "https://kuramanime.red" // Example base
                     case .anime3rb:
                         let titleText = try element.select("div.video-metadata span").first()?.text() ?? ""
                         episodeText = titleText.replacingOccurrences(of: "الحلقة ", with: "")
                         hrefEp = try element.attr("href")
                         sourceBaseURL = "https://anime3rb.com"
                     case .animesrbija:
                         episodeText = try element.select("span.anime-episode-num").text().replacingOccurrences(of: "Epizoda ", with: "")
                         hrefEp = try element.select("a.anime-episode-link").attr("href")
                         sourceBaseURL = "https://www.animesrbija.com"
                     case .tokyoinsider:
                          episodeText = try element.select("strong").text() // Get number from <strong>
                          hrefEp = try element.attr("href")
                          sourceBaseURL = "https://www.tokyoinsider.com"
                     case .anivibe:
                          episodeText = try element.select("div.epl-num").text()
                          hrefEp = try element.attr("href")
                          sourceBaseURL = "https://anivibe.net"
                     case .animebalkan:
                          episodeText = try element.select("div.epl-num").text()
                          hrefEp = try element.attr("href")
                          sourceBaseURL = "https://animebalkan.org" // Or .gg if needed
                     case .anibunker:
                          episodeText = try element.select("div.ep_number").text()
                          hrefEp = try element.attr("href")
                          sourceBaseURL = "https://www.anibunker.com"
                     // Explicitly ignore sources handled elsewhere or API sources
                     case .gogoanime, .aniworld, .animeunity, .animeflv, .anilist, .anilibria:
                          return nil
                     }

                     guard let finalEpisodeText = episodeText?.nilIfEmpty, let finalHref = hrefEp?.nilIfEmpty else { return nil }

                     // Construct absolute URL
                     let absoluteHref: String
                     if finalHref.hasPrefix("http") {
                          absoluteHref = finalHref
                      } else if let base = sourceBaseURL, let resolvedURL = URL(string: finalHref, relativeTo: URL(string: base)) {
                          absoluteHref = resolvedURL.absoluteString
                      } else {
                           print("Warning: Could not resolve relative URL for \(source.rawValue): \(finalHref)")
                           absoluteHref = finalHref // Fallback to using it as is
                       }

                     return Episode(number: finalEpisodeText, href: absoluteHref, downloadUrl: downloadUrlElement ?? "")

                 } catch {
                     print("Error parsing episode element for \(source.rawValue): \(error.localizedDescription)")
                     return nil
                 }
            }

        } catch { // Catch errors from the outer try block
            print("Error parsing episodes for source \(source.rawValue): \(error.localizedDescription)")
        }
        // Sort numerically after collecting all episodes
         return episodes.sorted { $0.episodeNumber < $1.episodeNumber }
    }


    // MARK: - Helpers (Moved from AnimeDetailViewController for context)
    // (Keep extractSeasonUrls, fetchAniWorldSeasonEpisodes here as they are static and used by fetchEpisodes)

     private static func extractSeasonUrls(document: Document) throws -> [(String, String)] {
         let seasonElements = try document.select("div.hosterSiteDirectNav a[title]")

         return seasonElements.compactMap { element in
             do {
                 let href = try element.attr("href")
                 let title = try element.attr("title")

                 if title.contains("Filme") {
                     return ("F", "https://aniworld.to" + href)
                 } else if title.contains("Staffel"),
                           let seasonNum = title.components(separatedBy: " ").last {
                     return ("S\(seasonNum)", "https://aniworld.to" + href)
                 }
                 return nil
             } catch {
                 return nil
             }
         }
     }

     private static func fetchAniWorldSeasonEpisodes(seasonUrl: String, seasonNumber: String) throws -> [Episode] {
         let config = URLSessionConfiguration.default
         config.requestCachePolicy = .returnCacheDataElseLoad
         config.urlCache = URLCache.shared

         let session = URLSession(configuration: config)
         guard let url = URL(string: seasonUrl) else { throw URLError(.badURL) }

         let semaphore = DispatchSemaphore(value: 0)
         var resultHtml: String?
         var resultError: Error?

         let task = session.dataTask(with: url) { data, response, error in
             if let error = error { resultError = error }
             else if let data = data, let html = String(data: data, encoding: .utf8) { resultHtml = html }
             semaphore.signal()
         }
         task.resume()
         semaphore.wait()

         if let error = resultError { throw error }
         guard let html = resultHtml else { throw URLError(.badServerResponse) }

         let document = try SwiftSoup.parse(html)

         return try document.select("table.seasonEpisodesList td a")
             .compactMap { element -> Episode? in
                 let fullText = try element.text()
                 let episodeHref = try element.attr("href")

                  // Extract number from text like "Episode 1" or just "1"
                  let episodeNumberStr = fullText.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()

                  guard !episodeNumberStr.isEmpty, let _ = Int(episodeNumberStr) else { return nil } // Validate

                 // Construct SxE format: e.g., S1E01
                 let formattedEpisodeNumber = "\(seasonNumber)E\(episodeNumberStr)"

                 return Episode(number: formattedEpisodeNumber, href: "https://aniworld.to" + episodeHref, downloadUrl: "")
             }
             // No need to sort here, sorting happens after combining all seasons
     }
}
