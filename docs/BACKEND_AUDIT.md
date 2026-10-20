# Auditoria do backend Gnarly — 20/10/2026

## Estado inicial (commit `b3cbb87`)

O Render executa `uvicorn main:app --host 0.0.0.0 --port $PORT`, com um worker, a partir de `backend/`. Não há Dockerfile/Blueprint neste repositório; o build instala `backend/requirements.txt`. Endpoints existentes: `GET/HEAD /`, `GET/POST /download`, `GET /search` (NDJSON), `GET /v1/search`, `GET /v1/suggest`, `GET /related` e `POST /align-lyrics`. `/health`, `/warm` e `/metrics` ainda não existiam.

`yt-dlp[default]` era sem pin; a versão observada no ambiente em 20/10 foi `2026.8.19`. Deno e `yt-dlp-ejs` resolvem desafios JavaScript. A extração usa `ffmpeg` como fallback para converter formatos não M4A; quando o formato nativo já é AAC/M4A, o pós-processador o preserva. O app espera áudio M4A (`audio/mp4`) e nome `.m4a`, então entregar Opus/WebM diretamente quebraria o contrato. Cookies ficam num Secret File, são copiados para um diretório temporário por extração e o diagnóstico de `GET /` expõe apenas nomes/contagens, nunca valores. O logger do yt-dlp filtra URLs completas, mas erros precisam continuar evitando tokens/URLs assinadas.

O cache local fica em `/tmp/nightcore_audio_cache`, tem limite LRU de 300 MiB e publicação atômica. `FileResponse` transmite do disco e oferece `Range`/`HEAD`; não carrega faixas inteiras em RAM. Trabalho simultâneo: 1 extração por padrão (máximo 2), 2 threads de extração, 4 IDs pendentes, single-flight por ID; tempo máximo de espera do pedido: 240 s. Um pedido desconectado deixa a thread já iniciada terminar, pois `run_in_executor` não a interrompe; os arquivos são limpos depois. Arquivos de trabalho órfãos são varridos durante nova extração, não no boot. Busca/sugestões já têm TTL em memória (600/300 s), single-flight e stale fallback.

## Linha de base HTTP

Medição em `docs/bench-backend-before.json`, realizada contra produção em 20/10/2026, sem cache R2. `scripts/bench_backend.py` lê a resposta em blocos de 64 KiB; os bytes abaixo são os recebidos pelo cliente e saíram pelo Render. Os casos são um vídeo musical curto (~3 min), um vídeo de 597 s (abaixo do limite estrito de 600 s) e um host inválido. Como a instância já estava acordada, **não é medição de cold start**; o script tem `--launch-local` para medir boot local. HTTP remoto não mede RSS/CPU do processo; para isso seria necessário correlacionar métricas Render da mesma janela.

| Caso | HTTP | TTFB | Total | Bytes |
|---|---:|---:|---:|---:|
| Faixa curta | 200 | 22,75 s | 31,985 s | 2.806.503 |
| Vídeo 597 s | 200 | 22,047 s | 35,687 s | 9.647.865 |
| Host inválido | 400 | 0,516 s | 0,516 s | 0 |

A amostra de métricas Render obtida para a janela próxima teve memória até ~268 MB e CPU de até ~0,116 core, mas incluiu troca de instância/deploy e **não permite atribuir pico por faixa**. Não há evidência de OOM nesta amostra.

## Limites e capacidade (referência: 20/10/2026)

O serviço gratuito tem [0,1 CPU e 512 MiB](https://render.com/docs/compute-plans), disco efêmero, [750 horas/mês compartilhadas e spin-down após 15 min de inatividade](https://render.com/docs/free). O despertar pode demorar aproximadamente um minuto. No workspace Hobby, a [franquia atual de banda de saída é 5 GB/mês](https://render.com/docs/outbound-bandwidth); 100 GB é apenas um cenário hipotético ou de plano anterior, **não uma franquia confirmada para este serviço**. Sem pagamento habilitado, exceder limites pode suspender serviços; com pagamento, excedente pode ser cobrado.

Tomando 5 GB decimais e ignorando cabeçalhos, a banda permitiria ~1.781 faixas curtas/mês (89 por pessoa para 20 pessoas) ou ~518 vídeos de 597 s (26 por pessoa). No cenário hipotético de 100 GB, seriam ~35.631 faixas curtas ou ~10.365 vídeos longos. São **limites máximos de bytes**, não capacidade de CPU ou garantia de serviço. CPU de 0,1 core, latência de extração e o limite de uma extração simultânea podem reduzir muito o throughput em picos. O limite de 512 MiB é simultâneo, não um orçamento mensal; com 268 MB observados, restariam ~244 MiB no pico amostrado, insuficientes para afirmar segurança de duas extrações.

Com cache R2, um hit completo deve enviar só HTTP 302 pelo Render, de modo que 5 GB deixam de ser o limite de áudio *para hits*. O primeiro miss continua custando os mesmos 2,8 MB ou 9,6 MB, além de uma cópia de entrada para R2; portanto a economia depende da taxa de repetição. Se 80% das requisições forem hits, o teto teórico de banda Render para essas faixas sobe aproximadamente 5 vezes; com 0% de hits, não melhora. A capacidade de CPU em miss e o limite de memória permanecem aproximadamente iguais; hits dispensam extração.

R2 Standard inclui [10 GB-mês, 1 milhão de operações Class A, 10 milhões Class B e egress gratuito](https://developers.cloudflare.com/r2/pricing/). O TTL de 7 dias **não garante custo zero**: uploads de muitas faixas únicas podem exceder armazenamento/operações da conta. Monitorar uso no painel e manter orçamento/alerta da conta é necessário. Regras de lifecycle podem remover objetos até 24 h após expiração; a aplicação também rejeitará por idade no `HEAD`.

## Compatibilidade e decisões

- O app atual usa `URLSession` e aceita redirects, mas o cabeçalho `X-Cover-Url` do backend é lido da **resposta final**. Um 302 para R2 privado não transfere esse cabeçalho para a resposta R2. O app tem capa da busca como fallback; isso precisa ser validado no build real antes de considerar o contrato visual intacto.
- Não aplicar `GZipMiddleware` globalmente: ele pode afetar áudio, `Range`, streaming e NDJSON. A compressão deve ser limitada às rotas JSON de busca.
- Não desativar conversão para toda fonte sem validar M4A/AAC: isso quebraria a reprodução e o formato persistido pelo app. Priorizar M4A nativo; remux sem reencode quando o codec for AAC e o contêiner diferente; qualquer caso incompatível deve receber erro claro ou fallback específico.
- R2 será ligado apenas quando as credenciais existirem. Falhas de `HEAD`/`PUT` voltam para o caminho local e ficam visíveis em métricas. Um redirect já enviado não pode fazer fallback se a rede do telefone falhar depois.

## Extrair vídeo no aparelho (avaliação)

Uma extração Swift client-side teria de reproduzir assinatura/cipher e desafios JS mutáveis do YouTube, manter cookies/PO Token e lidar com licenças e manutenção de uma biblioteca não oficial. O esforço e risco são altos; seria uma grande mudança no app e não cabe nesta alteração de backend. URLs `googlevideo` podem estar vinculadas ao IP de origem e expirar; **não foi validado** que uma URL resolvida no Render funcione na rede celular de outro IP. Assim, a entrega via cache R2 é a opção experimental de menor impacto no cliente.

## Operação

Preferir aquecimento via app a monitor de 5 minutos: manter um serviço gratuito acordado consome as 750 h mensais compartilhadas. Healthchecks.io, UptimeRobot ou Better Stack podem consultar `/health`, mas intervalo inferior a 15 min impede spin-down e pode consumir horas do workspace. Rotacionar o Secret File de cookies ao detectar falha de login/anti-bot; nunca publicar o conteúdo em issue/log.
