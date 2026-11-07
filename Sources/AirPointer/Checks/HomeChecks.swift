import AppKit
import Carbon

func runHomeChecks()throws {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.regular);NSApp.finishLaunching()
    func require(_ value:Bool,_ message:String)throws{if !value{throw LessonError.message(message)}}
    func descendants(_ view:NSView)->[NSView]{[view]+view.subviews.flatMap(descendants)}
    func visible(_ view:NSView)->[NSView]{view.isHidden ? []:[view]+view.subviews.flatMap(visible)}
    let home=AirPointerHome()
    defer{home.window.orderOut(nil)}
    func content()->[NSView]{home.window.contentView!.layoutSubtreeIfNeeded();return visible(home.window.contentView!)}
    func words()->String{content().compactMap{$0 as? NSTextField}.map(\.stringValue).joined(separator:" ")}
    func primary()->RemoteButton{content().compactMap{$0 as? RemoteButton}.first{$0.style == .primary}!}
    // The closed case is the only pointer: no microphone and no Gestures or Practice to find.
    func retired(_ views:[NSView],_ surface:String)throws{
        let text=views.flatMap{view->[String] in
            var parts=[view.accessibilityLabel() ?? "",view.toolTip ?? "",(view as? NSTextField)?.stringValue ?? "",(view as? NSButton)?.title ?? ""]
            if let choice=view as? NSSegmentedControl{parts+=(0..<choice.segmentCount).compactMap{choice.label(forSegment:$0)}}
            return parts
        }.joined(separator:" · ")
        // The tap's click sound is the one sound the pointer makes.
        for word in ["pointer only","\\bmic(rophone)?\\b","\\bgestures?\\b","\\bpractice\\b","(?<!click )\\bsound\\b"] {
            try require(text.range(of:word,options:[.regularExpression,.caseInsensitive])==nil,"\(surface) still says “\(word)”")
        }
        try require(!views.contains{$0 is NSSegmentedControl || $0.accessibilityRole() == .radioGroup},"\(surface) still offers a choice of modes or sections")
    }
    if #available(macOS 15,*){try require(home.window.toolbar?.allowsDisplayModeCustomization==false && home.window.toolbar?.displayMode == .iconOnly,"The toolbar should stay icon-only, with no menu to change it")}
    home.updateControl(phase:.ready,inputsReady:true)
    home.show()

    // One primary action on the Pointer page, retitled by phase.
    var controlPresses=0;home.onControl={controlPresses+=1}
    try require(primary().title=="Start Pointing","Ready did not offer Start Pointing")
    primary().performClick(nil)
    try require(controlPresses==1,"The pointer page's primary action did not reach the app")
    for (phase,title) in [(HomeControlPhase.running,"Pause"),(.paused("Paused"),"Resume"),(.needsInputs,"Connect AirPods")] {
        home.updateControl(phase:phase,inputsReady:true)
        try require(primary().title==title,"\(phase) did not expose \(title)")
        try require(content().compactMap{$0 as? RemoteButton}.filter{$0.style == .primary}.count==1,"\(phase) showed more than one primary action")
    }
    home.updateControl(phase:.running,inputsReady:true)
    try require(primary().hint==PointerShortcut.current.label,"Pause did not show its global shortcut")
    home.updateControl(phase:.ready,inputsReady:true)


    // fn ⌃ presses once per press: not while held, not with another modifier, and again after letting go.
    var chord=NotchChord()
    try require(chord.update([.function,.control]) && !chord.update([.function,.control]) && !chord.update([.function]),"fn ⌃ pressed more than once while held")
    try require(chord.update([.control,.function]) && !chord.update([]) && !chord.update([.function,.control,.command]) && !chord.update([]),"fn ⌃ with ⌘ still pressed")
    try require(!chord.update([.control]) && chord.update([.control,.function]),"Control, then fn, didn’t press")
    // Another chord works the same way, and a shortcut can be any fn chord or a key with ⌃ or ⌥. Looser ones are refused.
    var otherChord=NotchChord([.function,.option])
    try require(otherChord.update([.function,.option]) && !otherChord.update([.function,.option]) && !otherChord.update([]) && !otherChord.update([.function,.control]),"A changed chord pressed on the wrong keys")
    let optionP=PointerShortcut(modifiers:[.control,.option],key:35,keyName:"P")
    try require(PointerShortcut.fnControl.label=="fn ⌃" && PointerShortcut.fnControl.spoken=="fn Control" && optionP.label=="⌃⌥P" && optionP.spoken=="Control Option P","The shortcut is written wrong")
    try require(optionP.carbonModifiers==UInt32(controlKey|optionKey),"The shortcut registers the wrong modifiers")
    func accepted(_ result:PointerShortcut.Recorded)->PointerShortcut?{if case .shortcut(let value)=result{return value};return nil}
    try require(accepted(PointerShortcut.recorded([.function,.control]))==PointerShortcut.fnControl && accepted(PointerShortcut.recorded([.control,.option],key:35,name:"P"))==optionP,"A good shortcut was refused")
    let looseShortcuts:[(NSEvent.ModifierFlags,UInt16?)]=[(.function,nil),(.control,nil),([.control,.option],nil),([.function,.control],35),(.command,35),([],35),(.shift,35)]
    for (flags,key) in looseShortcuts {
        try require(accepted(PointerShortcut.recorded(flags,key:key,name:"P"))==nil,"A loose shortcut was allowed: \(flags) \(String(describing:key))")
    }
    try require(accepted(PointerShortcut.recorded([.function,.control],key:123,name:"←",special:true))?.modifiers==[.control],"An arrow key kept macOS’s fn flag")
    // Saving and loading use a throwaway store, so these checks never touch the real shortcut.
    let shortcutStore=UserDefaults(suiteName:"airpointer.check-shortcut")!
    shortcutStore.removePersistentDomain(forName:"airpointer.check-shortcut")
    defer{shortcutStore.removePersistentDomain(forName:"airpointer.check-shortcut")}
    try require(PointerShortcut.load(from:shortcutStore) == .fnControl,"The first shortcut should be fn ⌃")
    optionP.save(to:shortcutStore)
    try require(PointerShortcut.load(from:shortcutStore)==optionP,"A changed shortcut wasn’t kept")
    PointerShortcut(modifiers:[.command],key:35,keyName:"P").save(to:shortcutStore)
    try require(PointerShortcut.load(from:shortcutStore) == .fnControl,"A bad saved shortcut should fall back to fn ⌃")
    // The cursor only ever grows, and goes back only if it's still the size set here.
    try require(CursorSize.grown(from:1)==CursorSize.pointing && CursorSize.grown(from:1.5)==CursorSize.pointing && CursorSize.grown(from:2)==nil && CursorSize.grown(from:3)==nil,"The cursor size grew wrongly")
    try require(CursorSize.restored(1.5,current:CursorSize.pointing)==1.5 && CursorSize.restored(1.5,current:3)==nil,"The cursor size went back wrongly")
    // The ring only shows while the case is set down.
    let ringArt=CaseStepView()
    try require(ringArt.holdProgress==nil,"The case art starts with a ring")
    let ringSetup=SetupAssistant()
    ringSetup.go(to:2);ringSetup.update(SetupState(link:.holdStill,accessibilityTrusted:true,holdProgress:0.5))
    func setupRing()->CGFloat?{descendants(ringSetup.window.contentView!).compactMap{$0 as? CaseStepView}.compactMap(\.holdProgress).first}
    try require(setupRing()==0.5,"Setup didn’t show the hold ring")
    ringSetup.update(SetupState(link:.connected,accessibilityTrusted:true))
    try require(setupRing()==nil,"Setup kept the hold ring")
    // Every connect step has art and words in the notch, and the steps fill in order.
    let notchStages:[ClosedCaseStage]=[.openLid,.connecting,.closeLid,.holding,.settling,.calibrating]
    let notchContents=notchStages.compactMap{NotchContent.connecting($0,preparing:false)}
    try require(notchContents.count==notchStages.count && notchContents.map(\.progress)==[0,0,1,2,2,2] && NotchContent.pointing.progress==3 && NotchContent.pointing.live,"The notch is missing a connect step")
    try require(notchContents.map(\.step)==[.opening,.open,.close,.closed,.turn,.point] && NotchContent.connecting(.connecting,preparing:true)?.step == .opening,"The notch shows the wrong case art for a step")
    try require(NotchContent.lost.step == .opening && NotchContent.lost.title != NotchContent.connecting(.openLid,preparing:false)?.title,"The notch doesn't say the AirPods were lost")
    try require(NotchContent.connecting(.pointing,preparing:false)==nil && NotchContent.connecting(.off,preparing:false)==nil,"The notch kept a connect step after connecting")
    // Settings speak in plain terms and bind each control on its own.
    home.updatePointerSettings(PointerSettingsState(screens:["Built-in display","Projector"],screen:0,speed:1))
    var changedSettings:PointerSettingsState?
    home.onPointerSettingsChange={changedSettings=$0}
    home.selectSettings()
    try require(home.window.attachedSheet==nil,"Settings opened an overlay")
    let settingsWords=words()
    try require(settingsWords.lowercased().contains("pointer speed") && !settingsWords.contains("Yaw") && !settingsWords.contains("Pitch") && !settingsWords.contains("Reverse"),"Settings still expose sensor terminology")
    try require(!content().compactMap{$0 as? NSPopUpButton}.contains{$0.itemTitles.contains{$0.hasPrefix("Point left")}},"Settings still ask the user to choose axis directions")
    let slider=content().compactMap{$0 as? NSSlider}.first!
    slider.doubleValue=1.6;NSApp.sendAction(slider.action!,to:slider.target,from:slider)
    try require(changedSettings?.speed==1.6,"The speed slider did not preserve its value")
    try retired(content(),"Settings")
    try require(content().compactMap{$0 as? RemoteButton}.contains{$0.title=="Recalibrate…"},"Settings lost the way to recalibrate")
    // A tap's click sound is on by default and has its own switch.
    let clickSwitch=content().compactMap{$0 as? InkSwitch}.first{$0.accessibilityLabel()=="Click sound"}
    try require(settingsWords.contains("Click sound") && clickSwitch?.isOn==true,"Settings lost the click sound switch, or it starts off")
    clickSwitch!.setOn(false,animated:false);clickSwitch!.onChange?(false)
    try require(changedSettings?.clickSound==false && changedSettings?.speed==1.6,"The click sound switch did not change only the click sound")
    try require(TapClickSound.shared.loaded,"The app bundle has no tap click sound")
    try require(NotchShimmerSound.shared.loaded,"The app bundle has no notch shimmer")
    try require(Bundle.main.url(forResource:"LICENSE-cuelume",withExtension:"txt") != nil,"The app bundle has no license for its sounds")
    let gear=home.window.toolbar?.items.first{$0.label=="Settings"}
    try require(gear?.toolTip?.hasPrefix("Settings")==true,"Settings is not a single toolbar button")
    // Pointer and Settings are the only pages, so the toolbar is just the gear: no section tabs.
    try require(home.window.toolbar!.items.filter{$0.itemIdentifier != .flexibleSpace}.map(\.label)==["Settings"] && home.window.toolbar!.items.allSatisfy{$0.view==nil},"The toolbar still has section tabs")

    // Without tabs, Settings has its own way back; the pointer never waits for the microphone.
    content().compactMap{$0 as? RemoteButton}.first{$0.title=="Pointer" && $0.symbolName=="chevron.left"}!.performClick(nil)
    try require(primary().title=="Resume" || primary().title=="Start Pointing","Settings had no way back to the pointer")
    home.selectSettings();home.window.onEscape?()
    try require(primary().title=="Resume" || primary().title=="Start Pointing","Esc did not leave Settings")
    // Every step that offers Cancel (esc) answers to it.
    for phase in [HomeControlPhase.running,.connecting,.closedCase(.openLid),.closedCase(.turnUpright),.closedCase(.holdStill)] {
        home.updateControl(phase:phase,inputsReady:false)
        let before=controlPresses;home.window.onEscape?()
        try require(controlPresses==before+1,"Esc did nothing during \(phase)")
    }
    home.updateControl(phase:.connecting,inputsReady:false)
    try require(words().contains("Keep the lid open for a moment.") && !words().contains("sound"),"The pointer’s connection still waited for audio")
    for phase in [HomeControlPhase.needsInputs,.connecting,.needsAccessibility,.ready,.running,.paused("Paused"),.closedCase(.openLid),.closedCase(.closeLid),.closedCase(.turnUpright),.closedCase(.holdStill),.closedCase(.calibrate),.closedCase(.recenter)] {
        home.updateControl(phase:phase,inputsReady:true)
        try retired(content(),"The Pointer page (\(phase))")
    }
    home.updateControl(phase:.ready,inputsReady:true)
    try require(primary().hint==PointerShortcut.current.label,"Start Pointing did not show the shortcut")
    home.updateControl(phase:.paused("Paused"),inputsReady:true)
    try require(primary().hint==PointerShortcut.current.label,"Resume did not show the shortcut")
    try require(!content().contains{$0.accessibilityLabel()?.contains("to pause from any app")==true},"The Pointer page kept its shortcut line")
    home.updateControl(phase:.ready,inputsReady:true)

    // The closed case connects on the same page: close the lid, turn it upright, then the dots.
    func stepArt()->CaseStepView?{content().compactMap{$0 as? CaseStepView}.first}
    for (phase,title,heading,step) in [(HomeControlPhase.closedCase(.closeLid),"Lid Closed","Close the lid",CaseStep.close),(.closedCase(.turnUpright),"Cancel","Turn it upright",.turn),(.closedCase(.holdStill),"Cancel","Set it down",.closed),(.needsInputs,"Connect AirPods","Connect your AirPods",.closed),(.needsAccessibility,"Allow","Allow control",.closed)] {
        home.updateControl(phase:phase,inputsReady:false)
        try require(primary().title==title && words().contains(heading) && stepArt()?.step==step,"\(phase) did not show \(heading), \(title) and its picture")
        try require(content().compactMap{$0 as? RemoteButton}.filter{$0.style == .primary}.count==1,"\(phase) showed more than one primary action")
    }
    home.updateControl(phase:.closedCase(.closeLid),inputsReady:false)
    try require(primary().keyEquivalent=="\r","Lid Closed did not answer Return")
    // Connect with the lid shut waits for it to open, and esc cancels the wait.
    home.updateControl(phase:.closedCase(.openLid),inputsReady:false)
    try require(primary().title=="Cancel" && primary().keyEquivalent=="\u{1b}" && words().contains("Open the lid") && stepArt()?.step == .opening,"Waiting for the lid did not show Open the lid with an esc Cancel")
    home.updateControl(phase:.closedCase(.calibrate),inputsReady:true)
    try require(primary().title=="Start Calibration" && primary().keyEquivalent=="" && stepArt()==nil,"Calibration kept the case picture or the Return shortcut")
    // Saved edges leave one dot, with all three still one click away.
    home.updateControl(phase:.closedCase(.recenter),inputsReady:true)
    try require(primary().title=="Recenter" && words().contains("Point at the center") && content().compactMap({$0 as? RemoteButton}).contains{$0.title=="Recalibrate…"},
                "Recentering on saved edges hid the way back to all three dots")
    // Pause keeps the closed case connected; Disconnect is its own, quieter action.
    func disconnectButton()->RemoteButton?{content().compactMap{$0 as? RemoteButton}.first{$0.title=="Disconnect"}}
    home.updateControl(phase:.paused("Paused"),inputsReady:true)
    try require(primary().title=="Resume" && words().contains("Resume when you’re ready.") && stepArt()==nil,"A connected pause looked like a lost connection")
    var disconnects=0;home.onDisconnect={disconnects+=1}
    try require(disconnectButton()?.style == .tertiary,"A connected pause offered no Disconnect, or made it primary")
    disconnectButton()?.performClick(nil)
    try require(disconnects==1,"Disconnect did not reach the app")
    for phase in [HomeControlPhase.ready,.running,.closedCase(.calibrate),.closedCase(.recenter)] {
        home.updateControl(phase:phase,inputsReady:true)
        try require(disconnectButton() != nil,"\(phase) hid Disconnect while the case was connected")
    }
    for phase in [HomeControlPhase.needsInputs,.connecting,.closedCase(.closeLid)] {
        home.updateControl(phase:phase,inputsReady:false)
        try require(disconnectButton()==nil,"\(phase) offered Disconnect before there was a connection")
    }
    home.updateControl(phase:.running,inputsReady:true)
    try require(words().contains("Aim with the case. Tap its front to click."),"Pointing did not say how to aim and click")
    home.updateControl(phase:.paused("Your AirPods disconnected."),inputsReady:true)
    try require(words().contains("Your AirPods disconnected."),"A pause reason was not shown")

    // Setup is Allow, Style, Connect, Calibrate and Tap. Tap listens by itself, can be skipped, and finishes it.
    let assistant=SetupAssistant();defer{assistant.window.orderOut(nil)}
    func setupViews()->[NSView]{assistant.window.contentView!.layoutSubtreeIfNeeded();return visible(assistant.window.contentView!)}
    for (link,step) in [(SetupLink.idle,0),(.idle,1),(.idle,2),(.openLid,2),(.connecting,2),(.closeLid,2),(.turnUpright,2),(.holdStill,2),(.connected,2),(.connected,3)] {
        assistant.update(SetupState(link:link,accessibilityTrusted:step>0));assistant.go(to:step)
        try retired(descendants(assistant.window.contentView!),"Setup (\(link), step \(step+1))")
        try require(setupViews().compactMap{$0 as? RemoteButton}.filter{$0.style == .primary}.count<=1,"Setup step \(step+1) showed more than one primary action")
    }
    assistant.update(SetupState());assistant.go(to:0)
    try require(setupViews().contains{$0.accessibilityLabel()?.hasPrefix("Step 1 of 5, Allow") == true},"Setup should start by allowing control")
    // The guide sits on System Settings' largest ordinary window, above its + and − buttons and clear of its sidebar.
    func window(_ owner:Int,_ layer:Int,_ x:Int,_ y:Int,_ width:Int,_ height:Int)->[String:Any]{
        [kCGWindowOwnerPID as String:owner,kCGWindowLayer as String:layer,kCGWindowBounds as String:["X":x,"Y":y,"Width":width,"Height":height]]
    }
    let settingsWindows=[window(7,0,0,0,2000,2000),window(9,25,0,0,1500,1500),window(9,0,0,0,100,100),window(9,0,100,50,720,600)]
    let settingsFrame=AccessibilityGuide.settingsWindow(in:settingsWindows,owner:9,primaryHeight:1000)
    try require(settingsFrame==NSRect(x:100,y:350,width:720,height:600),"The guide should find System Settings’ window, in AppKit’s coordinates")
    try require(AccessibilityGuide.settingsWindow(in:settingsWindows,owner:3,primaryHeight:1000)==nil,"The guide should stay hidden with no window to follow")
    let guide=AccessibilityGuide.placement(settingsFrame!)
    try require(settingsFrame!.contains(guide) && guide.minX>=settingsFrame!.minX+260 && guide.minY>=settingsFrame!.minY+32,"The guide should sit above the + and − buttons, clear of the sidebar")
    let allowed=SetupState(accessibilityTrusted:true),linked=SetupState(link:.connected,accessibilityTrusted:true)
    let aiming=SetupState(link:.connected,accessibilityTrusted:true,calibrating:true),aimed=SetupState(link:.connected,accessibilityTrusted:true,calibrated:true)
    try require(SetupAssistant.following(0,from:SetupState(),to:allowed)==1,"Allowing control should lead on to Style")
    try require(SetupAssistant.following(2,from:allowed,to:linked)==3,"Connecting should lead on to Calibrate")
    try require(SetupAssistant.following(2,from:allowed,to:aimed)==4,"Connecting with saved edges should lead on to the tap")
    try require(SetupAssistant.following(3,from:aiming,to:aimed)==4,"Calibrating should lead on to the tap")
    try require(SetupAssistant.following(0,from:allowed,to:allowed)==nil && SetupAssistant.following(2,from:linked,to:linked)==nil && SetupAssistant.following(3,from:aimed,to:aimed)==nil && SetupAssistant.following(4,from:linked,to:aimed)==nil,"Coming back to a finished step shouldn’t move on by itself")
    var finished=0,listening=0,stoppedListening=0,choosing=0,chosenPlane:PointingPlane?
    assistant.onFinish={finished+=1};assistant.onLearnTap={listening+=1};assistant.onStopLearningTap={stoppedListening+=1};assistant.onChooseAirPods={choosing+=1}
    assistant.onChoosePlane={chosenPlane=$0}
    func setupSays(_ words:String)->Bool{setupViews().contains{($0 as? NSTextField)?.stringValue.contains(words)==true}}
    assistant.go(to:1);assistant.update(SetupState(link:.idle,accessibilityTrusted:true))
    try require(setupSays("Choose how to point"),"Setup’s Style step should explain the pointing styles")
    setupViews().compactMap{$0 as? RemoteButton}.first{$0.title==PointingPlane.flatTilt.shortTitle}?.performClick(nil)
    try require(chosenPlane == .flatTilt && setupSays(PointingPlane.flatTilt.subtitle),"Picking a style in setup should update the plane and its description")
    assistant.go(to:2);assistant.update(SetupState(link:.idle,accessibilityTrusted:true))
    try require(setupSays("diagnostic data") && setupSays("during a call"),"Setup should say what connecting does before anyone connects")
    assistant.update(SetupState(link:.idle,problem:ClosedCaseAirPods.Choice.several.failure,accessibilityTrusted:true))
    try require(setupSays("diagnostic data") && setupSays("Choose which to use"),"A problem shouldn’t hide what connecting does")
    let choose=setupViews().compactMap{$0 as? RemoteButton}.first{$0.style == .primary}
    try require(choose?.title=="Choose AirPods…","Several pairs should offer a choice right in setup")
    choose?.performClick(nil)
    try require(choosing==1,"The choice should open from setup’s button")
    assistant.update(SetupState(link:.connected,accessibilityTrusted:true,calibrated:true));assistant.go(to:3)
    try require(setupViews().compactMap{$0 as? RemoteButton}.first{$0.style == .primary}?.title=="Continue","Calibrate should lead on to the tap")
    assistant.go(to:4)
    try require(listening==1 && !setupViews().compactMap{$0 as? RemoteButton}.filter{!$0.isHidden && $0.title=="Skip for Now"}.isEmpty,"The tap step should listen by itself and offer a skip")
    assistant.update(SetupState(link:.idle,accessibilityTrusted:true,calibrated:true))
    try require(stoppedListening==1,"Losing the case on the tap step should stop listening")
    assistant.update(SetupState(link:.connected,accessibilityTrusted:true,calibrated:true))
    try require(listening==2,"Getting the case back on the tap step should listen again")
    assistant.go(to:3)
    try require(stoppedListening==2,"Leaving the tap step should stop listening")
    assistant.update(SetupState(link:.connected,accessibilityTrusted:true,calibrated:true,taps:SetupTaps(heard:3,learned:true)));assistant.go(to:9)
    let finish=setupViews().compactMap{$0 as? RemoteButton}.first{$0.style == .primary}
    try require(assistant.step==4 && listening==2 && finish?.title=="Finish" && setupViews().contains{$0.accessibilityLabel()?.hasPrefix("Step 5 of 5") == true},"Setup went past the tap step, or the tap step didn’t finish it")
    try retired(setupViews(),"Setup’s last step")
    finish?.performClick(nil)
    try require(finished==1,"Finish did not end setup")
    // Finish and Skip for Now both wait for Accessibility, since the pointer can't move without it.
    assistant.update(SetupState(link:.connected,calibrated:true,taps:SetupTaps(heard:3,learned:true)));assistant.go(to:4)
    setupViews().compactMap{$0 as? RemoteButton}.first{$0.style == .primary}?.performClick(nil)
    try require(finished==1 && assistant.step==0,"Setup finished without Accessibility")

    // Nobody connects before setup's Connect step has said what a session does, and each kind of ending says why somewhere.
    let defaults=UserDefaults.standard,firstRunKeys=["setupComplete","connectEffectsSeen"]
    let firstRunPrior=Dictionary(uniqueKeysWithValues:firstRunKeys.map{($0,defaults.object(forKey:$0))})
    defer{for key in firstRunKeys{if let value=firstRunPrior[key]{defaults.set(value,forKey:key)}else{defaults.removeObject(forKey:key)}}}
    for key in firstRunKeys{defaults.removeObject(forKey:key)}
    let app=App();defer{app.setup?.window.orderOut(nil);app.home?.window.orderOut(nil)}
    try require(app.showConnectEffectsFirst() && app.setup?.window.isVisible == true && app.setup?.step == (AXIsProcessTrusted() ? 2:0),"A first connection should open setup’s Connect step")
    func appWindow(_ text:String,on window:NSWindow?)->Bool{descendants(window!.contentView!).contains{($0 as? NSTextField)?.stringValue.contains(text)==true}}
    try require(appWindow("diagnostic data",on:app.setup?.window) || !AXIsProcessTrusted(),"The first connection should show what a session does")
    app.reportEnded("Reason during setup.",fromNotch:false)
    try require(app.home == nil,"Setup says why on its own step, so the window should stay closed")
    app.setup?.window.close()
    app.reportEnded("Reason in the notch.",fromNotch:true)
    try require(app.home == nil,"The notch says why for its own sessions, so the window should stay closed")
    app.reportEnded("Reason for the window.",fromNotch:false)
    try require(app.home?.window.isVisible == true && appWindow("Reason for the window.",on:app.home?.window),"A closed window should open to say why the connection ended")
    defaults.set(true,forKey:"connectEffectsSeen")
    try require(!app.showConnectEffectsFirst() && app.setup == nil,"Someone who pressed Connect shouldn’t be sent back to setup")
    defaults.removeObject(forKey:"connectEffectsSeen");defaults.set(true,forKey:"setupComplete")
    try require(!app.showConnectEffectsFirst() && app.setup == nil,"Finished setup shouldn’t be reopened to connect")

    // The notch shows every failure in full.
    let ending=NotchSurface();ending.frame=NSRect(x:0,y:0,width:360,height:NotchFlow.body+32)
    for reason in (0...60).flatMap({[ClosedCaseAirPods.helperFailure(Int32($0),stopping:false),ClosedCaseAirPods.restoreFailure(Int32($0))]}).compactMap({$0}) {
        ending.show(.ended(reason),fade:false);ending.layoutSubtreeIfNeeded()
        let shown=descendants(ending).compactMap{$0 as? NSTextField}.first{$0.stringValue==reason}
        let whole=rkWrap(reason,12);whole.maximumNumberOfLines=0
        let needed=whole.cell!.cellSize(forBounds:NSRect(x:0,y:0,width:shown?.frame.width ?? 0,height:400)).height
        try require(shown != nil && ceil(needed)<=shown!.frame.height,"The notch cuts off: \(reason)")
    }

    // The menu-bar popover: aim pad, Recenter, Pause and speed, then its rows. No mode and nothing to teach.
    let popover=MenuBarContentController()
    popover.apply(MenuBarState(status:.live,detail:"Press fn ⌃ to pause from any app",speed:1.2,canDisconnect:true))
    try retired(descendants(popover.view),"The menu-bar popover")
    try require(descendants(popover.view).compactMap{$0 as? NSButton}.contains{$0.title=="Open AirPointer"},"The menu-bar popover lost its rows")

    if let index=CommandLine.arguments.firstIndex(of:"--preview-directory"),CommandLine.arguments.indices.contains(index+1){
        let folder=URL(fileURLWithPath:CommandLine.arguments[index+1]);try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        // Renders the whole window frame so the toolbar is part of the picture.
        func render(_ name:String,from sample:AirPointerHome?=nil,view explicitView:NSView?=nil)throws{
            let window=(sample ?? home).window
            guard let view=explicitView ?? window.contentView?.superview else{return}
            window.contentView?.layoutSubtreeIfNeeded();view.display();RunLoop.main.run(until:Date().addingTimeInterval(0.05))
            guard let bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds) else{return}
            view.cacheDisplay(in:view.bounds,to:bitmap)
            let image=NSImage(size:view.bounds.size);image.lockFocus();HomePalette.canvas.setFill();view.bounds.fill();bitmap.draw(in:view.bounds);image.unlockFocus()
            if let tiff=image.tiffRepresentation,let flattened=NSBitmapImageRep(data:tiff){try flattened.representation(using:.png,properties:[:])?.write(to:folder.appendingPathComponent(name+".png"))}
        }
        let sample=AirPointerHome();sample.window.appearance=NSAppearance(named:.aqua)
        sample.updatePointerSettings(PointerSettingsState(screens:["Built-in Retina Display"],screen:0,speed:1))
        sample.show()
        // Pinned past the opening, so the open case shows its lid up.
        for art in descendants(sample.window.contentView!).compactMap({$0 as? CaseStepView}){art.pinnedTime=2}
        for (name,phase,inputs) in [("pointer-connect",HomeControlPhase.needsInputs,false),("pointer-connecting",.connecting,false),("pointer-permission",.needsAccessibility,true),("pointer-ready",.ready,true),("pointer-running",.running,true),("pointer-paused",.paused("Your AirPods disconnected. Open the case to reconnect. If it keeps happening, turn off Automatic Ear Detection."),true)] {
            sample.updateControl(phase:phase,inputsReady:inputs)
            sample.pad.point=CGPoint(x:0.62,y:0.4)
            try render(name,from:sample)
        }
        sample.window.appearance=NSAppearance(named:.darkAqua);try render("pointer-running-dark",from:sample)
        sample.window.appearance=NSAppearance(named:.aqua)
        // Each closed-case connect step, pinned mid-motion.
        for (name,phase,time) in [("pointer-closed-connect",HomeControlPhase.needsInputs,0.0),("pointer-close-lid",.closedCase(.closeLid),1.2),("pointer-turn",.closedCase(.turnUpright),1.25),("pointer-hold-still",.closedCase(.holdStill),0),("pointer-calibrate",.closedCase(.calibrate),0),("pointer-closed-paused",.paused("Paused"),0)] {
            sample.updateControl(phase:phase,inputsReady:false)
            for art in descendants(sample.window.contentView!).compactMap({$0 as? CaseStepView}){art.pinnedTime=time}
            try render(name,from:sample)
        }
        sample.updateControl(phase:.closedCase(.holdStill),inputsReady:false)
        sample.updateHold(0.62);try render("pointer-hold-ring",from:sample);sample.updateHold(nil)
        sample.updateControl(phase:.closedCase(.closeLid),inputsReady:false)
        for art in descendants(sample.window.contentView!).compactMap({$0 as? CaseStepView}){art.pinnedTime=1.2}
        sample.window.appearance=NSAppearance(named:.darkAqua);try render("pointer-close-lid-dark",from:sample)
        sample.window.appearance=NSAppearance(named:.aqua)
        sample.setNotice("Open the lid, briefly lift and reseat one earbud, then reconnect.");try render("notice",from:sample);sample.setNotice(nil)
        // Recenter, Recalibrate… and Disconnect share one row, even at the minimum width.
        let size=sample.window.frame.size
        sample.window.setContentSize(sample.window.contentMinSize)
        sample.updateControl(phase:.paused("Paused"),inputsReady:true)
        try render("pointer-closed-paused-min",from:sample)
        sample.window.setFrame(NSRect(origin:sample.window.frame.origin,size:size),display:false)
        sample.updateControl(phase:.ready,inputsReady:true)
        sample.setNotice("The case lost its connection. Connect again, then open the lid.")
        try render("pointer-notice",from:sample);sample.setNotice(nil)
        // Pointer and Settings are the only pages.
        sample.updatePointerSettings(PointerSettingsState(screens:["Built-in Retina Display","Projector"],screen:1,speed:1.4))
        sample.selectSettings();try render("settings",from:sample)
        sample.window.appearance=NSAppearance(named:.darkAqua);try render("settings-dark",from:sample)
        sample.window.appearance=NSAppearance(named:.aqua)
        sample.window.orderOut(nil)
        // The other redesigned surfaces, rendered from the real bundle.
        func snapshot(_ name:String,_ view:NSView,_ appearance:NSAppearance.Name? = .aqua)throws{
            if let appearance{view.appearance=NSAppearance(named:appearance)}
            view.layoutSubtreeIfNeeded();view.display()
            guard let bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds) else{return}
            view.cacheDisplay(in:view.bounds,to:bitmap)
            // Flatten onto the canvas so transparent areas don't come out black.
            let image=NSImage(size:view.bounds.size);image.lockFocus()
            view.effectiveAppearance.performAsCurrentDrawingAppearance{HomePalette.canvas.setFill();view.bounds.fill()}
            bitmap.draw(in:view.bounds);image.unlockFocus()
            if let tiff=image.tiffRepresentation,let flattened=NSBitmapImageRep(data:tiff){try flattened.representation(using:.png,properties:[:])?.write(to:folder.appendingPathComponent(name+".png"))}
        }
        // Layer-backed surfaces only draw inside a window, so render the frame view.
        func windowSnapshot(_ name:String,_ window:NSWindow,_ appearance:NSAppearance.Name)throws{
            window.appearance=NSAppearance(named:appearance);window.orderFront(nil)
            defer{window.orderOut(nil)}
            try snapshot(name,window.contentView!.superview!,nil)
        }
        let setup=SetupAssistant()
        for art in descendants(setup.window.contentView!).compactMap({$0 as? CaseStepView}){art.pinnedTime=1.2}
        setup.update(SetupState(link:.idle));setup.go(to:0);try windowSnapshot("setup-allow",setup.window,.aqua)
        try windowSnapshot("accessibility-guide",AccessibilityGuide.previewWindow(),.aqua)
        try windowSnapshot("accessibility-guide-dark",AccessibilityGuide.previewWindow(),.darkAqua)
        setup.go(to:1);try windowSnapshot("setup-style",setup.window,.aqua)
        setup.go(to:2);try windowSnapshot("setup-connect",setup.window,.aqua)
        setup.update(SetupState(link:.idle,problem:ClosedCaseAirPods.helperFailure(30,stopping:false)));try windowSnapshot("setup-connect-problem",setup.window,.aqua)
        setup.update(SetupState(link:.closeLid));try windowSnapshot("setup-close-lid",setup.window,.darkAqua)
        setup.update(SetupState(link:.turnUpright));try windowSnapshot("setup-turn",setup.window,.aqua)
        setup.update(SetupState(link:.holdStill,holdProgress:0.62));try windowSnapshot("setup-hold-still",setup.window,.aqua)
        setup.update(SetupState(link:.connected));try windowSnapshot("setup-connected",setup.window,.aqua)
        // The two moving steps as contact sheets, to check timing and direction.
        for (name,step,times) in [("case-steps-opening",CaseStep.opening,[0.0,0.8,1.0,1.2,1.4,1.6,3.2]),("case-steps-open",.open,[0.0,0.4,0.6,0.8,1.0,1.2,2.0]),("case-steps-close",.close,[0.0,0.8,1.0,1.2,1.4,1.6,3.2]),("case-steps-turn",.turn,[0.0,0.9,1.1,1.3,1.5,1.7,3.4])] {
            let row=NSView(frame:NSRect(x:0,y:0,width:CGFloat(times.count)*200,height:200))
            for (index,time) in times.enumerated() {
                let art=CaseStepView();art.translatesAutoresizingMaskIntoConstraints=true
                art.frame=NSRect(x:CGFloat(index)*200,y:0,width:200,height:200);art.step=step;art.pinnedTime=time;row.addSubview(art)
            }
            try snapshot(name,row)
        }
        setup.go(to:3);try windowSnapshot("setup-calibrate",setup.window,.darkAqua)
        // The notch at each step from fn ⌃ to pointing, hanging from a 14-inch notch over a menu bar.
        final class Wallpaper:NSView{override func draw(_ dirtyRect:NSRect){NSColor(srgbRed:0.36,green:0.42,blue:0.52,alpha:1).setFill();bounds.fill();NSColor(white:1,alpha:0.18).setFill();NSRect(x:0,y:bounds.height-32,width:bounds.width,height:32).fill()}}
        let notchSteps:[(String,NotchContent,Double)]=[("open-lid",NotchContent.connecting(.openLid,preparing:false)!,1.2),("looking",NotchContent.connecting(.connecting,preparing:false)!,0.8),
            ("close-lid",NotchContent.connecting(.closeLid,preparing:false)!,1.2),("turn",NotchContent.connecting(.settling,preparing:false)!,1.25),
            ("aim",NotchContent.connecting(.calibrating,preparing:false)!,0),("pointing",.pointing,0),("ended",.ended("AirPointer stopped waiting for the lid. Connect again when you’re ready."),0),("ended-long",.ended(ClosedCaseAirPods.helperFailure(30,stopping:false)!),0)]
        let notchRow=NotchFlow.body+32+20
        let notchSheet=Wallpaper(frame:NSRect(x:0,y:0,width:440,height:CGFloat(notchSteps.count)*notchRow))
        for (index,(_,content,time)) in notchSteps.enumerated() {
            let surface=NotchSurface();surface.neck=186;surface.inset=32
            surface.frame=NSRect(x:40,y:notchSheet.bounds.height-CGFloat(index+1)*notchRow+20,width:360,height:NotchFlow.body+32)
            surface.show(content,fade:false);surface.reveal(animated:false);surface.art.pinnedTime=time;notchSheet.addSubview(surface)
        }
        try snapshot("notch-steps",notchSheet,nil)
        setup.update(SetupState(link:.connected,accessibilityTrusted:true,calibrated:true));try windowSnapshot("setup-calibrated",setup.window,.aqua)
        setup.update(SetupState(link:.connected,accessibilityTrusted:true,calibrated:true,taps:SetupTaps(heard:2,listening:true)))
        setup.go(to:4);try windowSnapshot("setup-tap",setup.window,.darkAqua)
        setup.update(SetupState(link:.connected,accessibilityTrusted:true,calibrated:true,taps:SetupTaps(heard:1,mixed:true,failed:true)));try windowSnapshot("setup-tap-failed",setup.window,.aqua)
        setup.update(SetupState(link:.connected,accessibilityTrusted:true,calibrated:true,taps:SetupTaps(heard:3,learned:true)));try windowSnapshot("setup-finish",setup.window,.aqua)
        let tapTest=TapTestWindow{nil};try windowSnapshot("tap-test",tapTest.window,.aqua)
        var tapRun=TapTestRun(start:0);for k in 0..<8{tapRun.click(at:2.5+Double(k)*2)};tapRun.rejected(at:18.5,"not on the front, alignment 0.71")
        for k in 0..<7{tapRun.click(at:25.2+Double(k)*0.3)}
        for k in 0..<5{tapRun.aim(at:33.2+Double(k)*2.5,.zero);tapRun.click(at:33.3+Double(k)*2.5);if k>0{tapRun.aim(at:34+Double(k)*2.5,CGPoint(x:0.3,y:0))}};tapRun.click(at:34);tapRun.click(at:60)
        tapTest.run=tapRun;tapTest.sync(now:80);try windowSnapshot("tap-test-result",tapTest.window,.darkAqua)
        let overlay=CalibrationOverlayView(frame:NSRect(x:0,y:0,width:1440,height:900))
        overlay.step=1;overlay.progress=0.6;try snapshot("calibrate-right",overlay,nil)
        overlay.step=0;overlay.steps=1;overlay.progress=0.4;try snapshot("calibrate-center-only",overlay,nil)
        let bar=MenuBarContentController()
        bar.apply(MenuBarState(status:.live,detail:"Press fn ⌃ to pause from any app",speed:1.2))
        bar.setPointer(CGPoint(x:0.62,y:0.38))
        let barWindow=NSWindow(contentRect:NSRect(origin:.zero,size:bar.preferredContentSize),styleMask:[.borderless],backing:.buffered,defer:false)
        barWindow.contentViewController=bar;barWindow.backgroundColor=HomePalette.raised
        try windowSnapshot("menu-bar",barWindow,.aqua)
        bar.apply(MenuBarState(status:.paused("Paused"),detail:"Resume when you’re ready.",speed:1,canDisconnect:true))
        barWindow.setContentSize(bar.preferredContentSize)
        try windowSnapshot("menu-bar-dark",barWindow,.darkAqua)
        // The status item in each state, at menu-bar size and enlarged, on light and dark bars.
        let statuses:[MenuBarState.Status]=[.ready,.live,.connecting,.notConnected]
        let sheetSize=NSSize(width:CGFloat(statuses.count)*150+10,height:260)
        let sheet=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:Int(sheetSize.width)*2,pixelsHigh:Int(sheetSize.height)*2,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        sheet.size=sheetSize
        NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:sheet)
        for (row,name) in [NSAppearance.Name.aqua,.darkAqua].enumerated() {
            let y=sheetSize.height-CGFloat(row+1)*130
            NSColor(white:row == 0 ? 0.93:0.17,alpha:1).setFill();NSRect(x:0,y:y,width:sheetSize.width,height:130).fill()
            for (column,status) in statuses.enumerated() {
                let icon=StatusBarController.menuBarImage(for:status,appearance:NSAppearance(named:name)!),x=CGFloat(column)*150+10
                icon.draw(in:NSRect(x:x,y:y+56,width:18,height:18));icon.draw(in:NSRect(x:x+30,y:y+11,width:108,height:108))
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        try sheet.representation(using:.png,properties:[:])?.write(to:folder.appendingPathComponent("menu-bar-icon.png"))
    }
    print("PASS: one primary action per phase, pointer-only surfaces (no mode, microphone, Gestures or Practice on home, settings, setup or menu bar), four-step setup, the notch's connect steps and plain settings")
}
