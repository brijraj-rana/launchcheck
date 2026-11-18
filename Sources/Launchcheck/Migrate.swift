import AppKit
import LaunchcheckCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: Model

@MainActor
final class MigrationModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case running
        case done
        case failed(String)
    }

    /// Which rows the list shows.
    enum Scope: Hashable {
        case all, stranded, uncertain, ready, fine, new
    }

    @Published var old = ""
    @Published var new = ""
    /// The old site's addresses as text, when they were loaded or pasted because the site is offline.
    @Published var list: String?
    /// Where the list came from and how long it is: "214 from sitemap.xml".
    @Published var listNote: String?

    @Published var phase: Phase = .idle
    @Published var progress = AuditProgress(phase: "Starting")
    @Published var finishedSteps: [String] = []
    @Published var map: MigrationMap?

    @Published var scope: Scope = .all
    @Published var selected: String?
    /// What is typed in the destination field of the picked row.
    @Published var draft = ""
    /// Counts requests to edit the destination, so the field can take the keyboard for each.
    @Published var editRequests = 0
    /// Briefly the name of what was just copied, so the button can say so.
    @Published var copied = false
    /// Leave the matches that need a look out of what is copied or saved.
    @Published var confidentOnly = false
    @Published var failures = 0

    /// How many pages of each site to read; follows the setting in the address bar.
    var pageLimit: () -> Int = { 200 }
    private var task: Task<Void, Never>?
    private var run = 0

    var isRunning: Bool { phase == .running }

    var canStart: Bool {
        !new.trimmingCharacters(in: .whitespaces).isEmpty && (!old.trimmingCharacters(in: .whitespaces).isEmpty || list != nil)
    }

    // MARK: Running

    func start() {
        guard canStart else { return }
        var from = old.trimmingCharacters(in: .whitespacesAndNewlines)
        let to = new.trimmingCharacters(in: .whitespacesAndNewlines)
        // A list of full addresses says which site it is from.
        if from.isEmpty, let list, let base = URL(string: "https://invalid/"),
           let host = Migrator.addresses(in: list, base: base).first(where: { $0.host != "invalid" })?.host {
            from = host
            old = host
        }
        task?.cancel()
        run += 1
        let current = run
        var options = Options()
        options.maxPages = pageLimit()
        progress = AuditProgress(phase: "Starting")
        finishedSteps = []
        phase = .running

        let update: @Sendable (AuditProgress) -> Void = { [weak self] progress in
            Task { @MainActor in
                guard let self, self.run == current, self.isRunning else { return }
                if progress.phase != self.progress.phase, self.progress.phase != "Starting" {
                    let step = self.progress
                    self.finishedSteps.append(step.total > 0 ? "\(step.phase) (\(step.total))" : step.phase)
                }
                if progress.phase != self.progress.phase || progress.done >= self.progress.done { self.progress = progress }
            }
        }
        let list = list
        task = Task { [weak self] in
            do {
                let map = try await Migrator(options: options).run(old: from, new: to, oldList: list, progress: update)
                guard let self, self.run == current, !Task.isCancelled else { return }
                self.present(map)
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.run == current else { return }
                self.phase = .failed(error.localizedDescription)
                self.failures += 1
            }
        }
    }

    func stop() {
        task?.cancel()
        run += 1
        phase = map == nil ? .idle : .done
    }

    func present(_ map: MigrationMap) {
        self.map = map
        scope = .all
        phase = .done
        // The first row that needs a person is already open.
        select(rows.first?.id)
    }

    // MARK: The list

    static let order: [MigrationRow.Standing] = [.stranded, .uncertain, .ready, .fine]

    /// The rows on screen, the ones that need most attention first.
    var rows: [MigrationRow] {
        guard let map else { return [] }
        let wanted: [MigrationRow.Standing]
        switch scope {
        case .all: wanted = Self.order
        case .stranded: wanted = [.stranded]
        case .uncertain: wanted = [.uncertain]
        case .ready: wanted = [.ready]
        case .fine: wanted = [.fine]
        case .new: wanted = []
        }
        return wanted.flatMap { standing in map.rows.filter { $0.standing == standing } }
    }

    var row: MigrationRow? {
        map?.rows.first { $0.id == selected }
    }

    var position: (index: Int, count: Int)? {
        let ids = rows.map(\.id)
        guard let index = selected.flatMap({ ids.firstIndex(of: $0) }) else { return nil }
        return (index + 1, ids.count)
    }

    func select(_ id: String?) {
        selected = id
        draft = row?.destination ?? ""
    }

    func move(by step: Int) {
        let ids = rows.map(\.id)
        guard !ids.isEmpty else { return }
        let index = selected.flatMap { ids.firstIndex(of: $0) } ?? (step > 0 ? -1 : ids.count)
        select(ids[min(ids.count - 1, max(0, index + step))])
    }

    func show(_ scope: Scope) {
        self.scope = scope
        if !rows.contains(where: { $0.id == selected }) { select(rows.first?.id) }
    }

    // MARK: Editing

    /// Return on a row: the destination field takes the keyboard.
    func edit() {
        guard row?.needsRedirect == true || row?.edited == true else { return }
        editRequests += 1
    }

    /// Sends the picked row to a path. The row stays picked even when that moves it to another group.
    func send(to destination: String) {
        guard let id = selected, let row else { return }
        // Keeping a destination that was already settled changes nothing, and should not mark the row as edited.
        if row.sure, Migrator.entered(destination) == row.destination { return }
        map?.setDestination(destination, for: id)
        draft = self.row?.destination ?? ""
    }

    func title(of path: String?) -> String? {
        guard let path else { return nil }
        return map?.newPages.first { $0.path == path }?.title
    }

    func exists(_ path: String?) -> Bool {
        guard let path else { return false }
        return path.hasPrefix("http") || map?.newPages.contains { $0.path == path } == true
    }

    // MARK: The old list

    func loadList() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.xml, .plainText, .commaSeparatedText, .text]
        panel.message = "Choose the old site's sitemap, or a file with one address per line."
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        take(String(decoding: data, as: UTF8.self), from: url.lastPathComponent)
    }

    func pasteList() {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        take(text, from: "the clipboard")
    }

    private func take(_ text: String, from source: String) {
        guard let base = URL(string: "https://invalid/") else { return }
        let count = Migrator.addresses(in: text, base: base).count
        guard count > 0 else {
            failures += 1
            return
        }
        list = text
        listNote = "\(count.formatted()) from \(source)"
    }

    func forgetList() {
        list = nil
        listNote = nil
    }

    // MARK: Getting it out

    func text(_ format: MigrationFormat) -> String {
        map.map { format.render($0, confidentOnly: confidentOnly) } ?? ""
    }

    func copy(_ format: MigrationFormat) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text(format), forType: .string)
        copied = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.4))
            self?.copied = false
        }
    }

    func save(_ format: MigrationFormat) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = format.fileName
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try text(format).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    func open(_ path: String?, old: Bool) {
        guard let path, let map else { return }
        let address = path.hasPrefix("http") ? path : (old ? map.oldSite : map.newSite).dropLast() + path
        if let url = URL(string: String(address)) { NSWorkspace.shared.open(url) }
    }
}

// MARK: Marks and words

extension MigrationRow.Standing {
    var mark: Mark.Kind {
        switch self {
        case .stranded: return .error
        case .uncertain: return .warning
        case .ready: return .notice
        case .fine: return .passed
        }
    }

    var title: String {
        switch self {
        case .stranded: return "No match"
        case .uncertain: return "To check"
        case .ready: return "Ready"
        case .fine: return "Nothing to do"
        }
    }
}

extension MigrationRow {
    /// What happened to this address, in a sentence.
    var explanation: String {
        switch outcome {
        case .same: return "The new site has a page at this address."
        case .redirected: return "The new site already redirects this address to a page that loads."
        case .broken: return destination == nil
            ? "The new site redirects this address to a page that is not there, and nothing else looks like it."
            : "The new site redirects this address, but not well. Pointing it straight at this page fixes it."
        case .confident: return edited
            ? "Nothing lives at this address on the new site. It goes where you sent it."
            : "Nothing lives at this address on the new site, and this is plainly the page it became."
        case .possible: return "Nothing lives at this address on the new site. This is the closest page. Look at both before using it."
        case .unmatched: return "Nothing lives at this address on the new site and nothing looks like it. Choose where it should go, or leave it to return a 404."
        }
    }
}

// MARK: Screen

/// Moving a site: the old address and the new one above, what becomes of every old page below.
struct MigrateScreen: View {
    @ObservedObject var model: MigrationModel

    var body: some View {
        VStack(spacing: 0) {
            MigrateBar(model: model)
                .padding(.leading, 20)
                .padding(.trailing, 16)
                .frame(height: 52)
                .overlay(alignment: .bottom) { RunLine(running: model.isRunning, progress: model.progress) }
            switch model.phase {
            case .running:
                RunningView(title: "Comparing the two sites", subtitle: "Every old address is asked of the new site, and the missing ones are matched to the page they became.",
                            steps: model.finishedSteps, progress: model.progress)
            case .failed(let message):
                FailedView(title: "The sites could not be compared", message: message,
                           hint: "If the old site is already offline, give its addresses as a list: the button at the end of the first field.") { model.start() }
            case .idle, .done:
                if let map = model.map {
                    MigrateResult(model: model, map: map)
                } else {
                    MigrateIdle()
                }
            }
        }
    }
}

/// Two addresses and a button, where a check has one.
struct MigrateBar: View {
    @ObservedObject var model: MigrationModel
    @FocusState private var focused: Field?
    @Environment(\.isSnapshot) private var isSnapshot

    private enum Field {
        case old, new
    }

    var body: some View {
        HStack(spacing: 8) {
            field("Old", prompt: model.list == nil ? "oldsite.com" : "its address, if the list has only paths", text: $model.old, id: .old) {
                if let note = model.listNote {
                    Text(note).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                }
                if isSnapshot {
                    Image(systemName: "list.bullet").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                } else {
                    listMenu
                }
            }
            .shake(on: model.failures)
            Image(systemName: "arrow.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
            field("New", prompt: "newsite.webflow.io", text: $model.new, id: .new) { EmptyView() }

            if model.isRunning {
                Button("Stop") { model.stop() }
                    .buttonStyle(QuietButton())
                    .keyboardShortcut(.cancelAction)
            } else {
                Button(model.map == nil ? "Compare" : "Compare again") { model.start() }
                    .buttonStyle(QuietButton(prominent: true))
                    .disabled(!model.canStart)
            }
        }
        .onAppear { if model.map == nil { focused = .old } }
    }

    private func field<Trailing: View>(_ label: String, prompt: String, text: Binding<String>, id: Field, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary)
            if isSnapshot {
                Text(text.wrappedValue.isEmpty ? prompt : text.wrappedValue)
                    .font(.system(size: 13))
                    .foregroundStyle(text.wrappedValue.isEmpty ? .tertiary : .primary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField(prompt, text: text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($focused, equals: id)
                    .onSubmit { if id == .old, model.new.isEmpty { focused = .new } else { model.start() } }
                    .disabled(model.isRunning)
                    .accessibilityLabel("\(label) site address")
            }
            trailing()
        }
        .padding(.horizontal, 11)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Tone.wash))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(focused == id ? 0.28 : 0), lineWidth: 1))
        .animation(Motion.swap, value: focused)
    }

    private var listMenu: some View {
        Menu {
            Button("Load a Sitemap or a List…") { model.loadList() }
            Button("Paste a List") { model.pasteList() }
            if model.list != nil {
                Divider()
                Button("Forget the List") { model.forgetList() }
            }
        } label: {
            Image(systemName: "list.bullet").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Old site already offline? Give its addresses as a sitemap or a list.")
        .accessibilityLabel("Old addresses from a list")
    }
}

/// Nothing compared yet: say what this is for, and show what an answer looks like.
struct MigrateIdle: View {
    private let examples: [(Mark.Kind, String, String?, String)] = [
        (.passed, "/about", "/about", "Same address"),
        (.notice, "/blog/2021/anvil-care", "/posts/anvil-care", "Redirect written"),
        (.warning, "/our-people", "/team", "A guess to check"),
        (.error, "/clearance", nil, "Needs a person"),
    ]

    var body: some View {
        Scroller {
            VStack(alignment: .leading, spacing: 34) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Move a site without losing its ranking.")
                        .font(.system(size: 30, weight: .semibold))
                        .tracking(-0.4)
                    Text("Type the old address and the new one above. Every old page is looked up on the new site, and each one that would be lost gets a redirect written for it.")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 500, alignment: .leading)
                }
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel(text: "What becomes of each old page")
                    VStack(spacing: 0) {
                        ForEach(Array(examples.enumerated()), id: \.offset) { index, example in
                            if index > 0 { Tone.hairline.frame(height: 1) }
                            HStack(spacing: 10) {
                                Mark(example.0)
                                Route(from: example.1, to: example.2, dimmed: example.0 == .passed)
                                Spacer(minLength: 12)
                                Text(example.3).font(.system(size: 11.5)).foregroundStyle(.secondary)
                            }
                            .frame(height: 36)
                        }
                    }
                    .frame(maxWidth: 500)
                }
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel(text: "Good to know")
                    Text("The new site can still be on its staging address: redirects are written as paths. If the old site is already offline, give its addresses as a sitemap or a list with the button at the end of the first field.")
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

/// An old path, an arrow, and where it goes. Written inline, so short routes stay short.
private struct Route: View {
    let from: String
    let to: String?
    var dimmed = false

    var body: some View {
        HStack(spacing: 8) {
            Text(from).font(.system(size: 12, design: .monospaced)).foregroundStyle(dimmed ? .secondary : .primary).lineLimit(1).truncationMode(.middle)
            Image(systemName: "arrow.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
            if let to {
                Text(to).font(.system(size: 12, design: .monospaced)).foregroundStyle(dimmed ? .secondary : .primary).lineLimit(1).truncationMode(.middle)
            } else {
                Text("No match").font(.system(size: 11.5, weight: .medium)).foregroundStyle(Tone.error)
            }
        }
    }
}

// MARK: Result

struct MigrateResult: View {
    @ObservedObject var model: MigrationModel
    let map: MigrationMap

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(map.verdict)
                        .font(.system(size: 30, weight: .semibold))
                        .tracking(-0.4)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(summary)
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if map.oldPagesFound > map.rows.count {
                        Text("The first \(map.rows.count) of \(map.oldPagesFound) old pages were read. Raise the limit in the address bar of a check to read them all.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 12)
                ExportMenu(model: model, map: map).padding(.top, 10)
            }
            .padding(.horizontal, 28)
            .padding(.top, 30)
            scopes
                .padding(.horizontal, 28)
                .padding(.top, 20)
                .padding(.bottom, 12)
            Tone.hairline.frame(height: 1)
            HStack(spacing: 0) {
                list.frame(minWidth: 340, maxWidth: .infinity)
                Tone.hairline.frame(width: 1)
                Group {
                    if let row = model.row {
                        RouteInspector(model: model, map: map, row: row)
                            .id(row.id)
                            .transition(.soft)
                    } else {
                        VStack(spacing: 6) {
                            Text(model.scope == .new ? "New pages" : "Pick a page").font(.system(size: 13, weight: .medium))
                            Text(model.scope == .new ? "No old address leads to these. That is fine: they start with no history to keep."
                                 : "Use the arrow keys to move through the list.")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 240)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(width: 320)
            }
        }
    }

    private var summary: String {
        var parts: [String] = []
        if !map.breakdown.isEmpty { parts.append(map.breakdown) }
        // The two sites are named in the fields above; here only how much of each was read.
        parts.append("\(map.rows.count) old \(map.rows.count == 1 ? "page" : "pages"), \(map.newPages.count) new")
        parts.append(map.date.ago)
        return parts.joined(separator: " · ")
    }

    /// Counts by what each row needs, each one a filter. The same capsules as the issue list.
    private var scopes: some View {
        let options: [(MigrationModel.Scope, Mark.Kind, String, Int)] = [
            (.all, .none, "All", map.rows.count),
            (.stranded, .error, "No match", map.count(.stranded)),
            (.uncertain, .warning, "To check", map.count(.uncertain)),
            (.ready, .notice, "Ready", map.count(.ready)),
            (.fine, .passed, "Nothing to do", map.count(.fine)),
            (.new, .none, "New pages", map.unclaimed.count),
        ]
        return HStack(spacing: 6) {
            ForEach(options, id: \.0) { scope, mark, title, count in
                Button { model.show(scope) } label: {
                    HStack(spacing: 5) {
                        if mark != .none { Mark(mark) }
                        Text(title).font(.system(size: 11.5, weight: .medium))
                        Text("\(count)").font(.system(size: 11.5, weight: .medium).monospacedDigit())
                            .foregroundStyle(model.scope == scope ? .primary : .secondary)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(Capsule().fill(model.scope == scope ? Tone.lift : Color.clear))
                    .overlay(Capsule().strokeBorder(Tone.hairline).opacity(model.scope == scope ? 0 : 1))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(title), \(count)")
                .accessibilityAddTraits(model.scope == scope ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: List

    private var list: some View {
        Scroller(target: model.selected) {
            VStack(alignment: .leading, spacing: 18) {
                if model.scope == .new {
                    fresh
                } else if model.rows.isEmpty {
                    Text(map.rows.isEmpty ? "The old site listed no pages." : "Nothing here.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.top, 8)
                }
                ForEach(sections, id: \.title) { section in
                    VStack(alignment: .leading, spacing: 4) {
                        SectionLabel(text: section.title, count: section.rows.count).padding(.horizontal, 8)
                        VStack(spacing: 1) {
                            ForEach(section.rows) { row in
                                RouteRow(row: row, selected: model.selected == row.id) {
                                    // A click dissolves one explanation into the next; the arrow keys switch at once.
                                    Motion.run(Motion.swap) { model.select(row.id) }
                                }
                                .id(row.id)
                                .contextMenu {
                                    Button("Open Old Page") { model.open(row.path, old: true) }
                                    if let destination = row.destination { Button("Open New Page") { model.open(destination, old: false) } }
                                }
                            }
                        }
                    }
                }
            }
            // Marks and labels line up under the verdict.
            .padding(.leading, 20)
            .padding(.trailing, 8)
            .padding(.vertical, 14)
        }
    }

    private var sections: [(title: String, rows: [MigrationRow])] {
        let rows = model.rows
        return MigrationModel.order.compactMap { standing in
            let matching = rows.filter { $0.standing == standing }
            return matching.isEmpty ? nil : (standing == .ready ? "Ready to export" : standing.title, matching)
        }
    }

    /// New pages that no old address leads to. For information: there is nothing to do about them.
    private var fresh: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel(text: "No old address leads here", count: map.unclaimed.count).padding(.horizontal, 8)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(map.unclaimed, id: \.self) { path in
                    HStack(spacing: 10) {
                        Text(path).font(.system(size: 11.5, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 10)
                        Text(model.title(of: path) ?? "").font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(height: 30)
                }
            }
            .padding(.horizontal, 8)
        }
    }
}

/// One old address and where it goes. The two paths sit in two columns, so the list reads down either side.
struct RouteRow: View {
    let row: MigrationRow
    let selected: Bool
    let action: () -> Void

    var body: some View {
        let fine = row.standing == .fine
        Button(action: action) {
            HStack(spacing: 10) {
                Mark(row.standing.mark)
                Text(row.path)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(fine ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "arrow.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary).opacity(row.outcome == .same ? 0 : 1)
                HStack(spacing: 6) {
                    destination
                    Spacer(minLength: 0)
                    if row.standing == .uncertain {
                        // A guess says so in words as well as by its mark.
                        Text("check").font(.system(size: 10.5, weight: .medium)).foregroundStyle(Tone.warning)
                    } else if row.edited {
                        Text("yours").font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 34)
        }
        .buttonStyle(RowStyle(selected: selected))
        .accessibilityLabel("\(row.path), \(row.standing.title)\(row.destination.map { ", goes to \($0)" } ?? "")")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private var destination: some View {
        if row.outcome == .same {
            Text("Same address").font(.system(size: 11.5)).foregroundStyle(.tertiary)
        } else if let path = row.destination {
            Text(path)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(row.standing == .ready ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        } else {
            Text("No match").font(.system(size: 11.5, weight: .medium)).foregroundStyle(Tone.error)
        }
    }
}

// MARK: Inspector

/// The picked address: why it was decided this way, and the place to decide otherwise.
struct RouteInspector: View {
    @ObservedObject var model: MigrationModel
    let map: MigrationMap
    let row: MigrationRow
    @FocusState private var editing: Bool
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        let standing = row.standing
        Scroller {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 7) {
                        Mark(standing.mark)
                        Text(standing.title)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(standing == .stranded ? AnyShapeStyle(Tone.error) : (standing == .uncertain ? AnyShapeStyle(Tone.warning) : AnyShapeStyle(.secondary)))
                        Spacer(minLength: 8)
                        StepControl(position: model.position) { model.move(by: $0) }
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(row.path)
                            .font(.system(size: 15, weight: .semibold, design: .monospaced))
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        if let title = row.title, !title.isEmpty {
                            Text(title).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Text(row.explanation)
                        .font(.system(size: 13))
                        .lineSpacing(3.5)
                        .foregroundStyle(.primary.opacity(0.82))
                        .fixedSize(horizontal: false, vertical: true)
                }

                if row.needsRedirect || row.edited {
                    VStack(alignment: .leading, spacing: 7) {
                        SectionLabel(text: "Redirect to")
                        field
                        under
                    }
                    if !others.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            SectionLabel(text: row.destination == nil ? "Closest pages" : "Or one of these", count: others.count)
                            VStack(spacing: 0) {
                                ForEach(Array(others.enumerated()), id: \.element) { index, path in
                                    if index > 0 { Tone.hairline.frame(height: 1) }
                                    Button { Motion.run(Motion.swap) { model.send(to: path) } } label: {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(path).font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                                            if let title = model.title(of: path) {
                                                Text(title).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                                            }
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.vertical, 8)
                                    }
                                    .buttonStyle(RowStyle(inset: 0))
                                    .help("Send it here instead")
                                }
                            }
                        }
                    }
                } else if row.outcome == .redirected, let destination = row.destination {
                    VStack(alignment: .leading, spacing: 5) {
                        SectionLabel(text: "Goes to")
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Mark(.passed)
                            Text(destination).font(.system(size: 12.5, design: .monospaced)).textSelection(.enabled)
                        }
                    }
                }

                HStack(spacing: 8) {
                    if standing == .uncertain {
                        Button("Looks right") { Motion.run(Motion.swap) { model.send(to: row.destination ?? "") } }
                            .buttonStyle(QuietButton(compact: true))
                            .help("Keep this match and count it as ready")
                    }
                    Button("Open old") { model.open(row.path, old: true) }.buttonStyle(QuietButton(compact: true))
                    if row.destination != nil {
                        Button("Open new") { model.open(row.destination, old: false) }.buttonStyle(QuietButton(compact: true))
                    }
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: model.editRequests) { _, _ in editing = true }
    }

    /// The alternatives the matcher kept, without the one already chosen.
    private var others: [String] {
        row.alternatives.filter { $0 != row.destination }
    }

    /// Type a path, or pick a page of the new site from the menu.
    private var field: some View {
        HStack(spacing: 8) {
            if isSnapshot {
                Text(model.draft.isEmpty ? "/a-page-on-the-new-site" : model.draft)
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(model.draft.isEmpty ? .tertiary : .primary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            } else {
                TextField("/a-page-on-the-new-site", text: $model.draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5, design: .monospaced))
                    .focused($editing)
                    .onSubmit {
                        model.send(to: model.draft)
                        editing = false
                        // Hand the keyboard back to the list, so the arrow keys move again.
                        NSApp.keyWindow?.makeFirstResponder(nil)
                    }
                    .onExitCommand {
                        model.draft = row.destination ?? ""
                        editing = false
                        NSApp.keyWindow?.makeFirstResponder(nil)
                    }
                    .accessibilityLabel("Redirect to")
                Menu {
                    ForEach(others, id: \.self) { path in Button(path) { model.send(to: path) } }
                    if !others.isEmpty { Divider() }
                    ForEach(map.newPages.prefix(400)) { page in Button(page.path) { model.send(to: page.path) } }
                    Divider()
                    Button("No Redirect") { model.send(to: "") }
                } label: {
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Pick a page of the new site")
                .accessibilityLabel("Pick a page of the new site")
            }
        }
        .padding(.horizontal, 11)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Tone.wash))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(editing ? 0.28 : 0), lineWidth: 1))
        .animation(Motion.swap, value: editing)
    }

    /// What the destination is, and why it was chosen.
    @ViewBuilder private var under: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let destination = row.destination {
                if let title = model.title(of: destination) {
                    Text(title).font(.system(size: 12)).lineLimit(1)
                } else if !model.exists(destination) {
                    Text("No page was read at this address on the new site.").font(.system(size: 12)).foregroundStyle(Tone.warning)
                }
            }
            if let note = row.note {
                Text(note).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if !isSnapshot, editing {
                Text("Return to keep it, Esc to leave it as it was.").font(.system(size: 11.5)).foregroundStyle(.tertiary)
            }
        }
    }
}

/// Copy or save the redirects in each format.
struct ExportMenu: View {
    @ObservedObject var model: MigrationModel
    let map: MigrationMap
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        if isSnapshot {
            HStack(spacing: 5) {
                Image(systemName: "square.and.arrow.up").font(.system(size: 10.5, weight: .medium))
                Text("Export").font(.system(size: 11.5, weight: .medium))
            }
            .foregroundStyle(.secondary)
        } else {
            Menu {
                Section("Copy") {
                    ForEach(MigrationFormat.allCases, id: \.self) { format in Button(format.title) { model.copy(format) } }
                }
                Section("Save") {
                    ForEach(MigrationFormat.allCases, id: \.self) { format in Button("\(format.title)…") { model.save(format) } }
                }
                Divider()
                Toggle("Leave Out the Ones to Check", isOn: $model.confidentOnly)
            } label: {
                Label(model.copied ? "Copied" : "Export", systemImage: model.copied ? "checkmark" : "square.and.arrow.up")
                    .font(.system(size: 11.5, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(map.redirects().isEmpty && map.stranded == 0)
            .help("Copy or save the redirects")
        }
    }
}
