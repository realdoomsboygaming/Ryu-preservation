import UIKit

class SettingsViewSources: UITableViewController {

    @IBOutlet weak var retryMethod: UIButton!
    @IBOutlet weak var qualityPrefered: UIButton!

    @IBOutlet weak var gogoButton: UIButton!

    // Renamed outlets for clarity (previously related to HiAnime)
    @IBOutlet weak var anilistAudioButton: UIButton!
    @IBOutlet weak var anilistServerButton: UIButton!
    @IBOutlet weak var anilistSubtitlesButton: UIButton!

    @IBOutlet weak var otherFOrmats: UISwitch!

    override func viewDidLoad() {
        super.viewDidLoad()
        setupRetryMenu()
        setupMenu()
        setupGoGo()
        setupAniListAudioMenu() // Renamed function
        setupAniListServerMenu() // Renamed function
        setupAniListSubtitlesMenu() // Renamed function
        loadUserDefaults()

        if let selectedOption = UserDefaults.standard.string(forKey: "preferredQuality") {
            qualityPrefered.setTitle(selectedOption, for: .normal)
        }
    }

    private func loadUserDefaults() {
        otherFOrmats.isOn = UserDefaults.standard.bool(forKey: "otherFormats")
        // Load AniList specific preferences
        if let audioPref = UserDefaults.standard.string(forKey: "anilistAudioPref") { // Updated key
            anilistAudioButton.setTitle(audioPref, for: .normal)
        }
        if let serverPref = UserDefaults.standard.string(forKey: "anilistServerPref") { // Updated key
            anilistServerButton.setTitle(serverPref, for: .normal)
        }
        if let subtitlePref = UserDefaults.standard.string(forKey: "anilistSubtitlePref") { // Updated key
            anilistSubtitlesButton.setTitle(subtitlePref, for: .normal)
        }
    }

    @IBAction func otherFormatsToggle(_ sender: UISwitch) {
        UserDefaults.standard.set(sender.isOn, forKey: "otherFormats")
    }

    func setupRetryMenu() {
        let actions = [
            UIAction(title: "5 Tries", handler: { [weak self] _ in
                self?.setRetries(5)
            }),
            UIAction(title: "10 Tries", handler: { [weak self] _ in
                self?.setRetries(10)
            }),
            UIAction(title: "15 Tries", handler: { [weak self] _ in
                self?.setRetries(15)
            }),
            UIAction(title: "20 Tries", handler: { [weak self] _ in
                self?.setRetries(20)
            }),
            UIAction(title: "25 Tries", handler: { [weak self] _ in
                self?.setRetries(25)
            })
        ]

        let menu = UIMenu(title: "Select Retry Count", children: actions)

        retryMethod.menu = menu
        retryMethod.showsMenuAsPrimaryAction = true

        if let retries = UserDefaults.standard.value(forKey: "maxRetries") as? Int {
            retryMethod.setTitle("\(retries) Tries", for: .normal)
        } else {
            retryMethod.setTitle("Select Tries", for: .normal) // Default or placeholder
        }
    }

    func setupGoGo() {
        let action1 = UIAction(title: "Default", handler: { [weak self] _ in
            UserDefaults.standard.set("Default", forKey: "gogoFetcher")
            self?.gogoButton.setTitle("Default", for: .normal)
        })
        let action2 = UIAction(title: "Secondary", handler: { [weak self] _ in
            UserDefaults.standard.set("Secondary", forKey: "gogoFetcher")
            self?.gogoButton.setTitle("Secondary", for: .normal)
        })

        let menu = UIMenu(title: "Select Prefered Method", children: [action1, action2])

        gogoButton.menu = menu
        gogoButton.showsMenuAsPrimaryAction = true

        if let selectedOption = UserDefaults.standard.string(forKey: "gogoFetcher") {
            gogoButton.setTitle(selectedOption, for: .normal)
        }
    }

    private func setRetries(_ retries: Int) {
        UserDefaults.standard.set(retries, forKey: "maxRetries")
        retryMethod.setTitle("\(retries) Tries", for: .normal)
    }

    func setupMenu() {
        let action1 = UIAction(title: "360p", handler: { [weak self] _ in
            UserDefaults.standard.set("360p", forKey: "preferredQuality")
            self?.qualityPrefered.setTitle("360p", for: .normal)
        })
        let action2 = UIAction(title: "480p", handler: { [weak self] _ in
            UserDefaults.standard.set("480p", forKey: "preferredQuality")
            self?.qualityPrefered.setTitle("480p", for: .normal)
        })
        let action3 = UIAction(title: "720p", handler: { [weak self] _ in
            UserDefaults.standard.set("720p", forKey: "preferredQuality")
            self?.qualityPrefered.setTitle("720p", for: .normal)
        })
        let action4 = UIAction(title: "1080p", handler: { [weak self] _ in
            UserDefaults.standard.set("1080p", forKey: "preferredQuality")
            self?.qualityPrefered.setTitle("1080p", for: .normal)
        })

        let menu = UIMenu(title: "Select Prefered Quality", children: [action1, action2, action3, action4])

        qualityPrefered.menu = menu
        qualityPrefered.showsMenuAsPrimaryAction = true

        if let selectedOption = UserDefaults.standard.string(forKey: "preferredQuality") {
            qualityPrefered.setTitle(selectedOption, for: .normal)
        }
    }

    // Renamed function
    func setupAniListAudioMenu() {
        let action1 = UIAction(title: "sub", handler: { [weak self] _ in
            UserDefaults.standard.set("sub", forKey: "anilistAudioPref") // Updated key
            self?.anilistAudioButton.setTitle("sub", for: .normal)
        })
        let action2 = UIAction(title: "dub", handler: { [weak self] _ in
            UserDefaults.standard.set("dub", forKey: "anilistAudioPref") // Updated key
            self?.anilistAudioButton.setTitle("dub", for: .normal)
        })
        let action3 = UIAction(title: "raw", handler: { [weak self] _ in
            UserDefaults.standard.set("raw", forKey: "anilistAudioPref") // Updated key
            self?.anilistAudioButton.setTitle("raw", for: .normal)
        })
        let action4 = UIAction(title: "Always Ask", handler: { [weak self] _ in
            UserDefaults.standard.set("Always Ask", forKey: "anilistAudioPref") // Updated key
            self?.anilistAudioButton.setTitle("Always Ask", for: .normal)
        })

        let menu = UIMenu(title: "Select Prefered Audio", children: [action1, action2, action3, action4])

        anilistAudioButton.menu = menu // Use renamed outlet
        anilistAudioButton.showsMenuAsPrimaryAction = true

        if let selectedOption = UserDefaults.standard.string(forKey: "anilistAudioPref") { // Updated key
            anilistAudioButton.setTitle(selectedOption, for: .normal)
        } else {
            anilistAudioButton.setTitle("Always Ask", for: .normal) // Set default if none saved
            UserDefaults.standard.set("Always Ask", forKey: "anilistAudioPref")
        }
    }

    // Renamed function
    func setupAniListServerMenu() {
        let action1 = UIAction(title: "hd-1", handler: { [weak self] _ in
            UserDefaults.standard.set("hd-1", forKey: "anilistServerPref") // Updated key
            self?.anilistServerButton.setTitle("hd-1", for: .normal)
        })
        let action2 = UIAction(title: "hd-2", handler: { [weak self] _ in
            UserDefaults.standard.set("hd-2", forKey: "anilistServerPref") // Updated key
            self?.anilistServerButton.setTitle("hd-2", for: .normal)
        })
        let action3 = UIAction(title: "Always Ask", handler: { [weak self] _ in
            UserDefaults.standard.set("Always Ask", forKey: "anilistServerPref") // Updated key
            self?.anilistServerButton.setTitle("Always Ask", for: .normal)
        })

        let menu = UIMenu(title: "Select Prefered Server", children: [action1, action2, action3])

        anilistServerButton.menu = menu // Use renamed outlet
        anilistServerButton.showsMenuAsPrimaryAction = true

        if let selectedOption = UserDefaults.standard.string(forKey: "anilistServerPref") { // Updated key
            anilistServerButton.setTitle(selectedOption, for: .normal)
        } else {
            anilistServerButton.setTitle("Always Ask", for: .normal) // Set default if none saved
            UserDefaults.standard.set("Always Ask", forKey: "anilistServerPref")
        }
    }

    // Renamed function
    func setupAniListSubtitlesMenu() {
        let action1 = UIAction(title: "English", handler: { [weak self] _ in
            UserDefaults.standard.set("English", forKey: "anilistSubtitlePref") // Updated key
            self?.anilistSubtitlesButton.setTitle("English", for: .normal)
        })
        let action2 = UIAction(title: "Always Ask", handler: { [weak self] _ in
            UserDefaults.standard.set("Always Ask", forKey: "anilistSubtitlePref") // Updated key
            self?.anilistSubtitlesButton.setTitle("Always Ask", for: .normal)
        })
        let action3 = UIAction(title: "No Subtitles", handler: { [weak self] _ in
            UserDefaults.standard.set("No Subtitles", forKey: "anilistSubtitlePref") // Updated key
            self?.anilistSubtitlesButton.setTitle("No Subtitles", for: .normal)
        })
        let action4 = UIAction(title: "Always Import", handler: { [weak self] _ in
            UserDefaults.standard.set("Always Import", forKey: "anilistSubtitlePref") // Updated key
            self?.anilistSubtitlesButton.setTitle("Always Import", for: .normal)
        })

        let menu = UIMenu(title: "Select Subtitles Language", children: [action1, action3, action4, action2])

        anilistSubtitlesButton.menu = menu // Use renamed outlet
        anilistSubtitlesButton.showsMenuAsPrimaryAction = true

        if let selectedOption = UserDefaults.standard.string(forKey: "anilistSubtitlePref") { // Updated key
            anilistSubtitlesButton.setTitle(selectedOption, for: .normal)
        } else {
            anilistSubtitlesButton.setTitle("English", for: .normal) // Set default if none saved
            UserDefaults.standard.set("English", forKey: "anilistSubtitlePref")
        }
    }

    @IBAction func closeButtonTapped() {
        dismiss(animated: true, completion: nil)
    }
}
