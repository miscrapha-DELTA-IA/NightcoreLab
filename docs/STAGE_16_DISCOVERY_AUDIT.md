# Stage 16A — Discovery Engine: auditoria inicial

Data: 13/10/2026. Base examinada: `f08a20fcddf20b71a88cc765e60262527e263e3c`, main após merge do 15C (PR #46).

**Status: auditoria estática preliminar; implementação não iniciada.** Este arquivo não declara o milestone concluído nem valida qualidade de recomendações.

## Referências e pendência

Lido integralmente o anexo `NightcoreLab — Discovery Engine pesquisa e auditoria arquitetural(1).md`, de 13/10/2026. Lidos os contratos e caminhos de execução abaixo na base atual.

O segundo documento obrigatório, `NightcoreLab — Mapa open source de áudio, plugins, presets e voz.md`, não foi anexado nem localizado por título completo e buscas abreviadas. Sua leitura permanece pendente antes da implementação. As referências externas do anexo não foram reavaliadas nesta auditoria; nenhum código ou dependência externa foi incorporado.

O roadmap do anexo propõe medir uso real antes de ativar pesos acústicos. O pedido atual solicita a fundação do ranker v2 e smart queue; isso autoriza desenvolver esses contratos, mas não permite afirmar que seus pesos melhoram a qualidade musical sem avaliação posterior.

## 1. Sinais existentes e ausentes

| Sistema / arquivo | Evidência disponível | Lacuna relevante |
| --- | --- | --- |
| `Recommendation/RecommendationRanker.swift` | Ranker linear, contexto de velocidade, frecência, afinidade textual, novidade, penalidade de skip, diversidade de artista, quotas e cold start preservando a ordem do Mix | Não usa descritores acústicos ou histórico criativo; não entrega razões estruturadas |
| `Recommendation/TrackFeatures.swift` | Artistas e sua confiabilidade, tokens de título, tags de versão, duração opcional | Tags textuais não equivalem a gênero ou análise acústica |
| `Recommendation/UserTasteProfile.swift` | Preferências de artista/tokens/versões derivadas de plays e conclusões | Nenhum vínculo faixa–material–preset–velocidade |
| `Recommendation/PlayHistoryStore.swift` | Até 100 entradas em `omnibox.playHistory`; plays, conclusões, skips precoces e timestamps; sessão evita dupla conclusão | Não registra tempo realmente escutado, fração concluída, motivo do skip, export ou contexto criativo |
| `ContentView.swift`: `PlaybackQueue` | Deduplicação, exclusão da faixa atual, append, commit após playback confirmado e refill abaixo de 2 itens após avanço automático | Sem custo de transição, BPM/energia ou reordenação após skip |
| `MusicIntelligence/MusicIntelligenceEngine.swift` e `MusicAnalysisResult.swift` | Arquivos locais; energia, onsets, ritmo, capabilities, cobertura, identidade/revisão, cache persistente e scheduler compartilhado/cancelável | Candidatos remotos sem arquivo local não possuem análise; cache é por identidade do áudio, não simplesmente trackID |
| `MusicIntelligence/RhythmAnalyzer.swift` / contratos de ritmo | Ritmo existente reutilizável, confiança e candidatos de tempo | Não tratar BPM estimado como verdade única; comparar oitavas e respeitar confiança/cobertura |
| `MusicExpressionEngine/` | Contratos versionados e cache de key/sections/melody/moodHints; brilho, dinâmica e densidade definidos como dimensões mensuráveis | Não foi encontrado produtor de `MoodHintsResult` conectado ao app. A existência do contrato não comprova descritores disponíveis |
| `Creative/CreatorPreset.swift` | Codable v1: experienceID, materialID, typography, controls, exportProfile; store local de uma receita | Não possui identidade persistente própria de preset nem histórico por faixa; não inventar ID de preset salvo |
| `EnergyBudget.swift` | Política por cena para admitir novas análises, limites térmicos/Low Power/background | Discovery deverá receber a política; não criar outro observador ou loop de playback |

A API de análise de inteligência não garante uma única decodificação: energia/FFT tem sua passagem, e Rhythm v2 pode decodificar novamente em resolução temporal mais fina. O resultado é reutilizado por cache e versão de algoritmo. Não descrever o custo como uma FFT nova por recomendação nem como zero custo.

## 2. Diferenças entre a pesquisa e a base atual

- O anexo descreve prefetch das próximas cinco faixas. O código atual em `AudioDownloadManager.prefetch` mantém transfers anteriores e limita downloads especulativos a **duas faixas distintas**, excluindo a seleção foreground; há uma seleção foreground e uma transferência background por vez. A implementação deverá respeitar o mecanismo real e não ampliar o tráfego com base no texto da pesquisa.
- O ranking v1 não cria rádio somente de histórico quando o Mix falha/vem vazio. Esse comportamento é um contrato existente, distinto de tornar o processamento local. Não adicionar dependência obrigatória de servidor nova; a obtenção atual de candidatos continua dependendo da fonte existente.
- O skip legado é baseado na posição da fonte abaixo de 10 s. Não usá-lo como sinônimo de tempo ouvido. Seek, pausas e speed exigem semânticas explícitas para o novo log.
- `MusicExpressionEngine` é um diretório de contratos/cache na base examinada; não há evidência de um extrator de mood operacional. Features indisponíveis devem ser nil, nunca zero inventado.

## 3. Pontos de integração e invariantes

`ContentView.loadRelatedVideos` já protege requestID, cancelamento e faixa atual antes de publicar recomendações e alimentar a fila. `playTrack` só efetiva a transição e o histórico depois que a substituição começa. `playbackCompletionCount` conduz a conclusão. Esses limites de sessão devem também conduzir eventos Discovery e reordenação.

Preservar:

- Cold start: mesma ordem original após deduplicação/exclusões existentes.
- Nenhuma mutação de fila/history por download ou seleção que falhou.
- Mesma ordem apresentada em Descobrir e consumida na fila, quando representam o mesmo lote.
- Transferências existentes, IDs de seleção/generation, limites de concorrência e backoff do prefetch.
- Presets antigos, formato Codable v1, renderer, materiais, áudio, relógio e export existentes.
- Nada de inferência demográfica, identidade pessoal ou envio de gosto para telemetry.

## 4. Arquitetura proposta para implementação

`Candidate Source → MusicFeatureProfile → DiscoveryFeatureVector → RecommendationRanker explicável → PlaybackQueue`

Separar proveniência do candidato, descritores da faixa e preferências derivadas de eventos. `MusicDiscoveryFeatures` deve conter texto/versão, acústica opcional com origem/confiança/cobertura e contexto criativo observado. `DiscoveryFeatureVector` deve ser pequeno, determinístico e mascarado por disponibilidade; comparar somente dimensões válidas dos dois lados.

Manter o ranker v1 como baseline e estendê-lo com parcelas explícitas de similaridade acústica, compatibilidade criativa, histórico e diversidade. Uma razão como “1.25x + Chrome” só deve aparecer quando sustentada por eventos e contribuindo à pontuação; não inventar contexto para cold start ou candidatos desconhecidos.

A política de fila é separada do score: continuidade de energia, BPM compatível inclusive em oitavas, repetição e reordenação somente em eventos discretos. Nunca reordenar a cada frame/tick ou reiniciar transferências por mera mudança de posição.

## 5. Onde guardar e semântica do log

Proposta, ainda não implementada:

- Manter `omnibox.playHistory` e compatibilidade de seus campos existentes.
- Adicionar log versionado em Application Support, gravação atômica fora do MainActor, limite por quantidade e bytes, exclusão de backup e ação de apagar dados locais.
- `DiscoveryEvent`: trackID, timestamp, playDuration, completionRatio, skipReason, selectedPreset, materialID, experienceID, speed, audioPreset, exported. Campos desconhecidos permanecem opcionais.
- `playDuration` deve acumular intervalos efetivamente em reprodução com relógio monotônico; pause/resume, seek, troca de velocidade e fim de sessão são eventos, sem polling. Definir completionRatio separadamente de posição/seek e limitar a [0,1].
- Capturar contexto criativo no momento do evento; usar o ID de seleção de catálogo disponível, sem fingir que `CreatorPreset` v1 possui um UUID salvo. Só registrar exported após sucesso da geração, não por abrir a folha de compartilhamento.
- Cache compacto de perfis por identidade/revisão e versão do algoritmo; mapear trackID ao arquivo analisado e invalidar substituição da fonte. Reutilizar MusicAnalysisCache; não duplicar timelines no log.
- Limites iniciais sugeridos para revisão: 1.000 eventos / 1 MiB e 200 perfis / 1 MiB. São limites propostos, não memória medida nem contratos já publicados.

## 6. Custos e validação necessária

Não foram executados benchmark ou XCTest do Discovery, pois só a auditoria foi produzida. Nenhum ganho de qualidade/CPU/bateria é alegado.

Para C candidatos, H entradas de histórico, E eventos e D descritores pequenos: reconstruir preferência uma vez por evento/lote custa O(E·D); o ranker v1 inclui varredura de H por candidato, O(C·H), seguida de ordenação O(C log C). Uma fila gulosa de Q faixas com comparação por par pode custar O(Q²·D); limitar horizonte e executar apenas ao receber lote ou confirmar skip. Não mover trabalho desnecessariamente para cada atualização SwiftUI.

Análise offline é o custo dominante: a implementação existente pode examinar até 20 minutos de áudio e fazer passagem adicional para ritmo. Limitar a arquivos já disponíveis, admitir pelo EnergyBudget, cancelar consumidores obsoletos e reutilizar cache. Não disparar downloads adicionais para obter features.

Testes necessários: cold start/histórico vazio, histórico recorrente, skip real versus seek/falha de troca, diversidade, influência de preset/material, disponibilidade parcial, BPM em oitavas, confiança baixa, fila determinística, manutenção do prefetch, cancelamento, limites/recarga/limpeza do log e negação por EnergyBudget. XCTest completo, Release e IPA continuam gates antes de qualquer merge.

Qualidade musical exige replay e uso real: taxas de skip/conclusão, diversidade e comparação contra Mix/v1. Energia, latência e RSS precisam de iPhone/Instruments. Testes de contratos não validam preferência musical.

## 7. Próximo requisito

Receber e ler `NightcoreLab — Mapa open source de áudio, plugins, presets e voz.md`, conforme a lista obrigatória do pedido. Até lá, a branch contém somente esta auditoria; não há DiscoveryEvent, ranker v2, smart queue nova ou teste executado sendo declarado pronto.
