# LivePTV を Xcode で iPad にインストールする手順

Xcode の入った Mac を使って、LivePTV を iPad に直接インストールする手順です。
Swift Playgrounds 版と違い、最適化ありのビルド(Release)で動くので、解析が約2倍速くなります。

## 用意するもの

- **Xcode の入った Mac**
  - iPad の iPadOS に対応したバージョンが必要です。iPadOS が新しいのに Xcode が古いと、実行先に iPad が出ません。
- **Apple ID**
  - 無料のものでかまいません。
- **iPad と Mac をつなぐ USB ケーブル**
- **LivePTV フォルダ一式**
  - 開発に使っているフォルダと同じものです。中身の構成は次のとおりです。このまま使ってください。

```
LivePTV/
  LivePTV.xcodeproj     ← Xcode でこれを開く
  App/                  ← アプリの入口・設定(カメラのWi-Fi情報もここ)
  LivePTVKit/           ← 解析部分のパッケージ(Package.swift はこの中)
  docs/  scripts/  README.md
```

## 1. フォルダを Mac に用意する

1. Finder で iCloud Drive の **`LivePTV` > `別のMacへ移すもの`** を開きます。
2. **`LivePTV.zip`** を「書類」など iCloud の外にドラッグしてコピーします。
   - 雲のアイコンが付いている場合は、ダウンロードが終わってから行ってください。
3. コピーした zip をダブルクリックして展開します。`LivePTV` フォルダができます。
4. 以降は、展開したこのフォルダを使います。

フォルダのままコピーすると、iCloud のダウンロードが途中のまま一部のファイルが欠けることがあります。その状態で開くと、`project.pbxproj should exist` や `Missing package product` のエラーになります。1つのファイルである zip なら、全部そろってから届きます。

iCloud Drive の上で直接ビルドもしないでください。Xcode が作る大量のファイルが同期されて、失敗の原因になります。

## 2. Xcode で開いて署名を設定する

1. `LivePTV.xcodeproj` をダブルクリックします。
2. 初回はパッケージの読み込みに数十秒かかります。
   - 左下に「Resolving Package Graph」と出ます。
   - このフォルダの中にあるパッケージを使うので、ダウンロードはありません。
3. **Xcode > Settings… > Accounts** で、左下の「+」から自分の Apple ID を追加します。
4. 左のナビゲータ(見えなければ ⌘1)で、いちばん上の青い **LivePTV** を選びます。
5. **TARGETS > LivePTV > Signing & Capabilities** を開き、次のように設定します。
   - **TARGETS** の LivePTV は、設定画面の左端の列にあります(アプリのアイコンが付いている方)。**PROJECT** の方ではありません。
   - タブのすぐ下にある「All / Debug / Release」は **All** を選びます。
   - 「Automatically manage signing」にチェックを入れます。
   - **Team** で自分の Apple ID を選びます。無料の Apple ID なら「(Personal Team)」と付いたものです。
   - 赤いエラーが消えれば準備完了です。
   - `Failed to register bundle identifier` と出たら、**Bundle Identifier** の末尾を変えてください(例: `com.liveptv.ipad.7a83ffda` → `com.liveptv.ipad.7a83ffda2`)。

## 3. iPad の準備

1. iPad を USB で Mac につなぎます。
2. iPad に「このコンピュータを信頼しますか?」と出たら「信頼」を押し、パスコードを入力します。
3. iPad で **設定 > プライバシーとセキュリティ > デベロッパモード** をオンにします。
   - iPad が再起動します。再起動後に「オンにする」を押します。
   - この項目は、Xcode と一度つないだ後に表示されます。見当たらなければ、手順4で実行先を選んだ後にもう一度確認してください。

## 4. インストールして起動する

1. Xcode のウインドウ上部中央にある実行先で、次の2つを選びます。
   - 左側(スキーム)は、アプリのアイコンが付いた **LivePTV** を選びます。CameraKit や ace-probe などは選びません。
   - 右側(デバイス名の部分)は、つないだ iPad を選びます。
   - 初回は「Preparing iPad…」と表示され、準備に数分かかることがあります。
2. 左上の ▶︎ ボタン(⌘R)を押します。
   - ビルドとインストールが終わると、iPad でアプリが起動します。
   - 解析を速くするため、Release ビルドで実行するように設定してあります。
3. 無料の Apple ID で「信頼されていないデベロッパ」と出た場合:
   1. iPad の **設定 > 一般 > VPNとデバイス管理** で、自分の Apple ID を選んで「信頼」を押します。
   2. Xcode でもう一度 ▶︎ を押します。
4. 起動後に「ローカルネットワーク」や「カメラ」へのアクセスを求められたら、「許可」を押します。

一度インストールしたら、USB を外してもアプリは使えます。

## 使い方の要点

- **USB カメラを使う場合:** Ace Pro 2 を iPad の USB-C につなぎ、カメラ側を Web カメラモードにします。アプリのソースで「USB camera」を選びます。
- **アンサンブル相関:** 左パネルの「Ensemble correlation」をオンにします。
- **解析結果の保存先:** 「ファイル」アプリの **このiPad内 > LivePTV > Sessions** です。保存先フォルダはアプリ内で変更できます。

## 瓶・水槽越しの計測（v0.7 の補正機能）

- **背景除去**: 左パネルの「Background removal」は「Running mean」のままにします。瓶の反射・ラベル・傷のように動かないものが、映像から差し引かれます。最初の約 1 秒（30 フレーム）は平均を作る時間です。
- **瓶の輪郭を指定する**: 「Container」で「Round bottle」を選び、「Mark container outline」を押します。映像の上で、瓶の外側の左端から右端までをドラッグします。上端は水面のすぐ下、下端は底のすぐ上にします。
- **瓶の寸法と材質**: 「Analysis settings › Container and refraction」で、外径（mm）、壁の厚さ、材質（ガラス・アクリル・PET など）、液体（水・グリセリンなど）を入力します。長さの尺度（mm/px）は外径から自動で決まり、屈折による見かけの拡大も補正されます。
- **除外したい場所**: 「Add exclusion」を押して、その場所をドラッグで囲みます。
- **マスクの確認**: 「Show masked areas」で、計測から外している部分が色付きで表示されます（青: 瓶の外と壁際、橙: グレア、赤: 動く光の点）。
- 記録を止めると、補正の内容と品質の図（`figure_quality`）、論文用の手法説明（`methods.txt`）が保存されます。演算の詳細は [METHODS_ja.md](METHODS_ja.md) にあります。

## 注意

- **無料の Apple ID では、7日でアプリが起動しなくなります。**
  - その場合は、もう一度 Mac につないで Xcode の ▶︎ を押せば入れ直せます。
  - 測定データと設定は消えません。
  - 有料の Apple Developer Program なら、期限は1年です。
- **Swift Playgrounds 版とは別のアプリとして入ります。** 設定と保存データは、それぞれ別です。
- **カメラの Wi-Fi への自動参加は、初期設定でオフにしてあります。** 無料の Apple ID でも署名できるようにするためです。
  - カメラの Wi-Fi を使うときは、iPad の **設定 > Wi-Fi** で `Ace Pro 2 …` に手動で接続してください。アプリに戻ると、自動で接続を試みます。
  - 有料アカウントなら自動参加をオンにできます。**Signing & Capabilities** の「+ Capability」から、次の2つを追加してください。
    - Hotspot Configuration
    - Access WiFi Information
- **カメラの Wi-Fi パスワードについて:** パスワードは `App/Camera.local.plist` に入っていて、アプリに組み込まれます。このフォルダを他人に渡すときは、このファイルを削除してください。

## うまくいかないとき

| 症状 | 対処 |
|---|---|
| 実行先に iPad が出ない / Unsupported OS version | Xcode を最新版に更新する。ケーブルと「信頼」を確認する |
| `Failed to register bundle identifier` | Bundle Identifier の末尾を変える |
| `Personal development teams … do not support …` | Build Settings で **Code Signing Entitlements** を空にする |
| `One of … project.pbxproj should exist` | iCloud からのコピーが途中だった。zip を展開し直して、そのフォルダを開く |
| `Missing package product 'LivePTVKit'` | **File > Packages > Reset Package Caches** を実行する。`LivePTVKit` フォルダが `LivePTV.xcodeproj` の隣にあり、中に `Package.swift` があるか確認する。iCloud からのダウンロードが途中だった場合は、コピーし直す |
| 起動時に「検証できません」 | iPad をインターネットにつないで、VPNとデバイス管理で「信頼」を押す |
| 動きが遅い | 上部の **LivePTV > Edit Scheme… > Run > Build Configuration** が **Release** になっているか確認する |
