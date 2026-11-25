import CryptoKit
import Foundation

/// Self-contained receiver pages: no external assets, fonts, or network requests.
struct LANShareBrowser {
    private static let segmentCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-~")
    static func encodeSegment(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: segmentCharacters) ?? "" }

    private func url(_ path: [String]) -> String {
        "/" + path.map(Self.encodeSegment).joined(separator: "/")
    }

    func home(items: [(segment: String, item: LANShareItem)], text: String) -> Data {
        var content = ""
        if !items.isEmpty {
            let sorted = items.sorted {
                if $0.item.isDirectory != $1.item.isDirectory { return $0.item.isDirectory }
                return $0.item.name.localizedStandardCompare($1.item.name) == .orderedAscending
            }
            let rows = sorted.map { row(name: $0.item.name, directory: $0.item.isDirectory,
                                        size: $0.item.size, href: url(["files", $0.segment])) }.joined()
            content += fileSection(title: "共享目录", count: items.count, rows: rows)
        }
        if !text.isEmpty {
            content += """
            <section aria-labelledby="note"><div class="section-head"><h2 id="note">共享文本</h2>
            <div class="tools"><button type="button" id="copy" title="复制文本" aria-label="复制文本">\(svg(Self.copyGlyph))</button>
            <a class="action" href="/text.txt" title="下载 TXT" aria-label="下载 TXT">\(svg(Self.downloadGlyph))</a></div></div>
            <textarea id="shared-text" aria-label="共享文本" readonly>
            \(Self.escape(text))</textarea><span class="feedback" id="feedback" role="status"></span></section>
            """
        }
        if content.isEmpty {
            content = """
            <section class="empty"><span class="empty-mark">\(svg(Self.folderGlyph))</span><h2>等待共享内容</h2>
            <a class="action" href="/" title="刷新" aria-label="刷新">\(svg(Self.refreshGlyph))</a></section>
            """
        }
        return page(title: "内网文件共享", breadcrumb: "", content: content, hasText: !text.isEmpty)
    }

    func folder(item: LANShareItem, root: String, path: [String], entries: [LANShareRow]) -> Data {
        let ancestors = [root] + path.dropFirst(2)
        var crumbs = "<a href=\"/\">共享首页</a>"
        for (index, name) in ancestors.enumerated() {
            crumbs += "<span class=\"slash\" aria-hidden=\"true\">/</span>"
            if index == ancestors.count - 1 {
                crumbs += "<span aria-current=\"page\">\(Self.escape(name))</span>"
            } else {
                crumbs += "<a href=\"\(url(Array(path.prefix(index + 2))))\">\(Self.escape(name))</a>"
            }
        }
        let rows = entries.map { row(name: $0.name, directory: $0.isDirectory, size: $0.size,
                                     href: url(path + [$0.name])) }.joined()
        return page(title: item.name, breadcrumb: crumbs,
                    content: fileSection(title: "目录", count: entries.count, rows: rows), hasText: false)
    }

    private func fileSection(title: String, count: Int, rows: String) -> String {
        """
        <section aria-labelledby="files"><div class="section-head"><h2 id="files">\(title)</h2><span class="count">\(count) 项</span></div>
        \(rows.isEmpty ? "<p class=\"empty-row\">没有可共享的项目</p>" : "<ul>\(rows)</ul>")</section>
        """
    }

    private func row(name: String, directory: Bool, size: Int64, href: String) -> String {
        let action = directory ? "打开" : "下载"
        let detail = directory ? "" : "<small>\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))</small>"
        return """
        <li><a class="row" href="\(href)" aria-label="\(action) \(Self.escape(name))">
        <span class="icon \(directory ? "folder" : "file")">\(svg(directory ? Self.folderGlyph : Self.fileGlyph))</span>
        <strong>\(Self.escape(name))</strong>\(detail)
        <span class="row-action">\(svg(directory ? Self.openGlyph : Self.downloadGlyph))</span></a></li>
        """
    }

    private func svg(_ path: String) -> String {
        "<svg aria-hidden=\"true\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.65\" stroke-linecap=\"round\" stroke-linejoin=\"round\">\(path)</svg>"
    }

    private func page(title: String, breadcrumb: String, content: String, hasText: Bool) -> Data {
        Data("""
        <!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(Self.escape(title)) · Nooklet</title><style>\(Self.css)</style></head><body><main>
        <header><a class="brand" href="/" aria-label="Nooklet 共享首页"><span class="brand-mark" aria-hidden="true">↗</span>Nooklet</a>
        \(breadcrumb.isEmpty ? "" : "<nav aria-label=\"目录路径\">\(breadcrumb)</nav>")
        <h1>\(Self.escape(title))</h1></header>\(content)
        </main>\(hasText ? "<script>\(Self.script)</script>" : "")</body></html>
        """.utf8)
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static let folderGlyph = "<path d=\"M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z\"/>"
    private static let fileGlyph = "<path d=\"M13 3H6a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V10zM13 3v7h7\"/>"
    private static let openGlyph = "<path d=\"m9 6 6 6-6 6\"/>"
    private static let downloadGlyph = "<path d=\"M12 4v11m-4-4 4 4 4-4M5 16v4h14v-4\"/>"
    private static let copyGlyph = "<rect x=\"8\" y=\"8\" width=\"12\" height=\"12\" rx=\"2\"/><path d=\"M16 8V6a2 2 0 0 0-2-2H6a2 2 0 0 0-2 2v8a2 2 0 0 0 2 2h2\"/>"
    private static let refreshGlyph = "<path d=\"M20 11a8 8 0 1 0-2 6m2-6V6m0 5h-5\"/>"

    private static let script = """
    const field=document.getElementById('shared-text'), feedback=document.getElementById('feedback');
    document.getElementById('copy').addEventListener('click', async () => {
      field.focus(); field.select(); field.setSelectionRange(0,field.value.length);
      let copied=false;
      try { copied=document.execCommand('copy'); } catch {}
      if (!copied && navigator.clipboard) {
        try { await navigator.clipboard.writeText(field.value); copied=true; } catch {}
      }
      feedback.textContent=copied?'已复制':'已选中文本，可使用系统的复制操作';
    });
    """
    static let scriptHash = Data(SHA256.hash(data: Data(script.utf8))).base64EncodedString()

    private static let css = """
    :root{color-scheme:light dark;--bg:#f5f6f8;--card:#fff;--ink:#182331;--muted:#536276;--line:#e1e5ec;--tint:#edf3ff;--blue:#2152ad;--hover:#f4f7fc;--mark:#182d4a}
    @media(prefers-color-scheme:dark){:root{--bg:#11161e;--card:#1b2430;--ink:#edf3ff;--muted:#afbdd0;--line:#334153;--tint:#233851;--blue:#b2ceff;--hover:#222e3d;--mark:#2b486e}}
    *{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:15px/1.5 -apple-system,BlinkMacSystemFont,system-ui,sans-serif}
    main{width:min(100% - 32px,660px);margin:clamp(22px,5vw,52px) auto}header{margin-bottom:24px;overflow-wrap:anywhere}
    .brand{display:inline-flex;align-items:center;gap:9px;font-size:13px;font-weight:700;text-decoration:none;color:var(--ink)}
    .brand-mark{display:grid;place-items:center;background:var(--mark);color:#f2f7ff;width:27px;height:27px;border-radius:8px;font-size:16px}
    h1{font-size:clamp(25px,5vw,34px);letter-spacing:-.025em;line-height:1.2;margin:14px 0 0}
    nav{display:flex;gap:8px;flex-wrap:wrap;margin-top:17px;color:var(--muted);font-size:13px}nav a{color:var(--blue);text-underline-offset:3px}nav+h1{margin-top:6px}
    section{background:var(--card);border:1px solid var(--line);border-radius:14px;overflow:hidden;margin:0 0 14px}
    .section-head{padding:10px 15px;min-height:47px;display:flex;align-items:center;justify-content:space-between;gap:10px;border-bottom:1px solid var(--line)}
    h2{font-size:14px;margin:0;font-weight:660}.count{color:var(--muted);font-size:12px;white-space:nowrap}
    ul{list-style:none;margin:0;padding:0}li+li{border-top:1px solid var(--line)}
    .row{display:flex;align-items:center;gap:11px;min-height:54px;padding:9px 15px;color:inherit;text-decoration:none}
    .icon{flex:0 0 32px;height:32px;border-radius:8px;background:var(--tint);color:var(--blue);display:grid;place-items:center}.icon.file{background:var(--hover);color:var(--muted)}
    svg{width:17px;height:17px}.row strong{flex:1;min-width:0;overflow-wrap:anywhere;font-size:14px;font-weight:550}.row small{color:var(--muted);font-size:12px;white-space:nowrap}
    .row-action{color:var(--muted);width:24px;display:grid;place-items:center}
    .tools{display:flex;gap:4px}.action,button{display:inline-grid;place-items:center;width:34px;height:33px;padding:0;border:0;border-radius:7px;background:transparent;color:var(--blue);cursor:pointer}
    :is(a,button,textarea):focus-visible{outline:2px solid var(--blue);outline-offset:-2px}.row:active,.action:active,button:active{background:var(--tint)}
    @media(hover:hover){.row:hover,.action:hover,button:hover{background:var(--hover)}}
    textarea{display:block;resize:vertical;min-height:116px;width:calc(100% - 30px);margin:14px 15px;border:1px solid var(--line);border-radius:8px;background:var(--hover);color:var(--ink);padding:10px;font:14px/1.6 ui-monospace,monospace}
    .feedback{display:block;margin:0 15px 12px;color:var(--muted);font-size:12px}.feedback:empty{display:none}
    .empty{display:grid;justify-items:center;gap:7px;padding:24px 14px 18px}.empty-mark{display:grid;place-items:center;width:39px;height:39px;border-radius:10px;background:var(--tint);color:var(--blue)}
    .empty-row{color:var(--muted);margin:0;padding:17px}.empty .action{margin-top:2px}
    @media(max-width:600px){.action,button{width:42px;height:40px}}
    @media(max-width:360px){main{width:calc(100% - 22px)}.row{gap:8px;padding-inline:11px}}
    """
}
