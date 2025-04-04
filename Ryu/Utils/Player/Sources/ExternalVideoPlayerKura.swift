import AVKit
import WebKit
import SwiftSoup
import GoogleCast

class ExternalVideoPlayerKura: UIViewController, GCKRemoteMediaClientListener, CustomPlayerViewDelegate { // Added CustomPlayerViewDelegate
    private let streamURL: String
    private var webView: WKWebView?
    private var player: AVPlayer?
    private var playerViewController: AVPlayerViewController?
    private var activityIndicator: UIActivityIndicatorView?

    private var retryCount = 0
    private let maxRetries: Int

    private var cell: EpisodeCell
    private var fullURL: String
    private weak var animeDetailsViewController: AnimeDetailViewController?
    private var timeObserverToken: Any?

    private var originalRate: Float = 1.0
    private var holdGesture: UILongPressGestureRecognizer?
    private var videoURLs: [String: String] = [:] // Quality -> URL

    init(streamURL: String, cell: EpisodeCell, fullURL: String, animeDetailsViewController: AnimeDetailViewController) {
        self.streamURL = streamURL
        self.cell = cell
        self.fullURL = fullURL
        self.animeDetailsViewController = animeDetailsViewController
        self.maxRetries = UserDefaults.standard.integer(forKey: "maxRetries") > 0 ? UserDefaults.standard.integer(forKey: "maxRetries") : 10
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
        setupWebView()
    }

    private func setupHoldGesture() {
        holdGesture = UILongPressGestureRecognizer(target: self, action: #selector(handleHoldGesture(_:)))
        holdGesture?.minimumPressDuration = 0.5
        view.addGestureRecognizer(holdGesture!)
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
        player.rate = UserDefaults.standard.float(forKey: "holdSpeedPlayer")
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
        webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView?.navigationDelegate = self
        // Hide webview initially or keep it hidden if not needed for UI interaction
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
            showAlert(title: "Error", message: "Invalid URL")
            return
        }
        webView?.load(URLRequest(url: url))
    }

    private func extractVideoSources() {
        webView?.evaluateJavaScript("document.body.innerHTML") { [weak self] (result, error) in
            guard let self = self, let htmlString = result as? String else {
                self?.retryExtraction()
                return
            }

            self.handleVideoSources(htmlString: htmlString)
        }
    }

    private func handleVideoSources(htmlString: String) {
        do {
            let doc = try SwiftSoup.parse(htmlString)
            let videoElement = try doc.select("video#player").first()
            let sourceElements = try videoElement?.select("source")

            var extractedURLs: [String: String] = [:] // Use dictionary for easier lookup
            sourceElements?.forEach { element in
                if let size = try? element.attr("size"), // Use 'size' attribute for quality
                   let url = try? element.attr("src") {
                    let qualityLabel = "\(size)p" // Construct quality label
                    extractedURLs[qualityLabel] = url
                }
            }

            DispatchQueue.main.async {
                 self.videoURLs = extractedURLs // Store the extracted URLs
                if self.videoURLs.isEmpty {
                    self.retryExtraction()
                } else {
                    self.selectQuality()
                    self.activityIndicator?.stopAnimating()
                }
            }
        } catch {
            print("Error parsing HTML: \(error)")
            self.retryExtraction()
        }
    }


    private func selectQuality() {
        let preferredQuality = UserDefaults.standard.string(forKey: "preferredQuality") ?? "720p"

        // Exact match
        if let urlString = videoURLs[preferredQuality], let url = URL(string: urlString) {
            handleVideoURL(url: url)
            return
        }

        // Find closest available quality
        let availableQualities = videoURLs.keys.compactMap { Int($0.replacingOccurrences(of: "p", with: "")) }.sorted()
        let preferredValue = Int(preferredQuality.replacingOccurrences(of: "p", with: "")) ?? 720

        var bestMatchQuality: Int?
        var minDifference = Int.max

        for quality in availableQualities {
            let difference = abs(quality - preferredValue)
            if difference < minDifference {
                minDifference = difference
                bestMatchQuality = quality
            } else if difference == minDifference {
                // If differences are equal, prefer higher quality
                if quality > (bestMatchQuality ?? 0) {
                     bestMatchQuality = quality
                 }
            }
        }

        if let quality = bestMatchQuality, let urlString = videoURLs["\(quality)p"], let url = URL(string: urlString) {
            handleVideoURL(url: url)
        } else {
            // Fallback: show picker if no suitable quality found
            showQualitySelectionPopup()
        }
    }

    private func showQualitySelectionPopup() {
        let alertController = UIAlertController(title: "Select Quality", message: nil, preferredStyle: .actionSheet)

        // Sort qualities numerically, highest first
        let sortedQualities = videoURLs.keys.sorted {
            (Int($0.replacingOccurrences(of: "p", with: "")) ?? 0) > (Int($1.replacingOccurrences(of: "p", with: "")) ?? 0)
        }

        for quality in sortedQualities {
            if let urlString = videoURLs[quality], let url = URL(string: urlString) {
                 alertController.addAction(UIAlertAction(title: quality, style: .default) { [weak self] _ in
                     self?.handleVideoURL(url: url)
                 })
             }
        }

         alertController.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
             self?.dismiss(animated: true) // Dismiss if cancelled
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


    private func handleVideoURL(url: URL) {
        DispatchQueue.main.async { // Ensure UI updates happen on main thread
            self.activityIndicator?.stopAnimating() // Stop indicator once URL is ready

            if UserDefaults.standard.bool(forKey: "isToDownload") {
                self.handleDownload(url: url)
            } else if GCKCastContext.sharedInstance().sessionManager.hasConnectedCastSession() {
                self.castVideoToGoogleCast(videoURL: url)
                self.dismiss(animated: true)
            } else {
                let selectedPlayer = UserDefaults.standard.string(forKey: "mediaPlayerSelected") ?? "Default"
                switch selectedPlayer {
                case "VLC", "Infuse", "OutPlayer", "nPlayer":
                    self.animeDetailsViewController?.openInExternalPlayer(player: selectedPlayer, url: url)
                    self.dismiss(animated: true)
                case "Custom":
                    let videoTitle = self.animeDetailsViewController?.animeTitle ?? "Anime"
                    let imageURL = self.animeDetailsViewController?.imageUrl ?? ""
                    let customPlayerVC = CustomPlayerView(videoTitle: videoTitle, videoURL: url, cell: self.cell, fullURL: self.fullURL, image: imageURL)
                    customPlayerVC.modalPresentationStyle = .fullScreen
                    customPlayerVC.delegate = self // Set delegate
                    self.present(customPlayerVC, animated: true)
                default:
                    self.playOrCastVideo(url: url)
                }
            }
        }
    }

    private func handleDownload(url: URL) {
        UserDefaults.standard.set(false, forKey: "isToDownload")
        dismiss(animated: true)

        let downloadManager = DownloadManager.shared
        let title = animeDetailsViewController?.animeTitle ?? "Anime Download"
        downloadManager.startDownload(url: url, title: title, progress: { progress in
            print("Download progress: \(progress * 100)%")
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

    private func castVideoToGoogleCast(videoURL: URL) {
        DispatchQueue.main.async { // Ensure UI updates happen on main thread
            let metadata = GCKMediaMetadata(metadataType: .movie)

            if UserDefaults.standard.bool(forKey: "fullTitleCast") {
                metadata.setString(self.animeDetailsViewController?.animeTitle ?? "Unknown Anime", forKey: kGCKMetadataKeyTitle)
            } else {
                let episodeNumber = (self.animeDetailsViewController?.currentEpisodeIndex ?? -1) + 1
                metadata.setString("Episode \(episodeNumber)", forKey: kGCKMetadataKeyTitle)
            }

            if UserDefaults.standard.bool(forKey: "animeImageCast"), let imageURL = URL(string: self.animeDetailsViewController?.imageUrl ?? "") {
                metadata.addImage(GCKImage(url: imageURL, width: 480, height: 720))
            }

            let builder = GCKMediaInformationBuilder(contentURL: videoURL)
            builder.contentType = "video/mp4" // Assuming MP4, adjust if needed
            builder.metadata = metadata
            builder.streamType = UserDefaults.standard.string(forKey: "castStreamingType") == "live" ? .live : .buffered

            if let remoteMediaClient = GCKCastContext.sharedInstance().sessionManager.currentCastSession?.remoteMediaClient {
                let lastPlayedTime = UserDefaults.standard.double(forKey: "lastPlayedTime_\(self.fullURL)")
                if lastPlayedTime > 0 {
                    let options = GCKMediaLoadOptions()
                    options.playPosition = TimeInterval(lastPlayedTime)
                    remoteMediaClient.loadMedia(builder.build(), with: options)
                } else {
                    remoteMediaClient.loadMedia(builder.build())
                }
            } else {
                 print("Error: No active Google Cast session found.")
                 self.showAlert(title: "Cast Error", message: "No active Chromecast session found. Please ensure you are connected.")
            }
        }
    }


    private func playOrCastVideo(url: URL) {
         DispatchQueue.main.async { // Ensure UI updates happen on main thread
             let player = AVPlayer(url: url)
             let playerViewController = NormalPlayer() // Use NormalPlayer
             playerViewController.player = player

             self.addChild(playerViewController)
             self.view.addSubview(playerViewController.view)

             playerViewController.view.frame = self.view.bounds
             playerViewController.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
             playerViewController.didMove(toParent: self)

             let lastPlayedTime = UserDefaults.standard.double(forKey: "lastPlayedTime_\(self.fullURL)")

             if lastPlayedTime > 0 {
                 player.seek(to: CMTime(seconds: lastPlayedTime, preferredTimescale: CMTimeScale(NSEC_PER_SEC)))
             }

             player.play()

             self.player = player
             self.playerViewController = playerViewController
             self.addPeriodicTimeObserver()
         }
     }


    private func addPeriodicTimeObserver() {
        let interval = CMTime(seconds: 1.0, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserverToken = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self = self, let currentItem = self.player?.currentItem, currentItem.duration.seconds.isFinite else {
                return
            }

            self.updatePlaybackProgress(time: time, duration: currentItem.duration.seconds)
        }
    }

    private func updatePlaybackProgress(time: CMTime, duration: Double) {
         guard duration > 0 else { return } // Avoid division by zero
        let currentTime = time.seconds
        let progress = Float(currentTime / duration)
        let remainingTime = duration - currentTime

        cell.updatePlaybackProgress(progress: progress, remainingTime: remainingTime)
        UserDefaults.standard.set(currentTime, forKey: "lastPlayedTime_\(fullURL)")
        UserDefaults.standard.set(duration, forKey: "totalTime_\(fullURL)")

        updateContinueWatchingItem(currentTime: currentTime, duration: duration)
        sendPushUpdates(remainingTime: remainingTime, totalTime: duration)
    }

    private func updateContinueWatchingItem(currentTime: Double, duration: Double) {
        if let viewController = self.animeDetailsViewController,
           let episodeNumberString = viewController.episodes[safe: viewController.currentEpisodeIndex]?.number,
           let episodeNumberInt = Int(episodeNumberString) { // Safely convert to Int

            let selectedMediaSource = UserDefaults.standard.selectedMediaSource?.rawValue ?? "Kuramanime" // Use enum

            let continueWatchingItem = ContinueWatchingItem(
                animeTitle: viewController.animeTitle ?? "Unknown Anime",
                episodeTitle: "Ep. \(episodeNumberInt)",
                episodeNumber: episodeNumberInt,
                imageURL: viewController.imageUrl ?? "",
                fullURL: fullURL,
                lastPlayedTime: currentTime,
                totalTime: duration,
                source: selectedMediaSource
            )
            ContinueWatchingManager.shared.saveItem(continueWatchingItem)
        }
    }


    private func sendPushUpdates(remainingTime: Double, totalTime: Double) {
        guard let animeDetailsViewController = animeDetailsViewController, UserDefaults.standard.bool(forKey: "sendPushUpdates"), totalTime > 0, remainingTime / totalTime < 0.15, !animeDetailsViewController.hasSentUpdate
        else {
            return
        }

        let cleanedTitle = animeDetailsViewController.cleanTitle(animeDetailsViewController.animeTitle ?? "Unknown Anime")
        animeDetailsViewController.fetchAnimeID(title: cleanedTitle) { [weak self] animeID in
            let aniListMutation = AniListMutation()
            // Use the episode number from the cell safely
            let episodeNumber = Int(self?.cell.episodeNumber ?? "0") ?? 0
            aniListMutation.updateAnimeProgress(animeId: animeID, episodeNumber: episodeNumber) { result in
                switch result {
                case .success: print("Successfully updated anime progress.")
                case .failure(let error): print("Failed to update anime progress: \(error.localizedDescription)")
                }
            }
            animeDetailsViewController.hasSentUpdate = true
        }
    }


    private func retryExtraction() {
        retryCount += 1
        if retryCount < maxRetries {
            print("Retrying extraction (Attempt \(retryCount + 1))")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.loadInitialURL()
            }
        } else {
            print("Max retries reached. Unable to find video sources.")
            DispatchQueue.main.async {
                self.activityIndicator?.stopAnimating()
                 self.showAlert(title: "Error", message: "Could not extract video source after multiple attempts.")
                self.dismiss(animated: true)
            }
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        cleanup() // Ensure cleanup happens on deinit
    }

    private func cleanup() {
        player?.pause()
        player = nil

        // Remove player view controller if it exists
        if let vc = playerViewController {
            vc.willMove(toParent: nil)
            vc.view.removeFromSuperview()
            vc.removeFromParent()
            playerViewController = nil
        }


        if let timeObserverToken = timeObserverToken {
            player?.removeTimeObserver(timeObserverToken) // This might crash if player is already nil
            self.timeObserverToken = nil
        }

        webView?.stopLoading()
        webView?.navigationDelegate = nil // Break retain cycle
        webView?.removeFromSuperview()
        webView = nil // Release webView
    }

    @objc func playerItemDidReachEnd(notification: Notification) {
         // Common logic for ending playback
         if UserDefaults.standard.bool(forKey: "AutoPlay"), let animeDetailsViewController = self.animeDetailsViewController {
             let hasNextEpisode = animeDetailsViewController.isReverseSorted ?
                 (animeDetailsViewController.currentEpisodeIndex > 0) :
                 (animeDetailsViewController.currentEpisodeIndex < animeDetailsViewController.episodes.count - 1)

             if hasNextEpisode {
                 self.dismiss(animated: true) { [weak self] in
                     self?.playNextEpisode()
                 }
             } else {
                 self.dismiss(animated: true) // Dismiss if no next episode
             }
         } else {
             self.dismiss(animated: true) // Dismiss if autoplay is off
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
                 animeDetailsViewController.currentEpisodeIndex = 0 // Reset index if out of bounds
                 return
             }
         } else {
             nextIndex = animeDetailsViewController.currentEpisodeIndex + 1
             guard nextIndex < animeDetailsViewController.episodes.count else {
                 animeDetailsViewController.currentEpisodeIndex = animeDetailsViewController.episodes.count - 1 // Reset index if out of bounds
                 return
             }
         }
        animeDetailsViewController.currentEpisodeIndex = nextIndex // Update the index first
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
            // If cell is not visible, manually trigger the selection logic without the cell
            // This might require adjusting episodeSelected or creating a variant
            print("Cell for episode \(nextEpisode.number) not visible, triggering selection logic directly.")
            // Potentially call a modified version: animeDetailsViewController.selectEpisodeData(episode: nextEpisode)
            // For now, just logging the issue.
             animeDetailsViewController.showLoadingBanner()
             animeDetailsViewController.checkUserDefault(url: nextEpisode.href, cell: EpisodeCell(), fullURL: nextEpisode.href) // Pass a dummy cell
        }
    }
     // Add showAlert helper
     private func showAlert(title: String, message: String) {
          let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
          alert.addAction(UIAlertAction(title: "OK", style: .default))
          present(alert, animated: true)
      }
}

extension ExternalVideoPlayerKura: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Only extract if we haven't already started playing
         if !isVideoPlaying {
             extractVideoSources()
         }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        print("WebView navigation failed: \(error.localizedDescription)")
         if !isVideoPlaying { // Only retry if we haven't started playback
            retryExtraction()
         }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        print("WebView provisional navigation failed: \(error.localizedDescription)")
         if !isVideoPlaying { // Only retry if we haven't started playback
            retryExtraction()
         }
    }
}
