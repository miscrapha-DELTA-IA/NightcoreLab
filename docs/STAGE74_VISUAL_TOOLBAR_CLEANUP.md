# Stage 74 — Barra visual sem sobreposição

Base: `stage-73-visual-first-fluidity-final` (`c445cc62f1aeb09763764939db8cfbd74c81baf1`).

## Feedback da build 73 (iPhone)
- O novo fluxo de escolha de visuais ficou melhor.
- O botão «Criar» sobrepõe «Compartilhar».
- «Criar» é redundante como ação primária após a nova interface «Visual».

## Correção
- Remover a overlay central Visual/Criar e seus hit targets: sem controle invisível sobre Compartilhar.
- O botão circular de temas na barra superior esquerda passa a mostrar ícone + rótulo «Visual» (44×44 pt), abrindo o mesmo seletor Stage 73. O menu por toque prolongado conserva a troca direta de temas.
- Manter Compartilhar, gravar, microfone, visibilidade e menu de fundo no lugar, agora sem camada central sobreposta.
- Não excluir os recursos exclusivos do Studio: Performance Pads, overdub, loops, Vocal FX e ajustes finos continuam disponíveis em «Visual → Ferramentas avançadas». A sheet anterior se encerra antes de abrir Studio.
- Sem alteração de motor de áudio, streaming, stems, geometria, FPS, prévia de temas, karaoke ou export.

## Aceitação no dispositivo
- iPhone compacto e grande: toques em Visual, Compartilhar, gravação, microfone e menu de fundo sem colisão, inclusive Dynamic Type.
- Testar Aplicar/Cancelar no seletor; cancelar restaura a configuração anterior.
- Abrir Ferramentas avançadas e conferir pads, loops e sliders, sem duas sheets simultâneas.
- Testar compartilhamento de imagem e vídeo Story; botão «Criar» ausente.
- Build v74, CFBundleVersion 74, marketing 1.0.74 e CI `*-final`.
- Não mesclar em main nem alterar distribuição estável sem teste físico.
