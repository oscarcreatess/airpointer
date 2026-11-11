// ClosedCaseMotion: streams the AirPods' motion to the app while they sit in the
// closed case, for the one paired target, through the installed framework's own client.
// --pointer-session runs until the app stops it. Its case traffic only keeps the
// earbud stream open, and it reads no asset (see WHY THE HELPER TOUCHES MTIC AT ALL).
// Each renewal requires a verified receipt; renewal stops when an offer appears.
// Releasing a held asset may consume the case's staged analytics records.
// No LOGS, SYNC, firmware offers, console, model, configuration or security writes.
//
// EXIT CODES. Stable: the app maps them to plain messages. 0 is success.
// Every exit path runs the same cleanup first (sensor STOP, then release of a
// held case MTIC asset, then the ordinary link check), including on signals.
//    0 OK                   Stopped on request (phase.txt "stop").
//    2 USAGE                Wrong arguments.
//    3 INCOMPLETE           The session ended with no stop request and no other cause.
//   10 CAPTURE_DIR          Capture directory already exists or could not be created.
//   11 CAPTURE_WRITE        status.json could not be written.
//   12 TARGET_FILE          The target address file is missing or empty.
//   20 BT_NOT_AUTHORIZED    CBManager.authorization is not allowedAlways (read only, never prompts).
//   21 BT_UNAVAILABLE       The Classic Bluetooth manager did not reach powered-on within 8 s.
//   22 TARGET_NOT_PAIRED    The target address is not among this Mac's paired devices.
//   23 TARGET_NOT_CONNECTED The target is paired but was not connected when the helper started.
//   24 PRIVATE_API_MISSING  A private IOBluetooth/CoreBluetooth class or method is missing (macOS changed).
//   25 CHANNEL_BUSY         Another local client already owns the peer's L2CAP callback.
//   26 RECONNECT_FAILED     The helper closed the ordinary link and could not reopen it (3 tries ~1 s apart).
//   27 CHANNEL_NOT_OBTAINED No usable AACP channel (PSM 0x1001) within 10 s of the reconnect.
//   28 NO_SESSION_REPLY     The channel opened but the AirPods answered nothing to the session setup.
//   30 BASELINE_UNAVAILABLE No fresh accelerometer+gyro within 15 s with the lid open. AirPods also
//                           connected to an iPhone do this: setup answered, then no motion or UARP.
//   31 IDENTITY_UNAVAILABLE The earbud never confirmed its identity (root Model/VERSION).
//   32 WRONG_EARBUD_MODEL   The earbud's firmware ModelName is not AirPods Pro or AirPods 4.
//   34 WRONG_CASE_MODEL     Endpoint 1's firmware ModelName is not an AirPods charging case.
//   35 CASE_LOST            The case endpoint announced itself unreachable.
//   36 CASE_DECLINED        The case refused or rejected the diagnostic (MTIC) request.
//   40 REPLY_TIMEOUT        An expected earbud or case reply did not arrive in time.
//   41 UNEXPECTED_REPLY     A malformed, replayed or out-of-order reply; stopped for safety.
//   42 WRITE_FAILED         A write to the AirPods failed, or its request budget was exhausted.
//   43 MOTION_STALE         Accelerometer/gyro stopped arriving for more than 3 s.
//   44 INPUT_ENDED          The AirPods channel ended (the link dropped), including when that
//                           first showed up as a failed write.
//   45 SENSOR_STOP_FAILED   The session ended but a sensor STOP write failed.
//   46 RELEASE_UNCONFIRMED  The session ended but the case did not acknowledge releasing its held MTIC asset.
//   50 LEASE_EXPIRED        The app's app-lease.txt heartbeat went stale (more than 5 s old).
//   51 MOTION_PIPE_CLOSED   The app's motion pipe (stdout) closed or a write to it failed.
//   52 SIGNALED             SIGTERM, SIGINT or SIGHUP; cleanup ran before exit.
//   53 CLEANUP_TIMEOUT      Still running 30 s after the first signal (main thread stuck,
//                           e.g. in a synchronous Bluetooth call); exited without finishing cleanup.
// The first cause wins: a later cleanup problem never replaces it.
#import <Foundation/Foundation.h>
// H1 uses the system motion API and shared output and exit handling, without AACP or MTIC keep-alive.
// Additional H1 exit codes: 54 for motion permission, 55 for no initial motion, 56 for another connected headset.
#import <IOBluetooth/IOBluetooth.h>
#import <CoreBluetooth/CoreBluetooth.h>
#import <fcntl.h>
#import <unistd.h>
#import <signal.h>
#import <math.h>
#import <stdatomic.h>
#import <spawn.h>
#import <sys/wait.h>
#import <crt_externs.h>

enum {
    HelperExitOK=0,HelperExitUsage=2,HelperExitIncomplete=3,
    HelperExitCaptureDir=10,HelperExitCaptureWrite=11,HelperExitTargetFile=12,
    HelperExitBluetoothNotAuthorized=20,HelperExitBluetoothUnavailable=21,HelperExitTargetNotPaired=22,
    HelperExitTargetNotConnected=23,HelperExitPrivateAPIMissing=24,HelperExitChannelBusy=25,
    HelperExitReconnectFailed=26,HelperExitChannelNotObtained=27,HelperExitNoSessionReply=28,
    HelperExitBaselineUnavailable=30,HelperExitIdentityUnavailable=31,HelperExitWrongEarbudModel=32,
    HelperExitWrongCaseModel=34,HelperExitCaseLost=35,HelperExitCaseDeclined=36,
    HelperExitReplyTimeout=40,HelperExitUnexpectedReply=41,HelperExitWriteFailed=42,HelperExitMotionStale=43,
    HelperExitInputEnded=44,HelperExitSensorStopFailed=45,HelperExitReleaseUnconfirmed=46,
    HelperExitLeaseExpired=50,HelperExitMotionPipeClosed=51,HelperExitSignaled=52,HelperExitCleanupTimeout=53,
    HelperExitMotionNotAuthorized=54,HelperExitHeadphoneBaselineUnavailable=55,HelperExitMotionSourceAmbiguous=56,
};
typedef struct {int code;const char *name;const char *meaning;} HelperExitInfo;
static const HelperExitInfo helperExitTable[]={
    {HelperExitMotionNotAuthorized,"MOTION_NOT_AUTHORIZED","headphone motion permission not granted"},
    {HelperExitHeadphoneBaselineUnavailable,"HEADPHONE_BASELINE_UNAVAILABLE","no headphone motion; check ear detection and lift an earbud"},
    {HelperExitMotionSourceAmbiguous,"MOTION_SOURCE_AMBIGUOUS","another headset is connected"},
    {HelperExitOK,"OK","stopped on request"},
    {HelperExitUsage,"USAGE","wrong arguments"},
    {HelperExitIncomplete,"INCOMPLETE","session ended with no stop request or other cause"},
    {HelperExitCaptureDir,"CAPTURE_DIR","capture directory exists or could not be created"},
    {HelperExitCaptureWrite,"CAPTURE_WRITE","a capture file could not be written"},
    {HelperExitTargetFile,"TARGET_FILE","target address file missing or empty"},
    {HelperExitBluetoothNotAuthorized,"BT_NOT_AUTHORIZED","Bluetooth permission not granted"},
    {HelperExitBluetoothUnavailable,"BT_UNAVAILABLE","Bluetooth manager not powered on"},
    {HelperExitTargetNotPaired,"TARGET_NOT_PAIRED","target AirPods not paired"},
    {HelperExitTargetNotConnected,"TARGET_NOT_CONNECTED","target AirPods not connected"},
    {HelperExitPrivateAPIMissing,"PRIVATE_API_MISSING","a private Bluetooth API is missing"},
    {HelperExitChannelBusy,"CHANNEL_BUSY","another local client owns the L2CAP callback"},
    {HelperExitReconnectFailed,"RECONNECT_FAILED","closed ordinary link could not be reopened"},
    {HelperExitChannelNotObtained,"CHANNEL_NOT_OBTAINED","no AACP channel was obtained"},
    {HelperExitNoSessionReply,"NO_SESSION_REPLY","AACP channel opened but nothing answered"},
    {HelperExitBaselineUnavailable,"BASELINE_UNAVAILABLE","no fresh open-lid motion"},
    {HelperExitIdentityUnavailable,"IDENTITY_UNAVAILABLE","earbud identity not confirmed"},
    {HelperExitWrongEarbudModel,"WRONG_EARBUD_MODEL","earbud ModelName is not AirPods Pro or AirPods 4"},
    {HelperExitWrongCaseModel,"WRONG_CASE_MODEL","endpoint is not an AirPods charging case"},
    {HelperExitCaseLost,"CASE_LOST","charging case became unreachable"},
    {HelperExitCaseDeclined,"CASE_DECLINED","case declined the diagnostic request"},
    {HelperExitReplyTimeout,"REPLY_TIMEOUT","an expected reply timed out"},
    {HelperExitUnexpectedReply,"UNEXPECTED_REPLY","malformed, replayed or unexpected reply"},
    {HelperExitWriteFailed,"WRITE_FAILED","a write to the AirPods failed"},
    {HelperExitMotionStale,"MOTION_STALE","motion stopped arriving"},
    {HelperExitInputEnded,"INPUT_ENDED","AirPods channel ended"},
    {HelperExitSensorStopFailed,"SENSOR_STOP_FAILED","a sensor STOP write failed"},
    {HelperExitReleaseUnconfirmed,"RELEASE_UNCONFIRMED","case did not confirm releasing its held asset"},
    {HelperExitLeaseExpired,"LEASE_EXPIRED","app heartbeat expired"},
    {HelperExitMotionPipeClosed,"MOTION_PIPE_CLOSED","app motion pipe closed"},
    {HelperExitSignaled,"SIGNALED","terminated by a signal after cleanup"},
    {HelperExitCleanupTimeout,"CLEANUP_TIMEOUT","cleanup did not finish within 30 s of a signal; exited without it"},
};
static const HelperExitInfo *helperExitInfo(int code) {
    for(size_t i=0;i<sizeof(helperExitTable)/sizeof(helperExitTable[0]);i++) if(helperExitTable[i].code==code) return &helperExitTable[i];
    return NULL;
}

static BOOL motionOnStdout=NO;
// Session stdout is a bounded OS pipe carrying only motion rows.
#define printf(...) fprintf(motionOnStdout ? stderr : stdout, __VA_ARGS__)
#define puts(message) fprintf(motionOnStdout ? stderr : stdout,"%s\n",message)

// SIGTERM/SIGINT/SIGHUP only set this flag (from a private queue, so it is
// recorded even while the main thread is inside a synchronous Bluetooth call).
// The main thread notices it within one 20-50 ms pump and runs the ordinary
// cleanup path with shortened waits, then returns SIGNALED.
// The app sends one SIGTERM, 3 s after a stop. Only the first signal counts, so
// a repeat from anywhere else never cuts the cleanup short. Because SIGTERM no longer kills the process outright, a
// watchdog armed by that first signal exits with CLEANUP_TIMEOUT if the main
// thread is still busy 30 s later (longer than the worst-case link restore of
// about 23 s, so it only fires when the main thread is really stuck).
static _Atomic int terminationSignal=0;
static _Atomic unsigned long terminationEpoch=0;
static double terminationNoticedAt=0;
static double terminationWatchdogSeconds=30;
static NSMutableArray *terminationSources;
static void installTerminationHandlers(void) {
    if(terminationSources) return;
    terminationSources=NSMutableArray.array;
    dispatch_queue_t queue=dispatch_queue_create("airpointer.closed-case.signals",DISPATCH_QUEUE_SERIAL);
    const int signals[]={SIGTERM,SIGINT,SIGHUP};
    for(size_t i=0;i<sizeof(signals)/sizeof(signals[0]);i++) {
        int number=signals[i];signal(number,SIG_IGN);
        dispatch_source_t source=dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL,(uintptr_t)number,0,queue);
        dispatch_source_set_event_handler(source,^{
            unsigned long epoch=atomic_load(&terminationEpoch);double limit=terminationWatchdogSeconds;int expected=0;
            if(!atomic_compare_exchange_strong(&terminationSignal,&expected,number)) return;
            fprintf(stderr,"Received signal %d; stopping sensors and releasing the case before exit\n",number);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(limit*NSEC_PER_SEC)),queue,^{
                if(atomic_load(&terminationEpoch)!=epoch || atomic_load(&terminationSignal)!=number) return;
                dprintf(motionOnStdout?STDERR_FILENO:STDOUT_FILENO,"EXIT code=%d CLEANUP_TIMEOUT: still running %g s after signal %d; exiting without finishing cleanup. If motion or the AirPods connection misbehaves, turn Bluetooth off and on.\n",HelperExitCleanupTimeout,limit,number);
                _exit(HelperExitCleanupTimeout);
            });
        });
        dispatch_resume(source);[terminationSources addObject:source];
    }
}
// Self-test only: forget a raised signal and disarm its watchdog.
static void resetTerminationForTest(void) {
    atomic_fetch_add(&terminationEpoch,1);atomic_store(&terminationSignal,0);terminationNoticedAt=0;
}
static BOOL terminationRequested(void) {
    if(!atomic_load(&terminationSignal)) return NO;
    if(!terminationNoticedAt) terminationNoticedAt=NSProcessInfo.processInfo.systemUptime;
    return YES;
}

@interface NSObject (ClassicTrace)
+ (id)sharedInstance;
- (id)classicManager;
- (id)peer;
- (id)manager;
- (NSInteger)state;
- (NSInteger)internalState;
- (id)connectL2CAPCallback;
- (void)setConnectL2CAPCallback:(void (^)(id, NSInteger))callback;
- (void)openL2CAPChannel:(BluetoothL2CAPPSM)psm;
- (void)closeL2CAPChannel:(BluetoothL2CAPPSM)psm;
@end

static BOOL readVarint(NSData *data, NSUInteger *index, uint64_t *value) {
    const uint8_t *b=data.bytes;*value=0;
    for(unsigned shift=0;shift<64;shift+=7) {
        if(*index>=data.length) return NO;uint8_t byte=b[(*index)++];
        if(shift==63 && byte>1) return NO;
        *value|=(uint64_t)(byte&127)<<shift;if(!(byte&128)) return YES;
    }return NO;
}
static NSArray *wireFields(NSData *data) {
    NSMutableArray *fields=NSMutableArray.array;NSUInteger index=0;
    while(index<data.length) {
        uint64_t key,value;if(!readVarint(data,&index,&key) || !(key>>3)) break;
        if((key&7)==0) {if(!readVarint(data,&index,&value)) break;[fields addObject:@{@"number":@(key>>3),@"value":@(value)}];}
        else if((key&7)==2) {
            if(!readVarint(data,&index,&value) || value>data.length-index) break;
            [fields addObject:@{@"number":@(key>>3),@"bytes":[data subdataWithRange:NSMakeRange(index,(NSUInteger)value)]}];index+=(NSUInteger)value;
        } else if((key&7)==1 || (key&7)==5) {NSUInteger n=(key&7)==1?8:4;if(n>data.length-index) break;index+=n;}
        else break;
    }return fields;
}
static uint32_t le32(const uint8_t *b) {return (uint32_t)b[0] | (uint32_t)b[1]<<8 | (uint32_t)b[2]<<16 | (uint32_t)b[3]<<24;}
@interface ConsoleReader : NSObject <NSStreamDelegate>
@property(nonatomic,assign) FILE *motionStream;
@property BOOL motionStreamFailed;
@property NSMutableData *buffer;
@property NSUInteger scanned, chunks, controls;
@property NSMutableArray *uarpMessages;
@property NSMutableArray *earbudStateEvents;
@property NSString *phase;
@property NSMutableDictionary *lastSamples;
@property NSUInteger accelReports,gyroReports,accelFresh,gyroFresh;
@end
@implementation ConsoleReader
- (instancetype)init { if ((self = [super init])) { self.buffer = NSMutableData.data; self.uarpMessages = NSMutableArray.array;self.earbudStateEvents=NSMutableArray.array;self.lastSamples=NSMutableDictionary.dictionary;self.phase=@"open_baseline"; } return self; }
- (void)stream:(NSStream *)stream handleEvent:(NSStreamEvent)event {
    if (event == NSStreamEventErrorOccurred) {
        printf("Input stream error code=%ld\n", (long)stream.streamError.code); return;
    }
    if (event != NSStreamEventHasBytesAvailable) return;
    NSInputStream *input = (NSInputStream *)stream;
    while (input.hasBytesAvailable) {
        uint8_t bytes[16384]; NSInteger n = [input read:bytes maxLength:sizeof(bytes)];
        if (n <= 0) break;
        self.chunks++;
        NSData *chunk = [NSData dataWithBytes:bytes length:n];
        // Other AACP traffic can contain device identity: keep it only in memory.
        [self.buffer appendData:chunk];

        if (self.buffer.length > 262144) { puts("Capture size limit reached"); [input close]; return; }
        const uint8_t *b = self.buffer.bytes; NSUInteger count = self.buffer.length;
        while (self.scanned + 6 <= count) {
            NSUInteger i = self.scanned;
            if (memcmp(b+i, "\x04\x00\x04\x00", 4)) { self.scanned++; continue; }
            uint16_t opcode = b[i+4] | b[i+5] << 8;
            if (opcode == 0x4f) {
                if (i + 8 > count) break;
                NSUInteger size = b[i+6] | b[i+7]<<8;
                if (size > 32768) { self.scanned++; continue; }
                if (i + 8 + size > count) break;
                if (size >= 6) {
                    const uint8_t *u = b+i+8;
                    uint16_t type = u[0]<<8 | u[1], length = u[2]<<8 | u[3], identifier = u[4]<<8 | u[5];
                    if (size == (NSUInteger)length + 6) {
                        NSData *data = [NSData dataWithBytes:u length:size];
                        if(type==0x1b && length>=8) {
                            const uint8_t *c=u+6;uint16_t endpoint=(uint16_t)c[0]<<8|c[1], childType=(uint16_t)c[2]<<8|c[3];
                            uint16_t childLength=(uint16_t)c[4]<<8|c[5], childID=(uint16_t)c[6]<<8|c[7];
                            if((NSUInteger)childLength+8==length) {
                                const char *fourCC="";
                                if(childType==5 && childLength>=4) {
                                    if(!memcmp(c+8,"MTIC",4)) fourCC=" MTIC";
                                    else if(!memcmp(c+8,"LOGS",4)) fourCC=" LOGS";
                                    else fourCC=" other_asset";
                                }
                                printf("CASE HEADER RX uptime=%.6f endpoint=%u type=%u ID=%u body=%u%s\n",NSProcessInfo.processInfo.systemUptime,endpoint,childType,childID,childLength,fourCC);
                            }
                        }
                        [self.uarpMessages addObject:data];
                        printf("UARP RX uptime=%.6f type=%u length=%u ID=%u\n",NSProcessInfo.processInfo.systemUptime,type,length,identifier);
                        // Keep UARP payloads in memory only; analytics may contain device identifiers.
                    }
                }
                self.controls++; self.scanned += 8 + size;
            } else if (opcode == 0x06) {
                // Ordinary two-byte primary/secondary location notification.
                // Retain raw codes; do not infer left/right or a case-lid state here.
                // status.json carries them to the app, which follows the lid from them.
                if(i+8>count) break;
                double now=NSProcessInfo.processInfo.systemUptime;
                if(self.earbudStateEvents.count<1024) [self.earbudStateEvents addObject:@{@"received_uptime":@(now),@"primary_code":@(b[i+6]),@"secondary_code":@(b[i+7])}];
                printf("EARBUD STATE RX uptime=%.6f primary_code=%u secondary_code=%u\n",now,b[i+6],b[i+7]);
                self.controls++;self.scanned+=8;
            } else if (opcode == 0x17) {
                if (i + 12 > count) break;
                uint32_t descriptor = b[i+6] | b[i+7]<<8 | b[i+8]<<16 | (uint32_t)b[i+9]<<24;
                NSUInteger size = b[i+10] | b[i+11]<<8;
                if (i + 12 + size > count) break;
                if(descriptor==0x100000) {
                    NSData *payload=[NSData dataWithBytes:b+i+12 length:size];
                    for(NSDictionary *outer in wireFields(payload)) if([outer[@"number"] unsignedIntValue]==7 && outer[@"bytes"]) {
                        NSNumber *service=nil;NSData *report=nil;
                        for(NSDictionary *field in wireFields(outer[@"bytes"])) {
                            if([field[@"number"] unsignedIntValue]==1) service=field[@"value"];
                            if([field[@"number"] unsignedIntValue]==3) report=field[@"bytes"];
                        }
                        if(([service unsignedIntValue]==11 || [service unsignedIntValue]==12) && report.length==28) {
                            const uint8_t *r=report.bytes;uint64_t stamp=le32(r+20) | (uint64_t)le32(r+24)<<32;
                            if(r[0]==1 && stamp>0) {
                                NSDictionary *previous=self.lastSamples[service.stringValue];
                                BOOL fresh=!previous || stamp>[previous[@"sensor_us"] unsignedLongLongValue];
                                NSDictionary *row=@{@"sensor_us":@(stamp),@"received_uptime":@(NSProcessInfo.processInfo.systemUptime),
                                    @"x":@((int32_t)le32(r+1)),@"y":@((int32_t)le32(r+5)),@"z":@((int32_t)le32(r+9))};
                                if(fresh) self.lastSamples[service.stringValue]=row;
                                if(service.unsignedIntValue==11){self.accelReports++;if(fresh)self.accelFresh++;}
                                else{self.gyroReports++;if(fresh)self.gyroFresh++;}
                                NSUInteger sequence=self.accelReports+self.gyroReports;
                                if(fresh && self.motionStream && fprintf(self.motionStream,"%lu,%u,%llu,%.9f,%d,%d,%d\n",(unsigned long)sequence,service.unsignedIntValue,(unsigned long long)stamp,[row[@"received_uptime"] doubleValue],[row[@"x"] intValue],[row[@"y"] intValue],[row[@"z"] intValue])<0) self.motionStreamFailed=YES;
                            }
                        }
                    }
                }
                self.controls++; self.scanned += 12 + size;
            } else {
                if (opcode==2 || opcode==4 || opcode==6 || opcode==8 || opcode==12 || opcode==14 || opcode==43 || opcode==46 || opcode==79) self.controls++;
                self.scanned += 6;
            }
        }
        if(self.scanned) { [self.buffer replaceBytesInRange:NSMakeRange(0,self.scanned) withBytes:NULL length:0];self.scanned=0; }
    }
}
@end

static void pump(double seconds) {
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:seconds]];
}
static double operationDeadline=0;
static double cleanupStartedAt=0;
// A stream the link has closed under us. Writing to it can never succeed, and
// it may never report space again, so writers and the session loop stop at once.
static BOOL streamEnded(NSStream *stream) {
    NSStreamStatus status=stream.streamStatus;
    return status==NSStreamStatusError || status==NSStreamStatusAtEnd || status==NSStreamStatusClosed;
}
static BOOL sendPacket(NSOutputStream *output, NSData *data, const char *label) {
    double now=NSProcessInfo.processInfo.systemUptime;
    double deadline=now+3;
    if(operationDeadline>0) deadline=MIN(deadline,operationDeadline);
    // After a signal every write shares one ~2 s budget. A cleanup write
    // (sensor STOP, Abandon) still gets a short try of its own, even when a
    // blocked write before the cleanup used that whole budget.
    if(terminationRequested()) {
        deadline=MIN(deadline,terminationNoticedAt+2);
        if(cleanupStartedAt>0) deadline=MAX(deadline,now+.25);
    }
    NSUInteger sent = 0;
    while (sent < data.length && NSProcessInfo.processInfo.systemUptime<deadline) {
        if (streamEnded(output)) break;
        if (!output.hasSpaceAvailable) { pump(.02); continue; }
        NSInteger n = [output write:(const uint8_t *)data.bytes + sent maxLength:data.length-sent];
        if (n <= 0) break;
        sent += n;
    }
    printf("Send %s: bytes=%lu/%lu\n",label,sent,data.length);
    return sent == data.length;
}
static NSData *packet(const uint8_t *bytes, NSUInteger count) { return [NSData dataWithBytes:bytes length:count]; }
// Sessions that got motion had seen seven or more reads before the sensors started; the old fixed wait is the limit.
static void receiveUntilAnswered(ConsoleReader *reader, NSInputStream *input, double least, NSUInteger reads, double most) {
    double began=NSProcessInfo.processInfo.systemUptime,waited=0;
    while (!terminationRequested()) {
        waited=NSProcessInfo.processInfo.systemUptime-began;
        if (waited>=most || (waited>=least && reader.controls && reader.chunks>=reads)) break;
        pump(.05);
        if (input.hasBytesAvailable) [reader stream:input handleEvent:NSStreamEventHasBytesAvailable];
    }
    printf("Input status=%lu output received chunks=%lu after %.2f s\n",(unsigned long)input.streamStatus, reader.chunks, waited);
}
static void step(const char *name) {printf("STEP %s uptime=%.3f\n",name,NSProcessInfo.processInfo.systemUptime);}
static uint16_t be16(const uint8_t *p) { return p[0]<<8 | p[1]; }

static BOOL sendUARPPacket(NSOutputStream *output, uint16_t type, uint16_t identifier, NSData *body) {
    if(body.length>65529) return NO;
    uint16_t ulen=(uint16_t)(6+body.length), len=(uint16_t)body.length;
    uint8_t header[]={4,0,4,0,0x4f,0,(uint8_t)ulen,(uint8_t)(ulen>>8),
        (uint8_t)(type>>8),(uint8_t)type,(uint8_t)(len>>8),(uint8_t)len,(uint8_t)(identifier>>8),(uint8_t)identifier};
    NSMutableData *data=[NSMutableData dataWithBytes:header length:sizeof(header)]; [data appendData:body];
    printf("UARP TX uptime=%.6f type=%u ID=%u body=%lu\n",NSProcessInfo.processInfo.systemUptime,type,identifier,body.length);
    return sendPacket(output,data,"verified UARP request");
}
static uint32_t be32(const uint8_t *p) { return (uint32_t)p[0]<<24 | (uint32_t)p[1]<<16 | (uint32_t)p[2]<<8 | p[3]; }
static NSData *uarpMessage(uint16_t type,uint16_t identifier,NSData *body) {
    uint16_t n=(uint16_t)body.length;
    uint8_t header[]={type>>8,type,n>>8,n,identifier>>8,identifier};
    NSMutableData *message=[NSMutableData dataWithBytes:header length:6];[message appendData:body];return message;
}
static NSString *modelName(NSData *body) {
    if(body.length<10) return nil;const uint8_t *b=body.bytes;uint32_t n=be32(b+6);
    if(be16(b)!=0 || be32(b+2)!=2 || n!=body.length-10 || n>128) return nil;
    return [[NSString alloc] initWithBytes:b+10 length:n encoding:NSUTF8StringEncoding];
}
static NSDictionary *mticOffer(NSData *body) {
    if(body.length!=30) return nil;const uint8_t *b=body.bytes;
    uint16_t asset=be16(b+6);uint32_t length=be32(b+24);
    if(memcmp(b,"MTIC",4) || be16(b+4)!=0x0a || !asset || asset==0xffff || !length || length>65536) return nil;
    return @{@"asset_id":@(asset),@"asset_length":@(length)};
}
static BOOL retryInitialRootVersion(BOOL versionValid,NSUInteger sent,double age) {
    return !versionValid && sent>0 && sent<20 && age>=8;
}
// After the first valid root VERSION, the 1 s heartbeat waits for each reply.
// One lost reply used to leave it pending forever and the heartbeat stopped
// silently. Now an overdue reply is re-asked every 8 s (the startup cadence),
// at most twice; a third overdue reply (24 s of root silence) ends the session.
typedef enum {RootVersionWait=0,RootVersionResend=1,RootVersionFail=2} RootVersionAction;
static RootVersionAction steadyRootVersionAction(BOOL versionValid,BOOL pending,NSUInteger unansweredSends,double age) {
    if(!versionValid || !pending || age<8) return RootVersionWait;
    return unansweredSends>=3 ? RootVersionFail:RootVersionResend;
}
// Both names come from UARP AccessoryInformation property 2 (ModelName), which
// the firmware answers from a fixed string. Pro 3 answers "AirPods Pro" from the
// earbud and "AirPods Charging Case" from the case; AirPods 4 answers "AirPods"
// from the earbud and "Charging Case" or, on the ANC pair, "Wireless Charging
// Case" from the case; Pro 2 MagSafe cases can also answer "MagSafe Charging Case".
// They are model strings, not the user-editable Bluetooth device name, so a
// renamed pair still matches. Compare tolerantly: trim, ignore case, and accept
// later model suffixes such as "AirPods Pro 3", while still telling the earbud
// and the case apart. The app only targets product IDs it knows, so this broader
// earbud match can't select an unsupported pair by name on its own. Newer cases
// (AirPods Pro 2 with USB-C) report a 29-byte name that does not start with
// "AirPods", taken to be "MagSafe Charging Case (USB-C)", so a MagSafe charging
// case is accepted too.
static NSString *foldedModelName(NSString *name) {
    NSMutableCharacterSet *trim=NSMutableCharacterSet.whitespaceAndNewlineCharacterSet;[trim formUnionWithCharacterSet:NSCharacterSet.controlCharacterSet];
    return [[name stringByTrimmingCharactersInSet:trim] lowercaseString];
}
static BOOL earbudModelMatches(NSString *name) {
    NSString *folded=foldedModelName(name);
    BOOL airPods4=[folded isEqualToString:@"airpods"] || [folded hasPrefix:@"airpods 4"];
    return ([folded hasPrefix:@"airpods pro"] || airPods4) && ![folded containsString:@"case"];
}
static BOOL chargingCaseModelMatches(NSString *name) {
    NSString *folded=foldedModelName(name);
    // Pro cases answer "AirPods Charging Case" or "MagSafe Charging Case". The
    // AirPods 4 case answers "Charging Case"; the AirPods 4 ANC case answers
    // "Wireless Charging Case".
    return [folded containsString:@"case"] &&
        ([folded hasPrefix:@"airpods"] || [folded hasPrefix:@"charging case"] ||
         [folded hasPrefix:@"wireless charging case"] || [folded hasPrefix:@"magsafe charging case"]);
}
// The ordinary link is reopened with a few spaced attempts: a single failed
// openConnection used to exit and leave a link this helper closed still down.
// waitForLink(seconds) waits up to that long and returns early once connected.
static BOOL reopenOrdinaryLink(BOOL (^connected)(void),IOReturn (^open)(void),void (^waitForLink)(double),NSUInteger attempts,double spacing,NSUInteger *made) {
    NSUInteger tries=0;
    while(!connected() && tries<attempts) {
        IOReturn result=open();tries++;
        printf("Ordinary target reopen attempt %lu/%lu=0x%08x\n",(unsigned long)tries,(unsigned long)attempts,result);
        waitForLink(spacing);
    }
    if(made) *made=tries;
    return connected();
}
// Private selectors are checked before use, so a macOS change yields
// PRIVATE_API_MISSING instead of an unrecognized-selector crash.
static NSString *missingSelector(id object,NSArray<NSString *> *names) {
    if(!object) return @"(object unavailable)";
    for(NSString *name in names) if(![object respondsToSelector:NSSelectorFromString(name)]) return name;
    return nil;
}
static NSArray<NSString *> *requiredPeerSelectors(void) {
    return @[@"connectL2CAPCallback",@"setConnectL2CAPCallback:",@"openL2CAPChannel:",@"closeL2CAPChannel:",@"manager"];
}
static BOOL sessionLeaseFresh(NSURL *url,double now) {
    NSString *text=[NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:nil];
    double stamp=text.doubleValue;
    return text.length>0 && isfinite(stamp) && stamp>0 && now>=stamp-.5 && now-stamp<5;
}
static uint16_t nextIdentifier(uint16_t current) {return current==UINT16_MAX ? 1:current+1;}
@interface CaseSnapshot : NSObject
@property NSOutputStream *output;
@property NSMutableSet<NSNumber *> *announced,*caseResponseIDs;
@property NSMutableArray<NSNumber *> *recentCaseIDs;
@property double budgetStartedAt;
@property NSUInteger windowRequests,windowBytes;
@property uint16_t nextTXID,nextChildID,assetID;
@property BOOL targetBound,rootVersionValid,rootModelSent,rootVerified,caseActive,caseVersionValid,caseModelSent,caseModelVerified,caseRouteDrained,closedWindowStarted;
@property BOOL accepted,receiptAttempted,cleanupStarted,cleanupSent,cleanupWriteComplete,cleanupAck;
@property NSUInteger startupUnknownBytes,modelSentAfterVersionFrames;
@property BOOL solicitationAttempted,solicitationSent,solicitationReceiptVerified,denialReceiptAttempted;
@property NSUInteger solicitationAttempts,solicitationReceipts;
@property double lastSolicitationAt;
@property NSString *rootIdentity,*caseIdentity,*error,*pending;
@property int failure; // Exit code paired with the first error; see the table at the top.
@property double rootModelSince,nextCaseVersionAt,pendingSince;
@property double metadataDrainSince,offerWaitSince;
@property double nextActiveIdentityAt;
@property NSUInteger identityRefreshReplies;
@property NSUInteger missedReplies;
@property NSUInteger caseVersionFrames,caseVersionReplies,caseInnerBytes,caseRequests,unconfirmedBytes;
@property NSData *offer;
@property NSData *solicitationDenial;
@property NSDictionary *offerMetadata;
@end
@implementation CaseSnapshot
- (instancetype)init {if((self=[super init])) {self.nextTXID=1;self.nextChildID=1;self.announced=NSMutableSet.set;self.caseResponseIDs=NSMutableSet.set;self.recentCaseIDs=NSMutableArray.array;}return self;}
// Records the first failure only. A later message in the same batch (or a
// cleanup problem) must not replace the cause the app and exit code report.
- (void)fail:(int)code reason:(NSString *)reason {
    if(self.error) return;
    self.error=reason;self.failure=code;
}
- (BOOL)maySolicitAt:(double)now {
    if(!self.solicitationAttempted) return YES;
    return self.solicitationReceiptVerified && self.offerWaitSince>0 && now-self.lastSolicitationAt>=1;
}
- (BOOL)initializedCaseRoute {
    if(self.caseRouteDrained) return YES;
    // A missing idempotent setup response remains explicitly budgeted. A fresh,
    // ordered exact identity reply is required; this is not a claim of draining.
    return self.caseModelVerified && self.caseVersionValid &&
        self.caseVersionFrames==2 && self.caseVersionReplies==1 &&
        self.modelSentAfterVersionFrames==self.caseVersionFrames && self.startupUnknownBytes==8;
}
- (void)confirmClosedAt:(double)now {
    if(self.closedWindowStarted) return;self.closedWindowStarted=YES;
}
- (BOOL)canSendRoot:(uint16_t)type body:(NSData *)body {
    if(!self.targetBound) return NO;const uint8_t *b=body.bytes;
    if(type==1) return body.length==2 && be16(b)==7;
    if(type==3) return self.rootVersionValid && !self.rootModelSent && body.length==4 && be32(b)==2;
    if(type==0x15) return self.rootVerified && body.length==0;
    if(type==0x18 || type==0x1a) return body.length==4 && be16(b)==0 && [self.announced containsObject:@(be16(b+2))];
    return NO;
}
- (BOOL)sendRoot:(uint16_t)type body:(NSData *)body {
    if(![self canSendRoot:type body:body]) return NO;uint16_t identifier=self.nextTXID;self.nextTXID=nextIdentifier(identifier);return sendUARPPacket(self.output,type,identifier,body);
}
- (BOOL)canSendChild:(uint16_t)type body:(NSData *)body {
    NSUInteger bytes=body.length+6;const uint8_t *b=body.bytes;
    double now=NSProcessInfo.processInfo.systemUptime;
    if(!self.budgetStartedAt || now-self.budgetStartedAt>=60){self.budgetStartedAt=now;self.windowRequests=0;self.windowBytes=0;}
    NSUInteger requests=self.windowRequests,usedBytes=self.windowBytes,requestLimit=120,byteLimit=4096;
    if(!self.closedWindowStarted) return NO;
    if(!self.targetBound || !self.rootVerified || !self.caseActive || ![self.announced containsObject:@1] ||
       requests>=requestLimit || usedBytes+bytes>byteLimit || self.unconfirmedBytes+bytes>112) return NO;
    if(type==9) return self.cleanupStarted && self.accepted && !self.cleanupSent && body.length==4 && be16(b)==self.assetID && be16(b+2)==3;
    // Keep one operation and its ten inner bytes available for scoped Abandon.
    if(requests>=requestLimit-1 || usedBytes+bytes+10>byteLimit ||
       self.unconfirmedBytes+bytes+((self.accepted || type==0x0d)?10:0)>112) return NO;
    if(type==0x14) return self.caseModelVerified && self.solicitationSent && !self.accepted && !self.cleanupStarted && !self.denialReceiptAttempted && self.solicitationDenial && [body isEqualToData:self.solicitationDenial] && body.length==6 && !memcmp(b,"MTIC",4);
    if(self.cleanupStarted || self.error || self.pending) return NO;
    if(!self.caseModelVerified && self.caseInnerBytes+bytes>112) return NO;
    if(type==1) return !self.caseModelSent && self.caseVersionFrames<2 && body.length==2 && be16(b)==7;
    if(type==3) return body.length==4 && be32(b)==2 && ((self.caseVersionValid && !self.caseModelSent) || self.accepted);
    if(type==0x11) return self.caseModelVerified && [self initializedCaseRoute] && !self.offer && !self.accepted && [self maySolicitAt:NSProcessInfo.processInfo.systemUptime] && body.length==4 && !memcmp(b,"MTIC",4);
    if(type==0x0d) return self.caseModelVerified && [self initializedCaseRoute] && self.offer && !self.receiptAttempted && [body isEqualToData:self.offer] && mticOffer(body)!=nil;
    return NO;
}
- (BOOL)sendChild:(uint16_t)type body:(NSData *)body {
    if(![self canSendChild:type body:body]) return NO;
    self.caseRequests++;self.caseInnerBytes+=body.length+6;self.unconfirmedBytes+=body.length+6;
    self.windowRequests++;self.windowBytes+=body.length+6;
    if(type==1) self.caseVersionFrames++;if(type==3) {if(!self.caseModelVerified) self.modelSentAfterVersionFrames=self.caseVersionFrames;self.caseModelSent=YES;}
    if(type==0x0d) {self.receiptAttempted=YES;self.assetID=[self.offerMetadata[@"asset_id"] unsignedIntValue];}
    if(type==0x11) {self.solicitationAttempted=YES;self.solicitationAttempts++;self.solicitationReceiptVerified=NO;self.lastSolicitationAt=NSProcessInfo.processInfo.systemUptime;}
    if(type==0x14) self.denialReceiptAttempted=YES;
    if(type==9) self.cleanupSent=YES; // A partial write cannot authorize a second cleanup/retry.
    printf("CASE TX uptime=%.6f type=%u ID=%u bytes=%lu total_bytes=%lu\n",NSProcessInfo.processInfo.systemUptime,type,self.nextChildID,body.length+6,self.caseInnerBytes);
    uint16_t childID=self.nextChildID,rootID=self.nextTXID;self.nextChildID=nextIdentifier(childID);self.nextTXID=nextIdentifier(rootID);
    uint8_t endpoint[]={0,1};NSMutableData *outer=[NSMutableData dataWithBytes:endpoint length:2];[outer appendData:uarpMessage(type,childID,body)];
    return sendUARPPacket(self.output,0x1b,rootID,outer);
}
- (void)setPending:(NSString *)kind at:(double)now {self.pending=kind;self.pendingSince=now;}
- (void)acceptOfferIfReady {
    if(!self.caseModelVerified || ![self initializedCaseRoute] || !self.offer || self.receiptAttempted || self.pending || self.cleanupStarted || self.error) return;
    if([self sendChild:0x0d body:self.offer]) {self.accepted=YES;self.nextActiveIdentityAt=NSProcessInfo.processInfo.systemUptime+1;printf("CASE MTIC receipt ACK asset=%u length=%u; analytics may be consumed\n",self.assetID,[self.offerMetadata[@"asset_length"] unsignedIntValue]);}
    else [self fail:HelperExitWriteFailed reason:@"case MTIC receipt acknowledgement write failed"];
}
- (void)handleMessage:(NSData *)message {
    if(message.length<6 || !self.targetBound) return;const uint8_t *b=message.bytes;uint16_t type=be16(b),n=be16(b+2);
    if(message.length!=(NSUInteger)n+6) {[self fail:HelperExitUnexpectedReply reason:@"malformed UARP envelope"];return;}
    if(type==5) return;
    if(type==0x16 && (n!=2 || be16(b+6)!=0)) {[self fail:HelperExitUnexpectedReply reason:@"root discovery response failed"];return;}
    if(type==0x17 || type==0x19) {
        if(n!=2) {[self fail:HelperExitUnexpectedReply reason:@"malformed endpoint announcement"];return;}
        uint16_t endpoint=be16(b+6);if(type==0x17) [self.announced addObject:@(endpoint)];
        if([self.announced containsObject:@(endpoint)]) {uint8_t ack[]={0,0,endpoint>>8,endpoint};if(![self sendRoot:type==0x17?0x18:0x1a body:packet(ack,4)]) [self fail:HelperExitWriteFailed reason:@"endpoint receipt ACK write failed"];}
        if(endpoint==1) {self.caseActive=type==0x17;if(!self.caseActive) [self fail:HelperExitCaseLost reason:@"announced case became unreachable"];}
        return;
    }
    if(type==2) {
        if(n<4 || be16(b+6)!=0 || be16(b+8)<5 || be16(b+8)>7) {[self fail:HelperExitUnexpectedReply reason:@"root VERSION rejected"];return;}
        self.rootVersionValid=YES;
        if(!self.rootModelSent) {uint8_t model[]={0,0,0,2};if([self sendRoot:3 body:packet(model,4)]) {self.rootModelSent=YES;self.rootModelSince=NSProcessInfo.processInfo.systemUptime;}else [self fail:HelperExitWriteFailed reason:@"root Model write failed"];}
        return;
    }
    if(type==4 && self.rootModelSent && !self.rootVerified) {
        self.rootIdentity=modelName([message subdataWithRange:NSMakeRange(6,n)])?:@"Invalid model response";
        printf("Earbud ModelName=%s\n",self.rootIdentity.UTF8String);
        if(!earbudModelMatches(self.rootIdentity)) {
            [self fail:HelperExitWrongEarbudModel reason:[NSString stringWithFormat:@"root earbud ModelName '%@' is not an AirPods Pro or AirPods 4 earbud",self.rootIdentity]];
            return;
        }
        self.rootVerified=YES;return;
    }
    if(type!=0x1b) return;if(n<8) {[self fail:HelperExitUnexpectedReply reason:@"short downstream envelope"];return;}if(be16(b+6)!=1) return;
    if(!self.caseActive || ![self.announced containsObject:@1]) return;
    const uint8_t *inner=b+8;uint16_t it=be16(inner),in=be16(inner+2),identifier=be16(inner+4);
    if((NSUInteger)n!=(NSUInteger)in+8) {[self fail:HelperExitUnexpectedReply reason:@"malformed case inner frame"];return;}
    NSData *body=[NSData dataWithBytes:inner+6 length:in];const uint8_t *v=body.bytes;
    if(it==5) {
        if(in<4 || memcmp(v,"MTIC",4)) return;
        NSDictionary *meta=mticOffer(body);if(!meta) {[self fail:HelperExitUnexpectedReply reason:@"invalid or oversized case MTIC offer"];return;}
        if(!self.offer && !self.cleanupStarted && !self.error) {self.offer=body;self.offerMetadata=meta;}
        return;
    }
    if(it!=2 && it!=4 && it!=7 && it!=0x0f && it!=0x12 && it!=0x13) return;
    if([self.caseResponseIDs containsObject:@(identifier)]) {[self fail:HelperExitUnexpectedReply reason:@"replayed case response ID"];return;}
    [self.caseResponseIDs addObject:@(identifier)];
    [self.recentCaseIDs addObject:@(identifier)];
    if(self.recentCaseIDs.count>128){[self.caseResponseIDs removeObject:self.recentCaseIDs.firstObject];[self.recentCaseIDs removeObjectAtIndex:0];}
    if(it==0x0f && self.cleanupSent) {
        if(in!=4 || be16(v)!=self.assetID || be16(v+2)!=3) {[self fail:HelperExitUnexpectedReply reason:@"invalid scoped cleanup acknowledgement"];return;}
        self.cleanupAck=YES;self.pending=nil;self.unconfirmedBytes=self.startupUnknownBytes;return;
    }
    if(self.cleanupStarted) return;
    if(it==0x12 && self.solicitationSent && [self.pending isEqualToString:@"solicit"]) {
        if(in!=8 || be32(v)!=0 || memcmp(v+4,"MTIC",4)) {[self fail:(in==8 && !memcmp(v+4,"MTIC",4))?HelperExitCaseDeclined:HelperExitUnexpectedReply reason:@"case diagnostic request receipt was invalid or unsuccessful"];return;}
        self.solicitationReceiptVerified=YES;self.solicitationReceipts++;self.pending=nil;self.unconfirmedBytes=self.startupUnknownBytes;
    } else if(it==0x13 && self.solicitationSent && !self.accepted) {
        if(in!=6 || memcmp(v,"MTIC",4)) {[self fail:HelperExitUnexpectedReply reason:@"invalid case diagnostic rejection"];return;}
        self.solicitationDenial=body;
        BOOL acknowledged=[self sendChild:0x14 body:body];
        [self fail:HelperExitCaseDeclined reason:acknowledged?[NSString stringWithFormat:@"case diagnostic request declined (reason %u)",be16(v+4)]:@"case diagnostic rejection receipt could not be sent"];
    } else if(it==2 && self.caseVersionReplies<self.caseVersionFrames) {
        if(in<4 || be16(v)!=0 || be16(v+2)<5 || be16(v+2)>7) {[self fail:HelperExitUnexpectedReply reason:@"invalid case VERSION response"];return;}
        self.caseVersionValid=YES;self.caseVersionReplies++;self.unconfirmedBytes=self.unconfirmedBytes>=8?self.unconfirmedBytes-8:0;
        if(self.startupUnknownBytes) self.startupUnknownBytes-=MIN((NSUInteger)8,self.startupUnknownBytes);
        if(self.caseVersionReplies==self.caseVersionFrames) {
            if([self.pending isEqualToString:@"version"]) self.pending=nil;
            if(!self.pending) self.unconfirmedBytes=0;
            if(self.caseModelVerified) self.caseRouteDrained=YES;
        }
    } else if(it==4 && self.caseModelSent && !self.caseModelVerified) {
        if((![self.pending isEqual:@"model"] || self.modelSentAfterVersionFrames!=self.caseVersionFrames)) {[self fail:HelperExitUnexpectedReply reason:@"case identity reply did not match the ordered setup query"];return;}
        self.caseIdentity=modelName(body);
        printf("Case ModelName=%s\n",self.caseIdentity.UTF8String?: "(none)");
        if(!chargingCaseModelMatches(self.caseIdentity)) {
            [self fail:HelperExitWrongCaseModel reason:[NSString stringWithFormat:@"announced endpoint ModelName '%@' is not an AirPods charging case",self.caseIdentity?:@"(none)"]];
            return;
        }
        self.caseModelVerified=YES;self.pending=nil;self.unconfirmedBytes=self.unconfirmedBytes>=10?self.unconfirmedBytes-10:0;
        self.caseRouteDrained=self.caseVersionReplies==self.caseVersionFrames;
        if(self.caseRouteDrained) self.unconfirmedBytes=0;
        else {
            self.startupUnknownBytes=(self.caseVersionFrames-self.caseVersionReplies)*8;
            if(self.startupUnknownBytes!=8 || self.unconfirmedBytes!=8) [self fail:HelperExitReplyTimeout reason:@"more than one startup VERSION remained unanswered"];
        }
    } else if(it==4 && self.caseModelVerified && [self.pending isEqualToString:@"identity_refresh"]) {
        NSString *refreshed=modelName(body);
        if(!chargingCaseModelMatches(refreshed) || (self.caseIdentity.length && ![foldedModelName(refreshed) isEqualToString:foldedModelName(self.caseIdentity)])) {
            [self fail:HelperExitWrongCaseModel reason:[NSString stringWithFormat:@"case identity refresh '%@' did not match '%@'",refreshed?:@"(none)",self.caseIdentity?:@"(none)"]];
            return;
        }
        self.identityRefreshReplies++;self.pending=nil;self.unconfirmedBytes=self.startupUnknownBytes;
    } else if(it==4 && self.caseModelVerified && !self.pending) {
        puts("Late case identity reply ignored");
    } else [self fail:HelperExitUnexpectedReply reason:@"unexpected case response for pending request"];
}
- (void)tick:(double)now {
    if(self.cleanupStarted || self.error) return;
    // A pointer session runs on motion, and going stale ends it anyway. So a missed identity reply just gets asked again.
    if([self.pending isEqualToString:@"identity_refresh"] && now-self.pendingSince>=5) {
        self.missedReplies++;self.pending=nil;self.unconfirmedBytes=self.startupUnknownBytes;
        printf("Case identity reply missed (%lu so far); motion carries on\n",(unsigned long)self.missedReplies);return;
    }
    if(self.pending && now-self.pendingSince>=5) {[self fail:HelperExitReplyTimeout reason:[NSString stringWithFormat:@"case %@ response timed out",self.pending]];return;}
    if(self.rootModelSent && !self.rootVerified && now-self.rootModelSince>=8) {[self fail:HelperExitIdentityUnavailable reason:@"root Model response timed out"];return;}
    if(!self.closedWindowStarted) return;
    if(self.pending || !self.rootVerified || !self.caseActive) return;
    if(!self.caseModelVerified) {
        if(self.caseVersionValid && !self.caseModelSent) {
            uint8_t model[]={0,0,0,2};if(![self sendChild:3 body:packet(model,4)]) [self fail:HelperExitWriteFailed reason:@"case Model write failed"];
            else [self setPending:@"model" at:now];
            return;
        }
        if(!self.caseModelSent && self.caseVersionFrames<2 && now>=self.nextCaseVersionAt) {
            uint8_t version[]={0,7};if([self sendChild:1 body:packet(version,2)]) self.nextCaseVersionAt=now+8;else [self fail:HelperExitWriteFailed reason:@"case VERSION metadata write or budget failed"];
        }
        return;
    }
    // Finish accounting for startup before the first MTIC request.
    if(![self initializedCaseRoute]) {
        if(!self.metadataDrainSince) self.metadataDrainSince=now;
        if(now-self.metadataDrainSince>=5) [self fail:HelperExitReplyTimeout reason:@"case initialization replies remained incomplete"];
        return;
    }
    if(!self.offer && !self.solicitationAttempted) {
        const uint8_t tag[]={'M','T','I','C'};
        if([self sendChild:0x11 body:packet(tag,4)]) {self.solicitationSent=YES;[self setPending:@"solicit" at:now];}
        else [self fail:HelperExitWriteFailed reason:@"case diagnostic request could not be sent"];
        return;
    }
    if(!self.offer) {
        if(!self.solicitationReceiptVerified) {[self fail:HelperExitUnexpectedReply reason:@"case diagnostic request has no valid receipt"];return;}
        if(!self.offerWaitSince) self.offerWaitSince=now;
        // Each renewal cancels the case's asset-idle timer. Never renew after an
        // offer or a missing/invalid receipt (see WHY THE HELPER TOUCHES MTIC AT ALL).
        if([self maySolicitAt:now]) {
            const uint8_t tag[]={'M','T','I','C'};
            if([self sendChild:0x11 body:packet(tag,4)]) {self.solicitationSent=YES;[self setPending:@"solicit" at:now];}
            else [self fail:HelperExitWriteFailed reason:@"case route renewal could not be sent"];
        }
        return;
    }
    [self acceptOfferIfReady];if(self.error) return;
    // An active asset protects arbitration, but an idle stream still has its own
    // timeout. Ordinary ModelName traffic keeps it open; each query needs a reply.
    if(self.accepted && now>=self.nextActiveIdentityAt) {
        const uint8_t model[]={0,0,0,2};
        if([self sendChild:3 body:packet(model,4)]) {[self setPending:@"identity_refresh" at:now];self.nextActiveIdentityAt=now+1;}
        else [self fail:HelperExitWriteFailed reason:@"active case identity query could not be sent"];
    }
}
// WHY THE HELPER TOUCHES MTIC AT ALL. The case closes its earbud stream when
// its 3.5 s asset-arbitration idle timer expires with no asset kind selected.
// With no offer, the 1 s MTIC solicitations (0x11, each needing a receipt) cancel that timer; that is
// the keep-alive verified in the five-minute battery-only run, with no asset
// held at all. Once the case offers an MTIC asset, solicitations must stop
// (canSendChild 0x11 requires !offer && !accepted), so the helper ACKs the
// offer and keeps it active instead: an active asset keeps arbitration
// non-idle, and 1 s ModelName queries refresh the separate 14 s stream timer.
// It never reads DATA. On exit the held asset is released
// with a scoped Abandon (type 9, status 3). The case's handler does not
// distinguish Abandon from completion, so staged analytics are consumed.
// Skipping the Abandon would leave the case's own 480 s active-transfer watchdog to end the transfer on
// its "unsuccessful, restore the records" path, but the case would stay awake
// until then; that trade is the product owner's. Sessions on the tested pair ran
// past that watchdog while holding the asset, to about 30 minutes.
- (void)beginCleanup:(double)now {
    self.cleanupStarted=YES;if(!self.accepted || !self.caseActive) return;
    uint8_t body[]={self.assetID>>8,self.assetID,0,3};
    if([self sendChild:9 body:packet(body,4)]) {self.cleanupWriteComplete=YES;[self setPending:@"abandon_ack" at:now];}else if(!self.error) [self fail:HelperExitReleaseUnconfirmed reason:@"scoped case MTIC cleanup write failed"];
}
- (NSDictionary *)status {
    return @{@"root_identity_verified":@(self.rootVerified),@"case_identity_verified":@(self.caseModelVerified),@"error":self.error?:@""};
}
@end
static NSData *varintData(uint32_t value) {
    NSMutableData *data=NSMutableData.data;
    do {uint8_t b=value&127;value>>=7;if(value) b|=128;[data appendBytes:&b length:1];}while(value);return data;
}
// The sequence carries on across sessions, so it lives in the app's data folder,
// beside the target file rather than wherever the helper happened to be started.
static NSString *sensorSequencePath=nil;
// Set only when the file couldn't be written, so one session never repeats a number.
static unsigned unsavedSensorSequence=0;
static NSData *sensorSetting(uint8_t service,uint32_t interval) {
    NSString *path=sensorSequencePath;
    NSString *saved=[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    unsigned sequence=unsavedSensorSequence?:[saved intValue];
    sequence=sequence<8000 || sequence>=16000 ? 8001 : sequence+1;
    BOOL written=[[NSString stringWithFormat:@"%u",sequence] writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    unsavedSensorSequence=written?0:sequence;
    if(!written) printf("sensor sequence not saved\n");
    uint8_t setting[]={8,service,16,2,26,5,1,(uint8_t)interval,(uint8_t)(interval>>8),(uint8_t)(interval>>16),(uint8_t)(interval>>24)};
    uint8_t tag=8;NSMutableData *message=[NSMutableData dataWithBytes:&tag length:1];[message appendData:varintData(sequence)];
    uint8_t field[]={66,sizeof(setting)};[message appendBytes:field length:sizeof(field)];[message appendBytes:setting length:sizeof(setting)];
    uint16_t n=message.length;uint8_t header[]={4,0,4,0,0x17,0,0,0,0x10,0,(uint8_t)n,(uint8_t)(n>>8)};
    NSMutableData *data=[NSMutableData dataWithBytes:header length:sizeof(header)];[data appendData:message];return data;
}
static NSArray *sensorStatus(ConsoleReader *reader,double now) {
    NSMutableArray *sensors=NSMutableArray.array;
    for(NSString *key in @[@"11",@"12"]) {
        NSDictionary *last=reader.lastSamples[key];
        [sensors addObject:@{@"age_seconds":last?@(now-[last[@"received_uptime"] doubleValue]):@(-1)}];
    }
    return sensors;
}
// Cleanup order on every exit path: sensor STOP first (nothing to wait for),
// then the scoped Abandon of a held MTIC asset, whose acknowledgement can take
// seconds. STOP is sent for each sensor whose start was attempted, even if
// that start write was partial, so no subscription is left running.
static void stopSensorsThenRelease(NSOutputStream *output,CaseSnapshot *transfer,BOOL accelAttempted,BOOL gyroAttempted,BOOL *accelStopped,BOOL *gyroStopped) {
    *accelStopped=NO;*gyroStopped=NO;
    if(accelAttempted || gyroAttempted) {
        *accelStopped=sendPacket(output,sensorSetting(11,0),"known accelSTOP");
        *gyroStopped=sendPacket(output,sensorSetting(12,0),"known gyroSTOP");
    }
    [transfer beginCleanup:NSProcessInfo.processInfo.systemUptime];
}
// The first cause wins: the loop's own reason (lease, signal, input ended),
// else the first protocol/cleanup error, else success. An app stop request is
// success even before the case was reached (Cancel).
static int sessionExitCode(int loopExit,NSString *error,int failure,BOOL stopped) {
    if(loopExit) return loopExit;
    if(error) return failure?:HelperExitUnexpectedReply;
    return stopped ? HelperExitOK:HelperExitIncomplete;
}
// A dropped link usually shows up first as a failed write (the 1 s case
// keep-alive or the VERSION heartbeat runs before the loop reads the stream
// status), so a write failure on an ended channel is reported as INPUT_ENDED.
static BOOL writeFailureMeansLinkEnded(int loopExit,int failure,BOOL channelEnded) {
    return channelEnded && (loopExit==HelperExitWriteFailed || (!loopExit && failure==HelperExitWriteFailed));
}
static BOOL phaseIsStop(NSURL *phaseURL) {
    NSString *phase=[[NSString stringWithContentsOfURL:phaseURL encoding:NSUTF8StringEncoding error:nil] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return [phase isEqualToString:@"stop"];
}
#include "HeadphoneMotion.m"

static int runPointerSession(CBL2CAPChannel *channel, NSURL *directory) {
    double began=NSProcessInfo.processInfo.systemUptime;
    // Only bounds setup. The live loop moves this to now+15 on every pass, so a
    // session has no fixed length here.
    operationDeadline=began+720;
    ConsoleReader *reader=ConsoleReader.new;
    NSInputStream *input=channel.inputStream;NSOutputStream *output=channel.outputStream;
    if(!input || !output) {puts("AACP channel has no input/output streams; no device commands sent");return HelperExitChannelNotObtained;}
    signal(SIGPIPE,SIG_IGN);
    int pipeFlags=fcntl(STDOUT_FILENO,F_GETFL);if(pipeFlags<0 || fcntl(STDOUT_FILENO,F_SETFL,pipeFlags|O_NONBLOCK)<0) {puts("Motion pipe could not be made non-blocking; no device commands sent");return HelperExitMotionPipeClosed;}
    reader.motionStream=stdout;
    setvbuf(reader.motionStream,NULL,_IOLBF,0);
    input.delegate=reader;[input scheduleInRunLoop:NSRunLoop.currentRunLoop forMode:NSDefaultRunLoopMode];
    [output scheduleInRunLoop:NSRunLoop.currentRunLoop forMode:NSDefaultRunLoopMode];[input open];[output open];pump(.3);
    // AACP session setup. The 0x4d feature flags and 0x0f notification mask
    // are write-only here: nothing the AirPods send reports their previous
    // values, so they are deliberately not "restored" on exit (a guessed value
    // could switch off something macOS itself enabled). The 0x4d frame is
    // byte-identical to one captured from a Mac's own AACP session; the 0x0f
    // mask differs from that capture by one bit (ff ff fe ff). Both are sent
    // on this helper's own channel, which is closed on exit.
    const uint8_t handshake[]={0,0,4,0,1,0,2,0,0,0,0,0,0,0,0,0};
    const uint8_t flags[]={4,0,4,0,0x4d,0,0xff,0,0,0,0,0,0,0};
    const uint8_t notifications[]={4,0,4,0,0x0f,0,0xff,0xff,0xff,0xff};
    BOOL setup=sendPacket(output,packet(handshake,sizeof(handshake)),"known handshake");pump(.4);
    if(setup) setup=sendPacket(output,packet(flags,sizeof(flags)),"known flags");pump(.4);
    if(setup) setup=sendPacket(output,packet(notifications,sizeof(notifications)),"known notifications");
    if(setup) receiveUntilAnswered(reader,input,.5,7,2);
    step("session setup answered");
    BOOL sensorsStarted=NO,accelStarted=NO,gyroStarted=NO,accelAttempted=NO,gyroAttempted=NO,queryPending=NO,stopped=NO,discoverySent=NO,baselineVerified=NO,motionInputVerified=NO;NSUInteger processed=0,responses=0,queries=0,rootStartupQueries=0,rootUnanswered=0;
    CaseSnapshot *transfer=CaseSnapshot.new;transfer.output=output;transfer.targetBound=YES;double nextQuery=0,lastRootQueryAt=0;
    int exitCode=HelperExitOK;NSString *reason=@"deadline";
    NSURL *leaseURL=[directory.URLByDeletingLastPathComponent URLByAppendingPathComponent:@"app-lease.txt"];
    if(terminationRequested()) {exitCode=HelperExitSignaled;reason=@"termination signal during session setup";}
    else if(!setup) {exitCode=HelperExitWriteFailed;reason=@"AACP session setup write failed";}
    else if(!reader.controls) {exitCode=HelperExitNoSessionReply;reason=@"AACP channel opened but nothing answered the session setup";}
    else if(!sessionLeaseFresh(leaseURL,NSProcessInfo.processInfo.systemUptime)) {stopped=YES;exitCode=HelperExitLeaseExpired;reason=@"app session lease expired before sensors started";}
    else {
        accelAttempted=YES;accelStarted=sendPacket(output,sensorSetting(11,5000),"known accel");pump(.2);
        gyroAttempted=YES;gyroStarted=sendPacket(output,sensorSetting(12,5000),"known gyro");
        sensorsStarted=accelStarted && gyroStarted;
        if(!sensorsStarted) {exitCode=HelperExitWriteFailed;reason=@"sensor start write failed";}
    }
    if(exitCode) printf("Session setup ended: %s\n",reason.UTF8String);
    NSURL *phaseURL=[directory URLByAppendingPathComponent:@"phase.txt"];
    double nextStatus=0;NSUInteger publishedStates=0;BOOL publishedBaseline=NO;
    // The deadline moves on every pass, so this only ends a session if one pass stalls for about 9 s.
    while(sensorsStarted && !exitCode && NSProcessInfo.processInfo.systemUptime<operationDeadline-6) { @autoreleasepool {
        if(terminationRequested()) {exitCode=HelperExitSignaled;reason=@"termination signal";break;}
        // Before any write this cycle: a channel the link already closed ends the session as INPUT_ENDED.
        if(streamEnded(input) || streamEnded(output)) {reason=@"input ended";exitCode=HelperExitInputEnded;break;}
        {
            double now=NSProcessInfo.processInfo.systemUptime;
            if(!sessionLeaseFresh(leaseURL,now)){stopped=YES;reason=@"app session lease expired";exitCode=HelperExitLeaseExpired;break;}
            operationDeadline=now+15;
        }
        NSString *phase=[[NSString stringWithContentsOfURL:phaseURL encoding:NSUTF8StringEncoding error:nil] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if([phase isEqualToString:@"stop"]) {stopped=YES;reason=@"own stop flag";break;}
        if(phase.length) reader.phase=phase;
        double now=NSProcessInfo.processInfo.systemUptime;
        if(reader.motionStreamFailed) {[transfer fail:HelperExitMotionPipeClosed reason:@"Motion stream write failed"];reason=transfer.error;break;}
        if([phase isEqualToString:@"closed_confirmed"]) [transfer confirmClosedAt:now];
        RootVersionAction overdue=steadyRootVersionAction(transfer.rootVersionValid,queryPending,rootUnanswered,now-lastRootQueryAt);
        if(overdue==RootVersionFail) {[transfer fail:HelperExitReplyTimeout reason:@"earbud stopped answering the VERSION heartbeat"];reason=transfer.error;break;}
        if((!queryPending && now>=nextQuery) || (queryPending && (overdue==RootVersionResend || retryInitialRootVersion(transfer.rootVersionValid,rootStartupQueries,now-lastRootQueryAt)))) {
            uint8_t v[]={0,7};
            if(overdue==RootVersionResend) printf("Root VERSION reply overdue %.1f s; asking again (%lu unanswered)\n",now-lastRootQueryAt,(unsigned long)rootUnanswered);
            if([transfer sendRoot:1 body:packet(v,2)]) {queries++;queryPending=YES;lastRootQueryAt=now;rootUnanswered++;if(!transfer.rootVersionValid)rootStartupQueries++;}
            else {[transfer fail:HelperExitWriteFailed reason:@"root version write failed"];reason=transfer.error;break;}
        }
        pump(.02);if(input.hasBytesAvailable) [reader stream:input handleEvent:NSStreamEventHasBytesAvailable];
        while(processed<reader.uarpMessages.count) {
            NSData *message=reader.uarpMessages[processed++];[transfer handleMessage:message];const uint8_t *b=message.bytes;
            if(be16(b)==2 && message.length>=10 && be16(b+6)==0 && be16(b+8)>=5 && be16(b+8)<=7) {
                responses++;queryPending=NO;rootUnanswered=0;nextQuery=NSProcessInfo.processInfo.systemUptime+1;
            }
        }
        [reader.uarpMessages removeAllObjects];processed=0;
        now=NSProcessInfo.processInfo.systemUptime;
        if(motionInputVerified) {
            BOOL fresh=YES;
            for(NSString *service in @[@"11",@"12"]) {
                NSDictionary *last=reader.lastSamples[service];
                if(!last || now-[last[@"received_uptime"] doubleValue]>3) fresh=NO;
            }
            if(!fresh) {[transfer fail:HelperExitMotionStale reason:@"Motion stopped arriving"];reason=transfer.error;break;}
        }
        if(transfer.rootVerified && !discoverySent) {
            discoverySent=[transfer sendRoot:0x15 body:NSData.data];
            if(!discoverySent) [transfer fail:HelperExitWriteFailed reason:@"root discovery write failed"];
        }
        [transfer tick:now];
        {
            BOOL fresh=YES;
            for(NSNumber *service in @[@11,@12]) {
                NSUInteger count=service.intValue==11?reader.accelFresh:reader.gyroFresh;
                NSDictionary *last=reader.lastSamples[service.stringValue];
                if(count<25 || !last || now-[last[@"received_uptime"] doubleValue]>=1) fresh=NO;
            }
            if(fresh) motionInputVerified=YES;
            if(fresh && transfer.rootVerified && !baselineVerified) step("open baseline verified");
            if(fresh && transfer.rootVerified) baselineVerified=YES;
        }
        if(transfer.error) {reason=transfer.error;break;}
        // A new in-case report goes out at once: the app confirms the closed lid from it.
        if(reader.earbudStateEvents.count!=publishedStates) nextStatus=0;
        // So does a verified baseline: the app says "Close the lid" from it.
        if(baselineVerified && !publishedBaseline) nextStatus=0;
        if(now>=nextStatus) {
            NSArray *sensors=sensorStatus(reader,now);publishedStates=reader.earbudStateEvents.count;publishedBaseline=baselineVerified;
            NSDictionary *status=@{@"updated_unix":@(NSDate.date.timeIntervalSince1970),@"open_baseline_verified":@(baselineVerified),
                @"sensors":sensors,@"earbud_state_events":[reader.earbudStateEvents copy],@"case_snapshot":[transfer status]};
            if(![[NSJSONSerialization dataWithJSONObject:status options:NSJSONWritingPrettyPrinted error:nil] writeToURL:[directory URLByAppendingPathComponent:@"status.json"] atomically:YES]) {[transfer fail:HelperExitCaptureWrite reason:@"status write failed"];reason=transfer.error;break;}
            NSDictionary *latest=reader.lastSamples[@"11"];
            printf("HOLD phase=%s seconds=%.1f versions=%lu/%lu accel=%lu arrival_minus_sensor=%.3f\n",reader.phase.UTF8String,now-began,responses,queries,(unsigned long)reader.accelReports,latest?[latest[@"received_uptime"] doubleValue]-[latest[@"sensor_us"] doubleValue]*1e-6:0);nextStatus=now+1;
        }
        if(input.streamStatus==NSStreamStatusError || input.streamStatus==NSStreamStatusAtEnd) {reason=@"input ended";exitCode=HelperExitInputEnded;break;}
        if(now-began>15 && !motionInputVerified) {[transfer fail:HelperExitBaselineUnavailable reason:@"open baseline unavailable"];reason=transfer.error;break;}
        if(now-began>160 && !baselineVerified) {[transfer fail:HelperExitIdentityUnavailable reason:@"motion arrived but diagnostic identity remained unavailable"];reason=transfer.error;break;}
    }
    } // Drain temporary objects on each live receive cycle.
    if(writeFailureMeansLinkEnded(exitCode,transfer.failure,streamEnded(input) || streamEnded(output))) {
        reason=[NSString stringWithFormat:@"input ended (%@)",transfer.error?:reason];exitCode=HelperExitInputEnded;
    }
    // ---- Cleanup: identical for stop, lease expiry, pipe close, protocol errors and signals.
    double cleanupBegan=NSProcessInfo.processInfo.systemUptime;cleanupStartedAt=cleanupBegan;
    operationDeadline=cleanupBegan+7;
    // A signal shortens every remaining wait so the process exits within about 2 s.
    if(terminationRequested()) operationDeadline=MIN(operationDeadline>0?operationDeadline:cleanupBegan+2,MAX(cleanupBegan+.5,terminationNoticedAt+2));
    printf("Cleanup: %s; stopping sensors%s\n",reason.UTF8String,transfer.accepted?", then releasing the held case MTIC asset":"");
    // 1. Sensor STOP, then (2) the scoped Abandon of this exact live offered
    // asset. Abandon can consume the case's staged analytics; see beginCleanup.
    BOOL accelStopped=NO,gyroStopped=NO;
    stopSensorsThenRelease(output,transfer,accelAttempted,gyroAttempted,&accelStopped,&gyroStopped);
    // On a channel the link already ended a STOP cannot be delivered; the
    // dropped link stays the reported cause (the log line below still shows it).
    if((accelAttempted || gyroAttempted) && (!accelStopped || !gyroStopped) && !streamEnded(input) && !streamEnded(output)) [transfer fail:HelperExitSensorStopFailed reason:@"sensor STOP write failed"];
    // The release was already sent; a pointer session doesn't hold up a disconnect for its receipt.
    double cleanupDeadline=MIN(operationDeadline,NSProcessInfo.processInfo.systemUptime+1.5);
    while(transfer.cleanupWriteComplete && !transfer.cleanupAck) {
        double limit=cleanupDeadline;if(terminationRequested()) limit=MIN(limit,MAX(cleanupBegan,terminationNoticedAt)+1.5);
        if(NSProcessInfo.processInfo.systemUptime>=limit) break;
        pump(.02);if(input.hasBytesAvailable) [reader stream:input handleEvent:NSStreamEventHasBytesAvailable];
        while(processed<reader.uarpMessages.count) [transfer handleMessage:reader.uarpMessages[processed++]];
        if(input.streamStatus==NSStreamStatusError || input.streamStatus==NSStreamStatusAtEnd) break;
    }
    if(!transfer.cleanupWriteComplete && (accelAttempted || gyroAttempted)) {
        // Give the STOP writes a moment to leave the socket before the channel closes.
        double remaining=operationDeadline-NSProcessInfo.processInfo.systemUptime;
        if(remaining>0) pump(MIN(terminationRequested()?.05:.2,remaining));
    }
    if(transfer.accepted && !transfer.cleanupAck) [transfer fail:HelperExitReleaseUnconfirmed reason:@"scoped case cleanup acknowledgement unavailable"];
    // 3. A session that ended with no stop request and no cause yet (not signals: those report SIGNALED only).
    if(exitCode!=HelperExitSignaled && !transfer.error && !stopped) [transfer fail:(exitCode?:HelperExitIncomplete) reason:(exitCode && exitCode!=HelperExitInputEnded)?reason:[reason hasPrefix:@"input ended"]?@"AirPods input connection ended":@"Pointer session ended unexpectedly"];
    if(fclose(reader.motionStream)!=0) [transfer fail:HelperExitMotionPipeClosed reason:@"Motion stream close failed"];reader.motionStream=NULL;
    double finishedAt=NSProcessInfo.processInfo.systemUptime;NSArray *finalSensors=sensorStatus(reader,finishedAt);
    exitCode=sessionExitCode(exitCode,transfer.error,transfer.failure,stopped);
    printf("Cleanup finished in %.2f s: accel_stop=%d gyro_stop=%d mtic_release=%s; AACP 0x4d/0x0f session settings left as set (no prior values are reported to restore)\n",
           finishedAt-cleanupBegan,accelStopped,gyroStopped,!transfer.accepted?"none held":transfer.cleanupAck?"acknowledged":"unconfirmed");
    NSURL *statusURL=[directory URLByAppendingPathComponent:@"status.json"];
    NSData *priorStatus=[NSData dataWithContentsOfURL:statusURL];
    NSMutableDictionary *status=priorStatus?[[NSJSONSerialization JSONObjectWithData:priorStatus options:NSJSONReadingMutableContainers error:nil] mutableCopy]:NSMutableDictionary.dictionary;
    if(!status) status=NSMutableDictionary.dictionary;
    status[@"updated_unix"]=@(NSDate.date.timeIntervalSince1970);status[@"open_baseline_verified"]=@(baselineVerified);status[@"sensors"]=finalSensors;status[@"case_snapshot"]=[transfer status];
    [[NSJSONSerialization dataWithJSONObject:status options:NSJSONWritingPrettyPrinted error:nil] writeToURL:statusURL atomically:YES];
    [input close];[output close];[input removeFromRunLoop:NSRunLoop.currentRunLoop forMode:NSDefaultRunLoopMode];
    [output removeFromRunLoop:NSRunLoop.currentRunLoop forMode:NSDefaultRunLoopMode];input.delegate=nil;
    operationDeadline=0;cleanupStartedAt=0;
    return exitCode;
}
static NSString *normalize(NSString *value) {
    return [[[value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
             stringByReplacingOccurrencesOfString:@"-" withString:@":"] lowercaseString];
}

static NSUInteger testCount=0;
static void check(BOOL condition,NSString *label) {
    testCount++;if(!condition) {fprintf(stderr,"FAIL: %s\n",label.UTF8String);exit(1);}
}
static NSData *testOffer(uint16_t asset,uint32_t length) {
    uint8_t b[30]={'M','T','I','C',0,10,asset>>8,asset};
    b[24]=length>>24;b[25]=length>>16;b[26]=length>>8;b[27]=length;b[29]=1;return packet(b,30);
}
static NSData *testModel(NSString *name) {
    NSData *text=[name dataUsingEncoding:NSUTF8StringEncoding];uint32_t n=(uint32_t)text.length;
    uint8_t h[]={0,0,0,0,0,2,n>>24,n>>16,n>>8,n};NSMutableData *b=[packet(h,10) mutableCopy];[b appendData:text];return b;
}
static NSData *testChild(uint16_t type,uint16_t ID,NSData *body) {
    uint8_t endpoint[]={0,1};NSMutableData *b=[packet(endpoint,2) mutableCopy];[b appendData:uarpMessage(type,ID,body)];return uarpMessage(0x1b,500,b);
}
static CaseSnapshot *testSession(void) {
    CaseSnapshot *s=CaseSnapshot.new;s.output=NSOutputStream.outputStreamToMemory;[s.output open];
    s.targetBound=YES;s.rootVerified=YES;s.rootVersionValid=YES;s.closedWindowStarted=YES;return s;
}
static void testSensorWire(ConsoleReader *reader,uint64_t stamp) {
    uint8_t wire[46]={4,0,4,0,0x17,0,0,0,0x10,0,34,0,0x3a,32,8,11,0x1a,28,1};
    for(unsigned n=0;n<8;n++) wire[18+20+n]=stamp>>(8*n);
    NSInputStream *input=[NSInputStream inputStreamWithData:packet(wire,sizeof(wire))];[input open];
    [reader stream:input handleEvent:NSStreamEventHasBytesAvailable];[input close];
}
static void sessionChecks(void) {
    NSURL *lease=[NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]];
    [@"100\n" writeToURL:lease atomically:YES encoding:NSUTF8StringEncoding error:nil];
    check(sessionLeaseFresh(lease,100) && sessionLeaseFresh(lease,104.99) && !sessionLeaseFresh(lease,105),@"app lease expires after five seconds without a heartbeat");
    check(!sessionLeaseFresh(lease,90),@"future lease cannot authorize a session");
    [NSFileManager.defaultManager removeItemAtURL:lease error:nil];check(!sessionLeaseFresh(lease,100),@"missing app lease ends session");
    ConsoleReader *reader=ConsoleReader.new;
    for(unsigned i=1;i<=80005;i++){@autoreleasepool{testSensorWire(reader,(uint64_t)i*20000);}}
    check(reader.accelReports==80005 && reader.accelFresh==80005 && [reader.lastSamples[@"11"][@"sensor_us"] unsignedLongLongValue]==80005ULL*20000,@"live parser keeps going over long sessions");
    check(reader.lastSamples.count==1,@"live motion retains constant memory instead of recording history");
    testSensorWire(reader,20000);check(reader.accelFresh==80005,@"backwards live sample cannot refresh motion freshness");
    int fds[2];check(pipe(fds)==0,@"offline closed-reader pipe opened");close(fds[0]);
    void (*oldSignal)(int)=signal(SIGPIPE,SIG_IGN);reader.motionStream=fdopen(fds[1],"w");setvbuf(reader.motionStream,NULL,_IONBF,0);
    testSensorWire(reader,80006ULL*20000);check(reader.motionStreamFailed,@"closed parent motion pipe fails cleanly without SIGPIPE termination");fclose(reader.motionStream);reader.motionStream=NULL;signal(SIGPIPE,oldSignal);
    check(nextIdentifier(UINT16_MAX)==1 && nextIdentifier(1)==2,@"request IDs wrap without emitting zero");
    CaseSnapshot *s=testSession();[s.announced addObject:@1];s.caseActive=YES;s.caseModelVerified=YES;s.caseRouteDrained=YES;
    const uint8_t receipt[]={0,0,0,0,'M','T','I','C'},mtic[]={'M','T','I','C'},cleanup[]={0,7,0,3};
    double now=NSProcessInfo.processInfo.systemUptime;
    for(unsigned i=0;i<400;i++){
        if(i%60==0)s.budgetStartedAt=NSProcessInfo.processInfo.systemUptime-61;
        if(i>0)s.lastSolicitationAt=NSProcessInfo.processInfo.systemUptime-2;
        [s tick:now+2+i];[s handleMessage:testChild(0x12,(uint16_t)(100+i),packet(receipt,8))];
        check(!s.error && !s.pending,[NSString stringWithFormat:@"renewal %u requires a valid receipt: error=%@ pending=%@",i,s.error,s.pending]);
    }
    check(s.solicitationAttempts==400,@"renewal continues for as long as the session runs");
    s.caseRequests=100000;s.caseInnerBytes=1000000;s.budgetStartedAt=NSProcessInfo.processInfo.systemUptime-61;s.lastSolicitationAt=NSProcessInfo.processInfo.systemUptime-2;
    check([s canSendChild:0x11 body:packet(mtic,4)],@"live window budget is independent of lifetime totals");
    s.windowRequests=119;s.budgetStartedAt=NSProcessInfo.processInfo.systemUptime;
    check(![s canSendChild:0x11 body:packet(mtic,4)],@"live window has a hard request budget");
    s.accepted=YES;s.assetID=7;s.cleanupStarted=YES;
    check([s canSendChild:9 body:packet(cleanup,4)],@"live window reserves one cleanup operation");
    CaseSnapshot *hold=testSession();[hold.announced addObject:@1];hold.caseActive=YES;hold.caseModelVerified=YES;hold.caseRouteDrained=YES;
    hold.offer=testOffer(7,35);hold.offerMetadata=mticOffer(hold.offer);[hold tick:now];[hold tick:now+3600];
    check(hold.accepted && [hold.pending isEqual:@"identity_refresh"],@"active offered asset uses ordinary identity traffic rather than reading diagnostics on a timer");
    CaseSnapshot *ids=testSession();[ids.announced addObject:@1];ids.caseActive=YES;ids.caseModelVerified=YES;ids.solicitationSent=YES;
    for(unsigned i=0;i<70000;i++){@autoreleasepool{ids.pending=@"solicit";[ids handleMessage:testChild(0x12,(uint16_t)i,packet(receipt,8))];}}
    check(!ids.error && ids.solicitationReceipts==70000 && ids.caseResponseIDs.count==128,@"bounded replay window survives response ID rollover after long sessions");
    ids.pending=@"solicit";[ids handleMessage:testChild(0x12,(uint16_t)69999,packet(receipt,8))];check(ids.error!=nil,@"recent duplicate receipt still stops a live session");
}
// One serialized frame written by this helper, decoded just enough to check cleanup order.
typedef struct {BOOL sensor;unsigned service;uint32_t interval;BOOL uarp;uint16_t rootType,childType;} WireFrame;
static NSArray<NSValue *> *wireFramesSince(NSOutputStream *output,NSUInteger start) {
    NSData *wire=[output propertyForKey:NSStreamDataWrittenToMemoryStreamKey];NSMutableArray *frames=NSMutableArray.array;
    const uint8_t *w=wire.bytes;NSUInteger i=start;
    while(i+8<=wire.length && !memcmp(w+i,"\x04\x00\x04\x00",4)) {
        WireFrame f={0};
        if(w[i+4]==0x17 && i+12<=wire.length) {
            NSUInteger size=w[i+10]|w[i+11]<<8;if(i+12+size>wire.length) break;
            NSData *message=[wire subdataWithRange:NSMakeRange(i+12,size)];NSUInteger k=1;uint64_t sequence=0;
            const uint8_t *m=message.bytes;
            if(size>1 && m[0]==8 && readVarint(message,&k,&sequence) && k+13<=size && m[k]==66 && m[k+1]==11) {f.sensor=YES;f.service=m[k+3];f.interval=le32(m+k+9);}
            i+=12+size;
        } else if(w[i+4]==0x4f) {
            NSUInteger size=w[i+6]|w[i+7]<<8;if(i+8+size>wire.length || size<6) break;
            f.uarp=YES;f.rootType=be16(w+i+8);if(f.rootType==0x1b && size>=14) f.childType=be16(w+i+16);
            i+=8+size;
        } else break;
        [frames addObject:[NSValue valueWithBytes:&f objCType:@encode(WireFrame)]];
    }
    return frames;
}
static WireFrame frameAt(NSArray<NSValue *> *frames,NSUInteger index) {WireFrame f={0};if(index<frames.count) [frames[index] getValue:&f];return f;}
static NSUInteger wireLength(NSOutputStream *output) {return [(NSData *)[output propertyForKey:NSStreamDataWrittenToMemoryStreamKey] length];}
// Self-test only (--self-test-watchdog-child fire|disarm): raise SIGTERM, then
// block the main thread without pumping or cleaning up, as a stuck synchronous
// Bluetooth call would. No Bluetooth, IOBluetooth or CoreBluetooth calls.
static int watchdogChild(const char *mode) {
    BOOL disarm=!strcmp(mode,"disarm");
    terminationWatchdogSeconds=disarm?.5:.3;installTerminationHandlers();kill(getpid(),SIGTERM);
    double until=NSProcessInfo.processInfo.systemUptime+.4;
    while(!terminationRequested() && NSProcessInfo.processInfo.systemUptime<until) usleep(1000);
    if(!terminationRequested()) return 99;
    if(disarm) resetTerminationForTest();
    sleep(2);
    return 0;
}
static int watchdogChildStatus(const char *mode) {
    NSString *path=NSBundle.mainBundle.executablePath?:NSProcessInfo.processInfo.arguments.firstObject;
    if(!path) return -1;
    pid_t child=0;char *const args[]={(char *)path.fileSystemRepresentation,"--self-test-watchdog-child",(char *)mode,NULL};
    if(posix_spawn(&child,path.fileSystemRepresentation,NULL,NULL,args,*_NSGetEnviron())!=0) return -1;
    int status=0;double until=NSProcessInfo.processInfo.systemUptime+6;
    while(waitpid(child,&status,WNOHANG)==0) {
        if(NSProcessInfo.processInfo.systemUptime>until) {kill(child,SIGKILL);waitpid(child,&status,0);return -2;}
        usleep(20000);
    }
    return WIFEXITED(status)?WEXITSTATUS(status):-3;
}
static void hardeningChecks(void) {
    // Exit-code table: stable, distinct, documented, and clear of shell/signal values.
    size_t entries=sizeof(helperExitTable)/sizeof(helperExitTable[0]);NSMutableSet *codes=NSMutableSet.set,*names=NSMutableSet.set;BOOL tableValid=YES;
    for(size_t i=0;i<entries;i++) {
        const HelperExitInfo e=helperExitTable[i];
        if(e.code<0 || e.code==1 || e.code>=100 || !strlen(e.name) || !strlen(e.meaning)) tableValid=NO;
        [codes addObject:@(e.code)];[names addObject:@(e.name)];
    }
    check(tableValid && codes.count==entries && names.count==entries && entries==35,@"退出码表含 35 个不同的已说明代码, 均小于 100 且不为 1");
    const int required[]={HelperExitBluetoothNotAuthorized,HelperExitTargetNotPaired,HelperExitChannelNotObtained,HelperExitReconnectFailed,HelperExitReplyTimeout,
        HelperExitMotionStale,HelperExitUnexpectedReply,HelperExitLeaseExpired,HelperExitMotionPipeClosed,HelperExitPrivateAPIMissing,HelperExitSignaled,HelperExitNoSessionReply,
        HelperExitInputEnded,HelperExitCleanupTimeout};
    NSMutableSet *requiredSet=NSMutableSet.set;BOOL listed=YES;
    for(size_t i=0;i<sizeof(required)/sizeof(required[0]);i++) {[requiredSet addObject:@(required[i])];if(!helperExitInfo(required[i]) || !required[i]) listed=NO;}
    check(listed && requiredSet.count==sizeof(required)/sizeof(required[0]),@"each named failure has its own nonzero listed code");
    check(helperExitInfo(HelperExitOK)->code==0 && !helperExitInfo(99),@"exit names resolve and unknown codes are reported as such");
    check(sessionExitCode(HelperExitLeaseExpired,@"sensor STOP write failed",HelperExitSensorStopFailed,YES)==HelperExitLeaseExpired,@"lease expiry outranks a later cleanup failure");
    check(sessionExitCode(0,nil,0,YES)==HelperExitOK && sessionExitCode(0,nil,0,NO)==HelperExitIncomplete,@"app stop request is success even before the case was reached");
    check(sessionExitCode(0,@"scoped case cleanup acknowledgement unavailable",HelperExitReleaseUnconfirmed,YES)==HelperExitReleaseUnconfirmed,@"an unconfirmed release after a stop has its own code");
    check(sessionExitCode(HelperExitSignaled,nil,0,NO)==HelperExitSignaled && sessionExitCode(0,@"x",0,NO)==HelperExitUnexpectedReply,@"signals report SIGNALED; an uncoded error still exits nonzero");

    // Firmware ModelName matching: tolerant, but still tells the earbud from the case.
    check(earbudModelMatches(@"AirPods Pro") && earbudModelMatches(@" airpods pro\n") && earbudModelMatches(@"AirPods Pro 3") && earbudModelMatches(@"AIRPODS PRO\0"),@"earbud ModelName match ignores case, padding and a model suffix");
    check(earbudModelMatches(@"AirPods") && earbudModelMatches(@"AirPods 4") && earbudModelMatches(@"AirPods 4 ANC") && earbudModelMatches(@" airpods 4\n"),@"earbud match accepts the AirPods 4 ModelName forms");
    check(!earbudModelMatches(@"AirPods Charging Case") && !earbudModelMatches(@"AirPods Pro Case") && !earbudModelMatches(@"AirPods 3") && !earbudModelMatches(@"AirPods Max") && !earbudModelMatches(@"Invalid model response") && !earbudModelMatches(nil),@"earbud match rejects the case, other models and missing names");
    check(chargingCaseModelMatches(@"AirPods Charging Case") && chargingCaseModelMatches(@"airpods charging case ") && chargingCaseModelMatches(@"AirPods Pro Charging Case"),@"case ModelName match ignores case and padding");
    check(chargingCaseModelMatches(@"Charging Case") && chargingCaseModelMatches(@"AirPods Pro Case") && chargingCaseModelMatches(@" airpods pro case\n"),@"case match accepts the AirPods 4 case ModelName forms");
    check(chargingCaseModelMatches(@"Wireless Charging Case") && chargingCaseModelMatches(@"AirPods Wireless Charging Case") && chargingCaseModelMatches(@" wireless charging case\n") && chargingCaseModelMatches(@"MagSafe Charging Case"),@"case match accepts the AirPods 4 ANC Wireless Charging Case and MagSafe Charging Case ModelNames");
    check(!chargingCaseModelMatches(@"AirPods Pro") && !chargingCaseModelMatches(@"AirPods") && !chargingCaseModelMatches(@"Charging") && !chargingCaseModelMatches(nil),@"case match rejects the earbud name and non-case names");
    check(chargingCaseModelMatches(@"MagSafe Charging Case (USB-C)") && earbudModelMatches(@"AirPods Pro 2"),@"AirPods Pro 2 USB-C earbud and MagSafe case ModelNames are accepted");
    check(!chargingCaseModelMatches(@"MagSafe Charger") && !earbudModelMatches(@"MagSafe Charging Case (USB-C)"),@"MagSafe charger and the MagSafe case are not taken for the case or the earbud");
    CaseSnapshot *root=CaseSnapshot.new;root.targetBound=YES;root.rootModelSent=YES;
    [root handleMessage:uarpMessage(4,1,testModel(@"AirPods Pro 3"))];
    check(root.rootVerified && !root.error,@"root identity accepts a later AirPods Pro ModelName");
    CaseSnapshot *wrongRoot=CaseSnapshot.new;wrongRoot.targetBound=YES;wrongRoot.rootModelSent=YES;
    [wrongRoot handleMessage:uarpMessage(4,1,testModel(@"AirPods Charging Case"))];
    check(!wrongRoot.rootVerified && wrongRoot.failure==HelperExitWrongEarbudModel,@"a case ModelName at the root exits WRONG_EARBUD_MODEL");
    CaseSnapshot *airPods4Root=CaseSnapshot.new;airPods4Root.targetBound=YES;airPods4Root.rootModelSent=YES;
    [airPods4Root handleMessage:uarpMessage(4,1,testModel(@"AirPods"))];
    check(airPods4Root.rootVerified && !airPods4Root.error,@"root identity accepts AirPods 4's bare AirPods ModelName");
    CaseSnapshot *airPods4AncRoot=CaseSnapshot.new;airPods4AncRoot.targetBound=YES;airPods4AncRoot.rootModelSent=YES;
    [airPods4AncRoot handleMessage:uarpMessage(4,1,testModel(@"AirPods 4 ANC"))];
    check(airPods4AncRoot.rootVerified && !airPods4AncRoot.error,@"root identity accepts AirPods 4 ANC's ModelName");
    CaseSnapshot *tolerant=testSession();[tolerant.announced addObject:@1];tolerant.caseActive=YES;tolerant.caseModelSent=YES;tolerant.pending=@"model";
    [tolerant handleMessage:testChild(4,10,testModel(@"airpods charging case"))];
    check(tolerant.caseModelVerified && !tolerant.error,@"case identity accepts a case-insensitive ModelName");
    CaseSnapshot *peerAsCase=testSession();[peerAsCase.announced addObject:@1];peerAsCase.caseActive=YES;peerAsCase.caseModelSent=YES;peerAsCase.pending=@"model";
    [peerAsCase handleMessage:testChild(4,10,testModel(@"AirPods Pro"))];
    check(!peerAsCase.caseModelVerified && peerAsCase.failure==HelperExitWrongCaseModel,@"earbud ModelName on endpoint 1 exits WRONG_CASE_MODEL");
    CaseSnapshot *airPods4Case=testSession();[airPods4Case.announced addObject:@1];airPods4Case.caseActive=YES;airPods4Case.caseModelSent=YES;airPods4Case.pending=@"model";
    [airPods4Case handleMessage:testChild(4,13,testModel(@"Charging Case"))];
    check(airPods4Case.caseModelVerified && !airPods4Case.error,@"case identity accepts AirPods 4's bare Charging Case ModelName");
    CaseSnapshot *airPods4ProCase=testSession();[airPods4ProCase.announced addObject:@1];airPods4ProCase.caseActive=YES;airPods4ProCase.caseModelSent=YES;airPods4ProCase.pending=@"model";
    [airPods4ProCase handleMessage:testChild(4,14,testModel(@"AirPods Pro Case"))];
    check(airPods4ProCase.caseModelVerified && !airPods4ProCase.error,@"case identity accepts AirPods 4's AirPods Pro Case ModelName");
    CaseSnapshot *airPods4AncCase=testSession();[airPods4AncCase.announced addObject:@1];airPods4AncCase.caseActive=YES;airPods4AncCase.caseModelSent=YES;airPods4AncCase.pending=@"model";
    [airPods4AncCase handleMessage:testChild(4,15,testModel(@"Wireless Charging Case"))];
    check(airPods4AncCase.caseModelVerified && !airPods4AncCase.error,@"case identity accepts the AirPods 4 ANC Wireless Charging Case ModelName");
    CaseSnapshot *refresh=testSession();[refresh.announced addObject:@1];refresh.caseActive=YES;refresh.caseModelVerified=YES;refresh.caseIdentity=@"AirPods Charging Case";refresh.pending=@"identity_refresh";
    [refresh handleMessage:testChild(4,11,testModel(@"AirPods Charging Case "))];
    check(!refresh.error && refresh.identityRefreshReplies==1,@"identity refresh accepts the same case ModelName tolerantly");
    refresh.pending=@"identity_refresh";[refresh handleMessage:testChild(4,12,testModel(@"AirPods Pro Charging Case"))];
    check(refresh.failure==HelperExitWrongCaseModel,@"identity refresh still rejects a different case model");

    // Failure codes from real protocol paths, and first-cause-wins.
    uint8_t versionReply[]={0,0,0,6,0,0},announce[]={0,1},receipt[]={0,0,0,0,'M','T','I','C'},denial[]={'M','T','I','C',0,0x1a};
    CaseSnapshot *replay=testSession();[replay.announced addObject:@1];replay.caseActive=YES;replay.caseVersionFrames=1;replay.pending=@"version";
    [replay handleMessage:testChild(2,9,packet(versionReply,6))];[replay handleMessage:testChild(2,9,packet(versionReply,6))];
    NSString *firstError=replay.error;[replay fail:HelperExitReplyTimeout reason:@"later problem"];
    check(replay.failure==HelperExitUnexpectedReply && [replay.error isEqualToString:firstError],@"replayed reply exits UNEXPECTED_REPLY and a later failure cannot replace it");
    CaseSnapshot *late=testSession();late.pending=@"solicit";late.pendingSince=10;[late tick:15];
    check(late.failure==HelperExitReplyTimeout,@"a missing case reply exits REPLY_TIMEOUT");
    CaseSnapshot *lostCase=testSession();[lostCase.announced addObject:@1];lostCase.caseActive=YES;[lostCase handleMessage:uarpMessage(0x19,12,packet(announce,2))];
    check(lostCase.failure==HelperExitCaseLost,@"case unreachable announcement exits CASE_LOST");
    CaseSnapshot *refused=testSession();[refused.announced addObject:@1];refused.caseActive=YES;refused.caseModelVerified=YES;refused.caseRouteDrained=YES;
    [refused tick:10];[refused handleMessage:testChild(0x12,53,packet(receipt,8))];[refused handleMessage:testChild(0x13,54,packet(denial,6))];
    check(refused.failure==HelperExitCaseDeclined,@"case rejection exits CASE_DECLINED");
    CaseSnapshot *statusRefused=testSession();[statusRefused.announced addObject:@1];statusRefused.caseActive=YES;statusRefused.caseModelVerified=YES;statusRefused.caseRouteDrained=YES;
    [statusRefused tick:10];NSMutableData *nonzero=[packet(receipt,8) mutableCopy];((uint8_t *)nonzero.mutableBytes)[3]=1;[statusRefused handleMessage:testChild(0x12,55,nonzero)];
    check(statusRefused.failure==HelperExitCaseDeclined,@"nonzero receipt status exits CASE_DECLINED");
    CaseSnapshot *badTag=testSession();[badTag.announced addObject:@1];badTag.caseActive=YES;badTag.caseModelVerified=YES;badTag.caseRouteDrained=YES;
    [badTag tick:10];NSMutableData *logsTag=[packet(receipt,8) mutableCopy];((uint8_t *)logsTag.mutableBytes)[4]='L';[badTag handleMessage:testChild(0x12,56,logsTag)];
    check(badTag.failure==HelperExitUnexpectedReply,@"malformed receipt exits UNEXPECTED_REPLY");
    CaseSnapshot *silentRoot=testSession();silentRoot.rootVerified=NO;silentRoot.rootModelSent=YES;silentRoot.rootModelSince=10;[silentRoot tick:18];
    check(silentRoot.failure==HelperExitIdentityUnavailable,@"missing earbud ModelName exits IDENTITY_UNAVAILABLE");
    // A pointer session keeps going without case replies: motion decides, and a late reply is harmless.
    CaseSnapshot *missed=testSession();missed.caseModelVerified=YES;missed.caseIdentity=@"AirPods Charging Case";missed.pending=@"identity_refresh";missed.pendingSince=100;[missed tick:106];
    check(!missed.error && !missed.pending && missed.missedReplies==1,@"a pointer session survives a missed identity reply");
    [missed handleMessage:testChild(4,1300,testModel(@"AirPods Charging Case"))];check(!missed.error,@"a late identity reply doesn't end a pointer session");
    CaseSnapshot *noCaseYet=testSession();[noCaseYet.announced addObject:@1];noCaseYet.caseActive=YES;
    for(int t=100;t<=300;t++) [noCaseYet tick:t];
    check(!noCaseYet.error && noCaseYet.caseRequests>0 && !noCaseYet.caseModelVerified,@"a pointer session doesn't end when the case can't be identified");

    // Root VERSION heartbeat: a lost reply is re-asked, then ends the session; never silent.
    check(steadyRootVersionAction(NO,YES,5,100)==RootVersionWait && steadyRootVersionAction(YES,NO,0,100)==RootVersionWait,@"heartbeat recovery applies only to a pending steady-state query");
    check(steadyRootVersionAction(YES,YES,1,7.99)==RootVersionWait && steadyRootVersionAction(YES,YES,1,8)==RootVersionResend && steadyRootVersionAction(YES,YES,2,8)==RootVersionResend,@"an overdue root reply is re-asked after eight seconds, at most twice");
    check(steadyRootVersionAction(YES,YES,3,7.99)==RootVersionWait && steadyRootVersionAction(YES,YES,3,8)==RootVersionFail,@"a third overdue root reply ends the session as REPLY_TIMEOUT");

    // Reconnect: retries about 1 s apart, stops once connected, gives up after the bound.
    __block BOOL up=NO;__block NSUInteger opens=0,waits=0;__block double spacingSeen=0;__block NSUInteger succeedOn=0,repageOn=0;
    BOOL (^connected)(void)=^BOOL{return up;};
    IOReturn (^open)(void)=^IOReturn{opens++;if(succeedOn && opens>=succeedOn){up=YES;return kIOReturnSuccess;}return kIOReturnError;};
    void (^wait)(double)=^(double seconds){waits++;spacingSeen=seconds;if(repageOn && waits>=repageOn) up=YES;};
    NSUInteger made=0;up=YES;
    check(reopenOrdinaryLink(connected,open,wait,3,1,&made) && made==0 && opens==0,@"an already reconnected link is not reopened again");
    up=NO;opens=0;waits=0;succeedOn=3;
    check(reopenOrdinaryLink(connected,open,wait,3,1,&made) && made==3 && opens==3 && spacingSeen==1,@"two failed reopens are retried about one second apart");
    up=NO;opens=0;waits=0;succeedOn=0;
    check(!reopenOrdinaryLink(connected,open,wait,3,1,&made) && made==3 && opens==3 && waits==3,@"reconnect gives up after exactly three attempts");
    up=NO;opens=0;waits=0;repageOn=1;
    check(reopenOrdinaryLink(connected,open,wait,3,1,&made) && made==1,@"a link macOS re-pages on its own ends the retries");

    // Private API guard.
    check([missingSelector(NSObject.new,requiredPeerSelectors()) isEqualToString:@"connectL2CAPCallback"] && missingSelector(nil,@[@"state"])!=nil && !missingSelector(NSObject.new,@[@"description"]),@"missing private selectors are reported by name instead of crashing");

    // Cleanup order: both sensor STOPs leave before the scoped Abandon.
    NSString *sequenceFile=[NSTemporaryDirectory() stringByAppendingPathComponent:[@"closed-case-sequence-selftest-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    sensorSequencePath=sequenceFile;
    CaseSnapshot *held=testSession();[held.announced addObject:@1];held.caseActive=YES;held.caseModelVerified=YES;held.caseRouteDrained=YES;
    held.offer=testOffer(7,35);held.offerMetadata=mticOffer(held.offer);[held tick:NSProcessInfo.processInfo.systemUptime];
    check(held.accepted,@"offline held asset accepted for the cleanup-order check");
    NSUInteger mark=wireLength(held.output);BOOL accelStop=NO,gyroStop=NO;
    stopSensorsThenRelease(held.output,held,YES,YES,&accelStop,&gyroStop);
    NSArray<NSValue *> *frames=wireFramesSince(held.output,mark);WireFrame f0=frameAt(frames,0),f1=frameAt(frames,1),f2=frameAt(frames,2);
    check(accelStop && gyroStop && frames.count==3 && f0.sensor && f0.service==11 && f0.interval==0 && f1.sensor && f1.service==12 && f1.interval==0,@"cleanup sends accel and gyro STOP first");
    check(f2.uarp && f2.rootType==0x1b && f2.childType==9 && held.cleanupWriteComplete && [held.pending isEqual:@"abandon_ack"],@"scoped Abandon follows the sensor STOPs");
    uint8_t abandoned[]={0,7,0,3};[held handleMessage:testChild(0xf,600,packet(abandoned,4))];
    check(held.cleanupAck && !held.error,@"release acknowledgement completes the cleanup");
    CaseSnapshot *partialStart=testSession();mark=wireLength(partialStart.output);
    stopSensorsThenRelease(partialStart.output,partialStart,YES,NO,&accelStop,&gyroStop);frames=wireFramesSince(partialStart.output,mark);
    check(frames.count==2 && frameAt(frames,0).service==11 && frameAt(frames,1).service==12 && partialStart.cleanupStarted && !partialStart.cleanupWriteComplete,@"a partial sensor start still stops both sensors; no asset means no Abandon");
    CaseSnapshot *assetOnly=testSession();[assetOnly.announced addObject:@1];assetOnly.caseActive=YES;assetOnly.caseModelVerified=YES;assetOnly.caseRouteDrained=YES;
    assetOnly.offer=testOffer(9,35);assetOnly.offerMetadata=mticOffer(assetOnly.offer);[assetOnly tick:NSProcessInfo.processInfo.systemUptime];mark=wireLength(assetOnly.output);
    stopSensorsThenRelease(assetOnly.output,assetOnly,NO,NO,&accelStop,&gyroStop);frames=wireFramesSince(assetOnly.output,mark);
    check(frames.count==1 && frameAt(frames,0).childType==9 && !accelStop && !gyroStop,@"sensors that were never started get no STOP; the held asset is still released");
    sensorSequencePath=@"/nonexistent-closed-case-folder/sequence.txt";
    check(![sensorSetting(11,5000) isEqualToData:sensorSetting(11,5000)],@"a sequence file that can't be written never repeats a number");
    unsavedSensorSequence=0;
    [NSFileManager.defaultManager removeItemAtPath:sequenceFile error:nil];sensorSequencePath=nil;

    // Stop requests written while the helper starts are honoured, not overwritten.
    NSURL *phase=[NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[@"closed-case-phase-selftest-" stringByAppendingString:NSUUID.UUID.UUIDString]]];
    check(!phaseIsStop(phase),@"missing phase file is not a stop request");
    [@"stop\n" writeToURL:phase atomically:YES encoding:NSUTF8StringEncoding error:nil];check(phaseIsStop(phase),@"app stop request is recognised with its newline");
    [@"open_baseline" writeToURL:phase atomically:YES encoding:NSUTF8StringEncoding error:nil];check(!phaseIsStop(phase),@"other phases are not stop requests");
    [NSFileManager.defaultManager removeItemAtURL:phase error:nil];

    // Signals: SIGTERM and SIGHUP set the cleanup flag instead of killing the process.
    installTerminationHandlers();
    const int signals[]={SIGTERM,SIGHUP};
    for(size_t i=0;i<2;i++) {
        resetTerminationForTest();
        kill(getpid(),signals[i]);
        double until=NSProcessInfo.processInfo.systemUptime+2;
        while(!terminationRequested() && NSProcessInfo.processInfo.systemUptime<until) pump(.01);
        check(atomic_load(&terminationSignal)==signals[i] && terminationNoticedAt>0,[NSString stringWithFormat:@"signal %d runs the cleanup path instead of terminating",signals[i]]);
        kill(getpid(),SIGINT);pump(.05);
        check(atomic_load(&terminationSignal)==signals[i],@"a repeated signal cannot restart or cut the cleanup");
    }
    resetTerminationForTest();
    // Watchdog, in a child copy of this binary in a self-test-only mode (no
    // Bluetooth): a main thread stuck after a signal still exits, a disarmed one never does.
    check(watchdogChildStatus("fire")==HelperExitCleanupTimeout,@"a main thread stuck after a signal exits CLEANUP_TIMEOUT");
    check(watchdogChildStatus("disarm")==0,@"a disarmed signal watchdog never fires");

    // Writes on a dropped link, and cleanup writes after a signal.
    const uint8_t probeBytes[]={0,1,2,3};NSData *probe=packet(probeBytes,sizeof(probeBytes));
    NSOutputStream *closedOut=[NSOutputStream outputStreamToMemory];[closedOut open];[closedOut close];
    double sentAt=NSProcessInfo.processInfo.systemUptime;BOOL closedSent=sendPacket(closedOut,probe,"offline write to a closed channel");
    check(!closedSent && streamEnded(closedOut) && NSProcessInfo.processInfo.systemUptime-sentAt<.5,@"a write to a channel the link closed fails at once instead of spinning for three seconds");
    NSOutputStream *liveOut=[NSOutputStream outputStreamToMemory];[liveOut open];
    check(!streamEnded(liveOut),@"an open channel is not treated as ended");
    atomic_store(&terminationSignal,SIGTERM);terminationNoticedAt=NSProcessInfo.processInfo.systemUptime-5;
    check(!sendPacket(liveOut,probe,"offline write after the signal budget"),@"outside cleanup, a write after a signal respects the spent two-second budget");
    cleanupStartedAt=NSProcessInfo.processInfo.systemUptime;
    check(sendPacket(liveOut,probe,"offline cleanup STOP"),@"sensor STOP still gets its own try after a blocked write spent the signal budget");
    cleanupStartedAt=0;resetTerminationForTest();[liveOut close];
    check(writeFailureMeansLinkEnded(HelperExitWriteFailed,0,YES) && writeFailureMeansLinkEnded(0,HelperExitWriteFailed,YES),@"a write failure on an ended channel reports INPUT_ENDED");
    check(!writeFailureMeansLinkEnded(0,HelperExitWriteFailed,NO) && !writeFailureMeansLinkEnded(HelperExitLeaseExpired,HelperExitWriteFailed,YES) && !writeFailureMeansLinkEnded(0,HelperExitReplyTimeout,YES),@"other failures and write failures on a live channel keep their codes");
}
static int offlineSelfTest(void) {
    double headphoneValues[6];
    check(headphoneMotionValues((CMAcceleration){0,0,-1},(CMAcceleration){.2,0,0},(CMRotationRate){M_PI/2,0,0},headphoneValues) && fabs(headphoneValues[0]-.2)<1e-9 && headphoneValues[2]==-1 && fabs(headphoneValues[3]-90)<1e-9,@"系统运动数据转换为 g 和 deg/s");
    check(!headphoneMotionValues((CMAcceleration){NAN,0,0},(CMAcceleration){0,0,0},(CMRotationRate){0,0,0},headphoneValues),@"忽略非有限的系统运动数据");
    FILE *headphoneFile=tmpfile();NSUInteger headphoneSequence=0;double frameValues[]={0,0,1,0,0,90};
    check(headphoneFile && writeHeadphoneMotionFrame(headphoneFile,&headphoneSequence,1234567,2,frameValues),@"系统运动帧写入七列管道");
    rewind(headphoneFile);char headphoneLine[256];unsigned long sequence1=0,sequence2=0;unsigned service1=0,service2=0;unsigned long long stamp1=0,stamp2=0;
    BOOL firstFrame=fgets(headphoneLine,sizeof(headphoneLine),headphoneFile) && sscanf(headphoneLine,"%lu,%u,%llu",&sequence1,&service1,&stamp1)==3;
    BOOL secondFrame=fgets(headphoneLine,sizeof(headphoneLine),headphoneFile) && sscanf(headphoneLine,"%lu,%u,%llu",&sequence2,&service2,&stamp2)==3;
    check(firstFrame && secondFrame && sequence1==1 && sequence2==2 && service1==11 && service2==12 && stamp1==1234567 && stamp2==stamp1,@"同帧加速度和角速度共享时间戳且序号递增");fclose(headphoneFile);
    sessionChecks();
    hardeningChecks();
    ConsoleReader *sensorReader=ConsoleReader.new;sensorReader.motionStream=tmpfile();check(sensorReader.motionStream!=NULL,@"offline sensor stream opened");testSensorWire(sensorReader,100);
    NSDictionary *firstSensor=sensorReader.lastSamples[@"11"];
    check(firstSensor,@"actual RTBuddy wire parser recognizes a fresh sensor timestamp");
    testSensorWire(sensorReader,100);testSensorWire(sensorReader,90);
    check(sensorReader.lastSamples[@"11"]==firstSensor,@"duplicate and backwards sensor packets cannot refresh the live arrival clock");
    testSensorWire(sensorReader,200);
    check([sensorReader.lastSamples[@"11"][@"sensor_us"] unsignedLongLongValue]==200,@"later advancing sensor data restores freshness");
    fflush(sensorReader.motionStream);rewind(sensorReader.motionStream);char sampleLine[256];unsigned streamLines=0;
    while(fgets(sampleLine,sizeof(sampleLine),sensorReader.motionStream)) {streamLines++;check(strstr(sampleLine,streamLines==1?"1,11,100,":"4,11,200,")==sampleLine,@"live stream retains advancing sequence and device clock");}
    check(streamLines==2 && !sensorReader.motionStreamFailed,@"duplicate and backwards reports do not enter the live pointer stream");fclose(sensorReader.motionStream);sensorReader.motionStream=NULL;
    uint8_t stateWire[]={4,0,4,0,6,0,0,2};ConsoleReader *stateObserver=ConsoleReader.new;
    NSInputStream *stateInput=[NSInputStream inputStreamWithData:packet(stateWire,8)];[stateInput open];[stateObserver stream:stateInput handleEvent:NSStreamEventHasBytesAvailable];[stateInput close];
    check(stateObserver.earbudStateEvents.count==1 && [stateObserver.earbudStateEvents[0][@"primary_code"] intValue]==0 && [stateObserver.earbudStateEvents[0][@"secondary_code"] intValue]==2 && stateObserver.buffer.length==0,@"passive earbud state notification retains only timestamp and raw primary/secondary codes");
    check(!retryInitialRootVersion(NO,1,7.99) && retryInitialRootVersion(NO,1,8),@"initial root metadata retries only after eight seconds");
    check(retryInitialRootVersion(NO,19,8) && !retryInitialRootVersion(NO,20,8),@"initial root metadata has a finite twenty-query cap");
    check(!retryInitialRootVersion(YES,1,8) && !retryInitialRootVersion(NO,0,8),@"bootstrap retries require a pending unanswered initial VERSION");
    check(mticOffer(testOffer(7,1))!=nil,@"one-byte MTIC accepted");
    check(mticOffer(testOffer(7,65536))!=nil,@"64 KiB bound accepted");
    check(mticOffer(testOffer(7,65537))==nil,@"oversized offer rejected");
    check(mticOffer(testOffer(7,0))==nil && mticOffer(testOffer(0,1))==nil && mticOffer(testOffer(0xffff,1))==nil,@"zero length and reserved asset IDs rejected");
    NSMutableData *bad=[testOffer(7,35) mutableCopy];((uint8_t *)bad.mutableBytes)[5]=1;
    check(mticOffer(bad)==nil && mticOffer([bad subdataWithRange:NSMakeRange(0,29)])==nil,@"flags and truncated offer rejected");
    uint8_t version[]={0,7},info[]={0,0,0,2},announce[]={0,1},versionReply[]={0,0,0,6,0,0};
    CaseSnapshot *s=CaseSnapshot.new;
    check(![s canSendRoot:1 body:packet(version,2)],@"unbound target cannot send");
    s=testSession();
    check(![s canSendChild:1 body:packet(version,2)],@"unannounced endpoint cannot send");
    check(![s canSendRoot:0x1b body:NSData.data] && ![s canSendRoot:0 body:NSData.data],@"no generic downstream or SYNC root command");
    [s handleMessage:uarpMessage(0x17,100,packet(announce,2))];
    [s handleMessage:testChild(5,200,testOffer(7,35))];
    check(s.offer!=nil && !s.receiptAttempted && ![s canSendChild:0xd body:s.offer],@"preidentity offer cached but cannot be ACKed");
    check(![s canSendChild:3 body:packet(info,4)],@"case Model requires case VERSION");
    [s tick:100];check(!s.pending && s.caseVersionFrames==1,@"initial metadata VERSION has no premature pending deadline");
    [s tick:105.1];check(!s.error && s.caseVersionFrames==1,@"first unanswered metadata survives five seconds without extra send");
    [s handleMessage:testChild(2,201,packet(versionReply,6))];[s tick:100.1];
    check(s.caseModelSent && [s.pending isEqual:@"model"],@"valid VERSION unlocks the single preidentity Model request");
    [s handleMessage:testChild(4,202,testModel(@"AirPods Charging Case"))];[s tick:100.2];
    check(s.caseModelVerified && s.accepted && s.receiptAttempted && !s.pending,@"exact case identity unlocks the actual offer");
    [s beginCleanup:100.4];uint8_t abandoned[]={0,7,0,3};[s handleMessage:testChild(0xf,205,packet(abandoned,4))];
    check(s.cleanupWriteComplete && s.cleanupAck && !s.pending,@"scoped Abandon requires matching actual asset acknowledgment");
    check(s.nextTXID==6 && s.nextChildID==5,@"root counter shared across metadata, ACK and cleanup; independent child counter");
    NSData *wire=[s.output propertyForKey:NSStreamDataWrittenToMemoryStreamKey];NSUInteger cursor=0,frames=0;BOOL wireValid=YES;
    while(cursor<wire.length) {
        const uint8_t *w=(const uint8_t *)wire.bytes+cursor;
        if(wire.length-cursor<14 || memcmp(w,"\x04\x00\x04\x00\x4f\x00",6)) {wireValid=NO;break;}
        NSUInteger length=w[6]|w[7]<<8;
        if(length+8>wire.length-cursor || length<6 || be16(w+10)+6!=length || be16(w+12)!=frames+1) {wireValid=NO;break;}
        uint16_t type=be16(w+8);
        if(type!=0x18 && (type!=0x1b || length<14 || be16(w+14)!=1)) {wireValid=NO;break;}
        frames++;cursor+=length+8;
    }
    check(wireValid && frames==5,@"serialized AACP framing, shared monotonic IDs and announced destination exact");
    CaseSnapshot *replay=testSession();[replay.announced addObject:@1];replay.caseActive=YES;replay.caseVersionFrames=1;replay.pending=@"version";
    [replay handleMessage:testChild(2,9,packet(versionReply,6))];[replay handleMessage:testChild(2,9,packet(versionReply,6))];
    check([replay.error containsString:@"replayed"],@"replayed independent response ID rejected");
    CaseSnapshot *wrong=testSession();[wrong.announced addObject:@1];wrong.caseActive=YES;wrong.caseModelSent=YES;wrong.pending=@"model";
    [wrong handleMessage:testChild(4,10,testModel(@"AirPods Pro"))];
    check(wrong.error!=nil && !wrong.caseModelVerified,@"peer earbud identity rejected for case");
    CaseSnapshot *unreachable=testSession();[unreachable.announced addObject:@1];unreachable.caseActive=YES;unreachable.caseRequests=2;
    [unreachable handleMessage:uarpMessage(0x19,12,packet(announce,2))];
    check(!unreachable.caseActive && unreachable.error!=nil && unreachable.caseRequests==2,@"unreachable case stops flow without resetting its budget");
    CaseSnapshot *partial=testSession();[partial.announced addObject:@1];partial.caseActive=YES;partial.receiptAttempted=YES;partial.assetID=7;partial.cleanupStarted=YES;
    uint8_t cleanupBody[]={0,7,0,3};check(![partial canSendChild:9 body:packet(cleanupBody,4)],@"failed or partial receipt ACK does not authorize Abandon");

    const uint8_t mtic[]={'M','T','I','C'},logs[]={'L','O','G','S'};
    const uint8_t receipt[]={0,0,0,0,'M','T','I','C'},denial[]={'M','T','I','C',0,0x1a};
    // Replay the actual failed setup shape: two VERSION sends, one current
    // VERSION reply, then the exact ModelName reply. The missing eight bytes
    // stay charged; this does not claim every startup response was received.
    CaseSnapshot *gap=testSession();[gap.announced addObject:@1];gap.caseActive=YES;
    double gapNow=NSProcessInfo.processInfo.systemUptime;
    [gap tick:gapNow];[gap tick:gapNow+8.1];[gap tick:gapNow+16.2];
    check(gap.caseVersionFrames==2 && gap.caseRequests==2 && !gap.error,@"ordered setup caps unanswered VERSION attempts at two");
    [gap handleMessage:testChild(2,1100,packet(versionReply,6))];[gap tick:gapNow+16.3];
    check([gap.pending isEqual:@"model"] && gap.modelSentAfterVersionFrames==2 && gap.caseRequests==3,@"fresh identity query follows the last startup VERSION and becomes the only pending operation");
    check(![gap canSendChild:1 body:packet(version,2)],@"no VERSION retry is allowed after the identity query");
    [gap handleMessage:testChild(4,1101,testModel(@"AirPods Charging Case"))];
    check([gap initializedCaseRoute] && !gap.caseRouteDrained && gap.startupUnknownBytes==8 && gap.unconfirmedBytes==8,@"current exact identity permits one explicitly charged missing startup response");
    [gap tick:gapNow+16.4];
    check([gap.pending isEqual:@"solicit"] && gap.unconfirmedBytes==18 && gap.solicitationAttempts==1,@"the recorded setup pattern reaches one ordinary bounded MTIC request");
    [gap handleMessage:testChild(0x12,1102,packet(receipt,8))];
    check(!gap.error && gap.solicitationReceipts==1 && gap.startupUnknownBytes==8 && gap.unconfirmedBytes==8,@"a current receipt cannot erase the unresolved startup byte charge");
    [gap handleMessage:testChild(5,1103,testOffer(7,35))];[gap tick:gapNow+16.5];
    check(gap.accepted && [gap.pending isEqual:@"identity_refresh"] && gap.startupUnknownBytes==8 && gap.unconfirmedBytes<=112,@"holding the offer retains the startup charge and existing flow limit");
    [gap handleMessage:testChild(4,1104,testModel(@"AirPods Charging Case"))];
    check(gap.identityRefreshReplies==1 && gap.startupUnknownBytes==8 && gap.unconfirmedBytes==8,@"an identity reply preserves unresolved setup accounting");
    [gap handleMessage:testChild(2,1105,packet(versionReply,6))];
    check(gap.caseRouteDrained && gap.startupUnknownBytes==0 && gap.unconfirmedBytes==0 && !gap.error,@"a late unique valid VERSION reply resolves the carried charge");
    CaseSnapshot *tooManyGaps=testSession();[tooManyGaps.announced addObject:@1];tooManyGaps.caseActive=YES;tooManyGaps.caseVersionValid=YES;tooManyGaps.caseVersionFrames=3;tooManyGaps.caseVersionReplies=1;tooManyGaps.caseModelSent=YES;tooManyGaps.modelSentAfterVersionFrames=3;tooManyGaps.unconfirmedBytes=26;[tooManyGaps setPending:@"model" at:gapNow];
    [tooManyGaps handleMessage:testChild(4,1200,testModel(@"AirPods Charging Case"))];
    check(tooManyGaps.error && ![tooManyGaps initializedCaseRoute] && !tooManyGaps.solicitationAttempted,@"more than one unknown startup response still blocks asset operations");
    CaseSnapshot *unorderedModel=testSession();[unorderedModel.announced addObject:@1];unorderedModel.caseActive=YES;unorderedModel.caseModelSent=YES;
    [unorderedModel handleMessage:testChild(4,1201,testModel(@"AirPods Charging Case"))];
    check(unorderedModel.error && !unorderedModel.caseModelVerified,@"an unrequested identity response cannot unlock the new setup path");
    CaseSnapshot *fresh=testSession();[fresh.announced addObject:@1];fresh.caseActive=YES;fresh.caseModelVerified=YES;fresh.caseRouteDrained=YES;
    check([fresh canSendChild:0x11 body:packet(mtic,4)] && ![fresh canSendChild:0x11 body:packet(logs,4)],@"only exact MTIC may be requested from an identified case with no offer");
    double freshNow=NSProcessInfo.processInfo.systemUptime;[fresh tick:freshNow];
    check(fresh.solicitationSent && fresh.caseRequests==1 && [fresh.pending isEqual:@"solicit"] && !fresh.receiptAttempted,@"a fresh session sends exactly one request without inventing an asset ID");
    check(![fresh canSendChild:0x11 body:packet(mtic,4)],@"no second request goes out while one is unanswered");
    [fresh handleMessage:testChild(0x12,50,packet(receipt,8))];[fresh tick:freshNow+.1];[fresh tick:freshNow+.5];
    check(fresh.solicitationReceiptVerified && !fresh.error && !fresh.pending && !fresh.accepted && fresh.caseRequests==1,@"successful BE32 receipt waits for a real offer without VERSION polling");
    CaseSnapshot *requested=testSession();[requested.announced addObject:@1];requested.caseActive=YES;requested.caseModelVerified=YES;requested.caseRouteDrained=YES;
    [requested tick:10];[requested handleMessage:testChild(5,51,testOffer(7,35))];[requested tick:10.1];
    check(!requested.accepted && [requested.pending isEqual:@"solicit"],@"an early actual offer cannot bypass the outstanding solicitation receipt");
    [requested handleMessage:testChild(0x12,52,packet(receipt,8))];[requested tick:10.2];[requested tick:12];
    check(requested.accepted && requested.assetID==7 && requested.caseVersionFrames==0 && !requested.error,@"receipt plus actual offer holds the asset without periodic VERSION negotiation");
    CaseSnapshot *declined=testSession();[declined.announced addObject:@1];declined.caseActive=YES;declined.caseModelVerified=YES;declined.caseRouteDrained=YES;
    [declined tick:10];[declined handleMessage:testChild(0x12,53,packet(receipt,8))];[declined handleMessage:testChild(0x13,54,packet(denial,6))];
    check(declined.error && declined.denialReceiptAttempted && declined.caseRequests==2 && !declined.accepted,@"exact MTIC rejection receives its narrow ordinary receipt and stops");
    check(![declined canSendChild:0x14 body:packet(denial,6)],@"rejection receipt cannot be repeated");
    CaseSnapshot *badReceipt=testSession();[badReceipt.announced addObject:@1];badReceipt.caseActive=YES;badReceipt.caseModelVerified=YES;badReceipt.caseRouteDrained=YES;
    [badReceipt tick:10];NSMutableData *badReceiptBody=[packet(receipt,8) mutableCopy];((uint8_t *)badReceiptBody.mutableBytes)[3]=1;
    [badReceipt handleMessage:testChild(0x12,55,badReceiptBody)];
    check(badReceipt.error && !badReceipt.solicitationReceiptVerified && !badReceipt.accepted,@"nonzero solicitation receipt status never authorizes the asset");
    CaseSnapshot *drain=testSession();[drain.announced addObject:@1];drain.caseActive=YES;drain.caseModelVerified=YES;
    [drain tick:10];[drain tick:15];
    check(drain.error && !drain.solicitationAttempted && !drain.caseRequests,@"incomplete startup accounting times out without an MTIC request");

    CaseSnapshot *timeout=testSession();timeout.pending=@"solicit";timeout.pendingSince=10;[timeout tick:14.99];
    check(!timeout.error,@"request survives before five-second boundary");[timeout tick:15];check(timeout.error!=nil,@"five-second deadline stops without retry");
    CaseSnapshot *budget=testSession();[budget.announced addObject:@1];budget.caseActive=YES;budget.caseInnerBytes=105;
    check(![budget canSendChild:1 body:packet(version,2)],@"unverified lifetime byte budget enforced");
    budget.caseInnerBytes=0;budget.unconfirmedBytes=105;check(![budget canSendChild:1 body:packet(version,2)],@"unconfirmed ring budget enforced");
    budget=testSession();[budget.announced addObject:@1];budget.caseActive=YES;budget.caseModelVerified=YES;budget.accepted=YES;budget.assetID=7;budget.budgetStartedAt=NSProcessInfo.processInfo.systemUptime;
    budget.windowRequests=119;check(![budget canSendChild:1 body:packet(version,2)],@"normal requests reserve the final cleanup operation");
    budget.cleanupStarted=YES;check([budget canSendChild:9 body:packet(cleanupBody,4)],@"reserved final operation permits scoped Abandon");
    budget.cleanupStarted=NO;budget.windowRequests=0;budget.windowBytes=4086;
    check(![budget canSendChild:1 body:packet(version,2)],@"normal requests reserve ten window bytes for cleanup");
    budget.cleanupStarted=YES;check([budget canSendChild:9 body:packet(cleanupBody,4)],@"reserved window bytes remain available for scoped Abandon");
    CaseSnapshot *gated=testSession();[gated.announced addObject:@1];gated.caseActive=YES;gated.closedWindowStarted=NO;
    [gated tick:100];check(gated.caseRequests==0 && ![gated canSendChild:1 body:packet(version,2)],@"closed mode sends no case metadata before local confirmation");
    gated.caseModelVerified=YES;gated.caseRouteDrained=YES;
    check(![gated canSendChild:0x11 body:packet(mtic,4)],@"closed mode cannot solicit analytics before confirmation even with exact cached identity");
    gated.offer=testOffer(7,35);gated.offerMetadata=mticOffer(gated.offer);[gated tick:101];check(!gated.accepted && gated.caseRequests==0,@"an early real offer cannot bypass the closed confirmation gate");
    double gatedNow=NSProcessInfo.processInfo.systemUptime;[gated confirmClosedAt:gatedNow];[gated tick:gatedNow+.1];check(gated.accepted && !gated.error,@"one closed marker unlocks the identified actual offer");
    CaseSnapshot *renew=testSession();[renew.announced addObject:@1];renew.caseActive=YES;renew.caseModelVerified=YES;renew.caseRouteDrained=YES;
    double renewNow=NSProcessInfo.processInfo.systemUptime;[renew tick:renewNow];
    check(renew.solicitationAttempts==1 && [renew.pending isEqual:@"solicit"] && !renew.solicitationReceiptVerified,@"renewal starts with one charged request and awaits its receipt");
    [renew handleMessage:testChild(0x12,70,packet(receipt,8))];[renew tick:renewNow+.1];
    check(![renew maySolicitAt:renew.lastSolicitationAt+.99] && [renew maySolicitAt:renew.lastSolicitationAt+1],@"renewal has a one-second minimum spacing");
    CaseSnapshot *lostReceipt=testSession();[lostReceipt.announced addObject:@1];lostReceipt.caseActive=YES;lostReceipt.caseModelVerified=YES;lostReceipt.caseRouteDrained=YES;
    [lostReceipt tick:renewNow];[lostReceipt tick:renewNow+5.1];[lostReceipt tick:renewNow+30];
    check(lostReceipt.error && lostReceipt.solicitationAttempts==1 && lostReceipt.caseRequests==1,@"missing receipt stops the session without a renewal");
    CaseSnapshot *renewOffer=testSession();[renewOffer.announced addObject:@1];renewOffer.caseActive=YES;renewOffer.caseModelVerified=YES;renewOffer.caseRouteDrained=YES;
    [renewOffer tick:renewNow];[renewOffer handleMessage:testChild(0x12,80,packet(receipt,8))];
    [renewOffer handleMessage:testChild(5,81,testOffer(7,35))];[renewOffer tick:NSProcessInfo.processInfo.systemUptime];
    renewOffer.lastSolicitationAt=NSProcessInfo.processInfo.systemUptime-30;[renewOffer tick:NSProcessInfo.processInfo.systemUptime];
    check(renewOffer.accepted && renewOffer.solicitationAttempts==1 && !renewOffer.error,@"an actual offer ends renewals");
    check(![renewOffer canSendChild:0x11 body:packet(mtic,4)],@"accepted asset cannot authorize another solicitation");
    printf("PASS: %lu focused offline checks; no Bluetooth or capture APIs called\n",testCount);return 0;
}


static int finishHelper(int code,NSString *detail) {
    const HelperExitInfo *info=helperExitInfo(code);
    printf("EXIT code=%d %s: %s%s%s\n",code,info?info->name:"UNKNOWN",info?info->meaning:"unlisted code",detail.length?" - ":"",detail.length?detail.UTF8String:"");
    return code;
}
static void waitForConnection(IOBluetoothDevice *device,double seconds) {
    NSDate *until=[NSDate dateWithTimeIntervalSinceNow:seconds];
    while(!device.isConnected && until.timeIntervalSinceNow>0) pump(.05);
}

int main(int argc, const char *argv[]) { @autoreleasepool {
    setbuf(stdout, NULL);
    if(argc==2 && !strcmp(argv[1],"--self-test")) return offlineSelfTest();
    if(argc==3 && !strcmp(argv[1],"--self-test-watchdog-child")) return watchdogChild(argv[2]);
    BOOL headphoneSession=argc==4 && !strcmp(argv[2],"--headphone-session");
    if(argc!=4 || (!headphoneSession && strcmp(argv[2],"--pointer-session"))) {puts("Usage: ClosedCaseMotion TARGET_ADDRESS_FILE --pointer-session|--headphone-session NEW_CAPTURE_DIRECTORY");return HelperExitUsage;}
    motionOnStdout=YES;
    sensorSequencePath=[@(argv[1]).stringByDeletingLastPathComponent stringByAppendingPathComponent:@"closed-case-sensor-sequence.txt"];
    // A closed parent pipe must never kill the helper mid-reconnect, and a
    // termination signal runs the cleanup path instead of killing it.
    signal(SIGPIPE,SIG_IGN);
    installTerminationHandlers();
    // stderr is the app's session-log pipe. If the app stops reading, drop
    // log lines rather than block the loop that checks the lease and motion.
    int errorFlags=fcntl(STDERR_FILENO,F_GETFL);if(errorFlags>=0) fcntl(STDERR_FILENO,F_SETFL,errorFlags|O_NONBLOCK);
    NSURL *directory=[NSURL fileURLWithPath:@(argv[3]) isDirectory:YES];
    if ([NSFileManager.defaultManager fileExistsAtPath:directory.path]) return finishHelper(HelperExitCaptureDir,@"capture directory already exists; stopped");
    if (![NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:nil]) return finishHelper(HelperExitCaptureDir,@"capture directory could not be created");
    NSURL *phaseURL=[directory URLByAppendingPathComponent:@"phase.txt"];
    if (CBManager.authorization != CBManagerAuthorizationAllowedAlways) return finishHelper(HelperExitBluetoothNotAuthorized,@"existing Bluetooth permission unavailable; stopped");
    NSString *target = [NSString stringWithContentsOfFile:@(argv[1]) encoding:NSUTF8StringEncoding error:nil];
    if (!target.length) return finishHelper(HelperExitTargetFile,@"target address file is missing or empty");
    IOBluetoothDevice *device = nil;
    for (IOBluetoothDevice *candidate in IOBluetoothDevice.pairedDevices) {
        if ([normalize(candidate.addressString) isEqualToString:normalize(target)]) { device = candidate; break; }
    }
    if (!device) return finishHelper(HelperExitTargetNotPaired,@"exact target is not among the paired devices; stopped");
    if(headphoneSession) return finishHelper(runHeadphoneSession(device,directory),nil);
    // Preflight every private API before anything disruptive happens.
    Class coordinatorClass=NSClassFromString(@"IOBluetoothCoreBluetoothCoordinator");
    if(!coordinatorClass || ![coordinatorClass respondsToSelector:@selector(sharedInstance)]) return finishHelper(HelperExitPrivateAPIMissing,@"IOBluetoothCoreBluetoothCoordinator.sharedInstance unavailable");
    id coordinator = [coordinatorClass sharedInstance];
    NSString *missing=missingSelector(coordinator,@[@"classicManager"]);
    if(missing) return finishHelper(HelperExitPrivateAPIMissing,[@"coordinator lacks " stringByAppendingString:missing]);
    id manager = [coordinator classicManager];
    if((missing=missingSelector(manager,@[@"state"]))) return finishHelper(HelperExitPrivateAPIMissing,[@"classic manager lacks " stringByAppendingString:missing]);
    if(![device respondsToSelector:@selector(peer)]) return finishHelper(HelperExitPrivateAPIMissing,@"IOBluetoothDevice lacks peer");
    NSDate *readyDeadline = [NSDate dateWithTimeIntervalSinceNow:8];
    while ((NSInteger)[manager state] != CBManagerStatePoweredOn && readyDeadline.timeIntervalSinceNow > 0 && !terminationRequested()) pump(.05);
    printf("Classic manager state=%ld; target connected=%d\n", (long)[manager state], device.isConnected);
    step("classic manager ready");
    if (terminationRequested()) return finishHelper(HelperExitSignaled,@"before any device change");
    if ((NSInteger)[manager state] != CBManagerStatePoweredOn) return finishHelper(HelperExitBluetoothUnavailable,@"classic manager did not power on within 8 s");
    if (!device.isConnected) return finishHelper(HelperExitTargetNotConnected,@"target is not connected; nothing was changed");
    {
        // Read-only look at the current peer: refuse before disconnecting if the
        // framework changed or another local client owns the callback.
        id existingPeer=[device peer];
        if(existingPeer) {
            if((missing=missingSelector(existingPeer,requiredPeerSelectors()))) return finishHelper(HelperExitPrivateAPIMissing,[@"Classic peer lacks " stringByAppendingString:missing]);
            if([existingPeer connectL2CAPCallback]) return finishHelper(HelperExitChannelBusy,@"local L2CAP callback already occupied; nothing was changed");
        }
    }
    if (phaseIsStop(phaseURL)) return finishHelper(HelperExitOK,@"stop requested before the reconnect; nothing was changed");
    {
        // WHY THIS CYCLE EXISTS. On an already-established link the peer's
        // openL2CAPChannel:0x1001 still delivers a CBL2CAPChannel with error 0,
        // and writes succeed, but no AACP reply ever arrives: two console captures
        // and two earlier hold and read probes on such a link got zero input
        // chunks. Opened right after one exact-target disconnect/reconnect, the
        // same setup gets genuine replies. A usable channel only exists in that
        // connect-time window, and probing the old link first would cost seconds and write the session
        // setup into a channel that never answers, so the cycle always runs.
        // Failure is made safe instead: the link is retried and never left
        // closed by this helper if it can be reopened.
        // A signal inside this window is deliberately deferred until the link
        // is back: typically 1-4 s, at worst about 23 s if every synchronous
        // openConnection runs to its page timeout. The disconnect wait is not
        // skipped, because a still-closing link would look connected and the
        // reopen would be skipped. After a signal only the retry spacing shrinks.
        printf("One exact-target reconnect: close=0x%08x\n",[device closeConnection]);
        NSDate *disconnectDeadline = [NSDate dateWithTimeIntervalSinceNow:3];
        while (device.isConnected && disconnectDeadline.timeIntervalSinceNow > 0) pump(.05);
        step("link closed");
        // The channel below only answers when it opens inside the connect-time window, and
        // isConnected reports the link a second or more after openConnection returns. So an
        // accepted reopen goes straight on, as it always did; waiting for the link there
        // missed the window (and let macOS take the channel callback). Only a refused
        // reopen is retried, and the end of the run reopens a link that is still down.
        IOReturn result=[device openConnection];
        NSUInteger tries=1;
        printf("Ordinary target reopen attempt 1/3=0x%08x\n",result);
        if(result!=kIOReturnSuccess) {
            NSUInteger more=0;
            BOOL back=reopenOrdinaryLink(^BOOL{return device.isConnected;},^IOReturn{return [device openConnection];},^(double seconds){waitForConnection(device,terminationRequested()?MIN(seconds,.5):seconds);},2,1.0,&more);
            tries+=more;
            if(!back) waitForConnection(device,2); // macOS can also re-page the AirPods on its own.
            if(terminationRequested()) puts("Signal arrived during the reconnect; exit deferred until the link restore finished");
            if(!device.isConnected) return finishHelper(HelperExitReconnectFailed,[NSString stringWithFormat:@"ordinary link still down after %lu reopen attempts",(unsigned long)tries]);
        }
        printf("Ordinary target reopen accepted after %lu attempt(s); link connected=%d\n",(unsigned long)tries,device.isConnected);
        step("link reopened");
    }
    // From here the link is up or coming up, so a signal or stop can simply end.
    if (terminationRequested()) return finishHelper(HelperExitSignaled,@"after the reconnect");
    if (phaseIsStop(phaseURL)) return finishHelper(HelperExitOK,@"stop requested after the reconnect");
    id peer = [device peer];
    if (!peer) return finishHelper(HelperExitChannelNotObtained,@"no Classic peer after the reconnect; ordinary link is connected");
    if ((missing=missingSelector(peer,requiredPeerSelectors()))) return finishHelper(HelperExitPrivateAPIMissing,[@"Classic peer lacks " stringByAppendingString:missing]);
    id peerManager = [peer manager];
    if ((missing=missingSelector(peerManager,@[@"state"]))) return finishHelper(HelperExitPrivateAPIMissing,[@"peer manager lacks " stringByAppendingString:missing]);
    printf("Target peer class=%s, state=%ld, internalState=%ld, owning manager state=%ld\n",
           NSStringFromClass([peer class]).UTF8String, [peer respondsToSelector:@selector(state)]?(long)[peer state]:-1L,
           [peer respondsToSelector:@selector(internalState)]?(long)[peer internalState]:-1L, (long)[peerManager state]);
    if ((NSInteger)[peerManager state] != CBManagerStatePoweredOn) return finishHelper(HelperExitBluetoothUnavailable,@"peer manager is not powered on");
    // No IOBluetooth channel has been constructed in this process. Do not
    // replace another local user's callback if the framework installed one.
    if ([peer connectL2CAPCallback]) return finishHelper(HelperExitChannelBusy,@"local L2CAP callback already occupied");
    __block BOOL completed = NO, opened = NO, usable = NO;
    __block CBL2CAPChannel *ownedChannel = nil;
    [peer setConnectL2CAPCallback:^(id channel, NSInteger error) {
        completed = YES;
        opened = channel != nil && error == 0;
        usable = opened && [channel respondsToSelector:@selector(inputStream)] && [channel respondsToSelector:@selector(outputStream)];
        if (usable) ownedChannel = channel;
        printf("Underlying channel callback: channel_present=%d, error=%ld\n", channel != nil, (long)error);
        if (channel) printf("Channel class=%s\n", NSStringFromClass([channel class]).UTF8String);
    }];
    puts("Opening PSM 0x1001 in this helper's own session; no device commands");
    [peer openL2CAPChannel:0x1001];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:10];
    while (!completed && deadline.timeIntervalSinceNow > 0 && !terminationRequested()) pump(.05);
    [peer setConnectL2CAPCallback:nil];
    step("channel opened");
    int code=HelperExitChannelNotObtained;NSString *detail=completed?@"channel callback reported an error":@"no channel callback within 10 s";
    if (opened) {
        if (!usable) {code=HelperExitPrivateAPIMissing;detail=@"channel object lacks input/output streams";}
        else if (terminationRequested()) {code=HelperExitSignaled;detail=@"before any device command";}
        else {code=runPointerSession(ownedChannel,directory);detail=nil;}
        [peer closeL2CAPChannel:0x1001];pump(terminationRequested()?.05:.2);
    } else if (terminationRequested()) {code=HelperExitSignaled;detail=@"while waiting for the channel";}
    // Asked to stop, the helper just ends: opening the lid or the next Connect brings the link back, and
    // reopening here held a disconnect up for 27 s while the shut case couldn't answer (2026-11-03).
    BOOL stopAsked=terminationRequested() || phaseIsStop(phaseURL);
    pump(stopAsked?.05:.5);
    if (!device.isConnected && !stopAsked) {
        // The session itself did not close this link, but never leave it down if it can be reopened.
        NSUInteger tries=0;
        reopenOrdinaryLink(^BOOL{return device.isConnected;},^IOReturn{return [device openConnection];},^(double seconds){waitForConnection(device,seconds);},2,terminationRequested()?1.0:3.0,&tries);
        printf("Restoring ordinary target connection: %s after %lu attempt(s)\n",device.isConnected?"connected":"still down",(unsigned long)tries);
    }
    printf("Result: completed=%d, opened=%d, exit=%d, target_connected=%d\n",
           completed, opened, code, device.isConnected);
    return finishHelper(code,detail);
} }
