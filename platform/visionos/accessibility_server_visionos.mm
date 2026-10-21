/**************************************************************************/
/*  accessibility_server_visionos.mm                                      */
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

#import "accessibility_server_visionos.h"

#include "servers/display/display_server.h"

#import <UIKit/UIKit.h>

// Native hover regions of one window's Godot view, in the view's pixels.
@interface GDTHoverHost : NSObject
@property(nonatomic, weak) UIView *view;
- (void)updateTargets:(NSDictionary<NSNumber *, NSValue *> *)targets;
- (void)removeAll;
@end

@implementation GDTHoverHost {
	NSMutableDictionary<NSNumber *, UIHoverEffectLayer *> *_layers;
	// The shape each hover layer highlights; UIHoverEffectLayer adds sublayers of its own.
	NSMutableDictionary<NSNumber *, CAShapeLayer *> *_shapes;
}

- (instancetype)init {
	self = [super init];
	if (self) {
		_layers = [NSMutableDictionary dictionary];
		_shapes = [NSMutableDictionary dictionary];
	}
	return self;
}

- (void)updateTargets:(NSDictionary<NSNumber *, NSValue *> *)targets {
	UIView *view = self.view;
	if (!view) {
		[self removeAll];
		return;
	}
	const CGFloat scale = view.contentScaleFactor > 0 ? view.contentScaleFactor : 1.0;

	// Join the frame's implicit transaction instead of committing our own:
	// an explicit commit here flushes every change made so far this frame,
	// including half-applied RealityKit content, which then blinks.
	[CATransaction setDisableActions:YES];
	for (NSNumber *key in _layers.allKeys) {
		if (!targets[key]) {
			[_layers[key] removeFromSuperlayer];
			[_layers removeObjectForKey:key];
			[_shapes removeObjectForKey:key];
		}
	}
	[targets enumerateKeysAndObjectsUsingBlock:^(NSNumber *key, NSValue *value, BOOL *stop) {
		const CGRect pixels = value.CGRectValue;
		const CGRect frame = CGRectMake(pixels.origin.x / scale, pixels.origin.y / scale, pixels.size.width / scale, pixels.size.height / scale);
		UIHoverEffectLayer *layer = self->_layers[key];
		if (!layer) {
			UIShape *shape = [UIShape rectShapeWithCornerRadius:MIN(8.0, MIN(frame.size.width, frame.size.height) / 2.0)];
			layer = [[UIHoverEffectLayer alloc] initWithContainerView:view style:[UIHoverStyle styleWithEffect:[UIHoverHighlightEffect effect] shape:shape]];
			// The effect applies to the layer's content; a faint fill supplies it
			// without copying Godot's rendering.
			CAShapeLayer *content = [CAShapeLayer layer];
			content.fillColor = [UIColor colorWithWhite:1.0 alpha:0.01].CGColor;
			[layer addSublayer:content];
			[view.layer addSublayer:layer];
			self->_layers[key] = layer;
			self->_shapes[key] = content;
		}
		if (!CGRectEqualToRect(layer.frame, frame)) {
			layer.frame = frame;
			CAShapeLayer *content = self->_shapes[key];
			content.frame = layer.bounds;
			content.path = [UIBezierPath bezierPathWithRoundedRect:layer.bounds cornerRadius:MIN(8.0, MIN(frame.size.width, frame.size.height) / 2.0)].CGPath;
		}
	}];
}

- (void)removeAll {
	for (UIHoverEffectLayer *layer in _layers.allValues) {
		[layer removeFromSuperlayer];
	}
	[_layers removeAllObjects];
	[_shapes removeAllObjects];
}

@end

// MARK: Server

AccessibilityServer *AccessibilityServerVisionOS::create_func(Error &r_error) {
	r_error = OK;
	return memnew(AccessibilityServerVisionOS);
}

void AccessibilityServerVisionOS::register_create_func() {
	register_create_function("visionos", create_func);
}

AccessibilityServerVisionOS::~AccessibilityServerVisionOS() {
	for (const KeyValue<DisplayServerEnums::WindowID, void *> &host : hover_hosts) {
		GDTHoverHost *object = (__bridge_transfer GDTHoverHost *)host.value;
		[object removeAll];
	}
	hover_hosts.clear();
	for (const RID &rid : elements.get_owned_list()) {
		memdelete(elements.get_or_null(rid));
	}
}

bool AccessibilityServerVisionOS::_is_interactive(AccessibilityServerEnums::AccessibilityRole p_role) {
	switch (p_role) {
		case AccessibilityServerEnums::ROLE_BUTTON:
		case AccessibilityServerEnums::ROLE_DEFAULT_BUTTON:
		case AccessibilityServerEnums::ROLE_LINK:
		case AccessibilityServerEnums::ROLE_CHECK_BOX:
		case AccessibilityServerEnums::ROLE_RADIO_BUTTON:
		case AccessibilityServerEnums::ROLE_CHECK_BUTTON:
		case AccessibilityServerEnums::ROLE_SCROLL_BAR:
		case AccessibilityServerEnums::ROLE_SLIDER:
		case AccessibilityServerEnums::ROLE_SPIN_BUTTON:
		case AccessibilityServerEnums::ROLE_TEXT_FIELD:
		case AccessibilityServerEnums::ROLE_MULTILINE_TEXT_FIELD:
		case AccessibilityServerEnums::ROLE_COLOR_PICKER:
		case AccessibilityServerEnums::ROLE_TREE_ITEM:
		case AccessibilityServerEnums::ROLE_LIST_ITEM:
		case AccessibilityServerEnums::ROLE_LIST_BOX_OPTION:
		case AccessibilityServerEnums::ROLE_TAB:
		case AccessibilityServerEnums::ROLE_MENU_ITEM:
		case AccessibilityServerEnums::ROLE_MENU_ITEM_CHECK_BOX:
		case AccessibilityServerEnums::ROLE_MENU_ITEM_RADIO:
			return true;
		default:
			return false;
	}
}

// MARK: Windows

bool AccessibilityServerVisionOS::window_create(DisplayServerEnums::WindowID p_window_id, void *p_handle) {
	window_destroy(p_window_id);
	Element *root = memnew(Element);
	root->window = p_window_id;
	root->role = AccessibilityServerEnums::ROLE_WINDOW;
	window_roots[p_window_id] = elements.make_rid(root);
	return true;
}

void AccessibilityServerVisionOS::window_destroy(DisplayServerEnums::WindowID p_window_id) {
	if (void **host = hover_hosts.getptr(p_window_id)) {
		GDTHoverHost *object = (__bridge_transfer GDTHoverHost *)*host;
		[object removeAll];
		hover_hosts.erase(p_window_id);
	}
	if (const RID *root = window_roots.getptr(p_window_id)) {
		_free_tree(*root);
		window_roots.erase(p_window_id);
	}
}

void AccessibilityServerVisionOS::_free_tree(const RID &p_id) {
	Element *element = elements.get_or_null(p_id);
	if (!element) {
		return;
	}
	for (const RID &sub : element->sub_elements) {
		_free_tree(sub);
	}
	elements.free(p_id);
	memdelete(element);
}

RID AccessibilityServerVisionOS::get_window_root(DisplayServerEnums::WindowID p_window_id) const {
	const RID *root = window_roots.getptr(p_window_id);
	return root ? *root : RID();
}

// MARK: Elements

RID AccessibilityServerVisionOS::create_element(DisplayServerEnums::WindowID p_window_id, AccessibilityServerEnums::AccessibilityRole p_role) {
	Element *element = memnew(Element);
	element->window = p_window_id;
	element->role = p_role;
	return elements.make_rid(element);
}

RID AccessibilityServerVisionOS::create_sub_element(const RID &p_parent_rid, AccessibilityServerEnums::AccessibilityRole p_role, int p_insert_pos) {
	Element *parent = elements.get_or_null(p_parent_rid);
	ERR_FAIL_NULL_V(parent, RID());
	Element *element = memnew(Element);
	element->window = parent->window;
	element->role = p_role;
	element->parent = p_parent_rid;
	const RID rid = elements.make_rid(element);
	if (p_insert_pos < 0 || p_insert_pos >= (int)parent->sub_elements.size()) {
		parent->sub_elements.push_back(rid);
	} else {
		parent->sub_elements.insert(p_insert_pos, rid);
	}
	return rid;
}

bool AccessibilityServerVisionOS::has_element(const RID &p_id) const {
	return elements.owns(p_id);
}

void AccessibilityServerVisionOS::free_element(const RID &p_id) {
	Element *element = elements.get_or_null(p_id);
	if (!element) {
		return;
	}
	if (Element *parent = elements.get_or_null(element->parent)) {
		parent->sub_elements.erase(p_id);
	}
	_free_tree(p_id);
}

AccessibilityServerVisionOS::Element *AccessibilityServerVisionOS::_describe(const RID &p_id) {
	Element *element = elements.get_or_null(p_id);
	if (element && element->pass != pass) {
		// A node's update describes the element completely: start afresh.
		element->pass = pass;
		element->children.clear();
		element->hidden = false;
		element->disabled = false;
		element->clips_children = false;
	}
	return element;
}

void AccessibilityServerVisionOS::update_set_role(const RID &p_id, AccessibilityServerEnums::AccessibilityRole p_role) {
	if (Element *element = _describe(p_id)) {
		element->role = p_role;
	}
}

void AccessibilityServerVisionOS::update_set_bounds(const RID &p_id, const Rect2 &p_rect) {
	if (Element *element = _describe(p_id)) {
		element->bounds = p_rect;
	}
}

void AccessibilityServerVisionOS::update_set_transform(const RID &p_id, const Transform2D &p_transform) {
	if (Element *element = _describe(p_id)) {
		element->transform = p_transform;
	}
}

void AccessibilityServerVisionOS::update_add_child(const RID &p_id, const RID &p_child_id) {
	Element *element = _describe(p_id);
	if (element && p_child_id.is_valid() && p_child_id != p_id) {
		element->children.push_back(p_child_id);
	}
}

void AccessibilityServerVisionOS::update_set_flag(const RID &p_id, AccessibilityServerEnums::AccessibilityFlags p_flag, bool p_value) {
	Element *element = _describe(p_id);
	if (!element) {
		return;
	}
	switch (p_flag) {
		case AccessibilityServerEnums::FLAG_HIDDEN:
			element->hidden = p_value;
			break;
		case AccessibilityServerEnums::FLAG_DISABLED:
			element->disabled = p_value;
			break;
		case AccessibilityServerEnums::FLAG_CLIPS_CHILDREN:
			element->clips_children = p_value;
			break;
		default:
			break;
	}
}

// MARK: Updates

void AccessibilityServerVisionOS::update_if_active(const Callable &p_callable) {
	LocalVector<DisplayServerEnums::WindowID> windows;
	for (const KeyValue<DisplayServerEnums::WindowID, RID> &root : window_roots) {
		windows.push_back(root.key);
	}
	for (DisplayServerEnums::WindowID window : windows) {
		pass++;
		p_callable.call(window);
		_sync_hover(window);
	}
}

void AccessibilityServerVisionOS::_collect_targets(const RID &p_id, const Transform2D &p_parent, const Rect2 &p_clip, uint64_t p_window, bool p_root, LocalVector<Target> &r_targets, LocalVector<Target> &r_windows) const {
	const Element *element = elements.get_or_null(p_id);
	if (!element || element->hidden) {
		return;
	}
	const Transform2D transform = p_parent * element->transform;
	const Rect2 rect = transform.xform(element->bounds);
	Rect2 clip = p_clip;
	if (element->clips_children) {
		clip = clip.intersection(rect);
	}
	uint64_t window = p_window;
	const bool is_window = element->role == AccessibilityServerEnums::ROLE_WINDOW || element->role == AccessibilityServerEnums::ROLE_MENU ||
			element->role == AccessibilityServerEnums::ROLE_DIALOG || element->role == AccessibilityServerEnums::ROLE_TOOLTIP;
	if (!p_root && is_window) {
		// An embedded window draws over the controls of the window it is in.
		window = p_id.get_id();
		r_windows.push_back({ window, rect, p_window });
	}
	if (_is_interactive(element->role) && !element->disabled) {
		const Rect2 visible = rect.intersection(p_clip);
		if (visible.has_area()) {
			r_targets.push_back({ p_id.get_id(), visible, window });
		}
	}
	for (const RID &child : element->children) {
		_collect_targets(child, transform, clip, window, false, r_targets, r_windows);
	}
	for (const RID &sub : element->sub_elements) {
		_collect_targets(sub, transform, clip, window, false, r_targets, r_windows);
	}
}

void AccessibilityServerVisionOS::_sync_hover(DisplayServerEnums::WindowID p_window_id) {
	const RID *root = window_roots.getptr(p_window_id);
	DisplayServer *display_server = DisplayServer::get_singleton();
	if (!root || !display_server) {
		return;
	}
	UIView *view = (__bridge UIView *)(void *)display_server->window_get_native_handle(DisplayServerEnums::WINDOW_VIEW, p_window_id);

	GDTHoverHost *host = nil;
	if (void **existing = hover_hosts.getptr(p_window_id)) {
		host = (__bridge GDTHoverHost *)*existing;
	} else {
		if (!view) {
			return;
		}
		host = [GDTHoverHost new];
		hover_hosts[p_window_id] = (__bridge_retained void *)host;
	}
	host.view = view;

	LocalVector<Target> collected;
	LocalVector<Target> windows;
	const Rect2 everything(-1e9, -1e9, 2e9, 2e9);
	_collect_targets(*root, Transform2D(), everything, 0, true, collected, windows);

	// Drop targets an embedded window covers: an open menu takes the gaze.
	HashMap<uint64_t, Rect2> targets;
	for (const Target &target : collected) {
		bool covered = false;
		for (const Target &window : windows) {
			if (window.id != target.window && window.window == target.window && window.rect.intersects(target.rect)) {
				covered = true;
				break;
			}
		}
		if (!covered) {
			targets[target.id] = target.rect;
		}
	}

	NSMutableDictionary<NSNumber *, NSValue *> *rects = [NSMutableDictionary dictionaryWithCapacity:targets.size()];
	for (const KeyValue<uint64_t, Rect2> &target : targets) {
		rects[@(target.key)] = [NSValue valueWithCGRect:CGRectMake(target.value.position.x, target.value.position.y, target.value.size.x, target.value.size.y)];
	}
	[host updateTargets:rects];
}
