#!/bin/bash
set -euo pipefail
cd -- "$(dirname -- "$0")/.."

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo 'Execute este script no Mac do GitHub Actions. Ele não compila iOS no Windows.' >&2
  exit 1
fi

mkdir -p build dist
xcodebuild -version
xcodebuild \
  -project LiveShopCamera.xcodeproj \
  -scheme LiveShopCamera \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY='' \
  build 2>&1 | tee build/ios-build.log

app='build/DerivedData/Build/Products/Release-iphoneos/LiveShopCamera.app'
[[ -d "$app" ]] || { echo 'A compilação não gerou o aplicativo esperado.' >&2; exit 1; }

# A fresh staging folder avoids stale products without deleting an existing directory.
stage=$(mktemp -d "$PWD/build/ipa.XXXXXX")
mkdir "$stage/Payload"
ditto "$app" "$stage/Payload/LiveShopCamera.app"
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$stage/Payload/LiveShopCamera.app/Info.plist"

# This is an unsigned device binary, not a simulator build and not a signed distribution.
# AltStore/AltServer will sign it locally with the user's Apple account.
destination="$PWD/dist/LiveShopCamera-unsigned.ipa"
if [[ -f "$destination" ]]; then
  echo 'Já existe um IPA neste diretório. Use uma pasta de trabalho limpa para evitar confusão.' >&2
  exit 1
fi
(cd "$stage" && /usr/bin/zip -qry "$destination" Payload)
/usr/bin/unzip -t "$destination"
/usr/bin/shasum -a 256 "$destination"

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  cat >> "$GITHUB_STEP_SUMMARY" <<'SUMMARY'
### Pacote para iPhone gerado

Baixe **LiveShopCamera-iPhone** em **Artifacts**, extraia o ZIP e instale o arquivo
**LiveShopCamera-unsigned.ipa** pelo AltStore/AltServer no Windows.

O pacote ainda precisa ser assinado no seu computador. Não coloque a senha da sua
conta Apple nos arquivos ou nos segredos deste repositório.

A compilação bem-sucedida não confirma o funcionamento da lapela: teste o receptor
no iPhone físico e confira o áudio no Gerenciador de LIVE.
SUMMARY
fi
