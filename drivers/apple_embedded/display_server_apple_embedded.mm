/**************************************************************************/
/*  display_server_apple_embedded.mm                                      */
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

#import "display_server_apple_embedded.h"
#include "native_file_dialog.h"

#include "core/config/project_settings.h"
#include "core/input/input.h"
#include "core/io/file_access_pack.h"
#include "core/os/os.h"
#import "drivers/apple_embedded/apple_embedded.h"
#import "drivers/apple_embedded/godot_app_delegate_service_apple_embedded.h"
#import "drivers/apple_embedded/godot_keyboard_input_view.h"
#import "drivers/apple_embedded/godot_view_apple_embedded.h"
#import "drivers/apple_embedded/godot_view_controller.h"
#import "drivers/apple_embedded/key_mapping_apple_embedded.h"
#import "drivers/apple_embedded/os_apple_embedded.h"
#import "drivers/apple_embedded/tts_apple_embedded.h"
#include "servers/display/native_menu.h"

#import <GameController/GameController.h>

#ifdef VISIONOS_ENABLED
extern "C" void godot_visionos_request_window(uint64_t p_window);
extern "C" void godot_visionos_dismiss_window(uint64_t p_window);
#endif

static const float kDisplayServerIOSAcceleration = 1.f;

DisplayServerAppleEmbedded *DisplayServerAppleEmbedded::get_singleton() {
	return (DisplayServerAppleEmbedded *)DisplayServer::get_singleton();
}

DisplayServerAppleEmbedded::DisplayServerAppleEmbedded(const String &p_rendering_driver, DisplayServerEnums::WindowMode p_mode, DisplayServerEnums::VSyncMode p_vsync_mode, uint32_t p_flags, const Vector2i *p_position, const Vector2i &p_resolution, int p_screen, DisplayServerEnums::Context p_context, int64_t p_parent_window, Error &r_error) {
	KeyMappingAppleEmbedded::initialize();

	rendering_driver = p_rendering_driver;
#ifdef VISIONOS_ENABLED
	main_window_transparent = (p_flags & (1 << DisplayServerEnums::WINDOW_FLAG_TRANSPARENT)) != 0;
	main_window_unresizable = (p_flags & (1 << DisplayServerEnums::WINDOW_FLAG_RESIZE_DISABLED)) != 0;
	GDTAppDelegateService.viewController.view.backgroundColor = main_window_transparent ? UIColor.clearColor : UIColor.blackColor;
#endif

	// Init TTS
	bool tts_enabled = GLOBAL_GET("audio/general/text_to_speech");
	if (tts_enabled) {
		initialize_tts();
	}
	native_menu = memnew(NativeMenu);

	bool has_made_render_compositor_current = false;

#if defined(RD_ENABLED)
	rendering_context = nullptr;
	rendering_device = nullptr;

	CALayer *layer = nullptr;

	union {
#ifdef VULKAN_ENABLED
		RenderingContextDriverVulkanAppleEmbedded::WindowPlatformData vulkan;
#endif
#ifdef METAL_ENABLED
		GODOT_CLANG_WARNING_PUSH_AND_IGNORE("-Wunguarded-availability")
		// Eliminate "RenderingContextDriverMetal is only available on iOS 14.0 or newer".
		RenderingContextDriverMetal::WindowPlatformData metal;
		GODOT_CLANG_WARNING_POP
#endif
	} wpd;

#if defined(VULKAN_ENABLED)
	if (rendering_driver == "vulkan") {
		layer = [GDTAppDelegateService.viewController.godotView initializeRenderingForDriver:@"vulkan"];
		if (!layer) {
			ERR_FAIL_MSG("Failed to create iOS Vulkan rendering layer.");
		}
		wpd.vulkan.layer_ptr = (CAMetalLayer *const *)&layer;
		rendering_context = memnew(RenderingContextDriverVulkanAppleEmbedded);
	}
#endif
#ifdef METAL_ENABLED
	if (rendering_driver == "metal") {
		if (@available(iOS 14.0, *)) {
			layer = [GDTAppDelegateService.viewController.godotView initializeRenderingForDriver:@"metal"];
			wpd.metal.layer = (__bridge CA::MetalLayer *)layer;
			rendering_context = memnew(RenderingContextDriverMetal);
		} else {
			OS::get_singleton()->alert("Metal is only supported on iOS 14.0 and later.");
			r_error = ERR_UNAVAILABLE;
			return;
		}
	}
#endif
	if (rendering_context) {
		if (rendering_context->initialize() != OK) {
			memdelete(rendering_context);
			rendering_context = nullptr;
#if defined(GLES3_ENABLED)
			bool fallback_to_opengl3 = GLOBAL_GET("rendering/rendering_device/fallback_to_opengl3");
			if (fallback_to_opengl3 && rendering_driver != "opengl3") {
				WARN_PRINT("Your device does not seem to support MoltenVK or Metal, switching to OpenGL 3.");
				rendering_driver = "opengl3";
				OS::get_singleton()->set_current_rendering_method("gl_compatibility", OS::RENDERING_SOURCE_FALLBACK);
				OS::get_singleton()->set_current_rendering_driver_name(rendering_driver, OS::RENDERING_SOURCE_FALLBACK);
			} else
#endif
			{
				ERR_PRINT(vformat("Failed to initialize %s context", rendering_driver));
				r_error = ERR_UNAVAILABLE;
				return;
			}
		}
	}

	if (rendering_context) {
		if (rendering_context->window_create(DisplayServerEnums::MAIN_WINDOW_ID, &wpd) != OK) {
			ERR_PRINT(vformat("Failed to create %s window.", rendering_driver));
			memdelete(rendering_context);
			rendering_context = nullptr;
			r_error = ERR_UNAVAILABLE;
			return;
		}

		Size2i size = Size2i(layer.bounds.size.width, layer.bounds.size.height) * screen_get_max_scale();
		rendering_context->window_set_size(DisplayServerEnums::MAIN_WINDOW_ID, size.width, size.height);
		rendering_context->window_set_vsync_mode(DisplayServerEnums::MAIN_WINDOW_ID, p_vsync_mode);

		rendering_device = memnew(RenderingDevice);
		if (rendering_device->initialize(rendering_context, DisplayServerEnums::MAIN_WINDOW_ID) != OK) {
			rendering_device = nullptr;
			memdelete(rendering_context);
			rendering_context = nullptr;
			r_error = ERR_UNAVAILABLE;
			return;
		}
		rendering_device->screen_create(DisplayServerEnums::MAIN_WINDOW_ID);

		RendererCompositorRD::make_current();
		has_made_render_compositor_current = true;
	}
#endif

#if defined(GLES3_ENABLED)
	if (rendering_driver == "opengl3") {
		CALayer *layer = [GDTAppDelegateService.viewController.godotView initializeRenderingForDriver:@"opengl3"];

		if (!layer) {
			ERR_FAIL_MSG("Failed to create iOS OpenGLES rendering layer.");
		}

		RasterizerGLES3::make_current(false);
		has_made_render_compositor_current = true;
	}
#endif

	ERR_FAIL_COND_MSG(!has_made_render_compositor_current, vformat("Failed to make RendererCompositor current for rendering driver %s", rendering_driver));

	bool keep_screen_on = bool(GLOBAL_GET("display/window/energy_saving/keep_screen_on"));
	screen_set_keep_on(keep_screen_on);

	Input::get_singleton()->set_event_dispatch_function(_dispatch_input_events);

	r_error = OK;
}

DisplayServerAppleEmbedded::~DisplayServerAppleEmbedded() {
	if (native_menu) {
		memdelete(native_menu);
		native_menu = nullptr;
	}

#if defined(RD_ENABLED)
	if (rendering_device) {
		rendering_device->screen_free(DisplayServerEnums::MAIN_WINDOW_ID);
		memdelete(rendering_device);
		rendering_device = nullptr;
	}

	if (rendering_context) {
		rendering_context->window_destroy(DisplayServerEnums::MAIN_WINDOW_ID);
		memdelete(rendering_context);
		rendering_context = nullptr;
	}
#endif
}

Vector<String> DisplayServerAppleEmbedded::get_rendering_drivers_func() {
	Vector<String> drivers;

#if defined(VULKAN_ENABLED)
	drivers.push_back("vulkan");
#endif
#if defined(METAL_ENABLED)
	if (@available(ios 14.0, *)) {
		drivers.push_back("metal");
	}
#endif
#if defined(GLES3_ENABLED)
	drivers.push_back("opengl3");
#endif

	return drivers;
}

// MARK: Events

void DisplayServerAppleEmbedded::window_set_rect_changed_callback(const Callable &p_callable, DisplayServerEnums::WindowID p_window) {
#ifdef VISIONOS_ENABLED
	if (p_window != DisplayServerEnums::MAIN_WINDOW_ID) {
		if (SubWindowData *data = sub_windows.getptr(p_window)) { data->resize_callback = p_callable; }
		return;
	}
#endif
	window_resize_callback = p_callable;
}

void DisplayServerAppleEmbedded::window_set_window_event_callback(const Callable &p_callable, DisplayServerEnums::WindowID p_window) {
#ifdef VISIONOS_ENABLED
	if (p_window != DisplayServerEnums::MAIN_WINDOW_ID) {
		if (SubWindowData *data = sub_windows.getptr(p_window)) { data->event_callback = p_callable; }
		return;
	}
#endif
	window_event_callback = p_callable;
}
void DisplayServerAppleEmbedded::window_set_input_event_callback(const Callable &p_callable, DisplayServerEnums::WindowID p_window) {
#ifdef VISIONOS_ENABLED
	if (p_window != DisplayServerEnums::MAIN_WINDOW_ID) {
		if (SubWindowData *data = sub_windows.getptr(p_window)) { data->input_callback = p_callable; }
		return;
	}
#endif
	input_event_callback = p_callable;
}

void DisplayServerAppleEmbedded::window_set_input_text_callback(const Callable &p_callable, DisplayServerEnums::WindowID p_window) {
#ifdef VISIONOS_ENABLED
	if (p_window != DisplayServerEnums::MAIN_WINDOW_ID) {
		if (SubWindowData *data = sub_windows.getptr(p_window)) { data->text_callback = p_callable; }
		return;
	}
#endif
	input_text_callback = p_callable;
}

void DisplayServerAppleEmbedded::window_set_drop_files_callback(const Callable &p_callable, DisplayServerEnums::WindowID p_window) {
	// Probably not supported for iOS
}

void DisplayServerAppleEmbedded::process_events() {
	Input::get_singleton()->flush_buffered_events();
}

void DisplayServerAppleEmbedded::_dispatch_input_events(const Ref<InputEvent> &p_event) {
	DisplayServerAppleEmbedded::get_singleton()->send_input_event(p_event);
}

void DisplayServerAppleEmbedded::send_input_event(const Ref<InputEvent> &p_event) const {
#ifdef VISIONOS_ENABLED
	const InputEventFromWindow *window_event = Object::cast_to<InputEventFromWindow>(p_event.ptr());
	if (window_event && window_event->get_window_id() != DisplayServerEnums::MAIN_WINDOW_ID) {
		if (const SubWindowData *data = sub_windows.getptr(window_event->get_window_id())) {
			_window_callback(data->input_callback, p_event);
		}
		return;
	}
#endif
	_window_callback(input_event_callback, p_event);
}

void DisplayServerAppleEmbedded::send_input_text(const String &p_text, DisplayServerEnums::WindowID p_window) const {
#ifdef VISIONOS_ENABLED
	if (p_window != DisplayServerEnums::MAIN_WINDOW_ID) {
		if (const SubWindowData *data = sub_windows.getptr(p_window)) { _window_callback(data->text_callback, p_text); }
		return;
	}
#endif
	_window_callback(input_text_callback, p_text);
}

void DisplayServerAppleEmbedded::send_window_event(DisplayServerEnums::WindowEvent p_event, DisplayServerEnums::WindowID p_window) const {
#ifdef VISIONOS_ENABLED
	if (p_window != DisplayServerEnums::MAIN_WINDOW_ID) {
		if (const SubWindowData *data = sub_windows.getptr(p_window)) { _window_callback(data->event_callback, int(p_event)); }
		return;
	}
#endif
	_window_callback(window_event_callback, int(p_event));
}

void DisplayServerAppleEmbedded::_window_callback(const Callable &p_callable, const Variant &p_arg) const {
	if (p_callable.is_valid()) {
		p_callable.call(p_arg);
	}
}

// MARK: - Input

// MARK: Touches

void DisplayServerAppleEmbedded::touch_press(int p_idx, int p_x, int p_y, bool p_pressed, bool p_double_click, DisplayServerEnums::WindowID p_window) {
	Ref<InputEventScreenTouch> ev;
	ev.instantiate();

	ev->set_index(p_idx);
	ev->set_pressed(p_pressed);
	ev->set_position(Vector2(p_x, p_y));
	ev->set_double_tap(p_double_click);
	ev->set_window_id(p_window);
	perform_event(ev);
}

void DisplayServerAppleEmbedded::touch_drag(int p_idx, int p_prev_x, int p_prev_y, int p_x, int p_y, float p_pressure, Vector2 p_tilt, DisplayServerEnums::WindowID p_window) {
	Ref<InputEventScreenDrag> ev;
	ev.instantiate();
	ev->set_index(p_idx);
	ev->set_pressure(p_pressure);
	ev->set_tilt(p_tilt);
	ev->set_position(Vector2(p_x, p_y));
	ev->set_relative(Vector2(p_x - p_prev_x, p_y - p_prev_y));
	ev->set_relative_screen_position(ev->get_relative());
	ev->set_window_id(p_window);
	perform_event(ev);
}

void DisplayServerAppleEmbedded::perform_event(const Ref<InputEvent> &p_event) {
	Input *input_singleton = Input::get_singleton();
	if (input_singleton == nullptr) {
		return;
	}

	input_singleton->parse_input_event(p_event);
}

void DisplayServerAppleEmbedded::touches_canceled(int p_idx, DisplayServerEnums::WindowID p_window) {
	touch_press(p_idx, -1, -1, false, false, p_window);
}

// MARK: Keyboard

void DisplayServerAppleEmbedded::key(Key p_key, char32_t p_char, Key p_unshifted, Key p_physical, NSInteger p_modifier, bool p_pressed, KeyLocation p_location, DisplayServerEnums::WindowID p_window) {
	Ref<InputEventKey> ev;
	ev.instantiate();
	ev->set_echo(false);
	ev->set_pressed(p_pressed);
	ev->set_keycode(fix_keycode(p_char, p_key));
	if (@available(iOS 13.4, *)) {
		if (p_key != Key::SHIFT) {
			ev->set_shift_pressed(p_modifier & UIKeyModifierShift);
		}
		if (p_key != Key::CTRL) {
			ev->set_ctrl_pressed(p_modifier & UIKeyModifierControl);
		}
		if (p_key != Key::ALT) {
			ev->set_alt_pressed(p_modifier & UIKeyModifierAlternate);
		}
		if (p_key != Key::META) {
			ev->set_meta_pressed(p_modifier & UIKeyModifierCommand);
		}
	}
	ev->set_key_label(p_unshifted);
	ev->set_physical_keycode(p_physical);
	ev->set_unicode(fix_unicode(p_char));
	ev->set_location(p_location);
	ev->set_window_id(p_window);
	perform_event(ev);
}

// MARK: Motion

void DisplayServerAppleEmbedded::update_gravity(const Vector3 &p_gravity) {
	Input::get_singleton()->set_gravity(p_gravity);
}

void DisplayServerAppleEmbedded::update_accelerometer(const Vector3 &p_accelerometer) {
	Input::get_singleton()->set_accelerometer(p_accelerometer / kDisplayServerIOSAcceleration);
}

void DisplayServerAppleEmbedded::update_magnetometer(const Vector3 &p_magnetometer) {
	Input::get_singleton()->set_magnetometer(p_magnetometer);
}

void DisplayServerAppleEmbedded::update_gyroscope(const Vector3 &p_gyroscope) {
	Input::get_singleton()->set_gyroscope(p_gyroscope);
}

// MARK: -

bool DisplayServerAppleEmbedded::has_feature(DisplayServerEnums::Feature p_feature) const {
	switch (p_feature) {
#ifndef DISABLE_DEPRECATED
		case DisplayServerEnums::FEATURE_GLOBAL_MENU: {
			return (native_menu && native_menu->has_feature(NativeMenu::FEATURE_GLOBAL_MENU));
		} break;
#endif
		// case DisplayServerEnums::FEATURE_CURSOR_SHAPE:
		// case DisplayServerEnums::FEATURE_CUSTOM_CURSOR_SHAPE:
		// case DisplayServerEnums::FEATURE_HIDPI:
		// case DisplayServerEnums::FEATURE_ICON:
		// case DisplayServerEnums::FEATURE_IME:
		// case DisplayServerEnums::FEATURE_MOUSE:
		// case DisplayServerEnums::FEATURE_MOUSE_WARP:
		// case DisplayServerEnums::FEATURE_NATIVE_DIALOG:
		// case DisplayServerEnums::FEATURE_NATIVE_DIALOG_INPUT:
#ifdef VISIONOS_ENABLED
		case DisplayServerEnums::FEATURE_NATIVE_DIALOG_FILE:
		case DisplayServerEnums::FEATURE_NATIVE_DIALOG_FILE_MIME:
		case DisplayServerEnums::FEATURE_WINDOW_TRANSPARENCY:
			return true;
		case DisplayServerEnums::FEATURE_SUBWINDOWS:
			return rendering_driver == "metal";
#endif
		// case DisplayServerEnums::FEATURE_NATIVE_DIALOG_FILE:
		// case DisplayServerEnums::FEATURE_NATIVE_DIALOG_FILE_EXTRA:
		// case DisplayServerEnums::FEATURE_NATIVE_DIALOG_FILE_MIME:
		// case DisplayServerEnums::FEATURE_NATIVE_ICON:
		// case DisplayServerEnums::FEATURE_WINDOW_TRANSPARENCY:
		case DisplayServerEnums::FEATURE_CLIPBOARD:
		case DisplayServerEnums::FEATURE_HDR_OUTPUT:
		case DisplayServerEnums::FEATURE_KEEP_SCREEN_ON:
		case DisplayServerEnums::FEATURE_ORIENTATION:
		case DisplayServerEnums::FEATURE_TOUCHSCREEN:
		case DisplayServerEnums::FEATURE_VIRTUAL_KEYBOARD:
		case DisplayServerEnums::FEATURE_TEXT_TO_SPEECH:
			return true;
		default:
			return false;
	}
}

void DisplayServerAppleEmbedded::initialize_tts() const {
	const_cast<DisplayServerAppleEmbedded *>(this)->tts = [[GDTTTS alloc] init];
}

bool DisplayServerAppleEmbedded::tts_is_speaking() const {
	if (unlikely(!tts)) {
		initialize_tts();
	}
	ERR_FAIL_NULL_V(tts, false);
	return [tts isSpeaking];
}

bool DisplayServerAppleEmbedded::tts_is_paused() const {
	if (unlikely(!tts)) {
		initialize_tts();
	}
	ERR_FAIL_NULL_V(tts, false);
	return [tts isPaused];
}

TypedArray<Dictionary> DisplayServerAppleEmbedded::tts_get_voices() const {
	if (unlikely(!tts)) {
		initialize_tts();
	}
	ERR_FAIL_NULL_V(tts, TypedArray<Dictionary>());
	return [tts getVoices];
}

void DisplayServerAppleEmbedded::tts_speak(const String &p_text, const String &p_voice, int p_volume, float p_pitch, float p_rate, int64_t p_utterance_id, bool p_interrupt) {
	if (unlikely(!tts)) {
		initialize_tts();
	}
	ERR_FAIL_NULL(tts);
	[tts speak:p_text voice:p_voice volume:p_volume pitch:p_pitch rate:p_rate utterance_id:p_utterance_id interrupt:p_interrupt];
}

void DisplayServerAppleEmbedded::tts_pause() {
	if (unlikely(!tts)) {
		initialize_tts();
	}
	ERR_FAIL_NULL(tts);
	[tts pauseSpeaking];
}

void DisplayServerAppleEmbedded::tts_resume() {
	if (unlikely(!tts)) {
		initialize_tts();
	}
	ERR_FAIL_NULL(tts);
	[tts resumeSpeaking];
}

void DisplayServerAppleEmbedded::tts_stop() {
	if (unlikely(!tts)) {
		initialize_tts();
	}
	ERR_FAIL_NULL(tts);
	[tts stopSpeaking];
}

bool DisplayServerAppleEmbedded::is_dark_mode_supported() const {
	if (@available(iOS 13.0, *)) {
		return true;
	} else {
		return false;
	}
}

bool DisplayServerAppleEmbedded::is_dark_mode() const {
	if (@available(iOS 13.0, *)) {
		return [UITraitCollection currentTraitCollection].userInterfaceStyle == UIUserInterfaceStyleDark;
	} else {
		return false;
	}
}

void DisplayServerAppleEmbedded::set_system_theme_change_callback(const Callable &p_callable) {
	system_theme_changed = p_callable;
}

void DisplayServerAppleEmbedded::emit_system_theme_changed() {
	if (system_theme_changed.is_valid()) {
		Variant ret;
		Callable::CallError ce;
		system_theme_changed.callp(nullptr, 0, ret, ce);
		if (ce.error != Callable::CallError::CALL_OK) {
			ERR_PRINT(vformat("Failed to execute system theme changed callback: %s.", Variant::get_callable_error_text(system_theme_changed, nullptr, 0, ce)));
		}
	}
}

Rect2i DisplayServerAppleEmbedded::get_display_safe_area() const {
	UIEdgeInsets insets = UIEdgeInsetsZero;
	UIView *view = GDTAppDelegateService.viewController.godotView;
	if ([view respondsToSelector:@selector(safeAreaInsets)]) {
		insets = [view safeAreaInsets];
	}
	float scale = screen_get_scale();
	Size2i insets_position = Size2i(insets.left, insets.top) * scale;
	Size2i insets_size = Size2i(insets.left + insets.right, insets.top + insets.bottom) * scale;
	return Rect2i(screen_get_position() + insets_position, screen_get_size() - insets_size);
}

int DisplayServerAppleEmbedded::get_screen_count() const {
	return 1;
}

int DisplayServerAppleEmbedded::get_primary_screen() const {
	return 0;
}

Point2i DisplayServerAppleEmbedded::screen_get_position(int p_screen) const {
	p_screen = _get_screen_index(p_screen);
	int screen_count = get_screen_count();
	ERR_FAIL_INDEX_V(p_screen, screen_count, Point2i());

	return Point2i(0, 0);
}

Size2i DisplayServerAppleEmbedded::screen_get_size(int p_screen) const {
	p_screen = _get_screen_index(p_screen);
	int screen_count = get_screen_count();
	ERR_FAIL_INDEX_V(p_screen, screen_count, Size2i());

	CALayer *layer = GDTAppDelegateService.viewController.godotView.renderingLayer;

	if (!layer) {
		return Size2i();
	}

	return Size2i(layer.bounds.size.width, layer.bounds.size.height) * screen_get_scale(p_screen);
}

Rect2i DisplayServerAppleEmbedded::screen_get_usable_rect(int p_screen) const {
	p_screen = _get_screen_index(p_screen);
	int screen_count = get_screen_count();
	ERR_FAIL_INDEX_V(p_screen, screen_count, Rect2i());

	return Rect2i(screen_get_position(p_screen), screen_get_size(p_screen));
}

Vector<DisplayServerEnums::WindowID> DisplayServerAppleEmbedded::get_window_list() const {
	Vector<DisplayServerEnums::WindowID> list;
	list.push_back(DisplayServerEnums::MAIN_WINDOW_ID);
#ifdef VISIONOS_ENABLED
	for (const KeyValue<DisplayServerEnums::WindowID, SubWindowData> &entry : sub_windows) {
		list.push_back(entry.key);
	}
#endif
	return list;
}

DisplayServerEnums::WindowID DisplayServerAppleEmbedded::create_sub_window(DisplayServerEnums::WindowMode p_mode, DisplayServerEnums::VSyncMode p_vsync_mode, uint32_t p_flags, const Rect2i &p_rect, bool p_exclusive, DisplayServerEnums::WindowID p_transient_parent) {
#ifdef VISIONOS_ENABLED
	if (rendering_driver != "metal") {
		ERR_PRINT("Native visionOS windows require the Metal renderer.");
		return DisplayServerEnums::INVALID_WINDOW_ID;
	}
	const DisplayServerEnums::WindowID id = next_sub_window_id++;
	SubWindowData data;
	data.requested_size = p_rect.size.maxi(1);
	data.size = data.requested_size;
	data.transparent = (p_flags & (1 << DisplayServerEnums::WINDOW_FLAG_TRANSPARENT)) != 0;
	data.unresizable = (p_flags & (1 << DisplayServerEnums::WINDOW_FLAG_RESIZE_DISABLED)) != 0;
	sub_windows.insert(id, data);
	return id;
#else
	return DisplayServerEnums::INVALID_WINDOW_ID;
#endif
}

void DisplayServerAppleEmbedded::show_window(DisplayServerEnums::WindowID p_id) {
#ifdef VISIONOS_ENABLED
	if (SubWindowData *data = sub_windows.getptr(p_id)) {
		if (!data->visible) {
			data->visible = true;
			godot_visionos_request_window(p_id);
		}
	}
#endif
}

void DisplayServerAppleEmbedded::delete_sub_window(DisplayServerEnums::WindowID p_id) {
#ifdef VISIONOS_ENABLED
	SubWindowData *data = sub_windows.getptr(p_id);
	if (!data) { return; }
	focus_visionos_window(p_id, false);
	data = sub_windows.getptr(p_id);
	if (!data) { return; }
#if defined(RD_ENABLED)
	if (data->controller && rendering_device) {
		rendering_device->screen_free(p_id);
		rendering_context->window_destroy(p_id);
	}
#endif
	const bool was_visible = data->visible;
	sub_windows.erase(p_id);
	if (focused_window_id == p_id) { focused_window_id = DisplayServerEnums::INVALID_WINDOW_ID; }
	if (was_visible) { godot_visionos_dismiss_window(p_id); }
#endif
}

DisplayServerEnums::WindowID DisplayServerAppleEmbedded::get_focused_window() const {
#ifdef VISIONOS_ENABLED
	return focused_window_id;
#else
	return DisplayServerEnums::MAIN_WINDOW_ID;
#endif
}

void DisplayServerAppleEmbedded::focus_visionos_window(DisplayServerEnums::WindowID p_window, bool p_focused) {
#ifdef VISIONOS_ENABLED
	bool *focused = &main_window_focused;
	if (p_window != DisplayServerEnums::MAIN_WINDOW_ID) {
		SubWindowData *data = sub_windows.getptr(p_window);
		if (!data || !data->controller) { return; }
		focused = &data->focused;
	}
	if (*focused == p_focused) { return; }
	if (p_focused && focused_window_id != p_window) {
		const DisplayServerEnums::WindowID previous = focused_window_id;
		if (previous == DisplayServerEnums::MAIN_WINDOW_ID) {
			if (main_window_focused) {
				main_window_focused = false;
				send_window_event(DisplayServerEnums::WINDOW_EVENT_FOCUS_OUT, previous);
			}
		} else if (SubWindowData *old = sub_windows.getptr(previous)) {
			if (old->focused) {
				old->focused = false;
				send_window_event(DisplayServerEnums::WINDOW_EVENT_FOCUS_OUT, previous);
			}
		}
		if (p_window != DisplayServerEnums::MAIN_WINDOW_ID && !sub_windows.has(p_window)) { return; }
	}
	if (p_window == DisplayServerEnums::MAIN_WINDOW_ID) {
		main_window_focused = p_focused;
	} else {
		sub_windows.getptr(p_window)->focused = p_focused;
	}
	if (p_focused) {
		focused_window_id = p_window;
	} else if (focused_window_id == p_window) {
		focused_window_id = DisplayServerEnums::INVALID_WINDOW_ID;
	}
	send_window_event(p_focused ? DisplayServerEnums::WINDOW_EVENT_FOCUS_IN : DisplayServerEnums::WINDOW_EVENT_FOCUS_OUT, p_window);
#endif
}

void DisplayServerAppleEmbedded::connect_visionos_window(DisplayServerEnums::WindowID p_window, void *p_controller) {
#if defined(VISIONOS_ENABLED) && defined(METAL_ENABLED) && defined(RD_ENABLED)
	if (p_window == DisplayServerEnums::MAIN_WINDOW_ID) {
		window_set_title(main_window_title, p_window);
		window_set_size(window_get_size(p_window), p_window);
		return;
	}
	SubWindowData *data = sub_windows.getptr(p_window);
	if (!data || data->controller || !rendering_context || !rendering_device) { return; }
	GDTViewController *controller = (__bridge GDTViewController *)p_controller;
	CAMetalLayer *layer = (CAMetalLayer *)[controller.godotView initializeRenderingForDriver:@"metal"];
	if (!layer) { return; }
	RenderingContextDriverMetal::WindowPlatformData platform_data;
	platform_data.layer = (__bridge CA::MetalLayer *)layer;
	if (rendering_context->window_create(p_window, &platform_data) != OK) {
		ERR_PRINT(vformat("Failed to create Metal surface for visionOS window %d.", p_window));
		return;
	}
	data->controller = p_controller;
	controller.view.backgroundColor = data->transparent ? UIColor.clearColor : UIColor.blackColor;
	data->size = Size2i(layer.bounds.size.width, layer.bounds.size.height) * screen_get_scale();
	rendering_context->window_set_size(p_window, data->size.x, data->size.y);
	rendering_context->window_set_vsync_mode(p_window, DisplayServerEnums::VSYNC_ENABLED);
	if (rendering_device->screen_create(p_window) != OK) {
		ERR_PRINT(vformat("Failed to create rendering screen for visionOS window %d.", p_window));
		rendering_context->window_destroy(p_window);
		data->controller = nullptr;
		return;
	}
	resize_window(controller.view.bounds.size, p_window);
	window_set_size(data->requested_size, p_window);
	window_set_title(data->title, p_window);
#endif
}

void DisplayServerAppleEmbedded::disconnect_visionos_window(DisplayServerEnums::WindowID p_window, void *p_controller) {
#ifdef VISIONOS_ENABLED
	SubWindowData *data = sub_windows.getptr(p_window);
	if (!data || data->controller != p_controller) { return; }
	focus_visionos_window(p_window, false);
	data = sub_windows.getptr(p_window);
	if (!data || data->controller != p_controller) { return; }
	const Callable callback = data->event_callback;
#if defined(RD_ENABLED)
	if (rendering_device) { rendering_device->screen_free(p_window); }
	if (rendering_context) { rendering_context->window_destroy(p_window); }
#endif
	data->controller = nullptr;
	if (sub_windows.has(p_window)) { _window_callback(callback, int(DisplayServerEnums::WINDOW_EVENT_CLOSE_REQUEST)); }
	if (sub_windows.has(p_window)) { _window_callback(callback, int(DisplayServerEnums::WINDOW_EVENT_FORCE_CLOSE)); }
#endif
}

DisplayServerEnums::WindowID DisplayServerAppleEmbedded::get_window_at_screen_position(const Point2i &p_position) const {
	return DisplayServerEnums::MAIN_WINDOW_ID;
}

Point2i DisplayServerAppleEmbedded::mouse_get_position() const {
	return Point2i();
}

void DisplayServerAppleEmbedded::window_set_mouse_passthrough(const Vector<Vector2> &p_region, DisplayServerEnums::WindowID p_window) {
	if (!p_region.is_empty()) {
		ERR_PRINT("Mouse passthrough regions are not supported on Apple Embedded windows.");
	}
}

int64_t DisplayServerAppleEmbedded::window_get_native_handle(DisplayServerEnums::HandleType p_handle_type, DisplayServerEnums::WindowID p_window) const {
#ifdef VISIONOS_ENABLED
	if (p_window != DisplayServerEnums::MAIN_WINDOW_ID) {
		const SubWindowData *data = sub_windows.getptr(p_window);
		if (!data || !data->controller) { return 0; }
		GDTViewController *controller = (__bridge GDTViewController *)data->controller;
		if (p_handle_type == DisplayServerEnums::WINDOW_HANDLE) { return (int64_t)controller; }
		if (p_handle_type == DisplayServerEnums::WINDOW_VIEW) { return (int64_t)controller.godotView; }
		return 0;
	}
#endif
	ERR_FAIL_COND_V(p_window != DisplayServerEnums::MAIN_WINDOW_ID, 0);
	switch (p_handle_type) {
		case DisplayServerEnums::DISPLAY_HANDLE: {
			return 0; // Not supported.
		}
		case DisplayServerEnums::WINDOW_HANDLE: {
			return (int64_t)GDTAppDelegateService.viewController;
		}
		case DisplayServerEnums::WINDOW_VIEW: {
			return (int64_t)GDTAppDelegateService.viewController.godotView;
		}
		default: {
			return 0;
		}
	}
}

void DisplayServerAppleEmbedded::window_attach_instance_id(ObjectID p_instance, DisplayServerEnums::WindowID p_window) {
#ifdef VISIONOS_ENABLED
	if (p_window != DisplayServerEnums::MAIN_WINDOW_ID) {
		if (SubWindowData *data = sub_windows.getptr(p_window)) { data->attached_instance_id = p_instance; }
		return;
	}
#endif
	window_attached_instance_id = p_instance;
}

ObjectID DisplayServerAppleEmbedded::window_get_attached_instance_id(DisplayServerEnums::WindowID p_window) const {
#ifdef VISIONOS_ENABLED
	if (p_window != DisplayServerEnums::MAIN_WINDOW_ID) {
		const SubWindowData *data = sub_windows.getptr(p_window);
		return data ? data->attached_instance_id : ObjectID();
	}
#endif
	return window_attached_instance_id;
}

void DisplayServerAppleEmbedded::window_set_title(const String &p_title, DisplayServerEnums::WindowID p_window) {
#ifdef VISIONOS_ENABLED
	UIViewController *controller = nil;
	if (p_window == DisplayServerEnums::MAIN_WINDOW_ID) {
		main_window_title = p_title;
		controller = GDTAppDelegateService.viewController;
	} else if (SubWindowData *data = sub_windows.getptr(p_window)) {
		data->title = p_title;
		controller = (__bridge UIViewController *)data->controller;
	}
	controller.viewIfLoaded.window.windowScene.title = [NSString stringWithUTF8String:p_title.utf8().get_data()];
#endif
}

int DisplayServerAppleEmbedded::window_get_current_screen(DisplayServerEnums::WindowID p_window) const {
#ifdef VISIONOS_ENABLED
	ERR_FAIL_COND_V(p_window != DisplayServerEnums::MAIN_WINDOW_ID && !sub_windows.has(p_window), DisplayServerEnums::INVALID_SCREEN);
#else
	ERR_FAIL_COND_V(p_window != DisplayServerEnums::MAIN_WINDOW_ID, DisplayServerEnums::INVALID_SCREEN);
#endif
	return 0;
}

void DisplayServerAppleEmbedded::window_set_current_screen(int p_screen, DisplayServerEnums::WindowID p_window) {
	// Probably not supported for iOS
}

Point2i DisplayServerAppleEmbedded::window_get_position(DisplayServerEnums::WindowID p_window) const {
	return Point2i();
}

Point2i DisplayServerAppleEmbedded::window_get_position_with_decorations(DisplayServerEnums::WindowID p_window) const {
	return Point2i();
}

void DisplayServerAppleEmbedded::window_set_position(const Point2i &p_position, DisplayServerEnums::WindowID p_window) {
	// Probably not supported for single window iOS app
}

void DisplayServerAppleEmbedded::window_set_transient(DisplayServerEnums::WindowID p_window, DisplayServerEnums::WindowID p_parent) {
	// Probably not supported for iOS
}

void DisplayServerAppleEmbedded::window_set_max_size(const Size2i p_size, DisplayServerEnums::WindowID p_window) {
#ifdef VISIONOS_ENABLED
	if (p_window == DisplayServerEnums::MAIN_WINDOW_ID) {
		main_window_max_size = p_size;
	} else if (SubWindowData *data = sub_windows.getptr(p_window)) {
		data->max_size = p_size;
	}
	window_set_size(window_get_size(p_window), p_window);
#endif
}

Size2i DisplayServerAppleEmbedded::window_get_max_size(DisplayServerEnums::WindowID p_window) const {
#ifdef VISIONOS_ENABLED
	if (p_window == DisplayServerEnums::MAIN_WINDOW_ID) { return main_window_max_size; }
	if (const SubWindowData *data = sub_windows.getptr(p_window)) { return data->max_size; }
#endif
	return Size2i();
}

void DisplayServerAppleEmbedded::window_set_min_size(const Size2i p_size, DisplayServerEnums::WindowID p_window) {
#ifdef VISIONOS_ENABLED
	if (p_window == DisplayServerEnums::MAIN_WINDOW_ID) {
		main_window_min_size = p_size;
	} else if (SubWindowData *data = sub_windows.getptr(p_window)) {
		data->min_size = p_size;
	}
	window_set_size(window_get_size(p_window), p_window);
#endif
}

Size2i DisplayServerAppleEmbedded::window_get_min_size(DisplayServerEnums::WindowID p_window) const {
#ifdef VISIONOS_ENABLED
	if (p_window == DisplayServerEnums::MAIN_WINDOW_ID) { return main_window_min_size; }
	if (const SubWindowData *data = sub_windows.getptr(p_window)) { return data->min_size; }
#endif
	return Size2i();
}

void DisplayServerAppleEmbedded::window_set_size(const Size2i p_size, DisplayServerEnums::WindowID p_window) {
#ifdef VISIONOS_ENABLED
	if (p_size.x <= 0 || p_size.y <= 0) { return; }
	UIViewController *controller = nil;
	Size2i min_size;
	Size2i max_size;
	if (p_window == DisplayServerEnums::MAIN_WINDOW_ID) {
		controller = GDTAppDelegateService.viewController;
		min_size = main_window_min_size;
		max_size = main_window_max_size;
	} else if (SubWindowData *data = sub_windows.getptr(p_window)) {
		data->requested_size = p_size;
		controller = (__bridge UIViewController *)data->controller;
		min_size = data->min_size;
		max_size = data->max_size;
	}
	UIWindowScene *scene = controller.viewIfLoaded.window.windowScene;
	if (scene) {
		CGSize points = CGSizeMake(p_size.x / screen_get_scale(), p_size.y / screen_get_scale());
		UIWindowSceneGeometryPreferencesVision *preferences = [[UIWindowSceneGeometryPreferencesVision alloc] initWithSize:points];
		preferences.resizingRestrictions = window_get_flag(DisplayServerEnums::WINDOW_FLAG_RESIZE_DISABLED, p_window) ? UIWindowSceneResizingRestrictionsNone : UIWindowSceneResizingRestrictionsFreeform;
		const CGFloat unchanged = UIProposedSceneSizeNoPreference;
		preferences.minimumSize = CGSizeMake(min_size.x > 0 ? min_size.x / screen_get_scale() : unchanged, min_size.y > 0 ? min_size.y / screen_get_scale() : unchanged);
		preferences.maximumSize = CGSizeMake(max_size.x > 0 ? max_size.x / screen_get_scale() : unchanged, max_size.y > 0 ? max_size.y / screen_get_scale() : unchanged);
		[scene requestGeometryUpdateWithPreferences:preferences errorHandler:^(NSError *error) {
			WARN_PRINT(vformat("visionOS did not apply requested window size: %s", String::utf8(error.localizedDescription.UTF8String)));
		}];
	}
#endif
}

Size2i DisplayServerAppleEmbedded::window_get_size(DisplayServerEnums::WindowID p_window) const {
#ifdef VISIONOS_ENABLED
	if (p_window != DisplayServerEnums::MAIN_WINDOW_ID) {
		const SubWindowData *data = sub_windows.getptr(p_window);
		return data ? data->size : Size2i();
	}
#endif
	CGRect viewBounds = GDTAppDelegateService.viewController.view.bounds;
	return Size2i(viewBounds.size.width, viewBounds.size.height) * screen_get_max_scale();
}

Size2i DisplayServerAppleEmbedded::window_get_size_with_decorations(DisplayServerEnums::WindowID p_window) const {
	return window_get_size(p_window);
}

void DisplayServerAppleEmbedded::window_set_mode(DisplayServerEnums::WindowMode p_mode, DisplayServerEnums::WindowID p_window) {
	// Probably not supported for iOS
}

DisplayServerEnums::WindowMode DisplayServerAppleEmbedded::window_get_mode(DisplayServerEnums::WindowID p_window) const {
#ifdef VISIONOS_ENABLED
	return DisplayServerEnums::WINDOW_MODE_WINDOWED;
#endif
	return DisplayServerEnums::WindowMode::WINDOW_MODE_FULLSCREEN;
}

bool DisplayServerAppleEmbedded::window_is_maximize_allowed(DisplayServerEnums::WindowID p_window) const {
	return false;
}

void DisplayServerAppleEmbedded::window_set_flag(DisplayServerEnums::WindowFlags p_flag, bool p_enabled, DisplayServerEnums::WindowID p_window) {
#ifdef VISIONOS_ENABLED
	if (p_flag == DisplayServerEnums::WINDOW_FLAG_RESIZE_DISABLED) {
		if (p_window == DisplayServerEnums::MAIN_WINDOW_ID) { main_window_unresizable = p_enabled; }
		else if (SubWindowData *data = sub_windows.getptr(p_window)) { data->unresizable = p_enabled; }
		window_set_size(window_get_size(p_window), p_window);
		return;
	}
	if (p_flag == DisplayServerEnums::WINDOW_FLAG_TRANSPARENT) {
		if (p_window == DisplayServerEnums::MAIN_WINDOW_ID) { main_window_transparent = p_enabled; }
		UIViewController *controller = p_window == DisplayServerEnums::MAIN_WINDOW_ID ? GDTAppDelegateService.viewController : nil;
		if (p_window != DisplayServerEnums::MAIN_WINDOW_ID) {
			if (SubWindowData *data = sub_windows.getptr(p_window)) {
				data->transparent = p_enabled;
				controller = (__bridge UIViewController *)data->controller;
			}
		}
		if (controller) { controller.view.backgroundColor = p_enabled ? UIColor.clearColor : UIColor.blackColor; }
	}
#endif
}

bool DisplayServerAppleEmbedded::window_get_flag(DisplayServerEnums::WindowFlags p_flag, DisplayServerEnums::WindowID p_window) const {
#ifdef VISIONOS_ENABLED
	if (p_flag == DisplayServerEnums::WINDOW_FLAG_RESIZE_DISABLED) {
		if (p_window == DisplayServerEnums::MAIN_WINDOW_ID) { return main_window_unresizable; }
		if (const SubWindowData *data = sub_windows.getptr(p_window)) { return data->unresizable; }
	}
	if (p_flag == DisplayServerEnums::WINDOW_FLAG_TRANSPARENT) {
		if (p_window == DisplayServerEnums::MAIN_WINDOW_ID) { return main_window_transparent; }
		if (const SubWindowData *data = sub_windows.getptr(p_window)) { return data->transparent; }
	}
#endif
	return false;
}

void DisplayServerAppleEmbedded::window_request_attention(DisplayServerEnums::WindowID p_window) {
	// Probably not supported for iOS
}

void DisplayServerAppleEmbedded::window_move_to_foreground(DisplayServerEnums::WindowID p_window) {
#ifdef VISIONOS_ENABLED
	UIViewController *controller = nil;
	if (p_window == DisplayServerEnums::MAIN_WINDOW_ID) { controller = GDTAppDelegateService.viewController; }
	else if (SubWindowData *data = sub_windows.getptr(p_window)) { controller = (__bridge UIViewController *)data->controller; }
	UISceneSession *session = controller.viewIfLoaded.window.windowScene.session;
	if (session) {
		UISceneSessionActivationRequest *request = [UISceneSessionActivationRequest requestWithSession:session];
		[UIApplication.sharedApplication activateSceneSessionForRequest:request errorHandler:^(NSError *error) {
			WARN_PRINT(vformat("visionOS did not activate window: %s", String::utf8(error.localizedDescription.UTF8String)));
		}];
	}
#endif
}

bool DisplayServerAppleEmbedded::window_is_focused(DisplayServerEnums::WindowID p_window) const {
#ifdef VISIONOS_ENABLED
	if (p_window != DisplayServerEnums::MAIN_WINDOW_ID) {
		const SubWindowData *data = sub_windows.getptr(p_window);
		return data && data->focused;
	}
	return main_window_focused;
#endif
	return true;
}

float DisplayServerAppleEmbedded::screen_get_max_scale() const {
	return screen_get_scale(DisplayServerEnums::SCREEN_OF_MAIN_WINDOW);
}

void DisplayServerAppleEmbedded::screen_set_orientation(DisplayServerEnums::ScreenOrientation p_orientation, int p_screen) {
	p_screen = _get_screen_index(p_screen);
	int screen_count = get_screen_count();
	ERR_FAIL_INDEX(p_screen, screen_count);

	screen_orientation = p_orientation;
	if (@available(iOS 16.0, *)) {
		[GDTAppDelegateService.viewController setNeedsUpdateOfSupportedInterfaceOrientations];
	}
#if !defined(VISIONOS_ENABLED)
	else {
		[UIViewController attemptRotationToDeviceOrientation];
	}
#endif
}

DisplayServerEnums::ScreenOrientation DisplayServerAppleEmbedded::screen_get_orientation(int p_screen) const {
	p_screen = _get_screen_index(p_screen);
	int screen_count = get_screen_count();
	ERR_FAIL_INDEX_V(p_screen, screen_count, DisplayServerEnums::SCREEN_LANDSCAPE);

	return screen_orientation;
}

bool DisplayServerAppleEmbedded::window_can_draw(DisplayServerEnums::WindowID p_window) const {
#ifdef VISIONOS_ENABLED
	if (p_window != DisplayServerEnums::MAIN_WINDOW_ID) {
		const SubWindowData *data = sub_windows.getptr(p_window);
		return data && data->controller;
	}
#endif
	return true;
}

bool DisplayServerAppleEmbedded::can_any_window_draw() const {
	return true;
}

bool DisplayServerAppleEmbedded::is_touchscreen_available() const {
	return true;
}

_FORCE_INLINE_ int _convert_utf32_offset_to_utf16(const String &p_existing_text, int p_pos) {
	int limit = p_pos;
	for (int i = 0; i < MIN(p_existing_text.length(), p_pos); i++) {
		if (p_existing_text[i] > 0xffff) {
			limit++;
		}
	}
	return limit;
}

void DisplayServerAppleEmbedded::virtual_keyboard_show(const String &p_existing_text, const Rect2 &p_screen_rect, DisplayServerEnums::VirtualKeyboardType p_type, int p_max_length, int p_cursor_start, int p_cursor_end) {
	NSString *existingString = [[NSString alloc] initWithUTF8String:p_existing_text.utf8().get_data()];
	GDTViewController *controller = GDTAppDelegateService.viewController;
#ifdef VISIONOS_ENABLED
	if (focused_window_id != DisplayServerEnums::MAIN_WINDOW_ID) {
		if (SubWindowData *data = sub_windows.getptr(focused_window_id)) {
			controller = (__bridge GDTViewController *)data->controller;
		}
	}
#endif
	GDTKeyboardInputView *keyboard = controller.keyboardView;
	if (!keyboard) { return; }

	keyboard.keyboardType = UIKeyboardTypeDefault;
	keyboard.textContentType = nil;
	switch (p_type) {
		case DisplayServerEnums::KEYBOARD_TYPE_DEFAULT: {
			keyboard.keyboardType = UIKeyboardTypeDefault;
		} break;
		case DisplayServerEnums::KEYBOARD_TYPE_MULTILINE: {
			keyboard.keyboardType = UIKeyboardTypeDefault;
		} break;
		case DisplayServerEnums::KEYBOARD_TYPE_NUMBER: {
			keyboard.keyboardType = UIKeyboardTypeNumberPad;
		} break;
		case DisplayServerEnums::KEYBOARD_TYPE_NUMBER_DECIMAL: {
			keyboard.keyboardType = UIKeyboardTypeDecimalPad;
		} break;
		case DisplayServerEnums::KEYBOARD_TYPE_PHONE: {
			keyboard.keyboardType = UIKeyboardTypePhonePad;
			keyboard.textContentType = UITextContentTypeTelephoneNumber;
		} break;
		case DisplayServerEnums::KEYBOARD_TYPE_EMAIL_ADDRESS: {
			keyboard.keyboardType = UIKeyboardTypeEmailAddress;
			keyboard.textContentType = UITextContentTypeEmailAddress;
		} break;
		case DisplayServerEnums::KEYBOARD_TYPE_PASSWORD: {
			keyboard.keyboardType = UIKeyboardTypeDefault;
			keyboard.textContentType = UITextContentTypePassword;
		} break;
		case DisplayServerEnums::KEYBOARD_TYPE_URL: {
			keyboard.keyboardType = UIKeyboardTypeWebSearch;
			keyboard.textContentType = UITextContentTypeURL;
		} break;
	}

	[keyboard
			becomeFirstResponderWithString:existingString
							   cursorStart:_convert_utf32_offset_to_utf16(p_existing_text, p_cursor_start)
								 cursorEnd:_convert_utf32_offset_to_utf16(p_existing_text, p_cursor_end)];
}

bool DisplayServerAppleEmbedded::is_keyboard_active(DisplayServerEnums::WindowID p_window) const {
	GDTViewController *controller = GDTAppDelegateService.viewController;
#ifdef VISIONOS_ENABLED
	if (p_window != DisplayServerEnums::MAIN_WINDOW_ID) {
		if (const SubWindowData *data = sub_windows.getptr(p_window)) { controller = (__bridge GDTViewController *)data->controller; }
	}
#endif
	return [controller.keyboardView isFirstResponder];
}

void DisplayServerAppleEmbedded::virtual_keyboard_hide() {
	GDTViewController *controller = GDTAppDelegateService.viewController;
#ifdef VISIONOS_ENABLED
	if (focused_window_id != DisplayServerEnums::MAIN_WINDOW_ID) {
		if (SubWindowData *data = sub_windows.getptr(focused_window_id)) { controller = (__bridge GDTViewController *)data->controller; }
	}
#endif
	[controller.keyboardView resignFirstResponder];
}

void DisplayServerAppleEmbedded::virtual_keyboard_set_height(int height) {
	virtual_keyboard_height = height * screen_get_max_scale();
}

int DisplayServerAppleEmbedded::virtual_keyboard_get_height() const {
	return virtual_keyboard_height;
}

bool DisplayServerAppleEmbedded::has_hardware_keyboard() const {
	if (@available(iOS 14.0, *)) {
		return [GCKeyboard coalescedKeyboard];
	} else {
		return false;
	}
}

void DisplayServerAppleEmbedded::clipboard_set(const String &p_text) {
	[UIPasteboard generalPasteboard].string = [NSString stringWithUTF8String:p_text.utf8().get_data()];
}

String DisplayServerAppleEmbedded::clipboard_get() const {
	NSString *text = [UIPasteboard generalPasteboard].string;

	return String::utf8([text UTF8String]);
}

void DisplayServerAppleEmbedded::screen_set_keep_on(bool p_enable) {
	[UIApplication sharedApplication].idleTimerDisabled = p_enable;
}

bool DisplayServerAppleEmbedded::screen_is_kept_on() const {
	return [UIApplication sharedApplication].idleTimerDisabled;
}

void DisplayServerAppleEmbedded::resize_window(CGSize viewSize, DisplayServerEnums::WindowID p_window) {
	Size2i size = Size2i(viewSize.width, viewSize.height) * screen_get_max_scale();
	Callable callback = window_resize_callback;
	#ifdef VISIONOS_ENABLED
	if (p_window != DisplayServerEnums::MAIN_WINDOW_ID) {
		SubWindowData *data = sub_windows.getptr(p_window);
		if (!data || !data->controller) { return; }
		data->size = size;
		callback = data->resize_callback;
	}
	#endif

#if defined(RD_ENABLED)
	if (rendering_context) {
		rendering_context->window_set_size(p_window, size.x, size.y);
	}
#endif

	Variant resize_rect = Rect2i(Point2i(), size);
	_window_callback(callback, resize_rect);
}

void DisplayServerAppleEmbedded::window_set_vsync_mode(DisplayServerEnums::VSyncMode p_vsync_mode, DisplayServerEnums::WindowID p_window) {
	_THREAD_SAFE_METHOD_
#if defined(RD_ENABLED)
	if (rendering_context) {
		rendering_context->window_set_vsync_mode(p_window, p_vsync_mode);
	}
#endif
}

DisplayServerEnums::VSyncMode DisplayServerAppleEmbedded::window_get_vsync_mode(DisplayServerEnums::WindowID p_window) const {
	_THREAD_SAFE_METHOD_
#if defined(RD_ENABLED)
	if (rendering_context) {
		return rendering_context->window_get_vsync_mode(p_window);
	}
#endif
	return DisplayServerEnums::VSYNC_ENABLED;
}

// MARK: - HDR / EDR

void DisplayServerAppleEmbedded::_update_hdr_output(bool edr_headroom_changed) {
#ifdef RD_ENABLED
	if (!rendering_context) {
		return;
	}

	bool desired = edr_requested && _screen_hdr_is_supported();
	bool hdr_state_changed = rendering_context->window_get_hdr_output_enabled(DisplayServerEnums::MAIN_WINDOW_ID) != desired;
	if (hdr_state_changed) {
		rendering_context->window_set_hdr_output_enabled(DisplayServerEnums::MAIN_WINDOW_ID, desired);
	}

	float reference_luminance = _calculate_current_reference_luminance();
	rendering_context->window_set_hdr_output_reference_luminance(DisplayServerEnums::MAIN_WINDOW_ID, reference_luminance);
	rendering_context->window_set_hdr_output_linear_luminance_scale(DisplayServerEnums::MAIN_WINDOW_ID, reference_luminance);

	float max_luminance = _screen_potential_edr_headroom() * hardware_reference_luminance_nits;
	rendering_context->window_set_hdr_output_max_luminance(DisplayServerEnums::MAIN_WINDOW_ID, max_luminance);

	if (hdr_state_changed || edr_headroom_changed) {
		send_window_event(DisplayServerEnums::WINDOW_EVENT_OUTPUT_MAX_LINEAR_VALUE_CHANGED);
	}
#endif
}

void DisplayServerAppleEmbedded::current_edr_headroom_changed() {
	_update_hdr_output(true);
}

bool DisplayServerAppleEmbedded::window_is_hdr_output_supported(DisplayServerEnums::WindowID p_window) const {
#if defined(RD_ENABLED)
	if (rendering_device && !rendering_device->has_feature(RenderingDevice::Features::SUPPORTS_HDR_OUTPUT)) {
		return false;
	}
#endif
	return _screen_hdr_is_supported();
}

void DisplayServerAppleEmbedded::window_request_hdr_output(const bool p_enabled, DisplayServerEnums::WindowID p_window) {
#if defined(RD_ENABLED)
	ERR_FAIL_COND_MSG(p_enabled && rendering_device && !rendering_device->has_feature(RenderingDevice::Features::SUPPORTS_HDR_OUTPUT), "HDR output is not supported by the rendering device.");
#endif

	edr_requested = p_enabled;
	_update_hdr_output(false);
}

bool DisplayServerAppleEmbedded::window_is_hdr_output_requested(DisplayServerEnums::WindowID p_window) const {
	return edr_requested;
}

bool DisplayServerAppleEmbedded::window_is_hdr_output_enabled(DisplayServerEnums::WindowID p_window) const {
#if defined(RD_ENABLED)
	if (rendering_context) {
		return rendering_context->window_get_hdr_output_enabled(p_window);
	}
#endif
	return false;
}

void DisplayServerAppleEmbedded::window_set_hdr_output_reference_luminance(const float p_reference_luminance, DisplayServerEnums::WindowID p_window) {
	ERR_PRINT_ONCE("Manually setting reference white luminance is not supported on Apple devices, as they provide a user-facing brightness setting that directly controls reference white luminance.");
}

float DisplayServerAppleEmbedded::window_get_hdr_output_reference_luminance(DisplayServerEnums::WindowID p_window) const {
	return -1.0f; // Always auto-adjusted by the OS on Apple platforms.
}

float DisplayServerAppleEmbedded::_calculate_current_reference_luminance() const {
	float potential = _screen_potential_edr_headroom();
	float current = _screen_current_edr_headroom();
	return potential * hardware_reference_luminance_nits / current;
}

float DisplayServerAppleEmbedded::window_get_hdr_output_current_reference_luminance(DisplayServerEnums::WindowID p_window) const {
#if defined(RD_ENABLED)
	if (rendering_context) {
		return rendering_context->window_get_hdr_output_reference_luminance(p_window);
	}
#endif
	return 200.0f;
}

void DisplayServerAppleEmbedded::window_set_hdr_output_max_luminance(const float p_max_luminance, DisplayServerEnums::WindowID p_window) {
	ERR_PRINT_ONCE("Manually setting max luminance is not supported on Apple embedded devices as they provide accurate max luminance values for their built-in screens.");
}

float DisplayServerAppleEmbedded::window_get_hdr_output_max_luminance(DisplayServerEnums::WindowID p_window) const {
	return -1.0f;
}

float DisplayServerAppleEmbedded::window_get_hdr_output_current_max_luminance(DisplayServerEnums::WindowID p_window) const {
	return _screen_potential_edr_headroom() * hardware_reference_luminance_nits;
}

float DisplayServerAppleEmbedded::window_get_output_max_linear_value(DisplayServerEnums::WindowID p_window) const {
#if defined(RD_ENABLED)
	if (rendering_context) {
		return rendering_context->window_get_output_max_linear_value(p_window);
	}
#endif
	return 1.0f;
}

void DisplayServerAppleEmbedded::set_native_icon(const String &p_filename) {
	// Not supported on Apple embedded platforms.
}

void DisplayServerAppleEmbedded::set_icon(const Ref<Image> &p_icon) {
	// Not supported on Apple embedded platforms.
}

Error DisplayServerAppleEmbedded::file_dialog_show(const String &p_title, const String &p_current_directory, const String &p_filename, bool p_show_hidden, DisplayServerEnums::FileDialogMode p_mode, const Vector<String> &p_filters, const Callable &p_callback, DisplayServerEnums::WindowID p_window_id) {
	return AppleNativeFileDialog::show(p_title, p_current_directory, p_mode, p_filters, p_callback, p_window_id);
}
void DisplayServerAppleEmbedded::file_dialog_cancel(const Callable &p_callback) {
	AppleNativeFileDialog::cancel(p_callback);
}
