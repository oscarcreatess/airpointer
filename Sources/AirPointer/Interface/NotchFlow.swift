import AppKit
import AVFoundation
import QuartzCore

// The shortcut's modifier keys pressed together, with no other modifier, from any app. Keys still held never press it again.
struct NotchChord {
    private let required:NSEvent.ModifierFlags
    private var held=false
    init(_ required:NSEvent.ModifierFlags=[.function,.control]){self.required=required}
    mutating func update(_ flags:NSEvent.ModifierFlags)->Bool {
        let both=flags.contains(required)
        defer{held=both}
        return both && !held && flags.intersection(PointerShortcut.relevant).subtracting(required).isEmpty
    }
}

// Focus changes can drop a modifier event, so a timer reads the keys as well. Both read the same current
// state, so a late event never presses twice, and letting go always re-arms the chord.
final class NotchShortcut {
    private var chord=NotchChord(),monitors:[Any]=[],timer:Timer?,lastPress = -Double.infinity
    // The modifier keys to watch; nil while the shortcut uses a key, or is being recorded.
    var watched:NSEvent.ModifierFlags?=[.function,.control]{didSet{if let watched{chord=NotchChord(watched);_=chord.update(NSEvent.modifierFlags)}}}
    private let pressed:()->Void
    init(pressed:@escaping()->Void) {
        self.pressed=pressed
        // Keys already held at launch are not a press.
        _=chord.update(NSEvent.modifierFlags)
        if let local=NSEvent.addLocalMonitorForEvents(matching:.flagsChanged,handler:{[weak self] event in self?.sample();return event}){monitors.append(local)}
        if let global=NSEvent.addGlobalMonitorForEvents(matching:.flagsChanged,handler:{[weak self] _ in self?.sample()}){monitors.append(global)}
        let next=Timer(timeInterval:0.02,repeats:true){[weak self] _ in self?.sample()}
        next.tolerance=0.005;RunLoop.main.add(next,forMode:.common);timer=next
    }
    deinit{timer?.invalidate();for monitor in monitors{NSEvent.removeMonitor(monitor)}}
    // A second press within a second is a slip, not a cancel.
    private func sample() {
        guard watched != nil,chord.update(NSEvent.modifierFlags) else{return}
        press()
    }
    func press() {
        let now=ProcessInfo.processInfo.systemUptime
        if now-lastPress>=1{lastPress=now;pressed()}
    }
}

// One step in the notch: the case art, a title, a line under it, and how far connecting has got
// (open, close, turn), or nil to hide the progress.
struct NotchContent:Equatable {
    var step:CaseStep,title:String,detail:String,progress:Int?,live=false
    static func connecting(_ stage:ClosedCaseStage,preparing:Bool)->NotchContent? {
        switch stage {
        case .openLid:return NotchContent(step:.opening,title:"Open the lid",detail:"Keep both AirPods inside.",progress:0)
        // Finding the paired AirPods comes before the lid, and takes a moment at most.
        case .connecting where preparing:return NotchContent(step:.opening,title:"Open the lid",detail:"Keep both AirPods inside.",progress:0)
        case .connecting:return NotchContent(step:.open,title:"Looking for your AirPods…",detail:"Keep the lid open for a moment.",progress:0)
        case .closeLid:return NotchContent(step:.close,title:"Close the lid",detail:"AirPointer goes on by itself.",progress:1)
        case .holding:return NotchContent(step:.closed,title:"Set it down",detail:"On a flat surface, for a moment.",progress:2)
        case .settling:return NotchContent(step:.turn,title:"Turn it upright",detail:"A quarter turn clockwise.",progress:2)
        case .calibrating:return NotchContent(step:.point,title:"Aim at the screen",detail:"Pointing starts from where you hold it.",progress:2)
        default:return nil
        }
    }
    static let lost=NotchContent(step:.opening,title:"Lost your AirPods",detail:"Open the lid to reconnect, then close it to keep pointing.",progress:0)
    static let pointing=NotchContent(step:.point,title:"Pointing",detail:"Tap the front of the case to click.",progress:3,live:true)
    static var paused:NotchContent{NotchContent(step:.point,title:"Paused",detail:"Press \(PointerShortcut.current.label) to point again.",progress:nil)}
    // Restoring the AirPods link after a cancel can take up to 30 s, and nothing can start until it's done.
    static let finishing=NotchContent(step:.closed,title:"Disconnecting…",detail:"Just a moment. You can connect again after this.",progress:nil)
    static func ended(_ reason:String)->NotchContent{NotchContent(step:.closed,title:"Not connected",detail:reason,progress:nil)}
}

// The sound of the notch dropping down. It plays on the Mac's own output, never the AirPods.
final class NotchShimmerSound {
    static let shared=NotchShimmerSound()
    private let player=Bundle.main.url(forResource:"NotchShimmer",withExtension:"wav").flatMap{try? AVAudioPlayer(contentsOf:$0)}
    var loaded:Bool{player != nil}
    private init(){player?.prepareToPlay()}
    func play(){guard let player else{return};player.currentTime=0;player.play()}
}

// The panel never takes focus or clicks from the app being presented.
private final class NotchWindow:NSPanel {
    override var canBecomeKey:Bool{false}
    override var canBecomeMain:Bool{false}
}

// Connecting drops out of the notch: a black shape grown from the camera housing, the case art in the
// middle and the step under it. On a Mac without a notch it hangs from the middle of the menu bar.
final class NotchFlow {
    private let panel=NotchWindow(contentRect:.zero,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
    let surface=NotchSurface()
    private(set) var content:NotchContent?
    // The session stage last shown, so the timed steps (pointing, paused, ended) act only on a change.
    var stage:ClosedCaseStage?
    private(set) var screen:NSScreen?
    private var closedFrame=NSRect.zero,openFrame=NSRect.zero,expanded=false,transition=0
    private var motion:Timer?,dismiss:Timer?,screens:NSObjectProtocol?
    static let body:CGFloat=200
    init() {
        panel.title="AirPointer · Notch";panel.isOpaque=false;panel.backgroundColor = .clear;panel.hasShadow=false
        panel.level=NSWindow.Level(rawValue:NSWindow.Level.statusBar.rawValue+1)
        panel.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary,.stationary]
        panel.hidesOnDeactivate=false;panel.isMovable=false;panel.ignoresMouseEvents=true;panel.isReleasedWhenClosed=false
        let host=NSView();host.addSubview(surface);surface.autoresizingMask=[.width,.height];panel.contentView=host
        screens=NotificationCenter.default.addObserver(forName:NSApplication.didChangeScreenParametersNotification,object:nil,queue:.main){[weak self] _ in
            guard let self,self.expanded,self.motion==nil else{return}
            self.measure();self.panel.setFrame(self.openFrame,display:true)
        }
    }
    deinit{if let screens{NotificationCenter.default.removeObserver(screens)}}
    // Shows a step, opening the notch if it was closed. A timed step closes it again after `seconds`.
    func show(_ next:NotchContent,for seconds:Double?=nil) {
        dismiss?.invalidate();dismiss=nil
        if let seconds{dismiss=Timer.scheduledTimer(withTimeInterval:seconds,repeats:false){[weak self] _ in self?.collapse()}}
        guard next != content || !expanded else{return}
        content=next;surface.show(next,fade:expanded && motion==nil)
        if !expanded{expanded=true;NotchShimmerSound.shared.play();open()}
    }
    func collapse() {
        dismiss?.invalidate();dismiss=nil
        guard expanded else{return}
        expanded=false;content=nil;close()
    }
    // Prefers the physical notch, even when another display is the main one.
    private func measure() {
        guard let screen=NSScreen.screens.first(where:{$0.safeAreaInsets.top>0}) ?? NSScreen.main ?? NSScreen.screens.first else{return}
        self.screen=screen
        let inset=screen.safeAreaInsets.top>0 ? screen.safeAreaInsets.top:NSStatusBar.system.thickness
        var neck:CGFloat=180,center=screen.frame.midX
        if let left=screen.auxiliaryTopLeftArea,let right=screen.auxiliaryTopRightArea{neck=right.minX-left.maxX;center=(left.maxX+right.minX)/2}
        let width=min(max(neck+150,360),screen.frame.width-40)
        closedFrame=NSRect(x:center-neck/2,y:screen.frame.maxY-inset,width:neck,height:inset)
        openFrame=NSRect(x:center-width/2,y:screen.frame.maxY-inset-Self.body,width:width,height:Self.body+inset)
        surface.neck=neck;surface.inset=inset;surface.body=Self.body
    }
    private var still:Bool{NSWorkspace.shared.accessibilityDisplayShouldReduceMotion}
    private func open() {
        measure();transition+=1;motion?.invalidate();motion=nil
        let token=transition,target=openFrame
        surface.hideContents()
        if !panel.isVisible{panel.setFrame(closedFrame,display:true);panel.orderFrontRegardless()}
        if still{panel.setFrame(target,display:true);surface.reveal(animated:false);return}
        // Quick, with a slight rebound, sampled at 60 Hz. Smoothstep gives each turn zero speed, so it never
        // jerks. The step fades in as the shape lands.
        let frames=[panel.frame,NSRect(x:target.minX-3,y:target.minY-5,width:target.width+6,height:target.height+5),
                    NSRect(x:target.minX+1,y:target.minY+1,width:target.width-2,height:target.height-1),target]
        let times=[0.0,0.16,0.23,0.29],started=CACurrentMediaTime()
        var revealed=false
        let timer=Timer(timeInterval:1.0/60,repeats:true){[weak self] timer in
            guard let self,self.transition==token else{timer.invalidate();return}
            let elapsed=CACurrentMediaTime()-started
            if !revealed && elapsed>=times[1]{revealed=true;self.surface.reveal(animated:true)}
            if elapsed>=times[3]{timer.invalidate();self.motion=nil;self.panel.setFrame(target,display:true);return}
            let index=elapsed<times[1] ? 0:elapsed<times[2] ? 1:2,t=(elapsed-times[index])/(times[index+1]-times[index])
            let k=CGFloat(t*t*(3-2*t)),a=frames[index],b=frames[index+1]
            self.panel.setFrame(NSRect(x:a.minX+(b.minX-a.minX)*k,y:a.minY+(b.minY-a.minY)*k,width:a.width+(b.width-a.width)*k,height:a.height+(b.height-a.height)*k),display:true)
        }
        motion=timer;RunLoop.main.add(timer,forMode:.common)
    }
    private func close() {
        transition+=1;motion?.invalidate();motion=nil
        let token=transition
        surface.hideContents()
        guard panel.isVisible else{return}
        if still{panel.orderOut(nil);return}
        // The step goes first, the empty shape holds a beat, then it tucks back into the notch.
        DispatchQueue.main.asyncAfter(deadline:.now()+0.08){[weak self] in
            guard let self,self.transition==token else{return}
            NSAnimationContext.runAnimationGroup({context in
                context.duration=0.18;context.timingFunction=CAMediaTimingFunction(name:.easeIn)
                self.panel.animator().setFrame(self.closedFrame,display:true)
            }){[weak self] in guard let self,self.transition==token else{return};self.panel.orderOut(nil)}
        }
    }
}

// The black shape and what it holds. Only the part below the menu bar is the body; the neck above it
// sits over the camera housing, so it blends into the physical notch.
final class NotchSurface:NSView {
    var neck:CGFloat=180{didSet{needsLayout=true}}
    var inset:CGFloat=32{didSet{needsLayout=true}}
    var body:CGFloat=NotchFlow.body{didSet{needsLayout=true}}
    let art=CaseStepView()
    private let contents=NSView(),title=rkLabel("",15,.semibold,.white),detail=rkWrap("",12,NSColor(white:1,alpha:0.62))
    private let progress=NotchProgress(),dot=NotchLiveDot()
    private let outline=CAShapeLayer()
    init() {
        super.init(frame:.zero);wantsLayer=true;layer?.mask=outline
        art.translatesAutoresizingMaskIntoConstraints=true;art.fill=0.7
        title.alignment = .center;detail.alignment = .center
        detail.maximumNumberOfLines=4;detail.cell?.truncatesLastVisibleLine=true
        for view in [art,title,detail,progress,dot] as [NSView]{contents.addSubview(view)}
        addSubview(contents);contents.alphaValue=0
        setAccessibilityElement(true);setAccessibilityRole(.group);setAccessibilityLabel("AirPointer")
    }
    required init?(coder:NSCoder){fatalError("init(coder:) is not used")}
    func show(_ content:NotchContent,fade:Bool) {
        art.step=content.step;rkSetText(title,content.title);rkSetText(detail,content.detail)
        progress.filled=content.progress;progress.isHidden=content.progress==nil;dot.isHidden = !content.live
        let spoken=content.title+". "+content.detail
        // The notch never takes focus, so VoiceOver only hears a new step if it's announced.
        if accessibilityValue() as? String != spoken{
            NSAccessibility.post(element:NSApp as Any,notification:.announcementRequested,userInfo:[.announcement:spoken,.priority:NSAccessibilityPriorityLevel.high.rawValue])
        }
        setAccessibilityValue(spoken)
        needsLayout=true
        if fade{contents.alphaValue=0.15;NSAnimationContext.runAnimationGroup{context in context.duration=0.18;contents.animator().alphaValue=1}}
    }
    // The shape finishes growing before anything appears in it.
    func hideContents(){contents.alphaValue=0}
    func reveal(animated:Bool) {
        guard animated else{contents.alphaValue=1;return}
        NSAnimationContext.runAnimationGroup{context in context.duration=0.12;contents.animator().alphaValue=1}
    }
    private var visibleBody:CGFloat{max(0,bounds.height-inset)}
    override func layout() {
        super.layout()
        CATransaction.begin();CATransaction.setDisableActions(true);outline.frame=bounds;outline.path=silhouette;CATransaction.commit()
        let w=bounds.width,side:CGFloat=100,textWidth=max(10,w-48)
        contents.frame=NSRect(x:0,y:visibleBody-body,width:w,height:body)
        // Art, progress, title and line as one centered column, however many lines the line takes.
        let lines=detail.cell?.cellSize(forBounds:NSRect(x:0,y:0,width:textWidth,height:200)).height ?? 16
        let bars:CGFloat=progress.isHidden ? 0:4+12,detailHeight=min(body-side-6-bars-20-3,ceil(lines))
        let column=side+6+bars+20+3+detailHeight
        var y=(body+column)/2
        art.frame=NSRect(x:(w-side)/2,y:y-side,width:side,height:side);y-=side+6
        if !progress.isHidden{progress.frame=NSRect(x:(w-NotchProgress.width)/2,y:y-4,width:NotchProgress.width,height:4);y-=bars}
        // The live dot leads the title, and the pair stays centered.
        let titleWidth=ceil(title.attributedStringValue.size().width),lead:CGFloat=dot.isHidden ? 0:15
        title.frame=NSRect(x:24+lead/2,y:y-20,width:textWidth,height:20);y-=23
        dot.frame=NSRect(x:(w-titleWidth-lead)/2,y:title.frame.midY-4.5,width:9,height:9)
        detail.frame=NSRect(x:24,y:y-detailHeight,width:textWidth,height:detailHeight)
    }
    // One outline: a neck the width of the camera housing, concave shoulders where it meets the
    // menu bar's bottom edge, and the rounded body below.
    private var silhouette:CGPath {
        let w=bounds.width,h=bounds.height,b=visibleBody,neck=min(self.neck,w)
        let left=(w-neck)/2,right=(w+neck)/2,join=min(7,left,max(0,h-b)),top=min(20,b/2),radius=min(22,b/2)
        let p=CGMutablePath()
        p.move(to:CGPoint(x:left,y:h));p.addLine(to:CGPoint(x:right,y:h));p.addLine(to:CGPoint(x:right,y:b+join))
        p.addCurve(to:CGPoint(x:right+join,y:b),control1:CGPoint(x:right,y:b+join*0.45),control2:CGPoint(x:right+join*0.45,y:b))
        p.addLine(to:CGPoint(x:w-top,y:b))
        p.addCurve(to:CGPoint(x:w,y:b-top),control1:CGPoint(x:w-top*0.45,y:b),control2:CGPoint(x:w,y:b-top*0.45))
        p.addLine(to:CGPoint(x:w,y:radius))
        p.addCurve(to:CGPoint(x:w-radius,y:0),control1:CGPoint(x:w,y:radius*0.45),control2:CGPoint(x:w-radius*0.45,y:0))
        p.addLine(to:CGPoint(x:radius,y:0))
        p.addCurve(to:CGPoint(x:0,y:radius),control1:CGPoint(x:radius*0.45,y:0),control2:CGPoint(x:0,y:radius*0.45))
        p.addLine(to:CGPoint(x:0,y:b-top))
        p.addCurve(to:CGPoint(x:top,y:b),control1:CGPoint(x:0,y:b-top*0.45),control2:CGPoint(x:top*0.45,y:b))
        p.addLine(to:CGPoint(x:left-join,y:b))
        p.addCurve(to:CGPoint(x:left,y:b+join),control1:CGPoint(x:left-join*0.45,y:b),control2:CGPoint(x:left,y:b+join*0.45))
        p.closeSubpath()
        return p
    }
    override func draw(_ dirtyRect:NSRect) {
        guard let context=NSGraphicsContext.current?.cgContext else{return}
        // Pure black at the notch whatever the appearance, lifting a little toward the bottom edge.
        let colors=[CGColor(srgbRed:0,green:0,blue:0,alpha:1),CGColor(srgbRed:0,green:0,blue:0,alpha:1),CGColor(srgbRed:0.11,green:0.11,blue:0.11,alpha:1)] as CFArray
        guard let fade=CGGradient(colorsSpace:CGColorSpace(name:CGColorSpace.sRGB),colors:colors,locations:[0,0.35,1]) else{return}
        context.saveGState();context.addPath(silhouette);context.clip()
        context.drawLinearGradient(fade,start:CGPoint(x:0,y:visibleBody),end:CGPoint(x:0,y:0),options:[.drawsBeforeStartLocation,.drawsAfterEndLocation])
        context.restoreGState()
    }
}

// Open, close, turn: three short bars, filled as each step is done.
private final class NotchProgress:NSView {
    static let width:CGFloat=3*16+2*4
    var filled:Int?{didSet{needsDisplay=true}}
    override func draw(_ dirtyRect:NSRect) {
        for index in 0..<3 {
            NSColor(white:1,alpha:index<(filled ?? 0) ? 0.9:index==(filled ?? 0) ? 0.45:0.18).setFill()
            NSBezierPath(roundedRect:NSRect(x:CGFloat(index)*20,y:0,width:16,height:bounds.height),xRadius:2,yRadius:2).fill()
        }
    }
}

// Laser red, only while the pointer is live.
private final class NotchLiveDot:NSView {
    override func draw(_ dirtyRect:NSRect) {
        HomePalette.laser.withAlphaComponent(0.3).setFill();NSBezierPath(ovalIn:bounds).fill()
        HomePalette.laser.setFill();NSBezierPath(ovalIn:bounds.insetBy(dx:1.5,dy:1.5)).fill()
    }
}

extension App {
    func installNotch() {
        notch=NotchFlow();_=NotchShimmerSound.shared
        PointerShortcutKeys.shared.install{[weak self] in self?.notchPressed()}
    }
    // The shortcut connects from the notch when nothing is connected, cancels while connecting, and pauses or
    // resumes once the case is pointing.
    func notchPressed() {
        if let session=closedCaseSession,session.isActive {
            let fromWindow = !session.usesNotch
            switch session.stage {
            case .off:notch?.show(.finishing,for:fromWindow ? 1.6:nil)
            case .pointing:pause();if fromWindow{notch?.show(.paused,for:1.6)}
            case .ready:session.resumeCursor();if fromWindow && session.stage == .pointing{notch?.show(.pointing,for:1.6)}
            default:disconnectClosedCase();if fromWindow{notch?.collapse()}
            }
            refreshHome();return
        }
        if showConnectEffectsFirst(){return}
        // Missing Accessibility, or a session already running, goes through the window.
        guard AXIsProcessTrusted(),!closedCaseOwnsInput else{showHome();homeControlAction();return}
        home?.setNotice(nil)
        startClosedPointerSession(fromNotch:true)
    }
    // A session started from the notch walks through its steps there and goes straight to pointing.
    func refreshNotch() {
        guard let notch,let session=closedCaseSession,session.usesNotch else{return}
        let stage=session.stage
        let was=notch.stage;notch.stage=stage
        switch stage {
        case .off:
            if session.isActive{notch.show(.finishing)}
            else if was != .off || notch.content == .finishing{if let reason=session.endReason{notch.show(.ended(reason),for:max(4,Double(reason.count)/15))}else{notch.collapse()}}
        case .pointing:if was != .pointing{notch.show(.pointing,for:1.8)}
        case .ready:if was == .pointing{notch.show(.paused,for:1.6)}else{notch.collapse()}
        // The dots take over: a first calibration, or the case held another way than the saved edges.
        case .calibrating where !session.centersItself:notch.collapse()
        case .closeLid where session.usesHeadphoneMotion:notch.show(NotchContent(step:.close,title:"Close the lid",detail:"Then choose Lid Closed in AirPointer’s menu.",progress:1))
        case .openLid where session.opensLidFirst:notch.show(.lost)
        case .connecting where session.opensLidFirst && session.preparingConnection:notch.show(.lost)
        default:if let content=NotchContent.connecting(stage,preparing:session.preparingConnection){notch.show(content)}
        }
    }
}
