import Foundation
import NookletCore

func checkZshConfiguration() throws {
    let manager = FileManager.default
    let home = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? manager.removeItem(at: home) }
    let config = home.appendingPathComponent("config")
    let system = home.appendingPathComponent("etc")
    for directory in [config, system] {
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func fixture(_ text: String, at url: URL) throws {
        try Data(text.utf8).write(to: url)
    }

    let zshrc = config.appendingPathComponent(".zshrc")
    let nested = config.appendingPathComponent("nested settings.zsh")
    let link = config.appendingPathComponent("linked.zsh")
    try fixture(#"export ZDOTDIR="${XDG_CONFIG_HOME:-$HOME/config}""#, at: home.appendingPathComponent(".zshenv"))
    try fixture(#"""
    source "$ZDOTDIR/linked.zsh"
    cat <<'BODY'
    source "$ZDOTDIR/ignored.zsh"
    BODY
    # source "$ZDOTDIR/ignored.zsh"
    echo "source $ZDOTDIR/ignored.zsh"
    source <(echo unexpected)
    if [[ -f "$ZDOTDIR/after.zsh" ]]; then . \
      "$ZDOTDIR/after.zsh"; fi
    """#, at: zshrc)
    try fixture(#". "${0:A:h}/.zshrc""#, at: nested)
    try fixture("# nested content", at: config.appendingPathComponent("after.zsh"))
    try fixture("# ignored content", at: config.appendingPathComponent("ignored.zsh"))
    try manager.createSymbolicLink(at: link, withDestinationURL: nested)

    try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: nested.path)

    let scan = ZshConfigurationFiles.scan(home: home, environment: [:], systemDirectory: system)
    try expectEqual(scan.files.count, 4)
    try expectFalse(scan.limited)
    guard let root = scan.files.first(where: { $0.url == zshrc }),
          let included = scan.files.first(where: { $0.url == link }) else {
        throw CheckFailure("Missing startup and linked config files")
    }
    try expect(root.startup)
    try expectFalse(included.startup)
    try expectEqual(root.references.map(\.line), [1, 7, 8])
    try expectEqual(root.references.first?.target, included.id)
    try expectNil(root.references[1].target)
    try expectEqual(included.references.first?.target, root.id)

    try ZshConfigurationFiles.save("# updated", to: included)
    try expectEqual(try String(contentsOf: nested, encoding: .utf8), "# updated")
    try expectEqual(try manager.attributesOfItem(atPath: nested.path)[.posixPermissions] as? Int, 0o600)
    try expectEqual(try manager.destinationOfSymbolicLink(atPath: link.path), nested.path)
    try expectError(try ZshConfigurationFiles.save("# overwrite stale content", to: included))
    try expectEqual(try String(contentsOf: nested, encoding: .utf8), "# updated")

    let other = home.appendingPathComponent("fresh")
    try manager.createDirectory(at: other, withIntermediateDirectories: false)
    let fresh = ZshConfigurationFiles.scan(home: other, environment: [:], systemDirectory: system)
    guard let empty = fresh.files.first else { throw CheckFailure("Missing .zshrc creation entry") }
    try expectNil(empty.data)
    try ZshConfigurationFiles.save("# new zshrc", to: empty)
    try expectEqual(try String(contentsOf: empty.url, encoding: .utf8), "# new zshrc")
}
