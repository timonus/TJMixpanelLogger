//
//  TJMixpanelLogger.m
//
//  Created by Tim Johnsen on 11/21/22.
//  Copyright (c) 2022 Tim Johnsen. All rights reserved.
//

#import <CoreFoundation/CoreFoundation.h>
#import <sys/utsname.h>
#import <sys/sysctl.h>

#if TARGET_OS_WATCH
#import <WatchKit/WatchKit.h>
#else
#import <UIKit/UIKit.h>
#endif

#import "TJMixpanelLogger.h"

#import <zlib.h>

// Thanks Claude https://tijo.link/BGdVNx
static NSData *_gzipCompressData(NSData *const data, NSError **error) {
   if (!data.length) {
       if (error) {
           *error = [NSError errorWithDomain:@"CompressionErrorDomain" code:1
               userInfo:@{NSLocalizedDescriptionKey: @"Invalid input data"}];
       }
       return nil;
   }
   
   z_stream strm;
   strm.zalloc = Z_NULL;
   strm.zfree = Z_NULL;
   strm.opaque = Z_NULL;
   
   // Initialize deflate with gzip format
   if (deflateInit2(&strm, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY) != Z_OK) {
       if (error) {
           *error = [NSError errorWithDomain:@"CompressionErrorDomain" code:2
               userInfo:@{NSLocalizedDescriptionKey: @"Failed to initialize compression"}];
       }
       return nil;
   }
   
   // Set up input
   strm.avail_in = (uInt)data.length;
   strm.next_in = (Bytef *)data.bytes;
   
   // Prepare output buffer (compress can increase size)
   NSMutableData *compressedData = [NSMutableData dataWithLength:data.length * 1.1 + 12];
   strm.avail_out = (uInt)compressedData.length;
   strm.next_out = compressedData.mutableBytes;
   
   // Compress
   if (deflate(&strm, Z_FINISH) != Z_STREAM_END) {
       deflateEnd(&strm);
       if (error) {
           *error = [NSError errorWithDomain:@"CompressionErrorDomain" code:3
               userInfo:@{NSLocalizedDescriptionKey: @"Compression failed"}];
       }
       return nil;
   }
   
   // Cleanup and finalize
   [compressedData setLength:strm.total_out];
   deflateEnd(&strm);
   
   return compressedData;
}

__attribute__((objc_direct_members))
@implementation TJMixpanelLogger

static NSString *_projectToken;
static NSString *_sharedContainerIdentifier;
static NSDictionary *_customProperties;

+ (void)setProjectToken:(NSString *)trackingIdentifier
{
    _projectToken = trackingIdentifier;
}

+ (NSString *)projectToken
{
    return _projectToken;
}

+ (void)setSharedContainerIdentifier:(NSString *)sharedContainerIdentifier
{
    _sharedContainerIdentifier = sharedContainerIdentifier;
}

+ (NSString *)sharedContainerIdentifier
{
    return _sharedContainerIdentifier;
}

+ (void)setCustomProperties:(NSDictionary *)customProperties
{
    _customProperties = [customProperties copy];
}

+ (NSDictionary *)customProperties
{
    return _customProperties;
}

#define kUUIDByteLength 16 // Per docs, NSUUIDs are 16 bytes in length

static NSString *_uuidToBase64(NSUUID *const uuid)
{
    unsigned char bytes[kUUIDByteLength];
    [uuid getUUIDBytes:bytes];
    NSData *const data = [NSData dataWithBytesNoCopy:bytes length:kUUIDByteLength freeWhenDone:NO];
    // distinct_id cannot contain slashes per https://help.mixpanel.com/hc/en-us/articles/115004509406-Distinct-IDs-
    NSString *const string = [[[data base64EncodedStringWithOptions:0]
                               substringToIndex:22] // Strip off trailing "=="
                              stringByReplacingOccurrencesOfString:@"/" withString:@"-"];
    return string;
}

+ (void)logEventWithName:(NSString *const)name properties:(NSDictionary *const)eventProperties
{
    if (name.length == 0) {
        NSLog(@"[TJMixpanelLogger] Invalid event name %s", __PRETTY_FUNCTION__);
        return;
    }
    
    if (_projectToken.length == 0) {
        NSLog(@"[TJMixpanelLogger] Invalid project token %s", __PRETTY_FUNCTION__);
        return;
    }
    
    const NSTimeInterval timestamp = [[NSDate date] timeIntervalSince1970];
    
    static NSDictionary<NSString *, id> *staticProperties;
    static NSURLRequest *staticRequest;
    static NSURLSession *session;
    static NSJSONWritingOptions options;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSURLSessionConfiguration *sessionConfiguration = [NSURLSessionConfiguration backgroundSessionConfigurationWithIdentifier:[NSString stringWithFormat:@"com.tijo.logger.%@", [[NSUUID UUID] UUIDString]]];
        sessionConfiguration.sharedContainerIdentifier = _sharedContainerIdentifier;
        sessionConfiguration.sessionSendsLaunchEvents = NO;
        sessionConfiguration.networkServiceType = NSURLNetworkServiceTypeBackground;
        sessionConfiguration.timeoutIntervalForResource = 22776000; // 1 year
        sessionConfiguration.HTTPAdditionalHeaders = @{@"Content-Type": @"application/json"};
        sessionConfiguration.requestCachePolicy = NSURLRequestReloadIgnoringCacheData;
        session = [NSURLSession sessionWithConfiguration:sessionConfiguration];
        NSString *deviceModel = nil;
        BOOL isOnMac = NO;
#if TARGET_OS_SIMULATOR
        deviceModel = [[[NSProcessInfo processInfo] environment] objectForKey:@"SIMULATOR_MODEL_IDENTIFIER"];
#else
        if (@available(iOS 13.0, watchOS 6.0, *)) {
            if ([[NSProcessInfo processInfo] isMacCatalystApp]) {
                isOnMac = YES;
            } else if (@available(iOS 14.0, watchOS 7.0, *)) {
                if ([[NSProcessInfo processInfo] isiOSAppOnMac]) {
                    isOnMac = YES;
                }
            }
        }
        if (isOnMac) {
            // https://stackoverflow.com/a/13360637/3943258
            size_t len = 0;
            sysctlbyname("hw.model", NULL, &len, NULL, 0);
            if (len) {
                char *model = malloc(len * sizeof(char));
                sysctlbyname("hw.model", model, &len, NULL, 0);
                deviceModel = [[NSString alloc] initWithBytesNoCopy:model length:len encoding:NSUTF8StringEncoding freeWhenDone:YES];
            }
        }
        if (!deviceModel) {
            struct utsname systemInfo;
            uname(&systemInfo);
            deviceModel = [NSString stringWithCString:systemInfo.machine encoding:NSUTF8StringEncoding]; // https://stackoverflow.com/a/11197770/3943258
        }
        if (deviceModel) {
            if (isOnMac) {
                if (![deviceModel hasPrefix:@"Mac"]) {
                    deviceModel = [@"Mac-" stringByAppendingString:deviceModel];
                }
            } else if (NSClassFromString(@"UIWindowSceneGeometryPreferencesVision") != nil) { // https://tijo.link/RyvNUG
                deviceModel = [@"Vision-" stringByAppendingString:deviceModel];
            }
        }
#endif
        
        NSNumber *screenWidth;
        NSNumber *screenHeight;
#if TARGET_OS_WATCH
        WKInterfaceDevice *const device = [WKInterfaceDevice currentDevice];
        screenWidth = @(device.screenBounds.size.width);
        screenHeight = @(device.screenBounds.size.height);
#else
        UIDevice *const device = [UIDevice currentDevice];
        if (isOnMac) {
            screenWidth = nil;
            screenHeight = nil;
        } else {
            UIScreen *const screen = [UIScreen mainScreen];
            if (screen != nil) {
                const CGSize screenSize = screen.bounds.size;
                screenWidth = @(MIN(screenSize.width, screenSize.height));
                screenHeight = @(MAX(screenSize.width, screenSize.height));
            } else {
                screenWidth = nil;
                screenHeight = nil;
            }
        }
#endif
        
        id bundleIdentifierSuffix = nil;
        
        // Find "suffix" on top of main app bundle ID if this app has extensions and we're currently running in an extension.
        NSURL *bundleURL = [[NSBundle mainBundle] bundleURL];
        // https://stackoverflow.com/a/62619735/3943258
        for (; ![bundleURL.pathExtension isEqualToString:@"app"]; bundleURL = bundleURL.URLByDeletingLastPathComponent);
        NSString *const pluginsPath = [bundleURL.path stringByAppendingPathComponent:@"PlugIns"];
        const BOOL hasExtensions = [[NSFileManager defaultManager] fileExistsAtPath:pluginsPath];
        if (hasExtensions) {
            NSString *const mainAppBundleIdentifier = [[NSBundle bundleWithURL:bundleURL] bundleIdentifier];
            bundleIdentifierSuffix = [[NSBundle mainBundle] bundleIdentifier];
            if ([bundleIdentifierSuffix hasPrefix:mainAppBundleIdentifier]) {
                bundleIdentifierSuffix = [bundleIdentifierSuffix substringFromIndex:mainAppBundleIdentifier.length];
                if ([bundleIdentifierSuffix hasPrefix:@"."]) { // Strip off leading "." as well
                    bundleIdentifierSuffix = [bundleIdentifierSuffix substringFromIndex:1];
                }
            }
            if (![bundleIdentifierSuffix length]) {
                bundleIdentifierSuffix = [NSNull null];
            }
        }
        
        // https://help.mixpanel.com/hc/en-us/articles/115004613766-Default-Properties-Collected-by-Mixpanel#ios
        // https://github.com/mixpanel/mixpanel-iphone/blob/master/Sources/Mixpanel.m#L510
        staticProperties = ^NSDictionary *{
            NSMutableDictionary<NSString *, id> *const properties = [NSMutableDictionary dictionaryWithCapacity:9];
            properties[@"token"] = _projectToken;
            if (@available(watchOS 6.2, *)) {
                properties[@"distinct_id"] = [self distinctIdentifier];
            }
            properties[@"$app_version_string"] = [[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleShortVersionString"];
            properties[@"$os_version"] = [device systemVersion];
            properties[@"$model"] = deviceModel;
            if (screenWidth != nil && screenHeight != nil) {
                properties[@"$screen_height"] = screenHeight;
                properties[@"$screen_width"] = screenWidth;
            }
            // Custom
            properties[@"language"] = [[NSLocale preferredLanguages] firstObject];
            properties[@"bundle_id_suffix"] = bundleIdentifierSuffix;
            return [properties copy];
        }();
        
        NSURLComponents *const components = [NSURLComponents componentsWithString:@"https://api.mixpanel.com/track"];
        
        components.queryItems = @[
            [NSURLQueryItem queryItemWithName:@"ip" value:@"1"],
#if DEBUG
            [NSURLQueryItem queryItemWithName:@"verbose" value:@"1"],
#endif
        ];
        
        staticRequest = ^NSURLRequest *{
            NSMutableURLRequest *const request = [NSMutableURLRequest requestWithURL:components.URL];
            [request setHTTPMethod:@"POST"];
            return [request copy];
        }();
        
        if (@available(iOS 13.0, watchOS 6.0, *)) {
            options = NSJSONWritingWithoutEscapingSlashes;
        } else {
            options = 0;
        }
    });
    
    // -performExpiringActivityWithReason:... has two benefits
    // (1) It keeps the process alive long enough to finish the work within its block. This is especially useful for extension which might be shortlived.
    // (2) It runs the work in the block on another thread so we avoid blocking the calling thread.
    __block BOOL once = NO;
    NSString *const reason = [NSString stringWithFormat:@"%@-%f", name, timestamp];
    [[NSProcessInfo processInfo] performExpiringActivityWithReason:reason usingBlock:^(BOOL expired) {
        @synchronized (reason) {
            if (!once) {
                once = YES;
            } else {
                return;
            }
        }
        
        // https://developer.mixpanel.com/reference/track-event
        NSMutableDictionary *const properties = [staticProperties mutableCopy];
        NSDictionary *const customProperties = self.customProperties;
        if (customProperties) {
            [properties addEntriesFromDictionary:customProperties];
        }
        [properties addEntriesFromDictionary:@{
            @"time": @((unsigned long long)(timestamp * 1000)),
            @"$insert_id": _uuidToBase64([NSUUID UUID]),
        }];
        
        [properties addEntriesFromDictionary:eventProperties];
        
        NSMutableURLRequest *const request = [staticRequest mutableCopy];
        NSData *body = [NSJSONSerialization dataWithJSONObject:@[
            @{
                @"event": name,
                @"properties": properties,
            }
        ]
                                                       options:options
                                                         error:nil];
        NSError *error;
        // gzip compress https://developer.mixpanel.com/reference/import-events
        NSData *const compressedBody = _gzipCompressData(body, &error);
        if (error == nil && compressedBody.length > 0 && compressedBody.length < body.length) {
            [request setValue:@"gzip" forHTTPHeaderField:@"Content-Encoding"];
            [request setHTTPBody:compressedBody];
        } else {
            [request setHTTPBody:body];
        }
        NSURLSessionTask *task;
#if DEBUG
        task = [[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
            NSLog(@"%@ %@ %@", response, error, [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]);
        }];
#else
        task = [session downloadTaskWithRequest:request];
        task.countOfBytesClientExpectsToReceive = 0;
#endif
        if (@available(watchOS 4.0, *)) {
            task.countOfBytesClientExpectsToSend = request.HTTPBody.length;
        }
        [task resume];
    }];
}

+ (NSString *)distinctIdentifier
{
#if TARGET_OS_WATCH
    WKInterfaceDevice *const device = [WKInterfaceDevice currentDevice];
#else
    UIDevice *const device = [UIDevice currentDevice];
#endif
    return _uuidToBase64([device identifierForVendor]);
}

@end
