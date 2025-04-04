import Foundation
import SwiftSoup

enum AniwatchError: Error {
    case networkError(String)
    case parsingError(String)
    case invalidURL
    case noEpisodes
    case noStreamingSources
}

class Aniwatch: NSObject {
    
    private let baseURL = "https://hianime.to"
    private let searchURL = "https://hianime.to/search"
    private let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Safari/605.1.15"
    
    // MARK: - Search Anime
    
    func searchAnime(query: String, page: Int = 1, completion: @escaping (Result<[AnimeSearchResult], Error>) -> Void) {
        let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let urlString = "\(searchURL)?keyword=\(encodedQuery)&page=\(page)"
        
        guard let url = URL(string: urlString) else {
            completion(.failure(AniwatchError.invalidURL))
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.addValue(userAgent, forHTTPHeaderField: "User-Agent")
        
        let session = URLSession.shared
        let task = session.dataTask(with: request) { (data, response, error) in
            if let error = error {
                completion(.failure(AniwatchError.networkError(error.localizedDescription)))
                return
            }
            
            guard let data = data, let html = String(data: data, encoding: .utf8) else {
                completion(.failure(AniwatchError.parsingError("Failed to decode HTML")))
                return
            }
            
            do {
                let results = try self.parseSearchResults(html: html)
                completion(.success(results))
            } catch {
                completion(.failure(error))
            }
        }
        
        task.resume()
    }
    
    private func parseSearchResults(html: String) throws -> [AnimeSearchResult] {
        do {
            let doc: Document = try SwiftSoup.parse(html)
            var results: [AnimeSearchResult] = []
            
            // The container for search results
            let items = try doc.select("div.flw-item")
            
            for item in items {
                let titleElement = try item.select("h3.film-name a")
                let title = try titleElement.text()
                let idPath = try titleElement.attr("href")
                let id = idPath.replacingOccurrences(of: "/", with: "")
                
                // Image handling
                let imgElement = try item.select("img.film-poster-img")
                var imageURL = try imgElement.attr("data-src")
                if imageURL.isEmpty {
                    imageURL = try imgElement.attr("src")
                }
                
                // Episode info
                var subCount = 0
                var dubCount = 0
                let episodeElement = try item.select("div.tick-sub")
                if !episodeElement.isEmpty() {
                    let episodeText = try episodeElement.text()
                    let components = episodeText.components(separatedBy: "/")
                    if components.count >= 2 {
                        if let sub = Int(components[0].trimmingCharacters(in: .whitespaces)) {
                            subCount = sub
                        }
                        if let dub = Int(components[1].trimmingCharacters(in: .whitespaces)) {
                            dubCount = dub
                        }
                    }
                }
                
                // Type and duration
                let typeElement = try item.select("div.fd-infor span.fdi-item:first-child")
                let durationElement = try item.select("div.fd-infor span.fdi-item:nth-child(2)")
                
                let type = try typeElement.text()
                let duration = try durationElement.text()
                
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
            throw AniwatchError.parsingError("Failed to parse search results: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Get Anime Details
    
    func getAnimeDetails(id: String, completion: @escaping (Result<AnimeDetails, Error>) -> Void) {
        let urlString = "\(baseURL)/\(id)"
        
        guard let url = URL(string: urlString) else {
            completion(.failure(AniwatchError.invalidURL))
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.addValue(userAgent, forHTTPHeaderField: "User-Agent")
        
        let session = URLSession.shared
        let task = session.dataTask(with: request) { (data, response, error) in
            if let error = error {
                completion(.failure(AniwatchError.networkError(error.localizedDescription)))
                return
            }
            
            guard let data = data, let html = String(data: data, encoding: .utf8) else {
                completion(.failure(AniwatchError.parsingError("Failed to decode HTML")))
                return
            }
            
            do {
                let details = try self.parseAnimeDetails(html: html, id: id)
                completion(.success(details))
            } catch {
                completion(.failure(error))
            }
        }
        
        task.resume()
    }
    
    private func parseAnimeDetails(html: String, id: String) throws -> AnimeDetails {
        do {
            let doc: Document = try SwiftSoup.parse(html)
            
            // Extract basic info
            let titleElement = try doc.select("h2.film-name")
            let title = try titleElement.text()
            
            // Extract image
            let imgElement = try doc.select("div.film-poster img")
            var imageURL = try imgElement.attr("data-src")
            if imageURL.isEmpty {
                imageURL = try imgElement.attr("src")
            }
            
            // Extract description
            let descElement = try doc.select("div.film-description p.text")
            let description = try descElement.text()
            
            // Extract metadata like year, status, etc.
            var year = ""
            var status = ""
            var rating = ""
            let metaElements = try doc.select("div.anisc-info div.item")
            
            for element in metaElements {
                let label = try element.select("span.item-head").text().lowercased()
                
                if label.contains("released") {
                    year = try element.select("span.name").text()
                } else if label.contains("status") {
                    status = try element.select("span.name").text()
                } else if label.contains("rating") {
                    rating = try element.select("span.name").text()
                }
            }
            
            // Extract genres
            var genres: [String] = []
            let genreElements = try doc.select("div.anisc-info div.item span.name a[href^='/genre/']")
            for genreElement in genreElements {
                genres.append(try genreElement.text())
            }
            
            // Extract episodes
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
            throw AniwatchError.parsingError("Failed to parse anime details: \(error.localizedDescription)")
        }
    }
    
    private func parseEpisodes(doc: Document) throws -> [Episode] {
        var episodes: [Episode] = []
        
        do {
            let episodeElements = try doc.select("div.ss-list a.ssl-item")
            
            for element in episodeElements {
                let title = try element.attr("title")
                let number = try element.select("div.ssli-order").text()
                let numberClean = number.replacingOccurrences(of: "EP", with: "").trimmingCharacters(in: .whitespaces)
                let episodeId = try element.attr("href").replacingOccurrences(of: "/watch/", with: "")
                
                let episode = Episode(
                    id: episodeId,
                    number: numberClean,
                    title: title
                )
                
                episodes.append(episode)
            }
            
            // Sort episodes in ascending order
            episodes.sort { (ep1, ep2) -> Bool in
                if let num1 = Int(ep1.number), let num2 = Int(ep2.number) {
                    return num1 < num2
                }
                return ep1.number < ep2.number
            }
            
            return episodes
        } catch {
            throw AniwatchError.parsingError("Failed to parse episodes: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Get Episode Streaming Sources
    
    func getStreamingSources(episodeId: String, completion: @escaping (Result<[StreamingSource], Error>) -> Void) {
        let urlString = "\(baseURL)/watch/\(episodeId)"
        
        guard let url = URL(string: urlString) else {
            completion(.failure(AniwatchError.invalidURL))
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.addValue(userAgent, forHTTPHeaderField: "User-Agent")
        
        let session = URLSession.shared
        let task = session.dataTask(with: request) { (data, response, error) in
            if let error = error {
                completion(.failure(AniwatchError.networkError(error.localizedDescription)))
                return
            }
            
            guard let data = data, let html = String(data: data, encoding: .utf8) else {
                completion(.failure(AniwatchError.parsingError("Failed to decode HTML")))
                return
            }
            
            do {
                // First extract the episode ID, server ID and encryption data
                let (episodeId, servers) = try self.extractVideoParams(html: html)
                
                // Once we have the server info, get the actual streaming sources
                self.fetchStreamingSources(episodeId: episodeId, servers: servers, completion: completion)
            } catch {
                completion(.failure(error))
            }
        }
        
        task.resume()
    }
    
    private func extractVideoParams(html: String) throws -> (String, [VideoServer]) {
        do {
            let doc: Document = try SwiftSoup.parse(html)
            
            // Extract the episode ID
            let scriptElements = try doc.select("script")
            var episodeId = ""
            var servers: [VideoServer] = []
            
            // Look for the script that contains the episode ID and servers
            for script in scriptElements {
                let scriptContent = try script.html()
                
                // Parse the episode ID
                if scriptContent.contains("var episodeId = ") {
                    let pattern = "var episodeId = ['\"]([^'\"]+)['\"]"
                    if let regex = try? NSRegularExpression(pattern: pattern),
                       let match = regex.firstMatch(in: scriptContent, range: NSRange(scriptContent.startIndex..., in: scriptContent)),
                       let range = Range(match.range(at: 1), in: scriptContent) {
                        episodeId = String(scriptContent[range])
                    }
                }
                
                // Parse the server data
                if scriptContent.contains("var servers = ") {
                    // This is more complex and usually needs JSON parsing
                    // Example: var servers = [{name: "Server1", id: "1"}, ...]
                    if let serversStart = scriptContent.range(of: "var servers = "),
                       let jsonStart = scriptContent.range(of: "[", range: serversStart.upperBound..<scriptContent.endIndex),
                       let jsonEnd = scriptContent.range(of: "];", range: jsonStart.upperBound..<scriptContent.endIndex) {
                        
                        let jsonString = scriptContent[jsonStart.lowerBound..<jsonEnd.lowerBound] + "]"
                        
                        // Clean up the JSON string (replace single quotes, fix property names without quotes)
                        let cleanJson = cleanupJsonString(String(jsonString))
                        
                        if let data = cleanJson.data(using: .utf8),
                           let jsonArray = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                            
                            for serverDict in jsonArray {
                                if let name = serverDict["name"] as? String,
                                   let serverId = serverDict["id"] as? String {
                                    let server = VideoServer(name: name, id: serverId)
                                    servers.append(server)
                                }
                            }
                        }
                    }
                }
            }
            
            // If we couldn't extract the servers from JavaScript, try the HTML elements
            if servers.isEmpty {
                let serverElements = try doc.select("div.servers-list div.server-item")
                for element in serverElements {
                    if let serverId = try? element.attr("data-id"),
                       let serverName = try? element.text() {
                        let server = VideoServer(name: serverName, id: serverId)
                        servers.append(server)
                    }
                }
            }
            
            if episodeId.isEmpty || servers.isEmpty {
                throw AniwatchError.parsingError("Failed to extract episode ID or servers")
            }
            
            return (episodeId, servers)
        } catch {
            throw AniwatchError.parsingError("Failed to extract video parameters: \(error.localizedDescription)")
        }
    }
    
    private func cleanupJsonString(_ jsonString: String) -> String {
        var cleaned = jsonString
        
        // Replace single quotes with double quotes
        cleaned = cleaned.replacingOccurrences(of: "'", with: "\"")
        
        // Add quotes to property names (regex to find property names without quotes)
        let pattern = "([{,])\\s*([a-zA-Z0-9_]+)\\s*:"
        let regex = try? NSRegularExpression(pattern: pattern)
        cleaned = regex?.stringByReplacingMatches(
            in: cleaned,
            range: NSRange(location: 0, length: cleaned.utf16.count),
            withTemplate: "$1\"$2\":"
        ) ?? cleaned
        
        return cleaned
    }
    
    private func fetchStreamingSources(episodeId: String, servers: [VideoServer], completion: @escaping (Result<[StreamingSource], Error>) -> Void) {
        // Pick a preferred server (usually the first one is the default)
        guard let server = servers.first else {
            completion(.failure(AniwatchError.noStreamingSources))
            return
        }
        
        let urlString = "\(baseURL)/ajax/episode/servers?episodeId=\(episodeId)"
        
        guard let url = URL(string: urlString) else {
            completion(.failure(AniwatchError.invalidURL))
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.addValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.addValue(baseURL, forHTTPHeaderField: "Referer")
        
        let session = URLSession.shared
        let task = session.dataTask(with: request) { [weak self] (data, response, error) in
            guard let self = self else { return }
            
            if let error = error {
                completion(.failure(AniwatchError.networkError(error.localizedDescription)))
                return
            }
            
            guard let data = data else {
                completion(.failure(AniwatchError.parsingError("Failed to get server data")))
                return
            }
            
            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let htmlContent = json["html"] as? String {
                    
                    // Now parse the HTML to get the actual video source URL
                    let doc: Document = try SwiftSoup.parse(htmlContent)
                    let sourceElements = try doc.select("div.server-item")
                    
                    var sources: [StreamingSource] = []
                    
                    for element in sourceElements {
                        let serverId = try element.attr("data-id")
                        let serverName = try element.text()
                        
                        if serverId == server.id {
                            // This is our target server, now we need to get the actual video URL
                            // This often requires another AJAX call
                            self.fetchVideoSource(episodeId: episodeId, serverId: serverId) { result in
                                switch result {
                                case .success(let sourceURL):
                                    let source = StreamingSource(
                                        server: serverName,
                                        url: sourceURL
                                    )
                                    sources.append(source)
                                    completion(.success(sources))
                                case .failure(let error):
                                    completion(.failure(error))
                                }
                            }
                            return
                        }
                    }
                    
                    if sources.isEmpty {
                        completion(.failure(AniwatchError.noStreamingSources))
                    }
                } else {
                    completion(.failure(AniwatchError.parsingError("Failed to parse server data")))
                }
            } catch {
                completion(.failure(AniwatchError.parsingError("Failed to parse server response: \(error.localizedDescription)")))
            }
        }
        
        task.resume()
    }
    
    private func fetchVideoSource(episodeId: String, serverId: String, completion: @escaping (Result<String, Error>) -> Void) {
        let urlString = "\(baseURL)/ajax/episode/sources?id=\(serverId)"
        
        guard let url = URL(string: urlString) else {
            completion(.failure(AniwatchError.invalidURL))
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.addValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.addValue(baseURL, forHTTPHeaderField: "Referer")
        
        let session = URLSession.shared
        let task = session.dataTask(with: request) { (data, response, error) in
            if let error = error {
                completion(.failure(AniwatchError.networkError(error.localizedDescription)))
                return
            }
            
            guard let data = data else {
                completion(.failure(AniwatchError.parsingError("Failed to get video source data")))
                return
            }
            
            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let link = json["link"] as? String {
                    
                    // Sometimes the link is a direct video URL, other times it's an embed URL
                    // If it's an embed URL, we need to extract the actual video URL
                    if link.contains("embed") || link.contains("player") {
                        self.extractVideoFromEmbed(embedURL: link, completion: completion)
                    } else {
                        completion(.success(link))
                    }
                } else {
                    completion(.failure(AniwatchError.parsingError("Failed to extract video URL")))
                }
            } catch {
                completion(.failure(AniwatchError.parsingError("Failed to parse video source: \(error.localizedDescription)")))
            }
        }
        
        task.resume()
    }
    
    private func extractVideoFromEmbed(embedURL: String, completion: @escaping (Result<String, Error>) -> Void) {
        guard let url = URL(string: embedURL) else {
            completion(.failure(AniwatchError.invalidURL))
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.addValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.addValue(baseURL, forHTTPHeaderField: "Referer")
        
        let session = URLSession.shared
        let task = session.dataTask(with: request) { (data, response, error) in
            if let error = error {
                completion(.failure(AniwatchError.networkError(error.localizedDescription)))
                return
            }
            
            guard let data = data, let html = String(data: data, encoding: .utf8) else {
                completion(.failure(AniwatchError.parsingError("Failed to decode embed HTML")))
                return
            }
            
            // Look for video URL in the HTML or JavaScript
            // This is highly dependent on the specific embed player
            
            // Common patterns to look for:
            // - "file":"URL" in JSON
            // - <source src="URL">
            // - player.src("URL")
            
            if let range = html.range(of: "\"file\":\""),
               let endRange = html.range(of: "\"", range: range.upperBound..<html.endIndex) {
                let videoURL = String(html[range.upperBound..<endRange.lowerBound])
                    .replacingOccurrences(of: "\\", with: "")
                completion(.success(videoURL))
                return
            }
            
            do {
                let doc: Document = try SwiftSoup.parse(html)
                if let sourceElement = try? doc.select("source").first(),
                   let srcAttr = try? sourceElement.attr("src"),
                   !srcAttr.isEmpty {
                    completion(.success(srcAttr))
                    return
                }
            } catch {
                // Continue with other extraction methods
            }
            
            // If we couldn't find the video URL, return a failure
            completion(.failure(AniwatchError.parsingError("Could not extract video URL from embed")))
        }
        
        task.resume()
    }
}

// MARK: - Data Models

struct AnimeSearchResult {
    let id: String
    let title: String
    let imageURL: String
    let type: String
    let duration: String
    let subCount: Int
    let dubCount: Int
}

struct AnimeDetails {
    let id: String
    let title: String
    let imageURL: String
    let description: String
    let year: String
    let status: String
    let rating: String
    let genres: [String]
    let episodes: [Episode]
}

struct Episode {
    let id: String
    let number: String
    let title: String
}

struct VideoServer {
    let name: String
    let id: String
}

struct StreamingSource {
    let server: String
    let url: String
}
