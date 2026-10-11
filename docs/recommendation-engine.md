# Rádio local v1

O Rádio continua usando uma chamada a `/related` por lote, nos mesmos pontos de antes.
O backend e a telemetria não mudam. O app combina o Mix público recebido com candidatos
locais; não mede similaridade acústica, BPM, energia ou gênero.

## Fontes, pontuação e limites

- `TrackFeatures`: artista estruturado ou extraído do título, confiabilidade, tokens,
  tags de versão e duração opcional. Sem artista, não cria grupo artificial de “desconhecidos”.
- `UserTasteProfile`: derivado das até 100 entradas do histórico; repetições e conclusões
  alimentam afinidades por artista, tokens e versões. Features são calculadas uma vez por perfil.
- `RecommendationRanker`: afinidade 0,30; frecency existente 0,20; posição no Mix 0,25;
  contexto de velocidade 0,10; novidade 0,15; penalidades de skip 0,30 e duração 0,25.
  Pesos e limites ficam em `Weights` e `Policy`.
- Velocidade acima de 1,1 favorece `spedUp`; abaixo de 0,9 favorece `slowed`.
  Duração fora de 45–720 s é penalizada quando conhecida, exceto títulos mix/live.
- Skip usa a razão de skips por reproduções, com decaimento exponencial de 21 dias.
  A penalidade também alcança candidatos do mesmo artista, reduzida quando a atribuição
  do artista é incerta. Desconhecidos nunca compartilham penalidade.

A fração de **candidatos adicionados pelo histórico** cresce de zero até 70%, ao atingir
30 reproduções. Meta por lote: `round(10 × 0,7 × min(1, plays / 30))`. Isso é uma quota
por fonte: o próprio Mix pode incluir faixas conhecidas, e não é garantidamente inédito.
Itens já no Mix não entram novamente como candidatos do histórico.

Histórico exclui a faixa atual, fila existente, dez IDs mais recentemente tocados e
IDs com skip nos últimos 21 dias. Mix e histórico são deduplicados por ID. Sem dados,
a ordem recebida do Mix é preservada exatamente, após as exclusões que a fila já fazia.

Com histórico, a diversificação limita o artista principal a duas faixas consecutivas,
considerando também o final da fila existente. Falta de candidatos de uma fonte permite
completar a quota com a outra. Se a diversidade impedir completar o lote, ele será menor;
não se força uma terceira faixa seguida do mesmo artista. A preservação do Mix no cold
start tem precedência sobre a regra de diversidade.

O mesmo lote ordenado aparece em Descobrir e é acrescentado à fila. Itens que já estavam
na fila não são reordenados. O ranker não faz requisições extras. Mix vazio ou erro de rede
continua sem substituição por uma fila feita apenas do histórico.

## Histórico e confirmação dos eventos

`PlayHistoryStore` nasce em `NightcoreLabApp`, é injetado no ambiente e é o único escritor
de `omnibox.playHistory`. `OmniboxEngine` consulta esse store; mantém seu cache e debounce.
`HistoryEntry` acrescenta apenas campos opcionais (`completions`, `earlySkips`,
`lastSkippedAt`); JSON antigo continua decodificável.

- Início conta depois de `audio.play()` e confirmação do token de transição.
- Conclusão conta antes de avançar a fila, uma vez por sessão.
- Candidato a skip é capturado numa escolha manual abaixo de 10 s da posição da fonte.
  Só vira evento quando uma faixa diferente inicia, se a sessão anterior ainda for a
  mesma e não tiver terminado durante o download. Falhas e pedidos cancelados não contam.
- Pause/resume não conta novamente. Sessão restaurada conta ao tocar de fato; importação
  local não entra no histórico. Uma repetição após a conclusão inicia nova sessão.
- Reproduzir por link preserva metadados estruturados anteriormente conhecidos do mesmo ID.

Limitação: o limiar usa a posição de reprodução existente, não um cronômetro de tempo
realmente escutado; seek e velocidade alteram essa interpretação. Não se acrescentou
instrumentação de escuta contínua nesta versão.

Tudo permanece no aparelho. Não há eventos de gosto no `TelemetryManager`, nem envio
de histórico/perfil ao servidor. Continuam persistidos apenas os instantes de última
reprodução e último skip, sem uma linha do tempo ilimitada de eventos.

## Decisões em relação ao pacote de 11/10

| Item | Escolha implementada | Motivo |
| --- | --- | --- |
| D1 | Revelação temporária de Descobrir | Já entregue e validada no commit c33e474 |
| D2 | Zen único e temporário nas duas telas | Preserva a decisão aprovada e evita voltar aos dois estados legados |
| D3 | Descobrir, Equilibrado e Só ouvir; início com tudo visível | Mantém os atalhos já entregues |
| D4 | Ocultar Busca limpa texto e última consulta, mantém histórico/cache | Evita texto antigo reaparecer numa nova abertura |
| D5 | Um único ⚡ ao lado do 👁, sempre no canto superior esquerdo | Alcance e posição constantes; não comprime compartilhar/microfone no karaokê |
| D6 | Quota progressiva por fonte, até 70% | Poucos dados implicam pouca interferência no Mix |
| Montagem da busca | Continua montada em Zen/karaokê | O pacote se contradiz sobre desmontar; manter evita perder motor/cache |
| BPM, gênero, energia, remoção, presets salvos | Não utilizados | Sinais inexistentes; sem backend novo nesta série |
| Cold start versus diversidade | Mix original tem prioridade sem histórico | Cumpre a compatibilidade explícita para usuário novo |
| Falta de diversidade | Lote menor quando necessário | Não inventa artistas nem repete três do mesmo artista |
| Commits de painéis | Não refeitos | Parte 1 já estava na main; série começa pela barra |

## Validação

`PlayHistoryStoreTests`: JSON legado, persistência, poda, confirmação de início, seleção
falha/cancelada, sessão obsoleta, conclusão durante download, pause/resume, replay e
metadados de links. `TrackFeaturesTests` e `RecommendationRankerTests`: sinais ausentes,
confiabilidade, cold start, afinidade, skip/decaimento, velocidade, duração, quotas,
diversidade, fila preexistente, exclusões, Mix vazio e desempates determinísticos.

Os arquivos novos entram automaticamente pelo `project.yml`. `ios.yml` gera o projeto
com XcodeGen, executa XCTest no simulador e compila o IPA. Análise sintática em Linux
não equivale a execução desses testes. A qualidade musical dos pesos e a ergonomia
precisam de validação com uso real; os testes garantem os contratos do ranking.
