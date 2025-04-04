import AVKit
import WebKit
import SwiftSoup
import GoogleCast

class ExternalVideoPlayer3rb: UIViewController, GCKRemoteMediaClientListener, WKNavigationDelegate, CustomPlayerViewDelegate { // Added WKNavigationDelegate, CustomPlayerViewDelegate
    private let streamURL: String
    private var webView: WKWebView?
    private var player: AVPlayer?
    private var playerViewController: AVPlayerViewController?
    private var activityIndicator: UIActivityIndicatorView?

    private var progressView: UIProgressView? // Not used, consider removing
    private var progressLabel: UILabel?      // Not used, consider removing

    private var retryCount = 0
    private let maxRetries: Int

    private var cell: EpisodeCell
    private var fullURL: String
    private weak var animeDetailsViewController: AnimeDetailViewController?
    private var timeObserverToken: Any?

    private var originalRate: Float = 1.0
    private var holdGesture: UILongPressGestureRecognizer?
    private var qualityOptions: [(label: String, url: URL)] = [] // Changed to store URLs directly

    init(streamURL: String, cell: EpisodeCell, fullURL: String, animeDetailsViewController: AnimeDetailViewController) {
        self.streamURL = streamURL
        self.cell = cell
        self.fullURL = fullURL
        self.animeDetailsViewController = animeDetailsViewController

        let userDefaultsRetries = UserDefaults.standard.integer(forKey: "maxRetries")
        self.maxRetries = userDefaultsRetries > 0 ? userDefaultsRetries : 10 // Use default 10

        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        loadInitialURL()
        setupHoldGesture()
        setupNotificationObserver()
    }

    private func setupNotificationObserver() {
        NotificationCenter.default.addObserver(self, selector: #selector(playerItemDidReachEnd), name: .AVPlayerItemDidPlayToEndTime, object: player?.currentItem)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        UserDefaults.standard.set(false, forKey: "isToDownload")
        cleanup()
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        if UserDefaults.standard.bool(forKey: "AlwaysLandscape") {
            return .landscape
        } else {
            return .all
        }
    }

    override var prefersHomeIndicatorAutoHidden: Bool {
        return true
    }

    override var childForHomeIndicatorAutoHidden: UIViewController? {
        return playerViewController
    }

    override var prefersStatusBarHidden: Bool {
        return true
    }

    override var childForStatusBarHidden: UIViewController? {
        return playerViewController
    }

    private func setupUI() {
        view.backgroundColor = .secondarySystemBackground
        setupActivityIndicator()
        setupWebView() // WebView is needed for initial extraction
    }

    private func setupHoldGesture() {
        holdGesture = UILongPressGestureRecognizer(target: self, action: #selector(handleHoldGesture(_:)))
        holdGesture?.minimumPressDuration = 0.5
        if let holdGesture = holdGesture {
            view.addGestureRecognizer(holdGesture)
        }
    }

    @objc private func handleHoldGesture(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began: beginHoldSpeed()
        case .ended, .cancelled: endHoldSpeed()
        default: break
        }
    }

    private func beginHoldSpeed() {
        guard let player = player else { return }
        originalRate = player.rate
        let holdSpeed = UserDefaults.standard.float(forKey: "holdSpeedPlayer")
        player.rate = holdSpeed > 0 ? holdSpeed : 2.0 // Use default if invalid
    }

    private func endHoldSpeed() {
        player?.rate = originalRate
    }

    private func setupActivityIndicator() {
        activityIndicator = UIActivityIndicatorView(style: .large)
        activityIndicator?.translatesAutoresizingMaskIntoConstraints = false
        activityIndicator?.hidesWhenStopped = true

        if let activityIndicator = activityIndicator {
            view.addSubview(activityIndicator)

            NSLayoutConstraint.activate([
                activityIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                activityIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor)
            ])

            activityIndicator.startAnimating()
        }
    }

    private func setupWebView() {
         let configuration = WKWebViewConfiguration()
         webView = WKWebView(frame: .zero, configuration: configuration)
         webView?.navigationDelegate = self
         // Keep webview hidden as it's only for background extraction
         webView?.isHidden = true
         if let webView = webView {
             view.insertSubview(webView, at: 0) // Add behind activity indicator
             webView.translatesAutoresizingMaskIntoConstraints = false
             NSLayoutConstraint.activate([
                 webView.topAnchor.constraint(equalTo: view.topAnchor),
                 webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                 webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                 webView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
             ])
         }
     }


    private func loadInitialURL() {
        guard let url = URL(string: streamURL) else {
            print("Invalid stream URL")
            activityIndicator?.stopAnimating()
            showAlert(title: "Error", message: "Invalid stream URL.")
            return
        }
        let request = URLRequest(url: url)
        webView?.load(request)
    }

    private func loadIframeContent(url: URL) {
        print("Loading iframe content from: \(url.absoluteString)")
        let request = URLRequest(url: url)
        webView?.load(request)
        // Instead of a fixed delay, rely on webViewDidFinish to trigger extraction
    }


    private func extractIframeSource() {
        webView?.evaluateJavaScript("document.documentElement.outerHTML") { [weak self] (result, error) in // Use outerHTML
            guard let self = self, let htmlString = result as? String else {
                print("Error getting HTML for iframe extraction: \(error?.localizedDescription ?? "Unknown error")")
                self.retryExtraction()
                return
            }

            if let iframeURL = self.extractIframeSourceURL(from: htmlString) {
                print("Iframe src URL found: \(iframeURL.absoluteString)")
                self.loadIframeContent(url: iframeURL)
            } else {
                print("No iframe source found in initial page.")
                // Check if the video source is directly on this page
                if let qualityOptions = self.extractQualityOptions(from: htmlString) {
                    self.qualityOptions = qualityOptions
                    DispatchQueue.main.async {
                        self.selectQuality()
                    }
                } else {
                    self.retryExtraction() // Retry if neither iframe nor direct video found
                }
            }
        }
    }


    private func extractVideoSource() {
        webView?.evaluateJavaScript("document.documentElement.outerHTML") { [weak self] (result, error) in // Use outerHTML
            guard let self = self, let htmlString = result as? String else {
                print("Error getting HTML for video source extraction: \(error?.localizedDescription ?? "Unknown error")")
                self.retryExtraction()
                return
            }

            if let qualityOptions = self.extractQualityOptions(from: htmlString) {
                 print("Extracted quality options: \(qualityOptions)")
                self.qualityOptions = qualityOptions
                DispatchQueue.main.async {
                    self.selectQuality()
                }
            } else {
                print("No video source found in iframe content")
                self.retryExtraction()
            }
        }
    }

     private func extractQualityOptions(from htmlString: String) -> [(label: String, url: URL)]? {
         // Regex pattern to find the 'var videos = [...]' block
         let pattern = #"var\s+videos\s*=\s*\[(.*?)\]"#
         guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
               let match = regex.firstMatch(in: htmlString, range: NSRange(htmlString.startIndex..., in: htmlString)),
               let videosArrayRange = Range(match.range(at: 1), in: htmlString) else {
             print("Could not find 'var videos' block.")
             return nil
         }

         let videosArrayString = String(htmlString[videosArrayRange])
         // Attempt to parse this substring as JSON (it might be close enough)
         // This requires cleaning up JS object notation to valid JSON
         let cleanedJsonString = videosArrayString
             .replacingOccurrences(of: "'", with: "\"") // Replace single quotes with double
             .replacingOccurrences(of: #"(\w+):"#, with: "\"$1\":", options: .regularExpression) // Add quotes to keys

          // Add surrounding braces to make it a valid JSON object string if needed,
          // though it's an array, so brackets might be more appropriate if parsing directly.
          // For simplicity, let's try parsing assuming it's objects within an array structure.

         // Try parsing as an array of dictionaries
         guard let data = "[\(cleanedJsonString)]".data(using: .utf8), // Wrap in brackets
               let jsonArray = try? JSONSerialization.jsonObject(with: data, options: .allowFragments) as? [[String: Any]] else {
             print("Failed to parse video options JSON.")
             return nil
         }

         var options: [(label: String, url: URL)] = []
         for videoObject in jsonArray {
             if let label = videoObject["label"] as? String,
                let srcString = videoObject["src"] as? String,
                let url = URL(string: srcString) {
                 options.append((label: label, url: url))
             }
         }


         // Sort by quality descending (e.g., 1080p first)
         return options.isEmpty ? nil : options.sorted {
             (Int($0.label.replacingOccurrences(of: "p", with: "")) ?? 0) >
             (Int($1.label.replacingOccurrences(of: "p", with: "")) ?? 0)
         }
     }


    private func selectQuality() {
        let preferredQuality = UserDefaults.standard.string(forKey: "preferredQuality") ?? "720p"

        // Exact match
        if let matchingQuality = qualityOptions.first(where: { $0.label == preferredQuality }) {
            handleVideoURL(url: matchingQuality.url)
            return
        }

        // Find nearest quality if exact match fails
        if let nearestQuality = findNearestQuality(preferred: preferredQuality) {
            print("Preferred quality \(preferredQuality) not found. Using nearest: \(nearestQuality.label)")
            handleVideoURL(url: nearestQuality.url)
        }
        // Fallback: show picker if no options or nearest fails
        else if !qualityOptions.isEmpty {
            showQualityPicker()
        } else {
             print("No quality options found.")
             showAlert(title: "Error", message: "No video quality options found for this episode.")
             dismiss(animated: true)
         }
    }


    private func findNearestQuality(preferred: String) -> (label: String, url: URL)? {
        let preferredValue = Int(preferred.replacingOccurrences(of: "p", with: "")) ?? 0
        var closestOption: (label: String, url: URL)? = nil
        var smallestDifference = Int.max

        for option in qualityOptions {
            if let qualityValue = Int(option.label.replacingOccurrences(of: "p", with: "")) {
                let difference = abs(qualityValue - preferredValue)
                 if difference < smallestDifference {
                    smallestDifference = difference
                    closestOption = option
                 } else if difference == smallestDifference {
                     // If differences are equal, prefer higher quality
                     if qualityValue > (Int(closestOption?.label.replacingOccurrences(of: "p", with: "") ?? "0") ?? 0) {
                         closestOption = option
                     }
                 }
            }
        }
        return closestOption
    }


    private func showQualityPicker() {
        let alertController = UIAlertController(title: "Select Quality", message: nil, preferredStyle: .actionSheet)

        for option in qualityOptions { // Assumes qualityOptions is sorted high to low
            let action = UIAlertAction(title: option.label, style: .default) { [weak self] _ in
                self?.handleVideoURL(url: option.url)
            }
            alertController.addAction(action)
        }

        alertController.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
             self?.dismiss(animated: true) // Dismiss if user cancels
         })

         // Configure for iPad
         if UIDevice.current.userInterfaceIdiom == .pad {
             if let popoverController = alertController.popoverPresentationController {
                 popoverController.sourceView = self.view
                 popoverController.sourceRect = CGRect(x: self.view.bounds.midX, y: self.view.bounds.midY, width: 0, height: 0)
                 popoverController.permittedArrowDirections = []
             }
         }


        present(alertController, animated: true, completion: nil)
    }

    private func extractIframeSourceURL(from htmlString: String) -> URL? {
        do {
            let doc: Document = try SwiftSoup.parse(htmlString)
            guard let iframeElement = try doc.select("iframe").first(), // More robust selector
                  let sourceURLString = try iframeElement.attr("src").nilIfEmpty,
                  let sourceURL = URL(string: sourceURLString) else {
                      return nil
                  }
            return sourceURL
        } catch {
            print("Error parsing HTML with SwiftSoup for iframe: \(error)")
            return nil
        }
    }

    private func handleVideoURL(url: URL) {
        DispatchQueue.main.async {
            self.activityIndicator?.stopAnimating()

            if UserDefaults.standard.bool(forKey: "isToDownload") {
                self.handleDownload(url: url)
            }
            else if GCKCastContext.sharedInstance().sessionManager.hasConnectedCastSession() {
                self.castVideoToGoogleCast(videoURL: url)
                self.dismiss(animated: true, completion: nil)
            }
            else if let selectedPlayer = UserDefaults.standard.string(forKey: "mediaPlayerSelected") {
                 switch selectedPlayer {
                 case "VLC", "Infuse", "OutPlayer", "nPlayer":
                     self.animeDetailsViewController?.openInExternalPlayer(player: selectedPlayer, url: url)
                     self.dismiss(animated: true, completion: nil)
                 case "Custom":
                     let videoTitle = self.animeDetailsViewController?.animeTitle ?? "Anime"
                     let imageURL = self.animeDetailsViewController?.imageUrl ?? ""
                     let customPlayerVC = CustomPlayerView(videoTitle: videoTitle, videoURL: url, cell: self.cell, fullURL: self.fullURL, image: imageURL)
                     customPlayerVC.modalPresentationStyle = .fullScreen
                     customPlayerVC.delegate = self // Set delegate
                     self.present(customPlayerVC, animated: true)
                 default: // Includes "Default"
                     self.playOrCastVideo(url: url)
                 }
             }
            else { // Fallback to default player
                self.playOrCastVideo(url: url)
            }
        }
    }

    private func handleDownload(url: URL) {
        UserDefaults.standard.set(false, forKey: "isToDownload")

        self.dismiss(animated: true, completion: nil)

        let downloadManager = DownloadManager.shared
        let title = self.animeDetailsViewController?.animeTitle ?? "Anime Download"

        downloadManager.startDownload(url: url, title: title, progress: { progress in
            DispatchQueue.main.async {
                // Optional: Update UI if needed elsewhere
                // print("Download progress: \(progress * 100)%")
            }
        }) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let downloadURL):
                    print("Download completed. File saved at: \(downloadURL)")
                    self?.animeDetailsViewController?.showAlert(withTitle: "Download Completed!", message: "You can find your download in the Library -> Downloads.")
                case .failure(let error):
                    print("Download failed with error: \(error.localizedDescription)")
                    self?.animeDetailsViewController?.showAlert(withTitle: "Download Failed", message: error.localizedDescription)
                }
            }
        }
    }

    private func playOrCastVideo(url: URL) {
         DispatchQueue.main.async { // Ensure UI updates on main thread
             // Clean up any existing player view controller
             self.playerViewController?.willMove(toParent: nil)
             self.playerViewController?.view.removeFromSuperview()
             self.playerViewController?.removeFromParent()
             self.playerViewController = nil
             self.player = nil // Also release the player instance

             let player = AVPlayer(url: url)
             let playerViewController = NormalPlayer() // Use NormalPlayer
             playerViewController.player = player

             // Add as child view controller
             self.addChild(playerViewController)
             self.view.addSubview(playerViewController.view)
             playerViewController.view.frame = self.view.bounds
             playerViewController.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
             playerViewController.didMove(toParent: self)

             // Seek to last played time if available
             let lastPlayedTime = UserDefaults.standard.double(forKey: "lastPlayedTime_\(self.fullURL)")
             if lastPlayedTime > 0 {
                 player.seek(to: CMTime(seconds: lastPlayedTime, preferredTimescale: CMTimeScale(NSEC_PER_SEC)))
             }

             player.play() // Start playback

             // Store references
             self.player = player
             self.playerViewController = playerViewController
             self.addPeriodicTimeObserver() // Start observing time
         }
     }


    private func castVideoToGoogleCast(videoURL: URL) {
        DispatchQueue.main.async { // Ensure UI updates happen on main thread
            let metadata = GCKMediaMetadata(metadataType: .movie)

            if UserDefaults.standard.bool(forKey: "fullTitleCast") {
                metadata.setString(self.animeDetailsViewController?.animeTitle ?? "Unknown Anime", forKey: kGCKMetadataKeyTitle)
            } else {
                // Safely get episode number
                let episodeNumber = EpisodeNumberExtractor.extract(from: self.cell.episodeNumber)
                metadata.setString("Episode \(episodeNumber)", forKey: kGCKMetadataKeyTitle)
            }

            if UserDefaults.standard.bool(forKey: "animeImageCast"), let imageURL = URL(string: self.animeDetailsViewController?.imageUrl ?? "") {
                metadata.addImage(GCKImage(url: imageURL, width: 480, height: 720))
            }

            let builder = GCKMediaInformationBuilder(contentURL: videoURL)
            builder.contentType = "video/mp4" // Assume MP4 for 3rb
            builder.metadata = metadata

            let streamTypeString = UserDefaults.standard.string(forKey: "castStreamingType") ?? "buffered"
            builder.streamType = (streamTypeString == "live") ? .live : .buffered

            let mediaInformation = builder.build()

            if let remoteMediaClient = GCKCastContext.sharedInstance().sessionManager.currentCastSession?.remoteMediaClient {
                let lastPlayedTime = UserDefaults.standard.double(forKey: "lastPlayedTime_\(self.fullURL)")
                if lastPlayedTime > 0 {
                    let options = GCKMediaLoadOptions()
                    options.playPosition = TimeInterval(lastPlayedTime)
                    remoteMediaClient.loadMedia(mediaInformation, with: options)
                } else {
                    remoteMediaClient.loadMedia(mediaInformation)
                }
            } else {
                 print("Error: No active Google Cast session found.")
                 self.showAlert(title: "Cast Error", message: "No active Chromecast session found. Please ensure you are connected.")
            }
        }
    }


    private func addPeriodicTimeObserver() {
         // Remove existing observer first
         if let token = timeObserverToken {
             player?.removeTimeObserver(token)
             timeObserverToken = nil
         }

        let interval = CMTime(seconds: 1.0, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserverToken = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self = self,
                  let currentItem = self.player?.currentItem,
                  currentItem.duration.seconds.isFinite, // Check duration validity
                   duration > 0 else { // Ensure duration is positive
                      return
                  }

            let currentTime = time.seconds
            let duration = currentItem.duration.seconds
            let progress = Float(currentTime / duration) // Calculate progress
            let remainingTime = duration - currentTime

            self.cell.updatePlaybackProgress(progress: progress, remainingTime: remainingTime)

            UserDefaults.standard.set(currentTime, forKey: "lastPlayedTime_\(self.fullURL)")
            UserDefaults.standard.set(duration, forKey: "totalTime_\(self.fullURL)")

            // Update Continue Watching Item
            if let viewController = self.animeDetailsViewController,
               let episodeNumberString = viewController.episodes[safe: viewController.currentEpisodeIndex]?.number,
               let episodeNumberInt = Int(episodeNumberString) { // Safely convert

                 let selectedMediaSource = UserDefaults.standard.selectedMediaSource?.rawValue ?? "Anime3rb"

                 let continueWatchingItem = ContinueWatchingItem(
                     animeTitle: viewController.animeTitle ?? "Unknown Anime",
                     episodeTitle: "Ep. \(episodeNumberInt)",
                     episodeNumber: episodeNumberInt,
                     imageURL: viewController.imageUrl ?? "",
                     fullURL: self.fullURL,
                     lastPlayedTime: currentTime,
                     totalTime: duration,
                     source: selectedMediaSource
                 )
                 ContinueWatchingManager.shared.saveItem(continueWatchingItem)

                // Send AniList Update
                 let shouldSendPushUpdates = UserDefaults.standard.bool(forKey: "sendPushUpdates")

                 if shouldSendPushUpdates && remainingTime / duration < 0.15 && !viewController.hasSentUpdate {
                     let cleanedTitle = viewController.cleanTitle(viewController.animeTitle ?? "Unknown Anime")

                     viewController.fetchAnimeID(title: cleanedTitle) { animeID in
                         let aniListMutation = AniListMutation()
                         aniListMutation.updateAnimeProgress(animeId: animeID, episodeNumber: episodeNumberInt) { result in
                             switch result {
                             case .success():
                                 print("Successfully updated anime progress.")
                             case .failure(let error):
                                 print("Failed to update anime progress: \(error.localizedDescription)")
                             }
                         }

                         viewController.hasSentUpdate = true // Mark as updated
                     }
                 }
            } else {
                 print("Error: Could not get episode number or convert it to Int.")
            }
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        cleanup() // Call cleanup on deinit
    }

    private func cleanup() {
        player?.pause()
        player = nil

        if let vc = playerViewController {
            vc.willMove(toParent: nil)
            vc.view.removeFromSuperview()
            vc.removeFromParent()
            playerViewController = nil
        }

        if let token = timeObserverToken {
            // Player might be nil already, so check before removing observer
             // No easy way to check if player still exists here without storing it differently
             // For safety, just nil out the token. The observer should deallocate with the player.
            // player?.removeTimeObserver(token) // Potential crash if player is nil
            self.timeObserverToken = nil
        }

        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.removeFromSuperview()
        webView = nil
        retryCount = 0 // Reset retry count
        qualityOptions = [] // Clear options
    }


    private func retryExtraction() {
        retryCount += 1
        if retryCount < maxRetries {
            print("Retrying extraction (Attempt \(retryCount + 1))")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self = self else { return }
                self.loadInitialURL() // Retry loading the initial URL
            }
        } else {
            print("Max retries reached. Unable to find video source.")
            DispatchQueue.main.async {
                self.activityIndicator?.stopAnimating()
                 self.showAlert(title: "Error", message: "Could not extract video source after multiple attempts.")
                self.dismiss(animated: true)
            }
        }
    }

    private func playNextEpisode() {
        guard let animeDetailsViewController = self.animeDetailsViewController else {
            print("Error: animeDetailsViewController is nil")
            return
        }

        let nextIndex: Int
         if animeDetailsViewController.isReverseSorted {
             nextIndex = animeDetailsViewController.currentEpisodeIndex - 1
             guard nextIndex >= 0 else {
                 animeDetailsViewController.currentEpisodeIndex = 0 // Reset index
                 return
             }
         } else {
             nextIndex = animeDetailsViewController.currentEpisodeIndex + 1
             guard nextIndex < animeDetailsViewController.episodes.count else {
                 animeDetailsViewController.currentEpisodeIndex = animeDetailsViewController.episodes.count - 1 // Reset index
                 return
             }
         }
        animeDetailsViewController.currentEpisodeIndex = nextIndex // Update index first
        playEpisode(at: nextIndex)
    }

    private func playEpisode(at index: Int) {
        guard let animeDetailsViewController = self.animeDetailsViewController,
              index >= 0 && index < animeDetailsViewController.episodes.count else {
                  return
              }

        let nextEpisode = animeDetailsViewController.episodes[index]
        // Ensure the cell exists before trying to access it
        if let cell = animeDetailsViewController.tableView.cellForRow(at: IndexPath(row: index, section: 2)) as? EpisodeCell {
            animeDetailsViewController.episodeSelected(episode: nextEpisode, cell: cell)
        } else {
             // If cell is not visible, manually trigger the selection logic
             print("Cell for episode \(nextEpisode.number) not visible, triggering selection logic directly.")
             animeDetailsViewController.showLoadingBanner() // Show loading indicator
             animeDetailsViewController.checkUserDefault(url: nextEpisode.href, cell: EpisodeCell(), fullURL: nextEpisode.href) // Pass dummy cell
         }
    }

    @objc func playerItemDidReachEnd(notification: Notification) {
        if UserDefaults.standard.bool(forKey: "AutoPlay") {
            guard let animeDetailsViewController = self.animeDetailsViewController else { return }
            let hasNextEpisode = animeDetailsViewController.isReverseSorted ?
                (animeDetailsViewController.currentEpisodeIndex > 0) :
                (animeDetailsViewController.currentEpisodeIndex < animeDetailsViewController.episodes.count - 1)

            if hasNextEpisode {
                self.dismiss(animated: true) { [weak self] in
                    self?.playNextEpisode()
                }
            } else {
                self.dismiss(animated: true, completion: nil)
            }
        } else {
            self.dismiss(animated: true, completion: nil)
        }
    }

    // Add showAlert helper
     private func showAlert(title: String, message: String) {
          let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
          alert.addAction(UIAlertAction(title: "OK", style: .default))
          present(alert, animated: true)
      }
}

extension ExternalVideoPlayer3rb: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Decide what to extract based on the current URL
        if webView.url?.absoluteString == streamURL {
            print("Initial URL finished loading. Extracting iframe source...")
            extractIframeSource()
        } else {
             // We are likely on the iframe page now
             print("Iframe content finished loading. Extracting video source...")
             extractVideoSource()
         }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        print("WebView navigation failed: \(error.localizedDescription)")
        retryExtraction()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        print("WebView provisional navigation failed: \(error.localizedDescription)")
        retryExtraction()
    }
}

// Conform to CustomPlayerViewDelegate
extension ExternalVideoPlayer3rb {
     func customPlayerViewDidDismiss() {
         self.dismiss(animated: true, completion: nil)
     }
 }
