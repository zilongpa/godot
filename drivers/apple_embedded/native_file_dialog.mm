/**************************************************************************/
/*  native_file_dialog.mm                                                      */
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

#include "native_file_dialog.h"
#include "core/os/mutex.h"
#import "document_access.h"
#import "godot_app_delegate_service_apple_embedded.h"
#import "godot_view_controller.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

namespace {
Mutex request_mutex;
uint64_t next_request = 0;
uint64_t active_request = 0;
Callable active_callback;
Callable host_provider;
Callable host_finished;

bool is_active(uint64_t p_id) {
	MutexLock lock(request_mutex);
	return active_request == p_id;
}

bool complete(uint64_t p_id, bool p_ok, const Vector<String> &p_files) {
	MutexLock lock(request_mutex);
	if (active_request != p_id) { return false; }
	Callable callback = active_callback;
	active_callback = Callable();
	active_request = 0;
	if (callback.is_valid()) { callback.call_deferred(p_ok, p_files, 0); }
	return true;
}
}

@interface GDTNativeFileDialog : NSObject <UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate> {
@public
	uint64_t request_id;
	DisplayServerEnums::WindowID window_id;
	Callable finished;
	Vector<String> patterns;
	Vector<String> mime_types;
}
@property(nonatomic, strong) UIDocumentPickerViewController *picker;
@property(nonatomic, strong) NSFileCoordinator *reader;
@property(nonatomic, weak) UIScene *hostScene;
@property(nonatomic) BOOL reading;
@property(nonatomic) BOOL presenting;
@property(nonatomic, copy) dispatch_block_t finalizer;
@property(nonatomic) BOOL ended;
@property(nonatomic) BOOL notified;
- (void)finish:(NSArray<NSURL *> *)urls error:(NSString *)error;
- (BOOL)matchesURL:(NSURL *)url;
- (void)dismissWhenReady;
@end

static GDTNativeFileDialog *current_dialog;

// UIKit can delay the first document presentation while loading its service.
// A canceled presentation must settle before another is submitted to that host.
static void after_previous_dialog(uint64_t p_id, dispatch_block_t p_present, int p_attempt = 0) {
	if (!is_active(p_id)) { return; }
	if (!current_dialog) { p_present(); return; }
	if (p_attempt == 100) {
		ERR_PRINT("The previous system file dialog has not finished closing.");
		complete(p_id, false, Vector<String>());
		return;
	}
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 10), dispatch_get_main_queue(), ^{
		after_previous_dialog(p_id, p_present, p_attempt + 1);
	});
}

@implementation GDTNativeFileDialog
- (void)dismissWhenReady {
	if (self.presenting || !self.finalizer) { return; }
	dispatch_block_t done = self.finalizer;
	if (self.picker.presentingViewController) {
		[self.picker dismissViewControllerAnimated:NO completion:done];
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), done);
	} else { done(); }
}
- (void)disconnected:(NSNotification *)notification {
	if (notification.object == self.hostScene) {
		self.presenting = NO;
		[self finish:nil error:nil];
		[self dismissWhenReady];
	}
}
- (void)finish:(NSArray<NSURL *> *)urls error:(NSString *)error {
	if (self.ended) { return; }
	self.ended = YES;
	if (!urls) { [self.reader cancel]; }
	[[NSNotificationCenter defaultCenter] removeObserver:self];
	if (error && is_active(request_id)) { ERR_PRINT(String::utf8(error.UTF8String)); }
	Vector<String> paths;
	if (urls && is_active(request_id)) {
		[GodotDocumentAccess rememberURLs:urls];
		for (NSURL *url in urls) { paths.push_back(String::utf8(url.path.UTF8String)); }
	}
	// Dismiss before making completion visible to Godot, so callbacks may reopen.
	void (^done)(void) = ^{
		if (!self.presenting && !self.picker.presentingViewController) {
			if (current_dialog == self) { current_dialog = nil; }
			self.finalizer = nil;
		}
		if (self.notified) { return; }
		self.notified = YES;
		if (self->finished.is_valid()) { self->finished.call_deferred(self->window_id); }
		complete(self->request_id, !paths.is_empty(), paths);
	};
	self.finalizer = done;
	[self dismissWhenReady];
}
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
	if (controller == self.picker) { [self finish:nil error:nil]; }
}
- (void)presentationControllerDidDismiss:(UIPresentationController *)controller {
	[self finish:nil error:nil];
}
- (BOOL)matchesURL:(NSURL *)url {
	if (patterns.is_empty() && mime_types.is_empty()) { return YES; }
	String name = String::utf8(url.lastPathComponent.UTF8String);
	for (const String &pattern : patterns) {
		if (pattern == "*" || pattern == "*.*" || name.matchn(pattern)) { return YES; }
	}
	BOOL scoped = [url startAccessingSecurityScopedResource];
	UTType *actual = nil;
	[url getResourceValue:&actual forKey:NSURLContentTypeKey error:nil];
	if (!actual) { actual = [UTType typeWithFilenameExtension:url.pathExtension]; }
	if (scoped) { [url stopAccessingSecurityScopedResource]; }
	for (const String &mime : mime_types) {
		if (mime == "*/*" || mime == "application/octet-stream") { return YES; }
		UTType *type = [UTType typeWithMIMEType:@(mime.utf8().get_data())];
		if (type && [actual conformsToType:type]) { return YES; }
		if (actual.preferredMIMEType && String::utf8(actual.preferredMIMEType.UTF8String).matchn(mime)) { return YES; }
	}
	return NO;
}
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
	if (controller != self.picker || self.ended || self.reading) { return; }
	if (!urls.count) { [self finish:nil error:nil]; return; }
	self.reading = YES;
	self.reader = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
	// Providers can download during coordination. Never block the UI thread.
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		NSString *failure = nil;
		for (NSURL *url in urls) {
			if (!is_active(self->request_id)) { return; }
			if (![self matchesURL:url]) { failure = @"The selected file does not match the requested file types."; break; }
			NSError *error = nil;
			if (![GodotDocumentAccess validateURL:url coordinator:self.reader error:&error]) {
				failure = error.localizedDescription ?: @"The selected file could not be read.";
				break;
			}
		}
		dispatch_async(dispatch_get_main_queue(), ^{ [self finish:failure ? nil : urls error:failure]; });
	});
}
@end

void AppleNativeFileDialog::set_host_callbacks(const Callable &p_get_host, const Callable &p_finished) {
	MutexLock lock(request_mutex);
	host_provider = p_get_host;
	host_finished = p_finished;
}

Error AppleNativeFileDialog::show(const String &p_title, const String &p_directory, DisplayServerEnums::FileDialogMode p_mode, const Vector<String> &p_filters, const Callable &p_callback, DisplayServerEnums::WindowID p_window) {
#ifndef VISIONOS_ENABLED
	return ERR_UNAVAILABLE;
#else
	if (p_mode != DisplayServerEnums::FILE_DIALOG_MODE_OPEN_FILE && p_mode != DisplayServerEnums::FILE_DIALOG_MODE_OPEN_FILES) { return ERR_UNAVAILABLE; }
	if (!p_callback.is_valid()) { return ERR_INVALID_PARAMETER; }
	uint64_t id;
	Callable provider;
	Callable finished;
	{
		MutexLock lock(request_mutex);
		if (active_request) { return ERR_BUSY; }
		id = ++next_request;
		active_request = id;
		active_callback = p_callback;
		provider = host_provider;
		finished = host_finished;
	}
	// Blocks must own request arguments; callers often pass temporary Strings.
	const String title = p_title;
	const String directory = p_directory;
	const Vector<String> filters = p_filters;
	dispatch_async(dispatch_get_main_queue(), ^{
		after_previous_dialog(id, ^{
		if (!is_active(id)) { return; }
		GDTNativeFileDialog *dialog = [[GDTNativeFileDialog alloc] init];
		dialog->request_id = id;
		dialog->window_id = p_window;
		dialog->finished = finished;
		current_dialog = dialog;
		UIViewController *host = nil;
		if (provider.is_valid()) {
			int64_t handle = provider.call(p_window);
			host = (__bridge UIViewController *)(void *)handle;
		} else if (p_window == DisplayServerEnums::MAIN_WINDOW_ID || p_window == DisplayServerEnums::INVALID_WINDOW_ID) {
			host = GDTAppDelegateService.viewController;
		}
		if (!host.viewIfLoaded.window || host.presentedViewController) {
			[dialog finish:nil error:@"The requesting window is unavailable or already presenting a system dialog."];
			return;
		}
		dialog.hostScene = host.view.window.windowScene;
		[[NSNotificationCenter defaultCenter] addObserver:dialog selector:@selector(disconnected:) name:UISceneDidDisconnectNotification object:dialog.hostScene];
		NSMutableArray<UTType *> *types = [NSMutableArray array];
		BOOL unrestricted = NO;
		// UIKit has no filter-group menu. FileDialog's first group is All Recognized
		// (or its only filter); the synthetic All Files entry must not bypass it.
		if (!filters.is_empty()) {
			String filter = filters[0];
			for (String pattern : filter.get_slicec(';', 0).split(",", false)) {
				pattern = pattern.strip_edges();
				dialog->patterns.push_back(pattern);
				UTType *type = pattern.begins_with("*.") ? [UTType typeWithFilenameExtension:@(pattern.substr(2).utf8().get_data())] : nil;
				if (!type || type.dynamic) { unrestricted = YES; } else { [types addObject:type]; }
			}
			for (String mime : filter.get_slicec(';', 2).split(",", false)) {
				mime = mime.strip_edges();
				dialog->mime_types.push_back(mime);
				UTType *type = [UTType typeWithMIMEType:@(mime.utf8().get_data())];
				if (!type || type.dynamic) { unrestricted = YES; } else { [types addObject:type]; }
			}
		}
		if (unrestricted || !types.count) { types = [NSMutableArray arrayWithObject:UTTypeData]; }
		UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types asCopy:NO];
		picker.allowsMultipleSelection = p_mode == DisplayServerEnums::FILE_DIALOG_MODE_OPEN_FILES;
		picker.title = @(title.utf8().get_data());
		if (!directory.is_empty()) { picker.directoryURL = [NSURL fileURLWithPath:@(directory.utf8().get_data()) isDirectory:YES]; }
		picker.delegate = dialog;
		dialog.picker = picker;
		dialog.presenting = YES;
		@try {
			[host presentViewController:picker animated:NO completion:^{
				dialog.presenting = NO;
				picker.presentationController.delegate = dialog;
				if (dialog.ended) { [dialog dismissWhenReady]; }
			}];
		} @catch (NSException *exception) {
			dialog.presenting = NO;
			[dialog finish:nil error:exception.reason];
		}
		// UIKit can reject presentation without throwing or invoking completion.
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
			if (dialog.ended && picker.presentingViewController) {
				dialog.presenting = NO;
				[dialog dismissWhenReady];
			} else if (!dialog.reading && !picker.presentingViewController) {
				[dialog finish:nil error:@"The system file picker could not be presented in this window."];
				// End the request even if UIKit never calls its presentation completion.
				// Retain cleanup state so a delayed completion still dismisses the picker.
				if (dialog.finalizer) { dialog.finalizer(); }
			}
		});
		});
	});
	return OK;
#endif
}

void AppleNativeFileDialog::cancel(const Callable &p_callback) {
	uint64_t id;
	{
		MutexLock lock(request_mutex);
		if (!active_request || active_callback != p_callback) { return; }
		id = active_request;
		active_request = 0;
		active_callback = Callable();
	}
	dispatch_async(dispatch_get_main_queue(), ^{
		if (current_dialog && current_dialog->request_id == id) { [current_dialog finish:nil error:nil]; }
	});
}
