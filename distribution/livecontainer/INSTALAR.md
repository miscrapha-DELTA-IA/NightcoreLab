# Gnarly 56 — beta no LiveContainer

Esta é a build 56 (1.0.0) do Gnarly, com omnibox, karaokê, stems locais e a opção de GPU gratuita na nuvem. O IPA publicado é o mesmo que passou pela compilação e pelos testes desta versão. A importação e a execução no LiveContainer ainda precisam ser testadas em um iPhone.

## Instalar no iPhone com LiveContainer configurado

1. No Safari, baixe [Gnarly-56-FreeGPU.ipa](https://github.com/miscrapha-DELTA-IA/NightcoreLab/releases/download/gnarly-build56-livecontainer-beta/Gnarly-56-FreeGPU.ipa) e salve em Arquivos.
2. Abra o **LiveContainer → Apps → +** e selecione esse IPA. Se aparecer a escolha entre LiveContainer e SideStore, escolha **LiveContainer**.
3. Aguarde a importação e a assinatura pelo LiveContainer. Toque em **Gnarly** para abrir. Use o modo normal de abertura no primeiro teste.

O IPA é fornecido sem assinatura. No modo sem JIT, o próprio LiveContainer assina os apps com o certificado configurado nele; baixar o arquivo pelo Safari, sozinho, não instala o app.

## Adicionar o catálogo

Nas versões do LiveContainer com a aba **Sources/Fontes**, toque em **+** e cole:

```text
https://github.com/miscrapha-DELTA-IA/NightcoreLab/releases/download/gnarly-build56-livecontainer-beta/source.json
```

Abra **Gnarly Beta → Gnarly → Install**. O catálogo aponta para a mesma build 56 do download direto e identifica a versão como 1.0.0 (56). Não é necessário usar o catálogo para instalar pelo arquivo.

## Ainda não tem LiveContainer

Use o [guia oficial de LiveContainer + SideStore](https://livecontainer.github.io/docs/installation/lc_sidestore) e a versão estável oficial. O guia oferece instalação por Impactor/iloader usando computador e cabo, ou por um SideStore que já esteja instalado. A importação posterior do Gnarly pode ser feita só no iPhone.

Após instalar o host, siga a configuração oficial: entre no SideStore com sua própria conta Apple, faça **Refresh All** conforme o guia e, nas configurações do LiveContainer, use **Import Certificate from SideStore**. Confira **JIT-Less Mode Diagnose**. Renove o LiveContainer antes da validade indicada no SideStore. Não compartilhe conta Apple nem certificado entre os amigos.

## Requisitos e dados existentes

- **iOS 17 ou superior**, dispositivo arm64. A separação neural local exige iOS 18; no XR, prefira a opção de nuvem para este teste.
- O Gnarly dentro do LiveContainer usa um contêiner de dados próprio. Downloads, histórico e configurações do app instalado diretamente por sideload não são transferidos automaticamente. Mantenha a instalação atual durante o primeiro teste.
- As permissões são controladas pelo host. Ao testar o karaokê, confira o acesso do LiveContainer ao microfone. Importação de arquivos, gravação de Story e reconhecimento de fala também devem ser conferidos no aparelho.
- Para atualizar uma instalação já existente dentro do LiveContainer, importe o IPA e use a opção de atualizar/substituir o Gnarly no contêiner existente; não apague o contêiner para fazer uma atualização.

## GPU gratuita

Na música, abra **STEMS → Separar com GPU grátis → Enviar música e separar**. A opção comunitária usa BS-Roformer em um Space público do Hugging Face, sem token ou cartão configurado pelo app e sem alternativa paga automática. Leia o aviso de envio antes de confirmar: o mantenedor do Space controla a retenção do áudio e dos resultados.

Há fila e cota externa. A admissão inicial do backend é compartilhada entre os testadores: até duas tentativas por 24 horas por instância, com intervalo mínimo de 15 minutos. Esse contador é temporário e pode reiniciar com o serviço; a cota do Hugging Face pode bloquear antes disso. Não é uma garantia de duas separações concluídas por dia. Combine os testes de GPU entre os participantes.

Use Wi-Fi: os quatro WAVs de uma faixa de 4:53 podem somar cerca de 414 MB. Os stems concluídos ficam disponíveis offline. Um teste sintético de 12 segundos produziu quatro arquivos válidos; a tentativa sintética de 4:53 foi recusada por cota antes da inferência. Ainda não há medição de tempo de uma música completa nem avaliação de qualidade musical no XR.

## Primeiro teste antes de ampliar para 5–10 pessoas

Comece em dois aparelhos, incluindo o XR:

1. Abra, pesquise, feche/reabra a omnibox e reproduza uma música.
2. Confira fila, próxima faixa, download independente da reprodução e capa offline.
3. Bloqueie/desbloqueie a tela durante a reprodução; confira áudio e controles externos.
4. Confira microfone, legendas e pontuação do karaokê.
5. Quando houver cota, separe uma faixa pela GPU, altere os volumes dos quatro stems e reabra os resultados offline.

Registre modelo do iPhone, versão do iOS, versão do LiveContainer e o ponto em que algo falhar. Após esses testes, compartilhe a mesma página da release com os demais participantes.

## Identificação do pacote

- Nome exibido: **Gnarly**.
- Versão: **1.0.0 (56)**.
- Identificador: `com.nightcorelab.app`.
- Fonte: `e8ef9602bdc63c6ef771d3ccf28311f8db4d6716`.
- Tamanho: **112.012.192 bytes**.
- SHA-256: `bf1fc2a5128aa742d5c05895a8b42222680b8e958465f7723a995078f94e8c1e`.
- Os 26 modelos locais e seus avisos de licença estão preservados no IPA.
- Validação anterior à distribuição: CI completo com 685 testes, uma ausência de fixture já existente e zero falhas. Isso não substitui a validação física no LiveContainer.

Documentação oficial: [importar apps](https://github.com/LiveContainer/LiveContainer#installing-apps), [catálogos](https://livecontainer.github.io/docs/guides/sources), [instalação do host](https://livecontainer.github.io/docs/installation/lc_sidestore).
