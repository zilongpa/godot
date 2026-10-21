/**************************************************************************/
/*  godot_visionos_windows.mm                                             */
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

#import "godot_visionos_windows.h"

#if defined(VISIONOS_ENABLED)

#import "display_server_apple_embedded.h"

@implementation GDTWindowRequest

- (instancetype)initWithWindowID:(uint64_t)windowID
						   title:(NSString *)title
							size:(CGSize)size
					 minimumSize:(CGSize)minimumSize
					 maximumSize:(CGSize)maximumSize
					   resizable:(BOOL)resizable
					   placement:(GDTWindowPlacement)placement
			   placementTargetID:(NSNumber *)placementTargetID
				  ornamentAnchor:(GDTUnitPoint3D)ornamentAnchor
			   ornamentAlignment:(GDTOrnamentAlignment)ornamentAlignment {
	self = [super init];
	if (self) {
		_windowID = windowID;
		_title = [title copy];
		_size = size;
		_minimumSize = minimumSize;
		_maximumSize = maximumSize;
		_resizable = resizable;
		_placement = placement;
		_placementTargetID = placementTargetID;
		_ornamentAnchor = ornamentAnchor;
		_ornamentAlignment = ornamentAlignment;
	}
	return self;
}

@end

static id<GDTWindowHost> window_host = nil;
static id<GDTWindowContentProvider> content_provider = nil;
// Open windows by ID: their request and scene identifier.
static NSMutableDictionary<NSNumber *, GDTWindowRequest *> *open_requests = nil;
static NSMutableDictionary<NSNumber *, NSString *> *scene_identifiers = nil;

@implementation GDTVisionOSWindows

+ (void)initialize {
	if (self == [GDTVisionOSWindows class]) {
		open_requests = [NSMutableDictionary dictionary];
		scene_identifiers = [NSMutableDictionary dictionary];
		// The main window is declared by the app; see GodotWindowScenes.
		scene_identifiers[@0] = @"godot-main";
	}
}

+ (id<GDTWindowHost>)host {
	return window_host;
}

+ (void)setHost:(id<GDTWindowHost>)host {
	window_host = host;
}

+ (id<GDTWindowContentProvider>)contentProvider {
	return content_provider;
}

+ (void)setContentProvider:(id<GDTWindowContentProvider>)provider {
	content_provider = provider;
}

+ (void)openWindow:(GDTWindowRequest *)request {
	open_requests[@(request.windowID)] = request;
	[window_host openWindow:request];
}

+ (void)closeWindow:(uint64_t)windowID {
	[open_requests removeObjectForKey:@(windowID)];
	[window_host closeWindow:windowID];
	if (windowID != 0) {
		[scene_identifiers removeObjectForKey:@(windowID)];
	}
}

+ (void)windowClosedByPerson:(uint64_t)windowID {
	[open_requests removeObjectForKey:@(windowID)];
	if (DisplayServerAppleEmbedded *display = DisplayServerAppleEmbedded::get_singleton()) {
		display->visionos_window_closed_by_person(windowID);
	}
}

+ (NSString *)sceneIdentifierForWindow:(uint64_t)windowID {
	return scene_identifiers[@(windowID)];
}

+ (void)setSceneIdentifier:(NSString *)identifier forWindow:(uint64_t)windowID {
	scene_identifiers[@(windowID)] = identifier;
}

+ (GDTWindowRequest *)requestForWindow:(uint64_t)windowID {
	return open_requests[@(windowID)];
}

@end

#endif
