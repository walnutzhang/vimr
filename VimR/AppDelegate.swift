/**
 * Tae Won Ha - http://taewon.de - @hataewon
 * See LICENSE
 */

import Cocoa
import RxSwift
import PureLayout
import Sparkle

/// Keep the rawValues in sync with Action in the `vimr` Python script.
fileprivate enum VimRUrlAction: String {
  case activate = "activate"
  case open = "open"
  case newWindow = "open-in-new-window"
  case separateWindows = "open-in-separate-windows"
}

fileprivate let filePrefix = "file="
fileprivate let cwdPrefix = "cwd="

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate {

  enum Action {

    case newMainWindow(urls: [URL], cwd: URL)
    case openInKeyWindow(urls: [URL], cwd: URL)

    case preferences

    case cancelQuit
    case quitWithoutSaving
    case quit
  }

  @IBOutlet var debugMenu: NSMenuItem?
  @IBOutlet var updater: SUUpdater?

  override init() {
    let baseServerUrl = URL(string: "http://localhost:\(NetUtils.openPort())")!

    var initialAppState: AppState
    if let stateDict = UserDefaults.standard.value(forKey: PrefService.compatibleVersion) as? [String: Any] {
      initialAppState = AppState(dict: stateDict) ?? .default
    } else {
      if let oldDict = UserDefaults.standard.value(forKey: PrefService.lastCompatibleVersion) as? [String: Any] {
        initialAppState = Pref128ToCurrentConverter.appState(from: oldDict)
      } else {
        initialAppState = .default
      }
    }
    initialAppState.mainWindowTemplate.htmlPreview.server
      = Marked(baseServerUrl.appendingPathComponent(HtmlPreviewToolReducer.selectFirstPath))

    self.stateContext = Context(baseServerUrl: baseServerUrl, state: initialAppState)
    self.emit = self.stateContext.actionEmitter.typedEmit()

    self.openNewMainWindowOnLaunch = initialAppState.openNewMainWindowOnLaunch
    self.openNewMainWindowOnReactivation = initialAppState.openNewMainWindowOnReactivation
    self.useSnapshot = initialAppState.useSnapshotUpdate

    let source = self.stateContext.stateSource
    self.uiRoot = UiRoot(source: source, emitter: self.stateContext.actionEmitter, state: initialAppState)

    super.init()

    source
      .observeOn(MainScheduler.instance)
      .subscribe(onNext: { appState in
        self.hasMainWindows = !appState.mainWindows.isEmpty
        self.hasDirtyWindows = appState.mainWindows.values.reduce(false) { $1.isDirty ? true : $0 }

        self.openNewMainWindowOnLaunch = appState.openNewMainWindowOnLaunch
        self.openNewMainWindowOnReactivation = appState.openNewMainWindowOnReactivation

        if self.useSnapshot != appState.useSnapshotUpdate {
          self.useSnapshot = appState.useSnapshotUpdate
          self.setSparkleUrl(self.useSnapshot)
        }
      })
      .disposed(by: self.disposeBag)
  }

  fileprivate let stateContext: Context
  fileprivate let emit: (Action) -> Void

  fileprivate let uiRoot: UiRoot

  fileprivate var hasDirtyWindows = false
  fileprivate var hasMainWindows = false

  fileprivate var openNewMainWindowOnLaunch: Bool
  fileprivate var openNewMainWindowOnReactivation: Bool
  fileprivate var useSnapshot: Bool

  fileprivate let disposeBag = DisposeBag()

  fileprivate var launching = true

  fileprivate func setSparkleUrl(_ snapshot: Bool) {
    if snapshot {
      self.updater?.feedURL = URL(
        string: "https://raw.githubusercontent.com/qvacua/vimr/develop/appcast_snapshot.xml"
      )
    } else {
      self.updater?.feedURL = URL(
        string: "https://raw.githubusercontent.com/qvacua/vimr/master/appcast.xml"
      )
    }
  }
}

// MARK: - NSApplicationDelegate
extension AppDelegate {

  func applicationWillFinishLaunching(_: Notification) {
    self.launching = true

    let appleEventManager = NSAppleEventManager.shared()
    appleEventManager.setEventHandler(self,
                                      andSelector: #selector(AppDelegate.handle(getUrlEvent:replyEvent:)),
                                      forEventClass: UInt32(kInternetEventClass),
                                      andEventID: UInt32(kAEGetURL))
  }

  func applicationDidFinishLaunching(_: Notification) {
    self.launching = false

#if DEBUG
    self.debugMenu?.isHidden = false
#endif
  }

  func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
    if self.launching {
      if self.openNewMainWindowOnLaunch {
        self.newDocument(self)
        return true
      }
    } else {
      if self.openNewMainWindowOnReactivation {
        self.newDocument(self)
        return true
      }
    }

    return false
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplicationTerminateReply {
    if self.hasDirtyWindows && self.uiRoot.hasMainWindows {
      let alert = NSAlert()
      alert.addButton(withTitle: "Cancel")
      alert.addButton(withTitle: "Discard and Quit")
      alert.messageText = "There are windows with unsaved buffers!"
      alert.alertStyle = .warning

      if alert.runModal() == NSAlertSecondButtonReturn {
        self.emit(.quitWithoutSaving)
      } else {
        self.emit(.cancelQuit)
      }

      return .terminateCancel
    }

    if self.uiRoot.hasMainWindows {
      self.emit(.quit)

      return .terminateCancel
    }

    // There are no open main window, then just quit.
    return .terminateNow
  }

  // For drag & dropping files on the App icon.
  func application(_ sender: NSApplication, openFiles filenames: [String]) {
    let urls = filenames.map { URL(fileURLWithPath: $0) }
    self.emit(.newMainWindow(urls: urls, cwd: FileUtils.userHomeUrl))

    sender.reply(toOpenOrPrint: .success)
  }
}

// MARK: - AppleScript
extension AppDelegate {

  func handle(getUrlEvent event: NSAppleEventDescriptor, replyEvent: NSAppleEventDescriptor) {
    guard let urlString = event.paramDescriptor(forKeyword: UInt32(keyDirectObject))?.stringValue else {
      return
    }

    guard let url = URL(string: urlString) else {
      return
    }

    guard url.scheme == "vimr" else {
      return
    }

    guard let rawAction = url.host else {
      return
    }

    guard let action = VimRUrlAction(rawValue: rawAction) else {
      return
    }

    let queryParams = url.query?.components(separatedBy: "&")
    let urls = queryParams?
                 .filter { $0.hasPrefix(filePrefix) }
                 .flatMap { $0.without(prefix: filePrefix).removingPercentEncoding }
                 .map { URL(fileURLWithPath: $0) } ?? []
    let cwd = queryParams?
                .filter { $0.hasPrefix(cwdPrefix) }
                .flatMap { $0.without(prefix: cwdPrefix).removingPercentEncoding }
                .map { URL(fileURLWithPath: $0) }
                .first ?? FileUtils.userHomeUrl

    switch action {

    case .activate, .newWindow:
      self.emit(.newMainWindow(urls: urls, cwd: cwd))

    case .open:
      self.emit(.openInKeyWindow(urls: urls, cwd: cwd))

    case .separateWindows:
      urls.forEach { self.emit(.newMainWindow(urls: [$0], cwd: cwd)) }

    }
  }
}

// MARK: - IBActions
extension AppDelegate {

  @IBAction func newDocument(_ sender: Any?) {
    self.emit(.newMainWindow(urls: [], cwd: FileUtils.userHomeUrl))
  }

  @IBAction func openInNewWindow(_ sender: Any?) {
    self.openDocument(sender)
  }

  @IBAction func showPrefWindow(_ sender: Any?) {
    self.emit(.preferences)
  }

  // Invoked when no main window is open.
  @IBAction func openDocument(_: Any?) {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = true
    panel.begin { result in
      guard result == NSFileHandlingPanelOKButton else {
        return
      }

      let urls = panel.urls
      let commonParentUrl = FileUtils.commonParent(of: urls)

      self.emit(.newMainWindow(urls: urls, cwd: commonParentUrl))
    }
  }
}
