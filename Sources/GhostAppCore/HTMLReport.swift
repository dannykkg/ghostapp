import Foundation

public struct HTMLReportRenderer {
  public init() {}

  public func render(_ inventory: Inventory, homeDirectory: String) -> String {
    let assessment = inventory.assessment
    let statistics = assessment.statistics
    let counts = assessment.counts
    let generated = Self.dateFormatter.string(from: inventory.generatedAt)
    let reportID = "GA-\(Self.idFormatter.string(from: inventory.generatedAt))"
    let confirmed = counts.warning + counts.orphaned + counts.dangerous
    let attentionItems = assessment.items.filter { $0.level != .info && $0.level != .normal }
    let assessmentHTML =
      assessment.items.isEmpty
      ? "<p class=\"empty\">No assessment items were found.</p>"
      : assessment.items.map { assessmentItem($0, home: homeDirectory) }.joined()
    let attentionHTML =
      attentionItems.isEmpty
      ? "<div class=\"queue-empty\"><strong>No action queue</strong><span>No confirmed or review-level findings.</span></div>"
      : attentionItems.prefix(5).map { attentionItem($0) }.joined()
        + (attentionItems.count > 5
          ? "<a class=\"queue-more\" href=\"#findings\">View \(attentionItems.count - 5) more finding(s)</a>"
          : "")
    let evidenceHTML = findingEvidence(
      attentionItems.first ?? assessment.items.first,
      home: homeDirectory
    )
    let providerHTML = providerDistribution(inventory.packages)
    let packageHTML = PackageManager.allCases.compactMap { manager -> String? in
      let packages = inventory.packages.filter { $0.manager == manager }
      guard !packages.isEmpty else { return nil }
      return """
        <section class="manager-section" data-manager="\(escape(manager.rawValue))">
          <div class="manager-heading">
            <div><span class="manager-name">\(escape(managerLabel(manager)))</span><span class="manager-id">\(escape(manager.rawValue))</span></div>
            <span class="manager-count">\(packages.count) package(s)</span>
          </div>
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
      : "<ul class=\"warning-list\">"
        + inventory.warnings.map {
          "<li><strong>\(escape($0.provider))</strong><span>\(escape(redact($0.message, home: homeDirectory)))</span></li>"
        }.joined() + "</ul>"
    let embeddedJSON = inventoryJSON(inventory, home: homeDirectory)

    return """
      <!doctype html>
      <html lang="en">
      <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'">
        <title>GhostApp engineering scan report · \(escape(inventory.host))</title>
        <style>\(Self.styles)</style>
      </head>
      <body>
        <div class="report-console">
          <header class="topbar">
            <a class="brand" href="#overview" aria-label="GhostApp report overview">
              <span class="brand-mark" aria-hidden="true">⌁</span>
              <strong>GhostApp</strong>
              <span class="scan-complete"><span aria-hidden="true">●</span> Scan complete</span>
            </a>
            <nav aria-label="Report sections">
              <a class="active" href="#overview">Overview</a>
              <a href="#findings">Findings</a>
              <a href="#inventory">Inventory</a>
              <a href="#evidence">Evidence</a>
            </nav>
            <div class="host-meta"><strong>\(escape(inventory.host))</strong><span class="mono">\(escape(reportID))</span></div>
          </header>

          <main>
            <section class="report-heading" id="overview">
              <div>
                <p class="eyebrow">Deterministic local assessment</p>
                <h1>Engineering scan console</h1>
                <p class="subtitle">Software ownership, associated data, background services, and PATH integrity.</p>
              </div>
              <div class="scan-meta"><span class="health \(escape(assessment.status.rawValue))">\(escape(statusTitle(assessment.status)))</span><span>10 stages · \(escape(generated))</span><span>schema \(escape(inventory.schemaVersion))</span></div>
            </section>

            <div class="dashboard-layout">
              <div class="dashboard-main">
                <section class="metric-grid" aria-label="Scan summary">
                  <article class="module metric"><span class="module-label">Packages</span><strong>\(statistics.packages)</strong><p>\(statistics.directInstalls) direct · \(statistics.dependencies) dependencies · \(statistics.unclassified) unclassified</p></article>
                  <article class="module metric"><span class="module-label">Confirmed findings</span><strong>\(confirmed)</strong><p>\(counts.warning) warning · \(counts.orphaned) orphaned · \(counts.dangerous) dangerous</p></article>
                  <article class="module metric"><span class="module-label">Manual review</span><strong>\(counts.review)</strong><p>Ownership or intent requires confirmation</p></article>
                </section>

                <div class="overview-grid">
                  <section class="module">
                    <div class="module-heading"><h2>Provider distribution</h2><span>\(statistics.packages) records</span></div>
                    <div class="provider-bars" id="provider-distribution">\(providerHTML)</div>
                  </section>

                  <section class="module pipeline-module">
                    <div class="module-heading"><h2>Scan pipeline</h2><span>All stages completed</span></div>
                    <div class="pipeline" role="img" aria-label="10 of 10 scan stages completed">
                      <span></span><span></span><span></span><span></span><span></span><span></span><span></span><span></span><span></span><span></span>
                    </div>
                    <p class="pipeline-labels">Packages → toolchains → user bins → data association → services → PATH → assessment</p>
                  </section>

                  <section class="module evidence-preview">
                    <div class="module-heading"><h2>Finding evidence</h2><a href="#findings">View all findings</a></div>
                    \(evidenceHTML)
                  </section>
                </div>
              </div>

              <aside class="dashboard-side">
                <section class="module attention-module">
                  <div class="module-heading"><h2>Attention queue</h2><span>\(attentionItems.count) item(s)</span></div>
                  \(attentionHTML)
                </section>

                <section class="module guarantees">
                  <div class="module-heading"><h2>Report guarantees</h2><span>Local only</span></div>
                  <ul>
                    <li><span>✓</span> Complete Inventory JSON embedded</li>
                    <li><span>✓</span> Home directory displayed as <code>~</code></li>
                    <li><span>✓</span> No credential or session contents read</li>
                    <li><span>✓</span> No network or persistent browser storage</li>
                  </ul>
                </section>
              </aside>
            </div>

            <section class="report-section" id="findings">
              <div class="section-heading">
                <div><p class="section-index">01 / Assessment</p><h2>Findings and evidence</h2><p>Prioritized by actionability. Expand an item for its full path, evidence, and confidence.</p></div>
                <div class="severity-summary"><span>INFO \(counts.info)</span><span>REVIEW \(counts.review)</span><span>WARNING \(counts.warning)</span><span>ORPHANED \(counts.orphaned)</span><span>DANGEROUS \(counts.dangerous)</span></div>
              </div>
              <div class="assessment-list">\(assessmentHTML)</div>
            </section>

            <section class="report-section" id="inventory">
              <div class="section-heading">
                <div><p class="section-index">02 / Inventory</p><h2>Software inventory</h2><p>Search by software name, manager, command, or associated path.</p></div>
                <span class="section-total">\(statistics.packages) recognized packages</span>
              </div>
              <div class="toolbar">
                <label class="search-field"><span aria-hidden="true">⌕</span><input id="search" type="search" placeholder="Search software, manager, command, or path" aria-label="Search report"></label>
                <span id="results-count" class="results-count">\(statistics.packages) result(s)</span>
                <button type="button" data-action="expand">Expand visible</button>
                <button type="button" data-action="collapse">Collapse all</button>
              </div>
              <div id="package-groups">\(packageHTML)</div>
              <p id="no-results" class="empty hidden">No packages match this search.</p>
            </section>

            <section class="report-section" id="evidence">
              <div class="section-heading">
                <div><p class="section-index">03 / Supporting evidence</p><h2>Command and provider diagnostics</h2><p>Duplicate command resolution and provider-level warnings are kept separate from package records.</p></div>
              </div>
              <div class="diagnostic-grid">
                <article class="module"><div class="module-heading"><h2>Duplicate commands</h2><span>\(inventory.duplicateProducts.count)</span></div>\(duplicateHTML)</article>
                <article class="module"><div class="module-heading"><h2>Provider warnings</h2><span>\(inventory.warnings.count)</span></div>\(warningHTML)</article>
              </div>
            </section>

            <footer>
              <span>Generated locally by GhostApp · \(escape(reportID))</span>
              <span>Full scan data is embedded below; file contents, credentials, and sessions were not read.</span>
            </footer>
          </main>
        </div>
        <script type="application/json" id="ghostapp-data">\(embeddedJSON)</script>
        <script>
          const search = document.getElementById('search');
          const packages = [...document.querySelectorAll('details.searchable')];
          const groups = [...document.querySelectorAll('.manager-section')];
          const empty = document.getElementById('no-results');
          const results = document.getElementById('results-count');
          search.addEventListener('input', () => {
            const query = search.value.trim().toLowerCase();
            let visible = 0;
            for (const item of packages) {
              const match = !query || item.dataset.search.includes(query);
              item.classList.toggle('hidden', !match);
              if (match) visible++;
            }
            for (const group of groups) {
              group.classList.toggle('hidden', !group.querySelector('details.searchable:not(.hidden)'));
            }
            results.textContent = `${visible} result(s)`;
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

  private func providerDistribution(_ packages: [PackageRecord]) -> String {
    let counts = PackageManager.allCases.compactMap { manager -> (PackageManager, Int)? in
      let count = packages.lazy.filter { $0.manager == manager }.count
      return count == 0 ? nil : (manager, count)
    }
    .sorted { left, right in
      left.1 == right.1 ? left.0.rawValue < right.0.rawValue : left.1 > right.1
    }
    let total = max(packages.count, 1)
    return counts.map { manager, count in
      let percent = max(2, Int((Double(count) / Double(total) * 100).rounded()))
      return """
        <div class="provider-row">
          <span>\(escape(managerLabel(manager)))</span>
          <div class="bar-track"><span style="width:\(percent)%"></span></div>
          <strong>\(count)</strong>
        </div>
        """
    }.joined()
  }

  private func attentionItem(_ item: AssessmentItem) -> String {
    """
    <a class="queue-item \(escape(item.level.rawValue))" href="#findings">
      <span class="level-chip \(escape(item.level.rawValue))">\(escape(levelTitle(item.level)))</span>
      <strong>\(escape(item.title))</strong>
      <small>\(escape(item.summary))</small>
    </a>
    """
  }

  private func findingEvidence(_ item: AssessmentItem?, home: String) -> String {
    guard let item else {
      return "<p class=\"empty\">No finding evidence was recorded.</p>"
    }
    let path = item.path.map { redact($0, home: home) } ?? "—"
    return """
      <dl class="evidence-grid">
        <dt>Level</dt><dd><span class="level-chip \(escape(item.level.rawValue))">\(escape(levelTitle(item.level)))</span></dd>
        <dt>Finding</dt><dd>\(escape(item.title))</dd>
        <dt>Path</dt><dd><code>\(escape(path))</code></dd>
        <dt>Evidence</dt><dd>\(escape(redact(item.detail, home: home)))</dd>
        <dt>Confidence</dt><dd>\(escape(item.confidence.rawValue))</dd>
      </dl>
      """
  }

  private func assessmentItem(_ item: AssessmentItem, home: String) -> String {
    let path =
      item.path.map {
        "<div class=\"fact\"><span>Path</span><code>\(escape(redact($0, home: home)))</code></div>"
      } ?? ""
    return """
      <details class="assessment-item \(escape(item.level.rawValue))">
        <summary><span class="level-chip \(escape(item.level.rawValue))">\(escape(levelTitle(item.level)))</span><span class="summary-title">\(escape(item.title))</span><span class="summary-text">\(escape(item.summary))</span><span class="confidence">\(escape(item.confidence.rawValue))</span></summary>
        <div class="detail-body">
          \(path)
          <div class="fact"><span>Evidence</span><p>\(escape(redact(item.detail, home: home)))</p></div>
          <div class="fact"><span>Confidence</span><p>\(escape(item.confidence.rawValue))</p></div>
        </div>
      </details>
      """
  }

  private func packageItem(_ package: PackageRecord, home: String) -> String {
    let version = package.version.map { "<span class=\"tag version\">\(escape($0))</span>" } ?? ""
    let ownership = package.directInstall.map { $0 ? "direct" : "dependency" } ?? "unclassified"
    let totalSize = package.artifacts.compactMap(\.sizeBytes).reduce(0, +)
    let command =
      package.uninstallCommand.map {
        "<div class=\"fact\"><span>Uninstall command</span><code>\(escape(redact(shellCommand($0), home: home)))</code></div>"
      } ?? ""
    let binaries =
      package.binaries.isEmpty
      ? "<p class=\"empty\">No executable path reported.</p>"
      : "<ul class=\"path-list\">"
        + package.binaries.map { "<li><code>\(escape(redact($0, home: home)))</code></li>" }
        .joined() + "</ul>"
    let artifacts =
      package.artifacts.isEmpty
      ? "<p class=\"empty\">No artifacts reported.</p>"
      : """
      <div class="table-wrap"><table>
        <thead><tr><th>Kind</th><th>Path and evidence</th><th>Confidence</th><th>Size</th><th>Policy</th></tr></thead>
        <tbody>\(package.artifacts.map { artifactRow($0, home: home) }.joined())</tbody>
      </table></div>
      """
    let searchValues =
      [package.id, package.name, package.displayName, package.manager.rawValue]
      + package.binaries + package.artifacts.map(\.path)
    let searchText = Array(Set(searchValues.map { redact($0, home: home).lowercased() }))
      .sorted().joined(separator: " ")
    return """
      <details class="package searchable" data-search="\(escape(searchText))">
        <summary><span class="package-name">\(escape(package.displayName))</span><span class="package-tags">\(version)<span class="tag">\(escape(ownership))</span></span><span class="package-counts">\(package.binaries.count) bin · \(package.artifacts.count) artifact(s)</span></summary>
        <div class="detail-body package-body">
          <div class="package-facts">
            <div class="fact"><span>Package ID</span><code>\(escape(package.id))</code></div>
            <div class="fact"><span>Estimated associated size</span><p>\(escape(formatBytes(totalSize)))</p></div>
            \(command)
          </div>
          <h4>Executables</h4>\(binaries)
          <h4>Artifacts</h4>\(artifacts)
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
        <td><code>\(escape(redact(artifact.path, home: home)))</code><small>\(escape(redact(evidence, home: home)))</small></td>
        <td>\(escape(artifact.confidence.rawValue))</td>
        <td>\(escape(formatBytes(artifact.sizeBytes ?? 0)))</td>
        <td>\(escape(flags))</td>
      </tr>
      """
  }

  private func duplicateItem(_ product: SoftwareProduct, home: String) -> String {
    let installations = product.installations.map {
      "<li>\($0.activeInPath ? "<strong>ACTIVE</strong> " : "")<code>\(escape(redact($0.binary, home: home)))</code><span>\(escape(managerLabel($0.manager)))</span></li>"
    }.joined()
    return """
      <details class="diagnostic-item">
        <summary><span>\(escape(product.identity))</span><span class="tag">\(product.installations.count) installations</span></summary>
        <div class="detail-body"><ul class="installation-list">\(installations)</ul></div>
      </details>
      """
  }

  private func managerLabel(_ manager: PackageManager) -> String {
    switch manager {
    case .homebrewFormula: "Homebrew Formula"
    case .homebrewCask: "Homebrew Cask"
    case .cargo: "Cargo"
    case .npm: "npm Global"
    case .pipx: "pipx"
    case .uv: "uv Tools"
    case .rustup: "Rustup Toolchain"
    case .manual: "Manual Discovery"
    }
  }

  private func levelTitle(_ level: AssessmentLevel) -> String {
    switch level {
    case .normal: "Normal"
    case .info: "Info"
    case .review: "Review"
    case .warning: "Warning"
    case .orphaned: "Orphaned"
    case .dangerous: "Dangerous"
    }
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
    case .healthy: "Healthy"
    case .needsReview: "Needs review"
    case .warning: "Warning"
    case .danger: "Danger"
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

  private static let idFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return formatter
  }()

  private static let styles = """
    :root { color-scheme:light; --ink:#152235; --muted:#68758a; --line:#dde5ed; --page:#f6f9fb; --panel:#fff; --teal:#0c816d; --teal-soft:#e9f7f3; --blue:#1769df; --blue-soft:#edf4ff; --amber:#a96405; --amber-soft:#fff6e5; --red:#bd3735; --red-soft:#fff0ef; --purple:#6c4ab6; --purple-soft:#f2eeff; }
    * { box-sizing:border-box; }
    html { scroll-behavior:smooth; }
    body { margin:0; background:var(--page); color:var(--ink); font:14px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif; }
    a { color:inherit; }
    button,input { font:inherit; }
    code,.mono { font-family:ui-monospace,SFMono-Regular,Menlo,monospace; overflow-wrap:anywhere; }
    .report-console { min-height:100vh; }
    .topbar { min-height:64px; display:grid; grid-template-columns:1fr auto 1fr; align-items:center; gap:20px; padding:0 max(24px,calc((100vw - 1240px)/2)); background:#fff; border-bottom:1px solid var(--line); }
    .brand { display:flex; align-items:center; gap:9px; text-decoration:none; font-size:15px; }
    .brand-mark { display:grid; place-items:center; width:29px; height:29px; border-radius:8px; background:var(--teal); color:#fff; font-size:20px; font-weight:800; }
    .scan-complete { display:inline-flex; align-items:center; gap:5px; margin-left:3px; padding:4px 8px; border-radius:999px; background:var(--teal-soft); color:var(--teal); font-size:10px; font-weight:750; letter-spacing:.06em; text-transform:uppercase; }
    .topbar nav { display:flex; gap:4px; padding:4px; border-radius:9px; background:#f2f5f8; }
    .topbar nav a { padding:7px 11px; border-radius:7px; color:#687488; font-size:11px; text-decoration:none; }
    .topbar nav a:hover,.topbar nav a.active { background:#fff; color:var(--ink); box-shadow:0 1px 4px rgba(29,45,68,.09); }
    .host-meta { justify-self:end; text-align:right; font-size:10px; color:var(--muted); }
    .host-meta strong,.host-meta span { display:block; }
    main { width:min(1240px,calc(100% - 36px)); margin:0 auto; padding:26px 0 54px; }
    .report-heading { display:flex; justify-content:space-between; align-items:flex-end; gap:24px; margin-bottom:18px; }
    .eyebrow,.section-index { margin:0 0 5px; color:var(--teal); font-size:10px; font-weight:750; letter-spacing:.1em; text-transform:uppercase; }
    h1 { margin:0; font-size:24px; line-height:1.2; letter-spacing:-.025em; }
    .subtitle { margin:6px 0 0; color:var(--muted); font-size:12px; }
    .scan-meta { display:flex; flex-wrap:wrap; justify-content:flex-end; gap:7px; align-items:center; color:var(--muted); font-size:10px; }
    .health,.level-chip,.tag { display:inline-flex; align-items:center; border-radius:999px; white-space:nowrap; }
    .health { padding:5px 9px; font-size:10px; font-weight:750; letter-spacing:.05em; text-transform:uppercase; }
    .health.healthy { background:var(--teal-soft); color:var(--teal); }
    .health.needs-review { background:var(--purple-soft); color:var(--purple); }
    .health.warning { background:var(--amber-soft); color:var(--amber); }
    .health.danger { background:var(--red-soft); color:var(--red); }
    .dashboard-layout { display:grid; grid-template-columns:minmax(0,1fr) 294px; gap:13px; }
    .dashboard-main,.dashboard-side { min-width:0; }
    .dashboard-side { display:grid; gap:13px; align-content:start; }
    .module { background:var(--panel); border:1px solid var(--line); border-radius:9px; padding:15px; }
    .metric-grid { display:grid; grid-template-columns:repeat(3,minmax(0,1fr)); gap:11px; }
    .metric { min-height:111px; }
    .module-label { color:#748197; font-size:10px; font-weight:700; letter-spacing:.07em; text-transform:uppercase; }
    .metric>strong { display:block; margin:5px 0 2px; font-size:25px; line-height:1.15; }
    .metric p { margin:0; color:#7b8798; font-size:10px; }
    .overview-grid { display:grid; grid-template-columns:1fr 1fr; gap:11px; margin-top:11px; }
    .evidence-preview { grid-column:1/-1; }
    .module-heading { display:flex; justify-content:space-between; align-items:center; gap:12px; margin-bottom:12px; }
    .module-heading h2 { margin:0; font-size:12px; }
    .module-heading>span,.module-heading>a { color:#7d899b; font-size:9px; text-decoration:none; }
    .module-heading>a:hover { color:var(--blue); }
    .provider-bars { display:grid; gap:10px; }
    .provider-row { display:grid; grid-template-columns:118px 1fr 28px; gap:9px; align-items:center; color:#5f6c80; font-size:10px; }
    .provider-row strong { text-align:right; color:#39465a; }
    .bar-track { height:7px; overflow:hidden; border-radius:999px; background:#edf1f5; }
    .bar-track span { display:block; height:100%; border-radius:inherit; background:var(--blue); }
    .provider-row:nth-child(n+2) .bar-track span { background:#8ab2ec; }
    .pipeline { display:grid; grid-template-columns:repeat(10,1fr); gap:4px; margin:20px 0 12px; }
    .pipeline span { height:8px; border-radius:2px; background:var(--teal); }
    .pipeline-labels { margin:0; color:#7a8698; font-size:10px; line-height:1.6; }
    .evidence-grid { display:grid; grid-template-columns:86px 1fr; margin:0; border-radius:7px; background:#f4f7f9; padding:11px 12px; font:10px/1.6 ui-monospace,SFMono-Regular,Menlo,monospace; }
    .evidence-grid dt { color:#69778b; text-transform:uppercase; }
    .evidence-grid dd { margin:0; color:#344257; min-width:0; overflow-wrap:anywhere; }
    .level-chip { padding:3px 7px; font-size:9px; font-weight:750; letter-spacing:.05em; text-transform:uppercase; }
    .level-chip.normal,.level-chip.info { background:var(--blue-soft); color:var(--blue); }
    .level-chip.review { background:var(--purple-soft); color:var(--purple); }
    .level-chip.warning,.level-chip.orphaned { background:var(--amber-soft); color:var(--amber); }
    .level-chip.dangerous { background:var(--red-soft); color:var(--red); }
    .queue-item { display:block; margin:0 0 9px; padding:11px 11px 11px 13px; border-left:3px solid var(--amber); background:#fffbf2; text-decoration:none; }
    .queue-item.review { border-left-color:var(--purple); background:#faf8ff; }
    .queue-item.dangerous { border-left-color:var(--red); background:var(--red-soft); }
    .queue-item strong,.queue-item small { display:block; }
    .queue-item strong { margin:7px 0 4px; font-size:11px; }
    .queue-item small { color:#748095; font-size:9px; line-height:1.55; }
    .queue-item:hover { filter:brightness(.985); }
    .queue-more { display:block; margin-top:4px; color:var(--blue); font-size:10px; text-decoration:none; }
    .queue-empty strong,.queue-empty span { display:block; }
    .queue-empty strong { font-size:11px; }
    .queue-empty span { margin-top:4px; color:var(--muted); font-size:10px; }
    .guarantees ul { margin:0; padding:0; list-style:none; }
    .guarantees li { display:flex; gap:8px; align-items:flex-start; padding:9px 0; border-top:1px solid #edf1f4; color:#5e6a7e; font-size:9px; }
    .guarantees li:first-child { border-top:0; }
    .guarantees li>span { display:grid; place-items:center; flex:0 0 17px; height:17px; border-radius:50%; background:var(--teal-soft); color:var(--teal); font-weight:800; }
    .report-section { margin-top:18px; padding:22px; border:1px solid var(--line); border-radius:9px; background:#fff; scroll-margin-top:12px; }
    .section-heading { display:flex; justify-content:space-between; align-items:flex-end; gap:24px; margin-bottom:17px; }
    .section-heading h2 { margin:0; font-size:19px; letter-spacing:-.015em; }
    .section-heading p:not(.section-index) { margin:5px 0 0; color:var(--muted); font-size:11px; }
    .severity-summary { display:flex; flex-wrap:wrap; justify-content:flex-end; gap:6px; }
    .severity-summary span,.section-total,.results-count { color:#6f7c8f; font-size:9px; white-space:nowrap; }
    details { border-top:1px solid #e6ebf0; }
    details:last-child { border-bottom:1px solid #e6ebf0; }
    details summary { list-style:none; cursor:pointer; }
    details summary::-webkit-details-marker { display:none; }
    details summary::after { content:"+"; color:#8490a1; font-size:16px; line-height:1; }
    details[open] summary::after { content:"−"; }
    .assessment-item summary { display:grid; grid-template-columns:82px minmax(160px,.65fr) minmax(220px,1fr) 70px 16px; gap:10px; align-items:center; padding:12px 5px; }
    .summary-title { font-size:11px; font-weight:650; }
    .summary-text { color:#6e7a8d; font-size:10px; }
    .confidence { color:#758195; font-size:9px; text-align:right; text-transform:uppercase; }
    .detail-body { padding:5px 20px 16px 97px; color:#5d697c; }
    .fact { margin:7px 0; min-width:0; }
    .fact>span { display:block; margin-bottom:3px; color:#8490a2; font-size:9px; letter-spacing:.05em; text-transform:uppercase; }
    .fact p,.fact code { margin:0; font-size:10px; }
    .toolbar { display:flex; align-items:center; gap:8px; padding:9px; margin-bottom:16px; border:1px solid var(--line); border-radius:8px; background:#f8fafb; }
    .search-field { display:flex; align-items:center; gap:7px; min-width:240px; flex:1; color:#788598; }
    .search-field input { width:100%; border:0; outline:0; background:transparent; color:var(--ink); font-size:11px; }
    .toolbar button { padding:7px 9px; border:1px solid #d8e0e8; border-radius:6px; background:#fff; color:#526075; font-size:10px; cursor:pointer; }
    .toolbar button:hover { border-color:#9eb8db; color:var(--blue); }
    .manager-section { margin-top:20px; }
    .manager-section:first-child { margin-top:0; }
    .manager-heading { display:flex; justify-content:space-between; align-items:end; gap:16px; padding-bottom:8px; }
    .manager-name { display:block; font-size:12px; font-weight:700; }
    .manager-id,.manager-count { color:#8792a3; font-size:9px; }
    .manager-id { margin-top:2px; font-family:ui-monospace,SFMono-Regular,Menlo,monospace; }
    .package summary { display:grid; grid-template-columns:minmax(200px,1fr) minmax(160px,.7fr) 140px 16px; gap:10px; align-items:center; padding:11px 5px; }
    .package-name { font-size:11px; font-weight:650; overflow-wrap:anywhere; }
    .package-tags { display:flex; flex-wrap:wrap; gap:5px; }
    .tag { padding:3px 7px; background:#edf2f6; color:#617086; font-size:9px; }
    .tag.version { background:var(--blue-soft); color:var(--blue); }
    .package-counts { color:#778397; font-size:9px; text-align:right; }
    .package-body { padding-left:22px; }
    .package-facts { display:grid; grid-template-columns:repeat(3,minmax(0,1fr)); gap:12px; }
    h4 { margin:17px 0 7px; font-size:10px; text-transform:uppercase; letter-spacing:.06em; }
    .path-list,.installation-list { margin:0; padding-left:18px; }
    .path-list li,.installation-list li { margin:5px 0; font-size:10px; }
    .installation-list span { margin-left:8px; color:var(--muted); }
    .table-wrap { overflow-x:auto; }
    table { width:100%; border-collapse:collapse; font-size:10px; }
    th,td { padding:8px; border-top:1px solid #e7ecf1; text-align:left; vertical-align:top; }
    th { color:#7f8b9d; font-weight:650; white-space:nowrap; }
    td { color:#536176; }
    td small { display:block; margin-top:3px; color:#8a95a5; }
    .diagnostic-grid { display:grid; grid-template-columns:1fr 1fr; gap:12px; }
    .diagnostic-item summary { display:flex; justify-content:space-between; align-items:center; gap:10px; padding:10px 3px; font-size:10px; }
    .diagnostic-item summary::after { margin-left:auto; }
    .diagnostic-item .detail-body { padding-left:20px; }
    .warning-list { margin:0; padding:0; list-style:none; }
    .warning-list li { padding:9px 0; border-top:1px solid #e7ecf1; }
    .warning-list strong,.warning-list span { display:block; font-size:10px; }
    .warning-list span { margin-top:3px; color:var(--muted); }
    .empty { margin:8px 0; color:#7c889a; font-size:10px; }
    .hidden { display:none !important; }
    footer { display:flex; justify-content:space-between; gap:20px; margin-top:18px; padding:13px 3px 0; border-top:1px solid var(--line); color:#7d8999; font-size:9px; }
    @media (max-width:900px) { .topbar { grid-template-columns:1fr auto; padding:0 18px; } .topbar nav { display:none; } .dashboard-layout { grid-template-columns:1fr; } .dashboard-side { grid-template-columns:1fr 1fr; } }
    @media (max-width:680px) { main { width:min(100% - 20px,1240px); padding-top:18px; } .topbar { min-height:58px; } .scan-complete,.host-meta { display:none; } .report-heading,.section-heading { display:block; } .scan-meta,.severity-summary { justify-content:flex-start; margin-top:10px; } .metric-grid,.overview-grid,.dashboard-side,.diagnostic-grid { grid-template-columns:1fr; } .evidence-preview { grid-column:auto; } .assessment-item summary { grid-template-columns:72px 1fr 16px; } .assessment-item .summary-text,.assessment-item .confidence { display:none; } .detail-body { padding-left:10px; } .toolbar { align-items:stretch; flex-wrap:wrap; } .search-field { flex-basis:100%; } .package summary { grid-template-columns:1fr auto 16px; } .package-counts { display:none; } .package-facts { grid-template-columns:1fr; } .provider-row { grid-template-columns:100px 1fr 25px; } footer { display:block; } footer span { display:block; margin-top:5px; } }
    """
}
