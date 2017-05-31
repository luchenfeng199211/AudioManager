//
//  AudioManager.h
//  HealForce
//
//  Created by Healforce on 2017/3/21.
//  Copyright © 2017年 HealForce. All rights reserved.
//

#import <Foundation/Foundation.h>

#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>

@protocol AudioManagerDelegate <NSObject>

@optional
/*开始录音*/
- (void)audioStartRecording;
/*暂停录音*/
- (void)audioStopRecording;
/*停止录音*/
- (void)audioEndRecording;
@required
- (void)audioSaveFinishedCompleteWithMP3FileName:(NSString *)MP3FileName;
/*返回声音的音量大小*/
- (void)audioVolume:(double)volume;

/*监控耳机口插拔的回调*/
- (void)headPhoneState:(BOOL)state;

@end

typedef void(^VolumeBlock)(double volume);

@interface AudioManager : NSObject

@property (nonatomic,copy) VolumeBlock volumeBlock;
@property (nonatomic,assign) id <AudioManagerDelegate> delegate;
//+ (AudioManager *)sharedManager;

- (BOOL)isConnectingHeadPhoneJack;
- (void)resetAudioWaver;

//开始接受声音数据
- (void)startRecordingAudio;
//开始录制音频
- (void)startRecordingData;
//单纯停止录制
- (void)stopRecording;
//停止录制并将音频转化为mp3格式
- (void)endRecording;

@end
