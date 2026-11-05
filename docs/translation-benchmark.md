# ローカル翻訳エンジンの比較

## 目的

Kotobaの現行Apple Intelligenceと、Ollama用の初期モデルとして指定しているTranslateGemma 12B、追加候補のPLaMo 3 Translate 2Bを、同じMac・同じ公開テスト文で比較する。アプリ本体のエンジン切り替え実装はこの実験に含めない。

## 結果（2026年11月5〜6日）

Kotobaに追加する候補としては、PLaMo 3 Translate 2B Q4_K_Mを推奨する。今回のサンプルでは、Apple Intelligenceより高いCOMETスコアと短い応答時間を得た。TranslateGemma 12BとのCOMET差は95%信頼区間が0をまたぐため、品質の優劣は確認できない。一方、翻訳完了時間の中央値はTranslateGemmaの約1/6で、重みファイルも約1/4だった。

主評価は英→日がWMT24++、日→英がWMT23。それぞれ同じ100件を3モデルで測定した。COMETは高いほど良い指標で、正答率ではない。品質欄は拒否時の空・途中出力も含む全件スコア。時間は成功例の中央値で、初回ダウンロードや推論サーバー起動時間を含まない。

| モデル | COMET 英→日 | COMET 日→英 | 完了時間 英→日 | 完了時間 日→英 | 主評価200件の失敗 |
| --- | ---: | ---: | ---: | ---: | ---: |
| Apple Intelligence | 0.7924 | 0.8026 | 1.066秒 | 0.587秒 | 19件 |
| PLaMo 3 Translate 2B Q4_K_M | 0.8732 | 0.8361 | 0.294秒 | 0.186秒 | 0件 |
| TranslateGemma 12B Q4_K_M | 0.8743 | 0.8294 | 1.895秒 | 1.188秒 | 0件 |

最初の文字が出るまでの中央値は、英→日／日→英の順にAppleが0.956／0.583秒、PLaMoが0.070／0.057秒、TranslateGemmaが0.538／0.530秒。実行環境やOSの負荷が変われば時間も変わるため、数値はこのMacでの観測値として扱う。

| モデル | chrF++ 英→日（WMT24++） | chrF++ 日→英（WMT23） | COMET 日→英（補助WMT20） |
| --- | ---: | ---: | ---: |
| Apple Intelligence | 26.54 | 43.95 | 0.8033 |
| PLaMo 3 Translate 2B | 33.39 | 47.50 | 0.8272 |
| TranslateGemma 12B | 29.26 | 45.95 | 0.8308 |

両モデルが正常に翻訳した同一文だけを使ったCOMET差（PLaMo − 比較対象）も確認した。paired bootstrap 95%区間は次のとおり。探索的な比較であり、多重比較の補正は行っていない。

| 比較対象 | データセット | 正常翻訳のペア数 | 平均差 | 95%区間 |
| --- | --- | ---: | ---: | --- |
| Apple | WMT24++ 英→日 | 86 | +0.02195 | [+0.00045, +0.04058] |
| Apple | WMT23 日→英 | 95 | +0.02186 | [+0.00758, +0.03646] |
| TranslateGemma | WMT24++ 英→日 | 100 | −0.00116 | [−0.01781, +0.01339] |
| TranslateGemma | WMT23 日→英 | 100 | +0.00674 | [−0.00273, +0.01573] |

Appleは補助WMT20を含む300件中26件で安全フィルターによるエラーになった（WMT24++ 14件、WMT23 5件、WMT20 7件）。PLaMoとTranslateGemmaは各300件でエラー0件。正常翻訳だけの比較でもPLaMoがAppleを上回る傾向があり、全件の品質差を拒否件数だけで説明することはできない。

重みファイルはPLaMoが1,807,192,480 bytes（約1.81 GB）、TranslateGemmaが7,300,793,664 bytes（約7.30 GB）。実行時メモリ使用量の測定値ではない。両ファイルのSHA-256は固定リビジョンのHugging Face LFSオブジェクトと一致した。

各モデル300件、計900件の出力IDとCOMET値を検証済み。TranslateGemmaの手書きプロンプトは全300件でGGUFの公式テンプレートと一致することも確認した。詳細な数値、ハッシュ、実行環境は [translation-benchmark-results.json](translation-benchmark-results.json) に保存している。

この結果から8Bや31Bの性能、長文・専門用語の訳抜け、あらゆる文章での優劣は判断できない。アプリへの組み込みはまだ行っていない。

## データと評価方法

- 英→日：[Google WMT24++](https://huggingface.co/datasets/google/wmt24pp) の `en-ja_JP.jsonl`。リビジョン `fd7405c06494bc66a57b25f55d217a72f96e60dc`。998件からcanaryと `is_bad_source` を除外した960件のうち100件を抽出する。
- 日→英の主評価：[WMT23 General Translation](https://www2.statmt.org/wmt23/translation-task.html)の `ja-en`。ニュースに加えて会話・レビューなどの一般翻訳を対象とする。SacreBLEUで取得した日本語原文1,992件から100件を抽出する。参照訳は `refA` を使う。
- 日→英の補助評価：WMT20の `ja-en`。SacreBLEUで取得した993件から100件を抽出する。先に測定済みだったため、古いニュース中心のセットで傾向が変わるかを見る補助評価として残す。
- 英→日の参照訳を逆向きに使う方法を避け、日本語原文のテストセットを使用する。
- 抽出はPythonの `random.Random(20261105).sample`。全モデルで同一の計300件を使う。先の200件は英→日とWMT20日→英を交互に実行し、その後でWMT23の100件を追加する。3つのデータセットを個別に集計する。
- FLORES+も検討したが、公式配布のdevtest取得に認証が必要だったため採用しない。ゲートを迂回して取得しない。
- 意味の品質：[COMET-22 (`Unbabel/wmt22-comet-da`)](https://huggingface.co/Unbabel/wmt22-comet-da)。原文・生成訳・人手参照訳を用いる。正答率ではなく、値が高いほど良い品質指標。
- 表現の一致：[SacreBLEU](https://github.com/mjpost/sacrebleu)のchrF++ (`CHRF(word_order=2)`)。日本語の分かち書きに依存せず、文字n-gramと語n-gramを評価する。
- 速度：ローカルHTTP／アプリの呼び出し開始から、最初の空でない生成文字とストリーム完了までの壁時計時間。成功例の中央値・95パーセンタイルを使う。モデルごとに逐次実行し、翻訳推論を重ねない。
- 拒否・空応答・出力上限による打ち切り・通信エラーも記録する。全件スコアに加え、両モデルが成功した同一文だけを対象にCOMET差のpaired bootstrap 95%区間を求める（2,000回、seed固定）。拒否による差と、正常に訳せた文章での品質差を分ける。

この結果は各データセット100件のサンプル評価であり、テストセット全件の公式スコアではない。異なる言語方向・データセットのスコアを直接比較しない。公開ベンチマークの学習への混入は検証できない。論文全文・文書内の用語の統一・選択取得のUI品質は対象外。

## 実行環境とモデル

- Apple M4 Pro、48 GiBメモリ、macOS 27.2（26B123）
- Kotoba: `338e7464388e3aaca4f89a6bc340fad9a06d4aa5`
- llama.cpp: 公式macOS arm64配布 `b12125`、commit `7d516e25e`
- PLaMo: [`pfnet/plamo-3-translate-2b-GGUF`](https://huggingface.co/pfnet/plamo-3-translate-2b-GGUF)、Q4_K_M、revision `f2b4599dff9b3e45c62567eac15e83186b4cb64e`
- TranslateGemma: [`bullerwins/translategemma-12b-it-GGUF`](https://huggingface.co/bullerwins/translategemma-12b-it-GGUF)、Q4_K_M、revision `d7d1d8cc4ff53d4bc883ef33eae3894f07833b63`。Googleモデルのコミュニティ量子化版。
- llama.cpp側は全レイヤーをGPUに割り当て、context 8192、同時実行1、temperature 0.1、seed 42、出力上限1024トークン。専用のウォームアップを計測対象外で実行する。
- COMETはCPU・float32、batch size 8、読み込みworker 1で実行した。`num_workers=0` はCOMET 2.2.7とMacのPyTorchの組み合わせでエラーになったため、worker 1に変更して全900件の評価を完了した。推論サーバーは品質評価の前に終了した。
- Appleは現在の `TranslationEngine.swift` と `TranslationCore.swift` を直接コンパイルして呼び出す。アプリと同じ指示文・temperature 0.1を使い、原文ごとに会話を作り直す。seedや内部モデルの版は指定できない。最初の1件はコールド状態を含み得る。
- PLaMoには公式推奨のPFML3を直接渡す。TranslateGemmaにはKotobaと同じ公式形式の翻訳指示を、GGUF付属テンプレートと同じGemmaの特殊トークンで囲んでCompletions APIへ直接渡す。Chat Completions側による翻訳指示の二重適用を避ける。

TranslateGemmaはこのMacにOllamaが導入されていなかったため、PLaMoと同じllama.cppで測定する。Ollama対llama.cppの比較ではなく、候補モデルの比較である。アプリのOllama実行時と完全に同じ速度・結果を保証しない。

## 再実行

重み・データ・各文の出力・ログはGit対象外の `artifacts/translation-benchmark/` に保存する。公開原文やモデル重みをリポジトリへ追加しない。

```sh
uv venv --python 3.12 artifacts/translation-benchmark/comet-venv
uv pip install --python artifacts/translation-benchmark/comet-venv/bin/python \
  -r scripts/benchmark-requirements.txt
artifacts/translation-benchmark/comet-venv/bin/python \
  scripts/benchmark-translation.py prepare --count 100
python3 scripts/benchmark-download.py
```

llama.cppの[公式 `b12125`](https://github.com/ggml-org/llama.cpp/releases/tag/b12125) macOS arm64バイナリを取得し、対象モデルを1つずつ起動する。

```sh
llama-server -m artifacts/translation-benchmark/models/plamo-2b.gguf \
  -c 8192 -ngl 99 --parallel 1 --host 127.0.0.1 --port 18080 --metrics
python3 scripts/benchmark-translation.py run --model plamo-2b
```

PLaMoのサーバーを停止してから、モデルファイルを `gemma-12b.gguf` に差し替えて起動し、`--model gemma-12b` で同じ処理を実行する。両方を同時に起動しない。

```sh
xcrun swiftc -parse-as-library -O -module-cache-path .build/ModuleCache \
  Sources/Kotoba/TranslationCore.swift Sources/Kotoba/TranslationEngine.swift \
  scripts/benchmark-apple.swift -o artifacts/translation-benchmark/apple-benchmark
artifacts/translation-benchmark/apple-benchmark \
  artifacts/translation-benchmark/samples.jsonl \
  artifacts/translation-benchmark/apple-intelligence.jsonl
```

Pythonの実行器は既存IDをスキップして再開する。Swiftの実行器は追記式なので、再実行では出力先を新しいファイルにする。評価器は件数・IDの対応を検証し、重複や不完全な測定を拒否する。

```sh
export HF_HOME="$PWD/artifacts/translation-benchmark/hf-cache"
artifacts/translation-benchmark/comet-venv/bin/python -c \
  'from comet import download_model; print(download_model("Unbabel/wmt22-comet-da"))'
artifacts/translation-benchmark/comet-venv/bin/python \
  scripts/score-translation-benchmark.py --comet-checkpoint /absolute/path/to/model.ckpt
```

原文・参照訳・抽出済みサンプルのSHA-256は `samples-manifest.json`、取得したモデルの情報は `*.gguf.download.json`、各文の計測結果はモデル名のJSONL、集計は `summary.json` に保存する。
