# Gnarly 57 — beta no LiveContainer

Esta é a build 57 (1.0.0) do Gnarly, com omnibox, karaokê, stems locais e a opção de GPU gratuita na nuvem. O IPA publicado é o mesmo que passou pela compilação e pelos testes desta versão. A importação e a execução no LiveContainer ainda precisam ser testadas em um iPhone.

## Instalar no iPhone com LiveContainer configurado

1. No Safari, baixe [Gnarly-57-Continuity.ipa](https://github.com/miscrapha-DELTA-IA/NightcoreLab/releases/download/gnarly-build57-livecontainer-beta/Gnarly-57-Continuity.ipa) e salve em Arquivos.
2. Abra o **LiveContainer → Apps → +** e selecione esse IPA. Se aparecer a escolha entre LiveContainer e SideStore, escolha **LiveContainer**.
3. Aguarde a importação e a assinatura pelo LiveContainer. Toque em **Gnarly** para abrir. Use o modo normal de abertura no primeiro teste.

O IPA é fornecido sem assinatura. No modo sem JIT, o próprio LiveContainer assina os apps com o certificado configurado nele; baixar o arquivo pelo Safari, sozinho, não instala o app.

## Adicionar o catálogo

Nas versões do LiveContainer com a aba **Sources/Fontes**, toque em **+** e cole:

```text
https://raw.githubusercontent.com/miscrapha-DELTA-IA/NightcoreLab/gnarly-beta/source.json
```

Abra **Gnarly Beta → Gnarly → Install**. O catálogo aponta para a mesma build 57 do download direto e identifica a versão como 1.0.0 (57). Não é necessário usar o catálogo para instalar pelo arquivo.

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
5. Quando houver cota, inicie a GPU, puxe notificações, troque de música e saia/volte ao Gnarly. Confira que a tarefa mantém a música original e não pede uma nova admissão. Depois, altere os quatro volumes e reabra os stems offline.
6. No teste local, puxe notificações e confira que o processamento continua. Saia/volte ao app e confira pausa/retomada com o avanço salvo.
7. No karaokê, cante um trecho, volte e avance na letra: a pontuação deve permanecer e o trecho repetido não pode render pontos outra vez.
8. Abra **Ver resultado → Compartilhar resultado**. Confira a imagem com a mesma capa, layout e pontuação, sem passar pelo editor de Story.

Registre modelo do iPhone, versão do iOS, versão do LiveContainer e o ponto em que algo falhar. Após esses testes, compartilhe a mesma página da release com os demais participantes.

## Correções da build 57

- Puxar notificações ou a Central de Controle não cancela a separação.
- Trocar a música mantém a tarefa vinculada à faixa original. Seus stems não são aplicados à outra música.
- A GPU mantém admissão, identificador do pedido, resposta e arquivos concluídos. Retomar reutiliza esse pedido, sem pedir outra separação para ele. Uma falha real de cota continua sujeita ao provedor.
- As transferências de resultado e WAVs usam a sessão de downloads em segundo plano do iOS. O sistema controla a execução em segundo plano; encerrar o app à força pode interromper transferências. Ao reabrir, a tarefa salva pode ser retomada.
- A separação local pausa ao entrar em segundo plano, libera os modelos e retoma os segmentos já calculados ao voltar. O segmento que estava em cálculo pode precisar ser repetido. Os checkpoints usam espaço adicional no aparelho.
- Voltar ou avançar na letra preserva a pontuação; intervalos já avaliados não contam novamente. Os trechos pulados não ganham pontos automaticamente.
- Compartilhar na tela de resultado captura a tela apresentada, com sua capa, layout e pontuação, e abre a folha nativa de compartilhamento com essa imagem.

A execução física no XR e dentro do LiveContainer ainda precisa do teste no aparelho.

## Pacote verificado

Fonte: `21616005a706871bb5ea0697a123a9205393a9f4`.

Versão: **1.0.0 (57)**, arm64/iOS 17+, nome **Gnarly**, identificador `com.nightcorelab.app`, 26 partes do modelo local.

Tamanho: **112107110 bytes**. SHA-256:

```text
a12387c7bd3d361c8dd3eeb78ad090559e0e0c24111f15ef0c03e3a8f6440dc9
```
