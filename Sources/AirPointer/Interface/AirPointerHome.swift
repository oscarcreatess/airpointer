import AppKit

// The closed-case steps between connecting and ready: shut the lid, turn the
// case upright while it settles, then point at the calibration dots.
enum ClosedCaseStep:Equatable {case openLid,closeLid,turnUpright,holdStill,calibrate,recenter}
enum HomeControlPhase:Equatable {case needsInputs,connecting,needsAccessibility,ready,running,paused(String),closedCase(ClosedCaseStep)}

enum PointingPlane:String,CaseIterable,Equatable {
    case upright
    case flatSwivel
    case flatTilt

    var title:String {
        switch self {
        case .upright:return "Upright (vertical & lateral)"
        case .flatSwivel:return "Flat swivel + tilt"
        case .flatTilt:return "Flat tilt-joystick"
        }
    }
    var shortTitle:String {
        switch self {
        case .upright:return "Upright"
        case .flatSwivel:return "Flat swivel"
        case .flatTilt:return "Flat tilt"
        }
    }
    var subtitle:String {
        switch self {
        case .upright:return "Hold the closed case upright and aim at the screen."
        case .flatSwivel:return "Keep the case flat on your desk; swivel left/right and tilt forward/back."
        case .flatTilt:return "Keep the case flat and rock it forward, back, left or right like a joystick."
        }
    }
    var requiresTurnUpright:Bool {self == .upright}
}

extension NSScreen {
    // Stays the same across unplugging and reordering, unlike the place in NSScreen.screens.
    var displayID:String? {
        guard let number=deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid=CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else{return nil}
        return CFUUIDCreateString(nil,uuid) as String
    }
}

struct PointerSettingsState:Equatable {
    var screens:[String]=[]
    var screen=0
    // The display someone picked in Settings. While it's unplugged the pointer uses another, and this waits for it to return.
    var screenID:String?=nil
    // Paired AirPods Pro by name; -1 until one is chosen among several.
    var pairs:[String]=[]
    var pair=0
    var speed=1.0
    var clickSound=true
    var plane=PointingPlane.upright
    // The way this person's taps push the sensor, when setup learned one other than the usual.
    var tapDirection:[Double]?=nil

    // Slider legacy: 10…60 stored as pointerSensitivity; speed is that value / 25.
    private static let sensitivityKey="pointerSensitivity"
    private static let clickSoundKey="tapClickSound"
    private static let planeKey="pointingPlane"
    private static let tapDirectionKey="tapDirection"
    private static let screenKey="pointerScreen"
    private static let screenIDKey="pointerScreenID"

    static func screenIndex(chosen:String?,current:Int,in displays:[String?])->Int {
        if let chosen,let found=displays.firstIndex(of:chosen){return found}
        return max(0,min(current,displays.count-1))
    }

    static func loadPersisted()->PointerSettingsState {
        var value=PointerSettingsState()
        if let saved=UserDefaults.standard.object(forKey:sensitivityKey) as? Double,saved.isFinite{
            value.speed=min(60,max(10,saved))/25
        }
        value.clickSound=UserDefaults.standard.object(forKey:clickSoundKey) as? Bool ?? true
        if let raw=UserDefaults.standard.string(forKey:planeKey),let parsed=PointingPlane(rawValue:raw){
            value.plane=parsed
        }
        value.tapDirection=(UserDefaults.standard.array(forKey:tapDirectionKey) as? [Double]).flatMap{$0.count==3 ? $0:nil}
        if let saved=UserDefaults.standard.object(forKey:screenKey) as? Int{value.screen=max(0,saved)}
        value.screenID=UserDefaults.standard.string(forKey:screenIDKey)
        return value
    }

    mutating func clampSpeed(){speed=min(60,max(10,speed*25))/25}

    func persist(){
        UserDefaults.standard.set(min(60,max(10,speed*25)),forKey:Self.sensitivityKey)
        UserDefaults.standard.set(clickSound,forKey:Self.clickSoundKey)
        UserDefaults.standard.set(plane.rawValue,forKey:Self.planeKey)
        if let tapDirection{UserDefaults.standard.set(tapDirection,forKey:Self.tapDirectionKey)}else{UserDefaults.standard.removeObject(forKey:Self.tapDirectionKey)}
        UserDefaults.standard.set(screen,forKey:Self.screenKey)
        if let screenID{UserDefaults.standard.set(screenID,forKey:Self.screenIDKey)}else{UserDefaults.standard.removeObject(forKey:Self.screenIDKey)}
    }
}

func runPointerSettingsChecks()throws {
    let defaults=UserDefaults.standard
    let keys=["pointerSensitivity","tapClickSound","pointingPlane","pointerScreen","pointerScreenID","tapDirection"]
    let prior=Dictionary(uniqueKeysWithValues:keys.map{($0,defaults.object(forKey:$0))})
    defer{for key in keys{if let value=prior[key]{defaults.set(value,forKey:key)}else{defaults.removeObject(forKey:key)}}}
    for key in keys{defaults.removeObject(forKey:key)}
    let fresh=PointerSettingsState.loadPersisted()
    guard fresh.speed==1,fresh.clickSound,fresh.plane == .upright,fresh.screen==0,fresh.screenID==nil,fresh.tapDirection==nil else{
        throw LessonError.message("Default pointer settings should be speed 1, click sound on, upright plane, screen 0.")
    }
    var sample=PointerSettingsState(screen:1,screenID:"side",speed:1.4,clickSound:false,plane:.flatTilt,tapDirection:[0.6,0,-0.8])
    sample.clampSpeed();sample.persist()
    let loaded=PointerSettingsState.loadPersisted()
    guard abs(loaded.speed-1.4)<1e-9,!loaded.clickSound,loaded.plane == .flatTilt,loaded.screen==1,loaded.screenID=="side",loaded.tapDirection==[0.6,0,-0.8] else{
        throw LessonError.message("Pointer settings did not round-trip through UserDefaults.")
    }
    // The chosen display wherever it now sits; with it unplugged, a display that exists; with no choice, the same place.
    guard PointerSettingsState.screenIndex(chosen:"side",current:0,in:["main","other","side"])==2,
          PointerSettingsState.screenIndex(chosen:"side",current:2,in:["main","other"])==1,
          PointerSettingsState.screenIndex(chosen:"side",current:1,in:[nil,"other"])==1,
          PointerSettingsState.screenIndex(chosen:nil,current:1,in:["main","other"])==1,
          PointerSettingsState.screenIndex(chosen:"side",current:3,in:[])==0 else{
        throw LessonError.message("The chosen display wasn’t found after the displays changed.")
    }
}

// MARK: - Copy

private struct HomeControlKey:Equatable {let phase:HomeControlPhase;let inputs:Bool;let plane:PointingPlane}

private func hmCommand(_ phase:HomeControlPhase)->(title:String,hint:String?) {
    switch phase {
    case .needsInputs:return ("Connect AirPods",nil)
    case .connecting:return ("Cancel","esc")
    case .needsAccessibility:return ("Allow",nil)
    case .ready:return ("Start Pointing",PointerShortcut.current.label)
    case .running:return ("Pause",PointerShortcut.current.label)
    case .paused:return ("Resume",PointerShortcut.current.label)
    case .closedCase(.openLid):return ("Cancel","esc")
    case .closedCase(.closeLid):return ("Lid Closed","Return")
    case .closedCase(.turnUpright),.closedCase(.holdStill):return ("Cancel","esc")
    case .closedCase(.calibrate):return ("Start Calibration",nil)
    case .closedCase(.recenter):return ("Recenter",nil)
    }
}
private func hmHero(_ phase:HomeControlPhase,plane:PointingPlane = .upright)->(String,String) {
    switch phase {
    case .needsInputs:return ("Connect your AirPods","Hold the closed case with both AirPods inside. Connect, then open the lid.")
    case .connecting:return ("Looking for your AirPods…","Keep the lid open for a moment.")
    case .needsAccessibility:return ("Allow control","Press Allow to open the Accessibility list, then drag AirPointer into it so it can move the pointer and click.")
    case .ready:return ("Ready to point",plane == .upright ? "Hold the closed case upright and aim at the screen.":"Keep the closed case flat and aim at the screen.")
    case .running:return ("Pointing",plane == .upright ? "Aim with the case. Tap its front to click.":"Aim with the case. Tap the case to click.")
    case .paused(let reason):return ("Paused",reason=="Paused" || reason.isEmpty ? "Resume when you’re ready.":reason)
    case .closedCase(.openLid):return ("Open the lid","AirPointer connects when you open it. Keep both AirPods inside.")
    case .closedCase(.closeLid):return ("Close the lid","Keep both AirPods inside. AirPointer goes on by itself, or press Return.")
    case .closedCase(.turnUpright):return ("Turn it upright","Give the closed case a quarter turn clockwise.")
    case .closedCase(.holdStill):return ("Set it down","Put the closed case on a flat surface for a moment.")
    case .closedCase(.calibrate):return ("Point at the dots","Aim at each dot on your screen and hold still. Esc cancels.")
    case .closedCase(.recenter):return ("Point at the center","Your edges are saved, so one dot is enough. Esc cancels.")
    }
}

// MARK: - Building blocks

// A vertical page column whose full-width rows track the column's width.
private final class PageColumn:NSStackView {
    init(spacing:CGFloat=12) {
        super.init(frame:.zero)
        orientation = .vertical;alignment = .leading;self.spacing=spacing
        translatesAutoresizingMaskIntoConstraints=false
    }
    required init?(coder:NSCoder){fatalError("init(coder:) is not used")}
    func addFull(_ view:NSView) {
        view.translatesAutoresizingMaskIntoConstraints=false
        addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo:widthAnchor).isActive=true
    }
    // The column pins leading edges, so centered rows sit in a full-width holder.
    func addCentered(_ view:NSView) {
        let holder=NSView();view.translatesAutoresizingMaskIntoConstraints=false;holder.addSubview(view)
        NSLayoutConstraint.activate([
            view.centerXAnchor.constraint(equalTo:holder.centerXAnchor),
            view.topAnchor.constraint(equalTo:holder.topAnchor),view.bottomAnchor.constraint(equalTo:holder.bottomAnchor),
            view.leadingAnchor.constraint(greaterThanOrEqualTo:holder.leadingAnchor),
        ])
        addFull(holder)
    }
    func gap(_ value:CGFloat){if let last=arrangedSubviews.last{setCustomSpacing(value,after:last)}}
    @discardableResult func addHeader(_ text:String)->NSTextField {
        gap(24)
        let label=hmEyebrow(text);addFull(label);setCustomSpacing(8,after:label)
        return label
    }
}
private func hmEyebrow(_ text:String)->NSTextField {
    let label=rkLabel(text,11,.semibold,.secondaryLabelColor)
    label.attributedStringValue=NSAttributedString(string:text.uppercased(),attributes:[.font:NSFont.systemFont(ofSize:11,weight:.semibold),.foregroundColor:NSColor.secondaryLabelColor,.kern:0.6])
    label.setAccessibilityLabel(text)
    return label
}
private func hmScrollPage(top:CGFloat=8)->(NSScrollView,PageColumn) {
    let scroll=NSScrollView();scroll.drawsBackground=false;scroll.hasVerticalScroller=true;scroll.autohidesScrollers=true
    scroll.borderType = .noBorder;scroll.scrollerStyle = .overlay;scroll.translatesAutoresizingMaskIntoConstraints=false
    let document=RemoteFlipped();document.translatesAutoresizingMaskIntoConstraints=false
    scroll.documentView=document
    let column=PageColumn();document.addSubview(column)
    let clip=scroll.contentView
    NSLayoutConstraint.activate([
        document.leadingAnchor.constraint(equalTo:clip.leadingAnchor),
        document.trailingAnchor.constraint(equalTo:clip.trailingAnchor),
        document.topAnchor.constraint(equalTo:clip.topAnchor),
        column.leadingAnchor.constraint(equalTo:document.leadingAnchor,constant:24),
        column.trailingAnchor.constraint(equalTo:document.trailingAnchor,constant:-24),
        column.topAnchor.constraint(equalTo:document.topAnchor,constant:top),
        column.bottomAnchor.constraint(equalTo:document.bottomAnchor,constant:-24),
    ])
    return (scroll,column)
}
private func hmRow(_ leading:[NSView],trailing:[NSView]=[],spacing:CGFloat=8)->NSStackView {
    let row=rkHStack(leading+[rkSpacer()]+trailing,spacing:spacing)
    return row
}
private func hmSettingRow(_ title:String,_ caption:String?,_ control:NSView)->NSStackView {
    hmSettingRow(title,detail:caption.map{rkWrap($0,12)},control)
}
private func hmSettingRow(_ title:String,detail:NSView?,_ control:NSView)->NSStackView {
    let text=rkVStack([rkLabel(title,13,.medium)],spacing:2)
    if let detail{text.addArrangedSubview(detail)}
    text.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
    control.setContentHuggingPriority(.required,for:.horizontal)
    let row=rkHStack([text,rkSpacer(),control],spacing:16)
    row.heightAnchor.constraint(greaterThanOrEqualToConstant:44).isActive=true
    return row
}

// A dismissible line at the top of the window for things that went wrong.
private final class NoticeBar:NSView {
    private let text=rkWrap("",12,.labelColor)
    private let icon=rkSymbolView("exclamationmark.circle",13,.secondaryLabelColor)
    private let close=NSButton()
    init() {
        super.init(frame:.zero);translatesAutoresizingMaskIntoConstraints=false
        close.image=rkSymbol("xmark",10,.semibold);close.isBordered=false;close.imagePosition = .imageOnly
        close.contentTintColor = .secondaryLabelColor;close.target=self;close.action=#selector(dismiss)
        close.setAccessibilityLabel("Dismiss")
        // The message takes the width left over, so the dismiss button sits at the trailing edge.
        text.setContentHuggingPriority(.init(1),for:.horizontal);close.setContentHuggingPriority(.required,for:.horizontal)
        let row=rkHStack([icon,text,close],spacing:10);row.alignment = .firstBaseline;row.distribution = .fill
        let surface=RemoteSurface(HomePalette.raised,radius:10)
        rkPin(surface,in:self,insets:NSEdgeInsets(top:4,left:16,bottom:8,right:16))
        rkPin(row,in:surface,insets:NSEdgeInsets(top:10,left:12,bottom:10,right:10))
        isHidden=true
    }
    required init?(coder:NSCoder){fatalError("init(coder:) is not used")}
    func set(_ value:String?) {
        let value=value?.trimmingCharacters(in:.whitespacesAndNewlines)
        isHidden=value?.isEmpty ?? true
        if let value,!value.isEmpty,text.stringValue != value {
            text.stringValue=value
            NSAccessibility.post(element:text,notification:.announcementRequested,userInfo:[.announcement:value,.priority:NSAccessibilityPriorityLevel.high.rawValue])
        }
    }
    @objc private func dismiss(){isHidden=true}
}

// MARK: - Window

private enum HomePage:Equatable {case pointer,settings}

// A key window where bare Esc goes to the page unless a field is being edited.
final class HomeWindow:NSWindow {
    var onEscape:(()->Void)?
    override func sendEvent(_ event:NSEvent) {
        if event.type == .keyDown,!event.isARepeat,
           event.modifierFlags.intersection([.command,.control,.option]).isEmpty {
            let editing=firstResponder is NSTextView || firstResponder is NSTextField
            if event.keyCode==53,!editing,let onEscape{onEscape();return}
        }
        super.sendEvent(event)
    }
}

final class AirPointerHome:NSObject,NSWindowDelegate {
    let window:HomeWindow
    var onControl:(()->Void)?
    var onRecenter:(()->Void)?
    var onLearnGrip:(()->Void)?
    var onDisconnect:(()->Void)?
    var onSetup:(()->Void)?
    var onTeachTap:(()->Void)?
    var onSettings:(()->Void)?
    var onPointerSettingsChange:((PointerSettingsState)->Void)?
    var onClose:(()->Void)?

    fileprivate var phase=HomeControlPhase.needsInputs
    fileprivate var inputsReady=false
    fileprivate var pointerSettings=PointerSettingsState()

    let pad:AimPadView
    private let pageHost=NSView()
    private let notice=NoticeBar()
    private lazy var pointerPage=PointerPage(home:self)
    private lazy var settingsPage=SettingsPage(home:self)
    fileprivate private(set) var page=HomePage.pointer
    private var controlKey:HomeControlKey?

    init(pad:AimPadView=AimPadView()) {
        self.pad=pad;pad.setAccessibilityElement(true);pad.setAccessibilityRole(.image)
        window=HomeWindow(contentRect:NSRect(x:0,y:0,width:440,height:700),styleMask:[.titled,.closable,.miniaturizable,.resizable,.fullSizeContentView],backing:.buffered,defer:false)
        super.init()
        window.title="AirPointer";window.titleVisibility = .hidden
        window.isReleasedWhenClosed=false;window.delegate=self
        window.titlebarAppearsTransparent=true;window.titlebarSeparatorStyle = .none
        window.backgroundColor=HomePalette.canvas
        window.contentMinSize=NSSize(width:400,height:620);window.contentMaxSize=NSSize(width:560,height:4000)
        let toolbar=NSToolbar(identifier:"AirPointerRemote")
        toolbar.delegate=self;toolbar.displayMode = .iconOnly;toolbar.allowsUserCustomization=false
        if #available(macOS 15,*){toolbar.allowsDisplayModeCustomization=false}
        window.toolbar=toolbar;window.toolbarStyle = .unified
        let root=RemoteSurface(HomePalette.canvas)
        let stack=rkVStack([notice,pageHost],spacing:0,align:.leading)
        pageHost.translatesAutoresizingMaskIntoConstraints=false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo:root.safeAreaLayoutGuide.topAnchor),
            stack.leadingAnchor.constraint(equalTo:root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo:root.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo:root.bottomAnchor),
            notice.widthAnchor.constraint(equalTo:stack.widthAnchor),
            pageHost.widthAnchor.constraint(equalTo:stack.widthAnchor),
        ])
        window.contentView=root
        window.setContentSize(NSSize(width:440,height:700))
        window.center()
        window.onEscape={[weak self] in self?.handleEscape()}
        present(.pointer)
    }

    // MARK: Public API

    func show() {
        if window.isMiniaturized{window.deminiaturize(nil)}
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps:true)
    }

    // Called about 12 times a second: returns early unless something visible changed.
    func updateControl(phase:HomeControlPhase,inputsReady:Bool) {
        let key=HomeControlKey(phase:phase,inputs:inputsReady,plane:pointerSettings.plane)
        guard key != controlKey else{return}
        let announce=controlKey != nil && phase != self.phase
        controlKey=key
        self.phase=phase;self.inputsReady=inputsReady
        pointerPage.render()
        if announce{NSAccessibility.post(element:window,notification:.announcementRequested,userInfo:[.announcement:hmHero(phase,plane:pointerSettings.plane).0,.priority:NSAccessibilityPriorityLevel.high.rawValue])}
    }

    func updateHold(_ progress:CGFloat?){pointerPage.updateHold(progress)}
    func setNotice(_ text:String?){notice.set(text)}
    func selectPointer(){present(.pointer)}
    func selectSettings() {
        guard page != .settings else{return}
        present(.settings)
        NSAccessibility.post(element:window,notification:.announcementRequested,userInfo:[.announcement:"Settings",.priority:NSAccessibilityPriorityLevel.medium.rawValue])
    }
    func updatePointerSettings(_ value:PointerSettingsState) {
        guard value != pointerSettings else{return}
        pointerSettings=value;settingsPage.apply();pointerPage.render()
    }

    // MARK: Shared with pages

    fileprivate func changePointerSettings(_ value:PointerSettingsState) {
        pointerSettings=value;settingsPage.apply();pointerPage.render();onPointerSettingsChange?(value)
    }

    fileprivate func present(_ next:HomePage) {
        if next != page {
            if let responder=window.firstResponder as? NSView,responder.isDescendant(of:pageHost){_ = window.makeFirstResponder(nil)}
        }
        page=next
        let view:NSView
        switch next {
        case .pointer:pointerPage.render();view=pointerPage.view
        case .settings:settingsPage.apply();view=settingsPage.view
        }
        guard pageHost.subviews.first !== view else{return}
        pageHost.subviews.forEach{$0.removeFromSuperview()}
        rkPin(view,in:pageHost)
    }

    // MARK: Actions and keys

    @objc fileprivate func openSettings(){onSettings?()}

    private func handleEscape() {
        switch phase {
        case .running,.connecting,.closedCase(.openLid),.closedCase(.turnUpright),.closedCase(.holdStill):onControl?();return
        default:break
        }
        if page == .settings{present(.pointer)}
    }

    func windowWillClose(_ notification:Notification) {
        onClose?()
    }
}

private extension NSToolbarItem.Identifier {
    static let homeSettings=NSToolbarItem.Identifier("AirPointerSettings")
}

extension AirPointerHome:NSToolbarDelegate {
    func toolbarDefaultItemIdentifiers(_ toolbar:NSToolbar)->[NSToolbarItem.Identifier]{[.flexibleSpace,.homeSettings]}
    func toolbarAllowedItemIdentifiers(_ toolbar:NSToolbar)->[NSToolbarItem.Identifier]{toolbarDefaultItemIdentifiers(toolbar)}
    func toolbar(_ toolbar:NSToolbar,itemForItemIdentifier identifier:NSToolbarItem.Identifier,willBeInsertedIntoToolbar flag:Bool)->NSToolbarItem? {
        let item=NSToolbarItem(itemIdentifier:identifier)
        if identifier == .homeSettings {
            item.image=rkSymbol("gearshape",15);item.label="Settings";item.toolTip="Settings (⌘,)"
            item.isBordered=true;item.target=self;item.action=#selector(openSettings)
        } else{return nil}
        return item
    }
}

// MARK: - Pointer

private final class PointerPage:NSObject {
    unowned let home:AirPointerHome
    let view:NSScrollView
    private let stage=RemoteSurface(HomePalette.stage,radius:18)
    private let art=CaseStepView()
    private let chip=StatusChip()
    private let title=rkTitle("",26,align:.center)
    private let subtitle=rkWrap("",13,align:.center)
    private let primary=RemoteButton("Start Pointing",height:48)
    private let recenter=RemoteButton("Recenter",style:.tertiary,symbol:"scope",height:32)
    private let recalibrate=RemoteButton("Recalibrate…",style:.tertiary,symbol:"dot.viewfinder",height:32)
    private let disconnect=RemoteButton("Disconnect",style:.tertiary,symbol:"xmark.circle",height:32)
    private let secondary=NSStackView()
    private var showingPad:Bool?

    init(home:AirPointerHome) {
        self.home=home
        let page=hmScrollPage(top:4);view=page.0
        super.init()
        let column=page.1
        stage.translatesAutoresizingMaskIntoConstraints=false
        stage.heightAnchor.constraint(equalToConstant:228).isActive=true
        art.fill=0.86
        for view in [art,home.pad] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints=false;stage.addSubview(view)
        }
        NSLayoutConstraint.activate([
            art.topAnchor.constraint(equalTo:stage.topAnchor,constant:8),art.bottomAnchor.constraint(equalTo:stage.bottomAnchor,constant:-8),
            art.leadingAnchor.constraint(equalTo:stage.leadingAnchor),art.trailingAnchor.constraint(equalTo:stage.trailingAnchor),
            home.pad.centerXAnchor.constraint(equalTo:stage.centerXAnchor),home.pad.centerYAnchor.constraint(equalTo:stage.centerYAnchor),
            home.pad.heightAnchor.constraint(equalTo:stage.heightAnchor,constant:-32),
            home.pad.widthAnchor.constraint(equalTo:home.pad.heightAnchor,multiplier:1.6),
        ])
        column.addFull(stage);column.gap(18)
        column.addCentered(chip);column.gap(12)
        column.addFull(title);column.gap(6)
        column.addFull(subtitle);column.gap(22)
        primary.target=self;primary.action=#selector(primaryPressed)
        column.addFull(primary);column.gap(8)
        recenter.target=self;recenter.action=#selector(recenterPressed)
        recalibrate.target=self;recalibrate.action=#selector(recalibratePressed)
        disconnect.target=self;disconnect.action=#selector(disconnectPressed)
        recenter.toolTip="Recenter on where you’re aiming";recalibrate.toolTip="Point at three dots so AirPointer knows where your screen is"
        disconnect.toolTip="End the connection. To reconnect, connect again and open the lid."
        secondary.orientation = .horizontal;secondary.spacing=4
        secondary.addArrangedSubview(recenter);secondary.addArrangedSubview(recalibrate);secondary.addArrangedSubview(disconnect)
        column.addCentered(secondary)
        render()
    }

    func render() {
        let phase=home.phase
        let hero=hmHero(phase,plane:home.pointerSettings.plane),command=hmCommand(phase)
        rkSetText(title,hero.0);rkSetText(subtitle,hero.1)
        if primary.title != command.title{primary.title=command.title}
        if primary.hint != command.hint{primary.hint=command.hint}
        // The hint names the key: Return confirms the closed lid, esc cancels.
        let key=command.hint=="Return" ? "\r":command.hint=="esc" ? "\u{1b}":""
        if primary.keyEquivalent != key{primary.keyEquivalent=key}
        // Until the closed case is upright and held, the stage shows the step to do with it.
        let connected:Bool
        switch phase {
        // Closed before Connect and while asking for Accessibility, the lid opening while Connect waits, then the open case.
        case .needsInputs:connected=false;art.step = .closed
        case .closedCase(.openLid):connected=false;art.step = .opening
        case .connecting:connected=false;art.step = .open
        case .closedCase(.closeLid):connected=false;art.step = .close
        case .closedCase(.turnUpright):connected=false;art.step = .turn
        case .closedCase(.holdStill):connected=false;art.step = .closed
        case .needsAccessibility:connected=home.inputsReady;art.step = .closed
        default:connected=true
        }
        let live:Bool
        switch phase {
        case .needsInputs:chip.set("Not connected",dot:false);live=false
        case .connecting:chip.set("Connecting…",dot:false);live=false
        case .closedCase(.openLid):chip.set("Waiting for the lid",dot:false);live=false
        case .needsAccessibility:chip.set(connected ? "Connected":"Not connected",dot:connected);live=false
        case .ready:chip.set("Connected");live=false
        case .running:chip.set("Pointing",live:true);live=true
        case .paused:chip.set("Paused");live=false
        case .closedCase(.closeLid):chip.set("Connected");live=false
        case .closedCase(.turnUpright):chip.set("Connected");live=false
        case .closedCase(.holdStill):chip.set("Keep it still",dot:false);live=false
        case .closedCase(.calibrate):chip.set("Calibrating",dot:false);live=false
        case .closedCase(.recenter):chip.set("Recentering",dot:false);live=false
        }
        if showingPad != connected {
            showingPad=connected
            home.pad.isHidden = !connected;art.isHidden=connected
        }
        home.pad.live=live;home.pad.setAccessibilityLabel(live ? "Pointer preview, live":"Pointer preview")
        let screens=home.pointerSettings.screens
        home.pad.caption=screens.indices.contains(home.pointerSettings.screen) && screens.count>1 ? screens[home.pointerSettings.screen]:""
        // Centered rows live in holders; hiding the holder collapses the row.
        // The closed case stays connected through Pause until Disconnect.
        switch phase {
        case .running,.paused:recenter.isHidden=false;recalibrate.isHidden=false;disconnect.isHidden=false;secondary.superview?.isHidden=false
        case .ready:recenter.isHidden=true;recalibrate.isHidden=false;disconnect.isHidden=false;secondary.superview?.isHidden=false
        case .closedCase(.calibrate):recenter.isHidden=true;recalibrate.isHidden=true;disconnect.isHidden=false;secondary.superview?.isHidden=false
        // Saved edges might not suit a new grip, so all three dots stay one click away.
        case .closedCase(.recenter):recenter.isHidden=true;recalibrate.isHidden=false;disconnect.isHidden=false;secondary.superview?.isHidden=false
        default:secondary.superview?.isHidden=true
        }
    }

    func updateHold(_ progress:CGFloat?){art.holdProgress=progress}
    @objc private func primaryPressed(){home.onControl?()}
    @objc private func recenterPressed(){home.onRecenter?()}
    @objc private func recalibratePressed(){home.onLearnGrip?()}
    @objc private func disconnectPressed(){home.onDisconnect?()}
}

// MARK: - Settings

private final class SettingsPage:NSObject {
    unowned let home:AirPointerHome
    let view:NSScrollView
    private let screens=NSPopUpButton()
    private let pairs=NSPopUpButton()
    private let planes=NSPopUpButton()
    private let speed=NSSlider(value:1,minValue:0.4,maxValue:2.4,target:nil,action:nil)
    private let clickSound=InkSwitch()
    private let shortcutControl=PointerShortcutControl()
    private let speedValue=rkLabel("1.0×",13,.medium)

    init(home:AirPointerHome) {
        self.home=home
        let page=hmScrollPage(top:2);view=page.0
        super.init()
        let column=page.1
        // With no section tabs, this is the way back besides esc and ⌘1.
        let back=RemoteButton("Pointer",style:.tertiary,symbol:"chevron.left",height:28,target:self,action:#selector(backPressed))
        back.setAccessibilityLabel("Back to Pointer")
        column.addFull(hmRow([back]));column.gap(4)
        column.addFull(rkLabel("Settings",22,.bold))
        column.addHeader("AirPods")
        pairs.target=self;pairs.action=#selector(changed(_:));pairs.setAccessibilityLabel("AirPods to connect to")
        column.addFull(hmSettingRow("Connect to",nil,pairs))
        column.addHeader("Pointing")
        planes.addItems(withTitles:PointingPlane.allCases.map(\.title))
        planes.target=self;planes.action=#selector(changed(_:));planes.setAccessibilityLabel("How to point")
        column.addFull(hmSettingRow("How to point","Hold the case upright, swivel it flat on a desk, or tilt it flat like a joystick.",planes))
        column.addHeader("Screen")
        screens.target=self;screens.action=#selector(changed(_:));screens.setAccessibilityLabel("Screen to control")
        column.addFull(hmSettingRow("Point at",nil,screens))
        column.addHeader("Pointer speed")
        speed.target=self;speed.action=#selector(changed(_:));speed.isContinuous=true;speed.setAccessibilityLabel("Pointer speed")
        speedValue.font = .monospacedDigitSystemFont(ofSize:13,weight:.medium)
        speedValue.setContentHuggingPriority(.required,for:.horizontal)
        let ends=hmRow([rkLabel("Slower",12,.regular,.secondaryLabelColor)],trailing:[rkLabel("Faster",12,.regular,.secondaryLabelColor)])
        let track=rkVStack([speed,ends],spacing:2,align:.leading)
        ends.widthAnchor.constraint(equalTo:speed.widthAnchor).isActive=true
        speed.widthAnchor.constraint(equalTo:track.widthAnchor).isActive=true
        track.setHuggingPriority(.init(1),for:.horizontal)
        let slider=rkHStack([track,speedValue],spacing:14);slider.alignment = .top
        column.addFull(slider)
        column.addHeader("Tap to click")
        clickSound.setAccessibilityLabel("Click sound");clickSound.onChange={[weak self] _ in self?.changed(nil)}
        column.addFull(hmSettingRow("Click sound","Plays on this Mac when a tap on the case clicks.",clickSound))
        let teachTap=RemoteButton("Teach Tap…",style:.secondary,height:32,target:self,action:#selector(teachTap))
        column.addFull(hmSettingRow("Your tap","Tap the case three times so AirPointer knows how your taps feel.",teachTap))
        column.addHeader("Calibration")
        let recalibrate=RemoteButton("Recalibrate…",style:.secondary,height:32,target:self,action:#selector(recalibrate))
        column.addFull(hmSettingRow("Your screen","Point at three dots so AirPointer knows where your screen is.",recalibrate))
        column.addHeader("Shortcut")
        column.addFull(hmSettingRow("Turn the pointer on or off",detail:shortcutControl.note,shortcutControl))
        column.addFull(RemoteRule())
        let setup=RemoteButton("Run Setup Again…",style:.secondary,height:32,target:self,action:#selector(setup))
        column.addFull(hmSettingRow("Setup","Walk through connecting, permissions and calibration again.",setup))
        apply()
    }

    func apply() {
        let state=home.pointerSettings
        if screens.itemTitles != state.screens{screens.removeAllItems();screens.addItems(withTitles:state.screens)}
        if screens.itemArray.indices.contains(state.screen){screens.selectItem(at:state.screen)}
        screens.isEnabled=state.screens.count>1
        let pairTitles=state.pairs.isEmpty ? ["No AirPods Pro found"]:state.pair<0 ? ["Choose your AirPods"]+state.pairs:state.pairs
        if pairs.itemTitles != pairTitles{pairs.removeAllItems();pairs.addItems(withTitles:pairTitles)}
        pairs.selectItem(at:max(0,state.pair));pairs.isEnabled=state.pairs.count>1
        if let planeIndex=PointingPlane.allCases.firstIndex(of:state.plane){planes.selectItem(at:planeIndex)}
        speed.doubleValue=state.speed
        rkSetText(speedValue,String(format:"%.1f×",state.speed))
        speed.setAccessibilityValueDescription(String(format:"%.1f times normal speed",state.speed))
        clickSound.setOn(state.clickSound,animated:false)
    }
    @objc private func changed(_ sender:Any?) {
        var value=home.pointerSettings
        value.screen=max(0,screens.indexOfSelectedItem);value.speed=(speed.doubleValue*10).rounded()/10;value.clickSound=clickSound.isOn
        let planeIndex=planes.indexOfSelectedItem
        if PointingPlane.allCases.indices.contains(planeIndex){value.plane=PointingPlane.allCases[planeIndex]}
        if !value.pairs.isEmpty{value.pair=pairs.indexOfSelectedItem-(value.pair<0 ? 1:0)}
        home.changePointerSettings(value)
    }
    @objc private func backPressed(){home.present(.pointer)}
    @objc private func recalibrate(){home.onLearnGrip?()}
    @objc private func setup(){home.onSetup?()}
    @objc private func teachTap(){home.onTeachTap?()}
}
