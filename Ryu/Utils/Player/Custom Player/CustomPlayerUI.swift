import UIKit
import AVKit
import GoogleCast
import MediaPlayer
import AVFoundation

// Helper extension to find the parent ViewController
extension UIView {
    func findViewController() -> UIViewController? {
        if let nextResponder = self.next as? UIViewController {
            return nextResponder
        } else if let nextResponder = self.next as? UIView {
            return nextResponder.findViewController()
        } else {
            return nil
        }
    }
}


class CustomVideoPlayerView: UIView, AVPictureInPictureControllerDelegate, GCKRemoteMediaClientListener {
    private var player: AVPlayer?
    private var playerLayer: AVPlayerLayer?
    private var isControlsVisible = true
    private var hideControlsTimer: Timer?
    private var baseURL: URL? // Base URL for m3u8 segments
    private var realURL: URL? // The actual video URL being played
    private var qualities: [(String, String)] = [] // Format: [("1080p", "filename.m3u8")]
    private var currentQualityIndex = 0
    private var timeObserverToken: Any?
    private var isSeekingAllowed = false // Prevent seeking before duration is known
    private var blurEffectView: UIVisualEffectView?
    private var pipController: AVPictureInPictureController?
    private var isSpeedIndicatorVisible = false // Track visibility of speed indicator
    private var videoTitle: String = ""
    private var subtitlesURL: URL? // URL for external subtitles
    private var originalBrightness: CGFloat = UIScreen.main.brightness
    private var isFullBrightness = false
    private var cell: EpisodeCell // Reference to the cell for progress updates
    private var fullURL: String // The unique identifier URL for the episode
    private var hasSentUpdate = false // Flag to prevent multiple progress updates
    private var animeImage: String // For Cast metadata
    private var chromecastObserver: NSObjectProtocol? // Observer for Cast state changes

    // Skip times properties
    private var skipButtonsBottomConstraint: NSLayoutConstraint?
    private var skipButtons: [UIButton] = []
    private var skipIntervalViews: [UIView] = []
    private var skipIntervals: [(type: String, start: TimeInterval, end: TimeInterval, id: String)] = [] // Store type and ID
    private var autoSkipTimer: Timer? // Timer for auto-skip checks

    private var hasVotedForSkipTimes = false // Flag to track voting status
    private var hasSkippedIntro = false
    private var hasSkippedOutro = false

    // Seeking properties
    private var isSeeking = false
    private var seekThumbWidthConstraint: NSLayoutConstraint?
    private var seekThumbCenterXConstraint: NSLayoutConstraint?

    // Subtitle properties
    private var subtitles: [SubtitleCue] = []
    private var currentSubtitleIndex: Int?
    private var lastTranslationLanguage: String?
    private var subtitleTimer: Timer?
    private var subtitleFontSize: CGFloat = 16
    private var subtitleColor: UIColor = .white
    private var subtitleBorderWidth: CGFloat = 1
    private var subtitleBorderColor: UIColor = .black
    private var areSubtitlesHidden = false

    // Gesture Recognizer reference for hold speed check
    private var holdGestureRecognizer: UILongPressGestureRecognizer?

    // MARK: - UI Elements (Lazy Initialization)
    private lazy var playPauseButton: UIImageView = {
        let imageView = UIImageView()
        imageView.image = UIImage(systemName: "play.fill") // Initial state
        imageView.tintColor = .white
        imageView.isUserInteractionEnabled = true
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(playPauseButtonTapped))
        imageView.addGestureRecognizer(tapGesture)
        imageView.contentMode = .scaleAspectFit // Ensure icon fits
        return imageView
    }()

    private lazy var rewindButton: UIImageView = {
        let imageView = UIImageView(image: UIImage(systemName: "gobackward.10"))
        imageView.tintColor = .white
        imageView.isUserInteractionEnabled = true
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(rewindButtonTapped))
        imageView.addGestureRecognizer(tapGesture)
        imageView.contentMode = .scaleAspectFit
        return imageView
    }()

    private lazy var forwardButton: UIImageView = {
        let imageView = UIImageView(image: UIImage(systemName: "goforward.10"))
        imageView.tintColor = .white
        imageView.isUserInteractionEnabled = true
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(forwardButtonTapped))
        imageView.addGestureRecognizer(tapGesture)
        imageView.contentMode = .scaleAspectFit
        return imageView
    }()

    // Separate container for progress bar elements to handle gestures precisely
    private lazy var progressBarContainer: UIView = {
        let view = UIView()
        view.backgroundColor = .clear // Make container transparent
        return view
    }()

    private lazy var playerProgress: UIProgressView = {
        let progress = UIProgressView(progressViewStyle: .default)
        progress.progressTintColor = .systemTeal // Use accent color
        progress.trackTintColor = UIColor.white.withAlphaComponent(0.3) // Dim track color
        progress.translatesAutoresizingMaskIntoConstraints = false
        return progress
    }()

     // Thumb view for seeking interaction
     private lazy var seekThumb: UIView = {
         let view = UIView()
         view.backgroundColor = .white
         view.layer.cornerRadius = 8 // Make it circular
         view.layer.masksToBounds = true // Ensure corners are rounded
         view.translatesAutoresizingMaskIntoConstraints = false
         view.alpha = 0 // Initially hidden
         return view
     }()

    private lazy var currentTimeLabel: UILabel = {
        let label = UILabel()
        label.textColor = .white
        label.font = UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular) // Monospaced for consistent width
        return label
    }()

    private lazy var totalTimeLabel: UILabel = {
        let label = UILabel()
        label.textColor = .white
        label.font = UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular) // Monospaced
        label.textAlignment = .right // Align to the right
        return label
    }()

    private lazy var controlsContainerView: UIView = {
        let view = UIView()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.4) // Semi-transparent background
        return view
    }()

    private lazy var settingsButton: UIButton = {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "gear"), for: .normal)
        button.tintColor = .white
        button.showsMenuAsPrimaryAction = true // Enable UIMenu interaction
        return button
    }()

    // Speed indicator shown during long-press speed change
    private lazy var speedIndicatorLabel: UILabel = {
        let label = UILabel()
        label.textColor = .white
        label.font = UIFont.systemFont(ofSize: 12)
        label.textAlignment = .center
        label.isHidden = true // Initially hidden
        return label
    }()

    private lazy var speedIndicatorBackgroundView: UIView = {
        let view = UIView()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        view.layer.cornerRadius = 12
        view.isHidden = true // Initially hidden
        return view
    }()

    private lazy var speedButton: UIButton = {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "speedometer"), for: .normal)
        button.tintColor = .white
        button.showsMenuAsPrimaryAction = true // Enable UIMenu interaction
        return button
    }()

    private lazy var titleLabel: UILabel = {
        let label = UILabel()
        label.textColor = .white
        label.font = UIFont.systemFont(ofSize: 18, weight: .bold)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.numberOfLines = 1 // Ensure title doesn't wrap excessively
        label.lineBreakMode = .byTruncatingTail
        return label
    }()

     private lazy var episodeLabel: UILabel = {
         let label = UILabel()
         label.textColor = UIColor.white.withAlphaComponent(0.8) // Slightly dimmed
         label.font = UIFont.systemFont(ofSize: 14)
         label.translatesAutoresizingMaskIntoConstraints = false
         label.numberOfLines = 1
         label.lineBreakMode = .byTruncatingTail
         return label
     }()

    private lazy var dismissButton: UIImageView = {
        let imageView = UIImageView(image: UIImage(systemName: "xmark"))
        imageView.tintColor = .white
        imageView.isUserInteractionEnabled = true
        // Renamed selector to avoid conflict
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(dismissPlayerView))
        imageView.addGestureRecognizer(tapGesture)
        imageView.contentMode = .scaleAspectFit
        return imageView
    }()

    private lazy var pipButton: UIImageView = {
        let imageView = UIImageView(image: UIImage(systemName: "pip.enter"))
        imageView.tintColor = .white
        imageView.isUserInteractionEnabled = true
        // Renamed selector to avoid conflict
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(togglePictureInPicture))
        imageView.addGestureRecognizer(tapGesture)
        imageView.isHidden = !AVPictureInPictureController.isPictureInPictureSupported() // Hide if PiP not supported
        imageView.contentMode = .scaleAspectFit
        return imageView
    }()

    private lazy var subtitlesLabel: UILabel = {
        let label = UILabel()
        label.textColor = subtitleColor
        label.font = UIFont.systemFont(ofSize: subtitleFontSize, weight: .bold)
        label.numberOfLines = 0 // Allow multiple lines for subtitles
        label.textAlignment = .center
        label.layer.shadowColor = subtitleBorderColor.cgColor
        label.layer.shadowOffset = CGSize(width: 0, height: 0)
        label.layer.shadowOpacity = 1
        label.layer.shadowRadius = subtitleBorderWidth
        label.layer.masksToBounds = false
        return label
    }()

    // Corrected type to AVRoutePickerView
    private lazy var airplayButton: AVRoutePickerView = {
         let airplayView = AVRoutePickerView()
         airplayView.activeTintColor = .systemTeal
         airplayView.tintColor = .white // Set default tint
         airplayView.translatesAutoresizingMaskIntoConstraints = false
         return airplayView
     }()

    // MARK: - Initialization
    init(frame: CGRect, cell: EpisodeCell, fullURL: String, image: String) {
        self.cell = cell
        self.fullURL = fullURL
        self.animeImage = image
        super.init(frame: frame)
        setupPlayer()
        setupUI()
        setupGestures()
        updateSubtitleAppearance() // Apply initial subtitle style
        loadSettings()
        setupChromecastObserver()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Deinitialization
    deinit {
        NotificationCenter.default.removeObserver(self)
        if let token = timeObserverToken {
            player?.removeTimeObserver(token)
            timeObserverToken = nil // Nil out the token
        }
         subtitleTimer?.invalidate() // Invalidate subtitle timer
         subtitleTimer = nil
        if let observer = chromecastObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        // Restore brightness if needed
        if isFullBrightness {
            UIScreen.main.brightness = originalBrightness
        }
        print("CustomVideoPlayerView deinitialized")
    }

    // MARK: - Setup
    private func setupChromecastObserver() {
        // Listen for Cast state changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(checkCastState),
            name: .gckCastStateDidChange,
            object: nil
        )
    }

    @objc private func checkCastState() {
        // If connected, proceed with casting and dismiss the player
        guard GCKCastContext.sharedInstance().castState == .connected, let url = realURL else { return }
        proceedWithCasting(videoURL: url)
        // Dismiss the custom player view controller
        findViewController()?.dismiss(animated: true, completion: nil)
    }

    private func setupPlayer() {
        player = AVPlayer()
        playerLayer = AVPlayerLayer(player: player)
        playerLayer?.videoGravity = .resizeAspect // Default gravity
        layer.addSublayer(playerLayer!)

        // Observe player status for readiness
         player?.addObserver(self, forKeyPath: #keyPath(AVPlayer.currentItem.status), options: [.new, .initial], context: nil)

        // Observe playback end
        NotificationCenter.default.addObserver(self, selector: #selector(playerItemDidReachEnd), name: .AVPlayerItemDidPlayToEndTime, object: nil) // Observe all player items

        // Setup PiP controller if supported
        if AVPictureInPictureController.isPictureInPictureSupported() {
            pipController = AVPictureInPictureController(playerLayer: playerLayer!)
            pipController?.delegate = self
        }
    }

     override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
          // Allow interaction with controls even when hidden if the tap is on them
          if controlsContainerView.alpha > 0 {
               for subview in controlsContainerView.subviews.reversed() { // Check top-most views first
                   // Check if the subview is visible and interactive, and contains the touch point
                   if !subview.isHidden && subview.alpha > 0 && subview.isUserInteractionEnabled && subview.frame.contains(convert(point, to: controlsContainerView)) {
                        // If the tap is on a control, ensure controls are shown before returning the view
                         if !isControlsVisible { showControls() }
                        // Pass the hit test down to the subview
                        return subview.hitTest(convert(point, to: subview), with: event) ?? subview
                    }
                }
           }
           // Also check progressBarContainer separately
           // Use self.convert for coordinate conversion
           if progressBarContainer.frame.contains(point) && progressBarContainer.isUserInteractionEnabled {
                if !isControlsVisible { showControls() }
                return progressBarContainer.hitTest(convert(point, to: progressBarContainer), with: event) ?? progressBarContainer
            }


           // If tap is not on controls or progress bar, handle show/hide
           // Ensure the hit view is the background (self) or the controls container itself
           if let view = super.hitTest(point, with: event), (view == self || view == controlsContainerView) {
               handleTap() // Show/hide controls on background tap
               return self // Intercept tap on background so it doesn't fall through
           }


           return super.hitTest(point, with: event) // Default behavior otherwise
       }

    private func setupUI() {
        // Add subviews in correct Z-order (background first, then controls, then labels)
        addSubview(controlsContainerView) // Add container first
        addSubview(subtitlesLabel)
        addSubview(progressBarContainer) // Progress bar container separate for gestures

        // Add elements to their containers
        progressBarContainer.addSubview(playerProgress)
        progressBarContainer.addSubview(seekThumb)

        controlsContainerView.addSubview(playPauseButton)
        controlsContainerView.addSubview(rewindButton)
        controlsContainerView.addSubview(forwardButton)
        controlsContainerView.addSubview(currentTimeLabel)
        controlsContainerView.addSubview(totalTimeLabel)
        controlsContainerView.addSubview(settingsButton)
        controlsContainerView.addSubview(speedButton)
        controlsContainerView.addSubview(titleLabel)
        controlsContainerView.addSubview(dismissButton)
        if pipController != nil { controlsContainerView.addSubview(pipButton) } // Only add if supported
        controlsContainerView.addSubview(episodeLabel)
        controlsContainerView.addSubview(airplayButton) // Add AirPlay button view

         // Add speed indicator overlays last so they appear on top
         addSubview(speedIndicatorBackgroundView)
         addSubview(speedIndicatorLabel)

        // Setup constraints using translatesAutoresizingMaskIntoConstraints = false
        speedIndicatorLabel.translatesAutoresizingMaskIntoConstraints = false
        speedIndicatorBackgroundView.translatesAutoresizingMaskIntoConstraints = false
        speedButton.translatesAutoresizingMaskIntoConstraints = false
        controlsContainerView.translatesAutoresizingMaskIntoConstraints = false
        playPauseButton.translatesAutoresizingMaskIntoConstraints = false
        rewindButton.translatesAutoresizingMaskIntoConstraints = false
        forwardButton.translatesAutoresizingMaskIntoConstraints = false
        playerProgress.translatesAutoresizingMaskIntoConstraints = false
        currentTimeLabel.translatesAutoresizingMaskIntoConstraints = false
        totalTimeLabel.translatesAutoresizingMaskIntoConstraints = false
        settingsButton.translatesAutoresizingMaskIntoConstraints = false
        dismissButton.translatesAutoresizingMaskIntoConstraints = false
        pipButton.translatesAutoresizingMaskIntoConstraints = false
        subtitlesLabel.translatesAutoresizingMaskIntoConstraints = false
        episodeLabel.translatesAutoresizingMaskIntoConstraints = false
        progressBarContainer.translatesAutoresizingMaskIntoConstraints = false
        airplayButton.translatesAutoresizingMaskIntoConstraints = false // Ensure this is set

        // Activate constraints (Same as before, just ensure all elements are included)
        NSLayoutConstraint.activate([
            // Speed Indicator Constraints
             speedIndicatorBackgroundView.centerXAnchor.constraint(equalTo: centerXAnchor),
             speedIndicatorBackgroundView.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 60), // Position below top controls
             speedIndicatorBackgroundView.widthAnchor.constraint(equalTo: speedIndicatorLabel.widthAnchor, constant: 20),
             speedIndicatorBackgroundView.heightAnchor.constraint(equalTo: speedIndicatorLabel.heightAnchor, constant: 10),

             speedIndicatorLabel.centerXAnchor.constraint(equalTo: speedIndicatorBackgroundView.centerXAnchor),
             speedIndicatorLabel.centerYAnchor.constraint(equalTo: speedIndicatorBackgroundView.centerYAnchor),


            // Controls Container Constraints
            controlsContainerView.topAnchor.constraint(equalTo: topAnchor),
            controlsContainerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            controlsContainerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            controlsContainerView.bottomAnchor.constraint(equalTo: bottomAnchor),

             // Top Controls (Dismiss, PiP, AirPlay)
             dismissButton.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 15), // Adjusted padding
             dismissButton.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 15), // Adjusted padding
             dismissButton.widthAnchor.constraint(equalToConstant: 30), // Increased size
             dismissButton.heightAnchor.constraint(equalToConstant: 30), // Increased size

             pipButton.centerYAnchor.constraint(equalTo: dismissButton.centerYAnchor),
             pipButton.leadingAnchor.constraint(equalTo: dismissButton.trailingAnchor, constant: 20), // Spacing
             pipButton.widthAnchor.constraint(equalToConstant: 30),
             pipButton.heightAnchor.constraint(equalToConstant: 30), // Make PiP button same size

             airplayButton.centerYAnchor.constraint(equalTo: dismissButton.centerYAnchor),
             airplayButton.leadingAnchor.constraint(equalTo: pipButton.trailingAnchor, constant: 20), // Spacing
             airplayButton.widthAnchor.constraint(equalToConstant: 30), // Consistent size
             airplayButton.heightAnchor.constraint(equalToConstant: 30), // Consistent size


            // Center Controls (Play/Pause, Rewind, Forward)
            playPauseButton.centerXAnchor.constraint(equalTo: controlsContainerView.centerXAnchor),
            playPauseButton.centerYAnchor.constraint(equalTo: controlsContainerView.centerYAnchor),
            playPauseButton.widthAnchor.constraint(equalToConstant: 50), // Standard size
            playPauseButton.heightAnchor.constraint(equalToConstant: 55), // Standard size

            rewindButton.trailingAnchor.constraint(equalTo: playPauseButton.leadingAnchor, constant: -60), // Adjust spacing
            rewindButton.centerYAnchor.constraint(equalTo: playPauseButton.centerYAnchor),
            rewindButton.widthAnchor.constraint(equalToConstant: 35), // Slightly larger
            rewindButton.heightAnchor.constraint(equalToConstant: 35),

            forwardButton.leadingAnchor.constraint(equalTo: playPauseButton.trailingAnchor, constant: 60), // Adjust spacing
            forwardButton.centerYAnchor.constraint(equalTo: playPauseButton.centerYAnchor),
            forwardButton.widthAnchor.constraint(equalToConstant: 35), // Slightly larger
            forwardButton.heightAnchor.constraint(equalToConstant: 35),

             // Progress Bar Container Constraints (separate for gestures)
             progressBarContainer.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 10), // Use safe area + padding
             progressBarContainer.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -10), // Use safe area + padding
             progressBarContainer.bottomAnchor.constraint(equalTo: currentTimeLabel.topAnchor, constant: -5), // Position above time labels
             progressBarContainer.heightAnchor.constraint(equalToConstant: 20), // Slightly taller for easier interaction


             // Progress Bar Constraints (within its container)
             playerProgress.leadingAnchor.constraint(equalTo: progressBarContainer.leadingAnchor),
             playerProgress.trailingAnchor.constraint(equalTo: progressBarContainer.trailingAnchor),
             playerProgress.centerYAnchor.constraint(equalTo: progressBarContainer.centerYAnchor), // Center vertically
             playerProgress.heightAnchor.constraint(equalToConstant: 6), // Thinner progress bar


             // Seek Thumb Constraints (within progress bar container)
             seekThumb.centerYAnchor.constraint(equalTo: playerProgress.centerYAnchor),
             seekThumb.heightAnchor.constraint(equalToConstant: 16), // Larger thumb


            // Time Labels Constraints
            currentTimeLabel.leadingAnchor.constraint(equalTo: progressBarContainer.leadingAnchor), // Align with progress bar container edge
             currentTimeLabel.bottomAnchor.constraint(equalTo: controlsContainerView.safeAreaLayoutGuide.bottomAnchor, constant: -15), // Adjusted to safe area

            totalTimeLabel.trailingAnchor.constraint(equalTo: progressBarContainer.trailingAnchor), // Align with progress bar container edge
            totalTimeLabel.bottomAnchor.constraint(equalTo: currentTimeLabel.bottomAnchor), // Align baseline with current time

            // Bottom Controls (Title, Episode, Settings, Speed) - Positioned above progress bar
             titleLabel.leadingAnchor.constraint(equalTo: progressBarContainer.leadingAnchor), // Align with progress bar container
             titleLabel.bottomAnchor.constraint(equalTo: progressBarContainer.topAnchor, constant: -15), // Space below title
             titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: speedButton.leadingAnchor, constant: -10), // Don't overlap speed button

             episodeLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor), // Align with title
             episodeLabel.bottomAnchor.constraint(equalTo: titleLabel.topAnchor, constant: -2), // Place above title

            settingsButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor), // Align with title vertically
            settingsButton.trailingAnchor.constraint(equalTo: progressBarContainer.trailingAnchor), // Align with progress bar container
             settingsButton.widthAnchor.constraint(equalToConstant: 30), // Standard size
             settingsButton.heightAnchor.constraint(equalToConstant: 30),

            speedButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            speedButton.trailingAnchor.constraint(equalTo: settingsButton.leadingAnchor, constant: -15), // Spacing from settings
             speedButton.widthAnchor.constraint(equalToConstant: 30), // Standard size
             speedButton.heightAnchor.constraint(equalToConstant: 30),


            // Subtitles Label Constraints
            subtitlesLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            subtitlesLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -45), // Position above bottom controls
            subtitlesLabel.leadingAnchor.constraint(equalTo: progressBarContainer.leadingAnchor), // Align with progress bar edges
            subtitlesLabel.trailingAnchor.constraint(equalTo: progressBarContainer.trailingAnchor) // Align with progress bar edges
        ])

        // Initialize seek thumb constraints (will be updated)
        seekThumbWidthConstraint = seekThumb.widthAnchor.constraint(equalToConstant: 16)
        seekThumbCenterXConstraint = seekThumb.centerXAnchor.constraint(equalTo: playerProgress.leadingAnchor)
        seekThumbWidthConstraint?.isActive = true
        seekThumbCenterXConstraint?.isActive = true
        hideSeekThumb(animated: false) // Start with thumb hidden

        // Format episode label text
        let episodeText = self.cell.episodeNumber
        var formattedText = ""
        let episodeNum = EpisodeNumberExtractor.extract(from: episodeText) // Use extractor
        if episodeText.hasPrefix("S") {
            let components = episodeText.dropFirst().components(separatedBy: "E")
            if components.count == 2 {
                let seasonNumber = components[0]
                let episodeNumber = components[1]
                // Clean numbers (remove leading zeros if desired, though maybe not needed here)
                let cleanSeasonNum = Int(seasonNumber)?.description ?? seasonNumber
                let cleanEpisodeNum = Int(episodeNumber)?.description ?? episodeNumber
                formattedText = "Season \(cleanSeasonNum) · Episode \(cleanEpisodeNum)"
            } else {
                 // Fallback if SxE format is unexpected
                  formattedText = "Episode \(episodeNum)"
              }
        } else {
            formattedText = "Episode \(episodeNum)"
        }
        episodeLabel.text = formattedText
    }

    private func updateSubtitleAppearance() {
        subtitlesLabel.font = UIFont.systemFont(ofSize: subtitleFontSize, weight: .bold)
        subtitlesLabel.textColor = subtitleColor
        subtitlesLabel.layer.shadowColor = subtitleBorderColor.cgColor
        subtitlesLabel.layer.shadowRadius = subtitleBorderWidth
        subtitlesLabel.layer.shadowOpacity = subtitleBorderWidth > 0 ? 1 : 0 // Only show shadow if width > 0
    }


    private func setupGestures() {
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        tapGesture.delegate = self // Set delegate to allow specific hit testing
        // Add tap gesture to the main view (self) instead of controls container
        // This allows tapping anywhere to toggle controls. Hit testing will handle control interaction.
        self.addGestureRecognizer(tapGesture)

        let longPressGesture = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress))
        longPressGesture.minimumPressDuration = 0.3 // Shorter duration for speed change
        self.addGestureRecognizer(longPressGesture) // Add to main view
        self.holdGestureRecognizer = longPressGesture // Store reference

        let panGesture = UIPanGestureRecognizer(target: self, action: #selector(handleProgressPan(_:)))
        progressBarContainer.addGestureRecognizer(panGesture) // Add pan to the specific container

        let tap2Gesture = UITapGestureRecognizer(target: self, action: #selector(handleProgressTap(_:)))
        progressBarContainer.addGestureRecognizer(tap2Gesture) // Add tap to the specific container
    }


    // MARK: - Actions
    @objc private func airplayButtonTapped() {
        // AVRoutePickerView handles its own presentation
        print("AirPlay button (AVRoutePickerView) tapped - system handles presentation.")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer?.frame = self.bounds
        // Update skip interval positions when layout changes (e.g., rotation)
        updateProgressBarWithSkipIntervals()
    }

    // MARK: - Video Loading & Playback
    func setVideo(url: URL, title: String, subURL: URL? = nil, cell: EpisodeCell, fullURL: String) {
        self.videoTitle = title
        titleLabel.text = title
        self.baseURL = url.deletingLastPathComponent()
        self.realURL = url
        self.subtitlesURL = subURL
        self.cell = cell
        self.fullURL = fullURL

        // Reset state for new video
         resetSkipFlags()
         hasSentUpdate = false
         hasVotedForSkipTimes = false
         skipIntervals.removeAll()
         removeSkipButtonsAndIntervals() // Corrected function name
         subtitles.removeAll()
         subtitlesLabel.text = nil
         currentSubtitleIndex = nil
         lastTranslationLanguage = nil
         subtitleTimer?.invalidate()
         subtitleTimer = nil


        let lastPlayedTime = UserDefaults.standard.double(forKey: "lastPlayedTime_\(fullURL)")

        // Handle Chromecast connection before setting player item
        if GCKCastContext.sharedInstance().sessionManager.hasConnectedCastSession() {
            proceedWithCasting(videoURL: url)
            findViewController()?.dismiss(animated: true, completion: nil)
            return // Don't proceed with local playback if casting
        }

        if url.pathExtension == "m3u8" {
            // Parse M3U8 to get quality options
            parseM3U8(url: url) { [weak self] in
                guard let self = self else { return }
                 // Select preferred quality after parsing
                let savedPreferredQuality = UserDefaults.standard.string(forKey: "preferredQuality")
                 let preferredQualities = [savedPreferredQuality,"1080p","720p","480p","360p"].compactMap { $0 }

                 if let matchingQualityIndex = preferredQualities.lazy
                     .compactMap({ preferredQuality in
                         self.qualities.firstIndex(where: { $0.0.lowercased() == preferredQuality.lowercased() })
                     })
                     .first {
                      // Check if player item needs replacing (if quality changed or first load)
                       if self.player?.currentItem == nil || self.currentQualityIndex != matchingQualityIndex {
                            self.setQuality(index: matchingQualityIndex, seekTime: lastPlayedTime)
                       } else if lastPlayedTime > 0 {
                            // If same quality but need to seek
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { // Small delay for player readiness
                                self.player?.seek(to: CMTime(seconds: lastPlayedTime, preferredTimescale: 1))
                           }
                       }
                 } else {
                     // Fallback to highest quality if preferred not found
                     if let highestQualityIndex = self.qualities.indices.last {
                          if self.player?.currentItem == nil || self.currentQualityIndex != highestQualityIndex {
                               self.setQuality(index: highestQualityIndex, seekTime: lastPlayedTime)
                           } else if lastPlayedTime > 0 {
                               DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                   self.player?.seek(to: CMTime(seconds: lastPlayedTime, preferredTimescale: 1))
                              }
                           }
                     }
                 }
                 self.updateSettingsMenu() // Update menu after qualities are known
            }
        } else {
            // Direct URL (MP4, etc.)
            let playerItem = AVPlayerItem(url: url)
             player?.replaceCurrentItem(with: playerItem)
            qualities.removeAll() // Clear old qualities
             currentQualityIndex = 0 // Reset quality index
            updateSettingsMenu() // Update menu for non-m3u8

             // Add KVO observer *after* replacing the item
             playerItem.addObserver(self, forKeyPath: #keyPath(AVPlayerItem.status), options: [.new, .initial], context: nil)

            if lastPlayedTime > 0 {
                 // Don't seek immediately, wait for .readyToPlay status in KVO
                 objc_setAssociatedObject(playerItem, "seekTime", lastPlayedTime, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
             } else {
                  isSeekingAllowed = false // Disallow seeking until ready
              }
              objc_setAssociatedObject(playerItem, "wasPlaying", true, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) // Assume we want to play
        }

        // Load subtitles if URL is provided
        if let subtitlesURL = subtitlesURL {
            loadSubtitles(from: subtitlesURL)
            subtitlesLabel.isHidden = areSubtitlesHidden // Respect hidden setting
        } else {
            subtitles.removeAll()
            subtitlesLabel.isHidden = true
            subtitleTimer?.invalidate()
            subtitleTimer = nil
        }

        // Start observing playback time for progress updates
        addPeriodicTimeObserver(fullURL: fullURL, cell: cell)

        // Fetch skip times after setting up the player
         fetchAndSetupSkipTimes(title: title, episodeCell: cell)
    }


    func play() {
        player?.play()
        updatePlayPauseButton()
    }

    func pause() {
        player?.pause()
        updatePlayPauseButton()
    }

    // MARK: - M3U8 Handling
    private func parseM3U8(url: URL, completion: @escaping () -> Void) {
        URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            guard let data = data, let content = String(data: data, encoding: .utf8) else {
                print("Failed to load m3u8 file")
                DispatchQueue.main.async {
                    self?.qualities = []
                    completion()
                }
                return
            }

            let lines = content.components(separatedBy: .newlines)
            var parsedQualities: [(String, String)] = []

            for (index, line) in lines.enumerated() {
                if line.contains("#EXT-X-STREAM-INF") {
                     var qualityName: String?
                     if let resolutionPart = line.components(separatedBy: "RESOLUTION=").last?.components(separatedBy: ",").first,
                        let height = resolutionPart.components(separatedBy: "x").last,
                        let qualityNumber = ["1080", "720", "480", "360"].first(where: { height.hasPrefix($0) }) {
                         qualityName = "\(qualityNumber)p"
                     }
                      else if let namePart = line.components(separatedBy: "NAME=\"").last?.components(separatedBy: "\"").first {
                          qualityName = namePart // Use the NAME attribute directly
                      }

                      if let name = qualityName, index + 1 < lines.count {
                          let filename = lines[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
                          if !filename.isEmpty { // Ensure filename is not empty
                               parsedQualities.append((name, filename))
                          }
                      }
                }
            }

             parsedQualities.sort {
                 (Int($0.0.replacingOccurrences(of: "p", with: "")) ?? 0) >
                 (Int($1.0.replacingOccurrences(of: "p", with: "")) ?? 0)
             }

            DispatchQueue.main.async {
                self?.qualities = parsedQualities
                print("Parsed qualities: \(parsedQualities)")
                completion()
            }
        }.resume()
    }

     private func setQuality(index: Int, seekTime: Double = -1) {
         guard index >= 0 && index < qualities.count else {
              print("Error: Invalid quality index \(index)")
              return
          }

         // Remove observer from the old item *before* replacing it
         player?.currentItem?.removeObserver(self, forKeyPath: #keyPath(AVPlayerItem.status))


         currentQualityIndex = index
         let (_, filename) = qualities[index]

         guard let baseURL = baseURL, let fullURL = URL(string: filename, relativeTo: baseURL) else {
               print("Error: Could not construct full URL for quality \(qualities[index].0)")
               return
           }

          print("Setting quality to: \(qualities[index].0) - URL: \(fullURL.absoluteString)")

         let currentTime = player?.currentTime() ?? CMTime.zero
         let wasPlaying = player?.rate != 0
         let actualSeekTime = seekTime >= 0 ? seekTime : currentTime.seconds // Use provided seekTime or current time

         // Create new player item
         let playerItem = AVPlayerItem(url: fullURL)
         isSeekingAllowed = false // Disallow seeking until new item is ready
         player?.replaceCurrentItem(with: playerItem)

         // Observe status to handle seeking and playback state *after* replacing
          playerItem.addObserver(self, forKeyPath: #keyPath(AVPlayerItem.status), options: [.new, .initial], context: nil)

          // Update menu immediately to reflect selection
           updateSettingsMenu()

          // Store the state to restore after ready (handled in observeValue)
           objc_setAssociatedObject(playerItem, "seekTime", actualSeekTime, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
           objc_setAssociatedObject(playerItem, "wasPlaying", wasPlaying, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
     }

    // KVO for player item status
     override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
          if keyPath == #keyPath(AVPlayerItem.status),
             let playerItem = object as? AVPlayerItem,
             playerItem == player?.currentItem { // Ensure it's the current item

              switch playerItem.status {
              case .readyToPlay:
                   print("Player item ready to play.")
                   isSeekingAllowed = true // Allow seeking now

                   // Restore seek time and playback state
                   if let seekTimeValue = objc_getAssociatedObject(playerItem, "seekTime") as? Double, seekTimeValue >= 0 {
                       let seekCMTime = CMTime(seconds: seekTimeValue, preferredTimescale: 1)
                       print("Seeking to stored time: \(seekTimeValue)")
                        player?.seek(to: seekCMTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
                             if finished, let wasPlaying = objc_getAssociatedObject(playerItem, "wasPlaying") as? Bool, wasPlaying {
                                 print("Resuming playback after seek.")
                                 self?.player?.play()
                             }
                         }
                   } else if let wasPlaying = objc_getAssociatedObject(playerItem, "wasPlaying") as? Bool, wasPlaying {
                        print("Resuming playback without seek.")
                       player?.play()
                   }

                   updateTimeLabels() // Update labels with new duration
                   updateSettingsMenu() // Update menu state

              case .failed:
                  print("Player item failed: \(playerItem.error?.localizedDescription ?? "Unknown error")")
                   showAlert(title: "Playback Error", message: playerItem.error?.localizedDescription ?? "Could not load video.")
              case .unknown:
                  print("Player item status unknown.")
              @unknown default:
                  break
              }
          } else {
               // Important: Call super if the observation isn't for playerItem.status
               super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
           }
      }


    // MARK: - Time Observation & Progress Updates
    private func addPeriodicTimeObserver(fullURL: String, cell: EpisodeCell) {
         if let token = timeObserverToken {
             player?.removeTimeObserver(token)
             timeObserverToken = nil
         }

        let interval = CMTime(seconds: 1.0, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserverToken = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self = self,
                  let currentItem = self.player?.currentItem,
                  currentItem.duration.seconds.isFinite,
                  currentItem.duration.seconds > 0 else {
                      return
                  }

            let currentTime = time.seconds
            let duration = currentItem.duration.seconds

            if !self.isSeeking {
                let progress = duration > 0 ? Float(currentTime / duration) : 0
                self.updateTimeLabels(progress: Double(progress))
                self.updateProgressBarWithSkipIntervals()
                self.updateSeekThumbPosition(progress: CGFloat(progress))
            }

            let remainingTime = duration - currentTime
            self.cell.updatePlaybackProgress(progress: Float(currentTime / duration), remainingTime: remainingTime)

            UserDefaults.standard.set(currentTime, forKey: "lastPlayedTime_\(fullURL)")
            UserDefaults.standard.set(duration, forKey: "totalTime_\(fullURL)")

            self.updateContinueWatchingItem(currentTime: currentTime, duration: duration, fullURL: fullURL)
            self.sendPushUpdates(remainingTime: remainingTime, totalTime: duration, fullURL: fullURL)
            self.updateSkipButtonsVisibility() // Update skip button visibility periodically
        }
    }

    // Update Continue Watching Item
     private func updateContinueWatchingItem(currentTime: Double, duration: Double, fullURL: String) {
          let episodeNumberString = self.cell.episodeNumber
          let episodeNumber = EpisodeNumberExtractor.extract(from: episodeNumberString)

          guard episodeNumber != 0 else {
              print("Error: Could not get valid episode number for continue watching.")
              return
          }

          let selectedMediaSource = UserDefaults.standard.selectedMediaSource?.rawValue ?? "Unknown"

          let continueWatchingItem = ContinueWatchingItem(
              animeTitle: self.videoTitle,
              episodeTitle: "Ep. \(episodeNumber)",
              episodeNumber: episodeNumber,
              imageURL: self.animeImage,
              fullURL: fullURL,
              lastPlayedTime: currentTime,
              totalTime: duration,
              source: selectedMediaSource
          )
          ContinueWatchingManager.shared.saveItem(continueWatchingItem)
      }

      // Send Push Updates
      private func sendPushUpdates(remainingTime: Double, totalTime: Double, fullURL: String) {
           guard UserDefaults.standard.bool(forKey: "sendPushUpdates"),
                 totalTime > 0, remainingTime / totalTime < 0.15, !hasSentUpdate else {
                     return
                 }

           let episodeNumberString = self.cell.episodeNumber
           let episodeNumber = EpisodeNumberExtractor.extract(from: episodeNumberString)

           guard episodeNumber != 0 else {
                print("Error: Could not get valid episode number for AniList update.")
                return
            }

           let cleanedTitle = cleanTitle(self.videoTitle)

           fetchAnimeID(title: cleanedTitle) { [weak self] animeID in // Use local fetchAnimeID
               guard animeID != 0 else {
                   print("Could not fetch valid AniList ID for progress update.")
                   return
               }
               let aniListMutation = AniListMutation()
               aniListMutation.updateAnimeProgress(animeId: animeID, episodeNumber: episodeNumber) { result in
                   switch result {
                   case .success(): print("Successfully updated anime progress.")
                   case .failure(let error): print("Failed to update anime progress: \(error.localizedDescription)")
                   }
               }
               self?.hasSentUpdate = true // Set flag on self
           }
       }


    // MARK: - UI Updates
    private func updatePlayPauseButton() {
        let isPlaying = player?.rate != 0 && player?.error == nil // Check for error too
        let imageName = isPlaying ? "pause.fill" : "play.fill"
        playPauseButton.image = UIImage(systemName: imageName)
    }

    private func timeString(from timeInterval: TimeInterval) -> String {
        guard !timeInterval.isNaN && timeInterval.isFinite else { return "00:00" }
        let totalSeconds = Int(max(0, timeInterval))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, seconds) : String(format: "%02d:%02d", minutes, seconds)
    }

    private func updateTimeLabels() {
        guard let currentItem = player?.currentItem, currentItem.duration.seconds.isFinite, currentItem.duration.seconds > 0 else {
            currentTimeLabel.text = "00:00"
            totalTimeLabel.text = "00:00"
             playerProgress.progress = 0
             updateSeekThumbPosition(progress: 0) // Reset thumb
            return
        }
        let currentTime = player?.currentTime().seconds ?? 0
        let duration = currentItem.duration.seconds
        let remainingTime = duration - currentTime
        let progress = Float(currentTime / duration)

        currentTimeLabel.text = timeString(from: currentTime)
        totalTimeLabel.text = "-\(timeString(from: remainingTime))" // Show remaining time
        playerProgress.progress = progress
         updateSeekThumbPosition(progress: CGFloat(progress)) // Update thumb with current progress
    }

    private func updateTimeLabels(progress: Double) {
         guard let duration = player?.currentItem?.duration, duration.seconds.isFinite, duration.seconds > 0 else { return }
         let totalDurationSeconds = CMTimeGetSeconds(duration)
         let currentTime = progress * totalDurationSeconds
         let remainingTime = totalDurationSeconds - currentTime

         currentTimeLabel.text = timeString(from: currentTime)
         totalTimeLabel.text = "-\(timeString(from: remainingTime))"
         playerProgress.progress = Float(progress)
          // No need to update thumb position here, as this is called *from* the seek gesture
     }


    // MARK: - Controls Visibility
    private func showControls() {
        isControlsVisible = true
        UIView.animate(withDuration: 0.3) {
            self.controlsContainerView.alpha = 1
            // Update skip buttons constraints if needed (ensure they are linked)
            self.skipButtonsBottomConstraint?.constant = -10 // Example: move up above progress
            self.layoutIfNeeded() // Use self.layoutIfNeeded() for UIView subclass
        }
        resetHideControlsTimer()
    }

    private func hideControls() {
        if !isSeeking { // Don't hide if user is actively seeking
            isControlsVisible = false
            UIView.animate(withDuration: 0.3) {
                self.controlsContainerView.alpha = 0
                // Update skip buttons constraints if needed
                self.skipButtonsBottomConstraint?.constant = 35 // Example: move down
                self.layoutIfNeeded() // Use self.layoutIfNeeded()
            }
        }
    }


    private func resetHideControlsTimer() {
        hideControlsTimer?.invalidate()
        hideControlsTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
            self?.hideControls()
        }
    }

    // MARK: - Button Actions
    @objc private func playPauseButtonTapped() {
        if player?.rate == 0 { play() }
        else { pause() }
        resetHideControlsTimer()
    }

    @objc private func rewindButtonTapped() {
        guard let currentTime = player?.currentTime() else { return }
        let newTime = max(CMTimeGetSeconds(currentTime) - 10, 0)
        player?.seek(to: CMTime(seconds: newTime, preferredTimescale: 1))
        resetHideControlsTimer()
    }

    @objc private func forwardButtonTapped() {
        guard let currentTime = player?.currentTime(), let duration = player?.currentItem?.duration else { return }
        let newTime = min(CMTimeGetSeconds(currentTime) + 10, CMTimeGetSeconds(duration))
        player?.seek(to: CMTime(seconds: newTime, preferredTimescale: 1))
        resetHideControlsTimer()
    }


    // MARK: - Gesture Handling
    @objc private func handleTap() {
        if isControlsVisible { hideControls() }
        else { showControls() }
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            let holdSpeed = UserDefaults.standard.float(forKey: "holdSpeedPlayer")
            player?.rate = holdSpeed > 0 ? holdSpeed : 2.0 // Apply hold speed
            updateSpeedIndicator(speed: holdSpeed > 0 ? holdSpeed : 2.0) // Show indicator
        case .ended, .cancelled:
             // Restore to the speed selected via the speed menu (default 1.0 if none selected)
              let selectedSpeed = UserDefaults.standard.float(forKey: "playerSpeed") // Assuming you save selected speed
              player?.rate = selectedSpeed > 0 ? selectedSpeed : 1.0
             updateSpeedIndicator(speed: selectedSpeed > 0 ? selectedSpeed : 1.0) // Update indicator or hide if 1.0
        default:
            break
        }
         updateSpeedMenu() // Refresh menu state after any change
         resetHideControlsTimer() // Keep controls visible after interaction
    }

    @objc private func handleProgressPan(_ gesture: UIPanGestureRecognizer) {
        guard isSeekingAllowed else { return } // Prevent seeking if not ready

        let location = gesture.location(in: progressBarContainer)
        // Adjust calculation based on the actual tappable width (progressBarContainer width)
        let progress = max(0, min(1, location.x / progressBarContainer.bounds.width))

        switch gesture.state {
        case .began:
            isSeeking = true
            showSeekThumb() // Show thumb when seeking starts
            updateSeekThumbPosition(progress: CGFloat(progress))
            updateTimeLabels(progress: Double(progress)) // Update labels while scrubbing
        case .changed:
            updateSeekThumbPosition(progress: CGFloat(progress))
            // Update time labels immediately as user scrubs
             updateTimeLabels(progress: Double(progress))
        case .ended:
            isSeeking = false
            hideSeekThumb() // Hide thumb when seeking ends
            seek(to: Double(progress)) // Seek to final position
            resetHideControlsTimer() // Reset timer after interaction
        case .cancelled, .failed:
              isSeeking = false
              hideSeekThumb()
              resetHideControlsTimer()
        default:
            break
        }
    }


    @objc private func handleProgressTap(_ gesture: UITapGestureRecognizer) {
        guard isSeekingAllowed else { return } // Prevent seeking if not ready

        let location = gesture.location(in: progressBarContainer)
        let progress = max(0, min(1, location.x / progressBarContainer.bounds.width))
        seek(to: progress)
        resetHideControlsTimer() // Reset timer after interaction
    }


    // MARK: - Seeking Logic
     private func showSeekThumb(animated: Bool = true) {
         seekThumbWidthConstraint?.constant = 16 // Make thumb larger
          if animated {
              UIView.animate(withDuration: 0.2) {
                  self.seekThumb.alpha = 1
                  self.layoutIfNeeded() // Use self.layoutIfNeeded()
              }
          } else {
               self.seekThumb.alpha = 1
               self.layoutIfNeeded() // Use self.layoutIfNeeded()
           }
      }

      private func hideSeekThumb(animated: Bool = true) {
          seekThumbWidthConstraint?.constant = 0 // Make thumb very small or zero width
           if animated {
               UIView.animate(withDuration: 0.2) {
                   self.seekThumb.alpha = 0
                   self.layoutIfNeeded() // Use self.layoutIfNeeded()
               }
           } else {
                self.seekThumb.alpha = 0
                self.layoutIfNeeded() // Use self.layoutIfNeeded()
            }
       }

    private func updateSeekThumbPosition(progress: CGFloat) {
         guard let progressWidth = playerProgress?.bounds.width, progressWidth > 0 else { return }
         // Calculate center X based on progress within the progress bar's bounds
         let thumbCenterX = progressWidth * progress
         seekThumbCenterXConstraint?.constant = thumbCenterX
         // Animate the constraint change for smoother movement
          UIView.animate(withDuration: 0.05) { // Short duration for smooth tracking
              self.layoutIfNeeded() // Use self.layoutIfNeeded()
          }
     }

     private func seek(to progress: Double) {
          guard let duration = player?.currentItem?.duration, duration.seconds.isFinite, duration.seconds > 0 else { return }
          let seekTimeSeconds = progress * CMTimeGetSeconds(duration)
          let seekTime = CMTime(seconds: seekTimeSeconds, preferredTimescale: 1)
          print("Seeking to: \(seekTimeSeconds)s (\(progress * 100)%)")
          player?.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero) { finished in // Removed [weak self] as not needed here
               if finished {
                    print("Seek finished.")
                 } else {
                      print("Seek cancelled or interrupted.")
                  }
              }
      }

    // MARK: - Menu Updates
    private func updateSpeedMenu() {
        let speedOptions: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]
        // Check hold gesture state correctly using the stored recognizer
        let currentRate = (player?.rate == UserDefaults.standard.float(forKey: "holdSpeedPlayer") && holdGestureRecognizer?.state == .began) ? 1.0 : (player?.rate ?? 1.0) // Default to 1.0 if hold active

        let speedMenuItems = speedOptions.map { speed in
            UIAction(title: "\(speed)x", state: (abs(currentRate - speed) < 0.01) ? .on : .off) { [weak self] _ in
                self?.player?.rate = speed
                UserDefaults.standard.set(speed, forKey: "playerSpeed")
                self?.updateSpeedIndicator(speed: speed)
                self?.updateSpeedMenu()
                self?.resetHideControlsTimer()
            }
        }

        let speedMenu = UIMenu(title: "Select Speed", children: speedMenuItems)
        speedButton.menu = speedMenu
    }

     private func updateSettingsMenu() {
         var menuItems: [UIMenuElement] = []

         // --- Quality Submenu ---
         if !qualities.isEmpty {
             let qualityItems = qualities.enumerated().map { (index, quality) in
                 UIAction(title: quality.0, state: index == currentQualityIndex ? .on : .off) { [weak self] _ in
                     self?.setQuality(index: index)
                     self?.resetHideControlsTimer()
                 }
             }
             let qualitySubmenu = UIMenu(title: "Quality", image: UIImage(systemName: "rectangle.3.group"), children: qualityItems)
             menuItems.append(qualitySubmenu)
         }

         // --- Subtitles Submenu ---
         if !subtitles.isEmpty || subtitlesURL != nil {
             let fontSizeOptions: [CGFloat] = [14, 16, 18, 20, 22, 24]
             let fontSizeItems = fontSizeOptions.map { size in
                 UIAction(title: "\(Int(size))pt", state: subtitleFontSize == size ? .on : .off) { [weak self] _ in
                     self?.subtitleFontSize = size
                     self?.updateSubtitleAppearance()
                     self?.updateSettingsMenu()
                     self?.saveSettings()
                      self?.resetHideControlsTimer()
                 }
             }
             let fontSizeSubmenu = UIMenu(title: "Font Size", children: fontSizeItems)

             let colorOptions: [(String, UIColor)] = [("White", .white), ("Yellow", .yellow), ("Green", .systemGreen), ("Red", .systemRed), ("Blue", .systemBlue), ("Black", .black)]
             let colorItems = colorOptions.map { (name, color) in
                 UIAction(title: name, state: subtitleColor == color ? .on : .off) { [weak self] _ in
                     self?.subtitleColor = color
                     self?.updateSubtitleAppearance()
                     self?.updateSettingsMenu()
                     self?.saveSettings()
                      self?.resetHideControlsTimer()
                 }
             }
             let colorSubmenu = UIMenu(title: "Color", children: colorItems)

             let borderWidthOptions: [CGFloat] = [0, 1, 2, 3, 4, 5]
             let borderWidthItems = borderWidthOptions.map { width in
                 UIAction(title: "\(Int(width))pt", state: subtitleBorderWidth == width ? .on : .off) { [weak self] _ in
                     self?.subtitleBorderWidth = width
                     self?.updateSubtitleAppearance()
                     self?.updateSettingsMenu()
                     self?.saveSettings()
                      self?.resetHideControlsTimer()
                 }
             }
             let borderWidthSubmenu = UIMenu(title: "Shadow Intensity", children: borderWidthItems)

             let hideSubtitlesAction = UIAction(title: "Hide Subtitles", image: UIImage(systemName: areSubtitlesHidden ? "eye.slash" : "eye"), state: areSubtitlesHidden ? .on : .off) { [weak self] _ in
                 self?.toggleSubtitles()
                 self?.saveSettings()
                  self?.resetHideControlsTimer()
             }

             let isGoogleTranslateEnabled = UserDefaults.standard.bool(forKey: "googleTranslation")
             let subtitlesTranslationAction = UIAction(title: "Real-Time Translation", image: UIImage(systemName: "character.bubble"), state: isGoogleTranslateEnabled ? .on : .off) { _ in // Added image
                 UserDefaults.standard.set(!isGoogleTranslateEnabled, forKey: "googleTranslation")
                 self.updateSettingsMenu()
                  self.resetHideControlsTimer()
             }

             let currentLanguage = UserDefaults.standard.string(forKey: "translationLanguage") ?? "en"
             let languageOptions: [(String, String)] = [("en", "English"), ("ar", "Arabic"), ("bg", "Bulgarian"), ("cs", "Czech"), ("da", "Danish"), ("de", "German"), ("el", "Greek"), ("es", "Spanish"), ("et", "Estonian"), ("fi", "Finnish"), ("fr", "French"), ("hu", "Hungarian"), ("id", "Indonesian"), ("it", "Italian"), ("ja", "Japanese"), ("ko", "Korean"), ("lt", "Lithuanian"), ("lv", "Latvian"), ("nl", "Dutch"), ("pl", "Polish"), ("pt", "Portuguese"), ("ro", "Romanian"), ("ru", "Russian"), ("sk", "Slovak"), ("sl", "Slovenian"), ("sv", "Swedish"), ("tr", "Turkish"), ("uk", "Ukrainian")]

             let languageItems = languageOptions.map { (code, name) in
                 UIAction(title: name, state: currentLanguage == code ? .on : .off) { _ in
                     UserDefaults.standard.set(code, forKey: "translationLanguage")
                     self.updateSettingsMenu()
                     self.saveSettings()
                      self.resetHideControlsTimer()
                 }
             }
             let languageSubmenu = UIMenu(title: "Translation Language", children: languageItems)

              var subtitleChildren: [UIMenuElement] = [hideSubtitlesAction, fontSizeSubmenu, colorSubmenu, borderWidthSubmenu]
              if UserDefaults.standard.bool(forKey: "googleTranslationEnabledMain") {
                  subtitleChildren.append(subtitlesTranslationAction)
                   if isGoogleTranslateEnabled {
                       subtitleChildren.append(languageSubmenu)
                   }
               }

             let subtitleSettingsSubmenu = UIMenu(title: "Subtitles", image: UIImage(systemName: "captions.bubble"), children: subtitleChildren)
             menuItems.append(subtitleSettingsSubmenu)
         }

         // --- Aspect Ratio Submenu ---
         let aspectRatioOptions = ["Fit", "Fill"]
         let currentGravity = playerLayer?.videoGravity ?? .resizeAspect
         let aspectRatioItems = aspectRatioOptions.map { option in
             UIAction(title: option, state: (option == "Fit" && currentGravity == .resizeAspect) || (option == "Fill" && currentGravity == .resizeAspectFill) ? .on : .off) { [weak self] _ in
                 self?.playerLayer?.videoGravity = option == "Fit" ? .resizeAspect : .resizeAspectFill
                 self?.updateSettingsMenu()
                 self?.saveSettings()
                  self?.resetHideControlsTimer()
             }
         }
         let aspectRatioSubmenu = UIMenu(title: "Aspect Ratio", image: UIImage(systemName: "aspectratio"), children: aspectRatioItems)
         menuItems.append(aspectRatioSubmenu)

         // --- Full Brightness Action ---
         let brightnessAction = UIAction(title: "Full Brightness", image: UIImage(systemName: "sun.max"), state: isFullBrightness ? .on : .off) { [weak self] _ in
             self?.toggleFullBrightness()
             self?.saveSettings()
              self?.resetHideControlsTimer()
         }
         menuItems.append(brightnessAction)

         // --- Main Settings Menu ---
         let mainMenu = UIMenu(title: "Settings", children: menuItems)
         settingsButton.menu = mainMenu
     }


    private func toggleSubtitles() {
        areSubtitlesHidden.toggle()
        subtitlesLabel.isHidden = areSubtitlesHidden
        updateSettingsMenu() // Update menu to reflect state change
    }

    private func toggleFullBrightness() {
        isFullBrightness.toggle()
        if isFullBrightness {
            originalBrightness = UIScreen.main.brightness // Store current brightness
            UIScreen.main.brightness = 1.0 // Set to full
        } else {
            UIScreen.main.brightness = originalBrightness // Restore original
        }
        updateSettingsMenu() // Update menu state
    }

     private func updateSpeedIndicator(speed: Float) {
         speedIndicatorLabel.text = String(format: "%.2fx Speed", speed)
          let shouldHide = abs(speed - 1.0) < 0.01 // Hide if speed is effectively 1.0
          speedIndicatorLabel.isHidden = shouldHide
          speedIndicatorBackgroundView.isHidden = shouldHide

           UIView.animate(withDuration: 0.3) {
                self.speedIndicatorLabel.alpha = shouldHide ? 0 : 1
                self.speedIndicatorBackgroundView.alpha = shouldHide ? 0 : 1
            }
      }


    // MARK: - Playback End & Dismissal
    @objc private func playerItemDidReachEnd(notification: Notification) {
          guard let playerItem = notification.object as? AVPlayerItem,
                playerItem == player?.currentItem else {
                    return
                }

        pause() // Ensure player is paused visually
        resetHideControlsTimer() // Prevent controls from hiding immediately
        showControls() // Show controls at the end

        // Reset progress to end state
        playerProgress.progress = 1.0
        updateSeekThumbPosition(progress: 1.0) // Move thumb to end
        if let duration = player?.currentItem?.duration {
            currentTimeLabel.text = timeString(from: CMTimeGetSeconds(duration))
            totalTimeLabel.text = "-00:00"
        }

        // Handle voting if enabled and not already voted
        if UserDefaults.standard.bool(forKey: "skipFeedbacks") && !hasVotedForSkipTimes {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.showSkipVoteAlert()
            }
        }

         // Handle autoplay
         if UserDefaults.standard.bool(forKey: "AutoPlay") {
              print("Autoplay triggered (needs implementation to call next episode)")
                // For now, just dismiss
                dismissPlayerView() // Changed to call the correct dismiss function


          } else {
               print("Autoplay off, playback finished.")
           }

    }

    // Renamed dismiss function
    @objc private func dismissPlayerView() {
          if isFullBrightness {
               UIScreen.main.brightness = originalBrightness
               isFullBrightness = false
           }
          hasSentUpdate = false
         findViewController()?.dismiss(animated: true, completion: nil)
     }

    // MARK: - PiP Delegate Methods
    // Renamed PiP toggle function
    @objc private func togglePictureInPicture() {
        if let pipController = pipController {
            if pipController.isPictureInPictureActive {
                pipController.stopPictureInPicture()
            } else {
                 if pipController.isPictureInPicturePossible {
                      pipController.startPictureInPicture()
                  } else {
                       print("Picture in Picture is not possible at this moment.")
                        showAlert(title: "PiP Not Available", message: "Picture in Picture cannot be started right now.")
                   }
            }
        }
    }


    func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
         print("PiP Will Start")
      }

      func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
          print("PiP Did Start")
      }

      func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
          print("PiP Failed to Start: \(error.localizedDescription)")
           showAlert(title: "Picture in Picture Error", message: "Could not start Picture in Picture.")
       }

       func pictureInPictureControllerWillStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
           print("PiP Will Stop")
       }

       func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
           print("PiP Did Stop")
       }

       func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
            if let presentingVC = findViewController()?.presentingViewController {
                 presentingVC.present(findViewController()!, animated: true) {
                     completionHandler(true)
                 }
             } else {
                  completionHandler(true) // Indicate handled even if no re-presentation needed
              }
        }


    // MARK: - Subtitle Handling
    private func loadSubtitles(from url: URL) {
         URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
              guard let self = self, let data = data, error == nil else {
                  print("Error loading subtitles: \(error?.localizedDescription ?? "Unknown error")")
                  return
              }

              SubtitlesLoader.parseSubtitles(data: data) { [weak self] cues in
                   DispatchQueue.main.async {
                       print("Loaded \(cues.count) subtitle cues.")
                       self?.subtitles = cues
                        self?.subtitleTimer?.invalidate() // Invalidate previous timer if any
                        self?.subtitleTimer = Timer.scheduledTimer(timeInterval: 0.1, target: self, selector: #selector(self?.updateSubtitle), userInfo: nil, repeats: true) // Corrected selector
                   }
               }
         }.resume()
     }

    @objc private func updateSubtitle() {
         guard !areSubtitlesHidden, let player = player, !subtitles.isEmpty else {
              if subtitlesLabel.text != nil { // Clear label if subtitles are hidden or empty
                   subtitlesLabel.text = nil
               }
              return
          }

         let currentTime = player.currentTime()
         let isTranslationEnabled = UserDefaults.standard.bool(forKey: "googleTranslation")
         let currentTranslationLanguage = UserDefaults.standard.string(forKey: "translationLanguage") ?? "en"

          var foundCue: SubtitleCue? = nil
          if let currentIndex = currentSubtitleIndex,
             currentIndex < subtitles.count,
             CMTimeCompare(currentTime, subtitles[currentIndex].startTime) >= 0,
             CMTimeCompare(currentTime, subtitles[currentIndex].endTime) <= 0 {
              foundCue = subtitles[currentIndex]
          } else {
               if let newIndex = subtitles.firstIndex(where: { CMTimeCompare(currentTime, $0.startTime) >= 0 && CMTimeCompare(currentTime, $0.endTime) <= 0 }) {
                    foundCue = subtitles[newIndex]
                    currentSubtitleIndex = newIndex
                } else {
                     currentSubtitleIndex = nil // No cue found for this time
                 }
           }


         if let cue = foundCue {
             if isTranslationEnabled {
                 if cue.getTranslation(for: currentTranslationLanguage) != nil && lastTranslationLanguage == currentTranslationLanguage {
                      subtitlesLabel.text = cue.getTranslation(for: currentTranslationLanguage)
                  } else {
                       lastTranslationLanguage = currentTranslationLanguage
                       translateAndDisplaySubtitle(cue: cue, targetLanguage: currentTranslationLanguage)
                   }
             } else {
                 subtitlesLabel.text = cue.originalText
             }
         } else {
             subtitlesLabel.text = nil
         }
     }

     private func translateAndDisplaySubtitle(cue: SubtitleCue, targetLanguage: String) {
         subtitlesLabel.text = cue.originalText

         guard let cueIndex = subtitles.firstIndex(where: { $0.startTime == cue.startTime && $0.endTime == cue.endTime }) else { return }

         SubtitlesLoader.getTranslatedSubtitle(cue) { [weak self] translatedCue in
              guard let self = self else { return }
               self.subtitles[cueIndex] = translatedCue

               if self.currentSubtitleIndex == cueIndex {
                    DispatchQueue.main.async {
                         self.subtitlesLabel.text = translatedCue.getTranslation(for: targetLanguage) ?? translatedCue.originalText
                     }
                }
          }
      }

    // MARK: - Chromecast Integration
     func proceedWithCasting(videoURL: URL) {
         DispatchQueue.main.async {
             let metadata = GCKMediaMetadata(metadataType: .movie)

             if UserDefaults.standard.bool(forKey: "fullTitleCast") {
                 metadata.setString(self.videoTitle.isEmpty ? "Unknown Title" : self.videoTitle, forKey: kGCKMetadataKeyTitle)
             } else {
                  let episodeNumber = EpisodeNumberExtractor.extract(from: self.cell.episodeNumber)
                  metadata.setString("Episode \(episodeNumber)", forKey: kGCKMetadataKeyTitle)
              }

             if UserDefaults.standard.bool(forKey: "animeImageCast"), let imageURL = URL(string: self.animeImage) {
                 metadata.addImage(GCKImage(url: imageURL, width: 480, height: 720))
             }

             let builder = GCKMediaInformationBuilder(contentURL: videoURL)

              let contentType: String
              let urlString = videoURL.absoluteString.lowercased()
              if urlString.hasSuffix(".m3u8") { contentType = "application/x-mpegurl" }
              else if urlString.hasSuffix(".mp4") { contentType = "video/mp4" }
              else { contentType = "video/mp4" }
              builder.contentType = contentType
             builder.metadata = metadata

             let streamTypeString = UserDefaults.standard.string(forKey: "castStreamingType") ?? "buffered"
             builder.streamType = (streamTypeString == "live") ? .live : .buffered

             let mediaInformation = builder.build()

             if let remoteMediaClient = GCKCastContext.sharedInstance().sessionManager.currentCastSession?.remoteMediaClient {
                 let lastPlayedTime = UserDefaults.standard.double(forKey: "lastPlayedTime_\(self.fullURL)")
                 let options = GCKMediaLoadOptions()
                  options.playPosition = lastPlayedTime > 0 ? TimeInterval(lastPlayedTime) : 0
                 remoteMediaClient.loadMedia(mediaInformation, with: options)
                  remoteMediaClient.add(self) // Add listener for cast events
             } else {
                  print("Error: No active Google Cast session found.")
                   self.showAlert(title: "Cast Error", message: "No active Chromecast session found.")
               }
         }
     }

     // GCKRemoteMediaClientListener method
      func remoteMediaClient(_ client: GCKRemoteMediaClient, didUpdate mediaStatus: GCKMediaStatus?) {
          if let mediaStatus = mediaStatus, mediaStatus.idleReason == .finished {
               print("Cast media finished playing.")
                if UserDefaults.standard.bool(forKey: "AutoPlay") {
                     print("Cast Autoplay triggered (needs implementation)")
                 }
           }
       }
}

// MARK: - Gesture Recognizer Delegate
 extension CustomVideoPlayerView: UIGestureRecognizerDelegate {
     func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
          // Allow tap gesture only if the touch is not on specific controls or the progress bar
          if gestureRecognizer is UITapGestureRecognizer {
               let locationInControls = touch.location(in: controlsContainerView)
               let isTouchOnControl = controlsContainerView.subviews.contains { subview in
                   // Check visibility and interaction, and whether it's a UIControl or specific UIImageViews
                   !subview.isHidden && subview.alpha > 0 && subview.isUserInteractionEnabled &&
                   subview.frame.contains(locationInControls) &&
                   (subview is UIControl || subview == playPauseButton || subview == rewindButton || subview == forwardButton || subview == dismissButton || subview == pipButton || subview is AVRoutePickerView)
               }
               let locationInSelf = touch.location(in: self)
               let isTouchOnProgressBar = progressBarContainer.frame.contains(locationInSelf)

               // Allow tap if NOT on a control AND NOT on the progress bar
               return !isTouchOnControl && !isTouchOnProgressBar
           }
          return true // Allow other gestures (like long press)
      }
 }

// MARK: - Skip Time Handling
extension CustomVideoPlayerView {
    private func fetchAndSetupSkipTimes(title: String, episodeCell: EpisodeCell) {
        let cleanedTitle = cleanTitle(title)
        let episodeNumberString = episodeCell.episodeNumber
        let episodeNumber = EpisodeNumberExtractor.extract(from: episodeNumberString)

         guard episodeNumber != 0 else {
             print("Invalid episode number for skip times fetch: \(episodeNumberString)")
             return
         }

        fetchAnimeID(title: cleanedTitle) { [weak self] anilistID in
             guard anilistID != 0 else {
                 print("Could not get AniList ID for skip times.")
                 return
             }
             self?.fetchMALID(anilistID: anilistID) { malID in
                 guard let malID = malID else {
                      print("Could not get MAL ID for skip times.")
                      return
                  }
                 self?.fetchSkipTimes(malID: malID, episodeNumber: episodeNumber) { skipTimes in
                     DispatchQueue.main.async {
                         self?.skipIntervals = skipTimes
                         self?.updateSkipButtons()
                         self?.updateProgressBarWithSkipIntervals()
                         self?.setupSkipButtonUpdates()
                     }
                 }
             }
         }
    }

     func fetchAnimeID(title: String, completion: @escaping (Int) -> Void) {
           if let customIDString = UserDefaults.standard.string(forKey: "customAniListID_\(title)"),
              let customID = Int(customIDString) {
               completion(customID)
               return
           }
          AnimeService.fetchAnimeID(byTitle: title) { result in
              switch result {
              case .success(let id):
                  completion(id)
              case .failure(let error):
                  print("Error fetching anime ID for skip times: \(error.localizedDescription)")
                   completion(0)
              }
          }
      }

     func fetchMALID(anilistID: Int, completion: @escaping (Int?) -> Void) {
         let urlString = "https://api.ani.zip/mappings?anilist_id=\(anilistID)"
         guard let url = URL(string: urlString) else {
             completion(nil)
             return
         }

         URLSession.shared.dataTask(with: url) { data, response, error in
             guard let data = data, error == nil else {
                 completion(nil)
                 return
             }

             do {
                 if let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                    let mappings = json["mappings"] as? [String: Any],
                    let malID = mappings["mal_id"] as? Int {
                     completion(malID)
                 } else {
                     completion(nil)
                 }
             } catch {
                 print("Error parsing MAL ID JSON: \(error)")
                 completion(nil)
             }
         }.resume()
     }

    func fetchSkipTimes(malID: Int, episodeNumber: Int, completion: @escaping ([(type: String, start: TimeInterval, end: TimeInterval, id: String)]) -> Void) {
        let savedAniSkipInstance = UserDefaults.standard.string(forKey: "savedAniSkipInstance") ?? ""
        let baseURL = savedAniSkipInstance.isEmpty ? "https://api.aniskip.com/" : savedAniSkipInstance
        let endpoint = "v1/skip-times/\(malID)/\(episodeNumber)?types=op&types=ed&episodeLength=0" // Add episodeLength=0

        guard let url = URL(string: "\(baseURL)\(endpoint)") else {
            print("Invalid AniSkip URL")
            completion([])
            return
        }

        URLSession.shared.dataTask(with: url) { data, response, error in
            if let error = error { print("AniSkip Network error: \(error)"); completion([]); return }
            guard let data = data else { print("No data from AniSkip"); completion([]); return }

            do {
                if let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
                     if let found = json["found"] as? Bool, !found {
                          print("No skip times found for MAL ID \(malID), Episode \(episodeNumber)")
                          completion([])
                          return
                      }

                      if let results = json["results"] as? [[String: Any]] {
                         let skipTimes = results.compactMap { result -> (type: String, start: TimeInterval, end: TimeInterval, id: String)? in
                             guard let interval = result["interval"] as? [String: Double],
                                   let startTime = interval["start_time"],
                                   let endTime = interval["end_time"],
                                   let skipType = result["skip_type"] as? String,
                                   let skipId = result["skip_id"] as? String else {
                                       return nil
                                   }
                             return (type: skipType, start: startTime, end: endTime, id: skipId)
                         }
                         completion(skipTimes)
                      } else {
                           print("Invalid JSON format from AniSkip (no 'results')")
                           completion([])
                       }
                } else {
                     print("Invalid JSON format from AniSkip (top level)")
                     completion([])
                 }
            } catch {
                print("Error parsing AniSkip JSON: \(error)")
                completion([])
            }
        }.resume()
    }

    private func updateSkipButtons() {
        removeSkipButtonsAndIntervals() // Use corrected name

        guard let duration = player?.currentItem?.duration.seconds, duration > 0 else { return }

        // Create a single constraint for the bottom of the button group
         var bottomAnchorConstraint: NSLayoutYAxisAnchor = progressBarContainer.topAnchor
         var bottomConstant: CGFloat = -10 // Default spacing above progress bar

        for (index, interval) in skipIntervals.enumerated() {
            let button = UIButton(type: .system)
            let title = interval.type == "op" ? " Skip Intro" : " Skip Outro"
            let icon = UIImage(systemName: "forward.fill")

            button.setImage(icon, for: .normal)
            button.setTitle(title, for: .normal)
            button.tintColor = .black
            button.setTitleColor(.black, for: .normal)
            button.backgroundColor = UIColor.white.withAlphaComponent(0.9)
            button.layer.cornerRadius = 18
            button.layer.masksToBounds = true
            button.titleLabel?.font = UIFont.systemFont(ofSize: 14, weight: .medium)
            button.imageEdgeInsets = UIEdgeInsets(top: 0, left: -5, bottom: 0, right: 5)
            button.titleEdgeInsets = UIEdgeInsets(top: 0, left: 5, bottom: 0, right: -5)
            button.contentEdgeInsets = UIEdgeInsets(top: 5, left: 15, bottom: 5, right: 15)
            // button.sizeToFit() // Don't use sizeToFit with constraints

            button.tag = index
            button.addTarget(self, action: #selector(skipButtonTapped(_:)), for: .touchUpInside)
            button.alpha = 0
            button.isHidden = true

            controlsContainerView.addSubview(button)
            skipButtons.append(button)
            button.translatesAutoresizingMaskIntoConstraints = false

             // --- Position Skip Button ---
             NSLayoutConstraint.activate([
                  button.trailingAnchor.constraint(equalTo: settingsButton.trailingAnchor), // Align right edge
                  button.bottomAnchor.constraint(equalTo: bottomAnchorConstraint, constant: -bottomConstant) // Chain bottom anchors
              ])

             // Update for the next button's bottom constraint
              bottomAnchorConstraint = button.topAnchor
              bottomConstant = 5 // Spacing between skip buttons

             // --- Create Skip Interval View on Progress Bar ---
              let startPercentage = CGFloat(interval.start / duration)
              let endPercentage = CGFloat(interval.end / duration)
              guard startPercentage < 1.0, endPercentage > startPercentage else { continue }

              let skipView = UIView()
               skipView.backgroundColor = interval.type == "op" ? .systemOrange.withAlphaComponent(0.6) : .systemPurple.withAlphaComponent(0.6)
               skipView.layer.cornerRadius = playerProgress.frame.height / 2
               skipView.layer.masksToBounds = true
               skipView.isUserInteractionEnabled = false

               playerProgress.addSubview(skipView)
               skipIntervalViews.append(skipView)
               skipView.translatesAutoresizingMaskIntoConstraints = false

               let leadingConstraint = skipView.leadingAnchor.constraint(equalTo: playerProgress.leadingAnchor, constant: playerProgress.bounds.width * startPercentage)
               let widthConstraint = skipView.widthAnchor.constraint(equalToConstant: max(1, playerProgress.bounds.width * (endPercentage - startPercentage)))

               NSLayoutConstraint.activate([
                   leadingConstraint,
                   widthConstraint,
                   skipView.topAnchor.constraint(equalTo: playerProgress.topAnchor),
                   skipView.bottomAnchor.constraint(equalTo: playerProgress.bottomAnchor)
               ])
        }
    }

    // Corrected function name
    private func removeSkipButtonsAndIntervals() {
         for button in skipButtons { button.removeFromSuperview() }
         skipButtons.removeAll()
         for view in skipIntervalViews { view.removeFromSuperview() }
         skipIntervalViews.removeAll()
     }


     private func updateProgressBarWithSkipIntervals() {
          guard let duration = player?.currentItem?.duration.seconds, duration > 0 else { return }

          for (index, view) in skipIntervalViews.enumerated() {
              guard index < skipIntervals.count else { continue }
              let interval = skipIntervals[index]
              let startPercentage = CGFloat(interval.start / duration)
              let endPercentage = CGFloat(interval.end / duration)

               if let leadingConstraint = view.constraints.first(where: { $0.firstAttribute == .leading }) {
                    leadingConstraint.constant = playerProgress.bounds.width * startPercentage
                }
                if let widthConstraint = view.constraints.first(where: { $0.firstAttribute == .width }) {
                     widthConstraint.constant = max(1, playerProgress.bounds.width * (endPercentage - startPercentage))
                 }
          }
          // Use self.layoutIfNeeded() as this is a UIView subclass
          self.playerProgress.layoutIfNeeded()
      }


    private func setupSkipButtonUpdates() {
        // The periodic time observer already handles visibility updates
    }

    private func updateSkipButtonsVisibility() { // Renamed from @objc version
        guard let currentTime = player?.currentTime().seconds else { return }

        for (index, interval) in skipIntervals.enumerated() {
            guard index < skipButtons.count else { continue }
            let button = skipButtons[index]
            let isWithinInterval = currentTime >= interval.start && currentTime < interval.end

            let shouldShow = isWithinInterval && isControlsVisible

            if button.isHidden == !shouldShow {
                UIView.animate(withDuration: 0.3) {
                     button.alpha = shouldShow ? 1 : 0
                     button.isHidden = !shouldShow
                 }
             }

             if isWithinInterval {
                 let autoSkipEnabled: Bool
                 let hasSkippedFlag: Bool

                 if interval.type == "op" {
                     autoSkipEnabled = UserDefaults.standard.bool(forKey: "autoSkipIntro")
                     hasSkippedFlag = hasSkippedIntro
                 } else { // "ed"
                     autoSkipEnabled = UserDefaults.standard.bool(forKey: "autoSkipOutro")
                     hasSkippedFlag = hasSkippedOutro
                 }

                 if autoSkipEnabled && !hasSkippedFlag {
                      print("Auto-skipping \(interval.type)")
                      seek(to: interval.end / (player?.currentItem?.duration.seconds ?? 1.0))

                      if interval.type == "op" { hasSkippedIntro = true }
                      else { hasSkippedOutro = true }

                       UIView.animate(withDuration: 0.1) {
                           button.alpha = 0
                           button.isHidden = true
                       }
                  }
             }
        }
    }


    func resetSkipFlags() {
        hasSkippedIntro = false
        hasSkippedOutro = false
         hasVotedForSkipTimes = false
    }

    @objc private func skipButtonTapped(_ sender: UIButton) {
        guard sender.tag < skipIntervals.count else { return }
        let interval = skipIntervals[sender.tag]
        seek(to: interval.end / (player?.currentItem?.duration.seconds ?? 1.0))

         UIView.animate(withDuration: 0.2) {
             sender.alpha = 0
         } completion: { _ in
              sender.isHidden = true
          }

         if interval.type == "op" { hasSkippedIntro = true }
         else { hasSkippedOutro = true }

        resetHideControlsTimer()
    }

    private func showSkipVoteAlert() {
         guard !skipIntervals.isEmpty, let viewController = self.findViewController() else { return }

         let alert = UIAlertController(title: "Rate Skip Timestamps", message: "Were the skip timestamps accurate for this episode?", preferredStyle: .alert)

         alert.addAction(UIAlertAction(title: "👍 Accurate", style: .default) { [weak self] _ in
             self?.voteForSkipTimes(voteType: "upvote")
         })

         alert.addAction(UIAlertAction(title: "👎 Inaccurate", style: .default) { [weak self] _ in
             self?.voteForSkipTimes(voteType: "downvote")
         })

         alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))

          if UIDevice.current.userInterfaceIdiom == .pad {
               if let popoverController = alert.popoverPresentationController {
                   popoverController.sourceView = self
                   popoverController.sourceRect = CGRect(x: self.bounds.midX, y: self.bounds.midY, width: 0, height: 0)
                   popoverController.permittedArrowDirections = []
               }
           }

         viewController.present(alert, animated: true)
     }

     private func voteForSkipTimes(voteType: String) {
          print("Voting \(voteType) for \(skipIntervals.count) intervals")
          for interval in skipIntervals {
              sendVote(skipId: interval.id, voteType: voteType)
          }
          hasVotedForSkipTimes = true
      }


    private func sendVote(skipId: String, voteType: String) {
        let baseURL = "https://api.aniskip.com/"
        let endpoint = "v1/vote"
        guard let url = URL(string: "\(baseURL)\(endpoint)") else {
            print("Invalid AniSkip vote URL")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: String] = [ "skip_id": skipId, "vote_type": voteType ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                print("Error sending vote for \(skipId) (\(voteType)): \(error.localizedDescription)")
            } else if let httpResponse = response as? HTTPURLResponse {
                 if httpResponse.statusCode == 200 || httpResponse.statusCode == 201 {
                     print("Vote (\(voteType)) sent successfully for \(skipId)")
                 } else {
                      print("Unexpected response code (\(httpResponse.statusCode)) when voting for \(skipId)")
                       if let responseData = data, let responseString = String(data: responseData, encoding: .utf8) {
                            print("Server response: \(responseString)")
                        }
                   }
             } else {
                  print("Unexpected response or no response when voting for \(skipId)")
              }
        }.resume()
    }

    // MARK: - Settings Persistence
    func saveSettings() {
        let defaults = UserDefaults.standard
        defaults.set(subtitleFontSize, forKey: SettingsKeys.subtitleFontSize)
        if let colorData = try? NSKeyedArchiver.archivedData(withRootObject: subtitleColor, requiringSecureCoding: true) {
            defaults.set(colorData, forKey: SettingsKeys.subtitleColor)
        }
        defaults.set(subtitleBorderWidth, forKey: SettingsKeys.subtitleBorderWidth)
        defaults.set(areSubtitlesHidden, forKey: SettingsKeys.subtitlesHidden)
        defaults.set(playerLayer?.videoGravity == .resizeAspect, forKey: SettingsKeys.aspectRatioFit)
        defaults.set(isFullBrightness, forKey: SettingsKeys.fullBrightness)
        defaults.set(player?.rate ?? 1.0, forKey: "playerSpeed")
    }

    func loadSettings() {
        let defaults = UserDefaults.standard
        subtitleFontSize = defaults.object(forKey: SettingsKeys.subtitleFontSize) as? CGFloat ?? 16
        if let colorData = defaults.data(forKey: SettingsKeys.subtitleColor),
           let color = try? NSKeyedUnarchiver.unarchivedObject(ofClass: UIColor.self, from: colorData) {
            subtitleColor = color
        } else { subtitleColor = .white }
        subtitleBorderWidth = defaults.object(forKey: SettingsKeys.subtitleBorderWidth) as? CGFloat ?? 1
        areSubtitlesHidden = defaults.bool(forKey: SettingsKeys.subtitlesHidden)
        let isFitMode = defaults.bool(forKey: SettingsKeys.aspectRatioFit)
        playerLayer?.videoGravity = isFitMode ? .resizeAspect : .resizeAspectFill
        isFullBrightness = defaults.bool(forKey: SettingsKeys.fullBrightness)
        let savedSpeed = defaults.float(forKey: "playerSpeed")
        player?.rate = savedSpeed > 0 ? savedSpeed : 1.0

        updateSubtitleAppearance()
        subtitlesLabel.isHidden = areSubtitlesHidden
         if isFullBrightness {
              originalBrightness = UIScreen.main.brightness
              UIScreen.main.brightness = 1.0
          }
         updateSpeedMenu()
         updateSettingsMenu()
     }

      func cleanTitle(_ title: String) -> String {
          let unwantedStrings = ["(ITA)", "(Dub)", "(Dub ID)", "(Dublado)"]
          var cleanedTitle = title
          for unwanted in unwantedStrings {
              cleanedTitle = cleanedTitle.replacingOccurrences(of: unwanted, with: "")
          }
          cleanedTitle = cleanedTitle.replacingOccurrences(of: "\"", with: "")
          return cleanedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
      }

        func showAlert(title: String, message: String) {
            let alertController = UIAlertController(title: title, message: message, preferredStyle: .alert)
            alertController.addAction(UIAlertAction(title: "OK", style: .default, handler: nil))

             DispatchQueue.main.async {
                 self.findViewController()?.present(alertController, animated: true, completion: nil)
             }
        }
}

// Add Keys struct inside CustomVideoPlayerView
extension CustomVideoPlayerView {
    struct SettingsKeys {
        static let subtitleFontSize = "customPlayerSubtitleFontSize"
        static let subtitleColor = "customPlayerSubtitleColor"
        static let subtitleBorderWidth = "customPlayerSubtitleBorderWidth"
        static let subtitlesHidden = "customPlayerSubtitlesHidden"
        static let aspectRatioFit = "customPlayerAspectRatioFit"
        static let fullBrightness = "customPlayerFullBrightness"
    }
}
