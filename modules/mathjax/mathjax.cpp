/**************************************************************************/
/*  mathjax.cpp                                                           */
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

#include "mathjax.h"

#include "tex2svg.gen.h"

#include "core/io/compression.h"

#include <quickjs.h>

#ifdef WINDOWS_ENABLED
#include <windows.h>
#else
#include <pthread.h>
#endif

// MathJax's parser recurses deeply, so its thread gets a stack well beyond a
// main thread's, and JavaScript may use most of it.
static const size_t THREAD_STACK_SIZE = 16 * 1024 * 1024;
static const size_t JS_STACK_SIZE = 12 * 1024 * 1024;

MathJax *MathJax::singleton = nullptr;

void MathJax::_thread_main(void *p_mathjax) {
	static_cast<MathJax *>(p_mathjax)->_run();
}

#ifdef WINDOWS_ENABLED
static DWORD WINAPI mathjax_thread_entry(LPVOID p_mathjax) {
	MathJax::_thread_main(p_mathjax);
	return 0;
}
#else
static void *mathjax_thread_entry(void *p_mathjax) {
	MathJax::_thread_main(p_mathjax);
	return nullptr;
}
#endif

// Starts the thread, which loads MathJax. Returns when it's loaded.
Error MathJax::_start() {
	if (started) {
		return OK;
	}
#ifdef WINDOWS_ENABLED
	HANDLE thread = CreateThread(nullptr, THREAD_STACK_SIZE, mathjax_thread_entry, this, STACK_SIZE_PARAM_IS_A_RESERVATION, nullptr);
	ERR_FAIL_NULL_V_MSG(thread, FAILED, "Couldn't start MathJax's thread.");
	CloseHandle(thread);
#else
	pthread_attr_t attributes;
	pthread_attr_init(&attributes);
	pthread_attr_setstacksize(&attributes, THREAD_STACK_SIZE);
	pthread_attr_setdetachstate(&attributes, PTHREAD_CREATE_DETACHED);
	pthread_t thread;
	int error = pthread_create(&thread, &attributes, mathjax_thread_entry, this);
	pthread_attr_destroy(&attributes);
	ERR_FAIL_COND_V_MSG(error != 0, FAILED, "Couldn't start MathJax's thread.");
#endif
	started = true;
	done.wait();
	return OK;
}

// The thread: loads MathJax, then typesets each request until told to quit.
void MathJax::_run() {
	if (_load() != OK) {
		if (context) {
			JS_FreeContext(context);
			context = nullptr;
		}
		if (runtime) {
			JS_FreeRuntime(runtime);
			runtime = nullptr;
		}
	}
	done.post();
	while (true) {
		request.wait();
		if (quit) {
			break;
		}
		_typeset();
		done.post();
	}
	if (context) {
		JS_FreeContext(context);
	}
	if (runtime) {
		JS_FreeRuntime(runtime);
	}
	done.post();
}

Error MathJax::_load() {
	runtime = JS_NewRuntime();
	ERR_FAIL_NULL_V(runtime, ERR_OUT_OF_MEMORY);
	JS_SetMaxStackSize(runtime, JS_STACK_SIZE);
	context = JS_NewContext(runtime);
	ERR_FAIL_NULL_V(context, ERR_OUT_OF_MEMORY);

	// QuickJS wants the script zero-terminated.
	Vector<uint8_t> script;
	script.resize(_tex2svg_script_size + 1);
	int size = Compression::decompress(script.ptrw(), _tex2svg_script_size, _tex2svg_script_compressed, _tex2svg_script_compressed_size, Compression::MODE_DEFLATE);
	ERR_FAIL_COND_V(size != _tex2svg_script_size, ERR_INVALID_DATA);
	script.write[size] = 0;

	JSValue result = JS_Eval(context, (const char *)script.ptr(), size, "tex2svg.js", JS_EVAL_TYPE_GLOBAL);
	if (JS_IsException(result)) {
		ERR_FAIL_V_MSG(FAILED, "MathJax didn't load: " + _take_error());
	}
	JS_FreeValue(context, result);
	return OK;
}

// Typesets the request, on the thread.
void MathJax::_typeset() {
	svg = String();
	if (!context) {
		error_message = "MathJax didn't load.";
		return;
	}
	JSValue global = JS_GetGlobalObject(context);
	JSValue function = JS_GetPropertyStr(context, global, "tex2svg");
	JSValue args[2] = { JS_NewString(context, tex.utf8().get_data()), JS_NewBool(context, display) };
	JSValue result = JS_Call(context, function, JS_UNDEFINED, 2, args);
	if (JS_IsException(result)) {
		error_message = _take_error();
	} else {
		const char *text = JS_ToCString(context, result);
		svg = String::utf8(text);
		JS_FreeCString(context, text);
	}
	JS_FreeValue(context, result);
	JS_FreeValue(context, args[0]);
	JS_FreeValue(context, args[1]);
	JS_FreeValue(context, function);
	JS_FreeValue(context, global);
}

// Returns the pending exception's message, and clears it.
String MathJax::_take_error() {
	JSValue exception = JS_GetException(context);
	JSValue message = JS_GetPropertyStr(context, exception, "message");
	const char *text = JS_ToCString(context, JS_IsUndefined(message) ? exception : message);
	String result = String::utf8(text);
	JS_FreeCString(context, text);
	JS_FreeValue(context, message);
	JS_FreeValue(context, exception);
	return result;
}

String MathJax::tex_to_svg(const String &p_tex, bool p_display) {
	MutexLock lock(mutex);
	error_message = String();
	ERR_FAIL_COND_V(_start() != OK, String());
	tex = p_tex;
	display = p_display;
	request.post();
	done.wait();
	return svg;
}

String MathJax::get_error_message() const {
	MutexLock lock(mutex);
	return error_message;
}

void MathJax::_bind_methods() {
	ClassDB::bind_method(D_METHOD("tex_to_svg", "tex", "display"), &MathJax::tex_to_svg, DEFVAL(false));
	ClassDB::bind_method(D_METHOD("get_error_message"), &MathJax::get_error_message);
}

MathJax::MathJax() {
	singleton = this;
}

MathJax::~MathJax() {
	if (started) {
		quit = true;
		request.post();
		done.wait();
	}
	singleton = nullptr;
}
