import CoreBluetooth
import Foundation

// ================================================================
// BLEゲートウェイ(AsyncCAN-C3)クライアント
// ================================================================
// tab5_obd_monitor.ino の GatewayClient / gpsTaskFunc相当のフレーム再結合
// ロジックをSwiftへ移植。UUID・パケット形式はゲートウェイ側(ESP32-C3)と
// 完全一致させること（tab5_obd_monitor.ino 冒頭セクション1参照）。
//
// ★バックグラウンド設計：
//   - CBCentralManagerOptionRestoreIdentifierKey でstate restorationを有効化
//     （Info.plistの UIBackgroundModes=bluetooth-central と対）
//   - delegateキューはmain（CoreBluetoothの慣習どおり、CBPeripheralへの呼び出しは
//     常に同じキューから行う）
//   - バックグラウンドではUI更新(@Published)は結果的に画面が無いので無害だが、
//     重い処理はしない。実データの保存は RealmManager 経由で別キューへ逃がす
final class GatewayBLEManager: NSObject, ObservableObject {
    // MARK: - ゲートウェイ接続定義（ESP32-C3側と完全一致させること）
    static let serviceUUID = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    static let rxCharUUID  = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E") // Host -> Gateway (write)
    static let txCharUUID  = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E") // Gateway -> Host (notify)
    static let gatewayName = "AsyncCAN-C3"
    private static let restoreIdentifier = "OBDViewerLogger.CentralManager"
    // ★iOSアプリからは相手の実BluetoothアドレスはOS側の匿名化により取得できない。
    //   CBPeripheral.identifier（UUID。同一端末×同一アプリの組み合わせでは安定）を
    //   「MACアドレス代わり」として保存し、次回起動時の再接続に使う。
    private static let lastPeripheralIDKey = "GatewayBLEManager.lastPeripheralID"

    private static let statusSuccess: UInt8 = 0x00
    // ino の statusLabel() と同じ表記。成功(0x00)以外は値を記録しないが、
    // 「ゲートウェイとの通信が生きている」ことを示すため応答状態だけは画面に出す
    private static func statusLabel(_ s: UInt8) -> String {
        switch s {
        case 0x00: return "OK"
        case 0x01: return "N/A"      // TIMEOUT（車のECUから応答なし。車未接続時など）
        case 0x02: return "REJECT"
        case 0x03: return "SEQERR"
        default:   return "???"
        }
    }

    /// PIDごとの直近の応答。Dashboardは1PID=1タイルで、これを描画する
    /// （ino の pidTable[].valueText に相当。N/A等もここに入る）
    struct PidResponse {
        let statusLabel: String   // "OK" / "N/A" / "REJECT" / "SEQERR"
        let isOK: Bool
        let at: Date
        let fields: [PidField]    // デコード結果。成功以外・デコード不能時は空
    }

    @Published var isRunning = false
    @Published var isConnected = false
    /// PIDごとの直近の応答（値 or N/A等）。Dashboardのタイル表示用
    @Published var pidResponses: [UInt8: PidResponse] = [:]
    @Published var lastResponseAt: Date?

    /// 監視対象PID（PID選択画面から反映）。空なら要求を送らない。
    var selectedPIDs: Set<UInt8> = [] {
        didSet {
            // ★選択を外したPIDのタイルを即座に消す（以前はStartし直すまで灰色のまま残り、
            //   「選択が反映されていない」ように見えた）。要求の送信側は次のポーリングから
            //   新しい選択で動くので、Stop→Startは不要。
            pidResponses = pidResponses.filter { selectedPIDs.contains($0.key) }
        }
    }

    // [BLE-TRACE] 接続不具合の切り分け用ログ（原因特定後に削除する）
    private func trace(_ msg: String) { print("[BLE-TRACE] \(msg)") }

    /// 緯度経度(CoreLocation)。監視開始で測位を始め、各ログ行に付与する
    let location = LocationManager()

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var rxChar: CBCharacteristic?
    private var rxBuffer = Data()
    private var isDiscovering = false // GATT探索中の二重起動防止

    // アプリログ(Realm)用。ポーリングのたびに呼ばれる箇所で毎秒ログが溜まらないよう、
    // 「状態が変わった時だけ」記録するためのフラグ
    private var awaitingConnect = false        // connect()発行済み(接続待ち)
    private var isScanning = false             // scanForPeripherals実行中
    private var awaitingFirstResponse = false  // 接続後、最初の応答をまだ記録していない
    private func appLog(_ msg: String) { RealmManager.logEvent("BLE", msg) }

    private static func btStateName(_ s: CBManagerState) -> String {
        switch s {
        case .unknown: return "unknown"
        case .resetting: return "resetting"
        case .unsupported: return "unsupported"
        case .unauthorized: return "unauthorized"
        case .poweredOff: return "poweredOff"
        case .poweredOn: return "poweredOn"
        @unknown default: return "\(s.rawValue)"
        }
    }

    private var requestTimer: DispatchSourceTimer?
    private let timerQueue = DispatchQueue(label: "com.obdviewerlogger.ble.timer")

    override init() {
        super.init()
        central = CBCentralManager(
            delegate: self,
            queue: nil, // nil = メインキュー。CBPeripheral呼び出しは常にこのキューから行う
            options: [
                CBCentralManagerOptionRestoreIdentifierKey: Self.restoreIdentifier,
                CBCentralManagerOptionShowPowerAlertKey: true,
            ]
        )
    }

    // MARK: - 監視開始/停止（ino の onStartMonitoring/Back相当）

    func startMonitoring() {
        guard !isRunning else { return }
        isRunning = true
        RealmManager.logEvent("MON", "monitoring started (PIDs=\(selectedPIDs.count), gateway connected=\(isConnected))")
        pidResponses.removeAll()
        lastResponseAt = nil
        location.start()

        let t = DispatchSource.makeTimerSource(queue: timerQueue)
        t.schedule(deadline: .now(), repeating: 1.0) // 1秒間隔で一括要求（ino pollTimerCbと同じ周期）
        t.setEventHandler { [weak self] in
            DispatchQueue.main.async { self?.pollTick() }
        }
        t.resume()
        requestTimer = t
    }

    func stopMonitoring() {
        isRunning = false
        RealmManager.logEvent("MON", "monitoring stopped")
        location.stop()
        requestTimer?.cancel()
        requestTimer = nil
        // ★BLE接続自体は切らない（ino同様、Back相当＝画面を離れてもロギングは続けたい
        //   ケースを想定。完全に切るのはアプリ終了/明示操作時のみでよい）
    }

    // MARK: - ポーリング（ino pollTimerCb相当）

    private func pollTick() {
        guard isRunning else { return }
        guard let peripheral, peripheral.state == .connected, let rxChar else {
            connectIfNeeded()
            return
        }
        requestSelectedPIDs(peripheral: peripheral, char: rxChar)
    }

    private func requestSelectedPIDs(peripheral: CBPeripheral, char: CBCharacteristic) {
        guard !selectedPIDs.isEmpty else { return }
        var packet = Data([0x01, UInt8(selectedPIDs.count)]) // mode=0x01, count
        packet.append(contentsOf: selectedPIDs.sorted())
        peripheral.writeValue(packet, for: char, type: .withoutResponse)
    }

    // ★接続維持はStart/Stopと無関係に常時試みる（Start押下前から繋いでおきたい／
    //   ロギング停止中でも「今すぐ再開できる」状態を保ちたいため）。
    //
    // 再接続の要：ここでは「毎回スキャンし直す」のではなく、一度でも接続できた
    // CBPeripheralを覚えておき、それに対して connect() を呼ぶだけにする。
    // connect() は相手が電波圏外でも即失敗せず「保留」される仕様で、相手が
    // 再びアドバタイズを始めた瞬間にOS側が自動的に didConnect を発火させる
    // （ユーザー操作もスキャンも不要。バックグラウンドでも有効）。
    private func connectIfNeeded() {
        guard central.state == .poweredOn else { trace("connectIfNeeded: BT not poweredOn (\(central.state.rawValue))"); return }

        if let p = peripheral {
            trace("connectIfNeeded: have peripheral \(p.identifier) state=\(p.state.rawValue)")
            switch p.state {
            case .connected:
                // ★state restorationで「アプリ終了中もOSが接続を維持していた」場合、起動直後は
                //   既にconnectedなのでdidConnectが来ない。GATT探索(サービス→キャラ→Notify購読)を
                //   まだ済ませていなければここで開始する。これを怠るとリンクは生きているのに
                //   isConnected=falseのまま・データも受信できない。
                if rxChar == nil && !isDiscovering { didConnectPeripheral(p) }
            case .disconnected:
                requestConnect(p, reason: "known peripheral")
            default:
                break // connecting / disconnecting は完了を待つ
            }
            return
        }

        // アプリがプロセスごと終了→再起動された直後など、メモリ上にCBPeripheralが
        // 無い場合は、保存しておいたidentifier(UUID)から辿り直す
        trace("connectIfNeeded: saved id = \(savedPeripheralID?.uuidString ?? "nil")")
        if let saved = savedPeripheralID,
           let known = central.retrievePeripherals(withIdentifiers: [saved]).first {
            trace("connectIfNeeded: retrievePeripherals hit, state=\(known.state.rawValue) -> connect()")
            peripheral = known
            known.delegate = self
            requestConnect(known, reason: "restored from saved id")
            return
        }
        // OS側が裏で既に接続を維持しているケース（state restoration後の再起動直後等）
        if let already = central.retrieveConnectedPeripherals(withServices: [Self.serviceUUID]).first {
            trace("connectIfNeeded: retrieveConnectedPeripherals hit")
            peripheral = already
            already.delegate = self
            didConnectPeripheral(already) // 既にconnected状態なのでdidConnectは来ない
            return
        }

        // 初回ペアリング、または保存identifierが無効になった場合のみスキャンする
        trace("connectIfNeeded: -> scanForPeripherals")
        if !isScanning { isScanning = true; appLog("scan started (no known gateway)") }
        central.scanForPeripherals(withServices: [Self.serviceUUID], options: nil)
    }

    /// connect()は圏外でも即失敗せず「保留」される。保留に入った時だけ記録する
    private func requestConnect(_ p: CBPeripheral, reason: String) {
        if !awaitingConnect {
            awaitingConnect = true
            appLog("connect() requested — pending until gateway is in range (\(reason))")
        }
        central.connect(p, options: connectOptions)
    }

    private var connectOptions: [String: Any] {
        [CBConnectPeripheralOptionNotifyOnConnectionKey: true] // バックグラウンド再接続時に通知を出す
    }

    private var savedPeripheralID: UUID? {
        UserDefaults.standard.string(forKey: Self.lastPeripheralIDKey).flatMap(UUID.init)
    }

    private func rememberPeripheral(_ p: CBPeripheral) {
        UserDefaults.standard.set(p.identifier.uuidString, forKey: Self.lastPeripheralIDKey)
    }

    // MARK: - フレーム再結合（ino GatewayClient::onNotify/handlePacket相当）
    // ヘッダー5バイト: [status, mode, pid, payloadLenHi, payloadLenLo] + payload

    private func drainBuffer() {
        while true {
            guard rxBuffer.count >= 5 else { return }
            let header = [UInt8](rxBuffer.prefix(5))
            let payloadLen = (Int(header[3]) << 8) | Int(header[4])
            let total = 5 + payloadLen
            guard rxBuffer.count >= total else { return }

            let packet = [UInt8](rxBuffer.prefix(total))
            handlePacket(packet)
            rxBuffer.removeFirst(total)
        }
    }

    private func handlePacket(_ bytes: [UInt8]) {
        let status = bytes[0]
        let pid = bytes[2]
        guard let def = PidCatalog.byPid[pid] else { return }

        let now = Date()
        if awaitingFirstResponse {
            awaitingFirstResponse = false
            appLog(String(format: "first response after connect (pid=0x%02X, status=%@)", pid, Self.statusLabel(status)))
        }
        let ok = status == Self.statusSuccess
        let fields = ok ? def.decode(Data(bytes[5...])) : []

        // GUI用（メインキュー上）。成功以外(N/A等)も応答として記録し、値は保存しない
        pidResponses[pid] = PidResponse(statusLabel: Self.statusLabel(status),
                                        isOK: ok, at: now, fields: fields)
        lastResponseAt = now
        guard !fields.isEmpty else { return }

        // 永続化用（別キューへ）。同一秒の値は1レコードに足し込まれ、その秒の位置情報も付く
        let fix = location.currentFix()
        RealmManager.record(at: now, fields: fields,
                            latitude: fix?.coordinate.latitude,
                            longitude: fix?.coordinate.longitude)
    }
}

// MARK: - CBCentralManagerDelegate

extension GatewayBLEManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        trace("centralManagerDidUpdateState: \(central.state.rawValue)")
        appLog("Bluetooth state = \(Self.btStateName(central.state))")
        guard central.state == .poweredOn else { return }
        connectIfNeeded()
    }

    // ★アプリがバックグラウンドで終了され、BLEイベントで再起動されたときにここへ入る
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        // ★iOSがバックグラウンドで終了させたアプリを、BLEイベントで再起動した時にここへ来る
        RealmManager.logEvent("APP", "willRestoreState — iOS relaunched the app for BLE (restored peripherals=\(restored.count))")
        guard let p = restored.first else { return }
        peripheral = p
        p.delegate = self
        rememberPeripheral(p)
        trace("willRestoreState: restored \(p.identifier) state=\(p.state.rawValue)")
        // ★ここではperipheralに触らない。restore時点ではまだBTがpoweredOnになっておらず、
        //   discoverServices等を呼んでも無視される。直後に来る centralManagerDidUpdateState
        //   -> connectIfNeeded() が、接続済みならGATT探索を、未接続ならconnect()を行う。
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                         advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        trace("didDiscover: id=\(peripheral.identifier) name=\(peripheral.name ?? "nil") advName=\(advName ?? "nil") rssi=\(RSSI)")
        // ★スキャン時にサービスUUIDで絞り込み済み。iOSは同一機器の検出を1回にまとめるため、
        //   その時点でnameが未取得だと以後二度と通知されず接続できなくなる。名前では弾かない。
        central.stopScan()
        isScanning = false
        appLog("gateway discovered (rssi=\(RSSI))")
        self.peripheral = peripheral
        peripheral.delegate = self
        central.connect(peripheral, options: connectOptions)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        didConnectPeripheral(peripheral)
    }

    private func didConnectPeripheral(_ peripheral: CBPeripheral) {
        // 復元直後は connectIfNeeded() と didConnect の両方から呼ばれる。2 回目は無視する
        guard !isDiscovering, rxChar == nil else { return }
        trace("didConnect: \(peripheral.identifier)")
        awaitingConnect = false
        appLog("link connected")
        isDiscovering = true
        rememberPeripheral(peripheral) // ★次回起動時の再接続用にidentifierを保存
        rxBuffer.removeAll()
        peripheral.discoverServices([Self.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        trace("didDisconnect: error=\(error?.localizedDescription ?? "nil")")
        awaitingConnect = false
        awaitingFirstResponse = false
        appLog("link disconnected (error=\(error?.localizedDescription ?? "none"))")
        isDiscovering = false
        isConnected = false
        rxChar = nil
        rxBuffer.removeAll()
        // ★距離が離れて切断→再び近づいたら自動再接続（ユーザー操作不要）。
        //   connect()を呼ぶだけで、相手のアドバタイズ再開をOSが検知して自動的に
        //   繋ぎ直してくれる。Start/Stopの状態に関わらず常時これを試みる。
        connectIfNeeded()
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        trace("didFailToConnect: \(error?.localizedDescription ?? "nil")")
        awaitingConnect = false
        appLog("connect failed (error=\(error?.localizedDescription ?? "none"))")
        connectIfNeeded()
    }
}

// MARK: - CBPeripheralDelegate

extension GatewayBLEManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        trace("didDiscoverServices: \(peripheral.services?.map { $0.uuid.uuidString } ?? []) error=\(error?.localizedDescription ?? "nil")")
        guard let services = peripheral.services else { return }
        for s in services where s.uuid == Self.serviceUUID {
            peripheral.discoverCharacteristics([Self.rxCharUUID, Self.txCharUUID], for: s)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        trace("didDiscoverCharacteristics: \(service.characteristics?.map { $0.uuid.uuidString } ?? []) error=\(error?.localizedDescription ?? "nil")")
        guard let chars = service.characteristics else { return }
        for c in chars {
            if c.uuid == Self.rxCharUUID { rxChar = c }
            if c.uuid == Self.txCharUUID { peripheral.setNotifyValue(true, for: c) }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        trace("didUpdateNotificationState: \(characteristic.uuid) notifying=\(characteristic.isNotifying) error=\(error?.localizedDescription ?? "nil")")
        guard characteristic.uuid == Self.txCharUUID else { return }
        isDiscovering = false
        isConnected = characteristic.isNotifying
        if characteristic.isNotifying {
            awaitingFirstResponse = true
            appLog("GATT ready — notify subscribed")
        } else {
            appLog("notify NOT subscribed (error=\(error?.localizedDescription ?? "none"))")
        }
        rxBuffer.removeAll()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == Self.txCharUUID, let data = characteristic.value else { return }
        rxBuffer.append(data)
        drainBuffer()
    }
}
