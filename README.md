# BLE方向探知 (BLEFinder)

歩きながらBLEの電波の強さ（RSSI）を集めて、発信源の方向と位置を推定するiPhoneアプリ。

## しくみ

- 対象デバイスの広告電波のRSSIを連続受信し、路程損失モデルで距離に変換する
- 自分の移動は歩数計（距離）＋コンパス（方位）の推測航法で記録する
- 軌跡上の各地点からの推定距離に最もつじつまの合う一点を、最小二乗（ガウス・ニュートン法）で求める
- 直線移動だけだと進路の左右に鏡像候補が残る。横方向にも動くと解ける（アプリ内でも警告する）

少年の発案そのまま:「動きながらRSSIを取れば、移動方向と距離変化の関係から方位が分かる」。

## 限界

- iOSの制約でフォアグラウンド動作のみ
- AirTag / Apple製品はアドレスが回転するため対象不可。一般のBLEビーコン・機器向け
- 精度は数メートル級。RSSIのノイズ、多重反射、体による遮蔽、コンパス誤差の影響を受ける
- iPhoneにBLEの指向性アンテナ（AoA）は無いので、UWB式の直接の方向検出はできない。本方式はその代替

## ビルドとインストール

GitHub Actions（`.github/workflows/build.yml`）が未署名IPAをビルドする。Macは不要。

1. Actionsの最新runから `BLEFinder-ipa` artifact（BLEFinder-unsigned.ipa）をダウンロード
2. AltStore / SideStore などのサイドロードでインストール
3. 初回起動時に Bluetooth / モーション / 位置（方位用）の許可を与える

## 構成

- `ios/project.yml` — XcodeGen定義
- `ios/Sources/Scanner.swift` — BLEスキャンとRSSI平滑化（中央値）
- `ios/Sources/Tracker.swift` — 推測航法とサンプル収集
- `ios/Sources/Solver.swift` — 多点測位ソルバ（外れ値除去＋鏡像判定つき）
- `ios/Sources/ContentView.swift` — UI（デバイス一覧 / 探索マップ / 説明）
