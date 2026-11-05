# 開発・貢献ガイド

不具合報告、改善案、Pull Requestを歓迎します。開発環境と起動方法は[README.md](README.md)を参照してください。

## コードの読み方

| ファイル | 役割 |
| --- | --- |
| `Sources/Kotoba/KotobaApp.swift` | 起動、ウィンドウ、メニューバー、サービス、選択翻訳の呼び出し |
| `Sources/Kotoba/TranslatorView.swift` | 原文・訳文、設定、履歴の画面 |
| `Sources/Kotoba/AppModel.swift` | 翻訳の実行状態、設定、履歴の保存 |
| `Sources/Kotoba/TranslationEngine.swift` | Foundation ModelsとOllamaによる翻訳 |
| `Sources/Kotoba/TranslationCore.swift` | 翻訳方向の判定、Ollamaのストリーム処理 |
| `Sources/Kotoba/CaptureService.swift` | Accessibility、コピー補助、グローバルショートカット |
| `Tests/KotobaTests/TranslationCoreTests.swift` | 言語判定とストリーム処理の自動テスト |

[実装メモ](docs/implementation.md)には採用した構成と検証範囲を記載しています。[初期仕様案](docs/specification.md)には未実装の機能も含まれます。

## 不具合の報告

次の情報を添えてIssueを作成してください。

- macOS、Xcode / Swiftのバージョンと対象コミット。
- 使用エンジン。Ollamaの場合は本体のバージョンとモデル名。
- 再現手順、期待した動作、実際の動作。
- 選択取得の問題では、対象アプリ、権限状態、直接取得・コピー補助・サービスのどの経路か。

再現に使う文章は公開可能なダミーに置き換え、履歴ファイル、認証情報、個人情報を含む画面画像は添付しないでください。安全上の問題を見つけた場合、機密情報や攻撃に直結する詳細を公開Issueへ載せないでください。

## 変更と検証

変更は1つの目的にまとめ、大きな機能追加は先にIssueで提案してください。コミットは`fix: 選択取得時のエラー表示を修正`のようにConventional Commits形式で記述します。Pull Requestには変更理由、実施した確認と結果、未確認の点を記載してください。

```sh
swift test --cache-path .build/package-cache
zsh scripts/build-app.sh
codesign --verify --verbose dist/Kotoba.app
```

自動テストは言語判定とOllama応答の処理を対象にしており、実モデルの翻訳品質やOS権限を検証しません。画面・選択取得・クリップボード・履歴・Spacesに関わる変更は、該当操作を実機でも確認してください。確認できない項目は未確認と記載します。実モデルの比較では、原文、モデル、実行環境を揃え、単発の速度を一般的な性能として扱わないでください。

翻訳内容の外部送信、取得範囲の拡張、履歴保存の変更は、ユーザーが判断できる説明と操作を含めて提案してください。

## ライセンス

貢献するコード・文書を[MIT License](LICENSE)で提供できることを確認してください。第三者のコードや素材を含める場合は、出典とライセンスを明示してください。モデルの重み、ビルド成果物、署名鍵、個人の翻訳履歴はコミットしないでください。
