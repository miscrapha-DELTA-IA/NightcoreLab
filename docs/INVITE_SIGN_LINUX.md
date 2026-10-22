# Gnarly: IPA assinado na nuvem (Linux zsign / Apple Ad Hoc)

Este PR cria um workflow **manual, opt-in** de assinatura de uma IPA unsigned já compilada pelo GitHub Actions. Não altera o player, os stems, os temas, a UI, nem o Render. Não necessita de Mac para *assinar*, embora compilar um novo app iOS ainda exija uma ferramenta de build compatível com Xcode.

## 1. Pré-requisitos de distribuição Apple

- Inscrição Apple Developer ativa, App ID correspondente a **com.nightcorelab.app**.
- Certificado de distribuição Apple e respectiva chave privada exportados em **.p12**, com senha.
- Perfil **Ad Hoc** \`.mobileprovision\` selecionando o mesmo certificado e os **UDIDs já registrados** dos aparelhos autorizados.
- Certificado e perfil com validade superior a sete dias.
- Um link para IPA não remove a restrição dos aparelhos registrados. \`zsign -a\` (assinatura ad hoc autoassinada) não é equivalente a uma distribuição Apple Ad Hoc instalável em iPhone sem jailbreak.

Documentação Apple: https://developer.apple.com/help/account/provisioning-profiles/create-an-ad-hoc-provisioning-profile/

## 2. Secrets no GitHub

Configure o ambiente \`invite-signing\` em **Settings → Environments**, preferencialmente com aprovação humana. Nas Secrets and variables → Actions, crie:

| Nome | Conteúdo |
|---|---|
| \`GNARLY_SIGN_P12_BASE64\` | Base64 do arquivo binário \`.p12\` |
| \`GNARLY_SIGN_P12_PASSWORD\` | Senha do \`.p12\` |
| \`GNARLY_ADHOC_PROFILE_BASE64\` | Base64 do arquivo binário \`.mobileprovision\` |

No Windows PowerShell, para copiar o conteúdo base64 **somente para o campo Secret do GitHub**:

\`\`\`powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes('C:\seguro\AppleDistribution.p12'))
[Convert]::ToBase64String([IO.File]::ReadAllBytes('C:\seguro\GnarlyAdHoc.mobileprovision'))
\`\`\`

Nunca suba esses arquivos ao repositório, nem compartilhe o conteúdo base64 ou a senha no chat.

## 3. Executar

Após revisar e fazer merge somente deste workflow no branch padrão:

1. Abra um run de **Build Unsigned IPA (Free Route)** que terminou com SUCCESS e cujo artefato \`NightcoreLab-App\` ainda esteja disponível.
2. Copie o Run ID numérico (o da URL do GitHub Actions).
3. Em Actions → **Gnarly Invite IPA — Linux zsign (manual)** → Run workflow, informe \`unsigned_run_id\`.
4. Para a primeira execução, deixe **publish_to_r2=false**. O workflow valida o run, obtém \`NightcoreLab_Unsigned.ipa\`, injeta metadados de convite, verifica certificado/perfil, compila uma revisão fixa do zsign, assina e produz o artefato \`Gnarly-AdHoc-Signed-Linux-<run-id>\`.
5. Faça um teste físico em um iPhone cadastrado no perfil antes de publicar ou convidar pessoas.

## 4. R2 público + manifesto OTA (opcional)

Configure estas **Variables**: \`GNARLY_R2_INVITE_BUCKET\` (bucket), \`GNARLY_R2_PUBLIC_BASE_URL\` (HTTPS público, sem barra final).

Configure estas **Secrets** com escopo mínimo para esse bucket:
- \`GNARLY_R2_ACCOUNT_ID\`
- \`GNARLY_R2_ACCESS_KEY_ID\`
- \`GNARLY_R2_SECRET_ACCESS_KEY\`

Somente então marque **publish_to_r2=true** ao executar o workflow manual. Publica \`invites/run-<run-id>/Gnarly-Signed.ipa\` e \`manifest.plist\` no R2. O manifesto usa o **Bundle ID/CFBundleVersion reais extraídos da IPA assinada**. O link \`itms-services://\` aparece no resumo do run.

**Atenção:** num bucket público, qualquer pessoa com a URL pode baixar e redistribuir o pacote, embora apenas iPhones incluídos no perfil Ad Hoc possam instalá-lo. Para convites privados, use uma camada autenticada na distribuição, não o \`r2.dev\` público direto.

## 5. Os 7 dias NÃO estão implementados como bloqueio

O arquivo \`invite_pass.json\` contém \`issued_at\`, \`expires_at = issued_at + 604800\`, \`access_days=7\` e explicitamente **\`enforced_by_client=false\`**. É apenas metadado inserido antes da assinatura; o app atual NÃO lê/verifica esse arquivo para bloquear o funcionamento após sete dias. O iOS não implementa esse bloqueio automaticamente. Uma licença temporária confiável requer uma implementação isolada no runtime iOS e/ou backend, com validação criptográfica, política offline e testes. Isso é uma etapa futura separada.

## 6. UDID pelo Safari

**Não incluído**. A Apple oferece serviço de perfil OTA, mas não há extração silenciosa e automática de UDID: o usuário deve aceitar a instalação, e o backend precisa lidar com consentimento, segurança do \`.mobileconfig\`, mensagens assinadas e registro de dispositivo na Apple. Nunca exponha UDIDs em query strings de convites públicos.

Referências Apple: https://developer.apple.com/library/archive/documentation/NetworkingInternet/Conceptual/iPhoneOTAConfiguration/profile-service/profile-service.html

**Nenhuma credencial é necessária para revisar este PR.** A efetiva assinatura/distribuição depende de você cadastrar as Secrets/Variables e autorizar a execução manual.
