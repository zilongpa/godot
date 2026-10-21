/**************************************************************************/
/*  godot_visionos_windows.h                                              */
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

#pragma once

// Native windows on visionOS.
//
// Every Godot Window shown as a native window becomes a SwiftUI scene, which
// the engine opens, places and closes. By default the scene shows Godot's
// rendering. An extension can provide the content of selected windows
// instead, for example to show a Window's 3D world as a RealityKit volume.
// Extensions reach this API through NSClassFromString(@"GDTVisionOSWindows")
// and a copy of these declarations, since they do not link against the engine.

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// Matches Window::Placement.
typedef NS_ENUM(NSInteger, GDTWindowPlacement) {
	GDTWindowPlacementAutomatic = 0,
	GDTWindowPlacementUtilityPanel,
	GDTWindowPlacementLeading,
	GDTWindowPlacementTrailing,
	GDTWindowPlacementAbove,
	GDTWindowPlacementBelow,
	// Attached to the target window as an ornament instead of opening a scene.
	GDTWindowPlacementOrnament,
};

// Matches Window::OrnamentAlignment.
typedef NS_ENUM(NSInteger, GDTOrnamentAlignment) {
	GDTOrnamentAlignmentAutomatic = 0,
	GDTOrnamentAlignmentTopLeading,
	GDTOrnamentAlignmentTop,
	GDTOrnamentAlignmentTopTrailing,
	GDTOrnamentAlignmentLeading,
	GDTOrnamentAlignmentCenter,
	GDTOrnamentAlignmentTrailing,
	GDTOrnamentAlignmentBottomLeading,
	GDTOrnamentAlignmentBottom,
	GDTOrnamentAlignmentBottomTrailing,
};

// A point of a window in unit coordinates, as SwiftUI's UnitPoint3D:
// x from leading to trailing, y from top to bottom, z from back to front.
typedef struct {
	double x;
	double y;
	double z;
} GDTUnitPoint3D;

// What a host needs to present one Godot window. Sizes are in points; a zero
// component leaves that dimension to the system.
@interface GDTWindowRequest : NSObject
@property(nonatomic, readonly) uint64_t windowID;
@property(nonatomic, readonly, copy) NSString *title;
@property(nonatomic, readonly) CGSize size;
@property(nonatomic, readonly) CGSize minimumSize;
@property(nonatomic, readonly) CGSize maximumSize;
@property(nonatomic, readonly) BOOL resizable;
@property(nonatomic, readonly) GDTWindowPlacement placement;
// The window to place this one relative to, or nil for the system default.
@property(nonatomic, readonly, nullable) NSNumber *placementTargetID;
// For ornaments: the point of the target they attach to, and how they align to it.
@property(nonatomic, readonly) GDTUnitPoint3D ornamentAnchor;
@property(nonatomic, readonly) GDTOrnamentAlignment ornamentAlignment;

- (instancetype)initWithWindowID:(uint64_t)windowID
						   title:(NSString *)title
							size:(CGSize)size
					 minimumSize:(CGSize)minimumSize
					 maximumSize:(CGSize)maximumSize
					   resizable:(BOOL)resizable
					   placement:(GDTWindowPlacement)placement
			   placementTargetID:(nullable NSNumber *)placementTargetID
				  ornamentAnchor:(GDTUnitPoint3D)ornamentAnchor
			   ornamentAlignment:(GDTOrnamentAlignment)ornamentAlignment;
@end

typedef NS_ENUM(NSInteger, GDTWindowStyle) {
	GDTWindowStylePlain = 0,
	GDTWindowStyleVolumetric,
};

// A volume's size in meters.
typedef struct {
	double width;
	double height;
	double depth;
} GDTVolumeSize;

// Presents windows: the engine's own SwiftUI scenes.
NS_SWIFT_UI_ACTOR
@protocol GDTWindowHost <NSObject>
- (void)openWindow:(GDTWindowRequest *)request;
- (void)closeWindow:(uint64_t)windowID;
@end

// Provides the content of windows an extension presents itself.
NS_SWIFT_UI_ACTOR
@protocol GDTWindowContentProvider <NSObject>
// Called before a window is shown. Return YES to provide its content.
- (BOOL)providesContentForWindow:(uint64_t)windowID;
- (GDTWindowStyle)styleForWindow:(uint64_t)windowID;
// The size a volumetric window first opens with.
- (GDTVolumeSize)volumeSizeForWindow:(uint64_t)windowID;
// A SwiftUI AnyView, boxed as an object, shown while the window is open.
- (id)contentForWindow:(uint64_t)windowID;
// The window's scene has closed, by the game or by the person.
- (void)windowDidClose:(uint64_t)windowID;
@end

NS_SWIFT_UI_ACTOR
@interface GDTVisionOSWindows : NSObject

@property(class, nonatomic, strong, nullable) id<GDTWindowHost> host;
@property(class, nonatomic, strong, nullable) id<GDTWindowContentProvider> contentProvider;

+ (void)openWindow:(GDTWindowRequest *)request;
+ (void)closeWindow:(uint64_t)windowID;
// Tells Godot that the person closed a window whose content is provided.
+ (void)windowClosedByPerson:(uint64_t)windowID;

// The SwiftUI scene identifier presenting a window, used to place other
// windows relative to it.
+ (nullable NSString *)sceneIdentifierForWindow:(uint64_t)windowID;
+ (void)setSceneIdentifier:(nullable NSString *)identifier forWindow:(uint64_t)windowID;

// The request a window was last opened with, while it is open.
+ (nullable GDTWindowRequest *)requestForWindow:(uint64_t)windowID;

@end

NS_ASSUME_NONNULL_END
