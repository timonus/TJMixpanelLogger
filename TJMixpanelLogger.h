//
//  TJMixpanelLogger.h
//
//  Created by Tim Johnsen on 11/21/22.
//  Copyright (c) 2022 Tim Johnsen. All rights reserved.
//

@import Foundation;

@interface TJMixpanelLogger : NSObject

@property (nonatomic, copy, class) NSString *projectToken;
@property (nonatomic, copy, class) NSString *sharedContainerIdentifier;

+ (void)logEventWithName:(NSString *)name properties:(NSDictionary *)customProperties;

@end
