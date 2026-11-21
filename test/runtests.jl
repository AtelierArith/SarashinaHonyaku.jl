using Test
using HTTP
using JSON
using Sarashina
using SarashinaHonyaku

# ---------------------------------------------------------------------------
# 16 kHz / 16 bit / mono の WAV を組み立てるテスト用ヘルパー
# ---------------------------------------------------------------------------
function wav_bytes(seconds::Real; rate::Int = 16000, amp::Int = 1200)
    nsamples = round(Int, seconds * rate)
    io = IOBuffer()
    payload = nsamples * 2
    write(io, "RIFF"); write(io, UInt32(36 + payload)); write(io, "WAVE")
    write(io, "fmt "); write(io, UInt32(16)); write(io, UInt16(1)); write(io, UInt16(1))
    write(io, UInt32(rate)); write(io, UInt32(rate * 2)); write(io, UInt16(2)); write(io, UInt16(16))
    write(io, "data"); write(io, UInt32(payload))
    for i in 1:nsamples
        write(io, Int16(round(Int, amp * sin(2π * 440 * i / rate))))
    end
    return take!(io)
end

const ASR_TEXT = "こんにちは。今日はいい天気ですね。"
const EN_TEXT = "Hello. It's a beautiful day today."
const REQUESTS = Any[]

function mock_handler(req::HTTP.Request)
    push!(REQUESTS, (method = req.method, target = req.target, body = copy(req.body)))
    if req.target == "/v1/audio/transcriptions"
        return HTTP.Response(200, ["Content-Type" => "application/json"],
                             JSON.json(Dict("text" => ASR_TEXT)))
    elseif req.target == "/v1/translate"
        return HTTP.Response(200, ["Content-Type" => "application/json"],
                             JSON.json(Dict("translated_text" => EN_TEXT)))
    end
    return HTTP.Response(404, "unexpected")
end

mock = HTTP.serve!(mock_handler, "127.0.0.1", 0; verbose = -1)
mock_port = Int(HTTP.port(mock))

app = SarashinaHonyaku.App(;
    client = Sarashina.Client(api_key = "test-key", base_url = "http://127.0.0.1:$mock_port"))

app_server = HTTP.serve!(
    (req) -> SarashinaHonyaku.guarded(SarashinaHonyaku.handler, app, req),
    "127.0.0.1", 0; verbose = -1)
app_port = Int(HTTP.port(app_server))
base = "http://127.0.0.1:$app_port"

@testset "SarashinaHonyaku" begin
    @testset "health" begin
        resp = HTTP.get("$base/api/health"; status_exception = false)
        @test resp.status == 200
        data = JSON.parse(String(resp.body); dicttype = Dict{String,Any})
        @test data["ok"] == true
        @test data["has_api_key"] == true
    end

    @testset "static index" begin
        resp = HTTP.get("$base/"; status_exception = false)
        @test resp.status == 200
        @test occursin("text/html", HTTP.header(resp, "Content-Type"))
        @test occursin("Sarashina 音声翻訳", String(resp.body))
    end

    @testset "segment: ASR then translate" begin
        empty!(REQUESTS)
        body = wav_bytes(0.5)
        resp = HTTP.post("$base/api/segment?keywords=Sarashina,%E6%9B%B4%E7%B4%9A%E6%97%A5%E8%A8%98",
                         ["Content-Type" => "audio/wav"], body; status_exception = false)
        @test resp.status == 200
        data = JSON.parse(String(resp.body); dicttype = Dict{String,Any})
        @test data["ja"] == ASR_TEXT
        @test data["en"] == EN_TEXT
        @test data["duration"] ≈ 0.5 atol = 0.01

        @test length(REQUESTS) == 2
        @test REQUESTS[1].target == "/v1/audio/transcriptions"
        @test REQUESTS[2].target == "/v1/translate"
        @test occursin("keywords", String(REQUESTS[1].body))
        translate_req = JSON.parse(String(REQUESTS[2].body); dicttype = Dict{String,Any})
        @test translate_req["text"] == ASR_TEXT
        @test translate_req["source_lang"] == "ja"
        @test translate_req["target_lang"] == "en"
    end

    @testset "segment rejects non-WAV" begin
        resp = HTTP.post("$base/api/segment", ["Content-Type" => "audio/wav"], "hello"; status_exception = false)
        @test resp.status == 400
        @test occursin("WAV", String(resp.body))
    end

    @testset "segment rejects wrong sample rate" begin
        resp = HTTP.post("$base/api/segment", ["Content-Type" => "audio/wav"], wav_bytes(0.5; rate = 48000); status_exception = false)
        @test resp.status == 400
    end

    @testset "segment rejects too long audio" begin
        resp = HTTP.post("$base/api/segment", ["Content-Type" => "audio/wav"], wav_bytes(61); status_exception = false)
        @test resp.status == 400
        @test occursin("60", String(resp.body))
    end

    @testset "translate endpoint" begin
        resp = HTTP.post("$base/api/translate", ["Content-Type" => "application/json"],
                         JSON.json(Dict("text" => ASR_TEXT)); status_exception = false)
        @test resp.status == 200
        @test JSON.parse(String(resp.body); dicttype = Dict{String,Any})["en"] == EN_TEXT
    end

    @testset "unknown path" begin
        @test HTTP.get("$base/nope"; status_exception = false).status == 404
    end
end

@testset "split_for_translate" begin
    @test SarashinaHonyaku.split_for_translate("短い文。") == ["短い文。"]
    pieces = SarashinaHonyaku.split_for_translate(repeat("あ", 12_000))
    @test length(pieces) == 3
    @test all(p -> length(p) <= 5000, pieces)
    @test join(pieces) == repeat("あ", 12_000)
    sentences = SarashinaHonyaku.split_for_translate(join(fill("これは文です。", 600)))
    @test all(p -> length(p) <= 5000, sentences)
end

close(app_server)
close(mock)
