# Deep links e sugestões do Nightcore Lab

Os quatro arquivos completos estão no repositório. Os blocos abaixo mostram as adições e substituições desta implementação. O DSP em AudioEngineManager.swift não foi alterado.

## Limites da integração

- Registrar `nightcore` abre o app por URL; isso não cria uma Share Extension no menu Partilhar. É possível usar um Atalho do iOS que receba uma URL, codifique-a e abra o deep link. Uma Share Extension nativa exige um target separado.
- `/related` consulta o Mix público associado ao vídeo (`RD` + ID). Não representa recomendações personalizadas da conta nem garante que o YouTube forneça 5 músicas. Retorna até 10 itens válidos e pode retornar menos ou nenhum.
- A opção `extract_flat=True` evita a extração individual dos vídeos. Rede, cold start e bloqueios do YouTube ainda podem causar demora/falha.
- Um cartão inicia o download. A reprodução continua manual pelo botão Play, conforme o comportamento adotado no passo anterior; não há avanço automático entre faixas.
- A consulta de sugestões tem uma vaga própria, timeout de socket e limite de entradas; não ocupa as vagas de downloads.

## Info.plist

Adicionar dentro do dicionário principal:

```xml
<key>CFBundleURLTypes</key>
<array>
	<dict>
		<key>CFBundleTypeRole</key>
		<string>Editor</string>
		<key>CFBundleURLName</key>
		<string>com.nightcorelab.download</string>
		<key>CFBundleURLSchemes</key>
		<array>
			<string>nightcore</string>
		</array>
	</dict>
</array>
```

Exemplo com o valor `link` codificado:

```text
nightcore://download?link=https%3A%2F%2Fwww.youtube.com%2Fwatch%3Fv%3DjNQXAC9IVRw
```

Em Swift, construir com URLComponents evita quebrar URLs que contêm `&`:

```swift
var deepLink = URLComponents()
deepLink.scheme = "nightcore"
deepLink.host = "download"
deepLink.queryItems = [URLQueryItem(name: "link", value: youtubeURL)]
let urlToOpen = deepLink.url
```

## backend/main.py

Imports novos (preservar os demais):

```python
from itertools import islice
from urllib.parse import parse_qs, urlparse
```

Estado para limitar o trabalho de sugestões:

```python
_related_slots = threading.BoundedSemaphore(1)
RELATED_LIMIT = 10
RELATED_SCAN_LIMIT = 20
```

Adicionar após DownloadRequest; o endpoint usa o logger _YtdlpLog já existente:

```python
class RelatedVideo(BaseModel):
    title: str
    thumbnail: HttpUrl
    url: HttpUrl


def _youtube_video_id(url: str) -> str:
    """Valida o destino e normaliza watch, youtu.be, shorts, live e embed."""
    parsed = urlparse(url)
    host = (parsed.hostname or "").lower()
    if parsed.scheme not in {"http", "https"} or host not in ALLOWED_HOSTS:
        raise HTTPException(status_code=400, detail="Apenas links do YouTube são aceitos.")
    if parsed.username or parsed.password or parsed.port not in {None, 80, 443}:
        raise HTTPException(status_code=400, detail="Link do YouTube inválido.")
    parts = parsed.path.strip("/").split("/")
    video_id = ""
    if host == "youtu.be" and len(parts) == 1:
        video_id = parts[0]
    elif parsed.path.rstrip("/") == "/watch":
        video_id = parse_qs(parsed.query).get("v", [""])[0]
    elif len(parts) == 2 and parts[0] in {"shorts", "live", "embed"}:
        video_id = parts[1]
    if not re.fullmatch(r"[A-Za-z0-9_-]{11}", video_id):
        raise HTTPException(status_code=400, detail="Use o link de um vídeo do YouTube.")
    return video_id


def _related_entries(info: dict, seed_id: str) -> list[RelatedVideo]:
    seen = {seed_id}
    videos = []
    for entry in islice(info.get("entries") or [], RELATED_SCAN_LIMIT):
        if not isinstance(entry, dict):
            continue
        video_id = entry.get("id")
        title = entry.get("title")
        if not isinstance(video_id, str) or not re.fullmatch(r"[A-Za-z0-9_-]{11}", video_id):
            continue
        if video_id in seen or not isinstance(title, str) or not title.strip():
            continue
        if entry.get("is_live") or entry.get("availability") in {"private", "premium_only", "subscriber_only"}:
            continue
        duration = entry.get("duration")
        if isinstance(duration, (int, float)) and duration > MAX_DURATION_SECONDS:
            continue
        seen.add(video_id)
        thumbnails = [entry.get("thumbnail")]
        thumbnails.extend(t.get("url") for t in reversed(entry.get("thumbnails") or []) if isinstance(t, dict))
        thumbnail = next((t for t in thumbnails if isinstance(t, str) and t.startswith("https://")),
                         f"https://i.ytimg.com/vi/{video_id}/hqdefault.jpg")
        videos.append(RelatedVideo(title=title.strip(), thumbnail=thumbnail,
                                   url=f"https://www.youtube.com/watch?v={video_id}"))
        if len(videos) == RELATED_LIMIT:
            break
    return videos


@app.get("/related", response_model=list[RelatedVideo])
def related(url: HttpUrl):
    """Sugestões do Mix público do YouTube, sem baixar áudio ou extrair cada vídeo."""
    video_id = _youtube_video_id(str(url))
    if not _related_slots.acquire(blocking=False):
        raise HTTPException(status_code=429, detail="Sugestões ocupadas. Tente novamente.")
    try:
        options = {
            "extract_flat": True,
            "skip_download": True,
            "noplaylist": False,
            "playlistend": RELATED_SCAN_LIMIT,
            "lazy_playlist": True,
            "quiet": True,
            "logger": _YtdlpLog("related"),
            "cachedir": False,
            "socket_timeout": 8,
            "retries": 0,
            "extractor_retries": 0,
        }
        # A consulta usa o Mix público, não as recomendações pessoais dos cookies.
        mix_url = f"https://www.youtube.com/watch?v={video_id}&list=RD{video_id}"
        with yt_dlp.YoutubeDL(options) as ydl:
            info = ydl.extract_info(mix_url, download=False)
            if not isinstance(info, dict):
                return []
            return _related_entries(info, video_id)
    except yt_dlp.utils.DownloadError:
        log.warning("Mix indisponível para %s", video_id)
        raise HTTPException(status_code=502, detail="Sugestões temporariamente indisponíveis.")
    except Exception:
        log.exception("Erro ao consultar sugestões para %s", video_id)
        raise HTTPException(status_code=503, detail="Sugestões temporariamente indisponíveis.")
    finally:
        _related_slots.release()
```

## DownloadManager.swift

Modelo fora da classe:

```swift
struct RelatedVideo: Identifiable, Codable {
    let title: String
    let thumbnail: URL?
    let url: URL

    var id: String { url.absoluteString }
}
```

Estado dentro da classe:

```swift
@Published private(set) var relatedErrorMessage: String?
```

Consulta assíncrona dentro da classe:

```swift
func fetchRelatedVideos(for url: String) async -> [RelatedVideo] {
    relatedErrorMessage = nil
    guard let source = Self.youtubeVideoURL(from: url),
          var components = URLComponents(string: Self.apiBaseURL) else {
        relatedErrorMessage = "Não foi possível consultar sugestões para este link."
        return []
    }
    components.path += "/related"
    components.queryItems = [URLQueryItem(name: "url", value: source.absoluteString)]
    guard let endpoint = components.url else { return [] }
    var request = URLRequest(url: endpoint, timeoutInterval: 25)
    request.setValue("application/json", forHTTPHeaderField: "Accept")

    do {
        let (data, response) = try await URLSession.shared.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            relatedErrorMessage = "Sugestões indisponíveis agora. Tente novamente."
            return []
        }
        let videos = try JSONDecoder().decode([RelatedVideo].self, from: data)
        var seen = Set([source.absoluteString])
        return Array(videos.compactMap { video -> RelatedVideo? in
            guard let canonical = Self.youtubeVideoURL(from: video.url.absoluteString),
                  !video.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  seen.insert(canonical.absoluteString).inserted else { return nil }
            let thumbnail = video.thumbnail?.scheme?.lowercased() == "https" ? video.thumbnail : nil
            return RelatedVideo(title: video.title, thumbnail: thumbnail, url: canonical)
        }.prefix(10))
    } catch {
        if !Task.isCancelled {
            relatedErrorMessage = "Não foi possível carregar as sugestões."
        }
        return []
    }
}
```

Substituir looksLikeYouTube e adicionar os parsers dentro da classe:

```swift
nonisolated static func looksLikeYouTube(_ link: String) -> Bool {
    youtubeVideoURL(from: link) != nil
}

nonisolated static func youtubeVideoURL(from raw: String) -> URL? {
    guard let parts = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
          let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
          let host = parts.host?.lowercased(),
          ["youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com", "youtu.be"].contains(host),
          parts.user == nil, parts.password == nil,
          parts.port == nil || parts.port == 80 || parts.port == 443 else { return nil }
    let path = parts.path.split(separator: "/").map(String.init)
    let videoID: String?
    if host == "youtu.be", path.count == 1 {
        videoID = path[0]
    } else if path == ["watch"] {
        videoID = parts.queryItems?.first(where: { $0.name == "v" })?.value
    } else if path.count == 2, ["shorts", "live", "embed"].contains(path[0]) {
        videoID = path[1]
    } else {
        videoID = nil
    }
    guard let videoID, videoID.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil else {
        return nil
    }
    return URL(string: "https://www.youtube.com/watch?v=\(videoID)")
}

nonisolated static func youtubeURL(fromDeepLink url: URL) -> URL? {
    guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
          parts.scheme?.lowercased() == "nightcore",
          parts.host?.lowercased() == "download",
          parts.path.isEmpty || parts.path == "/",
          parts.user == nil, parts.password == nil, parts.port == nil else { return nil }
    let links = parts.queryItems?.filter { $0.name == "link" } ?? []
    guard links.count == 1, let link = links.first?.value else { return nil }
    return youtubeVideoURL(from: link)
}
```

## ContentView.swift

Novos estados dentro de ContentView:

```swift
@State private var relatedVideos: [RelatedVideo] = []
@State private var isLoadingRelated = false
@State private var relatedSourceURL: String?
@State private var relatedRequestID = UUID()
@State private var pendingDeepLink: String?
```

Adicionar relatedSection logo abaixo de trackCard no VStack principal. Adicionar à view principal os modificadores:

```swift
.onOpenURL(perform: handleDeepLink)
.task(id: relatedRequestID) { await loadRelatedVideos() }
.onChange(of: downloader.isDownloading) { _, downloading in
    guard !downloading, let link = pendingDeepLink else { return }
    pendingDeepLink = nil
    youtubeLink = link
    startDownload()
}
```

Seção do carrossel dentro de ContentView:

```swift
@ViewBuilder
private var relatedSection: some View {
    if relatedSourceURL != nil {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("PRÓXIMAS FAIXAS")
                    .font(.caption.weight(.heavy))
                    .tracking(2)
                    .foregroundStyle(currentTheme.accent)
                Spacer()
                if isLoadingRelated {
                    ProgressView().tint(currentTheme.accent)
                        .accessibilityLabel("Carregando sugestões")
                } else {
                    Button {
                        relatedRequestID = UUID()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Atualizar sugestões")
                }
            }

            if !relatedVideos.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 12) {
                        ForEach(relatedVideos) { video in
                            RelatedVideoCard(video: video, theme: currentTheme,
                                             isEnabled: !downloader.isDownloading) {
                                guard !downloader.isDownloading else { return }
                                youtubeLink = video.url.absoluteString
                                startDownload()
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            } else if isLoadingRelated {
                Text("Buscando músicas para continuar…")
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.Ink.secondary)
            } else {
                Text(downloader.relatedErrorMessage ?? "Nenhuma sugestão disponível para esta faixa.")
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.Ink.secondary)
            }
        }
    }
}
```

Substituir startDownload e adicionar os métodos seguintes:

```swift
private func startDownload() {
    guard !downloader.isDownloading else { return }
    let sourceURL = trimmedLink
    guard DownloadManager.looksLikeYouTube(sourceURL) else {
        downloader.errorMessage = "Cole o link de um vídeo do YouTube."
        return
    }
    isLinkFieldFocused = false
    resetRelatedVideos()
    downloader.downloadAudio(youtubeURL: sourceURL) { localURL, downloadedCoverURL in
        do {
            try audio.load(url: localURL)
            coverURL = downloadedCoverURL
            applyPitch()
            youtubeLink = ""
            relatedSourceURL = sourceURL
            relatedRequestID = UUID()
        } catch {
            errorMessage = "Não foi possível abrir o áudio baixado: \(error.localizedDescription)"
        }
    }
}

private func handleDeepLink(_ url: URL) {
    guard url.scheme?.lowercased() == "nightcore" else { return }
    guard let source = DownloadManager.youtubeURL(fromDeepLink: url) else {
        downloader.errorMessage = "Link inválido. Use nightcore://download?link= com um vídeo do YouTube."
        return
    }
    youtubeLink = source.absoluteString
    if downloader.isDownloading {
        // Mantém só o link mais recente, sem interromper a transferência atual.
        pendingDeepLink = source.absoluteString
    } else {
        startDownload()
    }
}

private func resetRelatedVideos() {
    relatedSourceURL = nil
    relatedVideos = []
    isLoadingRelated = false
    relatedRequestID = UUID() // Cancela a consulta anterior vinculada à view.
}

@MainActor
private func loadRelatedVideos() async {
    guard let sourceURL = relatedSourceURL else { return }
    let requestID = relatedRequestID
    isLoadingRelated = true
    let videos = await downloader.fetchRelatedVideos(for: sourceURL)
    guard !Task.isCancelled, requestID == relatedRequestID,
          sourceURL == relatedSourceURL else { return }
    relatedVideos = videos
    isLoadingRelated = false
}
```

No sucesso de importFile, após audio.load e coverURL = nil, chamar resetRelatedVideos() para remover sugestões da faixa anterior.

Para exibir o link pendente, adicionar ao VStack de youtubeField:

```swift
if pendingDeepLink != nil {
    Text("Link recebido. O próximo download começa ao terminar este.")
        .font(DS.Typography.caption)
        .foregroundStyle(currentTheme.accent)
        .padding(.leading, 16)
}
```

Componente fora de ContentView:

```swift
private struct RelatedVideoCard: View {
    let video: RelatedVideo
    let theme: AppTheme
    let isEnabled: Bool
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 16).fill(.ultraThinMaterial)
                AsyncImage(url: video.thumbnail) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    theme.accent.opacity(0.12)
                }
                .frame(width: 152, height: 120)
                .opacity(0.55)

                LinearGradient(colors: [.black.opacity(0.1), .black.opacity(0.85)],
                               startPoint: .top, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Spacer()
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(theme.accent)
                            .symbolEffect(.pulse, options: .repeating,
                                          isActive: isEnabled && !reduceMotion)
                            .shadow(color: theme.accent.opacity(0.65), radius: 8)
                    }
                    Spacer(minLength: 0)
                    Text(video.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(12)
            }
            .frame(width: 152, height: 120)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16)
                .strokeBorder(theme.accent.opacity(0.3), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.5)
        .accessibilityLabel("Baixar \(video.title)")
    }
}
```

## Verificação

```bash
python -m pip install -r backend/requirements.txt httpx
python -m unittest discover -s backend -p 'test_*.py'
```

Os testes cobrem validação de URLs, contrato JSON, modo flat sem download, duplicatas, exclusão da faixa atual, filtros, limites de resultados/iteração, indisponibilidade e liberação das vagas.

No macOS com o app instalado no simulador:

```bash
xcrun simctl openurl booted 'nightcore://download?link=https%3A%2F%2Fwww.youtube.com%2Fwatch%3Fv%3DjNQXAC9IVRw'
```

Conferir no iPhone/simulador: abertura a frio/quente, link inválido, link recebido durante outro download, sugestões em rede lenta/indisponível, toques consecutivos, importação local, temas e Reduzir Movimento. Esses cenários visuais ainda precisam ser executados no iOS.

Referências oficiais:
- https://developer.apple.com/documentation/xcode/defining-a-custom-url-scheme-for-your-app
- https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/Share.html
- https://github.com/yt-dlp/yt-dlp/blob/master/yt_dlp/extractor/youtube/_tab.py
- https://github.com/yt-dlp/yt-dlp#usage-and-options
