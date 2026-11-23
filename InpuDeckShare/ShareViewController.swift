import UIKit
import UniformTypeIdentifiers

/// The extension hands off the shared text to the app and closes itself. It
/// never renders the secret: the text goes through the persistent inbox and
/// the running app types it, which is the only route that owns the Bluetooth
/// connection. If the text cannot be read or saved, the extension keeps a
/// manual fallback instead of reporting success it did not earn.
final class ShareViewController: UIViewController {
    private let statusLabel = UILabel()
    private let sendButton = UIButton(type: .system)
    private let closeButton = UIButton(type: .system)

    private var fallbackAttributedText: [String] = []
    private var extractedText = ""
    private var isSending = false

    override func viewDidLoad() {
        super.viewDidLoad()
        configureUI()
        loadSharedContent()
    }

    private func configureUI() {
        view.backgroundColor = .systemGroupedBackground

        let titleLabel = UILabel()
        titleLabel.text = "InpuDeck"
        titleLabel.font = .preferredFont(forTextStyle: .title2)
        titleLabel.adjustsFontForContentSizeCategory = true

        let subtitleLabel = UILabel()
        subtitleLabel.text = localized("Текст піде через вибраний Bluetooth-вихід, щойно InpuDeck відкриється.")
        subtitleLabel.font = .preferredFont(forTextStyle: .subheadline)
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.numberOfLines = 0

        statusLabel.text = localized("Завантаження…")
        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        statusLabel.textColor = .secondaryLabel
        statusLabel.numberOfLines = 2

        var sendConfiguration = UIButton.Configuration.filled()
        sendConfiguration.title = localized("Надіслати зараз")
        sendConfiguration.image = UIImage(systemName: "paperplane.fill")
        sendConfiguration.imagePadding = 8
        sendButton.configuration = sendConfiguration
        sendButton.addTarget(self, action: #selector(sendTapped), for: .touchUpInside)
        sendButton.isEnabled = false

        closeButton.setTitle(localized("Закрити"), for: .normal)
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)

        let buttonRow = UIStackView(arrangedSubviews: [closeButton, sendButton])
        buttonRow.axis = .horizontal
        buttonRow.alignment = .center
        buttonRow.distribution = .fillEqually
        buttonRow.spacing = 12

        let stack = UIStackView(arrangedSubviews: [
            titleLabel,
            subtitleLabel,
            statusLabel,
            buttonRow
        ])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            sendButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            closeButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        ])
    }

    private func loadSharedContent() {
        let extensionItems = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        let providers = extensionItems.flatMap { $0.attachments ?? [] }
        fallbackAttributedText = extensionItems.compactMap { $0.attributedContentText?.string }
        loadProviderText(providers, index: 0, collected: [])
    }

    private func loadProviderText(
        _ providers: [NSItemProvider],
        index: Int,
        collected: [String]
    ) {
        guard index < providers.count else {
            let unique = collected.reduce(into: [String]()) { values, value in
                guard !value.isEmpty, !values.contains(value) else { return }
                values.append(value)
            }
            extractedText = (unique.isEmpty ? fallbackAttributedText : unique).joined(separator: "\n")
            enqueueAndClose()
            return
        }

        let provider = providers[index]
        let typeIdentifier: String?
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            typeIdentifier = UTType.url.identifier
        } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            typeIdentifier = UTType.plainText.identifier
        } else if provider.hasItemConformingToTypeIdentifier(UTType.text.identifier) {
            typeIdentifier = UTType.text.identifier
        } else {
            typeIdentifier = nil
        }

        guard let typeIdentifier else {
            loadProviderText(providers, index: index + 1, collected: collected)
            return
        }

        provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { [weak self] item, _ in
            let value = Self.stringValue(from: item)
            DispatchQueue.main.async {
                var updated = collected
                if let value, !value.isEmpty {
                    updated.append(value)
                }
                self?.loadProviderText(providers, index: index + 1, collected: updated)
            }
        }
    }

    nonisolated private static func stringValue(from item: NSSecureCoding?) -> String? {
        switch item {
        case let url as NSURL:
            url.absoluteString
        case let string as NSString:
            string as String
        case let data as NSData:
            String(data: data as Data, encoding: .utf8)
        default:
            nil
        }
    }

    private func enqueueAndClose() {
        guard !extractedText.isEmpty else {
            showManualFallback(localized("У спільному елементі немає тексту або URL."))
            return
        }
        guard extractedText.count <= 2_000 else {
            showManualFallback(localized("Скоротіть текст до 2000 символів."))
            return
        }
        guard ShareTextInbox.enqueue(extractedText) else {
            showManualFallback(localized("Не вдалося зберегти текст"))
            return
        }

        isSending = true
        sendButton.isEnabled = false
        closeButton.isEnabled = false
        statusLabel.text = localized("Текст збережено. Відкрий InpuDeck для надсилання.")

        // extensionContext.open is not a supported guarantee for foreground
        // launch, so the text is already in the inbox and the app picks it up
        // when the user opens it. Do not report success we did not earn: the
        // extension closes here, and the app's own launch path does the rest.
        extensionContext?.completeRequest(returningItems: nil)
    }

    private func showManualFallback(_ message: String) {
        isSending = false
        sendButton.isEnabled = true
        closeButton.isEnabled = true
        statusLabel.text = localizedFormat("%@. Текст не втрачено; можна повторити.", message)
    }

    @objc private func sendTapped() {
        guard !extractedText.isEmpty else {
            statusLabel.text = localized("Введіть текст для передавання.")
            return
        }
        guard ShareTextInbox.enqueue(extractedText) else {
            showManualFallback(localized("Не вдалося зберегти текст"))
            return
        }

        isSending = true
        sendButton.isEnabled = false
        closeButton.isEnabled = false
        statusLabel.text = localized("Текст збережено. Відкрий InpuDeck для надсилання.")
        extensionContext?.completeRequest(returningItems: nil)
    }

    @objc private func closeTapped() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}
