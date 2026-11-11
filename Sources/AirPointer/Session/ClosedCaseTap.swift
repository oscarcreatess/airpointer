import Foundation

// A finger tap on the front of the closed case, found in one earbud's raw motion (50 to 200 Hz).
// A finger on the front pushes one way: the sensor turns with the case, so however it's held, every recorded tap lines up
// with tapDirection, however light, and bumps elsewhere fall short. Strength and wobble overlap between the two, so they don't decide.
// The click is decided on the sample the spike arrives in, without waiting for the wobble to end. A first tap has to come from
// a still case, which keeps handling out; the finger's approach may drift it for up to 100 ms first. Just before a tap the case
// turned 28°/s at most, and just before tap-like jolts from moving it 41°/s or more, so turning asks for a firmer, more exact spike.
// A firm, exact spike with little turning counts even if the hand wasn't quite still. For a second after a tap the hand
// hasn't settled, so a spike there only has to come without much rotation.
// The thresholds come from closed-lid taps held in the hand, closed-lid handling and pointing (Tests/TapFixtures.csv)
// and from runs of the tap test. They and the default direction were tuned on AirPods Pro 3. AirPods 4 shares the H2
// motion stack but has a different case and earbud shape, so Teach Tap and the Tap Test should confirm its taps.
struct ClosedCaseTapDetector {
    // tap: click where the pointer was before `since` (sensor seconds), and keep it there through the wobble.
    // repeated means it counted only because it came soon after another tap. release: the pointer can move again.
    enum Event:Equatable{case tap(since:Double,jolt:Double,repeated:Bool),release}
    // Accelerations in g, rotation in degrees per second, times in seconds, so any sample rate works.
    static let jolt=0.2,softJolt=0.12,repeatJolt=0.22,stillAcceleration=0.08,minimumAlignment=0.9
    static let stillRotation=40.0,calmLead=30.0,leadRotation=60.0,calmRepeat=45.0,repeatRotation=90.0,fastRotation=35.0,runStartRotation=150.0
    static let firmJolt=0.3,firmAlignment=0.95,echoShare=0.7
    static let tapDirection:SIMD3<Double>={let v=SIMD3(-0.84,0.29,-0.46);return v/(v*v).sum().squareRoot()}()
    // A spike is the change over spikeOver, measured across a gap of at most spikeGap.
    static let spikeOver=0.015,spikeGap=0.05,stillFor=0.13,stillWindow=0.15,leadIn=0.1,peakWithin=0.03,refractory=0.25,fastRefractory=0.12
    // Rotation just before a spike is judged up to impactFrom ahead of it, because the impact itself turns the case.
    static let repeatLeadIn=0.12,impactFrom=0.02,runFor=1.0,runStartAfter=0.06,steadyFor=0.2
    // The case drops runs of samples over 60 ms more than twice a second, so stillness rides out gaps up to this.
    static let maximumGap=0.25
    fileprivate struct Sample{let t:Double;let a:SIMD3<Double>;let w:SIMD3<Double>}
    // The way a finger on the front pushes this case's sensor, learned in setup if it isn't tapDirection.
    var direction=Self.tapDirection
    var lowSampleRate=false
    private var recent:[Sample]=[],rotation:(t:Double,w:SIMD3<Double>)?
    private var lastTap = -Double.infinity,tapPeak=0.0,runFrom = -Double.infinity,steadyUntil:Double?
    // Jolts that didn't click, for the session log. The reader empties it.
    var ignored:[String]=[]
    private var lastIgnored = -Double.infinity,ignoredSize=0.0

    // Starting over lets go of a held pointer.
    mutating func reset()->[Event]{rotation=nil;runFrom = -Double.infinity;return restart()}
    private mutating func restart()->[Event]{
        let held=steadyUntil != nil;recent=[];steadyUntil=nil
        return held ? [.release]:[]
    }
    // Motion rows as the helper writes them: sequence, service (11 accelerometer, 12 gyroscope),
    // sensor microseconds, host uptime, then x, y, z in units of 1e-5. A batch can arrive out of order across services.
    mutating func feed(_ rows:[[Double]])->[Event]{
        rows.filter{$0.count==7}.sorted{$0[2]<$1[2]}.flatMap{feed(service:Int($0[1]),stamp:$0[2],x:$0[4],y:$0[5],z:$0[6])}
    }
    mutating func feed(service:Int,stamp:Double,x:Double,y:Double,z:Double)->[Event]{
        let t=stamp*1e-6,v=SIMD3(x,y,z)*1e-5
        guard t.isFinite,v.x.isFinite,v.y.isFinite,v.z.isFinite else{return []}
        if service==12{rotation=(t,v);return []}
        guard service==11 else{return []}
        if let last=recent.last,t<=last.t{return []}
        // Without a rotation close in time the shape can't be judged; after a long delivery gap it starts over.
        guard let rotation,abs(rotation.t-t)<=Self.maximumGap else{return restart()}
        var events:[Event]=[]
        if let last=recent.last,t-last.t>Self.maximumGap{events=restart()}
        let sample=Sample(t:t,a:v,w:rotation.w)
        defer{
            recent.append(sample)
            while let first=recent.first,t-first.t>Self.leadIn+Self.stillWindow+2*Self.maximumGap{recent.removeFirst()}
        }
        return events+step(sample)
    }
    private func length(_ v:SIMD3<Double>)->Double{(v*v).sum().squareRoot()}
    private mutating func step(_ s:Sample)->[Event]{
        var events:[Event]=[]
        if let steadyUntil,s.t>=steadyUntil{self.steadyUntil=nil;events.append(.release)}
        guard let before=recent.last(where:{s.t-$0.t>=Self.spikeOver}) ?? recent.first,s.t-before.t<=(lowSampleRate ? HeadphoneTapTuning.spikeGap:Self.spikeGap) else{return events}
        let spike=s.a-before.a,size=length(spike),projection=(spike*direction).sum()
        // Low-rate sampling may capture only the rebound peak, so H1 uses the calibrated axis and a longer refractory period to suppress duplicate clicks.
        let along=lowSampleRate ? abs(projection):projection
        if s.t-lastTap<=(lowSampleRate ? HeadphoneTapTuning.peakWithin:Self.peakWithin){tapPeak=max(tapPeak,along)}
        guard s.t-lastTap>=(lowSampleRate ? HeadphoneTapTuning.fastRefractory:Self.fastRefractory),size>=Self.softJolt else{return events}
        guard along>=size*(lowSampleRate ? HeadphoneTapTuning.minimumAlignment:Self.minimumAlignment) else{
            // The rebound of any jolt points backwards, so only forward ones say anything about a tap.
            if size>=Self.jolt,along>0{ignore(s.t,size,String(format:"not on the front, alignment %.2f, jolt %.2f g",along/size,size))}
            return events
        }
        guard along>=(lowSampleRate ? HeadphoneTapTuning.jolt:Self.jolt) else{ignore(s.t,along,String(format:"too soft, %.2f g",along));return events}
        let impactFrom=lowSampleRate ? HeadphoneTapTuning.impactFrom:Self.impactFrom
        let lead=rotations(from:s.t-Self.leadIn,to:s.t-impactFrom).max(),justBefore=rotations(from:s.t-Self.repeatLeadIn,to:s.t-impactFrom).max()
        // A case turning a little is often about to be moved, so a tap then has to be firmer and more exact.
        let firm=along>=Self.firmJolt && along>=size*(lowSampleRate ? HeadphoneTapTuning.firmAlignment:Self.firmAlignment)
        let base=still(before:s.t-Self.leadIn),first=base != nil && lead ?? 0<=(firm ? Self.leadRotation:Self.calmLead)
        let exact=firm && justBefore.map{$0<=Self.calmRepeat} ?? false
        // A spike turned down a moment ago starts a run for the next tap, not for the rest of itself.
        let repeated=s.t-runFrom<=Self.runFor && (runFrom==lastTap || s.t-runFrom>=Self.runStartAfter) && along>=(lowSampleRate ? HeadphoneTapTuning.jolt:Self.repeatJolt) && justBefore.map{$0<=(firm ? Self.repeatRotation:Self.calmRepeat)} ?? false
        // Soon after a click, a tap's own echo is much weaker than it and comes with the hand turning.
        if s.t-lastTap<Self.refractory{
            guard repeated,along>=tapPeak*Self.echoShare,justBefore ?? .infinity<=Self.fastRotation else{return events}
        }
        guard first || repeated || exact else{
            // A tap turned down for coming straight after a move still starts a run, so the next one counts.
            if along>=(lowSampleRate ? HeadphoneTapTuning.jolt:Self.repeatJolt),let justBefore,justBefore<=Self.runStartRotation{runFrom=s.t}
            ignore(s.t,along,base==nil ? unsteady(before:s.t-Self.leadIn,along:along):String(format:"jolt %.2f g, rotating %.0f°/s just before",along,lead ?? 0))
            return events
        }
        // The finger's approach may drift the case a little; the click belongs where that began.
        let drift=base.flatMap{base in recent.first{$0.t>=s.t-Self.leadIn && length($0.a-base)>Self.stillAcceleration}?.t}
        if steadyUntil != nil{events.append(.release)}
        lastTap=s.t;tapPeak=along;runFrom=s.t;steadyUntil=s.t+Self.steadyFor
        return events+[.tap(since:min(drift ?? before.t,before.t),jolt:along,repeated:!first && repeated)]
    }
    private func rotations(from:Double,to:Double)->[Double]{recent.filter{$0.t>=from && $0.t<=to}.map{length($0.w)}}
    // A spike can be turned down twice on its way up, so a much stronger reason still gets logged.
    private mutating func ignore(_ t:Double,_ size:Double,_ why:String){
        guard t-lastIgnored>=Self.refractory || size>ignoredSize*1.5 else{return}
        lastIgnored=t;ignoredSize=size;ignored.append(String(format:"ignored at %.2f: ",t)+why)
    }
    private func unsteady(before end:Double,along:Double)->String{
        let window=recent.filter{$0.t<end && end-$0.t<=Self.stillWindow}
        return String(format:"sudden %.2f g, not still before it, %d samples, rotating up to %.0f°/s",along,window.count,window.map{length($0.w)}.max() ?? 0)
    }
    // The resting acceleration over about 140 ms ending at `end`, if the case was still then. A gap in that window
    // borrows earlier samples, up to one gap's worth, so it only means fewer samples to judge by.
    private func still(before end:Double)->SIMD3<Double>?{Self.still(recent,before:end)}
    fileprivate static func still(_ recent:[Sample],before end:Double)->SIMD3<Double>?{
        func length(_ v:SIMD3<Double>)->Double{(v*v).sum().squareRoot()}
        let earlier=recent.filter{$0.t<end}
        var window=earlier.filter{end-$0.t<=Self.stillWindow}
        while window.count<3 || end-(window.first?.t ?? end)<Self.stillFor,
              let more=earlier.last(where:{$0.t<(window.first?.t ?? end)}),end-more.t<=Self.stillWindow+Self.maximumGap{window.insert(more,at:0)}
        guard window.count>=3,let first=window.first,end-first.t>=Self.stillFor else{return nil}
        let base=window.reduce(SIMD3<Double>.zero){$0+$1.a}/Double(window.count)
        guard window.allSatisfy({length($0.w)<=Self.stillRotation && length($0.a-base)<=Self.stillAcceleration}) else{return nil}
        return base
    }
}

// Learns which way a person's taps push the sensor, from a few taps on a still case in any direction. A person whose
// taps already line up with tapDirection keeps it, because it comes from many more taps than three.
struct ClosedCaseTapLearner {
    // agreeing is the largest group of taps so far that went the same way.
    enum Event:Equatable{case tap(agreeing:Int,total:Int),tooSoft,finished(direction:SIMD3<Double>),failed}
    static let taps=3,mostTaps=6,tapsAgree=0.9,keepDefault=0.95,refractory=0.4,softAfter=0.08,windUp=2.0,windUpWithin=0.05
    private typealias Detector=ClosedCaseTapDetector
    private let lowSampleRate:Bool
    init(lowSampleRate:Bool=false){self.lowSampleRate=lowSampleRate}
    private var recent:[Detector.Sample]=[],rotation:(t:Double,w:SIMD3<Double>)?,lastTap = -Double.infinity,lastSoft = -Double.infinity,softSince:Double?
    private var pushing:(start:Double,first:SIMD3<Double>,strongest:SIMD3<Double>)?
    private(set) var pushes:[SIMD3<Double>]=[]
    private var done=false

    mutating func feed(_ rows:[[Double]])->[Event]{
        rows.filter{$0.count==7}.sorted{$0[2]<$1[2]}.flatMap{feed(service:Int($0[1]),stamp:$0[2],x:$0[4],y:$0[5],z:$0[6])}
    }
    private func length(_ v:SIMD3<Double>)->Double{(v*v).sum().squareRoot()}
    mutating func feed(service:Int,stamp:Double,x:Double,y:Double,z:Double)->[Event]{
        let t=stamp*1e-6,v=SIMD3(x,y,z)*1e-5
        guard !done,t.isFinite,v.x.isFinite,v.y.isFinite,v.z.isFinite else{return []}
        if service==12{rotation=(t,v);return []}
        guard service==11,let rotation,abs(rotation.t-t)<=Detector.maximumGap else{return []}
        if let last=recent.last,t<=last.t{return []}
        let sample=Detector.Sample(t:t,a:v,w:rotation.w)
        defer{
            recent.append(sample)
            while let first=recent.first,t-first.t>Detector.leadIn+Detector.stillWindow+2*Detector.maximumGap{recent.removeFirst()}
        }
        guard let before=recent.last(where:{t-$0.t>=Detector.spikeOver}) ?? recent.first,t-before.t<=(lowSampleRate ? HeadphoneTapTuning.spikeGap:Detector.spikeGap) else{return []}
        let spike=v-before.a
        if let pushing{
            let along=(spike*pushing.first).sum()
            if t-pushing.start<=(lowSampleRate ? HeadphoneTapTuning.peakWithin:Detector.peakWithin),lowSampleRate || along>0{
                // H1 must not let a stronger sideways rebound overwrite the detected tap axis.
                if length(spike)>length(pushing.strongest), !lowSampleRate || abs(along)>=length(spike)*length(pushing.first)*HeadphoneTapTuning.peakAlignment{self.pushing!.strongest=spike}
                return []
            }
            if t-pushing.start<=(lowSampleRate ? HeadphoneTapTuning.windUpWithin:Self.windUpWithin){
                // The case can shift the other way just before a hard tap lands: a far bigger push this soon is the finger.
                if along<0,length(spike)>=Self.windUp*length(pushing.strongest){self.pushing=(t,spike,spike);lastTap=t}
                return []
            }
            self.pushing=nil
            pushes.append(pushing.strongest)
            return finish()
        }
        // A firm tap passes through this size on its way up, so too soft has to wait and see.
        var events:[Event]=[]
        if let softSince,t-softSince>=Self.softAfter{self.softSince=nil;lastSoft=t;events=[.tooSoft]}
        guard t-lastTap>=Self.refractory,length(spike)>=Detector.softJolt else{return events}
        if length(spike)>=Detector.jolt{softSince=nil}
        // As in the detector, a firm tap may come with more turning just ahead of it.
        let lead=length(spike)>=Detector.firmJolt ? Detector.leadRotation:Detector.calmLead
        let calm=recent.filter{$0.t>=t-Detector.leadIn && $0.t<=t-(lowSampleRate ? HeadphoneTapTuning.impactFrom:Detector.impactFrom)}.allSatisfy{length($0.w)<=lead}
        guard calm,Detector.still(recent,before:t-Detector.leadIn) != nil else{return events}
        guard length(spike)>=(lowSampleRate ? HeadphoneTapTuning.learningJolt:Detector.jolt) else{
            if softSince==nil,t-lastSoft>=Self.refractory{softSince=t}
            return events
        }
        lastTap=t;pushing=(t,spike,spike)
        return events
    }
    private mutating func finish()->[Event]{
        let group=Self.largestGroup(pushes,agreement:lowSampleRate ? HeadphoneTapTuning.learningAgreement:Self.tapsAgree,axis:lowSampleRate)
        var events:[Event]=[.tap(agreeing:group.count,total:pushes.count)]
        if group.count>=Self.taps{
            let mean=Self.unit(group.reduce(.zero,+))
            done=true;events.append(.finished(direction:(mean*Detector.tapDirection).sum()>=Self.keepDefault ? Detector.tapDirection:mean))
        }else if pushes.count>=Self.mostTaps{done=true;events.append(.failed)}
        return events
    }
    private static func unit(_ v:SIMD3<Double>)->SIMD3<Double>{v/max((v*v).sum().squareRoot(),1e-9)}
    private static func largestGroup(_ pushes:[SIMD3<Double>],agreement:Double,axis:Bool)->[SIMD3<Double>]{
        let units=pushes.map(unit)
        if axis{
            return units.map{one in units.filter{abs((one*$0).sum())>=agreement}.map{(one*$0).sum()<0 ? -$0:$0}}.max{$0.count<$1.count} ?? []
        }
        return units.map{one in units.filter{(one*$0).sum()>=agreement}}.max{$0.count<$1.count} ?? []
    }
}

// Recorded segments: real front taps (tap*, and the run of hand-held ones in held), lid closing, pointing,
// and the strongest closed-lid handling jolts with no tap.
func loadClosedCaseTapFixtures(_ url:URL) throws -> [(name:String,rows:[[Double]])] {
    var segments:[(name:String,rows:[[Double]])]=[]
    for line in try String(contentsOf:url,encoding:.utf8).split(separator:"\n") where !line.hasPrefix("#") {
        let fields=line.split(separator:",")
        guard fields.count==6,let service=Double(fields[1]),let stamp=Double(fields[2]),
              let x=Double(fields[3]),let y=Double(fields[4]),let z=Double(fields[5]) else{throw LessonError.message("Invalid tap fixture row.")}
        let name=String(fields[0]),row=[0,service,stamp+1e9,0,x,y,z]
        if segments.last?.name==name{segments[segments.count-1].rows.append(row)}else{segments.append((name,[row]))}
    }
    return segments
}

func runClosedCaseTapChecks(fixtures:URL?) throws {
    func replay(_ rows:[[Double]],batch:Int)->[ClosedCaseTapDetector.Event]{
        var detector=ClosedCaseTapDetector(),events:[ClosedCaseTapDetector.Event]=[]
        var index=0
        while index<rows.count{events+=detector.feed(Array(rows[index..<min(rows.count,index+batch)]));index+=batch}
        return events+detector.reset()
    }
    func taps(_ events:[ClosedCaseTapDetector.Event])->[Double]{events.compactMap{if case .tap(let since,_,_)=$0{return since};return nil}}
    // Every click holds the pointer and is let go before the next, so the pointer is never left frozen.
    func balanced(_ events:[ClosedCaseTapDetector.Event])->Bool{
        var held=false
        for event in events{
            switch event{case .tap:if held{return false};held=true;case .release:if !held{return false};held=false}
        }
        return !held
    }
    // Synthetic motion (50 Hz unless given a period): a still case at rest under gravity, with what happens after a second.
    // Each gyroscope reading lands a quarter period before its accelerometer one; `drop` skips samples by index.
    func motion(_ seconds:Double,period:Double=0.02,drop:(Int)->Bool={_ in false},_ shape:(Double)->(SIMD3<Double>,Double))->[[Double]]{
        (0..<Int((seconds/period).rounded())).filter{!drop($0)}.flatMap{i->[[Double]] in
            let t=Double(i)*period,(a,w)=shape(t),stamp=1e9+t*1e6
            return [[0,12,stamp-period*2.5e5,0,w*1e5,0,0],[0,11,stamp,0,a.x*1e5,a.y*1e5,a.z*1e5]]
        }
    }
    let rest=SIMD3(-0.8,-0.1,0.6),front=ClosedCaseTapDetector.tapDirection
    let still=motion(3){_ in (rest,0.8)}
    let tapped=motion(2){t in
        let k=Int(((t-1)/0.02).rounded())
        return k==0 ? (rest+front*0.5,85):k==1 ? (rest+SIMD3(0.2,0,0),70):(1...5).contains(k) ? (rest,30):(rest,0.8)
    }
    let turned=motion(2){t in t<1 ? (rest,0.8):(SIMD3(-0.6,-0.1,0.8),t<1.5 ? 120:5)}
    // A firm tap can leave the hand holding the case about 8° differently.
    let tilted=motion(2){t in
        let k=Int(((t-1)/0.02).rounded()),left=rest+SIMD3(0.14,0,0)
        return k==0 ? (rest+front*0.5,85):k==1 ? (rest+SIMD3(0.2,0,0),70):(1...5).contains(k) ? (left,30):t>1 ? (left,0.8):(rest,0.8)
    }
    let moving=motion(2){t in (rest+front*(t>1 && t<1.03 ? 0.5:0),60)}
    // The same small, short jolt counts on the front and not from another direction.
    func small(_ push:SIMD3<Double>)->[[Double]]{
        motion(2){t in
            let k=Int(((t-1)/0.02).rounded())
            return k==0 ? (rest+push,30):(1...3).contains(k) ? (rest,10):(rest,0.8)
        }
    }
    guard replay(still,batch:4).isEmpty else{throw LessonError.message("A still case must not click.")}
    let one=replay(tapped,batch:4)
    guard taps(one).count==1,abs(taps(one)[0]-(1e3+1))<0.021,case .tap=one.first,balanced(one) else{
        throw LessonError.message("A tap after a still moment must click once at the jolt, holding the pointer.")
    }
    guard taps(replay(tilted,batch:4)).count==1,balanced(replay(tilted,batch:4)) else{throw LessonError.message("A tap that tilts the case a little must still click.")}
    guard taps(replay(turned,batch:4)).isEmpty,balanced(replay(turned,batch:4)) else{throw LessonError.message("Turning the case must not click.")}
    guard taps(replay(moving,batch:4)).isEmpty else{throw LessonError.message("A jolt while the case is rotating must not click.")}
    guard taps(replay(small(SIMD3(0,0,0.3)),batch:4)).isEmpty,balanced(replay(small(SIMD3(0,0,0.3)),batch:4)) else{throw LessonError.message("A bump from another direction must not click.")}
    guard taps(replay(small(front*0.3),batch:4)).count==1 else{throw LessonError.message("A light tap on the front must click.")}
    // Differently sized batches, and services interleaved differently inside one, give the same result.
    guard replay(tapped,batch:1)==one,replay(tapped,batch:9)==one else{throw LessonError.message("Tap detection must not depend on batch size.")}
    var swapped=tapped;for i in stride(from:0,to:swapped.count-1,by:2){swapped.swapAt(i,i+1)}
    guard replay(swapped,batch:2)==one else{throw LessonError.message("Tap detection must not depend on row order within a batch.")}
    // A long delivery gap after the click lets go of the pointer.
    let cut=replay(tapped.filter{$0[2]<1e9+1.03e6 || $0[2]>1e9+1.3e6},batch:4)
    guard taps(cut).count==1,balanced(cut) else{throw LessonError.message("A gap after a click must release the pointer.")}
    // Short gaps, like the ones the case drops several times a second, don't lose the tap: one inside the still
    // moment, one at its start, and one hiding the ringing right after the jolt.
    for (from,to) in [(0.76,0.86),(0.70,0.80),(1.01,1.11)]{
        let events=replay(tapped.filter{$0[2]<1e9+from*1e6 || $0[2]>1e9+to*1e6},batch:4)
        guard taps(events).count==1,balanced(events) else{throw LessonError.message("A 100 ms gap at \(from) s must not lose the tap.")}
    }
    // A gap just before the jolt could hide the case starting to move, so that jolt doesn't count.
    guard replay(tapped.filter{$0[2]<1e9+0.87e6 || $0[2]>1e9+0.99e6},batch:4).isEmpty else{
        throw LessonError.message("A jolt right after a gap must not click.")
    }
    let hiddenTurn=replay(turned.filter{$0[2]<1e9+1.01e6 || $0[2]>1e9+1.11e6},batch:4)
    guard taps(hiddenTurn).isEmpty,balanced(hiddenTurn) else{throw LessonError.message("A turn hidden by a gap must not click.")}
    // Two jolts 180 ms apart are one tap if the case is turning between them.
    let twice=motion(2){t in
        let k=Int(((t-1)/0.02).rounded())
        return k==0 || k==9 ? (rest+front*0.5,85):(1...4).contains(k) ? (rest,40):(5...14).contains(k) ? (rest,8):(rest,0.8)
    }
    guard taps(replay(twice,batch:4)).count==1 else{throw LessonError.message("A second jolt inside 250 ms must not click again.")}
    // At 200 Hz, with the rotation a sample or two behind the jolt and every third sample missing, it's the same tap.
    let fast=motion(2,period:0.005,drop:{$0%3==1}){t in
        let k=Int(((t-1)/0.005).rounded())
        return k==0 ? (rest+front*0.5,0.8):k==1 ? (rest+SIMD3(0.3,0,0.1),40):k==2 ? (rest+SIMD3(0.1,0,0),85)
            :(3...30).contains(k) ? (rest,30):(rest,0.8)
    }
    for batch in [1,7,20]{
        let events=replay(fast,batch:batch)
        guard taps(events).count==1,abs(taps(events)[0]-(1e3+1))<0.021,case .tap=events.first,balanced(events) else{
            throw LessonError.message("A 200 Hz tap must click once at the jolt, holding the pointer.")
        }
    }
    let fastTurn=replay(motion(2,period:0.005){t in t<1 ? (rest,0.8):(SIMD3(-0.6,-0.1,0.8),t<1.5 ? 120:5)},batch:20)
    guard replay(motion(3,period:0.005){_ in (rest,0.8)},batch:20).isEmpty,taps(fastTurn).isEmpty,balanced(fastTurn) else{
        throw LessonError.message("At 200 Hz a still or turned case must not click.")
    }
    // Quick taps: the hand is still moving from the last tap, so only a firm spike without much rotation counts.
    // The first is always a real tap; `push` is what follows it.
    func run(_ times:[Double],push:SIMD3<Double>=front*0.5,rotation:Double=50,from:Double?=nil)->[ClosedCaseTapDetector.Event]{
        replay(motion(4){t in
            let hit=times.contains{abs($0-t)<0.005},first=abs(times[0]-t)<0.005
            return (rest+(first ? front*0.5:hit ? push:.zero),t>(from ?? times[0]) ? rotation:0.8)
        },batch:4)
    }
    let quick=run([1,1.5,2])
    guard taps(quick).count==3,balanced(quick) else{throw LessonError.message("Quick taps must each click.")}
    guard quick.filter({if case .tap(_,_,true)=$0{return true};return false}).count==2 else{throw LessonError.message("Only taps after the first count as repeats.")}
    guard taps(run([1,1.5],rotation:120)).count==1 else{throw LessonError.message("A repeat tap while the case is turning fast must not click.")}
    guard taps(run([1,1.5],push:front*0.22)).count==1 else{throw LessonError.message("A soft repeat while the case is turning must not click.")}
    let double=run([1,1.18],rotation:20)
    guard taps(double).count==2,balanced(double) else{throw LessonError.message("A fast second tap must click.")}
    guard taps(run([1,1.18],push:front*0.25,rotation:20)).count==1 else{throw LessonError.message("A tap's weak echo must not click.")}
    guard taps(run([1,1.1],rotation:20)).count==1 else{throw LessonError.message("Nothing clicks within 120 ms of a click.")}
    guard taps(run([1,1.5],push:SIMD3(0,0,0.5))).count==1 else{throw LessonError.message("A repeat from another direction must not click.")}
    guard taps(run([1,2.5])).count==1 else{throw LessonError.message("A run of taps must end after a second.")}
    let late=taps(run([1,1.6],from:0))
    guard late.count==1,abs(late[0]-(1e3+1.6))<0.021 else{throw LessonError.message("A tap turned down for moving must start a run.")}
    // A firm, exact spike with little turning needs no stillness; a softer one does.
    func unsteady(_ push:SIMD3<Double>)->[ClosedCaseTapDetector.Event]{
        replay(motion(2){t in
            let k=Int((t/0.02).rounded())
            return (rest+(abs(t-1)<0.005 ? push:SIMD3(k%2==0 ? 0.2:0,0,0)),20)
        },batch:4)
    }
    guard taps(unsteady(front*0.5)).count==1 else{throw LessonError.message("A firm tap on a slightly unsteady case must click.")}
    guard taps(unsteady(front*0.22)).isEmpty else{throw LessonError.message("A soft jolt on an unsteady case must not click.")}
    // Learning: three taps at one second and a half apart on a still case.
    let sideways=SIMD3(0.3,0.9,-0.3)/(SIMD3(0.3,0.9,-0.3)*SIMD3(0.3,0.9,-0.3)).sum().squareRoot()
    func tapping(_ pushes:[SIMD3<Double>],period:Double=0.02,rotation:Double=0.8)->[[Double]]{
        motion(Double(pushes.count)*1.5+1,period:period){t in
            for (index,push) in pushes.enumerated() where abs(t-1-Double(index)*1.5)<period/4{return (rest+push,rotation)}
            return (rest,rotation)
        }
    }
    func learn(_ rows:[[Double]])->[ClosedCaseTapLearner.Event]{var learner=ClosedCaseTapLearner();return learner.feed(rows)}
    func direction(_ events:[ClosedCaseTapLearner.Event])->SIMD3<Double>?{events.compactMap{if case .finished(let d)=$0{return d};return nil}.first}
    let elsewhere=tapping([sideways*0.5,sideways*0.4,sideways*0.6])
    guard let learned=direction(learn(elsewhere)),(learned*sideways).sum()>0.99 else{throw LessonError.message("Three taps one way must teach that direction.")}
    guard taps(replay(elsewhere,batch:4)).isEmpty else{throw LessonError.message("Taps from elsewhere must not click before they're learned.")}
    var taught=ClosedCaseTapDetector();taught.direction=learned
    guard taught.feed(elsewhere).filter({if case .tap=$0{return true};return false}).count==3 else{throw LessonError.message("A learned direction must click on those taps.")}
    guard direction(learn(tapping([front*0.5,front*0.4,front*0.6])))==front else{throw LessonError.message("Taps along the known direction must keep it.")}
    let across=SIMD3(0.46,0,-0.84)
    guard direction(learn(tapping([sideways*0.5,across*0.5,sideways*0.5,sideways*0.5]))) != nil else{throw LessonError.message("One stray tap must not spoil the others.")}
    let scattered=learn(tapping([sideways,across,front,sideways,across,front].map{$0*0.5}))
    guard direction(scattered)==nil,scattered.contains(.tap(agreeing:2,total:6)),scattered.last == .failed else{throw LessonError.message("Taps that never agree must fail.")}
    guard learn(tapping([sideways*0.5],rotation:60)).isEmpty else{throw LessonError.message("A jolt while the case is turning must not teach anything.")}
    guard learn(tapping([sideways*0.15])) == [.tooSoft] else{throw LessonError.message("A soft tap must ask for a firmer one.")}
    // At 200 Hz a firm tap rises through the soft size on its way up, and that must not ask for a firmer one.
    let rising=motion(3,period:0.005){t in
        let k=Int(((t-1)/0.005).rounded())
        return (rest+sideways*(k==0 ? 0.15:k==1 ? 0.3:k==2 ? 0.5:0),0.8)
    }
    guard learn(rising) == [.tap(agreeing:1,total:1)] else{throw LessonError.message("A firm tap must count once, without asking for a firmer one.")}
    // A hard tap can start with a small shift the other way and some turning, as recorded in setup.
    func braced(_ size:Double)->[[Double]]{
        motion(3,period:0.005){t in
            let k=Int(((t-1)/0.005).rounded()),near=(0...7).contains(k)
            return (rest+sideways*((0...5).contains(k) ? -size:k==6 ? 0.8:k==7 ? 1.2:0),near ? 40:0.8)
        }
    }
    for size in [0.15,0.25]{
        var learner=ClosedCaseTapLearner()
        guard learner.feed(braced(size)) == [.tap(agreeing:1,total:1)],learner.pushes.count==1,(learner.pushes[0]*sideways).sum()>0 else{
            throw LessonError.message("A hard tap after a shift of \(size) g must count once, along the finger's push.")
        }
    }
    var detail="synthetic stillness, tap, quick taps, learning, turn, moving jolt, gaps, ordering and refractory at 50 and 200 Hz, with and without short gaps"
    if let fixtures {
        let segments=try loadClosedCaseTapFixtures(fixtures)
        var held=0,falseClicks:[String]=[]
        for segment in segments{
            if segment.name=="h1learning"{
                for batch in [1,5,64]{
                    var learner=ClosedCaseTapLearner(lowSampleRate:true),input=HeadphoneTapInput(),events:[ClosedCaseTapLearner.Event]=[]
                    for index in stride(from:0,to:segment.rows.count,by:batch){
                        events+=learner.feed(input.feed(Array(segment.rows[index..<min(index+batch,segment.rows.count)])))
                    }
                    let impact=SIMD3(1.23916,-0.82497,-1.34518),expected=impact/(impact*impact).sum().squareRoot()
                    guard let learned=direction(events),abs((learned*expected).sum())>0.95 else{
                        throw LessonError.message("Recorded 25 Hz taps must teach a direction matching the clear impact, independent of batching.")
                    }
                }
                guard direction(learn(segment.rows))==nil else{
                    throw LessonError.message("The H1 regression must exercise the low-rate learner separately from H2.")
                }
                continue
            }
            let events=replay(segment.rows,batch:5)
            guard balanced(events) else{throw LessonError.message("\(segment.name): a held pointer was never released.")}
            // The tap segments are with the lid open, where a tap pushes another way. The app only clicks with it closed.
            if segment.name.hasPrefix("tap"){continue}
            if segment.name=="held"{held=taps(events).count}
            // Clicks are off until the case is pointing, so a lid closing can't click.
            else if segment.name != "lidclose",!taps(events).isEmpty{falseClicks.append(segment.name)}
        }
        guard falseClicks.isEmpty else{throw LessonError.message("Recorded handling clicked: \(falseClicks.joined(separator:", ")).")}
        // 15 soft taps on the closed case in the hand; the last is followed at once by movement and may be missed.
        guard (14...15).contains(held) else{throw LessonError.message("\(held) of 15 recorded hand-held taps clicked; at least 14 must.")}
        try runHeadphoneTapChecks(fixtures:fixtures.deletingLastPathComponent().appendingPathComponent("HeadphoneTapFixtures.csv"))
        detail+="; \(held) of 15 hand-held recorded taps clicked, \(segments.filter{!$0.name.hasPrefix("tap") && $0.name != "held" && $0.name != "h1learning"}.count) recorded handling and pointing segments never clicked; recorded H1 25 Hz learning"
    }
    print("PASS: closed-case tap detection, \(detail)")
}
