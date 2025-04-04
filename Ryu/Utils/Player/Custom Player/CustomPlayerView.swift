import UIKit
import AVKit

class CustomPlayerView: UIViewController {

    private var playerView: CustomVideoPlayerView!

    private var videoTitle: String
    private var videoURL: URL
    private var subURL: URL?
    private var cell: EpisodeCell
    private var fullURL: String
    private var animeImage: String

    weak var delegate: CustomPlayerViewDelegate?

    init(videoTitle: String, videoURL: URL, subURL: URL? = nil, cell: EpisodeCell, fullURL: String, image: String) {
        self.videoTitle = videoTitle
        self.videoURL = videoURL
        self.subURL = subURL
        self.cell = cell
        self.fullURL = fullURL
        self.animeImage = image
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .black

        setupAudioSession()

        // Initialize playerView with required parameters
        playerView = CustomVideoPlayerView(frame: view.bounds, cell: cell, fullURL: fullURL, image: animeImage)
        view.addSubview(playerView)

        playerView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            playerView.topAnchor.constraint(equalTo: view.topAnchor),
            playerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            playerView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        playerView.setVideo(url: videoURL, title: videoTitle, subURL: subURL, cell: cell, fullURL: fullURL)
    }

    private func setupAudioSession() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .moviePlayback, options: .mixWithOthers) // Allow mixing
            try audioSession.setActive(true)
            // Removed overrideOutputAudioPort, as it might interfere with AirPlay/Bluetooth
            // try audioSession.overrideOutputAudioPort(.speaker)
        } catch {
            print("Failed to set up AVAudioSession: \(error)")
        }
    }

    override var prefersHomeIndicatorAutoHidden: Bool {
        return true
    }

    override var prefersStatusBarHidden: Bool {
        return true
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        if UserDefaults.standard.bool(forKey: "AlwaysLandscape") {
            return .landscape
        } else {
            return .all // Allow all orientations if not forced
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        playerView.play() // Start playback when view appears
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
         // No need to pause here if we want playback to continue in PiP or background
         // playerView.pause()
    }


    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
         // Don't pause if PiP is active
         if playerView?.isPiPActive() != true {
              playerView?.pause()
         }
        delegate?.customPlayerViewDidDismiss() // Notify delegate
    }
}

// Delegate remains the same
protocol CustomPlayerViewDelegate: AnyObject {
    func customPlayerViewDidDismiss()
}

// Add this extension to CustomVideoPlayerView to check PiP state
extension CustomVideoPlayerView {
     func isPiPActive() -> Bool {
         return pipController?.isPictureInPictureActive ?? false
     }
}
