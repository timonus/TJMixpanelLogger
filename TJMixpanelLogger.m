//
//  TJMixpanelLogger.m
//
//  Created by Tim Johnsen on 11/21/22.
//  Copyright (c) 2022 Tim Johnsen. All rights reserved.
//

@import UIKit;
@import CoreFoundation;

#import "TJMixpanelLogger.h"
@import Darwin.POSIX.sys.utsname;

__attribute__((objc_direct_members))
@implementation TJMixpanelLogger

static NSString *_projectToken;
static NSString *_sharedContainerIdentifier;

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

static const NSUInteger kUUIDByteLength = 16; // Per docs, NSUUIDs are 16 bytes in length

static NSString *_uuidToBase64(NSUUID *const uuid)
{
    unsigned char bytes[kUUIDByteLength];
    [uuid getUUIDBytes:bytes];
    NSData *const data = [NSData dataWithBytesNoCopy:bytes length:kUUIDByteLength freeWhenDone:NO];
    // distinct_id cannot contain slashes per https://help.mixpanel.com/hc/en-us/articles/115004509406-Distinct-IDs-
    NSString *const string = [[[[data base64EncodedStringWithOptions:0]
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

    static NSDictionary *staticProperties;
    static NSMutableURLRequest *staticRequest;
    static NSURLSession *session;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _sessionConfiguration = [NSURLSessionConfiguration backgroundSessionConfigurationWithIdentifier:[NSString stringWithFormat:@"com.tijo.logger.%@", [[NSUUID UUID] UUIDString]]];
        _sessionConfiguration.sharedContainerIdentifier = _sharedContainerIdentifier;
        _sessionConfiguration.sessionSendsLaunchEvents = NO;
        _sessionConfiguration.networkServiceType = NSURLNetworkServiceTypeBackground;
        _sessionConfiguration.discretionary = YES;
        session = [NSURLSession sessionWithConfiguration:_sessionConfiguration];

        const CGFloat width = [UIScreen mainScreen].bounds.size.width;
        const CGFloat height = [UIScreen mainScreen].bounds.size.height;
        
        NSString *deviceModel = nil;
#if TARGET_IPHONE_SIMULATOR
        deviceModel = [[[NSProcessInfo processInfo] environment] objectForKey:@"SIMULATOR_MODEL_IDENTIFIER"];
#else
        struct utsname systemInfo;
        uname(&systemInfo);
        deviceModel = [NSString stringWithCString:systemInfo.machine encoding:NSUTF8StringEncoding]; // https://stackoverflow.com/a/11197770/3943258
#endif
        BOOL isOnMac = NO;
        if (@available(iOS 13.0, *)) {
            if ([[NSProcessInfo processInfo] isMacCatalystApp]) {
                isOnMac = YES;
            } else if (@available(iOS 14.0, *)) {
                if ([[NSProcessInfo processInfo] isiOSAppOnMac]) {
                    isOnMac = YES;
                }
            }
        }
        if (isOnMac && deviceModel) {
            deviceModel = [@"Mac-" stringByAppendingString:deviceModel];
        }
        
        // https://help.mixpanel.com/hc/en-us/articles/115004613766-Default-Properties-Collected-by-Mixpanel#ios
        // https://github.com/mixpanel/mixpanel-iphone/blob/master/Sources/Mixpanel.m#L510
        staticProperties = @{
            @"token": _projectToken,
            @"distinct_id": _uuidToBase64([[UIDevice currentDevice] identifierForVendor]),
            @"$app_version_string": [[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleShortVersionString"],
            @"$os_version": [[UIDevice currentDevice] systemVersion],
            @"$model": deviceModel,
            @"$screen_height": @((unsigned long)MAX(width, height)),
            @"$screen_width": @((unsigned long)MIN(width, height)),
            // Custom
            @"language": [[NSLocale preferredLanguages] firstObject]
        };
        
        // Find "suffix" on top of main app bundle ID if this is an extension.
        NSURL *bundleURL = [[NSBundle mainBundle] bundleURL];
        // https://stackoverflow.com/a/62619735/3943258
        for (; ![bundleURL.pathExtension isEqualToString:@"app"]; bundleURL = bundleURL.URLByDeletingLastPathComponent);
        NSString *mainAppBundleIdentifier;
        if (bundleURL) {
             mainAppBundleIdentifier = [[NSBundle bundleWithURL:bundleURL] bundleIdentifier];
        }
        NSString *bundleIdentifierSuffix = [[NSBundle mainBundle] bundleIdentifier];
        if ([bundleIdentifierSuffix hasPrefix:mainAppBundleIdentifier]) {
            bundleIdentifierSuffix = [bundleIdentifierSuffix substringFromIndex:mainAppBundleIdentifier.length];
            if ([bundleIdentifierSuffix hasPrefix:@"."]) { // Strip off leading "." as well
                [bundleIdentifierSuffix substringFromIndex:1];
            }
        }
        
        if (bundleIdentifierSuffix.length) {
            NSMutableDictionary *mutableStaticProperties = [staticProperties mutableCopy];
            mutableStaticProperties[@"bundle_id_suffix"] = bundleIdentifierSuffix;
            staticProperties = [mutableStaticProperties copy];
        }
        
        NSURLComponents *const components = [NSURLComponents componentsWithString:@"https://api.mixpanel.com/track"];
        
        components.queryItems = @[
            [NSURLQueryItem queryItemWithName:@"ip" value:@"1"],
#if DEBUG
            [NSURLQueryItem queryItemWithName:@"verbose" value:@"1"],
#endif
        ];
        
        staticRequest = [NSMutableURLRequest requestWithURL:components.URL];
        [staticRequest setHTTPMethod:@"POST"];
        [staticRequest setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        staticRequest.cachePolicy = NSURLRequestReloadIgnoringCacheData;
    });
    
    // https://developer.mixpanel.com/reference/track-event
    NSMutableDictionary *const properties = [staticProperties mutableCopy];
    [properties addEntriesFromDictionary:@{
        @"time": @((unsigned long)([[NSDate date] timeIntervalSince1970] * 1000)),
        @"$insert_id": _uuidToBase64([NSUUID UUID]),
    }];
    
    [properties addEntriesFromDictionary:customProperties];
    
    NSMutableURLRequest *const request = [staticRequest mutableCopy];
    NSJSONWritingOptions options = 0;
    if (@available(iOS 13.0, *)) {
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
    task.countOfBytesClientExpectsToSend = request.HTTPBody.length;
    [task resume];
}

@end
