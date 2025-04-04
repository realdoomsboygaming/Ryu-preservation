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
import AVKit // Import AVKit for AVPlayerViewControllerDelegate if needed here
import GoogleCast // Import GoogleCast if GCKRemoteMediaClientListener conformance is here

// Note: Conformance to delegates like GCKRemoteMediaClientListener, AVPlayerViewControllerDelegate, SynopsisCellDelegate, CustomPlayerViewDelegate
// should typically reside in the main AnimeDetailViewController class declaration, not the extension,
// as they relate to the ViewController's overall behavior and lifecycle.
// However, keeping the implementation details of the source handling logic here is fine.

extension AnimeDetailViewController {

    // MARK: - Source Handling Logic

    func handleAniListSource(url: String, cell: EpisodeCell, fullURL: String) {
        guard let episodeId = extractAniListEpisodeId(from: url) else {
            print("Could not extract episodeId from URL")
            hideLoadingBannerAndShowAlert(title: "Error", message: "Could not extract episodeId from URL")
            return
        }

        fetchAniListEpisodeOptions(episodeId: episodeId) { [weak self] options in
            guard let self = self else { return }

            if options.isEmpty {
                print("No options available for this episode")
                self.hideLoadingBannerAndShowAlert(title: "Error", message: "No options available for this episode")
                return
            }

            let preferredAudio = UserDefaults.standard.string(forKey: "anilistAudioPref") ?? "Always Ask"
            let preferredServer = UserDefaults.standard.string(forKey: "anilistServerPref") ?? "Always Ask"

            self.selectAudioCategory(options: options, preferredAudio: preferredAudio) { category in
                guard let servers = options[category], !servers.isEmpty else {
                    print("No servers available for selected category: \(category)")
                    self.hideLoadingBannerAndShowAlert(title: "Error", message: "No servers available for '\(category.capitalized)' audio.")
                    return
                }

                self.selectServer(servers: servers, preferredServer: preferredServer) { server in
                    let urls = ["https://aniwatch-api-gp1w.onrender.com/anime/episode-srcs?id="]
                    let randomURL = urls.randomElement()!
                    let finalURL = "\(randomURL)\(episodeId)&category=\(category)&server=\(server)"

                    self.fetchAniListData(from: finalURL) { [weak self] sourceURL, captionURLs in
                        guard let self = self else { return }

                        self.hideLoadingBanner {
                            DispatchQueue.main.async {
                                guard let sourceURL = sourceURL else {
                                    print("Error extracting source URL")
                                    self.showAlert(title: "Error", message: "Error extracting source URL")
                                    return
                                }

                                self.selectSubtitles(captionURLs: captionURLs) { selectedSubtitleURL in
                                    let subtitleURL = selectedSubtitleURL ?? URL(string: "https://nosubtitlesfor.you")!
                                    let selectedPlayer = UserDefaults.standard.string(forKey: "mediaPlayerSelected") ?? "Default"
                                    let isToDownload = UserDefaults.standard.bool(forKey: "isToDownload")

                                    if isToDownload {
                                         self.handleDownload(sourceURL: sourceURL, fullURL: fullURL)
                                     } else {
                                          switch selectedPlayer {
                                          case "Custom":
                                               self.openHiAnimeExperimental(url: sourceURL, subURL: subtitleURL, cell: cell, fullURL: fullURL)
                                          case "WebPlayer":
                                                self.startStreamingButtonTapped(withURL: sourceURL.absoluteString, captionURL: subtitleURL.absoluteString, playerType: .playerWeb, cell: cell, fullURL: fullURL)
                                           case "Infuse", "VLC", "OutPlayer", "nPlayer":
                                               self.openInExternalPlayer(player: selectedPlayer, url: sourceURL)
                                           default: // "Default" player
                                               self.playVideoWithAVPlayer(sourceURL: sourceURL, cell: cell, fullURL: fullURL)
                                           }
                                      }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    func handleSources(url: String, cell: EpisodeCell, fullURL: String) {
        guard let requestURL = encodedURL(from: url) else {
            hideLoadingBannerAndShowAlert(title: "Error", message: "Invalid URL: \(url)")
            return
        }

        URLSession.shared.dataTask(with: requestURL) { [weak self] (data, response, error) in
            guard let self = self else { return }

            DispatchQueue.main.async {
                if let error = error {
                    self.hideLoadingBannerAndShowAlert(title: "Error", message: "Error fetching video data: \(error.localizedDescription)")
                    return
                }

                guard let data = data, let htmlString = String(data: data, encoding: .utf8) else {
                    self.hideLoadingBannerAndShowAlert(title: "Error", message: "Error parsing video data")
                    return
                }

                guard let selectedSource = self.displayedDataSource else {
                     self.hideLoadingBannerAndShowAlert(title: "Error", message: "Source information missing.")
                     return
                 }

                let gogoFetcher = UserDefaults.standard.string(forKey: "gogoFetcher") ?? "Default"
                var srcURL: URL?
                var playerTypeOverride: String? = nil

                switch selectedSource {
                case .gogoanime:
                    if gogoFetcher == "Default" { srcURL = self.extractIframeSourceURL(from: htmlString) }
                    else if gogoFetcher == "Secondary" { srcURL = self.extractDownloadLink(from: htmlString) }
                    playerTypeOverride = gogoFetcher == "Secondary" ? VideoPlayerType.standard : VideoPlayerType.playerGoGo2
                case .animefire:
                    srcURL = self.extractDataVideoSrcURL(from: htmlString)
                    if let fireURL = srcURL {
                        self.fetchVideoDataAndChooseQuality(from: fireURL.absoluteString) { selectedURL in
                            guard let finalURL = selectedURL else {
                                self.hideLoadingBannerAndShowAlert(title: "Error", message: "Failed to get AnimeFire video link.")
                                return
                            }
                            self.hideLoadingBanner { self.playVideo(sourceURL: finalURL, cell: cell, fullURL: fullURL) }
                        }
                        return
                    } else {
                         self.hideLoadingBannerAndShowAlert(title: "Error", message: "Failed to extract initial AnimeFire URL.")
                         return
                     }

                case .animeWorld, .animeheaven, .animebalkan:
                    srcURL = self.extractVideoSourceURL(from: htmlString)
                case .kuramanime:
                     srcURL = URL(string: fullURL)
                     playerTypeOverride = VideoPlayerType.playerKura
                 case .animesrbija:
                     srcURL = self.extractAsgoldURL(from: htmlString)
                 case .anime3rb:
                      self.anime3rbGetter(from: htmlString) { finalUrl in
                          if let url = finalUrl { self.hideLoadingBanner { self.playVideo(sourceURL: url, cell: cell, fullURL: fullURL) } }
                          else { self.hideLoadingBannerAndShowAlert(title: "Error", message: "Error extracting source URL for Anime3rb") }
                      }
                      return
                  case .anivibe:
                      srcURL = self.extractAniVibeURL(from: htmlString)
                  case .anibunker:
                      srcURL = self.extractAniBunker(from: htmlString)
                  case .tokyoinsider:
                      self.extractTokyoVideo(from: htmlString) { selectedURL in
                           DispatchQueue.main.async { self.hideLoadingBanner { self.playVideo(sourceURL: selectedURL, cell: cell, fullURL: fullURL) } }
                       }
                       return
                  case .aniworld:
                       self.extractVidozaVideoURL(from: htmlString) { videoURL in
                           guard let finalURL = videoURL else {
                               self.hideLoadingBannerAndShowAlert(title: "Error", message: "Error extracting source URL for AniWorld")
                               return
                           }
                           DispatchQueue.main.async { self.hideLoadingBanner { self.playVideo(sourceURL: finalURL, cell: cell, fullURL: fullURL) } }
                       }
                       return
                   case .animeunity:
                        self.extractEmbedUrl(from: htmlString) { finalUrl in
                            if let url = finalUrl { self.hideLoadingBanner { self.playVideo(sourceURL: url, cell: cell, fullURL: fullURL) } }
                            else { self.hideLoadingBannerAndShowAlert(title: "Error", message: "Error extracting source URL for AnimeUnity") }
                        }
                        return
                    case .animeflv:
                         self.extractStreamtapeQueryParameters(from: htmlString) { videoURL in
                             if let url = videoURL { self.hideLoadingBanner { self.playVideo(sourceURL: url, cell: cell, fullURL: fullURL) } }
                             else { self.hideLoadingBannerAndShowAlert(title: "Error", message: "Error extracting source URL for AnimeFLV") }
                         }
                         return
                     case .anilist, .anilibria: // Handled in playEpisode
                          print("Error: handleSources called unexpectedly for \(selectedSource.rawValue)")
                          self.hideLoadingBannerAndShowAlert(title: "Internal Error", message: "Source handling error.")
                          return
                 }

                guard let finalSrcURL = srcURL else {
                    self.hideLoadingBannerAndShowAlert(title: "Error", message: "The stream URL wasn't found.")
                    return
                }

                self.hideLoadingBanner {
                     DispatchQueue.main.async {
                          if let playerType = playerTypeOverride {
                               self.startStreamingButtonTapped(withURL: finalSrcURL.absoluteString, captionURL: "", playerType: playerType, cell: cell, fullURL: fullURL)
                           } else {
                                self.playVideo(sourceURL: finalSrcURL, cell: cell, fullURL: fullURL)
                            }
                      }
                 }
            }
        }.resume()
    }

    // MARK: - Selection Prompts

    func selectAudioCategory(options: [String: [[String: Any]]], preferredAudio: String, completion: @escaping (String) -> Void) {
        if let audioOptions = options[preferredAudio], !audioOptions.isEmpty {
            completion(preferredAudio)
        } else {
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
        if let server = servers.first(where: { ($0["serverName"] as? String) == preferredServer }) {
            completion(server["serverName"] as? String ?? "")
        } else {
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
            completion(nil)
            return
        }

        if let preferredSubtitles = UserDefaults.standard.string(forKey: "anilistSubtitlePref") {
            if preferredSubtitles == "No Subtitles" {
                completion(nil)
                return
            }
            if preferredSubtitles == "Always Import" {
                self.hideLoadingBanner {
                    self.importSubtitlesFromURL(completion: completion)
                }
                return
            }
            if let preferredURL = captionURLs[preferredSubtitles] {
                completion(preferredURL)
                return
            }
        }

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
                  let fileExtension = url.pathExtension.lowercased() as String?,
                  ["srt", "ass", "vtt"].contains(fileExtension) else {
                      self.showAlert(title: "Error", message: "Invalid subtitle URL. Must end with .srt, .ass, or .vtt")
                      completion(nil)
                      return
                  }

            self.downloadSubtitles(from: url, completion: completion)
        })

        presentAlert(alert)
    }


    private func downloadSubtitles(from url: URL, completion: @escaping (URL?) -> Void) {
        let task = URLSession.shared.downloadTask(with: url) { localURL, response, error in
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

            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(url.pathExtension)

            do {
                // Ensure the temp directory exists
                 try FileManager.default.createDirectory(at: FileManager.default.temporaryDirectory, withIntermediateDirectories: true, attributes: nil)
                 // If a file already exists at tempURL, remove it first
                  if FileManager.default.fileExists(atPath: tempURL.path) {
                      try FileManager.default.removeItem(at: tempURL)
                  }
                try FileManager.default.moveItem(at: localURL, to: tempURL)
                DispatchQueue.main.async {
                    completion(tempURL)
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
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let topController = scene.windows.first?.rootViewController {
            if UIDevice.current.userInterfaceIdiom == .pad {
                alert.modalPresentationStyle = .popover
                if let popover = alert.popoverPresentationController {
                    popover.sourceView = topController.view
                    popover.sourceRect = CGRect(x: topController.view.bounds.midX, y: topController.view.bounds.midY, width: 0, height: 0)
                    popover.permittedArrowDirections = []
                }
            }
            topController.present(alert, animated: true)
        } else {
            print("Could not find top view controller to present alert")
        }
    }

    // MARK: - AniList Specific Helpers

    func extractAniListEpisodeId(from url: String) -> String? {
        let components = url.components(separatedBy: "?id=")
        guard components.count >= 2 else { return nil }
        let episodeIdPart = components[1].components(separatedBy: "&").first // Get the part after ?id= and before &
        guard let episodeId = episodeIdPart else { return nil }

        // Find the category and server parts if they exist after episodeId
        var remainingParams = ""
        if let range = url.range(of: episodeId + "&") {
             remainingParams = String(url[range.upperBound...])
         } else if let range = url.range(of: episodeId + "?") { // Should not happen with ?id= but maybe edge case
              remainingParams = String(url[range.upperBound...])
          }

        // Construct the ID string needed for the servers/sources API
        // Example: zoro/steinsgate-3?ep=13499&sub=6078 -> steinsgate-3?ep=13499
         if let epRange = url.range(of: "?ep=") ?? url.range(of: "&ep=") {
              let idPartBeforeEp = String(url[url.range(of: "/watch/")!.upperBound..<epRange.lowerBound])
              let epPart = url[epRange.lowerBound...] // Includes ?ep=...
              // Find the end of the episode part (next '&' or end of string)
               let epEndRange = epPart.range(of: "&")?.lowerBound ?? epPart.endIndex
               let finalEpPart = String(epPart[..<epEndRange])
               return idPartBeforeEp + finalEpPart // Combine ID base + episode query part
           }


        return episodeId // Fallback to just the part after ?id= if ?ep= not found
    }

    func fetchAniListEpisodeOptions(episodeId: String, completion: @escaping ([String: [[String: Any]]]) -> Void) {
        let urls = ["https://aniwatch-api-gp1w.onrender.com/anime/servers?episodeId="] // Provided logic's URL

        let randomURL = urls.randomElement()!
        // Construct URL carefully: use the extracted ID which might contain query params like ?ep=...
        guard let fullURL = URL(string: "\(randomURL)\(episodeId)") else {
             print("Failed to construct AniList episode options URL")
             completion([:])
             return
         }


        URLSession.shared.dataTask(with: fullURL) { data, response, error in
            guard let data = data else {
                print("Error fetching AniList episode options: \(error?.localizedDescription ?? "Unknown error")")
                completion([:])
                return
            }

            do {
                if let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
                    // Extract sub, dub, raw based on the JSON structure provided by the API
                     // The example JSON had sub/dub/raw directly under the root
                     let raw = json["raw"] as? [[String: Any]] ?? []
                     let sub = json["sub"] as? [[String: Any]] ?? []
                     let dub = json["dub"] as? [[String: Any]] ?? []
                     completion(["raw": raw, "sub": sub, "dub": dub])
                 } else {
                      print("Invalid JSON format for AniList episode options")
                      completion([:])
                  }
            } catch {
                print("Error parsing AniList episode options: \(error.localizedDescription)")
                completion([:])
            }
        }.resume()
    }

    func presentDubSubRawSelection(options: [String: [[String: Any]]], preferredType: String, completion: @escaping (String) -> Void) {
        DispatchQueue.main.async {
            let rawOptions = options["raw"]
            let subOptions = options["sub"]
            let dubOptions = options["dub"]

            let availableOptions = [
                "raw": rawOptions,
                "sub": subOptions,
                "dub": dubOptions
            ].filter { $0.value != nil && !($0.value!.isEmpty) }

            if availableOptions.isEmpty {
                self.showAlert(title: "Error", message: "No audio options available")
                return
            }
            if availableOptions.count == 1, let onlyOption = availableOptions.first {
                completion(onlyOption.key)
                return
            }

            // Don't automatically complete with preferredType here, let the alert show
            // if availableOptions[preferredType] != nil {
            //    completion(preferredType)
            //    return
            // }

            let alert = UIAlertController(title: "Select Audio", message: nil, preferredStyle: .actionSheet)

            for (type, _) in availableOptions {
                let title = type.capitalized
                alert.addAction(UIAlertAction(title: title, style: .default) { _ in
                    completion(type)
                })
            }
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel)) // Add Cancel

            // Presenting logic
            if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let topController = scene.windows.first?.rootViewController {
                if UIDevice.current.userInterfaceIdiom == .pad {
                    alert.modalPresentationStyle = .popover
                    if let popover = alert.popoverPresentationController {
                        popover.sourceView = topController.view
                        popover.sourceRect = CGRect(x: topController.view.bounds.midX, y: topController.view.bounds.midY, width: 0, height: 0)
                        popover.permittedArrowDirections = []
                    }
                }
                topController.present(alert, animated: true, completion: nil)
            } else {
                print("Could not find top view controller to present alert")
            }
        }
    }


    func presentServerSelection(servers: [[String: Any]], completion: @escaping (String) -> Void) {
        let alert = UIAlertController(title: "Select Server", message: nil, preferredStyle: .actionSheet)

        for server in servers {
            if let serverName = server["serverName"] as? String,
               serverName != "streamtape" && serverName != "streamsb" { // Filter out
                alert.addAction(UIAlertAction(title: serverName, style: .default) { _ in
                    completion(serverName)
                })
            }
        }

         // Add cancel action if there are servers to choose from
          if !alert.actions.filter({ $0.style == .default }).isEmpty {
              alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: nil))
          } else {
               // If no valid servers, show an error message instead of an empty sheet
               showAlert(title: "Error", message: "No compatible servers found.")
               return // Don't present the empty sheet
           }


        // Presenting logic
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let topController = scene.windows.first?.rootViewController {
            if UIDevice.current.userInterfaceIdiom == .pad {
                alert.modalPresentationStyle = .popover
                if let popover = alert.popoverPresentationController {
                    popover.sourceView = topController.view
                    popover.sourceRect = CGRect(x: topController.view.bounds.midX, y: topController.view.bounds.midY, width: 0, height: 0)
                    popover.permittedArrowDirections = []
                }
            }
            topController.present(alert, animated: true, completion: nil)
        } else {
            print("Could not find top view controller to present alert")
        }
    }

    func fetchAniListData(from fullURL: String, completion: @escaping (URL?, [String: URL]?) -> Void) {
        guard let url = URL(string: fullURL) else {
            print("Invalid URL for AniList: \(fullURL)")
            completion(nil, nil)
            return
        }

        URLSession.shared.dataTask(with: url) { (data, response, error) in
            if let error = error {
                print("Error fetching AniList data: \(error.localizedDescription)")
                completion(nil, nil)
                return
            }

            guard let data = data else {
                print("Error: No data received from AniList")
                completion(nil, nil)
                return
            }

            do {
                if let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
                    var captionURLs: [String: URL] = [:]

                    if let tracks = json["tracks"] as? [[String: Any]] {
                        for track in tracks {
                            if let file = track["file"] as? String, let label = track["label"] as? String, track["kind"] as? String == "captions", let trackURL = URL(string: file) { // Ensure URL is valid
                                captionURLs[label] = trackURL
                            }
                        }
                    }

                    var sourceURL: URL?
                    if let sources = json["sources"] as? [[String: Any]] {
                        if let source = sources.first, let urlString = source["url"] as? String {
                             sourceURL = URL(string: urlString)
                        }
                    }

                    completion(sourceURL, captionURLs.isEmpty ? nil : captionURLs) // Return nil if no captions
                } else {
                     print("Invalid JSON format received from AniList source endpoint.")
                     completion(nil, nil)
                 }
            } catch {
                print("Error parsing AniList JSON: \(error.localizedDescription)")
                completion(nil, nil)
            }
        }.resume()
    }

    // MARK: - HTML Fetching and Parsing (Generic Helpers)

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
            guard let videoElement = try doc.select("video").first(),
                  let sourceElement = try videoElement.select("source").first(), // Prioritize <source> tag
                  let sourceURLString = try sourceElement.attr("src").nilIfEmpty,
                  let sourceURL = URL(string: sourceURLString) else {
                      // Fallback: Check video tag's src attribute directly
                      if let videoSrcString = try videoElement?.attr("src").nilIfEmpty, let videoSrcURL = URL(string: videoSrcString) {
                           return videoSrcURL
                       }
                      return nil
                  }
            return sourceURL
        } catch {
            print("Error parsing HTML with SwiftSoup for video source: \(error)")
            // Fallback Regex (less reliable)
            let mp4Pattern = #"<source src="(.*?)" type="video/mp4">"#
            let m3u8Pattern = #"<source src="(.*?)" type="application/x-mpegURL">"#
            let videoSrcPattern = #"<video[^>]+src="([^"]+)"#

            if let mp4URL = extractURL(from: htmlString, pattern: mp4Pattern) { return mp4URL }
            if let m3u8URL = extractURL(from: htmlString, pattern: m3u8Pattern) { return m3u8URL }
             if let videoSrcURL = extractURL(from: htmlString, pattern: videoSrcPattern) { return videoSrcURL }
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
            guard let iframeElement = try doc.select("iframe[src]").first(), // Be more specific
                  let sourceURLString = try iframeElement.attr("src").nilIfEmpty else {
                      return nil
                  }
            // Handle schema-relative URLs (e.g., //example.com)
             if sourceURLString.hasPrefix("//") {
                  return URL(string: "https:" + sourceURLString)
              }
            return URL(string: sourceURLString)
        } catch {
            print("Error parsing HTML with SwiftSoup for iframe: \(error)")
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

            let (data, _, error) = URLSession.shared.syncRequest(with: request) // Assuming syncRequest exists

            guard let data = data, error == nil else {
                print("Error making AniBunker POST request: \(error?.localizedDescription ?? "Unknown error")")
                return nil
            }

            if let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
               let success = json["success"] as? Bool, success,
               let urlString = json["url"] as? String,
               let url = URL(string: urlString) {
                return url
            } else {
                print("Error parsing AniBunker JSON response")
                return nil
            }
        } catch {
            print("Error parsing AniBunker HTML with SwiftSoup: \(error)")
            return nil
        }
    }


    func extractEmbedUrl(from rawHtml: String, completion: @escaping (URL?) -> Void) {
         // Find the <video-player> tag content
         if let startIndex = rawHtml.range(of: "<video-player")?.upperBound,
            let endIndex = rawHtml.range(of: "</video-player>")?.lowerBound {

             let videoPlayerContent = String(rawHtml[startIndex..<endIndex])

             // Extract the embed_url attribute value
             if let embedUrlStart = videoPlayerContent.range(of: "embed_url=\"")?.upperBound,
                let embedUrlEnd = videoPlayerContent[embedUrlStart...].range(of: "\"")?.lowerBound {

                 var embedUrl = String(videoPlayerContent[embedUrlStart..<embedUrlEnd])
                 embedUrl = embedUrl.replacingOccurrences(of: "&", with: "&") // Clean HTML entities

                 // Fetch content of embed_url to find the final video link
                 extractWindowUrl(from: embedUrl) { finalUrl in
                     completion(finalUrl)
                 }
                 return // Exit after starting the async fetch
             }
         }
         // If extraction fails at any point
         print("Could not extract embed_url from AnimeUnity")
         completion(nil)
     }

    private func extractWindowUrl(from urlString: String, completion: @escaping (URL?) -> Void) {
        guard let url = URL(string: urlString) else {
            completion(nil)
            return
        }

        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { data, response, error in
            guard let data = data,
                  let pageContent = String(data: data, encoding: .utf8) else {
                      DispatchQueue.main.async { completion(nil) }
                      return
                  }

            // Try extracting from `window.downloadUrl` first
             let downloadUrlPattern = #"window\.downloadUrl\s*=\s*['"]([^'"]+)['"]"#
             if let regex = try? NSRegularExpression(pattern: downloadUrlPattern),
                let match = regex.firstMatch(in: pageContent, range: NSRange(pageContent.startIndex..., in: pageContent)),
                let urlRange = Range(match.range(at: 1), in: pageContent) {
                 let downloadUrlString = String(pageContent[urlRange]).replacingOccurrences(of: "amp;", with: "")
                 if let downloadUrl = URL(string: downloadUrlString) {
                     DispatchQueue.main.async { completion(downloadUrl) }
                     return
                 }
             }

            // Fallback: Try extracting from `sources:[{file:"..."}]`
             let sourcesPattern = #"sources\s*:\s*\[\s*\{\s*file\s*:\s*['"]([^'"]+)['"]"#
              if let sourcesRegex = try? NSRegularExpression(pattern: sourcesPattern),
                 let sourcesMatch = sourcesRegex.firstMatch(in: pageContent, range: NSRange(pageContent.startIndex..., in: pageContent)),
                 let sourcesUrlRange = Range(sourcesMatch.range(at: 1), in: pageContent) {
                 let downloadUrlString = String(pageContent[sourcesUrlRange]).replacingOccurrences(of: "amp;", with: "")
                  if let downloadUrl = URL(string: downloadUrlString) {
                      DispatchQueue.main.async { completion(downloadUrl) }
                      return
                  }
              }


            // If neither pattern matches
            DispatchQueue.main.async { completion(nil) }
        }.resume()
    }

    func extractDataVideoSrcURL(from htmlString: String) -> URL? {
        do {
            let doc: Document = try SwiftSoup.parse(htmlString)
            // More specific selector if possible, e.g., targeting a specific container div first
            guard let element = try doc.select("div[data-video-src]").first() ?? doc.select("video[data-video-src]").first(), // Check div or video tag
                  let sourceURLString = try element.attr("data-video-src").nilIfEmpty,
                  let sourceURL = URL(string: sourceURLString) else {
                      return nil
                  }
            print("Data-video-src URL: \(sourceURL.absoluteString)")
            return sourceURL
        } catch {
            print("Error parsing HTML with SwiftSoup for data-video-src: \(error)")
            return nil
        }
    }


    func extractDownloadLink(from htmlString: String) -> URL? {
        do {
            let doc: Document = try SwiftSoup.parse(htmlString)
            // Look for download links within the specific container
            guard let downloadElement = try doc.select("li.dowloads a").first() ?? doc.select("div.dowload a").first(), // Try both common structures
                  let hrefString = try downloadElement.attr("href").nilIfEmpty,
                  let downloadURL = URL(string: hrefString) else {
                      return nil
                  }
            print("Download link URL: \(downloadURL.absoluteString)")
            return downloadURL
        } catch {
            print("Error parsing HTML with SwiftSoup for download link: \(error)")
            return nil
        }
    }


    func extractTokyoVideo(from htmlString: String, completion: @escaping (URL) -> Void) {
         let formats = UserDefaults.standard.bool(forKey: "otherFormats") ? ["mp4", "mkv", "avi"] : ["mp4"]

         DispatchQueue.global(qos: .userInitiated).async {
             do {
                 let doc = try SwiftSoup.parse(htmlString)
                 let combinedSelector = formats.map { "a[href*='media.tokyoinsider.com'][href$='.\($0)']" }.joined(separator: ", ")
                 let downloadElements = try doc.select(combinedSelector)

                 let foundURLs = downloadElements.compactMap { element -> (URL, String)? in
                     guard let hrefString = try? element.attr("href").nilIfEmpty, let url = URL(string: hrefString) else { return nil }
                     let filename = url.lastPathComponent
                     return (url, filename)
                 }

                 DispatchQueue.main.async {
                     guard !foundURLs.isEmpty else {
                         self.hideLoadingBannerAndShowAlert(title: "Error", message: "No valid video URLs found for TokyoInsider.")
                         return
                     }
                     if foundURLs.count == 1 { completion(foundURLs[0].0); return }

                     let alertController = UIAlertController(title: "Select Video Format", message: "Choose which video to play", preferredStyle: .actionSheet)
                      if UIDevice.current.userInterfaceIdiom == .pad {
                           if let popoverController = alertController.popoverPresentationController {
                               popoverController.sourceView = self.view
                               popoverController.sourceRect = CGRect(x: self.view.bounds.midX, y: self.view.bounds.midY, width: 0, height: 0)
                               popoverController.permittedArrowDirections = []
                           }
                       }
                     for (url, filename) in foundURLs {
                         alertController.addAction(UIAlertAction(title: filename, style: .default) { _ in completion(url) })
                     }
                     alertController.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in self.hideLoadingBanner() })
                     self.hideLoadingBanner { self.present(alertController, animated: true) }
                 }
             } catch {
                 DispatchQueue.main.async {
                     print("Error parsing TokyoInsider HTML: \(error)")
                     self.hideLoadingBannerAndShowAlert(title: "Error", message: "Error extracting video URLs for TokyoInsider.")
                 }
             }
         }
     }

    func extractAsgoldURL(from documentString: String) -> URL? {
        let pattern = "\"player2\":\"!https://video\\.asgold\\.pp\\.ua/video/[^\"]*\""
        do {
            let regex = try NSRegularExpression(pattern: pattern)
            let range = NSRange(documentString.startIndex..., in: documentString)
            if let match = regex.firstMatch(in: documentString, range: range),
               let matchRange = Range(match.range, in: documentString) {
                var urlString = String(documentString[matchRange])
                urlString = urlString.replacingOccurrences(of: "\"player2\":\"!", with: "")
                urlString = urlString.replacingOccurrences(of: "\"", with: "")
                return URL(string: urlString)
            }
        } catch { return nil }
        return nil
    }

    func extractAniVibeURL(from htmlContent: String) -> URL? {
        let pattern = #""url":"(.*?\.m3u8)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(htmlContent.startIndex..., in: htmlContent)
        guard let match = regex.firstMatch(in: htmlContent, range: range) else { return nil }
        if let urlRange = Range(match.range(at: 1), in: htmlContent) {
            let extractedURLString = String(htmlContent[urlRange])
            let unescapedURLString = extractedURLString.replacingOccurrences(of: "\\/", with: "/")
            return URL(string: unescapedURLString)
        }
        return nil
    }


    func extractStreamtapeQueryParameters(from htmlString: String, completion: @escaping (URL?) -> Void) {
        let streamtapePattern = #"https?://(?:www\.)?streamtape\.com/[^\s"']+"#
        guard let streamtapeRegex = try? NSRegularExpression(pattern: streamtapePattern),
              let streamtapeMatch = streamtapeRegex.firstMatch(in: htmlString, range: NSRange(htmlString.startIndex..., in: htmlString)),
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

        var request = URLRequest(url: streamtapeURL)
        request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/92.0.4515.159 Safari/537.36", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { data, response, error in
            guard let data = data, error == nil else {
                print("Error fetching Streamtape page: \(error?.localizedDescription ?? "Unknown error")")
                completion(nil)
                return
            }

            let responseHTML = String(data: data, encoding: .utf8) ?? ""
            let queryPattern = #"\?id=[^&]+&expires=\d+&ip=\w+&token=\S+(?=['"])"#
            guard let queryRegex = try? NSRegularExpression(pattern: queryPattern),
                  let queryMatch = queryRegex.firstMatch(in: responseHTML, range: NSRange(responseHTML.startIndex..., in: responseHTML)),
                  let queryRange = Range(queryMatch.range, in: responseHTML) else {
                print("Streamtape query parameters not found.")
                completion(nil)
                return
            }

            let queryString = String(responseHTML[queryRange])
            let fullURL = "https://streamtape.com/get_video" + queryString
            completion(URL(string: fullURL))
        }.resume()
    }

    // --- Anime3rb specific methods ---
     func anime3rbGetter(from documentString: String, completion: @escaping (URL?) -> Void) {
         guard let videoPlayerURL = extractAnime3rbVideoURL(from: documentString) else {
             completion(nil)
             return
         }
         extractAnime3rbMP4VideoURL(from: videoPlayerURL.absoluteString) { mp4Url in
             DispatchQueue.main.async { completion(mp4Url) }
         }
     }

     func extractAnime3rbVideoURL(from documentString: String) -> URL? {
         let pattern = "https://video\\.vid3rb\\.com/player/[\\w-]+\\?token=[\\w]+&(?:amp;)?expires=\\d+"
         do {
             let regex = try NSRegularExpression(pattern: pattern)
             let range = NSRange(documentString.startIndex..., in: documentString)
             if let match = regex.firstMatch(in: documentString, range: range),
                let matchRange = Range(match.range, in: documentString) {
                 let urlString = String(documentString[matchRange]).replacingOccurrences(of: "&", with: "&")
                 return URL(string: urlString)
             }
         } catch { return nil }
         return nil
     }

     func extractAnime3rbMP4VideoURL(from urlString: String, completion: @escaping (URL?) -> Void) {
         guard let url = URL(string: urlString) else { completion(nil); return }
         var request = URLRequest(url: url)
         request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36", forHTTPHeaderField: "User-Agent")

         URLSession.shared.dataTask(with: request) { data, response, error in
             guard let data = data, let pageContent = String(data: data, encoding: .utf8) else {
                 DispatchQueue.main.async { completion(nil) }
                 return
             }
             let mp4Pattern = #"https?://[^\s<>"]+?\.mp4[^\s<>"]*"#
             guard let regex = try? NSRegularExpression(pattern: mp4Pattern) else {
                 DispatchQueue.main.async { completion(nil) }
                 return
             }
             let range = NSRange(pageContent.startIndex..., in: pageContent)
             if let match = regex.firstMatch(in: pageContent, range: range),
                let urlRange = Range(match.range, in: pageContent) {
                 let urlString = String(pageContent[urlRange]).replacingOccurrences(of: "amp;", with: "")
                 DispatchQueue.main.async { completion(URL(string: cleanedUrlString)) } // Use cleaned
                 return
             }
             DispatchQueue.main.async { completion(nil) }
         }.resume()
     }


    // --- AnimeFire specific methods ---
     func fetchVideoDataAndChooseQuality(from urlString: String, completion: @escaping (URL?) -> Void) {
         guard let url = URL(string: urlString) else {
             print("Invalid URL string for AnimeFire")
             completion(nil)
             return
         }
         let task = URLSession.shared.dataTask(with: url) { data, response, error in
             guard let data = data, error == nil else {
                 print("AnimeFire Network error: \(String(describing: error))")
                 completion(nil)
                 return
             }
             do {
                 if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                    let videoDataArray = json["data"] as? [[String: Any]] {
                     var availableQualitiesDict: [String: String] = [:]
                     for videoData in videoDataArray {
                         if let label = videoData["label"] as? String, let src = videoData["src"] as? String {
                             availableQualitiesDict[label] = src
                         }
                     }
                     if availableQualitiesDict.isEmpty {
                         print("No available video qualities found for AnimeFire")
                         completion(nil)
                     } else {
                         DispatchQueue.main.async {
                             self.choosePreferredQuality(availableQualities: availableQualitiesDict, completion: completion)
                         }
                     }
                 } else {
                     print("AnimeFire JSON structure invalid or data key missing")
                     completion(nil)
                 }
             } catch {
                 print("Error parsing AnimeFire JSON: \(error)")
                 completion(nil)
             }
         }
         task.resume()
     }


     func choosePreferredQuality(availableQualities: [String: String], completion: @escaping (URL?) -> Void) {
         let preferredQuality = UserDefaults.standard.string(forKey: "preferredQuality") ?? "1080p"
         if let preferredUrlString = availableQualities[preferredQuality], let url = URL(string: preferredUrlString) {
             completion(url)
             return
         }
         let availableLabels = availableQualities.keys.sorted {
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
                      if qualityValue > (Int(closestQualityLabel?.replacingOccurrences(of: "p", with: "") ?? "0") ?? 0) {
                          closestQualityLabel = label
                      }
                  }
             }
         }
         if let finalQualityLabel = closestQualityLabel, let urlString = availableQualities[finalQualityLabel], let finalUrl = URL(string: urlString) {
             completion(finalUrl)
         } else if let fallbackQuality = availableQualities.values.first, let fallbackUrl = URL(string: fallbackQuality) {
              completion(fallbackUrl)
         } else {
             print("No suitable quality option found for AnimeFire")
             completion(nil)
         }
     }
}
