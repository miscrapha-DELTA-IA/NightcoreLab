# Stage 15C — Final Review

Revisão realizada em 13/10/2026. Escopo: PR [#46](https://github.com/miscrapha-DELTA-IA/NightcoreLab/pull/46), Performance Foundation.

## 1. Identidade exata e situação do merge

| Referência | SHA |
| --- | --- |
| Base anterior ao 15C | `2c2ce27e94004a0c639204956e646e08ecdcfe3c` |
| Commit inicial, `feat: add runtime energy budget and performance foundation` | `b409e721fd9630d0a1bc928e340f770b42433b64` |
| Correção de compatibilidade MetricKit e replay no EOF | `ecdc0c0eb020d2fd167ae9b29a6e2832578ae936` |
| **Head final validado pela CI** | **`082a3e6155473a8aa3b30aca601124eeac6cd980`** |
| **Merge do PR #46 na main** | **`f08a20fcddf20b71a88cc765e60262527e263e3c`** |
| Árvore Git compartilhada pelo head validado e pelo merge | `8a4215e4cc7f31373be5439800bc9a68e435e88f` |

O GitHub confirma que o usuário já realizou o merge em **13/10/2026 às 16:13:25 UTC (13:13:25 em Fortaleza)**. Portanto, este documento é uma revisão retrospectiva do merge existente, não uma aprovação prévia fictícia. Nenhum novo merge foi executado para produzir este relatório.

`git diff --exit-code 082a3e6 f08a20f` não apresenta diferenças: o conteúdo incorporado à main é idêntico ao head validado. As evidências abaixo são das execuções do PR nesse head; não são apresentadas como uma nova execução pós-merge.

## 2. CI, XCTest, Release e IPA

Todos os quatro workflows do head final concluíram com `success`:

| Workflow | Execução | Resultado |
| --- | --- | --- |
| iOS Build | [38361310105](https://github.com/miscrapha-DELTA-IA/NightcoreLab/actions/runs/38361310105) | Build de simulador aprovado |
| Karaoke Clean Mode Tests | [38361310128](https://github.com/miscrapha-DELTA-IA/NightcoreLab/actions/runs/38361310128) | Aprovado |
| Share Card iOS Tests | [38361310525](https://github.com/miscrapha-DELTA-IA/NightcoreLab/actions/runs/38361310525) | Aprovado |
| Build Unsigned IPA (Free Route) | [38361310117](https://github.com/miscrapha-DELTA-IA/NightcoreLab/actions/runs/38361310117) | XcodeGen, benchmark, XCTest completo, Release e IPA aprovados |

O job principal `115175907341` registra:

- **421 testes reportados: 420 aprovados, 1 ignorado, 0 falhas.** Tempo reportado pelo XCTest: 76,574 s de testes; 79,884 s no resumo total da suíte.
- `EnergyBudgetTests`: cinco testes aprovados, cobrindo política normal/Low Power, estados térmicos, app em background, Reduce Motion, combinações de intervalos e impedimento de IO para análise não admitida.
- `PerformanceRegressionTests`: cinco testes aprovados, cobrindo pausa longa/seek/retomada, pausa curta/troca de faixa, interrupção, replay após seek até o fim e persistência local limitada.
- Teste ignorado: `RhythmGenreFixtureTests.testRealTracksWhenProvided`, por ausência de `TEST_RUNNER_NIGHTCORE_RHYTHM_FIXTURES` com `manifest.json`. Isso **não** valida ritmo com músicas reais.
- `xcodegen generate`: aprovado.
- `xcodebuild test`: `TEST SUCCEEDED`.
- Build **Release para iphoneos, sem assinatura**: `BUILD SUCCEEDED`.
- Empacotamento e upload do **IPA unsigned**: aprovados. Não é uma distribuição assinada/TestFlight/App Store.

Artefatos da execução principal, publicados em 13/10/2026 e com expiração informada para 20/10/2026:

| Artefato | ID | Conteúdo |
| --- | --- | --- |
| `NightcoreLab-App` | `11795965516` | `NightcoreLab_Unsigned.ipa` |
| `AudioQuality-Tests` | `11795700963` | Resultados XCTest (`AudioQuality.xcresult`) |
| `MaterialResolver-Benchmark` | `11795300872` | JSON do benchmark existente |

As primeiras tentativas não foram verdes: a API geral `hitchTimeRatio` exigia iOS 26 e foi substituída pela métrica de rolagem compatível com iOS 17. A espera fixa de 250 ms do teste de pausa longa também falhou; o deadline foi ancorado em relógio monotônico e o teste passou a aguardar a condição com timeout de 3 s, mantendo a asserção de engine parado. A CI acima corresponde às correções finais, não às tentativas com falha.

## 3. Todos os arquivos alterados no PR #46

Diff entre a base e o head final: **14 arquivos; 544 adições e 51 remoções**. O presente relatório é um arquivo adicional, posterior ao PR #46.

| Status | Caminho | Mudança |
| --- | --- | --- |
| Modificado | `NightcoreLab/Sources/AudioEngineManager.swift` | Deadline de idle stop, retomada/posição, proteção de callbacks e signposts |
| Modificado | `NightcoreLab/Sources/ContentView.swift` | Cadência e admissão de movimento do disco |
| Modificado | `NightcoreLab/Sources/Creative/AudioFeatureEngine.swift` | Budget explícito para admissão da análise automática |
| Modificado | `NightcoreLab/Sources/Creative/CreativeReactiveAccent.swift` | Consumo da política central no lugar do estado local de energia |
| Novo | `NightcoreLab/Sources/EnergyBudget.swift` | Value type, Environment e observadores por cena |
| Modificado | `NightcoreLab/Sources/KaraokeLyricsView.swift` | Intervalo explícito e pausa de updates da linha ativa |
| Novo | `NightcoreLab/Sources/LocalPerformanceMetrics.swift` | Subscriber MetricKit e armazenamento local limitado |
| Modificado | `NightcoreLab/Sources/NightcoreLabApp.swift` | Injeção da política e propriedade do subscriber no app delegate |
| Modificado | `NightcoreLab/Sources/NowPlayingScreen.swift` | Fundo usa budget em vez de estado Low Power duplicado |
| Modificado | `NightcoreLab/Sources/PlayerBackground.swift` | Marquee usa admissão central e task cancelável |
| Modificado | `NightcoreLab/Sources/TurbulentMarbleView.swift` | Política somente no agendamento live; caminho frozen preservado |
| Novo | `NightcoreLabTests/EnergyBudgetTests.swift` | Testes da política |
| Novo | `NightcoreLabTests/PerformanceRegressionTests.swift` | Testes de transporte e armazenamento |
| Novo | `docs/STAGE_15C_PERFORMANCE_AUDIT.md` | Auditoria inicial, escopo e protocolo de medição |

## 4. Arquitetura efetivamente entregue

### EnergyBudget

`struct EnergyBudget: Equatable, Sendable`, passado pelo SwiftUI Environment. Não há novo singleton da aplicação. O provider lê Low Power, thermal state, Reduce Motion e scene phase; reage a notificações e mudanças de cena, sem polling.

| Condição, app ativo | Teto de updates visuais | Nova análise | Decoração |
| --- | --- | --- | --- |
| Nominal | 60 FPS | Sim | Sim, salvo Reduce Motion |
| Low Power | 30 FPS | Não | Sim, salvo outra restrição |
| Thermal fair | 30 FPS | Sim, salvo Low Power | Sim, salvo Reduce Motion |
| Thermal serious | 15 FPS | Não | Não |
| Thermal critical | Updates pausados | Não | Não |
| App inativo/background | Updates pausados | Não | Não |

O valor técnico de FPS para critical/background é 1 para manter o intervalo finito, mas os consumidores pausam o Timeline. Reduce Motion suspende decoração; não elimina o progresso útil das palavras. `allowsExport` está exposto como política de admissão para consumidores futuros; **não foi conectado para interromper ou alterar o export existente**. Os tetos são configuração, não FPS medido.

### MetricKit local

`LocalPerformanceMetrics` pertence ao app delegate e registra-se no `MXMetricManager.shared` do sistema. Não é integrado ao `TelemetryManager`. Persiste somente CPU seconds, GPU seconds, peak memory bytes, background audio seconds e scroll hitch ratio/unidade. Não salva payload bruto, metadata de dispositivo, diagnósticos, faixas ou URLs.

IO serial em QoS utility, arquivo atômico protegido em `Application Support/LocalPerformance/metrics.json`, excluído de backup; limite de **30 registros e 64 KiB**. Métricas ausentes permanecem ausentes. Não há envio nem dependência externa. Entrega real dos agregados pelo sistema ainda precisa ser observada em dispositivo; o teste valida o armazenamento com amostras controladas.

### Timeline throttling

Karaokê e disco passam a ter intervalo explícito. Marble limita o agendamento live pelo menor valor entre o teto do chamador e o budget. O marquee cancela/reinicia conforme a política. O scrubber existente a 15 Hz e o loop reativo existente a 12 Hz durante reprodução / 450 ms pausado não foram otimizados nesta etapa. O budget não cria loop durante playback.

### Ciclo de vida do áudio

A pausa captura posição e pausa o player. Após **10 s configuráveis**, um único task cancelável para o player/engine, invalida callbacks antigos e preserva a posição para reagendamento. Play e troca de faixa cancelam deadlines obsoletos. A conclusão natural também agenda idle stop. Seek e replay no EOF foram cobertos. Signposts `Audio resume` e `Audio idle stop` permitem inspeção posterior.

Não foi criado um segundo engine de reprodução nem modificada a cadeia DSP. O renderer offline já existente continua intacto.

## 5. Fronteiras preservadas e precisão das afirmações

O diff de conteúdo confirma ausência de alterações em:

- `Creative/VisualComposition/CompositionRuntime.swift` e diretório de composição.
- `Creative/VisualMaterial/`: catálogo, tipos, resolver e algoritmos de materiais.
- `Share/`: inclusive `StorySceneView.swift` e `StoryVideoExporter.swift`, renderer/encoder e agendamento de export.
- `Resources/Shaders.metal`.
- `EnginePlaybackClock.swift` e `MusicIntelligence/RhythmAnalyzer.swift`.

As suítes existentes de paridade de runtime/material/tipografia e qualidade de áudio continuam no XCTest completo aprovado.

**Sincronização de áudio:** o algoritmo do relógio, compensação de latência, mapeamento de velocidade e equações DSP não foram alterados. Porém, o transporte e o getter de posição em `AudioEngineManager` foram alterados para preservar posição pausada/suspensa. Portanto, não seria correto afirmar que todo o código relacionado a tempo ficou intocado. Os testes aprovam os contratos exercitados no simulador; não substituem medição de sincronismo físico, Bluetooth ou comparação auditiva em iPhone.

**Preview/export:** os caminhos determinísticos de Story não foram editados. Isso sustenta preservação do contrato existente, mas não constitui nova inspeção pixel a pixel em hardware. Cadência e admissão do preview live passam a depender do budget; estados restritos podem suspender movimento/reação.

## 6. Medições disponíveis e ausentes

### O que foi medido

O benchmark já existente de `MaterialResolver` rodou no runner macOS, compilado em Release `-O`, com entradas aquecidas, **7 lotes cronometrados**, 100.000 frames por material e lote separado de contagem de alocações, **sem renderer**:

| Material | Mediana ns/frame | Chamadas de alocação observadas/frame |
| --- | ---: | ---: |
| original-marble | 189,02 | 0 |
| cyber-chrome | 160,08 | 0 |
| neon-pulse | 183,91 | 0 |
| liquid-glass | 208,75 | 0 |
| chrome-night | 166,47 | 0 |
| organic-pulse | 151,41 | 0 |
| atmospheric-smoke | 183,65 | 0 |
| advanced-marble | 169,33 | 0 |

O controle positivo detectou 1 evento de alocação. A instrumentação observa entradas malloc/calloc/realloc/valloc/posix_memalign e malloc_zone, deduplicando chamadas aninhadas. Não mede GPU, VM nem alocações do app inteiro. Strides reportados: `MaterialFrame` 216 bytes e `VisualParameterSet` 48 bytes; não representam RSS do app.

Esses números caracterizam o resolver **não modificado** no runner. Não são comparação antes/depois do 15C e não demonstram economia de bateria, melhoria de FPS ou desempenho em iPhone. Os tempos de XCTest também não são benchmark energético.

### O que não foi medido

Não há comparação controlada antes/depois de consumo energético, CPU/GPU do app inteiro, RSS/alocações em sessão longa, latência audível de retomada, carga térmica, FPS Metal, bateria ou pacotes reais recebidos do MetricKit. **Nenhum percentual de economia é alegado.** Scroll hitch ratio não equivale a FPS Metal.

### O que exige iPhone/Instruments

Comparar a base e o head validado no mesmo iPhone, mesma versão de iOS, arquivo, preset, volume e rota. Fazer 5 min de aquecimento, 15 min de reprodução, pausa de 30 s e retomada, com 3 repetições; acrescentar sessão de pelo menos 30 min.

Registrar Time Profiler e signposts de áudio, Allocations/Leaks e RSS, Energy Log, Metal System Trace/FPS e estados térmicos. Repetir em Low Power, Reduce Motion, background, alto-falante e Bluetooth. Exercitar comandos remotos, interrupções, troca de rota, seek durante pausa e troca de faixa. Comparar captura visual no mesmo timestamp e continuidade auditiva, inclusive com reverb; receber e inspecionar os agregados locais do MetricKit.

## 7. Riscos e conclusão

1. Parar o engine após a pausa longa pode reinicializar a cauda de efeitos DSP; posição e parâmetros preservados não garantem cauda de reverb bit a bit idêntica.
2. Teto nominal de 60 FPS pode reduzir a cadência anterior em telas ProMotion de 120 Hz. Fluidez perceptiva ainda requer dispositivo.
3. Suspensão do processo pode atrasar a execução do deadline em background. O prazo monotônico evita contar o atraso inicial como novo período de graça, mas não impede suspensão pelo sistema.
4. Thermal serious/critical e background suspendem decoração/reação; transições visuais e recuperação precisam de inspeção física.
5. Métricas MetricKit podem não chegar no simulador; scroll hitch não cobre todo o comportamento de Metal. Capacidade de coleta não significa ganho de performance comprovado.
6. Validação com músicas reais ficou ignorada por falta de fixtures; rotas físicas, comandos remotos e sessões longas não foram aprovados por este relatório.
7. O documento adicional de energia não estava disponível durante a implementação. Foram usados os pontos transcritos pelo usuário e `RUNTIME_STABILIZATION_STAGE10C.md`; essa limitação consta da auditoria inicial.

**Conclusão:** a fundação 15C foi incorporada com a mesma árvore validada por CI verde, Release e IPA unsigned. Os testes automatizados não têm falhas no head final, com a exceção explicitamente ignorada. A estabilidade física e a economia energética permanecem pendentes de validação em iPhone. Este relatório não modifica runtime e não autoriza nem executa novo merge.
