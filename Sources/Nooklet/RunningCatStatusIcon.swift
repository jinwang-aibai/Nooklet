import AppKit

@MainActor
final class RunningCatStatusIcon {
    private weak var button: NSStatusBarButton?
    private lazy var frames: [NSImage] = {
        let packaged = Bundle.main.resourceURL.flatMap {
            Bundle(url: $0.appendingPathComponent("Nooklet_Nooklet.bundle", isDirectory: true))
        }
        let bundle = packaged ?? Bundle.module
        return (0..<5).compactMap { index in
            let name = String(format: "frame-%03d", index)
            guard let url = bundle.url(forResource: name, withExtension: "png", subdirectory: "RunCat"),
                  let image = NSImage(contentsOf: url) else { return nil }
            image.size = NSSize(width: 26.25, height: 15)
            image.isTemplate = true
            return image
        }
    }()
    private var restingImage: NSImage? {
        frames.first ?? NSImage(systemSymbolName: "cat.fill", accessibilityDescription: nil)
    }
    private var frame = 0
    private var timer: Timer?
    private var load = 0.0
    private var delay: TimeInterval { 0.30 - 0.23 * load.squareRoot() }

    func attach(to button: NSStatusBarButton?) {
        self.button = button
        button?.image = restingImage
    }

    func setAnimating(_ animating: Bool) {
        if animating {
            if timer == nil, frames.count > 1 { scheduleFrame() }
        } else {
            timer?.invalidate()
            timer = nil
            frame = 0
            button?.image = restingImage
        }
    }

    func update(cpuUsage: Double?) {
        guard let cpuUsage, cpuUsage.isFinite else { return }
        load += (min(1, max(0, cpuUsage)) - load) * 0.45
    }

    private func scheduleFrame() {
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let button = self.button else { return }
                self.frame = (self.frame + 1) % self.frames.count
                button.image = self.frames[self.frame]
                self.scheduleFrame()
            }
        }
        timer.tolerance = delay * 0.12
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}
