/**************************************************************************/
/*  godot_window_host_visionos.swift                                      */
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

import Observation
import SwiftUI
import UIKit

// MARK: Placement

/// Resolves a window request into a SwiftUI placement. Used by every host:
/// SwiftUI identifies windows only by scene identifier, which is why each
/// open Godot window owns a scene identifier of its own.
@MainActor
enum GodotWindowPlacement {
	static func resolve(_ request: GDTWindowRequest?, in context: WindowPlacementContext) -> WindowPlacement {
		guard let request else { return WindowPlacement() }
		let size: CGSize? = request.size.width > 0 && request.size.height > 0 ? request.size : nil
		return WindowPlacement(position(for: request, in: context), size: size)
	}

	/// Volumes are sized in meters; SwiftUI sizes them in points.
	static func resolveVolume(_ request: GDTWindowRequest?, in context: WindowPlacementContext) -> WindowPlacement {
		guard let request, let provider = GDTVisionOSWindows.contentProvider else { return WindowPlacement() }
		let meters = provider.volumeSize(forWindow: request.windowID)
		guard meters.width > 0, meters.height > 0, meters.depth > 0 else {
			return WindowPlacement(position(for: request, in: context))
		}
		let size = Size3D(width: meters.width * pointsPerMeter, height: meters.height * pointsPerMeter, depth: meters.depth * pointsPerMeter)
		return WindowPlacement(position(for: request, in: context), size3D: size)
	}

	// Volumetric windows use a fixed scale between points and meters.
	private static let pointsPerMeter = 1360.0

	private static func position(for request: GDTWindowRequest, in context: WindowPlacementContext) -> WindowPlacement.Position? {
		if request.placement == .utilityPanel {
			return .utilityPanel
		}
		guard let target = request.placementTargetID,
				let identifier = GDTVisionOSWindows.sceneIdentifier(forWindow: target.uint64Value),
				let window = context.windows.first(where: { $0.id == identifier }) else {
			return nil
		}
		switch request.placement {
			case .leading: return .leading(window)
			case .trailing: return .trailing(window)
			case .above: return .above(window)
			case .below: return .below(window)
			default: return nil
		}
	}
}

// MARK: Slots

/// A scene for one Godot window: plain windows show Godot's rendering or
/// an extension's content; volumetric windows show an extension's content.
struct GodotWindowSlot: Hashable {
	static let plainCount = 8
	static let volumetricCount = 4

	let style: GDTWindowStyle
	let index: Int

	var sceneIdentifier: String {
		style == .volumetric ? "godot-volume-\(index)" : "godot-2d-\(index)"
	}

	static func all(_ style: GDTWindowStyle) -> [GodotWindowSlot] {
		(0..<(style == .volumetric ? volumetricCount : plainCount)).map { GodotWindowSlot(style: style, index: $0) }
	}
}

// MARK: Ornaments

extension GDTWindowPlacement {
	var isOrnament: Bool {
		self == .ornament
	}
}

/// Godot windows shown as ornaments of other windows, instead of in a scene.
/// Each window has a fixed number of ornament slots: SwiftUI views need a
/// fixed set of modifiers to keep the window's content and its state.
@MainActor
@Observable
final class GodotOrnaments {
	static let shared = GodotOrnaments()
	static let slotCount = 8

	// By the window they are attached to, then by slot.
	private var byTarget: [UInt64: [Int: GDTWindowRequest]] = [:]

	func add(_ request: GDTWindowRequest) {
		let target = request.placementTargetID?.uint64Value ?? 0
		var slots = byTarget[target, default: [:]]
		guard let slot = (0..<Self.slotCount).first(where: { slots[$0] == nil }) else {
			NSLog("Godot: cannot show ornament \(request.windowID); a window has at most \(Self.slotCount) ornaments.")
			return
		}
		slots[slot] = request
		byTarget[target] = slots
	}

	func remove(_ windowID: UInt64) -> Bool {
		for (target, slots) in byTarget {
			if let slot = slots.first(where: { $0.value.windowID == windowID })?.key {
				byTarget[target]?.removeValue(forKey: slot)
				return true
			}
		}
		return false
	}

	func ornament(on target: UInt64, slot: Int) -> GDTWindowRequest? {
		byTarget[target]?[slot]
	}
}

/// Shows the ornaments attached to a Godot window.
struct GodotOrnamentModifier: ViewModifier {
	let windowID: UInt64
	let volumetric: Bool

	func body(content: Content) -> some View {
		content
			.modifier(Slot(windowID: windowID, slot: 0, volumetric: volumetric))
			.modifier(Slot(windowID: windowID, slot: 1, volumetric: volumetric))
			.modifier(Slot(windowID: windowID, slot: 2, volumetric: volumetric))
			.modifier(Slot(windowID: windowID, slot: 3, volumetric: volumetric))
			.modifier(Slot(windowID: windowID, slot: 4, volumetric: volumetric))
			.modifier(Slot(windowID: windowID, slot: 5, volumetric: volumetric))
			.modifier(Slot(windowID: windowID, slot: 6, volumetric: volumetric))
			.modifier(Slot(windowID: windowID, slot: 7, volumetric: volumetric))
	}

	private struct Slot: ViewModifier {
		let windowID: UInt64
		let slot: Int
		let volumetric: Bool

		func body(content: Content) -> some View {
			let request = GodotOrnaments.shared.ornament(on: windowID, slot: slot)
			let anchor = request?.ornamentAnchor ?? GDTUnitPoint3D(x: 0.5, y: 1, z: 1)
			content.ornament(visibility: request == nil ? .hidden : .visible,
					attachmentAnchor: volumetric ? .scene(UnitPoint3D(x: anchor.x, y: anchor.y, z: anchor.z)) : .scene(UnitPoint(x: anchor.x, y: anchor.y)),
					contentAlignment: Self.alignment(request?.ornamentAlignment ?? .automatic, anchor: anchor)) {
				if let request {
					GodotSwiftUIViewController(windowID: request.windowID)
						.frame(width: request.size.width, height: request.size.height)
						.glassBackgroundEffect()
				}
			}
		}

		/// Automatic alignment keeps the ornament outside the window: content
		/// at the bottom edge hangs below it, at the leading edge sits before it.
		private static func alignment(_ alignment: GDTOrnamentAlignment, anchor: GDTUnitPoint3D) -> Alignment3D {
			func side(_ value: Double) -> Int { value < 0.5 - 0.001 ? -1 : (value > 0.5 + 0.001 ? 1 : 0) }
			let depth: DepthAlignment = anchor.z < 0.5 ? .front : .back
			var horizontal: HorizontalAlignment
			var vertical: VerticalAlignment
			switch alignment {
				case .topLeading: (horizontal, vertical) = (.leading, .top)
				case .top: (horizontal, vertical) = (.center, .top)
				case .topTrailing: (horizontal, vertical) = (.trailing, .top)
				case .leading: (horizontal, vertical) = (.leading, .center)
				case .center: (horizontal, vertical) = (.center, .center)
				case .trailing: (horizontal, vertical) = (.trailing, .center)
				case .bottomLeading: (horizontal, vertical) = (.leading, .bottom)
				case .bottom: (horizontal, vertical) = (.center, .bottom)
				case .bottomTrailing: (horizontal, vertical) = (.trailing, .bottom)
				default:
					horizontal = [HorizontalAlignment.trailing, .center, .leading][side(anchor.x) + 1]
					vertical = [VerticalAlignment.bottom, .center, .top][side(anchor.y) + 1]
			}
			return Alignment3D(horizontal: horizontal, vertical: vertical, depth: depth)
		}
	}
}

// MARK: Host

/// Opens, places and closes Godot's native windows. Each open window takes a
/// free slot of its style until its scene disconnects.
@MainActor
final class GodotWindowHost: NSObject, GDTWindowHost {
	static let shared = GodotWindowHost()

	// openWindow actions of the Godot windows currently presented. SwiftUI
	// places only windows opened this way, so any live window can open others.
	// A destroyed scene's views do not always disappear first, so each action
	// is also dropped when its window's scene disconnects.
	private var openers: [(token: UUID, windowID: UInt64, action: OpenWindowAction)] = []

	func registerOpener(_ action: OpenWindowAction, token: UUID, windowID: UInt64) {
		openers.removeAll { $0.token == token }
		openers.append((token, windowID, action))
	}

	func unregisterOpener(token: UUID) {
		openers.removeAll { $0.token == token }
	}

	// The main window's action when it is presented: it outlives the others.
	private var opener: OpenWindowAction? {
		(openers.first { $0.windowID == 0 } ?? openers.last)?.action
	}

	private var windowsBySlot: [GodotWindowSlot: UInt64] = [:]
	private var slotsByWindow: [UInt64: GodotWindowSlot] = [:]
	private var scenes: [UInt64: UIWindowScene] = [:]
	// Windows whose content an extension provides, and windows the game closed.
	private var provided = Set<UInt64>()
	// Each provided window's content, made once: SwiftUI evaluates the window's
	// body often, and the content must keep its identity and state.
	private var providedContent: [UInt64: AnyView] = [:]
	private var closing = Set<UInt64>()
	private var disconnectObserver: NSObjectProtocol?

	private override init() {
		super.init()
		disconnectObserver = NotificationCenter.default.addObserver(forName: UIScene.didDisconnectNotification, object: nil, queue: .main) { notification in
			guard let scene = notification.object as? UIWindowScene else { return }
			let identifier = ObjectIdentifier(scene)
			MainActor.assumeIsolated {
				GodotWindowHost.shared.sceneDisconnected(identifier)
			}
		}
	}

	func openWindow(_ request: GDTWindowRequest) {
		let windowID = request.windowID
		if request.placement.isOrnament {
			GodotOrnaments.shared.add(request)
			return
		}
		guard slotsByWindow[windowID] == nil else { return }
		let provider = GDTVisionOSWindows.contentProvider
		let isProvided = provider?.providesContent(forWindow: windowID) ?? false
		let style = isProvided ? provider!.style(forWindow: windowID) : .plain
		guard let slot = GodotWindowSlot.all(style).first(where: { windowsBySlot[$0] == nil }) else {
			NSLog("Godot: cannot open window \(windowID); all \(style == .volumetric ? "volumetric" : "plain") window slots are in use.")
			return
		}
		guard let open = opener else {
			NSLog("Godot: cannot open window \(windowID) while no Godot window is presented.")
			return
		}
		windowsBySlot[slot] = windowID
		slotsByWindow[windowID] = slot
		if isProvided {
			provided.insert(windowID)
		}
		GDTVisionOSWindows.setSceneIdentifier(slot.sceneIdentifier, forWindow: windowID)
		open(id: slot.sceneIdentifier, value: windowID)
	}

	func closeWindow(_ windowID: UInt64) {
		if GodotOrnaments.shared.remove(windowID) {
			return
		}
		if let scene = scenes[windowID] {
			// The slot is released once the scene disconnects.
			closing.insert(windowID)
			UIApplication.shared.requestSceneSessionDestruction(scene.session, options: nil)
		} else if slotsByWindow[windowID] != nil {
			// Not presented yet; its scene dismisses itself when it appears.
			release(windowID)
		}
	}

	func isOpen(_ windowID: UInt64, slot: GodotWindowSlot) -> Bool {
		windowsBySlot[slot] == windowID
	}

	func isProvided(_ windowID: UInt64) -> Bool {
		provided.contains(windowID)
	}

	func providedContent(for windowID: UInt64) -> AnyView {
		if let content = providedContent[windowID] {
			return content
		}
		let made = GDTVisionOSWindows.contentProvider?.content(forWindow: windowID)
		let content = (made as? AnyView) ?? AnyView(EmptyView())
		providedContent[windowID] = content
		return content
	}

	func attach(_ scene: UIWindowScene, windowID: UInt64, slot: GodotWindowSlot) {
		guard isOpen(windowID, slot: slot) else {
			UIApplication.shared.requestSceneSessionDestruction(scene.session, options: nil)
			return
		}
		scenes[windowID] = scene
	}

	private func sceneDisconnected(_ identifier: ObjectIdentifier) {
		guard let windowID = scenes.first(where: { ObjectIdentifier($0.value) == identifier })?.key else { return }
		scenes.removeValue(forKey: windowID)
		openers.removeAll { $0.windowID == windowID }
		let closedByGame = closing.remove(windowID) != nil
		let wasProvided = provided.contains(windowID)
		release(windowID)
		if wasProvided {
			GDTVisionOSWindows.contentProvider?.windowDidClose(windowID)
			// Godot learns about its own windows from their view controllers.
			if !closedByGame {
				GDTVisionOSWindows.windowClosed(byPerson: windowID)
			}
		}
	}

	private func release(_ windowID: UInt64) {
		if let slot = slotsByWindow.removeValue(forKey: windowID) {
			windowsBySlot.removeValue(forKey: slot)
		}
		provided.remove(windowID)
		providedContent.removeValue(forKey: windowID)
	}

	func request(slot: GodotWindowSlot) -> GDTWindowRequest? {
		windowsBySlot[slot].flatMap { GDTVisionOSWindows.request(forWindow: $0) }
	}
}

// MARK: Scenes

/// Reports the UIWindowScene a SwiftUI view is presented in.
struct GodotSceneReader: UIViewRepresentable {
	let onScene: @MainActor (UIWindowScene) -> Void

	final class Probe: UIView {
		var onScene: (@MainActor (UIWindowScene) -> Void)?

		override func didMoveToWindow() {
			super.didMoveToWindow()
			if let scene = window?.windowScene {
				onScene?(scene)
			}
		}
	}

	func makeUIView(context: Context) -> Probe {
		let probe = Probe()
		probe.isUserInteractionEnabled = false
		probe.onScene = onScene
		return probe
	}

	func updateUIView(_ probe: Probe, context: Context) {
		probe.onScene = onScene
	}
}

/// Registers the presenting window's openWindow action with GodotWindowHost.
struct GodotWindowOpener: ViewModifier {
	let windowID: UInt64

	@Environment(\.openWindow) private var openWindow
	@State private var token = UUID()

	func body(content: Content) -> some View {
		content
			.onAppear { GodotWindowHost.shared.registerOpener(openWindow, token: token, windowID: windowID) }
			.onDisappear { GodotWindowHost.shared.unregisterOpener(token: token) }
	}
}

private struct GodotHostedWindow: View {
	let slot: GodotWindowSlot
	let windowID: UInt64?

	var body: some View {
		if let windowID {
			content(windowID)
				.modifier(GodotOrnamentModifier(windowID: windowID, volumetric: slot.style == .volumetric))
				.modifier(GodotWindowOpener(windowID: windowID))
				.background(GodotSceneReader { scene in
					GodotWindowHost.shared.attach(scene, windowID: windowID, slot: slot)
				})
		}
	}

	private func content(_ windowID: UInt64) -> AnyView {
		if GodotWindowHost.shared.isProvided(windowID) {
			return GodotWindowHost.shared.providedContent(for: windowID)
		}
		return AnyView(GodotSwiftUIViewController(windowID: windowID).ignoresSafeArea())
	}
}

private struct GodotPlainWindowScene: Scene {
	let slot: GodotWindowSlot

	var body: some Scene {
		WindowGroup(id: slot.sceneIdentifier, for: UInt64.self) { $windowID in
			GodotHostedWindow(slot: slot, windowID: windowID)
		}
		.defaultWindowPlacement { _, context in
			GodotWindowPlacement.resolve(GodotWindowHost.shared.request(slot: slot), in: context)
		}
		.restorationBehavior(.disabled)
	}
}

private struct GodotVolumetricWindowScene: Scene {
	let slot: GodotWindowSlot

	var body: some Scene {
		WindowGroup(id: slot.sceneIdentifier, for: UInt64.self) { $windowID in
			GodotHostedWindow(slot: slot, windowID: windowID)
		}
		.windowStyle(.volumetric)
		// The content sets the volume's size in meters.
		.windowResizability(.contentSize)
		.defaultWindowPlacement { _, context in
			GodotWindowPlacement.resolveVolume(GodotWindowHost.shared.request(slot: slot), in: context)
		}
		.restorationBehavior(.disabled)
	}
}

// MARK: Main window

/// How the main window opens, written to Info.plist on export: visionOS sizes
/// a window when it opens, so Godot can't resize it afterwards without a jump.
enum GodotMainWindow {
	/// The project's window size, in points.
	static let defaultSize: CGSize = {
		let info = Bundle.main.infoDictionary?["GodotMainWindow"] as? [String: Any]
		let width = info?["Width"] as? Double ?? 0
		let height = info?["Height"] as? Double ?? 0
		// visionOS's own default.
		return width > 0 && height > 0 ? CGSize(width: width, height: height) : CGSize(width: 1280, height: 720)
	}()
}

/// The main window and the scenes for other Godot windows.
struct GodotWindowScenes: Scene {
	private static let plain = GodotWindowSlot.all(.plain)
	private static let volumetric = GodotWindowSlot.all(.volumetric)

	var body: some Scene {
		Window("Godot", id: "godot-main") {
			GodotSwiftUIViewController()
				.ignoresSafeArea()
				.modifier(GodotOrnamentModifier(windowID: 0, volumetric: false))
				.modifier(GodotWindowOpener(windowID: 0))
		}
		.defaultSize(GodotMainWindow.defaultSize)
		Group {
			GodotPlainWindowScene(slot: Self.plain[0])
			GodotPlainWindowScene(slot: Self.plain[1])
			GodotPlainWindowScene(slot: Self.plain[2])
			GodotPlainWindowScene(slot: Self.plain[3])
			GodotPlainWindowScene(slot: Self.plain[4])
			GodotPlainWindowScene(slot: Self.plain[5])
			GodotPlainWindowScene(slot: Self.plain[6])
			GodotPlainWindowScene(slot: Self.plain[7])
		}
		Group {
			GodotVolumetricWindowScene(slot: Self.volumetric[0])
			GodotVolumetricWindowScene(slot: Self.volumetric[1])
			GodotVolumetricWindowScene(slot: Self.volumetric[2])
			GodotVolumetricWindowScene(slot: Self.volumetric[3])
		}
	}
}
