# Painéis e densidade da interface

O olho no canto superior esquerdo controla as duas telas, inclusive sem faixa carregada.
Toque alterna Zen; mantenha pressionado para abrir o menu. O menu também oferece uma
entrada explícita para Zen, interruptores dos painéis da tela atual e **Mostrar tudo**.
O controle nunca é ocultado. Um toque no fundo sai do Zen.

## Preferências e atalhos

- **Descobrir:** todos os painéis visíveis (padrão de instalação nova).
- **Equilibrado:** player, busca e fila na tela principal; letras e temas disponíveis no karaokê.
- **Só ouvir:** player e controles de áudio; letras e temas disponíveis no karaokê.

Os atalhos são globais e apenas gravam `ui.hiddenPanels`; não existe preferência extra
de densidade. O modo limpo das letras continua controlando sua barra rápida de temas.
Cabeçalho/importação e mensagens de download continuam disponíveis fora do Zen.

Visibilidade e expansão são independentes. Ocultar/reexibir mantém a expansão anterior.
`PanelStore` é o único dono da visibilidade. As chaves `showDiscover`, `showQueue`,
`showPlaybackDetails`, `showPresets`, `showAudioControls` e `showExport` continuam sendo
preferências de expansão, com os nomes persistidos originais.

Zen é uma máscara temporária compartilhada entre as telas: oculta todos os painéis,
inclusive player, sem alterar suas preferências. Reiniciar o app sai do Zen. Alterar
um interruptor, escolher uma densidade ou mostrar tudo também sai do Zen.

## Busca

A Omnibox tem visibilidade própria. Texto com dois ou mais caracteres ou uma busca
submetida revela e expande Descobrir temporariamente. Isso nunca grava visibilidade
nem expansão. Limpar a busca devolve a apresentação às preferências salvas. Um toque
explícito no acordeão salva a expansão e prevalece até a próxima edição da consulta.
Links continuam indo diretamente para o fluxo de download.

Ocultar **Busca** pelo menu ou por um atalho limpa texto/resultados/última consulta e
fecha o teclado; reexibir não restaura texto antigo. Histórico e cache do motor não
são apagados. A consulta salva só é restaurada na primeira apresentação se Busca
estiver habilitada.

`normalExtras()` permanece na mesma posição estrutural ao entrar em Zen ou karaokê:
altura zero, recorte, opacidade zero, sem interação nem acessibilidade. Isso preserva
`SearchView`, sua sessão e seu motor; entrar nesses modos apenas fecha o teclado.
Downloads, fila e reprodução continuam nos seus donos originais.

## Migração

Na inicialização, escolhas falsas das seis chaves legadas `visible…` são unidas aos
IDs já existentes em `ui.hiddenPanels`. O conjunto é salvo antes de remover as chaves
antigas; uma segunda inicialização não reaplica escolhas antigas. IDs desconhecidos
são descartados. `isZenMode` é removida porque Zen não é mais persistido.

## Validação

`PanelSystemTests` cobre migração/idempotência, independência da expansão, histórico,
Zen, atalhos, recuperação com Mostrar tudo e resolução temporária de Descobrir.
`project.yml` inclui a pasta inteira de testes; o CI gera o projeto com XcodeGen e
executa estes testes junto aos testes existentes no simulador antes de gerar o IPA.

Verificação no aparelho:

1. Recolher e ocultar Descobrir; pesquisar; limpar: permanece oculto. Reexibir: recolhido.
2. Recolher resultados manualmente durante busca; editar: reabre sem gravar outra preferência.
3. Ocultar Busca com texto digitado; reexibir: vazio. Histórico de reprodução preservado.
4. Alternar Zen/karaokê com pesquisa em andamento: sessão preservada e teclado fechado.
5. Aplicar Só ouvir durante reprodução/prefetch; áudio e fila continuam; Mostrar tudo restaura painéis.
6. Conferir VoiceOver, Reduzir Movimento e acessibilidade do olho com todos os painéis ocultos.

Compilação iOS, testes XCTest e desempenho de transições dependem de Xcode/aparelho;
verificações estáticas em Linux não substituem esses passos.
