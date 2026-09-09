import AppKit
import BruceAppCore

@MainActor
final class MenuBarRefreshGlyphController {
    private weak var button: NSStatusBarButton?
    private let imageView = NSImageView()
    private var timer: Timer?
    private var rotation = 0.0

    func attach(to button: NSStatusBarButton) {
        detach()
        self.button = button

        if let image = NSImage(
            systemSymbolName: "arrow.clockwise",
            accessibilityDescription: "Bruce refreshing"
        ) {
            image.isTemplate = true
            imageView.image = image
        }
        imageView.imageScaling = .scaleProportionallyDown
        imageView.contentTintColor = .controlTextColor
        imageView.wantsLayer = true
        imageView.isHidden = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 2),
            imageView.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 14),
            imageView.heightAnchor.constraint(equalToConstant: 14),
        ])
    }

    func setVisible(_ visible: Bool) {
        imageView.isHidden = !visible
        if visible {
            startTimerIfNeeded()
        } else {
            stopTimer()
            rotation = 0
            imageView.layer?.setAffineTransform(.identity)
        }
    }

    func advance() {
        guard !imageView.isHidden else { return }
        rotation = (rotation + 45).truncatingRemainder(dividingBy: 360)
        imageView.layer?.setAffineTransform(
            CGAffineTransform(rotationAngle: rotation * .pi / 180)
        )
    }

    func detach() {
        stopTimer()
        imageView.removeFromSuperview()
        button = nil
        rotation = 0
        imageView.layer?.setAffineTransform(.identity)
    }

    private func startTimerIfNeeded() {
        guard timer == nil else { return }
        let timer = Timer(
            timeInterval: MenuBarRenderPolicy.animationIntervalSeconds,
            target: self,
            selector: #selector(timerDidFire),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    @objc private func timerDidFire() {
        advance()
    }
}
