// Mock AFC only: no device session or real service is opened by these tests.
#define main device_helper_unused_main
#include "../Sources/device_helper.m"
#undef main

#define CHECK(condition) NSCAssert((condition), @"Failed: %s", #condition)
static NSMutableDictionary<NSString *, NSData *> *MockFiles;
static NSMutableArray<NSString *> *MockRemoved;
static NSDictionary<NSString *, NSNumber *> *MockStatuses;
static NSArray<NSArray<NSString *> *> *MockMetadata;
static NSUInteger MockMetadataIndex, MockOffset, MockFileOpens, MockInfoOpens;
static NSData *MockReadBytes;
static int MockMetadataStatus;
static NSMutableDictionary<NSString *, NSArray *> *MockMetadataOverrides;
static NSString *MockWritePath;
static NSUInteger MockWrites;
int AFCFileInfoOpen(AFCConnectionRef connection, const char *path,
                    AFCKeyValueRef *dictionary) {
    (void)connection;
    MockInfoOpens++;
    NSString *name = [NSString stringWithUTF8String:path];
    *dictionary = NULL;
    if (MockStatuses[name]) return [MockStatuses[name] intValue];
    NSData *bytes = MockFiles[name];
    if (!bytes) return 8;
    MockMetadata = MockMetadataOverrides[name] ?:
        @[@[@"st_size", [NSString stringWithFormat:@"%lu", (unsigned long)bytes.length]],
          @[@"st_ifmt", @"S_IFREG"]];
    MockMetadataIndex = 0;
    *dictionary = (void *)1;
    return 0;
}
int AFCKeyValueRead(AFCKeyValueRef dictionary, char **key, char **value) {
    (void)dictionary;
    if (MockMetadataStatus) return MockMetadataStatus;
    if (MockMetadataIndex == MockMetadata.count) { *key = NULL; *value = NULL; return 0; }
    NSArray *row = MockMetadata[MockMetadataIndex++];
    *key = (char *)[row[0] UTF8String]; *value = (char *)[row[1] UTF8String];
    return 0;
}
int AFCKeyValueClose(AFCKeyValueRef dictionary) { (void)dictionary; return 0; }
int AFCFileRefOpen(AFCConnectionRef connection, const char *path,
                   unsigned long long mode, AFCFileRef *file) {
    (void)connection;
    if (mode == 3) {
        MockWritePath = [NSString stringWithUTF8String:path];
        CHECK([MockWritePath isEqual:@"Books/Sync/Books.plist"]);
        *file = (void *)2;
        return 0;
    }
    CHECK(mode == 1);
    MockFileOpens++;
    MockReadBytes = MockFiles[[NSString stringWithUTF8String:path]];
    MockOffset = 0;
    *file = MockReadBytes ? (void *)1 : NULL;
    return MockReadBytes ? 0 : 8;
}
int AFCFileRefRead(AFCConnectionRef connection, AFCFileRef file,
                   void *bytes, long *length) {
    (void)connection; (void)file;
    NSUInteger actual = MIN((NSUInteger)*length, MockReadBytes.length - MockOffset);
    memcpy(bytes, (const uint8_t *)MockReadBytes.bytes + MockOffset, actual);
    MockOffset += actual; *length = (long)actual;
    return 0;
}
int AFCFileRefClose(AFCConnectionRef connection, AFCFileRef file) {
    (void)connection; (void)file; return 0;
}
int AFCFileRefWrite(AFCConnectionRef connection, AFCFileRef file,
                    const void *bytes, long length) {
    (void)connection;
    CHECK(file == (void *)2 && MockWritePath);
    MockFiles[MockWritePath] = [NSData dataWithBytes:bytes length:(NSUInteger)length];
    MockWrites++;
    return 0;
}
int AFCRemovePath(AFCConnectionRef connection, const char *path) {
    (void)connection;
    NSString *name = [NSString stringWithUTF8String:path];
    [MockRemoved addObject:name];
    [MockFiles removeObjectForKey:name];
    return 0;
}

static void ResetMock(void) {
    MockFiles = NSMutableDictionary.dictionary;
    MockRemoved = NSMutableArray.array;
    MockStatuses = @{};
    MockMetadataStatus = 0;
    MockFileOpens = MockInfoOpens = 0;
    MockMetadataOverrides = NSMutableDictionary.dictionary;
    MockWritePath = nil;
    MockWrites = 0;
}

static NSString *WriteEmptySnapshot(NSString *parent) {
    NSString *root = [parent stringByAppendingPathComponent:@"snapshot"];
    CHECK([[NSFileManager defaultManager] createDirectoryAtPath:root
        withIntermediateDirectories:NO attributes:nil error:NULL]);
    NSMutableDictionary *files = NSMutableDictionary.dictionary;
    NSMutableDictionary *directories = NSMutableDictionary.dictionary;
    for (NSUInteger index = 0; index < sizeof(TrackedBooksFiles) / sizeof(char *); index++)
        files[[NSString stringWithUTF8String:TrackedBooksFiles[index]]] =
            @{ @"exists": @NO, @"localName": SnapshotFileName(index), @"size": @0 };
    for (NSUInteger index = 0; index < sizeof(TrackedBooksDirectories) / sizeof(char *); index++)
        directories[[NSString stringWithUTF8String:TrackedBooksDirectories[index]]] = @NO;
    NSDictionary *snapshot = @{ @"version": @1, @"files": files, @"directories": directories };
    CHECK([snapshot writeToFile:SnapshotManifestPath(root) atomically:YES]);
    return root;
}

int main(void) {
    @autoreleasepool {
        DeviceSession session = {0};
        NSString *token = @"0123456789abcdef0123";
        NSString *source = [AIRLIFT_SOURCE_PREFIX stringByAppendingString:token];
        NSString *link = [AIRLIFT_LINK_PREFIX stringByAppendingString:token];
        NSString *recovered = [AIRLIFT_RECOVERED_PREFIX stringByAppendingString:token];
        NSData *original = [@"original artwork bytes" dataUsingEncoding:NSUTF8StringEncoding];
        char temporary[] = "/tmp/aircard-move-native-XXXXXX";
        CHECK(mkdtemp(temporary) != NULL);
        NSString *root = [NSString stringWithUTF8String:temporary];
        NSString *snapshot = WriteEmptySnapshot(root);
        NSArray *cleanupArgs = @[source, link, recovered, snapshot];

        ResetMock();
        NSDictionary *r = RecoveredStatus(&session, recovered);
        CHECK([r[@"ok"] boolValue] && [r[@"absent"] boolValue]);
        CHECK([r[@"fileInfoOpenStatus"] intValue] == 8 && ![r[@"exists"] boolValue]);
        for (NSNumber *error in @[@1, @3, @7, @9, @30]) {
            MockStatuses = @{ recovered: error };
            r = RecoveredStatus(&session, recovered);
            CHECK(![r[@"ok"] boolValue] && [r[@"presence"] isEqual:@"unknown"]);
            CHECK(r[@"exists"] == NSNull.null && ![r[@"absent"] boolValue]);
            r = FinishMoveBackup(&session, cleanupArgs);
            CHECK([r[@"cleanupRefused"] boolValue] && MockRemoved.count == 0);
        }

        ResetMock(); MockFiles[recovered] = original;
        r = RecoveredStatus(&session, recovered);
        CHECK([r[@"ok"] boolValue] && [r[@"exists"] boolValue]);
        CHECK([r[@"metadata"][@"st_ifmt"] isEqual:@"S_IFREG"]);
        r = FinishMoveBackup(&session, cleanupArgs);
        CHECK([r[@"cleanupRefused"] boolValue] && MockRemoved.count == 0);
        CHECK([MockFiles[recovered] isEqualToData:original]);
        MockMetadataStatus = 7;
        r = RecoveredStatus(&session, recovered);
        CHECK([r[@"presence"] isEqual:@"unknown"] && ![r[@"absent"] boolValue]);

        ResetMock();
        CHECK(![RecoveredStatus(&session, @"../original")[@"ok"] boolValue]);
        CHECK(MockInfoOpens == 0);
        CHECK(![FinishMoveBackup(&session, @[source, link, @"not-generated", snapshot])[@"ok"] boolValue]);
        CHECK(MockInfoOpens == 0 && MockRemoved.count == 0);
        r = FinishMoveBackup(&session, cleanupArgs);
        CHECK([r[@"cleanupComplete"] boolValue] && [r[@"booksPreimageRestored"] boolValue]);
        CHECK(![MockRemoved containsObject:recovered]);

        ResetMock(); MockFiles[source] = original; MockFiles[link] = original;
        r = FinishMoveBackup(&session, cleanupArgs);
        CHECK([r[@"cleanupComplete"] boolValue]);
        CHECK(([MockRemoved isEqual:@[link, source]]));
        CHECK(![MockRemoved containsObject:recovered]);

        ResetMock(); MockStatuses = @{source: @7};
        r = FinishMoveBackup(&session, cleanupArgs);
        CHECK(![r[@"cleanupComplete"] boolValue] && ![r[@"sourceAbsent"] boolValue]);

        ResetMock(); MockFiles[recovered] = original;
        NSString *leaf = @"cardBackgroundCombined@3x.png";
        r = ExportRecoveredArtwork(&session, recovered, leaf, root);
        CHECK([r[@"ok"] boolValue] && MockRemoved.count == 0);
        CHECK([[NSData dataWithContentsOfFile:[root stringByAppendingPathComponent:leaf]] isEqualToData:original]);
        MockFiles[recovered] = [@"changed device bytes" dataUsingEncoding:NSUTF8StringEncoding];
        r = ExportRecoveredArtwork(&session, recovered, leaf, root);
        CHECK(![r[@"ok"] boolValue] && [r[@"error"] isEqual:@"local_export_failed"]);
        CHECK([[NSData dataWithContentsOfFile:[root stringByAppendingPathComponent:leaf]] isEqualToData:original]);
        CHECK(MockRemoved.count == 0);

        for (NSString *invalidLeaf in @[@"../../anything", @"pass.json", @"cardBackgroundCombined@4x.png"]) {
            NSUInteger calls = MockInfoOpens;
            CHECK(![ExportRecoveredArtwork(&session, recovered, invalidLeaf, root)[@"ok"] boolValue]);
            CHECK(MockInfoOpens == calls);
        }
        NSString *canary = [AIRLIFT_CANARY_PREFIX stringByAppendingString:@"0123456789abcdef0123456789abcdef.bin"];
        CHECK([ExportRecoveredArtwork(&session, recovered, canary, root)[@"ok"] boolValue]);
        CHECK(![ExportRecoveredArtwork(&session, recovered, leaf, @"relative")[@"ok"] boolValue]);

        ResetMock();
        NSString *cardHash = @"abcdefghijklmnopqrstuvwxyza=";
        NSString *sourceLink = [source stringByAppendingPathComponent:@"p0/p1/p2/link"];
        NSString *expectedTarget = [NSString stringWithFormat:
            @"../../../var/mobile/Library/Passes/Cards/%@.pkpass", cardHash];
        NSArray *linkMetadata = @[@[@"st_ifmt", @"S_IFLNK"], @[@"LinkTarget", expectedTarget]];
        MockFiles[source] = original;
        MockMetadataOverrides[source] = @[@[@"st_ifmt", @"S_IFDIR"]];
        MockFiles[sourceLink] = original;
        MockMetadataOverrides[sourceLink] = linkMetadata;
        MockFiles[@"Books"] = MockFiles[@"Books/Sync"] = original;
        NSArray *refresh = @[source, link, recovered, cardHash, snapshot];
        r = RefreshMoveBooks(&session, refresh);
        CHECK([r[@"ok"] boolValue] && MockWrites == 1 && MockRemoved.count == 0);
        NSDictionary *books = [NSPropertyListSerialization propertyListWithData:
            MockFiles[@"Books/Sync/Books.plist"] options:0 format:NULL error:NULL];
        NSArray *rows = books[@"Books"];
        CHECK(rows.count == 5);
        CHECK([rows[0][@"Persistent ID"] isEqual:[@"../../" stringByAppendingString:sourceLink]]);
        CHECK([rows[1][@"Persistent ID"] isEqual:[@"../../" stringByAppendingString:recovered]]);
        CHECK(([rows[2][@"Persistent ID"] isEqual:[NSString stringWithFormat:
            @"../../../Library/Passes/Cards/%@.pkpass/cardBackgroundCombined@3x.png", cardHash]]));
        CHECK([rows[4][@"Item ID"] isEqual:@"5"]);
        [MockFiles removeObjectForKey:sourceLink];
        MockFiles[link] = original; MockMetadataOverrides[link] = linkMetadata;
        MockFiles[recovered] = original;
        r = RefreshMoveBooks(&session, [refresh arrayByAddingObject:canary]);
        CHECK([r[@"ok"] boolValue] && [r[@"identifierCount"] intValue] == 6);
        CHECK([MockFiles[recovered] isEqualToData:original] && MockRemoved.count == 0);
        NSUInteger writes = MockWrites;
        MockMetadataOverrides[link] = @[@[@"st_ifmt", @"S_IFLNK"], @[@"LinkTarget", @"../../../wrong"]];
        CHECK(![RefreshMoveBooks(&session, refresh)[@"ok"] boolValue]);
        CHECK(MockWrites == writes);
        CHECK(![RefreshMoveBooks(&session, @[source, link, recovered, @"../../invalid-card", snapshot])[@"ok"] boolValue]);
        CHECK(![RefreshMoveBooks(&session, [refresh arrayByAddingObject:@"pass.json"])[@"ok"] boolValue]);
        CHECK(MockWrites == writes);

        ResetMock();
        MockFiles[source] = original;
        MockMetadataOverrides[source] = @[@[@"st_ifmt", @"S_IFDIR"]];
        MockFiles[link] = original;
        MockFiles[@"Books"] = MockFiles[@"Books/Sync"] = original;
        NSDictionary<NSString *, NSArray<NSString *> *> *originalLeaves = @{
            @"pkpass": @[@"cardBackground.png", @"cardBackground@2x.png", @"cardBackground@3x.png",
                @"cardBackground.pdf", @"strip.png", @"strip@2x.png", @"strip@3x.png",
                @"background.png", @"background@2x.png", @"background@3x.png",
                @"logo.png", @"logo@2x.png", @"logo@3x.png",
                @"cardBackgroundCombined.urls", @"cardBackgroundCombined@2x.urls",
                @"cardBackgroundCombined@3x.urls", @"cardBackgroundCombined.pdf.urls",
                @"cardBackgroundCombined@2x.png.urls", @"cardBackgroundCombined@3x.png.urls"],
            @"cache": @[@"FrontFace", @"PlaceHolder", @"Preview"],
            @"pkcache": @[@"FrontFace", @"PlaceHolder", @"Preview"],
        };
        for (NSString *container in originalLeaves) {
            NSString *target = [NSString stringWithFormat:
                @"../../../var/mobile/Library/Passes/Cards/%@.%@", cardHash, container];
            MockMetadataOverrides[link] = @[@[@"st_ifmt", @"S_IFLNK"], @[@"LinkTarget", target]];
            for (NSString *artworkLeaf in originalLeaves[container]) {
                r = RefreshOriginalBooks(&session,
                    @[source, link, recovered, cardHash, container, artworkLeaf, snapshot]);
                CHECK([r[@"ok"] boolValue] && [r[@"identifierCount"] intValue] == 3);
                books = [NSPropertyListSerialization propertyListWithData:
                    MockFiles[@"Books/Sync/Books.plist"] options:0 format:NULL error:NULL];
                rows = books[@"Books"];
                CHECK(rows.count == 3);
                CHECK(([rows[2][@"Persistent ID"] isEqual:[NSString stringWithFormat:
                    @"../../../Library/Passes/Cards/%@.%@/%@", cardHash, container, artworkLeaf]]));
                CHECK(MockRemoved.count == 0);
            }
        }
        NSUInteger writesBeforeInvalid = MockWrites;
        NSUInteger probesBeforeInvalid = MockInfoOpens;
        NSArray *invalidSelections = @[@[@"pkpass", @"pass.json"], @[@"pkpass", @"manifest.json"],
            @[@"pkpass", @"signature"], @[@"pkpass", @"FrontFace"], @[@"pkpass", @"../logo.png"],
            @[@"cache", @"logo.png"], @[@"pkcache", @"Preview.png"],
            @[@"../../private", @"FrontFace"], @[@"pkpass", @"cardBackgroundCombined@3x.png"],
            @[@"cache", @"cardBackgroundCombined.urls"], @[@"pkpass", @"pass.urls"],
            @[@"pkpass", @"cardBackgroundCombined@4x.urls"]];
        for (NSArray *selection in invalidSelections)
            CHECK(![RefreshOriginalBooks(&session,
                @[source, link, recovered, cardHash, selection[0], selection[1], snapshot])[@"ok"] boolValue]);
        CHECK(MockWrites == writesBeforeInvalid && MockInfoOpens == probesBeforeInvalid);
        MockMetadataOverrides[link] = @[@[@"st_ifmt", @"S_IFLNK"],
            @[@"LinkTarget", [NSString stringWithFormat:
                @"../../../var/mobile/Library/Passes/Cards/%@.pkcache", cardHash]]];
        CHECK(![RefreshOriginalBooks(&session,
            @[source, link, recovered, cardHash, @"cache", @"FrontFace", snapshot])[@"ok"] boolValue]);
        CHECK(MockWrites == writesBeforeInvalid);

        NSData *cacheBytes = [NSPropertyListSerialization dataWithPropertyList:
            @{ @"$archiver": @"NSKeyedArchiver", @"$objects": @[@"$null", original] }
            format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
        MockFiles[recovered] = cacheBytes;
        for (NSString *cacheLeaf in @[@"FrontFace", @"PlaceHolder", @"Preview"]) {
            r = ExportRecoveredArtwork(&session, recovered, cacheLeaf, root);
            CHECK([r[@"ok"] boolValue]);
            CHECK([[NSData dataWithContentsOfFile:[root stringByAppendingPathComponent:cacheLeaf]]
                isEqualToData:cacheBytes]);
        }
        for (NSString *artworkLeaf in originalLeaves[@"pkpass"]) {
            CHECK([ExportRecoveredArtwork(&session, recovered, artworkLeaf, root)[@"ok"] boolValue]);
            CHECK([[NSData dataWithContentsOfFile:[root stringByAppendingPathComponent:artworkLeaf]]
                isEqualToData:cacheBytes]);
        }
        for (NSString *privateLeaf in @[@"pass.json", @"manifest.json", @"signature", @"pass.urls",
                                       @"cardBackgroundCombined@4x.urls"])
            CHECK(![ExportRecoveredArtwork(&session, recovered, privateLeaf, root)[@"ok"] boolValue]);
        CHECK([MockFiles[recovered] isEqualToData:cacheBytes] && MockRemoved.count == 0);

        ResetMock();
        NSString *snapshotProbe = [root stringByAppendingPathComponent:@"snapshot-probe"];
        CHECK([[NSFileManager defaultManager] createDirectoryAtPath:snapshotProbe
            withIntermediateDirectories:NO attributes:nil error:NULL]);
        MockStatuses = @{ @"Books/Sync/Books.plist": @10 };
        r = SnapshotBooksState(NULL, snapshotProbe);
        CHECK(![r[@"ok"] boolValue]);
        CHECK([r[@"snapshotStatusUnknown"] isEqual:@"Books/Sync/Books.plist"]);
        CHECK(![[NSFileManager defaultManager] fileExistsAtPath:SnapshotManifestPath(snapshotProbe)]);
        CHECK(!BooksStateMatchesSnapshot(NULL, snapshot, LoadBooksSnapshot(snapshot)));
        r = RestoreBooksState(NULL, snapshot);
        CHECK(![r[@"ok"] boolValue] && [r[@"restoreRefused"] boolValue]);
        CHECK(MockRemoved.count == 0 && MockWrites == 0);

        MockStatuses = @{ @"Books/Sync": @10 };
        CHECK(![SnapshotBooksState(NULL, snapshotProbe)[@"ok"] boolValue]);
        CHECK(!BooksStateMatchesSnapshot(NULL, snapshot, LoadBooksSnapshot(snapshot)));
        CHECK([RestoreBooksState(NULL, snapshot)[@"restoreRefused"] boolValue]);
        CHECK(MockRemoved.count == 0 && MockWrites == 0);
        MockStatuses = @{};
        r = SnapshotBooksState(NULL, snapshotProbe);
        CHECK([r[@"ok"] boolValue] && [r[@"snapshotDurable"] boolValue]);
        CHECK(BooksStateMatchesSnapshot(NULL, snapshotProbe, LoadBooksSnapshot(snapshotProbe)));

        ResetMock();
        NSString *snapshotWithFile = [root stringByAppendingPathComponent:@"snapshot-with-file"];
        CHECK([[NSFileManager defaultManager] createDirectoryAtPath:snapshotWithFile
            withIntermediateDirectories:NO attributes:nil error:NULL]);
        MockFiles[@"Books/Books.plist"] = original;
        MockFiles[@"Books"] = original;
        MockMetadataOverrides[@"Books"] = @[@[@"st_ifmt", @"S_IFDIR"]];
        r = SnapshotBooksState(NULL, snapshotWithFile);
        CHECK([r[@"ok"] boolValue] && [r[@"snapshotDurable"] boolValue]);
        CHECK([[NSData dataWithContentsOfFile:[snapshotWithFile stringByAppendingPathComponent:@"file-0.bin"]]
            isEqualToData:original]);
        CHECK(BooksStateMatchesSnapshot(NULL, snapshotWithFile, LoadBooksSnapshot(snapshotWithFile)));

        CHECK([[NSFileManager defaultManager] removeItemAtPath:root error:NULL]);
        puts("Native move-backup: status, refusal, non-deletion, export, no-overwrite, scoped Books refresh, strict snapshot/restore and durable snapshot scenarios passed (mock AFC only).");
    }
    return 0;
}
