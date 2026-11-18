import LaunchcheckCore
import SwiftUI

/// Gives the window a sensible size the first time it ever opens. After that, wherever the user left it wins.
private struct FirstSize: NSViewRepresentable {
    let width: CGFloat
    let height: CGFloat

    func makeNSView(context: Context) -> NSView { Probe(size: NSSize(width: width, height: height)) }
    func updateNSView(_ view: NSView, context: Context) {}

    final class Probe: NSView {
        let size: NSSize
        init(size: NSSize) {
            self.size = size
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, !UserDefaults.standard.bool(forKey: "sizedForSidebar") else { return }
            UserDefaults.standard.set(true, forKey: "sizedForSidebar")
            DispatchQueue.main.async {
                window.setContentSize(self.size)
                window.center()
            }
        }
    }
}

@main
struct LaunchcheckApp: App {
    @StateObject private var model = AuditModel()

    init() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            let scale = args.firstIndex(of: "--scale").flatMap { $0 + 1 < args.count ? Double(args[$0 + 1]) : nil } ?? 2
            Snapshot.render(to: args[i + 1], scale: CGFloat(scale))
        }
    }

    var body: some Scene {
        Window("Launchcheck", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 900, idealWidth: 1060, minHeight: 580, idealHeight: 720)
                .background(FirstSize(width: 1060, height: 720))
                // launchcheck://open?site=example.com, from Launchwatch or anything else.
                .onOpenURL { model.open(link: $0) }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1060, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Report") {
                Button("Check Again") { model.start() }
                    .keyboardShortcut("r")
                    .disabled(model.isRunning || model.address.isEmpty || model.mode == .migrate)
                Button(model.mode == .migrate ? "Check a Site" : "Move a Site") { model.mode = model.mode == .migrate ? .check : .migrate }
                    .keyboardShortcut("m", modifiers: [.command, .shift])
                Divider()
                ForEach(Array(AuditModel.Tab.allCases.enumerated()), id: \.offset) { index, tab in
                    Button(tab.rawValue) {
                        model.mode = .check
                        model.tab = tab
                    }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
                        .disabled(model.report == nil || model.isRunning)
                }
                Divider()
                Button(model.selectedIssue.map(model.checklist.isHandled) == true ? "Mark as Not Handled" : "Mark as Handled") {
                    if let issue = model.selectedIssue { model.toggleHandled(issue) }
                }
                .keyboardShortcut("d")
                .disabled(model.report == nil || model.isRunning || model.mode == .migrate || model.tab != .issues || model.selectedIssue == nil)
                Divider()
                Button("Copy as Markdown") { model.copyMarkdown() }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .disabled(model.report == nil)
                Button("Save as Markdown…") { model.save(json: false) }
                    .keyboardShortcut("s")
                    .disabled(model.report == nil)
                Button("Save as HTML…") { model.save(as: .html) }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(model.report == nil)
                Button("Save as JSON…") { model.save(json: true) }
                    .disabled(model.report == nil)
                Divider()
                Button("Delete This Check") { if let report = model.report { model.delete(report) } }
                    .disabled(model.report == nil || model.isRunning)
                Button("Delete Site…") { if let host = model.report?.host { model.removal = .site(host) } }
                    .disabled(model.report == nil || model.isRunning)
                Button("Delete All Sites…") { model.removal = .everything }
                    .disabled(model.sites.isEmpty || model.isRunning)
            }
        }
    }
}
