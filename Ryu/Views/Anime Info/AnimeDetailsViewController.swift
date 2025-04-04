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
    
    // User agent for web requests
    var userAgent: String {
        return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Safari/605.1.15"
    }

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
                     self?.imageUrl = fallback
                     self?.tableView.reloadSections(IndexSet(integer: 0), with: .none)
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

        let actions = [
            UIAlertAction(title: "Cancel", style: .cancel),
            UIAlertAction(title: "Download", style: .default) { [weak self] _ in
                self?.startBatchDownload()
            }
        ]
        
        showAlert(
            title: "Download \(selectedEpisodes.count) Episodes?",
            message: "This will queue all selected episodes for download.",
            actions: actions
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

        alertController.addAction(UIAlertAction(title: "Custom AniList ID", style: .default) { [weak self] _ in
            self?.customAniListID()
        })
        
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
             if let presentedVC = self.presentedViewController as? UIAlertController,
                presentedVC.title == nil && (presentedVC.message?.contains("Loading") ?? false) {
                 return // Already showing a loading banner
             }

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

             self.present(alert, animated: true, completion: nil)
         }
     }

    func hideLoadingBanner(completion: (() -> Void)? = nil) {
        DispatchQueue.main.async {
            // Check if the presented VC is our loading alert
             if let alert = self.presentedViewController as? UIAlertController, 
                alert.title == nil && (alert.message?.contains("Loading") ?? false || alert.message?.contains("Extracting") ?? false) {
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

    func showAlert(title: String, message: String, actions: [UIAlertAction]? = nil) {
         DispatchQueue.main.async {
            // Dismiss loading banner first if it's showing
             self.hideLoadingBanner {
                 let alertController = UIAlertController(title: title, message: message, preferredStyle: .alert)
                 
                 if let customActions = actions, !customActions.isEmpty {
                     for action in customActions {
                         alertController.addAction(action)
                     }
                 } else {
                     alertController.addAction(UIAlertAction(title: "OK", style: .default))
                 }
                 
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
    
    // MARK: - Implementing Missing Methods
    
    // Sort episodes based on user preference
    func sortEpisodes() {
        isReverseSorted = UserDefaults.standard.bool(forKey: "isEpisodeReverseSorted")
        if isReverseSorted {
            episodes.sort { $0.episodeNumber > $1.episodeNumber }
        } else {
            episodes.sort { $0.episodeNumber < $1.episodeNumber }
        }
    }

    // Check if anime is in favorites
    func checkFavoriteStatus() {
        if let title = animeTitle, let href = href, let imageURL = imageUrl, let sourceStr = source {
            // Create a FavoriteItem object
            if let imageURLObj = URL(string: imageURL), let hrefURL = URL(string: href) {
                let item = FavoriteItem(title: title, imageURL: imageURLObj, contentURL: hrefURL, source: sourceStr)
                isFavorite = FavoritesManager.shared.isFavorite(item)
            }
        }
    }

    // Prepare and display options menu
    func showOptionsMenu(sourceItem: UIBarButtonItem) {
        let alertController = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        
        // Add favorite action
        let favoriteAction = UIAlertAction(
            title: isFavorite ? "Remove from Favorites" : "Add to Favorites", 
            style: .default
        ) { [weak self] _ in
            self?.toggleFavorite()
        }
        alertController.addAction(favoriteAction)
        
        // Add other actions
        alertController.addAction(UIAlertAction(title: "Advanced Settings", style: .default) { [weak self] _ in
            self?.showAdvancedSettingsMenu()
        })
        
        alertController.addAction(UIAlertAction(title: "Open in Browser", style: .default) { [weak self] _ in
            self?.openAnimeOnWeb()
        })
        
        alertController.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        
        // Configure popover for iPad
        if let popoverController = alertController.popoverPresentationController {
            popoverController.barButtonItem = sourceItem
        }
        
        present(alertController, animated: true)
    }
    

    // Toggle favorite status
    func toggleFavorite() {
        guard let title = animeTitle, 
              let href = href, 
              let imageURL = imageUrl, 
              let sourceStr = source,
              let imageURLObj = URL(string: imageURL), 
              let hrefURL = URL(string: href) else { return }
    
        let item = FavoriteItem(title: title, imageURL: imageURLObj, contentURL: hrefURL, source: sourceStr)
    
        if isFavorite {
             FavoritesManager.shared.removeFavorite(item)
        } else {
            FavoritesManager.shared.addFavorite(item)
        }
    
        isFavorite = !isFavorite
        tableView.reloadData()
    }
    


    // Fetch details and episodes from the selected source
    func fetchDetailsAndEpisodes() {
        guard let href = href else {
            showAlert(title: "Error", message: "No anime URL provided")
            refreshControl?.endRefreshing()
            return
        }
        
        showLoadingBanner(title: "Loading anime details...")
        
        // Fetch details from service
        AnimeDetailService.fetchAnimeDetails(from: href) { [weak self] result in
            guard let self = self else { return }
            
            self.hideLoadingBanner {
                switch result {
                case .success(let details):
                    self.synopsis = details.synopsis
                    self.aliases = details.aliases
                    self.airdate = details.airdate
                    self.stars = details.stars
                    self.episodes = details.episodes
                    
                    self.sortEpisodes()
                    self.tableView.reloadData()
                    
                case .failure(let error):
                    self.showAlert(title: "Error", message: "Failed to load anime details: \(error.localizedDescription)")
                }
                
                self.refreshControl?.endRefreshing()
            }
        }
    }
    
    func openInExternalPlayer(player: String, url: URL) {
        // Stop any currently playing content
        if let currentPlayer = self.player {
            currentPlayer.pause()
            self.player = nil
        }
    
        // Dismiss any active player controller
        if let playerVC = self.playerViewController {
            playerVC.dismiss(animated: true) {
                self.playerViewController = nil
            }
        }
    
        // Handle different player types
        switch player {
        case "VLC":
            // Launch VLC with the URL if installed
            if let vlcURL = URL(string: "vlc://\(url.absoluteString)") {
                UIApplication.shared.open(vlcURL, options: [:]) { success in
                    if !success {
                        self.showAlert(title: "Error", message: "VLC is not installed or could not be opened.")
                    }
                }
            }
        case "AVPlayer":
            // Use built-in AVPlayer
            let player = AVPlayer(url: url)
            let playerVC = AVPlayerViewController()
            playerVC.player = player
            self.present(playerVC, animated: true) {
                player.play()
            }
            self.player = player
            self.playerViewController = playerVC
        default:
            // Default to Safari
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        }
    }

    // MARK: - Required Protocol Methods
    
    // CustomPlayerViewDelegate method
    func customPlayerViewDidDismiss() {
        print("Player view was dismissed")
        // Add your implementation for handling player dismissal
    }
    
    // Episode selection handler
    func episodeSelected(episode: Episode, cell: EpisodeCell) {
        currentEpisodeIndex = episodes.firstIndex(of: episode) ?? 0
        
        // Check if download was requested
        let isToDownload = UserDefaults.standard.bool(forKey: "isToDownload")
        if isToDownload {
            downloadMedia(for: episode)
            UserDefaults.standard.set(false, forKey: "isToDownload")
            return
        }
        
        // Normal playback would be implemented here
        print("Episode selected: \(episode.number)")
        // Implementation would involve preparing player, fetching video URL, etc.
    }
    
    // Download media implementation
    func downloadMedia(for episode: Episode) {
        print("Downloading media for episode \(episode.number)")
        // Implementation would handle the actual download process
    }
    
    // Fetch AniList ID for notifications
    func fetchAniListIDForNotifications() {
        guard let title = animeTitle else { return }
        
        let cleanedTitle = cleanTitle(title)
        AnimeService.fetchAnimeID(byTitle: cleanedTitle) { [weak self] result in
            switch result {
            case .success(let id):
                print("Fetched AniList ID \(id) for notifications")
                // Implementation would schedule notifications
            case .failure(let error):
                print("Error fetching AniList ID for notifications: \(error)")
            }
        }
    }
    
    // Cancel notifications for anime
    func cancelNotificationsForAnime() {
        print("Cancelling notifications for anime")
        // Implementation would remove scheduled notifications
    }
    
    // Handle UserDefaults changes
    @objc func userDefaultsChanged() {
        let newReverseSorted = UserDefaults.standard.bool(forKey: "isEpisodeReverseSorted")
        if newReverseSorted != isReverseSorted {
            isReverseSorted = newReverseSorted
            sortEpisodes()
            tableView.reloadData()
        }
    }
    
    // Handle favorites changes
    @objc func favoritesChanged() {
        checkFavoriteStatus()
    }
    
    // Handle pull-to-refresh
    @objc func handleRefresh() {
        fetchDetailsAndEpisodes()
    }
    
    // Helper to get the base URL based on source
    func getBaseURL(for source: MediaSource, originalHref: String) -> String {
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
}
