# Compilar e instalar usando Windows e GitHub

Esta pasta contém apenas o app nativo, sem arquivos da extensão, certificados locais ou dados de pareamento. A [compilação 0.1.1 em macOS para iPhone já passou](https://github.com/mayc00n/live-audio-app/actions/runs/43056132828). Baixe **LiveShopCamera-iPhone** em **Artifacts** nessa execução e avance à etapa 3. Os artefatos expiram após três dias; se necessário, gere novamente pela etapa 2.

## 1. Colocar o projeto em um repositório privado

O projeto já está publicado no repositório público autorizado [mayc00n/live-audio-app](https://github.com/mayc00n/live-audio-app). Você não precisa reenviar os arquivos. Se replicar em outro repositório, envie o conteúdo desta pasta para a raiz: `LiveShopCamera.xcodeproj`, `LiveShopCamera`, `scripts` e `.github` devem ficar na raiz, sem uma pasta intermediária.

Se usar **Add file > Upload files** no navegador, atenção: o Windows pode ocultar a pasta `.github` e o site pode não recebê-la ao arrastar pastas. Confira que o arquivo `.github/workflows/ios-ipa.yml` apareceu. Se faltar, escolha **Add file > Create new file**, digite esse caminho completo no nome e cole o conteúdo do arquivo local correspondente. Depois confirme o envio.

Envie somente esta pasta. Não envie a pasta inteira do LiveShop Copilot, os certificados do servidor nem os arquivos temporários de testes.

## 2. Gerar o app

1. Abra a aba **Actions** no repositório.
2. Se o GitHub pedir, habilite os workflows desse repositório.
3. Escolha **Gerar app para iPhone > Run workflow > Run workflow**.
4. Aguarde a execução terminar. O primeiro envio e alterações nos arquivos do app também iniciam uma compilação; você pode repetir manualmente por esse menu.
5. Se ficar verde, abra a execução e baixe **LiveShopCamera-iPhone** em **Artifacts**.
6. Extraia o ZIP baixado. O arquivo de interesse é `LiveShopCamera-unsigned.ipa`.

Se falhar, abra a etapa vermelha e veja o erro; o artefato **Log-da-compilacao** também será disponibilizado quando houver log. Não existe app utilizável até uma compilação bem-sucedida.

Esse fluxo não pede senha Apple, certificado de assinatura ou assinatura paga de desenvolvedor. Compila um binário para iPhone sem assinatura; a assinatura será feita no seu Windows. O runner macOS padrão usa a cota do GitHub no repositório privado. Confira **Settings > Billing** da conta antes de executar. Não é necessário habilitar gastos pagos para esta preparação.

## 3. Assinar e instalar pelo Windows

Siga a [documentação oficial do AltStore Classic para Windows](https://faq.altstore.io/altstore-classic/how-to-install-altstore-windows) para instalar AltServer e AltStore. Ela detalha os componentes Apple, conexão USB, confiança no computador e Modo de Desenvolvedor do iPhone.

Depois abra o AltStore no iPhone, entre em **My Apps**, toque em **+** e selecione nosso IPA no app Arquivos. Para isso, transfira o IPA extraído ao iPhone, por exemplo pelo iCloud Drive. Mantenha AltServer aberto no Windows e siga as solicitações de assinatura com sua conta Apple.

A assinatura gratuita deve ser renovada a cada sete dias. O AltStore também ocupa uma das três vagas gratuitas de aplicativos. Não é necessário jailbreak ou TestFlight para esse caminho. A instalação concreta ainda precisa ser verificada com sua conta e versão do iOS.

## 4. Conectar à extensão

Com o app instalado, siga a seção **Vincular à extensão existente** do `README.md`. Use o QR HTTPS local do LiveShop Copilot, desconecte o VDO no painel e confira se o app mostra a lapela como entrada ativa.

Referências: [cota de GitHub Actions](https://docs.github.com/en/billing/concepts/product-billing/github-actions), [instalação do AltStore no Windows](https://faq.altstore.io/altstore-classic/how-to-install-altstore-windows) e [renovação dos apps](https://faq.altstore.io/altstore-classic/your-altstore).
