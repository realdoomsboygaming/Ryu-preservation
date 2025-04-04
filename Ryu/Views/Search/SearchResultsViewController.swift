//
//  SearchResultsViewController.swift
//  Ryu
//
//  Created by Francesco on 21/06/24.
//

import UIKit
import Kingfisher
import Alamofire
import SwiftSoup
import SafariServices

class SearchResultsViewController: UIViewController {
    
    private lazy var tableView: UITableView = {
        let table = UITableView()
        table.translatesAutoresizingMaskIntoConstraints = false
        return table
    }()
    
    private lazy var changeSourceButton: UIButton = {
        let button = UIButton(type: .system)
        button.setTitle("Change Source", for: .normal)
        button.addTarget(self, action: #selector(changeSourceButtonTapped), for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()
    
    private let loadingIndicator = UIActivityIndicatorView(style: .large)
    private let errorLabel = UILabel()
    private let noResultsLabel = UILabel()
    
    var searchResults: [(title: String, imageUrl: String, href: String)] = []
    var filteredResults: [(title: String, imageUrl: String, href: String)] = []
    var query: String = ""
    var selectedSource: String = ""
    
    private lazy var sortButton: UIBarButtonItem = {
        let button = UIBarButtonItem(image: UIImage(systemName: "arrow.up.arrow.down"), style: .plain, target: self, action: #selector(sortButtonTapped))
        return button
    }()
    
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        
        setupUI()
        fetchResults()
    }
    
    private func setupUI() {
        navigationItem.largeTitleDisplayMode = .never
        
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        ])
        
        tableView.dataSource = self
        tableView.delegate = self
        tableView.backgroundColor = .systemBackground
        tableView.register(SearchResultCell.self, forCellReuseIdentifier: "resultCell")
        
        setupLoadingIndicator()
        setupErrorLabel()
        setupNoResultsLabel()
        
        if let selectedSource = UserDefaults.standard.selectedMediaSource {
            switch selectedSource {
            case .animeWorld, .gogoanime, .kuramanime, .animefire:
                navigationItem.rightBarButtonItem = sortButton
            default:
                break
            }
        }
    }
    
    private func setupLoadingIndicator() {
        loadingIndicator.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(loadingIndicator)
        NSLayoutConstraint.activate([
            loadingIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            loadingIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }
    
    private func setupErrorLabel() {
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        errorLabel.textAlignment = .center
        errorLabel.numberOfLines = 0
        errorLabel.isHidden = true
        view.addSubview(errorLabel)
        NSLayoutConstraint.activate([
            errorLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            errorLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            errorLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            errorLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20)
        ])
    }
    
    private func setupNoResultsLabel() {
        noResultsLabel.translatesAutoresizingMaskIntoConstraints = false
        noResultsLabel.textAlignment = .center
        noResultsLabel.text = "No results found"
        noResultsLabel.isHidden = true
        
        view.addSubview(noResultsLabel)
        view.addSubview(changeSourceButton)
        
        NSLayoutConstraint.activate([
            noResultsLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            noResultsLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            
            changeSourceButton.topAnchor.constraint(equalTo: noResultsLabel.bottomAnchor, constant: 20),
            changeSourceButton.centerXAnchor.constraint(equalTo: view.centerXAnchor)
        ])
    }
    
    @objc private func sortButtonTapped() {
        let alertController = UIAlertController(title: "Sort Anime", message: nil, preferredStyle: .actionSheet)
        
        let allAction = UIAlertAction(title: "All", style: .default) { [weak self] _ in
            self?.filterResults(option: .all)
        }
        
        switch UserDefaults.standard.selectedMediaSource {
        case .gogoanime:
            let dubAction = UIAlertAction(title: "Dub", style: .default) { [weak self] _ in
                self?.filterResults(option: .dub)
            }
            let subAction = UIAlertAction(title: "Sub", style: .default) { [weak self] _ in
                self?.filterResults(option: .sub)
            }
            alertController.addAction(dubAction)
            alertController.addAction(subAction)
        case .animeWorld:
            let itaAction = UIAlertAction(title: "ITA", style: .default) { [weak self] _ in
                self?.filterResults(option: .ita)
            }
            alertController.addAction(itaAction)
        case .kuramanime:
            let dubAction = UIAlertAction(title: "Dub", style: .default) { [weak self] _ in
                self?.filterResults(option: .dub)
            }
            alertController.addAction(dubAction)
        case .animefire:
            let dubAction = UIAlertAction(title: "Dub", style: .default) { [weak self] _ in
                self?.filterResults(option: .dub)
            }
            alertController.addAction(dubAction)
        case .animeunity:
            let itaAction = UIAlertAction(title: "ITA", style: .default) { [weak self] _ in
                self?.filterResults(option: .ita)
            }
            alertController.addAction(itaAction)
        default:
            break
        }
        
        alertController.addAction(allAction)
        
        let cancelAction = UIAlertAction(title: "Cancel", style: .cancel, handler: nil)
        alertController.addAction(cancelAction)
        
        if let popoverController = alertController.popoverPresentationController {
            popoverController.barButtonItem = sortButton
        }
        
        present(alertController, animated: true, completion: nil)
    }
    
    private enum FilterOption {
        case all, dub, sub, ita
    }
    
    private func filterResults(option: FilterOption) {
        switch option {
        case .all:
            filteredResults = searchResults
        case .dub:
            switch selectedSource {
            case "GoGoAnime":
                filteredResults = searchResults.filter { $0.title.lowercased().contains("(dub)") }
            case "Kuramanime":
                filteredResults = searchResults.filter { $0.title.contains("(Dub ID)") }
            case "AnimeFire":
                filteredResults = searchResults.filter { $0.title.contains("(Dublado)") }
            default:
                filteredResults = searchResults
            }
        case .sub:
            filteredResults = searchResults.filter { !$0.title.lowercased().contains("(dub)") }
        case .ita:
            filteredResults = searchResults.filter { $0.title.contains("ITA") }
        }
        
        tableView.reloadData()
    }
    
    @objc private func changeSourceButtonTapped() {
        SourceMenu.showSourceSelector(from: self, sourceView: changeSourceButton) { [weak self] in
            self?.refreshResults()
        }
    }
    
    func refreshResults() {
        fetchResults()
    }
    
    private func fetchResults() {
        let session = proxySession.createAlamofireProxySession()
        
        loadingIndicator.startAnimating()
        tableView.isHidden = true
        errorLabel.isHidden = true
        noResultsLabel.isHidden = true
        changeSourceButton.isHidden = true
        
        guard let selectedSource = UserDefaults.standard.selectedMediaSource?.rawValue else {
            loadingIndicator.stopAnimating()
            SourceMenu.showSourceSelector(from: self, sourceView: view) { [weak self] in
                self?.refreshResults()
            }
            return
        }
        
        guard let urlParameters = getUrlAndParameters(for: selectedSource) else {
            showError("Unsupported media source.")
            SourceMenu.showSourceSelector(from: self, sourceView: view) { [weak self] in
                self?.refreshResults()
            }
            return
        }
        
        if selectedSource == "GoGoAnime" {
            DispatchQueue.main.async {
                self.fetchGoGoResults(urlParameters: urlParameters)
            }
        } else {
            session.request(urlParameters.url, method: .get, parameters: urlParameters.parameters).responseString { [weak self] response in
                guard let self = self else { return }
                self.loadingIndicator.stopAnimating()
                
                switch response.result {
                case .success(let value):
                    let results = self.parseHTML(html: value, for: MediaSource(rawValue: selectedSource) ?? .animeWorld)
                    self.searchResults = results
                    self.filteredResults = results
                    if results.isEmpty {
                        self.showNoResults()
                    } else {
                        self.tableView.isHidden = false
                        self.tableView.reloadData()
                    }
                case .failure(let error):
                    if let httpStatusCode = response.response?.statusCode {
                        switch httpStatusCode {
                        case 400:
                            self.showError("Bad request. Please check your input and try again.")
                        case 403:
                            self.showError("Access forbidden. You don't have permission to access this resource.")
                        case 404:
                            self.showError("Resource not found. Please try a different search.")
                        case 429:
                            self.showError("Too many requests. Please slow down and try again later.")
                        case 500:
                            self.showError("Internal server error. Please try again later.")
                        case 502:
                            self.showError("Bad gateway. The server is temporarily unable to handle the request.")
                        case 503:
                            self.showError("Service unavailable. Please try again later.")
                        case 504:
                            self.showError("Gateway timeout. The server took too long to respond.")
                        default:
                            self.showError("Unexpected error occurred. Please try again later.")
                        }
                    } else if let nsError = error as NSError?, nsError.domain == NSURLErrorDomain {
                        switch nsError.code {
                        case NSURLErrorNotConnectedToInternet:
                            self.showError("No internet connection. Please check your network and try again.")
                        case NSURLErrorTimedOut:
                            self.showError("Request timed out. Please try again later.")
                        default:
                            self.showError("Network error occurred. Please try again later.")
                        }
                    } else {
                        self.showError("Failed to fetch data. Please try again later.")
                    }
                }
            }
        }
    }
    
    private func fetchGoGoResults(urlParameters: (url: String, parameters: Parameters)) {
        let session = proxySession.createAlamofireProxySession()
        let group = DispatchGroup()
        var allResults: [(title: String, imageUrl: String, href: String)] = []
        
        group.enter()
        session.request(urlParameters.url, method: .get, parameters: urlParameters.parameters).responseString { [weak self] response in
            defer { group.leave() }
            if let value = try? response.result.get(),
               let document = try? SwiftSoup.parse(value),
               let results = self?.parseGoGoAnime(document) {
                allResults.append(contentsOf: results)
            }
        }
        group.enter()
        session.request(urlParameters.url + "&page=2", method: .get, parameters: urlParameters.parameters).responseString { [weak self] response in
            defer { group.leave() }
            if let value = try? response.result.get(),
               let document = try? SwiftSoup.parse(value),
               let results = self?.parseGoGoAnime(document) {
                allResults.append(contentsOf: results)
            }
        }
        group.enter()
        session.request(urlParameters.url + "&page=3", method: .get, parameters: urlParameters.parameters).responseString { [weak self] response in
            defer { group.leave() }
            if let value = try? response.result.get(),
               let document = try? SwiftSoup.parse(value),
               let results = self?.parseGoGoAnime(document) {
                allResults.append(contentsOf: results)
            }
        }
        
        group.notify(queue: .main) { [weak self] in
            self?.loadingIndicator.stopAnimating()
            self?.searchResults = allResults
            self?.filteredResults = allResults
            if allResults.isEmpty {
                self?.showNoResults()
            } else {
                self?.tableView.isHidden = false
                self?.tableView.reloadData()
            }
        }
    }
    
    private func getUrlAndParameters(for source: String) -> (url: String, parameters: Parameters)? {
        let url: String
        var parameters: Parameters = [:]
        
        switch source {
        case "AnimeWorld":
            url = "https://animeworld.so/search"
            parameters["keyword"] = query
        case "GoGoAnime":
            url = "https://anitaku.bz/search.html"
            parameters["keyword"] = query
        case "AnimeHeaven":
            url = "https://animeheaven.me/search.php"
            parameters["s"] = query
        case "AnimeFire":
            let encodedQuery = query.lowercased().replacingOccurrences(of: " ", with: "-").addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? query
            url = "https://animefire.plus/pesquisar/\(encodedQuery)"
        case "Kuramanime":
            url = "https://kuramanime.red/anime"
            parameters["search"] = query
        case "Anime3rb":
            url = "https://anime3rb.com/search"
            parameters["q"] = query
        case "HiAnime":
            let baseUrls = ["https://aniwatch-api-gp1w.onrender.com/anime/search"]
            url = baseUrls.randomElement()!
            parameters["q"] = query
        case "Anilibria":
            url = "https://api.anilibria.tv/v3/title/search"
            parameters["search"] = query
            parameters["filter"] = "id,names,posters"
        case "AnimeSRBIJA":
            url = "https://www.animesrbija.com/filter"
            parameters["search"] = query
        case "AniWorld":
            url = "https://aniworld.to/animes"
            parameters = [:]
        case "TokyoInsider":
            url = "https://www.tokyoinsider.com/anime/search"
            parameters["k"] = query
        case "AniVibe":
            url = "https://anivibe.net/search.html"
            parameters["keyword"] = query
        case "AnimeUnity":
            url = "https://www.animeunity.to/archivio"
            parameters["title"] = query
        case "AnimeFLV":
            url = "https://www3.animeflv.net/browse"
            parameters["q"] = query
        case "AnimeBalkan":
            url = "https://animebalkan.gg/"
            parameters["s"] = query
        case "AniBunker":
            url = "https://www.anibunker.com/search"
            parameters["q"] = query
        default:
            return nil
        }
        
        return (url, parameters)
    }

    private func fuzzySearch(_ query: String, in results: [(title: String, imageUrl: String, href: String)]) -> [(title: String, imageUrl: String, href: String)] {
        return results.filter { result in
            let title = result.title.lowercased()
            let searchQuery = query.lowercased()
            
            if title.contains(searchQuery) {
                return true
            }
            
            let titleWords = title.components(separatedBy: .whitespaces)
            let queryWords = searchQuery.components(separatedBy: .whitespaces)
            
            for queryWord in queryWords {
                for titleWord in titleWords {
                    if titleWord.contains(queryWord) || queryWord.contains(titleWord) {
                        return true
                    }
                }
            }
            
            return false
        }
    }
    
    private func showError(_ message: String) {
        loadingIndicator.stopAnimating()
        errorLabel.text = message
        errorLabel.isHidden = false
    }
    
    private func showNoResults() {
        noResultsLabel.isHidden = false
        changeSourceButton.isHidden = false
    }

    private func parseHiAnime(_ jsonString: String) -> [(title: String, imageUrl: String, href: String)] {
        do {
            guard let data = jsonString.data(using: .utf8),
                let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                let results = json["results"] as? [[String: Any]] else {
            print("Invalid HiAnime JSON format")
            return []
        }
        
        return results.compactMap { item -> (title: String, imageUrl: String, href: String)? in
            guard let title = item["title"] as? String,
                  let image = item["image"] as? String,
                  let id = item["id"] as? String else {
                return nil
            }
            
            // Construct the href - adjust path as needed
            let href = "/anime/\(id)"
            return (title: title, imageUrl: image, href: href)
        }
    } catch {
        print("Error parsing HiAnime JSON: \(error.localizedDescription)")
        return []
    }
}

    private func parseDocument(_ document: Document?, jsonString: String?, for source: MediaSource) -> [(title: String, imageUrl: String, href: String)] {
        switch source {
        case .animeWorld:
            guard let document = document else { return [] }
            return parseAnimeWorld(document)
        case .gogoanime:
            guard let document = document else { return [] }
            return parseGoGoAnime(document)
        case .animeheaven:
            guard let document = document else { return [] }
            return parseAnimeHeaven(document)
        case .animefire:
            guard let document = document else { return [] }
            return parseAnimeFire(document)
        case .kuramanime:
            guard let document = document else { return [] }
            return parseKuramanime(document)
        case .anime3rb:
            guard let document = document else { return [] }
            return parseAnime3rb(document)
        case .hianime:
            guard let jsonString = jsonString else { return [] }
            return parseHiAnime(jsonString)
        case .anilibria:
            guard let jsonString = jsonString else { return [] }
            return parseAnilibria(jsonString)
        case .animesrbija:
            guard let document = document else { return [] }
            return parseAnimeSRBIJA(document)
        case .aniworld:
            guard let document = document else { return [] }
            return parseAniWorld(document)
        case .tokyoinsider:
            guard let document = document else { return [] }
            return parseTokyoInsider(document)
        case .anivibe:
            guard let document = document else { return [] }
            return parseAniVibe(document)
        case .animeunity:
            guard let document = document else { return [] }
            return parseAnimeUnity(document)
        case .animeflv:
            guard let document = document else { return [] }
            return parseAnimeFLV(document)
        case .animebalkan:
            guard let document = document else { return [] }
            return parseAnimeBalkan(document)
        case .anibunker:
            guard let document = document else { return [] }
            return parseAniBunker(document)
        }
    }
    
    private func navigateToAnimeDetail(title: String, imageUrl: String, href: String) {
        let detailVC = AnimeDetailViewController()
        let selectedMedaiSource = UserDefaults.standard.string(forKey: "selectedMediaSource") ?? ""
        
        detailVC.configure(title: title, imageUrl: imageUrl, href: href, source: selectedMedaiSource)
        navigationController?.pushViewController(detailVC, animated: true)
    }
}

extension SearchResultsViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return filteredResults.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "resultCell", for: indexPath) as! SearchResultCell
        let result = filteredResults[indexPath.row]
        cell.configure(with: result)
        return cell
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let selectedResult = filteredResults[indexPath.row]
        navigateToAnimeDetail(title: selectedResult.title, imageUrl: selectedResult.imageUrl, href: selectedResult.href)
    }
}

extension SearchResultsViewController: UIContextMenuInteractionDelegate {
    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard let cell = interaction.view as? UITableViewCell,
              let indexPath = tableView.indexPath(for: cell) else {
                  return nil
              }
        
        let result = searchResults[indexPath.row]
        
        return UIContextMenuConfiguration(identifier: nil, previewProvider: {
            let detailVC = AnimeDetailViewController()
            let selectedMedaiSource = UserDefaults.standard.string(forKey: "selectedMediaSource") ?? ""
            detailVC.configure(title: result.title, imageUrl: result.imageUrl, href: result.href, source: selectedMedaiSource)
            return detailVC
        }, actionProvider: { _ in
            let openAction = UIAction(title: "Open", image: UIImage(systemName: "arrow.up.right.square")) { [weak self] _ in
                self?.navigateToAnimeDetail(title: result.title, imageUrl: result.imageUrl, href: result.href)
            }
            
            let openInBrowserAction = UIAction(title: "Open in Browser", image: UIImage(systemName: "globe")) { [weak self] _ in
                self?.openInBrowser(path: result.href)
            }
            
            let favoriteAction = UIAction(title: self.isFavorite(for: result) ? "Remove from the Library" : "Add to Library", image: UIImage(systemName: self.isFavorite(for: result) ? "bookmark.fill" : "bookmark")) { [weak self] _ in
                self?.toggleFavorite(for: result)
            }
            
            return UIMenu(title: "", children: [openAction, openInBrowserAction, favoriteAction])
        })
    }
    
    private func openInBrowser(path: String) {
        let selectedSource = UserDefaults.standard.string(forKey: "selectedMediaSource") ?? ""
        let baseUrl: String
        
        switch selectedSource {
        case "AnimeWorld":
            baseUrl = "https://animeworld.so"
        case "GoGoAnime":
            baseUrl = "https://anitaku.bz"
        case "AnimeHeaven":
            baseUrl = "https://animeheaven.me/"
        case "HiAnime":
            baseUrl = "https://hianime.to/watch/"
        default:
            baseUrl = ""
        }
        
        let fullUrlString = baseUrl + path
        
        guard let url = URL(string: fullUrlString) else {
            print("Invalid URL string: \(fullUrlString)")
            showAlert(withTitle: "Error", message: "The URL is invalid.")
            return
        }
        
        let safariViewController = SFSafariViewController(url: url)
        present(safariViewController, animated: true, completion: nil)
    }
    
    private func showAlert(withTitle title: String, message: String) {
        let alertController = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alertController.addAction(UIAlertAction(title: "OK", style: .default, handler: nil))
        present(alertController, animated: true, completion: nil)
    }
    
    private func isFavorite(for result: (title: String, imageUrl: String, href: String)) -> Bool {
        guard let anime = createFavoriteAnime(from: result) else { return false }
        return FavoritesManager.shared.isFavorite(anime)
    }
    
    private func toggleFavorite(for result: (title: String, imageUrl: String, href: String)) {
        guard let anime = createFavoriteAnime(from: result) else { return }
        
        if FavoritesManager.shared.isFavorite(anime) {
            FavoritesManager.shared.removeFavorite(anime)
        } else {
            FavoritesManager.shared.addFavorite(anime)
        }
        
        if let index = searchResults.firstIndex(where: { $0.href == result.href }) {
            tableView.reloadRows(at: [IndexPath(row: index, section: 0)], with: .automatic)
        }
    }
    
    private func createFavoriteAnime(from result: (title: String, imageUrl: String, href: String)) -> FavoriteItem? {
        guard let imageURL = URL(string: result.imageUrl),
              let contentURL = URL(string: result.href) else {
                  return nil
              }
        let selectedMediaSource = UserDefaults.standard.string(forKey: "selectedMediaSource") ?? "AnimeWorld"
        
        return FavoriteItem(title: result.title, imageURL: imageURL, contentURL: contentURL, source: selectedMediaSource)
    }
}

class SearchResultCell: UITableViewCell {
    let animeImageView = UIImageView()
    let titleLabel = UILabel()
    let disclosureIndicatorImageView = UIImageView()
    
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setupViews()
        configureAppearance()
    }
    
    override func setHighlighted(_ highlighted: Bool, animated: Bool) {
        super.setHighlighted(highlighted, animated: animated)
        UIView.animate(withDuration: 0.1) {
            self.contentView.alpha = highlighted ? 0.7 : 1.0
        }
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupViews() {
        animeImageView.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        disclosureIndicatorImageView.translatesAutoresizingMaskIntoConstraints = false
        
        contentView.addSubview(animeImageView)
        contentView.addSubview(titleLabel)
        contentView.addSubview(disclosureIndicatorImageView)
        
        NSLayoutConstraint.activate([
            animeImageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            animeImageView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            animeImageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
            animeImageView.widthAnchor.constraint(equalToConstant: 100),
            
            titleLabel.leadingAnchor.constraint(equalTo: animeImageView.trailingAnchor, constant: 15),
            titleLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: disclosureIndicatorImageView.leadingAnchor, constant: -10),
            
            disclosureIndicatorImageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -10),
            disclosureIndicatorImageView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            disclosureIndicatorImageView.widthAnchor.constraint(equalToConstant: 10),
            disclosureIndicatorImageView.heightAnchor.constraint(equalToConstant: 15)
        ])
        
        NSLayoutConstraint.activate([
            contentView.heightAnchor.constraint(equalToConstant: 160)
        ])
        
        animeImageView.clipsToBounds = true
        animeImageView.contentMode = .scaleAspectFill
        
        titleLabel.font = UIFont.systemFont(ofSize: 15, weight: .regular)
        titleLabel.numberOfLines = 0
        titleLabel.lineBreakMode = .byWordWrapping
        
        disclosureIndicatorImageView.image = UIImage(systemName: "chevron.compact.right")
        disclosureIndicatorImageView.tintColor = .gray
    }
    
    private func configureAppearance() {
        backgroundColor = UIColor.systemBackground
    }
    
    func configure(with result: (title: String, imageUrl: String, href: String)) {
        titleLabel.text = result.title
        if let url = URL(string: result.imageUrl) {
            animeImageView.kf.setImage(with: url, placeholder: UIImage(systemName: "photo"), options: [.transition(.fade(0.2)), .cacheOriginalImage])
        }
    }
}
