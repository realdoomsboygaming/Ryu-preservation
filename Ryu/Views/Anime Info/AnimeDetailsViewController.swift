import UIKit
import AVKit
import SwiftSoup // Ensure SwiftSoup is imported
import GoogleCast
import SafariServices
import UniformTypeIdentifiers // For UIDocumentPicker

// Main view controller for displaying anime details and episode list
class AnimeDetailViewController: UITableViewController, GCKRemoteMediaClientListener, AVPlayerViewControllerDelegate, CustomPlayerViewDelegate {

    // MARK: - Properties
    var animeTitle: String?
    var imageUrl: String?
    var href: String?       // URL path or identifier for the anime
    var source: String?     // The source name (e.g., "AnimeWorld", "HiAnime")

    var episodes: [Episode] = []
    var synopsis: String = ""
    var aliases: String = ""
    var airdate: String = ""
    var stars: String = ""

    var player: AVPlayer?
    var playerViewController: AVPlayerViewController?

    var currentEpisodeIndex: Int = 0 // Tracks the currently playing/selected episode index
    var timeObserverToken: Any?

    var isFavorite: Bool = false
    var isSynopsisExpanded = false
    var isReverseSorted = false // Tracks user preference for episode sorting
    var hasSentUpdate = false   // Flag to prevent multiple AniList updates per episode play

    var availableQualities: [String] = [] // Used by some sources like AnimeFire
    // var qualityOptions: [(name: String, fileName: String)] = [] // Might be needed for specific source handling

    // Multi-select properties
    private var isSelectMode = false
    private var selectedEpisodes = Set<Episode>()
    private var downloadButton: UIBarButtonItem!
    private var selectButton: UIBarButtonItem!
    private var cancelButton: UIBarButtonItem!
    private var selectAllButton: UIBarButtonItem!
    private var filterButton: UIBarButtonItem! // Moved filter button here

    // Service instance for HiAnime/Aniwatch
    private let aniwatchService = Aniwatch()

    // MARK: - Lifecycle Methods

    // Configures the view controller with initial data before loading
    func configure(title: String, imageUrl: String, href: String, source: String) {
        self.animeTitle = title
        self.href = href
        self.source = source // Store the source name

        // Handle placeholder/default images specifically for sources known to lack them initially
        // AniWorld and TokyoInsider images are often just placeholders on the search/list page
        if imageUrl.contains("large/default.jpg") && (source == "AniWorld" || source == "TokyoInsider") {
             self.imageUrl = imageUrl // Keep placeholder temporarily
             fetchImageUrl(source: source, href: href, fallback: imageUrl) // Attempt to fetch real image later
        } else {
            self.imageUrl = imageUrl // Use provided image URL directly
        }
    }

     // Fetches the actual cover image if the initial one was a placeholder
     private func fetchImageUrl(source: String, href: String, fallback: String) {
         guard let url = URL(string: href.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? href) else {
             self.imageUrl = fallback
             DispatchQueue.main.async { self.tableView.reloadSections(IndexSet(integer: 0), with: .none) } // Reload header section
             return
         }

         let task = URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
             guard let self = self,
                   let data = data,
                   let html = String(data: data, encoding: .utf8) else {
                 DispatchQueue.main.async {
                     self.imageUrl = fallback
                     self.tableView.reloadSections(IndexSet(integer: 0), with: .none)
                 }
                 return
             }

             do {
                 let doc = try SwiftSoup.parse(html)
                 var extractedImageUrl: String? = nil
                 // Source-specific image extraction logic
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
                 default: // Add other sources if needed
                     break
                 }
                 // Update UI on the main thread
                 DispatchQueue.main.async {
                    self.imageUrl = extractedImageUrl ?? fallback
                    self.tableView.reloadSections(IndexSet(integer: 0), with: .none) // Reload header
                 }
             } catch {
                 print("Error extracting image URL for \(source): \(error)")
                 DispatchQueue.main.async {
                     self.imageUrl = fallback
                     self.tableView.reloadSections(IndexSet(integer: 0), with: .none)
                 }
             }
         }
         task.resume()
     }


    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Ensure the selected source is updated if changed elsewhere
        if let currentSource = UserDefaults.standard.selectedMediaSource?.rawValue {
            self.source = currentSource
        }
        sortEpisodes() // Re-apply sorting based on user preference
        checkFavoriteStatus() // Update favorite status in case it changed
        tableView.reloadData() // Refresh table view data
        navigationController?.navigationBar.prefersLargeTitles = false // Keep small title
        reloadVisibleEpisodeProgress() // Update progress for potentially visible cells
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        setupNotifications()
        checkFavoriteStatus() // Initial check
        setupAudioSession()
        setupCastButton()
        setupMultiSelectUI() // Setup buttons for multi-select

        isReverseSorted = UserDefaults.standard.bool(forKey: "isEpisodeReverseSorted")
        fetchDetailsAndEpisodes() // Fetch data when view loads
        setupRefreshControl()
    }

     override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        reloadVisibleEpisodeProgress() // Refresh progress when view becomes fully visible
     }

     // Reloads progress specifically for visible episode cells
     private func reloadVisibleEpisodeProgress() {
         tableView.indexPathsForVisibleRows?.forEach { indexPath in
             if indexPath.section == 2, // Only for the episodes section
                let cell = tableView.cellForRow(at: indexPath) as? EpisodeCell,
                let episode = episodes[safe: indexPath.row] { // Use safe subscripting
                cell.loadSavedProgress(for: episode.href)
             }
         }
     }

    deinit {
        // Clean up observers and timers
        NotificationCenter.default.removeObserver(self)
        if let token = timeObserverToken {
            player?.removeTimeObserver(token)
            timeObserverToken = nil
        }
        // Remove Chromecast listener if added
        if let castSession = GCKCastContext.sharedInstance().sessionManager.currentCastSession,
           let remoteMediaClient = castSession.remoteMediaClient {
            remoteMediaClient.remove(self)
        }
    }

    // MARK: - Setup Methods

    private func setupUI() {
        title = "Details" // Set a default title, might be overridden later
        tableView.backgroundColor = .systemBackground
        tableView.register(AnimeHeaderCell.self, forCellReuseIdentifier: "AnimeHeaderCell")
        tableView.register(SynopsisCell.self, forCellReuseIdentifier: "SynopsisCell")
        tableView.register(EpisodeCell.self, forCellReuseIdentifier: "EpisodeCell")
        tableView.separatorStyle = .none
        tableView.allowsSelection = true
        tableView.allowsMultipleSelection = false // Enable only in edit mode
    }

    private func setupNotifications() {
        // Observe interruptions (like calls)
        NotificationCenter.default.addObserver(self, selector: #selector(handleInterruption), name: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance())
        // Observe changes to UserDefaults (like sort order preference)
        NotificationCenter.default.addObserver(self, selector: #selector(userDefaultsChanged), name: UserDefaults.didChangeNotification, object: nil)
        // Observe changes to the favorites list
        NotificationCenter.default.addObserver(self, selector: #selector(favoritesChanged), name: FavoritesManager.favoritesChangedNotification, object: nil)
    }

    private func setupRefreshControl() {
        refreshControl = UIRefreshControl()
        refreshControl?.addTarget(self, action: #selector(handleRefresh), for: .valueChanged)
        tableView.refreshControl = refreshControl
    }

    private func setupCastButton() {
        let castButton = GCKUICastButton(frame: CGRect(x: 0, y: 0, width: 24, height: 24))
        castButton.tintColor = .systemTeal // Match other button colors
        let optionsMenuItem = UIBarButtonItem(image: UIImage(systemName: "ellipsis.circle"), style: .plain, target: self, action: #selector(optionsMenuButtonTapped))
        optionsMenuItem.tintColor = .systemTeal
        // Order: Options, Cast
        navigationItem.rightBarButtonItems = [optionsMenuItem, UIBarButtonItem(customView: castButton)]
    }

    private func setupAudioSession() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            // Configure for playback, allowing mixing and background audio
            try audioSession.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers, .allowAirPlay])
            try audioSession.setActive(true)
            // Ensure output goes to speaker initially if desired (might be overridden by AirPlay/Cast)
            // try audioSession.overrideOutputAudioPort(.speaker) // Use cautiously, might interfere with routing
        } catch {
            print("Failed to set up AVAudioSession: \(error)")
        }
    }

    // MARK: - Multi-Select UI Setup & Handling
    func setupMultiSelectUI() {
        selectButton = UIBarButtonItem(title: "Select", style: .plain, target: self, action: #selector(toggleSelectMode))
        selectButton.tintColor = .systemTeal
        downloadButton = UIBarButtonItem(title: "Download", style: .plain, target: self, action: #selector(downloadSelectedEpisodes))
        downloadButton.tintColor = .systemTeal
        downloadButton.isEnabled = false // Disabled initially
        cancelButton = UIBarButtonItem(title: "Cancel", style: .plain, target: self, action: #selector(toggleSelectMode))
        cancelButton.tintColor = .systemTeal
        selectAllButton = UIBarButtonItem(title: "Select All", style: .plain, target: self, action: #selector(selectAllEpisodes))
        selectAllButton.tintColor = .systemTeal
        filterButton = UIBarButtonItem(image: UIImage(systemName: "line.3.horizontal.decrease.circle"), style: .plain, target: self, action: #selector(showFilterOptions)) // Use circle variant
        filterButton.tintColor = .systemTeal

        // Keep the original right bar button items (Cast, Options) initially
        // setupCastButton() already sets this.
    }

    @objc private func toggleSelectMode() {
        isSelectMode.toggle()
        selectedEpisodes.removeAll() // Clear selection when toggling mode
        tableView.allowsMultipleSelection = isSelectMode // Allow/disallow table view multiple selection

        if isSelectMode {
            // Configure Bar Buttons for Selection Mode
            navigationItem.title = "Select Episodes" // Change title
            navigationItem.leftBarButtonItem = cancelButton // Show Cancel on the left
            navigationItem.rightBarButtonItems = [downloadButton, filterButton, selectAllButton] // Show Download, Filter, Select All
            downloadButton.isEnabled = false // Start with download disabled
            navigationController?.setToolbarHidden(true, animated: true) // Hide tab bar if needed
        } else {
            // Configure Bar Buttons for Normal Mode
            navigationItem.title = "Details" // Restore original title
            navigationItem.leftBarButtonItem = nil // Remove Cancel button
            setupCastButton() // Restore original right buttons (Cast, Options)
            navigationController?.setToolbarHidden(false, animated: true) // Show tab bar again
        }

        // Reload episode cells to show/hide selection indicators
        tableView.reloadSections(IndexSet(integer: 2), with: .automatic)
    }

    @objc private func showFilterOptions() {
        let alertController = UIAlertController(title: "Filter/Select Episodes", message: nil, preferredStyle: .actionSheet)

        alertController.addAction(UIAlertAction(title: "Select Unwatched", style: .default) { [weak self] _ in self?.selectUnwatchedEpisodes() })
        alertController.addAction(UIAlertAction(title: "Select Watched", style: .default) { [weak self] _ in self?.selectWatchedEpisodes() })
        alertController.addAction(UIAlertAction(title: "Select Range...", style: .default) { [weak self] _ in self?.showRangeSelectionDialog() })
        alertController.addAction(UIAlertAction(title: "Deselect All", style: .default) { [weak self] _ in self?.deselectAllEpisodes() })
        alertController.addAction(UIAlertAction(title: "Cancel", style: .cancel))

        // Configure for iPad
        if let popoverController = alertController.popoverPresentationController {
            popoverController.barButtonItem = filterButton // Anchor to the filter button
        }

        present(alertController, animated: true)
    }

    private func selectUnwatchedEpisodes() {
        selectedEpisodes.removeAll()
        for episode in episodes {
            let fullURL = episode.href
            let lastPlayedTime = UserDefaults.standard.double(forKey: "lastPlayedTime_\(fullURL)")
            let totalTime = UserDefaults.standard.double(forKey: "totalTime_\(fullURL)")
            if totalTime <= 0 || (lastPlayedTime / totalTime) < 0.90 { // Consider < 90% watched as unwatched
                selectedEpisodes.insert(episode)
            }
        }
        downloadButton.isEnabled = !selectedEpisodes.isEmpty
        tableView.reloadSections(IndexSet(integer: 2), with: .automatic)
    }

    private func selectWatchedEpisodes() {
        selectedEpisodes.removeAll()
        for episode in episodes {
            let fullURL = episode.href
            let lastPlayedTime = UserDefaults.standard.double(forKey: "lastPlayedTime_\(fullURL)")
            let totalTime = UserDefaults.standard.double(forKey: "totalTime_\(fullURL)")
            if totalTime > 0 && (lastPlayedTime / totalTime) >= 0.90 { // Consider >= 90% watched
                selectedEpisodes.insert(episode)
            }
        }
        downloadButton.isEnabled = !selectedEpisodes.isEmpty
        tableView.reloadSections(IndexSet(integer: 2), with: .automatic)
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
                  let startText = alertController?.textFields?[0].text, !startText.isEmpty,
                  let endText = alertController?.textFields?[1].text, !endText.isEmpty,
                  let start = Int(startText), let end = Int(endText) else {
                self.showAlert(title: "Invalid Input", message: "Please enter valid start and end episode numbers.")
                return
            }
            self.selectEpisodesInRange(start: start, end: end)
        }
        alertController.addAction(selectAction)
        alertController.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alertController, animated: true)
    }

    private func selectEpisodesInRange(start: Int, end: Int) {
        let validStart = min(start, end)
        let validEnd = max(start, end)

        // Option: Add to current selection or replace? Currently replaces.
        selectedEpisodes.removeAll() // Clear previous selection before selecting range

        for episode in episodes {
            let episodeNum = EpisodeNumberExtractor.extract(from: episode.number)
            if episodeNum >= validStart && episodeNum <= validEnd {
                selectedEpisodes.insert(episode)
            }
        }
        downloadButton.isEnabled = !selectedEpisodes.isEmpty
        tableView.reloadSections(IndexSet(integer: 2), with: .automatic)
    }

    private func deselectAllEpisodes() {
        selectedEpisodes.removeAll()
        downloadButton.isEnabled = false
        tableView.reloadSections(IndexSet(integer: 2), with: .automatic)
    }

    @objc private func selectAllEpisodes() {
        selectedEpisodes = Set(episodes) // Select all currently loaded episodes
        downloadButton.isEnabled = !selectedEpisodes.isEmpty
        tableView.reloadSections(IndexSet(integer: 2), with: .automatic)
    }

    @objc private func downloadSelectedEpisodes() {
        guard !selectedEpisodes.isEmpty else { return }

        showAlert(
            title: "Download \(selectedEpisodes.count) Episodes?",
            message: "This will queue all selected episodes for download.",
            actions: [
                UIAlertAction(title: "Cancel", style: .cancel),
                UIAlertAction(title: "Download", style: .default) { [weak self] _ in
                    self?.startBatchDownload()
                }
            ]
        )
    }

    private func startBatchDownload() {
        let episodesToDownload = Array(selectedEpisodes).sorted {
             EpisodeNumberExtractor.extract(from: $0.number) < EpisodeNumberExtractor.extract(from: $1.number)
        }

        // Show initial confirmation that downloads are starting
        if !episodesToDownload.isEmpty {
            showAlert(title: "Downloads Queued", message: "\(episodesToDownload.count) episodes added to the download queue.")
        }

        // Process downloads one by one (or adapt DownloadManager for batching)
        processNextDownload(episodes: episodesToDownload)

        // Exit select mode after queuing
        toggleSelectMode()
    }

     // Processes downloads sequentially (can be slow for many episodes)
     // Consider enhancing DownloadManager to handle a batch queue if needed.
     private func processNextDownload(episodes: [Episode], index: Int = 0) {
         guard index < episodes.count else {
             print("Finished queuing all selected downloads.")
             return
         }

         let episode = episodes[index]
         print("Queuing download for Episode \(episode.number)")

         // Set flag and find dummy cell (or adapt DownloadManager)
         UserDefaults.standard.set(true, forKey: "isToDownload")
         let dummyCell = EpisodeCell() // Using dummy cell for context
         dummyCell.episodeNumber = episode.number

         // Call episodeSelected to trigger the download logic
         // episodeSelected will eventually call handleDownload
         episodeSelected(episode: episode, cell: dummyCell)

         // Add a small delay before processing the next to avoid overwhelming requests
         // Adjust delay as needed, or ideally, improve DownloadManager queueing
         DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
             self?.processNextDownload(episodes: episodes, index: index + 1)
         }
     }

    // MARK: - Data Fetching and Handling (Continued)

    // Fetches details from AniList API and presents the dedicated AniList info view
    private func fetchAndNavigateToAnime(title: String) {
        showLoadingBanner(title: "Fetching AniList ID...")
        // Prioritize custom ID if set by the user
        if let customIDString = UserDefaults.standard.string(forKey: "customAniListID_\(self.animeTitle ?? "")"),
           let animeID = Int(customIDString) {
            hideLoadingBanner { [weak self] in
                self?.navigateToAnimeDetail(for: animeID)
            }
            return
        }

        // Fetch ID from AniList API by title
        AnimeService.fetchAnimeID(byTitle: title) { [weak self] result in
            self?.hideLoadingBanner {
                switch result {
                case .success(let id):
                    self?.navigateToAnimeDetail(for: id)
                case .failure(let error):
                    print("Error fetching anime ID: \(error.localizedDescription)")
                    self?.showAlert(title: "Error", message: "Unable to find the anime ID from AniList.")
                }
            }
        }
    }

    // Navigates to the AnimeInformation view controller
    private func navigateToAnimeDetail(for animeID: Int) {
        DispatchQueue.main.async {
            let storyboard = UIStoryboard(name: "AnilistAnimeInformation", bundle: nil) // Ensure storyboard name is correct
            if let animeDetailVC = storyboard.instantiateViewController(withIdentifier: "AnimeInformation") as? AnimeInformation {
                animeDetailVC.animeID = animeID
                self.navigationController?.pushViewController(animeDetailVC, animated: true)
            } else {
                print("Error: Could not instantiate AnimeInformation view controller.")
                self.showAlert(title: "Error", message: "Could not open AniList details.")
            }
        }
    }

    // MARK: - Actions (Continued)

    @objc private func optionsMenuButtonTapped() {
        // This selector is now triggered by the UIBarButtonItem directly
        // Call showOptionsMenu, anchoring it to the button
        showOptionsMenu(sourceItem: navigationItem.rightBarButtonItems?.first ?? UIBarButtonItem()) // Adjust index if needed
    }

    // Fetches mappings from AniZip and shows tracking service options
    private func fetchAnimeIDAndMappings() {
        guard let title = self.animeTitle else {
            showAlert(title: "Error", message: "Anime title is not available.")
            return
        }
        showLoadingBanner(title: "Fetching Tracking Info...")
        let cleanedTitle = cleanTitle(title)

        // Use custom ID if available
        if let customIDString = UserDefaults.standard.string(forKey: "customAniListID_\(title)"),
           let animeID = Int(customIDString) {
            fetchMappingsAndShowOptions(animeID: animeID)
            return
        }

        // Otherwise, fetch by title
        AnimeService.fetchAnimeID(byTitle: cleanedTitle) { [weak self] result in
            self?.hideLoadingBanner {
                switch result {
                case .success(let id):
                    self?.fetchMappingsAndShowOptions(animeID: id)
                case .failure(let error):
                    print("Error fetching anime ID: \(error.localizedDescription)")
                    self?.showAlert(title: "Error", message: "Unable to find the anime ID from AniList.")
                }
            }
        }
    }

    // Fetches mappings using AniZip API
    private func fetchMappingsAndShowOptions(animeID: Int) {
        let urlString = "https://api.ani.zip/mappings?anilist_id=\(animeID)"
        guard let url = URL(string: urlString) else {
             hideLoadingBannerAndShowAlert(title: "Error", message: "Invalid Mapping URL")
             return
        }

        let task = URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            guard let self = self else { return }
            self.hideLoadingBanner { // Hide banner once response is received
                 if let error = error {
                     print("Error fetching mappings: \(error)")
                     self.showAlert(title: "Error", message: "Unable to fetch tracking service mappings.")
                     return
                 }
                 guard let data = data else {
                     self.showAlert(title: "Error", message: "No data received for mappings.")
                     return
                 }
                 do {
                     if let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                        let mappings = json["mappings"] as? [String: Any] {
                         DispatchQueue.main.async {
                             self.showTrackingOptions(mappings: mappings)
                         }
                     } else {
                          self.showAlert(title: "Error", message: "Could not parse tracking service mappings.")
                     }
                 } catch {
                     print("Error parsing mapping JSON: \(error)")
                     self.showAlert(title: "Error", message: "Failed to process tracking service data.")
                 }
            }
        }
        task.resume()
    }

    // Presents Action Sheet with links to tracking services
    private func showTrackingOptions(mappings: [String: Any]) {
        let alertController = UIAlertController(title: "Tracking Services", message: "Open this anime on:", preferredStyle: .actionSheet)
        let blacklist: Set<String> = ["type", "anilist_id", "themoviedb_id", "thetvdb_id"]

        let filteredMappings = mappings.filter { !blacklist.contains($0.key) }
        let sortedMappings = filteredMappings.sorted { $0.key < $1.key } // Sort alphabetically

        if sortedMappings.isEmpty {
             alertController.message = "No other tracking services found."
        } else {
            for (key, value) in sortedMappings {
                 let formattedServiceName = key.replacingOccurrences(of: "_id", with: "").capitalized
                 let idString: String
                 if let idInt = value as? Int {
                     idString = String(idInt)
                 } else if let idStr = value as? String {
                     idString = idStr
                 } else {
                     continue // Skip if ID is not String or Int
                 }
                 let action = UIAlertAction(title: formattedServiceName, style: .default) { [weak self] _ in
                     self?.openTrackingServiceURL(for: key, id: idString)
                 }
                 alertController.addAction(action)
             }
        }

        alertController.addAction(UIAlertAction(title: "Cancel", style: .cancel))

        // Popover setup for iPad
        if let popoverController = alertController.popoverPresentationController {
            popoverController.barButtonItem = navigationItem.rightBarButtonItems?.last // Anchor to the options button
        }
        present(alertController, animated: true)
    }

    // Opens the URL for the selected tracking service
    private func openTrackingServiceURL(for service: String, id: String) {
        var prefix = ""
        // Define URL prefixes for known services
        switch service {
        case "animeplanet_id": prefix = "https://animeplanet.com/anime/"
        case "kitsu_id": prefix = "https://kitsu.io/anime/" // Corrected Kitsu URL
        case "mal_id": prefix = "https://myanimelist.net/anime/"
        case "anisearch_id": prefix = "https://anisearch.com/anime/"
        case "anidb_id": prefix = "https://anidb.net/anime/"
        case "notifymoe_id": prefix = "https://notify.moe/anime/"
        case "livechart_id": prefix = "https://livechart.me/anime/"
        case "imdb_id": prefix = "https://www.imdb.com/title/"
        default:
            print("Unknown service key: \(service)")
            showAlert(title: "Error", message: "Cannot open link for unknown service.")
            return
        }

        let urlString = "\(prefix)\(id)"
        if let url = URL(string: urlString) {
            let safariVC = SFSafariViewController(url: url)
            DispatchQueue.main.async {
                self.present(safariVC, animated: true)
            }
        } else {
             showAlert(title: "Error", message: "Could not construct URL for \(service).")
        }
    }


    // Shows the advanced settings menu (currently only Custom AniList ID)
    private func showAdvancedSettingsMenu() {
        let alertController = UIAlertController(title: "Advanced Settings", message: nil, preferredStyle: .actionSheet)

        let customAniListIDAction = UIAction(title: "Custom AniList ID", image: UIImage(systemName: "pencil")) { [weak self] _ in
            self?.customAniListID()
        }
        alertController.addAction(customAniListIDAction)
        alertController.addAction(UIAlertAction(title: "Cancel", style: .cancel))

        // Popover setup for iPad
        if let popoverController = alertController.popoverPresentationController {
            popoverController.barButtonItem = navigationItem.rightBarButtonItems?.last // Anchor to options button
        }
        present(alertController, animated: true)
    }

    // Presents an alert to set/revert a custom AniList ID
    private func customAniListID() {
        let alert = UIAlertController(title: "Custom AniList ID", message: "Enter a custom AniList ID if the automatic detection is wrong:", preferredStyle: .alert)

        alert.addTextField { [weak self] textField in
            textField.placeholder = "Enter AniList ID (number)"
            textField.keyboardType = .numberPad // Ensure numeric input
            if let animeTitle = self?.animeTitle {
                textField.text = UserDefaults.standard.string(forKey: "customAniListID_\(animeTitle)")
            }
        }

        let saveAction = UIAlertAction(title: "Save", style: .default) { [weak self, weak alert] _ in
             guard let self = self,
                   let animeTitle = self.animeTitle,
                   let textField = alert?.textFields?.first,
                   let customIDText = textField.text,
                   !customIDText.isEmpty,
                   let _ = Int(customIDText) // Validate if it's an integer
             else {
                 self?.showAlert(title: "Invalid ID", message: "Please enter a valid numeric AniList ID.")
                 return
             }
             UserDefaults.standard.setValue(customIDText, forKey: "customAniListID_\(animeTitle)")
             self.showAlert(title: "Saved", message: "Custom AniList ID saved.")
              // Re-fetch notifications if favorited and enabled
             if self.isFavorite && UserDefaults.standard.bool(forKey: "notificationEpisodes") {
                 self.fetchAniListIDForNotifications()
             }
        }

        let revertAction = UIAlertAction(title: "Clear Custom ID", style: .destructive) { [weak self] _ in
            if let animeTitle = self?.animeTitle {
                UserDefaults.standard.removeObject(forKey: "customAniListID_\(animeTitle)")
                 // Also cancel existing notifications based on the potentially wrong ID
                 self?.cancelNotificationsForAnime()
                self?.showAlert(title: "Cleared", message: "Custom AniList ID cleared.")
            }
        }

        alert.addAction(saveAction)
        alert.addAction(revertAction)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))

        present(alert, animated: true)
    }

    // Opens the anime detail page on the source website
    private func openAnimeOnWeb() {
        guard let path = href else {
            showAlert(title: "Error", message: "Anime URL path is missing.")
            return
        }

        // Get base URL based on the *current* source being viewed
        let currentSourceString = self.source ?? UserDefaults.standard.string(forKey: "selectedMediaSource") ?? ""
        guard let currentSource = MediaSource(rawValue: currentSourceString) else {
            showAlert(title: "Error", message: "Invalid source selected.")
            return
        }

        let baseUrl = getBaseURL(for: currentSource, originalHref: path) // Use helper to get base URL
        let fullUrlString = path.starts(with: "http") ? path : baseUrl + path // Construct full URL

        guard let url = URL(string: fullUrlString) else {
            showAlert(title: "Error", message: "The URL '\(fullUrlString)' is invalid.")
            return
        }

        let safariViewController = SFSafariViewController(url: url)
        present(safariViewController, animated: true)
    }

    // MARK: - Alert & Loading Banner Helpers

    func showLoadingBanner(title: String = "Loading...") {
         DispatchQueue.main.async {
             // Avoid showing multiple banners
             guard self.presentedViewController as? UIAlertController == nil || self.presentedViewController?.message != title else { return }

             // Dismiss any existing alert first
             if let existingAlert = self.presentedViewController as? UIAlertController {
                 existingAlert.dismiss(animated: false)
             }

             let alert = UIAlertController(title: nil, message: title, preferredStyle: .alert)
             // Make background slightly transparent
             alert.view.backgroundColor = UIColor.black.withAlphaComponent(0.1)
             alert.view.alpha = 0.7
             alert.view.layer.cornerRadius = 15

             let loadingIndicator = UIActivityIndicatorView(style: .medium) // Use medium style
             loadingIndicator.translatesAutoresizingMaskIntoConstraints = false
             loadingIndicator.startAnimating()

             alert.view.addSubview(loadingIndicator)
             NSLayoutConstraint.activate([
                  // Center indicator horizontally
                  loadingIndicator.centerXAnchor.constraint(equalTo: alert.view.centerXAnchor),
                  // Position indicator vertically (adjust constant as needed)
                  loadingIndicator.centerYAnchor.constraint(equalTo: alert.view.centerYAnchor, constant: -10) // Slightly above center due to message padding
             ])
             // Set message constraints if needed, though default might be okay
             // Ensure message label exists and adjust constraints if default layout isn't centered

             self.present(alert, animated: true, completion: nil)
         }
     }

    func hideLoadingBanner(completion: (() -> Void)? = nil) {
        DispatchQueue.main.async {
            // Check if the presented VC is our loading alert
             if let alert = self.presentedViewController as? UIAlertController, alert.message?.contains("Loading") ?? false || alert.message?.contains("Extracting") ?? false {
                 alert.dismiss(animated: true, completion: completion)
            } else {
                completion?() // Call completion even if no alert was found
            }
        }
    }

    func hideLoadingBannerAndShowAlert(title: String, message: String) {
        hideLoadingBanner { [weak self] in
            self?.showAlert(title: title, message: message)
        }
    }

    func showAlert(title: String, message: String) {
         DispatchQueue.main.async {
            // Dismiss loading banner first if it's showing
             self.hideLoadingBanner {
                 let alertController = UIAlertController(title: title, message: message, preferredStyle: .alert)
                 alertController.addAction(UIAlertAction(title: "OK", style: .default))
                 self.present(alertController, animated: true)
             }
         }
     }

    // MARK: - Other Helper Methods

    func cleanTitle(_ title: String) -> String {
        // Remove common suffixes like (Dub), (ITA), etc.
        let unwantedStrings = ["(ITA)", "(Dub)", "(Dub ID)", "(Dublado)", "(Sub)", "(RAW)"] // Added Sub/Raw
        var cleanedTitle = title

        for unwanted in unwantedStrings {
             // Use case-insensitive comparison and remove surrounding whitespace
             if let range = cleanedTitle.range(of: unwanted, options: .caseInsensitive) {
                 cleanedTitle.removeSubrange(range)
             }
        }

        // Remove extra whitespace and quotes
        cleanedTitle = cleanedTitle.replacingOccurrences(of: "\"", with: "")
        cleanedTitle = cleanedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleanedTitle
    }

     func fetchAnimeID(title: String, completion: @escaping (Int) -> Void) {
        // Prioritize custom ID
        if let animeTitle = self.animeTitle, // Use the original title for the key
           let customIDString = UserDefaults.standard.string(forKey: "customAniListID_\(animeTitle)"),
           let id = Int(customIDString) {
            print("Using custom AniList ID: \(id) for title: \(animeTitle)")
            completion(id)
            return
        }

        // Fallback to API lookup with the cleaned title
        let cleanedTitle = cleanTitle(title) // Clean the title for lookup
        print("Fetching AniList ID for cleaned title: \(cleanedTitle)")
        AnimeService.fetchAnimeID(byTitle: cleanedTitle) { result in
            switch result {
            case .success(let id):
                print("Fetched AniList ID: \(id) for title: \(cleanedTitle)")
                completion(id)
            case .failure(let error):
                // Don't show alert here, handle failure where the ID is needed
                print("Error fetching anime ID for '\(cleanedTitle)': \(error.localizedDescription)")
                // Consider calling completion with a sentinel value like 0 or -1 if needed
                // completion(0) // Example: Indicate failure
            }
        }
    }

    // Encodes URL string safely
    func encodedURL(from urlString: String) -> URL? {
        // First, try creating URL directly (handles already encoded parts)
        if let url = URL(string: urlString) {
            return url
        }
        // If direct creation fails, try encoding allowed characters
        let allowedCharacters = CharacterSet.urlQueryAllowed.union(.urlPathAllowed)
        if let encodedString = urlString.addingPercentEncoding(withAllowedCharacters: allowedCharacters) {
            return URL(string: encodedString)
        }
        return nil // Return nil if both fail
    }

    // MARK: - Audio Session Handling
    @objc private func handleInterruption(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
                  return
              }

        switch type {
        case .began:
            player?.pause() // Pause player on interruption
            print("Audio interruption began.")
        case .ended:
            // Attempt to resume playback if appropriate
            if let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                if options.contains(.shouldResume) {
                    print("Audio interruption ended. Resuming playback.")
                    player?.play()
                     // Re-activate audio session if necessary
                     do {
                        try AVAudioSession.sharedInstance().setActive(true)
                     } catch {
                         print("Failed to re-activate AVAudioSession after interruption: \(error)")
                     }
                } else {
                     print("Audio interruption ended. Not resuming automatically.")
                }
            }
        default:
            break
        }
    }


    // MARK: - Parsing Helpers (Moved from AnimeDetailService for inclusion in full file)
    // NOTE: Ideally, these parsing functions belong in dedicated parser classes or within AnimeDetailService.
    // They are included here to fulfill the "print the full file" request based on potential previous structure.

    func extractMetadata(document: Document, for source: MediaSource) throws -> (aliases: String, synopsis: String, airdate: String, stars: String) {
        // (Implementation copied from previous response)
         var aliases = ""
         var synopsis = ""
         var airdate = ""
         var stars = ""

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
               aliases = try document.select("tr:contains(Alternative title) td").last()?.text() ?? ""
               synopsis = try document.select("tr:contains(Plot Summary) + tr td").text() // Row after Plot Summary
               airdate = try document.select("tr:contains(Vintage) td").last()?.text() ?? ""
               stars = try document.select("tr:contains(Rating) td").last()?.text().components(separatedBy: " (").first ?? "" // Extract score part

         case .anivibe:
              aliases = try document.select("span.alter").text()
              synopsis = try document.select("div.synp div.entry-content p").text() // Get text within the p tag
              airdate = try document.select(".spe span:contains(Aired:)").first()?.parent()?.text().replacingOccurrences(of: "Aired:", with: "").trimmingCharacters(in: .whitespaces) ?? "N/A"
              stars = try document.select(".spe span:contains(Rating:)").first()?.parent()?.text().replacingOccurrences(of: "Rating:", with: "").trimmingCharacters(in: .whitespaces) ?? "N/A"

         case .animeunity:
              aliases = "" // Often title is the main one, aliases might not be present
              synopsis = try document.select("div.desc").text() // Common description class
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

    func fetchEpisodes(document: Document, for source: MediaSource, href: String) -> [Episode] {
        // (Implementation copied from previous response)
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
                   print("Warning: AniWorld episode fetching in AnimeDetailService is basic and might only get the first season. Full fetching requires dedicated logic.")
                   episodeElements = try document.select("table.seasonEpisodesList tbody tr td a") // Example: Only gets first season links
                   // For a full implementation, you'd need to call the multi-season fetching logic here or earlier.
                   return [] // Returning empty to avoid incomplete list, handle this upstream.

              case .tokyoinsider:
                  episodeElements = try document.select("div.episode a.download-link") // Links with download-link class
              case .anivibe, .animebalkan: // Grouping similar structures
                   episodeElements = try document.select("div.eplister ul li a")
              case .animeunity:
                  // AnimeUnity often embeds episode data in JSON within attributes
                  return parseAnimeUnityEpisodes(document: document, baseURL: baseURL) // Use specific helper
              case .animeflv:
                   // AnimeFLV often stores episode info in JavaScript variables
                   return parseAnimeFLVJsonEpisodes(document: document, baseURL: baseURL) // Use specific helper
              case .anibunker:
                  episodeElements = try document.select("div.eps-display a")

              // Note: HiAnime and Anilibria fetch episodes via their dedicated service/API calls, not HTML parsing here.
              case .hianime, .anilibria:
                  return [] // Episodes are fetched via AnimeDetailService.fetchAnimeDetails for these

              default:
                  print("Episode parsing not implemented for source: \(source.rawValue)")
                  return [] // Return empty for unhandled sources
              }

              // Generic parsing loop for sources using standard link/text structure
              episodes = try episodeElements.compactMap { element -> Episode? in
                  guard let episodeTextRaw = try? element.text(), !episodeTextRaw.isEmpty,
                        let hrefPath = try? element.attr("href"), !hrefPath.isEmpty else {
                      print("Skipping episode element, missing text or href for source \(source.rawValue)")
                      return nil
                  }

                  let episodeNumber = extractEpisodeNumber(from: episodeTextRaw, for: source)
                  // Construct full URL if href is relative
                  let fullHref = hrefPath.starts(with: "http") ? hrefPath : baseURL + hrefPath

                  // Download URL is usually fetched later, set to empty string for now
                   // Use nil for downloadUrl if the Episode struct defines it as optional
                   return Episode(id: nil, number: episodeNumber, title: nil, href: fullHref, downloadUrl: "") // Adjust based on Episode struct
              }

              // Sort episodes numerically based on the extracted number
               episodes.sort {
                   // Extract numeric part for comparison, handle potential non-numeric cases
                   let num1 = EpisodeNumberExtractor.extract(from: $0.number)
                   let num2 = EpisodeNumberExtractor.extract(from: $1.number)
                   return num1 < num2
               }


          } catch {
              print("Error parsing episodes for \(source.rawValue): \(error.localizedDescription)")
          }
          return episodes
      }

    // Helper to extract episode number string based on source conventions
     func extractEpisodeNumber(from text: String, for source: MediaSource) -> String {
         // Default: Extract numbers, handle "Episode X", "Ep. X", etc.
         let cleaned = text.replacingOccurrences(of: "Episodio", with: "", options: .caseInsensitive)
                             .replacingOccurrences(of: "Epizoda", with: "", options: .caseInsensitive)
                             .replacingOccurrences(of: "Episode", with: "", options: .caseInsensitive)
                             .replacingOccurrences(of: "Ep.", with: "", options: .caseInsensitive)
                              .replacingOccurrences(of: "Folge", with: "", options: .caseInsensitive) // German for Episode
                             .replacingOccurrences(of: "الحلقة", with: "", options: .caseInsensitive) // Arabic for episode
                             .trimmingCharacters(in: .whitespacesAndNewlines)
         // Attempt to find the first sequence of digits (potentially with a decimal)
          if let range = cleaned.range(of: "^\\d+(\\.\\d+)?", options: .regularExpression) {
              return String(cleaned[range])
          }
          // Fallback if no number found at the start, return cleaned text or "1"
          return cleaned.isEmpty ? "1" : cleaned
      }

     // Helper to get the base URL for constructing full episode URLs
     func getBaseURL(for source: MediaSource, originalHref: String) -> String {
         // (Implementation copied from previous response)
         switch source {
         case .animeWorld: return "https://animeworld.so"
         case .animeheaven: return "https://animeheaven.me/"
         case .animesrbija: return "https://www.animesrbija.com"
         case .aniworld: return "https://aniworld.to"
         case .tokyoinsider: return "https://www.tokyoinsider.com"
         case .anivibe: return "https://anivibe.to" // Verify base URL
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
     func parseAnimeUnityEpisodes(document: Document, baseURL: String) -> [Episode] {
         // (Implementation copied from previous response)
          do {
              let rawHtml = try document.html()
              // Find the video-player element and extract the episodes JSON string
              if let startIndex = rawHtml.range(of: "<video-player")?.upperBound,
                 let endIndex = rawHtml.range(of: "</video-player>")?.lowerBound {
                  let videoPlayerContent = String(rawHtml[startIndex..<endIndex])
                  if let episodesStart = videoPlayerContent.range(of: "episodes=\"")?.upperBound,
                     let episodesEnd = videoPlayerContent[episodesStart...].range(of: "\"")?.lowerBound {

                      let episodesJson = String(videoPlayerContent[episodesStart..<episodesEnd])
                          .replacingOccurrences(of: "&quot;", with: "\"") // Decode HTML entities

                      if let episodesData = episodesJson.data(using: .utf8),
                         let episodesList = try? JSONSerialization.jsonObject(with: episodesData) as? [[String: Any]] {

                          return episodesList.compactMap { episodeDict in
                              guard let number = episodeDict["number"] as? String, !number.isEmpty,
                                    let linkPath = episodeDict["link"] as? String else { // 'link' is usually the relative path
                                  print("Skipping AnimeUnity episode due to missing number or link.")
                                  return nil
                              }
                              // Construct full href using base URL and link path
                              let hrefFull = baseURL + linkPath
                              // Use nil for id and downloadUrl as they aren't directly available here
                               return Episode(id: nil, number: number, title: nil, href: hrefFull, downloadUrl: nil)
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
      func parseAnimeFLVJsonEpisodes(document: Document, baseURL: String) -> [Episode] {
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
                             let episodeData = try? JSONSerialization.jsonObject(with: data) as? [[Double]] { // Use Double

                              // Also need the anime info script block for the base URL part
                              if let infoScriptRangeStart = scriptContent.range(of: "var anime_info = "),
                                 let infoScriptRangeEnd = scriptContent.range(of: "};", range: infoScriptRangeStart.upperBound..<scriptContent.endIndex),
                                 // Extract JSON string carefully, handling potential missing quotes
                                 let infoJsonStringAttempt = String(scriptContent[infoScriptRangeStart.upperBound..<infoScriptRangeEnd.lowerBound] + "}")
                                     .data(using: .utf8), // Convert to data first
                                 let animeInfoJson = try? JSONSerialization.jsonObject(with: infoJsonStringAttempt) as? [String: Any],
                                 let animeSlug = animeInfoJson["slug"] as? String { // Get the anime slug

                                  let verBaseURL = baseURL // Use the passed base URL, assuming it's already correct (/anime/...)

                                  episodes = episodeData.compactMap { episodePair in
                                      guard episodePair.count == 2 else { return nil }
                                      let episodeNumber = String(format: "%.0f", episodePair[0]) // Format as integer string
                                       // Construct href using the pattern: /ver/{slug}-{episodeNumber}
                                      let href = "\(verBaseURL.replacingOccurrences(of: "/anime/", with: "/ver/"))\(animeSlug)-\(episodeNumber)"
                                       return Episode(id: nil, number: episodeNumber, title: nil, href: href, downloadUrl: nil)
                                  }
                                  // Break after finding the correct script block
                                  break
                              } else {
                                  print("Could not find or parse anime_info script block in AnimeFLV.")
                              }
                          } else {
                             print("Failed to parse episodes array JSON from AnimeFLV script.")
                          }
                      } else {
                         print("Could not extract episodes array string from AnimeFLV script.")
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


    // Parses GoGoAnime episode ranges
    func parseGoGoEpisodes(elements: Elements, categoryHref: String) -> [Episode] {
         // categoryHref is like "/category/one-piece"
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
                      guard formattedEpisode != "0" else { continue } // Skip episode 0 if present
                      // Construct the specific episode href for GoGoAnime
                      let episodeHref = "https://anitaku.to/\(animeSlug)-episode-\(episodeNumber)" // Base URL + slug + episode pattern
                      episodes.append(Episode(id: nil, number: formattedEpisode, title: nil, href: episodeHref, downloadUrl: ""))
                 }
             }
              // Sort episodes numerically
              episodes.sort {
                  (Int($0.number) ?? 0) < (Int($1.number) ?? 0)
              }

         } catch {
             print("Error parsing GoGoAnime episode ranges: \(error)")
         }
         return episodes
     }

    // --- Add other parsing helpers copied from AnimeDetailService ---
     func extractVideoSourceURL(from htmlString: String) -> URL? {
        // (Implementation copied from previous response)
         do {
             let doc: Document = try SwiftSoup.parse(htmlString)
             // Try common selectors for video source
             if let videoElement = try doc.select("video").first(),
                let sourceElement = try videoElement.select("source[src]").first(), // More specific: source with src
                let sourceURLString = try sourceElement.attr("src").nilIfEmpty,
                let sourceURL = URL(string: sourceURLString) {
                 return sourceURL
             }
             // Add more selectors if needed for specific sites covered by this generic function
         } catch {
             print("Error parsing HTML with SwiftSoup in extractVideoSourceURL: \(error)")
         }

         // Fallback regex patterns if SwiftSoup fails or structure is different
         let mp4Pattern = #"<source[^>]+src="([^"]+\.mp4[^"]*)"# // Look for .mp4 within src
         let m3u8Pattern = #"<source[^>]+src="([^"]+\.m3u8[^"]*)"# // Look for .m3u8 within src
         let jsFilePattern = #"file:\s*['"](https?://[^'"]+\.(?:mp4|m3u8)[^'"]*)['"]"# // Look in JS variables

         if let mp4URL = extractURL(from: htmlString, pattern: mp4Pattern) { return mp4URL }
         if let m3u8URL = extractURL(from: htmlString, pattern: m3u8Pattern) { return m3u8URL }
         if let jsURL = extractURL(from: htmlString, pattern: jsFilePattern) { return jsURL }

         print("Could not extract video source URL using common methods.")
         return nil
     }

     func extractURL(from htmlString: String, pattern: String) -> URL? {
         // (Implementation copied from previous response)
         guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive), // Added caseInsensitive
               let match = regex.firstMatch(in: htmlString, range: NSRange(htmlString.startIndex..., in: htmlString)),
               let urlRange = Range(match.range(at: 1), in: htmlString) else { // Group 1 should contain the URL
                   return nil
               }

         let urlString = String(htmlString[urlRange]).replacingOccurrences(of: "\\/", with: "/") // Unescape slashes
         return URL(string: urlString)
     }

     func extractIframeSourceURL(from htmlString: String) -> URL? {
         // (Implementation copied from previous response)
         do {
             let doc: Document = try SwiftSoup.parse(htmlString)
             guard let iframeElement = try doc.select("iframe[src]").first(), // Ensure iframe has src
                   let sourceURLString = try iframeElement.attr("src").nilIfEmpty else {
                 print("No iframe with src found.")
                 return nil
             }
             // Handle potentially relative URLs starting with //
             let absoluteURLString = sourceURLString.starts(with: "//") ? "https:\(sourceURLString)" : sourceURLString
             return URL(string: absoluteURLString)
         } catch {
             print("Error parsing HTML with SwiftSoup in extractIframeSourceURL: \(error)")
             return nil
         }
     }

     func extractAniBunker(from htmlString: String) -> URL? {
         // (Implementation copied from previous response)
          do {
              let doc: Document = try SwiftSoup.parse(htmlString)
              guard let videoElement = try doc.select("div#videoContainer[data-video-id]").first(), // Be more specific
                    let videoID = try videoElement.attr("data-video-id").nilIfEmpty else {
                    print("AniBunker: Could not find video container or data-video-id.")
                    return nil
              }

              let url = URL(string: "https://www.anibunker.com/php/loader.php")! // API endpoint
              var request = URLRequest(url: url)
              request.httpMethod = "POST"
              // Required headers for this endpoint
              request.setValue("https://www.anibunker.com", forHTTPHeaderField: "Origin")
              request.setValue("https://www.anibunker.com", forHTTPHeaderField: "Referer")
              request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

              let bodyString = "player_id=url_hd&video_id=\(videoID)" // Requesting HD URL
              request.httpBody = bodyString.data(using: .utf8)

              // Use synchronous request for simplicity within this helper (consider async elsewhere)
              let (data, _, error) = URLSession.shared.syncRequest(with: request)

              guard let data = data, error == nil else {
                  print("Error making POST request to AniBunker loader: \(error?.localizedDescription ?? "Unknown error")")
                  return nil
              }

              // Parse the JSON response
              if let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                 let success = json["success"] as? Bool, success,
                 let urlString = json["url"] as? String,
                 let url = URL(string: urlString) {
                  print("AniBunker URL extracted: \(url)")
                  return url
              } else {
                  print("Error parsing AniBunker JSON response or success was false.")
                   if let json = try? JSONSerialization.jsonObject(with: data, options: []) {
                       print("AniBunker Response JSON: \(json)")
                   }
                  return nil
              }
          } catch {
              print("Error parsing HTML with SwiftSoup for AniBunker: \(error)")
              return nil
          }
     }

     func extractEmbedUrl(from rawHtml: String, completion: @escaping (URL?) -> Void) {
         // (Implementation copied from previous response)
          // Find the video-player element content
          if let startIndex = rawHtml.range(of: "<video-player")?.upperBound,
             let endIndex = rawHtml.range(of: "</video-player>")?.lowerBound {

              let videoPlayerContent = String(rawHtml[startIndex..<endIndex])

              // Extract the embed_url attribute value
              if let embedUrlStart = videoPlayerContent.range(of: "embed_url=\"")?.upperBound,
                 let embedUrlEnd = videoPlayerContent[embedUrlStart...].range(of: "\"")?.lowerBound {

                  var embedUrlString = String(videoPlayerContent[embedUrlStart..<embedUrlEnd])
                  embedUrlString = embedUrlString.replacingOccurrences(of: "&amp;", with: "&") // Decode HTML entity

                  // Now fetch the content of the embed URL to find the actual source
                  extractWindowUrl(from: embedUrlString, completion: completion)
                  return
              } else {
                 print("Could not find embed_url attribute in AnimeUnity video-player tag.")
              }
          } else {
             print("Could not find video-player tag in AnimeUnity HTML.")
          }
          // If extraction fails at any point
          completion(nil)
      }

     func extractWindowUrl(from urlString: String, completion: @escaping (URL?) -> Void) {
         // (Implementation copied from previous response)
          guard let url = URL(string: urlString) else {
              completion(nil)
              return
          }

          var request = URLRequest(url: url)
         // Use a standard browser User-Agent
          request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36", forHTTPHeaderField: "User-Agent")
         // Set Referer if needed, often crucial for embed pages
         request.setValue(urlString, forHTTPHeaderField: "Referer")


          URLSession.shared.dataTask(with: request) { data, response, error in
              guard let data = data,
                    let pageContent = String(data: data, encoding: .utf8),
                    error == nil else {
                        print("Error fetching embed page content from \(urlString): \(error?.localizedDescription ?? "Unknown error")")
                        DispatchQueue.main.async { completion(nil) }
                        return
                    }

              // Regex to find `window.downloadUrl = '...'` or similar patterns
              // Handle both single and double quotes, and potential whitespace variations
              let downloadUrlPattern = #"window\.downloadUrl\s*=\s*['"]([^'"]+)['"]"# // Primary pattern

              guard let regex = try? NSRegularExpression(pattern: downloadUrlPattern, options: []) else {
                   print("Invalid regex pattern for window.downloadUrl.")
                   DispatchQueue.main.async { completion(nil) }
                   return
              }

              let range = NSRange(pageContent.startIndex..<pageContent.endIndex, in: pageContent)
              if let match = regex.firstMatch(in: pageContent, options: [], range: range),
                 let urlRange = Range(match.range(at: 1), in: pageContent) { // Group 1 captures the URL

                  let downloadUrlString = String(pageContent[urlRange])
                  // Clean URL (remove HTML entities like &amp;)
                  let cleanedUrlString = downloadUrlString.replacingOccurrences(of: "&amp;", with: "&")

                  guard let downloadUrl = URL(string: cleanedUrlString) else {
                      print("Extracted downloadUrl string is not a valid URL: \(cleanedUrlString)")
                      DispatchQueue.main.async { completion(nil) }
                      return
                  }

                  print("Extracted download URL: \(downloadUrl)")
                  DispatchQueue.main.async { completion(downloadUrl) }
              } else {
                  print("Could not find window.downloadUrl pattern in embed page: \(urlString)")
                   // Optionally log a snippet of pageContent here for debugging
                   print("Page content snippet: \(pageContent.prefix(500))")
                  DispatchQueue.main.async { completion(nil) }
              }
          }.resume()
      }

     func extractDataVideoSrcURL(from htmlString: String) -> URL? {
         // (Implementation copied from previous response)
          do {
              let doc: Document = try SwiftSoup.parse(htmlString)
              // Select any element that has the 'data-video-src' attribute
              guard let element = try doc.select("[data-video-src]").first(),
                    let sourceURLString = try element.attr("data-video-src").nilIfEmpty, // Get the attribute value
                    let sourceURL = URL(string: sourceURLString) else {
                        print("Could not find element with 'data-video-src' attribute or attribute was empty/invalid.")
                        return nil
                    }
              print("Data-video-src URL: \(sourceURL.absoluteString)")
              return sourceURL
          } catch {
              print("Error parsing HTML with SwiftSoup in extractDataVideoSrcURL: \(error)")
              return nil
          }
      }

     func extractDownloadLink(from htmlString: String) -> URL? {
         // (Implementation copied from previous response)
          do {
              let doc: Document = try SwiftSoup.parse(htmlString)
              // Select anchor tags within list items having class 'dowloads' (adjust selector if needed)
              guard let downloadElement = try doc.select("li.dowloads a[href]").first(), // More specific: ensure 'a' has 'href'
                    let hrefString = try downloadElement.attr("href").nilIfEmpty, // Get href value
                    let downloadURL = URL(string: hrefString) else {
                        print("Could not find download link element (li.dowloads a) or href was empty/invalid.")
                        return nil
                    }
              print("Download link URL: \(downloadURL.absoluteString)")
              return downloadURL
          } catch {
              print("Error parsing HTML with SwiftSoup in extractDownloadLink: \(error)")
              return nil
          }
      }

     func extractTokyoVideo(from htmlString: String, completion: @escaping (URL?) -> Void) { // Changed to optional URL
         let formats = UserDefaults.standard.bool(forKey: "otherFormats") ? ["mp4", "mkv", "avi"] : ["mp4"]

         DispatchQueue.global(qos: .userInitiated).async {
             do {
                 let doc = try SwiftSoup.parse(htmlString)
                 // Construct a selector that matches links containing the base media URL and ending with allowed formats
                 let combinedSelector = formats.map { "a[href*='media.tokyoinsider.com'][href$=\'.\($0)\']" }.joined(separator: ", ")

                 let downloadElements = try doc.select(combinedSelector)

                 let foundURLs = downloadElements.compactMap { element -> (url: URL, filename: String)? in
                     guard let hrefString = try? element.attr("href").nilIfEmpty,
                           let url = URL(string: hrefString) else { return nil }
                     let filename = url.lastPathComponent // Get filename for display
                     return (url: url, filename: filename)
                 }

                 DispatchQueue.main.async {
                     guard !foundURLs.isEmpty else {
                         self.hideLoadingBannerAndShowAlert(title: "Not Found", message: "No video URLs found for allowed formats (\(formats.joined(separator: ", "))).")
                         completion(nil) // Indicate failure
                         return
                     }

                     if foundURLs.count == 1 {
                         completion(foundURLs[0].url) // Directly complete if only one option
                         return
                     }

                     // Present options if multiple formats are found
                     let alertController = UIAlertController(title: "Select Video Format", message: "Choose which video to play:", preferredStyle: .actionSheet)

                     if UIDevice.current.userInterfaceIdiom == .pad {
                         if let popoverController = alertController.popoverPresentationController {
                             popoverController.sourceView = self.view
                             popoverController.sourceRect = CGRect(x: self.view.bounds.midX, y: self.view.bounds.midY, width: 0, height: 0)
                             popoverController.permittedArrowDirections = []
                         }
                     }

                     // Add actions for each found format/URL
                     for (url, filename) in foundURLs {
                         let action = UIAlertAction(title: filename, style: .default) { _ in
                             completion(url)
                         }
                         alertController.addAction(action)
                     }

                     // Add cancel action
                     let cancelAction = UIAlertAction(title: "Cancel", style: .cancel) { _ in
                          self.hideLoadingBanner() // Hide banner on cancel
                          completion(nil) // Indicate cancellation or failure
                     }
                     alertController.addAction(cancelAction)

                     self.hideLoadingBanner { // Hide banner before showing options
                         self.present(alertController, animated: true)
                     }
                 }
             } catch {
                 DispatchQueue.main.async {
                     print("Error parsing TokyoInsider HTML with SwiftSoup: \(error)")
                     self.hideLoadingBannerAndShowAlert(title: "Error", message: "Error extracting video URLs.")
                     completion(nil) // Indicate failure
                 }
             }
         }
     }


    func extractAsgoldURL(from documentString: String) -> URL? {
        // (Implementation copied from previous response)
        // Pattern looks for "player2":"!https://...video/..."
         let pattern = "\"player2\":\"!(https?://video\\.asgold\\.pp\\.ua/video/[^\"]*)\"" // Capture the URL in group 1

         do {
             let regex = try NSRegularExpression(pattern: pattern, options: [])
             let range = NSRange(documentString.startIndex..<documentString.endIndex, in: documentString)

             if let match = regex.firstMatch(in: documentString, options: [], range: range),
                let matchRange = Range(match.range(at: 1), in: documentString) { // Get captured group 1
                 let urlString = String(documentString[matchRange])
                 print("Extracted Asgold URL: \(urlString)")
                 return URL(string: urlString)
             } else {
                print("Asgold URL pattern not found.")
             }
         } catch {
            print("Error creating regex for Asgold: \(error)")
         }
         return nil
     }

    func extractAniVibeURL(from htmlContent: String) -> URL? {
        // (Implementation copied from previous response)
         // Pattern looks for "url":"https://...m3u8" inside JSON-like structure
         let pattern = #""url"\s*:\s*"(https?://.*?\.m3u8[^"]*)""# // Capture the URL in group 1

         guard let regex = try? NSRegularExpression(pattern: pattern) else {
             print("Invalid regex pattern for AniVibe.")
             return nil
         }

         let range = NSRange(htmlContent.startIndex..., in: htmlContent)
         guard let match = regex.firstMatch(in: htmlContent, range: range) else {
             print("AniVibe m3u8 URL pattern not found.")
             return nil
         }

         if let urlRange = Range(match.range(at: 1), in: htmlContent) { // Group 1 has the URL
             let extractedURLString = String(htmlContent[urlRange])
             // Unescape any escaped forward slashes
             let unescapedURLString = extractedURLString.replacingOccurrences(of: "\\/", with: "/")
             print("Extracted AniVibe m3u8 URL: \(unescapedURLString)")
             return URL(string: unescapedURLString)
         }

         return nil
     }


    func extractStreamtapeQueryParameters(from htmlString: String, completion: @escaping (URL?) -> Void) {
        // (Implementation copied from previous response)
         // 1. Find the initial Streamtape embed URL within the provided HTML
         let streamtapePattern = #"https?://(?:www\.)?streamtape\.(?:com|to|net)/[ev]/[^\s"']+"# // Broader domain matching
         guard let streamtapeRegex = try? NSRegularExpression(pattern: streamtapePattern, options: []),
               let streamtapeMatch = streamtapeRegex.firstMatch(in: htmlString, options: [], range: NSRange(location: 0, length: htmlString.utf16.count)),
               let streamtapeRange = Range(streamtapeMatch.range, in: htmlString) else {
             print("Streamtape embed URL not found in initial HTML.")
             completion(nil)
             return
         }

         let streamtapeURLString = String(htmlString[streamtapeRange])
         guard let streamtapeURL = URL(string: streamtapeURLString) else {
             print("Invalid Streamtape URL found: \(streamtapeURLString)")
             completion(nil)
             return
         }
         print("Found Streamtape embed URL: \(streamtapeURLString)")

         // 2. Fetch the content of the Streamtape embed page
         var request = URLRequest(url: streamtapeURL)
         request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/92.0.4515.159 Safari/537.36", forHTTPHeaderField: "User-Agent")
          // Add referer if necessary, using the original page URL
         if let originalURL = self.href, let refererURL = URL(string: originalURL) {
              request.setValue(refererURL.absoluteString, forHTTPHeaderField: "Referer")
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

             // 3. Extract the query parameters for the actual video URL from the Streamtape page HTML
              // Pattern looks for the specific JS line that constructs the video link part
              // Example: document.getElementById('robotlink').innerHTML = '<a href="//streamtape.com/get_video?id=...&expires=...&ip=...&token=..."';
              // Or the 'norobotlink' variant
             let queryPattern = #"document\.getElementById\('(?:robotlink|norobotlink)'\)\.innerHTML\s*=\s*'<a href="(/+streamtape\.(?:com|to|net)/get_video\?[^"]+)"'# // Capture the relative URL + query

             guard let queryRegex = try? NSRegularExpression(pattern: queryPattern, options: []) else {
                  print("Invalid regex for Streamtape query.")
                  DispatchQueue.main.async { completion(nil) }
                  return
             }

             let range = NSRange(location: 0, length: responseHTML.utf16.count)
             if let queryMatch = queryRegex.firstMatch(in: responseHTML, options: [], range: range),
                 let queryRange = Range(queryMatch.range(at: 1), in: responseHTML) { // Group 1 has the path + query

                 let pathAndQuery = String(responseHTML[queryRange])
                  // Prepend "https:" if it starts with "//"
                 let fullURLString = pathAndQuery.starts(with: "//") ? "https:\(pathAndQuery)" : pathAndQuery

                 print("Extracted Streamtape video URL: \(fullURLString)")
                 DispatchQueue.main.async { completion(URL(string: fullURLString)) }
             } else {
                 print("Could not find Streamtape video query parameters in the page HTML.")
                 // Log snippet for debugging:
                 print("Streamtape HTML snippet: \(responseHTML.prefix(1000))")
                 DispatchQueue.main.async { completion(nil) }
             }
         }.resume()
     }

     func anime3rbGetter(from documentString: String, completion: @escaping (URL?) -> Void) {
         // (Implementation copied from previous response)
          // 1. Extract the initial video player embed URL
          guard let videoPlayerURL = extractAnime3rbVideoURL(from: documentString) else {
              print("Anime3rb: Could not find initial player embed URL.")
              completion(nil)
              return
          }
          print("Anime3rb: Found player embed URL: \(videoPlayerURL.absoluteString)")

          // 2. Fetch the content of that embed page to get the final MP4 URL
          extractAnime3rbMP4VideoURL(from: videoPlayerURL.absoluteString, completion: completion)
      }

     func extractAnime3rbVideoURL(from documentString: String) -> URL? {
         // (Implementation copied from previous response)
          // Pattern looks for the specific player URL structure used by Anime3rb
          let pattern = #"https?://video\.vid3rb\.com/player/[\w-]+(?:\?|&amp;)token=[\w]+(?:&|&amp;)expires=\d+"# // Non-capturing group for optional amp;

          do {
              let regex = try NSRegularExpression(pattern: pattern, options: [])
              let range = NSRange(documentString.startIndex..<documentString.endIndex, in: documentString)

              if let match = regex.firstMatch(in: documentString, options: [], range: range),
                 let matchRange = Range(match.range, in: documentString) {
                  let urlString = String(documentString[matchRange])
                   // Clean &amp; just in case
                  let cleanedURLString = urlString.replacingOccurrences(of: "&amp;", with: "&")
                  print("Anime3rb: Initial player URL extracted: \(cleanedURLString)")
                  return URL(string: cleanedURLString)
              } else {
                 print("Anime3rb: Initial player URL pattern not found.")
              }
          } catch {
               print("Anime3rb: Error creating regex for initial player URL: \(error)")
          }
          return nil
      }

    func extractAnime3rbMP4VideoURL(from urlString: String, completion: @escaping (URL?) -> Void) {
         // (Implementation copied from previous response)
          guard let url = URL(string: urlString) else {
              completion(nil)
              return
          }

          var request = URLRequest(url: url)
          request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36", forHTTPHeaderField: "User-Agent")
          request.setValue(urlString, forHTTPHeaderField: "Referer") // Set referer to the embed page itself

          URLSession.shared.dataTask(with: request) { data, response, error in
              guard let data = data,
                    let pageContent = String(data: data, encoding: .utf8),
                    error == nil else {
                        print("Anime3rb: Error fetching MP4 embed page content from \(urlString): \(error?.localizedDescription ?? "Unknown")")
                        DispatchQueue.main.async { completion(nil) }
                        return
                    }

              // Pattern looks for source src attribute containing .mp4
              let mp4Pattern = #"<source[^>]+src="([^"]+?\.mp4[^"]*)"#

              guard let regex = try? NSRegularExpression(pattern: mp4Pattern, options: []) else {
                   print("Anime3rb: Invalid regex for MP4 source.")
                   DispatchQueue.main.async { completion(nil) }
                   return
              }

              let range = NSRange(pageContent.startIndex..<pageContent.endIndex, in: pageContent)
              if let match = regex.firstMatch(in: pageContent, options: [], range: range),
                 let urlRange = Range(match.range(at: 1), in: pageContent) { // Group 1 has the URL
                  let mp4UrlString = String(pageContent[urlRange])
                   // Clean potential HTML entities
                  let cleanedUrlString = mp4UrlString.replacingOccurrences(of: "&amp;", with: "&")
                  let mp4Url = URL(string: cleanedUrlString)
                   print("Anime3rb: Extracted MP4 URL: \(mp4Url?.absoluteString ?? "Invalid URL")")
                  DispatchQueue.main.async { completion(mp4Url) }
              } else {
                  print("Anime3rb: MP4 source pattern not found in embed page: \(urlString)")
                   // Log snippet for debugging
                   print("Anime3rb Embed HTML snippet: \(pageContent.prefix(1000))")
                  DispatchQueue.main.async { completion(nil) }
              }
          }.resume()
      }

     func fetchVideoDataAndChooseQuality(from urlString: String, completion: @escaping (URL?) -> Void) {
         // (Implementation copied from previous response)
          guard let url = URL(string: urlString) else {
              print("Invalid URL string for fetching qualities: \(urlString)")
              completion(nil)
              return
          }

          let task = URLSession.shared.dataTask(with: url) { data, response, error in
              guard let data = data, error == nil else {
                  print("Network error fetching qualities: \(String(describing: error))")
                  DispatchQueue.main.async { completion(nil) }
                  return
              }

              do {
                  // Attempt to parse JSON (common for AnimeFire)
                  if let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                     let videoDataArray = json["data"] as? [[String: Any]] {

                      var qualitiesFound: [(String, String)] = [] // Store as (label, src)
                      for videoData in videoDataArray {
                          if let label = videoData["label"] as? String,
                             let src = videoData["src"] as? String {
                              qualitiesFound.append((label, src))
                          }
                      }

                      if qualitiesFound.isEmpty {
                          print("No available video qualities found in JSON")
                          DispatchQueue.main.async { completion(nil) }
                          return
                      }

                      DispatchQueue.main.async {
                           // Now choose the best quality based on preference
                           self.choosePreferredQualityFromList(availableQualities: qualitiesFound, completion: completion)
                      }

                  } else {
                       print("JSON structure is invalid or data key is missing for quality fetching")
                       DispatchQueue.main.async { completion(nil) }
                  }
              } catch {
                  print("Error parsing quality JSON: \(error)")
                  DispatchQueue.main.async { completion(nil) }
              }
          }
          task.resume()
      }

     // Helper to choose quality from a list of (label, urlString) tuples
     func choosePreferredQualityFromList(availableQualities: [(label: String, urlString: String)], completion: @escaping (URL?) -> Void) {
         let preferredQuality = UserDefaults.standard.string(forKey: "preferredQuality") ?? "1080p" // Default preference

         // Try to find an exact match
         if let exactMatch = availableQualities.first(where: { $0.label == preferredQuality }) {
             completion(URL(string: exactMatch.urlString))
             return
         }

         // If no exact match, find the closest available quality numerically
         let preferredValue = Int(preferredQuality.replacingOccurrences(of: "p", with: "")) ?? 1080
         let sortedByCloseness = availableQualities.sorted { quality1, quality2 in
             let val1 = Int(quality1.label.replacingOccurrences(of: "p", with: "")) ?? 0
             let val2 = Int(quality2.label.replacingOccurrences(of: "p", with: "")) ?? 0
             return abs(val1 - preferredValue) < abs(val2 - preferredValue)
         }

         if let closestMatch = sortedByCloseness.first {
             completion(URL(string: closestMatch.urlString))
         } else {
             print("No suitable quality option found after checking preferences.")
             completion(nil) // No quality could be selected
         }
     }

     func showQualityPicker(qualities: [String], completion: @escaping (String?) -> Void) {
         // (Implementation copied from previous response)
          let alertController = UIAlertController(title: "Choose Video Quality", message: nil, preferredStyle: .actionSheet)

          for quality in qualities.sorted(by: >) { // Sort from highest to lowest for presentation
              let action = UIAlertAction(title: quality, style: .default) { _ in
                  completion(quality)
              }
              alertController.addAction(action)
          }
         alertController.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completion(nil) } )

          // Popover setup for iPad
          if let popoverController = alertController.popoverPresentationController {
              popoverController.sourceView = self.view
              popoverController.sourceRect = CGRect(x: self.view.bounds.midX, y: self.view.bounds.midY, width: 0, height: 0)
              popoverController.permittedArrowDirections = [] // Center it
          }

          self.present(alertController, animated: true, completion: nil)
      }

     func extractVidozaVideoURL(from htmlString: String, completion: @escaping (URL?) -> Void) {
         // (Implementation copied from previous response)
          // Pattern looks for `sourcesCode: [{ src: "URL" ...}]`
          let scriptPattern = #"sourcesCode:\s*\[\s*\{\s*src:\s*"([^"]+)"# // Capture URL in group 1

          guard let scriptRegex = try? NSRegularExpression(pattern: scriptPattern),
                let scriptMatch = scriptRegex.firstMatch(in: htmlString, range: NSRange(htmlString.startIndex..., in: htmlString)),
                let urlRange = Range(scriptMatch.range(at: 1), in: htmlString) else {
                    print("Vidoza source pattern not found in HTML.")
                    DispatchQueue.main.async { completion(nil) }
                    return
                }

          let videoURLString = String(htmlString[urlRange])
          let finalURL = URL(string: videoURLString)
          print("Extracted Vidoza URL: \(finalURL?.absoluteString ?? "Invalid URL")")
          DispatchQueue.main.async { completion(finalURL) }
      }

     func extractAllVideoLinks(from htmlString: String) -> [VideoLink] {
         // (Implementation copied from previous response)
         var links: [VideoLink] = []

         // Pattern combines selectors for different hosts
         let pattern = "<li[^>]*?data-lang-key=\"(\\d)\"[^>]*?>\\s*<div>\\s*<a[^>]*?href=\"(/redirect/[^\"]+)\"[^>]*?>\\s*<i class=\"icon (Vidoza|VOE|Vidmoly)\""

         guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            print("Invalid regex for extracting AniWorld links.")
            return []
         }

         let matches = regex.matches(in: htmlString, range: NSRange(htmlString.startIndex..., in: htmlString))

         for match in matches {
            guard let langKeyRange = Range(match.range(at: 1), in: htmlString),
                  let urlRange = Range(match.range(at: 2), in: htmlString),
                  let hostRange = Range(match.range(at: 3), in: htmlString), // Capture group for host name
                  let langKey = Int(htmlString[langKeyRange]),
                  let language = VideoLanguage(rawValue: langKey) else {
                      continue
                  }

             let path = String(htmlString[urlRange])
             let hostString = String(htmlString[hostRange])
             let host: VideoHost

             switch hostString {
                 case "Vidoza": host = .vidoza
                 case "VOE": host = .voe
                 case "Vidmoly": host = .vidmoly
                 default: continue // Skip unknown hosts
             }

             let fullURL = "https://aniworld.to\(path)" // Base URL for AniWorld redirects
             links.append(VideoLink(url: fullURL, language: language, host: host))
         }

         return links
     }

     func extractLinks(from matches: [NSTextCheckingResult], in htmlString: String, host: VideoHost) -> [VideoLink] {
         // (Implementation copied from previous response)
          return matches.compactMap { match in
              // Ensure all capture groups are valid
              guard match.numberOfRanges == 4, // Expecting full match + 3 capture groups
                    let langKeyRange = Range(match.range(at: 1), in: htmlString),
                    let urlRange = Range(match.range(at: 2), in: htmlString),
                    // Group 3 is the host name, already known from the caller
                    let langKey = Int(htmlString[langKeyRange]),
                    let language = VideoLanguage(rawValue: langKey) else {
                        print("Error extracting link components for host \(host).")
                        return nil
                    }

              let path = String(htmlString[urlRange])
              let fullURL = "https://aniworld.to\(path)" // Assuming AniWorld base URL
              return VideoLink(url: fullURL, language: language, host: host)
          }
      }

     func processVideoURL(_ videoLink: VideoLink, completion: @escaping (URL?) -> Void) {
         // (Implementation copied from previous response)
          guard let url = URL(string: videoLink.url) else {
              DispatchQueue.main.async { completion(nil) }
              return
          }

          // 1. Follow the initial redirect URL (/redirect/...)
          var request = URLRequest(url: url)
         request.setValue("https://aniworld.to/", forHTTPHeaderField: "Referer") // Important referer
         request.setValue(self.userAgent, forHTTPHeaderField: "User-Agent")


          URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
               guard let self = self else { return }

               // Extract the final redirected URL (e.g., to vidoza.net, voe.sx)
               guard let finalURL = (response as? HTTPURLResponse)?.url, error == nil else {
                   print("Error following redirect from \(videoLink.url): \(error?.localizedDescription ?? "Unknown")")
                   DispatchQueue.main.async { completion(nil) }
                   return
               }
              print("Redirected to: \(finalURL.absoluteString)")


               // 2. Fetch content from the final embed host URL
               URLSession.shared.dataTask(with: finalURL) { data, response, error in
                   guard let data = data,
                         let htmlString = String(data: data, encoding: .utf8),
                         error == nil else {
                             print("Error fetching content from \(finalURL): \(error?.localizedDescription ?? "Unknown")")
                             DispatchQueue.main.async { completion(nil) }
                             return
                         }

                    // 3. Extract the direct video source based on the host
                   switch videoLink.host {
                   case .vidoza:
                       self.extractVidozaDirectURL(from: htmlString, completion: completion)
                   case .voe:
                       self.extractVoeDirectURL(from: htmlString, completion: completion)
                   case .vidmoly:
                       self.extractVidmolyDirectURL(from: htmlString, completion: completion)
                   }
               }.resume()
          }.resume()
      }


     func extractVoeDirectURL(from htmlString: String, completion: @escaping (URL?) -> Void) {
         // (Implementation copied from previous response)
          // Pattern to find 'hls': '...' (Base64 encoded URL)
          let hlsPattern = "'hls':\\s*'(.*?)'"
          guard let hlsRegex = try? NSRegularExpression(pattern: hlsPattern),
                let hlsMatch = hlsRegex.firstMatch(in: htmlString, range: NSRange(htmlString.startIndex..., in: htmlString)),
                let hlsRange = Range(hlsMatch.range(at: 1), in: htmlString) else {
                    print("VOE: HLS pattern not found.")
                    DispatchQueue.main.async { completion(nil) }
                    return
                }

          let hlsBase64 = String(htmlString[hlsRange])

          // Decode the Base64 string
          guard let hlsData = Data(base64Encoded: hlsBase64),
                let hlsLink = String(data: hlsData, encoding: .utf8),
                let finalURL = URL(string: hlsLink) else {
                    print("VOE: Failed to decode Base64 HLS URL or create URL object.")
                    DispatchQueue.main.async { completion(nil) }
                    return
                }

          print("Extracted VOE HLS URL: \(finalURL.absoluteString)")
          DispatchQueue.main.async { completion(finalURL) }
      }


     func extractVidozaDirectURL(from htmlString: String, completion: @escaping (URL?) -> Void) {
         // (Implementation copied from previous response)
          // Pattern looks for `sourcesCode: [{ src: "URL" ...}]`
          let scriptPattern = #"sourcesCode:\s*\[\s*\{\s*src:\s*"([^"]+)"# // Capture URL in group 1

          guard let scriptRegex = try? NSRegularExpression(pattern: scriptPattern),
                let scriptMatch = scriptRegex.firstMatch(in: htmlString, range: NSRange(htmlString.startIndex..., in: htmlString)),
                let urlRange = Range(scriptMatch.range(at: 1), in: htmlString) else { // Group 1 has the URL
                    print("Vidoza source pattern not found in HTML.")
                    DispatchQueue.main.async { completion(nil) }
                    return
                }

          let videoURLString = String(htmlString[urlRange])
          let finalURL = URL(string: videoURLString)
          print("Extracted Vidoza URL: \(finalURL?.absoluteString ?? "Invalid URL")")
          DispatchQueue.main.async { completion(finalURL) }
      }

    func extractVidmolyDirectURL(from htmlString: String, completion: @escaping (URL?) -> Void) {
         // (Implementation copied from previous response)
          // Pattern looks for `file: "URL"` within a script block
          let scriptPattern = #"file:\s*"(https?://[^"]+\.m3u8[^"]*)""# // Prioritize m3u8

          guard let scriptRegex = try? NSRegularExpression(pattern: scriptPattern),
                let scriptMatch = scriptRegex.firstMatch(in: htmlString, range: NSRange(htmlString.startIndex..., in: htmlString)),
                let urlRange = Range(scriptMatch.range(at: 1), in: htmlString) else { // Group 1 has the URL
                    print("Vidmoly m3u8 source pattern not found. Trying MP4.")
                   // Fallback to MP4 if m3u8 not found
                   let mp4Pattern = #"file:\s*"(https?://[^"]+\.mp4[^"]*)""#
                    guard let mp4Regex = try? NSRegularExpression(pattern: mp4Pattern),
                          let mp4Match = mp4Regex.firstMatch(in: htmlString, range: NSRange(htmlString.startIndex..., in: htmlString)),
                          let mp4UrlRange = Range(mp4Match.range(at: 1), in: htmlString) else {
                         print("Vidmoly MP4 source pattern also not found.")
                         DispatchQueue.main.async { completion(nil) }
                         return
                    }
                    let videoURLString = String(htmlString[mp4UrlRange])
                    let finalURL = URL(string: videoURLString)
                    print("Extracted Vidmoly MP4 URL: \(finalURL?.absoluteString ?? "Invalid URL")")
                    DispatchQueue.main.async { completion(finalURL) }
                    return
                }

          // If m3u8 was found initially
          let videoURLString = String(htmlString[urlRange])
          let finalURL = URL(string: videoURLString)
          print("Extracted Vidmoly m3u8 URL: \(finalURL?.absoluteString ?? "Invalid URL")")
          DispatchQueue.main.async { completion(finalURL) }
      }

}
