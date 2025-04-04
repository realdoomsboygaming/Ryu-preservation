import AVKit
import WebKit
import Combine
import GoogleCast

class ExternalVideoPlayer: UIViewController, WKNavigationDelegate, CustomPlayerViewDelegate { // Added CustomPlayerViewDelegate
    func customPlayerViewDidDismiss() {
        // When the custom player dismisses, dismiss this controller too
        self.dismiss(animated: true, completion: nil)
    }

    private var webView: WKWebView?
    private var playerViewController: AVPlayerViewController?
    private var streamURL: String
    private var activityIndicator: UIActivityIndicatorView?
    private var cell: EpisodeCell
    private var fullURL: String
    private weak var animeDetailsViewController: AnimeDetailViewController?
    private var player: AVPlayer?
    private var timeObserverToken: Any?
    private var isVideoPlaying = false // Track if video playback has started
    private var extractionTimer: Timer? // Timer for periodic extraction attempts

    private var retryCount = 0
    private var maxRetries: Int {
        UserDefaults.standard.integer(forKey: "maxRetries") > 0 ? UserDefaults.standard.integer(forKey: "maxRetries") : 10 // Use default 10 if not set or invalid
    }

    private var originalRate: Float = 1.0
    private var holdGesture: UILongPressGestureRecognizer?
    private var qualityOptions: [(name: String, url: String)] = []

    private let userAgents = [
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36",
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/14.1.2 Safari/605.1.15",
        "Mozilla/5.0 (iPhone; CPU iPhone OS 14_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/14.0 Mobile/15E148 Safari/604.1",
        "Mozilla/5.0 (iPad; CPU OS 14_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/14.0 Mobile/15E148 Safari/604.1",
        "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36"
    ]

    private var extractionCancellable: AnyCancellable?

    init(streamURL: String, cell: EpisodeCell, fullURL: String, animeDetailsViewController: AnimeDetailViewController) {
        self.streamURL = streamURL
        self.cell = cell
        self.fullURL = fullURL
        self.animeDetailsViewController = animeDetailsViewController
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .secondarySystemBackground
        setupWebView()
        setupActivityIndicator()
        setupHoldGesture()
        setupNotificationObserver()
        startExtractionProcess()
    }

    private func setupNotificationObserver() {
        NotificationCenter.default.addObserver(self, selector: #selector(playerItemDidReachEnd), name: .AVPlayerItemDidPlayToEndTime, object: player?.currentItem)
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

    private func setupHoldGesture() {
        holdGesture = UILongPressGestureRecognizer(target: self, action: #selector(handleHoldGesture(_:)))
        holdGesture?.minimumPressDuration = 0.5
        if let holdGesture = holdGesture {
            view.addGestureRecognizer(holdGesture)
        }
    }

    @objc private func handleHoldGesture(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            beginHoldSpeed()
        case .ended, .cancelled:
            endHoldSpeed()
        default:
            break
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
        // Allow media playback without user action
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.allowsInlineMediaPlayback = true // Allow inline playback

        let randomUserAgent = userAgents.randomElement() ?? userAgents[0]
        configuration.applicationNameForUserAgent = randomUserAgent

        webView = WKWebView(frame: view.bounds, configuration: configuration)
        webView?.navigationDelegate = self
        webView?.isHidden = true // Keep webview hidden

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

        if let url = URL(string: streamURL) {
            let request = URLRequest(url: url)
            webView?.load(request)
        }
    }

    private func startExtractionProcess() {
        // Use a Combine timer publisher for periodic checks
        extractionCancellable = Timer.publish(every: 0.5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.extractVideoLinks()
            }
    }

    private func stopExtractionProcess() {
        extractionCancellable?.cancel()
        extractionCancellable = nil
    }

    private func extractVideoLinks() {
        guard !isVideoPlaying else {
            stopExtractionProcess() // Stop checking once video is playing
            return
        }

        // JavaScript to find download links with specific text content
        let script = """
         function extractLinks() {
             const links = [];
             // Target links within the specific download container
             const downloadDivs = document.querySelectorAll('#content-download .mirror_link .dowload a');
             for (const a of downloadDivs) {
                 // Check if the link text contains "Download" and "mp4"
                 if (a.textContent.includes('Download') && a.textContent.includes('mp4')) {
                     const text = a.textContent.trim();
                     // Extract quality like "1080P" from text like "(1080P - mp4)"
                     const qualityMatch = text.match(/\\((\\d+P) - mp4\\)/);
                     const quality = qualityMatch ? qualityMatch[1].replace('P', 'p') : ''; // Normalize to lowercase 'p'
                     if (quality) { // Only add if quality was successfully extracted
                         links.push({name: quality, url: a.href});
                     }
                 }
             }
             return links; // Return the array of found links
         }
         extractLinks(); // Execute the function
         """

        webView?.evaluateJavaScript(script) { [weak self] (result, error) in
            guard let self = self, !self.isVideoPlaying else { return }

            if let links = result as? [[String: String]], !links.isEmpty {
                self.qualityOptions = links.compactMap { link in
                    guard let name = link["name"], !name.isEmpty, let url = link["url"] else { return nil }
                    return (name: name, url: url)
                }
                // Sort qualities numerically, highest first
                 self.qualityOptions.sort {
                    (Int($0.name.replacingOccurrences(of: "p", with: "")) ?? 0) >
                    (Int($1.name.replacingOccurrences(of: "p", with: "")) ?? 0)
                }
                self.stopExtractionProcess() // Stop timer once links are found
                self.handleQualitySelection() // Proceed to quality selection
            } else if error != nil {
                 // Don't log JS errors if video is already playing, as the context might be gone
                 if !self.isVideoPlaying {
                     print("Error extracting video links: \(error?.localizedDescription ?? "Unknown JavaScript error")")
                     self.retryExtractVideoLinks() // Retry on JavaScript error
                 }
             } else {
                 // No links found yet, continue trying (handled by the timer)
                 // Optionally add a retry count limit here as well
                 print("No download links found yet, will retry...")
             }
        }
    }

    private func retryExtractVideoLinks() {
        if !isVideoPlaying && retryCount < maxRetries {
            retryCount += 1
            print("Retrying extraction... Attempt \(retryCount) of \(maxRetries)")
            // Timer is already running, no need to schedule another check here
        } else if !isVideoPlaying {
            stopExtractionProcess() // Stop timer if max retries reached
            activityIndicator?.stopAnimating()
            print("Failed to extract video links after \(maxRetries) attempts.")
            showAlert(title: "Error", message: "Failed to extract video source after multiple attempts.")
            self.dismiss(animated: true, completion: nil)
        }
    }

    private func handleQualitySelection() {
        activityIndicator?.stopAnimating() // Stop loading indicator

        if qualityOptions.isEmpty {
            print("No quality options available.")
            showAlert(title: "Error", message: "No video quality options found for this episode.")
            self.dismiss(animated: true)
            return
        }

        let preferredQuality = UserDefaults.standard.string(forKey: "preferredQuality") ?? "1080p" // Default

        // Try exact match for preferred quality
        if let matchingOption = qualityOptions.first(where: { $0.name.lowercased() == preferredQuality.lowercased() }),
           let url = URL(string: matchingOption.url) {
            handleVideoURL(url: url)
        }
        // Try finding the closest quality if exact match fails
        else if let closestQuality = findClosestQuality(to: preferredQuality),
                let url = URL(string: closestQuality.url) {
            print("Preferred quality \(preferredQuality) not found. Using closest: \(closestQuality.name)")
            handleVideoURL(url: url)
        }
        // Fallback: Show picker if no suitable quality found
        else {
            showQualityPicker()
        }
    }

    private func findClosestQuality(to preferredQuality: String) -> (name: String, url: String)? {
        let preferredValue = Int(preferredQuality.replacingOccurrences(of: "p", with: "")) ?? 0
        var closestOption: (name: String, url: String)? = nil
        var smallestDifference = Int.max

        for option in qualityOptions {
            if let optionValue = Int(option.name.replacingOccurrences(of: "p", with: "")) {
                let difference = abs(preferredValue - optionValue)
                if difference < smallestDifference {
                    smallestDifference = difference
                    closestOption = option
                 } else if difference == smallestDifference {
                     // If differences are equal, prefer higher quality
                     if optionValue > (Int(closestOption?.name.replacingOccurrences(of: "p", with: "") ?? "0") ?? 0) {
                         closestOption = option
                     }
                 }
            }
        }
        return closestOption
    }

    private func showQualityPicker() {
        let alert = UIAlertController(title: "Select Quality", message: nil, preferredStyle: .actionSheet)

        for option in qualityOptions {
            alert.addAction(UIAlertAction(title: option.name, style: .default, handler: { [weak self] _ in
                if let url = URL(string: option.url) {
                    self?.handleVideoURL(url: url)
                } else {
                     self?.showAlert(title: "Error", message: "Invalid URL for selected quality.")
                    self?.dismiss(animated: true)
                 }
            }))
        }

        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
            self?.dismiss(animated: true) // Dismiss if user cancels
        })


        // Configure for iPad
        if UIDevice.current.userInterfaceIdiom == .pad {
            if let popoverController = alert.popoverPresentationController {
                popoverController.sourceView = self.view
                popoverController.sourceRect = CGRect(x: self.view.bounds.midX, y: self.view.bounds.midY, width: 0, height: 0)
                popoverController.permittedArrowDirections = []
            }
        }

        present(alert, animated: true, completion: nil)
    }


    private func handleVideoURL(url: URL) {
        DispatchQueue.main.async { // Ensure UI updates on main thread
            self.isVideoPlaying = true // Mark as playing to stop extraction retries
            self.stopExtractionProcess()
            self.activityIndicator?.stopAnimating() // Stop indicator

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
                    self.present(customPlayerVC, animated: true, completion: nil)
                default: // Includes "Default" case
                    self.playVideo(url: url.absoluteString)
                }
            }
            else { // Fallback to default player if no preference is set
                self.playVideo(url: url.absoluteString)
            }
        }
    }


    private func handleDownload(url: URL) {
        UserDefaults.standard.set(false, forKey: "isToDownload")

        self.dismiss(animated: true, completion: nil)

        let downloadManager = DownloadManager.shared
        let title = self.animeDetailsViewController?.animeTitle ?? "Anime Download"

        downloadManager.startDownload(url: url, title: title, progress: { progress in
            // Optional: Update UI with download progress if needed elsewhere
            // print("Download progress: \(progress * 100)%")
        }) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let downloadURL):
                    print("Download completed. File saved at: \(downloadURL)")
                    // Use correct argument label 'title:'
                    self?.animeDetailsViewController?.showAlert(title: "Download Completed!", message: "You can find your download in the Library -> Downloads.")
                case .failure(let error):
                    print("Download failed with error: \(error.localizedDescription)")
                    self?.animeDetailsViewController?.showAlert(title: "Download Failed", message: error.localizedDescription)
                }
            }
        }
    }

    private func castVideoToGoogleCast(videoURL: URL) {
        DispatchQueue.main.async { // Ensure UI updates on main thread
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
            builder.contentType = "video/mp4" // Assuming MP4 for Gogoanime downloads
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

    private func playVideo(url: String) {
        guard let videoURL = URL(string: url) else {
            print("Invalid video URL")
             showAlert(title: "Error", message: "Invalid video URL.")
            return
        }

        // Clean up existing player if any
         cleanupPlayer()

        let player = AVPlayer(url: videoURL)
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

        self.player = player
        self.playerViewController = playerViewController
        self.addPeriodicTimeObserver()

        player.play()
    }

    private func addPeriodicTimeObserver() {
         // Remove existing observer if it exists
         if let token = timeObserverToken {
             player?.removeTimeObserver(token)
             timeObserverToken = nil
         }

        let interval = CMTime(seconds: 1.0, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserverToken = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self = self,
                  let currentItem = self.player?.currentItem,
                  currentItem.duration.seconds.isFinite else { // Check duration validity
                      return
                  }

            // Fix: Access duration *after* checking validity
            let duration = currentItem.duration.seconds
            guard duration > 0 else { return } // Ensure duration is positive

            let currentTime = time.seconds
            let progress = Float(currentTime / duration) // Calculate progress
            let remainingTime = duration - currentTime

            self.cell.updatePlaybackProgress(progress: progress, remainingTime: remainingTime)

            UserDefaults.standard.set(currentTime, forKey: "lastPlayedTime_\(self.fullURL)")
            UserDefaults.standard.set(duration, forKey: "totalTime_\(self.fullURL)")

            // Update Continue Watching Item
            if let viewController = self.animeDetailsViewController,
               let episodeNumberString = viewController.episodes[safe: viewController.currentEpisodeIndex]?.number,
               let episodeNumberInt = Int(episodeNumberString) { // Safely convert

                 let selectedMediaSource = UserDefaults.standard.selectedMediaSource?.rawValue ?? "GoGoAnime"

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
                         guard animeID != 0 else {
                              print("Could not fetch valid AniList ID for progress update.")
                              return
                          }
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

    func playNextEpisode() {
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
             print("Cell for episode \(nextEpisode.number) not visible, triggering selection logic directly.")
             animeDetailsViewController.showLoadingBanner() // Show loading indicator
             animeDetailsViewController.checkUserDefault(url: nextEpisode.href, cell: EpisodeCell(), fullURL: nextEpisode.href) // Pass dummy cell
         }
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

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        UserDefaults.standard.set(false, forKey: "isToDownload")
        cleanup()
    }

    private func cleanupPlayer() {
         player?.pause()
         player = nil

         if let vc = playerViewController {
             vc.willMove(toParent: nil)
             vc.view.removeFromSuperview()
             vc.removeFromParent()
             playerViewController = nil
         }

         if let token = timeObserverToken {
             // Player might be nil already, check before removing
             // player?.removeTimeObserver(token) // Avoid potential crash
             timeObserverToken = nil
         }
     }

    private func cleanup() {
        cleanupPlayer() // Clean up player resources
        stopExtractionProcess()
        webView?.stopLoading()
        webView?.navigationDelegate = nil // Break retain cycles
        webView?.removeFromSuperview()
        webView = nil
        isVideoPlaying = false // Reset flag
        retryCount = 0 // Reset retry count
        qualityOptions = [] // Clear options
    }

     private func showAlert(title: String, message: String) {
          let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
          alert.addAction(UIAlertAction(title: "OK", style: .default))
          present(alert, animated: true)
      }

    deinit {
        cleanup()
        NotificationCenter.default.removeObserver(self)
        print("ExternalVideoPlayer deinitialized")
    }
}

extension ExternalVideoPlayer: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Start extraction process *after* the page finishes loading
        // The timer handles retries if links aren't immediately available
        // startExtractionProcess() // Moved timer start to viewDidLoad
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        print("Webview failed to load: \(error)")
        // Retry extraction if webview fails, as it might load partially
        if !isVideoPlaying { retryExtractVideoLinks() }
    }
}
