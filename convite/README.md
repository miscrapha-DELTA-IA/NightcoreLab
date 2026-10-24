# GNARLY — convite para iPhone (build 72, base estável)

O convite é um microsite estático de duas páginas. As builds 73 e 74 são experimentais e **não** fazem parte do canal do convite.

## Publicação no Netlify
- Branch: `feat/gnarly-invite-sideload-guide`
- Base directory: vazio
- Publish directory: `convite`
- Build command: nenhum

Se o Netlify estiver conectado a essa branch, o commit atualiza o site automaticamente. Se o site estiver publicado manualmente ou apontando para outra branch, é necessário implantar a pasta `convite/` desta branch.

## Build do convite
- Base original: `stage-72-argon-material-depth-final` (commit `ae0031681e4750b6882cf9992913462a499f9fbb`), cuja CI havia sido aprovada.
- Revisão exclusiva do botão de apoio: `stage-72-apoia-se-stable-final` (commit `3f6c0d01300bce872b41ec22fa8cdc344f7f53be`).
- Única mudança no aplicativo: `https://ko-fi.com/SEU_USUARIO` → `https://apoia.se/gnarlyapp`.
- Versão exibida e CFBundleVersion: **v72**, sem incorporar código das builds 73 ou 74.
- Execução de referência da nova IPA: https://github.com/miscrapha-DELTA-IA/NightcoreLab/actions/runs/40132796702
- Quando a execução finalizar com sucesso, selecione `Artifacts → NightcoreLab-App`, baixe o ZIP e extraia `NightcoreLab_Unsigned.ipa`.

**O link leva à execução até que haja um artefato confirmado**. Não declare a IPA revisada como aprovada antes da CI e do teste físico. Artefatos GitHub Actions expiram; a página não hospeda IPA própria.

O site ensina instalação via https://sideloadly.io/ (sem jailbreak). Credenciais Apple devem ser inseridas exclusivamente no Sideloadly.
