Gnarly **1.0.0 (57)** com correções na continuidade dos stems e no karaokê.

- Puxar notificações/Central de Controle mantém a separação ativa. Trocar de música mantém a tarefa vinculada à faixa original.
- A nuvem guarda o pedido e os arquivos recebidos para retomar sem iniciar outra separação. A separação local salva segmentos, pausa em segundo plano e retoma ao voltar; o segmento interrompido pode precisar ser repetido.
- Navegar pela letra preserva a pontuação, o combo e a precisão. Trechos já avaliados não contam novamente e saltos não geram pontos pela lacuna pulada.
- **Compartilhar resultado** envia uma imagem da tela de resultado apresentada, com sua capa, layout e pontuação, pela folha nativa de compartilhamento.

### Instalar

1. Baixe [Gnarly-57-Continuity.ipa](https://github.com/miscrapha-DELTA-IA/NightcoreLab/releases/download/gnarly-build57-livecontainer-beta/Gnarly-57-Continuity.ipa) no Safari e salve em Arquivos.
2. No LiveContainer configurado, abra **Apps → +** e selecione o IPA. Escolha instalar dentro do **LiveContainer**.
3. Aguarde a importação/assinatura e abra **Gnarly**. Para atualizar um Gnarly já no LiveContainer, mantenha o contêiner existente.

Também é possível atualizar pelo catálogo em **Sources/Fontes → +**:

```text
https://raw.githubusercontent.com/miscrapha-DELTA-IA/NightcoreLab/gnarly-beta/source.json
```

O IPA é fornecido sem assinatura. O LiveContainer precisa estar configurado para assinar os aplicativos; siga o [guia oficial de LiveContainer + SideStore](https://livecontainer.github.io/docs/installation/lc_sidestore). A instalação inicial usa computador/cabo ou SideStore já instalado. Depois disso, a importação do Gnarly pode ser feita no iPhone.

**iOS 17+**; modelo neural local em **iOS 18+**. A instalação dentro do LiveContainer tem dados separados do Gnarly instalado diretamente. Mantenha a instalação atual durante o primeiro teste.

A GPU gratuita continua sujeita à fila e à cota real do provedor. Retomar um pedido salvo não aumenta essa cota. O iOS controla a execução em segundo plano e pode interromper transferências ao encerrar o app à força; a tarefa fica registrada para retomada. As instruções e o teste inicial para dois aparelhos estão em [INSTALAR.md](https://github.com/miscrapha-DELTA-IA/NightcoreLab/releases/download/gnarly-build57-livecontainer-beta/INSTALAR.md).

A validação física no XR/LiveContainer ainda precisa ser realizada. Confira o arquivo **SHA256SUMS.txt** nos anexos para identificar o IPA.

### Validação do pacote

[Qualificação completa e IPA](https://github.com/miscrapha-DELTA-IA/NightcoreLab/actions/runs/39674158334): **696 testes, 1 ignorado por depender de faixas externas, zero falhas**. Modelo neural real, comparação com a referência, mixer, memória e renderização/exportação aprovados.

Fonte do aplicativo: [`2161600`](https://github.com/miscrapha-DELTA-IA/NightcoreLab/commit/21616005a706871bb5ea0697a123a9205393a9f4). Pacote verificado como **Gnarly 1.0.0 (57)**, arm64/iPhoneOS, iOS 17+, com as 26 partes do modelo local. O arquivo foi extraído do artefato original sem reempacotamento.
