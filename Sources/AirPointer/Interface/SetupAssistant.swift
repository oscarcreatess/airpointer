import AppKit

// First run: from "just installed" to "pointing" in five steps. Every view is
// built once; update() arrives ~12×/s and only diffs what is on screen.

// How far the closed case is through connecting: lid open, lid closed, upright.
enum SetupLink:Equatable {case idle,openLid,connecting,closeLid,turnUpright,holdStill,connected}

// How far setup is through learning this person's tap.
struct SetupTaps:Equatable {
    var heard=0
    var mixed=false,soft=false,listening=false,learned=false,failed=false
}

struct SetupState:Equatable {
    var link=SetupLink.idle
    var problem:String?=nil          // why the last connection ended, in the user's words
    var accessibilityTrusted=false
    var plane=PointingPlane.upright
    var calibrating=false
    var calibrated=false
    var holdProgress=0.0
    var taps=SetupTaps()
    var connected:Bool{link == .connected}
}

final class SetupAssistant:NSObject,NSWindowDelegate {
    let window:NSWindow
    var onConnect,onChooseAirPods,onLidClosed,onRequestAccessibility,onCalibrate,onLearnTap,onStopLearningTap,onFinish,onClose:(()->Void)?
    var onChoosePlane:((PointingPlane)->Void)?
    private(set) var step=0

    private enum Action{case none,connect,chooseAirPods,lidClosed,openAccessibility,calibrate,learnTap,reconnect,next,finish}
    private static let copy=[
        ("Let AirPointer move the pointer","Press Allow to open the Accessibility list, then drag AirPointer into it so it can move the pointer and click."),
        ("Choose how to point","Hold the closed case upright in the air, swivel it flat on your desk, or rock it flat like a joystick."),
        ("Connect your AirPods","Hold the closed case with both AirPods inside. Connect, then open the lid."),
        ("Show it where your screen is","Point at three dots — center, right edge, top edge. Hold still on each and it captures automatically. Keep the grip you’ll use."),
        ("Teach it your tap","Tap the case three times, with a short pause between taps. Keep it the way you’ll point with it."),
    ]
    private static let connectEffects="Your Mac can’t use your AirPods for audio while connected, so don’t connect during a call. Ending a session uses up diagnostic data on the case and changes some AirPods settings. These changes may last."
    private var state=SetupState()
    private var everConnected=false
    private var styleConfirmed=false
    private var helpDue=false
    private var helpTimer:Timer?
    private var primaryAction=Action.none
    private var secondaryAction=Action.none
    private var waiting:Timer?
    // Long enough to see a step's check mark, and to read the step before the dots cover it.
    private static let beat=0.8,readFor=1.5

    private let steps=SetupSteps()
    private let page=NSView()
    private let titleLabel=rkTitle("",26,align:.center)
    private let bodyLabel=rkWrap("",14,align:.center)
    private let stage=RemoteSurface(HomePalette.stage,radius:16)
    private let caseArt=CaseStepView()
    private let access=SetupAccessArt()
    private let styleArt=SetupStyleArt()
    private let targets=SetupTargetArt()
    private let tapArt=SetupTapArt()
    private let chip=StatusChip()
    private let check=SetupCheck()
    private let note=rkWrap("",13,align:.center)
    private let footer=rkHStack([],spacing:6),footerKey=KeyCap(PointerShortcut.current.label)
    private let back=RemoteButton("Back",style:.tertiary,height:36)
    private let secondary=RemoteButton("",style:.secondary)
    private let primary=RemoteButton("",style:.primary,hint:"Return")

    override init() {
        window=SetupWindow(contentRect:NSRect(x:0,y:0,width:560,height:620),styleMask:[.titled,.closable,.miniaturizable,.fullSizeContentView],backing:.buffered,defer:false)
        super.init()
        window.title="Set Up AirPointer";window.titleVisibility = .hidden
        window.titlebarAppearsTransparent=true;window.titlebarSeparatorStyle = .none
        window.isReleasedWhenClosed=false;window.backgroundColor=HomePalette.canvas;window.delegate=self
        styleArt.onSelect={[weak self] plane in
            guard let self else{return}
            self.state.plane=plane;self.styleConfirmed=true;self.apply()
            self.onChoosePlane?(plane)
        }
        build();apply();window.center()
    }

    // Opens at the first incomplete step; an open window keeps its place.
    func show() {
        if !window.isVisible{go(to:firstIncomplete);window.center()}
        window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
    }

    func go(to step:Int) {
        let next=min(Self.copy.count-1,max(0,step)),changed=next != self.step
        waiting?.invalidate();waiting=nil
        if self.step==1,next>1{styleConfirmed=true}
        if self.step==4,next != 4{onStopLearningTap?()}
        self.step=next
        // The case is already in hand, so this step just starts listening.
        if next==4,state.connected,!state.taps.learned,!state.taps.listening{onLearnTap?()}
        apply()
        guard changed else{return}
        if let responder=window.firstResponder as? NSView,responder.isHiddenOrHasHiddenAncestor{window.makeFirstResponder(nil)}
        reveal(page);announce("Step \(next+1) of \(Self.copy.count). \(next==2 ? linkCopy(state.link).0:Self.copy[next].0)")
    }

    func update(_ next:SetupState) {
        guard next != state else{return}
        let old=state,wasConnected=everConnected
        state=next;apply()
        // A link that drops on the tap step takes the listening with it; one that comes back picks it up.
        if step==4,old.connected != next.connected{
            if !next.connected{onStopLearningTap?()}
            else if !next.taps.learned,!next.taps.failed,!next.taps.listening{onLearnTap?()}
        }
        guard window.isVisible else{return}
        if step==2,old.link != next.link {
            reveal(caseArt)
            if next.connected && !wasConnected{announce("Connected")}else if next.link != .idle{announce(linkCopy(next.link).0)}
        }
        if step==0,next.accessibilityTrusted,!old.accessibilityTrusted{announce("Allowed")}
        if step==3,next.calibrated,!next.calibrating,old.calibrating || !old.calibrated{announce("Calibrated")}
        if step==4,next.taps.learned,!old.taps.learned{announce("Learned")}
        else if step==4,next.taps.heard != old.taps.heard,next.taps.heard>0{announce("\(next.taps.heard) of \(ClosedCaseTapLearner.taps)")}
        if let following=Self.following(step,from:old,to:next){
            // Accessibility is granted over in System Settings, so setup comes back to the front.
            if step==0{window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)}
            after(Self.beat){[weak self] in self?.lead(to:following)}
        }
    }

    // Once a step is done it leads to the next by itself: with the case in hand, the mouse is out of reach.
    static func following(_ step:Int,from old:SetupState,to next:SetupState)->Int? {
        switch step {
        case 0:return next.accessibilityTrusted && !old.accessibilityTrusted ? 1:nil
        case 2:return next.connected && !old.connected ? (next.calibrated ? 4:3):nil
        case 3:return next.calibrated && !next.calibrating && (old.calibrating || !old.calibrated) ? 4:nil
        default:return nil
        }
    }
    private func lead(to next:Int) {
        go(to:next)
        guard next==3 else{return}
        after(Self.readFor){[weak self] in
            guard let self,self.step==3,self.state.connected,!self.state.calibrated,!self.state.calibrating else{return}
            self.onCalibrate?()
        }
    }
    private func after(_ delay:TimeInterval,_ action:@escaping()->Void) {
        waiting?.invalidate()
        waiting=Timer.scheduledTimer(withTimeInterval:delay,repeats:false){[weak self] _ in self?.waiting=nil;action()}
    }

    func windowWillClose(_ notification:Notification) {
        helpTimer?.invalidate();helpTimer=nil;helpDue=false
        waiting?.invalidate();waiting=nil
        onClose?()
    }

    private var firstIncomplete:Int {
        if !state.accessibilityTrusted{return 0}
        if !styleConfirmed && !everConnected{return 1}
        if !state.connected{return 2}
        return state.calibrated ? 4:3
    }

    private func build() {
        let root=NSView(),rule=RemoteRule()
        window.contentView=root
        for view in [steps,page,rule,back,secondary,primary] as [NSView]{view.translatesAutoresizingMaskIntoConstraints=false;root.addSubview(view)}
        let lead=rkLabel("AirPointer lives in the menu bar. Press",13,.regular,.secondaryLabelColor)
        let tail=rkLabel("to pause from any app.",13,.regular,.secondaryLabelColor)
        for view in [lead,footerKey,tail]{view.setAccessibilityElement(false);footer.addArrangedSubview(view)}
        footer.setAccessibilityElement(true);footer.setAccessibilityRole(.staticText)
        let status=rkVStack([chip,check,note,footer],spacing:12,align:.centerX)
        for view in [titleLabel,bodyLabel,stage,status] as [NSView]{view.translatesAutoresizingMaskIntoConstraints=false;page.addSubview(view)}
        stage.addSubview(caseArt)
        rkPin(access,in:stage);rkPin(styleArt,in:stage);rkPin(targets,in:stage);rkPin(tapArt,in:stage)
        caseArt.fill=0.86
        NSLayoutConstraint.activate([
            steps.topAnchor.constraint(equalTo:root.safeAreaLayoutGuide.topAnchor,constant:8),
            steps.centerXAnchor.constraint(equalTo:root.centerXAnchor),
            page.topAnchor.constraint(equalTo:steps.bottomAnchor),
            page.leadingAnchor.constraint(equalTo:root.leadingAnchor),
            page.trailingAnchor.constraint(equalTo:root.trailingAnchor),
            page.bottomAnchor.constraint(equalTo:rule.topAnchor),
            titleLabel.topAnchor.constraint(equalTo:page.topAnchor,constant:28),
            titleLabel.leadingAnchor.constraint(equalTo:page.leadingAnchor,constant:48),
            titleLabel.trailingAnchor.constraint(equalTo:page.trailingAnchor,constant:-48),
            bodyLabel.topAnchor.constraint(equalTo:titleLabel.bottomAnchor,constant:8),
            bodyLabel.leadingAnchor.constraint(equalTo:titleLabel.leadingAnchor),
            bodyLabel.trailingAnchor.constraint(equalTo:titleLabel.trailingAnchor),
            stage.topAnchor.constraint(equalTo:page.topAnchor,constant:136),
            stage.centerXAnchor.constraint(equalTo:page.centerXAnchor),
            stage.widthAnchor.constraint(equalToConstant:464),
            stage.heightAnchor.constraint(equalToConstant:220),
            caseArt.centerXAnchor.constraint(equalTo:stage.centerXAnchor),
            caseArt.centerYAnchor.constraint(equalTo:stage.centerYAnchor),
            caseArt.widthAnchor.constraint(equalTo:stage.widthAnchor),
            caseArt.heightAnchor.constraint(equalToConstant:204),
            status.topAnchor.constraint(equalTo:stage.bottomAnchor,constant:20),
            status.centerXAnchor.constraint(equalTo:page.centerXAnchor),
            note.widthAnchor.constraint(equalToConstant:464),
            rule.leadingAnchor.constraint(equalTo:root.leadingAnchor),
            rule.trailingAnchor.constraint(equalTo:root.trailingAnchor),
            rule.bottomAnchor.constraint(equalTo:root.bottomAnchor,constant:-64),
            back.leadingAnchor.constraint(equalTo:root.leadingAnchor,constant:16),
            back.centerYAnchor.constraint(equalTo:root.bottomAnchor,constant:-32),
            primary.trailingAnchor.constraint(equalTo:root.trailingAnchor,constant:-20),
            primary.centerYAnchor.constraint(equalTo:back.centerYAnchor),
            secondary.trailingAnchor.constraint(equalTo:primary.leadingAnchor,constant:-8),
            secondary.centerYAnchor.constraint(equalTo:back.centerYAnchor),
        ])
        back.target=self;back.action=#selector(backPressed)
        secondary.target=self;secondary.action=#selector(secondaryPressed)
        primary.target=self;primary.action=#selector(primaryPressed);primary.keyEquivalent="\r"
    }

    private func apply() {
        let s=state
        if s.connected{everConnected=true}
        // The help line waits for six quiet seconds of looking for the AirPods.
        if step != 2 || s.link != .connecting{helpTimer?.invalidate();helpTimer=nil;helpDue=false}
        else if helpTimer==nil,!helpDue{helpTimer=Timer.scheduledTimer(withTimeInterval:6,repeats:false){[weak self] _ in self?.helpTimer=nil;self?.helpDue=true;self?.apply()}}
        steps.set(current:step,done:[s.accessibilityTrusted,styleConfirmed || everConnected,everConnected,s.calibrated && !s.calibrating,s.taps.learned])
        var art:NSView=caseArt,chipText:String?,dot=false,checkText:String?,noteText:String?
        var main=("Continue",Action.next),alt:(String,Action)?
        var copy=Self.copy[step]
        caseArt.holdProgress=nil
        switch step {
        case 0:
            art=access;access.on=s.accessibilityTrusted
            if s.accessibilityTrusted{checkText="Allowed"}else{main=("Allow",.openAccessibility);alt=("Skip for now",.next)}
        case 1:
            art=styleArt;styleArt.selected=s.plane
            noteText=s.plane.subtitle
        case 2:
            // Closed to start, the lid opening, close it, turn it upright: each sub-step brings its own words and art.
            copy=linkCopy(s.link)
            switch s.link {
            case .idle:
                caseArt.step = .closed;main=("Connect",.connect);var problem=s.problem
                // Setup has no Settings to send them to, so the choice comes from here.
                if s.problem==ClosedCaseAirPods.Choice.several.failure{main=("Choose AirPods…",.chooseAirPods);problem="More than one pair of AirPods Pro is paired with this Mac. Choose which to use."}
                // A problem doesn't replace the effects: the person hasn't connected yet.
                noteText=[problem,Self.connectEffects].compactMap{$0}.joined(separator:"\n\n")
            case .openLid:caseArt.step = .opening;chipText="Waiting for the lid";main=("Connecting…",.none)
            case .connecting:
                caseArt.step = .open;chipText="Looking for your AirPods…";main=("Connecting…",.none)
                if helpDue{noteText="Not connecting? Lift one AirPod out for a moment and put it back."}
            case .closeLid:caseArt.step = .close;chipText="Connected";dot=true;main=("Lid Closed",.lidClosed)
            case .turnUpright:caseArt.step = .turn;chipText="Connected";dot=true;main=("Continue",.none)
            case .holdStill:caseArt.step = .closed;caseArt.holdProgress=CGFloat(s.holdProgress);chipText="Keep it still";main=("Continue",.none)
            case .connected:caseArt.step = s.plane == .upright ? .point:.closed;chipText="Connected";dot=true
            }
        case 3:
            if s.plane != .upright {
                copy=("Show it where your screen is","Move the flat case toward three dots — center, right edge, top edge. Hold still on each and it captures automatically.")
            }
            art=targets;targets.done=s.calibrated && !s.calibrating
            if s.calibrating{main=("Calibrating…",.none)}
            else if !s.connected{main=("Connect Again",.reconnect);noteText=s.problem ?? "The case disconnected. Connect again, then open the lid."}
            else if s.calibrated{checkText="Calibrated";alt=("Calibrate Again",.calibrate)}
            else{main=("Start Calibration",.calibrate)}
        case 4:
            art=tapArt;tapArt.heard=s.taps.heard
            if !s.connected{main=("Connect Again",.reconnect);noteText=s.problem ?? "The case disconnected. Connect again, then open the lid."}
            // Teaching the tap is the last step, so once it's done the primary finishes setup.
            else if s.taps.learned{checkText="Learned";main=("Finish",.finish);alt=("Tap Again",.learnTap)}
            else if s.taps.failed{main=("Try Again",.learnTap);alt=("Skip for Now",.finish);noteText="Those taps went different ways. Hold the case still and tap the same spot each time."}
            else{
                main=("Listening…",.none);alt=("Skip for Now",.finish)
                if s.taps.soft{noteText="Tap a little firmer."}else if s.taps.mixed{noteText="Tap the same spot each time."}
            }
        default:break
        }
        rkSetText(titleLabel,copy.0);rkSetText(bodyLabel,copy.1);show(bodyLabel,!copy.1.isEmpty)
        for view in [caseArt,access,styleArt,targets,tapArt] as [NSView]{show(view,view === art)}
        show(chip,chipText != nil);if let chipText{chip.set(chipText,dot:dot)}
        show(check,checkText != nil);if let checkText{check.text=checkText}
        show(note,noteText != nil);if let noteText{rkSetText(note,noteText)}
        show(footer,main.1 == .finish)
        if footerKey.text != PointerShortcut.current.label{footerKey.text=PointerShortcut.current.label}
        footer.setAccessibilityLabel("AirPointer lives in the menu bar. Press \(PointerShortcut.current.spoken) to pause from any app.")
        show(back,step>0);enable(back,!s.calibrating)
        // The Return chip only shows while Return can act.
        let live=main.1 != .none,hint=live ? "Return":nil
        primaryAction=main.1;retitle(primary,main.0);enable(primary,live);if primary.hint != hint{primary.hint=hint}
        secondaryAction=alt?.1 ?? .none;show(secondary,alt != nil);if let alt{retitle(secondary,alt.0)}
    }

    private func linkCopy(_ link:SetupLink)->(String,String) {
        switch link {
        case .idle:return Self.copy[2]
        case .openLid:return ("Open the lid","AirPointer connects when you open it. Keep both AirPods inside.")
        case .connecting:return (Self.copy[2].0,"Keep the lid open for a moment.")
        case .closeLid:return ("Close the lid","Keep both AirPods inside. AirPointer goes on by itself, or press Return.")
        case .turnUpright:return ("Turn it upright","Give the closed case a quarter turn clockwise.")
        case .holdStill:return ("Set it down","Put the closed case on a flat surface for a moment.")
        case .connected:return ("You’re connected",state.plane == .upright ? "Keep holding the case like this.":"Keep the closed case flat like this.")
        }
    }
    private func show(_ view:NSView,_ visible:Bool){if view.isHidden == visible{view.isHidden = !visible}}
    private func retitle(_ button:RemoteButton,_ title:String){if button.title != title{button.title=title}}
    private func enable(_ button:RemoteButton,_ enabled:Bool){if button.isEnabled != enabled{button.isEnabled=enabled;button.needsDisplay=true}}
    private func reveal(_ view:NSView) {
        guard window.isVisible,!NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else{return}
        view.alphaValue=0
        NSAnimationContext.runAnimationGroup{context in context.duration=0.18;view.animator().alphaValue=1}
    }
    private func announce(_ text:String) {
        guard window.isVisible else{return}
        NSAccessibility.post(element:window,notification:.announcementRequested,userInfo:[.announcement:text,.priority:NSAccessibilityPriorityLevel.high.rawValue])
    }

    @objc private func backPressed(){go(to:step-1)}
    @objc private func primaryPressed(){perform(primaryAction)}
    @objc private func secondaryPressed(){perform(secondaryAction)}
    private func perform(_ action:Action) {
        waiting?.invalidate();waiting=nil
        switch action {
        case .none:break
        case .connect:onConnect?();apply()
        case .chooseAirPods:onChooseAirPods?()
        case .lidClosed:onLidClosed?()
        case .reconnect:go(to:2)
        case .openAccessibility:onRequestAccessibility?()
        case .calibrate:onCalibrate?()
        case .learnTap:onLearnTap?()
        case .next:go(to:step+1)
        case .finish:
            // The pointer can't move without Accessibility, so setup isn't done until it's allowed.
            guard state.accessibilityTrusted else{go(to:0);return}
            onFinish?()
            if window.isVisible{window.close()}
        }
    }
}

// MARK: - Pieces

// Esc and ⌘W close the assistant from anywhere in it.
private final class SetupWindow:NSWindow {
    override func sendEvent(_ event:NSEvent) {
        if event.type == .keyDown {
            let modifiers=event.modifierFlags.intersection([.command,.control,.option,.shift])
            if (event.keyCode==53 && modifiers.isEmpty) || (modifiers == .command && event.charactersIgnoringModifiers == "w"){performClose(nil);return}
        }
        super.sendEvent(event)
    }
}

// The one "done" mark: a filled disc with a check, drawn in flipped coordinates.
private func setupCheckMark(_ rect:NSRect,disc:NSColor=HomePalette.ink,mark:NSColor=HomePalette.canvas) {
    disc.setFill();NSBezierPath(ovalIn:rect).fill()
    let unit=rect.width/20,path=NSBezierPath()
    path.move(to:NSPoint(x:rect.minX+6*unit,y:rect.minY+10.3*unit))
    path.line(to:NSPoint(x:rect.minX+8.6*unit,y:rect.minY+12.9*unit))
    path.line(to:NSPoint(x:rect.minX+14*unit,y:rect.minY+7.2*unit))
    path.lineWidth=1.7*unit;path.lineCapStyle = .round;path.lineJoinStyle = .round
    mark.setStroke();path.stroke()
}

private func setupCentered(_ text:String,at point:NSPoint,_ attributes:[NSAttributedString.Key:Any]) {
    let size=(text as NSString).size(withAttributes:attributes)
    (text as NSString).draw(at:NSPoint(x:point.x-size.width/2,y:point.y-size.height/2),withAttributes:attributes)
}

// Allow · Style · Connect · Calibrate · Tap, as done, current and next.
private final class SetupSteps:NSView {
    private let names=["Allow","Style","Connect","Calibrate","Tap"]
    private var current = -1
    private var done=[Bool](repeating:false,count:5)
    private let font=NSFont.systemFont(ofSize:13),bold=NSFont.systemFont(ofSize:13,weight:.semibold)
    private let link:CGFloat=16,gap:CGFloat=6
    override var isFlipped:Bool{true}
    init(){super.init(frame:.zero);translatesAutoresizingMaskIntoConstraints=false}
    required init?(coder:NSCoder){fatalError("init(coder:) is not used")}
    func set(current:Int,done:[Bool]) {
        guard current != self.current || done != self.done else{return}
        self.current=current;self.done=done;needsDisplay=true
        let finished=names.indices.filter{done[$0] && $0 != current}.map{names[$0]}
        setAccessibilityLabel("Step \(current+1) of \(names.count), \(names[current])"+(finished.isEmpty ? "":". Done: "+finished.joined(separator:", ")))
    }
    override func isAccessibilityElement()->Bool{true}
    override func accessibilityRole()->NSAccessibility.Role?{.staticText}
    // Widths are reserved at the semibold weight so the row never shifts between steps.
    private func width(_ index:Int)->CGFloat{26+ceil((names[index] as NSString).size(withAttributes:[.font:bold]).width)}
    override var intrinsicContentSize:NSSize{NSSize(width:names.indices.reduce(0){$0+width($1)}+CGFloat(names.count-1)*(link+gap*2),height:20)}
    override func draw(_ dirtyRect:NSRect) {
        var x:CGFloat=0
        for index in names.indices {
            let now=index==current,reached=now || done[index]
            if index>0 {
                (reached ? HomePalette.ink:HomePalette.track).setFill()
                NSRect(x:x+gap,y:10,width:link,height:1).fill()
                x+=link+gap*2
            }
            let disc=NSRect(x:x,y:0,width:20,height:20)
            if done[index] && !now{setupCheckMark(disc)}
            else if now {
                HomePalette.ink.setFill();NSBezierPath(ovalIn:disc).fill()
                setupCentered("\(index+1)",at:NSPoint(x:disc.midX,y:disc.midY),[.font:NSFont.systemFont(ofSize:11,weight:.bold),.foregroundColor:HomePalette.canvas])
            } else {
                let ring=NSBezierPath(ovalIn:disc.insetBy(dx:0.75,dy:0.75));ring.lineWidth=1.5
                NSColor.tertiaryLabelColor.setStroke();ring.stroke()
                setupCentered("\(index+1)",at:NSPoint(x:disc.midX,y:disc.midY),[.font:NSFont.systemFont(ofSize:11,weight:.semibold),.foregroundColor:NSColor.secondaryLabelColor])
            }
            let label=names[index] as NSString,labelFont=now ? bold:font
            let size=label.size(withAttributes:[.font:labelFont])
            label.draw(at:NSPoint(x:x+26,y:floor(10-size.height/2)),withAttributes:[.font:labelFont,.foregroundColor:reached ? NSColor.labelColor:NSColor.secondaryLabelColor])
            x+=width(index)
        }
    }
}

// "Allowed" and "Calibrated": the done mark with its word.
private final class SetupCheck:NSView {
    var text=""{didSet{if text != oldValue{setAccessibilityLabel(text);invalidateIntrinsicContentSize();needsDisplay=true}}}
    private let font=NSFont.systemFont(ofSize:13,weight:.semibold)
    override var isFlipped:Bool{true}
    init(){super.init(frame:.zero);translatesAutoresizingMaskIntoConstraints=false}
    required init?(coder:NSCoder){fatalError("init(coder:) is not used")}
    override func isAccessibilityElement()->Bool{true}
    override func accessibilityRole()->NSAccessibility.Role?{.staticText}
    override var intrinsicContentSize:NSSize{NSSize(width:ceil((text as NSString).size(withAttributes:[.font:font]).width)+26,height:20)}
    override func draw(_ dirtyRect:NSRect) {
        setupCheckMark(NSRect(x:0,y:1,width:18,height:18))
        let size=(text as NSString).size(withAttributes:[.font:font])
        (text as NSString).draw(at:NSPoint(x:26,y:floor(10-size.height/2)),withAttributes:[.font:font,.foregroundColor:NSColor.labelColor])
    }
}

// A miniature Accessibility list: AirPointer's switch, with the pointer over
// it until macOS reports the app as trusted.
private final class SetupAccessArt:NSView {
    var on=false{didSet{if on != oldValue{needsDisplay=true}}}
    override var isFlipped:Bool{true}
    init() {
        super.init(frame:.zero)
        setAccessibilityElement(true);setAccessibilityRole(.image)
        setAccessibilityLabel("AirPointer being dragged into the Accessibility list")
    }
    required init?(coder:NSCoder){fatalError("init(coder:) is not used")}
    override func draw(_ dirtyRect:NSRect) {
        let card=NSRect(x:round(bounds.midX-150),y:round(bounds.midY-74),width:300,height:148)
        let shape=NSBezierPath(roundedRect:card.insetBy(dx:0.5,dy:0.5),xRadius:12,yRadius:12)
        HomePalette.canvas.setFill();shape.fill()
        HomePalette.rule.setStroke();shape.lineWidth=1;shape.stroke()
        let hairline=1/(window?.backingScaleFactor ?? 2)
        func drawName(_ icon:NSRect,midY:CGFloat) {
            NSApp.applicationIconImage?.draw(in:icon,from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:nil)
            let font=NSFont.systemFont(ofSize:13,weight:.medium),size=("AirPointer" as NSString).size(withAttributes:[.font:font])
            ("AirPointer" as NSString).draw(at:NSPoint(x:icon.maxX+10,y:floor(midY-size.height/2)),withAttributes:[.font:font,.foregroundColor:NSColor.labelColor])
        }
        var slot=NSRect.zero
        for row in 0..<3 {
            let frame=NSRect(x:card.minX+16,y:card.minY+8+CGFloat(row)*44,width:card.width-32,height:44)
            let icon=NSRect(x:frame.minX,y:frame.midY-12,width:24,height:24)
            let toggle=NSRect(x:frame.maxX-32,y:frame.midY-9,width:32,height:18)
            if row==1 {
                slot=frame.insetBy(dx:0,dy:5)
                if on{drawName(icon,midY:frame.midY)}
            } else {
                HomePalette.track.setFill()
                NSBezierPath(roundedRect:icon,xRadius:6,yRadius:6).fill()
                NSBezierPath(roundedRect:NSRect(x:icon.maxX+10,y:frame.midY-4,width:row==0 ? 96:72,height:8),xRadius:4,yRadius:4).fill()
            }
            if row != 1 || on{drawSwitch(toggle,on:row==1)}
            if row<2{HomePalette.rule.setFill();NSRect(x:icon.maxX+10,y:frame.maxY-hairline/2,width:frame.maxX-icon.maxX-10,height:hairline).fill()}
        }
        guard !on else{return}
        // An empty place in the list, and AirPointer on its way there.
        let place=NSBezierPath(roundedRect:slot,xRadius:8,yRadius:8)
        place.setLineDash([4,3],count:2,phase:0);place.lineWidth=1;HomePalette.track.setStroke();place.stroke()
        let dragged=NSRect(x:card.minX+66,y:slot.midY+10,width:148,height:44)
        NSGraphicsContext.saveGraphicsState()
        let shadow=NSShadow();shadow.shadowColor=NSColor.black.withAlphaComponent(0.25);shadow.shadowBlurRadius=10;shadow.shadowOffset=NSSize(width:0,height:-3);shadow.set()
        HomePalette.canvas.setFill();NSBezierPath(roundedRect:dragged,xRadius:10,yRadius:10).fill()
        NSGraphicsContext.restoreGraphicsState()
        let outline=NSBezierPath(roundedRect:dragged.insetBy(dx:0.5,dy:0.5),xRadius:10,yRadius:10);outline.lineWidth=1;HomePalette.rule.setStroke();outline.stroke()
        drawName(NSRect(x:dragged.minX+10,y:dragged.midY-12,width:24,height:24),midY:dragged.midY)
        let hand=NSCursor.closedHand.image
        hand.draw(in:NSRect(x:dragged.maxX-34,y:dragged.midY-hand.size.height/2,width:hand.size.width,height:hand.size.height),from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:nil)
    }
    private func drawSwitch(_ rect:NSRect,on:Bool) {
        (on ? HomePalette.ink:HomePalette.track).setFill()
        NSBezierPath(roundedRect:rect,xRadius:rect.height/2,yRadius:rect.height/2).fill()
        let knob=NSRect(x:on ? rect.maxX-rect.height+2:rect.minX+2,y:rect.minY+2,width:rect.height-4,height:rect.height-4)
        NSGraphicsContext.saveGraphicsState()
        let shadow=NSShadow();shadow.shadowColor=NSColor.black.withAlphaComponent(0.22);shadow.shadowBlurRadius=1.5;shadow.shadowOffset=NSSize(width:0,height:-0.5);shadow.set()
        (on ? HomePalette.canvas:NSColor.white).setFill();NSBezierPath(ovalIn:knob).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}

// The calibration overlay in miniature: center, right edge and top edge,
// with the next target in laser red.
// One dot for each tap heard.
private final class SetupTapArt:NSView {
    var heard=0{didSet{if heard != oldValue{needsDisplay=true;setAccessibilityLabel("\(heard) of \(ClosedCaseTapLearner.taps) taps heard")}}}
    init() {
        super.init(frame:.zero)
        setAccessibilityElement(true);setAccessibilityRole(.image)
        setAccessibilityLabel("0 of \(ClosedCaseTapLearner.taps) taps heard")
    }
    required init?(coder:NSCoder){fatalError("init(coder:) is not used")}
    override func draw(_ dirtyRect:NSRect) {
        let size:CGFloat=36,gap:CGFloat=28,count=CGFloat(ClosedCaseTapLearner.taps)
        let left=round(bounds.midX-(count*size+(count-1)*gap)/2),y=round(bounds.midY-size/2)
        for index in 0..<ClosedCaseTapLearner.taps {
            let disc=NSRect(x:left+CGFloat(index)*(size+gap),y:y,width:size,height:size)
            if index<heard{NSColor.white.setFill();NSBezierPath(ovalIn:disc).fill()}
            else{let ring=NSBezierPath(ovalIn:disc.insetBy(dx:1,dy:1));ring.lineWidth=2;NSColor(white:1,alpha:0.4).setStroke();ring.stroke()}
        }
    }
}

private final class SetupTargetArt:NSView {
    var done=false{didSet{if done != oldValue{needsDisplay=true}}}
    override var isFlipped:Bool{true}
    init() {
        super.init(frame:.zero)
        setAccessibilityElement(true);setAccessibilityRole(.image)
        setAccessibilityLabel("A screen with three dots: 1 in the center, 2 at the right edge, 3 at the top edge")
    }
    required init?(coder:NSCoder){fatalError("init(coder:) is not used")}
    override func draw(_ dirtyRect:NSRect) {
        let screen=NSRect(x:round(bounds.midX-152),y:round(bounds.midY-95),width:304,height:190)
        HomePalette.screen.setFill();NSBezierPath(roundedRect:screen,xRadius:12,yRadius:12).fill()
        let inner=screen.insetBy(dx:14,dy:14),grid=NSBezierPath()
        for i in 1..<3 {
            let x=inner.minX+inner.width*CGFloat(i)/3,y=inner.minY+inner.height*CGFloat(i)/3
            grid.move(to:NSPoint(x:x,y:inner.minY));grid.line(to:NSPoint(x:x,y:inner.maxY))
            grid.move(to:NSPoint(x:inner.minX,y:y));grid.line(to:NSPoint(x:inner.maxX,y:y))
        }
        NSColor(white:1,alpha:0.06).setStroke();grid.lineWidth=1;grid.stroke()
        let points=[NSPoint(x:inner.midX,y:inner.midY),NSPoint(x:inner.maxX-14,y:inner.midY),NSPoint(x:inner.midX,y:inner.minY+14)]
        let guide=NSBezierPath()
        for end in points.dropFirst(){guide.move(to:points[0]);guide.line(to:end)}
        guide.setLineDash([2,5],count:2,phase:0);guide.lineWidth=1.5;guide.lineCapStyle = .round
        NSColor(white:1,alpha:0.24).setStroke();guide.stroke()
        let font=NSFont.systemFont(ofSize:12,weight:.bold)
        for (index,point) in points.enumerated() {
            let disc=NSRect(x:point.x-12,y:point.y-12,width:24,height:24)
            if done{setupCheckMark(disc,disc:NSColor(white:1,alpha:0.92),mark:HomePalette.screen);continue}
            if index==0 {
                HomePalette.laser.withAlphaComponent(0.22).setFill();NSBezierPath(ovalIn:disc.insetBy(dx:-6,dy:-6)).fill()
                HomePalette.laser.setFill();NSBezierPath(ovalIn:disc).fill()
            } else {
                HomePalette.screen.setFill();NSBezierPath(ovalIn:disc).fill()
                let ring=NSBezierPath(ovalIn:disc.insetBy(dx:0.75,dy:0.75));ring.lineWidth=1.5
                NSColor(white:1,alpha:0.45).setStroke();ring.stroke()
            }
            setupCentered("\(index+1)",at:point,[.font:font,.foregroundColor:NSColor(white:1,alpha:index==0 ? 1:0.8)])
        }
    }
}

private final class SetupStyleArt:NSView {
    var selected=PointingPlane.upright{didSet{if selected != oldValue{sync()}}}
    var onSelect:((PointingPlane)->Void)?
    private var buttons:[RemoteButton]=[]
    init() {
        super.init(frame:.zero)
        appearance=NSAppearance(named:.darkAqua)
        let preview=CaseStepView();preview.step = .point;preview.fill=0.72
        preview.widthAnchor.constraint(equalToConstant:136).isActive=true
        preview.heightAnchor.constraint(equalToConstant:136).isActive=true
        buttons=PointingPlane.allCases.enumerated().map{index,plane in
            let button=RemoteButton(plane.shortTitle,style:plane == .upright ? .secondary:.tertiary,symbol:plane == .upright ? "checkmark":nil,height:36)
            button.tag=index;button.target=self;button.action=#selector(picked(_:))
            return button
        }
        let row=rkHStack(buttons,spacing:8)
        let stack=rkVStack([preview,row],spacing:12,align:.centerX)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo:centerXAnchor),
            stack.centerYAnchor.constraint(equalTo:centerYAnchor),
        ])
        sync()
    }
    required init?(coder:NSCoder){fatalError("init(coder:) is not used")}
    private func sync() {
        if let preview=subviews.first?.subviews.compactMap({$0 as? CaseStepView}).first {
            preview.step=selected == .upright ? .point:.closed
        }
        for (index,plane) in PointingPlane.allCases.enumerated() where buttons.indices.contains(index) {
            buttons[index].style=plane == selected ? .secondary:.tertiary
            buttons[index].symbolName=plane == selected ? "checkmark":nil
        }
    }
    @objc private func picked(_ sender:RemoteButton) {
        guard PointingPlane.allCases.indices.contains(sender.tag) else{return}
        let plane=PointingPlane.allCases[sender.tag]
        selected=plane;onSelect?(plane)
    }
}
