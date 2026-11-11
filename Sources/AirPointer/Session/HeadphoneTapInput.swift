import Foundation

enum HeadphoneTapTuning {
    static let spikeGap=0.09,peakWithin=0.12,impactFrom=0.06,minimumAlignment=0.85,fastRefractory=0.4
    static let learningJolt=0.35,jolt=0.35,firmAlignment=0.9,peakAlignment=0.9,learningAgreement=0.8,windUpWithin=0.16
}

struct HeadphoneTapInput {
    private var acceleration:[Double]?,rotation:[Double]?
    private var lastFrame = -Double.infinity

    mutating func feed(_ rows:[[Double]])->[[Double]] {
        var paired:[[Double]]=[]
        for row in rows where row.count==7 && row.allSatisfy(\.isFinite) && row[2]>0 {
            guard row[2]>lastFrame else{continue}
            if row[1]==11 {
                if let previous=acceleration,row[2]<previous[2]{continue}
                acceleration=row
            }else if row[1]==12 {
                if let previous=rotation,row[2]<previous[2]{continue}
                rotation=row
            }else{continue}
            guard var a=acceleration,var w=rotation else{continue}
            if w[2]<a[2]{rotation=nil;continue}
            if w[2]>a[2]+1{acceleration=nil;continue}
            lastFrame=a[2]
            w[2]=lastFrame;a[2]=lastFrame+1
            paired.append(w);paired.append(a)
            acceleration=nil;rotation=nil
        }
        return paired
    }
}

// Save H1 calibration results.
enum HeadphoneTapCalibration {
    static let key="headphoneTapDirection"
    static func direction(h2:[Double]?,headphone:Bool,defaults:UserDefaults = .standard)->SIMD3<Double>{
        let values=headphone ? defaults.array(forKey:key) as? [Double]:h2
        return values.flatMap{$0.count==3 ? SIMD3($0[0],$0[1],$0[2]):nil} ?? ClosedCaseTapDetector.tapDirection
    }
    static func save(_ direction:SIMD3<Double>,defaults:UserDefaults = .standard){
        defaults.set([direction.x,direction.y,direction.z],forKey:key)
    }
}

func runHeadphoneTapChecks(fixtures:URL) throws {
    let suite="local.airpointer.headphone-tap-check-"+UUID().uuidString
    guard let defaults=UserDefaults(suiteName:suite) else{throw LessonError.message("Cannot create isolated tap preferences.")}
    defer{defaults.removePersistentDomain(forName:suite)}
    let h2:[Double]=[0.6,0,-0.8],h1=SIMD3(0,1.0,0)
    defaults.set(h2,forKey:"tapDirection")
    guard HeadphoneTapCalibration.direction(h2:h2,headphone:true,defaults:defaults)==ClosedCaseTapDetector.tapDirection else{
        throw LessonError.message("H1 must not reuse a direction saved for H2.")
    }
    HeadphoneTapCalibration.save(h1,defaults:defaults)
    guard HeadphoneTapCalibration.direction(h2:h2,headphone:true,defaults:defaults)==h1,
          HeadphoneTapCalibration.direction(h2:h2,headphone:false,defaults:defaults)==SIMD3(0.6,0,-0.8),
          defaults.array(forKey:"tapDirection") as? [Double]==h2 else{
        throw LessonError.message("Teaching H1 must leave H2 calibration unchanged.")
    }
    var training:[[Double]]=[],test:[[Double]]=[]
    for line in try String(contentsOf:fixtures,encoding:.utf8).split(separator:"\n") where !line.hasPrefix("#"){
        let fields=line.split(separator:",")
        guard fields.count==7 else{throw LessonError.message("Invalid headphone tap fixture.")}
        let values=fields.dropFirst().compactMap{Double($0)}
        guard values.count==6,values.allSatisfy(\.isFinite) else{throw LessonError.message("Invalid headphone motion values.")}
        let row=[0,values[0],values[1]+1e9,values[2],values[3],values[4],values[5]]
        if fields[0]=="training"{training.append(row)}else if fields[0]=="test"{test.append(row)}else{throw LessonError.message("Unknown headphone segment.")}
    }
    var reference:[Double]?,score:TapTestRun?
    for batch in [1,5,64]{
        var input=HeadphoneTapInput(),learner=ClosedCaseTapLearner(lowSampleRate:true),direction:SIMD3<Double>?
        for i in stride(from:0,to:training.count,by:batch){
            for event in learner.feed(input.feed(Array(training[i..<min(i+batch,training.count)]))){
                if case .finished(let learned)=event{direction=learned}
            }
        }
        // Learn only from calibration data collected before the test; test taps must not influence the direction.
        guard let direction,abs((direction*SIMD3(-0.72645,0.01719,0.687)).sum())>0.99 else{
            throw LessonError.message("Recorded H1 training must retain the impact axis instead of the sideways rebound.")
        }
        input=HeadphoneTapInput()
        var detector=ClosedCaseTapDetector(),run=TapTestRun(start:0)
        detector.lowSampleRate=true;detector.direction=direction
        for i in stride(from:0,to:test.count,by:batch){
            for row in input.feed(Array(test[i..<min(i+batch,test.count)])){
                for event in detector.feed([row]){if case .tap=event{run.click(at:row[3])}}
            }
        }
        guard run.hits.count>=7,run.moveHits.count>=4,run.quickHits>=1,
              run.falseClicks==0,run.extraClicks<=2,run.moveExtra<=5 else{
            throw LessonError.message("Recorded H1 tap detection regressed: \(run.record)")
        }
        if let reference,run.clicks != reference{throw LessonError.message("H1 clicks must not depend on pipe batching.")}
        reference=run.clicks;score=run
    }
    try runAlignedHeadphoneTapChecks(directory:fixtures.deletingLastPathComponent())
    if let score{print("PASS: H1 same-frame replay, \(score.hits.count)/10 normal cues, \(score.quickHits)/8 requested quick taps, \(score.moveHits.count)/5 move cues, \(score.extraClicks) extra, \(score.moveExtra) move extra, \(score.falseClicks) false clicks in 30 s pointing; batches 1/5/64; isolated H2 calibration")}
}

func runAlignedHeadphoneTapChecks(directory:URL) throws {
    struct Trial:Decodable{
        let direction:[Double],hits:Int,quickClicks:Int,extraClicks:Int,falseClicks:Int,moveHits:Int,moveExtra:Int
        let continuousMovement:Bool
    }
    let trial=try JSONDecoder().decode(Trial.self,from:Data(contentsOf:directory.appendingPathComponent("HeadphoneTapAligned.json")))
    guard trial.direction.count==3,trial.direction.allSatisfy(\.isFinite),trial.continuousMovement else{
        throw LessonError.message("Invalid aligned headphone trial metadata.")
    }
    let lines=try String(contentsOf:directory.appendingPathComponent("HeadphoneTapAligned.csv"),encoding:.utf8).split(separator:"\n").filter{!$0.hasPrefix("#")}
    let rows=lines.map{$0.split(separator:",").compactMap{Double($0)}}
    guard rows.allSatisfy({$0.count==7 && $0.allSatisfy(\.isFinite)}) else{throw LessonError.message("Invalid aligned headphone trial motion.")}
    var reference:[Double]?
    for batch in [1,5,64]{
        var input=HeadphoneTapInput(),detector=ClosedCaseTapDetector(),run=TapTestRun(start:0)
        detector.direction=SIMD3(trial.direction[0],trial.direction[1],trial.direction[2]);detector.lowSampleRate=true
        for i in stride(from:0,to:rows.count,by:batch){
            for row in input.feed(Array(rows[i..<min(i+batch,rows.count)])){
                for event in detector.feed([row]){if case .tap=event,row[3]>=0{run.click(at:row[3])}}
            }
        }
        guard run.hits.count==trial.hits,run.record["quickClicks"] as? Int==trial.quickClicks,
              run.extraClicks==trial.extraClicks,run.falseClicks==trial.falseClicks,
              run.moveHits.count==trial.moveHits,run.moveExtra==trial.moveExtra else{
            throw LessonError.message("Aligned H1 trial changed: \(run.record)")
        }
        if let reference,run.clicks != reference{throw LessonError.message("Aligned H1 trial must survive split pipe reports.")}
        reference=run.clicks
    }
    print("PASS: aligned H1 trial, \(trial.hits)/10 normal cues, \(trial.quickClicks) quick clicks, \(trial.extraClicks) extra and \(trial.falseClicks) false in 30 s; continuous-motion limitation retained; batches 1/5/64")
}
