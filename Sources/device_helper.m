#import <CoreFoundation/CoreFoundation.h>
#import <Foundation/Foundation.h>
#include <fcntl.h>
#include <limits.h>
#include <signal.h>
#include <sys/socket.h>
#include <unistd.h>

#import "airlift_target.h"

typedef const void *AMDeviceRef;
typedef const void *AMDeviceNotificationRef;
typedef void *AMDServiceConnectionRef;
typedef void *AFCConnectionRef;
typedef void *AFCKeyValueRef;
typedef void *AFCFileRef;
typedef void *AFCDirectoryRef;

typedef struct {
    AMDeviceRef device;
    unsigned int message;
} AMDeviceNotificationCallbackInfo;

extern int AMDeviceNotificationSubscribeWithOptions(
    void (*callback)(AMDeviceNotificationCallbackInfo *, void *),
    int unused,
    unsigned int connectionType,
    void *context,
    AMDeviceNotificationRef *subscription,
    CFDictionaryRef options);
extern int AMDeviceNotificationUnsubscribe(AMDeviceNotificationRef subscription);
extern CFStringRef AMDeviceCopyDeviceIdentifier(AMDeviceRef device);
extern CFTypeRef AMDeviceCopyValue(AMDeviceRef device,
                                   CFStringRef domain,
                                   CFStringRef key);
extern int AMDeviceConnect(AMDeviceRef device);
extern int AMDeviceDisconnect(AMDeviceRef device);
extern int AMDeviceIsPaired(AMDeviceRef device);
extern int AMDevicePair(AMDeviceRef device);
extern int AMDeviceValidatePairing(AMDeviceRef device);
extern int AMDeviceStartSession(AMDeviceRef device);
extern int AMDeviceStopSession(AMDeviceRef device);
extern int AMDeviceSecureStartService(AMDeviceRef device,
                                      CFStringRef serviceName,
                                      CFDictionaryRef options,
                                      AMDServiceConnectionRef *connection);
extern int AMDServiceConnectionGetSocket(AMDServiceConnectionRef connection);
extern void *AMDServiceConnectionGetSecureIOContext(
    AMDServiceConnectionRef connection);
extern int AMDServiceConnectionInvalidate(AMDServiceConnectionRef connection);
extern int AMDServiceConnectionSend(AMDServiceConnectionRef connection,
                                    const void *bytes,
                                    size_t length);
extern int AMDServiceConnectionSendMessage(AMDServiceConnectionRef connection,
                                           CFTypeRef message,
                                           CFPropertyListFormat format);
extern int AMDServiceConnectionReceiveMessage(AMDServiceConnectionRef connection,
                                              CFTypeRef *message,
                                              CFPropertyListFormat *format);

extern int AFCConnectionOpen(int socket,
                             unsigned int ioTimeout,
                             AFCConnectionRef *connection);
extern int AFCConnectionClose(AFCConnectionRef connection);
extern int AFCConnectionSetSecureContext(AFCConnectionRef connection,
                                         void *secureContext);
extern int AFCConnectionSetDisposeSecureContextOnInvalidate(
    AFCConnectionRef connection,
    int dispose);
extern int AFCConnectionSetIOTimeout(AFCConnectionRef connection,
                                     unsigned int timeout);
extern int AFCFileInfoOpen(AFCConnectionRef connection,
                           const char *path,
                           AFCKeyValueRef *dictionary);
extern int AFCKeyValueRead(AFCKeyValueRef dictionary, char **key, char **value);
extern int AFCKeyValueClose(AFCKeyValueRef dictionary);
extern int AFCFileRefOpen(AFCConnectionRef connection,
                          const char *path,
                          unsigned long long mode,
                          AFCFileRef *file);
extern int AFCFileRefRead(AFCConnectionRef connection,
                          AFCFileRef file,
                          void *bytes,
                          long *length);
extern int AFCFileRefWrite(AFCConnectionRef connection,
                           AFCFileRef file,
                           const void *bytes,
                           long length);
extern int AFCFileRefClose(AFCConnectionRef connection, AFCFileRef file);
extern int AFCDirectoryOpen(AFCConnectionRef connection,
                            const char *path,
                            AFCDirectoryRef *directory);
extern int AFCDirectoryRead(AFCConnectionRef connection,
                            AFCDirectoryRef directory,
                            char **entry);
extern int AFCDirectoryClose(AFCConnectionRef connection,
                             AFCDirectoryRef directory);
extern int AFCDirectoryCreate(AFCConnectionRef connection, const char *path);
extern int AFCRemovePath(AFCConnectionRef connection, const char *path);

static const char *TrackedBooksFiles[] = {
    "Books/Books.plist",
    "Books/Sync/Books.plist",
    "Books/Sync/Upload.plist",
    "Books/Sync/Database/OutstandingAssets_4.sqlite",
    "Books/Sync/Database/OutstandingAssets_4.sqlite-shm",
    "Books/Sync/Database/OutstandingAssets_4.sqlite-wal",
};

static const char *TrackedBooksDirectories[] = {
    "Books",
    "Books/Sync",
    "Books/Sync/Database",
};

static CFStringRef TargetIdentifier;
static AMDeviceRef TargetDevice;

typedef struct {
    AMDeviceRef device;
    BOOL connected;
    BOOL sessionStarted;
    AMDServiceConnectionRef afcService;
    AFCConnectionRef afc;
    int subscribeStatus;
    int connectStatus;
    int validateStatus;
    int sessionStatus;
    int serviceStatus;
    int afcStatus;
} DeviceSession;

static void DeviceCallback(AMDeviceNotificationCallbackInfo *info,
                           void *context) {
    (void)context;
    if (!info || !info->device || info->message != 1 || TargetDevice) return;
    CFStringRef identifier = AMDeviceCopyDeviceIdentifier(info->device);
    BOOL matches = identifier && CFEqual(identifier, TargetIdentifier);
    if (identifier) CFRelease(identifier);
    if (!matches) return;
    TargetDevice = CFRetain(info->device);
    CFRunLoopStop(CFRunLoopGetMain());
}

static NSDictionary *SubscriptionOptions(BOOL directConnectionsOnly) {
    return @{
        @"NotificationOptionSearchForPairedDevices": @YES,
        @"NotificationOptionSearchForPairedDevicesViaDirectConnectionsOnly":
            @(directConnectionsOnly),
        @"NotificationOptionSearchForWiFiPairableDevices": @NO,
        @"NotificationOptionEnableRemoteXPC": @YES,
        @"NotificationOptionEnableUSBMux": @YES,
    };
}

static int FindTarget(void) {
    AMDeviceNotificationRef subscription = NULL;
    int status = AMDeviceNotificationSubscribeWithOptions(
        DeviceCallback,
        0,
        0,
        NULL,
        &subscription,
        (__bridge CFDictionaryRef)SubscriptionOptions(NO));
    if (status == 0)
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 30.0, false);
    if (subscription) AMDeviceNotificationUnsubscribe(subscription);
    return status;
}

#pragma mark - Device discovery & log streaming

// Discovery and log streaming go straight through MobileDevice.framework, the
// same way the flash path does, so the app needs no libimobiledevice tooling.

static NSMutableArray<NSMutableDictionary *> *DiscoveredDevices;

static void EnumerateCallback(AMDeviceNotificationCallbackInfo *info,
                              void *context) {
    (void)context;
    if (!info || !info->device || info->message != 1) return;
    CFStringRef identifier = AMDeviceCopyDeviceIdentifier(info->device);
    if (!identifier) return;
    NSString *udid =
        CFBridgingRelease(CFStringCreateCopy(kCFAllocatorDefault, identifier));
    CFRelease(identifier);
    for (NSDictionary *seen in DiscoveredDevices) {
        if ([seen[@"udid"] isEqual:udid]) return;
    }

    NSMutableDictionary *entry = [@{@"udid": udid} mutableCopy];
    if (AMDeviceConnect(info->device) == 0) {
        if (!AMDeviceIsPaired(info->device)) AMDevicePair(info->device);
        if (AMDeviceValidatePairing(info->device) == 0 &&
            AMDeviceStartSession(info->device) == 0) {
            NSDictionary<NSString *, NSString *> *keys = @{
                @"name": @"DeviceName",
                @"version": @"ProductVersion",
                @"product": @"ProductType",
                @"buildVersion": @"BuildVersion",
            };
            for (NSString *field in keys) {
                id value = CFBridgingRelease(AMDeviceCopyValue(
                    info->device, NULL, (__bridge CFStringRef)keys[field]));
                entry[field] =
                    [value isKindOfClass:NSString.class] ? value : @"";
            }
            AMDeviceStopSession(info->device);
        }
        AMDeviceDisconnect(info->device);
    }
    [DiscoveredDevices addObject:entry];
}

static int ListDevices(void) {
    DiscoveredDevices = [NSMutableArray array];
    AMDeviceNotificationRef subscription = NULL;
    int status = AMDeviceNotificationSubscribeWithOptions(
        EnumerateCallback,
        0,
        0,
        NULL,
        &subscription,
        (__bridge CFDictionaryRef)SubscriptionOptions(YES));
    if (status == 0)
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 2.0, false);
    if (subscription) AMDeviceNotificationUnsubscribe(subscription);
    NSData *data = [NSJSONSerialization dataWithJSONObject:DiscoveredDevices
                                                   options:0
                                                     error:nil];
    if (data) {
        fwrite(data.bytes, 1, data.length, stdout);
        fwrite("\n", 1, 1, stdout);
    }
    return status == 0 ? 0 : 2;
}

static int RunSyslog(void) {
    if (FindTarget() != 0 || !TargetDevice) return 2;
    AMDeviceRef device = TargetDevice;
    if (AMDeviceConnect(device) != 0) return 2;
    if (!AMDeviceIsPaired(device)) AMDevicePair(device);
    if (AMDeviceValidatePairing(device) != 0 || AMDeviceStartSession(device) != 0) {
        AMDeviceDisconnect(device);
        return 2;
    }

    AMDServiceConnectionRef connection = NULL;
    if (AMDeviceSecureStartService(
            device, CFSTR("com.apple.syslog_relay"), NULL, &connection) != 0 ||
        !connection) {
        AMDeviceStopSession(device);
        AMDeviceDisconnect(device);
        return 2;
    }

    signal(SIGPIPE, SIG_IGN);
    int sock = AMDServiceConnectionGetSocket(connection);
    char buffer[65536];
    while (sock >= 0) {
        ssize_t received = recv(sock, buffer, sizeof(buffer), 0);
        if (received <= 0) break;
        fwrite(buffer, 1, (size_t)received, stdout);
        fflush(stdout);
    }

    AMDServiceConnectionInvalidate(connection);
    AMDeviceStopSession(device);
    AMDeviceDisconnect(device);
    return 0;
}

static void OpenSession(DeviceSession *session) {
    memset(session, 0, sizeof(*session));
    session->connectStatus = session->validateStatus = -1;
    session->sessionStatus = session->serviceStatus = session->afcStatus = -1;
    session->subscribeStatus = FindTarget();
    session->device = TargetDevice;
    if (!session->device) return;

    session->connectStatus = AMDeviceConnect(session->device);
    session->connected = session->connectStatus == 0;
    if (!session->connected) return;

    if (!AMDeviceIsPaired(session->device)) {
        AMDevicePair(session->device);
    }
    session->validateStatus = AMDeviceValidatePairing(session->device);
    if (session->validateStatus != 0) {
        AMDevicePair(session->device);
        session->validateStatus = AMDeviceValidatePairing(session->device);
    }
    if (session->validateStatus != 0) return;
    session->sessionStatus = AMDeviceStartSession(session->device);
    session->sessionStarted = session->sessionStatus == 0;
    if (!session->sessionStarted) return;
    session->serviceStatus = AMDeviceSecureStartService(
        session->device,
        CFSTR("com.apple.afc"),
        NULL,
        &session->afcService);
    if (session->serviceStatus != 0 || !session->afcService) return;
    session->afcStatus = AFCConnectionOpen(
        AMDServiceConnectionGetSocket(session->afcService),
        0,
        &session->afc);
    void *secureContext =
        AMDServiceConnectionGetSecureIOContext(session->afcService);
    if (session->afcStatus == 0 && session->afc && secureContext) {
        AFCConnectionSetSecureContext(session->afc, secureContext);
        AFCConnectionSetDisposeSecureContextOnInvalidate(session->afc, 0);
        AFCConnectionSetIOTimeout(session->afc, 30);
    }
}

static void CloseSession(DeviceSession *session) {
    if (session->afc) AFCConnectionClose(session->afc);
    if (session->afcService)
        AMDServiceConnectionInvalidate(session->afcService);
    if (session->sessionStarted) AMDeviceStopSession(session->device);
    if (session->connected) AMDeviceDisconnect(session->device);
    if (session->device) CFRelease(session->device);
    TargetDevice = NULL;
}

static void PrintJSON(NSDictionary *object) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:object
                                                   options:0
                                                     error:nil];
    if (!data) return;
    fwrite(data.bytes, 1, data.length, stdout);
    fwrite("\n", 1, 1, stdout);
}

static BOOL AFCExists(AFCConnectionRef afc, NSString *path) {
    AFCKeyValueRef info = NULL;
    int status = AFCFileInfoOpen(afc, path.fileSystemRepresentation, &info);
    if (info) AFCKeyValueClose(info);
    return status == 0;
}

static long long AFCFileSize(AFCConnectionRef afc, NSString *path) {
    AFCKeyValueRef info = NULL;
    if (AFCFileInfoOpen(afc, path.fileSystemRepresentation, &info) != 0 ||
        !info) return -1;
    long long size = -1;
    char *key = NULL;
    char *value = NULL;
    while (AFCKeyValueRead(info, &key, &value) == 0 && key && value) {
        if (strcmp(key, "st_size") == 0) size = strtoll(value, NULL, 10);
        key = NULL;
        value = NULL;
    }
    AFCKeyValueClose(info);
    return size;
}

static NSString *AFCFileKind(AFCConnectionRef afc, NSString *path) {
    AFCKeyValueRef info = NULL;
    if (AFCFileInfoOpen(afc, path.fileSystemRepresentation, &info) != 0 ||
        !info) return nil;
    NSString *kind = nil;
    char *key = NULL;
    char *value = NULL;
    while (AFCKeyValueRead(info, &key, &value) == 0 && key && value) {
        if (strcmp(key, "st_ifmt") == 0)
            kind = [NSString stringWithUTF8String:value];
        key = NULL;
        value = NULL;
    }
    AFCKeyValueClose(info);
    return kind;
}

static NSData *AFCReadFileWithLimit(AFCConnectionRef afc,
                                    NSString *path,
                                    long long limit) {
    long long size = AFCFileSize(afc, path);
    if (size < 0 || size > limit) return nil;
    AFCFileRef file = NULL;
    if (AFCFileRefOpen(afc, path.fileSystemRepresentation, 1, &file) != 0 ||
        !file) return nil;
    NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)size];
    long long offset = 0;
    int status = 0;
    while (offset < size) {
        long length = (long)(size - offset);
        status = AFCFileRefRead(
            afc, file, (uint8_t *)data.mutableBytes + offset, &length);
        if (status != 0 || length <= 0 || length > size - offset) break;
        offset += length;
    }
    int closeStatus = AFCFileRefClose(afc, file);
    if (status != 0 || closeStatus != 0 || offset != size) return nil;
    return data;
}

static NSData *AFCReadFile(AFCConnectionRef afc, NSString *path) {
    return AFCReadFileWithLimit(afc, path, 16 * 1024 * 1024);
}

static BOOL AFCWriteFile(AFCConnectionRef afc, NSString *path, NSData *data) {
    AFCFileRef file = NULL;
    int status = AFCFileRefOpen(afc, path.fileSystemRepresentation, 3, &file);
    if (status != 0 || !file) return NO;
    status = data.length == 0
        ? 0 : AFCFileRefWrite(afc, file, data.bytes, (long)data.length);
    int closeStatus = AFCFileRefClose(afc, file);
    return status == 0 && closeStatus == 0;
}

static BOOL EnsureDirectory(AFCConnectionRef afc, NSString *path) {
    return AFCExists(afc, path) ||
        AFCDirectoryCreate(afc, path.fileSystemRepresentation) == 0;
}

static BOOL RemoveIfPresent(AFCConnectionRef afc, NSString *path) {
    if (!AFCExists(afc, path)) return YES;
    return AFCRemovePath(afc, path.fileSystemRepresentation) == 0 &&
        !AFCExists(afc, path);
}

static BOOL AllTrackedBooksFilesAbsent(AFCConnectionRef afc) {
    for (NSUInteger index = 0;
         index < sizeof(TrackedBooksFiles) / sizeof(char *);
         index++) {
        NSString *path =
            [NSString stringWithUTF8String:TrackedBooksFiles[index]];
        if (AFCExists(afc, path)) return NO;
    }
    return YES;
}

static NSArray<NSString *> *PresentTrackedBooksPaths(AFCConnectionRef afc) {
    NSMutableArray<NSString *> *paths = NSMutableArray.array;
    for (NSUInteger index = 0;
         index < sizeof(TrackedBooksFiles) / sizeof(char *);
         index++) {
        NSString *path =
            [NSString stringWithUTF8String:TrackedBooksFiles[index]];
        if (AFCExists(afc, path)) [paths addObject:path];
    }
    return paths;
}

static NSString *SnapshotFileName(NSUInteger index) {
    return [NSString stringWithFormat:@"file-%lu.bin", (unsigned long)index];
}

static NSString *SnapshotManifestPath(NSString *root) {
    return [root stringByAppendingPathComponent:@"manifest.plist"];
}

static NSDictionary *MoveBackupPathStatus(AFCConnectionRef afc, NSString *path);

static BOOL SyncSnapshotPath(NSString *path, BOOL directory) {
    int descriptor = open(path.fileSystemRepresentation,
        O_RDONLY | O_NOFOLLOW | (directory ? O_DIRECTORY : 0));
    if (descriptor < 0) return NO;
    BOOL synced = fsync(descriptor) == 0;
    BOOL closed = close(descriptor) == 0;
    return synced && closed;
}

static NSDictionary *LoadBooksSnapshot(NSString *root) {
    NSData *data = [NSData dataWithContentsOfFile:SnapshotManifestPath(root)];
    if (!data) return nil;
    id value = [NSPropertyListSerialization propertyListWithData:data
        options:NSPropertyListImmutable format:NULL error:nil];
    if (![value isKindOfClass:NSDictionary.class] ||
        ![value[@"version"] isEqual:@1] ||
        ![value[@"files"] isKindOfClass:NSDictionary.class] ||
        ![value[@"directories"] isKindOfClass:NSDictionary.class]) return nil;

    NSDictionary *files = value[@"files"];
    for (NSUInteger index = 0;
         index < sizeof(TrackedBooksFiles) / sizeof(char *);
         index++) {
        NSString *path = [NSString stringWithUTF8String:TrackedBooksFiles[index]];
        NSDictionary *row = [files[path] isKindOfClass:NSDictionary.class]
            ? files[path] : nil;
        NSString *expectedName = SnapshotFileName(index);
        if (![row[@"exists"] isKindOfClass:NSNumber.class] ||
            ![row[@"localName"] isEqual:expectedName]) return nil;
        if ([row[@"exists"] boolValue]) {
            NSString *localPath = [root stringByAppendingPathComponent:expectedName];
            BOOL isDirectory = NO;
            if (![[NSFileManager defaultManager] fileExistsAtPath:localPath
                isDirectory:&isDirectory] || isDirectory) return nil;
        }
    }
    NSDictionary *directories = value[@"directories"];
    for (NSUInteger index = 0;
         index < sizeof(TrackedBooksDirectories) / sizeof(char *);
         index++) {
        NSString *path =
            [NSString stringWithUTF8String:TrackedBooksDirectories[index]];
        if (![directories[path] isKindOfClass:NSNumber.class]) return nil;
    }
    return value;
}

static NSDictionary *SnapshotBooksState(AFCConnectionRef afc, NSString *root) {
    BOOL isDirectory = NO;
    BOOL rootReady = [[NSFileManager defaultManager] fileExistsAtPath:root
        isDirectory:&isDirectory] && isDirectory;
    if (!rootReady ||
        [[NSFileManager defaultManager] fileExistsAtPath:SnapshotManifestPath(root)])
        return @{ @"ok": @NO, @"snapshotDirectoryReady": @(rootReady) };

    NSMutableDictionary *files = NSMutableDictionary.dictionary;
    NSMutableDictionary *directories = NSMutableDictionary.dictionary;
    NSMutableArray<NSString *> *presentPaths = NSMutableArray.array;
    unsigned long long totalBytes = 0;
    NSError *localError = nil;

    for (NSUInteger index = 0;
         index < sizeof(TrackedBooksFiles) / sizeof(char *);
         index++) {
        NSString *path = [NSString stringWithUTF8String:TrackedBooksFiles[index]];
        NSString *localName = SnapshotFileName(index);
        NSDictionary *status = MoveBackupPathStatus(afc, path);
        if (![status[@"ok"] boolValue])
            return @{ @"ok": @NO, @"snapshotStatusUnknown": path,
                      @"pathStatus": status };
        BOOL exists = [status[@"present"] boolValue];
        if (exists && ![status[@"metadata"][@"st_ifmt"] isEqual:@"S_IFREG"])
            return @{ @"ok": @NO, @"unexpectedFileType": path };
        NSData *data = exists
            ? AFCReadFileWithLimit(afc, path, 128 * 1024 * 1024) : nil;
        if (exists && !data)
            return @{ @"ok": @NO, @"snapshotReadFailed": path };
        if (data) {
            totalBytes += data.length;
            if (totalBytes > 256 * 1024 * 1024)
                return @{ @"ok": @NO, @"snapshotTooLarge": @YES };
            NSString *localPath = [root stringByAppendingPathComponent:localName];
            if (![data writeToFile:localPath
                    options:NSDataWritingWithoutOverwriting
                      error:&localError])
                return @{ @"ok": @NO,
                          @"snapshotWriteFailed": path,
                          @"localError": localError.localizedDescription ?: @"unknown" };
            if (!SyncSnapshotPath(localPath, NO))
                return @{ @"ok": @NO, @"snapshotSyncFailed": localPath };
            [presentPaths addObject:path];
        }
        files[path] = @{ @"exists": @(exists),
                         @"localName": localName,
                         @"size": @(data.length) };
    }

    for (NSUInteger index = 0;
         index < sizeof(TrackedBooksDirectories) / sizeof(char *);
         index++) {
        NSString *path =
            [NSString stringWithUTF8String:TrackedBooksDirectories[index]];
        NSDictionary *status = MoveBackupPathStatus(afc, path);
        if (![status[@"ok"] boolValue])
            return @{ @"ok": @NO, @"snapshotStatusUnknown": path,
                      @"pathStatus": status };
        BOOL exists = [status[@"present"] boolValue];
        NSString *kind = status[@"metadata"][@"st_ifmt"];
        if (exists && ![kind isEqual:@"S_IFDIR"])
            return @{ @"ok": @NO, @"unexpectedDirectoryType": path };
        directories[path] = @(exists);
    }

    NSDictionary *manifest = @{ @"version": @1,
                                 @"files": files,
                                 @"directories": directories };
    NSData *manifestData = [NSPropertyListSerialization
        dataWithPropertyList:manifest format:NSPropertyListBinaryFormat_v1_0
        options:0 error:&localError];
    BOOL wroteManifest = manifestData && [manifestData
        writeToFile:SnapshotManifestPath(root)
        options:NSDataWritingAtomic
        error:&localError];
    BOOL durable = wroteManifest && SyncSnapshotPath(SnapshotManifestPath(root), NO) &&
        SyncSnapshotPath(root, YES);
    return @{ @"ok": @(durable), @"snapshotDurable": @(durable),
              @"presentPaths": presentPaths,
              @"snapshotBytes": @(totalBytes),
              @"localError": durable
                  ? (id)NSNull.null
                  : (localError.localizedDescription ?: @"Could not durably sync Books snapshot.") };
}

static BOOL BooksStateMatchesSnapshot(AFCConnectionRef afc,
                                      NSString *root,
                                      NSDictionary *snapshot) {
    NSDictionary *files = snapshot[@"files"];
    for (NSUInteger index = 0;
         index < sizeof(TrackedBooksFiles) / sizeof(char *);
         index++) {
        NSString *path = [NSString stringWithUTF8String:TrackedBooksFiles[index]];
        NSDictionary *row = files[path];
        BOOL expectedExists = [row[@"exists"] boolValue];
        NSDictionary *status = MoveBackupPathStatus(afc, path);
        if (![status[@"ok"] boolValue] ||
            [status[@"present"] boolValue] != expectedExists) return NO;
        if (expectedExists) {
            if (![status[@"metadata"][@"st_ifmt"] isEqual:@"S_IFREG"])
                return NO;
            NSData *expected = [NSData dataWithContentsOfFile:
                [root stringByAppendingPathComponent:SnapshotFileName(index)]];
            NSData *observed =
                AFCReadFileWithLimit(afc, path, 128 * 1024 * 1024);
            if (!expected || !observed || ![observed isEqualToData:expected])
                return NO;
        }
    }

    NSDictionary *directories = snapshot[@"directories"];
    for (NSUInteger index = 0;
         index < sizeof(TrackedBooksDirectories) / sizeof(char *);
         index++) {
        NSString *path =
            [NSString stringWithUTF8String:TrackedBooksDirectories[index]];
        BOOL expectedExists = [directories[path] boolValue];
        NSDictionary *status = MoveBackupPathStatus(afc, path);
        if (![status[@"ok"] boolValue]) return NO;
        BOOL exists = [status[@"present"] boolValue];
        if (exists != expectedExists) return NO;
        if (exists && ![status[@"metadata"][@"st_ifmt"] isEqual:@"S_IFDIR"])
            return NO;
    }
    return YES;
}

static BOOL EnsureBooksParent(AFCConnectionRef afc, NSString *path) {
    if (!EnsureDirectory(afc, @"Books")) return NO;
    if ([path hasPrefix:@"Books/Sync/"] &&
        !EnsureDirectory(afc, @"Books/Sync")) return NO;
    if ([path hasPrefix:@"Books/Sync/Database/"] &&
        !EnsureDirectory(afc, @"Books/Sync/Database")) return NO;
    return YES;
}

static NSDictionary *RestoreBooksState(AFCConnectionRef afc, NSString *root) {
    NSDictionary *snapshot = LoadBooksSnapshot(root);
    if (!snapshot) return @{ @"ok": @NO, @"error": @"invalid snapshot" };
    // Check every current tracked object before changing any Books state. In
    // particular, a transport error must not be treated as a missing file.
    for (NSUInteger group = 0; group < 2; group++) {
        const char **paths = group == 0 ? TrackedBooksFiles : TrackedBooksDirectories;
        NSUInteger count = group == 0 ? sizeof(TrackedBooksFiles) / sizeof(char *) :
            sizeof(TrackedBooksDirectories) / sizeof(char *);
        NSString *expectedKind = group == 0 ? @"S_IFREG" : @"S_IFDIR";
        for (NSUInteger index = 0; index < count; index++) {
            NSString *path = [NSString stringWithUTF8String:paths[index]];
            NSDictionary *status = MoveBackupPathStatus(afc, path);
            if (![status[@"ok"] boolValue] ||
                ([status[@"present"] boolValue] &&
                 ![status[@"metadata"][@"st_ifmt"] isEqual:expectedKind]))
                return @{ @"ok": @NO, @"preimageVerified": @NO,
                          @"restoreRefused": @YES, @"path": path,
                          @"pathStatus": status,
                          @"error": @"Books current state is unknown or has an unexpected type." };
        }
    }
    NSMutableArray<NSString *> *failures = NSMutableArray.array;
    NSDictionary *files = snapshot[@"files"];

    for (NSUInteger index = 0;
         index < sizeof(TrackedBooksFiles) / sizeof(char *);
         index++) {
        NSString *path = [NSString stringWithUTF8String:TrackedBooksFiles[index]];
        NSDictionary *row = files[path];
        if ([row[@"exists"] boolValue]) {
            NSData *data = [NSData dataWithContentsOfFile:
                [root stringByAppendingPathComponent:SnapshotFileName(index)]];
            if (!data || !EnsureBooksParent(afc, path) ||
                !AFCWriteFile(afc, path, data)) [failures addObject:path];
        } else if (!RemoveIfPresent(afc, path)) {
            [failures addObject:path];
        }
    }

    NSDictionary *directories = snapshot[@"directories"];
    for (NSInteger index =
             (NSInteger)(sizeof(TrackedBooksDirectories) / sizeof(char *)) - 1;
         index >= 0; index--) {
        NSString *path =
            [NSString stringWithUTF8String:TrackedBooksDirectories[index]];
        if (![directories[path] boolValue] && !RemoveIfPresent(afc, path))
            [failures addObject:path];
    }
    BOOL verified = failures.count == 0 &&
        BooksStateMatchesSnapshot(afc, root, snapshot);
    return @{ @"ok": @(verified),
              @"failures": failures,
              @"preimageVerified": @(verified) };
}

static BOOL IsSafeRelativePath(NSString *path) {
    if (!path.length || [path hasPrefix:@"/"] || [path hasSuffix:@"/"])
        return NO;
    for (NSString *component in [path componentsSeparatedByString:@"/"])
        if (!component.length || [component isEqual:@"."] ||
            [component isEqual:@".."]) return NO;
    return YES;
}

static BOOL IsLowercaseHex(NSString *value, NSUInteger length) {
    if (value.length != length) return NO;
    for (NSUInteger index = 0; index < value.length; index++) {
        unichar character = [value characterAtIndex:index];
        if (!((character >= '0' && character <= '9') ||
              (character >= 'a' && character <= 'f'))) return NO;
    }
    return YES;
}

static NSString *GeneratedToken(NSString *value, NSString *prefix) {
    if (![value hasPrefix:prefix] ||
        [value rangeOfString:@"/"].location != NSNotFound) return nil;
    NSString *token = [value substringFromIndex:prefix.length];
    return IsLowercaseHex(token, 20) ? token : nil;
}

static BOOL GeneratedNamesMatch(NSString *source,
                                NSString *linkDestination,
                                NSString *recovered) {
    NSString *token = GeneratedToken(source, AIRLIFT_SOURCE_PREFIX);
    return token &&
        [GeneratedToken(linkDestination, AIRLIFT_LINK_PREFIX)
            isEqualToString:token] &&
        [GeneratedToken(recovered, AIRLIFT_RECOVERED_PREFIX)
            isEqualToString:token];
}

static BOOL IsCanaryLeaf(NSString *leaf) {
    if (![leaf hasPrefix:AIRLIFT_CANARY_PREFIX] ||
        ![leaf hasSuffix:@".bin"] ||
        leaf.length < AIRLIFT_CANARY_PREFIX.length + @".bin".length ||
        [leaf rangeOfString:@"/"].location != NSNotFound) return NO;
    NSRange tokenRange = NSMakeRange(
        AIRLIFT_CANARY_PREFIX.length,
        leaf.length - AIRLIFT_CANARY_PREFIX.length - @".bin".length);
    return IsLowercaseHex([leaf substringWithRange:tokenRange], 32);
}

static BOOL RemoveGeneratedTree(AFCConnectionRef afc,
                                NSString *path,
                                NSUInteger depth) {
    if (depth > 32) return NO;
    NSString *kind = AFCFileKind(afc, path);
    if (!kind) return YES;
    if ([kind isEqual:@"S_IFDIR"]) {
        AFCDirectoryRef directory = NULL;
        if (AFCDirectoryOpen(afc, path.fileSystemRepresentation, &directory) !=
                0 ||
            !directory) return NO;
        NSMutableArray<NSString *> *children = NSMutableArray.array;
        BOOL readOK = YES;
        for (NSUInteger index = 0; index < 8192; index++) {
            char *raw = NULL;
            int status = AFCDirectoryRead(afc, directory, &raw);
            if (status != 0) {
                readOK = NO;
                break;
            }
            if (!raw) break;
            NSString *name = [NSString stringWithUTF8String:raw];
            if (!name || [name isEqual:@"."] || [name isEqual:@".."]) continue;
            [children addObject:name];
        }
        BOOL closeOK = AFCDirectoryClose(afc, directory) == 0;
        if (!readOK || !closeOK) return NO;
        for (NSString *name in children) {
            NSString *child = [path stringByAppendingPathComponent:name];
            if (!RemoveGeneratedTree(afc, child, depth + 1)) return NO;
        }
    }
    return AFCRemovePath(afc, path.fileSystemRepresentation) == 0 &&
        !AFCExists(afc, path);
}

static NSDictionary *SessionSummary(DeviceSession *session) {
    id productType = session->connected
        ? CFBridgingRelease(AMDeviceCopyValue(
              session->device, NULL, CFSTR("ProductType"))) : nil;
    id productVersion = session->connected
        ? CFBridgingRelease(AMDeviceCopyValue(
              session->device, NULL, CFSTR("ProductVersion"))) : nil;
    id buildVersion = session->connected
        ? CFBridgingRelease(AMDeviceCopyValue(
              session->device, NULL, CFSTR("BuildVersion"))) : nil;
    return @{
        @"subscribeStatus": @(session->subscribeStatus),
        @"targetObserved": @(session->device != NULL),
        @"connectStatus": @(session->connectStatus),
        @"validateStatus": @(session->validateStatus),
        @"sessionStatus": @(session->sessionStatus),
        @"serviceStatus": @(session->serviceStatus),
        @"afcStatus": @(session->afcStatus),
        @"productType": [productType isKindOfClass:NSString.class]
            ? productType : @"(nil)",
        @"productVersion": [productVersion isKindOfClass:NSString.class]
            ? productVersion : @"(nil)",
        @"buildVersion": [buildVersion isKindOfClass:NSString.class]
            ? buildVersion : @"(nil)",
    };
}

static BOOL BuildMatches(NSDictionary *summary,
                         NSString *version,
                         NSString *build) {
    return [summary[@"productVersion"] isEqual:version] &&
        [summary[@"buildVersion"] isEqual:build];
}

static BOOL TargetGate(NSDictionary *summary, BOOL *tested) {
    *tested = NO;
    if (![summary[@"productType"] hasPrefix:@"iPhone"]) return NO;
#define AIRLIFT_MATCH_TESTED(version, build) \
    if (BuildMatches(summary, version, build)) { \
        *tested = YES; \
        return YES; \
    }
    AIRLIFT_TESTED_BUILDS(AIRLIFT_MATCH_TESTED)
#undef AIRLIFT_MATCH_TESTED
    return YES;
}

static BOOL SendAll(AMDServiceConnectionRef service, NSData *data) {
    const uint8_t *cursor = data.bytes;
    size_t remaining = data.length;
    while (remaining) {
        int sent = AMDServiceConnectionSend(service, cursor, remaining);
        if (sent <= 0) return NO;
        cursor += sent;
        remaining -= (size_t)sent;
    }
    return YES;
}

static NSDictionary *Stage(DeviceSession *session, NSArray<NSString *> *args) {
    NSString *source = args[0];
    NSString *linkDestination = args[1];
    NSString *recovered = args[2];
    NSData *archive = [NSData dataWithContentsOfFile:args[3]];
    NSData *books = [NSData dataWithContentsOfFile:args[4]];
    NSString *snapshotRoot = args[5];
    NSDictionary *snapshot = LoadBooksSnapshot(snapshotRoot);
    BOOL safeArguments =
        GeneratedNamesMatch(source, linkDestination, recovered);
    BOOL snapshotMatches = snapshot && BooksStateMatchesSnapshot(
        session->afc, snapshotRoot, snapshot);
    BOOL freshPaths = !AFCExists(session->afc, source) &&
        !AFCExists(session->afc, linkDestination) &&
        !AFCExists(session->afc, recovered);
    if (!safeArguments || !archive || !books || !snapshotMatches || !freshPaths) {
        return @{ @"ok": @NO,
                  @"cleanupAuthorized": @NO,
                  @"safeArguments": @(safeArguments),
                  @"localInputsReadable": @(archive != nil && books != nil),
                  @"booksPreimageStable": @(snapshotMatches),
                  @"freshPaths": @(freshPaths) };
    }

    AMDServiceConnectionRef zipService = NULL;
    int serviceStatus = AMDeviceSecureStartService(
        session->device,
        CFSTR("com.apple.streaming_zip_conduit"),
        NULL,
        &zipService);
    int messageStatus = -1;
    int responseStatus = -1;
    BOOL archiveSent = NO;
    CFTypeRef response = NULL;
    if (serviceStatus == 0 && zipService) {
        messageStatus = AMDServiceConnectionSendMessage(
            zipService,
            (__bridge CFTypeRef)@{ @"MediaSubdir": source },
            kCFPropertyListBinaryFormat_v1_0);
        if (messageStatus == 0) archiveSent = SendAll(zipService, archive);
        if (archiveSent) {
            int socket = AMDServiceConnectionGetSocket(zipService);
            struct timeval timeout = { .tv_sec = 30, .tv_usec = 0 };
            setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                       sizeof(timeout));
            CFPropertyListFormat format = kCFPropertyListBinaryFormat_v1_0;
            responseStatus = AMDServiceConnectionReceiveMessage(
                zipService, &response, &format);
        }
    }
    if (response) CFRelease(response);
    if (zipService) AMDServiceConnectionInvalidate(zipService);

    NSString *link =
        [source stringByAppendingPathComponent:@"p0/p1/p2/link"];
    BOOL hasPayload = AFCExists(session->afc,
                                [source stringByAppendingPathComponent:@"payload"]) ||
                      AFCExists(session->afc,
                                [source stringByAppendingPathComponent:@"payload_0"]);
    BOOL sourceObjects = AFCExists(session->afc, source) &&
        AFCExists(session->afc, link) &&
        hasPayload;
    BOOL directoriesReady = EnsureDirectory(session->afc, @"Books") &&
        EnsureDirectory(session->afc, @"Books/Sync");
    BOOL booksWritten = sourceObjects && directoriesReady &&
        AFCWriteFile(session->afc, @"Books/Sync/Books.plist", books);
    BOOL ok = serviceStatus == 0 && messageStatus == 0 && archiveSent &&
        sourceObjects && booksWritten;
    return @{ @"ok": @(ok),
              @"cleanupAuthorized": @YES,
              @"safeArguments": @YES,
              @"booksPreimageStable": @YES,
              @"freshPaths": @YES,
              @"zipServiceStatus": @(serviceStatus),
              @"zipMessageStatus": @(messageStatus),
              @"zipResponseStatus": @(responseStatus),
              @"archiveSent": @(archiveSent),
              @"sourceObjectsPresent": @(sourceObjects),
              @"booksWritten": @(booksWritten) };
}

static NSDictionary *Finish(DeviceSession *session, NSArray<NSString *> *args) {
    NSString *source = args[0];
    NSString *linkDestination = args[1];
    NSString *recovered = args[2];
    NSData *expected = [NSData dataWithContentsOfFile:args[3]];
    NSString *targetTail = args[4];
    NSString *targetLeaf = args[5];
    NSString *waitArgument = args[6];
    NSString *snapshotRoot = args[7];
    NSDictionary *snapshot = LoadBooksSnapshot(snapshotRoot);
    BOOL safeArguments =
        GeneratedNamesMatch(source, linkDestination, recovered) &&
        IsSafeRelativePath(targetTail) && IsCanaryLeaf(targetLeaf) &&
        expected.length > 0 && expected.length < 4096 &&
        snapshot != nil &&
        ([waitArgument isEqual:@"0"] || [waitArgument isEqual:@"1"]);
    if (!safeArguments)
        return @{ @"ok": @NO, @"safeArguments": @NO };

    NSData *observed = nil;
    NSUInteger readbackAttempts = 0;
    NSUInteger maximumAttempts = [waitArgument isEqual:@"1"] ? 60 : 1;
    for (NSUInteger index = 0; index < maximumAttempts; index++) {
        readbackAttempts++;
        observed = AFCReadFile(session->afc, recovered);
        if ([observed isEqualToData:expected]) break;
        if (index + 1 < maximumAttempts) usleep(250000);
    }
    BOOL recoveredPresent = observed != nil;
    BOOL bytesMatch = recoveredPresent && [observed isEqualToData:expected];
    NSMutableArray<NSString *> *failures = NSMutableArray.array;

    NSString *targetThroughLink =
        [linkDestination stringByAppendingPathComponent:targetLeaf];
    if (!RemoveIfPresent(session->afc, targetThroughLink))
        [failures addObject:@"target canary"];
    BOOL targetAbsent = !AFCExists(session->afc, targetThroughLink);
    if (!RemoveIfPresent(session->afc, linkDestination))
        [failures addObject:@"relocated link"];
    if (!RemoveIfPresent(session->afc, recovered))
        [failures addObject:@"recovered file"];
    if (!RemoveGeneratedTree(session->afc, source, 0))
        [failures addObject:@"StreamingZip tree"];
    sleep(2);
    NSDictionary *booksRestore = RestoreBooksState(session->afc, snapshotRoot);
    BOOL booksRestored = [booksRestore[@"ok"] boolValue];
    if (!booksRestored) [failures addObject:@"Books preimage"];

    BOOL sourceAbsent = !AFCExists(session->afc, source);
    BOOL linkAbsent = !AFCExists(session->afc, linkDestination);
    BOOL recoveredAbsent = !AFCExists(session->afc, recovered);
    BOOL cleanupComplete = failures.count == 0 && targetAbsent &&
        sourceAbsent && linkAbsent && recoveredAbsent && booksRestored;
    return @{ @"ok": @(bytesMatch && cleanupComplete),
              @"safeArguments": @YES,
              @"recoveredPresent": @(recoveredPresent),
              @"recoveredBytesMatch": @(bytesMatch),
              @"readbackAttempts": @(readbackAttempts),
              @"observedLength": @(observed.length),
              @"cleanupComplete": @(cleanupComplete),
              @"cleanupFailureCount": @(failures.count),
              @"failures": failures,
              @"targetAbsent": @(targetAbsent),
              @"sourceAbsent": @(sourceAbsent),
              @"linkAbsent": @(linkAbsent),
              @"recoveredAbsent": @(recoveredAbsent),
              @"booksPreimageRestored": @(booksRestored),
              @"booksRestore": booksRestore };
}

static NSDictionary *FinishWrite(DeviceSession *session, NSArray<NSString *> *args) {
    NSString *source = args[0];
    NSString *linkDestination = args[1];
    NSString *recovered = args[2];
    NSString *snapshotRoot = args[3];
    if (!GeneratedNamesMatch(source, linkDestination, recovered) ||
        !LoadBooksSnapshot(snapshotRoot))
        return @{ @"ok": @NO, @"error": @"invalid cleanup arguments" };
    NSMutableArray<NSString *> *failures = NSMutableArray.array;

    if (!RemoveIfPresent(session->afc, linkDestination))
        [failures addObject:@"relocated link"];
    if (!RemoveIfPresent(session->afc, recovered))
        [failures addObject:@"recovered file"];
    if (!RemoveGeneratedTree(session->afc, source, 0))
        [failures addObject:@"StreamingZip tree"];
    sleep(2);
    NSDictionary *booksRestore = RestoreBooksState(session->afc, snapshotRoot);
    BOOL booksRestored = [booksRestore[@"ok"] boolValue];
    if (!booksRestored) [failures addObject:@"Books preimage"];

    BOOL sourceAbsent = !AFCExists(session->afc, source);
    BOOL linkAbsent = !AFCExists(session->afc, linkDestination);
    BOOL recoveredAbsent = !AFCExists(session->afc, recovered);
    BOOL cleanupComplete = failures.count == 0 && sourceAbsent && linkAbsent && recoveredAbsent && booksRestored;
    return @{ @"ok": @(cleanupComplete),
              @"cleanupComplete": @(cleanupComplete),
              @"failures": failures,
              @"sourceAbsent": @(sourceAbsent),
              @"linkAbsent": @(linkAbsent),
              @"recoveredAbsent": @(recoveredAbsent),
              @"booksPreimageRestored": @(booksRestored),
              @"booksRestore": booksRestore };
}

// Preserve raw AFC results rather than guessing whether a failed call means
// missing data or denied access. Only query the supplied path, never its peers.
static NSMutableDictionary *ArtworkFileInfo(AFCConnectionRef afc,
                                             NSString *path) {
    NSMutableDictionary *result = [@{ @"path": path, @"ok": @NO } mutableCopy];
    NSMutableDictionary *metadata = NSMutableDictionary.dictionary;
    result[@"metadata"] = metadata;
    AFCKeyValueRef info = NULL;
    int openStatus = AFCFileInfoOpen(afc, path.fileSystemRepresentation, &info);
    result[@"fileInfoOpenStatus"] = @(openStatus);
    if (openStatus != 0 || !info) {
        result[@"phase"] = @"file_info_open";
        result[@"message"] = [NSString stringWithFormat:
            @"AFC file-info open returned %d%@.", openStatus,
            info ? @"" : @" with no metadata handle"];
        if (info) result[@"keyValueCloseStatus"] = @(AFCKeyValueClose(info));
        return result;
    }

    BOOL complete = NO;
    for (NSUInteger index = 0; index < 64; index++) {
        char *key = NULL;
        char *value = NULL;
        int status = AFCKeyValueRead(info, &key, &value);
        result[@"keyValueReadStatus"] = @(status);
        result[@"metadataEntriesRead"] = @(index);
        if (status != 0) {
            result[@"message"] = [NSString stringWithFormat:
                @"AFC metadata read returned %d.", status];
            break;
        }
        if (!key && !value) {
            complete = YES;
            break;
        }
        if (!key || !value || strnlen(key, 129) > 128 ||
            strnlen(value, 4097) > 4096) {
            result[@"message"] = @"AFC returned malformed or oversized metadata.";
            break;
        }
        NSString *name = [NSString stringWithUTF8String:key];
        NSString *entry = [NSString stringWithUTF8String:value];
        if (!name || !entry || metadata[name]) {
            result[@"message"] = @"AFC returned invalid or duplicate metadata.";
            break;
        }
        metadata[name] = entry;
        result[@"metadataEntriesRead"] = @(index + 1);
    }
    int closeStatus = AFCKeyValueClose(info);
    result[@"keyValueCloseStatus"] = @(closeStatus);
    if (!complete) {
        result[@"phase"] = @"metadata_read";
        if (!result[@"message"])
            result[@"message"] = @"AFC metadata exceeded the 64-entry limit.";
    } else if (closeStatus != 0) {
        result[@"phase"] = @"metadata_close";
        result[@"message"] = [NSString stringWithFormat:
            @"AFC metadata close returned %d.", closeStatus];
    } else {
        result[@"ok"] = @YES;
        result[@"phase"] = @"complete";
    }
    return result;
}

// AFC's actual kAFCNotFoundError is 8. A denied, interrupted or malformed
// metadata query must never authorize cleanup of an in-flight moved original.
static NSDictionary *MoveBackupPathStatus(AFCConnectionRef afc, NSString *path) {
    NSDictionary *info = ArtworkFileInfo(afc, path);
    BOOL present = [info[@"ok"] boolValue];
    BOOL absent = [info[@"fileInfoOpenStatus"] intValue] == 8;
    BOOL known = present || absent;
    return @{ @"ok": @(known),
              @"presence": present ? @"present" : absent ? @"absent" : @"unknown",
              @"exists": known ? @(present) : (id)NSNull.null,
              @"present": @(present),
              @"absent": @(absent),
              @"fileInfoOpenStatus": info[@"fileInfoOpenStatus"],
              @"metadata": info[@"metadata"],
              @"fileInfo": info };
}

static NSDictionary *RecoveredStatus(DeviceSession *session, NSString *recovered) {
    if (!GeneratedToken(recovered, AIRLIFT_RECOVERED_PREFIX))
        return @{ @"ok": @NO, @"error": @"invalid recovered name",
                  @"presence": @"unknown", @"exists": NSNull.null,
                  @"present": @NO, @"absent": @NO };
    return MoveBackupPathStatus(session->afc, recovered);
}

static BOOL IsMoveBackupCardHash(NSString *value) {
    if (value.length < 20 || value.length > 44) return NO;
    for (NSUInteger index = 0; index < value.length; index++) {
        unichar character = [value characterAtIndex:index];
        if (!((character >= 'A' && character <= 'Z') ||
              (character >= 'a' && character <= 'z') ||
              (character >= '0' && character <= '9') ||
              character == '-' || character == '_' || character == '+' ||
              character == '=')) return NO;
    }
    return YES;
}

static BOOL IsOriginalArtworkLeaf(NSString *container, NSString *leaf) {
    if ([container isEqual:@"cache"] || [container isEqual:@"pkcache"])
        return [@[@"FrontFace", @"PlaceHolder", @"Preview"] containsObject:leaf];
    if (![container isEqual:@"pkpass"]) return NO;
    return [@[@"cardBackground.png", @"cardBackground@2x.png", @"cardBackground@3x.png",
               @"cardBackground.pdf", @"strip.png", @"strip@2x.png", @"strip@3x.png",
               @"background.png", @"background@2x.png", @"background@3x.png",
               @"logo.png", @"logo@2x.png", @"logo@3x.png",
               // Fixed artwork-URL candidates; allowance does not imply that
               // any particular device/card actually contains these names.
               @"cardBackgroundCombined.urls", @"cardBackgroundCombined@2x.urls",
               @"cardBackgroundCombined@3x.urls", @"cardBackgroundCombined.pdf.urls",
               @"cardBackgroundCombined@2x.png.urls", @"cardBackgroundCombined@3x.png.urls"] containsObject:leaf];
}

// AirTraffic can consume the book IDs after each relocation. Each wrapper
// supplies only its fixed whitelist; no arbitrary plist or ID is accepted.
static NSDictionary *RefreshScopedMoveBooks(DeviceSession *session,
                                            NSString *source, NSString *link,
                                            NSString *recovered, NSString *cardHash,
                                            NSString *container, NSArray<NSString *> *leaves,
                                            NSString *snapshotRoot) {
    if (!GeneratedNamesMatch(source, link, recovered) ||
        !IsMoveBackupCardHash(cardHash) || !LoadBooksSnapshot(snapshotRoot) ||
        ![@[@"pkpass", @"cache", @"pkcache"] containsObject:container])
        return @{ @"ok": @NO, @"error": @"invalid move Books arguments" };

    NSString *sourceLink = [source stringByAppendingPathComponent:@"p0/p1/p2/link"];
    NSDictionary *sourceStatus = MoveBackupPathStatus(session->afc, source);
    NSDictionary *sourceLinkStatus = MoveBackupPathStatus(session->afc, sourceLink);
    NSDictionary *linkStatus = MoveBackupPathStatus(session->afc, link);
    BOOL sourceReady = [sourceStatus[@"present"] boolValue] &&
        [sourceStatus[@"metadata"][@"st_ifmt"] isEqual:@"S_IFDIR"];
    NSString *expectedLinkTarget = [NSString stringWithFormat:
        @"../../../var/mobile/Library/Passes/Cards/%@.%@", cardHash, container];
    BOOL sourceLinkReady = [sourceLinkStatus[@"present"] boolValue] &&
        [sourceLinkStatus[@"metadata"][@"st_ifmt"] isEqual:@"S_IFLNK"] &&
        [sourceLinkStatus[@"metadata"][@"LinkTarget"] isEqual:expectedLinkTarget];
    BOOL relocatedLinkReady = [linkStatus[@"present"] boolValue] &&
        [linkStatus[@"metadata"][@"st_ifmt"] isEqual:@"S_IFLNK"] &&
        [linkStatus[@"metadata"][@"LinkTarget"] isEqual:expectedLinkTarget];
    BOOL linkReady = sourceLinkReady || relocatedLinkReady;
    if (!sourceReady || !linkReady)
        return @{ @"ok": @NO, @"error": @"move_staging_unavailable",
                  @"sourceStatus": sourceStatus, @"sourceLinkStatus": sourceLinkStatus,
                  @"linkStatus": linkStatus };

    NSMutableArray<NSString *> *identifiers = [NSMutableArray arrayWithObjects:
        [@"../../" stringByAppendingString:sourceLink],
        [@"../../" stringByAppendingString:recovered], nil];
    for (NSString *leaf in leaves)
        [identifiers addObject:[NSString stringWithFormat:
            @"../../../Library/Passes/Cards/%@.%@/%@", cardHash, container, leaf]];
    NSMutableArray<NSDictionary *> *books = NSMutableArray.array;
    for (NSUInteger index = 0; index < identifiers.count; index++)
        [books addObject:@{ @"Persistent ID": identifiers[index],
                            @"Item ID": [NSString stringWithFormat:@"%lu", (unsigned long)(index + 1)],
                            @"DSID": @"1" }];
    NSError *error = nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:@{ @"Books": books }
        format:NSPropertyListBinaryFormat_v1_0 options:0 error:&error];
    BOOL ok = data && EnsureBooksParent(session->afc, @"Books/Sync/Books.plist") &&
        AFCWriteFile(session->afc, @"Books/Sync/Books.plist", data);
    return @{ @"ok": @(ok), @"booksWritten": @(ok),
              @"identifierCount": @(identifiers.count),
              @"message": ok ? @"Move-backup book IDs refreshed." :
                  (error.localizedDescription ?: @"Could not refresh move-backup book IDs.") };
}

static NSDictionary *RefreshMoveBooks(DeviceSession *session,
                                      NSArray<NSString *> *args) {
    NSString *canary = args.count == 6 ? args[5] : nil;
    if (canary && !IsCanaryLeaf(canary))
        return @{ @"ok": @NO, @"error": @"invalid move Books arguments" };
    NSMutableArray<NSString *> *leaves = [NSMutableArray arrayWithArray:
        @[@"cardBackgroundCombined@3x.png", @"cardBackgroundCombined@2x.png",
          @"cardBackgroundCombined.pdf"]];
    if (canary) [leaves addObject:canary];
    return RefreshScopedMoveBooks(session, args[0], args[1], args[2], args[3],
                                   @"pkpass", leaves, args[4]);
}

// Probe one original visual at a time. Cache blobs are opaque image-set bytes;
// pass metadata and credentials are deliberately outside this whitelist.
static NSDictionary *RefreshOriginalBooks(DeviceSession *session,
                                          NSArray<NSString *> *args) {
    if (!IsOriginalArtworkLeaf(args[4], args[5]))
        return @{ @"ok": @NO, @"error": @"invalid original artwork selection" };
    return RefreshScopedMoveBooks(session, args[0], args[1], args[2], args[3],
                                   args[4], @[args[5]], args[6]);
}

// Unlike finish-write, this command never removes the recovered file: until
// it has been moved back, it may be the only remaining copy of the original.
static NSDictionary *FinishMoveBackup(DeviceSession *session,
                                      NSArray<NSString *> *args) {
    NSString *source = args[0];
    NSString *linkDestination = args[1];
    NSString *recovered = args[2];
    NSString *snapshotRoot = args[3];
    if (!GeneratedNamesMatch(source, linkDestination, recovered) ||
        !LoadBooksSnapshot(snapshotRoot))
        return @{ @"ok": @NO, @"cleanupComplete": @NO,
                  @"error": @"invalid cleanup arguments" };
    NSDictionary *recoveredBefore = RecoveredStatus(session, recovered);
    if (![recoveredBefore[@"absent"] boolValue])
        return @{ @"ok": @NO, @"cleanupComplete": @NO,
                  @"cleanupRefused": @YES,
                  @"error": @"recovered_file_not_confirmed_absent",
                  @"message": @"Recovered artwork may still need restoration. No cleanup was attempted.",
                  @"recoveredStatus": recoveredBefore,
                  @"recoveredAbsent": @NO };

    NSMutableArray<NSString *> *failures = NSMutableArray.array;
    if (!RemoveIfPresent(session->afc, linkDestination))
        [failures addObject:@"relocated link"];
    if (!RemoveGeneratedTree(session->afc, source, 0))
        [failures addObject:@"StreamingZip tree"];
    sleep(2);
    NSDictionary *booksRestore = RestoreBooksState(session->afc, snapshotRoot);
    BOOL booksRestored = [booksRestore[@"ok"] boolValue];
    if (!booksRestored) [failures addObject:@"Books preimage"];

    NSDictionary *sourceStatus = MoveBackupPathStatus(session->afc, source);
    NSDictionary *linkStatus = MoveBackupPathStatus(session->afc, linkDestination);
    NSDictionary *recoveredAfter = RecoveredStatus(session, recovered);
    BOOL sourceAbsent = [sourceStatus[@"absent"] boolValue];
    BOOL linkAbsent = [linkStatus[@"absent"] boolValue];
    BOOL recoveredAbsent = [recoveredAfter[@"absent"] boolValue];
    if (!sourceAbsent) [failures addObject:@"StreamingZip absence unconfirmed"];
    if (!linkAbsent) [failures addObject:@"relocated link absence unconfirmed"];
    if (!recoveredAbsent) [failures addObject:@"recovered absence unconfirmed"];
    BOOL complete = failures.count == 0 && booksRestored &&
        sourceAbsent && linkAbsent && recoveredAbsent;
    return @{ @"ok": @(complete), @"cleanupComplete": @(complete),
              @"failures": failures,
              @"sourceAbsent": @(sourceAbsent), @"sourceStatus": sourceStatus,
              @"linkAbsent": @(linkAbsent), @"linkStatus": linkStatus,
              @"recoveredAbsent": @(recoveredAbsent),
              @"recoveredStatusBefore": recoveredBefore,
              @"recoveredStatus": recoveredAfter,
              @"booksPreimageRestored": @(booksRestored),
              @"booksRestore": booksRestore };
}

static BOOL ArtworkSize(NSString *value, long long *size) {
    // Reject negatives, whitespace, trailing text and overflow instead of
    // accepting strtoll's partial parses. st_size is an unsigned decimal.
    if (![value isKindOfClass:NSString.class] || !value.length || value.length > 19)
        return NO;
    long long parsed = 0;
    for (NSUInteger index = 0; index < value.length; index++) {
        unichar character = [value characterAtIndex:index];
        if (character < '0' || character > '9') return NO;
        int digit = character - '0';
        if (parsed > (LLONG_MAX - digit) / 10) return NO;
        parsed = parsed * 10 + digit;
    }
    *size = parsed;
    return YES;
}

// This separate reader is intentionally limited to card export. Existing flash
// and staging callers keep their original AFCReadFileWithLimit behavior.
static NSData *ReadArtworkWithDiagnostics(AFCConnectionRef afc,
                                           NSString *path, long long limit,
                                           NSMutableDictionary *diagnostics) {
    diagnostics[@"path"] = path;
    diagnostics[@"ok"] = @NO;
    diagnostics[@"limitBytes"] = @(limit);
    diagnostics[@"bytesRead"] = @0;
    diagnostics[@"readCalls"] = @0;
    NSDictionary *info = ArtworkFileInfo(afc, path);
    diagnostics[@"fileInfo"] = info;
    if (![info[@"ok"] boolValue]) {
        diagnostics[@"phase"] = info[@"phase"];
        diagnostics[@"message"] = info[@"message"];
        return nil;
    }
    long long size = -1;
    if (!ArtworkSize(info[@"metadata"][@"st_size"], &size)) {
        diagnostics[@"phase"] = @"file_size";
        diagnostics[@"message"] = @"AFC metadata has no valid nonnegative decimal st_size.";
        return nil;
    }
    diagnostics[@"fileSize"] = @(size);
    if (size == 0 || size > limit) {
        diagnostics[@"phase"] = size == 0 ? @"empty_file" : @"size_limit";
        diagnostics[@"message"] = size == 0 ? @"AFC reports an empty artwork file." :
            [NSString stringWithFormat:@"AFC reports %lld bytes, exceeding the %lld-byte read limit.", size, limit];
        return nil;
    }

    AFCFileRef file = NULL;
    int openStatus = AFCFileRefOpen(afc, path.fileSystemRepresentation, 1, &file);
    diagnostics[@"fileOpenStatus"] = @(openStatus);
    if (openStatus != 0 || !file) {
        diagnostics[@"phase"] = @"file_open";
        diagnostics[@"message"] = [NSString stringWithFormat:
            @"AFC read-only file open returned %d%@.", openStatus,
            file ? @"" : @" with no file handle"];
        if (file) diagnostics[@"fileCloseStatus"] = @(AFCFileRefClose(afc, file));
        return nil;
    }
    NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)size];
    long long offset = 0;
    NSUInteger readCalls = 0;
    while (offset < size) {
        long requested = (long)MIN(size - offset, 64 * 1024);
        long length = requested;
        int status = AFCFileRefRead(afc, file,
            (uint8_t *)data.mutableBytes + offset, &length);
        diagnostics[@"fileReadStatus"] = @(status);
        diagnostics[@"readCalls"] = @(++readCalls);
        diagnostics[@"lastRequestedBytes"] = @(requested);
        diagnostics[@"lastReturnedBytes"] = @(length);
        if (status != 0 || length <= 0 || length > requested) {
            diagnostics[@"phase"] = @"file_read";
            diagnostics[@"message"] = [NSString stringWithFormat:
                @"AFC file read returned status %d and length %ld (requested %ld) after %lld of %lld bytes.",
                status, length, requested, offset, size];
            break;
        }
        offset += length;
        diagnostics[@"bytesRead"] = @(offset);
    }
    int closeStatus = AFCFileRefClose(afc, file);
    diagnostics[@"fileCloseStatus"] = @(closeStatus);
    if (offset != size) return nil;
    if (closeStatus != 0) {
        diagnostics[@"phase"] = @"file_close";
        diagnostics[@"message"] = [NSString stringWithFormat:
            @"AFC file close returned %d after reading %lld bytes.", closeStatus, offset];
        return nil;
    }
    diagnostics[@"ok"] = @YES;
    diagnostics[@"phase"] = @"complete";
    return data;
}

// Read only the known artwork leaves through a generated Airlift link. AFC may
// deny access outside Media on a given device; this is a capability probe too.
// Never relocate original artwork to make it readable.
static NSDictionary *ExportCardArtwork(DeviceSession *session,
                                       NSString *link, NSString *root) {
    if (!GeneratedToken(link, AIRLIFT_LINK_PREFIX) || !root.isAbsolutePath)
        return @{ @"ok": @NO, @"error": @"invalid export arguments" };
    NSDictionary *attributes = [[NSFileManager defaultManager]
        attributesOfItemAtPath:root error:nil];
    if (![attributes[NSFileType] isEqual:NSFileTypeDirectory])
        return @{ @"ok": @NO, @"error": @"output must be a real directory" };
    NSArray *leaves = @[@"cardBackgroundCombined@3x.png",
                        @"cardBackgroundCombined@2x.png",
                        @"cardBackgroundCombined.pdf"];
    NSMutableArray *files = NSMutableArray.array;
    NSMutableArray *fileDiagnostics = NSMutableArray.array;
    NSDictionary *diagnostics = @{
        @"link": ArtworkFileInfo(session->afc, link),
        @"files": fileDiagnostics,
    };
    for (NSString *leaf in leaves) {
        NSString *remote = [link stringByAppendingPathComponent:leaf];
        NSMutableDictionary *readDiagnostics = [@{ @"leaf": leaf } mutableCopy];
        [fileDiagnostics addObject:readDiagnostics];
        NSData *data = ReadArtworkWithDiagnostics(
            session->afc, remote, 16 * 1024 * 1024, readDiagnostics);
        if (!data.length)
            return @{ @"ok": @NO, @"error": @"artwork_read_unavailable",
                      @"leaf": leaf, @"files": files,
                      @"diagnostics": diagnostics,
                      @"message": [readDiagnostics[@"message"] stringByAppendingString:
                          @" Originals were not moved or modified."] };
        NSError *error = nil;
        if (![data writeToFile:[root stringByAppendingPathComponent:leaf]
                       options:NSDataWritingWithoutOverwriting error:&error])
            return @{ @"ok": @NO, @"error": @"local_export_failed",
                      @"leaf": leaf, @"files": files,
                      @"diagnostics": diagnostics,
                      @"message": error.localizedDescription ?: @"Local write failed" };
        [files addObject:@{ @"name": leaf, @"bytes": @(data.length) }];
    }
    return @{ @"ok": @YES, @"files": files, @"diagnostics": diagnostics };
}

// An explicit experimental move-out operation puts one artwork file at this
// generated Media-root name. Export only that file, without renaming/deleting
// anything on the device. Canary names are reserved for controlled self-tests.
static NSDictionary *ExportRecoveredArtwork(DeviceSession *session,
                                             NSString *recovered,
                                             NSString *leaf, NSString *root) {
    NSArray *leaves = @[@"cardBackgroundCombined@3x.png",
                        @"cardBackgroundCombined@2x.png",
                        @"cardBackgroundCombined.pdf"];
    if (!GeneratedToken(recovered, AIRLIFT_RECOVERED_PREFIX) ||
        (![leaves containsObject:leaf] && !IsCanaryLeaf(leaf) &&
         !IsOriginalArtworkLeaf(@"pkpass", leaf) &&
         !IsOriginalArtworkLeaf(@"cache", leaf)) ||
        !root.isAbsolutePath)
        return @{ @"ok": @NO, @"error": @"invalid recovered export arguments" };
    NSDictionary *attributes = [[NSFileManager defaultManager]
        attributesOfItemAtPath:root error:nil];
    if (![attributes[NSFileType] isEqual:NSFileTypeDirectory])
        return @{ @"ok": @NO, @"error": @"output must be a real directory" };
    NSDictionary *status = RecoveredStatus(session, recovered);
    if (![status[@"present"] boolValue] ||
        ![status[@"metadata"][@"st_ifmt"] isEqual:@"S_IFREG"])
        return @{ @"ok": @NO, @"error": @"recovered_regular_file_unavailable",
                  @"leaf": leaf, @"files": @[], @"recoveredStatus": status,
                  @"message": @"Recovered artwork is not a confirmed regular file." };

    NSMutableDictionary *readDiagnostics = [@{ @"leaf": leaf } mutableCopy];
    NSData *data = ReadArtworkWithDiagnostics(
        session->afc, recovered, 16 * 1024 * 1024, readDiagnostics);
    NSDictionary *diagnostics = @{ @"files": @[readDiagnostics] };
    if (!data.length)
        return @{ @"ok": @NO, @"error": @"recovered_artwork_read_unavailable",
                  @"leaf": leaf, @"files": @[], @"diagnostics": diagnostics,
                  @"message": readDiagnostics[@"message"] ?: @"Recovered artwork could not be read." };
    NSError *error = nil;
    if (![data writeToFile:[root stringByAppendingPathComponent:leaf]
                   options:NSDataWritingWithoutOverwriting error:&error])
        return @{ @"ok": @NO, @"error": @"local_export_failed",
                  @"leaf": leaf, @"files": @[], @"diagnostics": diagnostics,
                  @"message": error.localizedDescription ?: @"Local write failed" };
    return @{ @"ok": @YES,
              @"files": @[@{ @"name": leaf, @"bytes": @(data.length) }],
              @"diagnostics": diagnostics };
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        signal(SIGPIPE, SIG_IGN);
        if (argc < 2) return 64;
        NSString *command = [NSString stringWithUTF8String:argv[1]];

        // Discovery takes no UDID and log streaming takes no Airlift session,
        // so both are handled before the targeted session is opened.
        if ([command isEqual:@"list"] && argc == 2) return ListDevices();
        if ([command isEqual:@"syslog"] && argc == 3) {
            TargetIdentifier = CFStringCreateWithCString(
                kCFAllocatorDefault, argv[2], kCFStringEncodingUTF8);
            if (!TargetIdentifier) return 64;
            int status = RunSyslog();
            if (TargetDevice) {
                CFRelease(TargetDevice);
                TargetDevice = NULL;
            }
            CFRelease(TargetIdentifier);
            return status;
        }

        if (argc < 3) return 64;
        TargetIdentifier = CFStringCreateWithCString(
            kCFAllocatorDefault, argv[2], kCFStringEncodingUTF8);
        if (!TargetIdentifier) return 64;

        DeviceSession session;
        OpenSession(&session);
        NSDictionary *summary = SessionSummary(&session);
        BOOL targetTested = NO;
        BOOL targetGatePassed = TargetGate(summary, &targetTested);
        NSDictionary *operation = nil;
        if (session.afcStatus == 0 && session.afc && targetGatePassed) {
            if ([command isEqual:@"probe"] && argc == 3) {
                NSArray<NSString *> *presentPaths =
                    PresentTrackedBooksPaths(session.afc);
                operation = @{ @"ok": @YES,
                    @"booksStagingAbsent":
                        @(AllTrackedBooksFilesAbsent(session.afc)),
                    @"presentBooksPaths": presentPaths,
                    @"fixedSyncInputPresent":
                        @([presentPaths containsObject:@"Books/Sync/Books.plist"]),
                    @"booksSyncPlistPresent":
                        @(AFCExists(session.afc, @"Books/Sync/Books.plist")) };
            } else if ([command isEqual:@"snapshot-books"] && argc == 4) {
                operation = SnapshotBooksState(
                    session.afc, [NSString stringWithUTF8String:argv[3]]);
            } else if ([command isEqual:@"restore-books"] && argc == 4) {
                operation = RestoreBooksState(
                    session.afc, [NSString stringWithUTF8String:argv[3]]);
            } else if ([command isEqual:@"stage"] && argc == 9) {
                operation = Stage(&session, @[
                    [NSString stringWithUTF8String:argv[3]],
                    [NSString stringWithUTF8String:argv[4]],
                    [NSString stringWithUTF8String:argv[5]],
                    [NSString stringWithUTF8String:argv[6]],
                    [NSString stringWithUTF8String:argv[7]],
                    [NSString stringWithUTF8String:argv[8]],
                ]);
            } else if ([command isEqual:@"finish"] && argc == 11) {
                operation = Finish(&session, @[
                    [NSString stringWithUTF8String:argv[3]],
                    [NSString stringWithUTF8String:argv[4]],
                    [NSString stringWithUTF8String:argv[5]],
                    [NSString stringWithUTF8String:argv[6]],
                    [NSString stringWithUTF8String:argv[7]],
                    [NSString stringWithUTF8String:argv[8]],
                    [NSString stringWithUTF8String:argv[9]],
                    [NSString stringWithUTF8String:argv[10]],
                ]);
            } else if ([command isEqual:@"export-card-artwork"] && argc == 5) {
                operation = ExportCardArtwork(&session,
                    [NSString stringWithUTF8String:argv[3]],
                    [NSString stringWithUTF8String:argv[4]]);
            } else if ([command isEqual:@"export-recovered-artwork"] && argc == 6) {
                operation = ExportRecoveredArtwork(&session,
                    [NSString stringWithUTF8String:argv[3]],
                    [NSString stringWithUTF8String:argv[4]],
                    [NSString stringWithUTF8String:argv[5]]);
            } else if ([command isEqual:@"recovered-status"] && argc == 4) {
                operation = RecoveredStatus(&session,
                    [NSString stringWithUTF8String:argv[3]]);
            } else if ([command isEqual:@"refresh-move-books"] && (argc == 8 || argc == 9)) {
                NSMutableArray<NSString *> *arguments = NSMutableArray.array;
                for (int index = 3; index < argc; index++)
                    [arguments addObject:[NSString stringWithUTF8String:argv[index]]];
                operation = RefreshMoveBooks(&session, arguments);
            } else if ([command isEqual:@"refresh-original-books"] && argc == 10) {
                NSMutableArray<NSString *> *arguments = NSMutableArray.array;
                for (int index = 3; index < argc; index++)
                    [arguments addObject:[NSString stringWithUTF8String:argv[index]]];
                operation = RefreshOriginalBooks(&session, arguments);
            } else if ([command isEqual:@"finish-move-backup"] && argc == 7) {
                operation = FinishMoveBackup(&session, @[
                    [NSString stringWithUTF8String:argv[3]],
                    [NSString stringWithUTF8String:argv[4]],
                    [NSString stringWithUTF8String:argv[5]],
                    [NSString stringWithUTF8String:argv[6]],
                ]);
            } else if ([command isEqual:@"finish-write"] && argc == 7) {
                operation = FinishWrite(&session, @[
                    [NSString stringWithUTF8String:argv[3]],
                    [NSString stringWithUTF8String:argv[4]],
                    [NSString stringWithUTF8String:argv[5]],
                    [NSString stringWithUTF8String:argv[6]],
                ]);
            }
        }

        NSMutableDictionary *result = summary.mutableCopy;
        result[@"targetGatePassed"] = @(targetGatePassed);
        result[@"targetTested"] = @(targetTested);
        result[@"command"] = command ?: @"(nil)";
        result[@"operation"] = operation ?: @{ @"ok": @NO };
        PrintJSON(result);
        BOOL ok = targetGatePassed && session.afcStatus == 0 &&
            [operation[@"ok"] boolValue];
        CloseSession(&session);
        CFRelease(TargetIdentifier);
        return ok ? 0 : 2;
    }
}
