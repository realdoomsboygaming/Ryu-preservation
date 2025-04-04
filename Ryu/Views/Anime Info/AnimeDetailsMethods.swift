//
//  AnimeDetailsMethods.swift
//  Ryu
//
//  Created by Francesco on 19/09/24.
//

import UIKit
import SwiftSoup
import MobileCoreServices
import UniformTypeIdentifiers

extension AnimeDetailViewController {
    func selectAudioCategory(options: [String: [[String: Any]]], preferredAudio: String, completion: @escaping (String) -> Void) {
        // Check if the preferred audio option exists and is not empty
        if let audioOptions = options[preferredAudio], !audioOptions.isEmpty {
            completion(preferredAudio) // Use the preferred option directly
        } else {
            // Preferred option not available or empty, show selection dialog
            hideLoadingBanner {
                DispatchQueue.main.async {
                    self.presentDubSubRawSelection(options: options, preferredType: preferredAudio) { selectedCategory in
                        self.showLoadingBanner()
                        completion(selectedCategory)
                    }
                }
            }
        }
    }

    func selectServer(servers: [[String: Any]], preferredServer: String, completion: @escaping (String) -> Void) {
        // Check if the preferred server exists
        if let server = servers.first(where: { ($0["serverName"] as? String) == preferredServer }) {
            completion(server["serverName"] as? String ?? "") // Use the preferred server
        } else {
            // Preferred server not available, show selection dialog
            hideLoadingBanner {
                DispatchQueue.main.async {
                    self.presentServerSelection(servers: servers) { selectedServer in
                        self.showLoadingBanner()
                        completion(selectedServer)
                    }
                }
            }
        }
    }

    func selectSubtitles(captionURLs: [String: URL]?, completion: @escaping (URL?) -> Void) {
        guard let captionURLs = captionURLs, !captionURLs.isEmpty else {
            completion(nil) // No subtitles available
            return
        }

        // Check user preference
        if let preferredSubtitles = UserDefaults.standard.string(forKey: "anilistSubtitlePref") { // Updated key
            if preferredSubtitles == "No Subtitles" {
                completion(nil)
                return
            }
            if preferredSubtitles == "Always Import" {
                // Hide banner before showing import dialog
                self.hideLoadingBanner {
                    self.importSubtitlesFromURL(completion: completion)
                }
                return
            }
            // Check if preferred language exists in available captions
            if let preferredURL = captionURLs[preferredSubtitles] {
                completion(preferredURL)
                return
            }
        }

        // If no preference set, or preferred not available, show selection dialog
        hideLoadingBanner {
            DispatchQueue.main.async {
                self.presentSubtitleSelection(captionURLs: captionURLs, completion: completion)
            }
        }
    }

    func presentSubtitleSelection(captionURLs: [String: URL], completion: @escaping (URL?) -> Void) {
        let alert = UIAlertController(title: "Select Subtitle Source", message: nil, preferredStyle: .actionSheet)


        for (label, url) in captionURLs {
            alert.addAction(UIAlertAction(title: label, style: .default) { _ in
                completion(url)
            })
        }

        alert.addAction(UIAlertAction(title: "Import from a URL...", style: .default) { [weak self] _ in
            self?.importSubtitlesFromURL(completion: completion)
        })

        alert.addAction(UIAlertAction(title: "No Subtitles", style: .default) { _ in
            completion(nil)
        })

        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: nil))

        presentAlert(alert)
    }


    private func importSubtitlesFromURL(completion: @escaping (URL?) -> Void) {
        let alert = UIAlertController(title: "Enter Subtitle URL", message: "Enter the URL of the subtitle file (.srt, .ass, or .vtt)", preferredStyle: .alert)

        alert.addTextField { textField in
            textField.placeholder = "https://example.com/subtitles.srt"
            textField.keyboardType = .URL
            textField.autocorrectionType = .no
            textField.autocapitalizationType = .none
        }

        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))

        alert.addAction(UIAlertAction(title: "Import", style: .default) { [weak alert] _ in
            guard let urlString = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let url = URL(string: urlString),
                  let fileExtension = url.pathExtension.lowercased() as String?, // Safely get extension
                  ["srt", "ass", "vtt"].contains(fileExtension) else {
                      self.showAlert(title: "Error", message: "Invalid subtitle URL. Must end with .srt, .ass, or .vtt")
                      completion(nil)
                      return
                  }

            // Proceed to download
            self.downloadSubtitles(from: url, completion: completion)
        })

        presentAlert(alert)
    }


    private func downloadSubtitles(from url: URL, completion: @escaping (URL?) -> Void) {
        // Start download task
        let task = URLSession.shared.downloadTask(with: url) { localURL, response, error in
            // Check for errors and valid local URL
            guard let localURL = localURL,
                  error == nil,
                  let response = response as? HTTPURLResponse,
                  response.statusCode == 200 else {
                      DispatchQueue.main.async {
                          self.showAlert(title: "Error", message: "Failed to download subtitles")
                          completion(nil)
                      }
                      return
                  }

            // Create a unique temporary URL
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(url.pathExtension)

            // Move the downloaded file to the temporary location
            do {
                try FileManager.default.moveItem(at: localURL, to: tempURL)
                DispatchQueue.main.async {
                    completion(tempURL) // Return the URL of the saved file
                }
            } catch {
                print("Error moving downloaded file: \(error)")
                DispatchQueue.main.async {
                    self.showAlert(title: "Error", message: "Failed to save subtitles")
                    completion(nil)
                }
            }
        }

        task.resume()
    }

    private func presentAlert(_ alert: UIAlertController) {
        // Find the topmost view controller to present the alert
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let topController = scene.windows.first?.rootViewController {
            // Configure for iPad presentation
            if UIDevice.current.userInterfaceIdiom == .pad {
                alert.modalPresentationStyle = .popover
                if let popover = alert.popoverPresentationController {
                    popover.sourceView = topController.view
                    popover.sourceRect = CGRect(x: topController.view.bounds.midX, y: topController.view.bounds.midY, width: 0, height: 0)
                    popover.permittedArrowDirections = [] // Center without arrow
                }
            }
            topController.present(alert, animated: true)
        } else {
            print("Could not find top view controller to present alert")
        }
    }

    // Renamed function
    func extractAniListEpisodeId(from url: String) -> String? {
        let components = url.components(separatedBy: "?id=")
        guard components.count >= 2 else { return nil }
        let episodeId = components[1].components(separatedBy: "&").first
        guard let ep = components.last else { return nil }

        return episodeId.flatMap { "\($0)?\(ep)" }
    }

    // Renamed function
    func fetchAniListEpisodeOptions(episodeId: String, completion: @escaping ([String: [[String: Any]]]) -> Void) {
        let urls = ["https://aniwatch-api-gp1w.onrender.com/anime/servers?episodeId="] // Using provided logic's URL

        let randomURL = urls.randomElement()!
        let fullURL = URL(string: "\(randomURL)\(episodeId)")!

        URLSession.shared.dataTask(with: fullURL) { data, response, error in
            guard let data = data else {
                print("Error fetching episode options: \(error?.localizedDescription ?? "Unknown error")")
                completion([:])
                return
            }

            do {
                if let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                   let raw = json["raw"] as? [[String: Any]],
                   let sub = json["sub"] as? [[String: Any]],
                   let dub = json["dub"] as? [[String: Any]] {
                    completion(["raw": raw, "sub": sub, "dub": dub])
                } else {
                    completion([:])
                }
            } catch {
                print("Error parsing episode options: \(error.localizedDescription)")
                completion([:])
            }
        }.resume()
    }

    func presentDubSubRawSelection(options: [String: [[String: Any]]], preferredType: String, completion: @escaping (String) -> Void) {
        DispatchQueue.main.async {
            let rawOptions = options["raw"]
            let subOptions = options["sub"]
            let dubOptions = options["dub"]

            // Filter out nil or empty options
            let availableOptions = [
                "raw": rawOptions,
                "sub": subOptions,
                "dub": dubOptions
            ].filter { $0.value != nil && !($0.value!.isEmpty) }

            // Handle cases with no or only one option
            if availableOptions.isEmpty {
                print("No audio options available")
                self.showAlert(title: "Error", message: "No audio options available")
                // Consider how to handle this case - maybe default or return?
                return
            }
            if availableOptions.count == 1, let onlyOption = availableOptions.first {
                completion(onlyOption.key)
                return
            }

            // Check if preferred type is available
            if availableOptions[preferredType] != nil {
                // If preferred type exists and is valid, complete with it (moved check to selectAudioCategory)
                // completion(preferredType)
                // return // Removed this return to ensure the alert is shown if needed
            }

            // Show alert if preferred is not available or multiple options exist
            let alert = UIAlertController(title: "Select Audio", message: nil, preferredStyle: .actionSheet)

            for (type, _) in availableOptions {
                let title = type.capitalized // Capitalize for display
                alert.addAction(UIAlertAction(title: title, style: .default) { _ in
                    completion(type)
                })
            }

            // Find the topmost view controller to present the alert
            if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let topController = scene.windows.first?.rootViewController {
                // Configure for iPad presentation
                if UIDevice.current.userInterfaceIdiom == .pad {
                    alert.modalPresentationStyle = .popover
                    if let popover = alert.popoverPresentationController {
                        popover.sourceView = topController.view // Or a specific button if applicable
                        popover.sourceRect = CGRect(x: topController.view.bounds.midX, y: topController.view.bounds.midY, width: 0, height: 0)
                        popover.permittedArrowDirections = [] // Center without arrow
                    }
                }
                topController.present(alert, animated: true, completion: nil)
            } else {
                print("Could not find top view controller to present alert")
                // Handle error appropriately, maybe show a standard alert
            }
        }
    }


    func presentServerSelection(servers: [[String: Any]], completion: @escaping (String) -> Void) {
        let alert = UIAlertController(title: "Select Server", message: nil, preferredStyle: .actionSheet)

        for server in servers {
            if let serverName = server["serverName"] as? String,
               serverName != "streamtape" && serverName != "streamsb" { // Filter out specific servers
                alert.addAction(UIAlertAction(title: serverName, style: .default) { _ in
                    completion(serverName)
                })
            }
        }

        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: nil))

        // Find the topmost view controller to present the alert
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let topController = scene.windows.first?.rootViewController {
            // Configure for iPad presentation
            if UIDevice.current.userInterfaceIdiom == .pad {
                alert.modalPresentationStyle = .popover
                if let popover = alert.popoverPresentationController {
                    popover.sourceView = topController.view // Or a specific button if applicable
                    popover.sourceRect = CGRect(x: topController.view.bounds.midX, y: topController.view.bounds.midY, width: 0, height: 0)
                    popover.permittedArrowDirections = [] // Center without arrow
                }
            }
            topController.present(alert, animated: true, completion: nil)
        } else {
            print("Could not find top view controller to present alert")
            // Handle error appropriately
        }
    }

    // Renamed function
    func fetchAniListData(from fullURL: String, completion: @escaping (URL?, [String: URL]?) -> Void) {
        guard let url = URL(string: fullURL) else {
            print("Invalid URL for AniList: \(fullURL)") // Updated source name
            completion(nil, nil)
            return
        }

        URLSession.shared.dataTask(with: url) { (data, response, error) in
            if let error = error {
                print("Error fetching AniList data: \(error.localizedDescription)") // Updated source name
                completion(nil, nil)
                return
            }

            guard let data = data else {
                print("Error: No data received from AniList") // Updated source name
                completion(nil, nil)
                return
            }

            do {
                if let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
                    var captionURLs: [String: URL] = [:]

                    // Extract subtitles/tracks
                    if let tracks = json["tracks"] as? [[String: Any]] {
                        for track in tracks {
                            if let file = track["file"] as? String, let label = track["label"] as? String, track["kind"] as? String == "captions" {
                                captionURLs[label] = URL(string: file)
                            }
                        }
                    }

                    // Extract main video source URL
                    var sourceURL: URL?
                    if let sources = json["sources"] as? [[String: Any]] {
                        if let source = sources.first, let urlString = source["url"] as? String {
                             sourceURL = URL(string: urlString)
                        }
                    }

                    completion(sourceURL, captionURLs)
                }
            } catch {
                print("Error parsing AniList JSON: \(error.localizedDescription)") // Updated source name
                completion(nil, nil)
            }
        }.resume()
    }

    // --- HTML Fetching and Parsing (Keep existing ones as they are) ---

    func fetchHTMLContent(from url: String, completion: @escaping (Result<String, Error>) -> Void) {
        guard let url = URL(string: url) else {
            completion(.failure(NSError(domain: "Invalid URL", code: 0, userInfo: nil)))
            return
        }

        URLSession.shared.dataTask(with: url) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }

            guard let data = data, let htmlString = String(data: data, encoding: .utf8) else {
                completion(.failure(NSError(domain: "Invalid data", code: 0, userInfo: nil)))
                return
            }

            completion(.success(htmlString))
        }.resume()
    }

    func extractVideoSourceURL(from htmlString: String) -> URL? {
        do {
            let doc: Document = try SwiftSoup.parse(htmlString)
            // Prioritize video > source if available
            guard let videoElement = try doc.select("video").first(),
                  let sourceElement = try videoElement.select("source").first(),
                  let sourceURLString = try sourceElement.attr("src").nilIfEmpty,
                  let sourceURL = URL(string: sourceURLString) else {
                      // Fallback or error handling if structure isn't as expected
                      return nil
                  }
            return sourceURL
        } catch {
            print("Error parsing HTML with SwiftSoup: \(error)")
            // Fallback regex (might be less reliable)
            let mp4Pattern = #"<source src="(.*?)" type="video/mp4">"#
            let m3u8Pattern = #"<source src="(.*?)" type="application/x-mpegURL">"#

            if let mp4URL = extractURL(from: htmlString, pattern: mp4Pattern) {
                return mp4URL
            } else if let m3u8URL = extractURL(from: htmlString, pattern: m3u8Pattern) {
                return m3u8URL
            }
            return nil
        }
    }

    func extractURL(from htmlString: String, pattern: String) -> URL? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: htmlString, range: NSRange(htmlString.startIndex..., in: htmlString)),
              let urlRange = Range(match.range(at: 1), in: htmlString) else {
                  return nil
              }

        let urlString = String(htmlString[urlRange])
        return URL(string: urlString)
    }

    func extractIframeSourceURL(from htmlString: String) -> URL? {
        do {
            let doc: Document = try SwiftSoup.parse(htmlString)
            guard let iframeElement = try doc.select("iframe").first(),
                  let sourceURLString = try iframeElement.attr("src").nilIfEmpty,
                  let sourceURL = URL(string: sourceURLString) else {
                      return nil
                  }
            // Handle potential relative URLs or // prefixes if necessary
            let realSourceURL = "https:\(sourceURL)" // Assuming https if scheme is missing
            return URL(string: realSourceURL)
        } catch {
            print("Error parsing HTML with SwiftSoup: \(error)")
            return nil
        }
    }
    
    func extractAniBunker(from htmlString: String) -> URL? {
        do {
            let doc: Document = try SwiftSoup.parse(htmlString)
            guard let videoElement = try doc.select("div#videoContainer").first(),
                  let videoID = try videoElement.attr("data-video-id").nilIfEmpty else {
                return nil
            }

            let url = URL(string: "https://www.anibunker.com/php/loader.php")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("https://www.anibunker.com", forHTTPHeaderField: "Origin")
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

            let bodyString = "player_id=url_hd&video_id=\(videoID)"
            request.httpBody = bodyString.data(using: .utf8)

            let (data, _, error) = URLSession.shared.syncRequest(with: request)

            guard let data = data, error == nil else {
                print("Error making POST request: \(error?.localizedDescription ?? "Unknown error")")
                return nil
            }

            if let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
               let success = json["success"] as? Bool, success,
               let urlString = json["url"] as? String,
               let url = URL(string: urlString) {
                return url
            } else {
                print("Error parsing JSON response")
                return nil
            }
        } catch {
            print("Error parsing HTML with SwiftSoup: \(error)")
            return nil
        }
    }

    func extractEmbedUrl(from rawHtml: String, completion: @escaping (URL?) -> Void) {
        if let startIndex = rawHtml.range(of: "<video-player")?.upperBound,
           let endIndex = rawHtml.range(of: "</video-player>")?.lowerBound {

            let videoPlayerContent = String(rawHtml[startIndex..<endIndex])

            if let embedUrlStart = videoPlayerContent.range(of: "embed_url=\"")?.upperBound,
               let embedUrlEnd = videoPlayerContent[embedUrlStart...].range(of: "\"")?.lowerBound {

                var embedUrl = String(videoPlayerContent[embedUrlStart..<embedUrlEnd])
                // Clean potential HTML entities
                embedUrl = embedUrl.replacingOccurrences(of: "amp;", with: "")

                extractWindowUrl(from: embedUrl) { finalUrl in
                    completion(finalUrl)
                }
                return
            }
        }
        // If extraction fails
        completion(nil)
    }

    private func extractWindowUrl(from urlString: String, completion: @escaping (URL?) -> Void) {
        guard let url = URL(string: urlString) else {
            completion(nil)
            return
        }

        var request = URLRequest(url: url)
        // Set a realistic User-Agent
        request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { data, response, error in
            guard let data = data,
                  let pageContent = String(data: data, encoding: .utf8) else {
                      DispatchQueue.main.async {
                          completion(nil)
                      }
                      return
                  }

            // Regex to find the `window.downloadUrl` variable assignment
            let downloadUrlPattern = #"window\.downloadUrl\s*=\s*['"]([^'"]+)['"]"#

            guard let regex = try? NSRegularExpression(pattern: downloadUrlPattern, options: []) else {
                DispatchQueue.main.async {
                    completion(nil)
                }
                return
            }

            let range = NSRange(pageContent.startIndex..<pageContent.endIndex, in: pageContent)
            guard let match = regex.firstMatch(in: pageContent, options: [], range: range),
                  let urlRange = Range(match.range(at: 1), in: pageContent) else {
                // Try another common pattern if the first fails
                let sourcesPattern = #"sources:\[\{file:"([^"]+)"#
                if let sourcesRegex = try? NSRegularExpression(pattern: sourcesPattern),
                   let sourcesMatch = sourcesRegex.firstMatch(in: pageContent, options: [], range: range),
                   let sourcesUrlRange = Range(sourcesMatch.range(at: 1), in: pageContent) {
                       let downloadUrlString = String(pageContent[sourcesUrlRange])
                       let cleanedUrlString = downloadUrlString.replacingOccurrences(of: "amp;", with: "")
                       guard let downloadUrl = URL(string: cleanedUrlString) else {
                           DispatchQueue.main.async { completion(nil) }
                           return
                       }
                       DispatchQueue.main.async { completion(downloadUrl) }
                       return
                   }

                DispatchQueue.main.async { completion(nil) }
                return
            }

            let downloadUrlString = String(pageContent[urlRange])
            // Clean potential HTML entities again just in case
            let cleanedUrlString = downloadUrlString.replacingOccurrences(of: "amp;", with: "")

            guard let downloadUrl = URL(string: cleanedUrlString) else {
                DispatchQueue.main.async {
                    completion(nil)
                }
                return
            }

            DispatchQueue.main.async {
                completion(downloadUrl)
            }
        }.resume()
    }


    func extractDataVideoSrcURL(from htmlString: String) -> URL? {
        do {
            let doc: Document = try SwiftSoup.parse(htmlString)
            guard let element = try doc.select("[data-video-src]").first(),
                  let sourceURLString = try element.attr("data-video-src").nilIfEmpty,
                  let sourceURL = URL(string: sourceURLString) else {
                      return nil
                  }
            print("Data-video-src URL: \(sourceURL.absoluteString)")
            return sourceURL
        } catch {
            print("Error parsing HTML with SwiftSoup: \(error)")
            return nil
        }
    }

    func extractDownloadLink(from htmlString: String) -> URL? {
        do {
            let doc: Document = try SwiftSoup.parse(htmlString)
            guard let downloadElement = try doc.select("li.dowloads a").first(),
                  let hrefString = try downloadElement.attr("href").nilIfEmpty,
                  let downloadURL = URL(string: hrefString) else {
                      return nil
                  }
            print("Download link URL: \(downloadURL.absoluteString)")
            return downloadURL
        } catch {
            print("Error parsing HTML with SwiftSoup: \(error)")
            return nil
        }
    }

    func extractTokyoVideo(from htmlString: String, completion: @escaping (URL) -> Void) {
         let formats = UserDefaults.standard.bool(forKey: "otherFormats") ? ["mp4", "mkv", "avi"] : ["mp4"]

         DispatchQueue.global(qos: .userInitiated).async {
             do {
                 let doc = try SwiftSoup.parse(htmlString)
                 // Updated selector to be more robust
                 let combinedSelector = formats.map { "a[href*='media.tokyoinsider.com'][href$='.\($0)']" }.joined(separator: ", ")

                 let downloadElements = try doc.select(combinedSelector)

                 let foundURLs = downloadElements.compactMap { element -> (URL, String)? in
                     guard let hrefString = try? element.attr("href").nilIfEmpty,
                           let url = URL(string: hrefString) else { return nil }

                     let filename = url.lastPathComponent
                     return (url, filename)
                 }

                 DispatchQueue.main.async {
                     guard !foundURLs.isEmpty else {
                         self.hideLoadingBannerAndShowAlert(title: "Error", message: "No valid video URLs found")
                         return
                     }

                     // If only one URL is found, use it directly
                     if foundURLs.count == 1 {
                         completion(foundURLs[0].0)
                         return
                     }
                     // Present quality/format selection if multiple URLs found
                     let alertController = UIAlertController(title: "Select Video Format", message: "Choose which video to play", preferredStyle: .actionSheet)

                     // Configure for iPad
                     if UIDevice.current.userInterfaceIdiom == .pad {
                          if let popoverController = alertController.popoverPresentationController {
                              popoverController.sourceView = self.view // Present from the main view
                              popoverController.sourceRect = CGRect(x: self.view.bounds.midX, y: self.view.bounds.midY, width: 0, height: 0) // Center it
                              popoverController.permittedArrowDirections = [] // No arrow
                          }
                      }


                     for (url, filename) in foundURLs {
                         let action = UIAlertAction(title: filename, style: .default) { _ in
                             completion(url)
                         }
                         alertController.addAction(action)
                     }

                     let cancelAction = UIAlertAction(title: "Cancel", style: .cancel) { _ in
                        self.hideLoadingBanner() // Hide banner on cancel
                     }
                     alertController.addAction(cancelAction)

                     // Hide banner before presenting alert
                     self.hideLoadingBanner {
                         self.present(alertController, animated: true)
                     }
                 }
             } catch {
                 DispatchQueue.main.async {
                     print("Error parsing HTML with SwiftSoup: \(error)")
                     self.hideLoadingBannerAndShowAlert(title: "Error", message: "Error extracting video URLs")
                 }
             }
         }
     }


     func extractAsgoldURL(from documentString: String) -> URL? {
         // Regex to find the specific player URL structure
         let pattern = "\"player2\":\"!https://video\\.asgold\\.pp\\.ua/video/[^\"]*\""

         do {
             let regex = try NSRegularExpression(pattern: pattern, options: [])
             let range = NSRange(documentString.startIndex..<documentString.endIndex, in: documentString)

             if let match = regex.firstMatch(in: documentString, options: [], range: range),
                let matchRange = Range(match.range, in: documentString) {
                 // Extract the matched string part
                 var urlString = String(documentString[matchRange])
                 // Clean up the extracted string to get the pure URL
                 urlString = urlString.replacingOccurrences(of: "\"player2\":\"!", with: "")
                 urlString = urlString.replacingOccurrences(of: "\"", with: "")
                 return URL(string: urlString)
             }
         } catch {
             // Handle regex error if needed, though unlikely for a static pattern
             return nil
         }
         // Return nil if no match is found
         return nil
     }


    func extractAniVibeURL(from htmlContent: String) -> URL? {
        // Regex pattern to find the "url": "..." pattern containing .m3u8
        let pattern = #""url":"(.*?\.m3u8)""#

        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            print("Invalid regex pattern for AniVibe")
            return nil
        }

        let range = NSRange(htmlContent.startIndex..., in: htmlContent)
        guard let match = regex.firstMatch(in: htmlContent, range: range) else {
            print("No m3u8 URL found in AniVibe HTML")
            return nil
        }

        // Extract the captured group (the URL itself)
        if let urlRange = Range(match.range(at: 1), in: htmlContent) {
            let extractedURLString = String(htmlContent[urlRange])
            // Unescape any forward slashes if present
            let unescapedURLString = extractedURLString.replacingOccurrences(of: "\\/", with: "/")
            return URL(string: unescapedURLString)
        }

        return nil
    }


    func extractStreamtapeQueryParameters(from htmlString: String, completion: @escaping (URL?) -> Void) {
        // First, find the streamtape.com URL within the initial HTML
        let streamtapePattern = #"https?://(?:www\.)?streamtape\.com/[^\s"']+"#
        guard let streamtapeRegex = try? NSRegularExpression(pattern: streamtapePattern, options: []),
              let streamtapeMatch = streamtapeRegex.firstMatch(in: htmlString, options: [], range: NSRange(location: 0, length: htmlString.utf16.count)),
              let streamtapeRange = Range(streamtapeMatch.range, in: htmlString) else {
            print("Streamtape URL not found in HTML.")
            completion(nil)
            return
        }

        let streamtapeURLString = String(htmlString[streamtapeRange])
        guard let streamtapeURL = URL(string: streamtapeURLString) else {
            print("Invalid Streamtape URL.")
            completion(nil)
            return
        }

        // Now, fetch the content of the Streamtape page
        var request = URLRequest(url: streamtapeURL)
        request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/92.0.4515.159 Safari/537.36", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { data, response, error in
            guard let data = data, error == nil else {
                print("Error fetching Streamtape page: \(error?.localizedDescription ?? "Unknown error")")
                completion(nil)
                return
            }

            let responseHTML = String(data: data, encoding: .utf8) ?? ""

            // Regex to find the specific query parameters needed for get_video
            let queryPattern = #"\?id=[^&]+&expires=\d+&ip=\w+&token=\S+(?=['"])"# // Look for the query string ending before a ' or "
            guard let queryRegex = try? NSRegularExpression(pattern: queryPattern, options: []),
                  let queryMatch = queryRegex.firstMatch(in: responseHTML, options: [], range: NSRange(location: 0, length: responseHTML.utf16.count)),
                  let queryRange = Range(queryMatch.range, in: responseHTML) else {
                print("Query parameters not found.")
                completion(nil)
                return
            }

            let queryString = String(responseHTML[queryRange])
            let fullURL = "https://streamtape.com/get_video" + queryString // Construct the final URL

            completion(URL(string: fullURL)) // Return the final URL
        }.resume()
    }

    // --- Anime3rb specific methods ---
     func anime3rbGetter(from documentString: String, completion: @escaping (URL?) -> Void) {
         // 1. Extract the initial video player URL
         guard let videoPlayerURL = extractAnime3rbVideoURL(from: documentString) else {
             completion(nil)
             return
         }

         // 2. Fetch the content of that player URL and extract the MP4 source
         extractAnime3rbMP4VideoURL(from: videoPlayerURL.absoluteString) { mp4Url in
             DispatchQueue.main.async { // Ensure completion is called on the main thread
                 completion(mp4Url)
             }
         }
     }

     func extractAnime3rbVideoURL(from documentString: String) -> URL? {
         // Pattern to find the specific video player URL structure
         let pattern = "https://video\\.vid3rb\\.com/player/[\\w-]+\\?token=[\\w]+&(?:amp;)?expires=\\d+"

         do {
             let regex = try NSRegularExpression(pattern: pattern, options: [])
             let range = NSRange(documentString.startIndex..<documentString.endIndex, in: documentString)

             if let match = regex.firstMatch(in: documentString, options: [], range: range),
                let matchRange = Range(match.range, in: documentString) {
                 let urlString = String(documentString[matchRange])
                 // Clean potential HTML entities like &
                 let cleanedURLString = urlString.replacingOccurrences(of: "&", with: "&")
                 return URL(string: cleanedURLString)
             }
         } catch {
             // Handle regex error if needed
             return nil
         }
         // Return nil if no match is found
         return nil
     }

     func extractAnime3rbMP4VideoURL(from urlString: String, completion: @escaping (URL?) -> Void) {
         guard let url = URL(string: urlString) else {
             completion(nil)
             return
         }

         var request = URLRequest(url: url)
         // Set a realistic User-Agent if necessary
         request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36", forHTTPHeaderField: "User-Agent")

         URLSession.shared.dataTask(with: request) { data, response, error in
             guard let data = data,
                   let pageContent = String(data: data, encoding: .utf8) else {
                 // If fetching fails, return nil on the main thread
                 DispatchQueue.main.async {
                     completion(nil)
                 }
                 return
             }

             // Regex to find MP4 URLs within the player page content
             let mp4Pattern = #"https?://[^\s<>"]+?\.mp4[^\s<>"]*"# // More robust pattern

             guard let regex = try? NSRegularExpression(pattern: mp4Pattern, options: []) else {
                 DispatchQueue.main.async {
                     completion(nil)
                 }
                 return
             }

             let range = NSRange(pageContent.startIndex..<pageContent.endIndex, in: pageContent)
             if let match = regex.firstMatch(in: pageContent, options: [], range: range),
                let urlRange = Range(match.range, in: pageContent) {
                 let urlString = String(pageContent[urlRange])
                 // Clean potential HTML entities again
                 let cleanedUrlString = urlString.replacingOccurrences(of: "amp;", with: "")
                 let mp4Url = URL(string: cleanedUrlString)
                 // Return the found MP4 URL on the main thread
                 DispatchQueue.main.async {
                     completion(mp4Url)
                 }
                 return // Exit after finding the first match
             }

             // If no MP4 URL is found, return nil on the main thread
             DispatchQueue.main.async {
                 completion(nil)
             }
         }.resume()
     }

    // --- AnimeFire specific methods ---
     func fetchVideoDataAndChooseQuality(from urlString: String, completion: @escaping (URL?) -> Void) {
         guard let url = URL(string: urlString) else {
             print("Invalid URL string")
             completion(nil)
             return
         }

         // Make the network request to get the JSON data
         let task = URLSession.shared.dataTask(with: url) { data, response, error in
             guard let data = data, error == nil else {
                 print("Network error: \(String(describing: error))")
                 completion(nil)
                 return
             }

             do {
                 // Parse the JSON response
                 if let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                    let videoDataArray = json["data"] as? [[String: Any]] {

                     var availableQualitiesDict: [String: String] = [:] // Dictionary to store label -> src

                     // Extract available qualities and their URLs
                     for videoData in videoDataArray {
                         if let label = videoData["label"] as? String, let src = videoData["src"] as? String {
                             availableQualitiesDict[label] = src
                         }
                     }

                     if availableQualitiesDict.isEmpty {
                         print("No available video qualities found")
                         completion(nil)
                         return
                     }

                     // Choose the preferred or closest quality
                     DispatchQueue.main.async {
                         self.choosePreferredQuality(availableQualities: availableQualitiesDict, completion: completion)
                     }

                 } else {
                     print("JSON structure is invalid or data key is missing")
                     completion(nil)
                 }
             } catch {
                 print("Error parsing JSON: \(error)")
                 completion(nil)
             }
         }

         task.resume()
     }


    func choosePreferredQuality(availableQualities: [String: String], completion: @escaping (URL?) -> Void) {
        let preferredQuality = UserDefaults.standard.string(forKey: "preferredQuality") ?? "1080p" // Default to 1080p if not set

        // Check if the preferred quality exists directly
        if let preferredUrlString = availableQualities[preferredQuality], let url = URL(string: preferredUrlString) {
            completion(url)
            return
        }

        // If preferred quality not found, find the closest available quality
        let availableLabels = availableQualities.keys.sorted { // Sort numerically for closest match logic
            (Int($0.replacingOccurrences(of: "p", with: "")) ?? 0) > (Int($1.replacingOccurrences(of: "p", with: "")) ?? 0)
        }

        let preferredValue = Int(preferredQuality.replacingOccurrences(of: "p", with: "")) ?? 1080

        var closestQualityLabel: String? = nil
        var minDifference = Int.max

        for label in availableLabels {
            if let qualityValue = Int(label.replacingOccurrences(of: "p", with: "")) {
                let difference = abs(qualityValue - preferredValue)
                if difference < minDifference {
                    minDifference = difference
                    closestQualityLabel = label
                } else if difference == minDifference {
                     // If differences are equal, prefer higher quality
                     if qualityValue > (Int(closestQualityLabel?.replacingOccurrences(of: "p", with: "") ?? "0") ?? 0) {
                         closestQualityLabel = label
                     }
                 }
            }
        }


        // Get the URL for the chosen quality
        if let finalQualityLabel = closestQualityLabel, let urlString = availableQualities[finalQualityLabel], let finalUrl = URL(string: urlString) {
            completion(finalUrl)
        } else if let fallbackQuality = availableQualities.values.first, let fallbackUrl = URL(string: fallbackQuality) {
            // Fallback to the first available quality if closest logic fails (shouldn't happen if availableQualities is not empty)
             completion(fallbackUrl)
        }
        else {
            print("No suitable quality option found")
            completion(nil)
        }
    }
}
