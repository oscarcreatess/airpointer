#import <CoreMotion/CoreMotion.h>

// Convert to g and deg/s for the existing data stream.
static BOOL headphoneMotionValues(CMAcceleration gravity,CMAcceleration acceleration,CMRotationRate rotation,double values[6]) {
    values[0]=gravity.x+acceleration.x;values[1]=gravity.y+acceleration.y;values[2]=gravity.z+acceleration.z;
    values[3]=rotation.x*180/M_PI;values[4]=rotation.y*180/M_PI;values[5]=rotation.z*180/M_PI;
    for(unsigned i=0;i<6;i++) if(!isfinite(values[i]) || fabs(values[i])*1e5>INT32_MAX) return NO;
    return YES;
}

static BOOL writeHeadphoneMotionFrame(FILE *stream,NSUInteger *sequence,unsigned long long stamp,double host,const double values[6]) {
    // Both reports come from the same CMDeviceMotion sample.
    for(unsigned service=11;service<=12;service++) {
        unsigned offset=service==11?0:3;
        if(fprintf(stream,"%lu,%u,%llu,%.9f,%.0f,%.0f,%.0f\n",(unsigned long)++*sequence,service,
            stamp,host,values[offset]*1e5,values[offset+1]*1e5,values[offset+2]*1e5)<0) return NO;
    }
    return YES;
}

static BOOL otherHeadphonesConnected(IOBluetoothDevice *target) {
    // The system motion API cannot select a source by address, so reject the global source when another headset is connected.
    for(IOBluetoothDevice *device in IOBluetoothDevice.pairedDevices) {
        if([device.addressString isEqual:target.addressString] || !device.isConnected) continue;
        if(device.deviceClassMajor==kBluetoothDeviceClassMajorAudio &&
           (device.deviceClassMinor==kBluetoothDeviceClassMinorAudioHeadphones ||
            device.deviceClassMinor==kBluetoothDeviceClassMinorAudioHeadset ||
            device.deviceClassMinor==kBluetoothDeviceClassMinorAudioHandsFree)) return YES;
    }
    return NO;
}

static int runHeadphoneSession(IOBluetoothDevice *device,NSURL *directory) {
    if(!device.isConnected) return HelperExitTargetNotConnected;
    if(otherHeadphonesConnected(device)) return HelperExitMotionSourceAmbiguous;
    int flags=fcntl(STDOUT_FILENO,F_GETFL);
    if(flags<0 || fcntl(STDOUT_FILENO,F_SETFL,flags|O_NONBLOCK)<0) return HelperExitMotionPipeClosed;
    setvbuf(stdout,NULL,_IOLBF,0);
    CMHeadphoneMotionManager *manager=CMHeadphoneMotionManager.new;
    __block int failure=0;
    __block NSUInteger frames=0,sequence=0;
    __block double lastArrival=0,lastStamp=0;
    __block CMDeviceMotionSensorLocation source=CMDeviceMotionSensorLocationDefault;
    double began=NSProcessInfo.processInfo.systemUptime,nextStatus=0;
    NSURL *phaseURL=[directory URLByAppendingPathComponent:@"phase.txt"];
    NSURL *leaseURL=[directory.URLByDeletingLastPathComponent URLByAppendingPathComponent:@"app-lease.txt"];
    step("headphone motion started");
    [manager startDeviceMotionUpdatesToQueue:NSOperationQueue.mainQueue withHandler:^(CMDeviceMotion *motion,NSError *error) {
        if(failure || !device.isConnected) return;
        if(otherHeadphonesConnected(device)) {failure=HelperExitMotionSourceAmbiguous;return;}
        if(error) printf("Headphone motion error domain=%s code=%ld\n",error.domain.UTF8String,(long)error.code);
        if(!motion || !isfinite(motion.timestamp) || motion.timestamp<=0 || motion.timestamp<=lastStamp) return;
        double values[6];
        if(!headphoneMotionValues(motion.gravity,motion.userAcceleration,motion.rotationRate,values)) return;
        // Switching ears changes the sensor coordinate system.
        if(frames && motion.sensorLocation!=source) {failure=HelperExitMotionStale;return;}
        source=motion.sensorLocation;
        double host=NSProcessInfo.processInfo.systemUptime;
        unsigned long long stamp=(unsigned long long)llround(motion.timestamp*1e6);
        if(!writeHeadphoneMotionFrame(stdout,&sequence,stamp,host,values)) {failure=HelperExitMotionPipeClosed;return;}
        frames++;lastStamp=motion.timestamp;lastArrival=host;
    }];
    while(!failure) { @autoreleasepool {
        double now=NSProcessInfo.processInfo.systemUptime;
        if(terminationRequested()) {failure=HelperExitSignaled;break;}
        if(phaseIsStop(phaseURL)) break;
        if(!sessionLeaseFresh(leaseURL,now)) {failure=HelperExitLeaseExpired;break;}
        CMAuthorizationStatus authorization=CMHeadphoneMotionManager.authorizationStatus;
        if(authorization==CMAuthorizationStatusDenied || authorization==CMAuthorizationStatusRestricted) {failure=HelperExitMotionNotAuthorized;break;}
        if(otherHeadphonesConnected(device)) {failure=HelperExitMotionSourceAmbiguous;break;}
        if(!frames && now-began>15) {failure=HelperExitHeadphoneBaselineUnavailable;break;}
        // Closing the lid once interrupted motion for about 8 seconds; allow time for recovery.
        if(lastArrival && now-lastArrival>15) {failure=HelperExitMotionStale;break;}
        if(now>=nextStatus) {
            double age=lastArrival?now-lastArrival:100;
            BOOL fresh=device.isConnected && age<1;
            NSDictionary *state=@{@"updated_unix":@(NSDate.date.timeIntervalSince1970),
                @"open_baseline_verified":@(frames>=25),@"motion_backend":@"headphone",
                @"sensors":@[@{@"service":@11,@"age_seconds":@(age)},@{@"service":@12,@"age_seconds":@(age)}],
                @"case_snapshot":@{@"target_identity_verified":@YES,@"case_identity_verified":@NO,@"error":@""}};
            NSData *data=[NSJSONSerialization dataWithJSONObject:state options:NSJSONWritingPrettyPrinted error:nil];
            if(![data writeToURL:[directory URLByAppendingPathComponent:@"status.json"] atomically:YES]) {failure=HelperExitCaptureWrite;break;}
            printf("HOLD backend=headphone seconds=%.1f frames=%lu fresh=%d source=%ld\n",now-began,(unsigned long)frames,fresh,(long)source);
            nextStatus=now+.2;
        }
        pump(.02);
    }}
    [manager stopDeviceMotionUpdates];
    printf("Headphone motion stopped frames=%lu code=%d\n",(unsigned long)frames,failure);
    return failure;
}
