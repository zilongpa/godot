/**************************************************************************/
/*  accessibility_server_visionos.h                                       */
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

#include "core/templates/hash_map.h"
#include "core/templates/local_vector.h"
#include "core/templates/rid_owner.h"
#include "servers/display/accessibility_server_dummy.h"

// Follows the accessibility tree Godot's controls describe, and gives every
// interactive element a native hover effect: visionOS shows gaze highlights
// only for regions an app declares in advance.
class AccessibilityServerVisionOS : public AccessibilityServerDummy {
	GDSOFTCLASS(AccessibilityServerVisionOS, AccessibilityServerDummy)

	struct Element {
		DisplayServerEnums::WindowID window = DisplayServerEnums::INVALID_WINDOW_ID;
		// Children the element's update lists, and sub-elements it created.
		LocalVector<RID> children;
		LocalVector<RID> sub_elements;
		RID parent;
		AccessibilityServerEnums::AccessibilityRole role = AccessibilityServerEnums::ROLE_UNKNOWN;
		Rect2 bounds;
		Transform2D transform;
		// Negative when the element doesn't say.
		float corner_radius = -1;
		bool hidden = false;
		bool disabled = false;
		bool clips_children = false;
		// The update pass that last described this element.
		uint64_t pass = 0;
	};

	mutable RID_PtrOwner<Element> elements;
	HashMap<DisplayServerEnums::WindowID, RID> window_roots;
	uint64_t pass = 1;

	// Hover hosts by window, owned as Objective-C objects.
	HashMap<DisplayServerEnums::WindowID, void *> hover_hosts;

	Element *_describe(const RID &p_id);
	struct Target {
		uint64_t id = 0;
		Rect2 rect;
		float corner_radius = -1;
		// The embedded window (popup or subwindow) the target is in, if any.
		uint64_t window = 0;
	};
	void _collect_targets(const RID &p_id, const Transform2D &p_parent, const Rect2 &p_clip, uint64_t p_window, bool p_root, LocalVector<Target> &r_targets, LocalVector<Target> &r_windows) const;
	void _sync_hover(DisplayServerEnums::WindowID p_window_id);
	void _free_tree(const RID &p_id);

	static bool _is_interactive(AccessibilityServerEnums::AccessibilityRole p_role);
	static AccessibilityServer *create_func(Error &r_error);

public:
	static void register_create_func();

	virtual bool is_supported() const override { return true; }

	virtual bool window_create(DisplayServerEnums::WindowID p_window_id, void *p_handle) override;
	virtual void window_destroy(DisplayServerEnums::WindowID p_window_id) override;

	virtual RID create_element(DisplayServerEnums::WindowID p_window_id, AccessibilityServerEnums::AccessibilityRole p_role) override;
	virtual RID create_sub_element(const RID &p_parent_rid, AccessibilityServerEnums::AccessibilityRole p_role, int p_insert_pos = -1) override;
	virtual bool has_element(const RID &p_id) const override;
	virtual void free_element(const RID &p_id) override;

	virtual void update_if_active(const Callable &p_callable) override;
	virtual RID get_window_root(DisplayServerEnums::WindowID p_window_id) const override;

	virtual void update_set_role(const RID &p_id, AccessibilityServerEnums::AccessibilityRole p_role) override;
	virtual void update_set_bounds(const RID &p_id, const Rect2 &p_rect) override;
	virtual void update_set_corner_radius(const RID &p_id, float p_radius) override;
	virtual void update_set_transform(const RID &p_id, const Transform2D &p_transform) override;
	virtual void update_add_child(const RID &p_id, const RID &p_child_id) override;
	virtual void update_set_flag(const RID &p_id, AccessibilityServerEnums::AccessibilityFlags p_flag, bool p_value) override;

	~AccessibilityServerVisionOS();
};
