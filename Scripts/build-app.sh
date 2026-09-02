#!/bin/zsh

set -euo pipefail

script_directory="${0:A:h}"
repository_directory="${script_directory:h}"
configuration="${1:-debug}"
launch_after_build="${2:-}"

if [[ "${configuration}" != "debug" && "${configuration}" != "release" ]]; then
    print -u2 "Configuration must be 'debug' or 'release'."
    exit 2
fi
if [[ -n "${launch_after_build}" && "${launch_after_build}" != "--open" ]]; then
    print -u2 "Second argument must be '--open' when provided."
    exit 2
fi

if [[ -z "${DEVELOPER_DIR:-}" && -d "/Applications/Xcode.app/Contents/Developer" ]]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

cd "${repository_directory}"
swift build -c "${configuration}" --product Quota

binary_directory="$(swift build -c "${configuration}" --show-bin-path)"
binary_path="${binary_directory}/Quota"
current_user="$(id -un)"
user_home_directory="$(/usr/bin/dscl . -read "/Users/${current_user}" NFSHomeDirectory | /usr/bin/awk '{print $2}')"
if [[ "${user_home_directory}" != "/Users/${current_user}" ]]; then
    print -u2 "Could not resolve a conventional macOS user home directory."
    exit 4
fi
guarded_applications_directory="${user_home_directory}/Applications"
destination="${guarded_applications_directory}/Quota.app"
staging_directory="$(mktemp -d "${TMPDIR:-/tmp}/quota-app.XXXXXX")"
staged_app="${staging_directory}/Quota.app"

cleanup() {
    rm -rf "${staging_directory}"
}
trap cleanup EXIT

mkdir -p "${staged_app}/Contents/MacOS" "${staged_app}/Contents/Resources"
cp "${binary_path}" "${staged_app}/Contents/MacOS/Quota"
cp "${repository_directory}/Supporting/Info.plist" "${staged_app}/Contents/Info.plist"

iconset_directory="${staging_directory}/Quota.iconset"
mkdir -p "${iconset_directory}"
swift "${repository_directory}/Scripts/generate-icon.swift" "${iconset_directory}/icon_512x512@2x.png"
for icon_spec in \
    "16:icon_16x16.png" \
    "32:icon_16x16@2x.png" \
    "32:icon_32x32.png" \
    "64:icon_32x32@2x.png" \
    "128:icon_128x128.png" \
    "256:icon_128x128@2x.png" \
    "256:icon_256x256.png" \
    "512:icon_256x256@2x.png" \
    "512:icon_512x512.png"
do
    icon_size="${icon_spec%%:*}"
    icon_name="${icon_spec#*:}"
    sips -z "${icon_size}" "${icon_size}" \
        "${iconset_directory}/icon_512x512@2x.png" \
        --out "${iconset_directory}/${icon_name}" >/dev/null
done
iconutil -c icns "${iconset_directory}" -o "${staged_app}/Contents/Resources/Quota.icns"

case "${destination}" in
    /Users/*/Applications/Quota.app) ;;
    *)
        print -u2 "Refusing to replace unexpected destination: ${destination}"
        exit 3
        ;;
esac

mkdir -p "${guarded_applications_directory}"
rm -rf "${destination}"
mv "${staged_app}" "${destination}"
xattr -cr "${destination}"
codesign --force --sign - --identifier com.jbergvinson.quota "${destination}" >/dev/null
codesign --verify --deep --strict "${destination}"
print "Built ${destination}"
if [[ "${launch_after_build}" == "--open" ]]; then
    open "${destination}"
fi
