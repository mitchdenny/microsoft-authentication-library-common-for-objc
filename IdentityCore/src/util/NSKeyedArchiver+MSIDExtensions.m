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

#import "NSKeyedArchiver+MSIDExtensions.h"

@implementation NSKeyedArchiver (MSIDExtensions)

+ (NSData *)msidEncodeObject:(nullable id)obj usingBlock:(void (^)(NSKeyedArchiver *archiver))block
{
    NSKeyedArchiver *archiver;
    NSMutableData *data = [NSMutableData data];
    if (@available(iOS 11.0, macOS 10.13, *))
    {
        archiver = [[NSKeyedArchiver alloc] initRequiringSecureCoding:YES];
    }
#if !TARGET_OS_UIKITFORMAC
    else
    {
        archiver = [[NSKeyedArchiver alloc] initForWritingWithMutableData:data];
    }
#endif
    
    if (block) block(archiver);
    
    [archiver encodeObject:obj forKey:NSKeyedArchiveRootObjectKey];
    [archiver finishEncoding];
    
    NSData *result;
    if (@available(macOS 10.12, *))
    {
        result = archiver.encodedData;
    }
    else
    {
        result = data;
    }
    
    return result;
}

+ (NSData *)msidArchivedDataWithRootObject:(id)object
                     requiringSecureCoding:(BOOL)requiresSecureCoding
                                     error:(NSError **)error
{
    NSData *result;
    if (@available(iOS 11.0, macOS 10.13, *))
    {
        result = [NSKeyedArchiver archivedDataWithRootObject:object requiringSecureCoding:requiresSecureCoding error:error];
    }
#if !TARGET_OS_UIKITFORMAC
    else
    {
        result = [NSKeyedArchiver archivedDataWithRootObject:object];
    }
#endif
    
    return result;
}

@end