import ComposableArchitecture
import Inject
import Sparkle
import AppKit
import SwiftUI

@main
struct HexApp: App {
	static let appStore = Store(initialState: AppFeature.State()) {
		AppFeature()
	}

	/// Menu-bar-sized template NSImage built from the `Feather` asset.
	/// The source PNG is white-on-transparent at ~1024×1024; we redraw
	/// it into an 18pt canvas (standard macOS menu-bar glyph size) and
	/// mark it `isTemplate = true` so AppKit colours it with the
	/// current menu-bar foreground. Computed once at app launch.
	static let menuBarIcon: NSImage = {
		let side: CGFloat = 18
		guard let source = NSImage(named: "Feather") else {
			// Fall back to a visible SF Symbol so the status item is
			// never totally blank — signals "asset didn't load".
			return NSImage(
				systemSymbolName: "questionmark.square",
				accessibilityDescription: "Quill"
			) ?? NSImage()
		}
		let scaled = NSImage(size: NSSize(width: side, height: side))
		let rect = NSRect(x: 0, y: 0, width: side, height: side)
		scaled.lockFocus()
		// 1. Draw the feather (white-on-transparent) — this fills the
		//    alpha channel with the feather shape.
		source.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
		// 2. Replace the RGB with pure black wherever alpha > 0. The
		//    canonical macOS template-image format is black + alpha;
		//    some AppKit rendering passes misrender white + alpha in
		//    menu-bar contexts.
		NSColor.black.setFill()
		rect.fill(using: .sourceIn)
		scaled.unlockFocus()
		scaled.isTemplate = true
		return scaled
	}()

	@NSApplicationDelegateAdaptor(HexAppDelegate.self) var appDelegate
  
    var body: some Scene {
        MenuBarExtra {
            CheckForUpdatesView()

            // Copy last transcript to clipboard
            MenuBarCopyLastTranscriptButton()

            Button("Settings...") {
                appDelegate.presentSettingsView()
            }.keyboardShortcut(",")
			
			Divider()
			
			Button("Quit") {
				NSApplication.shared.terminate(nil)
			}.keyboardShortcut("q")
		} label: {
			// Quill nib in the menu bar. Uses `Image(nsImage:)` with an
			// explicitly template-marked `NSImage` — SwiftUI's
			// MenuBarExtra label doesn't reliably honor the asset-
			// catalog `template-rendering-intent` for custom image
			// assets (often renders as a blank slot), and
			// `Image(systemName: "feather")` doesn't work because
			// Apple's SF Symbols catalog has no symbol by that name.
			// Constructing the NSImage ourselves and forcing
			// `isTemplate = true` lets AppKit do the menu-bar tinting
			// that used to "just work" with an SF Symbol.
			Image(nsImage: HexApp.menuBarIcon)
		}


		WindowGroup {}.defaultLaunchBehavior(.suppressed)
			.commands {
				CommandGroup(after: .appInfo) {
					CheckForUpdatesView()

					Button("Settings...") {
						appDelegate.presentSettingsView()
					}.keyboardShortcut(",")
				}

				CommandGroup(replacing: .help) {}
			}
	}
}
