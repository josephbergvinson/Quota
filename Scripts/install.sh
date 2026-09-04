#!/bin/zsh

set -euo pipefail

script_directory="${0:A:h}"
minimum_macos_major=15
minimum_macos_minor=6
minimum_xcode_major=26
minimum_swift_major=6
minimum_swift_minor=2

fail() {
    print -u2 "Quota could not be installed: $1"
    exit 1
}

[[ "$(uname -s)" == "Darwin" ]] || fail "this installer only runs on macOS."

macos_version="$(sw_vers -productVersion)"
[[ "${macos_version}" == *.* ]] || fail "macOS reported an unexpected version: ${macos_version}."
macos_major="${macos_version%%.*}"
macos_remainder="${macos_version#*.}"
macos_minor="${macos_remainder%%.*}"
[[ "${macos_major}" == <-> ]] || fail "macOS reported an unexpected version: ${macos_version}."
[[ "${macos_minor}" == <-> ]] || fail "macOS reported an unexpected version: ${macos_version}."
if (( macos_major < minimum_macos_major || \
      (macos_major == minimum_macos_major && macos_minor < minimum_macos_minor) )); then
    fail "source installation requires macOS ${minimum_macos_major}.${minimum_macos_minor} or later; this Mac is running ${macos_version}. Download the prebuilt release to use Quota on macOS 14."
fi

developer_directory="${DEVELOPER_DIR:-}"
if [[ -z "${developer_directory}" ]]; then
    if [[ -d "/Applications/Xcode.app/Contents/Developer" ]]; then
        developer_directory="/Applications/Xcode.app/Contents/Developer"
    else
        developer_directory="$(xcode-select -p 2>/dev/null || true)"
    fi
fi

[[ -n "${developer_directory}" ]] || fail "install the full Xcode app, open it once, then try again."
[[ -d "${developer_directory}" ]] || fail "Xcode was not found at ${developer_directory}."
[[ "${developer_directory}" != "/Library/Developer/CommandLineTools" ]] || \
    fail "the Command Line Tools alone are not enough; install the full Xcode app."

export DEVELOPER_DIR="${developer_directory}"
if ! xcode_version="$(/usr/bin/xcodebuild -version 2>/dev/null)"; then
    fail "Xcode is not ready. Open Xcode once, finish any component installation, and accept its license."
fi
xcode_version_number="$(print -r -- "${xcode_version}" | /usr/bin/sed -nE \
    's/^Xcode ([0-9]+)(\.[0-9]+)?.*/\1/p' | /usr/bin/head -n 1)"
[[ -n "${xcode_version_number}" ]] || fail "Xcode reported an unrecognized version."
(( xcode_version_number >= minimum_xcode_major )) || \
    fail "Xcode ${minimum_xcode_major} or later is required; this Mac has Xcode ${xcode_version_number}."

swift_version_output="$(/usr/bin/xcrun swift --version 2>/dev/null)" || \
    fail "Xcode could not find the Swift compiler."
swift_version="$(print -r -- "${swift_version_output}" | /usr/bin/sed -nE \
    's/.*Apple Swift version ([0-9]+\.[0-9]+).*/\1/p' | /usr/bin/head -n 1)"
[[ -n "${swift_version}" ]] || fail "Xcode reported an unrecognized Swift version."
swift_major="${swift_version%%.*}"
swift_minor="${swift_version#*.}"
if (( swift_major < minimum_swift_major || \
      (swift_major == minimum_swift_major && swift_minor < minimum_swift_minor) )); then
    fail "Swift ${minimum_swift_major}.${minimum_swift_minor} or later is required; Xcode provides Swift ${swift_version}."
fi

codex_available=false
for candidate in \
    "/Applications/ChatGPT.app/Contents/Resources/codex" \
    "/Applications/Codex.app/Contents/Resources/codex"
do
    if [[ -x "${candidate}" ]]; then
        codex_available=true
        break
    fi
done
if [[ "${codex_available}" == false ]] && command -v codex >/dev/null 2>&1; then
    codex_available=true
fi

claude_available=false
if [[ -d "/Applications/Claude.app" ]] || command -v claude >/dev/null 2>&1; then
    claude_available=true
fi

print "Installing Quota with ${xcode_version%%$'\n'*} (Swift ${swift_version})..."
if [[ "${codex_available}" == false ]]; then
    print -u2 "Note: ChatGPT Plus and Pro connections require the ChatGPT app, Codex app, or Codex CLI."
fi
if [[ "${claude_available}" == false ]]; then
    print -u2 "Note: Claude Pro and Max connections require Claude Desktop or a current Claude Code install."
fi
if [[ "${codex_available}" == false && "${claude_available}" == false ]]; then
    print -u2 "      Quota can still be used with an OpenAI or Anthropic organization Admin API key."
fi

"${script_directory}/build-app.sh" release --open
