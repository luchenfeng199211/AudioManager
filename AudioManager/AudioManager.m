//
//  AudioManager.m
//  HealForce
//
//  Created by Healforce on 2017/3/21.
//  Copyright © 2017年 HealForce. All rights reserved.
//

#import "AudioManager.h"

#import "lame.h"

#import <Accelerate/Accelerate.h>

#define kOutputBus 0
#define kInputBus 1
#define FFT_LENGTH 2048

static AudioManager *_manager;
static NSMutableData *_resultData;
static AudioUnit curRioUnit;

static OSStatus recordingCallback(void *inRefCon,
                                  AudioUnitRenderActionFlags *ioActionFlags,
                                  const AudioTimeStamp *inTimeStamp,
                                  UInt32 inBusNumber,
                                  UInt32 inNumberFrames,
                                  AudioBufferList *ioData) {
    OSStatus err = noErr;
    err = AudioUnitRender(curRioUnit, ioActionFlags, inTimeStamp, kInputBus, inNumberFrames, ioData);
    
    if (ioData != NULL)
    {
        /*拿到音频分贝大小*/
        {
            NSData *pcmData = [NSData dataWithBytes:ioData->mBuffers[0].mData length:ioData->mBuffers[0].mDataByteSize];
            long long pcmAllLenght = 0;
            
            short butterByte[pcmData.length/2];
            memcpy(butterByte, pcmData.bytes, pcmData.length);//frame_size * sizeof(short)
            // 将 buffer 内容取出，进行平方和运算
            for (int i = 0; i < pcmData.length/2; i++)
            {
                pcmAllLenght += butterByte[i] * butterByte[i];
            }
            // 平方和除以数据总长度，得到音量大小。
            double mean = pcmAllLenght / (double)pcmData.length;
            double volume =10*log10(mean);//volume为分贝数大小
            
            if (volume > 25) {
                NSLog(@"分贝====%f",volume);
                if ([_manager.delegate respondsToSelector:@selector(audioVolume:)]) {
                    [_manager.delegate audioVolume:volume];
                }
            }
        }
        
        Float32 *bufferData = (Float32 *)ioData->mBuffers[0].mData;
        //NSLog(@"%f",bufferData);
        /*fft处理*/
        vDSP_Length log2n = log2f(FFT_LENGTH);
        FFTSetup fftSetup = vDSP_create_fftsetup(log2n, 0);
        DSPSplitComplex curComplexSplit;
        curComplexSplit.realp = (Float32 *)malloc(FFT_LENGTH/2*sizeof(Float32));
        curComplexSplit.imagp = (Float32 *)malloc(FFT_LENGTH/2*sizeof(Float32));
        Float32 mFFTNormFactor = 1.0/(2*FFT_LENGTH);
        Float32 *invertedCheckData = (Float32*)malloc(FFT_LENGTH/2*sizeof(Float32));
        
        vDSP_ctoz((COMPLEX *)bufferData, 2, &curComplexSplit, 1, FFT_LENGTH/2);
        vDSP_fft_zrip(fftSetup, &curComplexSplit, 1, log2n, FFT_FORWARD);
        
        vDSP_vsmul(curComplexSplit.realp, 1, &mFFTNormFactor, curComplexSplit.realp, 1, FFT_LENGTH/2);
        vDSP_vsmul(curComplexSplit.imagp, 1, &mFFTNormFactor, curComplexSplit.imagp, 1, FFT_LENGTH/2);
        float *outFFTData = (float *)malloc(FFT_LENGTH/2*sizeof(float));
        
        vDSP_zvmags(&curComplexSplit, 1, outFFTData, 1, FFT_LENGTH/2);
        
        vDSP_vsadd(outFFTData, 1, invertedCheckData, outFFTData, 1, FFT_LENGTH/2);
        Float32 one = 1;
        vDSP_vdbcon(outFFTData, 1, &one, outFFTData, 1, FFT_LENGTH/2, 0);
        
        //用完以后处理掉
        vDSP_destroy_fftsetup(fftSetup);
        
//        NSLog(@"outFFTData====%f",*outFFTData);
        
        [_resultData appendBytes:ioData->mBuffers[0].mData length:ioData->mBuffers[0].mDataByteSize];
        //        NSLog(@"%u",(unsigned int)ioData->mBuffers[0].mDataByteSize);
        //        NSLog(@"%@",resultData);
        
        for (UInt32 i=0; i<ioData->mNumberBuffers; ++i){
            //快速清空内存 ---- 是否外放声音
            memset(ioData->mBuffers[i].mData, 0, ioData->mBuffers[i].mDataByteSize);
        }
    }
    
    return err;
}

@interface AudioManager ()
{
    AudioStreamBasicDescription _audioFormat;
}
@property (nonatomic, assign) AudioUnit rioUnit;
@property (nonatomic, assign) AudioBufferList bufferList;
@end

@implementation AudioManager

//+ (AudioManager *)sharedManager
//{
//    static AudioManager *manager;
//    static dispatch_once_t once_t;
//    dispatch_once(&once_t, ^{
//        manager = [[AudioManager alloc] init];
//    });
//    return manager;
//}

- (instancetype)init
{
    self = [super init];
    if (self) {
        [self initRecordSession];
        [self initAudio];
        
        _resultData = [[NSMutableData alloc] init];
        curRioUnit = self.rioUnit;
        _manager = self;
    }
    return self;
}

-(void)initRecordSession
{
    AVAudioSession *session = [AVAudioSession sharedInstance];
    [session setCategory:AVAudioSessionCategoryPlayAndRecord error:nil];
    [session setActive:YES error:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(audioRouteChangeListenerCallback:) name:AVAudioSessionRouteChangeNotification object:nil];
}

- (void)initAudio
{
    OSStatus status;
    //    AudioComponentInstance audioUnit;
    
    // Describe audio component
    AudioComponentDescription desc;
    desc.componentType = kAudioUnitType_Output;
    desc.componentSubType = kAudioUnitSubType_RemoteIO;
    desc.componentManufacturer = kAudioUnitManufacturer_Apple;
    desc.componentFlags = 0;
    desc.componentFlagsMask = 0;
    
    // Get component
    AudioComponent inputComponent = AudioComponentFindNext(NULL, &desc);
    
    // Get audio units
    status = AudioComponentInstanceNew(inputComponent, &_rioUnit);
    //checkStatus(status);
    
    // Enable IO for recording
    UInt32 flag = 1;
    status = AudioUnitSetProperty(_rioUnit,
                                  kAudioOutputUnitProperty_EnableIO,
                                  kAudioUnitScope_Input,
                                  kInputBus,
                                  &flag,
                                  sizeof(flag));
    //checkStatus(status);
    
    // Enable IO for playback
    status = AudioUnitSetProperty(_rioUnit,
                                  kAudioOutputUnitProperty_EnableIO,
                                  kAudioUnitScope_Output,
                                  kOutputBus,
                                  &flag,
                                  sizeof(flag));
    //checkStatus(status);
    
    // Describe format
    _audioFormat.mSampleRate		= 44100;
    _audioFormat.mFormatID			= kAudioFormatLinearPCM;
    _audioFormat.mFormatFlags		= kLinearPCMFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    _audioFormat.mFramesPerPacket	= 1;
    _audioFormat.mChannelsPerFrame	= 1;
    _audioFormat.mBitsPerChannel	= 16;
    _audioFormat.mBytesPerFrame		= (_audioFormat.mBitsPerChannel / 8) * _audioFormat.mChannelsPerFrame;
    _audioFormat.mBytesPerPacket	= _audioFormat.mBytesPerFrame;
    
    // Apply format
    status = AudioUnitSetProperty(_rioUnit,
                                  kAudioUnitProperty_StreamFormat,
                                  kAudioUnitScope_Output,
                                  kInputBus,
                                  &_audioFormat,
                                  sizeof(_audioFormat));
    //checkStatus(status);
    status = AudioUnitSetProperty(_rioUnit,
                                  kAudioUnitProperty_StreamFormat,
                                  kAudioUnitScope_Input,
                                  kOutputBus,
                                  &_audioFormat,
                                  sizeof(_audioFormat));
    //checkStatus(status);
    
    // Set input callback
    AURenderCallbackStruct renderCallback;
    renderCallback.inputProc = recordingCallback;
    renderCallback.inputProcRefCon = NULL;
    status = AudioUnitSetProperty(_rioUnit,
                                  kAudioUnitProperty_SetRenderCallback,
                                  kAudioUnitScope_Input,
                                  kOutputBus,
                                  &renderCallback,
                                  sizeof(renderCallback));
    //checkStatus(status);
    
    // TODO: Allocate our own buffers if we want
    
    // Initialise
    status = AudioUnitInitialize(_rioUnit);
    //checkStatus(status);
}

- (void)startRecordingAudio
{
    if ([self.delegate respondsToSelector:@selector(audioStartRecording)]) {
        [self.delegate audioStartRecording];
    }
    
    AVAudioSession *session = [AVAudioSession sharedInstance];
    [session setCategory:AVAudioSessionCategoryPlayAndRecord error:nil];
    [session setActive:YES error:nil];
    
    OSStatus err = AudioOutputUnitStart(_rioUnit);
    if (err) NSLog(@"couldn't start AURemoteIO: %d", (int)err);
}

- (void)startRecordingData
{
    if (_resultData.length > 0) {
        [_resultData resetBytesInRange:NSMakeRange(0, _resultData.length)];
        [_resultData setLength:0];
    }
}

- (void)stopRecording
{
    AVAudioSession *session = [AVAudioSession sharedInstance];
    [session setCategory:AVAudioSessionCategoryPlayback error:nil];  //此处需要恢复设置回放标志，否则会导致其它播放声音也会变小
    [session setActive:YES error:nil];
    
    OSStatus err = AudioOutputUnitStop(_rioUnit);
    if (err) NSLog(@"couldn't start AURemoteIO: %d", (int)err);
}

- (void)endRecording
{
    if ([self.delegate respondsToSelector:@selector(audioEndRecording)]) {
        [self.delegate audioEndRecording];
    }
    
    [self saveAudioPCMToMP3];
}

- (void)saveAudioPCMToMP3
{
//    NSString *doc =[NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask, YES) lastObject];
//    NSString *fileName = [doc stringByAppendingPathComponent:@"curAudio.pcm"];
//    NSFileManager *fileManager = [NSFileManager defaultManager];
//    [fileManager createFileAtPath:fileName contents:_resultData attributes:nil];
    
    //获取当前系统时间戳，作为文件名
    NSString *userPhone = [[NSUserDefaults standardUserDefaults] objectForKey:@""];
    NSString *doc =[NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask, YES)  lastObject];
    NSString *fileNameSuperPath = [doc stringByAppendingPathComponent:[NSString stringWithFormat:@"%@",userPhone]];
    NSFileManager *fileManager = [NSFileManager defaultManager];
    if (![fileManager fileExistsAtPath:fileNameSuperPath]) {
        [fileManager createDirectoryAtPath:fileNameSuperPath withIntermediateDirectories:YES attributes:nil error:nil];
    }
    NSString *fileName = [doc stringByAppendingPathComponent:[NSString stringWithFormat:@"%@/curAudio.pcm",userPhone]];
    [fileManager createFileAtPath:fileName contents:_resultData attributes:nil];
    
    NSDate *date = [NSDate date];
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    [formatter setDateFormat:@"yyyyMMddhhmmssSSS"];
    NSString *MP3FileName = [NSString stringWithFormat:@"%@.mp3",[formatter stringFromDate:date]];
    NSString *mp3Path = [doc stringByAppendingPathComponent:[NSString stringWithFormat:@"%@/%@",userPhone,MP3FileName]];
    
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        // 处理耗时操作的代码块...
        BOOL success = [self audio_PCMtoMP3From:fileName to:mp3Path];
        if (success) {
            NSLog(@"转为mp3成功");
            [_resultData resetBytesInRange:NSMakeRange(0, _resultData.length)];
            [_resultData setLength:0];
            
            dispatch_async(dispatch_get_main_queue(), ^{
                //回调或者说是通知主线程刷新，
                if ([self.delegate respondsToSelector:@selector(audioSaveFinishedCompleteWithMP3FileName:)]) {
                    [self.delegate audioSaveFinishedCompleteWithMP3FileName:MP3FileName];
                }
            });
        }
        else
        {
            NSLog(@"转为mp3失败,正在重试");
            [self saveAudioPCMToMP3];
        }
    });
}

/*pcm转MP3，依赖于lame*/
- (BOOL)audio_PCMtoMP3From:(NSString *)filePath to:(NSString *)mp3FilePath
{
    BOOL isSuccess = NO;
    if (filePath == nil  || mp3FilePath == nil){
        return isSuccess;
    }
    NSFileManager* fileManager=[NSFileManager defaultManager];
    if([fileManager removeItemAtPath:mp3FilePath error:nil])
    {
        NSLog(@"删除");
    }
    
    @try {
        int read, write;
        
        FILE *pcm = fopen([filePath cStringUsingEncoding:1], "rb");     //source 被转换的音频文件位置
        fseek(pcm, 4*1024, SEEK_CUR);                                   //skip file header
        FILE *mp3 = fopen([mp3FilePath cStringUsingEncoding:1], "wb");  //output 输出生成的Mp3文件位置
        
        const int PCM_SIZE = 8192;
        const int MP3_SIZE = 8192;
        short int pcm_buffer[PCM_SIZE*2];
        unsigned char mp3_buffer[MP3_SIZE];
        
        lame_t lame = lame_init();
        lame_set_in_samplerate(lame, 44100);
        lame_set_VBR(lame, vbr_default);
        lame_init_params(lame);
        
        do {
            read = (int)fread(pcm_buffer, sizeof(short int), PCM_SIZE, pcm);
            if (read == 0)
                write = lame_encode_flush(lame, mp3_buffer, MP3_SIZE);
            else
                write = lame_encode_buffer(lame, pcm_buffer, pcm_buffer, read, mp3_buffer, MP3_SIZE);
            //write = lame_encode_buffer_interleaved(lame, pcm_buffer, read, mp3_buffer, MP3_SIZE);
            
            fwrite(mp3_buffer, write, 1, mp3);
            
        } while (read != 0);
        
        lame_close(lame);
        fclose(mp3);
        fclose(pcm);
        isSuccess = YES;
        
        if([fileManager removeItemAtPath:filePath error:nil])
        {
            NSLog(@"删除pcm文件");
        }
    }
    @catch (NSException *exception) {
        NSLog(@"error");
    }
    @finally {
        return isSuccess;
    }
}

- (BOOL)isConnectingHeadPhoneJack
{
    AVAudioSessionRouteDescription* route = [[AVAudioSession sharedInstance] currentRoute];
    for (AVAudioSessionPortDescription* desc in [route outputs]) {
        if ([[desc portType] isEqualToString:AVAudioSessionPortHeadphones])
            return YES;
    }
    return NO;
}

- (void)audioRouteChangeListenerCallback:(NSNotification *)notification
{
    NSDictionary *interuptionDict = notification.userInfo;
    NSInteger routeChangeReason = [[interuptionDict valueForKey:AVAudioSessionRouteChangeReasonKey] integerValue];
    switch (routeChangeReason) {
        case AVAudioSessionRouteChangeReasonNewDeviceAvailable:
        {
            NSLog(@"耳机插入");
            if ([self.delegate respondsToSelector:@selector(headPhoneState:)]) {
                [self.delegate headPhoneState:YES];
            }
        }
            break;
        case AVAudioSessionRouteChangeReasonOldDeviceUnavailable:
        {
            NSLog(@"耳机拔出");
            if ([self.delegate respondsToSelector:@selector(headPhoneState:)]) {
                [self.delegate headPhoneState:NO];
            }
        }
            break;
            
        default:
            break;
    }
}

- (void)resetAudioWaver
{
    if ([self.delegate respondsToSelector:@selector(audioVolume:)]) {
        [self.delegate audioVolume:0];
    }
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

@end
