import AppKit
import ApplicationServices
import JavaScriptCore
import CryptoKit
import AVFoundation

struct ClosedCasePointerFilter{
    private var previous:CGPoint?,filtered:CGPoint?,time:Double?
    private var velocity=CGPoint.zero
    mutating func feed(_ point:CGPoint,at stamp:Double)->CGPoint{
        guard point.x.isFinite,point.y.isFinite,stamp.isFinite else{return filtered ?? CGPoint(x:0.5,y:0.5)}
        guard let previous,let filtered,let time else{
            self.previous=point;self.filtered=point;self.time=stamp;return point
        }
        let dt=stamp-time
        guard dt>0 else{return filtered}
        if dt>0.25{self=ClosedCasePointerFilter();return feed(point,at:stamp)}
        func alpha(_ cutoff:Double)->Double{dt/(dt+1/(2 * .pi * cutoff))}
        let derivativeAlpha=alpha(3)
        velocity.x+=derivativeAlpha*((point.x-previous.x)/dt-velocity.x)
        velocity.y+=derivativeAlpha*((point.y-previous.y)/dt-velocity.y)
        let cutoff=min(25,3.5+8*hypot(velocity.x,velocity.y)),a=alpha(cutoff)
        let next=CGPoint(x:filtered.x+a*(point.x-filtered.x),y:filtered.y+a*(point.y-filtered.y))
        self.previous=point;self.filtered=next;self.time=stamp;return next
    }
}

func readClosedCaseMotionPipe(_ stream:FileHandle) throws ->Data?{
    var bytes=[UInt8](repeating:0,count:32768)
    let count=Darwin.read(stream.fileDescriptor,&bytes,bytes.count)
    if count<0{
        if errno==EAGAIN || errno==EWOULDBLOCK || errno==EINTR{return nil}
        throw LessonError.message("Motion connection ended.")
    }
    return count>0 ? Data(bytes.prefix(count)):nil
}
func closedCaseConnectionFresh(reportAge:Double,sensorAges:[Double],motionAge:Double)->Bool{
    reportAge>=0 && reportAge<2 && sensorAges.count==2 &&
        (motionAge<0.5 || sensorAges.allSatisfy{$0>=0 && $0+reportAge<1})
}
func closedCaseShouldPause(motionAge:Double)->Bool{motionAge>2}
func closedCaseInCaseReports(_ value:Any?)->[(uptime:Double,primary:Int,secondary:Int)]{
    (value as? [[String:Any]] ?? []).compactMap{report in
        guard let uptime=report["received_uptime"] as? Double,let primary=report["primary_code"] as? Int,
              let secondary=report["secondary_code"] as? Int else{return nil}
        return (uptime,primary,secondary)
    }
}
func closedCaseTilt(_ a:[Double],_ b:[Double])->Double{
    let aa:Double=a.map{$0*$0}.reduce(0,+),bb:Double=b.map{$0*$0}.reduce(0,+),ab:Double=zip(a,b).map(*).reduce(0,+)
    let n=sqrt(aa*bb)
    return n>0 ? acos(max(-1,min(1,ab/n)))*180/Double.pi:0
}
func closedCaseUpright(_ g:[Double],closed:[Double],held:[Double]?)->Bool{
    closedCaseTilt(g,closed)>=35 || held.map{closedCaseTilt(g,$0)<=30} == true
}
final class TapClickSound {
    static let shared=TapClickSound()
    // A running engine starts a sound at once, where AVAudioPlayer holds its caller about 30 ms every time. Its queue keeps
    // Core Audio off the pointer's main run loop. It only ever uses the output: touching its input would open a microphone.
    private let engine=AVAudioEngine(),node=AVAudioPlayerNode(),queue=DispatchQueue(label:"airpointer.click-sound",qos:.userInteractive)
    private let buffer:AVAudioPCMBuffer?
    var loaded:Bool{buffer != nil}
    private init(){
        buffer=Bundle.main.url(forResource:"TapClick",withExtension:"wav").flatMap{url in
            guard let file=try? AVAudioFile(forReading:url),
                  let buffer=AVAudioPCMBuffer(pcmFormat:file.processingFormat,frameCapacity:AVAudioFrameCount(file.length)),
                  (try? file.read(into:buffer)) != nil else{return nil}
            return buffer
        }
        if let buffer{engine.attach(node);engine.connect(node,to:engine.mainMixerNode,format:buffer.format)}
    }
    // A change of output stops the engine, so anything that needs it brings it back.
    private func run(){
        guard buffer != nil,!engine.isRunning else{return}
        if (try? engine.start()) != nil{node.play()}
    }
    func start(){queue.async{self.run()}}
    func stop(){queue.async{self.node.stop();self.engine.stop()}}
    func play(){queue.async{
        self.run()
        if let buffer=self.buffer,self.engine.isRunning{self.node.scheduleBuffer(buffer,at:nil,options:.interrupts)}
    }}
}
func closedCaseLidClosed(_ reports:[(uptime:Double,primary:Int,secondary:Int)])->Bool{
    var closed=false,index=0
    while index<reports.count{
        let report=reports[index]
        if report.primary==3 || report.secondary==3{closed=true}
        else if index+1<reports.count,report.primary==2,report.secondary==2,reports[index+1].primary==2,
                reports[index+1].secondary==2,reports[index+1].uptime-report.uptime<=0.5{
            closed.toggle();index+=2;continue
        }
        index+=1
    }
    return closed
}

func loadClosedCaseCalibration(from url:URL,grip:URL,target:URL,
                              completion:@escaping(String?,[String:Any]?,[String:Any]?)->Void){
    DispatchQueue.global(qos:.utility).async{
        let hash=(try? Data(contentsOf:target)).map{SHA256.hash(data:$0).map{String(format:"%02x",$0)}.joined()}
        func saved(_ url:URL)->[String:Any]?{
            guard let hash,let data=try? Data(contentsOf:url),let value=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any],
                  value["target_sha256"] as? String==hash else{return nil}
            return value
        }
        let calibration=saved(url).flatMap{value->[String:Any]? in
            guard let time=value["updated_unix"] as? Double,(0..<7*86400).contains(Date().timeIntervalSince1970-time) else{return nil}
            return value
        }
        let edges=saved(grip)
        DispatchQueue.main.async{completion(hash,calibration,edges)}
    }
}
func saveClosedCaseJSON(_ value:[String:Any],to url:URL,onError:((String)->Void)?=nil){
    DispatchQueue.global(qos:.utility).async{
        do{
            try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
            try JSONSerialization.data(withJSONObject:value,options:.prettyPrinted).write(to:url,options:.atomic)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
        }catch{
            let message="Couldn’t save \(url.lastPathComponent): \(error.localizedDescription)"
            NSLog("%@",message)
            if let onError{DispatchQueue.main.async{onError(message)}}
        }
    }
}

func makeClosedCaseMotionContext(onError:((String)->Void)?=nil) throws -> JSContext {
    guard let url=Bundle.main.url(forResource:"ClosedCaseOrientation",withExtension:"js"),let context=JSContext() else{
        throw LessonError.message("The closed-case motion component is missing.")
    }
    let source=try String(contentsOf:url,encoding:.utf8).replacingOccurrences(of:"export ",with:"")
    context.exceptionHandler={ context,error in
        context?.exception=error
        onError?(error?.toString() ?? "Motion conversion failed.")
    }
    context.evaluateScript(source+"\nvar rawFusion=new Orientation(); var rawGrip=new Grip();")
    guard context.exception==nil else{throw LessonError.message("The motion component could not load.")}
    return context
}

final class ClosedCaseMotion {
    let context:JSContext
    static func make(onError:((String)->Void)?=nil) throws -> ClosedCaseMotion {
        ClosedCaseMotion(context:try makeClosedCaseMotionContext(onError:onError))
    }
    init(context:JSContext){self.context=context}
    var fusionReady:Bool{context.evaluateScript("rawFusion.ready")?.toBool()==true}
    var needsFirstOffset:Bool{context.evaluateScript("rawFusion.seed===null && !rawFusion.ready")?.toBool()==true}
    var edgesWithoutCenter:Bool{context.evaluateScript("rawGrip.edges!==null && !rawGrip.center")?.toBool()==true}
    var measured:Int{Int(context.evaluateScript("rawFusion.measured")?.toInt32() ?? 0)}
    var gripEdges:[String:Any]?{context.evaluateScript("rawGrip.edges")?.toDictionary() as? [String:Any]}
    var gripGravity:[Double]?{(context.evaluateScript("rawGrip.gravity")?.toArray() as? [Double]).flatMap{$0.count==3 ? $0:nil}}
    var accelVector:[Double]?{(context.evaluateScript("rawFusion.accel&&rawFusion.accel.vector")?.toArray() as? [Double]).flatMap{$0.count==3 ? $0:nil}}
    var calibrationValues:[String:Any]?{context.evaluateScript("({bias:rawFusion.bias,gravity:rawFusion.accel.vector})")?.toDictionary() as? [String:Any]}
    var settling:[String:Any]?{context.evaluateScript("rawFusion.settling()")?.toDictionary() as? [String:Any]}
    var lastException:String?{
        guard let error=context.exception else{return nil}
        context.exception=nil;return error.toString()
    }
    func loadCalibration(_ saved:[String:Any]){
        context.setObject(saved,forKeyedSubscript:"savedCalibration" as NSString)
        context.evaluateScript("rawFusion=new Orientation(savedCalibration)")
    }
    func loadGrip(_ saved:[String:Any]){
        context.setObject(saved,forKeyedSubscript:"savedGrip" as NSString)
        context.evaluateScript("rawGrip=new Grip(savedGrip)")
    }
    func resetGrip(keepingEdges:Bool=false){
        context.evaluateScript(keepingEdges ? "rawGrip=new Grip(rawGrip.edges)":"rawGrip=new Grip()")
    }
    func run(_ script:String)->JSValue?{
        context.exception=nil
        let value=context.evaluateScript(script)
        return context.exception==nil ? value:nil
    }
    func applyOverlayPoses(center:Pose,right:Pose,up:Pose)->String?{
        context.setObject([center,right,up].map{[$0.w,$0.x,$0.y,$0.z]},forKeyedSubscript:"capturedPoses" as NSString)
        _=run("rawGrip=new Grip();rawGrip.setCenter(capturedPoses[0],rawFusion.referenceGravity);rawGrip.setAxis('right',capturedPoses[1]);rawGrip.setAxis('up',capturedPoses[2])")
        return lastException
    }
    func recenter(to pose:[Double],force:Bool=false)->Bool?{
        context.setObject(pose,forKeyedSubscript:"capturedCenter" as NSString)
        let value=run("rawGrip.recenter(capturedCenter,rawFusion.referenceGravity,\(force))")
        if lastException != nil{return nil}
        return value?.toBool()
    }
    func feed(_ rows:[[Double]],plane:PointingPlane = .upright)->[String:Any]?{
        context.setObject(rows,forKeyedSubscript:"rawRows" as NSString)
        context.setObject(plane.rawValue,forKeyedSubscript:"rawPlane" as NSString)
        return run("""
        for(const row of rawRows)rawFusion.feed(row);
        ({ready:rawFusion.ready,generation:rawFusion.generation,measured:rawFusion.measured,
          gyro:rawFusion.last[12] || {},accel:rawFusion.last[11] || {},g:rawFusion.accel&&rawFusion.accel.vector,
          point:rawGrip.point(rawFusion.q,rawFusion.accel&&rawFusion.accel.vector,rawPlane),q:rawFusion.q,edges:rawGrip.edges!==null})
        """)?.toDictionary() as? [String:Any]
    }
}

struct ClosedCaseSessionLaunch:Equatable{
    var fromNotch=false
    var afterLoss=false
    func pointsWhenReady(setupVisible:Bool)->Bool{fromNotch || !setupVisible}
}

func runClosedCaseStageChecks()throws {
    let links:[(ClosedCaseStage,SetupLink)]=[
        (.off,.idle),(.openLid,.openLid),(.connecting,.connecting),(.closeLid,.closeLid),
        (.settling,.turnUpright),(.holding,.holdStill),(.calibrating,.connected),(.ready,.connected),(.pointing,.connected)
    ]
    for (stage,link) in links where stage.setupLink != link{
        throw LessonError.message("Stage \(stage) should map to setup link \(link).")
    }
    guard !ClosedCaseSessionLaunch().pointsWhenReady(setupVisible:true),ClosedCaseSessionLaunch(fromNotch:true).pointsWhenReady(setupVisible:true) else{
        throw LessonError.message("Sessions started during setup must not auto-point; notch starts should.")
    }
}

func closedCaseAppendingHandle(_ url:URL) throws -> FileHandle {
    let descriptor=open(url.path,O_WRONLY|O_APPEND|O_CREAT,0o600)
    guard descriptor>=0 else{throw CocoaError(.fileWriteNoPermission,userInfo:[NSFilePathErrorKey:url.path])}
    return FileHandle(fileDescriptor:descriptor,closeOnDealloc:true)
}

final class ClosedCaseHelperLog {
    let limit:Int
    private let folder:URL
    private var handle:FileHandle?,written=0,rotated=false
    init(folder:URL,limit:Int=1<<20) throws {
        self.folder=folder;self.limit=limit
        handle=try closedCaseAppendingHandle(folder.appendingPathComponent("native.log"))
    }
    func attach(_ pipe:Pipe) {
        pipe.fileHandleForReading.readabilityHandler={ reading in
            let data=reading.availableData
            if data.isEmpty{reading.readabilityHandler=nil;try? self.handle?.close();self.handle=nil}else{self.write(data)}
        }
    }
    func write(_ data:Data) {
        if written+data.count>limit {
            let current=folder.appendingPathComponent("native-recent.log")
            if rotated {
                let older=folder.appendingPathComponent("native-recent.1.log")
                try? FileManager.default.removeItem(at:older);try? FileManager.default.moveItem(at:current,to:older)
            }
            try? handle?.close();handle=try? closedCaseAppendingHandle(current);written=0;rotated=true
        }
        try? handle?.write(contentsOf:data);written+=data.count
    }
}

func pruneClosedCaseSessions(in root:URL,keeping count:Int) {
    let keys:[URLResourceKey]=[.creationDateKey,.isDirectoryKey]
    guard let entries=try? FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:keys,options:[.skipsHiddenFiles]) else{return}
    func created(_ url:URL)->Date{(try? url.resourceValues(forKeys:[.creationDateKey]).creationDate) ?? .distantPast}
    let sessions=entries.filter{UUID(uuidString:$0.lastPathComponent) != nil && (try? $0.resourceValues(forKeys:[.isDirectoryKey]).isDirectory)==true}
    for folder in sessions.sorted(by:{created($0)>created($1)}).dropFirst(max(0,count)){try? FileManager.default.removeItem(at:folder)}
}

func runClosedCaseNativeChecks() throws {
    let temporary=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
    try FileManager.default.createDirectory(at:temporary,withIntermediateDirectories:true)
    defer{try? FileManager.default.removeItem(at:temporary)}
    guard ClosedCaseAirPods.toolOutput("/bin/echo",["ok"],timeout:5)==Data("ok\n".utf8) else{throw LessonError.message("A system tool’s output should come back.")}
    guard ClosedCaseAirPods.toolOutput("/usr/bin/false",[],timeout:5)==nil else{throw LessonError.message("A failed system tool should give nothing.")}
    let toolBegan=ProcessInfo.processInfo.systemUptime
    guard ClosedCaseAirPods.toolOutput("/bin/sleep",["5"],timeout:0.2)==nil,ProcessInfo.processInfo.systemUptime-toolBegan<2 else{throw LessonError.message("A hung system tool should time out.")}
    let first=Data("1,11,1000000,1,0,0,100000\n".utf8)
    let pipe=Pipe();defer{try? pipe.fileHandleForReading.close();try? pipe.fileHandleForWriting.close()}
    let flags=fcntl(pipe.fileHandleForReading.fileDescriptor,F_GETFL)
    guard flags>=0,fcntl(pipe.fileHandleForReading.fileDescriptor,F_SETFL,flags|O_NONBLOCK)==0,
          try readClosedCaseMotionPipe(pipe.fileHandleForReading)==nil else{throw LessonError.message("An empty live pipe must not block.")}
    try pipe.fileHandleForWriting.write(contentsOf:first)
    guard try readClosedCaseMotionPipe(pipe.fileHandleForReading)==first,
          try readClosedCaseMotionPipe(pipe.fileHandleForReading)==nil else{throw LessonError.message("Live pipe data must remain ordered without polling delays.")}
    try pipe.fileHandleForWriting.close()
    guard try readClosedCaseMotionPipe(pipe.fileHandleForReading)==nil else{throw LessonError.message("Live pipe must finish cleanly.")}
    guard closedCaseConnectionFresh(reportAge:1.05,sensorAges:[0.01,0.02],motionAge:0.01),
          !closedCaseConnectionFresh(reportAge:3,sensorAges:[0,0],motionAge:0.01),
          !closedCaseShouldPause(motionAge:1.9),
          closedCaseShouldPause(motionAge:2.01) else{
        throw LessonError.message("Live motion freshness and bounded delivery-gap handling failed.")
    }
    func frame(_ status:UInt8,_ lid:UInt8,model:[UInt8]=[0x27,0x20],length:Int=29)->[UInt8]{
        Array(([0x4C,0,7,0x19,1]+model+[status,0x99,0x8F,lid,0,4]+[UInt8](repeating:0,count:16)).prefix(length))
    }
    guard closedCaseLidOpen(frame(0x24,0x11),productID:0x2027)==true,closedCaseLidOpen(frame(0x62,0x32),productID:0x2027)==true,
          closedCaseLidOpen(frame(0x24,0x19),productID:0x2027)==false,closedCaseLidOpen(frame(0x02,0x11),productID:0x2027)==nil,
          closedCaseLidOpen(frame(0x24,0x11,model:[0x14,0x20]),productID:0x2027)==nil,closedCaseLidOpen(frame(0x24,0x11,model:[0x14,0x20]),productID:0x2014)==true,
          closedCaseLidOpen(frame(0x24,0x11,length:27),productID:0x2027)==nil else{
        throw LessonError.message("The lid broadcast must be read only for this model with an earbud in the case.")
    }
    func lid(_ timeline:[(Double,Int,Int)])->Bool{closedCaseLidClosed(timeline.map{(uptime:$0.0,primary:$0.1,secondary:$0.2)})}
    let closedOnce:[(Double,Int,Int)]=[(0,2,2),(4.6,2,2),(4.7,2,2)]
    let closedTwice:[(Double,Int,Int)]=[(0,2,2),(1.1,2,2),(1.2,2,2),(2.3,2,2),(2.4,2,2),(12.8,2,2),(12.9,2,2),(16.7,2,3)]
    let budLifted:[(Double,Int,Int)]=[(0,2,2),(2.8,1,2),(2.9,1,2),(3.1,2,2),(4.7,2,2),(4.7,2,2),(8.7,2,3)]
    let reported=try JSONSerialization.jsonObject(with:Data(#"[{"received_uptime":1.5,"primary_code":2,"secondary_code":2,"source_opcode":6},{"primary_code":2}]"#.utf8))
    guard closedCaseInCaseReports(reported).count==1,
          !lid([]),!lid(Array(closedOnce.prefix(2))),lid(closedOnce),!lid([(0,2,2),(4.6,2,2),(5.4,2,2)]),
          lid(Array(closedTwice.prefix(3))),!lid(Array(closedTwice.prefix(5))),lid(Array(closedTwice.prefix(7))),lid(closedTwice),
          !lid(Array(budLifted.prefix(5))),lid(Array(budLifted.prefix(6))),lid([(0,2,2),(9,2,3)]) else{
        throw LessonError.message("The lid must follow paired in-case reports and ignore an earbud lifted out.")
    }
    let listing:[String:Any]=["SPBluetoothDataType":[[
        "controller_properties":["controller_state":"attrib_on"],
        "device_connected":[["Test AirPods Pro":["device_vendorID":"0x004C","device_productID":"0x2027","device_address":"0a-1b-2c-3d-4e-5f"]],
                            ["Test AirPods Pro":["device_address":"0A:1B:2C:3D:4E:60"]],
                            ["Keyboard":["device_vendorID":"0x3434","device_productID":"0x2027","device_address":"0A:1B:2C:3D:4E:61"]]],
        "device_not_connected":[["Spare AirPods Pro":["device_vendorID":"0x004C","device_productID":"0x2024","device_address":"0A:1B:2C:3D:4E:62"]],
                                ["AirPods":["device_vendorID":"0x004C","device_productID":"0x2002","device_address":"0A:1B:2C:3D:4E:63"]]]]]]
    guard let survey=ClosedCaseAirPods.parse(try JSONSerialization.data(withJSONObject:listing)),survey.poweredOn,
          survey.pairs.map(\.address)==["0A:1B:2C:3D:4E:5F","0A:1B:2C:3D:4E:62"],survey.pairs.map(\.connected)==[true,false],
          survey.pairs[1].title=="Spare AirPods Pro · AirPods Pro 2" else{
        throw LessonError.message("Paired AirPods must be found by vendor and product ID, not by name.")
    }
    let bothConnected=ClosedCaseAirPods.Survey(poweredOn:true,pairs:survey.pairs.map{ClosedCaseAirPods(name:$0.name,model:$0.model,address:$0.address,connected:true,productID:$0.productID)})
    guard ClosedCaseAirPods.choose(survey,saved:"0a:1b:2c:3d:4e:62") == .chosen(survey.pairs[1]),
          ClosedCaseAirPods.choose(survey,saved:nil) == .chosen(survey.pairs[0]),
          ClosedCaseAirPods.choose(bothConnected,saved:"0A:1B:2C:3D:4E:99") == .several,
          ClosedCaseAirPods.choose(ClosedCaseAirPods.Survey(poweredOn:true,pairs:[]),saved:"0A:1B:2C:3D:4E:5F") == .missing,
          ClosedCaseAirPods.choose(ClosedCaseAirPods.Survey(poweredOn:false,pairs:survey.pairs),saved:nil) == .bluetoothOff,
          ClosedCaseAirPods.choose(nil,saved:nil) == .unreadable,
          Set([ClosedCaseAirPods.Choice.missing,.several,.bluetoothOff,.unreadable].compactMap(\.failure)).count==4,
          Set((2...6).map(ClosedCaseAirPods.restoreFailure)).count==5,
          [0,46].allSatisfy({ClosedCaseAirPods.helperFailure($0,stopping:false)==nil}),
          [50,51,52,nil].allSatisfy({ClosedCaseAirPods.helperFailure($0,stopping:true)==nil && ClosedCaseAirPods.helperFailure($0,stopping:false) != nil}),
          [35,40,42,43,44].allSatisfy({ClosedCaseAirPods.lostContact($0)}),
          ([0,25,26,30,46,50,53,nil] as [Int32?]).allSatisfy({!ClosedCaseAirPods.lostContact($0)}),
          Set([2,3,10,12,20,21,22,23,24,25,26,27,28,30,31,32,34,35,36,40,41,42,43,44,45,50,51,52,53].compactMap{ClosedCaseAirPods.helperFailure($0,stopping:false)}).count==29 else{
        throw LessonError.message("Choosing AirPods, or wording why none could be chosen, failed.")
    }
    let logs=temporary.appendingPathComponent("logs",isDirectory:true)
    try FileManager.default.createDirectory(at:logs,withIntermediateDirectories:true)
    let helperLog=try ClosedCaseHelperLog(folder:logs,limit:100)
    for index in 0..<40{helperLog.write(Data(String(format:"line %02d of the helper log\n",index).utf8))}
    let head=try String(contentsOf:logs.appendingPathComponent("native.log"),encoding:.utf8)
    let recent=try String(contentsOf:logs.appendingPathComponent("native-recent.log"),encoding:.utf8)
    let sizes=try FileManager.default.contentsOfDirectory(atPath:logs.path).map{try Data(contentsOf:logs.appendingPathComponent($0)).count}
    guard head.hasPrefix("line 00"),recent.hasSuffix("line 39 of the helper log\n"),sizes.count==3,sizes.allSatisfy({$0<=100}) else{
        throw LessonError.message("The helper log did not keep its start and latest output within its bound.")
    }
    let sessions=temporary.appendingPathComponent("sessions",isDirectory:true)
    var made:[URL]=[]
    for index in 0..<4 {
        let folder=sessions.appendingPathComponent(UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        try (folder as NSURL).setResourceValue(Date(timeIntervalSince1970:Double(1_000_000+index*60)),forKey:.creationDateKey)
        made.append(folder)
    }
    let keep=sessions.appendingPathComponent("notes",isDirectory:true)
    try FileManager.default.createDirectory(at:keep,withIntermediateDirectories:true)
    pruneClosedCaseSessions(in:sessions,keeping:2)
    let left=Set(try FileManager.default.contentsOfDirectory(atPath:sessions.path))
    guard left==Set([made[2].lastPathComponent,made[3].lastPathComponent,"notes"]) else{
        throw LessonError.message("Session pruning did not keep exactly the newest sessions.")
    }
    let context=try makeClosedCaseMotionContext()
    context.evaluateScript("""
    var seq=0,stamp=1000000;
    function sample(g,w){stamp+=20000;rawFusion.feed([++seq,11,stamp,stamp/1e6,...g.map(x=>Math.round(x*1e5))]);rawFusion.feed([++seq,12,stamp+3759,stamp/1e6,...w.map(x=>Math.round(x*1e5))]);}
    for(let i=0;i<110;i++)sample([0,0,1],[0.8,-0.3,0.4]);
    for(let i=0;i<50;i++)sample([0,0,1],[0.8,-0.3,30.4]);
    """)
    guard context.exception==nil,context.evaluateScript("rawFusion.ready")?.toBool()==true else{
        throw LessonError.message("Native JavaScript motion initialization failed.")
    }
    let degrees=context.evaluateScript("norm(rotation(rawFusion.q))*180/Math.PI")?.toDouble() ?? 0
    guard abs(degrees-30)<0.04 else{throw LessonError.message("Native raw orientation scale or integration failed.")}
    let warm=context.evaluateScript("JSON.stringify({bias:rawFusion.bias,q:rawFusion.q})")?.toString()
    context.evaluateScript("rawGrip=new Grip()")
    guard context.evaluateScript("rawFusion.ready")?.toBool()==true,
          context.evaluateScript("JSON.stringify({bias:rawFusion.bias,q:rawFusion.q})")?.toString()==warm else{
        throw LessonError.message("Opening closed-case grip calibration must preserve connection warm-up.")
    }
    let value=context.evaluateScript("({gyro:rawFusion.last[12],accel:rawFusion.last[11],point:[0.5,0.25],generation:rawFusion.generation})")?.toDictionary() as? [String:Any]
    guard let gyro=value?["gyro"] as? [String:Any],let host=gyro["host"] as? Double,host>0,
          let point=value?["point"] as? [Double],point==[0.5,0.25],value?["generation"] as? Int == 1 else{
        throw LessonError.message("Native motion bridge types failed.")
    }
    context.setObject([[1.0,11.0,5000000.0,5.0,0.0,0.0,100000.0]],forKeyedSubscript:"rawRows" as NSString)
    context.evaluateScript("for(const row of rawRows)rawFusion.feed(row)")
    guard context.exception==nil else{throw LessonError.message("Native sample array conversion failed.")}
    context.evaluateScript("rawGrip.setCenter(rawFusion.q);rawGrip.setAxis('right',rawFusion.q)")
    guard context.exception != nil else{throw LessonError.message("Native calibration errors must remain recoverable.")}
    context.exception=nil
    context.evaluateScript("rawGrip=new Grip()")
    guard context.exception==nil else{throw LessonError.message("Native calibration did not recover after a rejected pose.")}
    let dropped=try makeClosedCaseMotionContext()
    dropped.evaluateScript("""
    var seq=0,stamp=1000000;
    function sample(g,w){stamp+=20000;rawFusion.feed([++seq,11,stamp,stamp/1e6,...g.map(x=>Math.round(x*1e5))]);rawFusion.feed([++seq,12,stamp+3759,stamp/1e6,...w.map(x=>Math.round(x*1e5))]);}
    for(let i=0;i<110;i++)sample([0,0,1],[0,0,0]);
    var before=[...rawFusion.q];stamp+=1500000;
    for(let i=0;i<50;i++)sample([0,0,1],[0,0,30]);
    var short={generation:rawFusion.generation,degrees:norm(rotation(multiply(inverse(before),rawFusion.q)))*180/Math.PI};
    stamp+=2500000;sample([0,0,1],[0,0,0]);
    """)
    let short=dropped.evaluateScript("short")?.toDictionary() as? [String:Any]
    guard dropped.exception==nil,short?["generation"] as? Int==1,let turned=short?["degrees"] as? Double,abs(turned-29.4)<0.1,
          dropped.evaluateScript("rawFusion.generation")?.toInt32()==2 else{
        throw LessonError.message("A short motion drop must hold the pose and a long one must start over.")
    }
    dropped.evaluateScript("""
    var saved={right:[0.3,0,0],up:[0,0.3,0],gravity:[0,0,1],target_sha256:'x'},grip=new Grip(saved);
    var edges={kept:grip.recenter([1,0,0,0],[0,0,1]),center:grip.point([1,0,0,0]),right:grip.point([Math.cos(.075),Math.sin(.075),0,0]),
      swivelRight:grip.point([Math.cos(.075),Math.sin(.075),0,0],[0,0,1],'flatSwivel'),
      tiltCenter:grip.point([1,0,0,0],[0,0,1],'flatTilt'),
      tiltRight:grip.point([1,0,0,0],[0,0.15,Math.sqrt(1-0.0225)],'flatTilt'),
      parallel:new Grip({right:[0.3,0,0],up:[0.3,0.01,0],gravity:[0,0,1]}).edges===null,
      turned:new Grip(saved).recenter([Math.SQRT1_2,Math.SQRT1_2,0,0],[0,0,1]),fresh:new Grip().edges===null};
    """)
    let edges=dropped.evaluateScript("edges")?.toDictionary() as? [String:Any]
    func near(_ value:Any?,_ expected:[Double])->Bool{(value as? [Double]).map{zip($0,expected).allSatisfy{abs($0-$1)<1e-6} && $0.count==2} ?? false}
    guard dropped.exception==nil,edges?["kept"] as? Bool==true,near(edges?["center"],[0.5,0.5]),near(edges?["right"],[0.75,0.5]),
          near(edges?["swivelRight"],[0.75,0.5]),near(edges?["tiltCenter"],[0.5,0.5]),near(edges?["tiltRight"],[0.75,0.5]),
          edges?["parallel"] as? Bool==true,edges?["turned"] as? Bool==false,edges?["fresh"] as? Bool==true else{
        throw LessonError.message("Saved grip edges must recenter with one pose and refuse a different hold.")
    }
    let warmup=try makeClosedCaseMotionContext()
    warmup.evaluateScript("""
    var seq=0,stamp=1000000;
    function sample(o,g,w){stamp+=5000;o.feed([++seq,11,stamp,stamp/1e6,...g.map(x=>Math.round(x*1e5))]);o.feed([++seq,12,stamp+1000,stamp/1e6,...w.map(x=>Math.round(x*1e5))]);}
    var seeded=new Orientation({bias:[0.5,0.7,-0.2],gravity:[1,0,0]});sample(seeded,[0,0,1],[0.5,0.7,-0.2]);
    var saved={ready:seeded.ready,used:seeded.seedUsed,measured:seeded.measured};
    for(let i=0;i<500;i++)sample(seeded,[0,0,1],[0.6,0.7,-0.2]);
    var nudged={x:seeded.bias[0],measured:seeded.measured};
    var fresh=new Orientation(),readyAt=null;
    for(let i=0;i<400&&readyAt===null;i++){const k=Math.sin(i*0.55)*0.5;sample(fresh,[0,0,1],[0.4+k,0.7-k,-0.2+k*.5]);if(fresh.ready)readyAt=i*0.005;}
    var first={readyAt,bias:fresh.bias,measured:fresh.measured};
    """)
    let seededOffset=warmup.evaluateScript("saved")?.toDictionary() as? [String:Any]
    let nudgedOffset=warmup.evaluateScript("nudged")?.toDictionary() as? [String:Any]
    let firstOffset=warmup.evaluateScript("first")?.toDictionary() as? [String:Any]
    guard warmup.exception==nil,seededOffset?["ready"] as? Bool==true,seededOffset?["used"] as? Bool==true,seededOffset?["measured"] as? Int==0,
          let nudgedX=nudgedOffset?["x"] as? Double,abs(nudgedX-0.55)<0.005,nudgedOffset?["measured"] as? Int==1,
          let readyAt=firstOffset?["readyAt"] as? Double,readyAt<1.5,let firstBias=firstOffset?["bias"] as? [Double],
          abs(firstBias[0]-0.4)<0.1,abs(firstBias[1]-0.7)<0.1,abs(firstBias[2]+0.2)<0.1,firstOffset?["measured"] as? Int==1 else{
        throw LessonError.message("A saved offset must apply at once, a first one must allow a hand-held hold, and later ones must move it gently.")
    }
    let firstRun=try ClosedCaseMotion.make();let setsDown=firstRun.needsFirstOffset
    firstRun.loadCalibration(["bias":[0.1,0.1,0.1]])
    guard setsDown,!firstRun.needsFirstOffset else{throw LessonError.message("Only a case with no saved offset should be set down first.")}
    guard firstRun.feed([[1,11,1000000,1.0,0,0,100000],[2,12,1001000,1.0,0,0,0]],plane:.flatSwivel) != nil,
          firstRun.feed([[3,11,1020000,1.02,0,0,100000],[4,12,1021000,1.02,0,0,0]],plane:.flatTilt) != nil else{
        throw LessonError.message("Repeated motion feeds across pointing planes must not fail.")
    }
    guard !closedCaseUpright([0,0,1],closed:[0,0,1],held:nil),closedCaseUpright([1,0,0],closed:[0,0,1],held:nil),
          !closedCaseUpright([0.5,0,0.87],closed:[0,0,1],held:nil),closedCaseUpright([0.656,0,0.755],closed:[0,0,1],held:nil),closedCaseUpright([0.9,0.1,0.42],closed:[0.9,0.1,0.42],held:[1,0,0]),
          !closedCaseUpright([0,0,1],closed:[0,0,1],held:[1,0,0]) else{
        throw LessonError.message("Upright must follow a quarter turn from the closed pose or the pose of the saved edges.")
    }
    print("PASS: AirPods found by product ID with a plain reason for each failure, motion code in JavaScriptCore, known angular motion, a saved offset in any pose, a hand-held first offset, gentle re-measuring, upright from a quarter turn, bridge types and raw array conversion; no device or cursor operations, bounded helper log and newest-session pruning, the lid from paired in-case reports and from the lid broadcast, short-drop hold, long-drop restart and saved grip edges")
}

enum ClosedCaseStage:Equatable{case off,openLid,connecting,closeLid,settling,holding,calibrating,ready,pointing}

extension ClosedCaseStage{
    var setupLink:SetupLink{
        switch self{
        case .off:return .idle
        case .openLid:return .openLid
        case .connecting:return .connecting
        case .closeLid:return .closeLid
        case .settling:return .turnUpright
        case .holding:return .holdStill
        case .calibrating,.ready,.pointing:return .connected
        }
    }
}

final class ClosedCaseSession: NSObject {
    var onUpdate:((ClosedCaseSession)->Void)?
    var onPoint:((CGPoint)->Void)?
    // While set, the tap test counts taps instead of them clicking.
    enum TapOutcome{case click,rejected(String)}
    var tapTest:((TapOutcome)->Void)?
    // While learning, taps teach the direction instead of clicking.
    private var tapLearner:ClosedCaseTapLearner?,onTapLearning:((ClosedCaseTapLearner.Event)->Void)?
    func learnTaps(_ handler:@escaping(ClosedCaseTapLearner.Event)->Void){tapLearner=ClosedCaseTapLearner();onTapLearning=handler}
    func stopLearningTaps(){tapLearner=nil;onTapLearning=nil}
    var tapDirection:[Double]?{didSet{tapDetector.direction=tapDirection.flatMap{$0.count==3 ? SIMD3($0[0],$0[1],$0[2]):nil} ?? ClosedCaseTapDetector.tapDirection}}
    var onEnded:((String?)->Void)?
    var opensLidFirst=false
    private(set) var lostContact=false
    var isActive:Bool{preparing || helper?.isRunning == true  ||  bootstrap?.isRunning == true}
    var inputReady:Bool{connected && ProcessInfo.processInfo.systemUptime-lastHost<0.5}
    private(set) var calibrated=false
    var centerOnly:Bool{!calibrated && motion?.edgesWithoutCenter==true}
    var stage:ClosedCaseStage{
        if stopping || !isActive{return .off}
        if lidWatcher != nil{return .openLid}
        if !confirmed{return ready ? .closeLid:.connecting}
        // A first offset needs stillness, so the case is set down before it's turned.
        if motion?.needsFirstOffset==true{return .holding}
        guard held,turned else{return .settling}
        guard motion?.fusionReady==true else{return .holding}
        if !calibrated{return .calibrating}
        return enabled ? .pointing:.ready
    }
    // How far the first measure of the sensor has got: it fills while the case stays still and empties if it moves.
    var holdProgress:Double{stage == .holding ? motion?.settling?["progress"] as? Double ?? 0:0}
    var endReason:String?{stage == .off && !userEnded && endMessage != "Paused" ? endMessage:nil}
    var homePhase:HomeControlPhase{
        switch stage {
        case .off:return .needsInputs
        case .openLid:return .closedCase(.openLid)
        case .connecting:return .connecting
        case .closeLid:return .closedCase(.closeLid)
        case .settling:return .closedCase(.turnUpright)
        case .holding:return .closedCase(.holdStill)
        case .calibrating:return .closedCase(centerOnly ? .recenter:.calibrate)
        case .ready:return hasPointed ? .paused(pauseReason):.ready
        case .pointing:return .running
        }
    }
    var onFrame:((MotionFrame)->Void)?
    private(set) var aimPoint=CGPoint(x:0.5,y:0.5)
    var screenIndex=0
    var captureFolder:URL?{capture?.deletingLastPathComponent()}
    private var afterEnd:[()->Void]=[]
    private var helper:Process?, bootstrap:Process?, log:FileHandle?, stream:FileHandle?
    private var capture:URL?, pending=Data(), timer:Timer?, motion:ClosedCaseMotion?
    private var connected=false, confirmed=false, ready=false, stopping=false, held=false
    private var enabled=false{didSet{if enabled != oldValue{CursorSize.shared.pointingChanged(enabled)}}}
    private var generation=0, lastStatus=0.0, lastHost=0.0, pressedAt=0.0, loggedReady=false
    private var smooth=CGPoint(x:0.5,y:0.5), feedError:String?
    private var pointerFilter=ClosedCasePointerFilter()
    private var readStats=(count:0,total:0.0,longest:0.0,since:0.0)
    private var tapDetector=ClosedCaseTapDetector(),recentPoints:[(t:Double,point:CGPoint)]=[],tapHold:CGPoint?
    private var lastClick:(uptime:Double,position:CGPoint,count:Int64)?
    private var closedAt=0.0,startedAt=0.0,helperStartedAt=0.0,stoppedAt=0.0,busyRetries=0
    private var activity:NSObjectProtocol?
    private var savedMeasure=0,lastCalibrationSave=0.0
    private var closedGravity:[Double]?,heldGravity:[Double]?,uprightSince:Double?,turned=false
    private var cachedCalibration:[String:Any]?,cachedGrip:[String:Any]?,targetHash:String?
    private var silentOutput:PointerSilentOutput?
    private var motionRecord:FileHandle?
    private var lastLease=0.0
    private var endMessage="Paused"
    static let pointerSessions=airPointerDataFolder.appendingPathComponent("PointerSessions",isDirectory:true)
    static let keptSessions=10
    private var userEnded=false,hasPointed=false,pauseReason="Paused"
    private var preparing=false,preparation=0,signalled=false
    private var lidWatcher:ClosedCaseLidWatcher?,lidTimeout:Timer?
    private let bluetooth=ClosedCaseBluetoothAccess()
    private var resumeAfterDrop=false
    var speed=1.0,clickSound=true
    var plane=PointingPlane.upright{
        didSet{
            guard plane != oldValue else{return}
            if !plane.requiresTurnUpright && confirmed{turned=true}
            else if plane.requiresTurnUpright && confirmed && !calibrated{turned=false;uprightSince=nil}
            changed()
        }
    }
    var pointsWhenReady=false,usesNotch=false
    var centersItself:Bool{pointsWhenReady && centerOnly}
    var preparingConnection:Bool{preparing && lidWatcher==nil}
    private var settle:(stamp:Double,q:[Double])?
    private var calibrationURL:URL{
        airPointerDataFolder.appendingPathComponent("closed-case-sensor-calibration.json")
    }
    private var gripURL:URL{
        airPointerDataFolder.appendingPathComponent("closed-case-grip.json")
    }
    private var target:URL{ClosedCaseAirPods.targetURL}

    private func changed(){onUpdate?(self)}
    private func setAim(_ point:CGPoint){aimPoint=point}
    func confirmLidClosed(){guard helper?.isRunning == true,!confirmed,ready else{return};confirmClosed()}
    func applyCalibration(center:Pose,right:Pose,up:Pose) throws {
        guard confirmed,held,let motion else{throw LessonError.message("The case lost its connection. Connect again, then open the lid.")}
        let resume=resumeAfterDrop;pause()
        if let error=motion.applyOverlayPoses(center:center,right:right,up:up){
            feedError=nil;motion.resetGrip()
            throw LessonError.message(error.isEmpty ? "Calibration didn’t take. Point at the center to try again.":error)
        }
        finishCalibration(resume:resume);saveCalibration();saveGrip()
    }
    func applyCenter(_ center:Pose) throws -> Bool {
        guard confirmed,held,let motion else{throw LessonError.message("The case lost its connection. Connect again, then open the lid.")}
        let resume=resumeAfterDrop;pause()
        guard let kept=motion.recenter(to:[center.w,center.x,center.y,center.z]) else{
            feedError=nil;motion.resetGrip(keepingEdges:true)
            throw LessonError.message("Calibration didn’t take. Point at the center to try again.")
        }
        resumeAfterDrop=resume
        guard kept else{return false}
        finishCalibration(resume:resume)
        return true
    }
    private func finishCalibration(resume:Bool){
        calibrated=true;hasPointed=false;smooth=CGPoint(x:0.5,y:0.5);pointerFilter=ClosedCasePointerFilter();setAim(smooth)
        step("pointing")
        readStatus()
        if resume || pointsWhenReady{resumeAfterDrop=false;toggleCursor()}
    }
    private func centerHere(_ q:[Double]){
        guard let motion else{return}
        guard let kept=motion.recenter(to:q,force:true) else{
            feedError=nil;motion.resetGrip(keepingEdges:true);changed();return
        }
        if kept{finishCalibration(resume:false)}else{changed()}
    }
    func beginSession(){changed();if !isActive{start()}}
    func resumeCursor(){toggleCursor()}
    func recenter(){if calibrated && inputReady{let resume=enabled;setPose();if resume{toggleCursor()}}else{changed()}}
    func recalibrate(){pause();hasPointed=false;calibrated=false;motion?.resetGrip();changed()}
    func clearSavedGrip(){cachedGrip=nil;try? FileManager.default.removeItem(at:gripURL);if isActive{recalibrate()}}
    func pause(_ reason:String="Paused"){pauseReason=reason;enabled=false;resumeAfterDrop=false;changed()}
    func disconnect(then done:(()->Void)?=nil){
        if let done{if isActive{afterEnd.append(done)}else{done();return}}
        userEnded=true;stop()
    }
    func refreshDisplays(selecting index:Int) {
        screenIndex=index
    }
    private func fail(_ message:String){pause();feedError=message;stop()}
    private func resetFusion() throws {
        motion=try ClosedCaseMotion.make{ [weak self] error in self?.feedError=error }
        if let saved=cachedCalibration,
           let time=saved["updated_unix"] as? Double,
           (0..<7*86400).contains(Date().timeIntervalSince1970-time){
            motion?.loadCalibration(saved)
        }
        if let savedGrip=cachedGrip{motion?.loadGrip(savedGrip)}
        calibrated=false;generation=0;lastHost=0;pending=Data();smooth=CGPoint(x:0.5,y:0.5)
        pointerFilter=ClosedCasePointerFilter()
        setAim(smooth);feedError=nil;savedMeasure=0
    }
    private func saveCalibration(){
        guard let motion,motion.measured>savedMeasure,let values=motion.calibrationValues,let targetHash else{return}
        var saved=values;saved["target_sha256"]=targetHash;saved["updated_unix"]=Date().timeIntervalSince1970
        cachedCalibration=saved;savedMeasure=motion.measured;lastCalibrationSave=ProcessInfo.processInfo.systemUptime
        saveClosedCaseJSON(saved,to:calibrationURL){[weak self] message in try? self?.log?.write(contentsOf:Data((message+"\n").utf8))}
    }
    private func saveGrip(){
        guard let targetHash,let edges=motion?.gripEdges,edges["right"] != nil else{return}
        var saved=edges;saved["target_sha256"]=targetHash;saved["updated_unix"]=Date().timeIntervalSince1970
        cachedGrip=saved;saveClosedCaseJSON(saved,to:gripURL){[weak self] message in try? self?.log?.write(contentsOf:Data((message+"\n").utf8))}
    }
    private func confirmClosed(){
        guard !confirmed,ready,let capture else{return}
        do{
            closedAt=ProcessInfo.processInfo.systemUptime
            try Data("closed_confirmed\n".utf8).write(to:capture.appendingPathComponent("phase.txt"),options:.atomic)
            step("lid closed");confirmed=true;ready=false
            motion?.resetGrip(keepingEdges:true);calibrated=false;smooth=CGPoint(x:0.5,y:0.5);setAim(smooth)
            turned = !plane.requiresTurnUpright;uprightSince=nil;settle=nil
            closedGravity=motion?.accelVector
            heldGravity=motion?.gripGravity
            pointerFilter=ClosedCasePointerFilter()
        }catch{fail(error.localizedDescription)}
    }
    private func start(){
        guard !preparing else{return}
        preparing=true;preparation+=1;userEnded=false;lostContact=false;feedError=nil;endMessage="Paused";pressedAt=ProcessInfo.processInfo.systemUptime;loggedReady=false;busyRetries=0
        if clickSound{_=TapClickSound.shared}
        AudioOutputGuard.shared.sessionStarted(target:ClosedCaseAirPods.saved)
        changed()
        let token=preparation
        bluetooth.request{[weak self] allowed in
            guard let self,self.preparing,self.preparation==token else{return}
            guard allowed else{
                if let url=ClosedCaseBluetoothAccess.settings{NSWorkspace.shared.open(url)}
                self.finished(ClosedCaseAirPods.bluetoothDenied);return
            }
            ClosedCaseAirPods.survey{[weak self] survey in
                guard let self,self.preparing,self.preparation==token else{return}
                let choice=ClosedCaseAirPods.choose(survey,saved:ClosedCaseAirPods.saved)
                guard case .chosen(let pair)=choice else{self.finished(choice.failure ?? "");return}
                do{try ClosedCaseAirPods.save(pair)}catch{self.finished("AirPointer couldn’t save which AirPods to use. Connect again.");return}
                AudioOutputGuard.shared.sessionStarted(target:pair.address)
                loadClosedCaseCalibration(from:self.calibrationURL,grip:self.gripURL,target:self.target){[weak self] hash,saved,grip in
                    guard let self,self.preparing,self.preparation==token else{return}
                    self.targetHash=hash;self.cachedCalibration=saved;self.cachedGrip=grip
                    if pair.connected && !self.opensLidFirst{self.preparing=false;self.launch()}else{self.waitForLid(pair,token:token)}
                }
            }
        }
    }
    private func waitForLid(_ pair:ClosedCaseAirPods,token:Int){
        let watcher=ClosedCaseLidWatcher(productID:pair.productID){[weak self] in
            guard let self,self.preparing,self.preparation==token else{return}
            self.endLidWait();self.preparing=false;self.launch()
        }
        lidWatcher=watcher;watcher.start()
        lidTimeout=Timer.scheduledTimer(withTimeInterval:120,repeats:false){[weak self] _ in
            guard let self,self.preparing,self.preparation==token else{return}
            self.endLidWait();self.finished("AirPointer stopped waiting for the lid. Connect again when you’re ready.")
        }
        changed()
    }
    private func endLidWait(){lidTimeout?.invalidate();lidTimeout=nil;lidWatcher?.stop();lidWatcher=nil}
    private func launch(){
        guard let restore=Bundle.main.url(forResource:"ClosedCaseRestore",withExtension:"bin") else{
            finished("AirPods connection setup is missing from this build.");return
        }
        do{
            try resetFusion();confirmed=false;connected=false;ready=false;stopping=false;closedAt=0;stoppedAt=0;userEnded=false;hasPointed=false;pause()
            startedAt=ProcessInfo.processInfo.systemUptime
            if let activity{ProcessInfo.processInfo.endActivity(activity)}
            activity=ProcessInfo.processInfo.beginActivity(options:[.userInitiatedAllowingIdleSystemSleep,.latencyCritical],reason:"Receive AirPods pointer motion")
            let root=Self.pointerSessions
            pruneClosedCaseSessions(in:root,keeping:Self.keptSessions-1)
            let folder=root.appendingPathComponent(UUID().uuidString,isDirectory:true)
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            capture=folder.appendingPathComponent("recording",isDirectory:true)
            lastLease=0;endMessage="Paused";try renewSessionLease()
            if let address=try? String(contentsOf:target,encoding:.utf8){
                silentOutput=PointerSilentOutput(targetAddress:address)
            }
            log=try closedCaseAppendingHandle(folder.appendingPathComponent("native.log"))
            motionRecord=UserDefaults.standard.bool(forKey:"recordMotion") ? try? closedCaseAppendingHandle(folder.appendingPathComponent("motion-rows.csv")):nil
            step("connect pressed",at:pressedAt);step("restore started")
            let process=Process();bootstrap=process;process.executableURL=restore;process.arguments=[target.path]
            process.standardOutput=log;process.standardError=log
            process.terminationHandler={ [weak self] process in DispatchQueue.main.async{
                guard let self,self.bootstrap === process else{return};self.bootstrap=nil
                if self.stopping{self.finished(self.feedError ?? "Stopped. Reopen the lid.");return}
                if process.terminationStatus==0{self.launchHelper()}else{self.finished(ClosedCaseAirPods.restoreFailure(process.terminationStatus))}
            }}
            try process.run()
            scheduleTick(interval:0.05)
            changed()
        }catch{finished(error.localizedDescription)}
    }
    private func launchHelper(){
        guard let executable=Bundle.main.url(forResource:"ClosedCaseMotion",withExtension:"bin"),let capture else{
            finished("The closed-case motion component is missing.");return
        }
        let process=Process();helper=process;process.executableURL=executable
        process.arguments=[target.path,"--pointer-session",capture.path]
        var errorPipe:Pipe?
        let motionPipe=Pipe();stream=motionPipe.fileHandleForReading
        let flags=fcntl(motionPipe.fileHandleForReading.fileDescriptor,F_GETFL)
        guard flags>=0,fcntl(motionPipe.fileHandleForReading.fileDescriptor,F_SETFL,flags|O_NONBLOCK)==0 else{finished("Couldn’t open the motion connection.");return}
        process.standardOutput=motionPipe
        if let helperLog=try? ClosedCaseHelperLog(folder:capture.deletingLastPathComponent()){
            let errors=Pipe();errorPipe=errors;helperLog.attach(errors);process.standardError=errors
        }else{process.standardError=FileHandle.nullDevice}
        process.terminationHandler={ [weak self] process in DispatchQueue.main.async{
            guard let self,self.helper === process else{return};self.readStatus()
            let status=process.terminationReason == .exit ? process.terminationStatus:nil
            if status==25,!self.stopping,self.busyRetries<3{
                self.busyRetries+=1;self.helper=nil;self.preparing=true;let token=self.preparation
                DispatchQueue.main.asyncAfter(deadline:.now()+1.5){ [weak self] in
                    guard let self,self.preparing,self.preparation==token else{return}
                    self.preparing=false;self.launch()
                }
                return
            }
            self.lostContact = !self.userEnded && self.hasPointed && ClosedCaseAirPods.lostContact(status)
            self.finished(ClosedCaseAirPods.helperFailure(status,stopping:self.stopping) ?? self.feedError ??
                (self.stopping ? "Paused":"AirPods disconnected. Connect again, then open the lid."))
        }}
        do{
            helperStartedAt=ProcessInfo.processInfo.systemUptime
            try process.run()
            try? motionPipe.fileHandleForWriting.close();try? errorPipe?.fileHandleForWriting.close()
            scheduleTick(interval:0.005)
        }catch{try? errorPipe?.fileHandleForWriting.close();finished(error.localizedDescription)}
    }
    private func scheduleTick(interval:TimeInterval){
        timer?.invalidate()
        let next=Timer(timeInterval:interval,repeats:true){[weak self] _ in self?.tick()}
        RunLoop.main.add(next,forMode:.common);timer=next
    }
    private func tick(){
        let now=ProcessInfo.processInfo.systemUptime
        if isActive && !stopping{do{try renewSessionLease()}catch{fail("Couldn’t keep the pointer connection active.");return}}
        if bootstrap?.isRunning == true && now-startedAt>30{feedError="AirPods did not connect. Open the lid, wake one earbud, then reconnect.";stop();return}
        if !stopping && helper?.isRunning == true && !confirmed && lastHost==0 && now-helperStartedAt>20{
            fail("No fresh motion arrived. Open the lid, wake one earbud, then reconnect.");return
        }
        if stopping && stoppedAt>0 && now-stoppedAt>3{if !signalled{signalled=true;helper?.terminate()};return}
        if now-lastStatus>0.2{lastStatus=now;readStatus()}
        if !stopping && helper?.isRunning == true{readMotion()}
        if enabled && closedCaseShouldPause(motionAge:now-lastHost){
            pause("Lost the case’s motion. Pointing resumes when it’s back.");resumeAfterDrop=true
        }
        if resumeAfterDrop && !enabled && calibrated && connected && now-lastHost<0.25{resumeAfterDrop=false;toggleCursor()}
        if feedError != nil  &&  !stopping{stop()}
    }
    func step(_ name:String,at time:Double=ProcessInfo.processInfo.systemUptime){
        try? log?.write(contentsOf:Data(String(format:"STEP %@ uptime=%.3f\n",name,time).utf8))
    }
    private func renewSessionLease() throws{
        guard let capture else{return}
        let now=ProcessInfo.processInfo.systemUptime
        guard now-lastLease>=1 else{return}
        try Data(String(format:"%.6f\n",now).utf8).write(to:capture.deletingLastPathComponent().appendingPathComponent("app-lease.txt"),options:.atomic)
        lastLease=now
    }
    private func readStatus(){
        guard let capture,let data=try? Data(contentsOf:capture.appendingPathComponent("status.json")),
              let state=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any],
              let cs=state["case_snapshot"] as? [String:Any],let sensors=state["sensors"] as? [[String:Any]] else{return}
        let age=Date().timeIntervalSince1970-(state["updated_unix"] as? Double ?? 0)
        connected=closedCaseConnectionFresh(reportAge:age,sensorAges:sensors.map{$0["age_seconds"] as? Double ?? 100},motionAge:ProcessInfo.processInfo.systemUptime-lastHost)
        if connected && !stopping{silentOutput?.refresh()}
        ready = !stopping && !confirmed && connected && (state["open_baseline_verified"] as? Bool == true) && 
            (cs["root_identity_verified"] as? Bool == true)
        if ready && !loggedReady{loggedReady=true;step("close lid shown")}
        if ready,helper?.isRunning == true,closedCaseLidClosed(closedCaseInCaseReports(state["earbud_state_events"])){
            confirmClosed()
        }
        if !stopping && confirmed{
            held=cs["case_identity_verified"] as? Bool == true || (connected && ProcessInfo.processInfo.systemUptime-closedAt>=2)
        }
        if let error=cs["error"] as? String,!error.isEmpty,feedError==nil{
            try? log?.write(contentsOf:Data("helper error: \(error)\n".utf8))
            feedError="The case stopped responding. Connect again, then open the lid."
        }
        changed()
    }
    private func readMotion(){
        guard let motion else{return}
        let readAt=ProcessInfo.processInfo.systemUptime
        do{
            guard let stream,let fresh=try readClosedCaseMotionPipe(stream),!fresh.isEmpty else{return}
            try? motionRecord?.write(contentsOf:fresh)
            pending.append(fresh);guard pending.count<=65536 else{throw LessonError.message("Motion input fell behind.")}
            var rows=[[Double]]()
            while let end=pending.firstIndex(of:10){
                let line=pending.prefix(upTo:end);pending.removeSubrange(...end)
                guard let text=String(data:line,encoding:.utf8) else{throw LessonError.message("Invalid motion input.")}
                let values=text.split(separator:",").compactMap{Double($0)}
                guard values.count==7,values.allSatisfy(\.isFinite) else{throw LessonError.message("Invalid motion input.")}
                rows.append(values)
            }
            guard !rows.isEmpty else{return}
            defer{noteRead(from:readAt)}
            let tapEvents=tapLearner==nil && enabled && calibrated ? tapDetector.feed(rows):tapDetector.reset()
            for event in tapLearner?.feed(rows) ?? []{
                if case .tap=event,clickSound{TapClickSound.shared.play()}
                try? log?.write(contentsOf:Data("TAPLEARN \(event)\n".utf8))
                if case .finished=event{tapLearner=nil}else if case .failed=event{tapLearner=nil}
                onTapLearning?(event)
            }
            for note in tapDetector.ignored{try? log?.write(contentsOf:Data("tap: \(note)\n".utf8));tapTest?(.rejected(note))}
            tapDetector.ignored=[]
            // Ahead of the orientation code, which can take tens of milliseconds now and then.
            for event in tapEvents{
                switch event {
                case .release:tapHold=nil
                case .tap(let since,let jolt,let repeated):
                    let at=recentPoints.last{$0.t<since}?.point ?? smooth;tapHold=at
                    if enabled{
                        let decided=ProcessInfo.processInfo.systemUptime
                        if let tapTest{tapTest(.click)}else{postClick(at)}
                        let clicked=ProcessInfo.processInfo.systemUptime
                        if clickSound{TapClickSound.shared.play()}
                        let sounded=ProcessInfo.processInfo.systemUptime
                        try? log?.write(contentsOf:Data(String(format:"tap: click at %.2f, jolt %.2f g, %.0f ms after it began%@, %.0f ms after arrival, %.1f ms reading, %.1f ms posting, %.1f ms sound\n",since,jolt,1e3*((rows.last?[2] ?? 0)*1e-6-since),repeated ? ", repeat":"",1e3*(decided-(rows.last?[3] ?? decided)),1e3*(decided-readAt),1e3*(clicked-decided),1e3*(sounded-clicked)).utf8))
                    }
                }
            }
            guard let result=motion.feed(rows,plane:plane),
                  let gyro=result["gyro"] as? [String:Any],let accel=result["accel"] as? [String:Any],
                  let host=gyro["host"] as? Double,let stamp=gyro["stamp"] as? Double,
                  let accelHost=accel["host"] as? Double else{return}
            let nextGeneration=result["generation"] as? Int ?? 0
            if let measured=result["measured"] as? Int,measured>savedMeasure,
               savedMeasure==0 || ProcessInfo.processInfo.systemUptime-lastCalibrationSave>30{saveCalibration()}
            // The turn counts from where the case was set down. A table can match the saved grip's tilt,
            // so that shortcut is off and the case has to really move.
            if motion.needsFirstOffset{closedGravity=nil;heldGravity=nil;uprightSince=nil}
            else if confirmed,!turned,!plane.requiresTurnUpright{turned=true}
            else if confirmed,!turned,let g=result["g"] as? [Double],g.count==3 {
                if closedGravity==nil{closedGravity=g}
                if let closedGravity,closedCaseUpright(g,closed:closedGravity,held:heldGravity){
                    if uprightSince==nil{uprightSince=stamp}
                    if let uprightSince,stamp-uprightSince>=250000{turned=true}
                }else{uprightSince=nil}
            }
            if nextGeneration != generation{
                let resume=enabled || resumeAfterDrop
                motion.resetGrip(keepingEdges:true)
                generation=nextGeneration;calibrated=false;pause();resumeAfterDrop=resume
                smooth=CGPoint(x:0.5,y:0.5);setAim(smooth)
                pointerFilter=ClosedCasePointerFilter();recentPoints=[];tapHold=nil;settle=nil
            }
            guard host>lastHost,abs(host-accelHost)<0.25 else{return}
            lastHost=host
            if !calibrated,confirmed,held,turned,result["ready"] as? Bool==true,let q=result["q"] as? [Double],q.count==4 {
                onFrame?(MotionFrame(t:host,pose:Pose(w:q[0],x:q[1],y:q[2],z:q[3])))
            }
            if pointsWhenReady,!calibrated,confirmed,held,turned,result["ready"] as? Bool==true,result["edges"] as? Bool==true,
               let q=result["q"] as? [Double],q.count==4 {
                var d=0.0;if let settle{for i in 0..<4{d+=q[i]*settle.q[i]}}
                if let settle,2*acos(min(1,abs(d)))*180/Double.pi<2.5 {
                    if stamp-settle.stamp>=400000{self.settle=nil;centerHere(q)}
                }else{settle=(stamp,q)}
            }
            guard calibrated,let point=result["point"] as? [Double],point.count==2,point.allSatisfy(\.isFinite) else{return}
            let x=0.5+(point[0]-0.5)*speed,y=0.5+(point[1]-0.5)*speed
            if let tapHold{smooth=tapHold}else{
                smooth=pointerFilter.feed(CGPoint(x:min(1,max(0,x)),y:min(1,max(0,y))),at:stamp*1e-6)
                recentPoints.append((stamp*1e-6,smooth));while let first=recentPoints.first,stamp*1e-6-first.t>0.5{recentPoints.removeFirst()}
            }
            setAim(smooth);onPoint?(smooth)
            if enabled && ProcessInfo.processInfo.systemUptime-host<0.25{postCursor()}
        }catch{fail(error.localizedDescription)}
    }
    // How long a read of motion holds up the main run loop, for the session log.
    private func noteRead(from start:Double){
        let now=ProcessInfo.processInfo.systemUptime
        readStats.count+=1;readStats.total+=now-start;readStats.longest=max(readStats.longest,now-start)
        if now-readStats.since>=10{
            try? log?.write(contentsOf:Data(String(format:"READS %d, mean %.1f ms, longest %.1f ms\n",readStats.count,1e3*readStats.total/Double(readStats.count),1e3*readStats.longest).utf8))
            readStats=(0,0,0,now)
        }
    }
    func noteTapTest(_ text:String){
        try? log?.write(contentsOf:Data(String(format:"TAPTEST %@ uptime=%.3f\n",text,ProcessInfo.processInfo.systemUptime).utf8))
    }
    private func setPose(){
        guard connected,confirmed,let motion,motion.fusionReady else{return}
        pause()
        _=motion.run("rawGrip.center=[...rawFusion.q];if(rawFusion.accel&&rawFusion.accel.vector)rawGrip.gravity=unit(rawFusion.accel.vector);")
        if motion.lastException != nil{feedError=nil;return}
        smooth=CGPoint(x:0.5,y:0.5);pointerFilter=ClosedCasePointerFilter();setAim(smooth);readStatus()
        saveCalibration()
    }
    private func toggleCursor(){
        if enabled{pause();return}
        guard calibrated,connected,ProcessInfo.processInfo.systemUptime-lastHost<0.25 else{return}
        guard AXIsProcessTrusted() else{
            AccessibilityGuide.shared.open();return
        }
        enabled=true;hasPointed=true;resumeAfterDrop=false;if clickSound{TapClickSound.shared.start()}
        changed()
    }
    private func pointerBounds()->CGRect?{
        guard AXIsProcessTrusted(),NSScreen.screens.indices.contains(screenIndex),
              let number=NSScreen.screens[screenIndex].deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else{return nil}
        return CGDisplayBounds(CGDirectDisplayID(number.uint32Value))
    }
    private func postCursor(){
        guard let bounds=pointerBounds(),
              let event=CGEvent(mouseEventSource:nil,mouseType:.mouseMoved,mouseCursorPosition:screenPoint(smooth,bounds:bounds),mouseButton:.left) else{pause();return}
        event.post(tap:.cghidEventTap)
    }
    private func postClick(_ point:CGPoint){
        guard let bounds=pointerBounds() else{pause();return}
        let position=screenPoint(point,bounds:bounds),now=ProcessInfo.processInfo.systemUptime
        let count=lastClick.map{now-$0.uptime<NSEvent.doubleClickInterval && hypot($0.position.x-position.x,$0.position.y-position.y)<8 ? $0.count+1:1} ?? 1
        guard let down=CGEvent(mouseEventSource:nil,mouseType:.leftMouseDown,mouseCursorPosition:position,mouseButton:.left),
              let up=CGEvent(mouseEventSource:nil,mouseType:.leftMouseUp,mouseCursorPosition:position,mouseButton:.left) else{return}
        down.setIntegerValueField(.mouseEventClickState,value:count);up.setIntegerValueField(.mouseEventClickState,value:count)
        down.post(tap:.cghidEventTap);up.post(tap:.cghidEventTap);lastClick=(now,position,count)
    }
    func stop(){
        silentOutput?.stop();silentOutput=nil;TapClickSound.shared.stop()
        pause();if !stopping{stoppedAt=ProcessInfo.processInfo.systemUptime;step("disconnect pressed")};stopping=true;ready=false
        endMessage="Paused";changed()
        if let capture{try? Data("stop\n".utf8).write(to:capture.appendingPathComponent("phase.txt"),options:.atomic)}
        if bootstrap?.isRunning == true{bootstrap?.terminate();return}
        if helper?.isRunning != true{finished(feedError ?? "Stopped. Reopen the lid.")}
    }
    private func finished(_ message:String){
        step("session ended");endMessage=message;preparing=false;signalled=false;endLidWait()
        silentOutput?.stop();silentOutput=nil;TapClickSound.shared.stop();AudioOutputGuard.shared.sessionEnded()
        pause();timer?.invalidate();timer=nil;try? stream?.close();stream=nil;try? log?.close();log=nil;try? motionRecord?.close();motionRecord=nil
        if let activity{ProcessInfo.processInfo.endActivity(activity)};activity=nil
        helper=nil;bootstrap=nil;connected=false;ready=false;stopping=false;confirmed=false;held=false
        changed();onEnded?(endReason)
        let done=afterEnd;afterEnd=[];for action in done{action()}
    }
    func shutdown(){
        userEnded=true;stop();let deadline=Date().addingTimeInterval(7)
        while helper?.isRunning == true && deadline.timeIntervalSinceNow>0{RunLoop.current.run(until:Date().addingTimeInterval(0.05))}
        if helper?.isRunning == true{helper?.terminate()}
    }
}
