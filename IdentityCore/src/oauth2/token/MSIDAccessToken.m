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

#import "MSIDAccessToken.h"
#import "MSIDAADTokenResponse.h"
#import "NSOrderedSet+MSIDExtensions.h"
#import "MSIDAADV1RequestParameters.h"
#import "MSIDAADV1TokenResponse.h"
#import "MSIDUserInformation.h"
#import "NSDate+MSIDExtensions.h"

//in seconds, ensures catching of clock differences between the server and the device
static uint64_t s_expirationBuffer = 300;

@interface MSIDAccessToken()

@property (readwrite) NSString *target;

@end

@implementation MSIDAccessToken

#pragma mark - NSCopying

- (id)copyWithZone:(NSZone *)zone
{
    MSIDAccessToken *item = [super copyWithZone:zone];
    item->_expiresOn = [_expiresOn copyWithZone:zone];
    item->_cachedAt = [_cachedAt copyWithZone:zone];
    item->_accessToken = [_accessToken copyWithZone:zone];
    item->_target = [_target copyWithZone:zone];
    item->_idToken = [_idToken copyWithZone:zone];
    
    return item;
}

#pragma mark - NSObject

- (BOOL)isEqual:(id)object
{
    if (self == object)
    {
        return YES;
    }
    
    if (![object isKindOfClass:MSIDAccessToken.class])
    {
        return NO;
    }
    
    return [self isEqualToItem:(MSIDAccessToken *)object];
}

- (NSUInteger)hash
{
    NSUInteger hash = [super hash];
    hash = hash * 31 + self.expiresOn.hash;
    hash = hash * 31 + self.accessToken.hash;
    hash = hash * 31 + self.resource.hash;
    hash = hash * 31 + self.scopes.hash;
    hash = hash * 31 + self.cachedAt.hash;
    return hash;
}

- (BOOL)isEqualToItem:(MSIDAccessToken *)token
{
    if (!token)
    {
        return NO;
    }
    
    BOOL result = [super isEqualToItem:token];
    result &= (!self.expiresOn && !token.expiresOn) || [self.expiresOn isEqualToDate:token.expiresOn];
    result &= (!self.accessToken && !token.accessToken) || [self.accessToken isEqualToString:token.accessToken];
    result &= (!self.resource && !token.resource) || [self.resource isEqualToString:token.resource];
    result &= (!self.scopes && !token.scopes) || [self.scopes isEqualToOrderedSet:token.scopes];
    result &= (!self.cachedAt && !token.cachedAt) || [self.cachedAt isEqualToDate:token.cachedAt];
    result &= (!self.idToken && !token.idToken) || [self.idToken isEqualToString:token.idToken];
    
    return result;
}

#pragma mark - Cache

- (instancetype)initWithTokenCacheItem:(MSIDTokenCacheItem *)tokenCacheItem
{
    self = [super initWithTokenCacheItem:tokenCacheItem];
    
    if (self)
    {
        _expiresOn = tokenCacheItem.expiresOn;
        _cachedAt = tokenCacheItem.cachedAt;
        _accessToken = tokenCacheItem.accessToken;
        _idToken = tokenCacheItem.idToken;
        _target = tokenCacheItem.target;
    }
    
    return self;
}

- (MSIDTokenCacheItem *)tokenCacheItem
{
    MSIDTokenCacheItem *cacheItem = [super tokenCacheItem];
    cacheItem.expiresOn = self.expiresOn;
    cacheItem.cachedAt = self.cachedAt;
    cacheItem.accessToken = self.accessToken;
    cacheItem.idToken = self.idToken;
    cacheItem.target = self.target;
    return cacheItem;
}

#pragma mark - Response

- (instancetype)initWithTokenResponse:(MSIDTokenResponse *)response
                              request:(MSIDRequestParameters *)requestParams
{
    if (!(self = [super initWithTokenResponse:response request:requestParams]))
    {
        return nil;
    }
    
    [self fillToken:response
            request:requestParams];
    
    return self;
}

#pragma mark - Fill item

- (void)fillToken:(MSIDTokenResponse *)response
          request:(MSIDRequestParameters *)requestParams
{
    NSString *resource = nil;

    if ([response isKindOfClass:[MSIDAADV1TokenResponse class]])
    {
        NSString *fallbackResource = nil;
        
        if ([requestParams isKindOfClass:[MSIDAADV1RequestParameters class]])
        {
            MSIDAADV1RequestParameters *v1RequestParams = (MSIDAADV1RequestParameters *)requestParams;
            fallbackResource = v1RequestParams.resource;
        }
        
        MSIDAADV1TokenResponse *aadV1TokenResponse = (MSIDAADV1TokenResponse *)response;
        // Because resource is not always returned in the token response, we rely on the input resource as a fallback
        resource = aadV1TokenResponse.resource ? aadV1TokenResponse.resource : fallbackResource;
    }
    
    _target = resource ? resource : response.scope;
    
    _accessToken = response.accessToken;
    _idToken = response.idToken;
    
    [self fillExpiryFromResponse:response];
    [self fillExtendedExpiryFromResponse:response];
}

- (void)fillExpiryFromResponse:(MSIDTokenResponse *)response
{
    NSDate *expiresOn = response.expiryDate;
    
    if (!expiresOn)
    {
        MSID_LOG_WARN(nil, @"The server did not return the expiration time for the access token.");
        expiresOn = [NSDate dateWithTimeIntervalSinceNow:3600.0]; //Assume 1hr expiration
    }
    
    _expiresOn = [NSDate dateWithTimeIntervalSince1970:(uint64_t)[expiresOn timeIntervalSince1970]];
    
    _cachedAt = [NSDate dateWithTimeIntervalSince1970:(uint64_t)[[NSDate date] timeIntervalSince1970]];
}

- (void)fillExtendedExpiryFromResponse:(MSIDTokenResponse *)response
{
    if ([response isKindOfClass:[MSIDAADTokenResponse class]])
    {
        MSIDAADTokenResponse *aadTokenResponse = (MSIDAADTokenResponse *)response;
        NSMutableDictionary *serverInfo = [_additionalInfo mutableCopy];
        [serverInfo setValue:aadTokenResponse.extendedExpiresOnDate
                      forKey:MSID_EXTENDED_EXPIRES_ON_LEGACY_CACHE_KEY];
        _additionalInfo = serverInfo;
    }
}

#pragma mark - Token type

- (MSIDTokenType)tokenType
{
    return MSIDTokenTypeAccessToken;
}

#pragma mark - Expiry

- (BOOL)isExpired;
{
    NSDate *nowPlusBuffer = [NSDate dateWithTimeIntervalSinceNow:s_expirationBuffer];
    return [self.expiresOn compare:nowPlusBuffer] == NSOrderedAscending;
}

- (NSDate *)extendedExpireTime
{
    return _additionalInfo[MSID_EXTENDED_EXPIRES_ON_LEGACY_CACHE_KEY];
}

#pragma mark - Resource/scopes

- (NSString *)resource
{
    return _target;
}

- (NSOrderedSet<NSString *> *)scopes
{
    return [_target scopeSet];
}

@end