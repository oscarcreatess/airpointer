import AppKit

// A short tap test with a known answer: ten cues to tap on, eight taps as fast as feels natural, five taps followed at once
// by a swing, then a stretch of pointing with no taps. It gives miss and false-click counts nobody has to keep in their head,
// and the cues in native.log label the raw motion for replays.
struct TapTestRun {
    static let cues=10,quickTaps=8,moveCues=5
    static let getReady=2.0,getNext=3.0,cueEvery=2.0,quickFor=5.0,moveEvery=2.5,pointingFor=30.0
    // A click can land just after its step ends, and a quick tap just ahead of the step.
    static let lateClick=0.5,earlyTap=0.3
    // How far the pointer has to go after a tap, as a share of the screen, for a swing to count as a test.
    static let minimumSwing=0.1
    enum Phase:Equatable{
        case getReady(left:Double),tap(cue:Int),getQuick(left:Double),quick(left:Double),getMove(left:Double),move(cue:Int),point(left:Double),done
        // What native.log calls this step. The first countdown isn't labelled.
        var label:String?{
            switch self{
            case .tap(let cue):return "cue \(cue)"
            case .getQuick:return "next quick"
            case .quick:return "quick"
            case .getMove:return "next move"
            case .move(let cue):return "move \(cue)"
            case .point:return "pointing"
            default:return nil
            }
        }
    }
    let start:Double
    private(set) var clicks:[Double]=[]
    private(set) var rejections:[(t:Double,why:String)]=[]
    private var lastAim=CGPoint.zero,swingFrom:[Int:CGPoint]=[:],swings:[Int:Double]=[:]
    private var firstCue:Double{start+Self.getReady}
    private var quickReady:Double{firstCue+Double(Self.cues)*Self.cueEvery}
    private var quickStart:Double{quickReady+Self.getNext}
    private var moveReady:Double{quickStart+Self.quickFor}
    private var moveStart:Double{moveReady+Self.getNext}
    private var pointingStart:Double{moveStart+Double(Self.moveCues)*Self.moveEvery}
    var end:Double{pointingStart+Self.pointingFor}
    init(start:Double){self.start=start}
    mutating func click(at t:Double){
        clicks.append(t)
        if let cue=moveCue(at:t),swingFrom[cue]==nil{swingFrom[cue]=lastAim}
    }
    mutating func aim(at t:Double,_ point:CGPoint){
        lastAim=point
        if let cue=moveCue(at:t),let from=swingFrom[cue]{swings[cue]=max(swings[cue] ?? 0,hypot(point.x-from.x,point.y-from.y))}
    }
    mutating func rejected(at t:Double,_ why:String){rejections.append((t,why))}
    func phase(at t:Double)->Phase{
        if t<firstCue{return .getReady(left:firstCue-t)}
        if t<quickReady{return .tap(cue:Int((t-firstCue)/Self.cueEvery))}
        if t<quickStart{return .getQuick(left:quickStart-t)}
        if t<moveReady{return .quick(left:moveReady-t)}
        if t<moveStart{return .getMove(left:moveStart-t)}
        if t<pointingStart{return .move(cue:Int((t-moveStart)/Self.moveEvery))}
        return t<end ? .point(left:end-t):.done
    }
    private func cue(at t:Double)->Int?{
        guard t>=firstCue,t<quickReady+Self.lateClick else{return nil}
        return min(Self.cues-1,Int((t-firstCue)/Self.cueEvery))
    }
    private func moveCue(at t:Double)->Int?{
        guard t>=moveStart,t<pointingStart+Self.lateClick else{return nil}
        return min(Self.moveCues-1,Int((t-moveStart)/Self.moveEvery))
    }
    var hits:Set<Int>{Set(clicks.compactMap(cue(at:)))}
    private var quickClicks:Int{clicks.filter{$0>=quickStart-Self.earlyTap && $0<moveReady+Self.lateClick}.count}
    var quickHits:Int{min(quickClicks,Self.quickTaps)}
    var moveHits:Set<Int>{Set(clicks.compactMap(moveCue(at:)))}
    // Move cues where the pointer really went somewhere, so the test meant something.
    var swung:Set<Int>{Set(swings.filter{$0.value>=Self.minimumSwing}.keys)}
    // Clicks beyond one per move cue: the hand moving away set off another.
    var moveExtra:Int{clicks.compactMap(moveCue(at:)).count-moveHits.count}
    var falseClicks:Int{clicks.filter{$0>=pointingStart+Self.lateClick}.count}
    var extraClicks:Int{clicks.count-hits.count-quickHits-moveHits.count-moveExtra-falseClicks}
    // Why each missed cue didn't click, from the last jolt the detector turned down during it.
    var misses:[String:Int]{
        var counts:[String:Int]=[:]
        for missed in Set(0..<Self.cues).subtracting(hits){
            let why=rejections.last{cue(at:$0.t)==missed}?.why
            counts[why.map(Self.reason) ?? "no tap detected",default:0]+=1
        }
        return counts
    }
    static func reason(_ why:String)->String{
        if why.contains("not still") || why.contains("just before"){return "the case wasn’t still"}
        if why.contains("not on the front"){return "the jolt wasn’t on the front"}
        if why.contains("too soft"){return "too soft"}
        return "other"
    }
    var summary:String{
        var lines=[String]()
        if !misses.isEmpty{lines.append("Missed: "+misses.sorted{$0.value>$1.value}.map{"\($0.key) (\($0.value))"}.joined(separator:", ")+".")}
        lines.append("Tap fast: \(quickHits) of \(Self.quickTaps). Tap then swing: \(moveHits.count) of \(Self.moveCues), \(moveExtra) extra, a real swing on \(swung.count).")
        lines.append("\(extraClicks) other extra \(extraClicks==1 ? "click":"clicks"). \(falseClicks) false \(falseClicks==1 ? "click":"clicks") in \(Int(Self.pointingFor)) s of pointing.")
        return lines.joined(separator:" ")
    }
    var record:[String:Any]{
        ["hits":hits.count,"cues":Self.cues,"extraClicks":extraClicks,"falseClicks":falseClicks,"pointingSeconds":Self.pointingFor,"misses":misses,
         "quickHits":quickHits,"quickTaps":Self.quickTaps,"quickClicks":quickClicks,"moveHits":moveHits.count,"moveCues":Self.moveCues,"moveExtra":moveExtra,"swung":swung.count,
         "minimumAlignment":ClosedCaseTapDetector.minimumAlignment]
    }
}

func runTapTestChecks()throws{
    func expect(_ ok:Bool,_ message:String)throws{if !ok{throw LessonError.message(message)}}
    var run=TapTestRun(start:100)
    let cue=102.0,quick=125.0,move=133.0,pointing=145.5
    try expect(run.phase(at:100.5) == .getReady(left:1.5),"The test starts with a moment to get ready.")
    try expect(run.phase(at:cue) == .tap(cue:0) && run.phase(at:cue+19.99) == .tap(cue:9),"Ten cues run two seconds apart.")
    try expect(run.phase(at:cue+20) == .getQuick(left:3) && run.phase(at:quick) == .quick(left:5),"Three seconds' warning comes before tapping fast, which lasts five.")
    try expect(run.phase(at:quick+5) == .getMove(left:3) && run.phase(at:move) == .move(cue:0) && run.phase(at:pointing-0.01) == .move(cue:4),"Five swing cues run 2.5 seconds apart.")
    try expect(run.phase(at:pointing) == .point(left:30) && run.phase(at:175.5) == .done,"Thirty seconds of pointing end the test.")
    try expect(run.phase(at:quick).label == "quick" && run.phase(at:pointing+1).label == "pointing" && run.phase(at:100).label==nil,"The log names each step but not the first countdown.")
    try expect(run.hits.isEmpty && run.misses == ["no tap detected":10],"A silent run misses every cue.")
    for k in 0..<8{run.click(at:cue+Double(k)*2+0.6)}
    run.click(at:cue+0.9)
    run.rejected(at:cue+16.5,"sudden 0.31 g, not still before it")
    run.rejected(at:cue+18.5,"not on the front, alignment 0.71, jolt 0.34 g")
    try expect(run.hits.count==8,"Each cue with a click is a hit.")
    try expect(run.extraClicks==1,"A second click on one cue is extra.")
    try expect(run.misses == ["the case wasn’t still":1,"the jolt wasn’t on the front":1],"A miss says what turned the jolt down.")
    run.click(at:quick-0.1);for k in 1..<7{run.click(at:quick+Double(k)*0.3)}
    try expect(run.quickHits==7,"Fast taps are counted, including one just ahead of the step.")
    for k in 0..<2{run.click(at:quick+3+Double(k)*0.3)}
    try expect(run.quickHits==8 && run.extraClicks==2,"More fast clicks than taps asked for are extra.")
    run.aim(at:move+0.1,.zero);run.click(at:move+0.2);run.click(at:move+0.9);run.aim(at:move+1,CGPoint(x:0.05,y:0))
    try expect(run.swung.isEmpty,"A small move isn't a swing.")
    run.aim(at:move+1.5,CGPoint(x:0.3,y:0));run.click(at:move+2.7)
    try expect(run.swung==[0] && run.moveHits==[0,1] && run.moveExtra==1 && run.extraClicks==2,"A swing is measured from the tap, and a second click on a cue is a move extra.")
    run.click(at:pointing+0.3)
    try expect(run.moveHits.contains(4) && run.falseClicks==0,"The last cue's late click isn't a false one.")
    run.click(at:pointing+5)
    try expect(run.falseClicks==1,"A click while only pointing is a false one.")
    run.click(at:101)
    try expect(run.extraClicks==3,"A click before the first cue is extra.")
    print("PASS: tap test timing and scoring")
}

final class TapTestDots:NSView {
    var count=TapTestRun.cues{didSet{invalidateIntrinsicContentSize();needsDisplay=true}}
    var hits:Set<Int>=[]{didSet{needsDisplay=true}}
    var current:Int?{didSet{needsDisplay=true}}
    var finished=false{didSet{needsDisplay=true}}
    override var intrinsicContentSize:NSSize{NSSize(width:CGFloat(count)*22,height:18)}
    override func draw(_ dirtyRect:NSRect){
        let size:CGFloat=12,left=(bounds.width-CGFloat(count)*22)/2+5
        for k in 0..<count{
            let dot=NSBezierPath(ovalIn:NSRect(x:left+CGFloat(k)*22,y:(bounds.height-size)/2,width:size,height:size))
            let past=finished || (current.map{k<$0} ?? false)
            NSColor.white.withAlphaComponent(k==current || hits.contains(k) || past ? 1:0.4).set()
            if hits.contains(k){dot.fill()}else{dot.lineWidth=k==current ? 2.5:1.5;dot.stroke()}
            // A miss is told by a slash as well as an empty dot.
            if past && !hits.contains(k){
                let slash=NSBezierPath();slash.move(to:NSPoint(x:left+CGFloat(k)*22-1,y:(bounds.height-size)/2-1))
                slash.line(to:NSPoint(x:left+CGFloat(k)*22+size+1,y:(bounds.height+size)/2+1));slash.lineWidth=1.5;slash.stroke()
            }
        }
    }
}

final class TapTestWindow:NSObject,NSWindowDelegate {
    let window=NSWindow(contentRect:NSRect(x:0,y:0,width:480,height:440),styleMask:[.titled,.closable,.miniaturizable],backing:.buffered,defer:false)
    var run:TapTestRun?
    private(set) var stopped:String?
    private let liveSession:()->ClosedCaseSession?
    private weak var session:ClosedCaseSession?
    private let chip=StatusChip(),title=rkLabel("Tap test",22,.bold),instruction=rkWrap("",13)
    private let prompt=rkLabel("",40,.bold,.white),progress=rkLabel("",13,.regular,NSColor.white.withAlphaComponent(0.7)),dots=TapTestDots()
    private let primary=RemoteButton("Start Test")
    private var timer:Timer?,announced:String?
    private var totals=(hits:0,cues:0,quick:0,quickAsked:0,move:0,moveCues:0,extra:0,moveExtra:0,falseClicks:0,seconds:0.0)
    static let results=airPointerDataFolder.appendingPathComponent("TapTests.jsonl")

    init(session:@escaping()->ClosedCaseSession?){
        liveSession=session
        super.init()
        // Measured at no width, a long instruction would stretch the window.
        instruction.preferredMaxLayoutWidth=432
        window.title="AirPointer · Tap Test";window.delegate=self;window.isReleasedWhenClosed=false
        let stage=RemoteSurface(HomePalette.stage,radius:12);stage.translatesAutoresizingMaskIntoConstraints=false
        let inner=rkVStack([prompt,progress,dots],spacing:10,align:.centerX);inner.translatesAutoresizingMaskIntoConstraints=false
        stage.addSubview(inner)
        NSLayoutConstraint.activate([inner.centerXAnchor.constraint(equalTo:stage.centerXAnchor),inner.centerYAnchor.constraint(equalTo:stage.centerYAnchor),stage.heightAnchor.constraint(equalToConstant:170)])
        primary.target=self;primary.action=#selector(primaryClicked);primary.keyEquivalent="\r"
        let top=rkHStack([rkLabel("DEVELOPER",11,.semibold,.secondaryLabelColor),rkSpacer(),chip],spacing:8)
        let actions=rkHStack([rkSpacer(),primary],spacing:10)
        let column=rkVStack([top,title,instruction,stage,rkSpacer(),actions],spacing:12)
        column.setCustomSpacing(16,after:top);column.setCustomSpacing(20,after:instruction)
        rkPin(column,in:window.contentView!,insets:NSEdgeInsets(top:20,left:24,bottom:20,right:24))
        for view in [top,instruction,stage,actions] as [NSView]{view.widthAnchor.constraint(equalTo:column.widthAnchor).isActive=true}
        window.setContentSize(NSSize(width:480,height:440));window.center()
        sync(now:ProcessInfo.processInfo.systemUptime)
    }

    func show(){
        sync(now:ProcessInfo.processInfo.systemUptime);window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
        if timer==nil{
            let tick=Timer(timeInterval:0.05,repeats:true){[weak self] _ in self?.tick()}
            RunLoop.main.add(tick,forMode:.common);timer=tick
        }
    }
    private var running:Bool{session?.tapTest != nil}
    private func tick(){
        let now=ProcessInfo.processInfo.systemUptime
        if running,let aim=session?.aimPoint{run?.aim(at:now,aim)}
        if running,session?.stage != .pointing{finish(stoppedBecause:"Pointing stopped, so the test ended. Start pointing, then run it again.")}
        else if running,let run,now>=run.end{finish(stoppedBecause:nil)}
        sync(now:now)
    }
    @objc private func primaryClicked(){
        if running{finish(stoppedBecause:"Test cancelled.");sync(now:ProcessInfo.processInfo.systemUptime);return}
        guard let live=liveSession(),live.stage == .pointing else{return}
        stopped=nil;session=live;announced=nil
        run=TapTestRun(start:ProcessInfo.processInfo.systemUptime)
        live.noteTapTest("start")
        // Taps are only counted here, so they don't click whatever the pointer is on.
        live.tapTest={[weak self] outcome in
            guard let self else{return}
            let now=ProcessInfo.processInfo.systemUptime
            switch outcome{case .click:self.run?.click(at:now);case .rejected(let why):self.run?.rejected(at:now,why)}
        }
        sync(now:ProcessInfo.processInfo.systemUptime)
    }
    private func finish(stoppedBecause reason:String?){
        session?.tapTest=nil;stopped=reason
        guard let run else{return}
        if reason==nil{
            totals.hits+=run.hits.count;totals.cues+=TapTestRun.cues;totals.extra+=run.extraClicks
            totals.quick+=run.quickHits;totals.quickAsked+=TapTestRun.quickTaps;totals.move+=run.moveHits.count;totals.moveCues+=TapTestRun.moveCues;totals.moveExtra+=run.moveExtra
            totals.falseClicks+=run.falseClicks;totals.seconds+=TapTestRun.pointingFor
            session?.noteTapTest(String(format:"done hits=%d/%d extra=%d false=%d quick=%d/%d move=%d/%d moveExtra=%d swung=%d",run.hits.count,TapTestRun.cues,run.extraClicks,run.falseClicks,run.quickHits,TapTestRun.quickTaps,run.moveHits.count,TapTestRun.moveCues,run.moveExtra,run.swung.count))
            save(run)
        }else{session?.noteTapTest("stopped");self.run=nil}
    }
    private func save(_ run:TapTestRun){
        var record=run.record
        // H1 uses separate thresholds, so statistics must record them instead of H2 defaults.
        if session?.usesHeadphoneMotion == true{
            record["minimumAlignment"]=HeadphoneTapTuning.minimumAlignment
            record["headphoneMotion"]=true
        }
        record["date"]=ISO8601DateFormatter().string(from:Date());record["session"]=session?.captureFolder?.lastPathComponent ?? ""
        guard var line=try? JSONSerialization.data(withJSONObject:record,options:.sortedKeys) else{return}
        line.append(0x0A)
        if let file=try? closedCaseAppendingHandle(Self.results){try? file.write(contentsOf:line);try? file.close()}
    }
    func sync(now:Double){
        let phase=running ? run?.phase(at:now):nil
        if let label=phase?.label,label != announced{
            announced=label;session?.noteTapTest(label)
            // A new kind of step is easy to miss while watching the case, so it gets a sound too.
            if label.hasPrefix("next"){NSSound(named:"Tink")?.play()}
        }
        dots.count=TapTestRun.cues;dots.hits=run?.hits ?? [];dots.isHidden=run==nil;dots.finished=false;dots.current=nil
        progress.isHidden=false
        switch phase {
        case .getReady(let left):
            chip.set("Get ready",dot:false);rkSetText(title,"Get ready");rkSetText(instruction,"Hold the case the way you normally point with it.")
            prompt.stringValue=String(Int(left.rounded(.up)));progress.stringValue="Tap once on each cue"
            primary.title="Cancel"
        case .tap(let cue):
            chip.set("Tapping",live:true);rkSetText(title,"Tap once on each cue");rkSetText(instruction,"Tap the front of the case when the number changes.")
            prompt.stringValue="Tap";progress.stringValue="\(cue+1) of \(TapTestRun.cues)";dots.current=cue
            primary.title="Cancel"
        case .getQuick(let left):
            chip.set("Get ready",dot:false);rkSetText(title,"Next: tap fast");rkSetText(instruction,"Tap the front \(TapTestRun.quickTaps) times, as fast as feels natural. Don’t wait between taps.")
            prompt.stringValue="Tap fast in \(Int(left.rounded(.up)))";progress.stringValue="\(TapTestRun.quickTaps) quick taps";dots.isHidden=true
            primary.title="Cancel"
        case .quick:
            chip.set("Tapping",live:true);rkSetText(title,"Tap fast");rkSetText(instruction,"Tap the front \(TapTestRun.quickTaps) times, as fast as feels natural. Don’t wait between taps.")
            prompt.stringValue="Tap fast";progress.stringValue="\(run?.quickHits ?? 0) of \(TapTestRun.quickTaps) clicked"
            dots.count=TapTestRun.quickTaps;dots.hits=Set(0..<(run?.quickHits ?? 0))
            primary.title="Cancel"
        case .getMove(let left):
            chip.set("Get ready",dot:false);rkSetText(title,"Next: tap, then swing away");rkSetText(instruction,"On each cue, tap the front, then swing the pointer across the screen right away.")
            prompt.stringValue="Tap + swing in \(Int(left.rounded(.up)))";progress.stringValue="\(TapTestRun.moveCues) taps";dots.isHidden=true
            primary.title="Cancel"
        case .move(let cue):
            chip.set("Tapping",live:true);rkSetText(title,"Tap, then swing away");rkSetText(instruction,"On each cue, tap the front, then swing the pointer across the screen right away.")
            prompt.stringValue="Tap + swing";progress.stringValue="\(cue+1) of \(TapTestRun.moveCues)"
            dots.count=TapTestRun.moveCues;dots.hits=run?.moveHits ?? [];dots.current=cue
            primary.title="Cancel"
        case .point(let left):
            chip.set("Pointing",live:true);rkSetText(title,"Don’t tap now");rkSetText(instruction,"Point around the screen the way you normally would, and don’t touch the front of the case.")
            prompt.stringValue="Just point";progress.stringValue="\(Int(left.rounded(.up))) s left";dots.isHidden=true
            primary.title="Cancel"
        default:
            primary.title=run==nil ? "Start Test":"Run Again"
            let pointing=liveSession()?.stage == .pointing
            primary.isEnabled=pointing
            if let run,stopped==nil{
                dots.finished=true
                chip.set("Done",dot:false);rkSetText(title,"\(run.hits.count) of \(TapTestRun.cues) taps clicked")
                var text=run.summary
                if totals.cues>TapTestRun.cues{text+=" All runs so far: \(totals.hits) of \(totals.cues) taps, \(totals.quick) of \(totals.quickAsked) fast, \(totals.move) of \(totals.moveCues) with a swing, \(totals.extra+totals.moveExtra) extra, \(totals.falseClicks) false in \(Int(totals.seconds)) s."}
                rkSetText(instruction,text)
                prompt.stringValue="\(run.hits.count)/\(TapTestRun.cues)";progress.stringValue="\(run.quickHits)/\(TapTestRun.quickTaps) fast · \(run.moveHits.count)/\(TapTestRun.moveCues) with a swing · \(run.falseClicks) false"
            }else{
                chip.set(pointing ? "Ready":"Not pointing",dot:pointing);rkSetText(title,"Tap test")
                rkSetText(instruction,stopped ?? (pointing ? "Four steps: tap on each cue, tap fast, tap then swing away, then point without tapping. It takes about 75 seconds, and your taps won’t click anything.":"Start pointing with the closed case first, then run the test."))
                prompt.stringValue="\(TapTestRun.cues+TapTestRun.quickTaps+TapTestRun.moveCues) taps";progress.stringValue="then \(Int(TapTestRun.pointingFor)) seconds of pointing"
            }
            return
        }
        primary.isEnabled=true
    }
    func windowWillClose(_ notification:Notification){
        if running{finish(stoppedBecause:"Test cancelled.")}
        timer?.invalidate();timer=nil
    }
}
