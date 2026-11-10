import SwiftUI

struct ContentView: View {
    @EnvironmentObject var scanner: Scanner
    @EnvironmentObject var tracker: Tracker
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            DeviceListView(onPick: { tab = 1 })
                .tabItem { Label("デバイス", systemImage: "dot.radiowaves.left.and.right") }
                .tag(0)
            TrackView()
                .tabItem { Label("探索", systemImage: "location.magnifyingglass") }
                .tag(1)
            HelpView()
                .tabItem { Label("しくみ", systemImage: "info.circle") }
                .tag(2)
        }
        .onAppear {
            scanner.onTargetSample = { rssi in tracker.addRSSI(rssi) }
        }
    }
}

// MARK: - Device list

struct DeviceListView: View {
    @EnvironmentObject var scanner: Scanner
    var onPick: () -> Void

    var body: some View {
        NavigationStack {
            VStack {
                Text(scanner.stateText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                List(scanner.devices) { dev in
                    Button {
                        scanner.selectTarget(dev.id)
                        onPick()
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(dev.name).foregroundStyle(.primary)
                                Text(dev.id.uuidString.prefix(8) + "…")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(Int(dev.smoothedRSSI.rounded())) dBm")
                                .font(.body.monospacedDigit())
                                .foregroundStyle(dev.id == scanner.targetID ? .green : .primary)
                            if dev.id == scanner.targetID {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            }
                        }
                    }
                }
            }
            .navigationTitle("近くのBLEデバイス")
        }
    }
}

// MARK: - Tracking

struct TrackView: View {
    @EnvironmentObject var scanner: Scanner
    @EnvironmentObject var tracker: Tracker
    @State private var txPower = -59.0
    @State private var pathLoss = 2.0

    private var targetName: String {
        scanner.devices.first { $0.id == scanner.targetID }?.name ?? "未選択"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("対象: \(targetName)").font(.headline)
                        Spacer()
                        if let r = scanner.targetRSSI {
                            Text("\(Int(r.rounded())) dBm").font(.body.monospacedDigit())
                        } else {
                            Text("受信なし").foregroundStyle(.secondary)
                        }
                    }

                    if scanner.targetID == nil {
                        Text("先に「デバイス」タブで探したい機器を選んでください。")
                            .foregroundStyle(.secondary)
                    } else {
                        guidanceCard
                        MapView()
                            .frame(height: 320)
                            .background(Color(.secondarySystemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        statsRow
                        if let result = tracker.result, result.mirror != nil {
                            Label("直線移動だけだと左右の鏡像候補が残ります。横方向にも歩くと確定します。",
                                  systemImage: "exclamationmark.triangle")
                                .font(.footnote)
                                .foregroundStyle(.orange)
                        }
                        HStack(spacing: 12) {
                            Button(tracker.isRunning ? "停止" : "探索開始") {
                                tracker.isRunning ? tracker.stop() : tracker.start()
                            }
                            .buttonStyle(.borderedProminent)
                            Button("リセット") { tracker.reset() }
                                .buttonStyle(.bordered)
                        }
                        calibration
                    }
                    if !tracker.notice.isEmpty {
                        Text(tracker.notice).font(.footnote).foregroundStyle(.red)
                    }
                }
                .padding()
            }
            .navigationTitle("方向探知")
        }
    }

    private var guidanceCard: some View {
        Group {
            if let g = tracker.guidance, let result = tracker.result {
                VStack(alignment: .leading, spacing: 4) {
                    Text("推定位置まで 約 \(String(format: "%.1f", g.distance)) m")
                        .font(.title3.bold())
                    Text(directionText(g.relativeBearing))
                        .font(.headline)
                        .foregroundStyle(.blue)
                    Text("当てはまりの悪さ（残差）: \(String(format: "%.1f", result.residualRMS)) m　※小さいほど信頼できます")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                Text("「探索開始」を押して、対象の周りを歩いてください。歩いた軌跡と電波の強さから位置を推定します。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func directionText(_ rel: Double) -> String {
        let a = abs(rel)
        if a < 15 { return "だいたい正面です" }
        let side = rel > 0 ? "右" : "左"
        if a > 165 { return "真後ろです" }
        return "\(side) 約 \(Int(a.rounded()))° の方向です"
    }

    private var statsRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 16) {
                Text("サンプル \(tracker.sampleCount)")
                if let d = tracker.latestRange {
                    Text("今の推定距離 \(String(format: "%.1f", d)) m")
                }
                if let r = tracker.result {
                    Text("横の広がり \(String(format: "%.1f", r.lateralSpread)) m")
                }
            }
            HStack(spacing: 16) {
                Text("開始地点から \(String(format: "%.1f", tracker.distanceFromOrigin)) m")
                if tracker.usingGPS, let acc = tracker.gpsAccuracy {
                    Text("GPS ±\(String(format: "%.0f", acc)) m")
                } else {
                    Text("GPS待ち（歩数計で代替中）")
                }
            }
            if tracker.isRunning, tracker.sampleCount >= 8, tracker.maxSpreadFromStart < 0.5 {
                Label("自分の位置がほとんど動いていません。歩行が検出できていないと方向は出せません（モーションの許可、屋外ではGPS受信を確認）",
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }

    private var calibration: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("較正（合わないとき調整）").font(.subheadline.bold())
            Text("1m地点の電波強度: \(Int(txPower)) dBm").font(.caption)
            Slider(value: $txPower, in: -90 ... -40, step: 1) { _ in applyCalibration() }
            Text("電波の減衰の速さ: \(String(format: "%.1f", pathLoss))").font(.caption)
            Slider(value: $pathLoss, in: 1.5 ... 3.5, step: 0.1) { _ in applyCalibration() }
        }
    }

    private func applyCalibration() {
        tracker.txPower = txPower
        tracker.pathLoss = pathLoss
    }
}

// MARK: - Map

struct MapView: View {
    @EnvironmentObject var tracker: Tracker

    var body: some View {
        Canvas { context, size in
            var points: [(x: Double, y: Double)] = tracker.track
            if let r = tracker.result {
                points.append((r.x, r.y))
                if let m = r.mirror { points.append(m) }
            }
            guard let first = points.first else { return }
            var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
            for p in points {
                minX = min(minX, p.x); maxX = max(maxX, p.x)
                minY = min(minY, p.y); maxY = max(maxY, p.y)
            }
            let pad = 3.0
            minX -= pad; maxX += pad; minY -= pad; maxY += pad
            let spanX = max(maxX - minX, 6), spanY = max(maxY - minY, 6)
            let scale = min(size.width / spanX, size.height / spanY)
            func project(_ x: Double, _ y: Double) -> CGPoint {
                CGPoint(x: (x - minX) * scale, y: size.height - (y - minY) * scale)
            }

            // range circle for the latest reading
            if let d = tracker.latestRange {
                let c = project(tracker.posX, tracker.posY)
                let rect = CGRect(x: c.x - d * scale, y: c.y - d * scale,
                                  width: d * scale * 2, height: d * scale * 2)
                context.stroke(Path(ellipseIn: rect), with: .color(.blue.opacity(0.25)), lineWidth: 1)
            }
            // walked track
            if tracker.track.count > 1 {
                var path = Path()
                path.move(to: project(tracker.track[0].x, tracker.track[0].y))
                for p in tracker.track.dropFirst() { path.addLine(to: project(p.x, p.y)) }
                context.stroke(path, with: .color(.gray), lineWidth: 2)
            }
            // start point
            let start = project(0, 0)
            context.fill(Path(ellipseIn: CGRect(x: start.x - 3, y: start.y - 3, width: 6, height: 6)),
                         with: .color(.gray))
            // mirror candidate (hollow)
            if let r = tracker.result, let m = r.mirror {
                let c = project(m.x, m.y)
                context.stroke(Path(ellipseIn: CGRect(x: c.x - 8, y: c.y - 8, width: 16, height: 16)),
                               with: .color(.orange), lineWidth: 2)
            }
            // estimated position
            if let r = tracker.result {
                let c = project(r.x, r.y)
                context.fill(Path(ellipseIn: CGRect(x: c.x - 7, y: c.y - 7, width: 14, height: 14)),
                             with: .color(.red))
                context.stroke(Path(ellipseIn: CGRect(x: c.x - 13, y: c.y - 13, width: 26, height: 26)),
                               with: .color(.red.opacity(0.6)), lineWidth: 1.5)
            }
            // current position
            let me = project(tracker.posX, tracker.posY)
            context.fill(Path(ellipseIn: CGRect(x: me.x - 6, y: me.y - 6, width: 12, height: 12)),
                         with: .color(.blue))
            // north indicator
            context.draw(Text("N").font(.caption.bold()), at: CGPoint(x: size.width - 14, y: 14))
        }
    }
}

// MARK: - Help

struct HelpView: View {
    var body: some View {
        NavigationStack {
            List {
                Section("やり方") {
                    Text("1. 「デバイス」で探したい機器を選ぶ")
                    Text("2. 「探索開始」を押して、機器がありそうな場所の周りを歩き回る")
                    Text("3. 直線だけでなく横方向にも動くと、左右の鏡像候補が消えて位置が確定する")
                    Text("4. 赤い丸が推定位置。スマホを体の前に離して持つと精度が上がる")
                }
                Section("しくみ") {
                    Text("電波の強さ（RSSI）から距離を推し量り、歩いた軌跡上の各地点からの距離を集めて、最もつじつまの合う一点を計算しています（多点測位）。あなたの移動は歩数計の距離とコンパスの方位で記録します。")
                }
                Section("限界") {
                    Text("・画面を開いている間だけ動作します（バックグラウンド不可）")
                    Text("・探せるのはBLEの電波を出している一般の機器です。AirTagやApple製品はアドレスが変わり続けるため対象にできません")
                    Text("・精度は数メートル級です。壁や体での電波の遮り、コンパスの狂いに影響されます")
                    Text("・位置情報は端末内だけで処理し、記録・送信しません")
                }
            }
            .navigationTitle("しくみと限界")
        }
    }
}
