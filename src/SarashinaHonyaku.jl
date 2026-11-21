module SarashinaHonyaku

using HTTP
using JSON
using DotEnv
using Sarashina
using Sarashina: Client, SarashinaError

export App, serve, main

const WEB_DIR = normpath(joinpath(@__DIR__, "..", "web"))
const MAX_AUDIO_BYTES = 2 * 1024 * 1024      # Sarashina ASR の上限
const MAX_TRANSLATE_CHARS = 5000             # Sarashina Translate の上限
const ASR_SAMPLE_RATE = 16000

"""
    App(; client = nothing)

Application state. `client` is a `Sarashina.Client`; when `nothing`, it is created lazily
from `SARASHINA_API_KEY` (environment variable or `.env`) on the first request.
"""
mutable struct App
    client::Union{Nothing,Client}
end

App(; client = nothing) = App(client)

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------

function get_client(app::App)
    app.client === nothing || return app.client
    app.client = make_client()
    return app.client
end

# `Client()` reads `SARASHINA_API_KEY` from the environment or the current directory's `.env`.
# When the server is started from elsewhere, fall back to this project's `.env`.
function make_client()
    try
        return Client()
    catch err
        envfile = joinpath(dirname(@__DIR__), ".env")
        if isfile(envfile)
            cfg = DotEnv.config(envfile)
            if haskey(cfg, "SARASHINA_API_KEY") && !isempty(cfg["SARASHINA_API_KEY"])
                return Client(api_key = String(cfg["SARASHINA_API_KEY"]))
            end
        end
        throw(ArgumentError(string("SARASHINA_API_KEY が設定されていません。環境変数か .env に設定してください。 (", sprint(showerror, err), ")")))
    end
end

has_api_key(app::App) = app.client !== nothing || begin
    try
        get_client(app)
        true
    catch
        false
    end
end

_u16(b, i) = Int(b[i]) | (Int(b[i + 1]) << 8)
_u32(b, i) = Int(b[i]) | (Int(b[i + 1]) << 8) | (Int(b[i + 2]) << 16) | (Int(b[i + 3]) << 24)

is_wav(bytes::AbstractVector{UInt8}) =
    length(bytes) >= 12 && String(bytes[1:4]) == "RIFF" && String(bytes[9:12]) == "WAVE"

"""
    audio_duration(bytes)

Duration in seconds of a canonical 44-byte-header PCM WAV, or `nothing` if the header
is not the format the ASR API requires (16 kHz / 16-bit / mono / PCM).
"""
function audio_duration(bytes::AbstractVector{UInt8})
    is_wav(bytes) || return nothing
    length(bytes) >= 44 || return nothing
    audio_format = _u16(bytes, 21)
    channels = _u16(bytes, 23)
    sample_rate = _u32(bytes, 25)
    bits = _u16(bytes, 35)
    (audio_format == 1 && channels == 1 && sample_rate == ASR_SAMPLE_RATE && bits == 16) || return nothing
    return (length(bytes) - 44) / (ASR_SAMPLE_RATE * 2)
end

"""
    split_for_translate(text; limit = MAX_TRANSLATE_CHARS)

Split `text` into pieces of at most `limit` characters, preferring sentence boundaries.
"""
function split_for_translate(text::AbstractString; limit::Int = MAX_TRANSLATE_CHARS)
    length(text) <= limit && return String[String(text)]
    sentences = split(String(text), r"(?<=[。．！？!?\n])"; keepempty = false)
    chunks = String[]
    buf = IOBuffer()
    n = 0
    for s in sentences
        while length(s) > limit
            # 1 文が上限を超える場合は機械的に分割する
            n > 0 && (push!(chunks, String(take!(buf))); n = 0)
            push!(chunks, first(s, limit))
            s = chop(s; head = limit, tail = 0)
        end
        if n + length(s) > limit
            push!(chunks, String(take!(buf)))
            n = 0
        end
        write(buf, s)
        n += length(s)
    end
    n > 0 && push!(chunks, String(take!(buf)))
    return isempty(chunks) ? String[String(text)] : chunks
end

"""
    translate_long(client, text; source_lang = "ja", target_lang = "en")

`Sarashina.translate` but splits text longer than the 5,000-character API limit.
"""
function translate_long(client, text::AbstractString; source_lang = "ja", target_lang = "en")
    isempty(strip(text)) && return ""
    parts = map(split_for_translate(text)) do chunk
        Sarashina.translate(client, chunk; source_lang = source_lang, target_lang = target_lang)
    end
    return join(parts, " ")
end

"""
    transcribe_and_translate(app, wav; keywords = nothing)

Transcribe 16 kHz mono WAV bytes with Sarashina ASR, then translate the transcript to English.
Returns `(ja = ..., en = ...)`.
"""
function transcribe_and_translate(app::App, wav::AbstractVector{UInt8}; keywords = nothing)
    client = get_client(app)
    ja = Sarashina.transcribe(client, wav; response_format = "json", keywords = keywords)
    ja = strip(ja)
    isempty(ja) && return (ja = "", en = "")
    en = translate_long(client, ja; source_lang = "ja", target_lang = "en")
    return (ja = ja, en = en)
end

# ---------------------------------------------------------------------------
# HTTP handlers
# ---------------------------------------------------------------------------

json_response(status::Int, obj) =
    HTTP.Response(status, ["Content-Type" => "application/json; charset=utf-8"], JSON.json(obj))

error_response(status::Int, message::AbstractString) = json_response(status, Dict("error" => message))

function serve_static(path::AbstractString)
    file = normpath(joinpath(WEB_DIR, path == "/" ? "index.html" : lstrip(path, '/')))
    startswith(file, WEB_DIR) || return HTTP.Response(403, "forbidden")
    isfile(file) || return HTTP.Response(404, "not found")
    ctype = endswith(file, ".html") ? "text/html; charset=utf-8" :
            endswith(file, ".js") ? "text/javascript; charset=utf-8" :
            endswith(file, ".css") ? "text/css; charset=utf-8" :
            endswith(file, ".wav") ? "audio/wav" : "application/octet-stream"
    return HTTP.Response(200, ["Content-Type" => ctype, "Cache-Control" => "no-store"], read(file))
end

function handle_segment(app::App, req::HTTP.Request)
    bytes = Vector{UInt8}(req.body)
    length(bytes) <= MAX_AUDIO_BYTES ||
        return error_response(413, "音声が大きすぎます (最大 2 MiB, 16 kHz モノラルで約 60 秒)。")

    duration = audio_duration(bytes)
    duration === nothing &&
        return error_response(400, "WAV は 16 kHz・16 bit PCM・モノラルの必要があります。")
    duration >= 0.1 || return error_response(400, "音声が短すぎます (0.1 秒以上)。")
    duration <= 60 || return error_response(400, "音声が長すぎます (60 秒以下)。")

    uri = HTTP.URI(req.target)
    params = HTTP.URIs.queryparams(uri.query === nothing ? "" : uri.query)
    keywords = get(params, "keywords", "")
    kw = split(keywords, ','; keepempty = false) .|> strip |> x -> filter(!isempty, x)

    t0 = time()
    result = transcribe_and_translate(app, bytes; keywords = isempty(kw) ? nothing : kw)
    elapsed = round(time() - t0; digits = 2)
    @info "transcribed segment" duration = round(duration; digits = 2) seconds = elapsed chars = length(result.ja)
    return json_response(200, Dict("ja" => result.ja, "en" => result.en,
                                   "duration" => round(duration; digits = 2), "elapsed" => elapsed))
end

function handler(app::App, req::HTTP.Request)
    if req.method != "GET" && req.method != "POST"
        return HTTP.Response(405, "method not allowed")
    end
    path = HTTP.URI(req.target).path
    if req.method == "GET"
        path == "/api/health" && return json_response(200, Dict("ok" => true, "has_api_key" => has_api_key(app)))
        path == "/favicon.ico" && return HTTP.Response(204)
        return serve_static(path)
    end
    path == "/api/segment" && return handle_segment(app, req)
    path == "/api/translate" && return handle_translate(app, req)
    return error_response(404, "not found")
end

function handle_translate(app::App, req::HTTP.Request)
    text = try
        body = JSON.parse(String(Vector{UInt8}(req.body)); dicttype = Dict{String,Any})
        String(get(body, "text", ""))
    catch
        ""
    end
    isempty(strip(text)) && return error_response(400, "text が空です。")
    try
        client = get_client(app)
        return json_response(200, Dict("en" => translate_long(client, text)))
    catch err
        return api_error_response(err)
    end
end

api_error_response(err) = err isa SarashinaError ?
    error_response(502, sprint(showerror, err)) :
    err isa ArgumentError ? error_response(400, sprint(showerror, err)) :
    error_response(500, sprint(showerror, err))

# Wrap a handler so API failures become JSON errors instead of HTML 500s.
function guarded(f, app, req)
    try
        return f(app, req)
    catch err
        @error "request failed" exception = (err, catch_backtrace())
        return api_error_response(err)
    end
end

# ---------------------------------------------------------------------------
# Server
# ---------------------------------------------------------------------------

"""
    serve(; host = "127.0.0.1", port = 8080, client = nothing, quiet = false)

Start the local web app. Blocks until interrupted.
"""
function serve(; host::AbstractString = "127.0.0.1", port::Integer = 8080,
               client = nothing, quiet::Bool = false)
    app = App(; client = client)
    if !has_api_key(app)
        @warn "SARASHINA_API_KEY が見つかりません。.env か環境変数に設定してください。"
    end
    @info "SarashinaHonyaku: http://$host:$port"
    return HTTP.serve((req) -> guarded(handler, app, req), host, port; verbose = quiet ? -1 : 0)
end

function main(args::Vector{String} = ARGS)
    host = "127.0.0.1"
    port = 8080
    i = 1
    while i <= length(args)
        a = args[i]
        if a in ("--port", "-p") && i < length(args)
            port = parse(Int, args[i + 1]); i += 2
        elseif a in ("--host",) && i < length(args)
            host = args[i + 1]; i += 2
        elseif a in ("--help", "-h")
            println("usage: julia --project=. bin/server.jl [--host HOST] [--port PORT]")
            return
        else
            error("unknown argument: $a")
        end
    end
    serve(; host = host, port = port)
end

end # module
