import UIKit
import UniformTypeIdentifiers // Keep for UIDocumentPickerDelegate if used here directly (it's used in the extension)

class SettingsViewController: UITableViewController {

    // Main Section Outlets (These seem to be from an older structure, might need removal if not used in the Storyboard)
    // @IBOutlet var autoPlaySwitch: UISwitch!      // Moved to Player Section
    // @IBOutlet var landScapeSwitch: UISwitch!     // Moved to Player Section
    // @IBOutlet var browserPlayerSwitch: UISwitch! // Moved to Player Section
    // @IBOutlet var mergeActivitySwitch: UISwitch! // Moved to Home Section
    // @IBOutlet var FavoriteNotificationSwitch: UISwitch! // Moved to Favorite Section
    // @IBOutlet var syncThemeSwitch: UISwitch!     // Moved to Theme Section

    // Player Section Outlets
    @IBOutlet weak var playerButton: UIButton!
    @IBOutlet weak var episodeSortingSegmentedControl: UISegmentedControl!
    @IBOutlet weak var holdSpeedSteppper: UIStepper!
    @IBOutlet weak var holdSpeeedLabel: UILabel!
    // Player Switches moved here from main section
    @IBOutlet var autoPlaySwitch: UISwitch!
    @IBOutlet var landScapeSwitch: UISwitch!
    @IBOutlet var browserPlayerSwitch: UISwitch!

    // Home Section Outlets
    @IBOutlet weak var sourceButton: UIButton!
    @IBOutlet var mergeActivitySwitch: UISwitch!

    // Favorite Section Outlets
    @IBOutlet var FavoriteNotificationSwitch: UISwitch!

    // Theme Section Outlets
    @IBOutlet var syncThemeSwitch: UISwitch!
    @IBOutlet weak var themeSegmentedControl: UISegmentedControl!


    let githubURL = "https://github.com/cranci1/Ryu/" // Consider moving to a constants file

    override func viewDidLoad() {
        super.viewDidLoad()
        setupHoldSpeedStepper()
        setupThemeControls()
        loadUserDefaults()
        setupMediaPlayerMenu() // Renamed from setupMenu
        setupSourceButton()    // Setup source button separately

        // Set initial state for episode sorting
        let isReverseSorted = UserDefaults.standard.bool(forKey: "isEpisodeReverseSorted")
        episodeSortingSegmentedControl.selectedSegmentIndex = isReverseSorted ? 1 : 0
    }

    // MARK: - UI Setup & Loading
    private func setupThemeControls() {
        let syncWithSystem = UserDefaults.standard.bool(forKey: "syncWithSystem")
        syncThemeSwitch.isOn = syncWithSystem

        // Ensure segments exist before setting index
        if themeSegmentedControl.numberOfSegments < 2 {
             themeSegmentedControl.removeAllSegments()
             themeSegmentedControl.insertSegment(withTitle: "Dark", at: 0, animated: false)
             themeSegmentedControl.insertSegment(withTitle: "Light", at: 1, animated: false)
         }

        let selectedTheme = UserDefaults.standard.integer(forKey: "selectedTheme")
         // Check if selected index is valid
         if selectedTheme >= 0 && selectedTheme < themeSegmentedControl.numberOfSegments {
              themeSegmentedControl.selectedSegmentIndex = selectedTheme
          } else {
               themeSegmentedControl.selectedSegmentIndex = 0 // Default to Dark if invalid
               UserDefaults.standard.set(0, forKey: "selectedTheme") // Save default
           }

        themeSegmentedControl.isEnabled = !syncWithSystem
    }

    private func setupHoldSpeedStepper() {
        // Provide a default value if key doesn't exist
        let holdSpeed = UserDefaults.standard.float(forKey: "holdSpeedPlayer")
        let validHoldSpeed = holdSpeed > 0 ? holdSpeed : 2.0 // Default to 2.0x if 0 or negative

        holdSpeedSteppper.value = Double(validHoldSpeed)
        holdSpeedSteppper.minimumValue = 0.50
        holdSpeedSteppper.maximumValue = 2.0
        holdSpeedSteppper.stepValue = 0.25
        updateHoldSpeedLabel()
    }

    private func setupMediaPlayerMenu() { // Renamed from setupMenu
        let defaultIcon = UIImage(systemName: "play.rectangle.fill")
        let infuseIcon = UIImage(systemName: "flame")
        let vlcIcon = UIImage(systemName: "film")
        let outplayerIcon = UIImage(systemName: "play.circle.fill")
        let customIcon = UIImage(systemName: "wand.and.stars") // Changed icon
        let networkIcon = UIImage(systemName: "network")
        let nPlayerIcon = UIImage(systemName: "play.fill") // Reused icon

        let action1 = UIAction(title: "Default", image: defaultIcon, handler: { [weak self] _ in self?.setMediaPlayer("Default") })
        let action2 = UIAction(title: "VLC", image: vlcIcon, handler: { [weak self] _ in self?.setMediaPlayer("VLC") })
        let action3 = UIAction(title: "Infuse", image: infuseIcon, handler: { [weak self] _ in self?.setMediaPlayer("Infuse") })
        let action4 = UIAction(title: "OutPlayer", image: outplayerIcon, handler: { [weak self] _ in self?.setMediaPlayer("OutPlayer") })
        let action7 = UIAction(title: "nPlayer", image: nPlayerIcon, handler: { [weak self] _ in self?.setMediaPlayer("nPlayer") })
        let action5 = UIAction(title: "Custom", image: customIcon, handler: { [weak self] _ in self?.setMediaPlayer("Custom") })
        let action6 = UIAction(title: "WebPlayer", image: networkIcon, handler: { [weak self] _ in self?.setMediaPlayer("WebPlayer") })

        let menu = UIMenu(title: "Select Media Player", children: [action1, action5, action6, action2, action3, action4, action7]) // Reordered

        playerButton.menu = menu
        playerButton.showsMenuAsPrimaryAction = true

        // Set initial button title
        let selectedOption = UserDefaults.standard.string(forKey: "mediaPlayerSelected") ?? "Default"
        playerButton.setTitle(selectedOption, for: .normal)
    }

     private func setMediaPlayer(_ player: String) {
          UserDefaults.standard.set(player, forKey: "mediaPlayerSelected")
          playerButton.setTitle(player, for: .normal)
      }

     private func setupSourceButton() {
         updateSourceButtonTitle() // Set initial title
         // Action is set in the Storyboard/XIB or programmatically if needed elsewhere
     }

    private func updateSourceButtonTitle() {
        if let selectedSourceRawValue = UserDefaults.standard.string(forKey: "selectedMediaSource"),
           let selectedSource = MediaSource(rawValue: selectedSourceRawValue) {
            sourceButton.setTitle(selectedSource.displayName, for: .normal)
        } else {
            sourceButton.setTitle("Select Source", for: .normal) // Fallback text
        }
    }


    private func loadUserDefaults() {
        autoPlaySwitch.isOn = UserDefaults.standard.bool(forKey: "AutoPlay")
        landScapeSwitch.isOn = UserDefaults.standard.bool(forKey: "AlwaysLandscape")
        browserPlayerSwitch.isOn = UserDefaults.standard.bool(forKey: "browserPlayer")
        mergeActivitySwitch.isOn = UserDefaults.standard.bool(forKey: "mergeWatching")
        FavoriteNotificationSwitch.isOn = UserDefaults.standard.bool(forKey: "notificationEpisodes")

        // Hold speed and theme are loaded in their specific setup funcs
        updateHoldSpeedLabel() // Ensure label is correct
        updateSourceButtonTitle() // Ensure source button is correct
        updateAppAppearance() // Apply theme settings
    }

    // MARK: - IBActions
    @IBAction func closeButtonTapped() {
        dismiss(animated: true, completion: nil)
    }

    @IBAction func syncThemeSwitchChanged(_ sender: UISwitch) {
        UserDefaults.standard.set(sender.isOn, forKey: "syncWithSystem")
        themeSegmentedControl.isEnabled = !sender.isOn
        updateAppAppearance()
    }

    @IBAction func themeSegmentedControlChanged(_ sender: UISegmentedControl) {
        UserDefaults.standard.set(sender.selectedSegmentIndex, forKey: "selectedTheme")
        updateAppAppearance()
    }

    @IBAction func holdSpeedStepperValueChanged(_ sender: UIStepper) {
        let holdSpeed = Float(sender.value)
        UserDefaults.standard.set(holdSpeed, forKey: "holdSpeedPlayer")
        updateHoldSpeedLabel()
    }

    private func updateHoldSpeedLabel() {
        let holdSpeed = UserDefaults.standard.float(forKey: "holdSpeedPlayer")
        holdSpeeedLabel.text = String(format: "Hold Speed player: %.2fx", holdSpeed)
    }

    @IBAction func episodeSortingChanged(_ sender: UISegmentedControl) {
        let isReverseSorted = sender.selectedSegmentIndex == 1
        UserDefaults.standard.set(isReverseSorted, forKey: "isEpisodeReverseSorted")
        // Post notification if other VCs need immediate update
         NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: nil)
    }

    @IBAction func githubTapped(_ sender: UITapGestureRecognizer) {
        openURL(githubURL)
    }

    @IBAction func selectSourceButtonTapped(_ sender: UIButton) {
        SourceMenu.showSourceSelector(from: self, sourceView: sender) { [weak self] in
            self?.updateSourceButtonTitle()
        }
    }

    @IBAction func clearCache(_ sender: Any) { // Changed sender type
        clearCache()
    }

    @IBAction func autpPlayToggle(_ sender: UISwitch) {
        UserDefaults.standard.set(sender.isOn, forKey: "AutoPlay")
    }

    @IBAction func landScapeToggle(_ sender: UISwitch) {
        UserDefaults.standard.set(sender.isOn, forKey: "AlwaysLandscape")
    }

    @IBAction func browserPlayerToggle(_ sender: UISwitch) {
        UserDefaults.standard.set(sender.isOn, forKey: "browserPlayer")
    }

    @IBAction func mergeActivtyToggle(_ sender: UISwitch) {
        UserDefaults.standard.set(sender.isOn, forKey: "mergeWatching")
        // Update the manager's state directly
         ContinueWatchingManager.shared.setMergeWatching(sender.isOn)
         // Optionally, post a notification if other parts of the app need to react immediately
         // NotificationCenter.default.post(name: .continueWatchingMergeSettingChanged, object: nil)
    }

    @IBAction func notificationsToggle(_ sender: UISwitch) {
        if sender.isOn {
            requestNotificationPermissions { granted in
                DispatchQueue.main.async {
                    if granted {
                        UserDefaults.standard.set(true, forKey: "notificationEpisodes")
                    } else {
                        sender.setOn(false, animated: true) // Revert switch if permission denied
                        UserDefaults.standard.set(false, forKey: "notificationEpisodes")
                         self.showAlert(message: "Please enable notifications in Settings to use this feature.")
                    }
                }
            }
        } else {
            UserDefaults.standard.set(false, forKey: "notificationEpisodes")
        }
    }

    @IBAction func createBackup(_ sender: Any) { // Changed sender type
        guard let backupString = BackupManager.shared.createBackup() else {
            showAlert(message: "Failed to create backup.")
            return
        }
        saveBackupToTemporaryDirectory(backupString, sender: sender)
    }

    @IBAction private func importBackupTapped(_ sender: Any) { // Changed sender type
        presentDocumentPicker()
    }

    @IBAction private func resetAppTapped(_ sender: Any) { // Changed sender type
        presentResetConfirmation()
    }

    @IBAction func clearSearchHistory(_ sender: Any) { // Changed sender type
        clearSearchHistory()
    }

    @IBAction func deleteAllDonloads(_ sender: UIButton) { // Changed sender type
        showDeletionConfirmation()
    }


    // MARK: - Helper Methods
    private func updateAppAppearance() {
        let syncWithSystem = UserDefaults.standard.bool(forKey: "syncWithSystem")

        let style: UIUserInterfaceStyle = {
            if syncWithSystem { return .unspecified }
            return UserDefaults.standard.integer(forKey: "selectedTheme") == 0 ? .dark : .light
        }()

        // Apply to all windows
        UIApplication.shared.windows.forEach { window in
            window.overrideUserInterfaceStyle = style
        }
    }

    func openURL(_ urlString: String) {
        if let url = URL(string: urlString) {
            UIApplication.shared.open(url)
        }
    }

    private func requestNotificationPermissions(completion: @escaping (Bool) -> Void) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error = error {
                print("Error requesting notification permissions: \(error)")
                completion(false)
            } else {
                completion(granted)
            }
        }
    }

    private func clearSearchHistory() {
        UserDefaults.standard.removeObject(forKey: "SearchHistory")
        showAlert(message: "Search history cleared successfully!")
    }

    private func clearCache() {
        let cacheURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first

        do {
            if let cacheURL = cacheURL {
                let fileManager = FileManager.default
                let filePaths = try fileManager.contentsOfDirectory(at: cacheURL, includingPropertiesForKeys: nil, options: [])
                var totalSize: Int64 = 0
                for filePath in filePaths {
                    if let attributes = try? fileManager.attributesOfItem(atPath: filePath.path),
                       let fileSize = attributes[.size] as? NSNumber {
                        totalSize += fileSize.int64Value
                    }
                     try fileManager.removeItem(at: filePath)
                 }
                let formattedSize = ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)
                showAlert(message: "Cache cleared successfully! (\(formattedSize) removed)")
            }
        } catch {
            print("Could not clear cache: \(error)")
            showAlert(message: "Failed to clear cache.")
        }
    }

    private func showAlert(message: String) {
        let alertController = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alertController.addAction(UIAlertAction(title: "OK", style: .default, handler: nil))
        present(alertController, animated: true, completion: nil)
    }

    private func saveBackupToTemporaryDirectory(_ backupString: String, sender: Any) {
        guard let backupData = backupString.data(using: .utf8) else {
             showAlert(message: "Failed to encode backup data.")
             return
         }
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "dd_MMMM_yyyy-HHmm"
        let dateString = dateFormatter.string(from: Date())
        let fileName = "Ryu_Backup_\(dateString).albackup" // More descriptive name
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)

        do {
            try backupData.write(to: tempURL)
            presentActivityViewController(with: tempURL, sender: sender)
        } catch {
            showAlert(message: "Failed to save backup: \(error.localizedDescription)")
        }
    }

    private func presentActivityViewController(with url: URL, sender: Any) {
        let activityVC = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        activityVC.excludedActivityTypes = [.addToReadingList, .assignToContact, .markupAsPDF] // Example exclusions

        // Configure for iPad
        if let popoverController = activityVC.popoverPresentationController {
            if let sourceButton = sender as? UIBarButtonItem {
                 popoverController.barButtonItem = sourceButton
             } else if let sourceView = sender as? UIView {
                 popoverController.sourceView = sourceView
                 popoverController.sourceRect = sourceView.bounds
             } else {
                  popoverController.sourceView = self.view
                  popoverController.sourceRect = CGRect(x: self.view.bounds.midX, y: self.view.bounds.midY, width: 0, height: 0) // Center if source unknown
                  popoverController.permittedArrowDirections = []
              }
        }

        present(activityVC, animated: true, completion: nil)
    }

    private func presentDocumentPicker() {
        // Define the UTType for your backup file extension
         guard let backupType = UTType("me.cranci.albackup") else {
             showAlert(message: "Could not define backup file type.")
             return
         }

         let documentPicker = UIDocumentPickerViewController(forOpeningContentTypes: [backupType], asCopy: true)
         documentPicker.delegate = self
         documentPicker.allowsMultipleSelection = false
         present(documentPicker, animated: true, completion: nil)
    }

    private func presentResetConfirmation() {
        let alertController = UIAlertController(title: "Reset App Data", message: "Are you sure you want to reset all app Data? This action cannot be undone.", preferredStyle: .alert)

        let resetAction = UIAlertAction(title: "Reset", style: .destructive) { [weak self] _ in
            self?.resetUserDefaults()
            self?.loadUserDefaults() // Reload defaults after reset
            self?.showAlert(message: "App Data have been reset.")
             // Optionally clear other data like favorites, history, etc.
             FavoritesManager.shared.saveFavorites([]) // Clear favorites
             ContinueWatchingManager.shared.clearAllItems() // Assuming a method to clear all
             // Clear search history if not already covered by resetUserDefaults
             UserDefaults.standard.removeObject(forKey: "SearchHistory")
             // Clear caches again
             self?.clearCache()
             // Clear downloads
              self?.performDeletion(showConfirmation: false) // Delete without confirmation prompt


            NotificationCenter.default.post(name: .appDataReset, object: nil) // Notify other parts of the app
        }

        alertController.addAction(resetAction)
        alertController.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: nil))

        present(alertController, animated: true, completion: nil)
    }

    private func resetUserDefaults() {
        if let domain = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: domain)
            UserDefaults.standard.synchronize()
            // Re-apply essential defaults if needed, or handle in setupDefaultUserPreferences in AppDelegate
             setupDefaultUserPreferences() // Call the setup func again
        }
    }

     // Extracted deletion confirmation logic
      private func showDeletionConfirmation() {
          let alertController = UIAlertController(title: "Confirm Deletion", message: "Are you sure you want to delete all downloads? This action cannot be undone.", preferredStyle: .alert)

          let deleteAction = UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
              self?.performDeletion()
          }
          let cancelAction = UIAlertAction(title: "Cancel", style: .cancel)

          alertController.addAction(deleteAction)
          alertController.addAction(cancelAction)
          present(alertController, animated: true)
      }


     private func performDeletion(showConfirmation: Bool = true) { // Added parameter
         let fileManager = FileManager.default
         do {
             let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
             let fileURLs = try fileManager.contentsOfDirectory(at: documentsURL, includingPropertiesForKeys: nil)
             var deletedCount = 0
             var errorOccurred = false

             for fileURL in fileURLs {
                  // Optional: Check file extension if you only want to delete specific types
                  // if ["mp4", "mpeg", "albackup"].contains(fileURL.pathExtension.lowercased()) {
                      do {
                          try fileManager.removeItem(at: fileURL)
                          deletedCount += 1
                      } catch {
                           print("Failed to delete item \(fileURL.lastPathComponent): \(error)")
                           errorOccurred = true
                       }
                  // }
              }

             if showConfirmation { // Only show alert if triggered by user action
                  if errorOccurred {
                       showAlert(message: "Some downloads could not be deleted. Please check the Files app.")
                   } else if deletedCount > 0 {
                        showAlert(message: "All \(deletedCount) download(s) deleted successfully.")
                    } else {
                         showAlert(message: "No downloads found to delete.")
                     }
              }

             // Notify other parts of the app if needed
              // NotificationCenter.default.post(name: .downloadListUpdated, object: nil)

         } catch {
              if showConfirmation {
                   showAlert(message: "Failed to access downloads directory: \(error.localizedDescription)")
               }
              print("Failed to access downloads directory: \(error.localizedDescription)")
          }
     }

      // Re-apply default user preferences (can be called after reset)
       private func setupDefaultUserPreferences() {
            let defaultValues: [String: Any] = [
                "selectedMediaSource": "AnimeWorld", // Default source
                "AnimeListingService": "AniList", // Default listing service
                "maxRetries": 10,
                "holdSpeedPlayer": 2.0, // Use float literal
                "preferredQuality": "1080p",
                "subtitleHiPrefe": "English", // Default subtitle for AniList
                "serverHiPrefe": "Always Ask", // Default server for AniList
                "audioHiPrefe": "Always Ask", // Default audio for AniList
                 "anilistAudioPref": "Always Ask", // Default for renamed key
                 "anilistServerPref": "Always Ask",
                 "anilistSubtitlePref": "English",
                "syncWithSystem": true,
                "fullTitleCast": true,
                "animeImageCast": true,
                "AutoPlay": false, // Default autoplay to off
                "AlwaysLandscape": false, // Default landscape to off
                "browserPlayer": false, // Default browser player to off
                "mergeWatching": false, // Default merge watching to off
                "notificationEpisodes": false, // Default notifications to off
                "sendPushUpdates": false, // Default AniList updates to off
                "otherFormats": false, // Default other formats off
                 "gogoFetcher": "Default", // Default GoGo fetcher
                 "mediaPlayerSelected": "Default", // Default player
                 "castStreamingType": "buffered", // Default cast type
                 "autoSkipIntro": false, // Default skip intro off
                 "autoSkipOutro": false, // Default skip outro off
                 "skipFeedbacks": true, // Default feedback on
                 "customAnimeSkipInstance": false, // Default custom skip instance off
                 "googleTranslation": false, // Default translation off
                 "translationLanguage": "en", // Default translation lang
                 "customTranslatorInstance": false // Default custom translator off
            ]

            for (key, value) in defaultValues {
                // Set only if the key doesn't exist after reset
                 if UserDefaults.standard.object(forKey: key) == nil {
                      UserDefaults.standard.set(value, forKey: key)
                  }
            }
             UserDefaults.standard.synchronize() // Ensure defaults are saved
        }
}

// MARK: - UIDocumentPickerDelegate
extension SettingsViewController: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let selectedFileURL = urls.first else {
            showAlert(message: "No file selected.")
            return
        }
        // Security check: Ensure it's our expected file type if possible
         guard selectedFileURL.pathExtension == "albackup" else {
             showAlert(message: "Invalid file type selected. Please choose a '.albackup' file.")
             return
         }

        presentBackupImportOptions(for: selectedFileURL)
    }

    private func presentBackupImportOptions(for url: URL) {
        let alertController = UIAlertController(title: "Backup Import Options", message: "Choose how to handle the backup:", preferredStyle: .alert)

        let replaceAction = UIAlertAction(title: "Replace Current Data", style: .destructive) { [weak self] _ in // Make replace destructive
            self?.replaceData(withBackupAt: url)
        }

        let mergeAction = UIAlertAction(title: "Merge Backup with Data", style: .default) { [weak self] _ in
            self?.mergeBackup(withBackupAt: url)
        }

        alertController.addAction(replaceAction)
        alertController.addAction(mergeAction)
        alertController.addAction(UIAlertAction(title: "Cancel", style: .cancel)) // Keep cancel non-destructive

        present(alertController, animated: true)
    }

    private func replaceData(withBackupAt url: URL) {
        do {
            // Clear existing UserDefaults first
            if let domain = Bundle.main.bundleIdentifier {
                UserDefaults.standard.removePersistentDomain(forName: domain)
                UserDefaults.standard.synchronize()
            }

            let backupData = try Data(contentsOf: url)
            guard let backupString = String(data: backupData, encoding: .utf8) else {
                showAlert(message: "Invalid backup file format (not UTF8).")
                 // Re-apply default settings if replace failed
                 setupDefaultUserPreferences()
                return
            }

            if BackupManager.shared.importBackup(backupString) {
                showAlert(message: "Backup imported successfully and current data replaced!")
                NotificationCenter.default.post(name: .appDataReset, object: nil) // Notify app reset
                loadUserDefaults() // Reload UI with imported settings
                 updateAppAppearance() // Apply theme
            } else {
                showAlert(message: "Failed to import backup data.")
                 // Re-apply default settings if import failed
                 setupDefaultUserPreferences()
                  loadUserDefaults() // Reload UI with default settings
                  updateAppAppearance()
            }
        } catch {
            showAlert(message: "Failed to read backup file: \(error.localizedDescription)")
             // Re-apply default settings if file reading failed
             setupDefaultUserPreferences()
              loadUserDefaults()
              updateAppAppearance()
        }
    }

    private func mergeBackup(withBackupAt url: URL) {
        do {
            // Merging implies keeping existing data and overwriting/adding from backup
            let backupData = try Data(contentsOf: url)
            guard let backupString = String(data: backupData, encoding: .utf8) else {
                showAlert(message: "Invalid backup file format (not UTF8).")
                return
            }

            if BackupManager.shared.importBackup(backupString) { // BackupManager handles the merge logic
                showAlert(message: "Backup imported successfully and merged with current data!")
                NotificationCenter.default.post(name: .appDataReset, object: nil) // Notify potentially significant changes
                loadUserDefaults() // Reload UI with merged settings
                 updateAppAppearance() // Apply theme
            } else {
                showAlert(message: "Failed to import and merge backup.")
            }
        } catch {
            showAlert(message: "Failed to read backup file: \(error.localizedDescription)")
        }
    }
}
