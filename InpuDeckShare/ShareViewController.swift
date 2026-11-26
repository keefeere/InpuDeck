import UIKit
import UniformTypeIdentifiers

/// The extension hands off the shared text to the app and closes itself. It
/// never renders the secret: the text goes through the persistent inbox and
/// the running app types it, which is the only route that owns the Bluetooth
/// connection. The extension tries to bring the app forward via the URL
/// scheme, but iOS does not guarantee that — the app still opens from the URL
/// when it is already running. Only a failure (nothing read, too long, cannot
/// save) keeps a window, and it shows an error and a close button, never the
/// text.
final class ShareViewController: UIViewController {
    private let statusLabel = UILabel()
    private let closeButton = UIButton(type: .system)

    private var fallbackAttributedText: [String] = []
    private var extractedText = ""

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

        closeButton.setTitle(localized("Закрити"), for: .normal)
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [
            titleLabel,
            subtitleLabel,
            statusLabel,
            closeButton
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

        // Some providers never call the completion handler. Without a bound,
        // the extension would sit on "Завантаження…" forever and never close.
        // Track which of the two paths (handler vs timeout) won the race so a
        // late handler cannot double-advance the index.
        var settled = false
        let timeout = DispatchWorkItem { [weak self] in
            guard !settled else { return }
            settled = true
            self?.loadProviderText(providers, index: index + 1, collected: collected)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: timeout)

        provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { [weak self] item, _ in
            guard !settled else { return }
            settled = true
            timeout.cancel()
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
            ShareResult.write(status: .noText)
            showManualFallback(localized("У спільному елементі немає тексту або URL."))
            return
        }
        guard extractedText.count <= 2_000 else {
            ShareResult.write(status: .tooLong, length: extractedText.count)
            showManualFallback(localized("Скоротіть текст до 2000 символів."))
            return
        }
        guard ShareTextInbox.enqueue(extractedText) else {
            ShareResult.write(status: .enqueueFailed, length: extractedText.count)
            showManualFallback(localized("Не вдалося зберегти текст"))
            return
        }
        // Try to bring the app forward so the stored text can reach the
        // computer. The extension cannot transmit HID itself — only this
        // running app owns the Bluetooth route — so it hands off via the
        // URL scheme. iOS does not guarantee the launch, but the attempt is
        // honest: the app still opens from the URL when it is already running.
        openAppViaResponderChain(length: extractedText.count)
    }

    /// Walk the responder chain to the UIApplication and call openURL:options:completionHandler:.
    /// The extension target is APPLICATION_EXTENSION_API_ONLY, so a direct
    /// app.open(...) does not compile — the dynamic call is the honest path.
    /// completeRequest is called only in the completion, never before the
    /// result is known.
    private func openAppViaResponderChain(length: Int) {
        guard let sendURL = ShareHandoff.sendURL else {
            ShareResult.write(status: .ok, length: length, opened: false, foundUIApplication: false)
            showManualFallback(localized("Відкрийте InpuDeck вручну"))
            return
        }
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        var responder: UIResponder? = self
        while let current = responder {
            if current is UIApplication, current.responds(to: selector) {
                typealias Fn = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, (@convention(block) (Bool) -> Void)?) -> Void
                guard let method = current.method(for: selector) else {
                    ShareResult.write(status: .ok, length: length, opened: false, foundUIApplication: true)
                    showManualFallback(localized("Відкрийте InpuDeck вручну"))
                    return
                }
                let fn = unsafeBitCast(method, to: Fn.self)
                fn(current, selector, sendURL as NSURL, NSDictionary(), { [weak self] ok in
                    DispatchQueue.main.async {
                        self?.finishWithOpenResult(ok: ok, length: length, foundUIApplication: true)
                    }
                })
                return
            }
            responder = current.next
        }
        // UIApplication not found in the chain — the handoff was never
        // attempted. The text is in the inbox; the app must be opened manually.
        ShareResult.write(status: .ok, length: length, opened: false, foundUIApplication: false)
        showManualFallback(localized("Відкрийте InpuDeck вручну"))
    }

    private func finishWithOpenResult(ok: Bool, length: Int, foundUIApplication: Bool) {
        ShareResult.write(status: .ok, length: length, opened: ok, foundUIApplication: foundUIApplication)
        if ok {
            extensionContext?.completeRequest(returningItems: nil)
        } else {
            showManualFallback(localized("Відкрийте InpuDeck вручну"))
        }
    }

    private func showManualFallback(_ message: String) {
        statusLabel.text = localizedFormat("%@. Текст не втрачено.", message)
    }

    @objc private func closeTapped() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}
