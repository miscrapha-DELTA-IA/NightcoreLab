# Stage 73 — Visual First: escolher, misturar, aplicar e voltar

## Problema real observado no iPhone

O GNARLY original e Cyber Night seguem mais fluidos que os visuais recém-criados. Strata e Organism não agradaram. A mistura de tema/experiência/ritmo não tem uma ação inequívoca de **voltar ao tema puro**. Trocar o tema para Xerox enquanto Vector Drift continuava ativo deixava a geometria do túnel e mudava só a paleta, causando falsa expectativa.

## Uma decisão de produto

O usuário escolhe primeiro **qual visual quer na tela**, depois opcionalmente uma mistura. O ritmo musical é uma camada independente de intensidade, não outra forma de escolher o visual.

### Escolha simples
- Botão **Visual** no topo do player, e o raio abre o mesmo seletor. Na barra de karaokê há acesso direto a **Escolher visual**.
- A aba **Visuais** começa pelos favoritos confirmados no dispositivo: **GNARLY original** e **Cyber Night**.
- Escolher um **tema** define `creativePresetID = "original"`, eliminando qualquer experiência escondida que o sobrepusesse.
- Escolher uma **experiência** exibe sua geometria; quando o tema atual é GNARLY procedural, o modo sai de cena e o app seleciona Cyber Night como paleta base para que a experiência seja visível.
- Escolher um **modo GNARLY** usa o modo autônomo completo e limpa a experiência anterior. Strata e Organism continuam acessíveis, marcados como experimentais; não são oferecidos como favoritos.
- As cores e receitas continuam persistidas usando os IDs existentes. Nenhuma migração nem novo motor de áudio.

### Misturar
- A aba **Misturar** permite compor **Experiência + Tema**.
- O resumo no topo diz claramente: `Vector Drift 2000 + Xerox Serpentine`, por exemplo.
- **Limpar experiência** retorna à geometria do tema sem mudar as cores. O selector oferece também **Nenhuma · tema puro**.
- O botão de tema no karaokê passa a selecionar **tema puro** por padrão; o menu de contexto do raio também limpa a experiência anterior, em vez de alternar silenciosamente apenas a cor.

### Experimentar sem ficar preso
- O seletor abre em **sheet com detents medium/large**, deixando o player parcialmente visível. As escolhas alteram a aparência imediatamente como **prévia local**.
- **Aplicar visual** confirma. **Cancelar** ou fechamento sem confirmação restaura tema, experiência, reação e fundo originais, incluindo uso de foto pessoal.
- Durante a prévia do material, a foto pessoal é apenas desativada; não é apagada.
- O seletor usa as bindings atuais e fica num `View` próprio para não replicar o canvas nem criar fonte paralela de estado.

## Reatividade com fluidez real

### Causa e mitigação

O monitor PCM publica capturas no máximo ~30 Hz; a interface pode renderizar a 60 Hz. Usar essas capturas diretamente como parâmetro geométrico e alternar abruptamente as amplitudes entre leituras produz aparência de pequenos passos/solavancos, mesmo quando o relógio do shader é contínuo.

`CreativeVisualEnvelope` é um suavizador `@MainActor` atualizado no mesmo `TimelineView` que já agenda os frames:
- **Contínuo** (`.off`): o tempo de animação continua, sem geometria reagindo ao áudio.
- **Suave** (`.subtle`): amplitude baixa e release mais lento baseado em energia sustentada. **Não reduz FPS** nem redefine o relógio.
- **Intenso** (`.responsive`): ataque em torno de 110 ms e queda em torno de 230 ms; transientes mais presentes, sem step 30 Hz direto.
- O suavizador alimenta somente `CreativeUniverse`. O GNARLY tradicional e o Marble antigo permanecem no pipeline de resposta já aprovado.
- `CreativeUniverse` recebe sinais sem desvio via `max(raw,smoothed)`, o que invalidaria a suavização.
- Tectonic Mesh (9) e GNARLY Strata (13) têm custo elevadíssimo de amostras de ruído/placas por pixel; em frames ao vivo, seus detalhes secundários usam `quality <= 0.60` para evitar a segunda passagem de 9 células e a derivada adicional de heightfield. Story export continua a qualidade total. **Não há medição física de FPS**; isso é proteção preventiva.

## Critérios físicos antes de mudar convite

1. Começar em **Vector Drift + Xerox**, abrir Visual e selecionar **Xerox Serpentine**. A geometria deve deixar de ser túnel; o resumo deve dizer tema independente.
2. Clicar **Cancelar** e verificar retorno exato de Vector + Xerox; repetir escolhendo **Aplicar** e reiniciar app para verificar o estado.
3. Escolher **GNARLY original** e **Cyber Night** em toques independentes. Ambos devem exibir animação contínua reconhecível, sem preservar visual anterior.
4. Abrir **Misturar**, escolher Vector Drift, selecionar Xerox para paleta e usar **Limpar experiência**. O fundo deve voltar ao padrão do Xerox.
5. Começar num modo GNARLY, escolher experiência: a experiência deve aparecer de verdade, não ficar escondida por prioridade de modo GNARLY.
6. Comparar Contínuo/Suave/Intenso com música de graves fortes. Sobretudo Suave: não deve congelar nem acelerar o relógio.
7. Verificar Story MP4, cadeia de reprodução, buscas/downloads, karaokê, voz e persistência, incluindo quando a foto de fundo está ativa.
8. Comparar com Build 72 no iPhone real e usar Instruments para avaliar GPU/thermal, incluindo modo Eco e Stems.

## Scope

A base é `stage-72-argon-material-depth-final`, que passou nos workflows. Build **v73 / CFBundleVersion 73**. Não mexer em Stems, backend, single AVAudioEngine, clock central, música, IPA do convite nem injetar novos assets. Modos de Strata e Organism permanecem experimentais e precisam de uma reimaginação futura, não de um aumento artificial de FPS por conta própria.
