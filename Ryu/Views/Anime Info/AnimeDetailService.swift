import UIKit
import Alamofire
import SwiftSoup // Ensure SwiftSoup is imported

// --- Data Models ---
struct AnimeDetail {
    let aliases: String
    let synopsis: String
    let airdate: String
    let stars: String
    let episodes: [Episode]
}

// Response model for Anilibria API
struct AnilibriaResponse: Decodable {
    let names: Names
    let description: String
    let season: Season
    let player: Player
    let inFavorites: Int
    
    struct Names: Decodable {
        let ru: String
        let en: String
    }
    
    struct Season: Decodable {
        let year: Int
        let string: String
    }
    
    struct Player: Decodable {
        let list: [String: Episode]
        
        struct Episode: Decodable {
            let hls: HLS
            
            struct HLS: Decodable {
                let fhd: String?
                let hd: String?
                let sd: String?
            }
        }
    }
}

// Service class responsible for fetching detailed anime information
class AnimeDetailService {
    // Use the shared Alamofire session, potentially configured with a proxy
    static let session = proxySession.createAlamofireProxySession() // Assuming proxySession is globally accessible

    // Fetches detailed anime information based on the selected source and href/id.
    static func fetchAnimeDetails(
        from href: String, 
        completion: @escaping (Result<AnimeDetail, Error>) -> Void
    ) {
        guard let selectedSource = UserDefaults.standard.selectedMediaSource else {
            completion(.failure(NSError(
                domain: "AnimeDetailService", 
                code: -1, 
                userInfo: [NSLocalizedDescriptionKey: "No media source selected."]
            )))
            return
        }

        // --- Handle HiAnime (Aniwatch) Source ---
        if selectedSource == .hianime {
            // Extract the ID from the href (e.g., "/one-piece-100" -> "one-piece-100")
            let animeId = href.split(separator: "/").last.map(String.init) ?? href

            guard !animeId.isEmpty else {
                completion(.failure(NSError(domain: "AnimeDetailService", code: -2, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"])))
                return
            }

            let aniwatchService = Aniwatch() // Instantiate the Aniwatch service
            aniwatchService.getAnimeDetails(id: animeId) { result in
                switch result {
                case .success(let aniwatchDetails):
                    // Map AniwatchDetails to the AnimeDetail struct
                    let mappedDetail = AnimeDetail(
                        aliases: "", // Aliases not directly provided by this API endpoint
                        synopsis: aniwatchDetails.description,
                        airdate: aniwatchDetails.year, // Map year to airdate
                        stars: aniwatchDetails.rating, // Map rating to stars
                        episodes: aniwatchDetails.episodes.map { aniwatchEpisode in
                            // Construct the relative watch URL path
                            let watchHref = "/watch/\(aniwatchDetails.id)?ep=\(aniwatchEpisode.id ?? "")"
                            return Episode(
                                number: aniwatchEpisode.number,
                                href: watchHref, // Use the watch page path as href
                                downloadUrl: "" // Download URL not provided here
                            )
                        }
                    )
                    completion(.success(mappedDetail))
                case .failure(let error):
                    completion(.failure(error)) // Forward the error
                }
            }
            return // Exit early for HiAnime
        }

        // --- Handle Other Sources (HTML Parsing or Specific APIs) ---

        // Determine base URL based on the source
        let baseUrl = getBaseURL(for: selectedSource, originalHref: href)

        // Handle Anilibria separately as it uses a JSON API with just the ID
        if selectedSource == .anilibria {
            let anilibriaFullUrl = baseUrl + href // Assuming href is the ID for Anilibria
            fetchAnilibriaDetails(from: anilibriaFullUrl, completion: completion)
            return // Exit early for Anilibria
        }

        // Construct full URL correctly for HTML sources
        let fullUrlString = href.starts(with: "http") ? href : baseUrl + href

        guard let fullUrl = URL(string: fullUrlString) else {
            completion(.failure(NSError(
                domain: "AnimeDetailService", 
                code: -2, 
                userInfo: [NSLocalizedDescriptionKey: "Invalid constructed URL: \(fullUrlString)"]
            )))
            return
        }

        // Fetch HTML content for parsing for non-API sources
        session.request(fullUrl).responseString { response in
            switch response.result {
            case .success(let html):
                do {
                    let document = try SwiftSoup.parse(html)
                    // Extract metadata using source-specific logic
                    let (aliases, synopsis, airdate, stars) = try extractMetadata(document: document, for: selectedSource)
                    // Pass the correct base URL for episode href construction if needed
                    let episodes = fetchEpisodes(document: document, for: selectedSource, href: fullUrlString)

                    let details = AnimeDetail(
                        aliases: aliases, 
                        synopsis: synopsis, 
                        airdate: airdate, 
                        stars: stars, 
                        episodes: episodes
                    )
                    completion(.success(details))
                } catch {
                    print("Error parsing HTML for \(selectedSource.rawValue): \(error)")
                    completion(.failure(error)) // Forward SwiftSoup parsing errors
                }
            case .failure(let error):
                print("Network error fetching details for \(selectedSource.rawValue) (\(fullUrlString)): \(error)")
                completion(.failure(error)) // Forward Alamofire network errors
            }
        }
    }

    // Helper function to fetch and parse Anilibria details
    private static func fetchAnilibriaDetails(
        from fullUrlString: String, 
        completion: @escaping (Result<AnimeDetail, Error>) -> Void
    ) {
        guard let url = URL(string: fullUrlString) else {
            completion(.failure(NSError(
                domain: "AnimeDetailService", 
                code: -2, 
                userInfo: [NSLocalizedDescriptionKey: "Invalid Anilibria URL"]
            )))
            return
        }

        session.request(url).responseDecodable(of: AnilibriaResponse.self) { response in
            switch response.result {
            case .success(let anilibriaResponse):
                let aliases = anilibriaResponse.names.en
                let synopsis = anilibriaResponse.description
                let airdate = "\(anilibriaResponse.season.year) \(anilibriaResponse.season.string)"
                let stars = "\(anilibriaResponse.inFavorites) Favorites" // Use favorites as rating indicator

                let episodes = anilibriaResponse.player.list.map { (key, value) -> Episode in
                    let episodeNumber = key
                    let hlsUrl = value.hls.fhd ?? value.hls.hd ?? value.hls.sd ?? ""
                    let streamUrl = hlsUrl.starts(with: "http") ? hlsUrl : "https://cache.libria.fun\(hlsUrl)"
                    return Episode(
                        number: episodeNumber, 
                        href: streamUrl, 
                        downloadUrl: ""
                    )
                }.sorted { (Int($0.number) ?? 0) < (Int($1.number) ?? 0) } // Sort numerically

                let details = AnimeDetail(
                    aliases: aliases, 
                    synopsis: synopsis, 
                    airdate: airdate, 
                    stars: stars, 
                    episodes: episodes
                )
                completion(.success(details))

            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    // Helper function to extract metadata based on source
    private static func extractMetadata(
        document: Document, 
        for source: MediaSource
    ) throws -> (aliases: String, synopsis: String, airdate: String, stars: String) {
        var aliases = ""
        var synopsis = ""
        var airdate = "N/A" // Default value
        var stars = "N/A" // Default value

        do { // Wrap potentially throwing operations
            switch source {
            case .animeWorld:
                aliases = try document.select("div.widget-title h1").attr("data-jtitle")
                synopsis = try document.select("div.info div.desc").text()
                airdate = try document.select("div.row dl.meta dt:contains(Data di Uscita) + dd").first()?.text() ?? "N/A"
                stars = try document.select("dd.rating span").text()
            case .gogoanime:
                aliases = try document.select("div.anime_info_body_bg p.other-name a").text()
                synopsis = try document.select("div.anime_info_body_bg div.description p").text()
                let typeParagraphs = try document.select("div.anime_info_body_bg p.type")
                airdate = try typeParagraphs.first(where: { try $0.text().contains("Released:") })?.select("span").last?.text() ?? "N/A"
                stars = "" // No rating available
            case .animeheaven:
                aliases = try document.select("div.infodiv div.infotitlejp").text()
                synopsis = try document.select("div.infodiv div.infodes").text()
                airdate = try document.select("div.infoyear div.c2").eq(1).text()
                stars = try document.select("div.infoyear div.c2").last()?.text() ?? "N/A"
            case .animefire:
                aliases = try document.select("div.mr-2 h6.text-gray").text()
                synopsis = try document.select("div.divSinopse span.spanAnimeInfo").text()
                airdate = try document.select("div.divAnimePageInfo span:contains(Ano:)").first()?.text().replacingOccurrences(of: "Ano: ", with: "").trimmingCharacters(in: .whitespaces) ?? "N/A"
                stars = try document.select("div.div_anime_score h4.text-white").text()
            case .kuramanime:
                aliases = try document.select("div.anime__details__title span").last()?.text() ?? ""
                synopsis = try document.select("div.anime__details__text p").text()
                airdate = try document.select("div.anime__details__widget ul li:has(div:contains(Status:)) span").text()
                stars = try document.select("div.anime__details__widget ul li:has(div:contains(Skor:)) span").text()
            case .anime3rb:
                aliases = try document.select("div.alias_title > p > strong").text()
                synopsis = try document.select("p.leading-loose").text()
                airdate = try document.select("div.MetaSingle__MetaItem:contains(سنة الإنتاج) span").text()
                stars = try document.select("div.Rate--Rank span.text-gray-400").text()
            case .animesrbija:
                aliases = try document.select("h3.anime-eng-name").text()
                let rawSynopsis = try document.select("div.anime-description").text()
                synopsis = rawSynopsis.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression, range: nil)
                airdate = try document.select("div.anime-information-col div:contains(Datum:)").first()?.text().replacingOccurrences(of: "Datum:", with: "").trimmingCharacters(in: .whitespaces) ?? "N/A"
                stars = try document.select("div.anime-information-col div:contains(MAL Ocena:)").first()?.text().replacingOccurrences(of: "MAL Ocena:", with: "").trimmingCharacters(in: .whitespaces) ?? "N/A"
            case .aniworld:
                aliases = try document.select(".series-title span[itemprop='alternateName']").text()
                synopsis = try document.select("p.seri_des[itemprop='description']").text()
                airdate = try document.select("span[itemprop='startDate']").text()
                stars = try document.select("span[itemprop='ratingValue']").text()
            case .tokyoinsider:
                aliases = try document.select("tr:contains(Alternative title) td").last()?.text() ?? ""
                synopsis = try document.select("tr:contains(Plot Summary) + tr td").text()
                airdate = try document.select("tr:contains(Vintage) td").last()?.text() ?? ""
                stars = try document.select("tr:contains(Rating) td").last()?.text().components(separatedBy: " (").first ?? ""
            case .anivibe:
                aliases = try document.select("span.alter").text()
                synopsis = try document.select("div.synp div.entry-content p").text()
                airdate = try document.select(".spe span:contains(Aired:)").first()?.parent()?.text().replacingOccurrences(of: "Aired:", with: "").trimmingCharacters(in: .whitespaces) ?? "N/A"
                stars = try document.select(".spe span:contains(Rating:)").first()?.parent()?.text().replacingOccurrences(of: "Rating:", with: "").trimmingCharacters(in: .whitespaces) ?? "N/A"
            case .animeunity:
                aliases = try document.select(".breadcrumb-item.active").text() // Often title is in breadcrumb
                synopsis = try document.select("div.desc").text()
                airdate = try document.select(".info div:contains(Stato) span, .info li:contains(Stato) span").text()
                stars = try document.select(".info div:contains(Voto) span, .info li:contains(Voto) span").text()
            case .animeflv:
                aliases = try document.select("span.TxtAlt").text()
                synopsis = try document.select("div.Description p").text()
                airdate = try document.select(".Ficha span.TxtDd:contains(Emitido)").first()?.nextElementSibling()?.text() ?? "N/A"
                stars = try document.select(".VotesCn span#votes_prmd").text()
            case .animebalkan:
                aliases = try document.select("span.alter").text()
                synopsis = try document.select("div.entry-content p").text()
                airdate = try document.select(".spe span:contains(Status) b").text()
                stars = try document.select(".rating strong").text()
            case .anibunker:
                aliases = try document.select("div.sinopse--title_alternative").text().replacingOccurrences(of: "Títulos alternativos: ", with: "")
                synopsis = try document.select("div.sinopse--display p").text()
                airdate = try document.select(".field-info:contains(Ano) a").text()
                stars = try document.select(".rt .rating-average").text()
            default:
                print("Metadata extraction not implemented or needed via HTML for source: \(source.rawValue)")
            }
        } catch {
            print("Error extracting metadata for \(source.rawValue): \(error)")
            // Return default values on error during extraction
            return ("", "", "N/A", "N/A")
        }

        // Return potentially updated values or defaults
        return (aliases, synopsis, airdate, stars)
    }

    // Helper function to parse episode list from HTML based on source
    private static func fetchEpisodes(
        document: Document, 
        for source: MediaSource, 
        href: String
    ) -> [Episode] {
        var episodes: [Episode] = []
        do {
            let episodeElements: Elements
            let baseURL = getBaseURL(for: source, originalHref: href)

            switch source {
            case .animeWorld:
                episodeElements = try document.select("div.server.active[data-id='1'] ul.episodes li.episode a")
            case .gogoanime:
                episodeElements = try document.select("ul#episode_page li a")
                return parseGoGoEpisodes(elements: episodeElements, categoryHref: href)
            case .animeheaven:
                episodeElements = try document.select("div.infoepboxinner a.infoa")
            case .animefire:
                episodeElements = try document.select("div.div_video_list a")
            case .kuramanime:
                if let episodeContent = try? document.select("div#episodeListsSection a.follow-btn").attr("data-content"), !episodeContent.isEmpty {
                    let episodeDocument = try SwiftSoup.parse(episodeContent)
                    episodeElements = try episodeDocument.select("a.btn")
                } else {
                    episodeElements = try document.select("div.anime__details__episodes a")
                }
            case .anime3rb:
                episodeElements = try document.select("div.EpisodesList div.row a.Episode--Sm")
            case .animesrbija:
                episodeElements = try document.select("ul.anime-episodes-holder li.anime-episode-item a.anime-episode-link")
            case .aniworld:
                print("AniWorld episode fetch deferred to multi-step logic (not done in this function).")
                return [] // Defer complex multi-fetch logic
            case .tokyoinsider:
                episodeElements = try document.select("div.episode a.download-link")
            case .anivibe, .animebalkan:
                episodeElements = try document.select("div.eplister ul li a")
            case .animeunity:
                return parseAnimeUnityEpisodes(document: document, baseURL: baseURL)
            case .animeflv:
                return parseAnimeFLVJsonEpisodes(document: document, baseURL: baseURL)
            case .anibunker:
                episodeElements = try document.select("div.eps-display a")
            // HiAnime and Anilibria fetch episodes via API, handled earlier
            case .hianime, .anilibria:
                return []
            }

            // Generic parsing loop
            episodes = try episodeElements.array().compactMap { element -> Episode? in
                guard let episodeTextRaw = try? element.text(), !episodeTextRaw.isEmpty,
                      let hrefPath = try? element.attr("href"), !hrefPath.isEmpty else {
                    return nil
                }
                let episodeNumber = extractEpisodeNumber(from: episodeTextRaw, for: source)
                let fullHref = hrefPath.starts(with: "http") ? hrefPath : baseURL + hrefPath
                return Episode(
                    number: episodeNumber,
                    href: fullHref,
                    downloadUrl: ""
                )
            }

            // Sort episodes numerically
            episodes.sort {
                EpisodeNumberExtractor.extract(from: $0.number) < EpisodeNumberExtractor.extract(from: $1.number)
            }

        } catch {
            print("Error parsing episodes for \(source.rawValue): \(error.localizedDescription)")
        }
        return episodes
    }

    // Helper to extract episode number string
    private static func extractEpisodeNumber(
        from text: String, 
        for source: MediaSource
    ) -> String {
        let cleaned = text.replacingOccurrences(of: "Episodio", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "Epizoda", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "Episode", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "Ep.", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "Folge", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "الحلقة", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        if let range = cleaned.range(of: "^\\d+(\\.\\d+)?", options: .regularExpression) {
            return String(cleaned[range])
        }
        return cleaned.isEmpty ? "1" : cleaned
    }

    // Helper to get the base URL for constructing full episode URLs
    private static func getBaseURL(
        for source: MediaSource, 
        originalHref: String
    ) -> String {
        switch source {
        case .animeWorld: return "https://animeworld.so"
        case .animeheaven: return "https://animeheaven.me/"
        case .animesrbija: return "https://www.animesrbija.com"
        case .aniworld: return "https://aniworld.to"
        case .tokyoinsider: return "https://www.tokyoinsider.com"
        case .anivibe: return "https://anivibe.net"
        case .animebalkan: return "https://animebalkan.org"
        case .anibunker: return "https://www.anibunker.com"
        case .animeflv: return "https://www3.animeflv.net"
        case .animeunity: return "https://www.animeunity.to"
        case .anilibria: return "https://api.anilibria.tv/v3/" // API Base
        // Add other sources requiring base URL prepend
        default:
            // For sources where href is usually absolute or needs different handling
            if let url = URL(string: originalHref), let scheme = url.scheme, let host = url.host {
                return "\(scheme)://\(host)" // Extract base from the provided href itself
            }
            return "" // Fallback
        }
    }

    // Specific parser for AnimeUnity episodes embedded in JSON attribute
    private static func parseAnimeUnityEpisodes(
        document: Document, 
        baseURL: String
    ) -> [Episode] {
        do {
            let rawHtml = try document.html()
            if let videoPlayerElement = try document.select("video-player").first(),
               let episodesJsonEncoded = try? videoPlayerElement.attr("episodes") {
                // Decode HTML entities like &quot;
                let episodesJson = episodesJsonEncoded.replacingOccurrences(of: "&quot;", with: "\"")

                if let episodesData = episodesJson.data(using: .utf8),
                   let episodesList = try? JSONSerialization.jsonObject(with: episodesData) as? [[String: Any]] {
                    return episodesList.compactMap { episodeDict in
                        guard let number = episodeDict["number"] as? String, !number.isEmpty,
                              let linkPath = episodeDict["link"] as? String else {
                            return nil
                        }
                        let hrefFull = baseURL + linkPath
                        return Episode(
                            number: number, 
                            href: hrefFull, 
                            downloadUrl: ""
                        )
                    }
                }
            }
        } catch {
            print("Error parsing AnimeUnity episodes: \(error)")
        }
        return []
    }

    // Specific parser for AnimeFLV episodes embedded in JavaScript
    private static func parseAnimeFLVJsonEpisodes(
        document: Document, 
        baseURL: String
    ) -> [Episode] {
        var episodes: [Episode] = []
        do {
            let scripts = try document.select("script")
            for script in scripts {
                let scriptContent = try script.html()
                if scriptContent.contains("var episodes =") {
                    if let rangeStart = scriptContent.range(of: "var episodes = ["),
                       let rangeEnd = scriptContent.range(of: "];", range: rangeStart.upperBound..<scriptContent.endIndex) {
                        let jsonArrayString = "[" + String(scriptContent[rangeStart.upperBound..<rangeEnd.lowerBound]) + "]" // Ensure valid JSON array format

                        if let data = jsonArrayString.data(using: .utf8),
                           let episodeData = try? JSONSerialization.jsonObject(with: data) as? [[Double]] {

                            if let infoScriptRangeStart = scriptContent.range(of: "var anime_info = "),
                               let infoScriptRangeEnd = scriptContent.range(of: "};", range: infoScriptRangeStart.upperBound..<scriptContent.endIndex),
                               let infoJsonStringAttempt = String(scriptContent[infoScriptRangeStart.upperBound..<infoScriptRangeEnd.lowerBound] + "}")
                                   .data(using: .utf8),
                               let animeInfoJson = try? JSONSerialization.jsonObject(with: infoJsonStringAttempt) as? [String: Any],
                               let animeSlug = animeInfoJson["slug"] as? String {

                                let verBaseURL = baseURL // Use the passed base URL

                                episodes = episodeData.compactMap { episodePair in
                                    guard episodePair.count == 2 else { return nil }
                                    let episodeNumber = String(format: "%.0f", episodePair[0])
                                    let href = "\(verBaseURL.replacingOccurrences(of: "/anime/", with: "/ver/"))\(animeSlug)-\(episodeNumber)"
                                    return Episode(
                                        number: episodeNumber, 
                                        href: href, 
                                        downloadUrl: ""
                                    )
                                }
                                break // Found the correct script block
                            }
                        }
                    }
                }
            }
        } catch { 
            print("Error parsing AnimeFLV episodes from script: \(error)") 
        }
        // Sort episodes numerically
        episodes.sort { (Int($0.number) ?? 0) < (Int($1.number) ?? 0) }
        return episodes
    }

    // Parses GoGoAnime episode ranges from the specific HTML structure
    static func parseGoGoEpisodes(
        elements: Elements, 
        categoryHref: String
    ) -> [Episode] {
        let animeSlug = categoryHref.replacingOccurrences(of: "/category/", with: "")
        var episodes: [Episode] = []
        do {
            for element in elements {
                guard let startStr = try? element.attr("ep_start"),
                      let endStr = try? element.attr("ep_end"),
                      let start = Int(startStr),
                      let end = Int(endStr) else { continue }

                let validStart = min(start, end)
                let validEnd = max(start, end)

                for episodeNumber in validStart...validEnd {
                    let formattedEpisode = "\(episodeNumber)"
                    guard formattedEpisode != "0" else { continue }
                    let episodeHref = "https://anitaku.to/\(animeSlug)-episode-\(episodeNumber)"
                    episodes.append(Episode(
                        number: formattedEpisode,
                        href: episodeHref,
                        downloadUrl: ""
                    ))
                }
            }
            // Sort episodes numerically
            episodes.sort { (Int($0.number) ?? 0) < (Int($1.number) ?? 0) }

        } catch { 
            print("Error parsing GoGoAnime episode ranges: \(error)") 
        }
        return episodes
    }
}
