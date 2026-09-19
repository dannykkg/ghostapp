import Foundation

public struct HTMLReportRenderer {
  public init() {}

  public func render(_ inventory: Inventory, homeDirectory: String) -> String {
    let assessment = inventory.assessment
    let statistics = assessment.statistics
    let counts = assessment.counts
    let generated = Self.dateFormatter.string(from: inventory.generatedAt)
    let assessmentHTML =
      assessment.items.isEmpty
      ? "<p class=\"empty\">No assessment items were found.</p>"
      : assessment.items.map { assessmentItem($0, home: homeDirectory) }.joined()
    let packageHTML = PackageManager.allCases.compactMap { manager -> String? in
      let packages = inventory.packages.filter { $0.manager == manager }
      guard !packages.isEmpty else { return nil }
      return """
        <section class="manager-section">
          <h3>\(escape(manager.rawValue)) <span class="count">\(packages.count)</span></h3>
          <div class="package-list">
            \(packages.map { packageItem($0, home: homeDirectory) }.joined())
          </div>
        </section>
        """
    }.joined()
    let duplicateHTML =
      inventory.duplicateProducts.isEmpty
      ? "<p class=\"empty\">No duplicate commands detected.</p>"
      : inventory.duplicateProducts.map { duplicateItem($0, home: homeDirectory) }.joined()
    let warningHTML =
      inventory.warnings.isEmpty
      ? "<p class=\"empty\">No provider warnings.</p>"
      : "<ul>"
        + inventory.warnings.map {
          "<li><strong>\(escape($0.provider))</strong> — \(escape($0.message))</li>"
        }.joined() + "</ul>"
    let embeddedJSON = inventoryJSON(inventory, home: homeDirectory)

    return """
      <!doctype html>
      <html lang="en">
      <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'">
        <title>GhostApp report · \(escape(inventory.host))</title>
        <style>
          :root { color-scheme: light dark; --bg:#f4f6f8; --panel:#fff; --text:#18212b; --muted:#66717e; --line:#dfe4e9; --accent:#087ea4; --ok:#137333; --info:#1261a0; --review:#8a5a00; --warn:#b54708; --danger:#b42318; }
          @media (prefers-color-scheme:dark) { :root { --bg:#101418; --panel:#181e24; --text:#edf2f7; --muted:#9aa7b4; --line:#2d3741; --accent:#55c2e6; --ok:#62c47b; --info:#63b3ed; --review:#f6c453; --warn:#ff9b63; --danger:#ff7b72; } }
          * { box-sizing:border-box; }
          body { margin:0; background:var(--bg); color:var(--text); font:15px/1.55 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif; }
          main { width:min(1120px,calc(100% - 32px)); margin:32px auto 72px; }
          h1,h2,h3,p { margin-top:0; }
          h1 { margin-bottom:6px; font-size:30px; }
          h2 { margin:0 0 18px; font-size:21px; }
          h3 { margin:24px 0 10px; font-size:15px; text-transform:uppercase; letter-spacing:.07em; color:var(--muted); }
          .meta,.muted,.empty { color:var(--muted); }
          .panel { margin-top:18px; padding:22px; background:var(--panel); border:1px solid var(--line); border-radius:14px; box-shadow:0 4px 18px rgba(0,0,0,.04); }
          .hero { display:flex; gap:18px; justify-content:space-between; align-items:flex-start; }
          .status { display:inline-flex; padding:6px 11px; border-radius:999px; font-size:12px; font-weight:750; letter-spacing:.06em; background:color-mix(in srgb,var(--status) 15%,transparent); color:var(--status); }
          .status.healthy { --status:var(--ok); } .status.needs-review { --status:var(--review); } .status.warning { --status:var(--warn); } .status.danger { --status:var(--danger); }
          .cards { display:grid; grid-template-columns:repeat(4,minmax(0,1fr)); gap:12px; margin-top:18px; }
          .card { padding:15px; border:1px solid var(--line); border-radius:11px; }
          .card strong { display:block; font-size:25px; line-height:1.2; }
          .card span { color:var(--muted); font-size:12px; }
          .toolbar { display:flex; flex-wrap:wrap; gap:9px; margin-bottom:16px; }
          input,button { border:1px solid var(--line); border-radius:8px; padding:9px 11px; background:var(--panel); color:var(--text); font:inherit; }
          input { min-width:260px; flex:1; } button { cursor:pointer; } button:hover { border-color:var(--accent); }
          details { border:1px solid var(--line); border-radius:10px; margin:9px 0; overflow:hidden; background:color-mix(in srgb,var(--panel) 96%,var(--accent)); }
          summary { cursor:pointer; padding:13px 15px; font-weight:650; list-style-position:outside; }
          summary:hover { background:color-mix(in srgb,var(--accent) 7%,transparent); }
          .detail-body { padding:0 16px 16px 34px; color:var(--muted); }
          .detail-body p { margin:7px 0; }
          .level { display:inline-block; min-width:76px; font-size:11px; letter-spacing:.05em; }
          .level.info { color:var(--info); } .level.review { color:var(--review); } .level.warning,.level.orphaned { color:var(--warn); } .level.dangerous { color:var(--danger); }
          .badge { display:inline-block; margin-left:7px; padding:2px 7px; border-radius:999px; color:var(--muted); background:color-mix(in srgb,var(--muted) 12%,transparent); font-size:11px; font-weight:600; }
          .path,code { font-family:ui-monospace,SFMono-Regular,Menlo,monospace; font-size:12px; overflow-wrap:anywhere; color:var(--text); }
          table { width:100%; border-collapse:collapse; margin-top:10px; font-size:13px; }
          th,td { padding:8px; border-top:1px solid var(--line); text-align:left; vertical-align:top; }
          th { color:var(--muted); font-weight:600; }
          ul { margin:8px 0; padding-left:20px; }
          .count { font-size:12px; color:var(--muted); }
          .hidden { display:none !important; }
          footer { margin-top:22px; color:var(--muted); font-size:12px; text-align:center; }
          @media (max-width:760px) { main { width:min(100% - 18px,1120px); margin-top:14px; } .panel { padding:15px; } .cards { grid-template-columns:repeat(2,minmax(0,1fr)); } .hero { display:block; } .status { margin-top:8px; } .detail-body { padding-left:16px; } }
        </style>
      </head>
      <body>
        <main>
          <section class="panel">
            <div class="hero">
              <div><h1>GhostApp report</h1><p class="meta">\(escape(inventory.host)) · \(escape(generated)) · schema \(escape(inventory.schemaVersion))</p></div>
              <span class="status \(escape(assessment.status.rawValue))">\(escape(statusTitle(assessment.status)))</span>
            </div>
            <div class="cards">
              <div class="card"><strong>\(statistics.packages)</strong><span>packages recognized</span></div>
              <div class="card"><strong>\(statistics.directInstalls)</strong><span>direct installs</span></div>
              <div class="card"><strong>\(counts.warning + counts.orphaned + counts.dangerous)</strong><span>confirmed findings</span></div>
              <div class="card"><strong>\(counts.review)</strong><span>items need review</span></div>
            </div>
          </section>

          <section class="panel" id="assessment">
            <h2>Assessment</h2>
            <p class="muted">INFO \(counts.info) · REVIEW \(counts.review) · WARNING \(counts.warning) · ORPHANED \(counts.orphaned) · DANGEROUS \(counts.dangerous)</p>
            \(assessmentHTML)
          </section>

          <section class="panel" id="packages">
            <h2>Software inventory</h2>
            <div class="toolbar">
              <input id="search" type="search" placeholder="Search name, manager, command, or path…" aria-label="Search report">
              <button type="button" data-action="expand">Expand visible</button>
              <button type="button" data-action="collapse">Collapse all</button>
            </div>
            \(packageHTML)
            <p id="no-results" class="empty hidden">No packages match this search.</p>
          </section>

          <section class="panel" id="duplicates"><h2>Duplicate commands</h2>\(duplicateHTML)</section>
          <section class="panel" id="warnings"><h2>Provider warnings</h2>\(warningHTML)</section>
          <footer>Generated locally by GhostApp. Full scan data is embedded in this file; file contents, credentials, and sessions were not read.</footer>
        </main>
        <script type="application/json" id="ghostapp-data">\(embeddedJSON)</script>
        <script>
          const search = document.getElementById('search');
          const packages = [...document.querySelectorAll('details.searchable')];
          const empty = document.getElementById('no-results');
          search.addEventListener('input', () => {
            const query = search.value.trim().toLowerCase();
            let visible = 0;
            for (const item of packages) {
              const match = !query || item.dataset.search.includes(query);
              item.classList.toggle('hidden', !match);
              if (match) visible++;
            }
            empty.classList.toggle('hidden', visible !== 0);
          });
          document.querySelector('[data-action="expand"]').addEventListener('click', () => {
            packages.filter(item => !item.classList.contains('hidden')).forEach(item => item.open = true);
          });
          document.querySelector('[data-action="collapse"]').addEventListener('click', () => {
            document.querySelectorAll('details').forEach(item => item.open = false);
          });
        </script>
      </body>
      </html>
      """
  }

  private func assessmentItem(_ item: AssessmentItem, home: String) -> String {
    let path =
      item.path.map {
        "<p><strong>Path</strong><br><code>\(escape(redact($0, home: home)))</code></p>"
      } ?? ""
    return """
      <details class="assessment-item">
        <summary><span class="level \(escape(item.level.rawValue))">\(escape(item.level.rawValue.uppercased()))</span> \(escape(item.title))</summary>
        <div class="detail-body">
          <p>\(escape(item.summary))</p>
          \(path)
          <p><strong>Evidence</strong><br>\(escape(redact(item.detail, home: home)))</p>
          <p><strong>Confidence</strong> <span class="badge">\(escape(item.confidence.rawValue))</span></p>
        </div>
      </details>
      """
  }

  private func packageItem(_ package: PackageRecord, home: String) -> String {
    let version = package.version.map { " <span class=\"badge\">\(escape($0))</span>" } ?? ""
    let ownership = package.directInstall.map { $0 ? "direct" : "dependency" } ?? "unclassified"
    let totalSize = package.artifacts.compactMap(\.sizeBytes).reduce(0, +)
    let command =
      package.uninstallCommand.map {
        "<p><strong>Uninstall command</strong><br><code>\(escape(redact(shellCommand($0), home: home)))</code></p>"
      } ?? ""
    let binaries =
      package.binaries.isEmpty
      ? "<p class=\"empty\">No executable path reported.</p>"
      : "<ul>"
        + package.binaries.map { "<li><code>\(escape(redact($0, home: home)))</code></li>" }
        .joined() + "</ul>"
    let artifacts =
      package.artifacts.isEmpty
      ? "<p class=\"empty\">No artifacts reported.</p>"
      : """
      <table>
        <thead><tr><th>Kind</th><th>Path</th><th>Confidence</th><th>Size</th><th>Flags</th></tr></thead>
        <tbody>\(package.artifacts.map { artifactRow($0, home: home) }.joined())</tbody>
      </table>
      """
    let searchValues =
      [package.id, package.name, package.displayName, package.manager.rawValue]
      + package.binaries + package.artifacts.map(\.path)
    let searchText = Array(Set(searchValues.map { redact($0, home: home).lowercased() }))
      .sorted().joined(separator: " ")
    return """
      <details class="package searchable" data-search="\(escape(searchText))">
        <summary>\(escape(package.displayName))\(version)<span class="badge">\(escape(package.manager.rawValue))</span><span class="badge">\(ownership)</span></summary>
        <div class="detail-body">
          <p><strong>Package ID</strong> <code>\(escape(package.id))</code></p>
          <p><strong>Estimated size</strong> \(escape(formatBytes(totalSize))) · <strong>Binaries</strong> \(package.binaries.count) · <strong>Artifacts</strong> \(package.artifacts.count)</p>
          \(command)
          <p><strong>Executables</strong></p>\(binaries)
          <p><strong>Artifacts</strong></p>\(artifacts)
        </div>
      </details>
      """
  }

  private func artifactRow(_ artifact: Artifact, home: String) -> String {
    let flags = [
      artifact.sensitive ? "sensitive" : nil, artifact.removable ? "removable" : "review-only",
    ]
    .compactMap { $0 }.joined(separator: ", ")
    let evidence = artifact.evidence.map { "\($0.source): \($0.detail)" }.joined(separator: "; ")
    return """
      <tr>
        <td>\(escape(artifact.kind.rawValue))</td>
        <td><code>\(escape(redact(artifact.path, home: home)))</code><br><span class="muted">\(escape(evidence))</span></td>
        <td>\(escape(artifact.confidence.rawValue))</td>
        <td>\(escape(formatBytes(artifact.sizeBytes ?? 0)))</td>
        <td>\(escape(flags))</td>
      </tr>
      """
  }

  private func duplicateItem(_ product: SoftwareProduct, home: String) -> String {
    let installations = product.installations.map {
      "<li>\($0.activeInPath ? "<strong>ACTIVE</strong> " : "")<code>\(escape(redact($0.binary, home: home)))</code> — \(escape($0.manager.rawValue))</li>"
    }.joined()
    return """
      <details>
        <summary>\(escape(product.identity)) <span class="badge">\(product.installations.count) installations</span></summary>
        <div class="detail-body"><ul>\(installations)</ul></div>
      </details>
      """
  }

  private func redact(_ value: String, home: String) -> String {
    value.replacingOccurrences(of: home, with: "~")
  }

  private func escape(_ value: String) -> String {
    value
      .replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
      .replacingOccurrences(of: "\"", with: "&quot;")
      .replacingOccurrences(of: "'", with: "&#39;")
  }

  private func shellCommand(_ command: [String]) -> String {
    command.map { value in
      if value.allSatisfy({ $0.isLetter || $0.isNumber || "-_/.:@".contains($0) }) {
        return value
      }
      return "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }.joined(separator: " ")
  }

  private func formatBytes(_ value: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
  }

  private func statusTitle(_ status: InventoryStatus) -> String {
    switch status {
    case .healthy: "HEALTHY"
    case .needsReview: "NEEDS REVIEW"
    case .warning: "WARNING"
    case .danger: "DANGER"
    }
  }

  private func inventoryJSON(_ inventory: Inventory, home: String) -> String {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(inventory),
      let json = String(data: data, encoding: .utf8)
    else { return "{}" }
    return
      json
      .replacingOccurrences(of: home, with: "~")
      .replacingOccurrences(of: "&", with: "\\u0026")
      .replacingOccurrences(of: "<", with: "\\u003c")
      .replacingOccurrences(of: ">", with: "\\u003e")
  }

  private static let dateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
    return formatter
  }()
}
