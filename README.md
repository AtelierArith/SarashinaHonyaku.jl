# SarashinaHonyaku.jl

日本語の音声を **文字起こし** し、そのまま **英語に翻訳** するローカル Web アプリです。
音声認識と翻訳には [Sarashina API](https://docs.sarashina.ai/) を
[Sarashina.jl](https://github.com/AtelierArith/Sarashina.jl) 経由で使います。

- ブラウザでマイク入力を取得し、発話の切れ目（無音）で自動的に区切って送信
- 区切った音声を 16 kHz / 16 bit / モノラルの WAV にして `sarashina3.2-asr` で文字起こし
- 得られた日本語を `sarashina3.2-translate` で英語に翻訳
- 日本語と英語を並べて表示（コピー可）

サーバーは Julia の `HTTP.jl` だけで動く小さなものです。ページは `web/index.html` の 1 枚だけで、
ビルドや Node.js は不要です。

## 必要なもの

- Julia 1.10 以上（動作確認: 1.13.4）
- Sarashina API キー（https://chat.sarashina.ai/dashboard/api-keys で発行）
- `ffmpeg`（`scripts/debug_tts.jl` を使う場合のみ。通常の Web アプリ動作には不要）

## セットアップ

Sarashina.jl は GitHub から取得します（開発版の `main` ブランチを参照）。

```sh
cd SarashinaHonyaku.jl
julia --project=. -e 'using Pkg; Pkg.add(url="https://github.com/AtelierArith/Sarashina.jl"); Pkg.instantiate()'
```

このコマンドは `Project.toml` の `[sources]` を次のように書き換えます。

```toml
[sources]
Sarashina = {rev = "main", url = "https://github.com/AtelierArith/Sarashina.jl"}
```

最新の `main` を取り込み直す場合:

```sh
julia --project=. -e 'using Pkg; Pkg.update("Sarashina")'
```

ローカルで Sarashina.jl を編集しながら動かす場合だけ、次のように開発版として参照します。

```sh
julia --project=. -e 'using Pkg; Pkg.develop(path="../Sarashina.jl"); Pkg.instantiate()'
```

プロジェクト直下に `.env` を作り、API キーを設定します（`.env` は git 管理外です）。

```
SARASHINA_API_KEY=...
```

環境変数 `SARASHINA_API_KEY` でも構いません。キーはクライアント側（Sarashina.jl）が
環境変数 → `.env` の順に読みます。

## 起動

```sh
julia --project=. bin/server.jl
# http://127.0.0.1:8080 をブラウザで開く
```

ポートやホストを変える場合:

```sh
julia --project=. bin/server.jl --port 9000 --host 127.0.0.1
```

ブラウザで「録音開始」を押し、日本語で話しかけてください。0.8 秒ほど無音が続くと、
そこまでを 1 区切りとして自動送信し、文字起こしと英訳を追加します。録音中でも
「区切る」で即座に送信できます。「停止」を押した場合は、その時点までの音声を必ず送信します。

マイクが使えない環境でも、「サンプルで試す」を押すと同梱の `web/sample.wav` を送信して
日本語＋英訳の表示を確認できます。まずこれで表示を確認し、うまくいかない場合は
ステータス表示（録音中・認識中・エラー）を確認してください。

マイクは画面上部の「マイク」プルダウンから選べます。初回はマイクの許可後にデバイス名が
表示されます。録音中に切り替えると自動で再接続し、選択はブラウザに保存されます。

設定欄では次の値を変えられます。

| 設定 | 説明 |
|---|---|
| 固有名詞 | ASR の `keywords`。カンマ区切りで認識を寄せたい語を指定（初期値 `RustCall.jl, JuliaCon, Julia, Sarashina`） |
| 無音とみなす音量 | 区切りの閾値。周囲がうるさい場合は上げる。開始時に自動調整も可能 |
| 区切る無音の長さ | 発話の切れ目と判定する無音時間（0.5〜1.8 秒） |

## 構成

```
Project.toml
bin/server.jl              # エントリポイント
src/SarashinaHonyaku.jl    # HTTP サーバー、WAV 検証、ASR → 翻訳
web/index.html             # 録音・VAD・表示（素の JS）
scripts/debug_tts.jl       # TTS で音声を作り、ASR → 翻訳を通しで確認
test/runtests.jl           # モックサーバーによるオフラインテスト
```

API:

| メソッド・パス | 内容 |
|---|---|
| `GET /` | `web/index.html` |
| `GET /api/health` | `{"ok": true, "has_api_key": bool}` |
| `POST /api/segment?keywords=a,b` | ボディに 16 kHz WAV。`{"ja", "en", "duration", "elapsed"}` を返す |
| `POST /api/translate` | `{"text": "..."}` を受けて `{"en": "..."}` を返す |

## TTS を使ったデバッグループ

マイクを使わずに、Sarashina TTS で生成した音声をそのまま ASR → 翻訳に通せます。

```sh
julia --project=. scripts/debug_tts.jl
julia --project=. scripts/debug_tts.jl "確認したい日本語の文章"
```

TTS の出力は 24 kHz なので、スクリプト内で `ffmpeg` により 16 kHz・16 bit・モノラルへ変換してから
`transcribe_and_translate` に渡します。実行例:

```
入力  : こんにちは。今日はいい天気ですね。Sarashina の音声認識と翻訳をテストしています。
音声  : 6.46 秒 / 206798 バイト
ASR   : こんにちは、今日はいい天気ですね。さらしなの音声認識と翻訳をテストしています。
翻訳  : Hello, it's a beautiful day today. I'm testing Sarashina's speech recognition and translation features.
所要  : 1.22 秒
```

## テスト

```sh
julia --project=. -e 'using Pkg; Pkg.test()'
```

モックの Sarashina サーバーを立てるため、API キーなしで実行できます。
静的配信、WAV の検証、ASR → 翻訳の呼び出し、エラー応答、長文分割を確認します。

## 制限と注意

- ASR は 1 リクエスト **60 秒 / 2 MiB** まで。アプリは 20 秒で強制的に区切ります。
- 翻訳は 1 リクエスト 5,000 文字まで。超える場合は文単位で分割して送ります。
- レート制限は ASR・翻訳ともに 30 RPM です。短い間隔で連続送信すると 429 になることがあります
  （Sarashina.jl が `Retry-After` に従って自動再試行します）。
- 音声はローカルの Julia サーバーから Sarashina API に送られます。機密性の高い音声の扱いに注意してください。
- このアプリは SB Intuitions とは関係のない非公式のものです。
# SarashinaHonyaku.jl
