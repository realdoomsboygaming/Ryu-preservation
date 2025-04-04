import UIKit
import AVKit
import SwiftSoup
import GoogleCast
import SafariServices // Ensure SafariServices is imported

class AnimeDetailViewController: UITableViewController, GCKRemoteMediaClientListener, AVPlayerViewControllerDelegate, CustomPlayerViewDelegate { // Added CustomPlayerViewDelegate

    var animeTitle: String?
    var imageUrl: String?
    var href: String?
    var source: String? // Keep track of the source passed in

    var episodes: [Episode] = []
    var synopsis: String = ""
    var aliases: String = ""
    var airdate: String = ""
    var stars: String = ""

    var player: AVPlayer?
    var playerViewController: AVPlayerViewController? // Keep for default player

    var currentEpisodeIndex: Int = 0 // Tracks the currently playing/selected index
    var timeObserverToken: Any? // Keep for default player progress

    var isFavorite: Bool = false
    var isSynopsisExpanded = false
    var isReverseSorted = false
    var hasSentUpdate = false // Flag to prevent multiple updates for one episode

    var availableQualities: [String] = [] // For sources that provide quality options
    var qualityOptions: [(name: String, fileName: String)] = [] // Specific for M3U8 sources like GoGo2

    // Multi-select properties
    private var isSelectMode = false
    private var selectedEpisodes = Set<Episode>()
    private var downloadButton: UIBarButtonItem!
    private var selectButton: UIBarButtonItem!
    private var cancelButton: UIBarButtonItem!
    private var selectAllButton: UIBarButtonItem!
    private var filterButton: UIBarButtonItem!


    // MARK: - Configuration and Lifecycle
    
    func configure(title: String, imageUrl: String, href: String, source: String) {
        self.animeTitle = title
        self.href = href
        self.source = source // Store the source

        // Handle potential default image URL from AniList if source might provide better
        if imageUrl == "https://s4.anilist.co/file/anilistcdn/character/large/default.jpg" && (source == "AniWorld" || source == "TokyoInsider") {
            self.imageUrl = imageUrl // Set temporary fallback
            fetchImageUrl(source: source, href: href, fallback: imageUrl) // Fetch specific image
        } else {
            self.imageUrl = imageUrl
        }
    }

    private func fetchImageUrl(source: String, href: String, fallback: String) {
         guard let url = URL(string: href.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? href) else {
             DispatchQueue.main.async { self.imageUrl = fallback }
             return
         }

          let session = proxySession.createAlamofireProxySession() // Use proxy session if configured
          session.request(url).responseString { [weak self] response in
              guard let self = self else { return }
              switch response.result {
              case .success(let html):
                  do {
                      let doc = try SwiftSoup.parse(html)
                      var extractedImageUrl: String?
                      switch source {
                      case "AniWorld":
                          if let coverBox = try doc.select("div.seriesCoverBox").first(),
                             let img = try coverBox.select("img").first(),
                             let imgSrc = try? img.attr("data-src") {
                              extractedImageUrl = imgSrc.hasPrefix("/") ? "https://aniworld.to\(imgSrc)" : imgSrc
                          }
                      case "TokyoInsider":
                          if let img = try doc.select("img.a_img").first(),
                             let imgSrc = try? img.attr("src") {
                              extractedImageUrl = imgSrc
                          }
                      default: break
                      }
                      DispatchQueue.main.async {
                          self.imageUrl = extractedImageUrl ?? fallback
                          self.tableView.reloadRows(at: [IndexPath(row: 0, section: 0)], with: .none) // Reload header cell
                      }
                  } catch {
                      print("Error extracting image URL from \(source): \(error)")
                      DispatchQueue.main.async { self.imageUrl = fallback }
                  }
              case .failure(let error):
                  print("Error fetching HTML for image from \(source): \(error)")
                  DispatchQueue.main.async { self.imageUrl = fallback }
              }
          }
     }


    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // No need to set UserDefaults here, source is passed during configuration
        sortEpisodes() // Ensure episodes are sorted based on user preference
        tableView.reloadData() // Refresh data possibly changed in settings
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        // updateUI() is now called within fetchAnimeDetails completion
        setupNotifications()
        checkFavoriteStatus()
        setupAudioSession()
        setupCastButton()
        setupMultiSelectUI()

        isReverseSorted = UserDefaults.standard.bool(forKey: "isEpisodeReverseSorted")
        // Don't sort here yet, wait for episodes to be fetched

        navigationItem.largeTitleDisplayMode = .never
        fetchAnimeDetails() // Fetch details on load
        setupRefreshControl()
    }
    
    deinit {
         NotificationCenter.default.removeObserver(self)
         NotificationCenter.default.removeObserver(self, name: UserDefaults.didChangeNotification, object: nil)

         // Clean up Cast SDK listener
         if let castSession = GCKCastContext.sharedInstance().sessionManager.currentCastSession,
            let remoteMediaClient = castSession.remoteMediaClient {
             remoteMediaClient.remove(self)
         }
        print("AnimeDetailViewController deinitialized for \(animeTitle ?? "Unknown")")
     }

    // MARK: - UI Setup
    
    private func setupUI() {
        tableView.backgroundColor = .systemBackground
        tableView.register(AnimeHeaderCell.self, forCellReuseIdentifier: "AnimeHeaderCell")
        tableView.register(SynopsisCell.self, forCellReuseIdentifier: "SynopsisCell")
        tableView.register(EpisodeCell.self, forCellReuseIdentifier: "EpisodeCell")
        tableView.separatorStyle = .none // Or configure as needed
        tableView.allowsSelectionDuringEditing = true // Allow selection in edit mode
    }
    
    private func setupRefreshControl() {
        refreshControl = UIRefreshControl()
        refreshControl?.addTarget(self, action: #selector(handleRefresh), for: .valueChanged)
    }

    private func setupCastButton() {
        let castButton = GCKUICastButton(frame: CGRect(x: 0, y: 0, width: 24, height: 24))
         // Keep existing right bar button items if selectButton is primary
         var rightItems = navigationItem.rightBarButtonItems ?? []
         rightItems.insert(UIBarButtonItem(customView: castButton), at: 0) // Add Cast button first
         navigationItem.rightBarButtonItems = rightItems
    }

    // MARK: - Data Fetching & Handling

    private func fetchAnimeDetails() {
         guard let href = href, let source = source else {
             showAlert(title: "Error", message: "Missing anime information.")
             return
         }
         showLoadingBanner() // Show loading indicator

         AnimeDetailService.fetchAnimeDetails(from: href) { [weak self] result in
             DispatchQueue.main.async {
                 self?.hideLoadingBanner() // Hide indicator regardless of result
                 self?.refreshControl?.endRefreshing() // End refreshing if it was active

                 switch result {
                 case .success(let details):
                      self?.updateAnimeDetails(with: details)
                 case .failure(let error):
                      self?.showAlert(withTitle: "Error Loading Details", message: error.localizedDescription)
                      // Optionally, show a retry button or specific error state
                 }
             }
         }
     }

    @objc private func handleRefresh() {
        fetchAnimeDetails() // Call the fetch function on refresh
    }

    private func updateAnimeDetails(with details: AnimeDetail) {
         self.aliases = details.aliases
         self.synopsis = details.synopsis
         self.airdate = details.airdate
         self.stars = details.stars
         self.episodes = details.episodes
         self.sortEpisodes() // Sort fetched episodes
         self.tableView.reloadData() // Reload all data

         // Load progress for newly loaded episodes
         for (index, episode) in episodes.enumerated() {
             if let cell = tableView.cellForRow(at: IndexPath(row: index, section: 2)) as? EpisodeCell {
                 cell.loadSavedProgress(for: episode.href)
             }
         }
         checkFavoriteStatus() // Re-check favorite status after loading
     }


    private func sortEpisodes() {
        // Sort based on the episodeNumber property of the Episode struct
        episodes.sort { ep1, ep2 in
            if isReverseSorted {
                return ep1.episodeNumber > ep2.episodeNumber
            } else {
                return ep1.episodeNumber < ep2.episodeNumber
            }
        }
    }

    @objc private func userDefaultsChanged() {
        let newIsReverseSorted = UserDefaults.standard.bool(forKey: "isEpisodeReverseSorted")
        if newIsReverseSorted != isReverseSorted {
            isReverseSorted = newIsReverseSorted
            sortEpisodes()
            if episodes.count > 0 { // Only reload if there are episodes
                 tableView.reloadSections(IndexSet(integer: 2), with: .automatic)
            }
        }
    }

    // MARK: - Episode Playback & Handling
    
    func episodeSelected(episode: Episode, cell: EpisodeCell) {
        // Ensure we have the currently selected source
        guard let selectedSource = UserDefaults.standard.selectedMediaSource?.rawValue else {
             showAlert(title: "Error", message: "No media source selected.")
             return
        }

        showLoadingBanner()
        hasSentUpdate = false // Reset update flag for the new episode

        // Store the index of the selected episode
        currentEpisodeIndex = episodes.firstIndex(where: { $0.href == episode.href }) ?? 0
        let fullURL = episode.href // This is the key URL for the specific episode

        // --- Source-Specific Handling ---
        switch selectedSource {
        case "HiAnime":
            // HiAnime needs special handling to get servers/sources via AJAX
            // The 'episode.href' should contain the necessary info (e.g., /watch/anime-slug?ep=ep_id)
            handleHiAnimeSource(url: episode.href, cell: cell, fullURL: fullURL)

        case "AnimeWorld":
            // Construct the API URL
            let baseURL = "https://www.animeworld.so/api/episode/serverPlayerAnimeWorld?id="
            // Extract the ID from the episode href (assuming format like /episode/slug/server-id)
            let episodeId = episode.href.components(separatedBy: "/").last ?? episode.href
            let requestURL = baseURL + episodeId
            checkUserDefault(url: requestURL, cell: cell, fullURL: episode.href) // Pass original href for tracking

        case "AnimeHeaven":
            // Construct the full URL
            let baseURL = "https://animeheaven.me/"
            let requestURL = baseURL + episode.href // href is relative path like episode.php?id=...
            checkUserDefault(url: requestURL, cell: cell, fullURL: episode.href) // Pass original href

        // Add cases for other sources requiring specific URL construction or pre-processing
        case "AnimeFire", "Kuramanime", "Anime3rb", "Anilibria", "AnimeSRBIJA", "AniWorld", "TokyoInsider", "AniVibe", "AnimeUnity", "AnimeFLV", "AnimeBalkan", "AniBunker", "GoGoAnime":
             // These might use the direct href or need simple base URL prepending
             // The checkUserDefault will handle fetching and parsing based on the source
             checkUserDefault(url: episode.href, cell: cell, fullURL: episode.href) // Pass original href

        default:
            // Fallback for potentially unhandled sources
            print("Warning: Handling source '\(selectedSource)' with default logic.")
            checkUserDefault(url: episode.href, cell: cell, fullURL: episode.href)
        }
    }


    // Checks UserDefaults for download/browser player preference before playing
    private func checkUserDefault(url: String, cell: EpisodeCell, fullURL: String) {
        if UserDefaults.standard.bool(forKey: "isToDownload") {
             // Trigger download process (might need the final media URL first)
             print("Download requested for: \(url)")
             playEpisode(url: url, cell: cell, fullURL: fullURL) // Let playEpisode handle fetching the final URL for download
        } else if UserDefaults.standard.bool(forKey: "browserPlayer") {
             openInWeb(fullURL: url) // Open the initial episode page URL in browser
        } else {
             playEpisode(url: url, cell: cell, fullURL: fullURL) // Proceed to fetch and play
        }
    }
    
    // Fetches final video URL and presents player/download/cast
     func playEpisode(url: String, cell: EpisodeCell, fullURL: String) {
         hasSentUpdate = false // Reset for new episode attempt

         // Use the stored source
         guard let selectedSource = self.source ?? UserDefaults.standard.string(forKey: "selectedMediaSource") else {
              hideLoadingBannerAndShowAlert(title: "Error", message: "Selected source is missing.")
              return
         }


         // --- Source-Specific URL Fetching ---
         if selectedSource == "HiAnime" {
              // HiAnime source fetching is handled by handleHiAnimeSource, called from episodeSelected
              // If this function is called directly for HiAnime, it indicates an issue.
              print("Error: playEpisode called directly for HiAnime. Should be handled by handleHiAnimeSource.")
              hideLoadingBannerAndShowAlert(title: "Internal Error", message: "Playback logic error for HiAnime.")
              return
         } else if url.hasSuffix(".mp4") || url.hasSuffix(".m3u8") || url.contains("video.mp4") {
              // If URL is already a direct media link
              guard let directURL = URL(string: url) else {
                   hideLoadingBannerAndShowAlert(title: "Error", message: "Invalid direct media URL.")
                   return
              }
              hideLoadingBanner { [weak self] in
                   self?.playVideo(sourceURL: directURL, cell: cell, fullURL: fullURL)
              }
         } else {
              // Fetch HTML/JSON to extract the final media URL for other sources
              guard let requestURL = encodedURL(from: url) else {
                   hideLoadingBannerAndShowAlert(title: "Error", message: "Invalid episode URL.")
                   return
              }
              
              let session = proxySession.createAlamofireProxySession() // Use proxy session
               session.request(requestURL).responseString { [weak self] response in
                   guard let self = self else { return }
                   
                   switch response.result {
                   case .success(let htmlString):
                       // Extract the final source URL based on the source
                       var srcURL: URL?
                       let sourceEnum = MediaSource(rawValue: selectedSource)

                       // --- Extraction Logic per Source ---
                       switch sourceEnum {
                       case .GoGoAnime:
                            let gogoFetcher = UserDefaults.standard.string(forKey: "gogoFetcher") ?? "Default"
                            if gogoFetcher == "Default" {
                                 srcURL = self.extractIframeSourceURL(from: htmlString) // Might need refining for GoGo's iframe
                            } else { // Secondary
                                 srcURL = self.extractDownloadLink(from: htmlString) // Assuming this selector works for GoGo download links
                            }
                       case .AnimeFire:
                            srcURL = self.extractDataVideoSrcURL(from: htmlString)
                       case .AnimeWorld, .AnimeHeaven, .AnimeBalkan: // Group similar simple extractions
                            srcURL = self.extractVideoSourceURL(from: htmlString)
                       case .Kuramanime:
                            srcURL = URL(string: url) // Kuramanime URL might be direct player page needing different handling
                            // Trigger the specific player needed for Kuramanime
                             DispatchQueue.main.async {
                                 self.hideLoadingBanner()
                                 self.startStreamingButtonTapped(withURL: url, captionURL: "", playerType: VideoPlayerType.playerKura, cell: cell, fullURL: fullURL)
                             }
                             return // Exit early as it uses a specific player presentation
                       case .AnimeSRBIJA:
                           srcURL = self.extractAsgoldURL(from: htmlString)
                       case .Anime3rb:
                            self.anime3rbGetter(from: htmlString) { finalUrl in
                                if let url = finalUrl {
                                     self.hideLoadingBanner()
                                     self.playVideo(sourceURL: url, cell: cell, fullURL: fullURL)
                                } else {
                                     self.hideLoadingBannerAndShowAlert(title: "Error", message: "Error extracting Anime3rb source URL")
                                }
                            }
                            return // Exit early, handled asynchronously
                       case .AniVibe:
                            srcURL = self.extractAniVibeURL(from: htmlString)
                       case .AniBunker:
                            srcURL = self.extractAniBunker(from: htmlString)
                       case .TokyoInsider:
                            self.extractTokyoVideo(from: htmlString) { selectedURL in
                                 DispatchQueue.main.async {
                                     self.hideLoadingBanner()
                                     self.playVideo(sourceURL: selectedURL, cell: cell, fullURL: fullURL)
                                 }
                            }
                            return // Exit early, handled asynchronously
                       case .AniWorld:
                            // AniWorld needs multi-step extraction
                            self.extractVidozaVideoURL(from: htmlString) { videoURL in // Or handle other hosts
                                 guard let finalURL = videoURL else {
                                     self.hideLoadingBannerAndShowAlert(title: "Error", message: "Error extracting AniWorld source URL")
                                     return
                                 }
                                 DispatchQueue.main.async {
                                     self.hideLoadingBanner()
                                     self.playVideo(sourceURL: finalURL, cell: cell, fullURL: fullURL)
                                 }
                            }
                            return // Exit early, handled asynchronously
                       case .AnimeUnity:
                           self.extractEmbedUrl(from: htmlString) { finalUrl in
                               if let url = finalUrl {
                                    self.hideLoadingBanner()
                                    self.playVideo(sourceURL: url, cell: cell, fullURL: fullURL)
                               } else {
                                    self.hideLoadingBannerAndShowAlert(title: "Error", message: "Error extracting AnimeUnity source URL")
                               }
                           }
                           return // Exit early, handled asynchronously
                       case .AnimeFLV:
                           self.extractStreamtapeQueryParameters(from: htmlString) { videoURL in
                               if let url = videoURL {
                                    self.hideLoadingBanner()
                                    self.playVideo(sourceURL: url, cell: cell, fullURL: fullURL)
                               } else {
                                    self.hideLoadingBannerAndShowAlert(title: "Error", message: "Error extracting AnimeFLV source URL")
                               }
                           }
                           return // Exit early, handled asynchronously
                        
                       case .Anilibria, .HiAnime:
                             // These should ideally not reach here if handled earlier
                              print("Error: Unexpected source (\(selectedSource)) in generic fetch block.")
                              self.hideLoadingBannerAndShowAlert(title: "Error", message: "Internal error processing source.")
                       case .none:
                            print("Error: Unknown source \(selectedSource)")
                            self.hideLoadingBannerAndShowAlert(title: "Error", message: "Unknown source selected.")

                       } // End switch

                       // Proceed if srcURL was extracted directly in the switch
                       if let finalSrcURL = srcURL {
                            self.hideLoadingBanner {
                                DispatchQueue.main.async {
                                    // Handle GoGoAnime specific player choice
                                    if sourceEnum == .GoGoAnime {
                                         let gogoFetcher = UserDefaults.standard.string(forKey: "gogoFetcher") ?? "Default"
                                         let playerType = gogoFetcher == "Secondary" ? VideoPlayerType.standard : VideoPlayerType.playerGoGo2 // Use GoGo2 for secondary/direct download link extraction now
                                          self.startStreamingButtonTapped(withURL: finalSrcURL.absoluteString, captionURL: "", playerType: playerType, cell: cell, fullURL: fullURL)
                                    } else {
                                          // Play other sources
                                          self.playVideo(sourceURL: finalSrcURL, cell: cell, fullURL: fullURL)
                                    }
                                }
                           }
                       } else if sourceEnum != .Anime3rb && sourceEnum != .TokyoInsider && sourceEnum != .AniWorld && sourceEnum != .AnimeUnity && sourceEnum != .AnimeFLV {
                            // If srcURL is still nil after the switch (and not handled asynchronously)
                            self.hideLoadingBannerAndShowAlert(title: "Error", message: "The stream URL wasn't found for \(selectedSource).")
                       }


                   case .failure(let error):
                       self.hideLoadingBanner()
                       self.showAlert(title: "Error", message: "Failed to fetch episode page: \(error.localizedDescription)")
                   }
               }
         }
     }

    // MARK: - UI Updates and Navigation

    func showLoadingBanner() {
        #if os(iOS)
        DispatchQueue.main.async {
            // Avoid presenting if already presenting something else
            guard self.presentedViewController == nil else { return }

            let alert = UIAlertController(title: nil, message: "Extracting Video", preferredStyle: .alert)
             alert.view.backgroundColor = UIColor.black.withAlphaComponent(0.6) // More subtle background
             alert.view.alpha = 0.8
             alert.view.layer.cornerRadius = 15

             let loadingIndicator = UIActivityIndicatorView(style: .medium) // Use medium for smaller alert
             loadingIndicator.translatesAutoresizingMaskIntoConstraints = false
             loadingIndicator.startAnimating()

             alert.view.addSubview(loadingIndicator)
             NSLayoutConstraint.activate([
                 loadingIndicator.centerXAnchor.constraint(equalTo: alert.view.centerXAnchor),
                 loadingIndicator.centerYAnchor.constraint(equalTo: alert.view.centerYAnchor, constant: -10), // Adjust position slightly if needed
                 // Add constraints for message label if needed
             ])

             // Adjust alert height if needed
             let heightConstraint = NSLayoutConstraint(item: alert.view!, attribute: .height, relatedBy: .equal, toItem: nil, attribute: .notAnAttribute, multiplier: 1, constant: 80) // Example height
             alert.view.addConstraint(heightConstraint)

             self.present(alert, animated: true, completion: nil)
        }
        #endif
    }

    func hideLoadingBanner(completion: (() -> Void)? = nil) {
        DispatchQueue.main.async {
             // Check if the presented VC is our specific loading alert
             if let alert = self.presentedViewController as? UIAlertController, alert.message == "Extracting Video" {
                 alert.dismiss(animated: true) {
                     completion?()
                 }
             } else {
                 // If some other alert/VC is presented, or none, just call completion
                 completion?()
             }
        }
    }

    func hideLoadingBannerAndShowAlert(title: String, message: String) {
        hideLoadingBanner { [weak self] in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.showAlert(title: title, message: message)
            }
        }
    }
    
     func showAlert(title: String, message: String) {
         // Ensure alerts are presented correctly, even if another view is already presented
         DispatchQueue.main.async {
              let alertController = UIAlertController(title: title, message: message, preferredStyle: .alert)
              alertController.addAction(UIAlertAction(title: "OK", style: .default, handler: nil))

              var presentingController = self.navigationController ?? self // Start with nav controller or self
               // Find the topmost view controller
               while let presented = presentingController.presentedViewController {
                    presentingController = presented
               }

              // Ensure we don't present over the loading banner if it's still somehow visible
               if !(presentingController is UIAlertController && (presentingController as! UIAlertController).message == "Extracting Video") {
                    presentingController.present(alertController, animated: true, completion: nil)
               } else {
                    // If loading banner is still up, dismiss it first, then show the error
                     presentingController.dismiss(animated: false) { [weak presentingController] in
                           presentingController?.present(alertController, animated: true, completion: nil)
                     }
               }
         }
     }

    // MARK: - TableView DataSource & Delegate
    override func numberOfSections(in tableView: UITableView) -> Int {
        return 3 // Header, Synopsis, Episodes
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch section {
        case 0, 1: return 1
        case 2: return episodes.count
        default: return 0
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch indexPath.section {
        case 0:
            let cell = tableView.dequeueReusableCell(withIdentifier: "AnimeHeaderCell", for: indexPath) as! AnimeHeaderCell
            cell.configure(title: animeTitle, imageUrl: imageUrl, aliases: aliases, isFavorite: isFavorite, airdate: airdate, stars: stars, href: href)
            cell.favoriteButtonTapped = { [weak self] in self?.toggleFavorite() }
            cell.showOptionsMenu = { [weak self] in self?.showOptionsMenu() }
             cell.watchNextTapped = { [weak self] in self?.watchNextEpisode() }
            return cell
        case 1:
            let cell = tableView.dequeueReusableCell(withIdentifier: "SynopsisCell", for: indexPath) as! SynopsisCell
            cell.configure(synopsis: synopsis, isExpanded: isSynopsisExpanded)
            cell.delegate = self
            return cell
        case 2:
            let cell = tableView.dequeueReusableCell(withIdentifier: "EpisodeCell", for: indexPath) as! EpisodeCell
             guard indexPath.row < episodes.count else { return cell } // Bounds check
            let episode = episodes[indexPath.row]
            cell.configure(episode: episode, delegate: self)
            cell.loadSavedProgress(for: episode.href)
             cell.setSelectionMode(isSelectMode, isSelected: selectedEpisodes.contains(episode))
            return cell
        default:
            return UITableViewCell()
        }
    }
    
     // Adjust height for sections
     override func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
         switch indexPath.section {
         case 0: return UITableView.automaticDimension // Header cell
         case 1: return UITableView.automaticDimension // Synopsis cell
         case 2: return 65 // Episode cell height
         default: return 44
         }
     }

     override func tableView(_ tableView: UITableView, estimatedHeightForRowAt indexPath: IndexPath) -> CGFloat {
          switch indexPath.section {
          case 0: return 250 // Estimate for header
          case 1: return 100 // Estimate for synopsis
          case 2: return 65 // Fixed height for episodes
          default: return 44
          }
      }


    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
         tableView.deselectRow(at: indexPath, animated: true)
         if indexPath.section == 2 {
              guard indexPath.row < episodes.count else { return } // Bounds check
              let episode = episodes[indexPath.row]
              if isSelectMode {
                   if selectedEpisodes.contains(episode) {
                       selectedEpisodes.remove(episode)
                   } else {
                       selectedEpisodes.insert(episode)
                   }
                   downloadButton.isEnabled = !selectedEpisodes.isEmpty
                   tableView.reloadRows(at: [indexPath], with: .automatic)
              } else {
                   if let cell = tableView.cellForRow(at: indexPath) as? EpisodeCell {
                       episodeSelected(episode: episode, cell: cell)
                   }
              }
         }
     }

    // MARK: - Audio Session & Notifications
    private func setupNotifications() {
        NotificationCenter.default.addObserver(self, selector: #selector(handleInterruption), name: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance())
        NotificationCenter.default.addObserver(self, selector: #selector(userDefaultsChanged), name: UserDefaults.didChangeNotification, object: nil)
    }

    private func setupAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Failed to set audio session category: \(error)")
        }
    }

    @objc private func handleInterruption(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }
        if type == .began {
            player?.pause() // Pause default player
            // Add logic to pause custom player if applicable
        } else if type == .ended {
            if let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                if options.contains(.shouldResume) {
                    player?.play() // Resume default player
                    // Add logic to resume custom player if applicable
                }
            }
        }
    }

    // MARK: - Favorite Handling
    private func toggleFavorite() {
        isFavorite.toggle()
        if let anime = createFavoriteAnime() {
            if isFavorite {
                FavoritesManager.shared.addFavorite(anime)
                if UserDefaults.standard.bool(forKey: "notificationEpisodes") { // Check setting
                     fetchAniListIDForNotifications()
                 }
            } else {
                FavoritesManager.shared.removeFavorite(anime)
                 // Cancel notifications when removing from favorites
                 if let title = animeTitle {
                      if let customID = UserDefaults.standard.string(forKey: "customAniListID_\(title)"), let animeID = Int(customID) {
                           AnimeEpisodeService.cancelNotifications(forAnimeID: animeID)
                      } else {
                           let cleanedTitle = cleanTitle(title)
                           AnimeService.fetchAnimeID(byTitle: cleanedTitle) { result in
                               if case .success(let id) = result {
                                    AnimeEpisodeService.cancelNotifications(forAnimeID: id)
                               }
                           }
                      }
                 }
            }
        }
         // Reload only the header section
         if tableView.numberOfSections > 0 {
             tableView.reloadSections(IndexSet(integer: 0), with: .none)
         }
    }


    private func createFavoriteAnime() -> FavoriteItem? {
         guard let title = animeTitle,
               let imageUrlString = self.imageUrl, // Use the potentially updated imageUrl
               let imageURL = URL(string: imageUrlString),
               let hrefString = self.href, // Use stored href
               let contentURL = URL(string: hrefString),
               let source = self.source // Use stored source
               else {
             print("Error: Missing data to create FavoriteItem")
             return nil
         }
         return FavoriteItem(title: title, imageURL: imageURL, contentURL: contentURL, source: source)
     }


    private func checkFavoriteStatus() {
        if let anime = createFavoriteAnime() {
            isFavorite = FavoritesManager.shared.isFavorite(anime)
            if isFavorite && UserDefaults.standard.bool(forKey: "notificationEpisodes") {
                 fetchAniListIDForNotifications()
             }
            // Reload header cell to update bookmark icon
             if tableView.numberOfSections > 0 && tableView.numberOfRows(inSection: 0) > 0 {
                  tableView.reloadRows(at: [IndexPath(row: 0, section: 0)], with: .none)
             }
        }
    }
    
    // MARK: - Menu Actions & Navigation (Includes HiAnime update)
    private func showOptionsMenu() {
         let alertController = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)

         let trackingServicesAction = UIAlertAction(title: "Tracking Services", style: .default) { [weak self] _ in
             self?.fetchAnimeIDAndMappings()
         }
         trackingServicesAction.setValue(UIImage(systemName: "list.bullet"), forKey: "image")
         alertController.addAction(trackingServicesAction)

         let advancedSettingsAction = UIAlertAction(title: "Advanced Settings", style: .default) { [weak self] _ in
             self?.showAdvancedSettingsMenu()
         }
         advancedSettingsAction.setValue(UIImage(systemName: "gear"), forKey: "image")
         alertController.addAction(advancedSettingsAction)

         let fetchIDAction = UIAlertAction(title: "AniList Info", style: .default) { [weak self] _ in
             guard let self = self else { return }
             let cleanedTitle = self.cleanTitle(self.animeTitle ?? "Title")
             self.fetchAndNavigateToAnime(title: cleanedTitle)
         }
         fetchIDAction.setValue(UIImage(systemName: "info.circle"), forKey: "image")
         alertController.addAction(fetchIDAction)

          let currentSource = self.source ?? UserDefaults.standard.string(forKey: "selectedMediaSource") ?? ""
          // Allow "Open in Web" for HiAnime now
          if currentSource != "Anilibria" { // Only exclude Anilibria for now
               let openOnWebAction = UIAlertAction(title: "Open in Web", style: .default) { [weak self] _ in
                    self?.openAnimeOnWeb()
               }
               openOnWebAction.setValue(UIImage(systemName: "safari"), forKey: "image")
               alertController.addAction(openOnWebAction)
          }


         let cancelAction = UIAlertAction(title: "Cancel", style: .cancel, handler: nil)
         alertController.addAction(cancelAction)

         // Popover presentation for iPad
         if let popoverController = alertController.popoverPresentationController {
             // Try to anchor to the button that opened it, or fallback to view center
             if let headerCell = tableView.cellForRow(at: IndexPath(row: 0, section: 0)) as? AnimeHeaderCell {
                  popoverController.sourceView = headerCell.optionsButton // Anchor to the options button
                  popoverController.sourceRect = headerCell.optionsButton.bounds
             } else {
                  popoverController.sourceView = view
                  popoverController.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
                  popoverController.permittedArrowDirections = []
             }
         }

         present(alertController, animated: true, completion: nil)
     }

     private func openAnimeOnWeb() {
         guard let path = href, let source = self.source ?? UserDefaults.standard.string(forKey: "selectedMediaSource") else {
             showAlert(withTitle: "Error", message: "The URL or source is invalid.")
             return
         }

         let baseUrl: String
         switch source {
         case "AnimeWorld": baseUrl = "https://animeworld.so"
         case "GoGoAnime": baseUrl = "https://anitaku.bz"
         case "AnimeHeaven": baseUrl = "https://animeheaven.me/"
         case "HiAnime": baseUrl = "https://hianime.to" // Base URL for HiAnime
         case "AnimeFire": baseUrl = "https://animefire.plus"
         case "Kuramanime": baseUrl = "https://kuramanime.red" // Check if base URL needed
         case "Anime3rb": baseUrl = "" // Might be absolute
         case "Anilibria": baseUrl = "https://anilibria.tv/release/" // Example base
         case "AnimeSRBIJA": baseUrl = "https://www.animesrbija.com"
         case "AniWorld": baseUrl = "https://aniworld.to"
         case "TokyoInsider": baseUrl = "https://www.tokyoinsider.com"
         case "AniVibe": baseUrl = "https://anivibe.net"
         case "AnimeUnity": baseUrl = "https://www.animeunity.to"
         case "AnimeFLV": baseUrl = "https://www3.animeflv.net"
         case "AnimeBalkan": baseUrl = "" // Might be absolute
         case "AniBunker": baseUrl = "https://www.anibunker.com"
         default: baseUrl = ""
         }

         // Construct the full URL, handling relative paths
         let fullUrlString: String
         if path.starts(with: "http") {
             fullUrlString = path
         } else if baseUrl.isEmpty {
              showAlert(withTitle: "Error", message: "Cannot determine base URL for this source.")
              return
         } else {
             fullUrlString = baseUrl + (path.starts(with: "/") ? path : "/\(path)")
         }


         guard let url = URL(string: fullUrlString) else {
             showAlert(withTitle: "Error", message: "The constructed URL is invalid: \(fullUrlString)")
             return
         }

         let safariViewController = SFSafariViewController(url: url)
         present(safariViewController, animated: true, completion: nil)
     }
     
    // MARK: - Player and Casting (Includes HiAnime update)
     @objc func startStreamingButtonTapped(withURL url: String, captionURL: String, playerType: String, cell: EpisodeCell, fullURL: String) {
         deleteWebKitFolder() // Keep this if needed for specific players
         presentStreamingView(withURL: url, captionURL: captionURL, playerType: playerType, cell: cell, fullURL: fullURL)
     }

     func presentStreamingView(withURL url: String, captionURL: String, playerType: String, cell: EpisodeCell, fullURL: String) {
         hideLoadingBanner { [weak self] in
             guard let self = self else { return }
             DispatchQueue.main.async {
                 var streamingVC: UIViewController
                 switch playerType {
                 case VideoPlayerType.standard:
                     streamingVC = ExternalVideoPlayer(streamURL: url, cell: cell, fullURL: fullURL, animeDetailsViewController: self)
                 case VideoPlayerType.player3rb:
                     streamingVC = ExternalVideoPlayer3rb(streamURL: url, cell: cell, fullURL: fullURL, animeDetailsViewController: self)
                 case VideoPlayerType.playerKura:
                     streamingVC = ExternalVideoPlayerKura(streamURL: url, cell: cell, fullURL: fullURL, animeDetailsViewController: self)
                 case VideoPlayerType.playerGoGo2:
                     streamingVC = ExternalVideoPlayerGoGo2(streamURL: url, cell: cell, fullURL: fullURL, animeDetailsViewController: self)
                 case VideoPlayerType.playerWeb:
                      // Pass necessary data to WebPlayer
                      streamingVC = WebPlayer(streamURL: url, captionURL: captionURL, cell: cell, fullURL: fullURL, animeDetailsViewController: self)
                 default:
                      print("Error: Unknown player type requested: \(playerType)")
                      self.showAlert(title: "Error", message: "Invalid player type selected.")
                      return // Don't present anything if player type is invalid
                 }
                 streamingVC.modalPresentationStyle = .fullScreen
                 self.present(streamingVC, animated: true, completion: nil)
             }
         }
     }


    func playVideo(sourceURL: URL, cell: EpisodeCell, fullURL: String) {
        hideLoadingBanner() // Ensure banner is hidden before presenting player/options
        let selectedPlayer = UserDefaults.standard.string(forKey: "mediaPlayerSelected") ?? "Default"
        let isToDownload = UserDefaults.standard.bool(forKey: "isToDownload")

        if isToDownload {
            DispatchQueue.main.async {
                 self.hideLoadingBanner() // Explicitly hide again just before download starts
                self.handleDownload(sourceURL: sourceURL, fullURL: fullURL)
            }
        } else {
             DispatchQueue.main.async { // Ensure UI operations are on main thread
                  self.playVideoWithSelectedPlayer(player: selectedPlayer, sourceURL: sourceURL, cell: cell, fullURL: fullURL)
             }
        }
    }
    
    // MARK: - Multi-Select Implementation
     func setupMultiSelectUI() {
         selectButton = UIBarButtonItem(title: "Select", style: .plain, target: self, action: #selector(toggleSelectMode))
         downloadButton = UIBarButtonItem(image: UIImage(systemName: "arrow.down.circle"), style: .plain, target: self, action: #selector(downloadSelectedEpisodes))
         cancelButton = UIBarButtonItem(title: "Cancel", style: .plain, target: self, action: #selector(toggleSelectMode))
         selectAllButton = UIBarButtonItem(title: "Select All", style: .plain, target: self, action: #selector(selectAllEpisodes))
         filterButton = UIBarButtonItem(image: UIImage(systemName: "line.3.horizontal.decrease.circle"), style: .plain, target: self, action: #selector(showFilterOptions))

         // Set initial state (non-editing)
         navigationItem.leftBarButtonItem = nil // No left button initially
         // Keep existing right items (Cast button) and add the Select button
         var currentRightItems = navigationItem.rightBarButtonItems ?? []
         // Ensure Select button isn't added multiple times if this setup is called again
          if !currentRightItems.contains(selectButton) {
               currentRightItems.append(selectButton) // Add Select button
               navigationItem.rightBarButtonItems = currentRightItems
          }
     }


     @objc private func toggleSelectMode() {
         isSelectMode.toggle()
         selectedEpisodes.removeAll() // Clear selection when toggling mode

         if isSelectMode {
              // Keep Cast button, replace Select with Cancel, Filter, Download
              let castButton = navigationItem.rightBarButtonItems?.first // Assume Cast is first
              navigationItem.leftBarButtonItem = selectAllButton
              navigationItem.rightBarButtonItems = [castButton, cancelButton, filterButton, downloadButton].compactMap { $0 } // Keep cast if it exists
              downloadButton.isEnabled = false // Disable download initially
              tableView.allowsMultipleSelection = true // Allow multiple selections
         } else {
              // Restore original state: Cast and Select buttons
              let castButton = navigationItem.rightBarButtonItems?.first // Assume Cast is first
              navigationItem.leftBarButtonItem = nil
              navigationItem.rightBarButtonItems = [castButton, selectButton].compactMap { $0 }
              tableView.allowsMultipleSelection = false
         }

         // Reload only the episodes section to show/hide selection indicators
         if episodes.count > 0 {
             tableView.reloadSections(IndexSet(integer: 2), with: .automatic)
         }
     }


    @objc private func showFilterOptions() {
        let alertController = UIAlertController(title: "Filter/Select Episodes", message: nil, preferredStyle: .actionSheet)

        let selectUnwatchedAction = UIAlertAction(title: "Select Unwatched Episodes", style: .default) { [weak self] _ in
            self?.selectUnwatchedEpisodes()
        }

        let selectWatchedAction = UIAlertAction(title: "Select Watched Episodes", style: .default) { [weak self] _ in
            self?.selectWatchedEpisodes()
        }

        let rangeSelectionAction = UIAlertAction(title: "Range Selection", style: .default) { [weak self] _ in
            self?.showRangeSelectionDialog()
        }

        let deselectAllAction = UIAlertAction(title: "Deselect All", style: .default) { [weak self] _ in
            self?.deselectAllEpisodes()
        }
        
        let cancelAction = UIAlertAction(title: "Cancel", style: .cancel, handler: nil)

        alertController.addAction(selectUnwatchedAction)
        alertController.addAction(selectWatchedAction)
        alertController.addAction(rangeSelectionAction)
        alertController.addAction(deselectAllAction)
        alertController.addAction(cancelAction)

        // Popover presentation for iPad
         if let popoverController = alertController.popoverPresentationController {
              // Anchor to the filter button itself
              popoverController.barButtonItem = self.filterButton // Use the stored reference
         }


        present(alertController, animated: true, completion: nil)
    }

    // --- Selection helper methods ---
     private func selectUnwatchedEpisodes() {
         selectedEpisodes.removeAll() // Start fresh or add to existing? Clearing is safer.
         for episode in episodes {
             let lastPlayedTime = UserDefaults.standard.double(forKey: "lastPlayedTime_\(episode.href)")
             let totalTime = UserDefaults.standard.double(forKey: "totalTime_\(episode.href)")
             if totalTime <= 0 || (lastPlayedTime / totalTime) < 0.90 { // Consider watched if >= 90%
                  selectedEpisodes.insert(episode)
             }
         }
         downloadButton.isEnabled = !selectedEpisodes.isEmpty
         if episodes.count > 0 { tableView.reloadSections(IndexSet(integer: 2), with: .automatic) }
     }

     private func selectWatchedEpisodes() {
          selectedEpisodes.removeAll()
          for episode in episodes {
               let lastPlayedTime = UserDefaults.standard.double(forKey: "lastPlayedTime_\(episode.href)")
               let totalTime = UserDefaults.standard.double(forKey: "totalTime_\(episode.href)")
               if totalTime > 0 && (lastPlayedTime / totalTime) >= 0.90 {
                    selectedEpisodes.insert(episode)
               }
          }
          downloadButton.isEnabled = !selectedEpisodes.isEmpty
          if episodes.count > 0 { tableView.reloadSections(IndexSet(integer: 2), with: .automatic) }
      }

     private func showRangeSelectionDialog() {
         let alertController = UIAlertController(title: "Select Episode Range", message: "Enter start and end episode numbers", preferredStyle: .alert)

         alertController.addTextField { textField in
             textField.placeholder = "Start Episode (e.g., 1)"
             textField.keyboardType = .numberPad
         }
         alertController.addTextField { textField in
             textField.placeholder = "End Episode (e.g., 12)"
             textField.keyboardType = .numberPad
         }

         let selectAction = UIAlertAction(title: "Select", style: .default) { [weak self, weak alertController] _ in
             guard let self = self,
                   let startText = alertController?.textFields?[0].text,
                   let endText = alertController?.textFields?[1].text,
                   let start = Int(startText),
                   let end = Int(endText), start <= end else { // Basic validation
                 self.showAlert(title: "Error", message: "Please enter valid start and end episode numbers.")
                 return
             }
             self.selectEpisodesInRange(start: start, end: end)
         }
         let cancelAction = UIAlertAction(title: "Cancel", style: .cancel)
         alertController.addAction(selectAction)
         alertController.addAction(cancelAction)
         present(alertController, animated: true)
     }


    private func selectEpisodesInRange(start: Int, end: Int) {
         // selectedEpisodes.removeAll() // Decide if range selection should clear previous or add
         for episode in episodes {
              if episode.episodeNumber >= start && episode.episodeNumber <= end {
                   selectedEpisodes.insert(episode)
              }
         }
         downloadButton.isEnabled = !selectedEpisodes.isEmpty
         if episodes.count > 0 { tableView.reloadSections(IndexSet(integer: 2), with: .automatic) }
     }

     private func deselectAllEpisodes() {
         selectedEpisodes.removeAll()
         downloadButton.isEnabled = false
         if episodes.count > 0 { tableView.reloadSections(IndexSet(integer: 2), with: .automatic) }
     }


    @objc private func selectAllEpisodes() {
        selectedEpisodes = Set(episodes)
        downloadButton.isEnabled = !selectedEpisodes.isEmpty
        if episodes.count > 0 { tableView.reloadSections(IndexSet(integer: 2), with: .automatic) }
    }

    @objc private func downloadSelectedEpisodes() {
        guard !selectedEpisodes.isEmpty else { return }

        showAlert(
            title: "Download Multiple Episodes",
            message: "Do you want to queue \(selectedEpisodes.count) selected episodes for download?",
            actions: [
                UIAlertAction(title: "Cancel", style: .cancel, handler: nil),
                UIAlertAction(title: "Download", style: .default) { [weak self] _ in
                    self?.startBatchDownload()
                }
            ]
        )
    }

    private func startBatchDownload() {
        let episodesToDownload = Array(selectedEpisodes).sorted { $0.episodeNumber < $1.episodeNumber }

         // Check source compatibility
          guard let source = self.source ?? UserDefaults.standard.string(forKey: "selectedMediaSource"),
                MediaSource(rawValue: source) != .hianime,
                MediaSource(rawValue: source) != .anilibria,
                MediaSource(rawValue: source) != .aniworld,
                MediaSource(rawValue: source) != .anivibe else {
               showAlert(title: "Download Not Supported", message: "Batch download is not supported for the current source (\(source)). Please download episodes individually if available.")
               toggleSelectMode() // Exit select mode even if download fails
               return
          }


        UserDefaults.standard.set(true, forKey: "isToDownload") // Set download flag *once*
        processNextDownload(episodes: episodesToDownload)
        toggleSelectMode() // Exit select mode after starting
    }

    private func processNextDownload(episodes: [Episode], index: Int = 0) {
        guard index < episodes.count else {
            showAlert(title: "Downloads Queued", message: "\(episodes.count) episodes have been added to the download queue.")
            UserDefaults.standard.set(false, forKey: "isToDownload") // Reset flag *after* all are queued
            return
        }

        let episode = episodes[index]
        print("Queueing download for Episode \(episode.number)")

        // Use a dummy cell as the actual cell might not be visible/loaded
        let dummyCell = EpisodeCell()
        dummyCell.episodeNumber = episode.number

        // We call episodeSelected which will internally set 'isToDownload' and trigger the fetch->download flow
         // Make sure episodeSelected correctly handles the isToDownload flag *now*
         // We set it to true before calling this batch process.
         self.episodeSelected(episode: episode, cell: dummyCell)


        // Introduce a small delay before processing the next episode
        // to avoid overwhelming the network/system. Adjust delay as needed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.processNextDownload(episodes: episodes, index: index + 1)
        }
    }


    // Helper method for showing alerts with multiple actions
    private func showAlert(title: String, message: String, actions: [UIAlertAction]) {
        let alertController = UIAlertController(title: title, message: message, preferredStyle: .alert)
        for action in actions {
            alertController.addAction(action)
        }
        present(alertController, animated: true, completion: nil)
    }

     // MARK: - CustomPlayerViewDelegate
     func customPlayerViewDidDismiss() {
         // Handle any necessary cleanup or state updates after the custom player is dismissed
         print("Custom player dismissed")
          // Optional: Reload progress for the current cell if needed
          if currentEpisodeIndex < episodes.count {
               if let cell = tableView.cellForRow(at: IndexPath(row: currentEpisodeIndex, section: 2)) as? EpisodeCell {
                    cell.loadSavedProgress(for: episodes[currentEpisodeIndex].href)
               }
          }
     }
    
    // Add other necessary methods from AnimeDetailsMethods.swift directly here or ensure they are accessible
    // (like fetchHiAnimeData, extractEpisodeId, fetchEpisodeOptions, etc.)

    // MARK: - Placeholder for Methods from AnimeDetailsMethods.swift
    // (Copy the implementations from AnimeDetailsMethods.swift into this class)
    // func selectAudioCategory(...) { ... }
    // func selectServer(...) { ... }
    // func selectSubtitles(...) { ... }
    // func presentDubSubRawSelection(...) { ... }
    // func presentServerSelection(...) { ... }
    // func presentSubtitleSelection(...) { ... }
    // func importSubtitlesFromURL(...) { ... }
    // func downloadSubtitles(...) { ... }
    // func presentAlert(...) { ... }
    // func fetchHiAnimeData(...) { ... }
    // func fetchHTMLContent(...) { ... }
    // func extractVideoSourceURL(...) { ... }
    // func extractURL(...) { ... }
    // func extractIframeSourceURL(...) { ... }
    // func extractAniBunker(...) { ... }
    // func extractEmbedUrl(...) { ... }
    // func extractWindowUrl(...) { ... }
    // func extractDataVideoSrcURL(...) { ... }
    // func extractDownloadLink(...) { ... }
    // func extractTokyoVideo(...) { ... }
    // func extractAsgoldURL(...) { ... }
    // func extractAniVibeURL(...) { ... }
    // func extractStreamtapeQueryParameters(...) { ... }
    // func anime3rbGetter(...) { ... }
    // func extractAnime3rbVideoURL(...) { ... }
    // func extractAnime3rbMP4VideoURL(...) { ... }
    // func fetchVideoDataAndChooseQuality(...) { ... }
    // func choosePreferredQuality(...) { ... }
    // func showQualityPicker(...) { ... }
    // func extractVidozaVideoURL(...) { ... }
     // --- Copy method implementations from AnimeDetailsMethods.swift here ---
     // Example (copy all relevant methods):
     func selectAudioCategory(options: [String: [[String: Any]]], preferredAudio: String, completion: @escaping (String) -> Void) {
         // Implementation from AnimeDetailsMethods.swift
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
          // Implementation from AnimeDetailsMethods.swift
           if let server = servers.first(where: { ($0["serverName"] as? String)?.lowercased() == preferredServer.lowercased() }) { // Case-insensitive match
                completion(server["serverName"] as? String ?? "")
           } else if let firstServer = servers.first, let serverName = firstServer["serverName"] as? String {
                // Fallback to the first available server if preferred is not found
                 print("Preferred server '\(preferredServer)' not found, falling back to '\(serverName)'")
                completion(serverName)
           }
           else {
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
         // Implementation from AnimeDetailsMethods.swift
          guard let captionURLs = captionURLs, !captionURLs.isEmpty else {
               completion(nil)
               return
          }

          let preferredSubtitles = UserDefaults.standard.string(forKey: "subtitleHiPrefe") ?? "English" // Default to English

          if preferredSubtitles == "No Subtitles" {
               completion(nil)
               return
          }
          if preferredSubtitles == "Always Import" {
               self.hideLoadingBanner { // Hide loading before showing import options
                    self.importSubtitlesFromURL(completion: completion)
               }
               return
          }
          // Try to find an exact match first
          if let preferredURL = captionURLs.first(where: { $0.key.lowercased() == preferredSubtitles.lowercased() })?.value {
                completion(preferredURL)
                return
            }
          // Fallback: If exact match not found, try finding *any* English subtitle if preferred was English
           if preferredSubtitles.lowercased() == "english", let englishFallback = captionURLs.first(where: { $0.key.lowercased().contains("english") })?.value {
                print("Preferred subtitle '\(preferredSubtitles)' not found, falling back to first available English.")
                completion(englishFallback)
                return
            }
            // If still not found, show selection
           hideLoadingBanner {
                DispatchQueue.main.async {
                     self.presentSubtitleSelection(captionURLs: captionURLs, completion: completion)
                }
           }
     }

     func presentSubtitleSelection(captionURLs: [String: URL], completion: @escaping (URL?) -> Void) {
          let alert = UIAlertController(title: "Select Subtitle Source", message: nil, preferredStyle: .actionSheet)

          // Sort keys alphabetically for consistent order
           let sortedKeys = captionURLs.keys.sorted()

          for key in sortedKeys {
               if let url = captionURLs[key] {
                    alert.addAction(UIAlertAction(title: key, style: .default) { _ in
                         completion(url)
                    })
               }
          }

          alert.addAction(UIAlertAction(title: "Import from a URL...", style: .default) { [weak self] _ in
               self?.importSubtitlesFromURL(completion: completion)
          })

          alert.addAction(UIAlertAction(title: "No Subtitles", style: .default) { _ in
               completion(nil)
          })

          alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in
                // If cancelled, maybe default to no subtitles or the first available?
                // For now, just completing with nil might be okay, or you could default.
                 completion(nil) // Or completion(captionURLs.first?.value)
            })

          presentAlert(alert) // Use helper to present
      }

     func importSubtitlesFromURL(completion: @escaping (URL?) -> Void) {
          let alert = UIAlertController(title: "Enter Subtitle URL", message: "Enter the URL of the subtitle file (.srt, .ass, or .vtt)", preferredStyle: .alert)

          alert.addTextField { textField in
               textField.placeholder = "https://example.com/subtitles.srt"
               textField.keyboardType = .URL
               textField.autocorrectionType = .no
               textField.autocapitalizationType = .none
          }

          alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completion(nil) }) // Ensure completion is called

          alert.addAction(UIAlertAction(title: "Import", style: .default) { [weak self, weak alert] _ in
               guard let self = self,
                     let urlString = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                     let url = URL(string: urlString),
                     let fileExtension = Optional(url.pathExtension.lowercased()), // Make optional
                     ["srt", "ass", "vtt"].contains(fileExtension) else {
                    self.showAlert(title: "Error", message: "Invalid subtitle URL. Must be a valid URL ending with .srt, .ass, or .vtt")
                    completion(nil) // Ensure completion is called on error
                    return
               }

               self.showLoadingBanner() // Show loading while downloading
               self.downloadSubtitles(from: url, completion: { localURL in
                    self.hideLoadingBanner() // Hide loading after download attempt
                    completion(localURL)
               })
          })

          presentAlert(alert) // Use helper to present
      }


     func downloadSubtitles(from url: URL, completion: @escaping (URL?) -> Void) {
          let task = URLSession.shared.downloadTask(with: url) { localURL, response, error in
               guard let localURL = localURL,
                     error == nil,
                     let httpResponse = response as? HTTPURLResponse, // Check if it's HTTP response
                      (200...299).contains(httpResponse.statusCode) // Check for success status code
                      else {
                     print("Error downloading subtitles: \(error?.localizedDescription ?? "Unknown error"), Status Code: \((response as? HTTPURLResponse)?.statusCode ?? 0)")
                     DispatchQueue.main.async {
                          self.showAlert(title: "Error", message: "Failed to download subtitles. Status: \((response as? HTTPURLResponse)?.statusCode ?? 0)")
                          completion(nil)
                     }
                     return
                }

               // Create a unique temporary file URL
               let tempDirectory = FileManager.default.temporaryDirectory
               let destinationURL = tempDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(url.pathExtension)

               do {
                    // If a file already exists at the destination, remove it first
                     if FileManager.default.fileExists(atPath: destinationURL.path) {
                          try FileManager.default.removeItem(at: destinationURL)
                     }
                    try FileManager.default.moveItem(at: localURL, to: destinationURL)
                    DispatchQueue.main.async {
                         completion(destinationURL) // Return the URL in the temporary directory
                    }
               } catch {
                    print("Error moving downloaded subtitle file: \(error)")
                    DispatchQueue.main.async {
                         self.showAlert(title: "Error", message: "Failed to save subtitles locally.")
                         completion(nil)
                    }
               }
          }
          task.resume()
      }

      // Helper to present alerts consistently
      func presentAlert(_ alert: UIAlertController) {
           // Find the topmost view controller to present the alert
            var topController = UIApplication.shared.windows.first { $0.isKeyWindow }?.rootViewController
            while let presentedViewController = topController?.presentedViewController {
                 topController = presentedViewController
            }

            // Ensure it's not presented over itself or another alert if possible
            if !(topController is UIAlertController) {
                 topController?.present(alert, animated: true, completion: nil)
            } else {
                 print("Warning: Tried to present alert while another was already visible.")
                 // Optionally dismiss the old one first, or just log the warning
            }
       }
    
    func fetchHiAnimeData(from fullURL: String, completion: @escaping (URL?, [String: URL]?) -> Void) {
        // Implementation from AnimeDetailsMethods.swift
         guard let url = URL(string: fullURL) else {
             print("Invalid URL for HiAnime: \(fullURL)")
             completion(nil, nil)
             return
         }

         URLSession.shared.dataTask(with: url) { (data, response, error) in
             if let error = error {
                 print("Error fetching HiAnime data: \(error.localizedDescription)")
                 completion(nil, nil)
                 return
             }

             guard let data = data else {
                 print("Error: No data received from HiAnime")
                 completion(nil, nil)
                 return
             }

             do {
                 if let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
                     var captionURLs: [String: URL] = [:]

                     if let tracks = json["tracks"] as? [[String: Any]] {
                         for track in tracks {
                             if let file = track["file"] as? String,
                                let label = track["label"] as? String,
                                track["kind"] as? String == "captions", // Ensure it's a caption track
                                let captionUrl = URL(string: file) { // Validate URL
                                 captionURLs[label] = captionUrl
                             }
                         }
                     }

                     var sourceURL: URL?
                     if let sources = json["sources"] as? [[String: Any]] {
                         // Prioritize 'hls' or specific quality if needed, otherwise take first valid URL
                          if let firstSource = sources.first, let urlString = firstSource["url"] as? String {
                               sourceURL = URL(string: urlString)
                          }
                     }

                     completion(sourceURL, captionURLs.isEmpty ? nil : captionURLs) // Return nil if no captions found
                 } else {
                      print("HiAnime JSON structure is not as expected or 'data' key is missing")
                      completion(nil, nil)
                 }
             } catch {
                 print("Error parsing HiAnime JSON: \(error.localizedDescription)")
                 completion(nil, nil)
             }
         }.resume()
    }

    func presentDubSubRawSelection(options: [String: [[String: Any]]], preferredType: String, completion: @escaping (String) -> Void) {
         // Implementation from AnimeDetailsMethods.swift
          DispatchQueue.main.async {
              let availableOptions = options.filter { !$0.value.isEmpty }

              if availableOptions.isEmpty {
                   print("No audio options available")
                   self.showAlert(title: "Error", message: "No audio options available for this episode.")
                   // What should happen here? Maybe default to 'sub' or fail?
                   // Let's default to 'sub' if nothing else works, but ideally an error is better.
                   completion("sub") // Or handle failure appropriately
                   return
              }

              // If only one option is available, select it automatically
              if availableOptions.count == 1, let onlyOption = availableOptions.first {
                   print("Only one audio option available: \(onlyOption.key)")
                   completion(onlyOption.key)
                   return
              }

               // Check if the preferred type is available
                if availableOptions[preferredType] != nil {
                     print("Preferred audio type '\(preferredType)' found.")
                     completion(preferredType)
                     return
                }

               // If preferred type not found, show selection prompt
                print("Preferred audio type '\(preferredType)' not found. Showing selection.")
               let alert = UIAlertController(title: "Select Audio Type", message: "Your preferred audio ('\(preferredType.capitalized)') is not available.", preferredStyle: .actionSheet)

               // Add available options
                let sortedKeys = availableOptions.keys.sorted() // Sort for consistent order
               for type in sortedKeys {
                    let title = type.capitalized
                    alert.addAction(UIAlertAction(title: title, style: .default) { _ in
                         completion(type)
                    })
               }

                // Add cancel action - If cancelled, what should happen? Default to first available?
                alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in
                    // Default to the first available option if cancelled
                     completion(sortedKeys.first ?? "sub") // Fallback to 'sub' if even that fails
                })

                self.presentAlert(alert) // Use helper to present
          }
     }

     func presentServerSelection(servers: [[String: Any]], completion: @escaping (String) -> Void) {
          // Implementation from AnimeDetailsMethods.swift
           DispatchQueue.main.async {
                if servers.isEmpty {
                     self.showAlert(title: "Error", message: "No streaming servers available.")
                     // Handle failure - perhaps try another audio type or show error to user
                      completion("") // Indicate failure with empty string or handle error state
                     return
                }

                // If only one valid server, select it automatically
                 let validServers = servers.filter { ($0["serverName"] as? String) != "streamtape" && ($0["serverName"] as? String) != "streamsb" }
                 if validServers.count == 1, let serverName = validServers.first?["serverName"] as? String {
                      print("Only one valid server available: \(serverName)")
                      completion(serverName)
                      return
                 }


               let alert = UIAlertController(title: "Select Server", message: nil, preferredStyle: .actionSheet)

               for server in servers {
                    if let serverName = server["serverName"] as? String,
                       serverName.lowercased() != "streamtape", serverName.lowercased() != "streamsb" { // Filter out specific servers
                         alert.addAction(UIAlertAction(title: serverName, style: .default) { _ in
                              completion(serverName)
                         })
                    }
               }

                // Add cancel action
                alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in
                     // Handle cancellation - maybe default to the first valid server?
                      if let firstValidServerName = validServers.first?["serverName"] as? String {
                           completion(firstValidServerName)
                      } else {
                           completion("") // Indicate failure
                      }
                 })

                self.presentAlert(alert) // Use helper to present
           }
     }
    
    // ... (Include implementations for all other methods from AnimeDetailsMethods.swift) ...
    // func fetchHTMLContent(...) { ... }
    // func extractVideoSourceURL(...) { ... }
    // func extractURL(...) { ... }
    // func extractIframeSourceURL(...) { ... }
    // func extractAniBunker(...) { ... }
     func fetchHTMLContent(from url: String, completion: @escaping (Result<String, Error>) -> Void) {
          guard let url = URL(string: url) else {
               completion(.failure(NSError(domain: "Invalid URL", code: 0, userInfo: nil)))
               return
          }
          let session = proxySession.createAlamofireProxySession() // Use proxy session
           session.request(url).responseString { response in
                switch response.result {
                case .success(let htmlString):
                     completion(.success(htmlString))
                case .failure(let error):
                     completion(.failure(error))
                }
           }
     }

     func extractVideoSourceURL(from htmlString: String) -> URL? {
          do {
               let doc: Document = try SwiftSoup.parse(htmlString)
               // Try common selectors first
                if let videoElement = try doc.select("video").first(),
                    let sourceElement = try videoElement.select("source[src]").first(), // Look for src attribute
                    let sourceURLString = try sourceElement.attr("src").nilIfEmpty,
                    let sourceURL = URL(string: sourceURLString) {
                     return sourceURL
                }
                // Fallback for different structures if needed (e.g., direct src on video tag)
                 if let videoElement = try doc.select("video[src]").first(),
                    let sourceURLString = try videoElement.attr("src").nilIfEmpty,
                    let sourceURL = URL(string: sourceURLString) {
                     return sourceURL
                 }
               // Add more specific selectors based on source if necessary
               return nil // No common video source found
          } catch {
               print("Error parsing HTML with SwiftSoup for video source: \(error)")
               // Regex fallback (less reliable)
                let mp4Pattern = #"<source[^>]+src="([^"]+\.mp4[^"]*)"#
                let m3u8Pattern = #"<source[^>]+src="([^"]+\.m3u8[^"]*)"#

                if let mp4URL = extractURL(from: htmlString, pattern: mp4Pattern) { return mp4URL }
                if let m3u8URL = extractURL(from: htmlString, pattern: m3u8Pattern) { return m3u8URL }

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
           // Basic cleaning - remove potential HTML entities
           let cleanedUrlString = urlString.replacingOccurrences(of: "&amp;", with: "&")
          return URL(string: cleanedUrlString)
     }

     func extractIframeSourceURL(from htmlString: String) -> URL? {
          do {
               let doc: Document = try SwiftSoup.parse(htmlString)
               guard let iframeElement = try doc.select("iframe[src]").first(), // Ensure iframe has src
                     let sourceURLString = try iframeElement.attr("src").nilIfEmpty else {
                    print("No iframe with src found or src is empty.")
                    return nil
               }
                // Handle protocol-relative URLs (e.g., //example.com)
                let fullURLString: String
                if sourceURLString.starts(with: "//") {
                     fullURLString = "https:" + sourceURLString
                } else if !sourceURLString.starts(with: "http") {
                     // Handle potentially relative URLs if needed, requires base URL knowledge
                      print("Warning: Encountered potentially relative iframe src: \(sourceURLString)")
                      // For now, assume absolute or protocol-relative are most common
                      return nil
                } else {
                     fullURLString = sourceURLString
                }

               return URL(string: fullURLString)
          } catch {
               print("Error parsing HTML with SwiftSoup for iframe src: \(error)")
               return nil
          }
     }

     func extractAniBunker(from htmlString: String) -> URL? {
          do {
               let doc: Document = try SwiftSoup.parse(htmlString)
                guard let videoElement = try doc.select("div#videoContainer[data-video-id]").first(),
                       let videoID = try videoElement.attr("data-video-id").nilIfEmpty else {
                    print("AniBunker: data-video-id not found.")
                    return nil
               }

               let url = URL(string: "https://www.anibunker.com/php/loader.php")!
               var request = URLRequest(url: url)
               request.httpMethod = "POST"
               request.setValue("https://www.anibunker.com", forHTTPHeaderField: "Origin")
                request.setValue("https://www.anibunker.com", forHTTPHeaderField: "Referer") // Add Referer
               request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent") // Add User-Agent


               let bodyString = "player_id=url_hd&video_id=\(videoID)"
               request.httpBody = bodyString.data(using: .utf8)

               // --- Synchronous Request (Use with caution, preferably on background thread) ---
                let semaphore = DispatchSemaphore(value: 0)
                var resultURL: URL?
                var resultError: Error?

                 URLSession.shared.dataTask(with: request) { data, response, error in
                     defer { semaphore.signal() }
                      guard let data = data, error == nil else {
                           print("Error making POST request to AniBunker loader: \(error?.localizedDescription ?? "Unknown error")")
                           resultError = error ?? NSError(domain: "AniBunkerError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Network request failed"])
                           return
                      }

                      do {
                           if let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                              let success = json["success"] as? Bool, success,
                              let urlString = json["url"] as? String,
                              let url = URL(string: urlString) {
                               resultURL = url
                           } else {
                                print("Error parsing JSON response from AniBunker loader or success=false")
                                resultError = NSError(domain: "AniBunkerError", code: -2, userInfo: [NSLocalizedDescriptionKey: "Invalid JSON response"])
                           }
                      } catch {
                           print("Error parsing JSON response from AniBunker loader: \(error)")
                           resultError = error
                      }
                 }.resume()

                 _ = semaphore.wait(timeout: .now() + 15) // Wait for up to 15 seconds

                 if let error = resultError {
                      print("AniBunker extraction failed with error: \(error)")
                      return nil
                 }
                return resultURL
               // --- End Synchronous Request ---

          } catch {
               print("Error parsing HTML with SwiftSoup for AniBunker: \(error)")
               return nil
          }
     }

     func extractEmbedUrl(from rawHtml: String, completion: @escaping (URL?) -> Void) {
          // Find the <video-player> tag content
           guard let videoPlayerRange = rawHtml.range(of: "<video-player[^>]*>", options: .regularExpression) else {
                print("AnimeUnity: <video-player> tag not found.")
                completion(nil)
                return
           }
           // Search for embed_url within the tag attributes
            let searchRange = videoPlayerRange.lowerBound..<rawHtml.endIndex // Search from the start of the tag
            guard let embedUrlStart = rawHtml.range(of: "embed_url=\"", options: [], range: searchRange)?.upperBound,
                   let embedUrlEnd = rawHtml.range(of: "\"", options: [], range: embedUrlStart..<rawHtml.endIndex)?.lowerBound else {
                print("AnimeUnity: embed_url attribute not found.")
                completion(nil)
                return
            }

           var embedUrlString = String(rawHtml[embedUrlStart..<embedUrlEnd])
           embedUrlString = embedUrlString.replacingOccurrences(of: "&amp;", with: "&") // Clean HTML entities

           print("AnimeUnity: Found embed URL: \(embedUrlString)")
           extractWindowUrl(from: embedUrlString, completion: completion) // Proceed to extract from the embed page
      }


    private func extractWindowUrl(from urlString: String, completion: @escaping (URL?) -> Void) {
         guard let url = URL(string: urlString) else {
              completion(nil)
              return
         }

         var request = URLRequest(url: url)
         request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
         // Add Referer if necessary, often the main anime page URL
          if let originalHref = self.href { // Assuming self.href holds the original anime page URL
                request.setValue(originalHref, forHTTPHeaderField: "Referer")
          }


         URLSession.shared.dataTask(with: request) { data, response, error in
              guard let data = data,
                    let pageContent = String(data: data, encoding: .utf8) else {
                   print("AnimeUnity: Failed to fetch or decode content from \(urlString)")
                   DispatchQueue.main.async { completion(nil) }
                   return
              }

             // Look for downloadUrl, file, or similar patterns within script tags
              let patterns = [
                   #"window\.downloadUrl\s*=\s*['"]([^'"]+)['"]"#, // Original pattern
                   #"file:\s*['"]([^'"]+)['"]"#,                    // Common alternative
                   #"source:\s*\[{src:\s*['"]([^'"]+)['"]"#,          // Another structure
                   #"player\.loadSource\(\s*['"]([^'"]+)['"]"#       // Player loading source
              ]

              var foundUrlString: String? = nil

              for pattern in patterns {
                   if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
                        let range = NSRange(pageContent.startIndex..<pageContent.endIndex, in: pageContent)
                        if let match = regex.firstMatch(in: pageContent, options: [], range: range),
                           let urlRange = Range(match.range(at: 1), in: pageContent) {
                            foundUrlString = String(pageContent[urlRange])
                            break // Stop searching once a potential URL is found
                        }
                   }
              }


              guard let finalUrlString = foundUrlString else {
                   print("AnimeUnity: downloadUrl or similar pattern not found in \(urlString)")
                   DispatchQueue.main.async { completion(nil) }
                   return
              }


             let cleanedUrlString = finalUrlString.replacingOccurrences(of: "&amp;", with: "&")
                                                .replacingOccurrences(of: "\\/", with: "/") // Unescape slashes


             guard let downloadUrl = URL(string: cleanedUrlString) else {
                  print("AnimeUnity: Failed to create URL from extracted string: \(cleanedUrlString)")
                  DispatchQueue.main.async { completion(nil) }
                  return
             }

             print("AnimeUnity: Extracted final video URL: \(downloadUrl)")
             DispatchQueue.main.async { completion(downloadUrl) }

         }.resume()
     }


     func extractDataVideoSrcURL(from htmlString: String) -> URL? {
          do {
               let doc: Document = try SwiftSoup.parse(htmlString)
               // Try specific selectors first, e.g., within a known container
                if let videoContainer = try doc.select("#video_box, #playerContainer, .player-embed").first() { // Add more potential container selectors
                     if let sourceElement = try videoContainer.select("source[src]").first() ?? videoContainer.select("video[src]").first() {
                          if let src = try? sourceElement.attr("src").nilIfEmpty, let url = URL(string: src) {
                               return url
                          }
                     }
                     // Check for data-video-src attribute specifically
                      if let dataSrcElement = try videoContainer.select("[data-video-src]").first() {
                           if let src = try? dataSrcElement.attr("data-video-src").nilIfEmpty, let url = URL(string: src) {
                                return url
                           }
                      }
                }

               // Fallback to searching the whole document if not found in specific containers
               if let element = try doc.select("[data-video-src]").first(),
                  let sourceURLString = try element.attr("data-video-src").nilIfEmpty,
                  let sourceURL = URL(string: sourceURLString) {
                    print("Data-video-src URL: \(sourceURL.absoluteString)")
                    return sourceURL
               }

                print("Data-video-src attribute not found.")
               return nil
          } catch {
               print("Error parsing HTML with SwiftSoup for data-video-src: \(error)")
               return nil
          }
     }

     func extractDownloadLink(from htmlString: String) -> URL? {
         do {
             let doc: Document = try SwiftSoup.parse(htmlString)
             // Make selector more specific if possible, e.g., by parent container ID or class
              if let downloadElement = try doc.select("li.dowloads a[href], div.download-links a[href]").first() { // Example: Check multiple common parents/classes
                   let hrefString = try downloadElement.attr("href")
                   if let downloadURL = URL(string: hrefString) {
                        print("Download link URL: \(downloadURL.absoluteString)")
                        return downloadURL
                   }
              }
              print("Download link element not found.")
              return nil
         } catch {
             print("Error parsing HTML with SwiftSoup for download link: \(error)")
             return nil
         }
     }

    func extractTokyoVideo(from htmlString: String, completion: @escaping (URL?) -> Void) {
         let formats = UserDefaults.standard.bool(forKey: "otherFormats") ? ["mp4", "mkv", "avi"] : ["mp4"]

         DispatchQueue.global(qos: .userInitiated).async {
             do {
                 let doc = try SwiftSoup.parse(htmlString)
                  // Target links specifically within the 'episode' div or similar container
                  let episodeContainer = try doc.select("div.episode").first() ?? doc // Fallback to whole doc
                 let combinedSelector = formats.map { "a[href*=media.tokyoinsider.com][href$=.\($0)]" }.joined(separator: ", ")
                 let downloadElements = try episodeContainer.select(combinedSelector)

                 let foundURLs = downloadElements.compactMap { element -> (URL, String)? in
                     guard let hrefString = try? element.attr("href").nilIfEmpty,
                           let url = URL(string: hrefString) else { return nil }
                     let filename = url.lastPathComponent // Use filename as the display name
                     return (url, filename)
                 }

                 DispatchQueue.main.async {
                      guard !foundURLs.isEmpty else {
                           self.hideLoadingBannerAndShowAlert(title: "Error", message: "No valid video URLs found for selected formats.")
                           completion(nil) // Indicate failure
                           return
                      }

                     if foundURLs.count == 1 {
                           completion(foundURLs[0].0) // Directly complete if only one found
                           return
                     }

                     // --- Present quality selection ---
                     let alertController = UIAlertController(title: "Select Video Format", message: "Choose which video to play", preferredStyle: .actionSheet)

                     // Add actions for each found URL
                     for (url, filename) in foundURLs {
                          let action = UIAlertAction(title: filename, style: .default) { _ in
                               completion(url)
                          }
                          alertController.addAction(action)
                     }

                     // Cancel action
                     let cancelAction = UIAlertAction(title: "Cancel", style: .cancel) { _ in
                          self.hideLoadingBanner() // Hide banner if cancelled
                          completion(nil) // Indicate cancellation
                     }
                     alertController.addAction(cancelAction)

                     // Popover for iPad
                      if let popoverController = alertController.popoverPresentationController {
                           popoverController.sourceView = self.view
                           popoverController.sourceRect = CGRect(x: self.view.bounds.midX, y: self.view.bounds.midY, width: 0, height: 0)
                           popoverController.permittedArrowDirections = [] // No arrow for center presentation
                      }


                     self.hideLoadingBanner { // Hide loading before presenting options
                          self.present(alertController, animated: true)
                     }
                     // --- End quality selection ---
                 }
             } catch {
                 DispatchQueue.main.async {
                     print("Error parsing TokyoInsider HTML: \(error)")
                     self.hideLoadingBannerAndShowAlert(title: "Error", message: "Error extracting video URLs.")
                      completion(nil) // Indicate failure
                 }
             }
         }
     }

    func extractAsgoldURL(from documentString: String) -> URL? {
          // Look for player2 URL pattern specifically
           let pattern = "\"player2\":\"!(https?://video\\.asgold\\.pp\\.ua/video/[^\"]*)\"" // Capture group for the URL

          do {
               let regex = try NSRegularExpression(pattern: pattern, options: [])
               let range = NSRange(documentString.startIndex..<documentString.endIndex, in: documentString)

               if let match = regex.firstMatch(in: documentString, options: [], range: range),
                  let matchRange = Range(match.range(at: 1), in: documentString) { // Get the captured group
                    let urlString = String(documentString[matchRange])
                    // URL should be absolute already, remove potential escaping if needed
                     let cleanedURLString = urlString.replacingOccurrences(of: "\\/", with: "/")
                    return URL(string: cleanedURLString)
               }
          } catch {
               print("Error creating regex for Asgold URL: \(error)")
               return nil
          }
           print("Asgold player2 URL pattern not found.")
          return nil // Return nil if pattern not found
      }

     func extractAniVibeURL(from htmlContent: String) -> URL? {
          // Pattern to find the "url" key within a likely JSON structure embedded in script tags
           let pattern = #""url"\s*:\s*"([^"]+\.m3u8)""# // Capture the m3u8 URL

          guard let regex = try? NSRegularExpression(pattern: pattern) else {
               print("AniVibe: Failed to create regex.")
               return nil
          }

          let range = NSRange(htmlContent.startIndex..., in: htmlContent)
           // Find the first match
           guard let match = regex.firstMatch(in: htmlContent, range: range) else {
                print("AniVibe: m3u8 URL pattern not found in HTML content.")
                return nil
           }

          // Extract the captured group (the URL string)
           if let urlRange = Range(match.range(at: 1), in: htmlContent) {
               let extractedURLString = String(htmlContent[urlRange])
               // Unescape any potential forward slashes
                let unescapedURLString = extractedURLString.replacingOccurrences(of: "\\/", with: "/")
               print("AniVibe: Extracted m3u8 URL: \(unescapedURLString)")
               return URL(string: unescapedURLString)
           }

          return nil // Return nil if URL couldn't be extracted from the match
      }

     func extractStreamtapeQueryParameters(from htmlString: String, completion: @escaping (URL?) -> Void) {
          let streamtapePattern = #"https?://(?:www\.)?streamtape\.(?:com|to|net)/[ev]/[^\s"']+"# // More robust pattern
          guard let streamtapeRegex = try? NSRegularExpression(pattern: streamtapePattern, options: []),
                let streamtapeMatch = streamtapeRegex.firstMatch(in: htmlString, options: [], range: NSRange(location: 0, length: htmlString.utf16.count)),
                let streamtapeRange = Range(streamtapeMatch.range, in: htmlString) else {
               print("Streamtape embed/page URL not found in initial HTML.")
               completion(nil)
               return
          }

          let streamtapeURLString = String(htmlString[streamtapeRange])
          guard let streamtapeURL = URL(string: streamtapeURLString) else {
               print("Invalid Streamtape URL extracted: \(streamtapeURLString)")
               completion(nil)
               return
          }

           print("Found Streamtape page URL: \(streamtapeURL)")

           var request = URLRequest(url: streamtapeURL)
           request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
           // Add Referer if it helps bypass checks, using the original episode page URL if available
            if let originalHref = self.href {
                 request.setValue(originalHref, forHTTPHeaderField: "Referer")
            }


           URLSession.shared.dataTask(with: request) { data, response, error in
                guard let data = data, error == nil else {
                     print("Error fetching Streamtape page \(streamtapeURL): \(error?.localizedDescription ?? "Unknown error")")
                     DispatchQueue.main.async { completion(nil) }
                     return
                }

               guard let responseHTML = String(data: data, encoding: .utf8) else {
                    print("Could not decode Streamtape page content.")
                    DispatchQueue.main.async { completion(nil) }
                    return
               }

                // Pattern to find the get_video call with parameters within script tags
                 // This pattern looks for the specific structure often used by Streamtape
                  let queryPattern = #"document\.getElementById\('robotlink'\)\.innerHTML = '(?://streamtape\.com/get_video\?id=[^&]+&expires=\d+&ip=[^&]+&token=[^']+)'"#


                guard let queryRegex = try? NSRegularExpression(pattern: queryPattern, options: []) else {
                      print("Failed to create Streamtape query regex.")
                      DispatchQueue.main.async { completion(nil) }
                      return
                 }


                 let range = NSRange(location: 0, length: responseHTML.utf16.count)
                 if let queryMatch = queryRegex.firstMatch(in: responseHTML, options: [], range: range),
                    let queryRange = Range(queryMatch.range(at: 1), in: responseHTML) { // Capture group 1

                      var videoPart = String(responseHTML[queryRange])
                      // Ensure it starts with https:
                       if videoPart.starts(with: "//") {
                            videoPart = "https:" + videoPart
                       }

                       print("Found Streamtape get_video URL: \(videoPart)")
                       if let finalURL = URL(string: videoPart) {
                            DispatchQueue.main.async { completion(finalURL) }
                       } else {
                            print("Failed to create URL from Streamtape get_video string.")
                            DispatchQueue.main.async { completion(nil) }
                       }
                 } else {
                      print("Streamtape 'get_video' parameters not found in the page source.")
                      DispatchQueue.main.async { completion(nil) }
                 }
            }.resume()
      }

     func anime3rbGetter(from documentString: String, completion: @escaping (URL?) -> Void) {
           guard let videoPlayerURL = extractAnime3rbVideoURL(from: documentString) else {
                print("Anime3rb: Could not extract player URL.")
                completion(nil)
                return
           }
          print("Anime3rb: Found player URL: \(videoPlayerURL)")
          extractAnime3rbMP4VideoURL(from: videoPlayerURL.absoluteString, completion: completion)
      }

      func extractAnime3rbVideoURL(from documentString: String) -> URL? {
           // Pattern to find the video.vid3rb.com URL, allowing for different domains potentially
            let pattern = #"https?://(?:video|watch)\.(?:vid3rb|anime3rb)\.(?:com|pp\.ua)/player/[\w-]+(?:\?token=[\w]+(?:&amp;|&)expires=\d+)?"# // Made params optional


           do {
                let regex = try NSRegularExpression(pattern: pattern, options: [])
                let range = NSRange(documentString.startIndex..<documentString.endIndex, in: documentString)

                if let match = regex.firstMatch(in: documentString, options: [], range: range),
                   let matchRange = Range(match.range, in: documentString) {
                    var urlString = String(documentString[matchRange])
                     urlString = urlString.replacingOccurrences(of: "&amp;", with: "&") // Clean HTML entities
                    return URL(string: urlString)
                }
           } catch {
                print("Error creating regex for Anime3rb player URL: \(error)")
                return nil
           }
            print("Anime3rb player URL pattern not found.")
           return nil
       }

      func extractAnime3rbMP4VideoURL(from urlString: String, completion: @escaping (URL?) -> Void) {
           guard let url = URL(string: urlString) else {
                completion(nil)
                return
           }

           var request = URLRequest(url: url)
            request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
            // Add Referer if needed, likely the original episode page
            if let originalHref = self.href {
                 request.setValue(originalHref, forHTTPHeaderField: "Referer")
            }

           URLSession.shared.dataTask(with: request) { data, response, error in
                guard let data = data, error == nil,
                      let pageContent = String(data: data, encoding: .utf8) else {
                     print("Anime3rb: Failed to fetch or decode player page content from \(urlString). Error: \(error?.localizedDescription ?? "Unknown")")
                     DispatchQueue.main.async { completion(nil) }
                     return
                }

                // Look for source tags or script variables containing the mp4 URL
                 let mp4Pattern = #"src:\s*['"](https?://[^\s"']+\.mp4[^'"]*)['"]"# // Common pattern in player scripts

                guard let regex = try? NSRegularExpression(pattern: mp4Pattern, options: []) else {
                     print("Anime3rb: Failed to create MP4 regex.")
                     DispatchQueue.main.async { completion(nil) }
                     return
                }

                let range = NSRange(pageContent.startIndex..<pageContent.endIndex, in: pageContent)
                if let match = regex.firstMatch(in: pageContent, options: [], range: range),
                   let urlRange = Range(match.range(at: 1), in: pageContent) {
                    let mp4UrlString = String(pageContent[urlRange]).replacingOccurrences(of: "\\/", with: "/") // Unescape slashes
                     print("Anime3rb: Extracted MP4 URL: \(mp4UrlString)")
                     DispatchQueue.main.async { completion(URL(string: mp4UrlString)) }
                     return
                }

                // Fallback: Look for <source> tag if script pattern fails
                do {
                     let doc = try SwiftSoup.parse(pageContent)
                     if let sourceElement = try doc.select("video source[src*='.mp4']").first(),
                        let src = try? sourceElement.attr("src"),
                        let mp4Url = URL(string: src) {
                           print("Anime3rb: Extracted MP4 URL from source tag: \(mp4Url)")
                           DispatchQueue.main.async { completion(mp4Url) }
                           return
                     }
                } catch {
                      print("Anime3rb: SwiftSoup parsing failed for MP4 fallback: \(error)")
                }


                print("Anime3rb: MP4 URL not found in player page source.")
                DispatchQueue.main.async { completion(nil) }
           }.resume()
      }


     func extractVidozaVideoURL(from htmlString: String, completion: @escaping (URL?) -> Void) {
          // Pattern to find the sourcesCode structure and extract the src URL
           let scriptPattern = #"sourcesCode:\s*\[\{\s*src:\s*"([^"]+)"# // Capture the URL within src: "..."

          DispatchQueue.global(qos: .userInitiated).async { // Perform regex on background thread
               guard let scriptRegex = try? NSRegularExpression(pattern: scriptPattern) else {
                    print("Vidoza: Failed to create regex.")
                    DispatchQueue.main.async { completion(nil) }
                    return
               }

               let range = NSRange(htmlString.startIndex..., in: htmlString)
               guard let scriptMatch = scriptRegex.firstMatch(in: htmlString, range: range) else {
                    print("Vidoza: 'sourcesCode' pattern not found.")
                    DispatchQueue.main.async { completion(nil) }
                    return
               }

               // Extract the captured group (the URL string)
               if let urlRange = Range(scriptMatch.range(at: 1), in: htmlString) {
                    let videoURLString = String(htmlString[urlRange])
                     print("Vidoza: Extracted video URL: \(videoURLString)")
                     DispatchQueue.main.async { completion(URL(string: videoURLString)) }
               } else {
                    print("Vidoza: Could not extract URL from regex match.")
                    DispatchQueue.main.async { completion(nil) }
               }
          }
      }
     
      func extractVidmolyDirectURL(from htmlString: String, completion: @escaping (URL?) -> Void) {
          let scriptPattern = #"file:\s*"([^"]+\.m3u8)"# // Prioritize m3u8 if available
           let fallbackPattern = #"file:\s*"([^"]+\.mp4)"# // Fallback to mp4

          DispatchQueue.global(qos: .userInitiated).async {
              var foundUrlString: String? = nil

              // Try m3u8 pattern first
               if let regex = try? NSRegularExpression(pattern: scriptPattern) {
                    let range = NSRange(htmlString.startIndex..., in: htmlString)
                    if let match = regex.firstMatch(in: htmlString, range: range),
                       let urlRange = Range(match.range(at: 1), in: htmlString) {
                        foundUrlString = String(htmlString[urlRange])
                    }
               }

              // If m3u8 not found, try mp4 pattern
               if foundUrlString == nil, let regex = try? NSRegularExpression(pattern: fallbackPattern) {
                    let range = NSRange(htmlString.startIndex..., in: htmlString)
                    if let match = regex.firstMatch(in: htmlString, range: range),
                       let urlRange = Range(match.range(at: 1), in: htmlString) {
                        foundUrlString = String(htmlString[urlRange])
                    }
               }

              guard let finalUrlString = foundUrlString else {
                   print("Vidmoly: 'file:' pattern not found.")
                   DispatchQueue.main.async { completion(nil) }
                   return
              }

              print("Vidmoly: Extracted video URL: \(finalUrlString)")
              DispatchQueue.main.async { completion(URL(string: finalUrlString)) }
          }
      }


     // Add this property to hold available qualities temporarily
      var availableQualities: [String] = []

     func fetchVideoDataAndChooseQuality(from urlString: String, completion: @escaping (URL?) -> Void) {
          guard let url = URL(string: urlString) else {
               print("Invalid URL string for fetching video data: \(urlString)")
               completion(nil)
               return
          }

           let session = proxySession.createAlamofireProxySession() // Use proxy session if needed
           session.request(url).responseJSON { response in // Expecting JSON response
               switch response.result {
               case .success(let value):
                    guard let json = value as? [String: Any],
                          let videoDataArray = json["data"] as? [[String: Any]] else {
                         print("JSON structure is invalid or 'data' key is missing for URL: \(urlString)")
                         completion(nil)
                         return
                    }

                   self.availableQualities.removeAll() // Clear previous qualities
                   var qualityToUrlMap: [String: String] = [:]

                   for videoData in videoDataArray {
                        if let label = videoData["label"] as? String, let src = videoData["src"] as? String {
                             self.availableQualities.append(label)
                             qualityToUrlMap[label] = src
                        }
                   }

                    if self.availableQualities.isEmpty {
                         print("No available video qualities found for URL: \(urlString)")
                         completion(nil)
                         return
                    }

                   // Sort available qualities (e.g., numerically descending)
                    self.availableQualities.sort { q1, q2 in
                         let val1 = Int(q1.replacingOccurrences(of: "p", with: "")) ?? 0
                         let val2 = Int(q2.replacingOccurrences(of: "p", with: "")) ?? 0
                         return val1 > val2 // Higher quality first
                    }

                   // Choose quality based on preference
                    DispatchQueue.main.async {
                         self.choosePreferredQuality(availableQualities: self.availableQualities, videoDataMap: qualityToUrlMap, completion: completion)
                    }

               case .failure(let error):
                    print("Error fetching video data JSON from \(urlString): \(error)")
                    completion(nil)
               }
           }
      }


     func choosePreferredQuality(availableQualities: [String], videoDataMap: [String: String], completion: @escaping (URL?) -> Void) {
          let preferredQuality = UserDefaults.standard.string(forKey: "preferredQuality") ?? "1080p" // Default preference

          // Try to find the exact preferred quality
           if let urlString = videoDataMap[preferredQuality], let url = URL(string: urlString) {
                print("Preferred quality '\(preferredQuality)' found.")
                completion(url)
                return
           }

           // If not found, find the closest available quality (higher preferred)
            let preferredValue = Int(preferredQuality.replacingOccurrences(of: "p", with: "")) ?? 1080
            var bestMatchQuality: String? = nil
            var smallestDiff = Int.max

            let sortedAvailable = availableQualities.sorted { q1, q2 in // Sort descending numerically
                 (Int(q1.replacingOccurrences(of: "p", with: "")) ?? 0) > (Int(q2.replacingOccurrences(of: "p", with: "")) ?? 0)
            }

            for quality in sortedAvailable {
                 let qualityValue = Int(quality.replacingOccurrences(of: "p", with: "")) ?? 0
                 let diff = abs(preferredValue - qualityValue)

                 // Prefer higher or equal quality if close, otherwise closest lower
                  if qualityValue >= preferredValue {
                       if diff < smallestDiff {
                            smallestDiff = diff
                            bestMatchQuality = quality
                       }
                  } else { // Quality is lower than preferred
                       if bestMatchQuality == nil || diff < smallestDiff { // If no higher match found yet, or this is closer
                            smallestDiff = diff
                            bestMatchQuality = quality
                       }
                  }
            }
            
           // If still no match (shouldn't happen if availableQualities is not empty), fallback to highest available
            if bestMatchQuality == nil {
                 bestMatchQuality = sortedAvailable.first
            }


           if let finalQuality = bestMatchQuality, let urlString = videoDataMap[finalQuality], let url = URL(string: urlString) {
                print("Preferred quality '\(preferredQuality)' not found. Using closest available: '\(finalQuality)'")
                completion(url)
           } else {
                print("No suitable quality option found even after trying closest match.")
                completion(nil)
           }
      }

      func showQualityPicker(qualities: [String], videoDataMap: [String: String], completion: @escaping (URL?) -> Void) {
           DispatchQueue.main.async {
                let alertController = UIAlertController(title: "Choose Video Quality", message: nil, preferredStyle: .actionSheet)

                // Sort qualities for display (e.g., highest first)
                 let sortedQualities = qualities.sorted { q1, q2 in
                      (Int(q1.replacingOccurrences(of: "p", with: "")) ?? 0) > (Int(q2.replacingOccurrences(of: "p", with: "")) ?? 0)
                 }


                for quality in sortedQualities {
                     if let urlString = videoDataMap[quality], let url = URL(string: urlString) {
                          let action = UIAlertAction(title: quality, style: .default) { _ in
                               completion(url)
                          }
                          alertController.addAction(action)
                     }
                }

                let cancelAction = UIAlertAction(title: "Cancel", style: .cancel) { _ in completion(nil) }
                alertController.addAction(cancelAction)

               self.presentAlert(alertController) // Use helper
           }
      }


}
