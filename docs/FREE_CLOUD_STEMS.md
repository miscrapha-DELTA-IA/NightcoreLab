# GPU gratuita para stems — preparação do beta

## Estado e bloqueio de ativação (21/10/2026)

Render: workspace confirmado pelo usuário **My Workspace**, serviço NightcoreLab
`srv-db3ko7flk1mc73buohk0`, plano **free**, sem forma de pagamento segundo o usuário.
URL: https://nightcorelab.onrender.com.

Hugging Face: `Raphael-DeltaIA`, conta pessoal gratuita (`isPro: false`), criada em
21/10/2026 às 14:14:41 UTC segundo a API pública. Não há Spaces nessa conta.
A [documentação ZeroGPU](https://huggingface.co/docs/hub/spaces-zerogpu) exige
e-mail verificado, conta em boas condições e mais de 30 dias para hospedar até
dois Spaces gratuitos. A conta alcança 30 dias em **20/11/2026 às 14:14:41 UTC**;
a plataforma decide a elegibilidade efetiva. Não há acesso autenticado ao HF
neste ambiente e nenhum Space/GPU foi provisionado.

Não confundir código implementado/testado com GPU publicada ou desempenho medido.
A inferência na GPU real e a qualidade/performance no iPhone XR ainda precisam
de um teste depois da ativação. Os 35 minutos relatados eram uma estimativa na
tela, não um tempo de processamento medido.

## Fluxo implementado

1. Usuário escolhe explicitamente **Separar com GPU grátis** e aceita enviar áudio.
2. iPhone calcula SHA-256 em blocos e pede `/v1/stems/cloud/ticket` ao Render,
   usando código de acesso do beta salvo no Keychain. Nenhum token HF no app.
3. Render valida acesso, tamanho/duração e limites; assina autorização curta
   vinculada ao hash, tamanho, duração, modelo e origem HTTPS do Space.
4. iPhone envia o arquivo diretamente a `/gradio_api/upload` do Space, chama
   `separate` e acompanha SSE. Render não recebe áudio nem os WAVs.
5. Space valida assinatura, expiração, uso único, arquivo e duração; executa
   HTDemucs real em ZeroGPU, sem ensembles de shifts, e devolve quatro WAVs
   float32 estéreo/44,1 kHz e hashes. `other` é outros instrumentos, não a soma
   de tudo sem voz. O mixer mantém voz/outros/bateria/baixo independentes.
6. iPhone baixa os quatro arquivos sequencialmente para disco, confere hashes,
   formato, duração e número de amostras; publica o cache só quando completo.
   Os stems ficam disponíveis offline. Não carrega a música inteira na RAM.

O caminho local da build55 continua explícito. Uma falha na nuvem não compra
créditos, troca provedor ou inicia automaticamente processamento pesado no XR.
Cancelamento no iPhone pode não interromper uma chamada GPU já iniciada.

## Limites e proteção contra cobrança

- Render não instala torch, demucs ou gradio; apenas FastAPI/stdlib no novo router.
- Nenhuma instância paga, banco, disco, worker ou GPU é criada no Render.
- Desativado por padrão; só opera com `STEMS_CLOUD_ENABLED=1`, chave válida,
  origem HF válida, código de beta e `STEMS_CLOUD_FREE_ONLY=1`.
- Até **2 autorizações por 24 horas** no beta, com intervalo de 15 minutos.
  `STEMS_CLOUD_DAILY_JOBS=1` reduz para uma. Valores acima de 2 não aumentam o teto.
- No Space: fila máxima 2, concorrência 1, autorização de uso único, até 2
  admissões/24h, solicitação de até 120 segundos de GPU por chamada.
- Arquivo de até 35 MiB e música estritamente inferior a 10 minutos.
- O worker recusa iniciar fora de `SPACES_ZERO_GPU=true`; nenhum fallback CPU
  ou GPU dedicada. Nenhuma chave HF é enviada no protocolo: chamadas anônimas,
  sujeitas à cota anônima do HF (atualmente **2 minutos/dia**, contra 5 em conta
  gratuita autenticada). Duas autorizações não garantem duas músicas concluídas;
  a cota da plataforma pode acabar antes. Não há multiplicação/rotação de contas.
- **Os contadores locais não são uma garantia financeira persistente**: o disco
  efêmero do Render é perdido no restart, deploy ou spin-down. O contador do
  Space também pode reiniciar. A barreira financeira é usar exclusivamente
  chamadas anônimas ao ZeroGPU gratuito, sem credenciais/créditos pagos.
- No Render, o plano free pode cobrar excedente de tráfego se houver cartão.
  [Sem forma de pagamento](https://render.com/docs/free#bandwidth-and-build-pipeline),
  o serviço/build é bloqueado ao exceder a franquia em vez de cobrar. Manter essa
  condição; o limite de gastos de build cobre apenas build, não tráfego.

## Ativação quando a conta for elegível

1. Criar `Raphael-DeltaIA/gnarly-free-stems` como Space **Gradio / ZeroGPU**.
   Não selecionar GPU dedicada paga nem contratar PRO para contornar a espera.
2. Publicar **apenas** os arquivos de `backend/zerogpu_space` na raiz do Space.
   A versão do SDK está no README; dependências em requirements/packages.txt.
   Não incluir cache, `.env`, tokens, outros arquivos do backend ou `__pycache__`.
   Por exemplo, após login seguro pelo CLI oficial:

   ```sh
   hf upload Raphael-DeltaIA/gnarly-free-stems backend/zerogpu_space . --repo-type space --exclude '**/__pycache__/**' --exclude '*.pyc'
   ```

3. Configurar uma chave aleatória de pelo menos 32 caracteres como **secret**
   `STEMS_CLOUD_SIGNING_KEY` no Render e no Space, com o mesmo valor. Não enviar
   em chat, repositório ou logs. Criar `STEMS_CLOUD_BETA_CODE` aleatório com pelo
   menos 16 caracteres **somente no Render** e compartilhar com os testadores.
4. Configurar `STEMS_CLOUD_SPACE_URL` em ambos com a origem exata exibida pelo HF
   (`https://...hf.space`, sem caminho). A origem esperada para esse nome é
   `https://raphael-deltaia-gnarly-free-stems.hf.space`; confirmar na plataforma.
5. Manter `STEMS_CLOUD_FREE_ONLY=1`, `STEMS_CLOUD_DAILY_JOBS=2`; ativar
   `STEMS_CLOUD_ENABLED=1` no Render somente depois que o Space estiver executando
   em ZeroGPU e os segredos forem configurados. Fazer deploy padrão para aplicar.
6. Conferir GET `/v1/stems/cloud`: `enabled: true`, `free_only: true`. Fazer uma
   separação completa de áudio autorizado; medir upload/fila/inferência/download,
   conferir qualidade dos quatro stems e cache offline no XR. Não prometer tempo
   total ou capacidade para 5–10 pessoas antes desse teste e de avaliar a cota.

O Space é público: alguém que tenha a URL de um resultado pode acessá-lo até a
limpeza temporária (aproximadamente uma hora). O app avisa antes do envio.

## Alternativa avaliada

[Modal Starter](https://modal.com/pricing) inclui atualmente US$30/mês de compute.
O [spend limit do workspace](https://modal.com/docs/guide/budgets) é distinto do
orçamento de uso e pode bloquear despesas além dos créditos. Porém a
[documentação de billing](https://modal.com/docs/guide/billing) exige uma forma
de pagamento, e não existe conta/acesso Modal nesta sessão. Não foi provisionado
nem incluído como fallback automático. Um limite configurado só em nosso código
não substitui a proteção financeira configurada no próprio provedor.

Colab/Kaggle interativos não foram escolhidos como backend contínuo do aplicativo.
