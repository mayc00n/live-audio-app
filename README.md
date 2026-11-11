# LiveShop Camera para iPhone — primeira versão nativa

Atualização **0.1.3**: captura de gravação direta via RemoteIO no lugar do áudio de chamadas do WebRTC, preferência fixa pelo receptor Lightning e bloqueio de amostras quando a entrada muda. [Compilação para iPhone](https://github.com/mayc00n/live-audio-app/actions/runs/43072225350). A seleção 0,5x e a integração com a extensão local 0.4.1 permanecem. A confirmação da lapela exige testar o app atualizado no iPhone físico.

Atualização **0.1.1**: [compilação para iPhone aprovada](https://github.com/mayc00n/live-audio-app/actions/runs/43056132828). Corrige a consulta de entradas após falha e adiciona diagnóstico comparando os modos Gravação, Comunicação e Padrão do iOS. Com o receptor conectado, use **Diagnosticar lapela nos três modos → Ver diagnóstico do microfone → Copiar diagnóstico**. Esse teste não transmite áudio nem confirma sozinho a captação física pela lapela.

O app captura câmera e microfone com APIs nativas do iOS e envia mídia por WebRTC diretamente à extensão LiveShop Copilot no Chrome. O VDO.Ninja não participa. O servidor Windows existente continua necessário apenas para pareamento/sinalização; não recebe nem retransmite os quadros da câmera.

**Sem Mac próprio:** siga [COMECE-AQUI-WINDOWS.md](COMECE-AQUI-WINDOWS.md) para compilar em um runner macOS do GitHub Actions e assinar/instalar pelo AltStore no Windows. A primeira [compilação para iPhone passou](https://github.com/mayc00n/live-audio-app/actions/runs/42901148222) em 10/11/2026 e gerou o pacote `LiveShopCamera-unsigned.ipa`.

## Estado real da entrega

Projeto Swift/SwiftUI e Xcode com WebRTC 157.0.0 fixado, QR nativo, prévia sem corte, seleção de entrada de áudio e controles compatíveis com a extensão existente. **Compilado com sucesso no Xcode 16.4 em um Mac do GitHub Actions para iPhone ARM64**. O IPA e a biblioteca WebRTC incorporada tiveram a integridade e a plataforma verificadas. A instalação, a captura no iPhone físico e a lapela ainda precisam de teste. Os testes de protocolo no Windows e a compilação não substituem esses testes físicos. O IPA é entregue sem assinatura para assinatura local pelo AltStore/AltServer.

O app usa `AVAudioSession.availableInputs`, `setPreferredInput` e verifica `currentRoute.inputs`. Exigir microfone externo vem ativado. Se a entrada desejada não estiver realmente ativa, o app bloqueia o áudio e mostra o motivo. O nome/UID verificado identifica a rota do iOS; a confirmação final da lapela exige falar nela e ouvir/medir o som recebido no computador.

## Compilar e instalar no iPhone

1. Transfira esta pasta inteira para um Mac com Xcode 16 ou superior. O app requer iOS 17 ou superior.
2. Abra `LiveShopCamera.xcodeproj`. Aguarde o Xcode baixar o pacote WebRTC. Há acesso à internet nessa etapa; o uso em rede local não depende do VDO.
3. Em **Signing & Capabilities**, selecione sua equipe Apple e, se necessário, altere o Bundle Identifier para um identificador seu. As credenciais de assinatura não estão incluídas.
4. Conecte o iPhone ao Mac, habilite o Modo de Desenvolvedor quando solicitado e selecione esse iPhone como destino. Execute **Run**. Uma conta pessoal pode servir ao teste local, sujeita às limitações de assinatura da Apple; TestFlight/App Store têm requisitos próprios.
5. Para verificar build e testes no simulador, execute `bash validar-no-mac.command` no Terminal. O simulador verifica compilação/protocolo; não valida um receptor Lightning.

## Vincular à extensão existente

1. No Windows, mantenha aberto o servidor `iniciar-servidor-iphone.bat` do projeto original.
2. No widget/painel, desconecte o VDO e abra **iPhone via Wi-Fi**. Gere um QR local atualizado. Use o QR cuja URL começa com `https://IP-DO-PC:8443/iphone?token=...`; não use a URL `vdo.ninja/?view=...`.
3. Conecte a lapela Lightning ao iPhone e feche o VDO/câmera de outros apps para liberar os dispositivos.
4. No LiveShop Camera, leia o QR com **Ler QR da extensão**. Também é possível colar a URL completa. iPhone e PC devem estar no mesmo Wi-Fi, com acesso entre os dispositivos permitido pela rede.
5. Toque em **Conectar e transmitir**, permitindo câmera, microfone e rede local. O app verifica o HTTPS com a confiança normal do iOS. O perfil CA já instalado e confiável deve corresponder ao servidor atual; não é necessário recriar certificados como parte desta entrega.
6. Confirme **Entrada ativa**. Escolha o receptor na lista se houver mais de uma entrada. Em **Exigir microfone externo**, o app não deve enviar o microfone interno como substituto silencioso.
7. No Gerenciador de LIVE, mantenha selecionados **LiveShop Copilot Virtual Camera** e **LiveShop Copilot Virtual Microphone**. Confirme vídeo e áudio antes de transmitir ao público.

Mantenha o app em primeiro plano e o telefone desbloqueado. Ao ir para segundo plano, esta versão encerra a captura. A conexão usa apenas candidatos ICE locais: redes com isolamento de clientes/AP ou que bloqueiem UDP podem impedir a transmissão. Não há TURN externo.

## Validação física necessária

- Falar somente na lapela e comparar com o microfone interno; verificar a rota mostrada no app.
- Desconectar a lapela: o app deve bloquear áudio e indicar a entrada indisponível. Reconectar e atualizar as entradas.
- Trocar câmera mantendo a lapela; mutar/desmutar pelo app e pela extensão.
- Testar a imagem em retrato e a fluidez por ao menos 10 minutos, começando em HD/30 FPS. Não há garantia de que a remoção do VDO, sozinha, elimine todas as travadas do caminho da extensão.
- Confirmar novamente os modos USB e vídeo da extensão. Nenhum desses caminhos foi alterado para adicionar o app.

## Estrutura e dependência

- `LiveShopCamera/CameraPublisher.swift`: câmera nativa, oferta/resposta SDP, fila ICE, comandos remotos, estatísticas e ciclo de captura.
- `LiveShopCamera/AudioRouter.swift`: seleção/verificação de entrada física e bloqueio de fallback indevido.
- `LiveShopCamera/Pairing.swift`: validação da URL local e protocolo do servidor atual. Token apenas em memória; não é gravado em preferências.
- `LiveShopCameraTests/PairingTests.swift`: testes a executar no Mac.
- Dependência binária de terceiros: [stasel/WebRTC, versão 157.0.0](https://github.com/stasel/WebRTC/tree/157.0.0), distribuída por Swift Package Manager. Não é um pacote oficial da Apple. O manifesto dessa versão fixa o checksum do XCFramework. Licenças: consulte o repositório e os avisos incluídos na distribuição.

O projeto usa as [APIs de seleção de entrada da Apple](https://developer.apple.com/documentation/avfaudio/avaudiosession/availableinputs) e o [WebRTC nativo](https://webrtc.github.io/webrtc-org/native-code/ios/). O REA foi usado na investigação anterior do navegador; não há binário deste app compilado para inspecionar nem acesso de depuração ao iPhone nesta etapa. Não se afirma que a lapela já tenha sido testada pelo REA.
