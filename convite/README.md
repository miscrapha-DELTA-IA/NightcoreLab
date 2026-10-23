# GNARLY — convite beta e instalação iPhone (v66)

Este é um microsite estático em duas páginas que pode ser hospedado sem build ou dependências de servidor.

## Arquivos
- `index.html`: primeira página / convite.
- `instalar.html`: segunda página / download da IPA v66, Sideloadly e instalação.
- `styles.css`: layout GNARLY responsivo.

## Publicar no Netlify
1. Abra o Netlify e crie um site estático, escolhendo este repositório GitHub.
2. Selecione a branch `feat/gnarly-invite-sideload-guide` (antes do merge) ou `main` (depois do merge).
3. Configure **Base directory** como vazio e **Publish directory** como `convite`, sem build command.
4. Publique; a URL raiz mostrará `index.html` e `/instalar.html` será a segunda página.

Como alternativa, arraste a pasta `convite/` inteira para a ferramenta de deploy manual do Netlify, se disponível.

## IPA específica publicada no guia
- Build GNARLY **v66** (CFBundleVersion 66).
- Workflow aprovado: https://github.com/miscrapha-DELTA-IA/NightcoreLab/actions/runs/39995572649
- Artefato: **NightcoreLab-App**, ID 12522490230, contendo `NightcoreLab_Unsigned.ipa`.
- Link: https://github.com/miscrapha-DELTA-IA/NightcoreLab/actions/runs/39995572649/artifacts/12522490230
- Commit: `1b007b8f55750af7834906b565427ca2f69121a4`
- Expiração prevista: **2026-10-30 18:06:15 UTC**. O acesso exige conta GitHub logada; o download é um ZIP.
- Site oficial do Sideloadly: https://sideloadly.io/

**Importante:** este microsite não hospeda a IPA. O arquivo do Actions expira depois de sete dias. Antes de convidar pessoas após 30/10, publique uma cópia autorizada da mesma IPA em um endereço duradouro (por exemplo, GitHub Release) e atualize os links em `instalar.html`. As páginas não recebem senhas nem credenciais; autenticação da Apple ocorre apenas dentro do Sideloadly.

A gravação selfie foi adicionada ao código da Build 66, mas não substitui teste físico em iPhone. Não prometer no convite mixagem digital da trilha musical com a câmera.
