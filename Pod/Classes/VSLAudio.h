//
//  VSLAudio.h
//  Copyright © 2015 Devhouse Spindle. All rights reserved.
//
//

#import <Foundation/Foundation.h>

@interface VSLAudio : NSObject

/**
 *  YES if bluetooth is enabled otherwise NO.
 */
@property (readonly)BOOL bluetoothEnabled;

/**
 * The shared audio instance.
 */
+ (instancetype _Nonnull)sharedInstance;

/**
 *  Configure the shared audio session to suit the apps need.
 *
 *  @param error An error is given when configuration of the audio session fails.
 */
- (void)configureSharedAudioSessionWithError:(NSError * _Nullable * _Nullable)error;

/**
 *  Set the AVAudioSession output to bluetooth
 */
- (void)toggleBluetooth;
@end
