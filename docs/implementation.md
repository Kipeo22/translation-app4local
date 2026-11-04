# 専用アプリ初版の採用内容

2026-11-04。「専用アプリにまとめたい」という指定を受け、以前のOllama中心の仕様案から、既に利用中のApple Intelligenceを直接使うMacアプリを先に実装した。

## 現時点での構成

- SwiftUI + AppKit、macOS 26以降、Apple Silicon。
- 翻訳はFoundation ModelsのSystemLanguageModel。文章ごとに独立したセッションを使い、ストリーミングの累積スナップショットを専用ウィンドウへ反映する。
- 任意でOllamaのローカルChat APIに対応。推論モデルの導入は自動で行わない。
- Control+Option+T（設定でR／Yに変更可能）で選択テキストを取得。Carbonの登録型ホットキーを使い、通常のキー入力は監視しない。
- AXUIElementでの選択取得、任意の自動コピー補助、NSPasteboardからの手動貼り付け、NSServiceの受信経路。
- 900×730ptを初期値にしたリサイズ可能なウィンドウ。訳文は初期21pt、16〜32ptで調整可能。
- 翻訳の中断、完了判定、エラー表示、コピー、モデル待ち時間の計測。
- UserDefaultsで設定を保存。履歴は初期オフ、有効時のみApplication Support/Kotoba/history.jsonへ最大500件保存。
- 外部パッケージ・Web UI・外部APIキーなし。

## 元の仕様案から変えた点

- 標準エンジンをOllamaからApple Intelligenceのオンデバイスモデルへ変更した。
- MacのOS更新を確認し、OS下限を26にした。
- 履歴は小規模な個人用のため、SwiftDataではなくJSONファイルで初版を実装した。
- グローバルショートカットは追加依存を避け、Carbonで登録した。
- 履歴の検索、任意のキー組み合わせの録画、ログイン時起動、OCR、長文分割、クラウドモデルの直接接続は未実装。

## 確認できたことと未確認のこと

アプリのビルドと6件の自動テストを実行済み。実際のオンデバイスモデルで「Please do not share this document until Friday. The budget is 250 dollars.」を翻訳し、否定・金曜日の条件・250ドルを保持した訳文が返ることを確認した。1回目の実測では最初の文字1.34秒、完了1.36秒だった。

UI調整後に同じ短文で再確認した結果、最初の文字0.92秒・完了0.94秒だった。レポートは `artifacts/translation-smoke.json`。Control+Option+Tのキー登録も成功した。

これは同じ短文を2回使った動作検証。一般的な翻訳精度、速度分布、Naniや元のショートカットに対する優位性を示す評価ではない。OSの権限が必要な他アプリからの選択取得は、ユーザーの許可後に確認する。

## 参照

- [Apple: LanguageModelSession](https://developer.apple.com/documentation/foundationmodels/languagemodelsession)
- [Apple: 途中生成のスナップショット](https://developer.apple.com/documentation/foundationmodels/languagemodelsession/responsestream)
- [Apple: Private Cloud Computeの追加条件](https://developer.apple.com/documentation/foundationmodels/adding-server-side-intelligence-with-private-cloud-compute)
- [Ollama: Chat API](https://docs.ollama.com/api/chat)
