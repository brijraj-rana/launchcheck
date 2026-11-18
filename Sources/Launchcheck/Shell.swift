import AppKit
import LaunchcheckCore
import SwiftUI

// MARK: Window

struct ContentView: View {
    @ObservedObject var model: AuditModel
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(model: model)
                .frame(width: 216)
            Tone.hairline.frame(width: 1)
            VStack(spacing: 0) {
                AddressBar(model: model)
                    .padding(.leading, 20)
                    .padding(.trailing, 16)
                    .frame(height: 52)
                    .overlay(alignment: .bottom) { RunLine(model: model) }
                main
            }
            .background(Tone.surface)
        }
        .background(Tone.sidebar)
        .onAppear { if !isSnapshot { ArrowKeys.install(for: model) } }
        .confirmationDialog(removalTitle, isPresented: Binding(get: { model.removal != nil }, set: { if !$0 { model.removal = nil } }), titleVisibility: .visible) {
            Button(model.removal == .everything ? "Delete All" : "Delete", role: .destructive) { model.confirmRemoval() }
            Button("Cancel", role: .cancel) { model.removal = nil }
        } message: {
            Text("The kept checks are removed from this Mac. The site itself is not touched.")
        }
    }

    private var removalTitle: String {
        switch model.removal {
        case .site(let host): return "Delete \(host) and its kept checks?"
        case .everything: return "Delete all \(model.sites.count) sites and their kept checks?"
        case nil: return ""
        }
    }

    @ViewBuilder private var main: some View {
        switch model.phase {
        case .running:
            RunningView(model: model)
        case .failed(let message):
            FailedView(message: message) { model.start() }
        case .idle, .done:
            if let report = model.report {
                ReportShell(model: model, report: report)
            } else {
                IdleView()
            }
        }
    }
}

/// Up and down move through the list on screen, unless a text field is being typed in.
@MainActor
enum ArrowKeys {
    private static var installed = false

    static func install(for model: AuditModel) {
        guard !installed else { return }
        installed = true
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak model] event in
            guard let model, event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
                  !(event.window?.firstResponder is NSText), model.report != nil, !model.isRunning,
                  model.tab == .issues || model.tab == .pages else { return event }
            switch event.keyCode {
            case 125: model.move(by: 1)
            case 126: model.move(by: -1)
            default: return event
            }
            return nil
        }
    }
}

/// The hairline under the address bar, which fills as a check runs.
struct RunLine: View {
    @ObservedObject var model: AuditModel

    var body: some View {
        GeometryReader { geometry in
            let progress = model.progress
            let fraction = progress.total > 0 ? min(1, CGFloat(progress.done) / CGFloat(progress.total)) : 0.03
            ZStack(alignment: .leading) {
                Tone.hairline
                if model.isRunning {
                    Tone.ink.frame(width: max(8, geometry.size.width * fraction))
                        .animation(.easeOut(duration: 0.25), value: progress.done)
                }
            }
        }
        .frame(height: model.isRunning ? 2 : 1)
        .accessibilityHidden(true)
    }
}

// MARK: Sidebar

struct Sidebar: View {
    @ObservedObject var model: AuditModel
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                SectionLabel(text: "Sites")
                Spacer()
                if !model.sites.isEmpty, !isSnapshot {
                    Menu {
                        Button("Delete All Sites…", role: .destructive) { model.removal = .everything }
                    } label: {
                        Image(systemName: "ellipsis").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                            .frame(width: 20, height: 16).contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("More")
                    .accessibilityLabel("More")
                }
            }
            .padding(.leading, 18)
            .padding(.trailing, 12)
            .padding(.top, 54)
            .padding(.bottom, 6)
            if model.sites.isEmpty {
                Text("Sites you check are kept here with their last score.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)
                    .padding(.horizontal, 18)
                    .padding(.top, 2)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Scroller {
                    VStack(spacing: 1) {
                        ForEach(model.sites, id: \.host) { site in
                            SiteRow(site: site, selected: model.report?.host == site.host && !model.isRunning) {
                                model.show(site)
                            } delete: {
                                model.removal = .site(site.host)
                            }
                            .contextMenu {
                                Button("Check Again") {
                                    model.address = site.host
                                    model.start()
                                }
                                Button("Open in Browser") { model.open(site.site) }
                                Button("Copy Address") { model.copy(site.site) }
                                Divider()
                                Button("Delete Latest Check") { model.delete(site) }
                                Button("Delete Site…", role: .destructive) { model.removal = .site(site.host) }
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

struct SiteRow: View {
    let site: Report
    let selected: Bool
    let action: () -> Void
    let delete: () -> Void
    @State private var hovering = false

    var body: some View {
        let blocked = site.count(.error) > 0
        row(blocked: blocked)
            .overlay(alignment: .trailing) {
                // Under the pointer the score gives way to a way out.
                if hovering {
                    Button(action: delete) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(Tone.lift))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 6)
                    .help("Delete this site")
                    .accessibilityLabel("Delete \(site.host)")
                }
            }
            .onHover { hovering = $0 }
    }

    private func row(blocked: Bool) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                ScoreRing(score: site.score, blocked: blocked, size: 16, line: 2.5)
                VStack(alignment: .leading, spacing: 1) {
                    Text(site.host.hasPrefix("www.") ? String(site.host.dropFirst(4)) : site.host)
                        .font(.system(size: 12.5, weight: selected ? .semibold : .medium))
                        .lineLimit(1)
                    Text(site.date.ago)
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Text("\(site.score)")
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(blocked ? AnyShapeStyle(Tone.error) : AnyShapeStyle(.secondary))
                    .opacity(hovering ? 0 : 1)
            }
            .frame(height: 40)
        }
        .buttonStyle(RowStyle(selected: selected))
        .accessibilityLabel("\(site.host), score \(site.score), \(site.grade), checked \(site.date.ago)")
        .accessibilityAddTraits(selected ? .isSelected : [])
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
                    Text(model.address.isEmpty ? "yoursite.com" : model.address)
                        .font(.system(size: 13))
                        .foregroundStyle(model.address.isEmpty ? .tertiary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    TextField("yoursite.com", text: $model.address)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .focused($focused)
                        .onSubmit { model.start() }
                        .disabled(model.isRunning)
                        .accessibilityLabel("Site address")
                }
                if isSnapshot {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                } else {
                    options
                }
            }
            .padding(.horizontal, 11)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Tone.wash))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(focused ? 0.28 : 0), lineWidth: 1))
            .animation(.easeOut(duration: 0.12), value: focused)

            if model.isRunning {
                Button("Stop") { model.stop() }
                    .buttonStyle(QuietButton())
                    .keyboardShortcut(.cancelAction)
            } else {
                Button(sameSite ? "Check again" : "Check") { model.start() }
                    .buttonStyle(QuietButton(prominent: true))
                    .disabled(model.address.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .onAppear { focused = model.report == nil }
    }

    /// True when the address in the field is the site whose report is on screen.
    private var sameSite: Bool {
        func bare(_ host: String?) -> String? { host.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } }
        guard let shown = bare(model.report?.host) else { return false }
        return shown == bare(Auditor.siteURL(from: model.address)?.host)
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
        .help("How much to check")
        .accessibilityLabel("Options")
    }
}

// MARK: Before, during and when it goes wrong

/// Nothing checked yet: say what to do, and show what an answer looks like.
struct IdleView: View {
    private let examples: [(Severity, String, String)] = [
        (.error, "Pages are set to noindex", "/pricing"),
        (.error, "Pages still point at a staging domain", "/about"),
        (.warning, "Pages have no share image", "/contact"),
        (.warning, "robots.txt blocks AI search crawlers", "/robots.txt"),
        (.notice, "Titles are too long or too short", "/blog"),
    ]

    var body: some View {
        Scroller {
            VStack(alignment: .leading, spacing: 34) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Check a site before it goes live.")
                        .font(.system(size: 30, weight: .semibold))
                        .tracking(-0.4)
                    Text("Type an address above and press Return. Every page in the sitemap is read and held against \(Check.all.count) things that quietly cost a launch its search traffic.")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 500, alignment: .leading)
                }
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel(text: "The kind of thing it finds")
                    VStack(spacing: 0) {
                        ForEach(Array(examples.enumerated()), id: \.offset) { index, example in
                            if index > 0 { Tone.hairline.frame(height: 1) }
                            HStack(spacing: 10) {
                                Mark(example.0)
                                Text(example.1).font(.system(size: 13, weight: .medium))
                                Spacer(minLength: 12)
                                Text(example.2).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary)
                            }
                            .frame(height: 36)
                        }
                    }
                    .frame(maxWidth: 500)
                }
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel(text: "Ten areas")
                    Text(LaunchcheckCore.Category.allCases.map(\.title).joined(separator: ", ") + ".")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 500, alignment: .leading)
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 44)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct RunningView: View {
    @ObservedObject var model: AuditModel

    var body: some View {
        let progress = model.progress
        VStack(alignment: .leading, spacing: 26) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Reading \(Auditor.siteURL(from: model.address)?.host ?? model.address)")
                    .font(.system(size: 26, weight: .semibold))
                    .tracking(-0.3)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("The way a search engine does: every page, every link, nothing run.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(model.finishedSteps.enumerated()), id: \.offset) { _, step in
                    HStack(spacing: 10) {
                        Mark(.passed)
                        Text(step).font(.system(size: 13).monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .frame(height: 28)
                    .transition(.opacity)
                }
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 12, height: 12)
                    Text(progress.phase).font(.system(size: 13, weight: .semibold))
                    if progress.total > 0 {
                        Text("\(progress.done) of \(progress.total)")
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(height: 28)
            }
            .animation(.easeOut(duration: 0.2), value: model.finishedSteps.count)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 28)
        .padding(.top, 44)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .combine)
    }
}

struct FailedView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text("That site could not be checked")
                    .font(.system(size: 26, weight: .semibold))
                    .tracking(-0.3)
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: 500, alignment: .leading)
            }
            Text("Check the spelling, or try the address in a browser first.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Button("Try again", action: retry).buttonStyle(QuietButton())
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 28)
        .padding(.top, 44)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: Report frame

struct ReportShell: View {
    @ObservedObject var model: AuditModel
    let report: Report
    @Namespace private var tabs
    @Environment(\.isSnapshot) private var isSnapshot
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(AuditModel.Tab.allCases, id: \.self) { tab in
                    TabButton(title: tab.rawValue, count: count(for: tab), selected: model.tab == tab, namespace: tabs) {
                        // A click slides the underline; the keyboard shortcuts switch at once.
                        if reduceMotion { model.tab = tab } else { withAnimation(Motion.move) { model.tab = tab } }
                    }
                }
                Spacer()
                export
            }
            .padding(.leading, 18)
            .padding(.trailing, 16)
            .frame(height: 40)
            Tone.hairline.frame(height: 1)

            Group {
                switch model.tab {
                case .overview: OverviewTab(model: model, report: report)
                case .issues: IssuesTab(model: model, report: report)
                case .pages: PagesTab(model: model, report: report)
                case .changes: ChangesTab(model: model, report: report)
                }
            }
            .transaction { $0.animation = nil }
        }
    }

    @ViewBuilder private var export: some View {
        if isSnapshot {
            HStack(spacing: 5) {
                Image(systemName: "square.and.arrow.up").font(.system(size: 10.5, weight: .medium))
                Text("Export").font(.system(size: 11.5, weight: .medium))
            }
            .foregroundStyle(.secondary)
        } else {
            Menu {
                Button("Copy as Markdown") { model.copyMarkdown() }
                Button("Save as Markdown…") { model.save(json: false) }
                Button("Save as JSON…") { model.save(json: true) }
            } label: {
                Label(model.copied ? "Copied" : "Export", systemImage: model.copied ? "checkmark" : "square.and.arrow.up")
                    .font(.system(size: 11.5, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Copy or save this report")
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
    let namespace: Namespace.ID
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title).font(.system(size: 12.5, weight: .medium))
                if let count {
                    Text("\(count)")
                        .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            .foregroundStyle(selected || hovering ? .primary : .secondary)
            .padding(.horizontal, 10)
            .frame(height: 40)
            .overlay(alignment: .bottom) {
                if selected {
                    Rectangle().fill(Tone.ink).frame(height: 2).padding(.horizontal, 10)
                        .matchedGeometryEffect(id: "underline", in: namespace)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
