import UIKit
import AVKit
import SwiftSoup
import GoogleCast
import SafariServices

class AnimeDetailViewController: UITableViewController, GCKRemoteMediaClientListener, AVPlayerViewControllerDelegate, SynopsisCellDelegate {

    var animeTitle: String?
    var imageUrl: String?
    var href: String?
    var source: String?

    var episodes: [Episode] = []
    var synopsis: String = ""
    var aliases: String = ""
    var airdate: String = ""
    var stars: String = ""

    var player: AVPlayer?
    var playerViewController: AVPlayerViewController?

    var currentEpisodeIndex: Int = -1
    var timeObserverToken: Any?

    var isFavorite: Bool = false
    var isSynopsisExpanded = false
    var isReverseSorted = false
    var hasSentUpdate = false

    var availableQualities: [String] = []
    var qualityOptions: [(name: String, fileName: String)] = []

    // Multi-select properties
    private var isSelectMode = false
    private var selectedEpisodes = Set<Episode>()
    private var downloadButton: UIBarButtonItem!
    private var selectButton: UIBarButtonItem!
    private var cancelButton: UIBarButtonItem!
    private var selectAllButton: UIBarButtonItem!
    private var filterButton: UIBarButtonItem!

    // Store the source enum value
    private var displayedDataSource: MediaSource?

    // MARK: - Initialization
    func configure(title: String, imageUrl: String, href: String, source: String) {
        self.animeTitle = title
        self.href = href
        self.source = source
        self.displayedDataSource = MediaSource(rawValue: source)

        if imageUrl == "https://s4.anilist.co/file/anilistcdn/character/large/default.jpg" && (source == "AniWorld" || source == "TokyoInsider") {
            self.imageUrl = imageUrl // Set temporarily
            fetchImageUrl(source: source, href: href, fallback: imageUrl)
        } else {
            self.imageUrl = imageUrl
        }
    }

    private func fetchImageUrl(source: String, href: String, fallback: String) {
        guard let url = URL(string: href.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? href) else {
            DispatchQueue.main.async { self.imageUrl = fallback }
            return
        }

        let task = URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            guard let self = self, let data = data, let html = String(data: data, encoding: .utf8) else {
                DispatchQueue.main.async { self.imageUrl = fallback }
                return
            }

            do {
                let doc = try SwiftSoup.parse(html)
                var finalImageUrl: String?
                switch source {
                case "AniWorld":
                    if let coverBox = try doc.select("div.seriesCoverBox").first(),
                       let img = try coverBox.select("img").first(),
                       let imgSrc = try? img.attr("data-src") {
                        finalImageUrl = imgSrc.hasPrefix("/") ? "https://aniworld.to\(imgSrc)" : imgSrc
                    }
                case "TokyoInsider":
                    if let img = try doc.select("img.a_img").first(),
                       let imgSrc = try? img.attr("src") {
                        finalImageUrl = imgSrc
                    }
                default:
                    break
                }
                DispatchQueue.main.async {
                    self.imageUrl = finalImageUrl ?? fallback
                    if self.isViewLoaded {
                        self.tableView.reloadSections(IndexSet(integer: 0), with: .none)
                    }
                }
            } catch {
                print("Error extracting image URL: \(error)")
                DispatchQueue.main.async { self.imageUrl = fallback }
            }
        }
        task.resume()
    }

    // MARK: - Lifecycle Methods
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        sortEpisodesIfNeeded()
        tableView.reloadData()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        setupNotifications()
        checkFavoriteStatus()
        setupAudioSession()
        setupMultiSelectUI()
        setupCastButton()

        isReverseSorted = UserDefaults.standard.bool(forKey: "isEpisodeReverseSorted")
        fetchAnimeDetails()

        setupRefreshControl()
    }

    // MARK: - Setup Methods
    private func setupRefreshControl() {
        refreshControl = UIRefreshControl()
        refreshControl?.addTarget(self, action: #selector(handleRefresh), for: .valueChanged)
        tableView.refreshControl = refreshControl
    }

     private func setupCastButton() {
         let castButton = GCKUICastButton(frame: CGRect(x: 0, y: 0, width: 24, height: 24))
         // Add cast button next to the select/edit button
         var rightItems = navigationItem.rightBarButtonItems ?? []
         rightItems.append(UIBarButtonItem(customView: castButton))
         navigationItem.rightBarButtonItems = rightItems
     }

    func setupMultiSelectUI() {
        selectButton = UIBarButtonItem(title: "Select", style: .plain, target: self, action: #selector(toggleSelectMode))
        downloadButton = UIBarButtonItem(title: "Download", style: .plain, target: self, action: #selector(downloadSelectedEpisodes))
        cancelButton = UIBarButtonItem(title: "Cancel", style: .plain, target: self, action: #selector(toggleSelectMode))
        selectAllButton = UIBarButtonItem(title: "Select All", style: .plain, target: self, action: #selector(selectAllEpisodes))
        filterButton = UIBarButtonItem(image: UIImage(systemName: "line.3.horizontal.decrease"), style: .plain, target: self, action: #selector(showFilterOptions))

        // Initial state: show select button (Cast button is added in setupCastButton)
        navigationItem.rightBarButtonItems = [selectButton] // Start with just select
        navigationItem.leftBarButtonItem = nil
    }


    private func setupUI() {
        tableView.backgroundColor = .systemBackground
        tableView.register(AnimeHeaderCell.self, forCellReuseIdentifier: "AnimeHeaderCell")
        tableView.register(SynopsisCell.self, forCellReuseIdentifier: "SynopsisCell")
        tableView.register(EpisodeCell.self, forCellReuseIdentifier: "EpisodeCell")
        tableView.allowsMultipleSelection = true // Enable multiple selection always, managed by isSelectMode flag
        navigationItem.largeTitleDisplayMode = .never
    }

    private func setupNotifications() {
        NotificationCenter.default.addObserver(self, selector: #selector(handleInterruption), name: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance())
        NotificationCenter.default.addObserver(self, selector: #selector(userDefaultsChanged), name: UserDefaults.didChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(favoritesChanged), name: FavoritesManager.favoritesChangedNotification, object: nil) // Observe favorite changes
    }

     private func setupAudioSession() {
         do {
             let audioSession = AVAudioSession.sharedInstance()
             try audioSession.setCategory(.playback, mode: .moviePlayback, options: .mixWithOthers)
             try audioSession.setActive(true)
         } catch {
             print("Failed to set up AVAudioSession: \(error)")
         }
     }

    // MARK: - Data Fetching & Handling
    @objc private func handleRefresh() {
        fetchAnimeDetails()
    }

    private func fetchAnimeDetails() {
         guard let href = href, let source = displayedDataSource else {
             showAlert(title: "Error", message: "Missing anime information.")
             refreshControl?.endRefreshing()
             return
         }

         showLoadingBanner()

         AnimeDetailService.fetchAnimeDetails(from: href) { [weak self] (result) in
             DispatchQueue.main.async {
                 self?.hideLoadingBanner()
                 self?.refreshControl?.endRefreshing()
                 switch result {
                 case .success(let details):
                     self?.updateAnimeDetails(with: details)
                 case .failure(let error):
                     self?.showAlert(title: "Error", message: "Failed to load details: \(error.localizedDescription)")
                 }
             }
         }
     }


    private func updateAnimeDetails(with details: AnimeDetail) {
         aliases = details.aliases
         synopsis = details.synopsis
         airdate = details.airdate
         stars = details.stars
         episodes = details.episodes
         sortEpisodesIfNeeded()
         tableView.reloadData()
         checkFavoriteStatus()
     }


    private func sortEpisodesIfNeeded() {
         if isReverseSorted != UserDefaults.standard.bool(forKey: "isEpisodeReverseSorted") {
             isReverseSorted = UserDefaults.standard.bool(forKey: "isEpisodeReverseSorted")
         }
         sortEpisodes()
     }

    private func sortEpisodes() {
        episodes.sort { isReverseSorted ? $0.episodeNumber > $1.episodeNumber : $0.episodeNumber < $1.episodeNumber }
    }


    // MARK: - UI Actions & Updates
     @objc private func favoritesChanged() {
         checkFavoriteStatus()
         tableView.reloadSections(IndexSet(integer: 0), with: .none)
     }

    @objc private func userDefaultsChanged() {
        let newIsReverseSorted = UserDefaults.standard.bool(forKey: "isEpisodeReverseSorted")
        if newIsReverseSorted != isReverseSorted {
            isReverseSorted = newIsReverseSorted
            sortEpisodes()
            tableView.reloadSections(IndexSet(integer: 2), with: .automatic)
        }
    }

    private func toggleFavorite() {
        isFavorite.toggle()
        if let anime = createFavoriteAnime() {
            if isFavorite {
                FavoritesManager.shared.addFavorite(anime)
                if UserDefaults.standard.bool(forKey: "notificationEpisodes") {
                     fetchAniListIDForNotifications()
                 }
            } else {
                FavoritesManager.shared.removeFavorite(anime)
                 if let title = animeTitle {
                     if let customID = UserDefaults.standard.string(forKey: "customAniListID_\(title)"), let animeID = Int(customID) {
                         AnimeEpisodeService.cancelNotifications(forAnimeID: animeID)
                     } else {
                          let cleanedTitle = cleanTitle(title)
                          fetchAnimeID(title: cleanedTitle) { animeID in
                              AnimeEpisodeService.cancelNotifications(forAnimeID: animeID)
                          }
                     }
                 }
            }
        }
        tableView.reloadSections(IndexSet(integer: 0), with: .none)
    }

    private func createFavoriteAnime() -> FavoriteItem? {
        guard let title = animeTitle,
              let imageURLString = imageUrl, let imageURL = URL(string: imageURLString),
              let contentURLString = href, let contentURL = URL(string: contentURLString),
              let source = displayedDataSource?.rawValue else {
            print("Error: Missing data to create FavoriteItem")
            return nil
        }
        return FavoriteItem(title: title, imageURL: imageURL, contentURL: contentURL, source: source)
    }


    private func checkFavoriteStatus() {
        if let anime = createFavoriteAnime() {
            isFavorite = FavoritesManager.shared.isFavorite(anime)
        }
    }

     private func fetchAniListIDForNotifications() {
         guard let title = animeTitle, UserDefaults.standard.bool(forKey: "notificationEpisodes") else { return }

         let mediaSource = displayedDataSource?.rawValue ?? "Unknown Source"

         if let customID = UserDefaults.standard.string(forKey: "customAniListID_\(title)"), let animeID = Int(customID) {
             AnimeEpisodeService.fetchEpisodesSchedule(animeID: animeID, animeName: title, mediaSource: mediaSource)
             return
         }

         let cleanedTitle = cleanTitle(title)
         fetchAnimeID(title: cleanedTitle) { [weak self] animeID in
              guard let self = self else { return }
              AnimeEpisodeService.fetchEpisodesSchedule(animeID: animeID, animeName: title, mediaSource: mediaSource)
              print("Scheduling notifications for fetched ID: \(animeID)")
          }
     }

    // MARK: - Multi-Select Actions
     @objc private func toggleSelectMode() {
         isSelectMode = !isSelectMode
         selectedEpisodes.removeAll()

         if isSelectMode {
             let castButton = GCKUICastButton(frame: CGRect(x: 0, y: 0, width: 24, height: 24))
             navigationItem.leftBarButtonItems = [selectAllButton, filterButton]
             navigationItem.rightBarButtonItems = [cancelButton, downloadButton, UIBarButtonItem(customView: castButton)]
             downloadButton.isEnabled = false
             tableView.setEditing(false, animated: true)
         } else {
             setupCastButton() // Re-setup original right buttons
             navigationItem.leftBarButtonItems = nil
         }

         tableView.performBatchUpdates({
             let indexPaths = (0..<episodes.count).map { IndexPath(row: $0, section: 2) }
             tableView.reloadRows(at: indexPaths, with: .automatic)
         }, completion: nil)
     }


    @objc private func showFilterOptions() {
        let alertController = UIAlertController(title: "Filter Episodes", message: nil, preferredStyle: .actionSheet)

        let selectUnwatchedAction = UIAlertAction(title: "Select Unwatched", style: .default) { [weak self] _ in self?.selectUnwatchedEpisodes() }
        let selectWatchedAction = UIAlertAction(title: "Select Watched", style: .default) { [weak self] _ in self?.selectWatchedEpisodes() }
        let rangeSelectionAction = UIAlertAction(title: "Select Range", style: .default) { [weak self] _ in self?.showRangeSelectionDialog() }
        let deselectAllAction = UIAlertAction(title: "Deselect All", style: .default) { [weak self] _ in self?.deselectAllEpisodes() }
        let cancelAction = UIAlertAction(title: "Cancel", style: .cancel)

        alertController.addAction(selectUnwatchedAction)
        alertController.addAction(selectWatchedAction)
        alertController.addAction(rangeSelectionAction)
        alertController.addAction(deselectAllAction)
        alertController.addAction(cancelAction)

        if let popoverController = alertController.popoverPresentationController {
            popoverController.barButtonItem = filterButton
        }
        present(alertController, animated: true)
    }

    private func selectUnwatchedEpisodes() {
         selectedEpisodes.removeAll()
         for episode in episodes {
             let lastPlayedTime = UserDefaults.standard.double(forKey: "lastPlayedTime_\(episode.href)")
             let totalTime = UserDefaults.standard.double(forKey: "totalTime_\(episode.href)")
             let progress = (totalTime > 0) ? (lastPlayedTime / totalTime) : 0
             if progress < 0.9 {
                 selectedEpisodes.insert(episode)
             }
         }
         downloadButton.isEnabled = !selectedEpisodes.isEmpty
         tableView.reloadSections(IndexSet(integer: 2), with: .automatic)
     }

     private func selectWatchedEpisodes() {
         selectedEpisodes.removeAll()
         for episode in episodes {
             let lastPlayedTime = UserDefaults.standard.double(forKey: "lastPlayedTime_\(episode.href)")
             let totalTime = UserDefaults.standard.double(forKey: "totalTime_\(episode.href)")
             let progress = (totalTime > 0) ? (lastPlayedTime / totalTime) : 0
             if progress >= 0.9 {
                 selectedEpisodes.insert(episode)
             }
         }
         downloadButton.isEnabled = !selectedEpisodes.isEmpty
         tableView.reloadSections(IndexSet(integer: 2), with: .automatic)
     }


    private func showRangeSelectionDialog() {
        let alertController = UIAlertController(title: "Select Episode Range", message: "Enter start and end episode numbers", preferredStyle: .alert)

        alertController.addTextField { $0.placeholder = "Start Episode"; $0.keyboardType = .numberPad }
        alertController.addTextField { $0.placeholder = "End Episode"; $0.keyboardType = .numberPad }

        let selectAction = UIAlertAction(title: "Select", style: .default) { [weak self, weak alertController] _ in
             guard let self = self,
                   let startText = alertController?.textFields?[0].text, let start = Int(startText),
                   let endText = alertController?.textFields?[1].text, let end = Int(endText),
                   start <= end else {
                 self.showAlert(title: "Error", message: "Please enter a valid episode range.")
                 return
             }
             self.selectEpisodesInRange(start: start, end: end)
         }

        alertController.addAction(selectAction)
        alertController.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alertController, animated: true)
    }


    private func selectEpisodesInRange(start: Int, end: Int) {
        selectedEpisodes.removeAll()
        for episode in episodes {
            let episodeNum = EpisodeNumberExtractor.extract(from: episode.number)
            if episodeNum >= start && episodeNum <= end {
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
        selectedEpisodes = Set(episodes)
        downloadButton.isEnabled = !selectedEpisodes.isEmpty
        tableView.reloadSections(IndexSet(integer: 2), with: .automatic)
    }

    @objc private func downloadSelectedEpisodes() {
        guard !selectedEpisodes.isEmpty else { return }

        showAlert(
            title: "Download Multiple Episodes",
            message: "Do you want to download \(selectedEpisodes.count) selected episodes?",
            actions: [
                UIAlertAction(title: "Cancel", style: .cancel),
                UIAlertAction(title: "Download", style: .default) { [weak self] _ in
                    self?.startBatchDownload()
                }
            ]
        )
    }

    private func startBatchDownload() {
        let episodesToDownload = Array(selectedEpisodes).sorted { $0.episodeNumber < $1.episodeNumber }
        UserDefaults.standard.set(true, forKey: "isToDownload")
        processNextDownload(episodes: episodesToDownload)
        toggleSelectMode()
    }

    private func processNextDownload(episodes: [Episode], index: Int = 0) {
         guard index < episodes.count else {
             showAlert(title: "Downloads Queued", message: "All selected episodes have been queued for download.")
             UserDefaults.standard.set(false, forKey: "isToDownload")
             return
         }

         let episode = episodes[index]
         let dummyCell = EpisodeCell()
         dummyCell.episodeNumber = episode.number

         episodeSelected(episode: episode, cell: dummyCell)

         DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
             self?.processNextDownload(episodes: episodes, index: index + 1)
         }
     }

    // MARK: - Menu Actions
    private func showOptionsMenu() {
        let alertController = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)

        let trackingServicesAction = UIAlertAction(title: "Tracking Services", style: .default) { [weak self] _ in self?.fetchAnimeIDAndMappings() }
        trackingServicesAction.setValue(UIImage(systemName: "list.bullet"), forKey: "image")
        alertController.addAction(trackingServicesAction)

        let advancedSettingsAction = UIAlertAction(title: "Advanced Settings", style: .default) { [weak self] _ in self?.showAdvancedSettingsMenu() }
        advancedSettingsAction.setValue(UIImage(systemName: "gear"), forKey: "image")
        alertController.addAction(advancedSettingsAction)

        let anilistInfoAction = UIAlertAction(title: "AniList Info", style: .default) { [weak self] _ in
             guard let self = self else { return }
             let cleanedTitle = self.cleanTitle(self.animeTitle ?? "Title")
             self.fetchAndNavigateToAnime(title: cleanedTitle)
         }
         anilistInfoAction.setValue(UIImage(systemName: "info.circle"), forKey: "image")
         alertController.addAction(anilistInfoAction)

        if let source = displayedDataSource, source != .anilibria {
             let openOnWebAction = UIAlertAction(title: "Open in Web", style: .default) { [weak self] _ in self?.openAnimeOnWeb() }
             openOnWebAction.setValue(UIImage(systemName: "safari"), forKey: "image")
             alertController.addAction(openOnWebAction)
         }

        alertController.addAction(UIAlertAction(title: "Cancel", style: .cancel))

        if let popoverController = alertController.popoverPresentationController {
             if let headerCell = tableView.cellForRow(at: IndexPath(row: 0, section: 0)) as? AnimeHeaderCell {
                  popoverController.sourceView = headerCell.optionsButton // Anchor to the options button
                  popoverController.sourceRect = headerCell.optionsButton.bounds
                  popoverController.permittedArrowDirections = .up
              } else {
                  popoverController.sourceView = self.view
                  popoverController.sourceRect = CGRect(x: self.view.bounds.midX, y: self.view.bounds.minY + 50, width: 0, height: 0)
                  popoverController.permittedArrowDirections = [.up, .down]
              }
         }

        present(alertController, animated: true)
    }

    private func fetchAnimeIDAndMappings() {
        guard let title = self.animeTitle else {
            self.showAlert(title: "Error", message: "Anime title is not available.")
            return
        }
        let cleanedTitle = cleanTitle(title)
        fetchAnimeID(title: cleanedTitle) { [weak self] animeID in
             self?.fetchMappingsAndShowOptions(animeID: animeID)
         }
    }


    private func fetchMappingsAndShowOptions(animeID: Int) {
        let urlString = "https://api.ani.zip/mappings?anilist_id=\(animeID)"
        guard let url = URL(string: urlString) else { return }

        let task = URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            guard let self = self, let data = data, error == nil else {
                DispatchQueue.main.async { self?.showAlert(title: "Error", message: "Unable to fetch mappings.") }
                return
            }

            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let mappings = json["mappings"] as? [String: Any] {
                    DispatchQueue.main.async {
                        self.showTrackingOptions(mappings: mappings)
                    }
                } else {
                     DispatchQueue.main.async {
                          self.showAlert(title: "Error", message: "No mappings found for this anime.")
                      }
                 }
            } catch {
                DispatchQueue.main.async {
                    self.showAlert(title: "Error", message: "Unable to parse mappings.")
                }
            }
        }
        task.resume()
    }

    private func showTrackingOptions(mappings: [String: Any]) {
         let alertController = UIAlertController(title: "Tracking Services", message: nil, preferredStyle: .actionSheet)
         let blacklist: Set<String> = ["type", "anilist_id", "themoviedb_id", "thetvdb_id"]
         let filteredMappings = mappings.filter { !blacklist.contains($0.key) }
         let sortedMappings = filteredMappings.sorted { $0.key < $1.key }

         guard !sortedMappings.isEmpty else {
             showAlert(title: "No Services", message: "No additional tracking services found.")
             return
         }

         for (key, value) in sortedMappings {
             let formattedServiceName = key.replacingOccurrences(of: "_id", with: "").capitalized
             if let id = value as? String ?? (value as? Int).map(String.init) {
                 let action = UIAlertAction(title: formattedServiceName, style: .default) { [weak self] _ in
                     self?.openTrackingServiceURL(for: key, id: id)
                 }
                 alertController.addAction(action)
             }
         }

         alertController.addAction(UIAlertAction(title: "Cancel", style: .cancel))

         if UIDevice.current.userInterfaceIdiom == .pad {
              alertController.modalPresentationStyle = .popover
              if let popoverController = alertController.popoverPresentationController {
                  popoverController.sourceView = self.view
                  popoverController.sourceRect = CGRect(x: self.view.bounds.midX, y: self.view.bounds.midY, width: 0, height: 0)
                  popoverController.permittedArrowDirections = []
              }
          }

         present(alertController, animated: true)
     }

    private func openTrackingServiceURL(for service: String, id: String) {
        let prefixMap: [String: String] = [
            "animeplanet_id": "https://animeplanet.com/anime/",
            "kitsu_id": "https://kitsu.io/anime/",
            "mal_id": "https://myanimelist.net/anime/",
            "anisearch_id": "https://anisearch.com/anime/",
            "anidb_id": "https://anidb.net/anime/",
            "notifymoe_id": "https://notify.moe/anime/",
            "livechart_id": "https://livechart.me/anime/",
            "imdb_id": "https://www.imdb.com/title/"
        ]

        guard let prefix = prefixMap[service] else {
            showAlert(title: "Error", message: "Unknown tracking service: \(service)")
            return
        }

        let urlString = "\(prefix)\(id)"
        if let url = URL(string: urlString) {
            presentSafari(url: url)
        } else {
             showAlert(title: "Error", message: "Invalid URL: \(urlString)")
         }
    }

    private func showAdvancedSettingsMenu() {
        let alertController = UIAlertController(title: "Advanced Settings", message: nil, preferredStyle: .actionSheet)

        let customAniListIDAction = UIAlertAction(title: "Custom AniList ID", style: .default) { [weak self] _ in self?.customAniListID() }
        customAniListIDAction.setValue(UIImage(systemName: "pencil"), forKey: "image")
        alertController.addAction(customAniListIDAction)

        alertController.addAction(UIAlertAction(title: "Cancel", style: .cancel))

        if UIDevice.current.userInterfaceIdiom == .pad {
             alertController.modalPresentationStyle = .popover
             if let popoverController = alertController.popoverPresentationController {
                 popoverController.sourceView = self.view
                 popoverController.sourceRect = CGRect(x: self.view.bounds.midX, y: self.view.bounds.midY, width: 0, height: 0)
                 popoverController.permittedArrowDirections = []
             }
         }

        present(alertController, animated: true)
    }

    private func customAniListID() {
         guard let currentTitle = self.animeTitle else { return }

        let alert = UIAlertController(title: "Custom AniList ID", message: "Enter a custom AniList ID for this anime:", preferredStyle: .alert)

        alert.addTextField { textField in
            textField.placeholder = "AniList ID"
            textField.keyboardType = .numberPad
            textField.text = UserDefaults.standard.string(forKey: "customAniListID_\(currentTitle)")
        }

        let saveAction = UIAlertAction(title: "Save", style: .default) { [weak self] _ in
             if let textField = alert.textFields?.first, let customID = textField.text, !customID.isEmpty, Int(customID) != nil {
                 UserDefaults.standard.setValue(customID, forKey: "customAniListID_\(currentTitle)")
                 self?.showAlert(title: "Success", message: "Custom AniList ID saved.")
                 if UserDefaults.standard.bool(forKey: "notificationEpisodes") {
                     self?.fetchAniListIDForNotifications()
                 }
             } else {
                 self?.showAlert(title: "Error", message: "Please enter a valid AniList ID (numbers only).")
             }
         }


        let revertAction = UIAlertAction(title: "Clear Custom ID", style: .destructive) { [weak self] _ in
             UserDefaults.standard.removeObject(forKey: "customAniListID_\(currentTitle)")
             self?.showAlert(title: "Reverted", message: "The custom AniList ID has been cleared.")
             if UserDefaults.standard.bool(forKey: "notificationEpisodes") {
                  self?.fetchAniListIDForNotifications()
              }
         }

        alert.addAction(saveAction)
        alert.addAction(revertAction)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }


    private func openAnimeOnWeb() {
        guard let path = href, let source = displayedDataSource else {
            showAlert(title: "Error", message: "Anime information is incomplete.")
            return
        }

        let baseUrl: String
        switch source {
        case .animeWorld: baseUrl = "https://animeworld.so"
        case .gogoanime: baseUrl = "https://anitaku.bz"
        case .animeheaven: baseUrl = "https://animeheaven.me/"
        case .anilist: baseUrl = "https://hianime.to/watch/" // Base watch URL
        case .animefire: baseUrl = "https://animefire.plus"
        case .anilibria:
             baseUrl = "https://anilibria.tv/release/"
              if let _ = Int(path) {
                   let urlString = "\(baseUrl)\(path).html"
                   if let url = URL(string: urlString) { presentSafari(url: url); return }
              } else if let url = URL(string: path), path.contains("anilibria") {
                   presentSafari(url: url); return
              }
              showAlert(title: "Error", message: "Cannot determine Anilibria web URL.")
              return
         // Assume other sources include base URL in href or don't need one
         case .kuramanime, .anime3rb, .animesrbija, .aniworld, .tokyoinsider, .anivibe, .animeunity, .animeflv, .animebalkan, .anibunker:
            baseUrl = ""
         }

        let fullUrlString: String
        if !baseUrl.isEmpty && !path.hasPrefix("http") {
            fullUrlString = baseUrl + (path.hasPrefix("/") ? path : "/\(path)")
        } else {
            fullUrlString = path
        }


        guard let url = URL(string: fullUrlString) else {
            showAlert(title: "Error", message: "Invalid URL: \(fullUrlString)")
            return
        }
        presentSafari(url: url)
    }

     private func presentSafari(url: URL) {
         let safariViewController = SFSafariViewController(url: url)
         present(safariViewController, animated: true)
     }


    private func fetchAndNavigateToAnime(title: String) {
        if let animeTitle = self.animeTitle,
           let customIDString = UserDefaults.standard.string(forKey: "customAniListID_\(animeTitle)"),
           let customID = Int(customIDString) {
            navigateToAnimeDetail(for: customID)
            return
        }

         fetchAnimeID(title: title) { [weak self] animeID in
             // Check if ID is valid (not 0 which indicates failure)
              guard animeID != 0 else {
                  self?.showAlert(title: "Not Found", message: "Could not find this anime on AniList.")
                  return
              }
              self?.navigateToAnimeDetail(for: animeID)
          }
    }


    private func navigateToAnimeDetail(for animeID: Int) {
         DispatchQueue.main.async {
             let storyboard = UIStoryboard(name: "AnilistAnimeInformation", bundle: nil)
             if let animeDetailVC = storyboard.instantiateViewController(withIdentifier: "AnimeInformation") as? AnimeInformation {
                 animeDetailVC.animeID = animeID
                 self.navigationController?.pushViewController(animeDetailVC, animated: true)
             }
         }
     }

    func showAlert(title: String, message: String) {
        let alertController = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alertController.addAction(UIAlertAction(title: "OK", style: .default, handler: nil))
        DispatchQueue.main.async {
            var topController = UIApplication.shared.windows.filter {$0.isKeyWindow}.first?.rootViewController
            while let presentedViewController = topController?.presentedViewController {
                topController = presentedViewController
            }
            topController?.present(alertController, animated: true, completion: nil)
        }
    }


    // MARK: - TableView DataSource & Delegate
    override func numberOfSections(in tableView: UITableView) -> Int { 3 }
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
            guard indexPath.row < episodes.count else { return cell }
            let episode = episodes[indexPath.row]
            cell.configure(episode: episode, delegate: self)
            cell.loadSavedProgress(for: episode.href)
            cell.setSelectionMode(isSelectMode, isSelected: selectedEpisodes.contains(episode))
            return cell
        default: return UITableViewCell()
        }
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.section == 2 {
            guard indexPath.row < episodes.count else { return }
            let episode = episodes[indexPath.row]
            if isSelectMode {
                if selectedEpisodes.contains(episode) { selectedEpisodes.remove(episode) }
                else { selectedEpisodes.insert(episode) }
                downloadButton.isEnabled = !selectedEpisodes.isEmpty
                tableView.reloadRows(at: [indexPath], with: .automatic)
            } else {
                if let cell = tableView.cellForRow(at: indexPath) as? EpisodeCell {
                    episodeSelected(episode: episode, cell: cell)
                }
            }
        }
    }
    override func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) { cell.backgroundColor = .systemBackground }
    override func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat { UITableView.automaticDimension }
    override func tableView(_ tableView: UITableView, estimatedHeightForRowAt indexPath: IndexPath) -> CGFloat {
        switch indexPath.section {
        case 0: return 230
        case 1: return 100
        case 2: return 60
        default: return 44
        }
    }

    // MARK: - Episode Selection & Playback
     func episodeSelected(episode: Episode, cell: EpisodeCell) {
         showLoadingBanner()
         self.currentEpisodeIndex = episodes.firstIndex(where: { $0.href == episode.href }) ?? -1

         guard let selectedSource = displayedDataSource else {
             hideLoadingBannerAndShowAlert(title: "Error", message: "Source information missing.")
             return
         }

         let url = episode.href // URL to process
         let fullURLForTracking = episode.href // URL for saving progress

         checkUserDefault(url: url, cell: cell, fullURL: fullURLForTracking)
     }

    // MARK: - Loading Banner
    func showLoadingBanner() {
        #if os(iOS)
         guard presentedViewController as? UIAlertController == nil else { return }
        let alert = UIAlertController(title: nil, message: "Extracting Video", preferredStyle: .alert)
        alert.view.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        alert.view.layer.cornerRadius = 15
        let loadingIndicator = UIActivityIndicatorView(frame: CGRect(x: 10, y: 5, width: 50, height: 50))
        loadingIndicator.hidesWhenStopped = true
        loadingIndicator.style = .medium
        loadingIndicator.startAnimating();
        alert.view.addSubview(loadingIndicator)
        loadingIndicator.center = CGPoint(x: alert.view.bounds.midX, y: alert.view.bounds.midY - 10)
        present(alert, animated: true, completion: nil)
        #endif
    }

    // MARK: - Player Handling
    func checkUserDefault(url: String, cell: EpisodeCell, fullURL: String) {
        if UserDefaults.standard.bool(forKey: "isToDownload") {
            playEpisode(url: url, cell: cell, fullURL: fullURL)
        } else if UserDefaults.standard.bool(forKey: "browserPlayer") {
            openInWeb(fullURL: url)
        } else {
            playEpisode(url: url, cell: cell, fullURL: fullURL)
        }
    }

    @objc private func openInWeb(fullURL: String) {
        hideLoadingBanner {
            guard let source = self.displayedDataSource else {
                 self.showAlert(title: "Error", message: "Source information missing.")
                 return
             }
            let selectedMediaSource = source.rawValue

            switch selectedMediaSource {
            case "AniList": // Renamed
                if let extractedID = self.extractAniListEpisodeId(from: fullURL) {
                    let hiAnimeWatchURL = "https://hianime.to/watch/\(extractedID)"
                    self.openSafariViewController(with: hiAnimeWatchURL)
                } else {
                    self.showAlert(title: "Error", message: "Unable to extract episode ID for web view.")
                }
            case "Anilibria":
                self.showAlert(title: "Unsupported Function", message: "Anilibria doesn't support playing in web directly from episode links.")
            default:
                self.openSafariViewController(with: fullURL)
            }
        }
    }

    private func openSafariViewController(with urlString: String) {
        guard let url = URL(string: urlString) else {
            showAlert(title: "Error", message: "Unable to open the webpage. Invalid URL.")
            return
        }
        let safariViewController = SFSafariViewController(url: url)
        present(safariViewController, animated: true, completion: nil)
    }

    @objc func startStreamingButtonTapped(withURL url: String, captionURL: String, playerType: String, cell: EpisodeCell, fullURL: String) {
        deleteWebKitFolder()
        presentStreamingView(withURL: url, captionURL: captionURL, playerType: playerType, cell: cell, fullURL: fullURL)
    }

    func playEpisode(url: String, cell: EpisodeCell, fullURL: String) {
         hasSentUpdate = false

         guard let selectedSource = displayedDataSource else {
             hideLoadingBannerAndShowAlert(title: "Error", message: "Source information missing.")
             return
         }

         if selectedSource == .anilist { // Renamed from HiAnime
             handleHiAnimeSource(url: url, cell: cell, fullURL: fullURL) // Use the existing logic (needs rename later if API changes)
         } else if url.hasSuffix(".mp4") || url.hasSuffix(".m3u8") || url.contains("animeheaven.me/video.mp4") || selectedSource == .anilibria {
             hideLoadingBanner { [weak self] in
                 guard let videoURL = URL(string: url) else {
                      self?.showAlert(title: "Error", message: "Invalid video URL.")
                      return
                  }
                 self?.playVideo(sourceURL: videoURL, cell: cell, fullURL: fullURL)
             }
          }
          else {
             handleSources(url: url, cell: cell, fullURL: fullURL)
         }
     }


    func hideLoadingBanner(completion: (() -> Void)? = nil) {
        DispatchQueue.main.async {
            if let alert = self.presentedViewController as? UIAlertController, alert.message == "Extracting Video" {
                alert.dismiss(animated: true) { completion?() }
            } else {
                completion?()
            }
        }
    }

    func presentStreamingView(withURL url: String, captionURL: String, playerType: String, cell: EpisodeCell, fullURL: String) {
        hideLoadingBanner { [weak self] in
            guard let self = self else { return }
            DispatchQueue.main.async {
                var streamingVC: UIViewController?
                switch playerType {
                case VideoPlayerType.standard: streamingVC = ExternalVideoPlayer(streamURL: url, cell: cell, fullURL: fullURL, animeDetailsViewController: self)
                case VideoPlayerType.player3rb: streamingVC = ExternalVideoPlayer3rb(streamURL: url, cell: cell, fullURL: fullURL, animeDetailsViewController: self)
                case VideoPlayerType.playerKura: streamingVC = ExternalVideoPlayerKura(streamURL: url, cell: cell, fullURL: fullURL, animeDetailsViewController: self)
                case VideoPlayerType.playerGoGo2: streamingVC = ExternalVideoPlayerGoGo2(streamURL: url, cell: cell, fullURL: fullURL, animeDetailsViewController: self)
                case VideoPlayerType.playerWeb: streamingVC = WebPlayer(streamURL: url, captionURL: captionURL, cell: cell, fullURL: fullURL, animeDetailsViewController: self)
                default:
                    print("Error: Unknown player type requested: \(playerType)")
                    self.showAlert(title: "Player Error", message: "Unknown player type selected.")
                    return
                }
                if let vc = streamingVC {
                     vc.modalPresentationStyle = .fullScreen
                     self.present(vc, animated: true, completion: nil)
                 }
            }
        }
    }

    func deleteWebKitFolder() {
        if let libraryPath = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first {
            let webKitFolderPath = libraryPath.appendingPathComponent("WebKit")
            do {
                if FileManager.default.fileExists(atPath: webKitFolderPath.path) {
                    try FileManager.default.removeItem(at: webKitFolderPath)
                    print("Successfully deleted the WebKit folder.")
                } else {
                    print("The WebKit folder does not exist.")
                }
            } catch {
                print("Error deleting the WebKit folder: \(error.localizedDescription)")
            }
        } else {
            print("Could not find the Library directory.")
        }
    }

    private func handleHiAnimeSource(url: String, cell: EpisodeCell, fullURL: String) { // Keep internal name for now
         guard let episodeId = extractAniListEpisodeId(from: url) else { // Use renamed function
             print("Could not extract episodeId from URL")
             hideLoadingBannerAndShowAlert(title: "Error", message: "Could not extract episodeId from URL")
             return
         }

         fetchAniListEpisodeOptions(episodeId: episodeId) { [weak self] options in // Use renamed function
             guard let self = self else { return }

             if options.isEmpty {
                 print("No options available for this episode")
                 self.hideLoadingBannerAndShowAlert(title: "Error", message: "No options available for this episode")
                 return
             }

             let preferredAudio = UserDefaults.standard.string(forKey: "anilistAudioPref") ?? "" // Updated key
             let preferredServer = UserDefaults.standard.string(forKey: "anilistServerPref") ?? "" // Updated key

             self.selectAudioCategory(options: options, preferredAudio: preferredAudio) { category in
                 guard let servers = options[category], !servers.isEmpty else {
                     print("No servers available for selected category: \(category)")
                     self.hideLoadingBannerAndShowAlert(title: "Error", message: "No servers available for '\(category.capitalized)' audio.")
                     return
                 }

                 self.selectServer(servers: servers, preferredServer: preferredServer) { server in
                     let urls = ["https://aniwatch-api-gp1w.onrender.com/anime/episode-srcs?id="] // Use provided logic's URL
                     let randomURL = urls.randomElement()!
                     let finalURL = "\(randomURL)\(episodeId)&category=\(category)&server=\(server)"

                     self.fetchAniListData(from: finalURL) { [weak self] sourceURL, captionURLs in // Use renamed function
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
                                     self.openHiAnimeExperimental(url: sourceURL, subURL: subtitleURL, cell: cell, fullURL: fullURL)
                                 }
                             }
                         }
                     }
                 }
             }
         }
     }


    func hideLoadingBannerAndShowAlert(title: String, message: String) {
        #if os(iOS)
        hideLoadingBanner { [weak self] in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.showAlert(title: title, message: message)
            }
        }
        #endif
    }

    private func handleSources(url: String, cell: EpisodeCell, fullURL: String) {
         guard let requestURL = encodedURL(from: url) else {
             DispatchQueue.main.async {
                 self.hideLoadingBanner()
                 self.showAlert(title: "Error", message: "Invalid URL: \(url)")
             }
             return
         }

         URLSession.shared.dataTask(with: requestURL) { [weak self] (data, response, error) in
             guard let self = self else { return }

             DispatchQueue.main.async {
                 if let error = error {
                     self.hideLoadingBanner()
                     self.showAlert(title: "Error", message: "Error fetching video data: \(error.localizedDescription)")
                     return
                 }

                 guard let data = data, let htmlString = String(data: data, encoding: .utf8) else {
                     self.hideLoadingBanner()
                     self.showAlert(title: "Error", message: "Error parsing video data")
                     return
                 }

                 guard let selectedSource = self.displayedDataSource else {
                      self.hideLoadingBanner()
                      self.showAlert(title: "Error", message: "Source information missing.")
                      return
                  }

                 let gogoFetcher = UserDefaults.standard.string(forKey: "gogoFetcher") ?? "Default"
                 var srcURL: URL?

                 switch selectedSource {
                 case .gogoanime:
                     if gogoFetcher == "Default" { srcURL = self.extractIframeSourceURL(from: htmlString) }
                     else if gogoFetcher == "Secondary" { srcURL = self.extractDownloadLink(from: htmlString) }
                 case .animefire: srcURL = self.extractDataVideoSrcURL(from: htmlString)
                 case .animeWorld, .animeheaven, .animebalkan: srcURL = self.extractVideoSourceURL(from: htmlString)
                 case .kuramanime: srcURL = URL(string: fullURL) // Pass original for its player
                 case .animesrbija: srcURL = self.extractAsgoldURL(from: htmlString)
                 case .anime3rb:
                      self.anime3rbGetter(from: htmlString) { finalUrl in
                           if let url = finalUrl { self.hideLoadingBanner { self.playVideo(sourceURL: url, cell: cell, fullURL: fullURL) } }
                           else { self.hideLoadingBannerAndShowAlert(title: "Error", message: "Error extracting source URL for Anime3rb") }
                      }
                      return
                  case .anivibe: srcURL = self.extractAniVibeURL(from: htmlString)
                  case .anibunker: srcURL = self.extractAniBunker(from: htmlString)
                  case .tokyoinsider:
                       self.extractTokyoVideo(from: htmlString) { selectedURL in
                            DispatchQueue.main.async {
                                self.hideLoadingBanner { self.playVideo(sourceURL: selectedURL, cell: cell, fullURL: fullURL) }
                            }
                        }
                        return
                   case .aniworld:
                        self.extractVidozaVideoURL(from: htmlString) { videoURL in
                            guard let finalURL = videoURL else {
                                self.hideLoadingBannerAndShowAlert(title: "Error", message: "Error extracting source URL for AniWorld")
                                return
                            }
                            DispatchQueue.main.async {
                                self.hideLoadingBanner { self.playVideo(sourceURL: finalURL, cell: cell, fullURL: fullURL) }
                            }
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
                    // Anilist and Anilibria handled earlier
                    case .anilist, .anilibria:
                        print("Should not reach handleSources for Anilist/Anilibria")
                        self.hideLoadingBannerAndShowAlert(title: "Internal Error", message: "Source handling error.")
                        return
                   }

                 guard let finalSrcURL = srcURL else {
                     self.hideLoadingBannerAndShowAlert(title: "Error", message: "The stream URL wasn't found.")
                     return
                 }

                 self.hideLoadingBanner {
                     DispatchQueue.main.async {
                         switch selectedSource {
                         case .gogoanime:
                             let playerType = gogoFetcher == "Secondary" ? VideoPlayerType.standard : VideoPlayerType.playerGoGo2
                             self.startStreamingButtonTapped(withURL: finalSrcURL.absoluteString, captionURL: "", playerType: playerType, cell: cell, fullURL: fullURL)
                         case .animefire:
                              self.fetchVideoDataAndChooseQuality(from: finalSrcURL.absoluteString) { selectedURL in
                                   guard let selectedURL = selectedURL else {
                                       self.showAlert(title: "Error", message: "Failed to fetch video data for AnimeFire")
                                       return
                                   }
                                   self.playVideo(sourceURL: selectedURL, cell: cell, fullURL: fullURL)
                               }
                          case .kuramanime:
                              self.startStreamingButtonTapped(withURL: finalSrcURL.absoluteString, captionURL: "", playerType: VideoPlayerType.playerKura, cell: cell, fullURL: fullURL)
                         default:
                              self.playVideo(sourceURL: finalSrcURL, cell: cell, fullURL: fullURL)
                          }
                     }
                 }
             }
         }.resume()
     }

    // encodedURL remains the same
    func encodedURL(from urlString: String) -> URL? {
        let allowedCharacters = CharacterSet.urlQueryAllowed
        guard let encodedString = urlString.addingPercentEncoding(withAllowedCharacters: allowedCharacters) else { return nil }
        return URL(string: encodedString)
    }

    // MARK: - Casting
    private func proceedWithCasting(videoURL: URL) {
        DispatchQueue.main.async {
            let metadata = GCKMediaMetadata(metadataType: .movie)

            if UserDefaults.standard.bool(forKey: "fullTitleCast") {
                 metadata.setString(self.animeTitle ?? "Unknown Anime", forKey: kGCKMetadataKeyTitle)
             } else {
                 let episodeNumber = EpisodeNumberExtractor.extract(from: self.cell.episodeNumber)
                 metadata.setString("Episode \(episodeNumber)", forKey: kGCKMetadataKeyTitle)
             }

            if UserDefaults.standard.bool(forKey: "animeImageCast"), let imageURL = URL(string: self.imageUrl ?? "") {
                metadata.addImage(GCKImage(url: imageURL, width: 480, height: 720))
            }

            let builder = GCKMediaInformationBuilder(contentURL: videoURL)

            let contentType: String
            let urlString = videoURL.absoluteString.lowercased()
            if urlString.contains(".m3u8") { contentType = "application/x-mpegurl" }
            else if urlString.contains(".mp4") { contentType = "video/mp4" }
            else { contentType = "video/mp4" } // Default
            builder.contentType = contentType
            builder.metadata = metadata

            let streamTypeString = UserDefaults.standard.string(forKey: "castStreamingType") ?? "buffered"
            builder.streamType = (streamTypeString == "live") ? .live : .buffered

            let mediaInformation = builder.build()
            let mediaLoadOptions = GCKMediaLoadOptions()
            mediaLoadOptions.autoplay = true

            let lastPlayedTime = UserDefaults.standard.double(forKey: "lastPlayedTime_\(self.fullURL)")
            mediaLoadOptions.playPosition = lastPlayedTime > 0 ? lastPlayedTime : 0

            if let castSession = GCKCastContext.sharedInstance().sessionManager.currentCastSession,
               let remoteMediaClient = castSession.remoteMediaClient {
                remoteMediaClient.loadMedia(mediaInformation, with: mediaLoadOptions)
                remoteMediaClient.add(self)
            } else {
                 print("Error: Failed to load media to Google Cast - No session")
                 self.showAlert(title: "Cast Error", message: "No active Chromecast session found.")
             }
        }
    }

    func remoteMediaClient(_ client: GCKRemoteMediaClient, didUpdate mediaStatus: GCKMediaStatus?) {
        if let mediaStatus = mediaStatus, mediaStatus.idleReason == .finished {
            if UserDefaults.standard.bool(forKey: "AutoPlay") {
                DispatchQueue.main.async { [weak self] in
                    self?.playNextEpisode()
                }
            }
        }
    }

    // MARK: - Playback & External Players
    func playVideo(sourceURL: URL, cell: EpisodeCell, fullURL: String) {
         hideLoadingBanner() // Ensure banner is hidden before playback decision
         let selectedPlayer = UserDefaults.standard.string(forKey: "mediaPlayerSelected") ?? "Default"
         let isToDownload = UserDefaults.standard.bool(forKey: "isToDownload")

         if isToDownload {
             handleDownload(sourceURL: sourceURL, fullURL: fullURL)
         } else {
              DispatchQueue.main.async { // Ensure player presentation is on main thread
                  self.playVideoWithSelectedPlayer(player: selectedPlayer, sourceURL: sourceURL, cell: cell, fullURL: fullURL)
              }
          }
     }


    private func handleDownload(sourceURL: URL, fullURL: String) {
        UserDefaults.standard.set(false, forKey: "isToDownload")

        guard let episode = episodes.first(where: { $0.href == fullURL }) else {
            print("Error: Could not find episode for URL \(fullURL) to download.")
            showAlert(title: "Download Error", message: "Could not find episode details for download.")
            return
        }

        let downloadManager = DownloadManager.shared
        let title = "\(self.animeTitle ?? "Anime") - Ep. \(episode.number)"

        // Optionally show a less intrusive confirmation or just start
         self.showAlert(title: "Download Started", message: "'\(title)' download has begun.")

        downloadManager.startDownload(url: sourceURL, title: title, progress: { progress in
            // Update UI elsewhere if needed, e.g., a global download manager view
        }) { [weak self] result in
             DispatchQueue.main.async {
                 self?.handleDownloadResult(result) // Handle completion (success/failure)
             }
         }
    }


    private func handleDownloadResult(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            print("Download completed. File saved at: \(url)")
            // Optionally show a success alert here if needed
        case .failure(let error):
            print("Download failed with error: \(error.localizedDescription)")
            showAlert(title: "Download Failed", message: error.localizedDescription)
        }
    }

    private func playVideoWithSelectedPlayer(player: String, sourceURL: URL, cell: EpisodeCell, fullURL: String) {
         switch player {
         case "Infuse", "VLC", "OutPlayer", "nPlayer":
             openInExternalPlayer(player: player, url: sourceURL)
         case "Custom":
             let fileExtension = sourceURL.pathExtension.lowercased()
             if ["mkv", "avi"].contains(fileExtension) {
                  showAlert(title: "Unsupported Format", message: "The Custom Player does not support '\(fileExtension)' files. Please use an external player like VLC, Infuse, or Outplayer (setup in Settings).")
                  return
              }
             let videoTitle = animeTitle ?? "Anime"
             let imageURL = imageUrl ?? "https://s4.anilist.co/file/anilistcdn/character/large/default.jpg"
             let viewController = CustomPlayerView(videoTitle: videoTitle, videoURL: sourceURL, cell: cell, fullURL: fullURL, image: imageURL)
             viewController.modalPresentationStyle = .fullScreen
             viewController.delegate = self
             self.present(viewController, animated: true, completion: nil)
         case "WebPlayer":
              // Assuming WebPlayer is primarily for HiAnime/Anilist which provides caption URL
              // For other sources, pass an empty caption URL or fetch if possible
              let captionURLString = "" // Modify if captions are available for this source/URL
             startStreamingButtonTapped(withURL: sourceURL.absoluteString, captionURL: captionURLString, playerType: VideoPlayerType.playerWeb, cell: cell, fullURL: fullURL)
         default: // "Default" player
             playVideoWithAVPlayer(sourceURL: sourceURL, cell: cell, fullURL: fullURL)
         }
     }

    func openInExternalPlayer(player: String, url: URL) {
        let schemeMap: [String: String] = [
            "Infuse": "infuse://x-callback-url/play?url=", "VLC": "vlc://",
            "OutPlayer": "outplayer://", "nPlayer": "nplayer-"
        ]
        guard let baseScheme = schemeMap[player] else {
            showAlert(title: "Error", message: "Unsupported player selected.")
            return
        }

        let finalURLString: String
         if player == "nPlayer" {
             let urlStringWithoutScheme = url.absoluteString.replacingOccurrences(of: "http://", with: "").replacingOccurrences(of: "https://", with: "")
             finalURLString = baseScheme + urlStringWithoutScheme
         } else if player == "VLC" {
             guard let encodedURL = url.absoluteString.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) else {
                  showAlert(title: "Error", message: "Could not encode URL for VLC.")
                  return
              }
             finalURLString = baseScheme + encodedURL
         } else {
             finalURLString = baseScheme + url.absoluteString
         }

        guard let playerURL = URL(string: finalURLString) else {
            showAlert(title: "Error", message: "Failed to create URL for \(player).")
            return
        }

        if UIApplication.shared.canOpenURL(playerURL) {
            UIApplication.shared.open(playerURL, options: [:]) { success in
                 if !success { self.showAlert(title: "Error", message: "Could not open \(player).") }
            }
        } else {
            showAlert(title: "\(player) Not Found", message: "The \(player) app is not installed.")
        }
    }

    func openHiAnimeExperimental(url: URL, subURL: URL, cell: EpisodeCell, fullURL: String) { // Keep internal name
        let videoTitle = animeTitle ?? "Anime"
        let imageURL = imageUrl ?? "https://s4.anilist.co/file/anilistcdn/character/large/default.jpg"
        let viewController = CustomPlayerView(videoTitle: videoTitle, videoURL: url, subURL: subURL, cell: cell, fullURL: fullURL, image: imageURL)
        viewController.modalPresentationStyle = .fullScreen
        viewController.delegate = self
        self.present(viewController, animated: true, completion: nil)
    }

    private func playVideoWithAVPlayer(sourceURL: URL, cell: EpisodeCell, fullURL: String) {
         let fileExtension = sourceURL.pathExtension.lowercased()
         if ["mkv", "avi"].contains(fileExtension) {
              showAlert(title: "Unsupported Format", message: "The default player cannot play '\(fileExtension)' files. Please use an external player.")
              return
          }

         if GCKCastContext.sharedInstance().castState == .connected {
             proceedWithCasting(videoURL: sourceURL)
         } else {
             cleanupPlayer() // Clean up before presenting new player

             player = AVPlayer(url: sourceURL)
             playerViewController = NormalPlayer()
             playerViewController?.player = player
             playerViewController?.delegate = self // Set delegate for PiP
             // playerViewController?.entersFullScreenWhenPlaybackBegins = true // Often default behavior
             // playerViewController?.showsPlaybackControls = true // Default is true

             let lastPlayedTime = UserDefaults.standard.double(forKey: "lastPlayedTime_\(fullURL)")

             playerViewController?.modalPresentationStyle = .fullScreen
             present(playerViewController!, animated: true) {
                 if lastPlayedTime > 0 {
                     let seekTime = CMTime(seconds: lastPlayedTime, preferredTimescale: 1)
                     self.player?.seek(to: seekTime) { [weak self] _ in // Use weak self
                         self?.player?.play()
                     }
                 } else {
                     self.player?.play()
                 }
                 self.addPeriodicTimeObserver(cell: cell, fullURL: fullURL) // Add observer after presenting
             }
             // Observe playback end AFTER setting up the player
             NotificationCenter.default.addObserver(self, selector: #selector(playerItemDidReachEnd), name: .AVPlayerItemDidPlayToEndTime, object: player?.currentItem)
         }
     }


    // MARK: - Playback Progress & State
     private func addPeriodicTimeObserver(cell: EpisodeCell, fullURL: String) {
         if let token = timeObserverToken {
             player?.removeTimeObserver(token)
             timeObserverToken = nil
         }
         let interval = CMTime(seconds: 1.0, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
         timeObserverToken = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
             guard let self = self,
                   let currentItem = self.player?.currentItem, // Use optional chaining
                   currentItem.duration.seconds.isFinite,
                   currentItem.duration.seconds > 0 else {
                       return
                   }
             self.updatePlaybackProgress(time: time, duration: currentItem.duration.seconds, cell: cell, fullURL: fullURL)
         }
     }

    private func updatePlaybackProgress(time: CMTime, duration: Double, cell: EpisodeCell, fullURL: String) {
         let currentTime = time.seconds
         let progress = Float(currentTime / duration)
         let remainingTime = duration - currentTime

         cell.updatePlaybackProgress(progress: progress, remainingTime: remainingTime)

         UserDefaults.standard.set(currentTime, forKey: "lastPlayedTime_\(fullURL)")
         UserDefaults.standard.set(duration, forKey: "totalTime_\(fullURL)")

         updateContinueWatchingItem(currentTime: currentTime, duration: duration, fullURL: fullURL)
         sendPushUpdates(remainingTime: remainingTime, totalTime: duration, fullURL: fullURL)
     }


    private func updateContinueWatchingItem(currentTime: Double, duration: Double, fullURL: String) {
        guard let episode = episodes.first(where: { $0.href == fullURL }), // Find episode by URL
              let episodeNumberInt = Int(episode.number), // Use the found episode's number
              let currentTitle = animeTitle, // Use controller's title
              let currentImage = imageUrl, // Use controller's image URL
              let currentSource = displayedDataSource?.rawValue // Use stored source
              else {
            return
        }

        let continueWatchingItem = ContinueWatchingItem(
            animeTitle: currentTitle,
            episodeTitle: "Ep. \(episodeNumberInt)",
            episodeNumber: episodeNumberInt,
            imageURL: currentImage,
            fullURL: fullURL,
            lastPlayedTime: currentTime,
            totalTime: duration,
            source: currentSource
        )
        ContinueWatchingManager.shared.saveItem(continueWatchingItem)
    }


    private func sendPushUpdates(remainingTime: Double, totalTime: Double, fullURL: String) {
        guard UserDefaults.standard.bool(forKey: "sendPushUpdates"),
              totalTime > 0, remainingTime / totalTime < 0.15, !hasSentUpdate,
              let episode = episodes.first(where: { $0.href == fullURL }),
              let episodeNumberInt = Int(episode.number),
              let currentTitle = animeTitle else {
            return
        }

        let cleanedTitle = cleanTitle(currentTitle)

        fetchAnimeID(title: cleanedTitle) { [weak self] animeID in
            guard animeID != 0 else { // Check if fetching ID failed
                print("Could not fetch valid AniList ID for progress update.")
                return
            }
            let aniListMutation = AniListMutation()
            aniListMutation.updateAnimeProgress(animeId: animeID, episodeNumber: episodeNumberInt) { result in
                // Handle result...
            }
            self?.hasSentUpdate = true // Set flag on self
        }
    }


    // fetchAnimeID remains the same
     func fetchAnimeID(title: String, completion: @escaping (Int) -> Void) {
          var updatedTitle = title
          if displayedDataSource == .anilibria {
              if !self.aliases.isEmpty { updatedTitle = self.aliases }
          } else if let animeTitle = self.animeTitle {
               if let customIDString = UserDefaults.standard.string(forKey: "customAniListID_\(animeTitle)"),
                  let customID = Int(customIDString) {
                   completion(customID)
                   return
               }
           }

          AnimeService.fetchAnimeID(byTitle: updatedTitle) { result in
              switch result {
              case .success(let id):
                  completion(id)
              case .failure(let error):
                  print("Error fetching anime ID: \(error.localizedDescription)")
                   completion(0) // Indicate failure
              }
          }
      }

    // playNextEpisode remains the same
    func playNextEpisode() {
        guard let animeDetailsViewController = self.animeDetailsViewController else {
            print("Error: animeDetailsViewController is nil in playNextEpisode")
            return
        }

        let nextIndex: Int
         if animeDetailsViewController.isReverseSorted {
             nextIndex = animeDetailsViewController.currentEpisodeIndex - 1
             guard nextIndex >= 0 else {
                 print("Already at the first episode (reversed).")
                 animeDetailsViewController.currentEpisodeIndex = 0
                 return
             }
         } else {
             nextIndex = animeDetailsViewController.currentEpisodeIndex + 1
             guard nextIndex < animeDetailsViewController.episodes.count else {
                 print("Already at the last episode.")
                 animeDetailsViewController.currentEpisodeIndex = animeDetailsViewController.episodes.count - 1
                 return
             }
         }
        animeDetailsViewController.currentEpisodeIndex = nextIndex
        playEpisode(at: nextIndex)
    }

    // playEpisode remains the same
    private func playEpisode(at index: Int) {
         guard let animeDetailsViewController = self.animeDetailsViewController,
               index >= 0 && index < animeDetailsViewController.episodes.count else {
                   print("Error: Invalid index for playEpisode: \(index)")
                   return
               }

         let nextEpisode = animeDetailsViewController.episodes[index]
         if let cell = animeDetailsViewController.tableView.cellForRow(at: IndexPath(row: index, section: 2)) as? EpisodeCell {
             animeDetailsViewController.episodeSelected(episode: nextEpisode, cell: cell)
         } else {
              print("Cell for episode \(nextEpisode.number) not visible, triggering selection logic directly.")
              animeDetailsViewController.showLoadingBanner()
              animeDetailsViewController.checkUserDefault(url: nextEpisode.href, cell: EpisodeCell(), fullURL: nextEpisode.href)
          }
     }

    // playerItemDidReachEnd remains the same
    @objc func playerItemDidReachEnd(notification: Notification) {
         guard let playerItem = notification.object as? AVPlayerItem,
               playerItem == player?.currentItem else {
                   return
               }

         print("Player item did reach end.")

         if UserDefaults.standard.bool(forKey: "AutoPlay") {
              guard let animeDetailsViewController = self.animeDetailsViewController else { return }
              let hasNextEpisode = animeDetailsViewController.isReverseSorted ?
                  (animeDetailsViewController.currentEpisodeIndex > 0) :
                  (animeDetailsViewController.currentEpisodeIndex < animeDetailsViewController.episodes.count - 1)

             if hasNextEpisode {
                  playerViewController?.dismiss(animated: true) { [weak self] in
                      print("Dismissed player, attempting to play next episode.")
                      self?.playNextEpisode()
                  }
              } else {
                   print("No next episode to play or autoplay disabled.")
                   playerViewController?.dismiss(animated: true, completion: nil)
               }
          } else {
               print("Autoplay disabled.")
               playerViewController?.dismiss(animated: true, completion: nil)
           }
     }


    // downloadMedia remains the same
     func downloadMedia(for episode: Episode) {
          guard let index = episodes.firstIndex(where: { $0.href == episode.href }),
                let cell = tableView.cellForRow(at: IndexPath(row: index, section: 2)) as? EpisodeCell else {
              print("Error: Could not get cell for episode \(episode.number) to start download.")
              showAlert(title: "Download Error", message: "Could not initiate download.")
              return
          }
          UserDefaults.standard.set(true, forKey: "isToDownload")
          episodeSelected(episode: episode, cell: cell)
      }

    // watchNextEpisode remains the same
    private func watchNextEpisode() {
         let sortedEpisodes = isReverseSorted ? episodes.reversed() : episodes

         for episode in sortedEpisodes {
             let fullURL = episode.href
             let lastPlayedTime = UserDefaults.standard.double(forKey: "lastPlayedTime_\(fullURL)")
             let totalTime = UserDefaults.standard.double(forKey: "totalTime_\(fullURL)")
             let progress = (totalTime > 0) ? (lastPlayedTime / totalTime) : 0

             if progress < 0.9 {
                  if let index = episodes.firstIndex(of: episode) {
                      let indexPath = IndexPath(row: index, section: 2)
                      tableView.scrollToRow(at: indexPath, at: .middle, animated: true)
                      DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                          if let cell = self.tableView.cellForRow(at: indexPath) as? EpisodeCell {
                               self.episodeSelected(episode: episode, cell: cell)
                          } else {
                               self.episodeSelected(episode: episode, cell: EpisodeCell())
                           }
                      }
                  }
                  return
              }
         }

        if let firstEpisode = sortedEpisodes.first, let index = episodes.firstIndex(of: firstEpisode) {
             let indexPath = IndexPath(row: index, section: 2)
             tableView.scrollToRow(at: indexPath, at: .middle, animated: true)
             DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                  if let cell = self.tableView.cellForRow(at: indexPath) as? EpisodeCell {
                       self.episodeSelected(episode: firstEpisode, cell: cell)
                  } else {
                       self.episodeSelected(episode: firstEpisode, cell: EpisodeCell())
                  }
              }
         } else {
              showAlert(title: "All Watched", message: "You've finished all available episodes!")
          }
    }


    // MARK: - Cleanup & Helpers
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
              // Try removing observer only if player exists
               // Ideally, the observer should be weak or invalidated when player is nilled
              // player?.removeTimeObserver(token) // Avoid potential crash
             timeObserverToken = nil
         }
      }

    // cleanTitle remains the same
      func cleanTitle(_ title: String) -> String {
          let unwantedStrings = ["(ITA)", "(Dub)", "(Dub ID)", "(Dublado)"]
          var cleanedTitle = title
          for unwanted in unwantedStrings {
              cleanedTitle = cleanedTitle.replacingOccurrences(of: unwanted, with: "")
          }
          cleanedTitle = cleanedTitle.replacingOccurrences(of: "\"", with: "")
          return cleanedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
      }

      // showAlert remains the same
      func showAlert(title: String, message: String) {
          let alertController = UIAlertController(title: title, message: message, preferredStyle: .alert)
          alertController.addAction(UIAlertAction(title: "OK", style: .default, handler: nil))
          DispatchQueue.main.async {
              var topController = UIApplication.shared.windows.filter {$0.isKeyWindow}.first?.rootViewController
              while let presentedViewController = topController?.presentedViewController {
                  topController = presentedViewController
              }
              topController?.present(alertController, animated: true, completion: nil)
          }
      }
}

// Conformances remain the same
extension AnimeDetailViewController { // SynopsisCellDelegate moved to class declaration
    func synopsisCellDidToggleExpansion(_ cell: SynopsisCell) {
        isSynopsisExpanded.toggle()
        tableView.beginUpdates()
        tableView.endUpdates()
    }
}

extension AnimeDetailViewController { // CustomPlayerViewDelegate moved to class declaration
    func customPlayerViewDidDismiss() {
        // Handle dismissal if needed, e.g., check if playback finished
        print("Custom player was dismissed.")
    }
}
