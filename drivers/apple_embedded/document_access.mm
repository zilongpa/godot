/**************************************************************************/
/*  document_access.mm                                                      */
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

#import "document_access.h"
#include <stdio.h>
#include <sys/stat.h>

@implementation GodotDocumentAccess
+ (NSMutableDictionary<NSString *, NSURL *> *)grants {
	static NSMutableDictionary<NSString *, NSURL *> *grants;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ grants = [NSMutableDictionary dictionary]; });
	return grants;
}
+ (NSURL *)URLForPath:(NSString *)path {
	NSMutableDictionary *grants = [self grants];
	@synchronized(grants) {
		return grants[path.stringByStandardizingPath];
	}
}
+ (void)rememberURLs:(NSArray<NSURL *> *)urls {
	NSMutableDictionary *grants = [self grants];
	@synchronized(grants) {
		for (NSURL *url in urls) {
			grants[url.path.stringByStandardizingPath] = url;
		}
	}
}
+ (BOOL)validateURL:(NSURL *)url error:(NSError **)error {
	return [self validateURL:url coordinator:[[NSFileCoordinator alloc] initWithFilePresenter:nil] error:error];
}
+ (BOOL)validateURL:(NSURL *)url coordinator:(NSFileCoordinator *)coordinator error:(NSError **)error {
	if (!url.isFileURL) {
		if (error) { *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadUnsupportedSchemeError userInfo:nil]; }
		return NO;
	}
	BOOL scoped = [url startAccessingSecurityScopedResource];
	__block BOOL readable = NO;
	__block NSError *readError;
	[coordinator coordinateReadingItemAtURL:url options:0 error:error byAccessor:^(NSURL *coordinatedURL) {
		struct stat info;
		if (stat(coordinatedURL.fileSystemRepresentation, &info) == 0 && S_ISREG(info.st_mode)) {
			FILE *file = fopen(coordinatedURL.fileSystemRepresentation, "rb");
			if (file) {
				readable = YES;
				fclose(file);
			}
		}
		if (!readable) {
			readError = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadNoPermissionError userInfo:nil];
		}
	}];
	if (scoped) { [url stopAccessingSecurityScopedResource]; }
	if (readError && error && !*error) { *error = readError; }
	return readable;
}
@end
