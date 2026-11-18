import LaunchcheckCore
import SwiftUI

// MARK: Window

struct ContentView: View {
    @ObservedObject var model: AuditModel

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(model: model)
                .frame(width: 212)
            Tone.hairline.frame(width: 1)
            VStack(spacing: 0) {
                AddressBar(model: model)
                    .padding(.horizontal, 24)
                    .padding(.top, 14)
                    .padding(.bottom, 14)
                Tone.hairline.frame(height: 1)
                main
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder private var main: some View {
        switch model.phase {
        case .running:
            RunningView(model: model)
        case .failed(let message):
            FailedView(message: message)
        case .idle, .done:
            if let report = model.report {
                ReportShell(model: model, report: report)
            } else {
                IdleView()
            }
        }
    }
}

// MARK: Sidebar

struct Sidebar: View {
    @ObservedObject var model: AuditModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Eyebrow(text: "Sites")
                .padding(.horizontal, 16)
                .padding(.top, 52)
                .padding(.bottom, 8)
            if model.sites.isEmpty {
                Text("Sites you check are kept here, with their last score.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Scroller {
                    VStack(spacing: 1) {
                        ForEach(model.sites, id: \.host) { site in
                            SiteRow(site: site, selected: model.report?.host == site.host && !model.isRunning) {
                                model.show(site)
                            }
                            .contextMenu {
                                Button("Check Again") {
                                    model.address = site.host
                                    model.start()
                                }
                                Button("Forget This Site") { model.forget(site.host) }
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Tone.wash)
    }
}

struct SiteRow: View {
    let site: Report
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                ScoreRing(score: site.score, blocked: site.count(.error) > 0, size: 18, line: 3)
                VStack(alignment: .leading, spacing: 1) {
                    Text(site.host.hasPrefix("www.") ? String(site.host.dropFirst(4)) : site.host)
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("\(site.score) · \(site.date.ago)")
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 40)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(selected ? Tone.lift : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(site.host), score \(site.score), checked \(site.date.ago)")
    }
}

// MARK: Address bar

struct AddressBar: View {
    @ObservedObject var model: AuditModel
    @FocusState private var focused: Bool
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "globe")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                if isSnapshot {
                    Text(model.address).font(.system(size: 14)).frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    TextField("yoursite.com", text: $model.address)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .focused($focused)
                        .onSubmit { model.start() }
                        .disabled(model.isRunning)
                }
                if isSnapshot {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                } else {
                    options
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Tone.wash))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Tone.hairline))

            if model.isRunning {
                Button("Stop") { model.stop() }
                    .buttonStyle(QuietButton())
                    .keyboardShortcut(.cancelAction)
            } else {
                Button(model.report?.host == Auditor.siteURL(from: model.address)?.host ? "Check again" : "Check") { model.start() }
                    .buttonStyle(QuietButton(prominent: true))
                    .disabled(model.address.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .onAppear { focused = true }
    }

    private var options: some View {
        Menu {
            Picker("Pages", selection: $model.maxPages) {
                Text("Up to 50 pages").tag(50)
                Text("Up to 200 pages").tag(200)
                Text("Up to 1,000 pages").tag(1000)
            }
            .pickerStyle(.inline)
            Toggle("Check links to other sites", isOn: $model.checkExternalLinks)
            Toggle("Weigh images", isOn: $model.checkImages)
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Options")
    }
}

// MARK: Before, during and when it goes wrong

struct IdleView: View {
    private let points = [
        ("eye.slash", "Indexing", "A noindex left on from staging, a robots.txt that shuts everyone out, canonicals pointing at the wrong domain."),
        ("link", "Links", "Broken links and images, redirect chains, pages nothing links to."),
        ("text.alignleft", "Content", "Missing or repeated titles and descriptions, heading order, thin pages, leftover Lorem ipsum."),
        ("sparkles", "AI search", "Whether ChatGPT, Claude and Perplexity are allowed in, and whether there is an llms.txt."),
        ("curlybraces", "Structured data", "Schema.org markup that is broken, incomplete or retired."),
        ("lock", "Security and speed", "HTTPS, security headers, compression, heavy images, slow answers."),
    ]

    var body: some View {
        Scroller {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Check a site before it goes live.")
                        .font(.system(size: 26, weight: .semibold))
                    Text("Type an address and press Return. Every page in the sitemap is read and checked against \(Check.all.count) things that quietly cost a launch its search traffic.")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 520, alignment: .leading)
                }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    ForEach(points, id: \.1) { icon, title, text in
                        Card(padding: 14) {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 7) {
                                    Image(systemName: icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).frame(width: 16)
                                    Text(title).font(.system(size: 13, weight: .semibold))
                                }
                                Text(text)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, minHeight: 74, alignment: .topLeading)
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 30)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct RunningView: View {
    @ObservedObject var model: AuditModel

    var body: some View {
        let progress = model.progress
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Checking \(Auditor.siteURL(from: model.address)?.host ?? model.address)")
                    .font(.system(size: 22, weight: .semibold))
                    .lineLimit(1)
                Text("Reading the site the way a search engine does.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(model.finishedSteps.enumerated()), id: \.offset) { _, step in
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Tone.passed).frame(width: 14)
                        Text(step).font(.system(size: 13).monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .transition(.opacity)
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Circle().fill(Color.primary).frame(width: 6, height: 6).frame(width: 14)
                        Text(progress.phase).font(.system(size: 13, weight: .semibold))
                        Spacer()
                        if progress.total > 0 {
                            Text("\(progress.done) of \(progress.total)")
                                .font(.system(size: 12).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    GeometryReader { geometry in
                        let fraction = progress.total > 0 ? min(1, Double(progress.done) / Double(progress.total)) : 0.04
                        ZStack(alignment: .leading) {
                            Capsule().fill(Tone.hairline)
                            Capsule().fill(Color.primary).frame(width: max(6, geometry.size.width * fraction))
                        }
                    }
                    .frame(height: 3)
                    .padding(.leading, 24)
                }
            }
            .animation(.easeOut(duration: 0.2), value: model.finishedSteps.count)
            .animation(.easeOut(duration: 0.25), value: progress.done)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.top, 30)
        .frame(maxWidth: 560, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct FailedView: View {
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle().fill(Tone.error).frame(width: 7, height: 7)
                Text("Could not check that site").font(.system(size: 18, weight: .semibold))
            }
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.top, 30)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: Report frame

struct ReportShell: View {
    @ObservedObject var model: AuditModel
    let report: Report
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(AuditModel.Tab.allCases, id: \.self) { tab in
                    TabButton(title: tab.rawValue, count: count(for: tab), selected: model.tab == tab) { model.tab = tab }
                }
                Spacer()
                if isSnapshot {
                    Text("Export").font(.system(size: 11.5, weight: .medium)).padding(.horizontal, 10).frame(height: 24)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Tone.wash))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Tone.hairline))
                } else {
                    Menu("Export") {
                        Button("Copy as Markdown") { model.copyMarkdown() }
                        Button("Save as Markdown…") { model.save(json: false) }
                        Button("Save as JSON…") { model.save(json: true) }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .font(.system(size: 12))
                }
            }
            .padding(.horizontal, 20)
            .frame(height: 42)
            Tone.hairline.frame(height: 1)

            switch model.tab {
            case .overview: OverviewTab(model: model, report: report)
            case .issues: IssuesTab(model: model, report: report)
            case .pages: PagesTab(model: model, report: report)
            case .changes: ChangesTab(model: model, report: report)
            }
        }
    }

    private func count(for tab: AuditModel.Tab) -> Int? {
        switch tab {
        case .overview: return nil
        case .issues: return report.groups.count
        case .pages: return report.pages.count
        case .changes:
            guard let comparison = model.comparison else { return nil }
            let total = comparison.fixed.count + comparison.introduced.count + comparison.changes.count
            return total > 0 ? total : nil
        }
    }
}

struct TabButton: View {
    let title: String
    let count: Int?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title).font(.system(size: 12.5, weight: selected ? .semibold : .medium))
                if let count {
                    Text("\(count)")
                        .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(selected ? .primary : .secondary)
            .padding(.horizontal, 10)
            .frame(height: 42)
            .overlay(alignment: .bottom) {
                Rectangle().fill(selected ? Color.primary : .clear).frame(height: 2).padding(.horizontal, 10)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
