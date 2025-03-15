//
//  TJMixpanelLogger.h
//
//  Created by Tim Johnsen on 11/21/22.
//  Copyright (c) 2022 Tim Johnsen. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface TJMixpanelLogger : NSObject

@property (nonatomic, copy, class) NSString *projectToken;
@property (nonatomic, copy, class) NSString *sharedContainerIdentifier;

@property (nonatomic, copy, class) NSDictionary *customProperties; // Sent in every event

+ (void)logEventWithName:(NSString *)name properties:(NSDictionary *)customProperties;

+ (NSString *)distinctIdentifier;

@end
