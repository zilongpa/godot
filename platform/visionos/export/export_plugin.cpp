/**************************************************************************/
/*  export_plugin.cpp                                                     */
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

#include "export_plugin.h"

#include "logo_svg.gen.h"
#include "run_icon_svg.gen.h"

#include "core/io/dir_access.h"
#include "core/io/file_access.h"
#include "editor/editor_node.h"

Vector<String> EditorExportPlatformVisionOS::device_types({ "realityDevice" });

void EditorExportPlatformVisionOS::initialize() {
	if (EditorNode::get_singleton()) {
		EditorExportPlatformAppleEmbedded::_initialize(_visionos_logo_svg, _visionos_run_icon_svg);
#ifdef MACOS_ENABLED
		_start_remote_device_poller_thread();
#endif
	}
}

EditorExportPlatformVisionOS::~EditorExportPlatformVisionOS() {
#ifdef MACOS_ENABLED
	_stop_remote_device_poller_thread();
#endif
}

void EditorExportPlatformVisionOS::get_export_options(List<ExportOption> *r_options) const {
	EditorExportPlatformAppleEmbedded::get_export_options(r_options);

	// visionOS icons have no dark or tinted versions; they are a stack of
	// layers instead, from back to front.
	for (List<ExportOption>::Element *E = r_options->front(); E;) {
		List<ExportOption>::Element *next = E->next();
		if (E->get().option.name == "icons/icon_1024x1024_dark" || E->get().option.name == "icons/icon_1024x1024_tinted") {
			r_options->erase(E);
		}
		E = next;
	}
	r_options->push_back(ExportOption(PropertyInfo(Variant::STRING, "icons/icon_1024x1024_middle", PROPERTY_HINT_FILE_PATH, "*.svg,*.png,*.webp,*.jpg,*.jpeg"), ""));
	r_options->push_back(ExportOption(PropertyInfo(Variant::STRING, "icons/icon_1024x1024_front", PROPERTY_HINT_FILE_PATH, "*.svg,*.png,*.webp,*.jpg,*.jpeg"), ""));

	r_options->push_back(ExportOption(PropertyInfo(Variant::STRING, "application/min_visionos_version"), get_minimum_deployment_target()));

	r_options->push_back(ExportOption(PropertyInfo(Variant::INT, "application/app_role", PROPERTY_HINT_ENUM, "Window,Immersive"), 0));
	r_options->push_back(ExportOption(PropertyInfo(Variant::INT, "application/immersion_style", PROPERTY_HINT_ENUM, "Full,Mixed"), 1));
}

Vector<EditorExportPlatformAppleEmbedded::IconInfo> EditorExportPlatformVisionOS::get_icon_infos() const {
	return Vector<EditorExportPlatformAppleEmbedded::IconInfo>();
}

static Error _write_asset_contents(const String &p_dir, const String &p_json) {
	Error err = DirAccess::make_dir_recursive_absolute(p_dir);
	if (err != OK) {
		return err;
	}
	Ref<FileAccess> f = FileAccess::open(p_dir.path_join("Contents.json"), FileAccess::WRITE, &err);
	if (f.is_null()) {
		return err;
	}
	f->store_string(p_json);
	return OK;
}

// visionOS app icons are a stack of 1024×1024 layers that the system shows
// with depth: an opaque back layer and optional transparent ones in front.
Error EditorExportPlatformVisionOS::_export_icons(const Ref<EditorExportPreset> &p_preset, const String &p_iconset_dir) {
	const String info = "\"info\":{\"author\":\"xcode\",\"version\":1}";
	// The asset catalog's AppIcon is the stack, not an icon set of the same name.
	const String assets_dir = p_iconset_dir.trim_suffix("/").get_base_dir();
	DirAccess::remove_absolute(p_iconset_dir.trim_suffix("/"));
	const String stack_dir = assets_dir.path_join("AppIcon.solidimagestack");

	struct Layer {
		const char *name;
		const char *option;
	};
	const Layer layers[] = {
		{ "Front", "icons/icon_1024x1024_front" },
		{ "Middle", "icons/icon_1024x1024_middle" },
		{ "Back", "icons/icon_1024x1024" },
	};
	const int side = 1024;
	const Image::Interpolation interpolation = (Image::Interpolation)(p_preset->get("application/icon_interpolation").operator int());
	String stack_layers;
	for (const Layer &layer : layers) {
		const bool back = String(layer.name) == "Back";
		String path = p_preset->get(layer.option);
		if (path.is_empty() && back) {
			path = get_project_setting(p_preset, "application/config/icon");
		}
		if (path.is_empty()) {
			continue;
		}
		Error err = OK;
		Ref<Image> image = _load_icon_or_splash_image(path, &err);
		if (err != OK || image.is_null() || image->is_empty()) {
			add_message(EXPORT_MESSAGE_ERROR, TTR("Export Icons"), vformat("Invalid icon (%s): '%s'.", layer.option, path));
			return ERR_UNCONFIGURED;
		}
		image->convert(Image::FORMAT_RGBA8);
		if (image->get_width() != side || image->get_height() != side) {
			image->resize(side, side, interpolation);
		}
		if (back && image->detect_alpha() != Image::ALPHA_NONE) {
			// The back layer must be opaque; fill it with the boot splash color.
			const Color background = get_project_setting(p_preset, "application/boot_splash/bg_color");
			Ref<Image> opaque = Image::create_empty(side, side, false, Image::FORMAT_RGBA8);
			opaque->fill(Color(background.r, background.g, background.b, 1.0));
			opaque->blend_rect(image, Rect2i(0, 0, side, side), Point2i());
			image = opaque;
		}
		const String layer_dir = stack_dir.path_join(String(layer.name) + ".solidimagestacklayer");
		const String image_dir = layer_dir.path_join("Content.imageset");
		const String file = String(layer.name).to_lower() + ".png";
		err = _write_asset_contents(layer_dir, "{" + info + "}");
		if (err == OK) {
			err = _write_asset_contents(image_dir, "{\"images\":[{\"filename\":\"" + file + "\",\"idiom\":\"vision\",\"scale\":\"2x\"}]," + info + "}");
		}
		if (err == OK) {
			err = image->save_png(image_dir.path_join(file));
		}
		if (err != OK) {
			add_message(EXPORT_MESSAGE_ERROR, TTR("Export Icons"), vformat(TTR("Could not write to a file at path \"%s\"."), image_dir));
			return err;
		}
		if (!stack_layers.is_empty()) {
			stack_layers += ",";
		}
		stack_layers += "{\"filename\":\"" + String(layer.name) + ".solidimagestacklayer\"}";
	}
	return _write_asset_contents(stack_dir, "{" + info + ",\"layers\":[" + stack_layers + "]}");
}

String EditorExportPlatformVisionOS::_process_config_file_line(const Ref<EditorExportPreset> &p_preset, const String &p_line, const AppleEmbeddedConfigData &p_config, bool p_debug, const CodeSigningDetails &p_code_signing) {
	// Do visionOS specific processing first, and call super implementation if there are no matches

	String strnew;

	// Supported Destinations
	if (p_line.contains("$targeted_device_family")) {
		strnew += p_line.replace("$targeted_device_family", "7") + "\n";

		// MoltenVK Framework not used on visionOS
	} else if (p_line.contains("$moltenvk_buildfile")) {
		strnew += p_line.replace("$moltenvk_buildfile", "") + "\n";
	} else if (p_line.contains("$moltenvk_fileref")) {
		strnew += p_line.replace("$moltenvk_fileref", "") + "\n";
	} else if (p_line.contains("$moltenvk_buildphase")) {
		strnew += p_line.replace("$moltenvk_buildphase", "") + "\n";
	} else if (p_line.contains("$moltenvk_buildgrp")) {
		strnew += p_line.replace("$moltenvk_buildgrp", "") + "\n";

		// Launch Storyboard
	} else if (p_line.contains("$plist_launch_screen_name")) {
		// visionOS has no launch screens: it shows the app icon while the app
		// loads. The main window instead opens at the project's window size.
		int width = get_project_setting(p_preset, "display/window/size/window_width_override");
		int height = get_project_setting(p_preset, "display/window/size/window_height_override");
		if (width <= 0 || height <= 0) {
			width = get_project_setting(p_preset, "display/window/size/viewport_width");
			height = get_project_setting(p_preset, "display/window/size/viewport_height");
		}
		// A visionOS window has one pixel per point.
		String value =
				"<key>GodotMainWindow</key>\n"
				"<dict>\n"
				"	<key>Width</key>\n"
				"	<real>" +
				itos(width) + "</real>\n"
							  "	<key>Height</key>\n"
							  "	<real>" +
				itos(height) + "</real>\n"
							   "</dict>";
		strnew += p_line.replace("$plist_launch_screen_name", value) + "\n";
	} else if (p_line.contains("$pbx_launch_screen_file_reference")) {
		strnew += p_line.replace("$pbx_launch_screen_file_reference", "") + "\n";
	} else if (p_line.contains("$pbx_launch_screen_copy_files")) {
		strnew += p_line.replace("$pbx_launch_screen_copy_files", "") + "\n";
	} else if (p_line.contains("$pbx_launch_screen_build_phase")) {
		strnew += p_line.replace("$pbx_launch_screen_build_phase", "") + "\n";
	} else if (p_line.contains("$pbx_launch_screen_build_reference")) {
		strnew += p_line.replace("$pbx_launch_screen_build_reference", "") + "\n";

		// OS Deployment Target
	} else if (p_line.contains("$os_deployment_target")) {
		String min_version = p_preset->get("application/min_" + get_platform_name() + "_version");
		String value = "XROS_DEPLOYMENT_TARGET = " + min_version + ";";
		strnew += p_line.replace("$os_deployment_target", value) + "\n";

		// Valid Archs
	} else if (p_line.contains("$valid_archs")) {
		strnew += p_line.replace("$valid_archs", "arm64") + "\n";
	} else if (p_line.contains("<key>UIApplicationSupportsMultipleScenes</key>")) {
		strnew += p_line.replace("<false/>", "<true/>") + "\n";

		// Application Scene Manifest - Default Session Role
	} else if (p_line.contains("$application_scene_manifest_default_session_role")) {
		int app_role_enum = (int)p_preset->get("application/app_role");
		if (app_role_enum == 0) {
			// Windowed mode, not needed
			strnew += p_line.replace("$application_scene_manifest_default_session_role", "") + "\n";
			return strnew;
		}

		String value =
				"<key>UIApplicationPreferredDefaultSceneSessionRole</key>\n"
				"<string>CPSceneSessionRoleImmersiveSpaceApplication</string>";

		strnew += p_line.replace("$application_scene_manifest_default_session_role", value) + "\n";

		// Application Scene Manifest - Immersive Configuration
	} else if (p_line.contains("$application_scene_manifest_immersive_configuration")) {
		int app_role_enum = (int)p_preset->get("application/app_role");
		if (app_role_enum == 0) {
			// Windowed mode, not needed
			strnew += p_line.replace("$application_scene_manifest_immersive_configuration", "") + "\n";
			return strnew;
		}

		String initial_immersion_style;
		switch ((int)p_preset->get("application/immersion_style")) {
			case 0: // Full
				initial_immersion_style = "UIImmersionStyleFull";
				break;
			case 1: // Mixed
				initial_immersion_style = "UIImmersionStyleMixed";
				break;
		}

		String value =
				"<key>UISceneSessionRoleImmersiveSpaceApplication</key>\n"
				"<array>\n"
				"	<dict>\n"
				"		<key>UISceneInitialImmersionStyle</key>\n"
				"		<string>" +
				initial_immersion_style + "</string>\n"
										  "	</dict>\n"
										  "</array>";

		strnew += p_line.replace("$application_scene_manifest_immersive_configuration", value) + "\n";

		// Application Scene Manifest
	} else if (p_line.contains("$application_scene_manifest")) {
		int app_role_enum = (int)p_preset->get("application/app_role");
		if (app_role_enum == 0) {
			// Windowed mode, no Application Scene Manifest needed
			strnew += p_line.replace("$application_scene_manifest", "") + "\n";
			return strnew;
		}

		String initial_immersion_style;
		switch ((int)p_preset->get("application/immersion_style")) {
			case 0: // Full
				initial_immersion_style = "UIImmersionStyleFull";
				break;
			case 1: // Mixed
				initial_immersion_style = "UIImmersionStyleMixed";
				break;
		}

		String value =
				"<key>UIApplicationSceneManifest</key>\n"
				"<dict>\n"
				"	<key>UIApplicationPreferredDefaultSceneSessionRole</key>\n"
				"	<string>CPSceneSessionRoleImmersiveSpaceApplication</string>\n"
				"	  <key>UIApplicationSupportsMultipleScenes</key>\n"
				"	  <true/>\n"
				"	  <key>UISceneConfigurations</key>\n"
				"	  <dict>\n"
				"		  <key>UISceneSessionRoleImmersiveSpaceApplication</key>\n"
				"		  <array>\n"
				"			  <dict>\n"
				"				  <key>UISceneInitialImmersionStyle</key>\n"
				"				  <string>" +
				initial_immersion_style + "</string>\n"
										  "			  </dict>\n"
										  "		  </array>\n"
										  "	  </dict>\n"
										  "</dict>";

		strnew += p_line.replace("$application_scene_manifest", value) + "\n";

		// Apple Embedded common
	} else {
		strnew += EditorExportPlatformAppleEmbedded::_process_config_file_line(p_preset, p_line, p_config, p_debug, p_code_signing);
	}
	return strnew;
}
