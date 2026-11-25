import Combine
import Foundation
import NookletCore

@MainActor
final class SoftwareUpdateModel: ObservableObject {
    enum State: Equatable {
        case idle
        case checking
        case result(SoftwareUpdate)
        case failed(String)
    }

    @Published private(set) var state = State.idle

    func check() {
        guard state != .checking else { return }
        guard let version = AppVersion.current.version else {
            state = .failed(L10n.text("无法识别当前版本。"))
            return
        }
        state = .checking
        Task {
            do {
                state = .result(try await SoftwareUpdate.check(currentVersion: version))
            } catch SoftwareUpdate.CheckError.rateLimited {
                state = .failed(L10n.text("GitHub 的请求次数已达上限。请稍后重试。"))
            } catch let error as URLError where error.code == .notConnectedToInternet {
                state = .failed(L10n.text("网络未连接。请联网后重试。"))
            } catch {
                state = .failed(L10n.text("无法检查更新。请稍后重试。"))
            }
        }
    }
}
