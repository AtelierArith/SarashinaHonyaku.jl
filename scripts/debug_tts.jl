# TTS で音声を生成し、ASR → 翻訳のパイプラインを通しで確認するデバッグスクリプト。
#
#   julia --project=. scripts/debug_tts.jl "確認したい日本語の文章"
#
# Sarashina TTS の出力は 24 kHz なので、ffmpeg で ASR が要求する
# 16 kHz・16 bit PCM・モノラルに変換してから `transcribe_and_translate` に渡す。
using SarashinaHonyaku
using Sarashina
using Sarashina: Client

const DEFAULT_TEXT = "こんにちは。今日はいい天気ですね。Sarashina の音声認識と翻訳をテストしています。"

function main(args::Vector{String})
    text = isempty(args) ? DEFAULT_TEXT : join(args, " ")
    length(text) <= 700 || error("TTS の入力は 700 文字以下にしてください（現在 $(length(text)) 文字）")

    app = App()
    client = SarashinaHonyaku.get_client(app)

    mktempdir() do dir
        raw = joinpath(dir, "tts.wav")
        wav16 = joinpath(dir, "tts16k.wav")

        @info "TTS で音声を生成します" chars = length(text)
        Sarashina.speak(client, text; voice = "ja_f_1", response_format = "wav", path = raw)

        ffmpeg = Sys.which("ffmpeg")
        ffmpeg === nothing && error("ffmpeg が見つかりません。`brew install ffmpeg` などで導入してください。")
        run(`$ffmpeg -y -loglevel error -i $raw -ar 16000 -ac 1 -sample_fmt s16 $wav16`)

        bytes = read(wav16)
        duration = SarashinaHonyaku.audio_duration(bytes)
        duration === nothing && error("16 kHz / 16 bit / モノラルの WAV を作成できませんでした。")

        println()
        println("入力  : ", text)
        println("音声  : ", round(duration; digits = 2), " 秒 / ", length(bytes), " バイト")

        t0 = time()
        result = SarashinaHonyaku.transcribe_and_translate(app, bytes)
        println("ASR   : ", result.ja)
        println("翻訳  : ", result.en)
        println("所要  : ", round(time() - t0; digits = 2), " 秒")
    end
end

main(ARGS)
