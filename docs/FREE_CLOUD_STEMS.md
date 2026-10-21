# Stems com GPU gratuita — beta Gnarly

## Opção disponível agora: Space comunitário ZeroGPU

O beta integra a API pública de [D-r-e/audio-separator](https://huggingface.co/spaces/D-r-e/audio-separator), usando **BS-Roformer MUSDB18HQ, quatro stems**: voz, bateria, baixo e outros instrumentos. Não exige hospedar um Space na conta recém-criada, login HF no iPhone, token HF, cartão ou créditos. Chamadas são anônimas e sujeitas à cota do Hugging Face. Não há fallback pago.

A revisão auditada é `bbfd93e5fcc5bccd7b09fe41259c0902b266308a`, SDK Gradio 6.25.0. O Render verifica revisão, estado RUNNING e hardware `zero-a10g` antes de autorizar. Falha ou atualização bloqueia pedidos; não muda de provedor/modelo automaticamente. O operador precisa reavaliar alterações. O cache de disponibilidade dura até cinco minutos, abaixo do intervalo mínimo entre admissões.

Teste real de API em 21/10/2026: áudio sintético próprio de **12 segundos**, sem gravações pessoais, produziu quatro WAVs em **20,43 segundos até a resposta** (upload/fila/processamento/preparação; sem o download dos WAVs). Os quatro arquivos baixados têm 529.200 amostras, estéreo/44,1 kHz, valores finitos e hashes distintos, 4.233.688 bytes cada. Isso valida execução/contrato, **não** qualidade em música real, desempenho no XR ou tempo para uma faixa de 4:53. Não extrapolar esse tempo linearmente. Uma faixa completa ainda precisa de teste de aceitação.

## Fluxo

1. No app, escolher **Separar com GPU grátis** e confirmar o envio. A opção comunitária não exige código; um servidor privado pode configurar um código de beta opcional, salvo no Keychain.
2. O iPhone calcula hash em blocos e pede admissão ao Render. O Render valida duração/tamanho, configuração gratuita, limites e revisão/hardware do Space. A credencial de uma conta HF nunca entra no app.
3. O iPhone envia áudio **diretamente** ao Space, chama `/gradio_api/call/separate` com `Core instruments — 4 tracks` e acompanha SSE. Render não transfere áudio/WAVs nem carrega modelo.
4. O app usa apenas os quatro arquivos nomeados, rejeitando origens diferentes, nomes repetidos/ausentes ou contrato inesperado. Não renderiza HTML nem usa o ZIP do serviço.
5. Os WAVs são baixados para disco sequencialmente; o app valida origem HTTPS, nome, tamanho máximo, formato, duração e número de amostras e registra hashes locais antes de publicar o cache. O serviço comunitário **não fornece atestado do hash da fonte nem checksums independentes**; não apresentar os hashes locais como prova fornecida pelo servidor. A referência de origem é a solicitação HTTPS e o contrato da revisão auditada.
6. O mixer preserva os quatro stems independentes e identifica **BS-Roformer**. Outros instrumentos não incluem bateria/baixo. Demucs/prévia local continuam disponíveis. Caches completos são reutilizados offline sem GPU ou nova admissão.

A opção de nuvem fica disponível mesmo quando já existem stems locais. Falha não inicia trabalho pesado no XR automaticamente. Cancelar ou trocar a faixa pode não interromper uma separação já iniciada no provedor, e não garante restituição de cota. Nenhum ganho real de desempenho no XR foi medido nesta sessão.

## Privacidade e rede

O Space é comunitário/público. O mantenedor controla disponibilidade e retenção; **não há garantia de exclusão em uma hora nem API de exclusão remota**. O app explica isso antes do envio; evitar gravações confidenciais. Quem tem uma URL de resultado pode acessá-lo enquanto disponível.

WAV float32 preserva o ganho compartilhado dos stems, sem compressão com perdas ou normalização independente. Quatro arquivos de 4:53 podem somar aproximadamente 414 MB. Preferir Wi-Fi. O teste curto não comprova velocidade de download de uma música inteira.

## Limites e cobrança

- Render mantém o serviço **free**, sem novos workers, GPU, banco ou disco pago. O usuário confirmou que o workspace **My Workspace** não tem forma de pagamento.
- A API usa apenas stdlib/FastAPI no Render; gradio/torch/demucs não são instalados ou executados no serviço. A consulta de saúde é uma leitura pequena da API pública HF.
- Até **2 admissões por 24h**, intervalo de 15 minutos, arquivo até 35 MiB e duração estritamente inferior a 10 minutos. `STEMS_CLOUD_DAILY_JOBS=1` reduz o limite; valores acima de 2 não o elevam. A cota do provedor pode acabar antes.
- **O contador é local/efêmero** e pode reiniciar em deploy, restart ou spin-down. Não é uma garantia financeira persistente. A proteção de cobrança é usar somente chamadas anônimas ao ZeroGPU e Render sem forma de pagamento, sem token/créditos/fallback pago.
- A [cota atual ZeroGPU](https://huggingface.co/docs/hub/spaces-zerogpu) é de 2 minutos/dia para visitantes anônimos. Filas, cota por identidade/IP e limite de 120 segundos de GPU por chamada podem impedir a separação de uma faixa inteira. Duas admissões não garantem duas músicas prontas. Não usar rotação de contas/IPs para contornar cotas.
- No [Render sem cartão](https://render.com/docs/free#bandwidth-and-build-pipeline), exceder a franquia bloqueia builds/suspende serviço, em vez de cobrar. Se uma forma de pagamento for adicionada, o plano free pode cobrar tráfego excedente; limite de build não limita tráfego. Não ativar recursos pagos.

Configuração do perfil comunitário no serviço existente:

```text
STEMS_CLOUD_ENABLED=1
STEMS_CLOUD_FREE_ONLY=1
STEMS_CLOUD_PROVIDER=community_bs_roformer
STEMS_CLOUD_SPACE_URL=https://d-r-e-audio-separator.hf.space
STEMS_CLOUD_DAILY_JOBS=2
```

`STEMS_CLOUD_BETA_CODE` pode permanecer ausente para o beta público ou receber um segredo de pelo menos 16 caracteres para restringir a admissão. Não enviar segredos em chat, commits ou logs. GET `/v1/stems/cloud` mostra configuração e `provider_available` sem consumir uma admissão/GPU. Para desligar novas autorizações, usar `STEMS_CLOUD_ENABLED=0` e aplicar a configuração no Render.

## Hospedagem própria futura

A conta pessoal gratuita `Raphael-DeltaIA` foi criada em 21/10/2026 às 14:14:41 UTC. A [regra atual](https://huggingface.co/docs/hub/spaces-zerogpu) exige e-mail verificado, boa situação e mais de 30 dias para hospedar até dois Spaces ZeroGPU gratuitos. A conta completa 30 dias em **20/11/2026 às 14:14:41 UTC**; a plataforma decide elegibilidade. Isso restringe hospedar nosso próprio Space; não o uso da API pública acima.

O template `backend/zerogpu_space` continua disponível como alternativa **manual**, com HTDemucs real e autorização assinada de uso único vinculada ao áudio. Para usá-lo:

1. Criar `Raphael-DeltaIA/gnarly-free-stems` em **Gradio/ZeroGPU** quando elegível e publicar apenas os cinco arquivos do template na raiz. Não selecionar GPU dedicada paga ou comprar PRO para contornar a espera.
2. Configurar um segredo aleatório de pelo menos 32 caracteres `STEMS_CLOUD_SIGNING_KEY` no Space e Render, e `STEMS_CLOUD_BETA_CODE` de pelo menos 16 caracteres no Render. Não incluir os valores em código/IPA/chat.
3. Configurar a origem HTTPS real em `STEMS_CLOUD_SPACE_URL` de ambos. Escolher `STEMS_CLOUD_PROVIDER=owned_htdemucs` no Render. Manter free_only=1, ativar só depois de o Space estar pronto e verificar a execução com uma música real.

O template próprio verifica a assinatura, hash/tamanho/duração e devolve hashes independentes dos WAVs. Recusa iniciar fora de ZeroGPU. Tem limpeza temporária aproximada de uma hora, uma política diferente da comunidade. Nenhum Space próprio foi criado nesta sessão e não há autenticação HF configurada aqui.

## Validação e distribuição

O perfil próprio inicial foi validado com 90 testes backend e 32 subtestes. O baseline iOS `63e604359a6fd2cea9cb7de6a8bb72208f415f2c` passou a suíte completa (run 39621144478), preservando a build55. A revisão comunitária acrescenta contratos públicos/State do Gradio, limites e bloqueio de mudança de revisão/hardware, além de testes Swift de mapeamento e origem dos arquivos e propagação de BS-Roformer ao mixer.

O workflow `Free GPU Stems Beta` reutiliza o modelo local completo já qualificado somente se todos os hashes de DSP/modelo permanecerem iguais ao baseline. Executa os testes específicos de contrato/cancelamento/mixer e compila um IPA completo sem assinatura, com todos os 26 modelos locais. A suíte ampla existente continua rodando. Ainda é necessário assinar o IPA por sideload e aceitar em XR/faixa real antes de ampliar de dois para 5–10 testadores.

Modal foi avaliado: créditos Starter e spend limit podem limitar custos, porém exige forma de pagamento. Não foi integrado. Nenhum provedor pago foi provisionado.
