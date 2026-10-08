# Qualidade de áudio e importação MP3

Esta revisão usa processamento nativo do iOS 17+. Não incorpora código nem dependências do tape-warp.

## Avaliação da referência

O repositório https://github.com/krish-134/tape-warp foi consultado como referência:

- A implementação Rust de velocidade usa interpolação linear e altera o tom junto com a velocidade.
- O reverb Rust é um Schroeder básico; o próprio código reconhece a possibilidade de som metálico.
- O protótipo Python usa Rubber Band/Pedalboard e arquivos intermediários.
- Não havia licença declarada na árvore consultada. Não foi copiado código.

A separação entre processamento PCM e entrada/saída é adequada; trocar o motor nativo por esse protótipo não constitui, por si, uma melhoria de qualidade.

## Alterações

- Nightcore/Slowed: AVAudioUnitVarispeed altera velocidade e tom juntos. O time-stretch é ignorado nesse modo, evitando processamento desnecessário de transientes.
- Manter o tom original: AVAudioUnitTimePitch permanece ativo, com overlap 16.
- Velocidade e tom são atualizados juntos pela interface.
- Graves: shelf em 120 Hz, com compensação de ganho equivalente ao reforço. Isso reduz o acionamento excessivo do limitador; pode soar mais baixo que a versão anterior.
- Proteção: AUPeakLimiter dedicado e margem de saída de 1,5 dB. Não é uma garantia de true-peak nem normalização de loudness.
- Reverb: preset nativo medium hall mantido; bypass quando o controle está em zero.
- Entrada MP3/M4A/WAV/AIFF explicitada. Core Audio decodifica para PCM float32 sem reencodificação intermediária com perdas.
- Importações usam pastas exclusivas; importar um arquivo de mesmo nome não apaga a origem nem a faixa anterior.
- AAC/M4A exportado em 320 kb/s, qualidade máxima do encoder. WAV em PCM de 24 bits, preservando a taxa da fonte.
- Export usa o mesmo grafo da prévia, nomes únicos e limite de tentativas quando o render não avança.
- Backend: quando é necessário converter para AAC, solicita 320 kb/s; AAC/m4a nativo continua sendo preservado pelo pós-processador.

MP3 é formato de entrada. Exportação MP3 não foi adicionada: exigiria um encoder adicional. AAC e WAV continuam sendo as saídas.

Bitrate maior e WAV não recuperam informação que já foi perdida no arquivo original ou no YouTube. Bluetooth, fonte e ajustes extremos continuam influenciando o resultado. O processamento tem latência, mesmo sendo nativo.

## Verificação automatizada

O workflow iOS executa testes XCTest no simulador antes de produzir o IPA:

- Frequência e duração no modo fita em 0,5×, 0,8×, 1×, 1,25× e 2×.
- Frequência preservada com time-stretch.
- RMS no modo neutro, saída estéreo e WAV 24-bit.
- Saída finita e picos de amostras abaixo de full scale com graves e reverb altos.
- Exportação AAC decodificável.
- Importação e exportação de um MP3 real, gerado a partir de senoide de teste.

Esses testes não substituem escuta comparativa no iPhone com volume igualado, nem medem todas as condições de true-peak, codecs Bluetooth ou arquivos corrompidos.

## Ajustes de interface pendentes incluídos

O deep link agora preenche a caixa de texto; o usuário toca em Baixar. Se o Atalho enviar link vazio, o app informa isso explicitamente. A seção Próximas Faixas permanece visível; cartões vazios são placeholders, não músicas inventadas. Os cartões reais são carregados após download bem-sucedido pelo YouTube.
