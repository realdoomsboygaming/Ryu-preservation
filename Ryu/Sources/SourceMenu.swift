import UIKit

class SourceMenu {
    static weak var delegate: SourceSelectionDelegate?
    
    static func showSourceSelector(from viewController: UIViewController, barButtonItem: UIBarButtonItem? = nil, sourceView: UIView? = nil, completion: (() -> Void)? = nil) {
        DispatchQueue.main.async {
            let sources: [(title: String, source: MediaSource, language: String)] = [
                ("AnimeWorld", .animeWorld, "🇮🇹"),
                ("GoGoAnime", .gogoanime, "🇺🇸"),
                ("AnimeHeaven", .animeheaven, "🇺🇸"),
                ("AnimeFire", .animefire, "🇧🇷"),
                ("Kuramanime", .kuramanime, "🇮🇩"),
                ("Anime3rb", .anime3rb, "🇸🇦"),
                ("Anilibria", .anilibria, "🇷🇺"),
                ("AniList", .anilist, "🇺🇸"),
                ("AnimeSRBIJA", .animesrbija, "🇭🇷"),
                ("AniWorld", .aniworld, "🇩🇪"),
                ("TokyoInsider", .tokyoinsider, "🇺🇸"),
                ("AniVibe", .anivibe, "🇺🇸"),
                ("AnimeUnity", .animeunity, "🇮🇹"),
                ("AnimeFLV", .animeflv, "🇪🇸"),
                ("AnimeBalkan", .animebalkan, "🇭🇷"),
                ("AniBunker", .anibunker, "🇵🇹")
            ]
            
            let alertController = UIAlertController(title: "Select Source", message: "Choose your preferred source.", preferredStyle: .actionSheet)
            
            for (title, source, language) in sources {
                let actionTitle = "\(title) - \(language)"
                let action = UIAlertAction(title: actionTitle, style: .default) { _ in
                    UserDefaults.standard.selectedMediaSource = source
                    completion?()
                    delegate?.didSelectNewSource()
                }
                // Assuming you will rename the asset image as well
                setSourceImage(for: action, named: title == "AniList" ? "AniList" : title)
                alertController.addAction(action)
            }
            
            alertController.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            
            if let popoverController = alertController.popoverPresentationController {
                if let barButtonItem = barButtonItem {
                    popoverController.barButtonItem = barButtonItem
                } else if let sourceView = sourceView, sourceView.window != nil {
                    popoverController.sourceView = sourceView
                    popoverController.sourceRect = sourceView.bounds
                } else {
                    popoverController.sourceView = viewController.view
                    popoverController.sourceRect = viewController.view.bounds
                }
            }
            
            viewController.present(alertController, animated: true)
        }
    }
    
    private static func setSourceImage(for action: UIAlertAction, named imageName: String) {
        guard let originalImage = UIImage(named: imageName) else { return }
        let resizedImage = originalImage.resized(to: CGSize(width: 35, height: 35))
        action.setValue(resizedImage.withRenderingMode(.alwaysOriginal), forKey: "image")
    }
}

protocol SourceSelectionDelegate: AnyObject {
    func didSelectNewSource()
}
