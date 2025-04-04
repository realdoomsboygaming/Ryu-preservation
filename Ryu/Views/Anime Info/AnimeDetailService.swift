// Ryu/Views/Anime Info/AnimeDetailService.swift
import UIKit
import Alamofire
import SwiftSoup

// Structure for the final details passed to the AnimeDetailViewController
struct AnimeDetail {
    let aliases: String
    let synopsis: String
    let airdate: String
    let stars: String
    let episodes: [Episode] // Assumes Episode struct is defined elsewhere (e.g., EpisodeCell.swift or globally)
}

class AnimeDetailService {
    static let session = proxySession.createAlamofireProxySession() // Assuming proxySession is defined elsewhere

    // Fetches detailed anime information based on the selected source and href.
    static func fetchAnimeDetails(from href: String, completion: @escaping (Result<AnimeDetail, Error>) -> Void) {
        guard let selectedSource = UserDefaults.standard.selectedMediaSource else {
            completion(.failure(NSError(domain: "AnimeDetailService", code: -1, userInfo: [NSLocalizedDescriptionKey: "No media source selected."])))
            return
        }

        // --- Handle HiAnime (Aniwatch) Source ---
        if selectedSource == .hianime {
            // Extract the ID from the href (assuming href is the anime ID for HiAnime)
            // The href might be like "/watch/one-piece-100" or just "one-piece-100"
            let animeId = href.split(separator: "/").last.map(String.init) ?? href

            if animeId.isEmpty {
                 completion(.failure(AniwatchError.invalidURL))
                 return
            }

            let aniwatchService = Aniwatch()
            aniwatchService.getAnimeDetails(id: animeId) { result in
                switch result {
                case .success(let aniwatchDetails):
                    // Map AniwatchDetails to the AnimeDetail struct expected by the view controller
                    let mappedDetail = AnimeDetail(
                        aliases: "", // Aniwatch details doesn't explicitly provide aliases in the current model
                        synopsis: aniwatchDetails.description,
                        airdate: aniwatchDetails.year, // Map 'year' to 'airdate'
                        stars: aniwatchDetails.rating, // Map 'rating' to 'stars'
                        // Map the episodes. Ensure the Episode struct definition matches.
                        episodes: aniwatchDetails.episodes.map { aniwatchEpisode in
                             // Construct the watch page URL needed for `href` in the Episode struct
                             // Note: The Aniwatch service currently puts the *source fetch URL* in href.
                             // We might need to adjust the Episode struct or how href is used later.
                             // For now, let's use the watch page URL format.
                            let watchHref = "/watch/\(aniwatchDetails.id)?ep=\(aniwatchEpisode.id ?? "")" // Construct watch URL
                            return Episode(
                                number: aniwatchEpisode.number,
                                href: watchHref, // Use the constructed watch URL
                                downloadUrl: "" // Assuming no direct download URL from details
                            )
                        }
                    )
                    completion(.success(mappedDetail))
                case .failure(let error):
                    completion(.failure(error))
                }
            }
            return // Exit early as HiAnime logic is handled
        }

        // --- Handle Other Sources (Existing Logic) ---

        // Determine base URL based on the source
        let baseUrls: [String]
        switch selectedSource {
        case .animeWorld:
            baseUrls = ["https://animeworld.so"]
        case .gogoanime:
            baseUrls = ["https://anitaku.bz"] // Or other GoGo mirrors if needed
        case .animeheaven:
            baseUrls = ["https://animeheaven.me/"]
        // Add cases for other HTML-based sources
        case .animefire:
             baseUrls = ["https://animefire.plus"] // No base needed if href is absolute
        case .kuramanime:
             baseUrls = ["https://kuramanime.vip"] // Verify base URL
        case .anime3rb:
             baseUrls = ["https://anime3rb.watch"] // Verify base URL
        case .animesrbija:
             baseUrls = [""] // href seems absolute
        case .aniworld:
             baseUrls = ["https://aniworld.to"] // href is relative
        case .tokyoinsider:
             baseUrls = [""] // href seems absolute
        case .anivibe:
             baseUrls = [""] // href seems absolute
        case .animeunity:
              baseUrls = [""] // href seems absolute
        case .animeflv:
               baseUrls = [""] // href seems absolute
        case .animebalkan:
                baseUrls = [""] // href seems absolute
        case .anibunker:
                 baseUrls = [""] // href seems absolute

        // Add cases for other non-HiAnime sources...
        case .anilibria: // Anilibria uses JSON, handle differently if needed or ensure href is correct ID
             baseUrls = ["https://api.anilibria.tv/v3/title?id="]
             // Note: Anilibria logic was special-cased below, might need adjustments
             // If href is just the ID, construct the full URL here.
             let anilibriaFullUrl = baseUrls.first! + href
              fetchAnilibriaDetails(from: anilibriaFullUrl, completion: completion)
              return // Exit early for Anilibria


        default:
            baseUrls = [""] // Default or handle unknown source
        }

        let baseUrl = baseUrls.first ?? "" // Use first or default if multiple mirrors exist
        // Construct full URL correctly, handling cases where href might already be absolute
        let fullUrlString = href.starts(with: "http") ? href : baseUrl + href

        guard let fullUrl = URL(string: fullUrlString) else {
             completion(.failure(NSError(domain: "AnimeDetailService", code: -2, userInfo: [NSLocalizedDescriptionKey: "Invalid constructed URL: \(fullUrlString)"])))
             return
        }


        // Fetch HTML content for parsing
        session.request(fullUrl).responseString { response in
            switch response.result {
            case .success(let html):
                do {
                    let document = try SwiftSoup.parse(html)
                    // Extract details using source-specific logic
                    let (aliases, synopsis, airdate, stars) = try extractMetadata(document: document, for: selectedSource)
                    let episodes = fetchEpisodes(document: document, for: selectedSource, href: fullUrlString) // Pass full URL if needed for episode href construction

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

     // Helper function to fetch and parse Anilibria details (extracted from original logic)
     private static func fetchAnilibriaDetails(from fullUrlString: String, completion: @escaping (Result<AnimeDetail, Error>) -> Void) {
         guard let url = URL(string: fullUrlString) else {
             completion(.failure(NSError(domain: "AnimeDetailService", code: -2, userInfo: [NSLocalizedDescriptionKey: "Invalid Anilibria URL"])))
             return
         }

         session.request(url).responseDecodable(of: AnilibriaResponse.self) { response in
             switch response.result {
             case .success(let anilibriaResponse):
                 let aliases = anilibriaResponse.names.en
                 let synopsis = anilibriaResponse.description
                 let airdate = "\(anilibriaResponse.season.year) \(anilibriaResponse.season.string)"
                 // Anilibria doesn't have a direct star rating in this structure, using favorites count
                 let stars = "\(anilibriaResponse.inFavorites) Favorites"

                 let episodes = anilibriaResponse.player.list.map { (key, value) -> Episode in
                     let episodeNumber = key
                     // Prioritize FHD, then HD, then SD
                     let hlsUrl = value.hls.fhd ?? value.hls.hd ?? value.hls.sd ?? ""
                     // Prepend the base cache URL if the URL is relative
                     let streamUrl = hlsUrl.starts(with: "http") ? hlsUrl : "https://cache.libria.fun\(hlsUrl)"
                     // Anilibria doesn't provide a separate download URL in this API response
                     return Episode(number: episodeNumber, href: streamUrl, downloadUrl: "") // href is the stream URL
                 }.sorted { Int($0.number) ?? 0 < Int($1.number) ?? 0 } // Sort episodes numerically

                 let details = AnimeDetail(aliases: aliases, synopsis: synopsis, airdate: airdate, stars: stars, episodes: episodes)
                 completion(.success(details))

             case .failure(let error):
                 completion(.failure(error))
             }
         }
     }


    // Helper function to extract metadata based on source
    private static func extractMetadata(document: Document, for source: MediaSource) throws -> (aliases: String, synopsis: String, airdate: String, stars: String) {
        var aliases = ""
        var synopsis = ""
        var airdate = ""
        var stars = ""

        // Add specific selectors for each source
        switch source {
        case .animeWorld:
            aliases = try document.select("div.widget-title h1").attr("data-jtitle")
            synopsis = try document.select("div.info div.desc").text()
            airdate = try document.select("div.row dl.meta dt:contains(Data di Uscita) + dd").first()?.text() ?? "N/A"
            stars = try document.select("dd.rating span").text()
        case .gogoanime:
            aliases = try document.select("div.anime_info_body_bg p.other-name a").text()
            synopsis = try document.select("div.anime_info_body_bg div.description p").text() // More specific
            airdate = try document.select("p.type:contains(Released:) span").text() // Get span text
            stars = "" // GogoAnime doesn't show ratings prominently
        case .animeheaven:
             aliases = try document.select("div.infodiv div.infotitlejp").text()
             synopsis = try document.select("div.infodiv div.infodes").text()
             airdate = try document.select("div.infoyear div.c2").eq(1).text() // Second div.c2 for airdate
             stars = try document.select("div.infoyear div.c2").last()?.text() ?? "N/A" // Last div.c2 for stars
        case .animefire:
            aliases = try document.select("div.mr-2 h6.text-gray").text()
            synopsis = try document.select("div.divSinopse span.spanAnimeInfo").text()
            // Find the span containing the release year, might need adjustment
            airdate = try document.select("div.divAnimePageInfo span:contains(Ano:)").first()?.text().replacingOccurrences(of: "Ano: ", with: "") ?? "N/A"
            stars = try document.select("div.div_anime_score h4.text-white").text()
        case .kuramanime:
             aliases = try document.select("div.anime__details__title span").last()?.text() ?? "" // Often the Japanese title
             synopsis = try document.select("div.anime__details__text p").text()
             // Find the 'Status:' list item and get its sibling value for airdate
             airdate = try document.select("div.anime__details__widget ul li:contains(Status:) span").text() // Example, adjust selector
             stars = try document.select("div.anime__details__widget ul li:contains(Skor:) span").text() // Find Score

        case .anime3rb:
             // Aliases might not be directly available, title is usually in h1
             aliases = try document.select("div.alias_title > p > strong").text() // Example, adjust selector
             synopsis = try document.select("p.leading-loose").text()
             airdate = try document.select("div.MetaSingle__MetaItem:contains(سنة الإنتاج) span").text() // Example selector
             stars = try document.select("div.Rate--Rank span.text-gray-400").text() // Example selector for score

        case .animesrbija:
              aliases = try document.select("h3.anime-eng-name").text()
              let rawSynopsis = try document.select("div.anime-description").text()
              synopsis = rawSynopsis.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression, range: nil)
              airdate = try document.select("div.anime-information-col div:contains(Datum:)").first()?.text().replacingOccurrences(of: "Datum:", with: "").trimmingCharacters(in: .whitespaces) ?? "N/A"
              stars = try document.select("div.anime-information-col div:contains(MAL Ocena:)").first()?.text().replacingOccurrences(of: "MAL Ocena:", with: "").trimmingCharacters(in: .whitespaces) ?? "N/A"

        case .aniworld:
              aliases = try document.select(".series-title span[itemprop='alternateName']").text() // Example selector
              synopsis = try document.select("p.seri_des[itemprop='description']").text()
              airdate = try document.select("span[itemprop='startDate']").text() // Or similar metadata selector
              stars = try document.select("span[itemprop='ratingValue']").text() // Example selector


         case .tokyoinsider:
              // TokyoInsider has a table structure often
              aliases = try document.select("tr:contains(Alternative title) td").last()?.text() ?? ""
              synopsis = try document.select("tr:contains(Plot Summary) + tr td").text() // Row after Plot Summary
              airdate = try document.select("tr:contains(Vintage) td").last()?.text() ?? ""
              stars = try document.select("tr:contains(Rating) td").last()?.text().components(separatedBy: " (").first ?? "" // Extract score part

        case .anivibe:
             aliases = try document.select("span.alter").text()
             synopsis = try document.select("div.synp div.entry-content p").text() // Get text within the p tag
             // Airdate might be within a specific info section
             airdate = try document.select(".spe span:contains(Aired:)").first()?.parent()?.text().replacingOccurrences(of: "Aired:", with: "").trimmingCharacters(in: .whitespaces) ?? "N/A"
             stars = try document.select(".spe span:contains(Rating:)").first()?.parent()?.text().replacingOccurrences(of: "Rating:", with: "").trimmingCharacters(in: .whitespaces) ?? "N/A"

        case .animeunity:
             aliases = "" // Often title is the main one, aliases might not be present
             synopsis = try document.select("div.desc").text() // Common description class
             // Metadata often in a list or divs
             airdate = try document.select(".info div:contains(Stato) span, .info li:contains(Stato) span").text() // Example status/airdate
             stars = try document.select(".info div:contains(Voto) span, .info li:contains(Voto) span").text() // Example rating


        case .animeflv:
             aliases = try document.select("span.TxtAlt").text()
             synopsis = try document.select("div.Description p").text()
             airdate = try document.select(".Ficha span.TxtDd:contains(Emitido)").first()?.nextElementSibling()?.text() ?? "N/A" // Find by label, get next element
             stars = try document.select(".VotesCn span#votes_prmd").text() // Rating often has specific ID/class


        case .animebalkan:
            aliases = try document.select("span.alter").text() // Similar structure to anivibe often
            synopsis = try document.select("div.entry-content p").text()
            airdate = try document.select(".spe span:contains(Status) b").text() // Example structure
            stars = try document.select(".rating strong").text() // Example structure

        case .anibunker:
             aliases = try document.select("div.sinopse--title_alternative").text().replacingOccurrences(of: "Títulos alternativos: ", with: "")
             synopsis = try document.select("div.sinopse--display p").text()
             airdate = try document.select(".field-info:contains(Ano) a").text() // Year often in a link
             stars = try document.select(".rt .rating-average").text() // Rating might be in specific div


        // Add cases for other HTML-based sources...
        default:
            print("Metadata extraction not implemented for source: \(source.rawValue)")
        }

        return (aliases, synopsis, airdate, stars)
    }


    // Helper function to parse episode list from HTML based on source
    // Updated to return [Episode] and handle different source structures
     private static func fetchEpisodes(document: Document, for source: MediaSource, href: String) -> [Episode] {
         var episodes: [Episode] = []
         do {
             let episodeElements: Elements // Use Elements for SwiftSoup collection
             let downloadUrlElement: String = "" // Generally not available directly here
             let baseURL = getBaseURL(for: source, originalHref: href) // Get base URL dynamically

             switch source {
             case .animeWorld:
                 episodeElements = try document.select("div.server.active[data-id='1'] ul.episodes li.episode a") // Target specific server if needed
             case .gogoanime:
                // GoGoAnime episode list is often dynamically loaded or in a specific structure
                 episodeElements = try document.select("ul#episode_page li a") // Selector for episode range links
                 return parseGoGoEpisodes(elements: episodeElements, categoryHref: href) // Use specific parser for GoGo
             case .animeheaven:
                 episodeElements = try document.select("div.infoepboxinner a.infoa") // Updated selector
             case .animefire:
                  episodeElements = try document.select("div.div_video_list a")
             case .kuramanime:
                 // Kuramanime loads episodes dynamically, might need JS evaluation or API call
                 // Fallback to parsing what's available in HTML
                 episodeElements = try document.select("div.anime__details__episodes a") // Example selector
             case .anime3rb:
                 episodeElements = try document.select("div.EpisodesList div.row a.Episode--Sm") // Example selector
             case .animesrbija:
                  episodeElements = try document.select("ul.anime-episodes-holder li.anime-episode-item a.anime-episode-link")
             case .aniworld:
                 // AniWorld loads seasons dynamically, requires multiple fetches handled elsewhere
                 // This function might just return an empty array, or fetch only the first season shown
                 // For simplicity here, returning empty. Detail fetch should handle multi-season logic.
                 // episodeElements = try document.select("table.seasonEpisodesList tbody tr td a") // Only gets first season
                 return [] // Defer complex multi-fetch logic
             case .tokyoinsider:
                 episodeElements = try document.select("div.episode a.download-link") // Links with download-link class
             case .anivibe, .animebalkan: // Grouping similar structures
                  episodeElements = try document.select("div.eplister ul li a")
             case .animeunity:
                 // AnimeUnity often embeds episode data in JSON within attributes
                 // This requires specific parsing not just selector matching
                 return parseAnimeUnityEpisodes(document: document, baseURL: baseURL) // Use specific helper
             case .animeflv:
                  // AnimeFLV often stores episode info in JavaScript variables
                  return parseAnimeFLVJsonEpisodes(document: document, baseURL: baseURL) // Use specific helper
             case .anibunker:
                 episodeElements = try document.select("div.eps-display a")


             default:
                 print("Episode parsing not implemented for source: \(source.rawValue)")
                 return [] // Return empty for unhandled sources
             }

             // Generic parsing loop for sources using standard link/text structure
             episodes = try episodeElements.compactMap { element -> Episode? in
                 guard let episodeTextRaw = try? element.text(),
                       let hrefPath = try? element.attr("href"), !hrefPath.isEmpty else {
                     print("Skipping episode element, missing text or href for source \(source.rawValue)")
                     return nil
                 }

                 let episodeNumber = extractEpisodeNumber(from: episodeTextRaw, for: source)
                 // Construct full URL if href is relative
                 let fullHref = hrefPath.starts(with: "http") ? hrefPath : baseURL + hrefPath

                 // Download URL is usually fetched later, set to empty string for now
                 return Episode(number: episodeNumber, href: fullHref, downloadUrl: "")
             }

             // Sort episodes numerically
             episodes.sort {
                 (Double($0.number.replacingOccurrences(of: "[^0-9.]", with: "", options: .regularExpression)) ?? 0) <
                 (Double($1.number.replacingOccurrences(of: "[^0-9.]", with: "", options: .regularExpression)) ?? 0)
             }


         } catch {
             print("Error parsing episodes for \(source.rawValue): \(error.localizedDescription)")
         }
         return episodes
     }

    // Helper to extract episode number string based on source conventions
     private static func extractEpisodeNumber(from text: String, for source: MediaSource) -> String {
        // Default: Extract numbers, handle "Episode X", "Ep. X", etc.
         let cleaned = text.replacingOccurrences(of: "Episodio", with: "", options: .caseInsensitive)
                             .replacingOccurrences(of: "Epizoda", with: "", options: .caseInsensitive)
                             .replacingOccurrences(of: "Episode", with: "", options: .caseInsensitive)
                             .replacingOccurrences(of: "Ep.", with: "", options: .caseInsensitive)
                             .replacingOccurrences(of: "الحلقة", with: "", options: .caseInsensitive) // Arabic for episode
                             .trimmingCharacters(in: .whitespacesAndNewlines)
        // Attempt to find the first sequence of digits (potentially with a decimal)
         if let range = cleaned.range(of: "^\\d+(\\.\\d+)?", options: .regularExpression) {
             return String(cleaned[range])
         }
         // Fallback if no number found at the start
         return cleaned.isEmpty ? "1" : cleaned // Fallback to original text or "1" if empty
     }

     // Helper to get the base URL for constructing full episode URLs
     private static func getBaseURL(for source: MediaSource, originalHref: String) -> String {
         switch source {
         case .animeWorld: return "https://animeworld.so"
         case .animeheaven: return "https://animeheaven.me/"
         case .animesrbija: return "https://www.animesrbija.com"
         case .aniworld: return "https://aniworld.to"
         case .tokyoinsider: return "https://www.tokyoinsider.com"
         case .anivibe: return "https://anivibe.net" // Verify base URL
         case .animebalkan: return "https://animebalkan.org" // Verify base URL
         case .anibunker: return "https://www.anibunker.com"
         case .animeflv: return "https://www3.animeflv.net"
         case .animeunity: return "https://www.animeunity.to"
         // Add other sources requiring base URL prepend
         default:
             // For sources where href is usually absolute or needs different handling
             if let url = URL(string: originalHref), let scheme = url.scheme, let host = url.host {
                 return "\(scheme)://\(host)" // Extract base from the provided href itself
             }
             return "" // Fallback
         }
     }

     // Specific parser for AnimeUnity episodes embedded in JSON
     private static func parseAnimeUnityEpisodes(document: Document, baseURL: String) -> [Episode] {
         do {
             let rawHtml = try document.html()
             // Find the video-player element and extract the episodes JSON string
             if let startIndex = rawHtml.range(of: "<video-player")?.upperBound,
                let endIndex = rawHtml.range(of: "</video-player>")?.lowerBound {
                 let videoPlayerContent = String(rawHtml[startIndex..<endIndex])
                 if let episodesStart = videoPlayerContent.range(of: "episodes=\"")?.upperBound,
                    let episodesEnd = videoPlayerContent[episodesStart...].range(of: "\"")?.lowerBound {

                     let episodesJson = String(videoPlayerContent[episodesStart..<episodesEnd])
                         .replacingOccurrences(of: """, with: "\"") // Decode HTML entities

                     if let episodesData = episodesJson.data(using: .utf8),
                        let episodesList = try? JSONSerialization.jsonObject(with: episodesData) as? [[String: Any]] {

                         return episodesList.compactMap { episodeDict in
                             guard let number = episodeDict["number"] as? String, !number.isEmpty,
                                   // 'link' might be the relative watch page URL
                                   let linkPath = episodeDict["link"] as? String else {
                                 print("Skipping AnimeUnity episode due to missing number or link.")
                                 return nil
                             }
                             // Construct full href using base URL and link path
                             let hrefFull = baseURL + linkPath
                             return Episode(number: number, href: hrefFull, downloadUrl: "")
                         }
                     } else {
                         print("Failed to parse episodes JSON from AnimeUnity attribute.")
                     }
                 } else {
                    print("Could not find episodes JSON attribute in AnimeUnity video-player tag.")
                 }
             } else {
                 print("Could not find video-player tag in AnimeUnity HTML.")
             }
         } catch {
             print("Error parsing AnimeUnity episodes: \(error)")
         }
         return []
     }

     // Specific parser for AnimeFLV episodes embedded in JavaScript
      private static func parseAnimeFLVJsonEpisodes(document: Document, baseURL: String) -> [Episode] {
         var episodes: [Episode] = []
         do {
             let scripts = try document.select("script")
             for script in scripts {
                 let scriptContent = try script.html()
                 // Find the script block containing `var episodes = [...]`
                 if scriptContent.contains("var episodes =") {
                     // Extract the JSON array string for episodes
                     if let rangeStart = scriptContent.range(of: "var episodes = ["),
                        let rangeEnd = scriptContent.range(of: "];", range: rangeStart.upperBound..<scriptContent.endIndex) {

                         let jsonArrayString = String(scriptContent[rangeStart.upperBound..<rangeEnd.lowerBound]) + "]"
                         // The format seems to be [[number, id], [number, id], ...]
                         if let data = jsonArrayString.data(using: .utf8),
                            let episodeData = try? JSONSerialization.jsonObject(with: data) as? [[Double]] { // Use Double to handle potential non-integer episode numbers if they exist

                             // Also need the anime info script block for the base URL part
                             if let infoScriptRangeStart = scriptContent.range(of: "var anime_info = "),
                                let infoScriptRangeEnd = scriptContent.range(of: "};", range: infoScriptRangeStart.upperBound..<scriptContent.endIndex),
                                let infoJsonString = String(scriptContent[infoScriptRangeStart.upperBound..<infoScriptRangeEnd.lowerBound] + "}")
                                    .data(using: .utf8),
                                let animeInfoJson = try? JSONSerialization.jsonObject(with: infoJsonString) as? [String: Any],
                                let animeSlug = animeInfoJson["slug"] as? String { // Get the anime slug

                                 let verBaseURL = baseURL.replacingOccurrences(of: "/anime/", with: "/ver/") // Base URL for viewing episodes

                                 episodes = episodeData.compactMap { episodePair in
                                     guard episodePair.count == 2 else { return nil }
                                     let episodeNumber = String(format: "%.0f", episodePair[0]) // Format as integer string
                                      // Construct href using the pattern: /ver/{slug}-{episodeNumber}
                                     let href = "\(verBaseURL)\(animeSlug)-\(episodeNumber)"
                                     return Episode(number: episodeNumber, href: href, downloadUrl: "")
                                 }
                                 // Break after finding the correct script block
                                 break
                             }
                         }
                     }
                 }
             }
         } catch {
             print("Error parsing AnimeFLV episodes from script: \(error)")
         }
         // Sort episodes numerically
         episodes.sort {
             (Int($0.number) ?? 0) < (Int($1.number) ?? 0)
         }
         return episodes
     }


}

// Helper extension for safe array access
extension Collection {
    subscript (safe index: Index) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}
