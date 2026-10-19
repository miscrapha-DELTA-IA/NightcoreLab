# Gnarly: fontes e recuperação de áudio

Auditoria de 19/10/2026. Objetivo: reduzir falhas de extração sem trocar o motor de áudio, contratos HTTP, modelos, fila ou interface.

| Repositório | Papel | Decisão |
| --- | --- | --- |
| [yt-dlp](https://github.com/yt-dlp/yt-dlp) | Extração atual de áudio | Mantido como fonte primária, com cooldown existente. |
| [YouTube.js](https://github.com/LuanRT/YouTube.js) | Cliente InnerTube | Ainda depende do YouTube; não resolve independência e adicionaria runtime. |
| [youtube-source](https://github.com/lavalink-devs/youtube-source) | Fonte YouTube para Lavalink | Ainda depende do YouTube; novo servidor JVM mudaria a arquitetura. |
| [spotDL](https://github.com/spotDL/spotify-downloader) | Metadados Spotify e correspondência de áudio no YouTube | Não remove a dependência de áudio do YouTube. |
| [Music Assistant](https://github.com/music-assistant/server) | Biblioteca com múltiplos provedores | Referência para identificação e recuperação por provedor; não incorporar o servidor inteiro. |
| [Navidrome](https://github.com/navidrome/navidrome) e [OpenSubsonic](https://github.com/opensubsonic/open-subsonic-api) | Streaming de biblioteca própria | Independente, mas exige biblioteca e servidor configurados; não inventar credenciais ou catálogo. |
| [Audius](https://github.com/AudiusProject/apps) | Catálogo e streams públicos independentes | Adaptador pequeno no worker atual, usando API pública. |
| [Parachord](https://github.com/Parachord/parachord) | Player com resolução de múltiplas fontes | Referência conceitual; nenhum motor ou interface incorporado. |

## Implementação

O contrato continua sendo `/download` retornando arquivo M4A completo. O cache de áudio, a deduplicação de downloads e os limites de workers existentes são mantidos. O adaptador Audius só é consultado depois de falha transitória do YouTube, inclusive durante cooldown. Nenhuma chave nova é necessária. Não há cópia de código dos projetos pesquisados.

A identidade vem exclusivamente de resultados estruturados de músicas observados pelo servidor em `/v1/search` ou `/search`. Exige artista verificado no Audius, nome e título normalizados iguais, duração com diferença máxima de dois segundos, uma única correspondência e acesso público ao stream. Remix, live e outras versões não são removidos do título para forçar correspondência. Redirecionamentos ficam restritos a HTTPS nos domínios Audius e ao hostname exato do armazenamento R2 observado no redirecionamento oficial. Arquivos têm limite de 32 MiB, duração inferior a 600 segundos e validação local com ffprobe antes da conversão. Não se usa prévia como faixa completa. Limites de rede, conversão, cache negativo e cooldown do provedor evitam tentativas ilimitadas. URLs assinadas não são registradas nos logs.

Buscas e sugestões idênticas simultâneas compartilham o mesmo resultado. Durante falha ou saturação, resultados de até uma hora podem ser reutilizados, sem renovar essa validade na falha. Os contratos JSON e a quantidade de workers são preservados.

## Limitações e validação

Audius tem catálogo próprio: não garante que a música pedida exista nele. Correspondência textual e duração são conservadoras, mas não equivalem a fingerprint acústico. Links diretos sem metadados conhecidos, gravações ambíguas e faixas indisponíveis continuam retornando o erro original. Metadados em memória são perdidos no reinício. O karaokê continua alinhando o arquivo efetivamente baixado pelo fluxo Whisper existente.

Testes offline cobrem recuperação durante 429, manutenção do erro original, recusa de versões/restrições, redirecionamentos externos, limpeza de temporários, cache negativo, compartilhamento de buscas e cache em falhas. O teste de rede Audius usa uma faixa pública conhecida, sem associar identidades artificiais em produção. Isso não demonstra disponibilidade de todo o catálogo nem desempenho equivalente a um serviço comercial. Validar a faixa originalmente problemática e o karaokê na build instalada ainda é necessário.
