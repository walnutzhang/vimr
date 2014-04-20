/**
 * Tae Won Ha — @hataewon
 *
 * http://taewon.de
 * http://qvacua.com
 *
 * See LICENSE
 */

#import "VRFileItemManager.h"
#import "VRLog.h"
#import "VRUtils.h"
#import "VRFileItem.h"
#import "NSArray+VR.h"


typedef void (^VRHandlerForCachedChildrenBlock)(NSArray *);
static NSString *const qHandlerForCachedChildrenKey = @"handler-for-cached-children-key";
static NSString *const qParentFileItemToCacheKey = @"parent-file-item-to-cache-key";

@interface VRFileItemManager ()

@property (readonly) NSMutableDictionary *url2CachedFileItem;
@property (readonly) NSMutableArray *mutableFileItemsForTargetUrl;
@property BOOL shouldCancelScanning;

// declared here to be used in the callback (and not to make it public)
- (void)reCacheUrls:(NSArray *)fileSystemRep flags:(FSEventStreamEventFlags const [])flags;

@end


void streamCallback(
        ConstFSEventStreamRef stream,
        void *callBackInfo,
        size_t numEvents,
        void *eventPaths,
        const FSEventStreamEventFlags eventFlags[],
        const FSEventStreamEventId eventIds[]
) {
    int i;
    char **paths = eventPaths;
    __weak VRFileItemManager *urlManager = (__bridge VRFileItemManager *) callBackInfo;

    @autoreleasepool {
        NSMutableArray *urls = [[NSMutableArray alloc] initWithCapacity:numEvents];
        for (i = 0; i < numEvents; i++) {
            NSString *path = [urlManager.fileManager stringWithFileSystemRepresentation:paths[i]
                                                                                 length:strlen(paths[i])];
            NSURL *url = [NSURL fileURLWithPath:path];
            [urls addObject:url];
            log4Debug(@"%@ changed!", url);
        }
        [urlManager reCacheUrls:urls flags:eventFlags];
    };
}


@implementation VRFileItemManager {
    NSThread *_thread;
    FSEventStreamRef _stream;
    FSEventStreamEventId _lastEventId;
}

TB_AUTOWIRE(fileManager)

#pragma mark Properties
- (NSArray *)fileItemsOfTargetUrl {
    return self.mutableFileItemsForTargetUrl;
}

- (NSArray *)registeredUrls {
    return self.url2CachedFileItem.allKeys;
}

#pragma mark Public
- (void)registerUrl:(NSURL *)url {
    @synchronized (self) {
        if ([_url2CachedFileItem.allKeys containsObject:url]) {
            log4Warn(@"%@ is already registered!", url);
            return;
        }

        if (![self isDir:url]) {
            log4Warn(@"%@ is not a dir!", url);
            return;
        }

        _url2CachedFileItem[url] = [[VRFileItem alloc] initWithUrl:url isDir:YES];

        [self stop];
        [self start];
    }
}

- (void)unregisterUrl:(NSURL *)url {
    @synchronized (self) {
        [_url2CachedFileItem removeObjectForKey:url];

        [self stop];
        [self start];
    }
}

- (BOOL)setTargetUrl:(NSURL *)url {
    VRFileItem *root = self.url2CachedFileItem[url];
    if (!root) {
        log4Warn(@"The URL %@ is not yet registered.", url);
        return NO;
    }

    /**
    * Build up cached file items.
    * Non-cached items will be built up async.
    * However, when the monitoring thread is caching, we wait until ready and build up the list
    */
    [self.mutableFileItemsForTargetUrl removeAllObjects];

    // we don't add root to mutableFileItemsForTargetUrl, since it is a dir
    [self traverseFileItemChildHierachy:root];

    return YES;
}

- (void)cleanUp {
    [self stop];
}

#pragma mark NSObject
- (id)init {
    self = [super init];
    RETURN_NIL_WHEN_NOT_SELF

    _lastEventId = kFSEventStreamEventIdSinceNow;

    _url2CachedFileItem = [[NSMutableDictionary alloc] initWithCapacity:5];
    _mutableFileItemsForTargetUrl = [[NSMutableArray alloc] initWithCapacity:500];
    _shouldCancelScanning = NO;

    return self;
}

#pragma mark Private
- (void)traverseFileItemChildHierachy:(VRFileItem *)parent {
    if (parent.isCachingChildren) {
        log4Debug(@"file item %@ is currently being cached", parent.url);
        return;
    }

    if (parent.shouldCacheChildren) {
        VRHandlerForCachedChildrenBlock handlerForCachedChildren = ^(NSArray *children) {
            for (VRFileItem *child in children) {
                if (!child.dir) {
                    [self addToFileItemsForTargetUrl:child];
                }
            }
        };

        [self performSelector:@selector(cacheChildrenForFileItemAndCallback:) onThread:_thread withObject:@{
                qParentFileItemToCacheKey : parent,
                qHandlerForCachedChildrenKey : handlerForCachedChildren,
        }       waitUntilDone:NO];

        return;
    }

    log4Debug(@"children of %@ cached, traversing or adding", parent.url);
    for (VRFileItem *child in parent.children) {
        if (child.dir) {
            log4Debug(@"traversing child %@", child.url);
            [self traverseFileItemChildHierachy:child];
        } else {
            [self addToFileItemsForTargetUrl:child];
        }
    }
}

- (void)addToFileItemsForTargetUrl:(VRFileItem *)item {
    [self.mutableFileItemsForTargetUrl addObject:item.url.path];
}

/**
* performed on a separate thread
*/
- (void)cacheChildrenForFileItemAndCallback:(NSDictionary *)dict {
    @autoreleasepool {
        VRFileItem *parent = dict[qParentFileItemToCacheKey];
        VRHandlerForCachedChildrenBlock handlerForCachedChildren = dict[qHandlerForCachedChildrenKey];

        if (self.shouldCancelScanning) {
            log4Debug(@"cancelling the scanning as requested at %@", parent.url);
            return;
        }

        log4Debug(@"building children for %@", parent.url);

        parent.isCachingChildren = YES;

        NSArray *childUrls = [self.fileManager contentsOfDirectoryAtURL:parent.url
                                             includingPropertiesForKeys:@[NSURLIsDirectoryKey]
                                                                options:NSDirectoryEnumerationSkipsPackageDescendants
                                                                  error:NULL];

        for (NSURL *childUrl in childUrls) {
            [parent.children addObject:[self fileItemFromUrl:childUrl]];
        }

        parent.shouldCacheChildren = NO; // because shouldCacheChildren means, "should add direct descendants"
        parent.isCachingChildren = NO; // direct descendants scanning is done

        handlerForCachedChildren(parent.children);

        for (VRFileItem *child in parent.children) {
            if (self.shouldCancelScanning) {
                log4Debug(@"cancelling the scanning as requested at %@", parent.url);
                return;
            }

            if (child.dir) {
                [self performSelector:@selector(cacheChildrenForFileItemAndCallback:) onThread:_thread withObject:@{
                        qParentFileItemToCacheKey : child,
                        qHandlerForCachedChildrenKey : handlerForCachedChildren,
                }       waitUntilDone:NO];
            }
        }
    }
}

- (VRFileItem *)fileItemFromUrl:(NSURL *)url {
    BOOL dir = [self isDir:url];

    return [[VRFileItem alloc] initWithUrl:url isDir:dir];
}

- (BOOL)isDir:(NSURL *)url {
    NSNumber *isDir = nil;
    [url getResourceValue:&isDir forKey:NSURLIsDirectoryKey error:NULL];

    return isDir.boolValue;
}

- (void)reCacheUrls:(NSArray *)urls flags:(FSEventStreamEventFlags const [])flags {
    [urls enumerateObjectsUsingBlock:^(NSURL *url, NSUInteger idx, BOOL *stop) {
        log4Debug(@"recaching for %@", url);

        FSEventStreamEventFlags flag = flags[idx];

        if (flag & kFSEventStreamEventFlagMustScanSubDirs) {
            log4Debug(@"%@ must subscan", url);
        }
    }];
}

- (FSEventStreamContext)contextWithSelfAsInfo {
    FSEventStreamContext context;

    memset(&context, 0, sizeof(context));
    context.info = (__bridge void *) (self);

    return context;
}

/**
* performed on a separate thread
*/
- (void)scheduleStream:(id)sender {
    @autoreleasepool {
        _stream = [self newStream];
    }

    FSEventStreamScheduleWithRunLoop(_stream, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
    FSEventStreamStart(_stream);

    CFRunLoopRun();
}

- (FSEventStreamRef)newStream {
    NSMutableArray *paths = [[NSMutableArray alloc] initWithCapacity:self.registeredUrls.count];
    for (NSURL *url in self.registeredUrls) {
        [paths addObject:url.path];
    }

    FSEventStreamContext context = [self contextWithSelfAsInfo];

    return FSEventStreamCreate(
            kCFAllocatorDefault,
            &streamCallback,
            &context,
            (__bridge CFArrayRef) paths,
            _lastEventId,
            0.5,
            kFSEventStreamCreateFlagNone
    );
}

- (void)start {
    @synchronized (self) {
        if (_thread) {
            return;
        }

        if (self.registeredUrls.isEmpty) {
            return;
        }

        log4Debug(@"starting a new thread");
        _thread = [[NSThread alloc] initWithTarget:self selector:@selector(scheduleStream:) object:self];
        _thread.name = @"file-item-manager-thread";

        [_thread start];
    }
}

- (void)stop {
    @synchronized (self) {
        if (!_thread) {
            return;
        }

        _lastEventId = FSEventStreamGetLatestEventId(_stream);

        FSEventStreamStop(_stream);
        FSEventStreamInvalidate(_stream);
        FSEventStreamRelease(_stream);

        log4Debug(@"stopping the thread");
        [_thread cancel];

        _stream = NULL;
        _thread = nil;
    }
}

@end
