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

__attribute__((objc_direct_members))
@implementation TJMixpanelLogger

static NSString *_projectToken;
static NSString *_sharedContainerIdentifier;
static NSDictionary *_customProperties;

static NSURLSessionConfiguration *_sessionConfiguration;

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
    if (![_sharedContainerIdentifier isEqual:sharedContainerIdentifier]) {
        _sharedContainerIdentifier = sharedContainerIdentifier;
        _sessionConfiguration.sharedContainerIdentifier = sharedContainerIdentifier;
    }
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

static const NSUInteger kUUIDByteLength = 16; // Per docs, NSUUIDs are 16 bytes in length

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

+ (void)logEventWithName:(NSString *const)name properties:(NSDictionary *const)customProperties
{
    if (name.length == 0 || _projectToken.length == 0) {
        NSLog(@"Invalid %s", __PRETTY_FUNCTION__);
        return;
    }
    
    const NSTimeInterval timestamp = [[NSDate date] timeIntervalSince1970];
    
    static NSDictionary<NSString *, id> *staticProperties;
    static NSURLRequest *staticRequest;
    static NSURLSession *session;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _sessionConfiguration = [NSURLSessionConfiguration backgroundSessionConfigurationWithIdentifier:[NSString stringWithFormat:@"com.tijo.logger.%@", [[NSUUID UUID] UUIDString]]];
        _sessionConfiguration.sharedContainerIdentifier = _sharedContainerIdentifier;
        _sessionConfiguration.sessionSendsLaunchEvents = NO;
        _sessionConfiguration.networkServiceType = NSURLNetworkServiceTypeBackground;
        _sessionConfiguration.timeoutIntervalForResource = 22776000; // 1 year
        session = [NSURLSession sessionWithConfiguration:_sessionConfiguration];
        
#if TARGET_OS_WATCH
        WKInterfaceDevice *const device = [WKInterfaceDevice currentDevice];
        const CGFloat width = device.screenBounds.size.width;
        const CGFloat height = device.screenBounds.size.height;
#else
        UIDevice *const device = [UIDevice currentDevice];
        const CGFloat width = [UIScreen mainScreen].bounds.size.width;
        const CGFloat height = [UIScreen mainScreen].bounds.size.height;
#endif
        
        NSString *deviceModel = nil;
#if TARGET_OS_SIMULATOR
        deviceModel = [[[NSProcessInfo processInfo] environment] objectForKey:@"SIMULATOR_MODEL_IDENTIFIER"];
#else
        BOOL isOnMac = NO;
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
                deviceModel = [@"Mac-" stringByAppendingString:deviceModel];
            } else if (NSClassFromString(@"UIWindowSceneGeometryPreferencesVision") != nil) { // https://tijo.link/RyvNUG
                deviceModel = [@"Vision-" stringByAppendingString:deviceModel];
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
                properties[@"distinct_id"] = _uuidToBase64([device identifierForVendor]);
            }
            properties[@"$app_version_string"] = [[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleShortVersionString"];
            properties[@"$os_version"] = [device systemVersion];
            properties[@"$model"] = deviceModel;
            properties[@"$screen_height"] = @((unsigned long)MAX(width, height));
            properties[@"$screen_width"] = @((unsigned long)MIN(width, height));
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
            [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
            request.cachePolicy = NSURLRequestReloadIgnoringCacheData;
            return [request copy];
        }();
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
        
        [properties addEntriesFromDictionary:customProperties];
        
        NSMutableURLRequest *const request = [staticRequest mutableCopy];
        NSJSONWritingOptions options = 0;
        if (@available(iOS 13.0, watchOS 6.0, *)) {
            options = NSJSONWritingWithoutEscapingSlashes;
        }
        [request setHTTPBody:[NSJSONSerialization dataWithJSONObject:@[
            @{
                @"event": name,
                @"properties": properties,
            }
        ]
                                                             options:options
                                                               error:nil]];
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

@end
