/*
 * cocos2d for iPhone: http://www.cocos2d-swift.org
 *
 * Copyright (c) 2014 Cocos2D Authors
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 * THE SOFTWARE.
 */


#import <Foundation/Foundation.h>
#import "CCFileLocator.h"
#import "CCFile.h"
#import "CCFile_Private.h"
#import "CCFileLocatorDatabaseProtocol.h"
#import "CCFileMetaData.h"
#import "ccUtils.h"

// Options are only used internally for now
static NSString *const CCFILELOCATOR_SEARCH_OPTION_SKIPRESOLUTIONSEARCH = @"CCFILELOCATOR_SEARCH_OPTION_SKIPRESOLUTIONSEARCH";

// Define CCFILELOCATOR_TRACE_SEARCH as 1 to get trace logs of a search for debugging purposes
#if CCFILELOCATOR_TRACE_SEARCH == 1
	#define TraceLog( s, ... ) NSLog( @"[CCFILELOCATOR][TRACE] %@", [NSString stringWithFormat:(s), ##__VA_ARGS__] )
#else
	#define TraceLog( s, ... )
#endif


#pragma mark - CCFileResolvedMetaData helper class

@interface CCFileResolvedMetaData : NSObject

@property (nonatomic, copy) NSString *filename;
@property (nonatomic) BOOL useUIScale;

@end

@implementation CCFileResolvedMetaData

@end


#pragma mark - CCFileLocator

@interface CCFileLocator ()

@property (nonatomic, strong) NSMutableDictionary *cache;

@end


@implementation CCFileLocator

- (id)init
{
    self = [super init];

    if (self)
    {
        self.searchPaths = @[[[NSBundle mainBundle] resourcePath]];
        self.untaggedContentScale = 4;
        self.deviceContentScale = 4;
        self.cache = [NSMutableDictionary dictionary];
        
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(purgeCache)
                                                     name:NSCurrentLocaleDidChangeNotification
                                                   object:nil];
    }

    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

+ (CCFileLocator *)sharedFileLocator
{
    static CCFileLocator *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^
    {
        sharedInstance = [[CCFileLocator alloc] init];
    });
    return sharedInstance;
}

- (void)setSearchPaths:(NSArray *)searchPaths
{
    if ([_searchPaths isEqualToArray:searchPaths])
    {
        return;
    }

    _searchPaths = [searchPaths copy];

    [self purgeCache];
}

- (CCFile *)fileNamedWithResolutionSearch:(NSString *)filename error:(NSError **)error
{
    TraceLog(@"Start searching for image named \"%@\" including content scale variants...", filename);
    return [self fileNamed:filename options:nil error:error];
}

- (CCFile *)fileNamed:(NSString *)filename error:(NSError **)error
{
    TraceLog(@"Start searching for file named \"%@\"...", filename);
    NSDictionary *defaultOptions = @{CCFILELOCATOR_SEARCH_OPTION_SKIPRESOLUTIONSEARCH : @YES};

    return [self fileNamed:filename options:defaultOptions error:error];
};

- (CCFile *)fileNamed:(NSString *)filename options:(NSDictionary *)options error:(NSError **)error
{
    if (!_searchPaths || _searchPaths.count == 0)
    {
        [self setErrorPtr:error code:CCFileLocatorErrorNoSearchPaths description:@"No search paths set."];
        return nil;
    }

    CCFile *cachedFile = _cache[filename];
    if (cachedFile)
    {
        TraceLog(@"SUCCESS: Cache hit for \”%@\” -> %@", filename, cachedFile);
        return cachedFile;
    };

    CCFileResolvedMetaData *metaData = [self resolvedMetaDataForFilename:filename];

    CCFile *result = [self findFileInAllSearchPaths:filename metaData:metaData options:options];

    if (result)
    {
        return result;
    }

    [self setErrorPtr:error code:CCFileLocatorErrorNoFileFound description:@"No file found."];
    return nil;
}

- (CCFile *)findFileInAllSearchPaths:(NSString *)filename metaData:(CCFileResolvedMetaData *)metaData options:(NSDictionary *)options
{
    for (NSString *searchPath in _searchPaths)
    {
        NSString *resolvedFilename = filename;

        if (metaData)
        {
            resolvedFilename = metaData.filename;
        }

        CCFile *aFile = [self findFilename:resolvedFilename inSearchPath:searchPath options:options];

        if (aFile)
        {
            if (metaData)
            {
                aFile.useUIScale = metaData.useUIScale;
            }

            _cache[filename] = aFile;
            return aFile;
        }
    }
    return nil;
}

- (CCFileResolvedMetaData *)resolvedMetaDataForFilename:(NSString *)filename
{
    if (!_database)
    {
        return nil;
    }

    for (NSString *searchPath in _searchPaths)
    {
        CCFileMetaData *metaData = [_database metaDataForFileNamed:filename inSearchPath:searchPath];

        if (!metaData)
        {
            continue;
        }

        TraceLog(@"* Database entry for search path \"%@\": %@", searchPath, metaData);
        return [self resolveMetaData:metaData];
    }

    return nil;
}

- (CCFileResolvedMetaData *)resolveMetaData:(CCFileMetaData *)metaData
{
    CCFileResolvedMetaData *fileLocatorResolvedMetaData = [[CCFileResolvedMetaData alloc] init];

    NSString *localizedFileName = [self localizedFilenameWithMetaData:metaData];

    fileLocatorResolvedMetaData.filename = localizedFileName ?: metaData.filename;
    fileLocatorResolvedMetaData.useUIScale = metaData.useUIScale;

    return fileLocatorResolvedMetaData;
}

- (NSString *)localizedFilenameWithMetaData:(CCFileMetaData *)metaData
{
    if (!metaData.localizations)
    {
        return nil;
    }

    for (NSString *languageID in [NSLocale preferredLanguages])
    {
        NSString *filenameForLanguageID = metaData.localizations[languageID];
        if (filenameForLanguageID)
        {
            TraceLog(@"* Localization for languageID \"%@\" found: \"%@\"", languageID, filenameForLanguageID);
            return filenameForLanguageID;
        }
    }

    return nil;
}

- (CCFile *)findFilename:(NSString *)filename inSearchPath:(NSString *)searchPath options:(NSDictionary *)options
{
    __block CCFile *ret = nil;
    
    [self tryVariantsForFilename:filename options:options block:^(NSString *variantName, CGFloat contentScale, BOOL tagged) {
        NSURL *fileURL = [NSURL fileURLWithPath:[searchPath stringByAppendingPathComponent:variantName]];

        BOOL isDirectory = NO;
        NSFileManager *fileManager = [NSFileManager defaultManager];
        if ([fileManager fileExistsAtPath:fileURL.path isDirectory:&isDirectory] && !isDirectory)
        {
            TraceLog(@"SUCCESS: File exists! Filename: \"%@\" in search path: \"%@\"", fileLocatorSearchData.filename, searchPath);
            ret = [[CCFile alloc] initWithName:filename url:fileURL contentScale:contentScale];
        }
    }];
    
    return ret;
}

- (NSString *)contentScaleFilenameWithBasefilename:(NSString *)baseFilename contentScale:(int)contentScale
{
    NSString *base = [baseFilename stringByDeletingPathExtension];
    NSString *ext = [baseFilename pathExtension];
    return [NSString stringWithFormat:@"%@-%dx.%@", base, contentScale, ext];
}

- (void)tryVariantsForFilename:(NSString *)filename options:(NSDictionary *)options block:(void (^)(NSString *name, CGFloat contentScale, BOOL tagged))block
{
    if ([options[CCFILELOCATOR_SEARCH_OPTION_SKIPRESOLUTIONSEARCH] boolValue])
    {
        block(filename, _untaggedContentScale, NO);
    }
    else
    {
        int contentScale = CCNextPOT(ceil(self.deviceContentScale));
        
        // First try the highest-res explicit variant.
        block([self contentScaleFilenameWithBasefilename:filename contentScale:contentScale], contentScale, YES);
        
        // Then the untagged variant.
        block(filename, self.untaggedContentScale, NO);
        
        // Then the lower-res explicit variants.
        while(true)
        {
            contentScale /= 2;
            if(contentScale < 1) break;
            
            block([self contentScaleFilenameWithBasefilename:filename contentScale:contentScale], contentScale, YES);
        }
    }
}

- (void)purgeCache
{
    [_cache removeAllObjects];
}

- (void)setErrorPtr:(NSError **)errorPtr code:(NSInteger)code description:(NSString *)description
{
    if (errorPtr)
    {
        *errorPtr = [NSError errorWithDomain:@"cocos2d"
                                        code:code
                                    userInfo:@{NSLocalizedDescriptionKey : description}];
    }
}

@end
