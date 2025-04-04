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
            .kuramanime: "https://kuramanime.red/quick/ongoing?order_by=updated", // Search/list page might be better?
            .anime3rb: "https://anime3rb.com/titles/list?status[0]=upcomming&status[1]=finished&sort_by=addition_date", // Search/list page
            .animesrbija: "https://www.animesrbija.com/filter?sort=new", // Search/list page
            .aniworld: "https://aniworld.to/neu", // List page
            .tokyoinsider: "https://www.tokyoinsider.com/new", // List page
            .anivibe: "https://anivibe.net/newest", // List page
            .animeunity: "https://www.animeunity.to/", // Base URL
            .animeflv: "https://www3.animeflv.net/", // Base URL
            .animebalkan: "https://animebalkan.org/animesaprevodom/?status=&type=&order=update", // Search/list page
            .anibunker: "https://www.anibunker.com/animes" // List page
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
                   tsIndex + 1 < components.count,
                   let extractedId = components[tsIndex + 1].components(separatedBy: CharacterSet.decimalDigits.inverted).first {
                    fullUrlString = baseUrl + extractedId
                } else {
                    // Fallback or error if ID extraction fails
                    completion(.failure(NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "Could not extract Anilibria ID."])))
                    return
                }
            } else if let _ = Int(href) { // If href is already just the ID
                fullUrlString = baseUrl + href
            } else {
                // Assume href is a full URL to the release page, need to adapt fetching if needed
                // Or signal an error if only ID-based fetching is supported
                completion(.failure(NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unsupported Anilibria URL format."])))
                return
            }
        case .anilist:
            // Extract ID for API call
            let prefixes = ["https://aniwatch-api-gp1w.onrender.com/anime/episode-srcs?id="] // Add other relevant prefixes if needed
            func extractIdentifier(from fullUrl: String) -> String? {
                if let watchRange = fullUrl.range(of: "/watch/") {
                    let potentialIdPart = String(fullUrl[watchRange.upperBound...])
                    // The ID might be the part before the first '?' or the whole part if no '?'
                    return String(potentialIdPart.split(separator: "?")[0])
                }
                for prefix in prefixes {
                    if let idRange = fullUrl.range(of: prefix) {
                        let startIndex = fullUrl.index(idRange.upperBound, offsetBy: 0)
                        if let endRange = fullUrl[startIndex...].range(of: "?ep=") ?? fullUrl[startIndex...].range(of: "&ep=") {
                            return String(fullUrl[startIndex..<endRange.lowerBound])
                        }
                    }
                }
                return nil
            }

            if let identifier = extractIdentifier(from: href) {
                fullUrlString = baseUrl + identifier
            } else if !href.contains("/") { // Assume href is just the ID
                fullUrlString = baseUrl + href
            } else {
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
            completion(.failure(NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid final URL constructed."])))
            return
        }

        // --- Data Fetching and Parsing ---
        if selectedSource == .anilibria {
            session.request(fullUrl).responseDecodable(of: AnilibriaResponse.self) { response in
                switch response.result {
                case .success(let anilibriaResponse):
                    let aliases = anilibriaResponse.names.en
                    let synopsis = anilibriaResponse.description
                    let airdate = "\(anilibriaResponse.season.year) \(anilibriaResponse.season.string)"
                    let stars = String(anilibriaResponse.inFavorites)

                    let episodes = anilibriaResponse.player.list.map { (key, value) -> Episode in
                        let episodeNumber = key
                        let fhdUrl = value.hls.fhd.map { "https://cache.libria.fun\($0)" }
                        let hdUrl = value.hls.hd.map { "https://cache.libria.fun\($0)" }
                        let sdUrl = value.hls.sd.map { "https://cache.libria.fun\($0)" }
                        let selectedUrl = fhdUrl ?? hdUrl ?? sdUrl ?? ""
                        return Episode(number: episodeNumber, href: selectedUrl, downloadUrl: "")
                    }.sorted { Int($0.number) ?? 0 < Int($1.number) ?? 0 }

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
                    let malscore = moreInfo["malscore"] as? String ?? "N/A"

                    let aliases = name // Assuming 'name' is the primary alias
                    let airdate = premiered
                    let stars = malscore

                    // Fetch episodes separately using the API endpoint for episodes
                    fetchAniListEpisodes(from: href) { result in // Pass original href
                        switch result {
                        case .success(let episodes):
                            let details = AnimeDetail(aliases: aliases, synopsis: description, airdate: airdate, stars: stars, episodes: episodes)
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
                        // (Keep the existing switch cases here, ensure they handle errors gracefully)
                        switch selectedSource {
                         case .animeWorld:
                             aliases = try document.select("div.widget-title h1").attr("data-jtitle")
                             synopsis = try document.select("div.info div.desc").text()
                             airdate = try document.select("div.row dl.meta dt:contains(Data di Uscita) + dd").first()?.text() ?? ""
                             stars = try document.select("dd.rating span").text()
                         case .gogoanime:
                             aliases = try document.select("div.anime_info_body_bg p.other-name a").text()
                             synopsis = try document.select("div.anime_info_body_bg div.description").text()
                             airdate = try document.select("p.type:contains(Released:)").first()?.text().replacingOccurrences(of: "Released: ", with: "") ?? ""
                             stars = ""
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
                             // Safely unwrap and cast
                              if let dateText = try document.select("div.anime__details__widget ul li div.col-9").eq(3).text().components(separatedBy: "s/d").first?.trimmingCharacters(in: .whitespaces) {
                                   airdate = dateText
                               } else {
                                   airdate = "" // Or some default/error value
                               }
                             stars = try document.select("div.anime__details__widget div.row div.col-lg-6 ul li").select("div:contains(Skor:) ~ div.col-9").text()
                         case .anime3rb:
                             aliases = ""
                             synopsis = try document.select("p.leading-loose").text()
                             airdate = try document.select("td[title]").attr("title")
                             stars = try document.select("p.text-lg.leading-relaxed").first()?.text() ?? ""
                         case .animesrbija:
                              aliases = try document.select("h3.anime-eng-name").text()
                              let rawSynopsis = try document.select("div.anime-description").text()
                              synopsis = rawSynopsis.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                              if let dateElement = try document.select("div.anime-information-col div:contains(Datum:)").first()?.text(),
                                 let dateStr = dateElement.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) {
                                  airdate = dateStr.components(separatedBy: "to").first?.trimmingCharacters(in: .whitespaces) ?? ""
                              } else { airdate = "" }
                              if let scoreElement = try document.select("div.anime-information-col div:contains(MAL Ocena:)").first()?.text(),
                                 let scoreStr = scoreElement.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) {
                                  stars = scoreStr
                              } else { stars = "" }
                         case .aniworld:
                             aliases = ""
                             synopsis = try document.select("p.seri_des").text()
                             airdate = "N/A"
                             stars = "N/A"
                         case .tokyoinsider:
                             aliases = ""
                             synopsis = try document.select("td[style*='border-bottom: 0']").text()
                             airdate = try document.select("tr.c_h2:contains(Vintage:)").select("td:not(:has(b))").text()
                             stars = "N/A"
                         case .anivibe:
                             aliases = try document.select("span.alter").text()
                             synopsis = try document.select("div.synp div.entry-content").text()
                             airdate = try document.select("div.split").text()
                             stars = "N/A"
                         case .animeunity:
                             aliases = ""
                             synopsis = try document.select("div.description").text()
                             airdate = "N/A"
                             stars = "N/A"
                         case .animeflv:
                             aliases = try document.select("span.TxtAlt").text()
                             synopsis = try document.select("div.Description p").text()
                             airdate = "N/A"
                             stars = "N/A"
                         case .animebalkan:
                             aliases = ""
                             synopsis = try document.select("div.entry-content").text()
                             airdate = "N/A"
                             stars = "N/A"
                         case .anibunker:
                             aliases = ""
                             synopsis = try document.select("div.sinopse--display p").text()
                             airdate = try document.select("div.field-info:contains(Ano:)").first()?.text().replacingOccurrences(of: "Ano: ", with: "") ?? ""
                             stars = "N/A"
                         case .anilist, .anilibria: // Should not be reached here
                             print("Error: HTML parsing called for API source \(selectedSource.rawValue)")
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

    // Renamed function
    static func fetchAniListEpisodes(from href: String, completion: @escaping (Result<[Episode], Error>) -> Void) {
         let baseUrl = "https://aniwatch-api-gp1w.onrender.com/anime/episodes/" // API endpoint for episodes

         let fullUrlString: String
         // Extract the core ID part from the href (e.g., "steinsgate-3" from "/watch/steinsgate-3?ep=...")
         if let watchRange = href.range(of: "/watch/") {
             let potentialIdPart = String(href[watchRange.upperBound...])
             let idPart = String(potentialIdPart.split(separator: "?")[0])
             fullUrlString = baseUrl + idPart
         } else if !href.contains("/") { // Assume href is just the ID
             fullUrlString = baseUrl + href
         } else {
             completion(.failure(NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid AniList href format for episode fetching."])))
             return
         }

         guard let fullUrl = URL(string: fullUrlString) else {
              completion(.failure(NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid final URL for AniList episodes."])))
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
                         let episodeId = episodeDict["episodeId"] as? String, // The ID for fetching sources
                         let number = episodeDict["number"] as? Int
                     else {
                         return nil
                     }

                     let episodeNumber = "\(number)"
                     // Construct the href needed for *fetching sources*, which includes the episodeId
                      let hrefForSources = "https://aniwatch-api-gp1w.onrender.com/anime/episode-srcs?id=\(episodeId)"

                     return Episode(number: episodeNumber, href: hrefForSources, downloadUrl: "") // href is now the source fetch URL
                 }

                 completion(.success(episodes))

             case .failure(let error):
                 completion(.failure(error))
             }
         }
     }


    private static func fetchEpisodes(document: Document, for source: MediaSource, href: String) -> [Episode] {
        var episodes: [Episode] = []
        do {
            var episodeElements: Elements?
            let downloadUrlElement: String = "" // Generally not available easily here
            let baseURL = href // Base URL for resolving relative paths, if needed

            switch source {
            case .animeWorld:
                episodeElements = try document.select("div.server.active ul.episodes li.episode a")
            case .gogoanime:
                 // Fetch total episodes to generate links
                 let totalEpisodesString = try document.select("#episode_page li a").last()?.attr("ep_end") ?? "0"
                 let totalEpisodes = Int(totalEpisodesString) ?? 0
                 let animeIDPart = href.replacingOccurrences(of: "/category/", with: "") // Extract ID part

                 episodes = (1...totalEpisodes).map { episodeNumber in
                     let episodeHref = "https://anitaku.bz/\(animeIDPart)-episode-\(episodeNumber)"
                     return Episode(number: "\(episodeNumber)", href: episodeHref, downloadUrl: "")
                 }
                 return episodes // Return early as we generated the list

             case .animeheaven:
                 episodeElements = try document.select("div.infoepisode a.pull-left") // Updated selector
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
                  let seasonUrls = try extractSeasonUrls(document: document)
                  let sortedSeasonUrls = seasonUrls.sorted { pair1, pair2 in
                      let season1 = pair1.0
                      let season2 = pair2.0
                      if season1 == "F" { return false }
                      if season2 == "F" { return true }
                      return (Int(season1.dropFirst()) ?? 0) < (Int(season2.dropFirst()) ?? 0)
                  }
                  let group = DispatchGroup()
                  var allEpisodes: [Episode] = []
                  let queue = DispatchQueue(label: "com.aniworld.fetch", attributes: .concurrent)
                  let syncQueue = DispatchQueue(label: "com.aniworld.sync")
                  for (seasonNumber, seasonUrl) in sortedSeasonUrls {
                      group.enter()
                      queue.async {
                          if let seasonEpisodes = try? fetchAniWorldSeasonEpisodes(seasonUrl: seasonUrl, seasonNumber: seasonNumber) {
                              syncQueue.async {
                                  allEpisodes.append(contentsOf: seasonEpisodes)
                                  group.leave()
                              }
                          } else { group.leave() }
                      }
                  }
                  group.wait()
                  return allEpisodes.sorted {
                      guard let num1 = Int($0.number.split(separator: "E").last ?? ""),
                            let num2 = Int($1.number.split(separator: "E").last ?? "") else { return false }
                      return num1 < num2
                  }.uniqued(by: \.number)

             case .tokyoinsider:
                 episodeElements = try document.select("div.episode")
             case .anivibe, .animebalkan:
                 episodeElements = try document.select("div.eplister ul li a")
             case .animeunity:
                  let rawHtml = try document.html()
                  if let startIndex = rawHtml.range(of: "<video-player")?.upperBound,
                     let endIndex = rawHtml.range(of: "</video-player>")?.lowerBound {
                       let videoPlayerContent = String(rawHtml[startIndex..<endIndex])
                       if let episodesStart = videoPlayerContent.range(of: "episodes=\"")?.upperBound,
                          let episodesEnd = videoPlayerContent[episodesStart...].range(of: "\"")?.lowerBound {
                            let episodesJson = String(videoPlayerContent[episodesStart..<episodesEnd]).replacingOccurrences(of: """, with: "\"") // Corrected replacement
                            if let episodesData = episodesJson.data(using: .utf8),
                               let episodesList = try? JSONSerialization.jsonObject(with: episodesData) as? [[String: Any]] {
                                 episodes = episodesList.compactMap { episodeDict in
                                     guard let number = episodeDict["number"] as? String,
                                           let link = episodeDict["link"] as? String else { return nil }
                                     // Construct href using ID or link based on what AnimeUnity expects
                                     let hrefEp: String
                                     if let id = episodeDict["id"] as? Int { hrefEp = baseURL + "/\(id)" }
                                     else { hrefEp = link } // Fallback? Verify this link format
                                     return Episode(number: number, href: hrefEp, downloadUrl: "")
                                 }
                                 return episodes
                             }
                        }
                  }
                  print("Could not extract episodes from AnimeUnity video-player tag.")
                  return [] // Return empty if extraction failed

             case .animeflv:
                  do {
                       let rawHtml = try document.html()
                       // Regex to find the highest episode number listed in the JS array `episodes = [[epNum, id], ...]`
                       let pattern = #"var episodes\s*=\s*\[\[(\d+),\d+\]"#
                       if let regex = try? NSRegularExpression(pattern: pattern, options: []),
                          let match = regex.firstMatch(in: rawHtml, options: [], range: NSRange(location: 0, length: rawHtml.utf16.count)),
                          let range = Range(match.range(at: 1), in: rawHtml),
                          let highestEpisodeNum = Int(String(rawHtml[range])) {

                           let modifiedBaseURL = baseURL.replacingOccurrences(of: "/anime/", with: "/ver/")

                           for episodeNumber in 1...highestEpisodeNum {
                               let hrefEp = "\(modifiedBaseURL)-\(episodeNumber)"
                               let episode = Episode(number: "\(episodeNumber)", href: hrefEp, downloadUrl: "")
                               episodes.append(episode)
                           }
                           return episodes // Return generated list
                       } else { print("No episodes found via regex for AnimeFLV.") }
                   } catch { print("Error parsing AnimeFLV episodes via regex: \(error.localizedDescription)") }
                   return [] // Return empty on error

             case .anibunker:
                 episodeElements = try document.select("div.eps-display a")
             case .anilist, .anilibria: // Explicitly ignore API sources here
                 return []
            }


            // Common parsing logic for HTML sources (needs refinement per source)
            guard let elements = episodeElements else { return [] }

            episodes = elements.compactMap { element -> Episode? in
                do {
                    let episodeText: String
                    let hrefEp: String

                    switch source {
                    case .animeheaven:
                        episodeText = try element.select("div.watch2").text() // Adjusted selector
                        hrefEp = try element.attr("href")
                    case .animefire:
                        let titleText = try element.text()
                        episodeText = titleText.components(separatedBy: " ").last ?? ""
                        hrefEp = try element.attr("href")
                    case .kuramanime:
                         episodeText = try element.text().replacingOccurrences(of: "Ep ", with: "")
                         hrefEp = try element.attr("href")
                    case .anime3rb:
                         let titleText = try element.select("div.video-metadata span").first()?.text() ?? ""
                         episodeText = titleText.replacingOccurrences(of: "الحلقة ", with: "")
                         hrefEp = try element.attr("href")
                    case .animesrbija:
                         episodeText = try element.select("span.anime-episode-num").text().replacingOccurrences(of: "Epizoda ", with: "")
                         let baseHref = try element.select("a.anime-episode-link").attr("href")
                         hrefEp = "https://www.animesrbija.com" + baseHref
                    case .aniworld: // Handled above
                         return nil
                    case .tokyoinsider:
                         episodeText = try element.select("strong").text()
                         let baseHref = try element.select("a.download-link").attr("href")
                         guard baseHref.contains("/episode/") else { return nil } // Filter out non-episode links
                         hrefEp = "https://www.tokyoinsider.com" + baseHref
                     case .anivibe, .animebalkan:
                          episodeText = try element.select("div.epl-num").text()
                          let baseHref = try element.attr("href")
                          let baseUrlPrefix = (source == .anivibe) ? "https://anivibe.net" : "https://animebalkan.org" // Or maybe empty if href is full?
                          hrefEp = baseUrlPrefix + baseHref // Adjust if href is absolute
                     case .animeunity, .animeflv, .gogoanime: // Handled above
                         return nil
                     case .anibunker:
                          episodeText = try element.select("div.ep_number").text()
                          let baseHref = try element.attr("href")
                          hrefEp = "https://www.anibunker.com" + baseHref
                     default: // Fallback for AnimeWorld and potentially others
                         episodeText = try element.text()
                         hrefEp = try element.attr("href")
                    }

                    // Basic validation
                    guard !episodeText.isEmpty, !hrefEp.isEmpty else { return nil }

                    // Ensure href is absolute
                     let finalHref: String
                     if !hrefEp.hasPrefix("http"), let baseUrlURL = URL(string: baseURL) {
                          finalHref = URL(string: hrefEp, relativeTo: baseUrlURL)?.absoluteString ?? hrefEp
                      } else {
                           finalHref = hrefEp
                       }


                    return Episode(number: episodeText, href: finalHref, downloadUrl: downloadUrlElement) // Use finalHref
                } catch {
                    print("Error parsing episode element for \(source.rawValue): \(error.localizedDescription)")
                    return nil
                }
            }

        } catch {
            print("Error parsing episodes for source \(source.rawValue): \(error.localizedDescription)")
        }
        return episodes
    }


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
            if let error = error {
                resultError = error
            } else if let data = data,
                      let html = String(data: data, encoding: .utf8) {
                resultHtml = html
            }
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

                // Updated logic to extract episode number more reliably
                 guard let episodeNumberStr = fullText.components(separatedBy: CharacterSet.decimalDigits.inverted).filter({ !$0.isEmpty }).first, // Get first sequence of digits
                       let episodeNumber = Int(episodeNumberStr) else { return nil }

                let paddedEpisodeNumber = String(format: "%02d", episodeNumber) // Keep padding
                let formattedEpisodeNumber = "\(seasonNumber)E\(paddedEpisodeNumber)"

                return Episode(number: formattedEpisodeNumber, href: "https://aniworld.to" + episodeHref, downloadUrl: "")
            }
            .sorted { // Sort by episode number within the season
                 guard let num1Str = $0.number.split(separator: "E").last, let num1 = Int(num1Str),
                       let num2Str = $1.number.split(separator: "E").last, let num2 = Int(num2Str) else { return false }
                 return num1 < num2
             }
    }
}
