# Otimização do backend Gnarly — relatório de validação

Data: 20/10/2026. Branch: `feat/backend-r2-offload`, derivada de `b3cbb87`. Nenhuma alteração do omnibox foi incluída.

## O que foi implementado

- Cache privado Cloudflare R2 via SigV4 com `httpx`, bucket `gnarly-cache`, TTL de 7 dias, upload em stream após o primeiro download, HEAD com LRU e 302/URL assinada para hits. Falhas R2 usam o fluxo local. Lifecycle é mesclado no startup se a chave tiver permissão.
- Cache `/tmp` original e envio por `FileResponse` preservados, incluindo `Range`, `HEAD` e formato M4A. Arquivos ativos são protegidos contra evicção. Limite de fila, guarda de RSS, cancelamento de job ainda enfileirado e `/queue` adicionados.
- `/health`, `/warm`, `/metrics`, logs JSON com remoção de URLs assinadas, ETag/gzip só para busca JSON, proteção por token opcional e limites por IP/token. Erros de download mapeados a códigos HTTP semânticos mantendo o campo `detail`.
- `yt-dlp` fixado em `2026.8.19`; rotina semanal de update com PR após testes, smoke diário de produção com issue em falha e circuit breaker por estratégia de player client.

## Resultados medidos

| Medida | Produção antes (`b3cbb87`) | Checkout depois, local Windows | R2 em produção |
|---|---:|---:|---|
| Faixa curta, primeiro byte | 22,75 s | 8,562 s com cache vazio | Pendente de deploy |
| Faixa curta, total | 31,985 s / 2.806.503 bytes | 8,578 s / 3.731.016 bytes, formato/bitrate da origem pode variar | Pendente de deploy |
| 597 s, primeiro byte/total | 22,047 / 35,687 s; 9.647.865 bytes | 19,250 / 19,312 s; 9.655.276 bytes, cache vazio | Pendente de deploy |
| Hit local | Não medido isoladamente | 0,016 s no smoke repetido | Pendente |
| 20 usuários, pico 5, mesmo vídeo em cache | Não medido | 0% erro; p95 0,047 s; 6.185.760 bytes totais | Pendente |
| RSS/CPU por teste | Render chegou a ~268 MB e 0,116 core numa janela com deploy; sem atribuição por faixa | Pico 104,1 MB e 1,438 s de CPU nas duas extrações frias; pico 80,9 MB no teste de carga quente | Pendente |
| Boot até health | Cold start Render não capturado | 2,718 s antes / 2,140 s depois em execuções locais diferentes | Pendente |

Fontes: `docs/bench-backend-before.json`, `docs/bench-backend-after-local-cold.json`, `docs/bench-backend-local-smoke.json`, `docs/bench-backend-local-after.json`, `docs/load-test-local.json`, `docs/load-test-cold-local.json`. Os ambientes e possivelmente os formatos/bitrates da origem diferem; **não interpretar a diferença de latência como aceleração comprovada da produção**. O p95 do teste de carga fria mediu uma única extração compartilhada por 20 pedidos, sem R2. O alvo de RSS <400 MiB foi cumprido nos testes locais; falta medir na instância Render.

## Projeção de banda e custo

Cada hit R2 deve trocar os 2,8–9,6 MB de áudio pela resposta 302 do Render. O telefone continua baixando o arquivo completo, agora do R2. Um miss envia o arquivo ao primeiro usuário **e o envia novamente ao R2**; ambos os fluxos podem contar na banda de saída do Render. Com 80% hits, isso projeta ~40% da banda anterior, economia de ~60% e teto teórico da franquia 5 GB ~2,5 vezes maior. Essa taxa de hit é **hipótese**, ainda não observada; com menos de 50% hits, o offload pode piorar o consumo de banda do Render. Misses ainda consomem CPU. R2 Standard oferece 10 GB-mês, 1M operações Class A e 10M Class B gratuitos; não existe garantia de custo zero para volume arbitrário. Ver [preços R2](https://developers.cloudflare.com/r2/pricing/) e [banda Render](https://render.com/docs/outbound-bandwidth).

## Compatibilidade e limites conscientes

- O app iOS usa M4A e `URLSession` background. A resposta final do R2 possui `Content-Type: audio/mp4` e `Content-Disposition` com título; o app já traz URL de miniatura da busca ou de `i.ytimg.com` para links colados. O cabeçalho `X-Cover-Url` emitido no 302 não atravessa para a resposta final. Um teste no iPhone continua necessário.
- A instrução de *zero transcode absoluto* conflita com o contrato M4A para fontes apenas MP3/Opus/FLAC. O caminho nativo M4A não reencoda e o fallback AAC remuxa com `-c:a copy`; os demais casos mantêm o fallback de conversão para não quebrar faixas. Trocar o contrato para vários codecs deve ser mudança iOS específica, fora deste branch.
- Um cliente que desconecta enquanto yt-dlp já roda não pode interromper a thread com segurança. A thread termina sob o gate de concorrência, e o workspace é limpo. Pedidos ainda esperando o semáforo são cancelados.
- Cache R2 privado não foi testado com as credenciais reais do Render neste checkout. Testes offline cobrem parser, assinatura, HEAD TTL/LRU, PUT stream, lifecycle merge, 302, Range/HEAD e fallback. A validação de ponta a ponta após deploy deve verificar `r2_uploads_ok`, `cache_r2_hits` e `r2_fallbacks` em `/metrics` antes de medir custo/latência.

## Verificações

`python -m pytest -q backend`: 79 testes aprovados, 1 pulado (exige ffmpeg no host), 23 subtests. Extrações frias locais de faixa curta e 597 s: ambas HTTP 200/M4A. Teste de carga fria: 20/20 HTTP 200, pico configurado de cinco, p95 3,282 s, RSS máximo 98,3 MB e apenas uma estratégia yt-dlp bem-sucedida (single-flight); teste quente: p95 0,047 s, RSS máximo 80,9 MB. O workflow CI realiza o pytest e smoke de produção após merge.

## Operação após deploy

1. `GET /health` para status e RSS; `GET /metrics` para R2, fila, cookies e circuito.
2. Download de vídeo curto pela API: primeira requisição deve retornar M4A local; aguardar `r2_uploads_ok` subir. Segunda requisição deve responder 302 para R2 e baixar M4A válido. Testar `Range` e `HEAD`.
3. Conferir lifecycle de 7 dias no bucket. Se o token não tiver permissão de configurar bucket, aplicar a regra no painel R2 sem apagar outras regras.
4. No iPhone, conferir título/capa, progresso de download, reprodução, karaokê e Share. Testar também com R2 indisponível para confirmar o fallback local.
5. Para monitor gratuito, apontar Healthchecks.io/UptimeRobot/Better Stack para `/health` em intervalo **maior que 15 minutos** se desejar preservar spin-down e as 750 h/mês gratuitas. O aquecimento que o app já faz em `GET /` evita manter o serviço acordado o tempo todo.
