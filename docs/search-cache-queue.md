# Busca, cache e fila de áudio

O projeto iOS é gerado por `xcodegen generate`; `project.yml` é a fonte das dependências.
Requer Xcode 26 / Swift 6.2 para a revisão fixada do lcharlick (produto `DownloadKit`).
O produto `SDWebImageSwiftUI` fornece `WebImage`, com cache de imagens de 64 MB em
memória e 256 MB em disco, por até sete dias.

## Fluxo

- `SearchView` aplica debounce de 400 ms e cancela consultas antigas. `YouTubeSearchService`
  chama `GET /search?query=…` na mesma ponte configurada em Servidor.
- No servidor, o processo Python executa `yt-dlp` com
  `["ytsearch15:<query>", "--dump-json", "--flat-playlist"]`, sem shell,
  com limite de consulta, concorrência e timeout. O Swift decodifica NDJSON,
  valida IDs, remove duplicatas e fornece uma capa de fallback.
- `AudioDownloadManager` usa a fila async/await do lcharlick com
  `URLSessionConfiguration.background`. Há uma transferência ativa por vez.
  Selecionar uma faixa elimina a fila especulativa anterior e aumenta a prioridade
  da transferência existente, quando possível. Seleções antigas não recebem callbacks.
- `GET /download?url=…` reutiliza a extração M4A existente; `POST /download` continua
  compatível. O GET permite reconstruir tarefas de background sem depender de POST body.
- Depois de o motor iniciar a reprodução, as próximas cinco faixas únicas são
  submetidas à fila. Falhas de prefetch são silenciosas; uma seleção explícita pode tentar novamente.
- O cache valida o áudio com `AVAudioFile`, move o arquivo e grava seu índice
  atomicamente antes de publicar `isCached`. A troca para uma faixa em cache não espera
  a rede nem o cancelamento dos downloads anteriores.
- O cache fica em `Library/Caches/NightcoreAudio`, com limite de 30 faixas / 512 MB.
  A faixa em reprodução e as da fila ficam protegidas da limpeza. O sistema pode
  remover Caches; a existência do arquivo é verificada ao consultar o cache.

## Background e limites

O AppDelegate encaminha o completion handler de eventos da sessão de background.
O índice de pendências permite recuperar metadados após um relançamento. A revisão
fixada do lcharlick recria tarefas ao reconectar: o adapter cancela a tarefa antiga
para impedir transferências duplicadas. Downloads incompletos podem reiniciar;
este endpoint temporário não oferece retomada byte a byte garantida.

O iOS controla o agendamento de tarefas em background e o encerramento forçado pelo
usuário interrompe esse mecanismo. “Instantâneo” significa sem download quando o
arquivo está em cache; a abertura do arquivo e o motor de áudio ainda têm latência.
Busca e GET de áudio exigem o deploy desta versão do backend.

## Verificação

- `python -m unittest discover -s backend -p 'test_*.py'`: contratos offline,
  argumentos da busca, timeout, concorrência, validação de URLs e compatibilidade GET.
- `SearchAndCacheTests`: parsing NDJSON, filtros, limites, identidade, persistência,
  rejeição de arquivos inválidos, remoção pelo sistema e limpeza protegida.
- O workflow `ios.yml` resolve SPM, executa testes no simulador e compila o IPA.
- Verificação no aparelho: selecionar durante prefetch, tocar uma faixa marcada como
  pronta em modo avião, alternar rapidamente resultados e colocar o app em background.
