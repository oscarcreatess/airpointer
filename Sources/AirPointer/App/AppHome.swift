import AppKit
import ApplicationServices

extension App {
    func startClosedPointerSession(fromNotch:Bool=false){
        startClosedPointerSession(ClosedCaseSessionLaunch(fromNotch:fromNotch))
    }
    func startClosedPointerSession(_ launch:ClosedCaseSessionLaunch){
        // A session still running ends first, without holding up the window.
        if let old=closedCaseSession,old.isActive{old.disconnect{[weak self] in self?.startClosedPointerSession(launch)};return}
        pause();calibrator.disconnected()
        let session=ClosedCaseSession();closedCaseSession=session
        session.usesNotch=launch.fromNotch;session.opensLidFirst=launch.afterLoss
        session.pointsWhenReady=launch.pointsWhenReady(setupVisible:setup?.window.isVisible == true);notch?.stage=nil
        applyPointerSettings(pointerSettings,to:session)
        session.onPoint={ [weak self] point in self?.homePreview.point=point;self?.statusBar?.updatePointer(point) }
        session.onFrame={ [weak self] frame in if self?.calibrator.closedCase != nil{self?.calibrator.feed(frame)} }
        closedCalibrationDeclined=false
        session.onUpdate={ [weak self] session in
            guard let self,self.closedCaseSession === session else{return}
            self.closedCaseOwnsInput=session.isActive
            // Setup asks for calibration on its own step; elsewhere the dots appear as soon as the case is upright.
            // A finished calibration leaves the overlay to show "Calibrated"; anything else ends it.
            if session.stage == .calibrating{if self.setup?.window.isVisible != true && !session.centersItself{self.presentClosedCalibration(session)}}
            else if self.calibrator.closedCase != nil && !session.calibrated{
                let declined=self.closedCalibrationDeclined;self.calibrator.cancel();self.closedCalibrationDeclined=declined
            }
            // The state timer stands down while the session owns the input, so the menu bar, HUD and setup follow the session here.
            self.refreshHome();self.refreshStatusBar();self.refreshSetup();self.refreshNotch()
        }
        session.onEnded={ [weak self,weak session] reason in
            // The window is often out of sight while pointing, so the notch says what happened and pointing returns once the lid opens and closes.
            if session?.lostContact == true{
                DispatchQueue.main.async{self?.startClosedPointerSession(ClosedCaseSessionLaunch(fromNotch:true,afterLoss:true))}
                return
            }
            // Disconnect stays quiet.
            guard let reason else{return}
            self?.reportEnded(reason,fromNotch:session?.usesNotch == true)
        }
        home?.setNotice(nil)
        session.beginSession()
    }
    // A connection that drops on its own says why: setup on its Connect step, the notch for its own sessions, and the window for the rest, even if it was closed.
    func reportEnded(_ reason:String,fromNotch:Bool){
        let inSetup=setup?.window.isVisible == true,several=reason==ClosedCaseAirPods.Choice.several.failure
        if !inSetup,several || !fromNotch{showHome()}
        home?.setNotice(reason)
        if several,!inSetup{showHomeSettings()}
    }
    // Pause keeps the case connected; this is the one way to end the connection on purpose.
    @objc func disconnectClosedCase(){
        guard let session=closedCaseSession,session.isActive else{return}
        if calibrator.closedCase != nil{calibrator.cancel()}
        session.disconnect();refreshHome();refreshStatusBar()
    }
    // The closed case calibrates through the same full-screen dots as the rest of the app.
    func presentClosedCalibration(_ session:ClosedCaseSession){
        guard !calibrator.isActive,!closedCalibrationDeclined else{return}
        calibrator.closedCase={ [weak session] center,right,up in
            guard let session else{throw LessonError.message("The case lost its connection. Connect again, then open the lid.")}
            try session.applyCalibration(center:center,right:right,up:up)
        }
        calibrator.closedCenter=session.centerOnly ? { [weak session] center in
            guard let session else{throw LessonError.message("The case lost its connection. Connect again, then open the lid.")}
            return try session.applyCenter(center)
        }:nil
        calibrator.show(on:controlledScreen)
    }
    func showHome(){
        if home==nil {
            let view=AirPointerHome(pad:homePreview)
            view.onControl={ [weak self] in self?.homeControlAction() }
            view.onRecenter={ [weak self] in self?.homeRecenter() }
            view.onLearnGrip={ [weak self] in self?.recalibrate() }
            view.onDisconnect={ [weak self] in self?.disconnectClosedCase() }
            view.onSetup={ [weak self] in self?.runSetupAgain() }
            view.onTeachTap={ [weak self] in self?.teachTap() }
            view.onSettings={ [weak self] in self?.showHomeSettings() }
            view.onPointerSettingsChange={ [weak self] value in self?.applyHomePointerSettings(value) }
            view.onClose={ [weak self] in self?.pause() }
            home=view
        }
        refreshHome();home?.show()
    }
    var homeInputsReady:Bool{closedCaseSession?.inputReady == true}
    func homeControlAction(){
        // Without Accessibility the button says Allow, even during a session, so it only ever opens the list.
        guard AXIsProcessTrusted() else{
            home?.setNotice(nil)
            AccessibilityGuide.shared.open()
            refreshHome();return
        }
        if let session=closedCaseSession,session.isActive{
            switch session.stage {
            case .closeLid:session.confirmLidClosed()
            case .calibrating:closedCalibrationDeclined=false;presentClosedCalibration(session)
            case .ready:session.resumeCursor()
            case .pointing:pause()
            default:disconnectClosedCase()
            }
            refreshHome();return
        }
        guard !closedCaseOwnsInput,!showConnectEffectsFirst() else{return}
        home?.setNotice(nil)
        startClosedPointerSession()
    }
    func homeRecenter(){if let session=closedCaseSession,session.isActive{session.recenter()}else{pause();refreshHome()}}
    // The phase drives the window, the menu bar and the HUD, so it is
    // computed even while the window has never been opened.
    func refreshHome(){
        let trusted=AXIsProcessTrusted(),ready=homeInputsReady
        if let session=closedCaseSession{homePhase=trusted ? session.homePhase:.needsAccessibility}
        else if !trusted{homePhase = .needsAccessibility}
        else{homePhase = .needsInputs}
        let title:String
        if !trusted{title="Allow AirPointer…"}
        else if let session=closedCaseSession,session.isActive {
            switch session.stage {
            case .pointing:title="Pause"
            case .ready:title="Start Pointing"
            case .closeLid:title="Lid Closed"
            case .calibrating:title="Start Calibration"
            default:title="Cancel Connecting"
            }
        }else{title="Start Pointing"}
        for item in homeMenuItems{item.title=title}
        disconnectMenuItem?.isHidden=closedCaseSession?.isActive != true
        guard let home else{return}
        home.updatePointerSettings(homePointerSettings())
        home.updateControl(phase:homePhase,inputsReady:ready)
        home.updateHold(homePhase == .closedCase(.holdStill) ? CGFloat(closedCaseSession?.holdProgress ?? 0):nil)
    }
    func homePointerSettings()->PointerSettingsState {
        let chosen=ClosedCaseAirPods.choose(ClosedCaseAirPods.Survey(poweredOn:true,pairs:closedCasePairs),saved:ClosedCaseAirPods.saved)
        var pair = -1;if case .chosen(let found)=chosen{pair=closedCasePairs.firstIndex(of:found) ?? -1}
        var value=pointerSettings
        value.screens=NSScreen.screens.map(\.localizedName)
        value.pairs=closedCasePairs.map(\.title)
        value.pair=pair
        if !value.screens.isEmpty,value.screen>=value.screens.count{value.screen=value.screens.count-1}
        return value
    }
    func showHomeSettings(){
        guard let home else{return};pause()
        home.updatePointerSettings(homePointerSettings());home.selectSettings()
        ClosedCaseAirPods.survey{[weak self] survey in
            guard let self,let survey else{return}
            self.closedCasePairs=survey.pairs;self.home?.updatePointerSettings(self.homePointerSettings())
        }
    }
    private func applyPointerSettings(_ value:PointerSettingsState,to session:ClosedCaseSession){
        session.speed=value.speed;session.clickSound=value.clickSound;session.plane=value.plane
        session.tapDirection=value.tapDirection;session.screenIndex=value.screen
    }
    func applyHomePointerSettings(_ value:PointerSettingsState){
        // Another pair is a different connection, so a session on the old one ends.
        if closedCasePairs.indices.contains(value.pair),closedCasePairs[value.pair].address != ClosedCaseAirPods.saved {
            disconnectClosedCase()
            do{try ClosedCaseAirPods.save(closedCasePairs[value.pair])}catch{home?.setNotice("AirPointer couldn’t save which AirPods to use. Try again.")}
        }
        var next=value;next.clampSpeed()
        let screenChanged=pointerSettings.screen != next.screen
        let planeChanged=pointerSettings.plane != next.plane
        pointerSettings.speed=next.speed
        pointerSettings.clickSound=next.clickSound
        pointerSettings.plane=next.plane
        if screenChanged,NSScreen.screens.indices.contains(next.screen){pointerSettings.screen=next.screen;pointerSettings.screenID=NSScreen.screens[next.screen].displayID}
        pointerSettings.persist()
        if screenChanged || planeChanged{pause()}
        if let session=closedCaseSession{applyPointerSettings(pointerSettings,to:session)}
        if planeChanged{
            try? FileManager.default.removeItem(at:airPointerDataFolder.appendingPathComponent("closed-case-grip.json"))
            closedCaseSession?.clearSavedGrip()
        }
        home?.updatePointerSettings(homePointerSettings())
        refreshSetup()
    }
    @objc func openHomeSettings(){showHome();showHomeSettings()}
    @objc func homeMenuControl(){showHome();homeControlAction()}
    @objc func homeMenuRecenter(){homeRecenter()}
    @objc func showPointerPage(){showHome();home?.selectPointer()}
}

extension App {
    // First run: setup never finished.
    var needsSetup:Bool{!UserDefaults.standard.bool(forKey:"setupComplete")}
    // Setup's Connect step says what a session does, so every way to connect goes there until someone has pressed it.
    func showConnectEffectsFirst()->Bool{
        guard needsSetup,!UserDefaults.standard.bool(forKey:"connectEffectsSeen") else{return false}
        showSetup();setup?.go(to:AXIsProcessTrusted() ? 2:0);return true
    }
    @objc func showSetup(){
        if setup==nil {
            let assistant=SetupAssistant()
            // Setup always connects the closed case.
            assistant.onConnect={ [weak self] in
                UserDefaults.standard.set(true,forKey:"connectEffectsSeen")
                self?.startClosedPointerSession()
            }
            assistant.onChoosePlane={ [weak self] plane in
                guard let self else{return}
                var value=self.homePointerSettings();value.plane=plane
                self.applyHomePointerSettings(value)
            }
            assistant.onChooseAirPods={ [weak self] in self?.chooseAirPods() }
            assistant.onLidClosed={ [weak self] in self?.closedCaseSession?.confirmLidClosed() }
            assistant.onRequestAccessibility={AccessibilityGuide.shared.open()}
            assistant.onCalibrate={ [weak self] in
                guard let self,let session=self.closedCaseSession,session.isActive else{self?.recalibrate();return}
                // Setup always aims at all three dots, even when edges were saved before.
                self.closedCalibrationDeclined=false;session.recalibrate()
                if session.stage == .calibrating{self.presentClosedCalibration(session)}
            }
            assistant.onFinish={ [weak self] in UserDefaults.standard.set(true,forKey:"setupComplete");self?.showHome() }
            assistant.onLearnTap={ [weak self] in self?.learnTap() }
            assistant.onStopLearningTap={ [weak self] in self?.stopLearningTap() }
            assistant.onClose={ [weak self] in self?.closedCaseSession?.stopLearningTaps();self?.setup=nil }
            setupTaps=SetupTaps()
            setup=assistant
            refreshSetup()
        }
        home?.window.orderOut(nil)
        setup?.show()
    }
    private func chooseAirPods(){
        ClosedCaseAirPods.survey{[weak self] survey in
            guard let self,let survey else{return}
            let menu=NSMenu()
            for pair in survey.pairs{
                let item=NSMenuItem(title:pair.title,action:#selector(self.pickAirPods(_:)),keyEquivalent:"")
                item.target=self;item.representedObject=pair;menu.addItem(item)
            }
            menu.popUp(positioning:nil,at:NSEvent.mouseLocation,in:nil)
        }
    }
    @objc private func pickAirPods(_ item:NSMenuItem){
        guard let pair=item.representedObject as? ClosedCaseAirPods,(try? ClosedCaseAirPods.save(pair)) != nil else{return}
        UserDefaults.standard.set(true,forKey:"connectEffectsSeen")
        startClosedPointerSession()
    }
    @objc func runSetupAgain(){pause();showSetup();setup?.go(to:AXIsProcessTrusted() ? 1:0)}
    func teachTap(){pause();showSetup();setupTaps=SetupTaps();refreshSetup();setup?.go(to:4)}
    private func learnTap(){
        setupTaps=SetupTaps(listening:true)
        closedCaseSession?.learnTaps{ [weak self] event in
            guard let self else{return}
            switch event {
            case .tap(let agreeing,let total):self.setupTaps.heard=agreeing;self.setupTaps.mixed=total>agreeing;self.setupTaps.soft=false
            case .tooSoft:self.setupTaps.soft=true
            case .finished(let direction):
                self.setupTaps=SetupTaps(heard:ClosedCaseTapLearner.taps,learned:true)
                self.pointerSettings.tapDirection=direction==ClosedCaseTapDetector.tapDirection ? nil:[direction.x,direction.y,direction.z]
                self.pointerSettings.persist()
                self.closedCaseSession?.tapDirection=self.pointerSettings.tapDirection
            case .failed:self.setupTaps=SetupTaps(failed:true)
            }
            self.refreshSetup()
        }
        refreshSetup()
    }
    private func stopLearningTap(){
        closedCaseSession?.stopLearningTaps()
        if setupTaps.listening{setupTaps=SetupTaps();refreshSetup()}
    }
    func refreshSetup(){
        guard let setup else{return}
        let session=closedCaseSession
        let stage=session?.stage ?? .off
        let link=stage.setupLink
        let problem=stage == .off ? session?.endReason:nil
        setup.update(SetupState(link:link,problem:problem,
                                accessibilityTrusted:AXIsProcessTrusted(),
                                plane:pointerSettings.plane,
                                calibrating:calibrator.isActive,
                                calibrated:session?.calibrated == true,
                                holdProgress:session?.holdProgress ?? 0,
                                taps:setupTaps))
    }
}

// MARK: - Menu bar and HUD

extension App {
    func installStatusBar(){
        let bar=StatusBarController()
        bar.onToggleControl={ [weak self] in
            guard let self else{return}
            self.homeControlAction()
        }
        bar.onRecenter={ [weak self] in self?.homeRecenter() }
        bar.onPause={ [weak self] in self?.pause();self?.refreshHome() }
        bar.onDisconnect={ [weak self] in self?.disconnectClosedCase() }
        bar.onOpen={ [weak self] in self?.showPointerPage() }
        bar.onCalibrate={ [weak self] in self?.recalibrate() }
        bar.onSettings={ [weak self] in self?.openHomeSettings() }
        bar.onQuit={ NSApp.terminate(nil) }
        bar.onSpeedChange={ [weak self] speed in
            guard let self else{return}
            var value=self.homePointerSettings();value.speed=speed;self.applyHomePointerSettings(value)
        }
        statusBar=bar
    }
    var controlledScreen:NSScreen? {
        let index=pointerSettings.screen
        return NSScreen.screens.indices.contains(index) ? NSScreen.screens[index]:NSScreen.main
    }
    func refreshStatusBar(){
        var status:MenuBarState.Status,detail:String
        switch homePhase {
        case .needsInputs:status = .notConnected;detail="Connect, then open the lid."
        case .connecting:status = .connecting;detail="Keep the lid open for a moment."
        case .needsAccessibility:status = .needsAccess;detail="Allow AirPointer in Accessibility to move the pointer."
        case .closedCase(.openLid):status = .connecting;detail="Open the lid to connect."
        case .closedCase(.closeLid):status = .connecting;detail="Close the lid."
        case .closedCase(.turnUpright):status = .connecting;detail="Turn the closed case upright."
        case .closedCase(.holdStill):status = .connecting;detail="Put the closed case on a flat surface."
        case .closedCase(.calibrate):status = .connecting;detail="Point at the dots on your screen."
        case .closedCase(.recenter):status = .connecting;detail="Point at the dot in the center of your screen."
        case .ready:status = .ready;detail="Hold the closed case upright."
        case .running:status = .live;detail="Press \(PointerShortcut.current.label) to pause from any app"
        case .paused(let reason):status = .paused(reason=="Paused" ? "":reason);detail="Resume when you’re ready."
        }
        statusBar?.update(MenuBarState(status:status,detail:detail,speed:pointerSettings.speed,canDisconnect:closedCaseSession?.isActive == true))
        announcePhaseChange()
    }
    // The HUD answers "what just happened?" on the screen being presented.
    private func announcePhaseChange(){
        guard homePhase != hudPhase else{return}
        let previous=hudPhase;hudPhase=homePhase
        // The notch has no step for this, so the HUD says it for every session.
        switch (previous,homePhase) {
        case (.running,.needsAccessibility),(.paused,.needsAccessibility):
            hud.show("Pointer stopped — allow AirPointer in Accessibility",symbol:"hand.raised",on:controlledScreen);return
        default:break
        }
        // A session from the notch says it there; the HUD stays for a pointer on another screen.
        if closedCaseSession?.usesNotch == true,let notch,notch.screen == controlledScreen{return}
        switch (previous,homePhase) {
        case (_,.running):hud.show("Pointing",live:true,on:controlledScreen)
        case (.running,.paused(let reason)):
            let short=reason=="Paused" || reason.isEmpty ? "":" — "+(reason.split(separator:".").first.map(String.init) ?? reason)
            hud.show("Paused"+short,symbol:"pause.fill",on:controlledScreen)
        case (.running,.needsInputs),(.paused,.needsInputs):hud.show("Disconnected — connect again, then open the lid",symbol:"xmark.circle",on:controlledScreen)
        default:break
        }
    }
}
