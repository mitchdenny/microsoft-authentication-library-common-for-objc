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

#import <XCTest/XCTest.h>
#import "MSIDKeychainTokenCache.h"
#import "MSIDBrokerKeyProvider.h"
#import <CommonCrypto/CommonCryptor.h>
#import "MSIDKeychainUtil.h"

@interface MSIDBrokerKeyProviderTests : XCTestCase

@end

@implementation MSIDBrokerKeyProviderTests

- (void)setUp
{
    [super setUp];

    // Clear keychain
    NSDictionary *query = @{(id)kSecClass : (id)kSecClassKey,
                            (id)kSecAttrKeyClass : (id)kSecAttrKeyClassSymmetric};

    SecItemDelete((CFDictionaryRef)query);
}

#pragma mark - Normal scenarios

- (void)testBrokerKeyWithError_whenNoKeyInKeychain_shouldCreateNewKey
{
    MSIDBrokerKeyProvider *keyProvider = [[MSIDBrokerKeyProvider alloc] initWithGroup:nil];
    NSError *error = nil;
    NSData *brokerKey = [keyProvider brokerKeyWithError:&error];

    XCTAssertNotNil(brokerKey);
    XCTAssertNil(error);
    XCTAssertEqual([brokerKey length], 32);
}

- (void)testBrokerKeyWithError_whenKeyInKeychain_shouldReturnKey
{
    // Pre-add key to the keychain
    NSData *keyData = [@"my-random-key-data" dataUsingEncoding:NSUTF8StringEncoding];

    [self addKey:keyData
     accessGroup:[[NSBundle mainBundle] bundleIdentifier]
  applicationTag:@"com.microsoft.adBrokerKey"];

    // Read key from broker key provider
    MSIDBrokerKeyProvider *keyProvider = [[MSIDBrokerKeyProvider alloc] initWithGroup:nil];
    NSError *error = nil;
    NSData *brokerKey = [keyProvider brokerKeyWithError:&error];

    XCTAssertNotNil(brokerKey);
    XCTAssertNil(error);
    XCTAssertEqualObjects(brokerKey, keyData);
}

#pragma mark - Migration scenarios

- (void)testBrokerKeyWithError_whenMultipleKeysPresent_shouldReturnOneFromSharedgroup
{
    // Add one key to the shared group
    NSData *firstKeyData = [@"my-random-key-data-1" dataUsingEncoding:NSUTF8StringEncoding];
    [self addKey:firstKeyData accessGroup:@"com.microsoft.adalcache" applicationTag:@"com.microsoft.adBrokerKey"];

    // Add second key to private groyp
    NSData *secondKeyData = [@"my-random-key-data-2" dataUsingEncoding:NSUTF8StringEncoding];
    [self addKey:secondKeyData accessGroup:[[NSBundle mainBundle] bundleIdentifier] applicationTag:@"com.microsoft.adBrokerKey"];

    // Try to read key
    MSIDBrokerKeyProvider *keyProvider = [[MSIDBrokerKeyProvider alloc] initWithGroup:@"com.microsoft.adalcache"];
    NSError *error = nil;
    NSData *brokerKey = [keyProvider brokerKeyWithError:&error];

    XCTAssertNotNil(brokerKey);
    XCTAssertNil(error);
    XCTAssertEqualObjects(brokerKey, firstKeyData);
}

- (void)testBrokerKeyWithError_whenCorrectKeyPresentInPrivateCache_shouldReturnOneFromPrivateCache
{
    // Add one key to the shared group
    NSData *firstKeyData = [@"my-random-key-data-1" dataUsingEncoding:NSUTF8StringEncoding];
    [self addKey:firstKeyData accessGroup:@"com.microsoft.adalcache" applicationTag:@"com.microsoft.adBrokerKeyUnknown"];

    // Add second key to private groyp
    NSData *secondKeyData = [@"my-random-key-data-2" dataUsingEncoding:NSUTF8StringEncoding];
    [self addKey:secondKeyData accessGroup:[[NSBundle mainBundle] bundleIdentifier] applicationTag:@"com.microsoft.adBrokerKey"];

    // Try to read key
    MSIDBrokerKeyProvider *keyProvider = [[MSIDBrokerKeyProvider alloc] initWithGroup:@"com.microsoft.adalcache"];
    NSError *error = nil;
    NSData *brokerKey = [keyProvider brokerKeyWithError:&error];

    XCTAssertNotNil(brokerKey);
    XCTAssertNil(error);
    XCTAssertEqualObjects(brokerKey, secondKeyData);
}

- (void)testBrokerKeyWithError_whenMultipleEntriesPresentInOtherGroups_shouldReturnOneEntry
{
    // Add one key to the shared group
    NSData *firstKeyData = [@"my-random-key-data-1" dataUsingEncoding:NSUTF8StringEncoding];
    [self addKey:firstKeyData accessGroup:@"com.microsoft.adalcache" applicationTag:@"com.microsoft.adBrokerKeyUnknown"];

    // Add second key to private group
    NSData *secondKeyData = [@"my-random-key-data-2" dataUsingEncoding:NSUTF8StringEncoding];
    [self addKey:secondKeyData accessGroup:[[NSBundle mainBundle] bundleIdentifier] applicationTag:@"com.microsoft.adBrokerKey"];

    // Add third key to intune mam group
    NSData *thirdKeyData = [@"my-random-key-data-3" dataUsingEncoding:NSUTF8StringEncoding];
    [self addKey:thirdKeyData accessGroup:@"com.microsoft.intune.mam" applicationTag:@"com.microsoft.adBrokerKey"];

    // Try to read key
    MSIDBrokerKeyProvider *keyProvider = [[MSIDBrokerKeyProvider alloc] initWithGroup:@"com.microsoft.adalcache"];
    NSError *error = nil;
    NSData *brokerKey = [keyProvider brokerKeyWithError:&error];

    XCTAssertNotNil(brokerKey);
    XCTAssertNil(error);
    XCTAssertEqualObjects(brokerKey, secondKeyData);
}

#pragma mark - Helpers

- (void)addKey:(NSData *)keyData
   accessGroup:(NSString *)accessGroup
applicationTag:(NSString *)applicationTag
{
    NSData *symmetricTag = [applicationTag dataUsingEncoding:NSUTF8StringEncoding];
    NSString *keychainGroup = [MSIDKeychainUtil accessGroup:accessGroup];

    NSDictionary *symmetricKeyAttr =
    @{
      (id)kSecClass : (id)kSecClassKey,
      (id)kSecAttrKeyClass : (id)kSecAttrKeyClassSymmetric,
      (id)kSecAttrApplicationTag : (id)symmetricTag,
      (id)kSecAttrKeyType : @(CSSM_ALGID_AES),
      (id)kSecAttrKeySizeInBits : @(kChosenCipherKeySize << 3),
      (id)kSecAttrEffectiveKeySize : @(kChosenCipherKeySize << 3),
      (id)kSecAttrCanEncrypt : @YES,
      (id)kSecAttrCanDecrypt : @YES,
      (id)kSecValueData : keyData,
      (id)kSecAttrAccessible : (id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
      (id)kSecAttrAccessGroup : keychainGroup
      };

    OSStatus result = SecItemAdd((__bridge CFDictionaryRef)symmetricKeyAttr, NULL);
    XCTAssertEqual(result, errSecSuccess);
}

@end