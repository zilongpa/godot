/**************************************************************************/
/*  file_access_apple_embedded.mm                                                      */
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

#include "file_access_apple_embedded.h"
#import "document_access.h"

void FileAccessAppleEmbedded::coordinate(void (^p_read)(NSURL *)) const {
	NSError *error = nil;
	NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
	[coordinator coordinateReadingItemAtURL:document_url options:0 error:&error byAccessor:p_read];
	coordination_error = error ? ERR_FILE_CANT_READ : OK;
}

Error FileAccessAppleEmbedded::open_internal(const String &p_path, int p_mode_flags) {
	close();
	document_url = [GodotDocumentAccess URLForPath:@(fix_path(p_path).utf8().get_data())];
	if (!document_url) {
		return FileAccessUnix::open_internal(p_path, p_mode_flags);
	}
	if (p_mode_flags != READ) {
		document_url = nil;
		return ERR_UNAVAILABLE;
	}
	scoped = [document_url startAccessingSecurityScopedResource];
	__block Error result = ERR_FILE_CANT_OPEN;
	coordinate(^(NSURL *url) {
		result = FileAccessUnix::open_internal(String::utf8(url.path.UTF8String), p_mode_flags);
	});
	if (coordination_error != OK) { result = coordination_error; }
	if (result != OK) { close(); }
	return result;
}

uint64_t FileAccessAppleEmbedded::get_buffer(uint8_t *p_dst, uint64_t p_length) const {
	if (!document_url) { return FileAccessUnix::get_buffer(p_dst, p_length); }
	__block uint64_t count = 0;
	coordinate(^(NSURL *url) { count = FileAccessUnix::get_buffer(p_dst, p_length); });
	return count;
}

uint64_t FileAccessAppleEmbedded::get_length() const {
	if (!document_url) { return FileAccessUnix::get_length(); }
	__block uint64_t length = 0;
	coordinate(^(NSURL *url) { length = FileAccessUnix::get_length(); });
	return length;
}

void FileAccessAppleEmbedded::seek_end(int64_t p_position) {
	if (!document_url) { FileAccessUnix::seek_end(p_position); return; }
	coordinate(^(NSURL *url) { FileAccessUnix::seek_end(p_position); });
}

Error FileAccessAppleEmbedded::get_error() const {
	return coordination_error != OK ? coordination_error : FileAccessUnix::get_error();
}

bool FileAccessAppleEmbedded::file_exists(const String &p_path) {
	NSURL *url = [GodotDocumentAccess URLForPath:@(fix_path(p_path).utf8().get_data())];
	if (!url) { return FileAccessUnix::file_exists(p_path); }
	NSError *error = nil;
	return [GodotDocumentAccess validateURL:url error:&error];
}

int64_t FileAccessAppleEmbedded::_get_size(const String &p_path) {
	NSURL *url = [GodotDocumentAccess URLForPath:@(fix_path(p_path).utf8().get_data())];
	if (!url) { return FileAccessUnix::_get_size(p_path); }
	BOOL access = [url startAccessingSecurityScopedResource];
	__block int64_t size = -1;
	NSError *error = nil;
	NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
	[coordinator coordinateReadingItemAtURL:url options:0 error:&error byAccessor:^(NSURL *item) {
		size = FileAccessUnix::_get_size(String::utf8(item.path.UTF8String));
	}];
	if (access) { [url stopAccessingSecurityScopedResource]; }
	return size;
}

uint64_t FileAccessAppleEmbedded::_get_modified_time(const String &p_path) {
	NSURL *url = [GodotDocumentAccess URLForPath:@(fix_path(p_path).utf8().get_data())];
	if (!url) { return FileAccessUnix::_get_modified_time(p_path); }
	BOOL access = [url startAccessingSecurityScopedResource];
	__block uint64_t time = 0;
	NSError *error = nil;
	NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
	[coordinator coordinateReadingItemAtURL:url options:0 error:&error byAccessor:^(NSURL *item) {
		time = FileAccessUnix::_get_modified_time(String::utf8(item.path.UTF8String));
	}];
	if (access) { [url stopAccessingSecurityScopedResource]; }
	return time;
}

void FileAccessAppleEmbedded::close() {
	FileAccessUnix::close();
	if (scoped) { [document_url stopAccessingSecurityScopedResource]; }
	scoped = false;
	document_url = nil;
	coordination_error = OK;
}
FileAccessAppleEmbedded::~FileAccessAppleEmbedded() { close(); }
