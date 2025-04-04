import UIKit

class SettingsViewTranslation: UITableViewController {

    @IBOutlet var translationSwitch: UISwitch!
    @IBOutlet var customInstanceSwitch: UISwitch!

    @IBOutlet weak var preferedLanguage: UIButton!

    // List of supported languages by Deeplx (adjust if API changes)
    let supportedLanguages: [(code: String, name: String)] = [
        ("en", "English"), ("ar", "Arabic"), ("bg", "Bulgarian"), ("cs", "Czech"),
        ("da", "Danish"), ("de", "German"), ("el", "Greek"), ("es", "Spanish"),
        ("et", "Estonian"), ("fi", "Finnish"), ("fr", "French"), ("hu", "Hungarian"),
        ("id", "Indonesian"), ("it", "Italian"), ("ja", "Japanese"), ("ko", "Korean"),
        ("lt", "Lithuanian"), ("lv", "Latvian"), ("nl", "Dutch"), ("pl", "Polish"),
        ("pt", "Portuguese"), ("ro", "Romanian"), ("ru", "Russian"), ("sk", "Slovak"),
        ("sl", "Slovenian"), ("sv", "Swedish"), ("tr", "Turkish"), ("uk", "Ukrainian")
    ]

    override func viewDidLoad() {
        super.viewDidLoad()
        loadUserDefaults()
        setupLanguageMenu()
        // Disable language selection if translation is off initially
        preferedLanguage.isEnabled = translationSwitch.isOn
        customInstanceSwitch.isEnabled = translationSwitch.isOn // Also disable custom instance if translation off
    }

    private func loadUserDefaults() {
        translationSwitch.isOn = UserDefaults.standard.bool(forKey: "googleTranslation") // Keep old key for main toggle
        customInstanceSwitch.isOn = UserDefaults.standard.bool(forKey: "customTranslatorInstance")

        // Update UI state based on loaded values
         preferedLanguage.isEnabled = translationSwitch.isOn
         customInstanceSwitch.isEnabled = translationSwitch.isOn
         // Update language button title
          let selectedLanguageCode = UserDefaults.standard.string(forKey: "translationLanguage") ?? "en"
          let selectedLanguageName = supportedLanguages.first(where: { $0.code == selectedLanguageCode })?.name ?? "English"
          preferedLanguage.setTitle(selectedLanguageName, for: .normal)
    }

    @IBAction func closeButtonTapped() {
        dismiss(animated: true, completion: nil)
    }

    @IBAction func translationToggle(_ sender: UISwitch) {
        UserDefaults.standard.set(sender.isOn, forKey: "googleTranslation") // Keep old key
        // Enable/disable dependent controls
        preferedLanguage.isEnabled = sender.isOn
        customInstanceSwitch.isEnabled = sender.isOn
        // If turning off, maybe reset custom instance URL? Optional.
        // if !sender.isOn {
        //     UserDefaults.standard.removeObject(forKey: "savedTranslatorInstance")
        //     UserDefaults.standard.set(false, forKey: "customTranslatorInstance")
        //     customInstanceSwitch.setOn(false, animated: true)
        // }
    }

    func setupLanguageMenu() {
        let currentLanguageCode = UserDefaults.standard.string(forKey: "translationLanguage") ?? "en"

        let languageItems = supportedLanguages.map { (code, name) in
            UIAction(title: name, state: currentLanguageCode == code ? .on : .off) { [weak self] _ in
                UserDefaults.standard.set(code, forKey: "translationLanguage")
                self?.preferedLanguage.setTitle(name, for: .normal)
                 // No need to call setupLanguageMenu again here, just update title
            }
        }

        let languageSubmenu = UIMenu(title: "Select Language", children: languageItems)

        preferedLanguage.menu = languageSubmenu
        preferedLanguage.showsMenuAsPrimaryAction = true

        // Set initial title based on saved preference or default
        let selectedLanguageName = supportedLanguages.first(where: { $0.code == currentLanguageCode })?.name ?? "English"
        preferedLanguage.setTitle(selectedLanguageName, for: .normal)
    }


    @IBAction func urlToggle(_ sender: UISwitch) {
        UserDefaults.standard.set(sender.isOn, forKey: "customTranslatorInstance")

        if sender.isOn {
            presentURLAlert()
        } else {
            // Optionally clear the saved URL when toggled off
            // UserDefaults.standard.removeObject(forKey: "savedTranslatorInstance")
        }
    }

    private func presentURLAlert() {
        let alertController = UIAlertController(title: "Enter Custom Instance URL", message: "Format: https://your-instance.com/api/translate\n(Must match the DeepLX API structure)", preferredStyle: .alert)

        alertController.addTextField { textField in
            textField.placeholder = "https://translate-api-first.vercel.app/api/translate" // Example
            textField.keyboardType = .URL
             // Pre-fill with existing saved URL if available
              textField.text = UserDefaults.standard.string(forKey: "savedTranslatorInstance")
        }

        let saveAction = UIAlertAction(title: "Save", style: .default) { [weak self] _ in
            if let urlString = alertController.textFields?.first?.text, !urlString.isEmpty {
                 // Basic validation: Check if it starts with https://
                 if urlString.lowercased().hasPrefix("https://") {
                      self?.saveURL(urlString)
                  } else {
                       self?.showAlert(title: "Invalid URL", message: "URL must start with https://")
                       // Revert the switch state if URL is invalid after saving attempt
                        self?.customInstanceSwitch.setOn(false, animated: true)
                        UserDefaults.standard.set(false, forKey: "customTranslatorInstance")
                   }
            } else {
                 // Handle empty input - maybe revert switch?
                  self?.showAlert(title: "Input Required", message: "Please enter a URL.")
                  self?.customInstanceSwitch.setOn(false, animated: true)
                  UserDefaults.standard.set(false, forKey: "customTranslatorInstance")
              }
        }

        let cancelAction = UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
            // Revert the switch if user cancels without saving a valid URL
            if UserDefaults.standard.string(forKey: "savedTranslatorInstance") == nil || UserDefaults.standard.string(forKey: "savedTranslatorInstance")!.isEmpty {
                self?.customInstanceSwitch.setOn(false, animated: true)
                UserDefaults.standard.set(false, forKey: "customTranslatorInstance")
            }
        }


        alertController.addAction(saveAction)
        alertController.addAction(cancelAction)

        present(alertController, animated: true, completion: nil)
    }

    private func saveURL(_ urlString: String) {
        UserDefaults.standard.set(urlString, forKey: "savedTranslatorInstance")
         showAlert(title: "Success", message: "Custom instance URL saved.")
    }

     // Helper to show simple alerts
     private func showAlert(title: String, message: String) {
         let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
         alert.addAction(UIAlertAction(title: "OK", style: .default))
         present(alert, animated: true)
     }
}
