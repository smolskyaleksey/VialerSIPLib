//
//  VSLAudio.m
//  Copyright © 2015 Devhouse Spindle. All rights reserved.
//
//

#import "VSLAudio.h"

@import AVFoundation;
#import <CocoaLumberjack/CocoaLumberjack.h>
#import "NSError+VSLError.h"

static const DDLogLevel ddLogLevel = DDLogLevelVerbose;
static NSString * const VSLAudioErrorDomain = @"VialerSIPLib.VSLAudio";

@interface VSLAudio ()
@property (assign)BOOL bluetoothEnabled;
@end

@implementation VSLAudio

+ (instancetype)sharedInstance {
    static dispatch_once_t once;
    static id sharedInstance;

    dispatch_once(&once, ^{
        sharedInstance = [[self alloc] init];
    });
    return sharedInstance;
}

- (void)configureSharedAudioSessionWithError:(NSError * _Nullable __autoreleasing *)error {
    NSError *audioSessionCategoryError;
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayAndRecord
                                     withOptions:AVAudioSessionCategoryOptionAllowBluetooth
                                           error:&audioSessionCategoryError];

    if (audioSessionCategoryError) {
        DDLogError(@"Error setting the correct AVAudioSession category");
        if (error != NULL) {
            *error = [NSError VSLUnderlyingError:audioSessionCategoryError
                         localizedDescriptionKey:NSLocalizedString(@"Error setting the correct AVAudioSession category", nil)
                     localizedFailureReasonError:NSLocalizedString(@"Error setting the correct AVAudioSession category", nil)
                                     errorDomain:VSLAudioErrorDomain
                                       errorCode:audioSessionCategoryError.code];
        }
    }
    [self setPreferredAudioToBuildIn];
}

- (void)toggleBluetooth {
    if (!self.bluetoothEnabled) {
        self.bluetoothEnabled = [self setPreferredAudioToBluetooth];
    } else {
        self.bluetoothEnabled = ![self setPreferredAudioToBuildIn];
    }
    DDLogVerbose(@"Bluetooth was turned %@", self.bluetoothEnabled ? @"ON" : @"OFF");
}

- (BOOL)setPreferredAudioToBuildIn {
    AVAudioSessionPortDescription *audioPort = [self builtinAudioDevice];
    DDLogInfo(@"Selected audio port: %@", audioPort);
    return [self setPreferredInput:audioPort];
}

- (BOOL)setPreferredAudioToBluetooth {
    AVAudioSessionPortDescription *audioPort = [self bluetoothAudioDevice];
    DDLogInfo(@"Selected audio port: %@", audioPort);
    return [self setPreferredInput:audioPort];
}

- (BOOL)setPreferredInput:(AVAudioSessionPortDescription *)audioPort {
    NSError* audioError = nil;
    [[AVAudioSession sharedInstance] setPreferredInput:audioPort
                                                 error:&audioError];
    if (audioError) {
        DDLogWarn(@"Error setting AudioPort. Error:\n%@", audioError);
        return NO;
    } else {
        return YES;
    }
}

- (AVAudioSessionPortDescription *)builtinAudioDevice {
    NSArray* builtinRoutes = @[AVAudioSessionPortBuiltInMic];
    return [self audioDeviceFromTypes:builtinRoutes];
}

- (AVAudioSessionPortDescription *)bluetoothAudioDevice {
    NSArray* bluetoothRoutes = @[AVAudioSessionPortBluetoothA2DP, AVAudioSessionPortBluetoothLE, AVAudioSessionPortBluetoothHFP];
    return [self audioDeviceFromTypes:bluetoothRoutes];
}

- (AVAudioSessionPortDescription*)audioDeviceFromTypes:(NSArray *)types {
    NSArray* routes = [[AVAudioSession sharedInstance] availableInputs];

    DDLogInfo(@"Audio routes %@", routes);
    for (AVAudioSessionPortDescription* route in routes) {
        if ([types containsObject:route.portType]) {
            return route;
        }
    }
    return nil;
}

@end
