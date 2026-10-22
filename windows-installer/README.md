# Gnarly Installer — Windows x64 · beta 0.1

Instalador independente derivado do [iloader](https://github.com/nab138/iloader), sem afiliação ao autor original. Código MIT; avisos originais em LICENSE e LICENSE-BRANDING.

## Usar

1. Execute `Gnarly-Installer-Windows-x64-Setup.exe` no Windows 10/11 x64. Esta beta não tem certificado comercial de assinatura do Windows.
2. Instale **Dispositivos Apple** da Microsoft Store, caso o Windows ainda não reconheça iPhones.
3. Abra **Gnarly Installer**, conecte o iPhone por USB, desbloqueie e confirme **Confiar neste computador**.
4. Entre na **conta Apple do dono desse iPhone**, com a senha normal e o código solicitado. Não envie credenciais ao autor do Gnarly. Salvar a senha é opcional; o armazenamento usa o cofre do Windows, separado do iloader oficial.
5. Selecione o iPhone, confira a conta exibida, marque a confirmação e clique em **Instalar / renovar Gnarly**. O programa baixa a build 57 qualificada, verifica tamanho e SHA-256 e reutiliza o download íntegro.
6. No iPhone, quando solicitado: **Ajustes › Geral › VPN e Gerenciamento de Dispositivo** para confiar no perfil; **Ajustes › Privacidade e Segurança › Modo Desenvolvedor** para ativar o modo e reiniciar.

Instala o Gnarly diretamente no iOS. Não exige LiveContainer nem JIT. Requer iOS 17+; o modelo de stems local exige iOS 18+.

## Renovar e instalar nos amigos

A conta gratuita exige renovação em até **7 dias**. Reconecte o iPhone, entre na mesma conta, selecione o aparelho e use o mesmo botão. Não desinstale o Gnarly para atualizar. Use a mesma conta para manter a identidade de assinatura. Não há garantia de migração dos dados de uma instalação anterior feita com outro identificador, outra conta ou dentro do LiveContainer.

Use uma conta própria por amigo; uma única conta gratuita não atende livremente 5–10 iPhones. A detecção USB é automática, mas o aparelho e a conta precisam ser confirmados antes de cada instalação. Esta beta não instala silenciosamente ao conectar nem agenda renovação sem o aparelho disponível.

## Privacidade e limites

O login é executado localmente pelo mecanismo aberto do iloader/isideload. Ele se comunica com a Apple e usa um serviço externo de anisette (`mac-ani.jkcoxson.com`). Não existe servidor do Gnarly recebendo sua senha. Para não manter o login no computador compartilhado, deixe **Salvar credenciais** desmarcado e saia da conta ao terminar. Não compartilhe logs de autenticação publicamente.

A build é validada no Windows em CI: interface, compilação nativa e integridade do IPA. Instalação real e renovação ainda precisam ser verificadas com um iPhone conectado. O ambiente de desenvolvimento não tem acesso ao seu USB.

## Compilar

Windows x64 com Rust stable, Bun 1.4.3, ferramentas C++ do Visual Studio, Perl e Make:

```
bun install --frozen-lockfile
bun run build
bun tauri icon public/gnarly.svg
cargo test --release --locked --manifest-path src-tauri/Cargo.toml --lib gnarly::tests
bun tauri build --bundles nsis -- --locked
```

Origem iOS: `gnarly-build57-livecontainer-beta`. IPA: SHA-256 `a12387c7bd3d361c8dd3eeb78ad090559e0e0c24111f15ef0c03e3a8f6440dc9`, 112107110 bytes. Não acompanha automaticamente a branch main nem muda para builds não qualificadas.
