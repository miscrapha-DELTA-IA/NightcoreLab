# Stage 68 — Auditoria de linguagem visual GNARLY (feedback físico)

Fonte de pesquisa: `GNARLY_Creative_Universe_Master_Specification.md` (auditoria de 26 referências). Feedback priorizado da revisão manual da Build 65.

## Contrato de produto: quatro camadas independentes

1. **Tema:** paleta, luz, textura, materialidade. Os seis novos temas (Xerox, Prism, Subatomic, Jacquard, Isometric, Lenticular) são temas e não modos GNARLY.
2. **Experiência:** comportamento e composição espacial do tema (câmera de túnel, cromatografia de impressão, cristais, correntes fluidas, gravura, fendas).
3. **Ritmo visual:** Desligado/Fluido/Reativo controla a força de acoplamento ao áudio, NÃO escolhe um novo tema. Se Desligado, não prometer feedback de graves/hats/médios.
4. **Modo GNARLY:** direção criativa procedimental autônoma; antigo Gnarly e as versões Strata/Compiler/Organism são agrupados separadamente. Não remover IDs dos formatos de projetos salvos.

## Decisões por look (preservar os aprovados)

| Look | Diagnóstico do usuário | Direção implementada nesta revisão |
| --- | --- | --- |
| Nocturnal Lithograph (12) | Sem personalidade ou interação | Gravura ativa com anel de cobre, horizonte, céu riscado e partículas nos agudos |
| Liquid Monochrome (11) | Visual interessante, poucas diferenças entre temas | Células e convecção dependentes de cores, graves e médios; maior influência dos temas |
| Vector Drift (10) | Túnel não convincente, movimento duro | Profundidade radial logarítmica, variação de foco, múltiplos anéis contínuos e aceleração por graves |
| Tectonic Mesh (9) | Visual esquisito, reatividade salva | Reimaginar como cânion de fenda pulsante com contornos e filamentos sob tração |
| Caustic Dissection (8) | Boa; mas idêntica a Prism Carmine | Preservar sensação cáustica, trocar geometria por fluidos fraturados distintos da grade de losangos Prism |
| Subcultural Archive (7) | Estético porém inerte | Desgaste de impressão, halftone, xerox slit-scan e stencil pulsante |
| Xerox Serpentine (1) | Desejo de capa do álbum se formando | Preservado nesta etapa; **não** simular falsa composição da capa com cor média. Mosaic reveal real exige amostragem da imagem no Metal e mesma composição na exportação |
| Prism Carmine (2) | Idêntico ao Caustic | Retém losangos cristalinos; Caustic agora tem estrutura própria |
| Subatomic Bubble (3) | Aprovado | Preservado |
| Isometric Chasm (5) | Aprovado | Preservado |
| GNARLY Strata (13) | Insatisfatório | Redesenho para abismo com curvas de erosão, falhas e camadas radiais; não simula memória irreversível |
| Kinematic Compiler (14) | Aprovado | Preservado |
| Chromatic Organism (15) | Aprovado | Preservado |

## Alterações de engenharia

- Mantemos IDs estáveis, `AppTheme.allCases` e seleção persistida; nenhum migration break.
- Para experiências 7–12, o tema agora altera mais fortemente três canais de material e sua assinatura cromática influencia parâmetros geométricos dentro do Metal. Mudar tema não é apenas trocar tint.
- O mesmo avaliador `CreativeUniverse.metal` ainda serve às superfícies ao vivo e às exportações Story. Nenhum segundo motor de áudio e nenhuma nova textura dinâmica de rede.
- O menu do raio organiza temas clássicos, materiais e modos GNARLY; o botão rápido circula apenas temas.
- O carrossel compacto do karaokê não mistura mais os modos GNARLY com temas; o ícone de brilho acessa os quatro modos.
- O Creator separa experiências clássicas e GNARLY, explica as quatro camadas e tem um botão explícito para ativar reação quando a preferência atual está em Desligado.
- Testes adicionados para partição dos grupos e respostas de paleta, sem alterar compatibilidade do catálogo.

## Não afirmar sem validação

- Não há amostragem pixel-a-pixel da capa no Xerox ou simulação fotoquímica permanente.
- Os shaders continuam analíticos, não possuem estado irreversível, física 3D nem feedback de giroscópio real.
- Performance, qualidade visual e paridade GPU ao vivo/Story requerem screenshots e comparações num iPhone de verdade.
- Esta é uma iteração experimental de estética; não substituir a IPA do convite por uma build não aprovada.
