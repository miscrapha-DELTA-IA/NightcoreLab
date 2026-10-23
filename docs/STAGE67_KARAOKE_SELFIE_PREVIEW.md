# GNARLY Stage 67 — Karaokê + câmera + prévia antes de salvar

## Experiência

- O botão de gravação da Stage 66 permanece no canto superior do player/karaokê.
- Ao abrir a câmera, aparece uma faixa compacta de letra sincronizada **sobre a câmera frontal**. O rosto continua visível e os controles ficam abaixo da letra.
- A gravação capta câmera frontal + voz do microfone, com limite de 90 segundos. As mudanças de estrofe são amostradas do PlaybackClock do GNARLY (com offset), não por temporizador musical independente.
- Após Parar, o app compõe a letra sobre os quadros do vídeo localmente usando AVVideoCompositionCoreAnimationTool, sem segundo AVAudioEngine. Durante a exportação, a interface informa o processamento.
- Depois a **prévia do vídeo gravado** é reproduzível no app. Só após isso aparecem **Salvar em Fotos**, **Compartilhar** e **Descartar e refazer**.
- Se não houver letra sincronizada, o vídeo fica só com câmera e voz. Se a composição de letras falhar, mostra aviso e oferece a prévia do arquivo original em vez de bloquear o usuário.
- A trilha da música **não é mixada digitalmente** ao arquivo, e a reprodução pode continuar por baixo. O som ambiente pode ser captado pelo microfone. Não prometa paridade da mixagem da música.
- O arquivo temporário é removido ao descartar; salvar em Fotos exige ação explícita.
- Não modificar EnginePlaybackClock, motor de áudio, Stems nem o restante do player.

## Testes físicos necessários antes de compartilhar

1. Abrir o karaokê da música com letras carregadas; tocar no círculo vermelho. Verificar câmera frontal e letra sobreposta legível.
2. Cantar por 8 a 15 s, parar e aguardar a prévia. **Reproduzir** a prévia verificando voz + letras desenhadas no vídeo final, mesmo sem a UI de gravação.
3. Tocar em **Descartar e refazer**. Confirmar que o vídeo antigo não foi salvo em Fotos.
4. Fazer nova gravação e tocar em **Salvar em Fotos**; abrir a galeria e verificar imagem, áudio e sobreposição.
5. Gravar durante mudança de estrofe, pausa e seek. O texto deve seguir a música de fato.
6. Testar música sem letras, câmera negada, microfone negado, app em background, fones Bluetooth e alto-falante.
7. Conferir reprodução normal, karaokê, Share e Stems sem regressões.

## Distribuição

- Branch: stage-67-karaoke-selfie-preview-final, baseada na última IPA aprovada v66.
- Build v67, CFBundleVersion 67.
- **Não trocar o download v66 do convite pela v67 até a nova IPA passar na CI e a prévia ser testada em iPhone real.**
