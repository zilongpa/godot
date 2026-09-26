/**************************************************************************/
/*  godot_swiftui_view_controller.swift                                   */
/**************************************************************************/
/*                         This file is part of:                          */
/*                             GODOT ENGINE                               */
/*                        https://godotengine.org                         */
/**************************************************************************/
/* Copyright (c) 2014-present Godot Engine contributors (see AUTHORS.md). */
/* Copyright (c) 2007-2014 Juan Linietsky, Ariel Manzur.                  */
/*                                                                        */
/* Permission is hereby granted, free of charge, to any person obtaining  */
/* a copy of this software and associated documentation files (the        */
/* "Software"), to deal in the Software without restriction, including    */
/* without limitation the rights to use, copy, modify, merge, publish,    */
/* distribute, sublicense, and/or sell copies of the Software, and to     */
/* permit persons to whom the Software is furnished to do so, subject to  */
/* the following conditions:                                              */
/*                                                                        */
/* The above copyright notice and this permission notice shall be         */
/* included in all copies or substantial portions of the Software.        */
/*                                                                        */
/* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,        */
/* EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF     */
/* MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. */
/* IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY   */
/* CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,   */
/* TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE      */
/* SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.                 */
/**************************************************************************/

import SwiftUI
import UIKit

struct GodotSwiftUIViewController: UIViewControllerRepresentable {
	var windowID: UInt64 = 0

	func makeUIViewController(context: Context) -> GDTViewController {
		let viewController = GDTViewController()
		viewController.godotWindowID = Int(windowID)
		if windowID == 0 {
			GDTAppDelegateService.viewController = viewController
		} else {
			#if os(visionOS)
			GodotWindowControllers.register(windowID, controller: viewController)
			#endif
		}
		return viewController
	}

	func updateUIViewController(_ uiViewController: GDTViewController, context: Context) {
		#if os(visionOS)
		if windowID != 0 {
			uiViewController.godotAttachWindowIfReady()
		}
		#endif
	}

	static func dismantleUIViewController(_ uiViewController: GDTViewController, coordinator: ()) {
		#if os(visionOS)
		if uiViewController.godotWindowID != 0 {
			GodotWindowControllers.unregister(UInt64(uiViewController.godotWindowID), controller: uiViewController)
		}
		#endif
	}

}

#if os(visionOS)
@MainActor private enum GodotWindowControllers {
	private final class WeakController {
		weak var value: GDTViewController?

		init(_ controller: GDTViewController) {
			value = controller
		}
	}

	private static var controllers: [UInt64: WeakController] = [:]
	private static var requestedWindows = Set<UInt64>()

	static func request(_ id: UInt64) {
		requestedWindows.insert(id)
	}

	static func dismiss(_ id: UInt64) {
		requestedWindows.remove(id)
	}

	static func isRequested(_ id: UInt64) -> Bool {
		requestedWindows.contains(id)
	}

	static func register(_ id: UInt64, controller: GDTViewController) {
		controllers[id] = WeakController(controller)
	}

	static func attach(_ id: UInt64) {
		controllers[id]?.value?.godotAttachWindowIfReady()
	}

	static func unregister(_ id: UInt64, controller: GDTViewController) {
		if controllers[id]?.value === controller {
			controllers.removeValue(forKey: id)
		}
	}
}

private extension Notification.Name {
	static let godotOpenWindow = Notification.Name("org.godotengine.visionos.openWindow")
	static let godotCloseWindow = Notification.Name("org.godotengine.visionos.closeWindow")
}

@_cdecl("godot_visionos_request_window")
public func godotVisionOSRequestWindow(_ id: UInt64) {
	DispatchQueue.main.async {
		GodotWindowControllers.request(id)
		GodotWindowControllers.attach(id)
		// Renderer integrations may claim the request before the default host opens it.
		let routing = NSMutableDictionary()
		NotificationCenter.default.post(name: .godotOpenWindow, object: id, userInfo: ["routing": routing])
	}
}

@_cdecl("godot_visionos_dismiss_window")
public func godotVisionOSDismissWindow(_ id: UInt64) {
	DispatchQueue.main.async {
		GodotWindowControllers.dismiss(id)
		NotificationCenter.default.post(name: .godotCloseWindow, object: id)
	}
}

private struct GodotPrimaryWindow: View {
	@Environment(\.openWindow) private var openWindow

	var body: some View {
		GodotSwiftUIViewController()
			.ignoresSafeArea()
			.onReceive(NotificationCenter.default.publisher(for: .godotOpenWindow)) { note in
				guard let id = note.object as? UInt64 else { return }
				let routing = note.userInfo?["routing"] as? NSMutableDictionary
				DispatchQueue.main.async {
					guard routing?["claimed"] as? Bool != true else { return }
					guard GodotWindowControllers.isRequested(id) else { return }
					openWindow(id: "godot-2d", value: id)
				}
			}
	}
}

private struct GodotSecondaryWindow: View {
	let id: UInt64
	@Environment(\.dismiss) private var dismiss

	var body: some View {
		GodotSwiftUIViewController(windowID: id)
			.ignoresSafeArea()
			.onAppear {
				if !GodotWindowControllers.isRequested(id) { dismiss() }
			}
			.onReceive(NotificationCenter.default.publisher(for: .godotCloseWindow)) { note in
				if note.object as? UInt64 == id { dismiss() }
			}
	}
}
#endif

struct GodotWindowScene: Scene {
	var body: some Scene {
		#if os(visionOS)
		Window("Godot", id: "godot-main") {
			GodotPrimaryWindow()
		}
		WindowGroup("Godot 2D", id: "godot-2d", for: UInt64.self) { id in
			if let value = id.wrappedValue {
				GodotSecondaryWindow(id: value)
			}
		}
		.defaultSize(width: 960, height: 600)
		.restorationBehavior(.disabled)
		#else
		WindowGroup {
			GodotSwiftUIViewController()
				.ignoresSafeArea()
		}
		#endif
	}
}
