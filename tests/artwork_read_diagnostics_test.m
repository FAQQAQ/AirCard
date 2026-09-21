// Standalone mock harness: no device services are opened. Compile with the
// same Foundation/MobileDevice libraries as device_helper and run this binary.
#define main device_helper_unused_main
#include "../Sources/device_helper.m"
#undef main

static NSArray<NSArray<NSString *> *> *MockMetadata;
static NSData *MockBytes;
static NSUInteger MockMetadataIndex;
static NSUInteger MockOffset;
static int MockInfoOpenStatus, MockMetadataReadStatus, MockMetadataCloseStatus;
static int MockFileOpenStatus, MockReadStatus, MockFileCloseStatus;
static BOOL MockNoInfoHandle, MockNoFileHandle, MockOversizedRead;
static NSUInteger MockFileOpens, MockFileCloses;

int AFCFileInfoOpen(AFCConnectionRef connection, const char *path,
                    AFCKeyValueRef *dictionary) {
    (void)connection; (void)path;
    MockMetadataIndex = 0;
    *dictionary = MockNoInfoHandle ? NULL : (void *)1;
    return MockInfoOpenStatus;
}
int AFCKeyValueRead(AFCKeyValueRef dictionary, char **key, char **value) {
    (void)dictionary;
    if (MockMetadataReadStatus) return MockMetadataReadStatus;
    if (MockMetadataIndex == MockMetadata.count) { *key = NULL; *value = NULL; return 0; }
    NSArray *entry = MockMetadata[MockMetadataIndex++];
    *key = (char *)[entry[0] UTF8String];
    *value = (char *)[entry[1] UTF8String];
    return 0;
}
int AFCKeyValueClose(AFCKeyValueRef dictionary) {
    (void)dictionary;
    return MockMetadataCloseStatus;
}
int AFCFileRefOpen(AFCConnectionRef connection, const char *path,
                   unsigned long long mode, AFCFileRef *file) {
    (void)connection; (void)path;
    NSCAssert(mode == 1, @"Artwork must only be opened read-only");
    MockFileOpens++;
    *file = MockNoFileHandle ? NULL : (void *)1;
    return MockFileOpenStatus;
}
int AFCFileRefRead(AFCConnectionRef connection, AFCFileRef file,
                   void *bytes, long *length) {
    (void)connection; (void)file;
    if (MockReadStatus) return MockReadStatus;
    if (MockOversizedRead) { (*length)++; return 0; }
    NSUInteger actual = MIN((NSUInteger)*length, MockBytes.length - MockOffset);
    memcpy(bytes, (const uint8_t *)MockBytes.bytes + MockOffset, actual);
    MockOffset += actual;
    *length = (long)actual;
    return 0;
}
int AFCFileRefClose(AFCConnectionRef connection, AFCFileRef file) {
    (void)connection; (void)file;
    MockFileCloses++;
    return MockFileCloseStatus;
}

static void ResetMock(void) {
    MockMetadata = @[@[@"st_size", @"3"], @[@"st_ifmt", @"S_IFREG"],
                     @[@"LinkTarget", @"/private/var/mobile/Library/Passes/Cards/test.pkpass"]];
    MockBytes = [@"abc" dataUsingEncoding:NSUTF8StringEncoding];
    MockMetadataIndex = MockOffset = MockFileOpens = MockFileCloses = 0;
    MockInfoOpenStatus = MockMetadataReadStatus = MockMetadataCloseStatus = 0;
    MockFileOpenStatus = MockReadStatus = MockFileCloseStatus = 0;
    MockNoInfoHandle = MockNoFileHandle = MockOversizedRead = NO;
}
static NSData *ReadMock(NSMutableDictionary *diagnostics) {
    return ReadArtworkWithDiagnostics(NULL, @"generated/cardBackgroundCombined@3x.png",
                                      16 * 1024 * 1024, diagnostics);
}
#define CHECK(condition) NSCAssert((condition), @"Failed: %s", #condition)

int main(void) {
    @autoreleasepool {
        ResetMock();
        NSMutableDictionary *d = NSMutableDictionary.dictionary;
        CHECK([ReadMock(d) isEqualToData:MockBytes]);
        CHECK([d[@"ok"] boolValue] && [d[@"bytesRead"] intValue] == 3);
        CHECK([d[@"fileInfo"][@"metadata"][@"st_ifmt"] isEqual:@"S_IFREG"]);
        CHECK(d[@"fileInfo"][@"metadata"][@"LinkTarget"] != nil);
        CHECK(MockFileCloses == 1);

        ResetMock(); d = NSMutableDictionary.dictionary;
        MockInfoOpenStatus = 8; MockMetadataCloseStatus = 9;
        CHECK(ReadMock(d) == nil);
        CHECK([d[@"phase"] isEqual:@"file_info_open"]);
        CHECK([d[@"fileInfo"][@"fileInfoOpenStatus"] intValue] == 8);
        CHECK([d[@"fileInfo"][@"keyValueCloseStatus"] intValue] == 9);
        CHECK(MockFileOpens == 0);

        ResetMock(); d = NSMutableDictionary.dictionary;
        MockNoInfoHandle = YES;
        CHECK(ReadMock(d) == nil && [d[@"phase"] isEqual:@"file_info_open"]);
        CHECK(d[@"fileInfo"][@"keyValueCloseStatus"] == nil);

        ResetMock(); d = NSMutableDictionary.dictionary;
        MockMetadataReadStatus = 7; MockMetadataCloseStatus = 9;
        CHECK(ReadMock(d) == nil && [d[@"phase"] isEqual:@"metadata_read"]);
        CHECK([d[@"fileInfo"][@"keyValueReadStatus"] intValue] == 7);
        CHECK([d[@"fileInfo"][@"keyValueCloseStatus"] intValue] == 9);

        ResetMock(); d = NSMutableDictionary.dictionary;
        MockMetadataCloseStatus = 9;
        CHECK(ReadMock(d) == nil && [d[@"phase"] isEqual:@"metadata_close"]);
        CHECK(MockFileOpens == 0);

        for (NSString *size in @[@"-1", @"3bad", @" 3", @"", @"9223372036854775808"]) {
            ResetMock(); d = NSMutableDictionary.dictionary;
            MockMetadata = @[@[@"st_size", size]];
            CHECK(ReadMock(d) == nil && [d[@"phase"] isEqual:@"file_size"]);
            CHECK(MockFileOpens == 0);
        }
        ResetMock(); d = NSMutableDictionary.dictionary;
        MockMetadata = @[@[@"st_size", @"0"]];
        CHECK(ReadMock(d) == nil && [d[@"phase"] isEqual:@"empty_file"]);
        CHECK(MockFileOpens == 0);

        ResetMock(); d = NSMutableDictionary.dictionary;
        MockMetadata = @[@[@"st_size", @"16777217"]];
        CHECK(ReadMock(d) == nil && [d[@"phase"] isEqual:@"size_limit"]);
        CHECK([d[@"fileSize"] longLongValue] == 16777217 && MockFileOpens == 0);

        ResetMock(); d = NSMutableDictionary.dictionary;
        MockFileOpenStatus = 3; MockFileCloseStatus = 9;
        CHECK(ReadMock(d) == nil && [d[@"phase"] isEqual:@"file_open"]);
        CHECK([d[@"fileOpenStatus"] intValue] == 3);
        CHECK([d[@"fileCloseStatus"] intValue] == 9 && MockFileCloses == 1);

        ResetMock(); d = NSMutableDictionary.dictionary;
        MockReadStatus = 4; MockFileCloseStatus = 11;
        CHECK(ReadMock(d) == nil && [d[@"phase"] isEqual:@"file_read"]);
        CHECK([d[@"fileReadStatus"] intValue] == 4);
        CHECK([d[@"fileCloseStatus"] intValue] == 11 && MockFileCloses == 1);
        CHECK([d[@"bytesRead"] intValue] == 0);

        ResetMock(); d = NSMutableDictionary.dictionary;
        MockBytes = [@"ab" dataUsingEncoding:NSUTF8StringEncoding];
        CHECK(ReadMock(d) == nil && [d[@"phase"] isEqual:@"file_read"]);
        CHECK([d[@"fileReadStatus"] intValue] == 0);
        CHECK([d[@"bytesRead"] intValue] == 2 && MockFileCloses == 1);

        ResetMock(); d = NSMutableDictionary.dictionary;
        MockOversizedRead = YES;
        CHECK(ReadMock(d) == nil && [d[@"phase"] isEqual:@"file_read"]);
        CHECK([d[@"bytesRead"] intValue] == 0 && MockFileCloses == 1);

        ResetMock(); d = NSMutableDictionary.dictionary;
        MockFileCloseStatus = 11;
        CHECK(ReadMock(d) == nil && [d[@"phase"] isEqual:@"file_close"]);
        CHECK([d[@"bytesRead"] intValue] == 3);
        CHECK([d[@"fileCloseStatus"] intValue] == 11);

        ResetMock(); d = NSMutableDictionary.dictionary;
        MockBytes = [NSMutableData dataWithLength:70000];
        MockMetadata = @[@[@"st_size", @"70000"]];
        CHECK([ReadMock(d) isEqualToData:MockBytes]);
        CHECK([d[@"readCalls"] intValue] == 2 && [d[@"bytesRead"] intValue] == 70000);

        puts("Native artwork diagnostics: 14 scenario groups passed (mock AFC only).");
    }
    return 0;
}
