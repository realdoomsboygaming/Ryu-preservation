import UIKit
import SwiftSoup

class HomeViewController: UITableViewController, SourceSelectionDelegate {

    @IBOutlet private weak var airingCollectionView: UICollectionView!
    @IBOutlet private weak var trendingCollectionView: UICollectionView!
    @IBOutlet private weak var seasonalCollectionView: UICollectionView!
    @IBOutlet private weak var featuredCollectionView: UICollectionView!
    @IBOutlet private weak var continueWatchingCollectionView: UICollectionView!

    @IBOutlet weak var dateLabel: UILabel!
    @IBOutlet weak var selectedSourceLabel: UILabel!
    @IBOutlet weak var selectSourceLable: UIBarButtonItem!

    private var airingAnime: [Anime] = []
    private var trendingAnime: [Anime] = []
    private var seasonalAnime: [Anime] = []
    private var featuredAnime: [AnimeItem] = []
    private var continueWatchingItems: [ContinueWatchingItem] = []

    private let airingErrorLabel = UILabel()
    private let trendingErrorLabel = UILabel()
    private let seasonalErrorLabel = UILabel()
    private let featuredErrorLabel = UILabel()

    private let airingActivityIndicator = UIActivityIndicatorView(style: .medium)
    private let trendingActivityIndicator = UIActivityIndicatorView(style: .medium)
    private let seasonalActivityIndicator = UIActivityIndicatorView(style: .medium)
    private let featuredActivityIndicator = UIActivityIndicatorView(style: .medium)

    private let aniListServiceAiring = AnilistServiceAiringAnime()
    private let aniListServiceTrending = AnilistServiceTrendingAnime()
    private let aniListServiceSeasonal = AnilistServiceSeasonalAnime()

    private let funnyTexts: [String] = [
        "No shows here... did you just break the internet?",
        "Oops, looks like you finished everything! Try something fresh.",
        "You've watched it all! Time to rewatch or explore!",
        "Nothing left to watch... for now!",
        "All clear! Ready to start a new watch marathon?",
        "Your watchlist is taking a nap... Wake it up with something new!",
        "Nothing to continue here... maybe it's snack time?",
        "Looks empty... Wanna start a new adventure?",
        "All caught up! What’s next on the list?",
        "Did you know that by holding on most cells you can get some hidden features?"
    ]

    private let emptyContinueWatchingLabel: UILabel = {
        let label = UILabel()
        label.textColor = .gray
        label.textAlignment = .center
        label.numberOfLines = 0
        label.isUserInteractionEnabled = true
        return label
    }()

    override func viewDidLoad() {
        super.viewDidLoad()

        setupCollectionViews()
        setupDateLabel()
        setupSelectedSourceLabel()
        setupRefreshControl()
        setupEmptyContinueWatchingLabel()
        setupErrorLabelsAndActivityIndicators()
        setupActivityIndicators()
        fetchAnimeData()

        let longPressGesture = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        continueWatchingCollectionView.addGestureRecognizer(longPressGesture)

        SourceMenu.delegate = self

        NotificationCenter.default.addObserver(self, selector: #selector(handleAppDataReset), name: .appDataReset, object: nil)

        setupContextMenus()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        view.viewWithTag(999)?.removeFromSuperview() // Remove potential old empty label
        navigationController?.navigationBar.prefersLargeTitles = true
        loadContinueWatchingItems()
        setupSelectedSourceLabel()

        // Refresh featured only if source changed
        let currentSelectedSource = UserDefaults.standard.selectedMediaSource?.rawValue ?? "AnimeWorld"
        if let displayedSource = selectedSourceLabel.text?.replacingOccurrences(of: "on ", with: "").replacingOccurrences(of: "%", with: ""), displayedSource != currentSelectedSource {
             fetchFeaturedAnime { [weak self] in
                 self?.refreshFeaturedUI()
             }
         }
    }

    private func setupContextMenus() {
        // Applied only to collection views showing data from AniList/MAL/Kitsu
        let collectionViews = [trendingCollectionView, seasonalCollectionView, airingCollectionView]

        for collectionView in collectionViews {
            let interaction = UIContextMenuInteraction(delegate: self)
            collectionView?.addInteraction(interaction)
        }
    }

    @objc func handleLongPress(_ gestureRecognizer: UILongPressGestureRecognizer) {
        if gestureRecognizer.state == .began {
            let point = gestureRecognizer.location(in: continueWatchingCollectionView)
            if let indexPath = continueWatchingCollectionView.indexPathForItem(at: point) {
                showContinueWatchingOptions(for: indexPath)
            }
        }
    }

    func showContinueWatchingOptions(for indexPath: IndexPath) {
        let item = continueWatchingItems[indexPath.item]

        let alertController = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)

        let resumeAction = UIAlertAction(title: "Resume", style: .default) { [weak self] _ in
            self?.resumeWatching(item: item)
        }

        let deleteAction = UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
            self?.showRemoveAlert(for: indexPath)
        }

        let cancelAction = UIAlertAction(title: "Cancel", style: .cancel, handler: nil)

        alertController.addAction(resumeAction)
        alertController.addAction(deleteAction)
        alertController.addAction(cancelAction)

        if let popoverController = alertController.popoverPresentationController {
            if let cell = continueWatchingCollectionView.cellForItem(at: indexPath) {
                popoverController.sourceView = cell
                popoverController.sourceRect = cell.bounds
            } else {
                // Fallback presentation if cell is not visible
                popoverController.sourceView = continueWatchingCollectionView
                popoverController.sourceRect = CGRect(x: continueWatchingCollectionView.bounds.midX, y: continueWatchingCollectionView.bounds.midY, width: 0, height: 0)
            }
            popoverController.permittedArrowDirections = [.up, .down]
        }

        present(alertController, animated: true, completion: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func setupEmptyContinueWatchingLabel() {
        emptyContinueWatchingLabel.frame = continueWatchingCollectionView.bounds // Set initial frame
        continueWatchingCollectionView.backgroundView = emptyContinueWatchingLabel
    }

    func loadContinueWatchingItems() {
        continueWatchingItems = ContinueWatchingManager.shared.getItems()
        continueWatchingCollectionView.reloadData()

        if continueWatchingItems.isEmpty {
            let randomText = funnyTexts.randomElement() ?? "No anime here!"
            emptyContinueWatchingLabel.text = randomText
            emptyContinueWatchingLabel.isHidden = false
        } else {
            emptyContinueWatchingLabel.isHidden = true
        }
    }

    func setupCollectionViews() {
        let collectionViews = [continueWatchingCollectionView, airingCollectionView, trendingCollectionView, seasonalCollectionView, featuredCollectionView]
        let cellIdentifiers = ["ContinueWatchingCell", "AiringAnimeCell", "SlimmAnimeCell", "SlimmAnimeCell", "SlimmAnimeCell"]
        let cellClasses: [AnyClass] = [ContinueWatchingCell.self, AiringAnimeCell.self, SlimmAnimeCell.self, SlimmAnimeCell.self, SlimmAnimeCell.self] // Use correct types

        for (index, collectionView) in collectionViews.enumerated() {
            collectionView?.delegate = self
            collectionView?.dataSource = self

            let identifier = cellIdentifiers[index]
            let cellClass = cellClasses[index]

            if cellClass is UICollectionViewCell.Type {
                 // Register XIBs for custom cells if they exist
                 if identifier == "ContinueWatchingCell" {
                     // ContinueWatchingCell is registered programmatically
                     collectionView?.register(cellClass, forCellWithReuseIdentifier: identifier)
                 } else if ["AiringAnimeCell", "SlimmAnimeCell"].contains(identifier) {
                     let nib = UINib(nibName: identifier, bundle: nil)
                     collectionView?.register(nib, forCellWithReuseIdentifier: identifier)
                 } else {
                     // Fallback for standard cells (though unlikely needed with custom cells)
                     collectionView?.register(cellClass, forCellWithReuseIdentifier: identifier)
                 }
             }
        }
    }


    private func setupErrorLabelsAndActivityIndicators() {
        let errorLabels = [airingErrorLabel, trendingErrorLabel, seasonalErrorLabel, featuredErrorLabel]
        let collectionViews = [airingCollectionView, trendingCollectionView, seasonalCollectionView, featuredCollectionView]
        let activityIndicators = [airingActivityIndicator, trendingActivityIndicator, seasonalActivityIndicator, featuredActivityIndicator]

        for (index, label) in errorLabels.enumerated() {
            label.textColor = .gray
            label.textAlignment = .center
            label.numberOfLines = 0
            label.isHidden = true

            let collectionView = collectionViews[index]
            collectionView?.backgroundView = label // Set as background view

            let activityIndicator = activityIndicators[index]
            activityIndicator.hidesWhenStopped = true
            collectionView?.addSubview(activityIndicator) // Add indicator as subview
             activityIndicator.translatesAutoresizingMaskIntoConstraints = false // Important for constraints
             NSLayoutConstraint.activate([
                 activityIndicator.centerXAnchor.constraint(equalTo: collectionView!.centerXAnchor),
                 activityIndicator.centerYAnchor.constraint(equalTo: collectionView!.centerYAnchor)
             ])
        }
    }

    func setupDateLabel() {
        let currentDate = Date()
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "EEEE, dd MMMM yyyy"
        dateFormatter.locale = Locale.current
        let dateString = dateFormatter.string(from: currentDate)

        dateLabel.text = String(format: NSLocalizedString("on %@", comment: "Prefix for date label"), dateString)
    }

    func setupSelectedSourceLabel() {
        let selectedSource = UserDefaults.standard.selectedMediaSource?.rawValue ?? "AnimeWorld"
        selectSourceLable.title = selectedSource

        // Update the label text only if it has changed
        let newLabelText = String(format: NSLocalizedString("on %@%", comment: "Prefix for selected Source"), selectedSource)
        if selectedSourceLabel.text != newLabelText {
            selectedSourceLabel.text = newLabelText
            // Optionally trigger a refresh if the source change requires it
            // fetchFeaturedAnime { [weak self] in self?.refreshFeaturedUI() } // Moved this logic to viewWillAppear
        }
    }


    func setupRefreshControl() {
        refreshControl = UIRefreshControl()
        refreshControl?.addTarget(self, action: #selector(refreshData), for: .valueChanged)
        // Assign the refresh control to the TableView, not CollectionView
        tableView.refreshControl = refreshControl
    }

    @objc func refreshData() {
        fetchAnimeData() // Refetch all data including featured
    }

    private func setupActivityIndicators() {
        let activityIndicators = [airingActivityIndicator, trendingActivityIndicator, seasonalActivityIndicator, featuredActivityIndicator]
        let collectionViews = [airingCollectionView, trendingCollectionView, seasonalCollectionView, featuredCollectionView]

        for (index, indicator) in activityIndicators.enumerated() {
            guard let collectionView = collectionViews[index] else { continue }

            indicator.hidesWhenStopped = true
            indicator.translatesAutoresizingMaskIntoConstraints = false
            collectionView.addSubview(indicator) // Add as subview

            NSLayoutConstraint.activate([
                indicator.centerXAnchor.constraint(equalTo: collectionView.centerXAnchor),
                indicator.centerYAnchor.constraint(equalTo: collectionView.centerYAnchor)
            ])
        }
    }

    func fetchAnimeData() {
        let dispatchGroup = DispatchGroup()

        [airingActivityIndicator, trendingActivityIndicator, seasonalActivityIndicator, featuredActivityIndicator].forEach { $0.startAnimating() }

        dispatchGroup.enter()
        fetchTrendingAnime { dispatchGroup.leave() }

        dispatchGroup.enter()
        fetchSeasonalAnime { dispatchGroup.leave() }

        dispatchGroup.enter()
        fetchAiringAnime { dispatchGroup.leave() }

        dispatchGroup.enter()
        fetchFeaturedAnime { dispatchGroup.leave() } // Fetch featured along with others

        dispatchGroup.notify(queue: .main) {
            self.refreshUI()
            self.refreshControl?.endRefreshing()
            [self.airingActivityIndicator, self.trendingActivityIndicator, self.seasonalActivityIndicator, self.featuredActivityIndicator].forEach { $0.stopAnimating() }
        }
    }

    func fetchTrendingAnime(completion: @escaping () -> Void) {
        aniListServiceTrending.fetchTrendingAnime { [weak self] animeList in
            DispatchQueue.main.async {
                if let animeList = animeList, !animeList.isEmpty {
                    self?.trendingAnime = animeList
                    self?.trendingErrorLabel.isHidden = true
                    self?.trendingCollectionView.reloadData() // Reload specific collection view
                } else {
                    self?.trendingErrorLabel.text = NSLocalizedString("Unable to load trending anime. Make sure to check your connection", comment: "Trending Anime loading error")
                    self?.trendingErrorLabel.isHidden = false
                }
                self?.trendingActivityIndicator.stopAnimating() // Stop specific indicator
                completion()
            }
        }
    }

    func fetchSeasonalAnime(completion: @escaping () -> Void) {
        aniListServiceSeasonal.fetchSeasonalAnime { [weak self] animeList in
             DispatchQueue.main.async {
                if let animeList = animeList, !animeList.isEmpty {
                    self?.seasonalAnime = animeList
                    self?.seasonalErrorLabel.isHidden = true
                    self?.seasonalCollectionView.reloadData() // Reload specific collection view
                } else {
                    self?.seasonalErrorLabel.text = NSLocalizedString("Unable to load seasonal anime. Make sure to check your connection", comment: "Seasonal Anime loading error")
                    self?.seasonalErrorLabel.isHidden = false
                }
                 self?.seasonalActivityIndicator.stopAnimating() // Stop specific indicator
                completion()
             }
        }
    }

    func fetchAiringAnime(completion: @escaping () -> Void) {
        aniListServiceAiring.fetchAiringAnime { [weak self] animeList in
            DispatchQueue.main.async {
                if let animeList = animeList, !animeList.isEmpty {
                    self?.airingAnime = animeList
                    self?.airingErrorLabel.isHidden = true
                    self?.airingCollectionView.reloadData() // Reload specific collection view
                } else {
                    self?.airingErrorLabel.text = NSLocalizedString("Unable to load airing anime. Make sure to check your connection", comment: "Airing Anime loading error")
                    self?.airingErrorLabel.isHidden = false
                }
                 self?.airingActivityIndicator.stopAnimating() // Stop specific indicator
                completion()
            }
        }
    }

    private func fetchFeaturedAnime(completion: @escaping () -> Void) {
        guard let selectedSource = UserDefaults.standard.selectedMediaSource else {
            DispatchQueue.main.async {
                self.featuredErrorLabel.text = "No source selected."
                self.featuredErrorLabel.isHidden = false
                self.featuredActivityIndicator.stopAnimating()
                completion()
            }
            return
        }

        let (sourceURLString, parseStrategy) = getSourceInfo(for: selectedSource.rawValue)

        DispatchQueue.main.async {
            self.featuredAnime.removeAll()
            self.featuredCollectionView.reloadData()
            self.featuredActivityIndicator.startAnimating()
            self.featuredErrorLabel.isHidden = true
        }

        guard let urlString = sourceURLString, let url = URL(string: urlString), let parse = parseStrategy else {
            DispatchQueue.main.async {
                self.featuredErrorLabel.text = "Unable to load featured anime. Invalid source or parsing strategy."
                self.featuredErrorLabel.isHidden = false
                self.featuredActivityIndicator.stopAnimating()
                completion()
            }
            return
        }

        URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            guard let self = self else { return }

            if let error = error {
                DispatchQueue.main.async {
                    self.featuredErrorLabel.text = "Error loading featured anime: \(error.localizedDescription)"
                    self.featuredErrorLabel.isHidden = false
                    self.featuredActivityIndicator.stopAnimating()
                    completion()
                }
                return
            }

            guard let data = data else {
                 DispatchQueue.main.async {
                    self.featuredErrorLabel.text = "Error loading featured anime. No data received."
                    self.featuredErrorLabel.isHidden = false
                    self.featuredActivityIndicator.stopAnimating()
                    completion()
                 }
                 return
             }

             let htmlString = String(data: data, encoding: .utf8)

             do {
                 // Pass nil for document if it's a JSON source, otherwise parse HTML
                 let animeItems = try parse(nil, htmlString)

                 DispatchQueue.main.async {
                     self.featuredActivityIndicator.stopAnimating()
                     if !animeItems.isEmpty {
                         self.featuredAnime = animeItems
                         self.featuredErrorLabel.isHidden = true
                     } else {
                         self.featuredErrorLabel.text = "No featured anime found."
                         self.featuredErrorLabel.isHidden = false
                     }
                     self.featuredCollectionView.reloadData()
                     completion()
                 }
             } catch {
                 DispatchQueue.main.async {
                     self.featuredErrorLabel.text = "Error parsing featured anime: \(error.localizedDescription)"
                     self.featuredErrorLabel.isHidden = false
                     self.featuredActivityIndicator.stopAnimating()
                     completion()
                 }
             }
        }.resume()
    }

    // Consolidated refresh function
    func refreshUI() {
        DispatchQueue.main.async {
            self.loadContinueWatchingItems() // Ensure this is called to update the label
            // Reload all collection views
            self.continueWatchingCollectionView.reloadData()
            self.airingCollectionView.reloadData()
            self.trendingCollectionView.reloadData()
            self.seasonalCollectionView.reloadData()
            self.featuredCollectionView.reloadData() // Ensure featured is reloaded too

            self.setupDateLabel()
            self.setupSelectedSourceLabel()
        }
    }

    @IBAction func selectSourceButtonTapped(_ sender: UIBarButtonItem) {
        SourceMenu.showSourceSelector(from: self, barButtonItem: sender) { [weak self] in
            self?.setupSelectedSourceLabel()
            // Trigger featured anime fetch when source changes
            self?.fetchFeaturedAnime {
                 self?.refreshFeaturedUI()
             }
        }
    }

    func didSelectNewSource() {
        setupSelectedSourceLabel()
        fetchFeaturedAnime { [weak self] in
            self?.refreshFeaturedUI()
        }
    }

    func refreshFeaturedUI() {
        DispatchQueue.main.async {
            self.featuredCollectionView.reloadData()
            self.setupSelectedSourceLabel() // Update label again after fetch completes
        }
    }


    func showRemoveAlert(for indexPath: IndexPath) {
        let item = continueWatchingItems[indexPath.item]

        let alertTitle = NSLocalizedString("Remove Item", comment: "Title for remove item alert")
        let alertMessage = String(format: NSLocalizedString("Do you want to remove '%@' from continue watching?", comment: "Message for remove item alert"), item.animeTitle)

        let alert = UIAlertController(title: alertTitle, message: alertMessage, preferredStyle: .alert)

        let cancelActionTitle = NSLocalizedString("Cancel", comment: "Cancel action title")
        let removeActionTitle = NSLocalizedString("Remove", comment: "Remove action title")

        alert.addAction(UIAlertAction(title: cancelActionTitle, style: .cancel, handler: nil))
        alert.addAction(UIAlertAction(title: removeActionTitle, style: .destructive, handler: { [weak self] _ in
            self?.removeContinueWatchingItem(at: indexPath)
        }))

        present(alert, animated: true, completion: nil)
    }

    func removeContinueWatchingItem(at indexPath: IndexPath) {
        let item = continueWatchingItems[indexPath.item]
        ContinueWatchingManager.shared.clearItem(fullURL: item.fullURL)
        continueWatchingItems.remove(at: indexPath.item)
        continueWatchingCollectionView.deleteItems(at: [indexPath]) // Use deleteItems for animation

        if continueWatchingItems.isEmpty {
            let randomText = funnyTexts.randomElement() ?? "No anime here!"
            emptyContinueWatchingLabel.text = randomText
            emptyContinueWatchingLabel.isHidden = false
        }
    }

    @objc func handleAppDataReset() {
        DispatchQueue.main.async {
            self.fetchAnimeData() // Refetch all data
            self.refreshUI() // Update the entire UI
        }
    }
}

// MARK: - CollectionView DataSource
extension HomeViewController: UICollectionViewDataSource {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        switch collectionView {
        case continueWatchingCollectionView:
            return continueWatchingItems.count
        case trendingCollectionView:
            return trendingAnime.count
        case seasonalCollectionView:
            return seasonalAnime.count
        case airingCollectionView:
            return airingAnime.count
        case featuredCollectionView:
            return featuredAnime.count
        default:
            return 0
        }
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        switch collectionView {
        case continueWatchingCollectionView:
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "ContinueWatchingCell", for: indexPath) as! ContinueWatchingCell
            let item = continueWatchingItems[indexPath.item]
            cell.configure(with: item)
            return cell
        case trendingCollectionView, seasonalCollectionView, featuredCollectionView:
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "SlimmAnimeCell", for: indexPath)
            if let slimmCell = cell as? SlimmAnimeCell {
                configureSlimmCell(slimmCell, at: indexPath, for: collectionView)
            }
            // Add context menu interaction
            let interaction = UIContextMenuInteraction(delegate: self)
            cell.addInteraction(interaction)
            return cell
        case airingCollectionView:
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "AiringAnimeCell", for: indexPath)
            if let airingCell = cell as? AiringAnimeCell {
                configureAiringCell(airingCell, at: indexPath)
            }
             // Add context menu interaction
             let interaction = UIContextMenuInteraction(delegate: self)
             cell.addInteraction(interaction)
            return cell
        default:
            fatalError("Unexpected collection view")
        }
    }

    private func configureSlimmCell(_ cell: SlimmAnimeCell, at indexPath: IndexPath, for collectionView: UICollectionView) {
        switch collectionView {
        case trendingCollectionView:
            let anime = trendingAnime[indexPath.item]
            let imageUrl = URL(string: anime.coverImage.large)
            cell.configure(with: anime.title.romaji, imageUrl: imageUrl)
        case seasonalCollectionView:
            let anime = seasonalAnime[indexPath.item]
            let imageUrl = URL(string: anime.coverImage.large)
            cell.configure(with: anime.title.romaji, imageUrl: imageUrl)
        case featuredCollectionView:
            let anime = featuredAnime[indexPath.item]
            let imageUrl = URL(string: anime.imageURL)
            cell.configure(with: anime.title, imageUrl: imageUrl)
        default:
            break
        }
    }

    private func configureAiringCell(_ cell: AiringAnimeCell, at indexPath: IndexPath) {
        let anime = airingAnime[indexPath.item]
        let imageUrl = URL(string: anime.coverImage.large)
        cell.configure(
            with: anime.title.romaji,
            imageUrl: imageUrl,
            episodes: anime.episodes,
            description: anime.description,
            airingAt: anime.airingAt
        )
    }
}

// MARK: - CollectionView Delegate
extension HomeViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        switch collectionView {
        case continueWatchingCollectionView:
            let item = continueWatchingItems[indexPath.item]
            resumeWatching(item: item)
        case trendingCollectionView:
            let anime = trendingAnime[indexPath.item]
            navigateToAnimeDetail(for: anime)
        case seasonalCollectionView:
            let anime = seasonalAnime[indexPath.item]
            navigateToAnimeDetail(for: anime)
        case airingCollectionView:
            let anime = airingAnime[indexPath.item]
            navigateToAnimeDetail(for: anime)
        case featuredCollectionView:
            let anime = featuredAnime[indexPath.item]
            navigateToAnimeDetail(title: anime.title, imageUrl: anime.imageURL, href: anime.href)
        default:
            break
        }
    }

    private func resumeWatching(item: ContinueWatchingItem) {
        let detailVC = AnimeDetailViewController()

        detailVC.configure(title: item.animeTitle, imageUrl: item.imageURL, href: item.fullURL, source: item.source)

        // Create a dummy episode to pass - actual episode logic is in AnimeDetailViewController
        let episode = Episode(number: String(item.episodeNumber), href: item.fullURL, downloadUrl: "")
        let dummyCell = EpisodeCell() // Need a cell to pass for progress updates
        dummyCell.episodeNumber = String(item.episodeNumber)

        // Ensure the correct source is set before navigating
        UserDefaults.standard.set(item.source, forKey: "selectedMediaSource")
        self.didSelectNewSource() // This might trigger an unnecessary fetch, consider refining

        // Navigate first
        navigationController?.pushViewController(detailVC, animated: true)

        // Then call episodeSelected on the presented VC
        // Use DispatchQueue.main.async to ensure it runs after navigation transition completes
        DispatchQueue.main.async {
            detailVC.episodeSelected(episode: episode, cell: dummyCell)
        }
    }


    private func navigateToAnimeDetail(for anime: Anime) {
        let storyboard = UIStoryboard(name: "AnilistAnimeInformation", bundle: nil)
        if let animeDetailVC = storyboard.instantiateViewController(withIdentifier: "AnimeInformation") as? AnimeInformation {
            animeDetailVC.animeID = anime.id
            navigationController?.pushViewController(animeDetailVC, animated: true)
        }
    }

    private func navigateToAnimeDetail(title: String, imageUrl: String, href: String) {
        let detailVC = AnimeDetailViewController()
        let selectedMedaiSource = UserDefaults.standard.selectedMediaSource?.rawValue ?? "" // Use enum

        detailVC.configure(title: title, imageUrl: imageUrl, href: href, source: selectedMedaiSource)
        navigationController?.pushViewController(detailVC, animated: true)
    }
}

// MARK: - Context Menu Interaction Delegate
extension HomeViewController: UIContextMenuInteractionDelegate {
    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard let collectionView = interaction.view as? UICollectionView,
              let indexPath = collectionView.indexPathForItem(at: location) else { return nil }

        // Determine the section based on the collection view
        let section: Int
        switch collectionView {
        case trendingCollectionView: section = 0
        case seasonalCollectionView: section = 1
        case airingCollectionView: section = 2
        case featuredCollectionView: section = 3 // Add case for featured
        default: return nil
        }

        // Use a unique identifier combining section and item
        let identifier = "\(section)-\(indexPath.item)" as NSCopying

        return UIContextMenuConfiguration(identifier: identifier, previewProvider: { [weak self] in
            self?.previewViewController(for: IndexPath(item: indexPath.item, section: section))
        }, actionProvider: { [weak self] _ in
            guard let self = self else { return nil }

            // Actions for AniList/MAL/Kitsu based collection views
            if collectionView == self.trendingCollectionView || collectionView == self.seasonalCollectionView || collectionView == self.airingCollectionView {
                 guard let anime = self.animeForIndexPath(IndexPath(item: indexPath.item, section: section)) else { return nil }
                 let openAction = UIAction(title: "Open", image: UIImage(systemName: "eye")) { _ in
                     self.openAnimeDetail(for: IndexPath(item: indexPath.item, section: section))
                 }

                 let searchAction = UIAction(title: "Search Episodes", image: UIImage(systemName: "magnifyingglass")) { _ in
                     self.searchEpisodes(for: IndexPath(item: indexPath.item, section: section))
                 }
                 return UIMenu(title: "", children: [openAction, searchAction])
            }
            // Actions for Featured collection view (source-specific)
            else if collectionView == self.featuredCollectionView {
                 guard let animeItem = self.featuredAnime[safe: indexPath.item] else { return nil }
                 let openAction = UIAction(title: "Open", image: UIImage(systemName: "eye")) { _ in
                     self.navigateToAnimeDetail(title: animeItem.title, imageUrl: animeItem.imageURL, href: animeItem.href)
                 }
                 return UIMenu(title: "", children: [openAction])
            }
            else {
                 return nil // No context menu for other collection views like continue watching
            }

        })
    }


    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, previewForHighlightingMenuWithConfiguration configuration: UIContextMenuConfiguration) -> UITargetedPreview? {
        guard let indexPath = configuration.identifier as? IndexPath, // Use correct identifier type
              let cell = cellForIndexPath(indexPath) else {
            return nil
        }

        let parameters = UIPreviewParameters()
        parameters.backgroundColor = .clear
        // Create preview target centered on the cell's content view
        let target = UIPreviewTarget(container: cell.superview ?? cell, center: cell.center)
        return UITargetedPreview(view: cell.contentView, parameters: parameters, target: target)
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, willPerformPreviewActionForMenuWith configuration: UIContextMenuConfiguration, animator: UIContextMenuInteractionCommitAnimating) {
         guard let indexPath = configuration.identifier as? IndexPath else { return }

         animator.addCompletion { [weak self] in
             self?.openAnimeDetail(for: indexPath)
         }
     }


    private func previewViewController(for indexPath: IndexPath) -> UIViewController? {
        // Handle preview only for sections with Anime objects (AniList/MAL/Kitsu data)
         guard indexPath.section < 3, // Only for trending, seasonal, airing
               let anime = animeForIndexPath(indexPath) else {
             // For featured section, potentially show a simple image/title preview if desired
             if indexPath.section == 3, let animeItem = featuredAnime[safe: indexPath.item] {
                  let vc = UIViewController()
                  let imageView = UIImageView()
                  imageView.kf.setImage(with: URL(string: animeItem.imageURL))
                  imageView.contentMode = .scaleAspectFit
                  vc.view = imageView
                  // Adjust preferredContentSize if needed
                 vc.preferredContentSize = CGSize(width: 150, height: 220) // Example size
                 return vc
             }
             return nil
         }

        let storyboard = UIStoryboard(name: "AnilistAnimeInformation", bundle: nil)
        guard let animeDetailVC = storyboard.instantiateViewController(withIdentifier: "AnimeInformation") as? AnimeInformation else {
            return nil
        }

        animeDetailVC.animeID = anime.id
        // Adjust preferredContentSize if needed for the preview
        animeDetailVC.preferredContentSize = CGSize(width: 0, height: 300) // Example size
        return animeDetailVC
    }


    private func animeForIndexPath(_ indexPath: IndexPath) -> Anime? {
        // Only return Anime for sections 0, 1, 2
        guard indexPath.section < 3 else { return nil }
        switch indexPath.section {
        case 0:
            return trendingAnime[safe: indexPath.item] // Use safe subscripting
        case 1:
            return seasonalAnime[safe: indexPath.item]
        case 2:
            return airingAnime[safe: indexPath.item]
        default:
            return nil
        }
    }


    private func openAnimeDetail(for indexPath: IndexPath) {
         // Handle opening based on section
         if indexPath.section < 3 { // Trending, Seasonal, Airing
             guard let anime = animeForIndexPath(indexPath) else { return }
             navigateToAnimeDetail(for: anime)
         } else if indexPath.section == 3 { // Featured
             guard let animeItem = featuredAnime[safe: indexPath.item] else { return }
             navigateToAnimeDetail(title: animeItem.title, imageUrl: animeItem.imageURL, href: animeItem.href)
         }
     }


    private func searchEpisodes(for indexPath: IndexPath) {
        // Only search for sections with Anime objects
        guard indexPath.section < 3, let anime = animeForIndexPath(indexPath) else { return }
        let query = anime.title.romaji

        guard !query.isEmpty else {
            showError(message: "Could not find anime title.")
            return
        }

        searchMedia(query: query)
    }

    private func indexPathForCell(_ cell: UICollectionViewCell) -> IndexPath? {
        let collectionViews = [trendingCollectionView, seasonalCollectionView, airingCollectionView, featuredCollectionView]

        for (section, collectionView) in collectionViews.enumerated() {
            if let indexPath = collectionView?.indexPath(for: cell) {
                // Return an IndexPath with the correct section
                return IndexPath(item: indexPath.item, section: section)
            }
        }
        return nil
    }


     private func cellForIndexPath(_ indexPath: IndexPath) -> UICollectionViewCell? {
         let collectionViews = [trendingCollectionView, seasonalCollectionView, airingCollectionView, featuredCollectionView]
         guard indexPath.section < collectionViews.count else { return nil }
         // Use item from the provided indexPath, section should be 0 for collection view's own index path system
         return collectionViews[indexPath.section]?.cellForItem(at: IndexPath(item: indexPath.item, section: 0))
     }


    private func searchMedia(query: String) {
        let resultsVC = SearchResultsViewController()
        resultsVC.query = query
        navigationController?.pushViewController(resultsVC, animated: true)
    }

    private func showError(message: String) {
        let alertController = UIAlertController(title: "Error", message: message, preferredStyle: .alert)
        alertController.addAction(UIAlertAction(title: "OK", style: .default, handler: nil))
        present(alertController, animated: true, completion: nil)
    }
}

// Models remain the same
class AnimeItem: NSObject {
    let title: String
    let imageURL: String
    let href: String

    init(title: String, imageURL: String, href: String) {
        self.title = title
        self.imageURL = imageURL
        self.href = href
    }
}

struct Anime {
    let id: Int
    let title: Title
    let coverImage: CoverImage
    let episodes: Int?
    let description: String?
    let airingAt: Int?
    var mediaRelations: [MediaRelation] = []
    var characters: [Character] = []
}

struct MediaRelation {
    let node: MediaNode

    struct MediaNode {
        let id: Int
        let title: Title
    }
}

struct Character {
    let node: CharacterNode
    let role: String

    struct CharacterNode {
        let id: Int
        let name: Name

        struct Name {
            let full: String
        }
    }
}

struct Title {
    let romaji: String
    let english: String?
    let native: String?
}

struct CoverImage {
    let large: String
}
