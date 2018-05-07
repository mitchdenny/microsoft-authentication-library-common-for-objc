// Copyright (c) Microsoft Corporation.
// All rights reserved.
//
// This code is licensed under the MIT License.
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files(the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and / or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions :
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

#import "MSIDCacheItem.h"
#import "MSIDTokenType.h"

typedef NS_ENUM(NSUInteger, MSIDComparisonOptions) {
    Any,
    ExactStringMatch,
    SubSet,
    Intersect,
};

@class MSIDBaseToken;

@interface MSIDTokenCacheItem : MSIDCacheItem

// Client id
@property (readwrite, nonnull) NSString *clientId;

// Token type
@property (readwrite) MSIDTokenType tokenType;
@property (readwrite, nullable) NSString *oauthTokenType;

// Tokens
@property (readwrite, nullable) NSString *accessToken;
@property (readwrite, nullable) NSString *refreshToken;
@property (readwrite, nullable) NSString *idToken;

// Targets
@property (readwrite, nullable) NSString *target;

// Dates
@property (readwrite, nullable) NSDate *expiresOn;
@property (readwrite, nullable) NSDate *cachedAt;

// Family ID
@property (readwrite, nullable) NSString *familyId;

// Additional info
@property (readwrite, nullable) NSDictionary *additionalInfo;

- (nullable MSIDBaseToken *)tokenWithType:(MSIDTokenType)tokenType;

- (BOOL)matchesTarget:(nullable NSString *)target comparisonOptions:(MSIDComparisonOptions)comparisonOptions;

- (BOOL)matchesWithUniqueUserId:(nullable NSString *)uniqueUserId
                    environment:(nullable NSString *)environment;

- (BOOL)matchesWithLegacyUserId:(nullable NSString *)legacyUserId
                    environment:(nullable NSString *)environment;

- (BOOL)matchesWithRealm:(nullable NSString *)realm
                clientId:(nullable NSString *)clientId
                  target:(nullable NSString *)target
          targetMatching:(MSIDComparisonOptions)matchingOptions;

@end
