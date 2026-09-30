import Foundation

// ================================================================
// PID定義・デコード処理
// ================================================================
// tab5_obd_monitor.ino の pidTable[] / CSV_SPECS[] / decodeCsvInto() を
// Swiftへ移植したもの。数値のみを返す（GUI表示用・Realm保存用に共用）。
// ino側の decodeInto()（人間可読の単位・記号付き文字列）は、iOS側では
// 表示直前にフォーマットするだけなので個別には移植していない。

struct PidField {
    let name: String   // ino の CSV_SPECS ヘッダー名と同じ（例: "RPM[rpm]"）
    let value: Double
}

struct PidDefinition {
    let pid: UInt8
    let name: String       // ino の pidTable[].name と同じ（例: "RPM"）
    let fieldNames: [String]   // CSV列見出し(=decodeが返すフィールド名)。並び順はCSVの列順にも使う
    let decode: (Data) -> [PidField]  // データ不足/非対応時は空配列
}

enum PidCatalog {
    // u16(): ino の u16(const uint8_t* d, int i) と同じ（ビッグエンディアン16bit）
    private static func u16(_ d: [UInt8], _ i: Int) -> Int {
        (Int(d[i]) << 8) | Int(d[i + 1])
    }

    static let all: [PidDefinition] = [
        PidDefinition(pid: 0x0C, name: "RPM", fieldNames: ["RPM[rpm]"]) { data in
            let d = [UInt8](data)
            guard d.count >= 2 else { return [] }
            return [PidField(name: "RPM[rpm]", value: Double(u16(d, 0)) / 4.0)]
        },
        PidDefinition(pid: 0x0D, name: "Speed", fieldNames: ["Speed[km/h]"]) { data in
            let d = [UInt8](data)
            guard !d.isEmpty else { return [] }
            return [PidField(name: "Speed[km/h]", value: Double(d[0]))]
        },
        PidDefinition(pid: 0x04, name: "Load", fieldNames: ["Load[%]"]) { data in
            let d = [UInt8](data)
            guard !d.isEmpty else { return [] }
            return [PidField(name: "Load[%]", value: Double(d[0]) / 2.55)]
        },
        PidDefinition(pid: 0x11, name: "Throttle", fieldNames: ["Throttle[%]"]) { data in
            let d = [UInt8](data)
            guard !d.isEmpty else { return [] }
            return [PidField(name: "Throttle[%]", value: Double(d[0]) / 2.55)]
        },
        PidDefinition(pid: 0x49, name: "PedalD", fieldNames: ["PedalD[%]"]) { data in
            let d = [UInt8](data)
            guard !d.isEmpty else { return [] }
            return [PidField(name: "PedalD[%]", value: Double(d[0]) / 2.55)]
        },
        PidDefinition(pid: 0x4A, name: "PedalE", fieldNames: ["PedalE[%]"]) { data in
            let d = [UInt8](data)
            guard !d.isEmpty else { return [] }
            return [PidField(name: "PedalE[%]", value: Double(d[0]) / 2.55)]
        },
        PidDefinition(pid: 0x70, name: "Boost", fieldNames: ["Boost[kPa]"]) { data in
            // A=Sup, D-E=SensA（供給フラグ0x02が立っていて5バイト以上ある時のみ有効）
            let d = [UInt8](data)
            guard !d.isEmpty else { return [] }
            let sup = d[0]
            guard (sup & 0x02) != 0, d.count >= 5 else { return [] }
            return [PidField(name: "Boost[kPa]", value: Double(u16(d, 3)) / 32.0)]
        },
        PidDefinition(pid: 0x6D, name: "RailP", fieldNames: ["RailP[MPa]"]) { data in
            let d = [UInt8](data)
            guard !d.isEmpty else { return [] }
            let sup = d[0]
            guard (sup & 0x02) != 0, d.count >= 5 else { return [] }
            return [PidField(name: "RailP[MPa]", value: Double(u16(d, 3) * 10) / 1000.0)]
        },
        PidDefinition(pid: 0x78, name: "EGT", fieldNames: ["EGT_S1[C]", "EGT_S2[C]", "EGT_S3[C]"]) { data in
            // A=Sup, B-C/D-E/F-G = センサー1/2/3。歯抜け(非搭載)は該当フィールドを出力しない
            let d = [UInt8](data)
            guard !d.isEmpty else { return [] }
            let sup = d[0]
            let names = ["EGT_S1[C]", "EGT_S2[C]", "EGT_S3[C]"]
            var out: [PidField] = []
            for s in 0..<3 where d.count >= 2 + s * 2 {
                if (sup & (1 << s)) != 0 {
                    let t = Double(u16(d, 1 + s * 2)) / 10.0 - 40.0
                    out.append(PidField(name: names[s], value: t))
                }
            }
            return out
        },
        PidDefinition(pid: 0x10, name: "MAF", fieldNames: ["MAF[g/s]"]) { data in
            let d = [UInt8](data)
            guard d.count >= 2 else { return [] }
            return [PidField(name: "MAF[g/s]", value: Double(u16(d, 0)) / 100.0)]
        },
        PidDefinition(pid: 0x05, name: "WaterTemp", fieldNames: ["WaterTemp[C]"]) { data in
            let d = [UInt8](data)
            guard !d.isEmpty else { return [] }
            return [PidField(name: "WaterTemp[C]", value: Double(Int(d[0]) - 40))]
        },
        PidDefinition(pid: 0x46, name: "AmbTemp", fieldNames: ["AmbTemp[C]"]) { data in
            let d = [UInt8](data)
            guard !d.isEmpty else { return [] }
            return [PidField(name: "AmbTemp[C]", value: Double(Int(d[0]) - 40))]
        },
        PidDefinition(pid: 0x42, name: "Volt", fieldNames: ["Volt[V]"]) { data in
            let d = [UInt8](data)
            guard d.count >= 2 else { return [] }
            return [PidField(name: "Volt[V]", value: Double(u16(d, 0)) / 1000.0)]
        },
        PidDefinition(pid: 0x83, name: "NOx", fieldNames: ["NOx[ppm]"]) { data in
            let d = [UInt8](data)
            guard !d.isEmpty else { return [] }
            let sup = d[0] & 0x0F
            guard (sup & 0x01) != 0, d.count >= 3 else { return [] }
            let raw = u16(d, 1)
            guard raw != 0xFFFF else { return [] } // 0xFFFF=無効値
            return [PidField(name: "NOx[ppm]", value: Double(raw))]
        },
        PidDefinition(pid: 0x88, name: "SCR", fieldNames: ["SCR_Active[0or1]"]) { data in
            let d = [UInt8](data)
            guard !d.isEmpty else { return [] }
            return [PidField(name: "SCR_Active[0or1]", value: (d[0] & 0x80) != 0 ? 1 : 0)]
        },
        PidDefinition(pid: 0x8B, name: "DPFStat", fieldNames: ["DPF_Regen[0or1]", "DPF_Active[0or1]"]) { data in
            let d = [UInt8](data)
            guard !d.isEmpty else { return [] }
            let st: UInt8 = d.count >= 2 ? d[1] : 0
            return [
                PidField(name: "DPF_Regen[0or1]", value: Double(st & 0x01)),
                PidField(name: "DPF_Active[0or1]", value: (st & 0x02) != 0 ? 1 : 0),
            ]
        },
        PidDefinition(pid: 0x8C, name: "O2Wide", fieldNames: ["Lambda1[-]"]) { data in
            // O2 wide, Lambda B1S1のみ代表表示
            let d = [UInt8](data)
            guard !d.isEmpty else { return [] }
            let sup = d[0]
            guard (sup & 0x10) != 0, d.count >= 11 else { return [] }
            let lambda = Double(u16(d, 9)) * 0.000122
            return [PidField(name: "Lambda1[-]", value: lambda)]
        },
    ]

    static let byPid: [UInt8: PidDefinition] = Dictionary(uniqueKeysWithValues: all.map { ($0.pid, $0) })
}
