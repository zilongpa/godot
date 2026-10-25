/**************************************************************************/
/*  mathjax.h                                                             */
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

#include "core/object/class_db.h"
#include "core/os/mutex.h"
#include "core/os/semaphore.h"

struct JSRuntime;
struct JSContext;

// Typesets TeX formulas as SVG with MathJax, run by QuickJS. MathJax loads the
// first time a formula is asked for, on a thread of its own with the deep
// stack its recursive parser wants, and stays loaded.
class MathJax : public Object {
	GDCLASS(MathJax, Object);

	static MathJax *singleton;

	Mutex mutex;
	// The thread serves one job at a time: it waits for a request, typesets
	// the formula and posts that it's done.
	Semaphore request;
	Semaphore done;
	bool started = false;
	bool quit = false;
	String tex;
	bool display = false;
	String svg;
	String error_message;

	JSRuntime *runtime = nullptr;
	JSContext *context = nullptr;

	Error _start();
	void _run();
	Error _load();
	void _typeset();
	String _take_error();

protected:
	static void _bind_methods();

public:
	static MathJax *get_singleton() { return singleton; }
	static void _thread_main(void *p_mathjax);

	String tex_to_svg(const String &p_tex, bool p_display = false);
	String get_error_message() const;

	MathJax();
	~MathJax();
};
