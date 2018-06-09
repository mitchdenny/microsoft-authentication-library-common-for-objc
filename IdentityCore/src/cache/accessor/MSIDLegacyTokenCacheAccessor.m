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

#import "MSIDLegacyTokenCacheAccessor.h"
#import "MSIDKeyedArchiverSerializer.h"
#import "MSIDLegacySingleResourceToken.h"
#import "MSIDTelemetry+Internal.h"
#import "MSIDTelemetryEventStrings.h"
#import "MSIDTelemetryCacheEvent.h"
#import "MSIDAadAuthorityCache.h"
#import "MSIDLegacyTokenCacheKey.h"
#import "MSIDConfiguration.h"
#import "MSIDTokenResponse.h"
#import "NSDate+MSIDExtensions.h"
#import "MSIDAuthority.h"
#import "MSIDOauth2Factory.h"
#import "MSIDLegacyTokenCacheQuery.h"
#import "MSIDLegacyAccessToken.h"
#import "MSIDLegacyRefreshToken.h"
#import "MSIDLegacyTokenCacheItem.h"
#import "MSIDBrokerResponse.h"
#import "MSIDTokenFilteringHelper.h"
#import "NSString+MSIDExtensions.h"
#import "MSIDIdTokenClaims.h"
#import "MSIDAccountIdentifier.h"

@interface MSIDLegacyTokenCacheAccessor()
{
    id<MSIDTokenCacheDataSource> _dataSource;
    MSIDKeyedArchiverSerializer *_serializer;
    NSArray *_otherAccessors;
}

@end

@implementation MSIDLegacyTokenCacheAccessor

#pragma mark - Init

- (instancetype)initWithDataSource:(id<MSIDTokenCacheDataSource>)dataSource
               otherCacheAccessors:(NSArray<id<MSIDCacheAccessor>> *)otherAccessors
{
    self = [super init];

    if (self)
    {
        _dataSource = dataSource;
        _serializer = [[MSIDKeyedArchiverSerializer alloc] init];
        _otherAccessors = otherAccessors;
    }

    return self;
}

#pragma mark - Persistence

- (BOOL)saveTokensWithFactory:(MSIDOauth2Factory *)factory
                configuration:(MSIDConfiguration *)configuration
                     response:(MSIDTokenResponse *)response
                      context:(id<MSIDRequestContext>)context
                        error:(NSError **)error
{
    if (response.isMultiResource)
    {
        BOOL result = [self saveAccessTokenWithFactory:factory configuration:configuration response:response context:context error:error];

        if (!result) return NO;

        return [self saveSSOStateWithFactory:factory configuration:configuration response:response context:context error:error];
    }
    else
    {
        return [self saveLegacySingleResourceTokenWithFactory:factory configuration:configuration response:response context:context error:error];
    }
}

- (BOOL)saveTokensWithFactory:(MSIDOauth2Factory *)factory
               brokerResponse:(MSIDBrokerResponse *)response
             saveSSOStateOnly:(BOOL)saveSSOStateOnly
                      context:(id<MSIDRequestContext>)context
                        error:(NSError **)error
{
    MSIDConfiguration *configuration = [[MSIDConfiguration alloc] initWithAuthority:[NSURL URLWithString:response.authority]
                                                                        redirectUri:nil
                                                                           clientId:response.clientId
                                                                             target:response.resource];

    if (saveSSOStateOnly)
    {
        return [self saveSSOStateWithFactory:factory
                               configuration:configuration
                                    response:response.tokenResponse
                                     context:context
                                       error:error];
    }

    return [self saveTokensWithFactory:factory
                         configuration:configuration
                              response:response.tokenResponse
                               context:context
                                 error:error];
}

- (BOOL)saveSSOStateWithFactory:(MSIDOauth2Factory *)factory
                  configuration:(MSIDConfiguration *)configuration
                       response:(MSIDTokenResponse *)response
                        context:(id<MSIDRequestContext>)context
                          error:(NSError **)error
{
    if (!response)
    {
        [self fillInternalErrorWithMessage:@"No response provided" context:context error:error];
        return NO;
    }

    BOOL result = [self saveRefreshTokenWithFactory:factory
                                      configuration:configuration
                                           response:response
                                            context:context
                                              error:error];

    if (!result)
    {
        return NO;
    }

    for (id<MSIDCacheAccessor> accessor in _otherAccessors)
    {
        if (![accessor saveSSOStateWithFactory:factory
                                 configuration:configuration
                                      response:response
                                       context:context
                                         error:error])
        {
            MSID_LOG_WARN(context, @"Failed to save SSO state in other accessor: %@", accessor.class);
            MSID_LOG_WARN(context, @"Failed to save SSO state in other accessor: %@, error %@", accessor.class, *error);
        }
    }

    return YES;
}

- (MSIDRefreshToken *)getRefreshTokenWithAccount:(MSIDAccountIdentifier *)account
                                        familyId:(NSString *)familyId
                                         factory:(MSIDOauth2Factory *)factory
                                   configuration:(MSIDConfiguration *)configuration
                                         context:(id<MSIDRequestContext>)context
                                           error:(NSError **)error
{
    MSIDRefreshToken *refreshToken = [self getRefreshTokenForAccountImpl:account
                                                                familyId:familyId
                                                                 factory:factory
                                                           configuration:configuration
                                                                 context:context
                                                                   error:error];

    if (!refreshToken)
    {
        for (id<MSIDCacheAccessor> accessor in _otherAccessors)
        {
            MSIDRefreshToken *refreshToken = [accessor getRefreshTokenWithAccount:account
                                                                         familyId:familyId
                                                                          factory:factory
                                                                    configuration:configuration
                                                                          context:context
                                                                            error:error];

            if (refreshToken)
            {
                return refreshToken;
            }
        }
    }

    return refreshToken;

}

- (BOOL)clearWithContext:(id<MSIDRequestContext>)context
                   error:(NSError **)error
{
    return [_dataSource clearWithContext:context error:error];
}

- (NSArray<MSIDAccount *> *)allAccountsForEnvironment:(NSString *)environment
                                             clientId:(NSString *)clientId
                                             familyId:(NSString *)familyId
                                              factory:(MSIDOauth2Factory *)factory
                                              context:(id<MSIDRequestContext>)context
                                                error:(NSError **)error
{
    MSIDTelemetryCacheEvent *event = [self startCacheEventWithName:MSID_TELEMETRY_EVENT_TOKEN_CACHE_LOOKUP context:context];

    MSIDLegacyTokenCacheQuery *query = [MSIDLegacyTokenCacheQuery new];
    __auto_type items = [_dataSource tokensWithKey:query serializer:_serializer context:context error:error];

    NSArray<NSString *> *environmentAliases = [factory cacheAliasesForEnvironment:environment context:context];

    BOOL (^filterBlock)(MSIDCredentialCacheItem *tokenCacheItem) = ^BOOL(MSIDCredentialCacheItem *tokenCacheItem) {
        if ([environmentAliases count] && ![tokenCacheItem.environment msidIsEquivalentWithAnyAlias:environmentAliases])
        {
            return NO;
        }

        if (clientId && ![tokenCacheItem.clientId isEqualToString:clientId])
        {
            return NO;
        }

        if (familyId && ![tokenCacheItem.familyId isEqualToString:familyId])
        {
            return NO;
        }

        return YES;
    };

    NSArray *refreshTokens = [MSIDTokenFilteringHelper filterTokenCacheItems:items
                                                                   tokenType:MSIDRefreshTokenType
                                                                 returnFirst:NO
                                                                    filterBy:filterBlock];

    [self stopTelemetryLookupEvent:event
                         tokenType:MSIDRefreshTokenType
                         withToken:nil
                           success:[refreshTokens count] > 0
                           context:context];

    NSMutableSet *resultAccounts = [NSMutableSet set];

    for (MSIDLegacyRefreshToken *refreshToken in refreshTokens)
    {
        MSIDAccount *account = [MSIDAccount new];
        account.homeAccountId = refreshToken.homeAccountId;
        account.authority = [MSIDAuthority cacheUrlForAuthority:refreshToken.authority tenantId:refreshToken.realm];
        account.accountType = MSIDAccountTypeMSSTS;
        account.username = refreshToken.legacyUserId;
        [resultAccounts addObject:account];
    }

    return [resultAccounts allObjects];
}

#pragma mark - Public

- (MSIDLegacyAccessToken *)getAccessTokenForAccount:(MSIDAccountIdentifier *)account
                                            factory:(MSIDOauth2Factory *)factory
                                      configuration:(MSIDConfiguration *)configuration
                                            context:(id<MSIDRequestContext>)context
                                              error:(NSError **)error
{
    NSArray *aliases = [factory cacheAliasesForAuthority:configuration.authority context:context];

    return (MSIDLegacyAccessToken *)[self getTokenByLegacyUserId:account.legacyAccountId
                                                            type:MSIDAccessTokenType
                                                       authority:configuration.authority
                                                   lookupAliases:aliases
                                                        clientId:configuration.clientId
                                                        resource:configuration.target
                                                         context:context
                                                           error:error];
}

- (MSIDLegacySingleResourceToken *)getSingleResourceTokenForAccount:(MSIDAccountIdentifier *)account
                                                            factory:(MSIDOauth2Factory *)factory
                                                      configuration:(MSIDConfiguration *)configuration
                                                            context:(id<MSIDRequestContext>)context
                                                              error:(NSError **)error
{
    NSArray *aliases = [factory cacheAliasesForAuthority:configuration.authority context:context];

    return (MSIDLegacySingleResourceToken *)[self getTokenByLegacyUserId:account.legacyAccountId
                                                                    type:MSIDLegacySingleResourceTokenType
                                                               authority:configuration.authority
                                                           lookupAliases:aliases
                                                                clientId:configuration.clientId
                                                                resource:configuration.target
                                                                 context:context
                                                                   error:error];
}

- (BOOL)validateAndRemoveRefreshToken:(MSIDBaseToken<MSIDRefreshableToken> *)token
                              context:(id<MSIDRequestContext>)context
                                error:(NSError **)error
{
    if (!token || [NSString msidIsStringNilOrBlank:token.refreshToken])
    {
        [self fillInternalErrorWithMessage:@"Removing tokens can be done only as a result of a token request. Valid refresh token should be provided." context:context error:error];
        return NO;
    }

    MSID_LOG_VERBOSE(context, @"Removing refresh token with clientID %@, authority %@", token.clientId, token.authority);
    MSID_LOG_VERBOSE_PII(context, @"Removing refresh token with clientID %@, authority %@, userId %@, token %@", token.clientId, token.authority, token.homeAccountId, _PII_NULLIFY(token.refreshToken));

    MSIDCredentialCacheItem *cacheItem = [token tokenCacheItem];

    NSURL *storageAuthority = token.storageAuthority ? token.storageAuthority : token.authority;

    MSIDLegacyRefreshToken *tokenInCache = (MSIDLegacyRefreshToken *)[self getTokenByLegacyUserId:token.primaryUserId
                                                                                             type:cacheItem.credentialType
                                                                                        authority:token.authority
                                                                                    lookupAliases:@[storageAuthority]
                                                                                         clientId:cacheItem.clientId
                                                                                         resource:cacheItem.target
                                                                                          context:context
                                                                                            error:error];

    if (tokenInCache && [tokenInCache.refreshToken isEqualToString:token.refreshToken])
    {
        MSID_LOG_VERBOSE(context, @"Found refresh token in cache and it's the latest version, removing token");
        MSID_LOG_VERBOSE_PII(context, @"Found refresh token in cache and it's the latest version, removing token %@", token);

        return [self removeToken:token userId:token.primaryUserId context:context error:error];
    }

    return YES;
}

- (BOOL)removeAccessToken:(MSIDLegacyAccessToken *)token
                  context:(id<MSIDRequestContext>)context
                    error:(NSError **)error
{
    return [self removeToken:token userId:token.legacyUserId context:context error:error];
}

- (BOOL)clearCacheForAccount:(MSIDAccountIdentifier *)account
                     context:(id<MSIDRequestContext>)context
                       error:(NSError **)error
{
    if (!account.legacyAccountId)
    {
        [self fillInternalErrorWithMessage:@"Can't clear cache without user id" context:context error:error];
        return NO;
    }

    MSID_LOG_VERBOSE(context, @"(Legacy accessor) Clearing cache with account");
    MSID_LOG_VERBOSE_PII(context, @"(Legacy accessor) Clearing cache with account %@", account.legacyAccountId);

    MSIDTelemetryCacheEvent *event = [self startCacheEventWithName:MSID_TELEMETRY_EVENT_TOKEN_CACHE_DELETE context:context];

    MSIDLegacyTokenCacheQuery *query = [MSIDLegacyTokenCacheQuery new];
    query.legacyUserId = account.legacyAccountId;

    BOOL result = [_dataSource removeItemsWithKey:query context:context error:error];

    [_dataSource saveWipeInfoWithContext:context error:nil];

    [self stopTelemetryEvent:event withItem:nil success:result context:context];
    return result;
}

#pragma mark - Input validation

- (void)fillInternalErrorWithMessage:(NSString *)message
                             context:(id<MSIDRequestContext>)context
                               error:(NSError **)error
{
    MSID_LOG_ERROR(context, @"%@", message);

    if (error) *error = MSIDCreateError(MSIDErrorDomain, MSIDErrorInternal, message, nil, nil, nil, context.correlationId, nil);
}

#pragma mark - Internal

- (MSIDLegacyRefreshToken *)getRefreshTokenForAccountImpl:(MSIDAccountIdentifier *)account
                                                 familyId:(NSString *)familyId
                                                  factory:(MSIDOauth2Factory *)factory
                                            configuration:(MSIDConfiguration *)configuration
                                                  context:(id<MSIDRequestContext>)context
                                                    error:(NSError **)error
{
    NSString *clientId = familyId ? [MSIDCacheKey familyClientId:familyId] : configuration.clientId;
    NSArray<NSURL *> *aliases = [factory refreshTokenLookupAuthorities:configuration.authority context:context];

    MSID_LOG_VERBOSE(context, @"(Legacy accessor) Finding refresh token with legacy user ID, clientId %@, authority %@", clientId, aliases);
    MSID_LOG_VERBOSE_PII(context, @"(Legacy accessor) Finding refresh token with legacy user ID %@, clientId %@, authority %@", account.legacyAccountId, clientId, aliases);

    MSIDLegacyRefreshToken *resultToken = (MSIDLegacyRefreshToken *)[self getTokenByLegacyUserId:account.legacyAccountId
                                                                                            type:MSIDRefreshTokenType
                                                                                       authority:configuration.authority
                                                                                   lookupAliases:aliases
                                                                                        clientId:clientId
                                                                                        resource:nil
                                                                                         context:context
                                                                                           error:error];

    // If no legacy user ID available, or no token found by legacy user ID, try to look by unique user ID
    if (!resultToken
        && ![NSString msidIsStringNilOrBlank:account.homeAccountId])
    {
        MSID_LOG_VERBOSE(context, @"(Legacy accessor) Finding refresh token with new user ID, clientId %@, authority %@", clientId, aliases);
        MSID_LOG_VERBOSE_PII(context, @"(Legacy accessor) Finding refresh token with new user ID %@, clientId %@, authority %@", account.homeAccountId, clientId, aliases);

        *error = nil;

        resultToken = (MSIDLegacyRefreshToken *) [self getTokenByHomeAccountId:account.homeAccountId
                                                                     tokenType:MSIDRefreshTokenType
                                                                     authority:configuration.authority
                                                                 lookupAliases:aliases
                                                                      clientId:clientId
                                                                      resource:nil
                                                                       context:context
                                                                         error:error];
    }

    return resultToken;
}

- (BOOL)saveAccessTokenWithFactory:(MSIDOauth2Factory *)factory
                     configuration:(MSIDConfiguration *)configuration
                          response:(MSIDTokenResponse *)response
                           context:(id<MSIDRequestContext>)context
                             error:(NSError **)error
{
    MSIDLegacyAccessToken *accessToken = [factory legacyAccessTokenFromResponse:response configuration:configuration];

    if (!accessToken)
    {
        [self fillInternalErrorWithMessage:@"Tried to save access token, but no access token returned" context:context error:error];
        return NO;
    }

    MSID_LOG_INFO(context, @"(Legacy accessor) Saving access token in legacy accessor");
    MSID_LOG_INFO_PII(context, @"(Legacy accessor) Saving access token in legacy accessor %@", accessToken);

    return [self saveToken:accessToken
                   factory:factory
                 cacheItem:accessToken.legacyTokenCacheItem
                    userId:accessToken.legacyUserId
                   context:context
                     error:error];
}

- (BOOL)saveRefreshTokenWithFactory:(MSIDOauth2Factory *)factory
                      configuration:(MSIDConfiguration *)configuration
                           response:(MSIDTokenResponse *)response
                            context:(id<MSIDRequestContext>)context
                              error:(NSError **)error
{
    MSIDLegacyRefreshToken *refreshToken = [factory legacyRefreshTokenFromResponse:response configuration:configuration];

    if (!refreshToken)
    {
        MSID_LOG_INFO(context, @"No refresh token returned in the token response, not updating cache");
        return YES;
    }

    MSID_LOG_INFO(context, @"(Legacy accessor) Saving multi resource refresh token in legacy accessor");
    MSID_LOG_INFO_PII(context, @"(Legacy accessor) Saving multi resource refresh token in legacy accessor %@", refreshToken);

    BOOL result = [self saveToken:refreshToken
                          factory:factory
                        cacheItem:refreshToken.legacyTokenCacheItem
                           userId:refreshToken.legacyUserId
                          context:context
                            error:error];

    if (!result || [NSString msidIsStringNilOrBlank:refreshToken.familyId])
    {
        // If saving failed or it's not an FRT, we're done
        return result;
    }

    MSID_LOG_VERBOSE(context, @"Saving family refresh token in all caches");
    MSID_LOG_VERBOSE_PII(context, @"Saving family refresh token in all caches %@", _PII_NULLIFY(refreshToken.refreshToken));

    // If it's an FRT, save it separately and update the clientId of the token item
    MSIDLegacyRefreshToken *familyRefreshToken = [refreshToken copy];
    familyRefreshToken.clientId = [MSIDCacheKey familyClientId:refreshToken.familyId];

    return [self saveToken:familyRefreshToken
                   factory:factory
                 cacheItem:familyRefreshToken.legacyTokenCacheItem
                    userId:familyRefreshToken.legacyUserId
                   context:context
                     error:error];
}

- (BOOL)saveLegacySingleResourceTokenWithFactory:(MSIDOauth2Factory *)factory
                                   configuration:(MSIDConfiguration *)configuration
                                        response:(MSIDTokenResponse *)response
                                         context:(id<MSIDRequestContext>)context
                                           error:(NSError **)error
{
    MSIDLegacySingleResourceToken *legacyToken = [factory legacyTokenFromResponse:response configuration:configuration];

    if (!legacyToken)
    {
        [self fillInternalErrorWithMessage:@"Tried to save single resource token, but no access token returned" context:context error:error];
        return NO;
    }

    MSID_LOG_INFO(context, @"(Legacy accessor) Saving single resource tokens in legacy accessor");
    MSID_LOG_INFO_PII(context, @"(Legacy accessor) Saving single resource tokens in legacy accessor %@", legacyToken);

    // Save token for legacy single resource token
    return [self saveToken:legacyToken
                   factory:factory
                 cacheItem:legacyToken.legacyTokenCacheItem
                    userId:legacyToken.legacyUserId
                   context:context
                     error:error];
}

- (BOOL)saveToken:(MSIDBaseToken *)token
          factory:(MSIDOauth2Factory *)factory
        cacheItem:(MSIDLegacyTokenCacheItem *)tokenCacheItem
           userId:(NSString *)userId
          context:(id<MSIDRequestContext>)context
            error:(NSError **)error
{
    MSIDTelemetryCacheEvent *event = [self startCacheEventWithName:MSID_TELEMETRY_EVENT_TOKEN_CACHE_WRITE context:context];
    
    NSURL *newAuthority = [factory cacheURLFromAuthority:token.authority context:context];
    
    MSID_LOG_VERBOSE(context, @"(Legacy accessor) Saving token %@ with authority %@, clientID %@", [MSIDCredentialTypeHelpers credentialTypeAsString:tokenCacheItem.credentialType], newAuthority, tokenCacheItem.clientId);
    MSID_LOG_VERBOSE_PII(context, @"(Legacy accessor) Saving token %@ for account %@ with authority %@, clientID %@", tokenCacheItem, userId, newAuthority, tokenCacheItem.clientId);
    
    // The authority used to retrieve the item over the network can differ from the preferred authority used to
    // cache the item. As it would be awkward to cache an item using an authority other then the one we store
    // it with we switch it out before saving it to cache.
    tokenCacheItem.authority = newAuthority;

    MSIDLegacyTokenCacheKey *key = [[MSIDLegacyTokenCacheKey alloc] initWithAuthority:newAuthority
                                                                             clientId:tokenCacheItem.clientId
                                                                             resource:tokenCacheItem.target
                                                                         legacyUserId:userId];
    
    BOOL result = [_dataSource saveToken:tokenCacheItem
                                     key:key
                              serializer:_serializer
                                 context:context
                                   error:error];

    [self stopTelemetryEvent:event withItem:token success:result context:context];
    
    return result;
}

- (NSArray<MSIDBaseToken *> *)allTokensWithContext:(id<MSIDRequestContext>)context
                                             error:(NSError **)error
{
    MSIDLegacyTokenCacheQuery *query = [MSIDLegacyTokenCacheQuery new];
    __auto_type items = [_dataSource tokensWithKey:query serializer:_serializer context:context error:error];
    
    NSMutableArray<MSIDBaseToken *> *tokens = [NSMutableArray new];
    
    for (MSIDLegacyTokenCacheItem *item in items)
    {
        MSIDBaseToken *token = [item tokenWithType:item.credentialType];
        if (token)
        {
            [tokens addObject:token];
        }
    }
    
    return tokens;
}

- (BOOL)removeToken:(MSIDBaseToken *)token
             userId:(NSString *)userId
            context:(id<MSIDRequestContext>)context
              error:(NSError **)error
{
    if (!token)
    {
        if (error)
        {
            *error = MSIDCreateError(MSIDErrorDomain, MSIDErrorInternal, @"Token not provided", nil, nil, nil, context.correlationId, nil);
        }
        
        return NO;
    }
    
    MSID_LOG_VERBOSE(context, @"(Legacy accessor) Removing token with clientId %@, authority %@", token.clientId, token.authority);
    MSID_LOG_VERBOSE_PII(context, @"(Legacy accessor) Removing token %@ with account %@", token, userId);

    MSIDTelemetryCacheEvent *event = [self startCacheEventWithName:MSID_TELEMETRY_EVENT_TOKEN_CACHE_DELETE context:context];
    
    MSIDCredentialCacheItem *cacheItem = token.tokenCacheItem;
 
    NSURL *authority = token.storageAuthority ? token.storageAuthority : token.authority;

    MSIDLegacyTokenCacheKey *key = [[MSIDLegacyTokenCacheKey alloc] initWithAuthority:authority
                                                                             clientId:cacheItem.clientId
                                                                             resource:cacheItem.target
                                                                         legacyUserId:userId];
    
    BOOL result = [_dataSource removeItemsWithKey:key context:context error:error];

    if (result && token.credentialType == MSIDRefreshTokenType)
    {
        [_dataSource saveWipeInfoWithContext:context error:nil];
    }
    
    [self stopTelemetryEvent:event withItem:nil success:result context:context];
    return result;
}

#pragma mark - Private

- (MSIDBaseToken *)getTokenByLegacyUserId:(NSString *)legacyUserId
                                     type:(MSIDCredentialType)type
                                authority:(NSURL *)authority
                            lookupAliases:(NSArray<NSURL *> *)aliases
                                 clientId:(NSString *)clientId
                                 resource:(NSString *)resource
                                  context:(id<MSIDRequestContext>)context
                                    error:(NSError **)error
{
    MSIDTelemetryCacheEvent *event = [self startCacheEventWithName:MSID_TELEMETRY_EVENT_TOKEN_CACHE_LOOKUP context:context];

    for (NSURL *alias in aliases)
    {
        MSID_LOG_VERBOSE(context, @"(Legacy accessor) Looking for token with alias %@, clientId %@, resource %@", alias, clientId, resource);
        MSID_LOG_VERBOSE_PII(context, @"(Legacy accessor) Looking for token with alias %@, clientId %@, resource %@, legacy userId %@", alias, clientId, resource, legacyUserId);

        MSIDLegacyTokenCacheKey *key = [[MSIDLegacyTokenCacheKey alloc] initWithAuthority:alias
                                                                                 clientId:clientId
                                                                                 resource:resource
                                                                             legacyUserId:legacyUserId];
        
        if (!key)
        {
            return nil;
        }
        
        NSError *cacheError = nil;
        MSIDLegacyTokenCacheItem *cacheItem = (MSIDLegacyTokenCacheItem *) [_dataSource tokenWithKey:key serializer:_serializer context:context error:&cacheError];
        
        if (cacheError)
        {
            [self stopTelemetryLookupEvent:event tokenType:type withToken:nil success:NO context:context];
            if (error) *error = cacheError;
            return nil;
        }

        if (cacheItem)
        {
            MSIDBaseToken *token = [cacheItem tokenWithType:type];
            token.storageAuthority = token.authority;
            token.authority = authority;
            [self stopTelemetryLookupEvent:event tokenType:type withToken:token success:YES context:context];
            return token;
        }
    }

    [self stopTelemetryLookupEvent:event tokenType:type withToken:nil success:NO context:context];
    return nil;
}

- (MSIDBaseToken *)getTokenByHomeAccountId:(NSString *)homeAccountId
                                 tokenType:(MSIDCredentialType)tokenType
                                 authority:(NSURL *)authority
                             lookupAliases:(NSArray<NSURL *> *)aliases
                                  clientId:(NSString *)clientId
                                  resource:(NSString *)resource
                                   context:(id<MSIDRequestContext>)context
                                     error:(NSError **)error
{
    for (NSURL *alias in aliases)
    {
        MSID_LOG_VERBOSE(context, @"(Legacy accessor) Looking for token with alias %@, clientId %@, resource %@", alias, clientId, resource);
        MSID_LOG_VERBOSE_PII(context, @"(Legacy accessor) Looking for token with alias %@, clientId %@, resource %@, unique userId %@", alias, clientId, resource, homeAccountId);

        MSIDLegacyTokenCacheQuery *query = [MSIDLegacyTokenCacheQuery new];
        query.authority = alias;
        query.clientId = clientId;
        query.resource = resource;

        NSError *cacheError = nil;
        NSArray *tokens = [_dataSource tokensWithKey:query serializer:_serializer context:context error:&cacheError];
        
        if (cacheError)
        {
            if (error) *error = cacheError;
            return nil;
        }
        
        BOOL (^filterBlock)(MSIDCredentialCacheItem *cacheItem) = ^BOOL(MSIDCredentialCacheItem *cacheItem) {
            return [cacheItem.homeAccountId isEqualToString:homeAccountId];
        };
        
        NSArray *matchedTokens = [MSIDTokenFilteringHelper filterTokenCacheItems:tokens
                                                                       tokenType:tokenType
                                                                     returnFirst:YES
                                                                        filterBy:filterBlock];
        
        if ([matchedTokens count])
        {
            MSIDBaseToken *token = matchedTokens[0];
            token.storageAuthority = token.authority;
            token.authority = authority;
            return token;
        }
    }
    
    return nil;
}

#pragma mark - Telemetry helpers

- (MSIDTelemetryCacheEvent *)startCacheEventWithName:(NSString *)cacheEventName
                                             context:(id<MSIDRequestContext>)context
{
    [[MSIDTelemetry sharedInstance] startEvent:[context telemetryRequestId]
                                     eventName:cacheEventName];

    return [[MSIDTelemetryCacheEvent alloc] initWithName:cacheEventName context:context];
}

- (void)stopTelemetryEvent:(MSIDTelemetryCacheEvent *)event
                  withItem:(MSIDBaseToken *)token
                   success:(BOOL)success
                   context:(id<MSIDRequestContext>)context
{
    [event setStatus:success ? MSID_TELEMETRY_VALUE_SUCCEEDED : MSID_TELEMETRY_VALUE_FAILED];
    if (token)
    {
        [event setToken:token];
    }
    [[MSIDTelemetry sharedInstance] stopEvent:[context telemetryRequestId]
                                        event:event];
}

- (void)stopTelemetryLookupEvent:(MSIDTelemetryCacheEvent *)event
                       tokenType:(MSIDCredentialType)tokenType
                       withToken:(MSIDBaseToken *)token
                         success:(BOOL)success
                         context:(id<MSIDRequestContext>)context
{
    if (!success && tokenType == MSIDRefreshTokenType)
    {
        [event setWipeData:[_dataSource wipeInfo:context error:nil]];
    }
    
    [self stopTelemetryEvent:event
                    withItem:token
                     success:success
                     context:context];
}

@end
