import UIKit
import SwiftSoup
import GoogleCast 
class HomeViewController: UITableViewController, SourceSelectionDelegate, UIContextMenuInteractionDelegate {

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
        view.viewWithTag(999)?.removeFromSuperview() // Ensure empty state label is removed if needed
        navigationController?.navigationBar.prefersLargeTitles = true
        loadContinueWatchingItems()
        setupSelectedSourceLabel() // Update source label in case it changed in settings

        // Check if the selected source changed and refresh featured if needed
        let currentSelectedSource = UserDefaults.standard.string(forKey: "selectedMediaSource") ?? "AnimeWorld"
        if let displayedSource = selectedSourceLabel.text?.replacingOccurrences(of: "on ", with: "").replacingOccurrences(of: "%", with: "") {
            if displayedSource != currentSelectedSource {
                fetchFeaturedAnime { [weak self] in
                    self?.refreshFeaturedUI()
                }
            }
        }
    }

    private func setupContextMenus() {
        // Apply context menus to relevant collection views
        let collectionViews = [trendingCollectionView, seasonalCollectionView, airingCollectionView] // Removed featuredCollectionView for now
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
        emptyContinueWatchingLabel.frame = continueWatchingCollectionView.bounds // Initial frame
        continueWatchingCollectionView.backgroundView = emptyContinueWatchingLabel
        // Ensure constraints are set if using Auto Layout for the background view
        emptyContinueWatchingLabel.translatesAutoresizingMaskIntoConstraints = false
        if let backgroundView = continueWatchingCollectionView.backgroundView {
            NSLayoutConstraint.activate([
                emptyContinueWatchingLabel.centerXAnchor.constraint(equalTo: backgroundView.centerXAnchor),
                emptyContinueWatchingLabel.centerYAnchor.constraint(equalTo: backgroundView.centerYAnchor, constant: -20), // Adjust vertical position
                emptyContinueWatchingLabel.leadingAnchor.constraint(equalTo: backgroundView.leadingAnchor, constant: 20),
                emptyContinueWatchingLabel.trailingAnchor.constraint(equalTo: backgroundView.trailingAnchor, constant: -20)
            ])
        }
    }

    func loadContinueWatchingItems() {
        continueWatchingItems = ContinueWatchingManager.shared.getItems()
        continueWatchingCollectionView.reloadData()

        if continueWatchingItems.isEmpty {
            let randomText = funnyTexts.randomElement() ?? "No anime here!"
            emptyContinueWatchingLabel.text = randomText
            emptyContinueWatchingLabel.isHidden = false
            continueWatchingCollectionView.backgroundView?.isHidden = false // Make sure background is visible
        } else {
            emptyContinueWatchingLabel.isHidden = true
             continueWatchingCollectionView.backgroundView?.isHidden = true // Hide background when not empty
        }
        // Reload the table view section containing the continue watching collection view
        tableView.reloadSections(IndexSet(integer: 1), with: .none)
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

            if identifier == "ContinueWatchingCell" {
                collectionView?.register(cellClass, forCellWithReuseIdentifier: identifier)
            } else {
                collectionView?.register(UINib(nibName: identifier, bundle: nil), forCellWithReuseIdentifier: identifier)
            }

             // Add flow layout setup for horizontal scrolling and margins
             if let flowLayout = collectionView?.collectionViewLayout as? UICollectionViewFlowLayout {
                 flowLayout.scrollDirection = .horizontal
                 flowLayout.sectionInset = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16) // Add left/right margins
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
            label.translatesAutoresizingMaskIntoConstraints = false // Ensure Auto Layout is enabled

            let collectionView = collectionViews[index]
            collectionView?.backgroundView = label // Set as background view

            // Add constraints for the label within the background view
            if let backgroundView = collectionView?.backgroundView {
                 NSLayoutConstraint.activate([
                     label.centerXAnchor.constraint(equalTo: backgroundView.centerXAnchor),
                     label.centerYAnchor.constraint(equalTo: backgroundView.centerYAnchor),
                     label.leadingAnchor.constraint(equalTo: backgroundView.leadingAnchor, constant: 16),
                     label.trailingAnchor.constraint(equalTo: backgroundView.trailingAnchor, constant: -16)
                 ])
            }


            let activityIndicator = activityIndicators[index]
            activityIndicator.hidesWhenStopped = true
             collectionView?.addSubview(activityIndicator) // Add indicator as subview
             activityIndicator.translatesAutoresizingMaskIntoConstraints = false
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
        let selectedSource = UserDefaults.standard.string(forKey: "selectedMediaSource") ?? "AnimeWorld"
        selectSourceLable.title = selectedSource // Update the button title directly

         // Update the label below the "Featured" title
         if selectedSourceLabel != nil {
             selectedSourceLabel.text = String(format: NSLocalizedString("on %@%", comment: "Prefix for selected Source"), selectedSource)
         }
    }

    func setupRefreshControl() {
        refreshControl = UIRefreshControl()
        refreshControl?.addTarget(self, action: #selector(refreshData), for: .valueChanged)
        // Add the refresh control to the table view
        tableView.refreshControl = refreshControl
    }


    @objc func refreshData() {
        fetchAnimeData()
    }

    private func setupActivityIndicators() {
        let activityIndicators = [airingActivityIndicator, trendingActivityIndicator, seasonalActivityIndicator, featuredActivityIndicator]
        let collectionViews = [airingCollectionView, trendingCollectionView, seasonalCollectionView, featuredCollectionView]

        for (index, indicator) in activityIndicators.enumerated() {
            guard let collectionView = collectionViews[index] else { continue }

            indicator.hidesWhenStopped = true
            indicator.translatesAutoresizingMaskIntoConstraints = false
            collectionView.addSubview(indicator) // Add as subview, not background

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
        fetchFeaturedAnime { dispatchGroup.leave() }

        dispatchGroup.notify(queue: .main) {
            self.refreshUI()
            self.refreshControl?.endRefreshing()
            [self.airingActivityIndicator, self.trendingActivityIndicator, self.seasonalActivityIndicator, self.featuredActivityIndicator].forEach { $0.stopAnimating() }
        }
    }

    func fetchTrendingAnime(completion: @escaping () -> Void) {
        aniListServiceTrending.fetchTrendingAnime { [weak self] animeList in
            DispatchQueue.main.async { // Ensure UI updates on main thread
                if let animeList = animeList, !animeList.isEmpty {
                    self?.trendingAnime = animeList
                    self?.trendingErrorLabel.isHidden = true
                    self?.trendingCollectionView.backgroundView?.isHidden = true // Hide error label view
                } else {
                    self?.trendingErrorLabel.text = NSLocalizedString("Unable to load trending anime. Make sure to check your connection", comment: "Trending Anime loading error")
                    self?.trendingErrorLabel.isHidden = false
                    self?.trendingCollectionView.backgroundView?.isHidden = false // Show error label view
                }
                 self?.trendingCollectionView.reloadData() // Reload specific collection view
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
                    self?.seasonalCollectionView.backgroundView?.isHidden = true
                } else {
                    self?.seasonalErrorLabel.text = NSLocalizedString("Unable to load seasonal anime. Make sure to check your connection", comment: "Seasonal Anime loading error")
                    self?.seasonalErrorLabel.isHidden = false
                     self?.seasonalCollectionView.backgroundView?.isHidden = false
                }
                 self?.seasonalCollectionView.reloadData()
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
                     self?.airingCollectionView.backgroundView?.isHidden = true
                } else {
                    self?.airingErrorLabel.text = NSLocalizedString("Unable to load airing anime. Make sure to check your connection", comment: "Airing Anime loading error")
                    self?.airingErrorLabel.isHidden = false
                     self?.airingCollectionView.backgroundView?.isHidden = false
                }
                 self?.airingCollectionView.reloadData()
                completion()
            }
        }
    }

    // Use the extension method for fetching featured anime
    private func fetchFeaturedAnime(completion: @escaping () -> Void) {
        let selectedSource = UserDefaults.standard.string(forKey: "selectedMediaSource") ?? "AnimeWorld"
        let (sourceURL, parseStrategy) = getSourceInfo(for: selectedSource)

        DispatchQueue.main.async {
            self.featuredAnime.removeAll()
            self.featuredCollectionView.reloadData()
            self.featuredActivityIndicator.startAnimating()
            self.featuredErrorLabel.isHidden = true
            self.featuredCollectionView.backgroundView?.isHidden = true
        }

        guard let urlString = sourceURL, let url = URL(string: urlString), let parse = parseStrategy else {
            DispatchQueue.main.async {
                self.featuredAnime = []
                self.featuredErrorLabel.text = "Unable to load featured anime. Invalid source or parsing strategy."
                self.featuredErrorLabel.isHidden = false
                self.featuredCollectionView.backgroundView?.isHidden = false
                self.featuredActivityIndicator.stopAnimating()
                completion()
            }
            return
        }

        URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            guard let self = self else { return }

            DispatchQueue.main.async { // Ensure all UI updates happen on main thread
                self.featuredActivityIndicator.stopAnimating() // Stop indicator regardless of outcome

                if let error = error {
                    self.featuredErrorLabel.text = "Error loading featured anime: \(error.localizedDescription)"
                    self.featuredErrorLabel.isHidden = false
                    self.featuredCollectionView.backgroundView?.isHidden = false
                    completion()
                    return
                }

                guard let data = data, let html = String(data: data, encoding: .utf8) else {
                    self.featuredErrorLabel.text = "Error loading featured anime. Invalid data received."
                    self.featuredErrorLabel.isHidden = false
                    self.featuredCollectionView.backgroundView?.isHidden = false
                    completion()
                    return
                }

                do {
                    let doc: Document = try SwiftSoup.parse(html)
                    let animeItems = try parse(doc)

                    if !animeItems.isEmpty {
                        self.featuredAnime = animeItems
                        self.featuredErrorLabel.isHidden = true
                        self.featuredCollectionView.backgroundView?.isHidden = true
                    } else {
                        self.featuredAnime = [] // Clear data if no items found
                        self.featuredErrorLabel.text = "No featured anime found for \(selectedSource)."
                        self.featuredErrorLabel.isHidden = false
                        self.featuredCollectionView.backgroundView?.isHidden = false
                    }
                    self.featuredCollectionView.reloadData() // Reload the specific collection view
                    completion()

                } catch {
                    self.featuredAnime = [] // Clear data on parsing error
                    self.featuredErrorLabel.text = "Error parsing featured anime: \(error.localizedDescription)"
                    self.featuredErrorLabel.isHidden = false
                    self.featuredCollectionView.backgroundView?.isHidden = false
                     self.featuredCollectionView.reloadData()
                    completion()
                }
            }
        }.resume()
    }


    func refreshUI() {
        DispatchQueue.main.async {
            self.loadContinueWatchingItems() // This already reloads the collection view
            self.airingCollectionView.reloadData()
            self.trendingCollectionView.reloadData()
            self.seasonalCollectionView.reloadData()
             // Featured is reloaded within its fetch function
            self.setupDateLabel()
            self.setupSelectedSourceLabel()
        }
    }


    @IBAction func selectSourceButtonTapped(_ sender: UIBarButtonItem) {
        SourceMenu.showSourceSelector(from: self, barButtonItem: sender) { [weak self] in
            self?.setupSelectedSourceLabel()
            // Fetch featured anime immediately after source selection
            self?.fetchFeaturedAnime { [weak self] in
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
            self.setupSelectedSourceLabel() // Ensure label updates correctly
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
        continueWatchingCollectionView.deleteItems(at: [indexPath])

        if continueWatchingItems.isEmpty {
            let randomText = funnyTexts.randomElement() ?? "No anime here!"
            emptyContinueWatchingLabel.text = randomText
            emptyContinueWatchingLabel.isHidden = false
            continueWatchingCollectionView.backgroundView?.isHidden = false
        }
        // Reload the table view section to potentially update its height if needed
        tableView.reloadSections(IndexSet(integer: 1), with: .none)
    }

    @objc func handleAppDataReset() {
        DispatchQueue.main.async {
            self.fetchAnimeData() // Refetch all data
            self.refreshUI() // Update UI elements
        }
    }
}

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
             } else {
                  print("Error: Could not dequeue SlimmAnimeCell") // Debugging
             }
             return cell
        case airingCollectionView:
             let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "AiringAnimeCell", for: indexPath)
             if let airingCell = cell as? AiringAnimeCell {
                 configureAiringCell(airingCell, at: indexPath)
             } else {
                  print("Error: Could not dequeue AiringAnimeCell") // Debugging
             }
             return cell
        default:
            fatalError("Unexpected collection view")
        }
    }

    private func configureSlimmCell(_ cell: SlimmAnimeCell, at indexPath: IndexPath, for collectionView: UICollectionView) {
        switch collectionView {
        case trendingCollectionView:
            guard indexPath.item < trendingAnime.count else { return } // Bounds check
            let anime = trendingAnime[indexPath.item]
            let imageUrl = URL(string: anime.coverImage.large)
            cell.configure(with: anime.title.romaji, imageUrl: imageUrl)
        case seasonalCollectionView:
            guard indexPath.item < seasonalAnime.count else { return } // Bounds check
            let anime = seasonalAnime[indexPath.item]
            let imageUrl = URL(string: anime.coverImage.large)
            cell.configure(with: anime.title.romaji, imageUrl: imageUrl)
        case featuredCollectionView:
            guard indexPath.item < featuredAnime.count else { return } // Bounds check
            let anime = featuredAnime[indexPath.item]
            let imageUrl = URL(string: anime.imageURL)
            cell.configure(with: anime.title, imageUrl: imageUrl)
        default:
            break
        }
    }

    private func configureAiringCell(_ cell: AiringAnimeCell, at indexPath: IndexPath) {
         guard indexPath.item < airingAnime.count else { return } // Bounds check
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

extension HomeViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        switch collectionView {
        case continueWatchingCollectionView:
             guard indexPath.item < continueWatchingItems.count else { return } // Bounds check
            let item = continueWatchingItems[indexPath.item]
            resumeWatching(item: item)
        case trendingCollectionView:
             guard indexPath.item < trendingAnime.count else { return } // Bounds check
            let anime = trendingAnime[indexPath.item]
            navigateToAnimeDetail(for: anime)
        case seasonalCollectionView:
             guard indexPath.item < seasonalAnime.count else { return } // Bounds check
            let anime = seasonalAnime[indexPath.item]
            navigateToAnimeDetail(for: anime)
        case airingCollectionView:
             guard indexPath.item < airingAnime.count else { return } // Bounds check
            let anime = airingAnime[indexPath.item]
            navigateToAnimeDetail(for: anime)
        case featuredCollectionView:
             guard indexPath.item < featuredAnime.count else { return } // Bounds check
            let anime = featuredAnime[indexPath.item]
            navigateToAnimeDetail(title: anime.title, imageUrl: anime.imageURL, href: anime.href)
        default:
            break
        }
    }

    private func resumeWatching(item: ContinueWatchingItem) {
        let detailVC = AnimeDetailViewController()

        // Configure detailVC with item data
        detailVC.configure(title: item.animeTitle, imageUrl: item.imageURL, href: item.fullURL, source: item.source)

        // Set the selected source in UserDefaults *before* pushing
        UserDefaults.standard.set(item.source, forKey: "selectedMediaSource")
        didSelectNewSource() // Update UI elements related to source if needed

        // Show loading banner *before* fetching details, as fetching happens in detailVC's viewDidLoad
        detailVC.showLoadingBanner()

        // Push the view controller
        navigationController?.pushViewController(detailVC, animated: true)

        // After pushing, we need to find the episode and trigger selection *within* detailVC
        // This needs detailVC to be loaded first. We can pass the info or use a completion block.
        // For simplicity, let's assume detailVC handles resuming based on the passed href/fullURL on its load.
        // If detailVC needs explicit triggering, you might need a delegate pattern or pass the episode info.

        // Example of passing info (if needed):
        // detailVC.initialEpisodeToPlayHref = item.fullURL // Add this property to detailVC
        // detailVC.initialPlaybackTime = item.lastPlayedTime
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
         let selectedMedaiSource = UserDefaults.standard.string(forKey: "selectedMediaSource") ?? "" // Ensure source is set

         detailVC.configure(title: title, imageUrl: imageUrl, href: href, source: selectedMedaiSource)
         navigationController?.pushViewController(detailVC, animated: true)
     }
}

// MARK: - Context Menu Delegate Implementation
extension HomeViewController { // Keep UIContextMenuInteractionDelegate conformance

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
         guard let collectionView = interaction.view as? UICollectionView,
               let indexPath = collectionView.indexPathForItem(at: location) else { return nil }

         // Determine which collection view it is and get the corresponding section index
         let section: Int
         switch collectionView {
         case trendingCollectionView: section = 0
         case seasonalCollectionView: section = 1
         case airingCollectionView: section = 2
         // Add featuredCollectionView if needed, assign a unique section number (e.g., 3)
          case featuredCollectionView: section = 3 // Example section index
         default: return nil // Don't show menu for other collection views like Continue Watching
         }

        // Use a combined IndexPath (item from collection view, section from mapping) as the identifier
        let contextIdentifier = IndexPath(item: indexPath.item, section: section) as NSCopying

        return UIContextMenuConfiguration(identifier: contextIdentifier, previewProvider: { [weak self] in
            // Pass the combined IndexPath to the preview provider
            self?.previewViewController(for: contextIdentifier as! IndexPath)
        }, actionProvider: { [weak self] _ in
            guard let self = self else { return nil }
            // Pass the combined IndexPath to action handlers
            let openAction = UIAction(title: "Open", image: UIImage(systemName: "eye")) { _ in
                self.openAnimeDetail(for: contextIdentifier as! IndexPath)
            }

            let searchAction = UIAction(title: "Search Episodes", image: UIImage(systemName: "magnifyingglass")) { _ in
                self.searchEpisodes(for: contextIdentifier as! IndexPath)
            }

            return UIMenu(title: "", children: [openAction, searchAction])
        })
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, previewForHighlightingMenuWithConfiguration configuration: UIContextMenuConfiguration) -> UITargetedPreview? {
         guard let combinedIndexPath = configuration.identifier as? IndexPath,
               let cell = cellForIndexPath(combinedIndexPath) else {
                   return nil
               }

         let parameters = UIPreviewParameters()
         parameters.backgroundColor = .clear
         let previewTarget = UIPreviewTarget(container: cell.superview!, center: cell.center) // Use cell's center in its superview

         return UITargetedPreview(view: cell, parameters: parameters, target: previewTarget)
     }

     func contextMenuInteraction(_ interaction: UIContextMenuInteraction, previewForDismissingMenuWithConfiguration configuration: UIContextMenuConfiguration) -> UITargetedPreview? {
          guard let combinedIndexPath = configuration.identifier as? IndexPath,
                let cell = cellForIndexPath(combinedIndexPath) else {
                    return nil
                }
          let parameters = UIPreviewParameters()
          parameters.backgroundColor = .clear
          let previewTarget = UIPreviewTarget(container: cell.superview!, center: cell.center)

          return UITargetedPreview(view: cell, parameters: parameters, target: previewTarget)
      }

    // Helper to get the correct anime data based on the *combined* IndexPath's section
    private func animeForIndexPath(_ combinedIndexPath: IndexPath) -> Anime? { // Return optional Anime
        // Handle only sections that correspond to Anilist data (Anime struct)
        switch combinedIndexPath.section {
        case 0: // Trending
            guard combinedIndexPath.item < trendingAnime.count else { return nil }
            return trendingAnime[combinedIndexPath.item]
        case 1: // Seasonal
            guard combinedIndexPath.item < seasonalAnime.count else { return nil }
            return seasonalAnime[combinedIndexPath.item]
        case 2: // Airing
            guard combinedIndexPath.item < airingAnime.count else { return nil }
            return airingAnime[combinedIndexPath.item]
        // Section 3 (Featured) uses AnimeItem, not Anime, so return nil here
        case 3:
             return nil // Featured anime uses AnimeItem struct
        default:
            return nil
        }
    }

    // Helper to get the correct AnimeItem data for the featured section
     private func animeItemForIndexPath(_ combinedIndexPath: IndexPath) -> AnimeItem? {
         guard combinedIndexPath.section == 3, // Ensure it's the featured section
               combinedIndexPath.item < featuredAnime.count else {
             return nil
         }
         return featuredAnime[combinedIndexPath.item]
     }


     // Updated preview provider
     private func previewViewController(for combinedIndexPath: IndexPath) -> UIViewController? {
          if let anime = animeForIndexPath(combinedIndexPath) { // Handles Anilist sections
              let storyboard = UIStoryboard(name: "AnilistAnimeInformation", bundle: nil)
              guard let animeDetailVC = storyboard.instantiateViewController(withIdentifier: "AnimeInformation") as? AnimeInformation else {
                  return nil
              }
              animeDetailVC.animeID = anime.id
              return animeDetailVC
          } else if let animeItem = animeItemForIndexPath(combinedIndexPath) { // Handles Featured section
              let detailVC = AnimeDetailViewController()
              let selectedMedaiSource = UserDefaults.standard.string(forKey: "selectedMediaSource") ?? ""
              detailVC.configure(title: animeItem.title, imageUrl: animeItem.imageURL, href: animeItem.href, source: selectedMedaiSource)
              // We need to fetch data within the preview if possible, or show basic info
              // For simplicity, returning the configured VC; it will load data when fully presented.
              return detailVC
          }
          return nil
      }

    // Updated action handler
    private func openAnimeDetail(for combinedIndexPath: IndexPath) {
         if let anime = animeForIndexPath(combinedIndexPath) {
             navigateToAnimeDetail(for: anime)
         } else if let animeItem = animeItemForIndexPath(combinedIndexPath) {
             navigateToAnimeDetail(title: animeItem.title, imageUrl: animeItem.imageURL, href: animeItem.href)
         }
     }

     // Updated action handler
     private func searchEpisodes(for combinedIndexPath: IndexPath) {
          var query: String?
          if let anime = animeForIndexPath(combinedIndexPath) {
              query = anime.title.romaji // Use romaji title for Anilist items
          } else if let animeItem = animeItemForIndexPath(combinedIndexPath) {
              query = animeItem.title // Use the title from AnimeItem
          }

          guard let searchQuery = query, !searchQuery.isEmpty else {
              showError(message: "Could not find anime title.")
              return
          }
          searchMedia(query: searchQuery)
      }

    // Updated helper to get the correct cell based on combined IndexPath
    private func cellForIndexPath(_ combinedIndexPath: IndexPath) -> UICollectionViewCell? {
         let collectionViews = [trendingCollectionView, seasonalCollectionView, airingCollectionView, featuredCollectionView] // Added featured
         guard combinedIndexPath.section < collectionViews.count else { return nil }
         // Use item from combinedIndexPath, section 0 for the specific collection view
         return collectionViews[combinedIndexPath.section]?.cellForItem(at: IndexPath(item: combinedIndexPath.item, section: 0))
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

// AnimeItem definition (ensure it exists)
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

// Anime struct definition (ensure it exists)
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

// Supporting structs (ensure they exist)
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
