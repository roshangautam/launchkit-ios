//
//  LKBundlesManager.m
//  LaunchKit
//
//  Created by Rizwan Sattar on 7/27/15.
//
//

#import "LKBundlesManager.h"

#import "LKAPIClient.h"
#import "LKLog.h"
#import "LK_SSZipArchive.h"

static BOOL const LOAD_PREPACKAGED_BUNDLES = YES;
static BOOL const LOAD_CACHED_BUNDLES = YES;
static BOOL const STORE_SERVER_BUNDLE_UPDATE_TIME = YES;

static LKBundlesManager *_sharedInstance;

NSString *const LKBundlesManagerDidFinishRetrievingBundlesManifest = @"LKBundlesManagerDidFinishRetrievingBundlesManifest";
NSString *const LKBundlesManagerDidFinishDownloadingRemoteBundles = @"LKBundlesManagerDidFinishDownloadingRemoteBundles";

// Add category that reveals our (private) LKBundleInfo method to upgrade resource version to newest
// (once we have retrieved the remote manifest and determined that this is, in fact, the newest available
@interface LKBundleInfo (UpdatingResourceVersion)
- (void) markResourceVersionAsNewest;
@end

@interface LKBundlesManager ()

@property (strong, nonatomic) NSMutableDictionary *remoteBundleMap;
@property (strong, nonatomic) NSMutableDictionary *localBundleMap;

@property (strong, nonatomic) LKAPIClient *apiClient;
@property (assign, nonatomic) BOOL retrievingRemoteBundlesManifest;
@property (assign, nonatomic) BOOL latestRemoteBundlesManifestRetrieved;

@property (assign, nonatomic) BOOL downloadingRemoteBundles;
@property (assign, nonatomic) BOOL remoteBundlesDownloaded;

// This is stored on our [application support]/launchkit/bundles folder
@property (strong, nonatomic) NSDate *localBundlesFolderUpdatedTime;

@property (strong, nonatomic) NSDate *lastManifestRetrievalTime;
@property (strong, nonatomic) NSURLSession *remoteUIDownloadSession;

@property (strong, nonatomic) NSMutableDictionary *pendingRemoteBundleLoadHandlers;

@end

@implementation LKBundlesManager

+ (instancetype) defaultManager
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _sharedInstance = [[LKBundlesManager alloc] init];
    });
    return _sharedInstance;
}

- (instancetype) initWithAPIClient:(LKAPIClient *)apiClient
{
    self = [super init];
    if (self) {
        self.apiClient = apiClient;
        self.remoteBundleMap = [NSMutableDictionary dictionaryWithCapacity:2];
        self.localBundleMap = [NSMutableDictionary dictionaryWithCapacity:2];
        self.localBundlesFolderUpdatedTime = [NSDate distantPast];
        self.latestRemoteBundlesManifestRetrieved = NO;
        self.remoteBundlesDownloaded = NO;
        self.pendingRemoteBundleLoadHandlers = [NSMutableDictionary dictionaryWithCapacity:1];
    }
    return self;
}

- (void)updateFromPreviousState:(NSDictionary *)state
{
    if (![state isKindOfClass:[NSDictionary class]]) {
        return;
    }

    NSDate *lastManifestRetrievalTime = state[@"lastManifestRetrievalTime"];
    if ([lastManifestRetrievalTime isKindOfClass:[NSDate class]]) {
        _lastManifestRetrievalTime = lastManifestRetrievalTime;
    }
}

- (NSDictionary *)stateDictionary
{
    NSMutableDictionary *state = [NSMutableDictionary dictionary];
    if (self.lastManifestRetrievalTime) {
        state[@"lastManifestRetrievalTime"] = self.lastManifestRetrievalTime;
    }
    return state;
}


- (void) updateServerBundlesUpdatedTimeWithTime:(NSDate *)bundlesUpdatedTime
{
    if ([self.localBundlesFolderUpdatedTime isEqualToDate:bundlesUpdatedTime]) {

        // We have the same 'local' server time as our current, so
        // mark that we have the latest, and there's nothing else to do
        self.latestRemoteBundlesManifestRetrieved = YES;

        // We may have tried to load some bundles earlier, but were waiting to
        // verify that our localBundlesFolderUpdatedTime is *still* the same as
        // on the server, so flush any pending loads.
        dispatch_async(dispatch_get_main_queue(), ^{
            [self notifyAnyPendingBundleLoadHandlers];
        });

        return;
    }

    // We may already be in the process of retrieving remote bundles, so check for that.
    // Rare Edge Case Note™: It may be fetching an _older_ timestamped manifest+bundle
    // when it receives a new timestamp. In that case, the new timestamped data won't be
    // downloaded until the _next_ time that updateServerBundlesUpdatedTimeWithTime: is
    // called. It essentially "self-corrects", eventually (Assuming LK is still making
    // track calls).
    if (!self.retrievingRemoteBundles) {

        if (self.debugMode) {
            if (self.verboseLogging) {
                if ([self.localBundlesFolderUpdatedTime isEqualToDate:[NSDate distantPast]]) {
                    LKLog(@"RETRIEVING Manifest+Bundles because: Local bundle time is not available, assuming no bundles");
                } else {
                    LKLog(@"RETRIEVING Manifest+Bundles because: Local bundle time (%@) != server time (%@)");
                }
            }
        }

        // We don't have the latest bundle manifest, so go and fetch it (and
        // consequently download any new bundles)
        self.latestRemoteBundlesManifestRetrieved = NO;
        [self retrieveAndCacheAvailableRemoteBundlesWithAssociatedServerTimestamp:bundlesUpdatedTime completion:^(NSError *error) {
            if (error) {
                LKLogWarning(@"Received error downloading and caching remote bundles: %@", error);
            } else {
                LKLog(@"Remote bundles downloaded and cached.");
            }
        }];
    }
}

- (BOOL)retrievingRemoteBundles
{
    return self.retrievingRemoteBundlesManifest || self.downloadingRemoteBundles;
}

- (BOOL)hasNewestRemoteBundles
{
    return self.latestRemoteBundlesManifestRetrieved && self.remoteBundlesDownloaded;
}

+ (nullable NSDate *)updateTimeInLocalBundlesFolder
{
    if (!STORE_SERVER_BUNDLE_UPDATE_TIME) {
        return nil;
    }
    NSURL *bundlesURL = [LKBundlesManager bundlesCacheDirectoryURLCreateIfNeeded:YES];
    NSURL *bundlesCanaryFileURL = [bundlesURL URLByAppendingPathComponent:@"LKWuzHere.txt"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:bundlesCanaryFileURL.path]) {
        // File doesn't exist; maybe it was deleted by iOS, or we never finished downloading bundles?
        return nil;
    }

    NSData *updateTimeStringData = [NSData dataWithContentsOfURL:bundlesCanaryFileURL];
    NSString *updateTimeString = [[NSString alloc] initWithData:updateTimeStringData encoding:NSUTF8StringEncoding];
    NSTimeInterval timeInterval = [updateTimeString doubleValue];
    if (timeInterval == 0.0) {
        // Not a valid time string
        return nil;
    }

    NSDate *updateTime = [NSDate dateWithTimeIntervalSince1970:timeInterval];
    return updateTime;
}

+ (void)setUpdateTimeInLocalBundlesFolder:(NSDate *)updateTime
{
    if (!updateTime || !STORE_SERVER_BUNDLE_UPDATE_TIME) {
        return;
    }
    NSURL *bundlesURL = [LKBundlesManager bundlesCacheDirectoryURLCreateIfNeeded:YES];
    NSURL *bundlesCanaryFileURL = [bundlesURL URLByAppendingPathComponent:@"LKWuzHere.txt"];
    NSString *updateTimeString = [NSString stringWithFormat:@"%f", updateTime.timeIntervalSince1970];
    NSData *updateTimeStringData = [updateTimeString dataUsingEncoding:NSUTF8StringEncoding];
    [updateTimeStringData writeToURL:bundlesCanaryFileURL atomically:NO];
}

+ (NSURL *)bundlesCacheDirectoryURLCreateIfNeeded:(BOOL)createIfNeeded
{
    NSString *appSupportDir = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).lastObject;
    NSString *launchKitDir = [appSupportDir stringByAppendingPathComponent:@"launchkit"];
    NSString *bundlesCacheDir = [launchKitDir stringByAppendingPathComponent:@"bundles"];
    NSURL *bundlesCacheDirUrl = [NSURL fileURLWithPath:bundlesCacheDir];
    NSFileManager *fileManager = [NSFileManager defaultManager];
    BOOL isDirectory = true;
    if (createIfNeeded && ![fileManager fileExistsAtPath:bundlesCacheDir isDirectory:&isDirectory] && isDirectory) {
        NSError *folderCreateError = nil;
        [fileManager createDirectoryAtPath:bundlesCacheDir
               withIntermediateDirectories:YES
                                attributes:nil
                                     error:&folderCreateError];
        if (folderCreateError != nil) {
            // Handle folder create error
            LKLogError(@"Could not create bundles cache folder at %@, error: %@", bundlesCacheDirUrl.path, folderCreateError);
            return nil;
        }

        // Exclude this folder from iCloud backups
        NSError *excludeFromiCloudError = nil;
        [bundlesCacheDirUrl setResourceValue:@(YES) forKey:NSURLIsExcludedFromBackupKey error:&excludeFromiCloudError];
        if (excludeFromiCloudError != nil) {
            // Should this count as a full-on error?
            LKLogWarning(@"Was not able to exclude bundles cache folder at %@ from iCloud Backups. Error: %@", bundlesCacheDirUrl.path, excludeFromiCloudError);
        }
    }
    return bundlesCacheDirUrl;
}

+ (void)deleteBundlesCacheDirectory
{
    NSURL *bundlesCacheDirUrl = [LKBundlesManager bundlesCacheDirectoryURLCreateIfNeeded:NO];
    if (bundlesCacheDirUrl) {
        NSError *deleteBundlesDirError = nil;
        [[NSFileManager defaultManager] removeItemAtURL:bundlesCacheDirUrl error:&deleteBundlesDirError];
        if (deleteBundlesDirError != nil && !([deleteBundlesDirError.domain isEqualToString:@"NSCocoaErrorDomain"] && deleteBundlesDirError.code == NSFileNoSuchFileError)) {
            LKLogWarning(@"Unable to delete bundles cache directory: %@", deleteBundlesDirError);
        }
    }
}

#pragma mark - Local Bundles Map

- (void)rebuildLocalBundlesMap
{
    NSFileManager *fileManager = [NSFileManager defaultManager];
    self.localBundleMap = [NSMutableDictionary dictionaryWithCapacity:1];

    if (LOAD_PREPACKAGED_BUNDLES) {
        // First fill in whatever we have in our pre-packaged main bundle (if any)
        NSString *mainBundleBaseSubdirectory = @"LaunchKitRemoteResources";
        NSArray *urlsWithBundleNames = [[NSBundle mainBundle] URLsForResourcesWithExtension:@"" subdirectory:mainBundleBaseSubdirectory];
        for (NSURL *urlWithBundleName in urlsWithBundleNames) {
            NSString *bundleName = urlWithBundleName.lastPathComponent;
            NSString *bundleNamePath = [mainBundleBaseSubdirectory stringByAppendingPathComponent:bundleName];
            NSArray *versionUrls = [[NSBundle mainBundle] URLsForResourcesWithExtension:@""
                                                                           subdirectory:bundleNamePath];
            if (versionUrls.count == 0) {
                continue;
            }

            // Take the first version in here (there should only be one version, since we would not have packaged multiple
            NSString *version = [versionUrls[0] lastPathComponent];
            NSString *versionPath = [bundleNamePath stringByAppendingPathComponent:version];
            NSURL *bundleUrl = [[NSBundle mainBundle] URLForResource:bundleName
                                                       withExtension:@"bundle"
                                                        subdirectory:versionPath];
            if (bundleUrl == nil) {
                continue;
            }

            NSError *getAttributesError = nil;
            NSDictionary *bundleAttributes = [fileManager attributesOfItemAtPath:bundleUrl.path error:&getAttributesError];
            NSDate *createTime = bundleAttributes[NSFileCreationDate];
            self.localBundleMap[bundleName] = [[LKBundleInfo alloc] initWithName:bundleName
                                                                         version:version
                                                                             url:bundleUrl
                                                                      createTime:createTime
                                                                 resourceVersion:LKResourceVersionPrepackaged];
        }
    }

    if (LOAD_CACHED_BUNDLES) {
        // Load bundles from cache
        NSURL *bundlesCacheDirUrl = [LKBundlesManager bundlesCacheDirectoryURLCreateIfNeeded:NO];
        if (![fileManager fileExistsAtPath:bundlesCacheDirUrl.path]) {
            // We haven't made one yet, so we're done
            return;
        }

        NSError *errorEnumeratingFiles = nil;
        NSArray *fileUrls = [fileManager contentsOfDirectoryAtURL:bundlesCacheDirUrl
                                       includingPropertiesForKeys:nil
                                                          options:NSDirectoryEnumerationSkipsHiddenFiles
                                                            error:&errorEnumeratingFiles];

        // [UI Name]/[version]/[name].bundle
        for (NSURL *fileUrl in fileUrls) {
            // Each item is a folder of the bundle name
            BOOL isDirectory = NO;
            [fileManager fileExistsAtPath:fileUrl.path isDirectory:&isDirectory];
            if (!isDirectory) {
                continue;
            }

            NSString *name = fileUrl.lastPathComponent;

            // Gather version info
            NSError *errorEnumeratingVersions;
            NSArray *versionUrls = [fileManager contentsOfDirectoryAtURL:fileUrl
                                              includingPropertiesForKeys:nil
                                                                 options:NSDirectoryEnumerationSkipsHiddenFiles
                                                                   error:&errorEnumeratingVersions];
            NSURL *mostRecentVersionUrl = nil;
            NSDate *mostRecentCreateTime = nil;
            for (NSURL *versionUrl in versionUrls) {
                // Verify this version folder has a bundle in it
                // in case for some reason the bundle was deleted or didn't download correctly
                NSError *errorEnumeratingVersionFiles = nil;
                NSArray *versionContents = [fileManager contentsOfDirectoryAtURL:versionUrl includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles error:&errorEnumeratingVersionFiles];
                if (versionContents.count == 0) {
                    // The version folder doesn't have anything, so this might be corrupt, skip it
                    continue;
                }

                NSError *getVersionFolderAttributeError = nil;
                NSDictionary *attributes = [fileManager attributesOfItemAtPath:versionUrl.path
                                                                         error:&getVersionFolderAttributeError];
                NSDate *createTime = attributes[NSFileCreationDate];
                if (mostRecentCreateTime == nil || [mostRecentCreateTime compare:createTime] == NSOrderedAscending) {
                    mostRecentCreateTime = createTime;
                    mostRecentVersionUrl = versionUrl;
                }
            }
            NSString *version = mostRecentVersionUrl.lastPathComponent;

            if (!mostRecentVersionUrl) {
                // This bundle doesn't have any valid versions, so skip it
                continue;
            }

            // Pick the first file within this directory
            NSError *errorEnumeratingUIFiles = nil;
            NSArray *bundleUrls = [fileManager contentsOfDirectoryAtURL:mostRecentVersionUrl
                                             includingPropertiesForKeys:nil
                                                                options:NSDirectoryEnumerationSkipsHiddenFiles
                                                                  error:&errorEnumeratingUIFiles];
            NSURL *localCacheUrl = (NSURL *) bundleUrls.firstObject;


            LKBundleInfo *info = [[LKBundleInfo alloc] initWithName:name
                                                            version:version
                                                                url:localCacheUrl
                                                         createTime:mostRecentCreateTime
                                                    resourceVersion:LKResourceVersionLocalCache];

            self.localBundleMap[info.name] = info;
        }
    }

    // Load the "update time" we stored in a canary file. This will help us determine whether or not
    // our local bundles is definitely out of date with server, and if it's missing, it could imply
    // that iOS/tvOS/watchOS has "cleaned" our folders without us knowing.
    NSDate *localUpdateTime = [LKBundlesManager updateTimeInLocalBundlesFolder];
    if (localUpdateTime) {
        self.localBundlesFolderUpdatedTime = localUpdateTime;
    } else {
        self.localBundlesFolderUpdatedTime = [NSDate distantPast];
    }
}

#pragma mark - Remote Bundles Map


- (void) retrieveRemoteBundlesManifestWithCompletion:(void (^)(NSError *error))completion
{
    void (^finishWithError)(NSError *error) = ^(NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.lastManifestRetrievalTime = [NSDate date];
            self.latestRemoteBundlesManifestRetrieved = (error == nil);
            if (self.debugMode) {
                LKLog(@"LKBundlesManager: Finished retrieving remote bundle manifest.");
            }
            self.retrievingRemoteBundlesManifest = NO;
            if (completion) {
                completion(error);
            }
            [[NSNotificationCenter defaultCenter] postNotificationName:LKBundlesManagerDidFinishRetrievingBundlesManifest
                                                                object:self];
        });
    };
    if (self.debugMode) {
        LKLog(@"LKBundlesManager: Retrieving remote bundle manifest...");
    }
    self.retrievingRemoteBundlesManifest = YES;
    __weak LKBundlesManager *_weakSelf = self;
    [self.apiClient retrieveBundlesManifestWithSuccessBlock:^(NSArray *bundleInfos) {
        if (!_weakSelf.remoteBundleMap) {
            _weakSelf.remoteBundleMap = [NSMutableDictionary dictionaryWithCapacity:bundleInfos.count];
        }
        for (LKBundleInfo *bundleInfo in bundleInfos) {
            // Check our local bundle map, and
            // if we have the same version,
            // mark our local version as "newest"
            LKBundleInfo *localBundleInfo = self.localBundleMap[bundleInfo.name];
            if (localBundleInfo != nil && [localBundleInfo.version isEqualToString:bundleInfo.version]) {
                [localBundleInfo markResourceVersionAsNewest];
            }

            NSURL *remoteUrl = bundleInfo.url;
            if (remoteUrl == nil) {
                // no url, skip
                continue;
            }
            _weakSelf.remoteBundleMap[bundleInfo.name] = bundleInfo;
        }

        finishWithError(nil);

    } errorBlock:^(NSError *error) {
        finishWithError(error);
    }];
}

- (void)retrieveAndCacheAvailableRemoteBundlesWithAssociatedServerTimestamp:(NSDate *)serverTimestamp completion:(void (^)(NSError *error))completion
{
    [self retrieveRemoteBundlesManifestWithCompletion:^(NSError *error) {
        if (error != nil) {
            if (completion) {
                completion(error);
            }
        } else {
            [self downloadRemoteBundlesForceRetrieve:NO associatedServerTimestamp:serverTimestamp completion:^(NSError *error) {

                if (completion) {
                    completion(error);
                }
            }];
        }
    }];
}


- (void)loadBundleWithId:(NSString *)bundleId completion:(LKRemoteBundleLoadHandler)completion
{
    // Early check: we might have the manifest already, so check if this bundleId doesnt
    // exist in the manifest (and therefore not worth waiting for downloads anyway)
    if (self.latestRemoteBundlesManifestRetrieved) {
        // We have the remote manifest at least, so we can check if our UI even exists
        LKBundleInfo *locallyAvailableBundleInfo = [self localBundleInfoWithName:bundleId];
        if (!locallyAvailableBundleInfo) {
            if (completion) {
                completion(nil, [self bundleInfoNotFoundErrorForId:bundleId]);
            }
            return;
        }
    }


    // If we are not current, always wait until we are current
    // This can be:
    // 1. We are just starting up, and even though we may have a local update time,
    // we haven't received a track call yet to update us with the "true" update time on the server
    // 2. We may actively be downloading the bundles when this request comes in
    //
    // In both situations we have to wait for the process to finish, before notifying the
    // completion block.
    if (!self.hasNewestRemoteBundles || self.retrievingRemoteBundles) {
        if (completion) {

            // We should wait until the remote bundle manifest is returned and then attempt this again
            NSMutableArray *handlers = self.pendingRemoteBundleLoadHandlers[bundleId];
            if (handlers == nil) {
                handlers = [NSMutableArray arrayWithObject:completion];
            } else {
                [handlers addObject:completion];
            }
            self.pendingRemoteBundleLoadHandlers[bundleId] = handlers;
        }
        return;
    }

    // We aren't downloading anything else, so just search what we have to load the bundle if possible
    if (completion) {
        NSError *error = nil;
        NSBundle *bundle = [self availableBundleWithId:bundleId error:&error];
        completion(bundle, error);
    }
}


- (NSBundle *) availableBundleWithId:(NSString *)bundleId error:(NSError **)error
{
    LKBundleInfo *bundleInfo = [self localBundleInfoWithName:bundleId];
    if (!bundleInfo || !bundleInfo.url) {
        *error = [self bundleInfoNotFoundErrorForId:bundleId];
        return nil;
    }

    NSBundle *bundle = [NSBundle bundleWithURL:bundleInfo.url];
    if (!bundle) {
        *error = [self bundleLoadErrorForUrl:bundleInfo.url];
        return nil;
    }

    return bundle;
}


- (void) notifyAnyPendingBundleLoadHandlers
{
    for (NSString *bundleId in self.pendingRemoteBundleLoadHandlers) {
        NSArray *loadHandlers = self.pendingRemoteBundleLoadHandlers[bundleId];

        NSError *error = nil;
        NSBundle *bundle = [self availableBundleWithId:bundleId error:&error];

        for (NSInteger i = 0; i < loadHandlers.count; i++) {
            LKRemoteBundleLoadHandler loadHandler = loadHandlers[i];
            loadHandler(bundle, error);
        }
    }
    [self.pendingRemoteBundleLoadHandlers removeAllObjects];
}


- (NSError *)bundleInfoNotFoundErrorForId:(NSString *)bundleId
{
    NSString *message = [NSString stringWithFormat:@"Bundle not found for id: %@", bundleId];
    return [[NSError alloc] initWithDomain:@"LKBundlesManagerError"
                                      code:404
                                  userInfo:@{@"message" : message}];
}


- (NSError *)bundleLoadErrorForUrl:(NSURL *)url
{
    NSString *message = [NSString stringWithFormat:@"Bundle could not be loaded at file url: %@", url.absoluteString];
    return [[NSError alloc] initWithDomain:@"LKBundlesManagerError"
                                      code:500
                                  userInfo:@{@"message" : message}];
}

#pragma mark -

- (void) downloadRemoteBundlesForceRetrieve:(BOOL)forceRetrieve associatedServerTimestamp:(NSDate *)serverTimestamp completion:(void (^)(NSError *error))completion
{
    NSMutableArray *infosNeedingDownload = [NSMutableArray arrayWithCapacity:self.remoteBundleMap.count];
    // Make a list of infos that need to be downloaded
    for (NSString *name in self.remoteBundleMap) {
        LKBundleInfo *remoteInfo = self.remoteBundleMap[name];
        LKBundleInfo *localInfo = self.localBundleMap[name];
        // If the info doesn't have a local cache, but has remote info, add it
        if (forceRetrieve || localInfo == nil || ![localInfo.version isEqualToString:remoteInfo.version]) {
            [infosNeedingDownload addObject:remoteInfo];
        }
    }

    __block NSInteger numItemsToDownload = infosNeedingDownload.count;
    __weak LKBundlesManager *_weakSelf = self;

    void (^onDownloadsFinished)(NSError *error) = ^(NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            _weakSelf.remoteBundlesDownloaded = (error == nil);
            _weakSelf.downloadingRemoteBundles = NO;
            // Mark our local folder with the 'serverBundlesUpdated' timestamp on the server
            if (STORE_SERVER_BUNDLE_UPDATE_TIME) {
                [LKBundlesManager setUpdateTimeInLocalBundlesFolder:serverTimestamp];
                _weakSelf.localBundlesFolderUpdatedTime = serverTimestamp;
            }
            if (self.debugMode && infosNeedingDownload.count > 0) {
                LKLog(@"LKBundlesManager: Finished downloading remote bundles.");
            }
            [self notifyAnyPendingBundleLoadHandlers];
            if (completion) {
                completion(error);
            }
            [[NSNotificationCenter defaultCenter] postNotificationName:LKBundlesManagerDidFinishDownloadingRemoteBundles
                                                                object:_weakSelf];
        });
    };

    if (infosNeedingDownload.count > 0) {
        if (self.debugMode) {
            LKLog(@"LKBundlesManager: Downloading %lu remote bundles...", (unsigned long)infosNeedingDownload.count);
        }
        self.downloadingRemoteBundles = YES;
        for (LKBundleInfo *info in infosNeedingDownload) {
            if (self.debugMode && self.verboseLogging) {
                LKBundleInfo *localInfo = _weakSelf.localBundleMap[info.name];
                NSString *newOrUpdating = @"new";
                if (localInfo != nil) {
                    newOrUpdating = @"update";
                }
                LKLog(@"LKBundlesManager: Downloading %@ version %@ (%@)...", info.name, info.version, newOrUpdating);
            }
            [_weakSelf downloadBundleFromInfo:info deleteOtherVersions:YES completion:^(LKBundleInfo *savedInfo, NSError *error) {
                numItemsToDownload--;
                if (numItemsToDownload == 0) {
                    onDownloadsFinished(error);
                }
            }];
        }
    } else {
        if (self.debugMode) {
            LKLog(@"LKBundlesManager: No need to download any remote bundles.");
        }
        onDownloadsFinished(nil);
    }
}


- (void)deleteVersionsOfBundleWithName:(NSString *)name exceptVersion:(NSString *)versionToKeep
{
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSURL *bundleVersionsDir = [[LKBundlesManager bundlesCacheDirectoryURLCreateIfNeeded:NO] URLByAppendingPathComponent:name];

    NSError *errorEnumeratingFiles = nil;
    NSArray *versionFolderUrls = [fileManager contentsOfDirectoryAtURL:bundleVersionsDir includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles error:&errorEnumeratingFiles];
    if (errorEnumeratingFiles != nil) {
        return;
    }

    NSUInteger numDeleted = 0;
    for (NSURL *versionFolderUrl in versionFolderUrls) {
        if ([versionFolderUrl.lastPathComponent isEqualToString:versionToKeep]) {
            continue;
        }
        NSError *versionFolderDeleteError = nil;
        [fileManager removeItemAtURL:versionFolderUrl error:&versionFolderDeleteError];
        if (versionFolderDeleteError != nil) {
            LKLogWarning(@"Unable to delete version: %@ of bundle '%@': %@",
                         versionFolderUrl.lastPathComponent,
                         name,
                         versionFolderDeleteError);
        } else {
            numDeleted++;
        }
    }
    LKLog(@"Deleted %lu old versions of bundle '%@'", numDeleted, name);
}


- (void)deleteLocalBundleInfo:(LKBundleInfo *)bundleInfo
{
    NSFileManager *fileManager = [NSFileManager defaultManager];

    // localCacheUrl == .bundle file, so go back up one level to reveal version
    NSURL *versionFolderUrl = [bundleInfo.url URLByDeletingLastPathComponent];
    NSError *deleteVersionError = nil;
    [fileManager removeItemAtURL:versionFolderUrl error:&deleteVersionError];
}


- (void) downloadBundleFromInfo:(LKBundleInfo *)info deleteOtherVersions:(BOOL)deleteOtherVersions completion:(void(^)(LKBundleInfo *savedInfo, NSError *error))completion
{
    NSURL *remoteUICacheDirUrl = [LKBundlesManager bundlesCacheDirectoryURLCreateIfNeeded:YES];
    NSURL *localCacheParentUrl = [[remoteUICacheDirUrl URLByAppendingPathComponent:info.name] URLByAppendingPathComponent:info.version];
    __weak LKBundlesManager *_weakSelf = self;
    [self saveDataFromRemoteUrl:info.url toDirectoryUrl:localCacheParentUrl completion:^(NSURL *savedFileUrl, NSError *error) {
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                LKBundleInfo *savedInfo = nil;
                if (savedFileUrl != nil) {
                    savedInfo = [[LKBundleInfo alloc] initWithName:info.name
                                                           version:info.version
                                                               url:savedFileUrl
                                                        createTime:info.createTime
                                                   resourceVersion:LKResourceVersionNewest];
                    _weakSelf.localBundleMap[savedInfo.name] = savedInfo;
                    if (deleteOtherVersions) {
                        [_weakSelf deleteVersionsOfBundleWithName:savedInfo.name
                                                    exceptVersion:savedInfo.version];
                    }
                }
                completion(savedInfo, error);
            });
        }
    }];
}


- (void)saveDataFromRemoteUrl:(NSURL *)remoteUrl toDirectoryUrl:(NSURL *)directoryUrl completion:(void (^)(NSURL *savedFileUrl, NSError *error))completion
{
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSURLRequest *request = [NSURLRequest requestWithURL:remoteUrl];

    // NOTE: Data tasks like this do not work with a background session. If we need to do that, we need to create
    // a download task. However, this could fire appDelete callbacks, which might confuse the main app, so let's
    // stick with a data task for now
    NSURLSessionDownloadTask *downloadTask = [[NSURLSession sharedSession] downloadTaskWithRequest:request completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {

        NSURL *savedUrl = nil;
        if (error) {
            if (completion) {
                completion(nil, error);
            }
        } else {
            if ([fileManager fileExistsAtPath:directoryUrl.path]) {
                NSError *deleteExistingFileError = nil;
                [fileManager removeItemAtURL:directoryUrl error:&deleteExistingFileError];
                if (deleteExistingFileError != nil) {
                    LKLogError(@"Couldn't delete existing item at %@ in order to download a new copy. Error: %@", deleteExistingFileError);
                    if (completion) {
                        completion(nil, deleteExistingFileError);
                    }
                    return;
                }
            }


            // Unzip if the saved file is zipped
            if ([remoteUrl.lastPathComponent.pathExtension isEqualToString:@"zip"]) {
                NSError *unzipError = nil;
                // This will store the unzippedPath into .tempUnzippedPath.
                // NOTE: This is clearly not thread-safe. Ideally Soffes' method should *return*
                // the unzipped path, or nil if unsuccessful, rather than BOOL.
                BOOL unzipped = [LK_SSZipArchive unzipFileAtPath:location.path toDestination:directoryUrl.path overwrite:YES password:nil error:&unzipError];

                if (!unzipped || unzipError != nil) {
                    if (completion) {
                        completion(nil, unzipError);
                    }
                    return;
                }

                // Find the first file in the directory path we saved
                NSError *directoryContentsError = nil;
                NSArray *filesInDirectory = [fileManager contentsOfDirectoryAtURL:directoryUrl
                                                       includingPropertiesForKeys:nil
                                                                          options:NSDirectoryEnumerationSkipsHiddenFiles
                                                                            error:&directoryContentsError];
                if (filesInDirectory.count > 0) {
                    savedUrl = filesInDirectory[0];
                }

            } else {
                // Copy the file as-is from the NSURL location to our cached file area
                NSError *copyError = nil;
                [fileManager copyItemAtURL:location toURL:directoryUrl error:&copyError];
                savedUrl = directoryUrl;
            }
            if (completion) {
                completion(savedUrl, nil);
            }
        }
    }];
    [downloadTask resume];
}

- (void) copyFromPath:(NSString *)sourcePath toPath:(NSString *)destinationPath
{
    NSFileManager *fileManager = [NSFileManager defaultManager];
    if ([fileManager fileExistsAtPath:destinationPath]) {
        [fileManager removeItemAtPath:destinationPath error:nil];
    }

    NSError *copyError = nil;
    BOOL success = [fileManager copyItemAtPath:sourcePath toPath:destinationPath error:&copyError];
    if (!success) {
        NSLog(@"Couldn't copy file, error: %@", copyError);
    }
}

#pragma mark -

- (LKBundleInfo *)localBundleInfoWithName:(NSString *)name
{
    return self.localBundleMap[name];
}

- (LKBundleInfo *)remoteBundleInfoWithName:(NSString *)name
{
    return self.remoteBundleMap[name];
}

+ (NSBundle *)cachedBundleFromInfo:(LKBundleInfo *)info
{
    if (info.url.isFileURL) {
        NSBundle *bundle = [NSBundle bundleWithURL:info.url];
        return bundle;
    }
    return nil;
}


@end
