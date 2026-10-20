# Stems locais (motor opt-in)

`StemSeparationService.shared` gera quatro arquivos CAF float32 estéreo a 44,1 kHz.
Este serviço não é acionado pela UI nem pelo `AudioEngineManager`; uma integração
de reprodução futura poderá escolher os arquivos sem alterar este motor.

```swift
let service = StemSeparationService.shared
let events = await service.states() // AsyncStream<StemSeparationState>
Task {
    for await state in events { print(state) }
}
let files = try await service.separate(trackID: track.id, sourceURL: cachedAudioURL)
// files.vocals, files.drums, files.bass, files.other
```

Estados: `naoBaixado`, `baixando(0...1)`, `processando(0...1, eta:)`,
`pausado(motivo)`, `pronto(StemURLs)` e `erro(mensagem)`. O trabalho roda fora
do ator principal; cancele a `Task` do chamador para interromper processamento
e guardar dados retomáveis do download. Durante estado térmico serious/critical
ou Modo de Pouca Energia, o processamento aguarda e publica `pausado`.

O backend é um `StemSeparationBackend` actor. O inicial é a conversão FP32
[HTDemucs Core ML](https://huggingface.co/dexxdean/htdemucs-coreml) na revisão
`8b4d48132d579d5aa53fb0569de605c64318a2af`, licenciada em MIT. Seu
`.mlpackage` é baixado diretamente pelos três arquivos declarados no modelo,
com tamanho e SHA-256 fixos, usando `URLSession` em background. A versão
compilada fica em `Application Support/StemModels/8b4d481-fp32-10s`; não entra
no backup. A inferência usa `.cpuAndGPU`, pois o autor alerta que ANE não é
estável nessa conversão. Entrada: `[1,2,441000]` (`audio`); saída:
`[1,4,2,441000]` (`sources`), na ordem **vocals, drums, bass, other**.
O STFT/iSTFT está dentro do grafo Core ML. A sobreposição entre chunks é de
44.100 amostras e usa crossfade temporal. O residual do modelo é atribuído
ao stem `other` para preservar a soma da mistura.

Os resultados ficam em `Application Support/Stems/<trackID>/<modelVersion>/`
(IDs com caracteres de caminho são normalizados e recebem um hash)
e são reutilizados se os quatro CAFs estiverem íntegros. A pasta é excluída
do backup. A conversão para estéreo 44,1 kHz usa buffers de 8.192 frames; o
processamento mantém apenas um chunk e o tail de overlap em memória.

## Testes e benchmark

`StemAudioMathTests` valida a reconstrução estéreo e o crossfade. O teste exige
SNR acima de 110 dB para uma mistura sintética após correção de residual.
É um teste da matemática do pipeline; não mede a qualidade de separação do
modelo. O fornecedor dessa conversão não publicou vetores independentes de
STFT/iSTFT para o host, pois ambas as transformadas estão embutidas no modelo.

Em um iPhone, habilite o log da categoria `StemBenchmark` e registre: tempo
total, segundos de processamento por minuto de áudio, pico de RSS em bytes,
estado térmico, Modo de Pouca Energia, taxa de erro do download, espaço livre
antes e depois e SNR de reconstrução dos quatro CAFs somados contra a fonte.
Teste pelo menos faixas de 30 s e 4 min em um iPhone frio e após uso prolongado.

## Licenças e escolha do modelo

HTDemucs e sua conversão acima são MIT. O [Mini-BS-RoFormer 18M original](https://huggingface.co/HiDolen/Mini-BS-RoFormer-18M)
também é MIT, mas o repositório fornecido contém apenas Safetensors/PyTorch,
sem `.mlpackage` para iOS. O `schism-dsp`/`SchismPipeline` citado no pedido
não está publicado como pacote Swift acessível; por isso não foi adicionado
ao `project.yml`. A [V2](https://huggingface.co/HiDolen/Mini-BS-RoFormer-V2-46.8M)
é CC-BY-NC-4.0 e não é usada. A interface de backend permite adicionar uma
conversão Core ML Mini-BS-RoFormer validada futuramente.
