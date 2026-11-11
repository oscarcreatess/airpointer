import Foundation
import CoreBluetooth

let airPointerDataFolder=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
    .appendingPathComponent("AirPointer",isDirectory:true)

// The AirPods the closed-case pointer connects to, found among this Mac's paired devices by
// Apple's vendor and product IDs rather than by name. The address stays in Application Support
// and never goes into a log.
struct ClosedCaseAirPods:Equatable {
    let name:String,model:String,address:String,connected:Bool
    // Apple's product ID, which the lid broadcast also carries.
    var productID:UInt16=0
    var title:String{name.localizedCaseInsensitiveContains(model) ? name:"\(name) · \(model)"}
    // 产品 ID 使用小写, 与 parse() 中的标准化结果一致.
    static let models=["0x200e":"AirPods Pro 1","0x2014":"AirPods Pro 2","0x2024":"AirPods Pro 2","0x2027":"AirPods Pro 3",
                       "0x2019":"AirPods 4","0x201b":"AirPods 4 ANC"]
    var usesHeadphoneMotion:Bool{productID==0x200E}
    static let targetURL=airPointerDataFolder.appendingPathComponent("closed-case-target.txt")

    enum Choice:Equatable {
        case chosen(ClosedCaseAirPods),missing,several,bluetoothOff,unreadable
        var failure:String? {
            switch self {
            case .chosen:return nil
            case .missing:return "No AirPods Pro or AirPods 4 are paired with this Mac. Pair them in System Settings → Bluetooth, then connect again."
            case .several:return "More than one pair of AirPods Pro or AirPods 4 is paired with this Mac. Choose yours in Settings, then connect again."
            case .bluetoothOff:return "Bluetooth is off. Turn it on in Control Center, then connect again."
            case .unreadable:return "AirPointer couldn’t read this Mac’s Bluetooth devices. Connect again."
            }
        }
    }
    struct Survey{let poweredOn:Bool,pairs:[ClosedCaseAirPods]}

    static func normalized(_ address:String)->String {
        address.trimmingCharacters(in:.whitespacesAndNewlines).replacingOccurrences(of:"-",with:":").uppercased()
    }
    // `system_profiler SPBluetoothDataType -json`, connected pairs first. Same-named entries
    // without a product ID (the case's own radio, for one) are left out.
    static func parse(_ data:Data)->Survey? {
        guard let root=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any],
              let info=(root["SPBluetoothDataType"] as? [[String:Any]])?.first else{return nil}
        let state=(info["controller_properties"] as? [String:Any])?["controller_state"] as? String
        var pairs:[ClosedCaseAirPods]=[]
        for (key,connected) in [("device_connected",true),("device_not_connected",false)] {
            for entry in info[key] as? [[String:Any]] ?? [] {
                for (name,value) in entry {
                    guard let device=value as? [String:Any],(device["device_vendorID"] as? String)?.lowercased()=="0x004c",
                          let product=(device["device_productID"] as? String)?.lowercased(),let model=models[product],
                          let address=(device["device_address"] as? String).map(normalized),
                          address.range(of:"^(?:[0-9A-F]{2}:){5}[0-9A-F]{2}$",options:.regularExpression) != nil else{continue}
                    pairs.append(ClosedCaseAirPods(name:name,model:model,address:address,connected:connected,productID:UInt16(product.dropFirst(2),radix:16) ?? 0))
                }
            }
        }
        return Survey(poweredOn:state != "attrib_off",pairs:pairs)
    }
    // The saved pair while it's still paired; otherwise the only pair, or the only connected one.
    static func choose(_ survey:Survey?,saved:String?)->Choice {
        guard let survey else{return .unreadable}
        guard survey.poweredOn else{return .bluetoothOff}
        if let saved=saved.map(normalized),let pair=survey.pairs.first(where:{$0.address==saved}){return .chosen(pair)}
        if survey.pairs.count==1{return .chosen(survey.pairs[0])}
        let connected=survey.pairs.filter(\.connected)
        if connected.count==1{return .chosen(connected[0])}
        return survey.pairs.isEmpty ? .missing:.several
    }
    static var saved:String?{(try? String(contentsOf:targetURL,encoding:.utf8)).map(normalized)}
    // The same bytes an earlier build packaged, so saved calibrations keep matching.
    static func save(_ pair:ClosedCaseAirPods) throws {
        guard saved != pair.address else{return}
        try FileManager.default.createDirectory(at:targetURL.deletingLastPathComponent(),withIntermediateDirectories:true)
        try Data(pair.address.utf8).write(to:targetURL,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:targetURL.path)
    }
    // Asks the system on a utility queue and answers on the main one; nil when it couldn't be read.
    static func survey(completion:@escaping(Survey?)->Void) {
        DispatchQueue.global(qos:.userInitiated).async{
            let result=toolOutput("/usr/sbin/system_profiler",["SPBluetoothDataType","-json"],timeout:20).flatMap{parse($0)}
            DispatchQueue.main.async{completion(result)}
        }
    }
    // A system tool's output, or nil if it fails or outlasts the timeout, so a hung tool can't leave Connect waiting.
    static func toolOutput(_ path:String,_ arguments:[String],timeout:TimeInterval)->Data? {
        let process=Process(),output=Pipe()
        process.executableURL=URL(fileURLWithPath:path);process.arguments=arguments
        process.standardOutput=output;process.standardError=FileHandle.nullDevice
        guard (try? process.run()) != nil else{return nil}
        var data=Data();let finished=DispatchSemaphore(value:0)
        DispatchQueue.global(qos:.userInitiated).async{
            data=output.fileHandleForReading.readDataToEndOfFile();process.waitUntilExit();finished.signal()
        }
        guard finished.wait(timeout:.now()+timeout) == .success else{
            if process.isRunning{process.terminate()}
            return nil
        }
        return process.terminationStatus==0 ? data:nil
    }
    static let bluetoothDenied="AirPointer needs Bluetooth to reach your AirPods. Allow it in System Settings → Privacy & Security → Bluetooth, then connect again."
    // ClosedCaseRestore's exit codes, in plain words.
    static func restoreFailure(_ status:Int32)->String {
        switch status {
        case 3:return "Your AirPods didn’t answer. Open the lid, briefly lift and reseat one earbud, then connect again."
        case 4:return bluetoothDenied
        case 5:return "Your AirPods aren’t paired with this Mac anymore. Pair them in System Settings → Bluetooth, then connect again."
        case 6:return Choice.bluetoothOff.failure!
        default:return "AirPointer couldn’t start the connection to your AirPods. Connect again."
        }
    }
    // Exits that mean the AirPods went quiet, not that anything here failed. They're usually asleep, and opening the lid wakes them.
    static func lostContact(_ status:Int32?)->Bool{status.map{[35,40,42,43,44].contains($0)} ?? false}
    // ClosedCaseMotion's exit codes (the table atop CaseSustainedRenewal.m), or nil for a crash.
    // Nil back means nothing to tell: a requested stop, or a case that finishes its own cleanup.
    static func helperFailure(_ status:Int32?,stopping:Bool)->String? {
        let reopen="Open the lid, take one AirPod out and put it back, then connect again."
        switch status {
        case 0,46:return nil
        case 2:return "AirPointer couldn’t start its motion helper. Quit and reopen AirPointer, then connect again."
        case 3:return "The connection ended unexpectedly. Connect again, then open the lid."
        case 10,11:return "AirPointer couldn’t save its session files. Free some disk space, then connect again."
        case 12:return "AirPointer lost track of which AirPods to use. Connect again."
        case 20:return bluetoothDenied
        case 21:return "Bluetooth isn’t ready. Turn it on, wait a few seconds, then connect again."
        case 22:return restoreFailure(5)
        case 23:return "Your AirPods aren’t connected. Open the lid, choose them in the Bluetooth menu, then connect again."
        case 24:return "This version of macOS changed a Bluetooth feature AirPointer needs. The closed-case pointer won’t work until AirPointer is updated."
        case 25:return "Another app is using your AirPods’ control connection. Quit other AirPods utilities, then connect again."
        case 26:return "Your AirPods didn’t reconnect. "+reopen
        case 27:return "Your AirPods reconnected but didn’t open a motion connection. "+reopen
        case 28:return "Your AirPods didn’t answer. "+reopen
        // Also what AirPods connected to an iPhone at the same time do: they answer the setup, then send nothing.
        case 30:return "No motion came from your AirPods. If they’re also connected to your iPhone, turn off Bluetooth there. Keep both AirPods in the open case, then connect again."
        case 31:return "Your AirPods didn’t say what model they are. "+reopen
        case 32:return "These earbuds don’t report as AirPods Pro or AirPods 4. The closed-case pointer needs one of those."
        case 34:return "The case didn’t report as an AirPods charging case. Use the case that came with these AirPods, then connect again."
        case 35:return "The charging case stopped responding. Connect again, then open the lid."
        case 36:return "The charging case turned down AirPointer’s request. Open the lid, wait a few seconds, then connect again."
        case 40:return "Your AirPods stopped answering. Connect again, then open the lid."
        case 41:return "Your AirPods sent something unexpected, so AirPointer stopped to be safe. Connect again, then open the lid."
        case 42:return "AirPointer couldn’t send to your AirPods. Connect again, then open the lid. If it keeps happening, turn Bluetooth off and on."
        case 43:return "Motion from your AirPods stopped. Connect again, then open the lid."
        case 44:return "The connection to your AirPods ended. Connect again, then open the lid."
        case 45:return "The pointer stopped, but your AirPods may still be sending motion. Turn Bluetooth off and on to reset them."
        case 50:return stopping ? nil:"AirPointer stopped responding, so the AirPods connection closed. Connect again from the Pointer page."
        case 51:return stopping ? nil:"AirPointer stopped reading motion, so the AirPods connection closed. Connect again from the Pointer page."
        case 52:return stopping ? nil:"The AirPods connection closed when AirPointer was stopped. Connect again from the Pointer page."
        case 53:return "AirPointer had to force the AirPods connection closed. If the pointer or your AirPods act oddly, turn Bluetooth off and on, then connect again."
        case 54:return "AirPointer needs Motion & Fitness access. Allow it in System Settings → Privacy & Security → Motion & Fitness, then connect again."
        case 55:return "No motion came from your AirPods Pro 1. Turn off Automatic Ear Detection in AirPods settings, briefly lift one AirPod out of the open case and put it back, then connect again."
        case 56:return "Disconnect other headphones from this Mac before using AirPods Pro 1, then connect again."
        default:return stopping ? nil:"The AirPods connection ended unexpectedly. Connect again, then open the lid."
        }
    }
}

// Asks for Bluetooth at Connect, so the system prompt appears when it makes sense.
final class ClosedCaseBluetoothAccess:NSObject,CBCentralManagerDelegate {
    private var manager:CBCentralManager?,waiting:[(Bool)->Void]=[]
    static let settings=URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth")
    func request(_ completion:@escaping(Bool)->Void) {
        switch CBManager.authorization {
        case .allowedAlways:completion(true)
        case .notDetermined:
            waiting.append(completion)
            if manager==nil{manager=CBCentralManager(delegate:self,queue:.main)}
        default:completion(false)
        }
    }
    func centralManagerDidUpdateState(_ central:CBCentralManager) {
        guard CBManager.authorization != .notDetermined else{return}
        let allowed=CBManager.authorization == .allowedAlways,answers=waiting
        waiting=[];manager=nil
        for answer in answers{answer(allowed)}
    }
}

// Apple's proximity-pairing broadcast as macOS hands it over (company ID first): 4C 00, type 07, length
// 19, prefix 01, the product ID little-endian, status, batteries, charge, then the lid byte, whose bit 3
// is set while the lid is closed. That byte is current only while an earbud reports being in the case
// (status bit 6 or bit 2). Nil for any other broadcast. The rest, an address fragment among it, is never read.
func closedCaseLidOpen(_ bytes:[UInt8],productID:UInt16)->Bool?{
    guard bytes.count==29,bytes[0]==0x4C,bytes[1]==0,bytes[2]==7,bytes[3]==0x19,bytes[4]==1,
          bytes[5]==UInt8(productID & 0xFF),bytes[6]==UInt8(productID>>8),bytes[7] & 0x44 != 0 else{return nil}
    return bytes[10] & 0x08==0
}

// After Connect with the lid shut, waits for it to open by listening for the AirPods' own broadcast, the
// one that shows the battery card on an iPhone. Only AirPods paired with this Mac carry a name. It runs
// only while Connect waits, so opening the case in everyday use does nothing.
final class ClosedCaseLidWatcher:NSObject,CBCentralManagerDelegate {
    private var manager:CBCentralManager?,opened:(()->Void)?,ended=false
    private let productID:UInt16
    private var lastOpen:[UUID:Double]=[:]
    init(productID:UInt16,opened:@escaping()->Void){self.productID=productID;self.opened=opened}
    func start(){manager=CBCentralManager(delegate:self,queue:.main)}
    func stop(){
        guard !ended else{return};ended=true
        manager?.stopScan();manager?.delegate=nil;manager=nil;opened=nil
    }
    func centralManagerDidUpdateState(_ central:CBCentralManager){
        if central.state == .poweredOn{central.scanForPeripherals(withServices:nil,options:[CBCentralManagerScanOptionAllowDuplicatesKey:true])}
    }
    func centralManager(_ central:CBCentralManager,didDiscover peripheral:CBPeripheral,advertisementData:[String:Any],rssi:NSNumber){
        guard let data=advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data else{return}
        let bytes=[UInt8](data)
        guard let open=closedCaseLidOpen(bytes,productID:productID) else{return}
        let now=ProcessInfo.processInfo.systemUptime,named=peripheral.name != nil
        guard named,open else{lastOpen[peripheral.identifier]=nil;return}
        // Two open frames within two seconds, so one stray frame can't start a connection.
        if let previous=lastOpen[peripheral.identifier],now-previous<=2{let fire=opened;opened=nil;fire?();return}
        lastOpen[peripheral.identifier]=now
    }
}
