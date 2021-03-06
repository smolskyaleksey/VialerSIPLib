//
//  VSLCall.m
//  Copyright © 2015 Devhouse Spindle. All rights reserved.
//

#import "VSLCall.h"

#import <AVFoundation/AVFoundation.h>
#import <CocoaLumberjack/CocoaLumberjack.h>
#import "NSError+VSLError.h"
#import "NSString+PJString.h"
#import "VSLAudioController.h"
#import "VSLEndpoint.h"
#import "VSLRingback.h"
#import "VialerSIPLib.h"
#import "VialerUtils.h"


static const DDLogLevel ddLogLevel = DDLogLevelVerbose;
static NSString * const VSLCallErrorDomain = @"VialerSIPLib.VSLCall";

NSString * const VSLCallStateChangedNotification = @"VSLCallStateChangedNotification";
NSString * const VSLCallConnectedNotification = @"VSLCallConnectedNotification";
NSString * const VSLCallDisconnectedNotification = @"VSLCallDisconnectedNotification";

@interface VSLCall()
@property (readwrite, nonatomic) VSLCallState callState;
@property (readwrite, nonatomic) NSString *callStateText;
@property (readwrite, nonatomic) NSInteger lastStatus;
@property (readwrite, nonatomic) NSString *lastStatusText;
@property (readwrite, nonatomic) VSLMediaState mediaState;
@property (readwrite, nonatomic) NSString *localURI;
@property (readwrite, nonatomic) NSString *remoteURI;
@property (readwrite, nonatomic) NSString *callerName;
@property (readwrite, nonatomic) NSString *callerNumber;
@property (readwrite, nonatomic) NSInteger callId;
@property (readwrite, nonatomic) NSUUID *uuid;
@property (readwrite, nonatomic) BOOL incoming;
@property (strong, nonatomic) VSLRingback *ringback;
@property (readwrite, nonatomic) BOOL muted;
@property (readwrite, nonatomic) BOOL speaker;
@property (readwrite, nonatomic) BOOL onHold;
@property (strong, nonatomic) NSString *currentAudioSessionCategory;
@property (nonatomic) BOOL connected;
@property (nonatomic) BOOL userDidHangUp;
@property (strong, nonatomic) AVAudioPlayer *disconnectedSoundPlayer;
@property (readwrite, nonatomic) VSLCallTransferState transferStatus;
@property (readwrite, nonatomic) NSTimeInterval lastSeenConnectDuration;
@property (strong, nonatomic) NSString *numberToCall;
@property (weak, nonatomic) VSLAccount *account;
/**
 *  Stats
 */
@property (readwrite, nonatomic) float totalMBsUsed;
@property (readwrite, nonatomic) float R;
@property (readwrite, nonatomic) float MOS;
@end

@implementation VSLCall

#pragma mark - Life Cycle

- (instancetype)initPrivateWithAccount:(VSLAccount *)account {
    if (self = [super init]) {
        self.uuid = [[NSUUID alloc] init];
        self.account = account;
    }
    return self;
}

- (instancetype)initInboundCallWithCallId:(NSUInteger)callId account:(VSLAccount *)account {
    if (self = [self initPrivateWithAccount:account]) {
        self.callId = callId;

        pjsua_call_info callInfo;
        pj_status_t status = pjsua_call_get_info((pjsua_call_id)self.callId, &callInfo);
        if (status == PJ_SUCCESS) {
            if (callInfo.state == VSLCallStateIncoming) {
                self.incoming = YES;
            } else {
                self.incoming = NO;
            }
            [self updateCallInfo:callInfo];
        }
    }
    DDLogVerbose(@"Inbound call init with uuid:%@ and id:%ld", self.uuid.UUIDString, (long)self.callId);
    return self;
}

- (instancetype)initOutboundCallWithNumberToCall:(NSString *)number account:(VSLAccount *)account {
    if (self = [self initPrivateWithAccount:account]) {
        self.numberToCall = [VialerUtils cleanPhoneNumber:number];
    }
    return self;
}

- (void)dealloc {
    DDLogVerbose(@"Dealloc Call uuid:%@ id:%ld", self.uuid.UUIDString, (long)self.callId);
}

#pragma mark - Properties
- (void)setCallState:(VSLCallState)callState {
    if (_callState != callState) {
        NSString *stringFromCallStateProperty = NSStringFromSelector(@selector(callState));
        [self willChangeValueForKey:stringFromCallStateProperty];
        DDLogDebug(@"Call(%@). CallState will change from %@(%ld) to %@(%ld)", self.uuid.UUIDString, VSLCallStateString(_callState),
                   (long)_callState, VSLCallStateString(callState), (long)callState);
        _callState = callState;

        switch (_callState) {
            case VSLCallStateNull: {

            } break;
            case VSLCallStateIncoming: {
                pj_status_t status = pjsua_call_answer((pjsua_call_id)self.callId, PJSIP_SC_RINGING, NULL, NULL);
                if (status != PJ_SUCCESS) {
                    DDLogWarn(@"Error %d while sending status code PJSIP_SC_RINGING", status);
                }
            } break;

            case VSLCallStateCalling: {

            } break;

            case VSLCallStateEarly: {
                if (!self.incoming) {
                    [self.ringback start];
                }
            } break;

            case VSLCallStateConnecting: {
            } break;

            case VSLCallStateConfirmed: {
                self.connected = YES;
                [self.ringback stop];
                // Register for the audio interruption notification to be able to restore the sip audio session after an interruption (incoming call/alarm....).
                [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(audioInterruption:) name:VSLAudioControllerAudioInterrupted object:nil];
                [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(audioInterruption:) name:VSLAudioControllerAudioResumed object:nil];
                [[NSNotificationCenter defaultCenter] postNotificationName:VSLCallConnectedNotification object:nil];

            } break;

            case VSLCallStateDisconnected: {
                [self calculateStats];
                [self.ringback stop];

                [[NSNotificationCenter defaultCenter] removeObserver:self name:VSLAudioControllerAudioResumed object:nil];
                [[NSNotificationCenter defaultCenter] removeObserver:self name:VSLAudioControllerAudioInterrupted object:nil];
                [[NSNotificationCenter defaultCenter] postNotificationName:VSLCallDisconnectedNotification object:nil];

                if (self.connected && !self.userDidHangUp) {
                    [self.disconnectedSoundPlayer play];
                }
            } break;
        }
        [self didChangeValueForKey:stringFromCallStateProperty];

        NSDictionary *notificationUserInfo = @{VSLNotificationUserInfoCallKey : self};
        [[NSNotificationCenter defaultCenter] postNotificationName:VSLCallStateChangedNotification
                                                            object:nil
                                                          userInfo:notificationUserInfo];
    }
}

- (void)setTransferStatus:(VSLCallTransferState)transferStatus {
    if (_transferStatus != transferStatus) {
        NSString *stringFromTranferStatusProperty = NSStringFromSelector(@selector(transferStatus));
        [self willChangeValueForKey:stringFromTranferStatusProperty];
        _transferStatus = transferStatus;
        [self didChangeValueForKey:stringFromTranferStatusProperty];
    }
}

- (void)setMediaState:(VSLMediaState)mediaState {
    if (_mediaState != mediaState) {
        DDLogDebug(@"MediaState will change from %@(%ld) to %@(%ld)", VSLMediaStateString(_mediaState),
                   (long)_mediaState, VSLMediaStateString(mediaState), (long)mediaState);
        _mediaState = mediaState;
    }
}

- (VSLRingback *)ringback {
    if (!_ringback) {
        _ringback = [[VSLRingback alloc] init];
    }
    return _ringback;
}

- (NSTimeInterval)connectDuration {
    // Check if call was ever connected before.
    if (self.callId == PJSUA_INVALID_ID) {
        return 0;
    }

    pjsua_call_info callInfo;
    pjsua_call_get_info((pjsua_call_id)self.callId, &callInfo);
    NSTimeInterval latestConnecDuration = callInfo.connect_duration.sec;

    // Workaround for callInfo.connect_duration being 0 at end of call
    if (latestConnecDuration > self.lastSeenConnectDuration) {
        self.lastSeenConnectDuration = latestConnecDuration;
        return latestConnecDuration;
    } else {
        return self.lastSeenConnectDuration;
    }
}

#pragma mark - Actions

- (void)startWithCompletion:(void (^)(NSError * error))completion {
    NSAssert(self.account, @"An account must be set to be able to start a call");
    pj_str_t sipUri = [self.numberToCall sipUriWithDomain:self.account.accountConfiguration.sipDomain];

    // Create call settings.
    pjsua_call_setting callSetting;
    pjsua_call_setting_default(&callSetting);
    callSetting.aud_cnt = 1;

    pj_status_t status = pjsua_call_make_call((int)self.account.accountId, &sipUri, &callSetting, NULL, NULL, (int *)&_callId);
    DDLogVerbose(@"Call(%@) received id:%ld", self.uuid.UUIDString, (long)self.callId);

    NSError *error;
    if (status != PJ_SUCCESS) {
        DDLogError(@"Error creating call");
        if (error != NULL) {
            error = [NSError VSLUnderlyingError:nil
                        localizedDescriptionKey:NSLocalizedString(@"Could not setup call", nil)
                    localizedFailureReasonError:[NSString stringWithFormat:NSLocalizedString(@"PJSIP status code: %d", nil), status]
                                    errorDomain:VSLCallErrorDomain
                                      errorCode:VSLCallErrorCannotCreateCall];
        }
    }
    completion(error);
}

- (AVAudioPlayer *)disconnectedSoundPlayer {
    if (!_disconnectedSoundPlayer) {
        NSBundle *podBundle = [NSBundle bundleForClass:self.classForCoder];
        NSBundle *vialerBundle = [NSBundle bundleWithURL:[podBundle URLForResource:@"VialerSIPLib" withExtension:@"bundle"]];
        NSURL *disconnectedSound = [vialerBundle URLForResource:@"disconnected" withExtension:@"wav"];
        NSAssert(disconnectedSound, @"No sound available");
        NSError *error;
        _disconnectedSoundPlayer = [[AVAudioPlayer alloc] initWithContentsOfURL:disconnectedSound error:&error];
        _disconnectedSoundPlayer.volume = 1.0f;
        [_disconnectedSoundPlayer prepareToPlay];
    }
    return _disconnectedSoundPlayer;
}

- (BOOL)transferToCall:(VSLCall *)secondCall {
    NSError *error;
    if (!self.onHold && ![self toggleHold:&error]) {
        DDLogError(@"Error holding call: %@", error);
        return NO;
    }
    pj_status_t success = pjsua_call_xfer_replaces((pjsua_call_id)self.callId, (pjsua_call_id)secondCall.callId, 0, nil);

    if (success == PJ_SUCCESS) {
        self.transferStatus = VSLCallTransferStateInitialized;
        return YES;
    }
    return NO;
}

- (void)callTransferStatusChangedWithStatusCode:(NSInteger)statusCode statusText:(NSString *)text final:(BOOL)final {
    if (statusCode == PJSIP_SC_TRYING) {
        self.transferStatus = VSLCallTransferStateTrying;
    } else if (statusCode / 100 == 2) {
        self.transferStatus = VSLCallTransferStateAccepted;
        // After successfull transfer, end the call.
        NSError *error;
        [self hangup:&error];
        if (error) {
            DDLogError(@"Error hangup call: %@", error);
        }
    } else {
        self.transferStatus = VSLCallTransferStateRejected;
    }
}

- (void)reinvite {
    if (self.callState > VSLCallStateNull && self.callState < VSLCallStateDisconnected) {
        pjsua_call_reinvite((pjsua_call_id)self.callId, PJSUA_CALL_UPDATE_CONTACT, NULL);
        DDLogDebug(@"Reinvite sent");
    }
}

#pragma mark - Callback methods

- (void)updateCallInfo:(pjsua_call_info)callInfo {
    self.callState = (VSLCallState)callInfo.state;
    self.callStateText = [NSString stringWithPJString:callInfo.state_text];
    self.lastStatus = callInfo.last_status;
    self.lastStatusText = [NSString stringWithPJString:callInfo.last_status_text];
    self.localURI = [NSString stringWithPJString:callInfo.local_info];
    self.remoteURI = [NSString stringWithPJString:callInfo.remote_info];
    if (self.remoteURI) {
        NSDictionary *callerInfo = [self getCallerInfoFromRemoteUri:self.remoteURI];
        self.callerName = callerInfo[@"caller_name"];
        self.callerNumber = callerInfo[@"caller_number"];
    }
}

- (void)callStateChanged:(pjsua_call_info)callInfo {
    [self updateCallInfo:callInfo];
}

- (void)mediaStateChanged:(pjsua_call_info)callInfo  {
    pjsua_call_media_status mediaState = callInfo.media_status;
    DDLogVerbose(@"Media State Changed from %@ to %@", VSLMediaStateString(self.mediaState), VSLMediaStateString((VSLMediaState)mediaState));
    self.mediaState = (VSLMediaState)mediaState;

    if (self.mediaState == VSLMediaStateActive || self.mediaState == VSLMediaStateRemoteHold) {
        [self.ringback stop];
        pjsua_conf_connect(callInfo.conf_slot, 0);
        pjsua_conf_connect(0, callInfo.conf_slot);
    }

    [self updateCallInfo:callInfo];
}

#pragma mark - User actions
- (void)answerWithCompletion:(void (^)(NSError *error))completion {
    pj_status_t status;

    if (self.callId != PJSUA_INVALID_ID) {
        status = pjsua_call_answer((int)self.callId, PJSIP_SC_OK, NULL, NULL);

        if (status != PJ_SUCCESS) {
            DDLogError(@"Could not answer call PJSIP returned status code:%d", status);
            NSError *error = [NSError VSLUnderlyingError:nil
                                 localizedDescriptionKey:NSLocalizedString(@"Could not answer call", nil)
                             localizedFailureReasonError:[NSString stringWithFormat:NSLocalizedString(@"PJSIP status code: %d", nil), status]
                                             errorDomain:VSLCallErrorDomain
                                               errorCode:VSLCallErrorCannotAnswerCall];
            completion(error);
        } else {
            completion(nil);
        }

    } else {
        DDLogError(@"Could not answer call, PJSIP indicated callId(%ld) as invalid", (long)self.callId);
        NSError *error = [NSError VSLUnderlyingError:nil
                             localizedDescriptionKey:NSLocalizedString(@"Could not answer call", nil)
                         localizedFailureReasonError:[NSString stringWithFormat:NSLocalizedString(@"Call Id: %d invalid", nil), self.callId]
                                         errorDomain:VSLCallErrorDomain
                                           errorCode:VSLCallErrorCannotAnswerCall];
        completion(error);
    }
}

- (BOOL)decline:(NSError **)error {
    pj_status_t status = pjsua_call_answer((int)self.callId, PJSIP_SC_BUSY_HERE, NULL, NULL);
    if (status != PJ_SUCCESS) {
        if (error != NULL) {
            *error = [NSError VSLUnderlyingError:nil
                         localizedDescriptionKey:NSLocalizedString(@"Could not decline call", nil)
                     localizedFailureReasonError:[NSString stringWithFormat:NSLocalizedString(@"PJSIP status code: %d", nil), status]
                                     errorDomain:VSLCallErrorDomain
                                       errorCode:VSLCallErrorCannotDeclineCall];
        }
        return NO;
    }
    return YES;
}

- (BOOL)hangup:(NSError **)error {
    if (self.callId != PJSUA_INVALID_ID) {
        if (self.callState != VSLCallStateDisconnected) {
            self.userDidHangUp = YES;
            pj_status_t status = pjsua_call_hangup((int)self.callId, 0, NULL, NULL);
            if (status != PJ_SUCCESS) {
                if (error != NULL) {
                    *error = [NSError VSLUnderlyingError:nil
                                 localizedDescriptionKey:NSLocalizedString(@"Could not hangup call", nil)
                             localizedFailureReasonError:[NSString stringWithFormat:NSLocalizedString(@"PJSIP status code: %d", nil), status]
                                             errorDomain:VSLCallErrorDomain
                                               errorCode:VSLCallErrorCannotHangupCall];
                }
                return NO;
            }
        }
    }
    return YES;
}

- (BOOL)toggleMute:(NSError **)error {
    if (self.callState != VSLCallStateConfirmed) {
        return YES;
    }

    pjsua_call_info callInfo;
    pjsua_call_get_info((pjsua_call_id)self.callId, &callInfo);

    pj_status_t status;
    if (!self.muted) {
        status = pjsua_conf_disconnect(0, callInfo.conf_slot);
    } else {
        status = pjsua_conf_connect(0, callInfo.conf_slot);
    }

    if (status == PJ_SUCCESS) {
        self.muted = !self.muted;
        DDLogVerbose(self.muted ? @"Microphone muted": @"Microphone unmuted");
    } else {
        if (error != NULL) {
            NSDictionary *userInfo = @{NSLocalizedDescriptionKey:NSLocalizedString(@"Could not toggle mute call", nil),
                                       NSLocalizedFailureReasonErrorKey:[NSString stringWithFormat:NSLocalizedString(@"PJSIP status code: %d", status)]
                                       };
            *error = [NSError errorWithDomain:VSLCallErrorDomain code:VSLCallErrorCannotToggleMute userInfo:userInfo];
        }
        return NO;
        DDLogError(@"Error toggle muting microphone in call %@", self.uuid.UUIDString);
    }
    return YES;
}

- (void)toggleSpeaker {
    AVAudioSession *audioSession = [AVAudioSession sharedInstance];
    if (!self.speaker) {
        [audioSession overrideOutputAudioPort:AVAudioSessionPortOverrideSpeaker error:nil];
        self.speaker = YES;
    } else {
        [audioSession overrideOutputAudioPort:AVAudioSessionPortOverrideNone error:nil];
        self.speaker = NO;
    }
    DDLogVerbose(self.speaker ? @"Speaker modus activated": @"Speaker modus deactivated");
}

- (BOOL)toggleHold:(NSError **)error {
    if (self.callState != VSLCallStateConfirmed) {
        return YES;
    }
    pj_status_t status;

    if (self.onHold) {
        status = pjsua_call_reinvite((pjsua_call_id)self.callId, PJ_TRUE, NULL);
    } else {
        status = pjsua_call_set_hold((pjsua_call_id)self.callId, NULL);
    }

    if (status == PJ_SUCCESS) {
        self.onHold = !self.onHold;
        DDLogVerbose(self.onHold ? @"Call is on hold": @"On hold state ended");
    } else {
        if (error != NULL) {
            NSDictionary *userInfo = @{NSLocalizedDescriptionKey:NSLocalizedString(@"Could not toggle onhold call", nil),
                                       NSLocalizedFailureReasonErrorKey:[NSString stringWithFormat:NSLocalizedString(@"PJSIP status code: %d", status)]
                                       };
            *error = [NSError errorWithDomain:VSLCallErrorDomain code:VSLCallErrorCannotToggleHold userInfo:userInfo];
        }
        return NO;
        DDLogError(@"Error toggle holding in call %@", self.uuid.UUIDString);
    }
    return YES;
}

- (BOOL)sendDTMF:(NSString *)character error:(NSError **)error {
    // Return if the call is not confirmed or when the call is on hold.
    if (self.callState != VSLCallStateConfirmed || self.onHold) {
        return YES;
    }

    pj_status_t status;
    pj_str_t digits = [character pjString];

    // Try sending DTMF digits to remote using RFC 2833 payload format first.
    status = pjsua_call_dial_dtmf((pjsua_call_id)self.callId, &digits);

    if (status == PJ_SUCCESS) {
        DDLogVerbose(@"Succesfull send character: %@ for DTMF for call %@", character, self.uuid.UUIDString);
    } else {
        // The RFC 2833 payload format did not work.
        const pj_str_t kSIPINFO = pj_str("INFO");

        for (NSUInteger i = 0; i < [character length]; ++i) {
            pjsua_msg_data messageData;
            pjsua_msg_data_init(&messageData);
            messageData.content_type = pj_str("application/dtmf-relay");

            NSString *messageBody = [NSString stringWithFormat:@"Signal=%C\r\nDuration=300", [character characterAtIndex:i]];
            messageData.msg_body = [messageBody pjString];

            status = pjsua_call_send_request((pjsua_call_id)self.callId, &kSIPINFO, &messageData);
            if (status == PJ_SUCCESS) {
                DDLogVerbose(@"Succesfull send character: %@ for DTMF for call %@", character, self.uuid.UUIDString);
            } else {
                if (error != NULL) {
                    NSDictionary *userInfo = @{NSLocalizedDescriptionKey:NSLocalizedString(@"Could not send DTMF", nil),
                                               NSLocalizedFailureReasonErrorKey:[NSString stringWithFormat:NSLocalizedString(@"PJSIP status code: %d", status)]
                                               };
                    *error = [NSError errorWithDomain:VSLCallErrorDomain code:VSLCallErrorCannotSendDTMF userInfo:userInfo];
                }
                return NO;
                DDLogError(@"Error error sending DTMF for call %@", self.uuid.UUIDString);
            }
        }
    }
    return YES;
}

/**
 * The Actual audio interuption is handled in VSLAudioController
 */
- (void)audioInterruption:(NSNotification *)notification {
    if (([notification.name isEqualToString:VSLAudioControllerAudioInterrupted] && !self.onHold) ||
        ([notification.name isEqualToString:VSLAudioControllerAudioResumed] && self.onHold)) {
        [self toggleHold:nil];
    }
}

#pragma mark - KVO override

+ (BOOL)automaticallyNotifiesObserversOfCallState {
    return NO;
}

+ (BOOL)automaticallyNotifiesObserversOfTransferStatus {
    return NO;
}

#pragma mark - helper function

/**
 *  Get the caller_name and caller_number from a string
 *
 *  @param string the input string formatter like "name" <sip:42@sip.nl>
 *
 *  @return NSDictionary output like @{"caller_name: name, "caller_number": 42}.
 */
- (NSDictionary *)getCallerInfoFromRemoteUri:(NSString *)string {
    NSString *callerName = @"";
    NSString *callerNumber = @"";
    NSString *callerHost;
    NSString *destination;
    NSRange delimterRange;
    NSRange atSignRange;
    NSRange semiColonRange;
    // Create a character set which will be trimmed from the string.
    NSMutableCharacterSet *charactersToTrim = [[NSCharacterSet whitespaceCharacterSet] mutableCopy];

    if ([[NSPredicate predicateWithFormat:@"SELF MATCHES '.+\\\\s\\\\(.+\\\\)'"] evaluateWithObject:string]) {
        /**
         * This matches the remote_uri for a format of: "destination (display_name)
         */

        delimterRange = [string rangeOfString:@" (" options:NSBackwardsSearch];

        // Create a character set which will be trimmed from the string.
        // All in-line whitespace and double quotes.
        [charactersToTrim addCharactersInString:@"\"()"];

        callerName = [[string substringFromIndex:delimterRange.location] stringByTrimmingCharactersInSet:charactersToTrim];

        destination = [string substringToIndex:delimterRange.location];

        // Get the last part of the uri starting from @
        atSignRange = [destination rangeOfString:@"@" options:NSBackwardsSearch];
        callerHost = [destination substringToIndex: atSignRange.location];

        // Get the telephone part starting from the :
        semiColonRange = [callerHost rangeOfString:@":" options:NSBackwardsSearch];
        callerNumber = [callerHost substringFromIndex:semiColonRange.location + 1];
    } else if ([[NSPredicate predicateWithFormat:@"SELF MATCHES '.+\\\\s<.+>'"] evaluateWithObject:string]) {
        /**
         *  This matches the remote_uri format of: "display_name" <destination_address>
         */

        delimterRange = [string rangeOfString:@" <" options:NSBackwardsSearch];

        // All in-line whitespace and double quotes.
        [charactersToTrim addCharactersInString:@"\""];

        // Get the caller_name from to where the first < is
        // and also trimming the characters defined in charactersToTrim.
        callerName = [[string substringToIndex:delimterRange.location] stringByTrimmingCharactersInSet:charactersToTrim];

        // Get the second part of the uri starting from the <
        NSRange destinationRange = NSMakeRange(delimterRange.location + 2,
                                               ([string length] - (delimterRange.location + 2) - 1));
        destination = [string substringWithRange: destinationRange];

        // Get the last part of the uri starting from @
        atSignRange = [destination rangeOfString:@"@" options:NSBackwardsSearch];
        callerHost = [destination substringToIndex: atSignRange.location];

        // Get the telephone part starting from the :
        semiColonRange = [callerHost rangeOfString:@":" options:NSBackwardsSearch];
        callerNumber = [callerHost substringFromIndex:semiColonRange.location + 1];
    } else if ([[NSPredicate predicateWithFormat:@"SELF MATCHES '<.+\\\\>'"] evaluateWithObject:string]) {
        /**
         * This matches the remote_uri format of: <sip:42@test.nl>
         */

        // Get the second part of the uri starting from the <
        NSRange destinationRange = NSMakeRange(1,
                                               ([string length] - 2));
        destination = [string substringWithRange: destinationRange];

        // Get the last part of the uri starting from @
        atSignRange = [destination rangeOfString:@"@" options:NSBackwardsSearch];
        callerHost = [destination substringToIndex: atSignRange.location];

        // Get the telephone part starting from the :
        semiColonRange = [callerHost rangeOfString:@":" options:NSBackwardsSearch];
        callerNumber = [callerHost substringFromIndex:semiColonRange.location + 1];
    } else {
        /**
         * This matches the remote_uri format of: sip:42@test.nl
         */

        // Get the last part of the uri starting from @
        atSignRange = [string rangeOfString:@"@" options:NSBackwardsSearch];
        if (atSignRange.location != NSNotFound) {
            callerHost = [string substringToIndex: atSignRange.location];

            // Get the telephone part starting from the :
            semiColonRange = [callerHost rangeOfString:@":" options:NSBackwardsSearch];
            if (semiColonRange.location != NSNotFound) {
                callerNumber = [callerHost substringFromIndex:semiColonRange.location + 1];
            }
        }
    }

    return @{
             @"caller_name": callerName,
             @"caller_number": callerNumber,
             };
}

#pragma mark - Stats

- (void)calculateStats {
    [self calculateMOS];
    [self calculateTotalMBsUsed];
}

- (float)calculateTotalMBsUsed {
    pj_status_t status = PJ_SUCCESS;
    pjsua_stream_stat stat;
    status = pjsua_call_get_stream_stat((pjsua_call_id)self.callId, 0, &stat);
    if (status == PJ_SUCCESS) {
        self.totalMBsUsed = (stat.rtcp.rx.bytes + stat.rtcp.tx.bytes) / 1024.0 / 1024.0;
    } else {
        DDLogInfo(@"No data");
    }
    return self.totalMBsUsed;
}

/**
 *  This will calculate the current MOS value of the call.
 *
 *  Credits to: https://www.pingman.com/kb/article/how-is-mos-calculated-in-pingplotter-pro-50.html
 */
- (float)calculateR {
    pj_status_t status = PJ_SUCCESS;
    pjsua_stream_stat stat;
    status = pjsua_call_get_stream_stat((pjsua_call_id)self.callId, 0, &stat);
    if (status == PJ_SUCCESS) {

        // Average Jitter in miliseconds
        float rxJitter = (float)stat.rtcp.rx.jitter.mean / 1000;

        // Round Trip Time in miliseconds.
        float averageRoundTripTime = stat.rtcp.rtt.mean / 1000.0f;

        // If there is no Round Trip Time information in rtcp packets we estimate value.
        if (averageRoundTripTime == 0) {
            averageRoundTripTime = 20.0; // Guess from Bob after logging of some calls.
        }

        // Take the average latency, add jitter, but double the impact to latency
        // then add 10 for protocol latencies
        float effectiveLatency = averageRoundTripTime + rxJitter * 2 + 10;

        // Implement a basic curve - deduct 4 for the R value at 160ms of latency
        // (round trip).  Anything over that gets a much more agressive deduction.
        float R;
        if (effectiveLatency < 160) {
            R = 93.2 - (effectiveLatency / 40);
        } else {
            R = 93.2 - (effectiveLatency - 120) / 10;
        }

        // Number of packets send and received.
        float rxPackets = stat.rtcp.rx.pkt;

        // Percentage package loss (100 = 100% loss - 0 = 0% loss)
        float rxPacketLoss = rxPackets == 0 ? 100.0 : (((float)stat.rtcp.rx.loss) / (float)(rxPackets + stat.rtcp.rx.loss)) * 100.0;

        // Now, let's deduct 2.5 R values per percentage of packet loss.
        self.R = R - (rxPacketLoss * 2.5);
    } else {
        DDLogInfo(@"No R");
    }
    return self.R;
}

- (float)calculateMOS {
    // Convert the R into an MOS value.
    float R = [self calculateR];
    if (R > 0) {
        self.MOS = 1 + 0.035 * R + .000007 * R * (R - 60) * (100 - R);
    } else {
        DDLogInfo(@"No MOS");
    }
    return self.MOS;
}

- (NSString *)debugDescription {
    NSMutableString *desc = [[NSMutableString alloc] initWithFormat:@"%@\n", self];
    [desc appendFormat:@"\t UUID: %@\n", self.uuid.UUIDString];
    [desc appendFormat:@"\t Call ID: %ld\n", (long)self.callId];
    [desc appendFormat:@"\t CallState: %@\n", VSLCallStateString(self.callState)];
    [desc appendFormat:@"\t VSLMediaState: %@\n", VSLMediaStateString(self.mediaState)];
    [desc appendFormat:@"\t VSLCallTransferState: %@\n", VSLCallTransferStateString(self.transferStatus)];
    [desc appendFormat:@"\t Account: %ld\n", (long)self.account.accountId];
    [desc appendFormat:@"\t Last Status: %@(%ld)\n", self.lastStatusText, (long)self.lastStatus];
    [desc appendFormat:@"\t Number to Call: %@\n", self.numberToCall];
    [desc appendFormat:@"\t Local URI: %@\n", self.localURI];
    [desc appendFormat:@"\t Remote URI: %@\n", self.remoteURI];
    [desc appendFormat:@"\t Caller Name: %@\n", self.callerName];
    [desc appendFormat:@"\t Caller Number: %@\n", self.callerNumber];
    [desc appendFormat:@"\t Is Incoming: %@\n", self.isIncoming? @"YES" : @"NO"];
    [desc appendFormat:@"\t Is muted: %@\n", self.muted? @"YES" : @"NO"];
    [desc appendFormat:@"\t On Speaker: %@\n", self.speaker? @"YES" : @"NO"];
    [desc appendFormat:@"\t On Hold: %@\n", self.onHold? @"YES" : @"NO"];
    [desc appendFormat:@"\t User Did Hangup: %@\n", self.userDidHangUp? @"YES" : @"NO"];

    return desc;
}

@end
