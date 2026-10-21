Gnarly **1.0.0 (56)** disponível para o primeiro beta pelo LiveContainer. Inclui omnibox, karaokê, stems locais e separação opcional com GPU gratuita/BS-Roformer. O pacote preserva os recursos e os 26 modelos locais da versão atual.

### Instalar no iPhone

1. Baixe [Gnarly-56-FreeGPU.ipa](https://github.com/miscrapha-DELTA-IA/NightcoreLab/releases/download/gnarly-build56-livecontainer-beta/Gnarly-56-FreeGPU.ipa) no Safari e salve em Arquivos.
2. Abra **LiveContainer → Apps → +**, selecione o IPA e escolha instalar **dentro do LiveContainer**.
3. Aguarde a importação/assinatura e abra **Gnarly**.

É necessário ter o LiveContainer configurado. O IPA não tem assinatura; no modo sem JIT, o LiveContainer utiliza seu certificado para assiná-lo. Para configurar o host pela primeira vez, siga o [guia oficial](https://livecontainer.github.io/docs/installation/lc_sidestore): computador/cabo ou SideStore já instalado. Depois disso, a importação do Gnarly é feita no iPhone.

### Catálogo para LiveContainer

Em **Sources/Fontes → +**, cole:

```text
https://github.com/miscrapha-DELTA-IA/NightcoreLab/releases/download/gnarly-build56-livecontainer-beta/source.json
```

Abra **Gnarly Beta → Gnarly → Install**. Se a sua versão não tiver Sources, use a importação do IPA acima.

### Antes de testar

- **iOS 17+**. O modelo neural local exige iOS 18; no XR, prefira a opção de GPU na nuvem.
- A instalação dentro do LiveContainer tem dados separados da instalação direta. Mantenha a instalação atual durante o primeiro teste.
- A compatibilidade em execução no LiveContainer ainda aguarda teste no aparelho, especialmente áudio com a tela bloqueada e microfone/karaokê. Comece em dois aparelhos antes de ampliar para 5–10.
- **GPU gratuita tem fila e cota**, sem alternativa paga automática. A admissão inicial no backend é compartilhada: até duas tentativas/24h por instância, com intervalo de 15 minutos, em contador temporário. A cota do Hugging Face pode bloquear antes. O áudio é enviado a um Space público; leia o aviso no app. Prefira Wi-Fi.

Consulte [INSTALAR.md](https://github.com/miscrapha-DELTA-IA/NightcoreLab/releases/download/gnarly-build56-livecontainer-beta/INSTALAR.md) para configuração, testes e limites da GPU.

### Verificação

Fonte: [`e8ef960`](https://github.com/miscrapha-DELTA-IA/NightcoreLab/commit/e8ef9602bdc63c6ef771d3ccf28311f8db4d6716). CI completo: **685 testes, zero falhas, uma ausência de fixture já existente**. IPA arm64 íntegro, sem criptografia de distribuição, com os 26 modelos locais. Execução física no LiveContainer pendente.

**SHA-256** de `Gnarly-56-FreeGPU.ipa` (112.012.192 bytes):

```text
bf1fc2a5128aa742d5c05895a8b42222680b8e958465f7723a995078f94e8c1e
```
