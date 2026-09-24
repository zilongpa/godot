/**************************************************************************/
/*  file_access_apple_embedded.h                                                      */
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

#include "drivers/unix/file_access_unix.h"
#import <Foundation/Foundation.h>

class FileAccessAppleEmbedded : public FileAccessUnix {
	NSURL *document_url = nil;
	bool scoped = false;
	mutable Error coordination_error = OK;
	void coordinate(void (^p_read)(NSURL *)) const;

public:
	Error open_internal(const String &p_path, int p_mode_flags) override;
	uint64_t get_buffer(uint8_t *p_dst, uint64_t p_length) const override;
	uint64_t get_length() const override;
	void seek_end(int64_t p_position = 0) override;
	Error get_error() const override;
	bool file_exists(const String &p_path) override;
	int64_t _get_size(const String &p_path) override;
	uint64_t _get_modified_time(const String &p_path) override;
	void close() override;
	~FileAccessAppleEmbedded() override;
};
