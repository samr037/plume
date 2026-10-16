#!/bin/sh
# Construit Plume.app : binaire Swift, llama-server (llama.cpp) et ses dylibs, traductions, licences.
#
# Variables :
#   WL_BUILD      dossier de build SwiftPM (défaut /tmp/wl-build ; hors de ~/Claude : "build.db disk I/O error" sinon)
#   WL_APP        app produite (défaut ~/Applications/Plume.app)
#   WL_SIGN       identité de signature. Défaut "Plume Dev" : certificat auto-signé local et stable, car macOS
#                 rattache l'autorisation d'Accessibilité à l'identité (une signature ad hoc la perd à chaque build).
#                 "-" = signature ad hoc (CI).
#   WL_VERSION    version affichée (CFBundleShortVersionString), ex. 0.2.0
#   WL_LLAMA_TAG  build llama.cpp embarqué (défaut b11429)
set -e
cd "$(dirname "$0")/.."
BUILD="${WL_BUILD:-/tmp/wl-build}"
APP="${WL_APP:-$HOME/Applications/Plume.app}"
IDENTITY="${WL_SIGN:-Plume Dev}"
LLAMA_TAG="${WL_LLAMA_TAG:-b11429}"
BUNDLE_ID=io.github.samr037.plume

swift build -c release --product Plume --scratch-path "$BUILD"
BIN="$(swift build -c release --product Plume --scratch-path "$BUILD" --show-bin-path)/Plume"

# llama.cpp précompilé (arm64, Metal), mis en cache dans le dossier de build.
LLAMA_DIR="$BUILD/llama-$LLAMA_TAG"
if [ ! -x "$LLAMA_DIR/llama-server" ]; then
  echo "Téléchargement de llama.cpp $LLAMA_TAG…"
  mkdir -p "$BUILD"
  T="$(mktemp -d)"
  curl -fsSL "https://github.com/ggml-org/llama.cpp/releases/download/$LLAMA_TAG/llama-$LLAMA_TAG-bin-macos-arm64.tar.gz" -o "$T/llama.tgz"
  tar xzf "$T/llama.tgz" -C "$T"
  rm -rf "$LLAMA_DIR"
  mv "$T/llama-$LLAMA_TAG" "$LLAMA_DIR"
  rm -rf "$T"
fi

if [ "$IDENTITY" = "Plume Dev" ] && ! security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
  echo "Création du certificat de signature local « $IDENTITY »…"
  T="$(mktemp -d)"
  /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=$IDENTITY" \
    -keyout "$T/key.pem" -out "$T/cert.pem" \
    -addext "keyUsage=critical,digitalSignature" -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null
  /usr/bin/openssl pkcs12 -export -inkey "$T/key.pem" -in "$T/cert.pem" -out "$T/id.p12" -passout pass:wl
  security import "$T/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P wl -T /usr/bin/codesign
  rm -rf "$T"
fi

rm -rf "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -n "$WL_VERSION" ] && /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $WL_VERSION" "$APP/Contents/Info.plist"
cp "$BIN" "$APP/Contents/MacOS/Plume"

# llama-server et les dylibs qu'il charge (@rpath = @loader_path : même dossier). cp -L résout les liens symboliques.
cp -L "$LLAMA_DIR/llama-server" "$APP/Contents/MacOS/"
for lib in libllama-server-impl.dylib libllama-common.0.dylib libmtmd.0.dylib libllama.0.dylib libggml.0.dylib \
           libggml-cpu.0.dylib libggml-blas.0.dylib libggml-metal.0.dylib libggml-rpc.0.dylib libggml-base.0.dylib; do
  cp -L "$LLAMA_DIR/$lib" "$APP/Contents/MacOS/"
done

# Traductions (français = langue de développement, anglais via en.lproj).
for l in Resources/*.lproj; do rm -rf "$APP/Contents/Resources/$(basename "$l")"; cp -R "$l" "$APP/Contents/Resources/"; done
# Bundles de ressources SwiftPM éventuels (WhisperKit/tokenizers).
for b in "$(dirname "$BIN")"/*.bundle; do [ -e "$b" ] && cp -R "$b" "$APP/Contents/Resources/"; done
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp Resources/THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/THIRD_PARTY_NOTICES.txt"
cp LICENSE "$APP/Contents/Resources/LICENSE.txt"

# Le code imbriqué d'abord, puis l'app.
for f in "$APP/Contents/MacOS/llama-server" "$APP"/Contents/MacOS/*.dylib; do
  codesign --force --sign "$IDENTITY" "$f"
done
codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP"
codesign --verify --strict --verbose=1 "$APP"
echo "Construit : $APP"
