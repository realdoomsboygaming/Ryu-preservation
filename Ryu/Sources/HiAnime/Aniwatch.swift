// Ryu/Sources/HiAnime/Aniwatch.swift (or similar path)
import Foundation
import SwiftSoup // Make sure SwiftSoup is added via Swift Package Manager

// --- Error Handling ---
enum AniwatchError: Error {
    case networkError(String)
    case parsingError(String)
    case invalidURL
    case noEpisodes
    case noStreamingSources
    case jsonDecodingError(String)
    case dataExtractionError(String)
}

// --- Data Models ---

// Represents a search result item from Aniwatch/HiAnime
struct AnimeSearchResult: Hashable {
    let id: String
    let title: String
    let imageURL: String
    let type: String        // e.g., "TV", "Movie"
    let duration: String    // e.g., "23 min"
    let subCount: Int       // Number of subbed episodes
    let dubCount: Int       // Number of dubbed episodes
}

// Represents detailed information about a specific anime
struct AnimeDetails: Hashable {
    let id: String
    let title: String
    let imageURL: String
    let description: String
    let year: String        // e.g., "2023"
    let status: String      // e.g., "Finished Airing", "Currently Airing"
    let rating: String      // e.g., "8.5"
    let genres: [String]
    let episodes: [Episode] // Uses the Episode struct defined elsewhere or below
}

// Represents a single episode, assuming definition exists elsewhere or uncomment below
/*
struct Episode: Hashable, Codable {
    let id: String?         // Server-specific ID for fetching sources
    let number: String      // Episode number (e.g., "1", "12.5")
    let title: String?      // Optional episode title
    let href: String        // URL to the watch page for this episode
    let downloadUrl: String?// Optional direct download URL if available

    func hash(into hasher: inout Hasher) {
       hasher.combine(number)
       hasher.combine(href)
    }

    static func == (lhs: Episode, rhs: Episode) -> Bool {
       return lhs.number == rhs.number && lhs.href == rhs.href
    }
}
*/


// Represents a video server option (e.g., Vidstreaming, MegaCloud)
struct VideoServer: Codable, Hashable {
    let name: String
    let id: String // Server identifier used in API calls
}

// Represents a streaming source URL with its server name and type
struct StreamingSource: Codable, Hashable {
    let server: String
    let url: String    // The actual M3U8 or MP4 URL
    let type: String?  // Optional: "sub" or "dub" if available
}


// --- Service Class ---

class Aniwatch: NSObject {

    // Base URLs and paths for the Aniwatch/HiAnime site
    private let baseURL = "https://hianime.to"
    private let searchPath = "/search"
    private let ajaxBaseURL = "https://hianime.to/ajax"
    // Standard User-Agent to mimic a browser
    private let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Safari/605.1.15"

    private let session: URLSession

    override init() {
        // Configure URLSession with necessary headers
        let configuration = URLSessionConfiguration.default
        configuration.httpAdditionalHeaders = ["User-Agent": userAgent]
        self.session = URLSession(configuration: configuration)
        super.init()
    }

    // MARK: - Search Anime

    /// Fetches anime search results based on a query.
    /// - Parameters:
    ///   - query: The search term.
    ///   - page: The page number for pagination (default is 1).
    ///   - completion: Callback with the result (array of `AnimeSearchResult` or an error).
    func searchAnime(query: String, page: Int = 1, completion: @escaping (Result<[AnimeSearchResult], Error>) -> Void) {
        let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let urlString = "\(baseURL)\(searchPath)?keyword=\(encodedQuery)&page=\(page)"

        guard let url = URL(string: urlString) else {
            completion(.failure(AniwatchError.invalidURL))
            return
        }

        // Perform the data task
        let task = session.dataTask(with: url) { (data, response, error) in
            if let error = error {
                completion(.failure(AniwatchError.networkError(error.localizedDescription)))
                return
            }

            guard let data = data, let html = String(data: data, encoding: .utf8) else {
                completion(.failure(AniwatchError.parsingError("Failed to decode HTML")))
                return
            }

            // Parse the HTML response
            do {
                let results = try self.parseSearchResults(html: html)
                completion(.success(results))
            } catch {
                completion(.failure(error))
            }
        }
        task.resume()
    }

    /// Parses the HTML content of the search results page.
    /// - Parameter html: The HTML string to parse.
    /// - Returns: An array of `AnimeSearchResult`.
    /// - Throws: `AniwatchError.parsingError` if parsing fails.
    private func parseSearchResults(html: String) throws -> [AnimeSearchResult] {
        do {
            let doc: Document = try SwiftSoup.parse(html)
            var results: [AnimeSearchResult] = []
            // Selector for the main container of each search result item
            let items = try doc.select("div.flw-item")

            for item in items {
                // Use `guard let` with `try?` for safer unwrapping and error handling during parsing
                guard let titleElement = try item.select("h3.film-name a").first(),
                      let title = try? titleElement.text(), !title.isEmpty,
                      let idPath = try? titleElement.attr("href"), !idPath.isEmpty,
                      let imgElement = try item.select("img.film-poster-img").first() else {
                    print("Skipping item due to missing essential elements (title, id, or image).")
                    continue // Skip this item if essential info is missing
                }

                // Extract the anime ID from the href attribute
                let id = idPath.replacingOccurrences(of: "/", with: "") // Assumes ID is the last path component

                // Safely get image URL, checking both data-src and src attributes
                var imageURL = (try? imgElement.attr("data-src")) ?? (try? imgElement.attr("src")) ?? ""

                // Extract episode counts (Sub/Dub) safely
                var subCount = 0
                var dubCount = 0
                // Look for the element containing sub/dub counts
                if let episodeElement = try? item.select("div.tick-item.tick-sub, div.tick-item.tick-dub, .fd-infor .tick-item").first(where: { element in // Broader selector
                    guard let text = try? element.text() else { return false }
                    return text.contains("/") || text.contains("EP") // Check for common patterns
                }),
                   let episodeText = try? episodeElement.text() {
                    let cleanedText = episodeText.replacingOccurrences(of: "EP", with: "").trimmingCharacters(in: .whitespaces)
                    let counts = cleanedText.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }

                     if counts.count >= 1, let sub = Int(counts[0]) { subCount = sub }
                     // Check if dub count exists explicitly or assume sub is total if no "/"
                     if counts.count >= 2, let dub = Int(counts[1]) {
                        dubCount = dub
                     } else if counts.count == 1 { // Handle cases like "EP 12" -> assume sub
                         subCount = Int(counts[0]) ?? 0
                     }

                     // More specific selectors if the above is too broad
                     if let subElement = try? item.select(".tick-sub").first(), let subText = try? subElement.text().replacingOccurrences(of: "EP", with: "").trimmingCharacters(in: .whitespaces) {
                        subCount = Int(subText) ?? 0
                     }
                     if let dubElement = try? item.select(".tick-dub").first(), let dubText = try? dubElement.text().replacingOccurrences(of: "EP", with: "").trimmingCharacters(in: .whitespaces) {
                        dubCount = Int(dubText) ?? 0
                     }


                } else {
                    print("Could not find or parse episode count element for title: \(title)")
                }


                 // Extract Type and Duration safely using more specific selectors if possible
                let type = (try? item.select("span.fdi-item").first()?.text()) ?? "N/A" // Often the first item
                let duration = (try? item.select("span.fdi-item").array().dropFirst().first?.text()) ?? "N/A" // Often the second


                let result = AnimeSearchResult(
                    id: id,
                    title: title,
                    imageURL: imageURL,
                    type: type,
                    duration: duration,
                    subCount: subCount,
                    dubCount: dubCount
                )
                results.append(result)
            }
            return results
        } catch {
            // Wrap the SwiftSoup error in our custom error type
            throw AniwatchError.parsingError("Failed to parse search results HTML: \(error.localizedDescription)")
        }
    }

    // MARK: - Get Anime Details

    /// Fetches detailed information for a specific anime ID.
    /// - Parameters:
    ///   - id: The unique identifier for the anime (extracted from search results or URL).
    ///   - completion: Callback with the result (`AnimeDetails` or an error).
    func getAnimeDetails(id: String, completion: @escaping (Result<AnimeDetails, Error>) -> Void) {
        let urlString = "\(baseURL)/\(id)" // Construct URL for the anime detail page

        guard let url = URL(string: urlString) else {
            completion(.failure(AniwatchError.invalidURL))
            return
        }

        // Perform the data task
        let task = session.dataTask(with: url) { (data, response, error) in
            if let error = error {
                completion(.failure(AniwatchError.networkError(error.localizedDescription)))
                return
            }

            guard let data = data, let html = String(data: data, encoding: .utf8) else {
                completion(.failure(AniwatchError.parsingError("Failed to decode HTML")))
                return
            }

            // Parse the HTML response
            do {
                let details = try self.parseAnimeDetails(html: html, id: id)
                completion(.success(details))
            } catch {
                completion(.failure(error))
            }
        }
        task.resume()
    }

    /// Parses the HTML content of an anime detail page.
    /// - Parameters:
    ///   - html: The HTML string to parse.
    ///   - id: The anime ID (passed through for inclusion in the result).
    /// - Returns: An `AnimeDetails` object.
    /// - Throws: `AniwatchError.parsingError` if parsing fails.
    private func parseAnimeDetails(html: String, id: String) throws -> AnimeDetails {
        do {
            let doc: Document = try SwiftSoup.parse(html)

            // Extract title (safer unwrapping)
            let title = try doc.select("h2.film-name").first()?.text() ?? "Unknown Title"

            // Extract image URL (safer unwrapping)
            let imageElement = try doc.select("div.film-poster img").first()
            let imageURL = try imageElement?.attr("data-src") ?? (try imageElement?.attr("src")) ?? ""

            // Extract description (safer unwrapping)
            let description = try doc.select("div.film-description div.text").first()?.text() ?? "No description available."

            // Extract metadata (year, status, rating) with default values
            var year = "N/A"
            var status = "N/A"
            var rating = "N/A" // Changed from empty string to N/A for consistency

            let infoItems = try doc.select("div.anisc-info .item") // Selector for info items
            for item in infoItems {
                let head = try item.select(".item-head").text().lowercased() // e.g., "premiered:", "status:"
                let name = try item.select(".name, a").text() // Get text from span.name or nested link

                if head.contains("premiered") || head.contains("released") {
                    year = name
                } else if head.contains("status") {
                    status = name
                } else if head.contains("mal score") {
                    rating = name // Use MAL score if available
                } else if head.contains("rating") && rating == "N/A" { // Fallback to generic rating if MAL score wasn't found
                    rating = name
                }
            }

            // Extract genres (safer unwrapping)
            let genres = try doc.select("div.anisc-info .item a[href*='/genre/']").map { try $0.text() }

            // Parse episodes using the dedicated function
            let episodes = try parseEpisodes(doc: doc)

            return AnimeDetails(
                id: id,
                title: title,
                imageURL: imageURL,
                description: description,
                year: year,
                status: status,
                rating: rating,
                genres: genres,
                episodes: episodes
            )
        } catch {
            throw AniwatchError.parsingError("Failed to parse anime details HTML: \(error.localizedDescription)")
        }
    }

    /// Parses the episode list from the anime detail page HTML.
    /// - Parameter doc: The `Document` object representing the parsed HTML.
    /// - Returns: An array of `Episode` objects.
    /// - Throws: `AniwatchError.parsingError` if parsing fails.
    private func parseEpisodes(doc: Document) throws -> [Episode] {
        var episodes: [Episode] = []
        do {
            // Attempt to find the episode list container first
            guard let episodeListContainer = try doc.select("#episodes-content .ss-list").first() else {
                // Try an alternative selector if the primary one fails
                 guard let alternativeContainer = try doc.select("ul.sslist.scroll-area").first() else {
                    print("Could not find episode list container using primary or alternative selectors.")
                    return [] // No episodes found or container structure changed
                 }
                 // If alternative found, use it
                 let episodeElements = try alternativeContainer.select("a.ssl-item.ep-item")
                 guard !episodeElements.isEmpty() else {
                      print("No episode elements (a.ssl-item.ep-item) found within alternative container.")
                      return []
                  }
                 return try processEpisodeElements(episodeElements) // Process using helper
            }

            // If primary container found, proceed
            let episodeElements = try episodeListContainer.select("a.ssl-item.ep-item") // Selector for individual episode links

             guard !episodeElements.isEmpty() else {
                 print("No episode elements (a.ssl-item.ep-item) found within primary container.")
                 return []
             }
            episodes = try processEpisodeElements(episodeElements) // Process using helper

            return episodes

        } catch {
             throw AniwatchError.parsingError("Failed to parse episodes section: \(error.localizedDescription)")
        }
    }

    // Helper function to process the selected episode elements
    private func processEpisodeElements(_ elements: Elements) throws -> [Episode] {
        var episodes: [Episode] = []
         for element in elements {
             // Safely extract attributes and text
             let title = (try? element.attr("title")) ?? "Episode" // Default title if not found
             let numberText = (try? element.select("div.ssli-order").text()) ?? ""
             let numberClean = numberText.replacingOccurrences(of: "EP", with: "").trimmingCharacters(in: .whitespaces)
             let href = (try? element.attr("href")) ?? ""

             // Extract the episode ID from the href (more robustly)
             let episodeId = href.split(separator: "/").last?.split(separator: "?").first.map(String.init) ?? ""

             guard !href.isEmpty, !episodeId.isEmpty else {
                 print("Skipping episode due to missing href or ID. Title: \(title), Number: \(numberClean)")
                 continue // Skip if essential data is missing
             }


             let episode = Episode(
                  id: episodeId, // Use the extracted ID
                  number: numberClean,
                  title: title,
                  href: href, // Keep original href if needed elsewhere
                  downloadUrl: nil // Assuming no direct download URL here
             )
             episodes.append(episode)
         }
         // Sort by episode number safely
         episodes.sort { (ep1, ep2) -> Bool in
             guard let num1 = Double(ep1.number), let num2 = Double(ep2.number) else {
                  // Handle non-numeric or complex episode numbers (e.g., "12.5", "OVA 1")
                  // Simple string comparison as fallback, might need refinement for complex cases
                  return ep1.number.localizedStandardCompare(ep2.number) == .orderedAscending
             }
             return num1 < num2
         }
         return episodes
     }

    // MARK: - Get Episode Streaming Sources

    /// Fetches available streaming sources for a given episode ID.
    /// This typically involves multiple network requests.
    /// - Parameters:
    ///   - episodeId: The unique identifier for the episode (from `AnimeDetails.episodes`).
    ///   - completion: Callback with the result (array of `StreamingSource` or an error).
    func getStreamingSources(episodeId: String, completion: @escaping (Result<[StreamingSource], Error>) -> Void) {
        // 1. Fetch the available server IDs for the episode
        let serversURLString = "\(ajaxBaseURL)/episode/servers?episodeId=\(episodeId)"

        guard let serversURL = URL(string: serversURLString) else {
            completion(.failure(AniwatchError.invalidURL))
            return
        }

        var serversRequest = URLRequest(url: serversURL)
        serversRequest.httpMethod = "GET"
        serversRequest.addValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        serversRequest.addValue("\(baseURL)/watch/\(episodeId)", forHTTPHeaderField: "Referer") // Crucial Referer header

        let serversTask = session.dataTask(with: serversRequest) { [weak self] (data, response, error) in
            guard let self = self else { return }

            if let error = error {
                completion(.failure(AniwatchError.networkError("Failed to fetch servers: \(error.localizedDescription)")))
                return
            }

            guard let data = data else {
                completion(.failure(AniwatchError.parsingError("No data received for servers.")))
                return
            }

            do {
                // Parse the server list HTML response
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let htmlContent = json["html"] as? String else {
                    throw AniwatchError.parsingError("Invalid JSON format for servers.")
                }

                let doc: Document = try SwiftSoup.parse(htmlContent)
                // Select server items, potentially using a broader selector if needed
                let serverElements = try doc.select("div.server-item[data-id], div.ps__-list .server-item[data-id]")


                var servers: [VideoServer] = []
                for element in serverElements {
                    if let serverId = try? element.attr("data-id"), !serverId.isEmpty,
                       let serverName = try? element.text(), !serverName.isEmpty {
                       // Check for type (sub/dub) - might need adjustment based on actual HTML structure
                       let type = (try? element.attr("data-type")) ?? // Add fallback or default if needed

                       servers.append(VideoServer(name: serverName, id: serverId))
                    }
                }


                guard !servers.isEmpty else {
                    throw AniwatchError.noStreamingSources // No servers found
                }

                // --- Logic to select server and fetch sources ---
                // Prioritize preferred servers or types if logic exists
                // For now, fetching sources for ALL available servers
                 self.fetchAllVideoSources(episodeId: episodeId, servers: servers, completion: completion)
                 // --- End of server selection logic ---


            } catch let parseError as AniwatchError {
                completion(.failure(parseError))
            } catch {
                completion(.failure(AniwatchError.parsingError("Failed to parse server HTML: \(error.localizedDescription)")))
            }
        }
        serversTask.resume()
    }

    /// Fetches the actual streaming source URLs for multiple servers concurrently.
   private func fetchAllVideoSources(episodeId: String, servers: [VideoServer], completion: @escaping (Result<[StreamingSource], Error>) -> Void) {
       let group = DispatchGroup()
       var allSources: [StreamingSource] = []
       var firstError: Error?

       let syncQueue = DispatchQueue(label: "com.ryu.aniwatch.sourceSync") // For thread-safe appending

       for server in servers {
           group.enter()
           fetchVideoSource(episodeId: episodeId, serverId: server.id) { result in
               syncQueue.async { // Ensure thread safety when modifying shared array
                   switch result {
                   case .success(let sourcesFromServer):
                       // Add server name and type information to the sources
                       let sourcesWithServerInfo = sourcesFromServer.map { source -> StreamingSource in
                           // Attempt to infer type (sub/dub) from server name or source URL if possible
                           let inferredType = server.name.lowercased().contains("dub") ? "dub" : (server.name.lowercased().contains("sub") ? "sub" : nil)
                           return StreamingSource(server: server.name, url: source.url, type: inferredType ?? source.type)
                       }
                       allSources.append(contentsOf: sourcesWithServerInfo)
                   case .failure(let error):
                       print("Failed to fetch source for server \(server.name): \(error)")
                       if firstError == nil { firstError = error } // Keep track of the first error encountered
                   }
                   group.leave()
               }
           }
       }

       group.notify(queue: .main) {
           if !allSources.isEmpty {
               completion(.success(allSources))
           } else if let error = firstError {
               completion(.failure(error)) // Return the first error if all requests failed
           } else {
               completion(.failure(AniwatchError.noStreamingSources)) // No sources found even if no specific error occurred
           }
       }
   }



    /// Fetches the final streaming URL for a specific server ID.
    /// - Parameters:
    ///   - episodeId: The episode identifier.
    ///   - serverId: The server identifier.
    ///   - completion: Callback with the result (array containing one `StreamingSource` or an error).
    private func fetchVideoSource(episodeId: String, serverId: String, completion: @escaping (Result<[StreamingSource], Error>) -> Void) {
        let sourceURLString = "\(ajaxBaseURL)/episode/sources?id=\(serverId)"

        guard let sourceURL = URL(string: sourceURLString) else {
            completion(.failure(AniwatchError.invalidURL))
            return
        }

        var sourceRequest = URLRequest(url: sourceURL)
        sourceRequest.httpMethod = "GET"
        sourceRequest.addValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        sourceRequest.addValue("\(baseURL)/watch/\(episodeId)", forHTTPHeaderField: "Referer")

        let task = session.dataTask(with: sourceRequest) { (data, response, error) in
            if let error = error {
                completion(.failure(AniwatchError.networkError("Failed to fetch video sources: \(error.localizedDescription)")))
                return
            }

            guard let data = data else {
                completion(.failure(AniwatchError.parsingError("No data received for video sources.")))
                return
            }

            do {
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let link = json["link"] as? String else {
                    throw AniwatchError.parsingError("Invalid JSON format for sources.")
                }

                // --- Further Extraction Logic (if needed) ---
                // Check if the 'link' is an embed URL that requires further scraping
                 if link.contains("megacloud.tv") || link.contains("vidstreaming.io") || link.contains("streamtape.com") || link.contains("mp4upload.com") || link.contains("filemoon.sx") { // Add other known embed hosts
                    print("Found embed URL: \(link). Attempting further extraction...")
                     self.extractVideoFromEmbed(embedURL: link) { result in
                         completion(result.map { [StreamingSource(server: serverId, url: $0, type: nil)] }) // Wrap in array
                     }
                 } else {
                    // Assume it's a direct link (M3U8 or MP4)
                     let source = StreamingSource(server: serverId, url: link, type: nil)
                     completion(.success([source])) // Wrap in array
                 }
                // --- End of Further Extraction Logic ---

            } catch let parseError as AniwatchError {
                completion(.failure(parseError))
            } catch {
                completion(.failure(AniwatchError.parsingError("Failed to parse sources JSON: \(error.localizedDescription)")))
            }
        }
        task.resume()
    }


    /// Extracts the direct video source URL from common embed players.
    /// Needs specific implementation for each player type (MegaCloud, Vidstreaming, etc.).
    /// - Parameters:
    ///   - embedURL: The URL of the embed player page.
    ///   - completion: Callback with the result (direct video URL string or an error).
    private func extractVideoFromEmbed(embedURL: String, completion: @escaping (Result<String, Error>) -> Void) {
         guard let url = URL(string: embedURL) else {
            completion(.failure(AniwatchError.invalidURL))
            return
         }

        // --- Determine Host and Apply Specific Extraction Logic ---
         if embedURL.contains("megacloud.tv") {
             // Implement MegaCloud extraction logic (often involves API calls for encrypted sources)
             // Placeholder: Assume direct extraction for now, replace with actual logic
             print("Attempting MegaCloud extraction (placeholder)...")
              extractSourceFromGenericEmbed(url: url, pattern: "\"file\":\"(.*?)\"", completion: completion)

         } else if embedURL.contains("vidstreaming.io") || embedURL.contains("streamwish.to") {
            // Implement Vidstreaming/StreamWish extraction
            print("Attempting Vidstreaming/StreamWish extraction...")
             extractSourceFromGenericEmbed(url: url, pattern: "file:\\s*\"(https?://.*?)\"", completion: completion)

         } else if embedURL.contains("streamtape.com") {
             // Implement Streamtape extraction
             print("Attempting Streamtape extraction...")
              // Streamtape often requires finding a specific script variable or element ID
              // Example pattern (might need adjustment):
              extractSourceFromGenericEmbed(url: url, pattern: "document\\.getElementById\\('robotlink'\\)\\.innerHTML\\s*=\\s*'<a href=\"(//streamtape\\.com/get_video.*?)\"", fallbackPattern: "document\\.getElementById\\('norobotlink'\\)\\.innerHTML\\s*=\\s*'<a href=\"(//streamtape\\.com/get_video.*?)\"", completion: completion)


         } else if embedURL.contains("mp4upload.com") {
             // Implement MP4Upload extraction
             print("Attempting MP4Upload extraction...")
             extractSourceFromGenericEmbed(url: url, pattern: "player\\.src\\(\"([^\"]+)\"\\);", completion: completion)

         } else if embedURL.contains("filemoon.sx") || embedURL.contains("filemoon.to") {
             // Implement Filemoon extraction (often involves evaluating packed JS)
             print("Attempting Filemoon extraction (complex)...")
             // Placeholder: This usually requires more advanced JS evaluation
              extractSourceFromGenericEmbed(url: url, pattern: "file:\\s*\"(https?://.*?m3u8.*?)\"", completion: completion) // Look for m3u8


         } else {
            print("Unsupported embed host: \(embedURL)")
            completion(.failure(AniwatchError.parsingError("Unsupported embed host.")))
         }
         // --- End of Host Determination ---
    }

    /// Generic helper to fetch embed page content and apply a regex pattern.
    private func extractSourceFromGenericEmbed(url: URL, pattern: String, fallbackPattern: String? = nil, completion: @escaping (Result<String, Error>) -> Void) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.addValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.addValue(baseURL, forHTTPHeaderField: "Referer") // Referer can be crucial

        let task = session.dataTask(with: request) { (data, response, error) in
            if let error = error {
                completion(.failure(AniwatchError.networkError("Failed to fetch embed page: \(error.localizedDescription)")))
                return
            }

            guard let data = data, let html = String(data: data, encoding: .utf8) else {
                completion(.failure(AniwatchError.parsingError("Failed to decode embed HTML.")))
                return
            }

             // Function to try extracting with a given pattern
             func tryExtract(with p: String) -> String? {
                 guard let regex = try? NSRegularExpression(pattern: p) else { return nil }
                 let range = NSRange(html.startIndex..., in: html)
                 if let match = regex.firstMatch(in: html, range: range),
                    let urlRange = Range(match.range(at: 1), in: html) {
                    var extractedURL = String(html[urlRange])
                    // Ensure scheme is present for relative URLs (like Streamtape sometimes uses //)
                    if extractedURL.starts(with: "//") {
                        extractedURL = "https:\(extractedURL)"
                    }
                    // Remove potential escape characters
                    extractedURL = extractedURL.replacingOccurrences(of: "\\/", with: "/")
                     return extractedURL
                 }
                 return nil
             }

            // Try primary pattern
             if let finalURL = tryExtract(with: pattern) {
                 completion(.success(finalURL))
                 return
             }

             // Try fallback pattern if provided and primary failed
             if let fallback = fallbackPattern, let finalURL = tryExtract(with: fallback) {
                completion(.success(finalURL))
                return
             }


            // If both patterns fail
            completion(.failure(AniwatchError.parsingError("Could not find video source URL using pattern(s) in embed page: \(url)")))
        }
        task.resume()
    }

}
